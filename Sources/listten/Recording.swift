import Foundation
import ListtenCore

/// The one path that exists end to end today: arm a session, record it, keep the
/// state and the checkpoints beside the audio, and stop on the same terms the
/// domain would give any other caller.
///
/// It is deliberately assembled here rather than in `ListtenCore`, because what
/// drives a session is the menu bar agent's job and that does not exist yet.
/// Until it does, this is what a real recording can be tested against.
enum Recording {
    static func run(seconds: Double, root: URL, rotateEvery: TimeInterval) async {
        let store = FileSessionStore(root: root)
        let clock = SystemTimeSource()

        let session: Session
        do {
            session = try await ArmSession(
                sessions: store,
                prompt: ConsolePrompt(),
                clock: clock
            )()
        } catch {
            fail("could not arm a session: \(error)")
        }

        let directory = root.appending(path: session.id)
        print("session \(session.id)")
        print("  \(directory.path)")

        var recording: Session
        do {
            recording = try await ConfirmRecording(sessions: store)(sessionID: session.id)
        } catch {
            fail("could not start recording: \(error)")
        }

        let log = JSONLProgressLog(url: directory.appending(path: "progress.jsonl"))
        let capture = SegmentedCapture(
            sources: [.microphone: MicrophoneCapture()],
            directory: directory.appending(path: "audio"),
            rotateEvery: rotateEvery
        )

        let stream: AsyncStream<Segment>
        do {
            stream = try await capture.start()
        } catch {
            fail("could not start capture: \(error)")
        }

        print("recording \(seconds)s, rotating every \(Int(rotateEvery))s")
        let stopper = Task {
            try await Task.sleep(for: .seconds(seconds))
            return try await capture.stop()
        }

        for await segment in stream {
            recording = await keep(segment, in: recording, store: store, log: log)
        }

        do {
            for partial in try await stopper.value {
                recording = await keep(partial, in: recording, store: store, log: log)
            }
        } catch {
            fail("capture reported: \(error)")
        }

        do {
            let stopped = try await StopRecording(sessions: store, minimumDuration: 1)(
                sessionID: session.id
            )
            print(
                "state \(stopped.state.rawValue), \(stopped.segments.count) segment(s), "
                    + String(format: "%.2f", stopped.duration) + "s"
            )
        } catch {
            fail("could not stop: \(error)")
        }
    }

    /// Runs what a launch would run: resolve whatever a previous run left open.
    static func resume(root: URL) async {
        let store = FileSessionStore(root: root)
        do {
            let resolved = try await ResumeInterrupted(sessions: store, minimumDuration: 1)()
            guard !resolved.isEmpty else {
                print("nothing left open under \(root.path)")
                return
            }
            for session in resolved {
                print(
                    "\(session.id) -> \(session.state.rawValue), "
                        + "\(session.segments.count) segment(s), "
                        + String(format: "%.2f", session.duration) + "s"
                )
            }
        } catch {
            fail("recovery reported: \(error)")
        }
    }

    /// Audio is the source of truth, so the checkpoint is written first: a crash
    /// between the two leaves a segment the log knows about and the state file
    /// does not, which recovery can reconcile. The other order loses it.
    private static func keep(
        _ segment: Segment,
        in session: Session,
        store: FileSessionStore,
        log: JSONLProgressLog
    ) async -> Session {
        do {
            try log.append(.segmentClosed(segment: segment))
            let grown = try session.appending(segment)
            try await store.save(grown)
            print(
                "  \(segment.track.rawValue)-\(segment.index) "
                    + String(format: "%.2f", segment.duration) + "s"
            )
            return grown
        } catch {
            FileHandle.standardError.write(Data("could not keep a segment: \(error)\n".utf8))
            return session
        }
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("\(message)\n".utf8))
        exit(1)
    }
}

/// The prompt a menu bar notification will replace. Recording was asked for on
/// the command line, so there is nothing left to ask.
private struct ConsolePrompt: RecordingPrompting {
    func askWhetherToRecord(sessionID: String) async throws {
        print("armed \(sessionID)")
    }
}

private struct SystemTimeSource: TimeSource {
    var now: Date { Date() }
}
