import Foundation

/// Session state on disk, one `session.json` under a directory named for the
/// session.
///
/// A save writes a temporary file next to the destination and moves it into
/// place with `rename`, which APFS performs atomically: a reader sees the whole
/// previous state or the whole new one, never half of either, so a crash or a
/// full disk cannot leave state that no longer parses.
///
/// State that cannot be read is an error rather than a session that was never
/// saved, since recovery treats a missing session as nothing to do. Temporary
/// files a crash left behind are ignored: only `session.json` is state.
public actor FileSessionStore: SessionStoring {
    public struct UnreadableSession: Error {
        public let id: String
        public let underlying: any Error
    }

    public struct WriteFailed: Error, Equatable {
        public let path: String
        public let code: Int32
    }

    static let stateFileName = "session.json"

    private let root: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(root: URL) {
        self.root = root
    }

    public func save(_ session: Session) async throws {
        let directory = root.appending(path: session.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let destination = directory.appending(path: Self.stateFileName)
        let temporary = Self.temporaryURL(for: destination)
        try encoder.encode(session).write(to: temporary)

        // Left where it is when the rename fails: removing it would need a
        // second failure path, and an ignored leftover costs only a file.
        guard rename(temporary.path, destination.path) == 0 else {
            throw WriteFailed(path: destination.path, code: errno)
        }
    }

    public func load(id: String) async throws -> Session? {
        let file = root.appending(path: id).appending(path: Self.stateFileName)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }

        let data = try Data(contentsOf: file)
        do {
            return try decoder.decode(Session.self, from: data)
        } catch {
            throw UnreadableSession(id: id, underlying: error)
        }
    }

    public func unfinished() async throws -> [Session] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }

        var unfinished: [Session] = []
        for entry in try FileManager.default.contentsOfDirectory(atPath: root.path) {
            guard let session = try await load(id: entry), !session.state.isTerminal else {
                continue
            }
            unfinished.append(session)
        }
        // A directory listing has no order of its own, and the port promises one.
        return unfinished.sorted { $0.id < $1.id }
    }

    /// Next to the destination, so the rename stays inside one filesystem.
    static func temporaryURL(for destination: URL) -> URL {
        destination
            .deletingLastPathComponent()
            .appending(path: ".\(destination.lastPathComponent).\(UUID().uuidString)")
    }
}
