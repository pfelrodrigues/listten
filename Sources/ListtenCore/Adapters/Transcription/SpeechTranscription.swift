import AVFoundation
import Foundation
import Speech

/// Apple's on-device speech recognition, reading finished audio files.
///
/// Measured on audio this product recorded: 45 seconds transcribed in 0.33
/// seconds once the model is warm, which is the bet the whole project was
/// started on.
///
/// Nothing here asks for permission. Speech recognition authorisation covers
/// listening to a person; reading a file the user already recorded does not go
/// through it, which was checked rather than assumed.
public struct SpeechTranscription: Transcribing {
    public let capabilities: TranscriptionCapabilities

    /// Only the locales whose model is on the machine. Declaring one that is
    /// merely supported would promise a transcription that stalls on a download
    /// the caller never asked for, and the port says a language outside the
    /// declared set is refused rather than attempted.
    public static func installed() async -> SpeechTranscription {
        SpeechTranscription(
            languages: Set(await SpeechTranscriber.installedLocales.map { $0.identifier(.bcp47) })
        )
    }

    public init(languages: Set<String>) {
        capabilities = TranscriptionCapabilities(
            // This reads whole files, so a hypothesis has nothing to be useful
            // for and the engine is configured not to produce any. Live captions
            // would be a different preset and a different backend.
            streaming: false,
            // One file goes in per request. The caller transcribes each track
            // and interleaves them on the clock it already owns.
            multitrack: false,
            // The framework has no speaker separation. Two tracks are how this
            // product tells one voice from the others.
            diarization: false,
            languages: languages
        )
    }

    public func transcribe(
        _ request: TranscriptionRequest
    ) async throws -> AsyncThrowingStream<TranscriptionEvent, any Error> {
        guard let track = request.audio.keys.sorted(by: { $0.rawValue < $1.rawValue }).first else {
            throw TranscriptionFailure.noAudio
        }
        guard capabilities.languages.contains(request.language) else {
            throw TranscriptionFailure.unsupportedLanguage(request.language)
        }
        guard request.audio.count == 1 else {
            throw TranscriptionFailure.multitrackUnsupported(tracks: request.audio.count)
        }

        // Opened here rather than in the stream: a file that will not open is a
        // request to fix, not a transport failure to retry, and the port draws
        // that line at whether transcription got under way.
        let url = request.audio[track]!
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw TranscriptionFailure.unreadableAudio(url.lastPathComponent)
        }

        let locale = Locale(identifier: request.language)
        return AsyncThrowingStream { continuation in
            let work = Task {
                do {
                    let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
                    let analyzer = SpeechAnalyzer(modules: [transcriber])

                    let reading = Task {
                        for try await result in transcriber.results {
                            guard let line = try Self.line(from: result) else { continue }
                            continuation.yield(.line(line))
                        }
                    }
                    try await analyzer.start(inputAudioFile: file, finishAfterFile: true)
                    try await analyzer.finalizeAndFinishThroughEndOfInput()
                    try await reading.value
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in work.cancel() }
        }
    }

    /// Whether a result is worth keeping.
    ///
    /// The engine marks a silent stretch with a line holding only punctuation.
    /// Observed on a real recording: after "Teste 123 testando o som", a second
    /// finalized result arrived reading "." and spanning eight seconds. A
    /// transcript made of full stops is noise a reader steps over.
    ///
    /// Separate from `line` because that behaviour cannot be provoked on demand
    /// — silence alone does not do it — so the rule is checked here rather than
    /// left resting on a fixture nobody can regenerate.
    static func carriesWords(_ text: String) -> Bool {
        text.contains { $0.isLetter || $0.isNumber }
    }

    private static func line(from result: SpeechTranscriber.Result) throws -> TranscriptLine? {
        let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
        guard carriesWords(text) else { return nil }

        let start = max(0, result.range.start.seconds)
        let end = max(start, result.range.end.seconds)
        // Speaker stays empty because diarization is declared false, and the
        // contract holds every line to that. The instants are clamped above, so
        // the only way this throws is a rule changing under it, which is worth
        // hearing about rather than turning into a dropped line.
        return try TranscriptLine(speaker: "", start: start, end: end, text: text)
    }
}
