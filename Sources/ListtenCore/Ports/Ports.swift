import Foundation

/// Where sessions are kept between runs, so an interrupted one can be resumed.
public protocol SessionStoring: Sendable {
    func save(_ session: Session) async throws
    func load(id: String) async throws -> Session?
    func unfinished() async throws -> [Session]
}

/// Asks the user whether to record. Nothing reaches disk before the answer.
public protocol RecordingPrompting: Sendable {
    func askWhetherToRecord(sessionID: String) async
}

/// Injected so tests do not depend on wall time.
public protocol Clock: Sendable {
    var now: Date { get }
}
