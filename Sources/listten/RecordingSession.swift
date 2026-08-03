import Foundation
import ListtenCore

/// A recording that somebody else decides the length of.
///
/// `Recording.run` records for a number of seconds because a command line has
/// no other way to say when to stop. A person clicking a menu does, so this
/// holds the same pipeline open until asked to end it.
actor RecordingSession {
    /// What the menu shows. Recording carries what it has so far, since a bar
    /// that only says "recording" cannot tell working from wedged.
    enum State: Equatable {
        case idle
        case recording(segments: Int, seconds: TimeInterval)
        case finishing
        case finished(id: String, outcome: String, seconds: TimeInterval)
        case failed(String)
    }

    private let root: URL
    private let rotateEvery: TimeInterval
    private let store: FileSessionStore

    private var state = State.idle
    private var capture: SegmentedCapture?
    private var pump: Task<Void, Never>?
    private var sessionID: String?

    init(root: URL, rotateEvery: TimeInterval = 45) {
        self.root = root
        self.rotateEvery = rotateEvery
        self.store = FileSessionStore(root: root)
    }

    func current() -> State { state }

    func start() async {
        switch state {
        case .recording, .finishing: return
        default: break
        }

        do {
            let armed = try await ArmSession(
                sessions: store,
                prompt: SilentPrompt(),
                clock: SystemTimeSource()
            )()
            var session = try await ConfirmRecording(sessions: store)(sessionID: armed.id)

            let capture = SegmentedCapture(
                sources: [.microphone: MicrophoneCapture()],
                directory: root.appending(path: armed.id).appending(path: "audio"),
                rotateEvery: rotateEvery
            )
            let stream = try await capture.start()

            self.capture = capture
            self.sessionID = armed.id
            state = .recording(segments: 0, seconds: 0)

            let step = PerformStep(progress: SessionProgressLogs(root: root))
            let store = self.store
            pump = Task { [weak self] in
                for await segment in stream {
                    session = await Recording.keep(
                        segment,
                        in: session,
                        of: armed.id,
                        store: store,
                        step: step
                    )
                    await self?.grew(to: session)
                }
            }
        } catch {
            // Named rather than swallowed: a recording that failed to start is
            // the one thing a menu bar has to be able to say out loud.
            state = .failed(Self.describing(error))
            capture = nil
        }
    }

    func stop() async {
        guard case .recording = state, let capture, let sessionID else { return }
        state = .finishing

        do {
            // The partials come back from stop, and the pump has to have drained
            // before the session is read back: it is what writes the segments in.
            let partials = try await capture.stop()
            await pump?.value

            if var session = try await store.load(id: sessionID) {
                let step = PerformStep(progress: SessionProgressLogs(root: root))
                for partial in partials {
                    session = await Recording.keep(
                        partial,
                        in: session,
                        of: sessionID,
                        store: store,
                        step: step
                    )
                }
            }

            let stopped = try await StopRecording(sessions: store, minimumDuration: 1)(
                sessionID: sessionID
            )
            state = .finished(
                id: sessionID,
                outcome: stopped.state.rawValue,
                seconds: stopped.duration
            )
        } catch {
            state = .failed(Self.describing(error))
        }
        self.capture = nil
        self.sessionID = nil
        pump = nil
    }

    /// Where the finished session's files are, for the menu item that opens it.
    func directory() -> URL? {
        guard case .finished(let id, _, _) = state else { return nil }
        return root.appending(path: id)
    }

    private func grew(to session: Session) {
        guard case .recording = state else { return }
        state = .recording(segments: session.segments.count, seconds: session.duration)
    }

    private static func describing(_ error: any Error) -> String {
        error is MicrophoneCapture.AccessDenied
            ? "Microphone access is off for Listten"
            : String(describing: error)
    }
}

/// The notification with a Record button is #26. Until it exists, the click on
/// the menu is the answer, so there is nothing left to ask.
private struct SilentPrompt: RecordingPrompting {
    func askWhetherToRecord(sessionID: String) async throws {}
}

struct SystemTimeSource: TimeSource {
    var now: Date { Date() }
}
