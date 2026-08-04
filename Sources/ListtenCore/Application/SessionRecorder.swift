import Foundation

/// A recording somebody else decides the length of.
///
/// Recording for a number of seconds is what a command line does because it has
/// no other way to say when to stop. A person clicking a menu does, so this
/// holds the pipeline open until asked to end it, and reports enough along the
/// way that a caller can show whether audio is still arriving.
///
/// It takes a factory rather than a capture because where the audio goes depends
/// on the session id, and there is no session until one is armed.
public actor SessionRecorder {
    /// What a caller can show. Recording carries what it has so far: a light
    /// that only says "on" cannot tell working from wedged.
    public enum State: Sendable, Equatable {
        case idle
        case recording(segments: Int, seconds: TimeInterval)
        case finishing
        /// A recording that reached disk and is being walked to a note.
        case processing(id: String)
        /// The note, where the reader will find it.
        case processed(id: String, note: URL)
        /// Stopped without a note to make: a recording too short to be a meeting.
        case finished(id: String, outcome: SessionState, seconds: TimeInterval)
        case failed(String)
        /// Kept apart from `failed` because it carries the session, which is
        /// what makes running it again a menu item rather than a mechanism.
        case processingFailed(id: String, reason: String)
    }

    public typealias CaptureFactory = @Sendable (String) async throws -> any AudioCapturing

    /// Everything after the audio, keyed by session. A closure for the same
    /// reason as `CaptureFactory`: the recorder drives the pipeline without
    /// knowing what transcribes or where a note is written.
    public typealias ProcessingFactory = @Sendable (String) async throws -> NoteLocation

    private let sessions: any SessionStoring
    private let progress: any ProgressLogging
    private let prompt: any RecordingPrompting
    private let clock: any TimeSource
    private let minimumDuration: TimeInterval
    private let makeCapture: CaptureFactory
    private let makeNote: ProcessingFactory

    private var state = State.idle
    private var capture: (any AudioCapturing)?
    private var pump: Task<Void, Never>?
    private var sessionID: String?

    public init(
        sessions: any SessionStoring,
        progress: any ProgressLogging,
        prompt: any RecordingPrompting,
        clock: any TimeSource,
        minimumDuration: TimeInterval,
        capture: @escaping CaptureFactory,
        process: @escaping ProcessingFactory
    ) {
        self.sessions = sessions
        self.progress = progress
        self.prompt = prompt
        self.clock = clock
        self.minimumDuration = minimumDuration
        self.makeCapture = capture
        self.makeNote = process
    }

    public func current() -> State { state }

    /// Ignored while one is already running, so a second click cannot leave a
    /// recording nobody holds a handle to. Processing the last session is not a
    /// recording and does not hold this back: everything after the audio can be
    /// run again, and the audio cannot.
    public func start() async {
        switch state {
        case .recording, .finishing: return
        default: break
        }

        do {
            let armed = try await ArmSession(sessions: sessions, prompt: prompt, clock: clock)()
            let confirmed = try await ConfirmRecording(sessions: sessions)(sessionID: armed.id)
            let capture = try await makeCapture(armed.id)
            let stream = try await capture.start()

            self.capture = capture
            sessionID = armed.id
            state = .recording(segments: 0, seconds: 0)

            pump = Task { [weak self] in
                var session = confirmed
                for await segment in stream {
                    session = await self?.keeping(segment, in: session) ?? session
                }
            }
        } catch {
            // Named rather than swallowed: a recording that failed to start is
            // the one thing a caller has to be able to say out loud.
            state = .failed(String(describing: error))
            capture = nil
        }
    }

    public func stop() async {
        guard case .recording = state, let capture, let sessionID else { return }
        state = .finishing

        do {
            // The partials come back from stop and the pump has to have drained
            // first: it is what writes the closed segments in.
            let partials = try await capture.stop()
            await pump?.value

            if var session = try await sessions.load(id: sessionID) {
                for partial in partials {
                    session = await keeping(partial, in: session)
                }
            }

            let stopped = try await StopRecording(
                sessions: sessions,
                minimumDuration: minimumDuration
            )(sessionID: sessionID)
            if stopped.state == .recorded {
                writeUp(sessionID)
            } else {
                // Discarded, so there is no meeting to write up. Processing it
                // would be refused by the pipeline and reported as a failure the
                // user did nothing wrong to cause.
                state = .finished(id: sessionID, outcome: stopped.state, seconds: stopped.duration)
            }
        } catch {
            state = .failed(String(describing: error))
        }
        self.capture = nil
        self.sessionID = nil
        pump = nil
    }

    /// Walks a session already on disk to its note.
    ///
    /// Spawned rather than awaited, so stopping hands the menu back at once: an
    /// hour of meeting is about forty seconds of transcription, and a caller
    /// polling for the state has to be able to say that it is running.
    ///
    /// Public because the pipeline is safe to run again on the same session, so
    /// a failed run is retried from the menu rather than through a mechanism of
    /// its own.
    public func process(id: String) {
        // Never over a running recording: `stop()` only answers from
        // `.recording`, so moving off it here would leave a capture nobody can
        // end and the meeting in the room unfinishable. Stopping reaches the
        // same work through `writeUp`, from `.finishing`, which is its own.
        switch state {
        case .recording, .finishing: return
        default: break
        }

        writeUp(id)
    }

    private func writeUp(_ id: String) {
        state = .processing(id: id)
        Task { [weak self] in await self?.settle(id) }
    }

    private func settle(_ id: String) async {
        let reached: State
        do {
            reached = .processed(id: id, note: try await makeNote(id).delivered)
        } catch {
            reached = .processingFailed(id: id, reason: String(describing: error))
        }

        // A recording started while this ran owns the state now: what is
        // happening beats what has finished, and the note is still on disk.
        guard case .processing(let running) = state, running == id else { return }
        state = reached
    }

    /// Wrapped in PerformStep, so an intent lands before the state is saved and
    /// a completion after: a crash between the two leaves a step recovery can
    /// name rather than a segment nobody can account for.
    ///
    /// A segment that cannot be kept does not end the recording — the audio is
    /// already on disk and recovery reads the directory — but it does surface,
    /// because a session quietly missing a minute is the failure this whole
    /// design is against.
    private func keeping(_ segment: Segment, in session: Session) async -> Session {
        do {
            // Built before the step and captured as a value: the closure
            // crosses an isolation boundary, so it may hold nothing of this
            // actor's.
            let grown = try session.appending(segment)
            let store = sessions
            try await PerformStep(progress: progress)(
                .closingSegment(track: segment.track, index: segment.index),
                of: session.id
            ) {
                try await store.save(grown)
            }
            if case .recording = state {
                state = .recording(segments: grown.segments.count, seconds: grown.duration)
            }
            return grown
        } catch {
            state = .failed("a segment could not be kept: \(error)")
            return session
        }
    }
}
