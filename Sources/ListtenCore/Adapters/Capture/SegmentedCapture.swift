import AVFoundation
import Foundation

/// Writes each track to numbered CAF files, closing one every rotation.
///
/// A single file whose header is only written at the end loses everything to a
/// crash. Closing a file every rotation is what makes the write-ahead claim
/// literal: a `kill -9` costs the tail of one segment, and every file before it
/// is complete, playable and transcribable.
public actor SegmentedCapture: AudioCapturing {
    public struct UnsupportedAudioFormat: Error, Equatable {
        public let sampleRate: Double
    }

    /// Confirming needs a capture to confirm: there is nothing held before one
    /// starts, and nowhere to hand it once the sources ended or it has stopped.
    public struct CaptureNotRunning: Error, Equatable {}

    private struct OpenFile {
        let file: AVAudioFile
        let format: AVAudioFormat
        let index: Int
    }

    private let sources: [Track: any AudioSource]
    private let directory: URL
    private let rotateEvery: TimeInterval

    private var continuation: AsyncStream<Segment>.Continuation?
    /// Whether the stream can still carry a segment, which a live continuation
    /// alone does not say: the sources ending finishes it without clearing it.
    private var isRunning = false
    private var writers: [Task<Void, Never>] = []
    private var supervisor: Task<Void, Never>?
    private var accumulators: [Track: SegmentAccumulator] = [:]
    private var open: [Track: OpenFile] = [:]
    private var anchor: TimeInterval?
    private var writeFailure: (any Error)?
    private var preRoll: PreRoll?

    /// A positive `preRoll` holds that many seconds in memory and writes nothing
    /// until `confirm()`, so the stream carries no segment before the user has
    /// answered. Zero, the default, writes from the first buffer.
    public init(
        sources: [Track: any AudioSource],
        directory: URL,
        rotateEvery: TimeInterval = 45,
        preRoll: TimeInterval = 0
    ) {
        precondition(rotateEvery > 0, "a rotation of zero closes a segment per buffer")
        precondition(preRoll >= 0, "a pre-roll cannot reach forwards")
        self.sources = sources
        self.directory = directory
        self.rotateEvery = rotateEvery
        self.preRoll = preRoll > 0 ? PreRoll(window: preRoll) : nil
    }

    /// Frames the ring is holding for a session nobody has answered for yet.
    public var preRollFrames: Int { preRoll?.frames ?? 0 }

    /// The user said yes. What the ring holds becomes the opening of the first
    /// segment and the ring is done: everything after this is written as it
    /// arrives. Refusing is simply never calling this, which costs nothing and
    /// leaves nothing behind.
    ///
    /// Confirming twice, or confirming a capture with no pre-roll, writes
    /// nothing: the audio was handed over already. Confirming one that is not
    /// running is refused rather than ignored, since a drain with nowhere to
    /// yield leaves files on disk that no session ever accounts for.
    public func confirm() throws {
        guard isRunning else { throw CaptureNotRunning() }
        guard var pending = preRoll else { return }
        preRoll = nil
        for held in pending.draining() {
            try write(held.audio, to: held.track)
        }
    }

    /// Returns once every device is running, not once they have been asked to:
    /// a caller that stops immediately afterwards would otherwise race a source
    /// into starting after it was told to stop.
    public func start() async throws -> AsyncStream<Segment> {
        guard continuation == nil else { throw CaptureAlreadyStarted() }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let (stream, continuation) = AsyncStream<Segment>.makeStream()
        self.continuation = continuation

        // Marked running only once every source is, and unwound if one refuses:
        // a half-started capture that still looks started drains confirm() into
        // a stream nobody reads, and blocks the retry that would have worked.
        do {
            for (track, source) in sources {
                let audio = try await source.start()
                writers.append(Task { await self.consume(track, from: audio) })
            }
        } catch {
            for writer in writers {
                writer.cancel()
            }
            for source in sources.values {
                await source.stop()
            }
            writers = []
            continuation.finish()
            self.continuation = nil
            throw error
        }
        isRunning = true

        // Every source ending means no more audio is coming, so the stream ends
        // there. Waiting for stop instead would hang any caller that drains the
        // stream first, which is how a caller naturally reads one.
        let running = writers
        supervisor = Task { [weak self] in
            for writer in running {
                _ = await writer.result
            }
            await self?.sourcesEnded()
        }
        return stream
    }

    private func sourcesEnded() {
        isRunning = false
        continuation?.finish()
    }

    public func stop() async throws -> [Segment] {
        guard continuation != nil else { return [] }

        for source in sources.values {
            await source.stop()
        }
        for writer in writers {
            _ = await writer.result
        }
        writers = []
        supervisor = nil

        // Whatever is still open is finalized here rather than abandoned, so
        // stopping never costs the audio since the last rotation.
        var partials: [Segment] = []
        for track in accumulators.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            if let segment = try accumulators[track]?.closing() {
                partials.append(segment)
            }
            open[track] = nil
        }

        isRunning = false
        continuation?.finish()
        continuation = nil
        accumulators = [:]
        anchor = nil

        // Thrown after finalizing, so everything that could reach disk did. The
        // files are still there and their names are derivable from the track and
        // index, but this call cannot hand back both a list and a failure.
        if let failure = writeFailure {
            writeFailure = nil
            throw failure
        }
        return partials
    }

    private func consume(_ track: Track, from stream: AsyncStream<CapturedAudio>) async {
        do {
            for await audio in stream {
                // While the ring is holding, nothing reaches disk: the answer
                // has not come, and a refusal must leave no trace of the audio.
                guard preRoll == nil else {
                    preRoll?.append(audio, to: track)
                    continue
                }
                try write(audio, to: track)
            }
        } catch {
            // AsyncStream carries no failure, so it is held until stop, which is
            // the one place a caller must look. Silence here would make a full
            // disk indistinguishable from a meeting that ended.
            writeFailure = writeFailure ?? error
        }
    }

    private func write(_ audio: CapturedAudio, to track: Track) throws {
        // A device swapped mid-session can come back at another rate, and a file
        // written at two rates plays back as neither.
        if let current = open[track], current.format.sampleRate != audio.sampleRate {
            try closeOpenSegment(of: track)
        }

        var accumulator = accumulator(for: track, anchoredAt: audio.hostTime)
        let placement = try accumulator.placing(audio)
        accumulators[track] = accumulator

        try file(for: track, index: placement.index, rate: audio.sampleRate)
            .write(from: try buffer(from: audio))

        guard let closed = placement.closed else { return }
        open[track] = nil
        continuation?.yield(closed)
    }

    /// The anchor is the first buffer any track delivered, not the instant
    /// start returned: a device can stamp a buffer marginally before that, and
    /// audio older than the anchor is refused rather than placed at a negative
    /// instant. Both tracks share it, which is what lines them up.
    private func accumulator(
        for track: Track,
        anchoredAt hostTime: TimeInterval
    )
        -> SegmentAccumulator
    {
        let anchor = anchor ?? hostTime
        self.anchor = anchor
        if let existing = accumulators[track] { return existing }
        let fresh = SegmentAccumulator(track: track, anchor: anchor, rotateEvery: rotateEvery)
        accumulators[track] = fresh
        return fresh
    }

    private func closeOpenSegment(of track: Track) throws {
        guard var accumulator = accumulators[track], let closed = try accumulator.closing() else {
            return
        }
        accumulators[track] = accumulator
        open[track] = nil
        continuation?.yield(closed)
    }

    private func file(for track: Track, index: Int, rate: Double) throws -> AVAudioFile {
        if let current = open[track], current.index == index {
            return current.file
        }
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1) else {
            throw UnsupportedAudioFormat(sampleRate: rate)
        }
        let file = try AVAudioFile(
            forWriting: url(for: track, index: index),
            settings: format.settings
        )
        open[track] = OpenFile(file: file, format: format, index: index)
        return file
    }

    private func buffer(from audio: CapturedAudio) throws -> AVAudioPCMBuffer {
        guard
            let format = AVAudioFormat(standardFormatWithSampleRate: audio.sampleRate, channels: 1),
            let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(audio.frames)
            ),
            let channel = buffer.floatChannelData?[0]
        else {
            throw UnsupportedAudioFormat(sampleRate: audio.sampleRate)
        }
        buffer.frameLength = AVAudioFrameCount(audio.frames)
        audio.samples.withUnsafeBufferPointer { source in
            channel.update(from: source.baseAddress!, count: audio.frames)
        }
        return buffer
    }

    /// `mic-0001.caf`, matching the layout the design describes.
    public nonisolated func url(for track: Track, index: Int) -> URL {
        let prefix = track == .microphone ? "mic" : "sys"
        return directory.appending(path: "\(prefix)-\(String(format: "%04d", index + 1)).caf")
    }
}
