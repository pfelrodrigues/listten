import Foundation

/// One `progress.jsonl` per session, in the same directory the state file
/// lives in, so a session is one directory to copy, move or delete.
public struct SessionProgressLogs: ProgressLogging {
    static let logFileName = "progress.jsonl"

    private let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// The directory is created here rather than assumed: the intent is written
    /// before the work that saves the session, so the first append may well be
    /// the first thing this session ever wrote.
    public func append(_ checkpoint: Checkpoint, for sessionID: String) throws {
        try FileManager.default.createDirectory(
            at: root.appending(path: sessionID),
            withIntermediateDirectories: true
        )
        try log(for: sessionID).append(checkpoint)
    }

    public func checkpoints(for sessionID: String) throws -> [Checkpoint] {
        try log(for: sessionID).entries()
    }

    private func log(for sessionID: String) -> JSONLProgressLog {
        JSONLProgressLog(
            url: root.appending(path: sessionID).appending(path: Self.logFileName)
        )
    }
}
