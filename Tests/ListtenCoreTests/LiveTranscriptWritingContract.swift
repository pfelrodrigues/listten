import Foundation
import Testing

@testable import ListtenCore

private func line(_ track: Track, _ start: TimeInterval, _ text: String) -> LiveLine {
    // Written here, so a line this fixture could not hold fails the suite rather
    // than being caught somewhere a caller cannot see.
    try! LiveLine(track: track, start: start, end: start + 2, text: text)
}

/// The rules every `LiveTranscriptWriting` obeys, written once so the in-memory
/// fake cannot be tidier than the file on disk. `readBack` is the caller's,
/// since the port has no reader: nothing in this product reads that file.
func verifyLiveTranscriptWritingContract<Writer: LiveTranscriptWriting>(
    _ make: @Sendable () -> Writer,
    readBack: @Sendable (Writer, String) async throws -> [LiveLine],
    sourceLocation: SourceLocation = #_sourceLocation
) async throws {
    let empty = make()
    #expect(
        try await readBack(empty, "never-written").isEmpty,
        "a session nothing was written for held lines anyway",
        sourceLocation: sourceLocation
    )

    let writer = make()
    // Out of order on purpose: the file records what settled, not what should
    // have, and a writer that sorted on the way in or out would reorder a
    // meeting to look tidier than it was.
    let alpha = [
        line(.microphone, 10, "shall we start with the migration"),
        line(.system, 4, "the migration slipped a week"),
        line(.microphone, 16, "i will draft the plan today"),
    ]
    // Interleaved with another session's, since one meeting's words appearing in
    // another's transcript is worse than losing them.
    try await writer.append(alpha[0], for: "alpha")
    try await writer.append(line(.system, 0, "another meeting entirely"), for: "bravo")
    try await writer.append(alpha[1], for: "alpha")
    try await writer.append(alpha[2], for: "alpha")

    #expect(
        try await readBack(writer, "alpha") == alpha,
        "lines came back reordered, changed, or belonging to another session",
        sourceLocation: sourceLocation
    )
    #expect(
        try await readBack(writer, "bravo").count == 1,
        "one session's lines reached another's transcript",
        sourceLocation: sourceLocation
    )
    #expect(
        try await readBack(writer, "charlie").isEmpty,
        "a session nobody wrote for is empty, not a failure",
        sourceLocation: sourceLocation
    )
}

@Test("the in-memory live transcript honours the contract")
func inMemoryLiveTranscriptsHonourTheContract() async throws {
    try await verifyLiveTranscriptWritingContract({ InMemoryLiveTranscripts() }) { writer, id in
        await writer.lines(for: id)
    }
}

/// Nothing here saves a session first: the first line of a live transcript can
/// land before anything else about the meeting has reached disk.
@Test("the file-backed live transcript honours the same contract as the fake")
func sessionLiveTranscriptsHonourTheContract() async throws {
    let parent = temporaryRoot()
    try await verifyLiveTranscriptWritingContract({
        SessionLiveTranscripts(root: parent.appending(path: UUID().uuidString))
    }) { writer, id in
        try JSONLLog<LiveLine>(url: writer.url(for: id)).entries()
    }
    try FileManager.default.removeItem(at: parent)
}
