import Foundation
import Testing

@testable import ListtenCore

private func withTemporaryLog<T>(_ body: (JSONLProgressLog, URL) throws -> T) throws -> T {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "listten-progress-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    let url = directory.appending(path: "progress.jsonl")
    let result = try body(JSONLProgressLog(url: url), url)
    try FileManager.default.removeItem(at: directory)
    return result
}

/// Writes bytes the log would never write itself, which is how a crash and a
/// damaged file are staged without killing the test process.
private func appendRaw(_ text: String, to url: URL) throws {
    if !FileManager.default.fileExists(atPath: url.path) {
        #expect(FileManager.default.createFile(atPath: url.path, contents: nil))
    }
    let handle = try FileHandle(forWritingTo: url)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(text.utf8))
    try handle.close()
}

private func encoded(_ checkpoint: Checkpoint) throws -> String {
    String(decoding: try JSONEncoder().encode(checkpoint), as: UTF8.self)
}

private let closed = Checkpoint.segmentClosed(
    segment: Segment(index: 0, track: .microphone, start: 0, duration: 30)
)
private let transcribed = Checkpoint.chunkTranscribed(index: 0)

@Test("checkpoints come back in the order they were appended")
func checkpointsComeBackInOrder() throws {
    try withTemporaryLog { log, _ in
        try log.append(closed)
        try log.append(transcribed)

        let read = try log.checkpoints()
        #expect(read == [closed, transcribed])
    }
}

@Test("a log nobody wrote to holds no checkpoints")
func missingFileHoldsNoCheckpoints() throws {
    try withTemporaryLog { log, _ in
        let read = try log.checkpoints()
        #expect(read.isEmpty)
    }
}

@Test("an empty file holds no checkpoints")
func emptyFileHoldsNoCheckpoints() throws {
    try withTemporaryLog { log, url in
        try appendRaw("", to: url)

        let read = try log.checkpoints()
        #expect(read.isEmpty)
    }
}

@Test("a line torn by a crash mid-append is dropped, and the lines before it survive")
func tornLastLineIsDropped() throws {
    try withTemporaryLog { log, url in
        try log.append(closed)
        try log.append(transcribed)
        let torn = try encoded(.chunkTranscribed(index: 1)).dropLast(6)
        try appendRaw(String(torn), to: url)

        let read = try log.checkpoints()
        #expect(read == [closed, transcribed])
    }
}

@Test("a terminated line that does not decode is corruption, reported with its number")
func corruptLineIsReported() throws {
    try withTemporaryLog { log, url in
        try log.append(closed)
        try appendRaw("{\"chunkTranscribed\":\n", to: url)
        try log.append(transcribed)

        #expect(throws: JSONLProgressLog.Failure.corruptLine(number: 2)) {
            try log.checkpoints()
        }
    }
}

/// Checkpoints from two tracks and two stages do not finish in index order, and
/// the log records what happened rather than what should have. Sorting on read
/// would silently reorder a recovery.
@Test("entries that arrived out of order are all returned, as they were written")
func outOfOrderEntriesAreKeptAsWritten() throws {
    try withTemporaryLog { log, _ in
        let arrived = [
            Checkpoint.chunkTranscribed(index: 3),
            Checkpoint.chunkTranscribed(index: 1),
            Checkpoint.chunkTranscribed(index: 2),
        ]
        for checkpoint in arrived {
            try log.append(checkpoint)
        }

        let read = try log.checkpoints()
        #expect(read == arrived)
    }
}

/// A checkpoint that could not be written is worse than one nobody asked for:
/// recovery would believe work was done.
@Test("a log that cannot be opened reports it instead of losing the checkpoint")
func unwritableLogIsReported() throws {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "listten-absent-\(UUID().uuidString)")
        .appending(path: "progress.jsonl")

    #expect(throws: JSONLProgressLog.Failure.unwritable(path: url.path, code: ENOENT)) {
        try JSONLProgressLog(url: url).append(transcribed)
    }
}

/// Appends are atomic and go to the end of the file, so a second writer neither
/// overwrites the first nor lands inside one of its lines.
@Test("two logs on the same path both keep their appends")
func twoLogsOnTheSamePathBothAppend() throws {
    try withTemporaryLog { first, url in
        let second = JSONLProgressLog(url: url)
        try first.append(closed)
        try second.append(transcribed)
        try first.append(.chunkTranscribed(index: 1))

        let read = try second.checkpoints()
        #expect(read == [closed, transcribed, .chunkTranscribed(index: 1)])
    }
}
