import Foundation
import Testing

@testable import ListtenCore

/// The fakes are how the suite stays predictable, so their own guarantees are
/// worth a test.
@Test("the store lists unfinished sessions in a stable order")
func unfinishedSessionsComeBackInAStableOrder() async throws {
    let store = InMemorySessionStore()
    for id in ["delta", "alpha", "charlie", "bravo", "echo", "foxtrot"] {
        try await store.save(Session(id: id, startedAt: .init(timeIntervalSince1970: 0)))
    }

    let listed = try await store.unfinished().map(\.id)

    #expect(listed == ["alpha", "bravo", "charlie", "delta", "echo", "foxtrot"])
}

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
