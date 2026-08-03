import Foundation
import Testing

@testable import ListtenCore

/// The prompt spy's own guarantees, since the suite leans on them. The ordering
/// promise that used to live here moved into SessionStoringContract, where both
/// implementations answer for it instead of only the tidier one.
@Test("the prompt spy counts a delivered ask once, as attempted and as asked")
func deliveredPromptIsAttemptedAndAsked() async throws {
    let prompts = RecordingPromptSpy()

    try await prompts.askWhetherToRecord(sessionID: "s1")

    #expect(await prompts.attempts == ["s1"])
    #expect(await prompts.asked == ["s1"])
}

@Test("the prompt spy counts an undelivered ask as attempted, never as asked")
func undeliveredPromptIsAttemptedButNotAsked() async throws {
    let prompts = RecordingPromptSpy(failure: PromptUndeliverable())

    await #expect(throws: PromptUndeliverable.self) {
        try await prompts.askWhetherToRecord(sessionID: "s1")
    }

    #expect(await prompts.attempts == ["s1"])
    #expect(await prompts.asked.isEmpty)
}
