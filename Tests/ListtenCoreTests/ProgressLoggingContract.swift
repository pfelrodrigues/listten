import Foundation
import Testing

@testable import ListtenCore

/// The rules every `ProgressLogging` obeys, written once so the in-memory fake
/// cannot be tidier than the logs on disk. Recovery reads whatever this returns
/// as the truth about what ran, so an implementation that reorders entries or
/// lets one session's steps reach another changes which step gets redone.
func verifyProgressLoggingContract(
    _ make: @Sendable () -> any ProgressLogging,
    sourceLocation: SourceLocation = #_sourceLocation
) async throws {
    let chunk = PipelineStep.transcribingChunk(index: 0)
    let next = PipelineStep.transcribingChunk(index: 1)
    let segment = PipelineStep.closingSegment(track: .system, index: 4)

    let empty = make()
    #expect(
        try await empty.checkpoints(for: "never-logged").isEmpty,
        "a session that never logged holds no checkpoints",
        sourceLocation: sourceLocation
    )

    let log = make()
    // Written for one session while another is logging, since a step of one
    // meeting appearing in another's recovery would redo work on the wrong audio.
    try await log.append(.intent(chunk), for: "alpha")
    try await log.append(.intent(segment), for: "bravo")
    try await log.append(.completion(chunk), for: "alpha")
    try await log.append(.intent(next), for: "alpha")

    #expect(
        try await log.checkpoints(for: "alpha") == [
            .intent(chunk), .completion(chunk), .intent(next),
        ],
        "checkpoints come back in the order they were appended",
        sourceLocation: sourceLocation
    )
    #expect(
        try await log.checkpoints(for: "bravo") == [.intent(segment)],
        "a session holds its own checkpoints and no others",
        sourceLocation: sourceLocation
    )
    #expect(
        try await log.checkpoints(for: "charlie").isEmpty,
        "a session nobody logged for is empty, not a failure",
        sourceLocation: sourceLocation
    )
}

@Test("the in-memory progress log honours the contract")
func inMemoryProgressLogHonoursTheContract() async throws {
    try await verifyProgressLoggingContract { InMemoryProgressLog() }
}

/// The first append creates the log, so nothing here saves a session first: an
/// intent is written before the work that would put the session on disk.
@Test("the file-backed progress log honours the same contract as the fake")
func sessionProgressLogsHonourTheContract() async throws {
    let parent = temporaryRoot()
    try await verifyProgressLoggingContract {
        SessionProgressLogs(root: parent.appending(path: UUID().uuidString))
    }
    try FileManager.default.removeItem(at: parent)
}

/// Beside the state file rather than under a directory of its own: a session is
/// one directory, and recovery reads both without a second layout to know about.
@Test("a session's progress lands in the same directory as its state")
func progressLandsBesideTheStateFile() throws {
    let root = temporaryRoot()
    let logs = SessionProgressLogs(root: root)
    try logs.append(.intent(.transcribingChunk(index: 0)), for: "2026-01-01-aaa")

    let expected =
        root
        .appending(path: "2026-01-01-aaa")
        .appending(path: SessionProgressLogs.logFileName)
    #expect(FileManager.default.fileExists(atPath: expected.path))
    try FileManager.default.removeItem(at: root)
}
