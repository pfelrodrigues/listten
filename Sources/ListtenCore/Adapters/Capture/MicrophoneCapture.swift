import AVFoundation
import Foundation

/// Microphone input, delivered as buffers stamped on the machine clock.
///
/// The stamp is the host time AVFoundation reports for the buffer, not the
/// instant this process happened to see it, so the microphone and the system
/// tap describe the same conversation on one timeline.
public actor MicrophoneCapture: AudioSource {
    /// Sized so the drain can fall behind for over a second before anything is
    /// lost, at about 1 MB. The device may hand over more frames than the tap
    /// asked for, so a slot is several times the requested buffer.
    private static let slots = 16
    private static let framesPerSlot = 16384

    private let engine = AVAudioEngine()
    private var continuation: AsyncStream<CapturedAudio>.Continuation?
    private var configurationObserver: (any NSObjectProtocol)?
    private var ring: CaptureRing?
    private var drain: Task<Void, Never>?

    public init() {}

    /// Buffers the audio thread had to throw away because the drain fell
    /// behind. Non-zero means audio is missing from the recording. It survives
    /// stopping, since the caller only asks once the stream has ended.
    public var droppedBuffers: Int { ring?.dropped ?? droppedWhileRunning }
    private var droppedWhileRunning = 0

    public func start() throws -> AsyncStream<CapturedAudio> {
        guard continuation == nil else { throw CaptureAlreadyStarted() }

        let ring = CaptureRing(slots: Self.slots, framesPerSlot: Self.framesPerSlot)
        self.ring = ring

        let (stream, continuation) = AsyncStream<CapturedAudio>.makeStream()
        self.continuation = continuation

        installTap(into: ring)
        observeConfigurationChanges()

        engine.prepare()
        do {
            try engine.start()
        } catch {
            tearDown()
            throw error
        }

        drain = Task.detached(priority: .userInitiated) {
            await Self.drain(ring, into: continuation)
        }
        return stream
    }

    public func stop() {
        guard continuation != nil else { return }
        tearDown()
    }

    /// The engine reports a configuration change when the input device is
    /// swapped. The tap is bound to the old format, so both it and the engine
    /// have to be brought back up; the ring and its timestamps carry on, which
    /// is what keeps the two tracks aligned across the gap.
    private func observeConfigurationChanges() {
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            Task { await self.restartAfterConfigurationChange() }
        }
    }

    private func restartAfterConfigurationChange() {
        guard let ring, continuation != nil else { return }

        engine.inputNode.removeTap(onBus: 0)
        installTap(into: ring)

        guard !engine.isRunning else { return }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            // The device went away for good. Tearing down ends the stream, which
            // tells the caller to finalize what it has rather than wait for
            // audio that is not coming.
            tearDown()
        }
    }

    /// Everything inside the tap block runs on the audio thread, where
    /// allocating, locking or waiting would cost recorded audio. It copies into
    /// a slot that already exists and returns.
    private func installTap(into ring: CaptureRing) {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        let sampleRate = format.sampleRate

        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, time in
            guard let channel = buffer.floatChannelData?[0] else { return }
            _ = ring.write(
                samples: channel,
                frames: Int(buffer.frameLength),
                hostTime: AVAudioTime.seconds(forHostTime: time.hostTime),
                sampleRate: sampleRate
            )
        }
    }

    /// Off the audio thread, so this is where buffers become Swift values. On
    /// cancellation it flushes what the ring still holds before finishing, so
    /// stopping does not cost the last fraction of a second.
    private static func drain(
        _ ring: CaptureRing,
        into continuation: AsyncStream<CapturedAudio>.Continuation
    ) async {
        while !Task.isCancelled {
            var moved = false
            while let audio = ring.read() {
                continuation.yield(audio)
                moved = true
            }
            guard !moved else { continue }
            do {
                try await Task.sleep(for: .milliseconds(5))
            } catch {
                break
            }
        }

        while let audio = ring.read() {
            continuation.yield(audio)
        }
        continuation.finish()
    }

    private func tearDown() {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
        configurationObserver = nil

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()

        if let drain {
            // The drain flushes the ring and finishes the stream on its way out.
            drain.cancel()
        } else {
            continuation?.finish()
        }
        drain = nil
        continuation = nil
        droppedWhileRunning = ring?.dropped ?? droppedWhileRunning
        ring = nil
    }
}
