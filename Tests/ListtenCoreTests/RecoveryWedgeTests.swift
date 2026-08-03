import Foundation
import Testing

@testable import ListtenCore

@Test("a damaged log on a session with nothing to resolve does not fail the run")
func damagedLogOnABystanderDoesNotFailTheRun() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "resume-\(UUID())")
    let store = FileSessionStore(root: root)
    defer { try? FileManager.default.removeItem(at: root) }

    // Recorded: the pipeline owns it, recovery has nothing to do with it.
    var bystander = Session(id: "bbb", startedAt: .init(timeIntervalSince1970: 0))
    bystander = try bystander.applying(.confirm)
    bystander = try bystander.applying(.stopRecording)
    try await store.save(bystander)
    try Data("{\"torn\n".utf8)
        .write(to: root.appending(path: "bbb").appending(path: "progress.jsonl"))

    let recovery = try await ResumeInterrupted(
        sessions: store,
        progress: SessionProgressLogs(root: root),
        minimumDuration: 60
    )()

    #expect(recovery.resumed.isEmpty)
    // Named, and named as progress rather than as state, which is intact.
    #expect(recovery.unreadableProgress == ["bbb"])
    #expect(recovery.unreadableState.isEmpty)
}

@Test("a run that read everything says so, and one that lost a file does not")
func isCleanNamesTheDifference() async throws {
    let store = InMemorySessionStore()
    let progress = InMemoryProgressLog()
    try await store.save(
        try Session(id: "aaa", startedAt: .init(timeIntervalSince1970: 0))
            .applying(.confirm)
            .appending(Segment(index: 0, track: .microphone, start: 0, duration: 90))
    )

    let resume = ResumeInterrupted(sessions: store, progress: progress, minimumDuration: 60)
    #expect(try await resume().isClean)

    try await store.save(
        try Session(id: "bbb", startedAt: .init(timeIntervalSince1970: 0))
            .applying(.confirm)
            .appending(Segment(index: 0, track: .microphone, start: 0, duration: 90))
    )
    await progress.corrupt(id: "bbb")

    #expect(try await !resume().isClean)
}

/// Losing the redo list is not losing the meeting: which step to redo needs the
/// log, but moving a crashed recording to recorded never did.
@Test("a session whose log is unreadable is still resolved, with nothing to redo")
func unreadableLogStillResolvesTheSession() async throws {
    let store = InMemorySessionStore()
    let progress = InMemoryProgressLog()
    try await store.save(
        try Session(id: "aaa", startedAt: .init(timeIntervalSince1970: 0))
            .applying(.confirm)
            .appending(Segment(index: 0, track: .microphone, start: 0, duration: 90))
    )
    await progress.corrupt(id: "aaa")

    let recovery = try await ResumeInterrupted(
        sessions: store,
        progress: progress,
        minimumDuration: 60
    )()

    #expect(recovery.resumed.map(\.session.state) == [.recorded])
    #expect(recovery.resumed.map(\.redo) == [[]])
    #expect(recovery.unreadableProgress == ["aaa"])
    #expect(try await store.load(id: "aaa")?.state == .recorded)
}
