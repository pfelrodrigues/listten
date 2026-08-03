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

private let closed = Checkpoint.completion(.closingSegment(track: .microphone, index: 0))
private let transcribed = Checkpoint.completion(.transcribingChunk(index: 0))

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
        let torn = try encoded(.completion(.transcribingChunk(index: 1))).dropLast(6)
        try appendRaw(String(torn), to: url)

        let read = try log.checkpoints()
        #expect(read == [closed, transcribed])
    }
}

/// Without this the first append after a crash fuses with the torn line, and
/// the fused line is terminated, so the tail rule no longer drops it: every
/// checkpoint written before the crash is buried behind a line that throws.
@Test("an append after a torn line leaves the checkpoints before it readable")
func appendAfterATornLineKeepsEarlierCheckpoints() throws {
    try withTemporaryLog { log, url in
        try log.append(closed)
        try log.append(transcribed)
        let torn = try encoded(.completion(.transcribingChunk(index: 1))).dropLast(6)
        try appendRaw(String(torn), to: url)

        try log.append(.completion(.transcribingChunk(index: 2)))

        let read = try log.checkpoints()
        #expect(read == [closed, transcribed, .completion(.transcribingChunk(index: 2))])
    }
}

@Test("a log torn during its very first append still takes the next one")
func appendAfterATornFirstLineStartsTheLogOver() throws {
    try withTemporaryLog { log, url in
        try appendRaw(String(try encoded(closed).dropLast(6)), to: url)

        try log.append(transcribed)

        let read = try log.checkpoints()
        #expect(read == [transcribed])
    }
}

@Test("a terminated line that does not decode is corruption, reported with its number")
func corruptLineIsReported() throws {
    try withTemporaryLog { log, url in
        try log.append(closed)
        try appendRaw("{\"completion\":\n", to: url)
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
            Checkpoint.completion(.transcribingChunk(index: 3)),
            Checkpoint.completion(.transcribingChunk(index: 1)),
            Checkpoint.completion(.transcribingChunk(index: 2)),
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

/// Sequential writers cannot tell O_APPEND from seeking to the end first, so
/// the writers here race: without the atomic append they compute the same end
/// and overwrite each other, and the count is what catches it.
@Test("writers racing on one path each land a whole line")
func racingWritersEachLandAWholeLine() throws {
    try withTemporaryLog { log, url in
        let writers = 8
        let each = 64

        DispatchQueue.concurrentPerform(iterations: writers) { writer in
            let racing = JSONLProgressLog(url: url)
            for entry in 0..<each {
                #expect(throws: Never.self) {
                    try racing.append(
                        .completion(.transcribingChunk(index: writer * each + entry))
                    )
                }
            }
        }

        let read = try log.checkpoints()
        #expect(read.count == writers * each)
        #expect(indices(of: read).sorted() == Array(0..<writers * each))
    }
}

/// Dropping a torn tail means reading it, so a log that cannot be read cannot be
/// repaired. Appending to one blind fuses the next line onto the tear and buries
/// every checkpoint before it, which is the corruption this file exists to stop.
@Test("a log that cannot be read refuses the append rather than writing blind")
func unreadableLogRefusesTheAppend() throws {
    try withTemporaryLog { log, url in
        try log.append(closed)
        try FileManager.default.setAttributes([.posixPermissions: 0o200], ofItemAtPath: url.path)
        // Root would sail past the barrier and make the rest of this vacuous.
        #expect(!FileManager.default.isReadableFile(atPath: url.path))

        #expect(throws: JSONLProgressLog.Failure.unwritable(path: url.path, code: EACCES)) {
            try log.append(transcribed)
        }

        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        #expect(try log.checkpoints() == [closed])
    }
}

/// The refusal above is not pedantry: this is what writing blind would have
/// done. The torn line and the one fused onto it are both lost, and so is every
/// checkpoint that came before them.
@Test("a torn tail on an unreadable log is never fused over")
func tornTailOnAnUnreadableLogIsNeverFusedOver() throws {
    try withTemporaryLog { log, url in
        try log.append(closed)
        try appendRaw(String(try encoded(transcribed).dropLast(4)), to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o200], ofItemAtPath: url.path)
        #expect(!FileManager.default.isReadableFile(atPath: url.path))

        #expect(throws: JSONLProgressLog.Failure.self) { try log.append(transcribed) }

        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        #expect(try log.checkpoints() == [closed])
    }
}

/// The offset came from the path while the truncation went to the descriptor,
/// so a path replaced mid-repair sized the open file against a foreign one.
@Test("a repair truncates at the last newline of the file it opened, not of the path")
func repairTruncatesTheFileItOpened() throws {
    try withTemporaryLog { log, url in
        let line = try encoded(closed)
        let descriptor = try openTorn(url, keeping: line)
        defer { close(descriptor) }

        // Longer, so its last newline sits past the end of the opened file.
        let replacement = url.deletingLastPathComponent().appending(path: "replacement.jsonl")
        try Data(String(repeating: "x", count: line.count * 2).utf8 + [newline])
            .write(to: replacement)
        #expect(rename(replacement.path, url.path) == 0)

        try log.dropUnfinishedTail(descriptor)

        #expect(try contents(of: descriptor) == Data("\(line)\n".utf8))
    }
}

/// Reading the log back by path let a Cocoa error out of a call whose only
/// declared failure is the log's own, which a caller catching it never sees.
@Test("a repair whose path vanished stays on its descriptor instead of throwing")
func repairOnAVanishedPathStaysOnItsDescriptor() throws {
    try withTemporaryLog { log, url in
        let line = try encoded(closed)
        let descriptor = try openTorn(url, keeping: line)
        defer { close(descriptor) }
        try FileManager.default.removeItem(at: url)

        #expect(throws: Never.self) { try log.dropUnfinishedTail(descriptor) }
        #expect(try contents(of: descriptor) == Data("\(line)\n".utf8))
    }
}

private let newline = UInt8(ascii: "\n")

/// Stages a torn log and hands back a descriptor on it, so the test can change
/// what the path names while the repair holds the original file.
private func openTorn(_ url: URL, keeping line: String) throws -> Int32 {
    try appendRaw("\(line)\nTORN", to: url)
    let descriptor = open(url.path, O_RDWR | O_APPEND)
    #expect(descriptor >= 0)
    return descriptor
}

private func contents(of descriptor: Int32) throws -> Data {
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
    try handle.seek(toOffset: 0)
    return try handle.readToEnd() ?? Data()
}

private func indices(of checkpoints: [Checkpoint]) -> [Int] {
    checkpoints.compactMap {
        guard case .completion(.transcribingChunk(let index)) = $0 else { return nil }
        return index
    }
}
