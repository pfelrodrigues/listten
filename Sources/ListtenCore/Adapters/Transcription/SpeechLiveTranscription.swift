import AVFoundation
import Foundation
import Speech

/// Apple's on-device speech recognition, listening to audio as it arrives.
///
/// The same framework the file-reading backend uses, on a different preset. It
/// is noisier than that one on identical audio — it heard "os criptos" where the
/// file backend heard "os scripts" — which is fine for following along and not
/// fine as the transcript a note is written from.
///
/// Nothing here asks for permission, which was checked rather than assumed:
/// `SFSpeechRecognizer.authorizationStatus()` reads `notDetermined` on this
/// machine and the gated tests below transcribe live audio anyway, from a plain
/// test binary with no bundle identity. Feeding buffers to an analyser does not
/// go through speech recognition authorisation, the same finding
/// `SpeechTranscription` recorded for reading a file.
///
/// Should that ever change, the analyser refuses, the refusal arrives in the
/// stream, and the caller records a live transcript that stopped while the
/// recording carried on. That is the failure this path is allowed to have. A
/// prompt that cannot be shown is not: it is the hang
/// `MicrophoneCapture.ensureAccess` exists to avoid.
public struct SpeechLiveTranscription: LiveTranscribing {
    /// The analyser named no format it can take this audio in. Distinct from a
    /// language it will not transcribe, which is refused before this.
    public struct NoCompatibleAudioFormat: Error, Equatable {}

    public let capabilities: TranscriptionCapabilities

    /// Only the locales whose model is on the machine, for the same reason the
    /// file backend does it: declaring one that is merely supported promises a
    /// transcription that stalls on a download nobody asked for.
    public static func installed() async -> SpeechLiveTranscription {
        SpeechLiveTranscription(
            languages: Set(await SpeechTranscriber.installedLocales.map { $0.identifier(.bcp47) })
        )
    }

    public init(languages: Set<String>) {
        capabilities = TranscriptionCapabilities(
            // Hypotheses arrive about three times a second and carry the whole
            // accumulated text. They are what a caller shows while a line is
            // still being revised, never what it stores.
            streaming: true,
            // One analyser per track. Both tracks through one would lose the
            // attribution that having two tracks is for.
            multitrack: false,
            // The framework has no speaker separation here either.
            diarization: false,
            languages: languages
        )
    }

    public func transcribe(
        _ request: LiveTranscriptionRequest,
        hearing audio: AsyncStream<LiveAudioEvent>
    ) async throws -> AsyncThrowingStream<TranscriptionEvent, any Error> {
        guard capabilities.languages.contains(request.language) else {
            throw TranscriptionFailure.unsupportedLanguage(request.language)
        }

        let transcriber = SpeechTranscriber(
            locale: Locale(identifier: request.language),
            preset: .progressiveTranscription
        )
        guard
            let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
                compatibleWith: [transcriber]
            )
        else {
            throw NoCompatibleAudioFormat()
        }

        return AsyncThrowingStream { continuation in
            let work = Task {
                let analyzer = SpeechAnalyzer(modules: [transcriber])
                let (inputs, feeding) = AsyncStream<AnalyzerInput>.makeStream()
                do {
                    try await analyzer.prepareToAnalyze(in: analyzerFormat)

                    let reading = Task {
                        for try await result in transcriber.results {
                            guard let line = try Self.line(from: result) else { continue }
                            continuation.yield(result.isFinal ? .line(line) : .partial(line))
                        }
                    }
                    try await analyzer.start(inputSequence: inputs)

                    // Rebuilt when the device rate changes, which is the same
                    // mid-session swap the capture already survives. The
                    // conversion runs here rather than at the fork: only this
                    // knows what rate it needs, and this task is neither the
                    // audio thread nor the one writing the recording.
                    var converter: AVAudioConverter?
                    var deviceFormat: AVAudioFormat?

                    for await event in audio {
                        switch event {
                        case .audio(let captured):
                            guard let source = Self.format(of: captured) else { continue }
                            if deviceFormat?.sampleRate != source.sampleRate {
                                deviceFormat = source
                                converter = AVAudioConverter(from: source, to: analyzerFormat)
                            }
                            guard
                                let converter,
                                let buffer = try Self.buffer(from: captured, in: source),
                                let resampled = try Self.resampled(
                                    buffer,
                                    with: converter,
                                    to: analyzerFormat
                                )
                            else { continue }
                            feeding.yield(AnalyzerInput(buffer: resampled))
                        case .settle:
                            // Bounded, because it has been measured not to
                            // return: on a real recording, asked to settle over
                            // a stretch the analyser had nothing volatile for,
                            // `finalize` never came back, and since this is the
                            // task that also feeds the analyser the whole track
                            // stopped — the recording hung on the way out with
                            // its audio safe and the process alive.
                            //
                            // Giving up on one settle costs the lines it would
                            // have closed, which the next settle closes instead.
                            // Waiting forever costs the meeting.
                            //
                            // Issued from the feeding task on purpose, so a
                            // settle cannot overtake the audio it settles.
                            await Self.settling(analyzer)
                        }
                    }

                    feeding.finish()
                    try await analyzer.finalizeAndFinishThroughEndOfInput()
                    try await reading.value
                    continuation.finish()
                } catch {
                    feeding.finish()
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in work.cancel() }
        }
    }

    /// How long a settle is given before the meeting goes on without it. Long
    /// enough that a slow one still lands, short next to the five seconds
    /// between them.
    private static let settleTimeout = Duration.seconds(3)

    private static func settling(_ analyzer: SpeechAnalyzer) async {
        let finalizing = Task { try await analyzer.finalize(through: nil) }
        let timeout = Task {
            try await Task.sleep(for: settleTimeout)
            finalizing.cancel()
        }
        defer { timeout.cancel() }
        // A settle that failed is not a transcription that failed: the lines it
        // would have closed are closed by the next one, or by the finalize that
        // ends the stream. Written as do/catch rather than swallowed in one
        // word, which this module does not allow: discarding a failure has to
        // be something a reader sees a reason for.
        do {
            try await finalizing.value
        } catch {
            return
        }
    }

    private static func format(of audio: CapturedAudio) -> AVAudioFormat? {
        guard audio.sampleRate > 0 else { return nil }
        return AVAudioFormat(standardFormatWithSampleRate: audio.sampleRate, channels: 1)
    }

    /// Its own rather than the capture's, which throws a capture's error and
    /// belongs to the file it is writing.
    private static func buffer(
        from audio: CapturedAudio,
        in format: AVAudioFormat
    ) throws -> AVAudioPCMBuffer? {
        guard
            let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(max(1, audio.frames))
            ),
            let channel = buffer.floatChannelData?[0],
            audio.frames > 0
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(audio.frames)
        audio.samples.withUnsafeBufferPointer { source in
            channel.update(from: source.baseAddress!, count: audio.frames)
        }
        return buffer
    }

    /// The analyser asks for 16 kHz mono; the devices deliver 24 or 48. Off the
    /// audio thread and off the writer's task, so neither pays for it.
    private static func resampled(
        _ buffer: AVAudioPCMBuffer,
        with converter: AVAudioConverter,
        to format: AVAudioFormat
    ) throws -> AVAudioPCMBuffer? {
        let ratio = format.sampleRate / buffer.format.sampleRate
        guard
            let out = AVAudioPCMBuffer(
                pcmFormat: format,
                // Slack for the resampler's own tail, which lands a few frames
                // either side of the ratio.
                frameCapacity: AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
            )
        else { return nil }

        let input = OneShotInput(buffer)
        var failure: NSError?
        converter.convert(to: out, error: &failure) { _, status in input.next(status) }
        if let failure { throw failure }
        guard out.frameLength > 0 else { return nil }
        return out
    }

    /// One buffer, handed over once and then never again.
    ///
    /// The converter's input block is declared `@Sendable`, but it is called
    /// synchronously on this thread before `convert` returns, so nothing here
    /// crosses one. That is what the unchecked conformance stands for.
    private final class OneShotInput: @unchecked Sendable {
        private let buffer: AVAudioPCMBuffer
        private var supplied = false

        init(_ buffer: AVAudioPCMBuffer) {
            self.buffer = buffer
        }

        func next(
            _ status: UnsafeMutablePointer<AVAudioConverterInputStatus>
        ) -> AVAudioPCMBuffer? {
            guard !supplied else {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
    }

    /// Punctuation-only results are dropped by the same rule the file backend
    /// uses. A forced cadence lands on a silent stretch far more often than
    /// reading a file does, so the rule matters more here, not less.
    private static func line(from result: SpeechTranscriber.Result) throws -> TranscriptLine? {
        let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
        guard SpeechTranscription.carriesWords(text) else { return nil }

        let start = max(0, result.range.start.seconds)
        let end = max(start, result.range.end.seconds)
        // Speaker stays empty because diarization is declared false, and the
        // contract holds every line to that.
        return try TranscriptLine(speaker: "", start: start, end: end, text: text)
    }
}
