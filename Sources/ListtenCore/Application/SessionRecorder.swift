import Foundation

/// What a factory hands back: the capture, and the live transcript following it
/// where there is one.
///
/// They arrive together because they are made together — the live transcript
/// reads the sink the capture was built with — and because something has to
/// await the live side after the capture has stopped, or the last few seconds of
/// finals are lost. Nil means no live transcript, which is what a machine with
/// no model for the language gets, and the capture is then exactly what it was
/// before this existed.
public struct ArmedRecording: Sendable {
    public let capture: any AudioCapturing
    public let live: LiveTranscript?

    public init(capture: any AudioCapturing, live: LiveTranscript? = nil) {
        self.capture = capture
        self.live = live
    }
}

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

    public typealias CaptureFactory = @Sendable (String) async throws -> ArmedRecording

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
    private var arming = false
    /// Why a segment never reached the state file, where stopping will find it.
    private var segmentFailure: String?
    private var writing: Task<Void, Never>?
    private var unwritten: [String: String] = [:]
    private var capture: (any AudioCapturing)?
    private var pump: Task<Void, Never>?
    private var sessionID: String?
    private var live: LiveTranscript?
    private var liveTask: Task<Void, Never>?
    private var lastLiveOutcome: LiveTranscript.Outcome?

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

    /// How the live transcript of the last recording went, or nil where there
    /// was none. Deliberately not part of `State`: a meeting recorded perfectly
    /// must not read as failed because the transcript for following along
    /// stopped growing.
    public func liveOutcome() -> LiveTranscript.Outcome? { lastLiveOutcome }

    /// Ignored while one is already running, so a second click cannot leave a
    /// recording nobody holds a handle to. Processing the last session is not a
    /// recording and does not hold this back: everything after the audio can be
    /// run again, and the audio cannot.
    public func start() async {
        switch state {
        case .recording, .finishing: return
        default: break
        }
        // The guard above reads a state that four suspension points below have
        // not reached yet, so two clicks both pass it, both arm a capture, and
        // the second overwrites the first: a live device nobody holds a handle
        // to, recording a meeting nothing can stop. This is the handle.
        guard !arming else { return }
        arming = true
        defer { arming = false }

        do {
            let armed = try await ArmSession(sessions: sessions, prompt: prompt, clock: clock)()
            let confirmed = try await ConfirmRecording(sessions: sessions)(sessionID: armed.id)
            let recording = try await makeCapture(armed.id)
            let stream = try await recording.capture.start()

            capture = recording.capture
            live = recording.live
            sessionID = armed.id
            segmentFailure = nil
            lastLiveOutcome = nil
            state = .recording(segments: 0, seconds: 0)

            // Spawned only once the capture is running. A start that threw
            // leaves a stream nobody will ever finish, and a task awaiting one
            // never returns.
            liveTask = recording.live.map { transcript in Task { await transcript.run() } }

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
            live = nil
        }
    }

    public func stop() async {
        guard case .recording = state, let capture, let sessionID else { return }
        state = .finishing

        // Everything below runs while the state still says finishing, and the
        // terminal state is set once at the end. An actor is reentrant: with the
        // state moved first, a start landing on one of the awaits below would be
        // accepted, arm a capture, and then be torn down by this method
        // resuming — a recording that can never be stopped, and a device nobody
        // holds a handle to.
        var reached: State?
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
            if stopped.state != .recorded {
                // Discarded, so there is no meeting to write up. Processing it
                // would be refused by the pipeline and reported as a failure the
                // user did nothing wrong to cause.
                reached = .finished(
                    id: sessionID,
                    outcome: stopped.state,
                    seconds: stopped.duration
                )
            }
        } catch {
            reached = .failed(String(describing: error))
        }

        // After the capture, which is what ends the sink the live side reads,
        // and outside the catch so a stop that failed still gets here: a live
        // task nobody awaits holds an analyser open into the next meeting.
        await liveTask?.value
        if let live {
            lastLiveOutcome = await live.outcome()
        }

        self.capture = nil
        self.live = nil
        liveTask = nil
        self.sessionID = nil
        pump = nil

        // A segment that never reached the state file leaves audio the session
        // does not name, which recovery adopts and the pipeline refuses. Writing
        // up anyway would replace this diagnosis with whatever the pipeline made
        // of it, and offer a retry that cannot work until recovery has run.
        if let lost = segmentFailure {
            state = .failed(lost)
        } else if let reached {
            state = reached
        } else {
            writeUp(sessionID)
        }
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

    /// Chained rather than spawned loose: stopping and starting through one slow
    /// write-up would otherwise run a pipeline per stop, over the same audio,
    /// and throw away every result but one.
    private func writeUp(_ id: String) {
        state = .processing(id: id)
        let queued = writing
        writing = Task { [weak self] in
            await queued?.value
            await self?.settle(id)
        }
    }

    private func settle(_ id: String) async {
        do {
            let note = try await makeNote(id).delivered
            unwritten[id] = nil
            // A recording started while this ran owns the state now: what is
            // happening beats what has finished, and the note is on disk either
            // way, so the cost is the menu item pointing at it.
            guard case .processing(let running) = state, running == id else { return }
            state = .processed(id: id, note: note)
        } catch {
            // A failure cannot be dropped the way a success can. Losing it
            // leaves a meeting with no note, nothing said about it, and no id to
            // run again, so it is recorded where a later state cannot overwrite
            // it and the menu offers it back.
            let reason = String(describing: error)
            unwritten[id] = reason
            guard case .processing(let running) = state, running == id else { return }
            state = .processingFailed(id: id, reason: reason)
        }
    }

    /// Sessions left on disk with audio and no note, picked up where the last
    /// run stopped.
    ///
    /// Quitting during a write-up, or a crash, leaves a meeting recorded and
    /// unwritten with nothing that ever looks at it again: recovery resolves the
    /// states no later step can and hands the rest to the pipeline, and until
    /// this existed the pipeline was only ever reached by stopping a recording.
    ///
    /// Everything after the audio is reproducible, so this is safe on a session
    /// that was halfway through: it starts again from the audio.
    public func writeUpWhatIsUnwritten() async {
        guard case .idle = state else { return }

        let waiting: UnfinishedSessions
        do {
            waiting = try await sessions.unfinished()
        } catch {
            // One unreadable store is not a reason to refuse to record. The
            // meetings are still on disk and the next launch asks again.
            state = .failed("could not look for unwritten notes: \(error)")
            return
        }

        // Recording and armed belong to recovery, which resolves them before
        // this runs. What is left is a meeting whose audio is complete and whose
        // note was never written.
        for session in waiting.sessions
        where session.state == .recorded || session.state == .transcribing
            || session.state == .transcribed || session.state == .summarizing
        {
            unwritten[session.id] = unwritten[session.id] ?? "the note was never written"
        }
    }

    /// Meetings whose note was never written, by session, with what went wrong.
    /// Survives whatever the recorder is doing now, because a failure that only
    /// lived in the current state would be lost to the next recording.
    public func unwrittenNotes() -> [String: String] { unwritten }

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
            // Recorded rather than set: moving off .recording here would let a
            // start in, and the recording still running would have nothing to
            // stop it. Stopping reads this and reports it.
            segmentFailure = segmentFailure ?? "a segment could not be kept: \(error)"
            return session
        }
    }
}
