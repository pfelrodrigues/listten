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
/// saved, since recovery treats a missing session as nothing to do. A scan
/// names it instead of throwing, so the sessions around it stay reachable.
/// Temporary files a crash left behind are ignored: only `session.json` is
/// state.
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
        var isDirectory: ObjCBool = false
        let directory = root.appending(path: id)
        // An entry that is not a session directory holds no state to lose.
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else { return nil }

        do {
            let data = try Data(contentsOf: directory.appending(path: Self.stateFileName))
            return try decoder.decode(Session.self, from: data)
        } catch let failure as CocoaError where failure.code == .fileReadNoSuchFile {
            // Only a proven absence reads as a session that was never saved.
            return nil
        } catch {
            throw UnreadableSession(id: id, underlying: error)
        }
    }

    public func unfinished() async throws -> UnfinishedSessions {
        guard FileManager.default.fileExists(atPath: root.path) else {
            return UnfinishedSessions(sessions: [])
        }

        var unfinished: [Session] = []
        var unreadable: [String] = []
        for entry in try FileManager.default.contentsOfDirectory(atPath: root.path) {
            do {
                guard let session = try await load(id: entry), !session.state.isTerminal else {
                    continue
                }
                unfinished.append(session)
            } catch let failure as UnreadableSession {
                // One file that cannot be parsed is one lost session, not a
                // store that cannot be listed.
                unreadable.append(failure.id)
            }
        }
        // A directory listing has no order of its own, and the port promises one.
        return UnfinishedSessions(
            sessions: unfinished.sorted { $0.id < $1.id },
            unreadable: unreadable.sorted()
        )
    }

    /// Next to the destination, so the rename stays inside one filesystem.
    static func temporaryURL(for destination: URL) -> URL {
        destination
            .deletingLastPathComponent()
            .appending(path: ".\(destination.lastPathComponent).\(UUID().uuidString)")
    }
}
