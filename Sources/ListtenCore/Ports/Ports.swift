import Foundation

/// Where sessions are kept between runs, so an interrupted one can be resumed.
public protocol SessionStoring: Sendable {
    func save(_ session: Session) async throws
    func load(id: String) async throws -> Session?

    /// Ordered by id, which sorts chronologically. An implementation free to
    /// return any order would make recovery depend on storage internals, and a
    /// fake that happened to be tidier than production would hide it.
    func unfinished() async throws -> [Session]
}

/// Delivers audio as finalized segments, both tracks stamped on one clock so
/// they can be interleaved later.
public protocol AudioCapturing: Sendable {
    /// Segments as they close on rotation. The stream finishes when capture ends.
    func start() async throws -> AsyncStream<Segment>

    /// Finalizes whatever is still open, so its audio is not lost. Both tracks
    /// are open when capture ends, so this returns a partial segment for each.
    /// Finalizing belongs to the contract rather than to an adapter's memory.
    func stop() async throws -> [Segment]
}

/// Asks the user whether to record. Nothing reaches disk before the answer.
public protocol RecordingPrompting: Sendable {
    func askWhetherToRecord(sessionID: String) async
}

/// Injected so tests do not depend on wall time. Not named `Clock`: that would
/// shadow the standard library's protocol for anyone importing this module.
public protocol TimeSource: Sendable {
    var now: Date { get }
}
