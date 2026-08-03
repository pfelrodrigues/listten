import Foundation

/// Progress as an append-only log: one JSON checkpoint per line, never
/// rewritten, so recovery costs a read rather than a database.
///
/// What a reader may rely on:
///
/// - Each append is one `O_APPEND` write of a whole line, so writers never land
///   inside each other's lines and a crash can only tear the last one.
/// - Checkpoints come back in the order they were appended. The log is the
///   chronology; nothing is sorted or renumbered on read.
/// - A missing or empty file holds no checkpoints. A session that never got far
///   enough to checkpoint is not a failure.
/// - An unterminated last line is dropped. The newline is written with the line
///   it ends, so a line without one is a write that did not finish.
/// - Both sides honour that: the next append removes the unfinished tail before
///   it writes, since a line fused onto one ends up terminated and undecodable,
///   which is corruption, and corruption buries every checkpoint before it.
/// - Any other line that does not decode is corruption and throws. A damaged
///   log must not read as a shorter one that happens to parse.
/// - A write this small to a regular file is all or nothing, so a short one is
///   reported rather than retried: the bytes it left behind are an unfinished
///   tail like any other, and the next append drops them.
public struct JSONLProgressLog: Sendable {
    public enum Failure: Error, Equatable {
        case unwritable(path: String, code: Int32)
        case partialWrite(path: String)
        case corruptLine(number: Int)
    }

    private static let newline = UInt8(ascii: "\n")

    private let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func append(_ checkpoint: Checkpoint) throws {
        var line = try JSONEncoder().encode(checkpoint)
        line.append(Self.newline)

        // Reading needs O_RDWR: what the tail looks like decides where to write.
        let descriptor = open(url.path, O_RDWR | O_APPEND | O_CREAT, 0o600)
        guard descriptor >= 0 else { throw Failure.unwritable(path: url.path, code: errno) }
        defer { close(descriptor) }

        try dropUnfinishedTail(descriptor)

        let written = line.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
        // Retrying half a line would append the remainder behind whatever else
        // arrived, so a short write is reported instead.
        guard written == line.count else { throw Failure.partialWrite(path: url.path) }
    }

    /// Writing behind a torn line would fuse the two into one terminated line
    /// the reader cannot decode, burying every checkpoint before it.
    private func dropUnfinishedTail(_ descriptor: Int32) throws {
        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            throw Failure.unwritable(path: url.path, code: errno)
        }
        guard status.st_size > 0 else { return }

        var last = UInt8(0)
        guard pread(descriptor, &last, 1, status.st_size - 1) == 1 else {
            throw Failure.unwritable(path: url.path, code: errno)
        }
        guard last != Self.newline else { return }

        // Only a crash gets here, so reading the whole log costs nothing usual.
        let stored = try Data(contentsOf: url)
        let terminated =
            stored.lastIndex(of: Self.newline)
            .map { stored.distance(from: stored.startIndex, to: $0) + 1 } ?? 0
        guard ftruncate(descriptor, off_t(terminated)) == 0 else {
            throw Failure.unwritable(path: url.path, code: errno)
        }
    }

    public func checkpoints() throws -> [Checkpoint] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let stored = try Data(contentsOf: url)

        let decoder = JSONDecoder()
        // Everything after the last newline is an unfinished append: empty when
        // the file ends cleanly, a torn line when it does not.
        let lines =
            stored.split(
                separator: Self.newline,
                omittingEmptySubsequences: false
            )
            .dropLast()

        return try lines.enumerated()
            .map { number, line in
                do {
                    return try decoder.decode(Checkpoint.self, from: Data(line))
                } catch {
                    throw Failure.corruptLine(number: number + 1)
                }
            }
    }
}
