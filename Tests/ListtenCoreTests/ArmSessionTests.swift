import Foundation
import Testing

@testable import ListtenCore

@Test("arming stores an armed session and asks the user whether to record")
func armingStoresAndPrompts() async throws {
    let store = InMemorySessionStore()
    let prompts = RecordingPromptSpy()
    let arm = ArmSession(sessions: store, prompt: prompts, clock: FixedClock())

    let session = try await arm.callAsFunction()

    #expect(session.state == .armed)
    #expect(try await store.load(id: session.id)?.state == .armed)
    #expect(await prompts.asked == [session.id])
}
