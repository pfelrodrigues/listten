import Foundation
import Testing

@testable import ListtenCore

@Test("a session left recording by a crash is treated as recorded, since partial audio is valid")
func interruptedRecordingBecomesRecorded() async throws {
    let store = InMemorySessionStore()
    var session = Session(id: "s1", startedAt: .init(timeIntervalSince1970: 0))
    session = try session.applying(.confirm)
    session = try session.appending(Segment(index: 0, track: .microphone, start: 0, duration: 90))
    try await store.save(session)

    let resumed = try await ResumeInterrupted(sessions: store, minimumDuration: 60)()

    #expect(resumed.map(\.state) == [.recorded])
}

@Test("a crash does not rescue a recording that stopping would have discarded")
func recoveryAppliesTheSameMinimumAsStopping() async throws {
    let store = InMemorySessionStore()
    var session = Session(id: "s1", startedAt: .init(timeIntervalSince1970: 0))
    session = try session.applying(.confirm)
    session = try session.appending(Segment(index: 0, track: .microphone, start: 0, duration: 10))
    try await store.save(session)

    let resumed = try await ResumeInterrupted(sessions: store, minimumDuration: 60)()

    #expect(resumed.map(\.state) == [.discarded])
}

@Test("an armed session found at startup is discarded, since its prompt died with the process")
func armedSessionIsDiscarded() async throws {
    let store = InMemorySessionStore()
    let session = Session(id: "s1", startedAt: .init(timeIntervalSince1970: 0))
    try await store.save(session)

    let resolved = try await ResumeInterrupted(sessions: store, minimumDuration: 60)()

    #expect(resolved.map(\.state) == [.discarded])
    #expect(try await store.load(id: "s1")?.state == .discarded)
    #expect(try await store.unfinished().isEmpty)
}

@Test("finished sessions are left alone")
func terminalSessionsAreNotResumed() async throws {
    let store = InMemorySessionStore()
    var session = Session(id: "s1", startedAt: .init(timeIntervalSince1970: 0))
    session = try session.applying(.discard)
    try await store.save(session)

    #expect(try await ResumeInterrupted(sessions: store, minimumDuration: 60)().isEmpty)
}

@Test("an unfinished session that is not recording is left for the pipeline to pick up")
func nonRecordingUnfinishedSessionIsUntouched() async throws {
    let store = InMemorySessionStore()
    var session = Session(id: "s1", startedAt: .init(timeIntervalSince1970: 0))
    session = try session.applying(.confirm)
    session = try session.applying(.stopRecording)
    try await store.save(session)

    #expect(try await ResumeInterrupted(sessions: store, minimumDuration: 60)().isEmpty)
}
