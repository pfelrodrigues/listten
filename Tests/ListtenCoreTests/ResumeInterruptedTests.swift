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

@Test("finished sessions are left alone")
func terminalSessionsAreNotResumed() async throws {
    let store = InMemorySessionStore()
    var session = Session(id: "s1", startedAt: .init(timeIntervalSince1970: 0))
    session = try session.applying(.discard)
    try await store.save(session)

    #expect(try await ResumeInterrupted(sessions: store, minimumDuration: 60)().isEmpty)
}

/// Against the real store on purpose: unreadable state is only representable
/// where state is a file, and recovery losing every healthy meeting to one
/// corrupt neighbour is the failure this asserts against.
@Test("a session whose state cannot be read does not hold back the ones that can")
func unreadableSessionDoesNotBlockRecovery() async throws {
    let root = temporaryRoot()
    let store = FileSessionStore(root: root)
    for id in ["2026-01-01-aaa", "2026-01-02-bbb", "2026-01-03-ccc"] {
        var session = Session(id: id, startedAt: .init(timeIntervalSince1970: 0))
        session = try session.applying(.confirm)
        try await store.save(
            try session.appending(Segment(index: 0, track: .microphone, start: 0, duration: 600))
        )
    }
    let corrupted =
        root
        .appending(path: "2026-01-01-aaa")
        .appending(path: FileSessionStore.stateFileName)
    try Data(#"{"id":"2026-01-01-aaa","started"#.utf8).write(to: corrupted)

    // Still a failure, and it says which session it was: the loss is reported
    // rather than masked, only after the readable ones are safe.
    await #expect(throws: ResumeInterrupted.UnreadableSessions(ids: ["2026-01-01-aaa"])) {
        _ = try await ResumeInterrupted(sessions: store, minimumDuration: 30)()
    }

    #expect(try await store.load(id: "2026-01-02-bbb")?.state == .recorded)
    #expect(try await store.load(id: "2026-01-03-ccc")?.state == .recorded)
    try FileManager.default.removeItem(at: root)
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
