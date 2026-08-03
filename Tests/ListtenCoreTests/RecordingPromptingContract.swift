import Foundation
import Testing

@testable import ListtenCore

/// Whether the implementation under test can reach the user at all. The port has
/// one outcome for each, so the contract is verified once per case.
enum PromptDelivery {
    case delivered
    case undeliverable
}

/// The rules every `RecordingPrompting` obeys, written once so the spy cannot
/// drift away from the notification centre it stands for. A prompt the user
/// never sees has to throw: an implementation that returns anyway leaves the
/// session armed waiting for an answer nobody can give, which is issue #51.
func verifyRecordingPromptingContract(
    expecting delivery: PromptDelivery,
    _ make: @Sendable () -> any RecordingPrompting,
    sourceLocation: SourceLocation = #_sourceLocation
) async throws {
    let prompt = make()
    switch delivery {
    case .delivered:
        // Returning says nothing about the decision, so the next meeting is still askable.
        try await prompt.askWhetherToRecord(sessionID: "2026-08-02T09-00-00.000Z-aaaaaaaa")
        try await prompt.askWhetherToRecord(sessionID: "2026-08-02T10-00-00.000Z-bbbbbbbb")
    case .undeliverable:
        await #expect(
            throws: (any Error).self,
            "an undelivered prompt reported as delivered",
            sourceLocation: sourceLocation
        ) {
            try await prompt.askWhetherToRecord(sessionID: "2026-08-02T09-00-00.000Z-aaaaaaaa")
        }
    }
}

@Test("the prompt spy honours the contract when the prompt reaches the user")
func spyHonoursTheDeliveredContract() async throws {
    try await verifyRecordingPromptingContract(expecting: .delivered) { RecordingPromptSpy() }
}

@Test("the prompt spy honours the contract when the prompt cannot be delivered")
func spyHonoursTheUndeliverableContract() async throws {
    try await verifyRecordingPromptingContract(expecting: .undeliverable) {
        RecordingPromptSpy(failure: PromptUndeliverable())
    }
}
