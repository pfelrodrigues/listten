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

public struct CaptureAlreadyStarted: Error, Equatable {}

/// One audio device, delivering buffers as it produces them. The microphone and
/// the system tap are two of these; turning buffers into rotated segments on
/// disk is what `AudioCapturing` does with them.
public protocol AudioSource: Sendable {
    /// Buffers stamped on the machine clock, so two sources describe one
    /// timeline. Throws if this source was already started.
    func start() async throws -> AsyncStream<CapturedAudio>

    /// Idempotent, like `AudioCapturing.stop()`: stopping a source that never
    /// started, or stopping one twice, is not an error.
    func stop() async
}

/// Delivers audio as finalized segments, both tracks stamped on one clock so
/// they can be interleaved later.
public protocol AudioCapturing: Sendable {
    /// Segments as they close on rotation. The stream finishes when capture
    /// ends. Throws if this capture was already started: the same audio cannot
    /// be captured twice, and answering with an empty stream would turn a
    /// caller's mistake into a recording that went missing quietly.
    func start() async throws -> AsyncStream<Segment>

    /// Finalizes whatever is still open, so its audio is not lost. Both tracks
    /// are open when capture ends, so this returns a partial segment for each.
    /// Finalizing belongs to the contract rather than to an adapter's memory.
    ///
    /// Idempotent: stopping a capture that never started, or stopping one
    /// twice, reports nothing rather than audio that was never heard.
    func stop() async throws -> [Segment]
}

/// Asks the user whether to record. Nothing reaches disk before the answer.
///
/// Throwing means the prompt was not delivered, so no answer is ever coming.
/// Returning means it was delivered and says nothing about whether the user
/// answered: an implementation that reported the decline as an error would make
/// a refused meeting indistinguishable from a notification centre that is off.
public protocol RecordingPrompting: Sendable {
    func askWhetherToRecord(sessionID: String) async throws
}

/// Injected so tests do not depend on wall time. Not named `Clock`: that would
/// shadow the standard library's protocol for anyone importing this module.
public protocol TimeSource: Sendable {
    var now: Date { get }
}
