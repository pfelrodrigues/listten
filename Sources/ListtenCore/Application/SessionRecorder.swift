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
        case finished(id: String, outcome: SessionState, seconds: TimeInterval)
        case failed(String)
    }

    public typealias CaptureFactory = @Sendable (String) async throws -> any AudioCapturing

    private let sessions: any SessionStoring
    private let progress: any ProgressLogging
    private let prompt: any RecordingPrompting
    private let clock: any TimeSource
    private let minimumDuration: TimeInterval
    private let makeCapture: CaptureFactory

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
        capture: @escaping CaptureFactory
    ) {
        self.sessions = sessions
        self.progress = progress
        self.prompt = prompt
        self.clock = clock
        self.minimumDuration = minimumDuration
        self.makeCapture = capture
    }

    public func current() -> State { state }

    /// Ignored while one is already running, so a second click cannot leave a
    /// recording nobody holds a handle to.
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
            state = .finished(id: sessionID, outcome: stopped.state, seconds: stopped.duration)
        } catch {
            state = .failed(String(describing: error))
        }
        self.capture = nil
        self.sessionID = nil
        pump = nil
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
