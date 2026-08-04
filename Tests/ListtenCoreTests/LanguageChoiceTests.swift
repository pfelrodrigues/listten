import Foundation
import Testing

@testable import ListtenCore

/// Hears one language, and only from the segment named: everything before it is
/// silence, which is what a meeting waiting for people to join sounds like.
private func detector(_ language: String, audibleFrom index: Int = 0) -> FakeLanguageDetection {
    FakeLanguageDetection(
        candidates: ["en-US", "pt-BR"],
        heard: ["mic-\(index).caf": language]
    )
}

private func file(_ index: Int) -> SegmentFile {
    SegmentFile(
        track: .microphone,
        index: index,
        duration: 45,
        url: URL(filePath: "/memory/mic-\(index).caf")
    )
}

@Test("a language said outright is used, and nothing is transcribed to find it")
func aFixedLanguageIsUsedAsGiven() async throws {
    let chosen = try await LanguageChoice.fixed("en-US")
        .resolved(against: [file(0)], using: detector("pt-BR"))

    #expect(chosen == "en-US")
}

@Test("a detected language is the one the audio turned out to be in")
func aDetectedLanguageComesFromTheAudio() async throws {
    let chosen = try await LanguageChoice.detected
        .resolved(against: [file(0)], using: detector("pt-BR"))

    #expect(chosen == "pt-BR")
}

/// Most meetings open with people waiting for the last person to join. Deciding
/// the language on that would decide it on nothing.
@Test("silence at the start does not decide the language")
func silenceAtTheStartIsSkipped() async throws {
    let chosen = try await LanguageChoice.detected.resolved(
        against: [file(0), file(1), file(2)],
        using: detector("pt-BR", audibleFrom: 2)
    )

    #expect(chosen == "pt-BR")
}

/// A meeting nobody could hear in any language. Saying so beats picking one and
/// transcribing an hour of audio into nothing.
@Test("a meeting nothing was heard in is refused rather than assigned a language")
func aMeetingHeardInNoLanguageIsRefused() async {
    await #expect(throws: LanguageChoice.Undetectable.self) {
        _ = try await LanguageChoice.detected.resolved(
            against: [file(0), file(1)],
            using: detector("pt-BR", audibleFrom: 9)
        )
    }
}
