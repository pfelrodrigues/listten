import AVFoundation
import Foundation
import Speech

/// Which language a recording is in, decided by transcribing a sample of it once
/// per candidate and keeping the one the engine was surest of.
///
/// Confidence rather than word count. Measured on a real recording of Portuguese
/// speech: pt-BR and en-US both returned thirty words, so counting them picked
/// English and transcribed the meeting phonetically ("Boom, when was I, wolf"
/// for "Bom, vamos lá, eu vou falar"). The confidences were 0.93 and 0.29.
public struct SpeechLanguageDetection: LanguageDetecting {
    /// Below this, confidence says nothing. A silent segment came back as a
    /// single full stop with a confidence of 0.8, which would have decided a
    /// meeting on nothing at all.
    private static let enoughWords = 5

    public let candidates: [String]

    public static func installed() async -> SpeechLanguageDetection {
        SpeechLanguageDetection(
            among: Set(await SpeechTranscriber.installedLocales.map { $0.identifier(.bcp47) })
        )
    }

    /// One tag per language rather than per dialect. Nine English dialects would
    /// mean nine passes over the same audio to answer what the first one already
    /// answered, and a dialect barely moves the confidence of a language the
    /// speaker is not speaking.
    ///
    /// Within a language, the region's own where the machine holds it, so a Mac
    /// with en-GB and en-US installed does not pick whichever sorted first.
    public init(among installed: Set<String>) {
        var byLanguage: [String: String] = [:]
        for tag in installed.sorted() {
            let language = String(tag.prefix { $0 != "-" })
            let regional = Locale.Language(identifier: language).maximalIdentifier
            let preferred = Locale.Language(identifier: regional).region
                .map { "\(language)-\($0.identifier)" }
            if byLanguage[language] == nil || tag == preferred {
                byLanguage[language] = tag
            }
        }
        candidates = byLanguage.values.sorted()
    }

    public func language(of sample: SegmentFile) async throws -> String? {
        var best: (language: String, confidence: Double)?

        for candidate in candidates {
            let heard = try await confidence(of: sample, in: candidate)
            guard let heard, heard > (best?.confidence ?? 0) else { continue }
            best = (candidate, heard)
        }
        return best?.language
    }

    /// Nil where the sample produced too little to judge, which is silence and
    /// is not the same as a language the engine was unsure of.
    private func confidence(of sample: SegmentFile, in language: String) async throws -> Double? {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: sample.url)
        } catch {
            throw TranscriptionFailure.unreadableAudio(sample.url.lastPathComponent)
        }

        let transcriber = SpeechTranscriber(
            locale: Locale(identifier: language),
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.transcriptionConfidence]
        )
        let analyzer = SpeechAnalyzer(modules: [transcriber])

        let reading = Task {
            var words = 0
            var total = 0.0
            var scored = 0
            for try await result in transcriber.results {
                let text = String(result.text.characters)
                words += text.split(whereSeparator: \.isWhitespace)
                    .count { SpeechTranscription.carriesWords(String($0)) }
                for run in result.text.runs {
                    guard let confidence = run.transcriptionConfidence else { continue }
                    total += Double(confidence)
                    scored += 1
                }
            }
            return (words: words, confidence: scored > 0 ? total / Double(scored) : 0)
        }

        try await analyzer.start(inputAudioFile: file, finishAfterFile: true)
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        let heard = try await reading.value

        return heard.words >= Self.enoughWords ? heard.confidence : nil
    }
}
