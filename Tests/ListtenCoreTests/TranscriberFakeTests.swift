import Foundation
import Testing

@testable import ListtenCore

/// Written out rather than derived from the fixture, so a fake that started
/// returning something else fails here instead of agreeing with itself.
@Test("the fake returns the transcript it says it has")
func theFakeReturnsAKnownTranscript() async throws {
    let backend = FakeTranscriber()
    let request = TranscriptionRequest(
        audio: [.microphone: fakeAudio[.microphone]!],
        language: "en-US"
    )

    let run = try await transcribed(await backend.transcribe(request))

    #expect(
        run.finalized.map(\.text) == [
            "Shall we start with the migration?",
            "I will draft the plan today.",
        ]
    )
    #expect(run.finalized.map(\.start) == [0, 4])
}

/// A backend that takes both tracks answers about both, which is the difference
/// the `multitrack` capability names.
@Test("a multitrack request comes back with both tracks on one clock")
func aMultitrackRequestReturnsBothTracks() async throws {
    let backend = FakeTranscriber(
        capabilities: TranscriptionCapabilities(
            streaming: false,
            multitrack: true,
            diarization: true,
            languages: ["en-US"]
        )
    )
    let request = TranscriptionRequest(audio: fakeAudio, language: "en-US")

    let run = try await transcribed(await backend.transcribe(request))

    #expect(run.finalized.map(\.speaker) == ["you", "others", "you", "others"])
    #expect(run.finalized.map(\.start) == [0, 2, 4, 6])
}

@Test("each attempt takes the next fault, so a backend can fail once and then work")
func eachAttemptTakesTheNextFault() async throws {
    let backend = FakeTranscriber(faults: [.serverError(status: 500), .timedOut])
    let request = TranscriptionRequest(
        audio: [.microphone: fakeAudio[.microphone]!],
        language: "en-US"
    )

    await #expect(throws: TranscriptionFailure.serverError(status: 500)) {
        _ = try await transcribed(await backend.transcribe(request))
    }
    await #expect(throws: TranscriptionFailure.timedOut) {
        _ = try await transcribed(await backend.transcribe(request))
    }
    let third = try await transcribed(await backend.transcribe(request))

    #expect(third.finalized.count == 2, "the attempt past the last fault did not succeed")
    #expect(await backend.attempts.count == 3)
}

@Test("a fault can be made to land after the caller already has part of the transcript")
func aFaultCanLandAfterSomeEvents() async throws {
    let backend = FakeTranscriber(faults: [.timedOut], deliveredBeforeFault: 3)
    let request = TranscriptionRequest(
        audio: [.microphone: fakeAudio[.microphone]!],
        language: "en-US"
    )

    var delivered: [TranscriptionEvent] = []
    await #expect(throws: TranscriptionFailure.timedOut) {
        for try await event in try await backend.transcribe(request) {
            delivered.append(event)
        }
    }

    #expect(delivered.count == 3)
}
