import Foundation
import Testing

@testable import ListtenCore

/// An implementation plus a sample it can answer for and one it cannot, since
/// one reads a file and the other is told what it heard.
struct LanguageDetectorUnderTest {
    let detector: any LanguageDetecting
    /// A recording in a language the detector knows, and the tag that is.
    let spoken: (sample: SegmentFile, language: String)
    /// A recording nothing could be heard in.
    let silent: SegmentFile
}

/// The rules every `LanguageDetecting` obeys, written once so the fake cannot
/// drift away from the engine that reads audio.
func verifyLanguageDetectingContract(
    _ make: @Sendable () -> LanguageDetectorUnderTest,
    sourceLocation: SourceLocation = #_sourceLocation
) async throws {
    let subject = make()

    #expect(
        !subject.detector.candidates.isEmpty,
        "a detector that knows no languages cannot answer anything",
        sourceLocation: sourceLocation
    )

    let heard = try await subject.detector.language(of: subject.spoken.sample)
    #expect(
        heard == subject.spoken.language,
        "heard \(heard ?? "nothing") in audio spoken in \(subject.spoken.language)",
        sourceLocation: sourceLocation
    )
    #expect(
        heard.map { subject.detector.candidates.contains($0) } ?? false,
        "answered with a language it does not list",
        sourceLocation: sourceLocation
    )

    // Half a meeting in one language and half in another is what a detector
    // that varies produces, and nothing downstream would notice.
    #expect(
        try await subject.detector.language(of: subject.spoken.sample) == heard,
        "the same sample answered differently the second time",
        sourceLocation: sourceLocation
    )

    #expect(
        try await subject.detector.language(of: subject.silent) == nil,
        "silence was assigned a language",
        sourceLocation: sourceLocation
    )
}

@Test("the fake detector honours the contract")
func fakeLanguageDetectorHonoursTheContract() async throws {
    try await verifyLanguageDetectingContract {
        LanguageDetectorUnderTest(
            detector: FakeLanguageDetection(
                candidates: ["en-US", "pt-BR"],
                heard: ["mic-0001.caf": "pt-BR"]
            ),
            spoken: (sample: detectionSample("mic-0001.caf"), language: "pt-BR"),
            silent: detectionSample("mic-0002.caf")
        )
    }
}

func detectionSample(_ name: String) -> SegmentFile {
    SegmentFile(
        track: .microphone,
        index: 0,
        duration: 45,
        url: URL(filePath: "/memory/\(name)")
    )
}
