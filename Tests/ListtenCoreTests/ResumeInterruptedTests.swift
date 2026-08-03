import Foundation
import Testing

@testable import ListtenCore

private let chunk = PipelineStep.transcribingChunk(index: 3)
private let segment = PipelineStep.closingSegment(track: .microphone, index: 0)

private func recording(_ id: String, duration: TimeInterval) throws -> Session {
    try Session(id: id, startedAt: .init(timeIntervalSince1970: 0))
        .applying(.confirm)
        .appending(Segment(index: 0, track: .microphone, start: 0, duration: duration))
}

@Test("a session left recording by a crash is treated as recorded, since partial audio is valid")
func interruptedRecordingBecomesRecorded() async throws {
    let store = InMemorySessionStore()
    try await store.save(try recording("s1", duration: 90))

    let resumed = try await ResumeInterrupted(
        sessions: store,
        progress: InMemoryProgressLog(),
        minimumDuration: 60
    )()

    #expect(resumed.map(\.session.state) == [.recorded])
}

@Test("a crash does not rescue a recording that stopping would have discarded")
func recoveryAppliesTheSameMinimumAsStopping() async throws {
    let store = InMemorySessionStore()
    try await store.save(try recording("s1", duration: 10))

    let resumed = try await ResumeInterrupted(
        sessions: store,
        progress: InMemoryProgressLog(),
        minimumDuration: 60
    )()

    #expect(resumed.map(\.session.state) == [.discarded])
}

@Test("an armed session found at startup is discarded, since its prompt died with the process")
func armedSessionIsDiscarded() async throws {
    let store = InMemorySessionStore()
    let session = Session(id: "s1", startedAt: .init(timeIntervalSince1970: 0))
    try await store.save(session)

    let resolved = try await ResumeInterrupted(
        sessions: store,
        progress: InMemoryProgressLog(),
        minimumDuration: 60
    )()

    #expect(resolved.map(\.session.state) == [.discarded])
    #expect(try await store.load(id: "s1")?.state == .discarded)
    #expect(try await store.unfinished().sessions.isEmpty)
}

@Test("finished sessions are left alone")
func terminalSessionsAreNotResumed() async throws {
    let store = InMemorySessionStore()
    var session = Session(id: "s1", startedAt: .init(timeIntervalSince1970: 0))
    session = try session.applying(.discard)
    try await store.save(session)

    #expect(
        try await ResumeInterrupted(
            sessions: store,
            progress: InMemoryProgressLog(),
            minimumDuration: 60
        )()
        .isEmpty
    )
}

/// Against the real store on purpose: unreadable state is only representable
/// where state is a file, and recovery losing every healthy meeting to one
/// corrupt neighbour is the failure this asserts against.
@Test("a session whose state cannot be read does not hold back the ones that can")
func unreadableSessionDoesNotBlockRecovery() async throws {
    let root = temporaryRoot()
    let store = FileSessionStore(root: root)
    for id in ["2026-01-01-aaa", "2026-01-02-bbb", "2026-01-03-ccc"] {
        try await store.save(try recording(id, duration: 600))
    }
    let corrupted =
        root
        .appending(path: "2026-01-01-aaa")
        .appending(path: FileSessionStore.stateFileName)
    try Data(#"{"id":"2026-01-01-aaa","started"#.utf8).write(to: corrupted)

    // Still a failure, and it says which session it was: the loss is reported
    // rather than masked, only after the readable ones are safe.
    await #expect(throws: ResumeInterrupted.UnreadableSessions(ids: ["2026-01-01-aaa"])) {
        _ = try await ResumeInterrupted(
            sessions: store,
            progress: SessionProgressLogs(root: root),
            minimumDuration: 30
        )()
    }

    #expect(try await store.load(id: "2026-01-02-bbb")?.state == .recorded)
    #expect(try await store.load(id: "2026-01-03-ccc")?.state == .recorded)
    try FileManager.default.removeItem(at: root)
}

@Test("an unfinished session that got nowhere is left for the pipeline to pick up")
func nonRecordingUnfinishedSessionIsUntouched() async throws {
    let store = InMemorySessionStore()
    try await store.save(try recording("s1", duration: 90).applying(.stopRecording))

    #expect(
        try await ResumeInterrupted(
            sessions: store,
            progress: InMemoryProgressLog(),
            minimumDuration: 60
        )()
        .isEmpty
    )
}

/// The distinction the state alone cannot make: transcribing says a chunk was
/// being worked on, never which one, and redoing all of them or none of them are
/// both wrong.
@Test("a step interrupted by the crash is named, so the pipeline redoes that one")
func interruptedStepIsNamed() async throws {
    let store = InMemorySessionStore()
    let progress = InMemoryProgressLog()
    let transcribing = try recording("s1", duration: 90)
        .applying(.stopRecording)
        .applying(.startTranscribing)
    try await store.save(transcribing)
    try await progress.append(.intent(.transcribingChunk(index: 2)), for: "s1")
    try await progress.append(.completion(.transcribingChunk(index: 2)), for: "s1")
    try await progress.append(.intent(chunk), for: "s1")

    let resumed = try await ResumeInterrupted(
        sessions: store,
        progress: progress,
        minimumDuration: 60
    )()

    #expect(resumed == [.init(session: transcribing, redo: [chunk])])
}

/// A step that reached its completion is done, whatever the state around it
/// looks like: a recovery that redid it would transcribe the same audio twice.
@Test("a step that finished before the crash is not redone")
func finishedStepIsNotRedone() async throws {
    let store = InMemorySessionStore()
    let progress = InMemoryProgressLog()
    try await store.save(
        try recording("s1", duration: 90).applying(.stopRecording).applying(.startTranscribing)
    )
    try await progress.append(.intent(chunk), for: "s1")
    try await progress.append(.completion(chunk), for: "s1")

    let resumed = try await ResumeInterrupted(
        sessions: store,
        progress: progress,
        minimumDuration: 60
    )()

    #expect(resumed.isEmpty)
}

@Test("a recording that was interrupted mid-segment is recorded and says which segment to redo")
func interruptedRecordingNamesItsSegment() async throws {
    let store = InMemorySessionStore()
    let progress = InMemoryProgressLog()
    try await store.save(try recording("s1", duration: 90))
    try await progress.append(.intent(segment), for: "s1")

    let resumed = try await ResumeInterrupted(
        sessions: store,
        progress: progress,
        minimumDuration: 60
    )()

    #expect(resumed.map(\.session.state) == [.recorded])
    #expect(resumed.map(\.redo) == [[segment]])
}

/// Nothing survives a discarded session, so a step it died inside is not work
/// waiting to be redone: it is work nobody will ever want.
@Test("a session recovery discarded has nothing left to redo")
func discardedSessionRedoesNothing() async throws {
    let store = InMemorySessionStore()
    let progress = InMemoryProgressLog()
    try await store.save(try recording("s1", duration: 10))
    try await progress.append(.intent(segment), for: "s1")

    let resumed = try await ResumeInterrupted(
        sessions: store,
        progress: progress,
        minimumDuration: 60
    )()

    #expect(resumed.map(\.session.state) == [.discarded])
    #expect(resumed.map(\.redo) == [[]])
}

/// A completion is only ever written by the step that declared the intent, so a
/// log holding one alone describes work that cannot have happened. It is louder
/// than unreadable state, and reported first: one costs a meeting, the other
/// would resume a meeting from a lie.
@Test("a completion nobody intended is reported by session and step, ahead of unreadable state")
func brokenProgressIsLoudAndTakesPrecedence() async throws {
    let store = InMemorySessionStore()
    let progress = InMemoryProgressLog()
    try await store.save(try recording("broken", duration: 90))
    try await store.save(try recording("healthy", duration: 90))
    try await store.save(try recording("unreadable", duration: 90))
    await store.corrupt(id: "unreadable")
    try await progress.append(.completion(chunk), for: "broken")

    await #expect(
        throws: ResumeInterrupted.BrokenProgress(
            broken: ["broken": .init(completionWithoutIntent: chunk)]
        )
    ) {
        _ = try await ResumeInterrupted(
            sessions: store,
            progress: progress,
            minimumDuration: 60
        )()
    }

    #expect(try await store.load(id: "healthy")?.state == .recorded)
    #expect(try await store.load(id: "broken")?.state == .recording)
}

@Test("progress that cannot be read costs that meeting and no other")
func unreadableProgressIsReportedLikeUnreadableState() async throws {
    let store = InMemorySessionStore()
    let progress = InMemoryProgressLog()
    try await store.save(try recording("lost", duration: 90))
    try await store.save(try recording("healthy", duration: 90))
    await progress.corrupt(id: "lost")

    await #expect(throws: ResumeInterrupted.UnreadableSessions(ids: ["lost"])) {
        _ = try await ResumeInterrupted(
            sessions: store,
            progress: progress,
            minimumDuration: 60
        )()
    }

    #expect(try await store.load(id: "healthy")?.state == .recorded)
    #expect(try await store.load(id: "lost")?.state == .recording)
}

/// The crash the two-phase pair is for, staged on the real log: the completion
/// was half written when the process died, so the line is dropped and the step
/// reads as interrupted rather than done.
@Test("a log torn between the intent and the completion leaves the step to be redone")
func stepTornBetweenItsEndsIsRedone() async throws {
    let root = temporaryRoot()
    let store = FileSessionStore(root: root)
    let progress = SessionProgressLogs(root: root)
    let transcribing = try recording("2026-01-01-aaa", duration: 90)
        .applying(.stopRecording)
        .applying(.startTranscribing)
    try await store.save(transcribing)
    try progress.append(.intent(chunk), for: transcribing.id)

    let line = try JSONEncoder().encode(Checkpoint.completion(chunk)).dropLast(6)
    let log =
        root
        .appending(path: transcribing.id)
        .appending(path: SessionProgressLogs.logFileName)
    let handle = try FileHandle(forWritingTo: log)
    try handle.seekToEnd()
    try handle.write(contentsOf: line)
    try handle.close()

    let resumed = try await ResumeInterrupted(
        sessions: store,
        progress: progress,
        minimumDuration: 60
    )()

    #expect(resumed == [.init(session: transcribing, redo: [chunk])])
    try FileManager.default.removeItem(at: root)
}
