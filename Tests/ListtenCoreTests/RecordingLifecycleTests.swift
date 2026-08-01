import Foundation
import Testing

@testable import ListtenCore

private func armedSession(in store: InMemorySessionStore) async throws -> Session {
    try await ArmSession(sessions: store, prompt: RecordingPromptSpy(), clock: FixedTimeSource())()
}

@Test("confirming moves the session into recording and persists it")
func confirmingStartsRecording() async throws {
    let store = InMemorySessionStore()
    let session = try await armedSession(in: store)

    let confirmed = try await ConfirmRecording(sessions: store)(sessionID: session.id)

    #expect(confirmed.state == .recording)
    #expect(try await store.load(id: session.id)?.state == .recording)
}

@Test("confirming a session that was never armed fails")
func confirmingUnknownSessionFails() async throws {
    let store = InMemorySessionStore()

    await #expect(throws: SessionNotFound.self) {
        try await ConfirmRecording(sessions: store)(sessionID: "nope")
    }
}

@Test("a recording too short to be a meeting is discarded, keeping its audio")
func shortRecordingIsDiscarded() async throws {
    let store = InMemorySessionStore()
    var session = try await armedSession(in: store)
    session = try session.applying(.confirm)
    session = try session.appending(Segment(index: 0, track: .microphone, start: 0, duration: 20))
    try await store.save(session)

    let stopped = try await StopRecording(sessions: store, minimumDuration: 60)(
        sessionID: session.id
    )

    #expect(stopped.state == .discarded)
}

@Test("a recording long enough to be a meeting moves on to processing")
func longRecordingIsKept() async throws {
    let store = InMemorySessionStore()
    var session = try await armedSession(in: store)
    session = try session.applying(.confirm)
    session = try session.appending(Segment(index: 0, track: .microphone, start: 0, duration: 90))
    try await store.save(session)

    let stopped = try await StopRecording(sessions: store, minimumDuration: 60)(
        sessionID: session.id
    )

    #expect(stopped.state == .recorded)
}

@Test("stopping a session that was never armed fails")
func stoppingUnknownSessionFails() async throws {
    let store = InMemorySessionStore()

    await #expect(throws: SessionNotFound.self) {
        try await StopRecording(sessions: store, minimumDuration: 60)(sessionID: "nope")
    }
}
