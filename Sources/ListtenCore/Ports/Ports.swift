import Foundation

/// Where sessions are kept between runs, so an interrupted one can be resumed.
public protocol SessionStoring: Sendable {
    /// Replaces whatever was held for that id: the last state saved wins.
    func save(_ session: Session) async throws

    /// Nil means the session was never saved. State that exists but cannot be
    /// read is an error, since recovery reads nil as nothing left to do.
    func load(id: String) async throws -> Session?

    /// A scan of everything still open. Both lists are ordered by id, which
    /// sorts chronologically. An implementation free to return any order would
    /// make recovery depend on storage internals, and a fake that happened to be
    /// tidier than production would hide it.
    func unfinished() async throws -> UnfinishedSessions
}

/// What a scan found. State that cannot be read is reported beside the sessions
/// that can, rather than as a failure of the scan: one session's storage is not
/// the store, and recovery that gives up on the first corrupt file loses every
/// healthy meeting to save one.
public struct UnfinishedSessions: Sendable, Equatable {
    public let sessions: [Session]
    public let unreadable: [String]

    public init(sessions: [Session], unreadable: [String] = []) {
        self.sessions = sessions
        self.unreadable = unreadable
    }
}

/// Where progress is written as it happens, one log per session: a step records
/// its intent before it acts and its completion once it has, so a resumed run
/// reads the pair rather than guessing from the state which step it stopped in.
///
/// Held to these by `verifyProgressLoggingContract`:
///
/// - Checkpoints come back for the session they were written for, in the order
///   they were appended. The log is the chronology, and one session's steps are
///   never another's.
/// - A session that never logged holds no checkpoints. Not reaching the first
///   step is how every session starts, not a failure.
/// - The first append creates the log, so progress can be recorded for a session
///   whose own state is not saved yet: the intent is written before the work
///   that would save it.
public protocol ProgressLogging: Sendable {
    func append(_ checkpoint: Checkpoint, for sessionID: String) async throws
    func checkpoints(for sessionID: String) async throws -> [Checkpoint]
}

public struct CaptureAlreadyStarted: Error, Equatable {}

/// One audio device, delivering buffers as it produces them. The microphone and
/// the system tap are two of these; turning buffers into rotated segments on
/// disk is what `AudioCapturing` does with them.
public protocol AudioSource: Sendable {
    /// Buffers stamped on the machine clock, so two sources describe one
    /// timeline. Throws if this source was already started.
    func start() async throws -> AsyncStream<CapturedAudio>

    /// Idempotent: stopping a source that never started, or stopping one twice,
    /// is not an error. Held to this by `verifyAudioSourceContract`.
    func stop() async
}

/// Delivers audio as finalized segments, both tracks stamped on one clock so
/// they can be interleaved later.
///
/// No `(track, index)` is repeated across `start()` and `stop()`: the session
/// identifies a segment by that pair and refuses a repeat, so an implementation
/// that reused an index would lose the audio behind it. Held to this by
/// `verifyAudioCapturingContract`.
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

/// What the note says. No frontmatter and no identifiers: the note has to read
/// on its own, and fitting it into a knowledge base is somebody else's job.
public struct MeetingNote: Sendable, Equatable {
    public let title: String
    public let summary: String
    public let actionItems: [String]
    public let transcript: Transcript

    public init(
        title: String,
        summary: String,
        actionItems: [String],
        transcript: Transcript
    ) {
        self.title = title
        self.summary = summary
        self.actionItems = actionItems
        self.transcript = transcript
    }
}

/// Where a note ended up: kept inside the session directory, delivered to the
/// configured folder.
public struct NoteLocation: Sendable, Equatable {
    public let kept: URL
    public let delivered: URL

    public init(kept: URL, delivered: URL) {
        self.kept = kept
        self.delivered = delivered
    }
}

/// The copy failed and the note is still at `kept`. Naming where it stayed is
/// what lets a retry deliver the same note rather than regenerate one.
public struct NoteNotDelivered: Error {
    public let kept: URL
    public let underlying: any Error

    public init(kept: URL, underlying: any Error) {
        self.kept = kept
        self.underlying = underlying
    }
}

/// Writes the finished note where the user will read it.
///
/// The note is written inside the session directory first and copied to the
/// destination afterwards, so a destination that is missing, unmounted or
/// read-only costs the copy and never the note. Held to these by
/// `verifyNoteWritingContract`:
///
/// - What is delivered is what was kept, byte for byte.
/// - A destination that is not there is unavailable, never created. An
///   unmounted volume looks exactly like a missing folder, so creating it would
///   write a phantom note onto the boot disk and report success.
/// - A name already taken at the destination is never overwritten: the note
///   lands beside it. There is no deduplication either way, since two meetings
///   may share a title and neither is a copy of the other.
public protocol NoteWriting: Sendable {
    func write(_ note: MeetingNote, for sessionID: String) async throws -> NoteLocation
}

/// One audio file a capture left behind, described by what the file itself
/// says. It carries no start: where a segment sits on the session timeline was
/// never written into the file, only into the state a crash may have taken.
public struct SegmentFile: Sendable, Equatable {
    public let track: Track
    public let index: Int
    public let duration: TimeInterval
    /// Where it is, so a caller that has to read it — transcription — does not
    /// have to know the layout that wrote it.
    public let url: URL

    public init(track: Track, index: Int, duration: TimeInterval, url: URL) {
        self.track = track
        self.index = index
        self.duration = duration
        self.url = url
    }
}

/// What a session actually has on disk, whatever its state file remembers.
///
/// A segment closes as a file before anything records that it did, so a crash
/// in that window leaves audio nobody accounts for. Recovery reads this to find
/// it rather than trusting the log to have been faster than the crash.
public protocol RecordedAudio: Sendable {
    func segments(for sessionID: String) async throws -> [SegmentFile]
}

/// Where a session's transcripts are kept.
///
/// Both of them: the raw one the engine produced and the corrected one a note is
/// written from. Correction is derived, never destructive, and a store that only
/// held the corrected one would make that sentence false the first time a
/// glossary entry was wrong.
public protocol TranscriptStoring: Sendable {
    func save(_ transcript: CorrectedTranscript, for sessionID: String) async throws
    func load(for sessionID: String) async throws -> CorrectedTranscript?
}
