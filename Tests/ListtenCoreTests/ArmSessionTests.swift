import Foundation
import Testing

@testable import ListtenCore

@Test("arming stores an armed session and asks the user whether to record")
func armingStoresAndPrompts() async throws {
    let store = InMemorySessionStore()
    let prompts = RecordingPromptSpy()
    let arm = ArmSession(sessions: store, prompt: prompts, clock: FixedTimeSource())

    let session = try await arm.callAsFunction()

    #expect(session.state == .armed)
    #expect(try await store.load(id: session.id)?.state == .armed)
    #expect(await prompts.asked == [session.id])
}

/// Stands for whatever the notification centre refuses with.
struct PromptUndeliverable: Error, Equatable {}

@Test("a prompt that never reached the user fails arming, instead of reading as unanswered")
func undeliverablePromptFailsArming() async throws {
    let store = InMemorySessionStore()
    let prompts = RecordingPromptSpy(failure: PromptUndeliverable())
    let arm = ArmSession(sessions: store, prompt: prompts, clock: FixedTimeSource())

    await #expect(throws: PromptUndeliverable.self) { try await arm() }
    #expect(await prompts.asked.isEmpty)
    #expect(try await store.unfinished().map(\.state) == [.armed])
}

@Test("two sessions armed at the same instant get different ids")
func idsDoNotCollide() async throws {
    let store = InMemorySessionStore()
    let arm = ArmSession(sessions: store, prompt: RecordingPromptSpy(), clock: FixedTimeSource())

    let first = try await arm()
    let second = try await arm()

    #expect(first.id != second.id)
    #expect(try await store.load(id: first.id) != nil)
    #expect(try await store.load(id: second.id) != nil)
}

@Test("session ids sort chronologically")
func idsSortByTime() async throws {
    let store = InMemorySessionStore()
    let early = ArmSession(
        sessions: store,
        prompt: RecordingPromptSpy(),
        clock: FixedTimeSource(now: .init(timeIntervalSince1970: 0))
    )
    let late = ArmSession(
        sessions: store,
        prompt: RecordingPromptSpy(),
        clock: FixedTimeSource(now: .init(timeIntervalSince1970: 3600))
    )

    #expect(try await early().id < late().id)
}
