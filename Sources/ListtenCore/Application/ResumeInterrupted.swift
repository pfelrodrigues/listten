import Foundation

/// Runs at startup over the unfinished sessions, resolving the two states no
/// later step can and naming the step each one was interrupted inside. Recovery
/// is the normal path, not the exceptional one: a session left recording by a
/// crash keeps its closed segments, so it moves on as recorded rather than being
/// thrown away. It ends on the same terms a user pressing Stop would get, so how
/// the process died cannot change the verdict. An armed one is discarded
/// instead: its prompt did not survive the process, so nobody can answer it any
/// more, and nothing was recorded. Every other unfinished state is left for the
/// pipeline step that owns it, and reported only when a step was in flight.
///
/// What the progress log adds is which step to resume. A step whose intent has
/// no completion is one the process died inside, so it is named for redo; a step
/// with both ends is finished and must not run again.
public struct ResumeInterrupted: Sendable {
    /// Raised after the readable sessions are already resolved, so state that
    /// cannot be read costs the meeting it describes and no other.
    public struct UnreadableSessions: Error, Equatable {
        public let ids: [String]
    }

    /// A log holding a completion nobody intended describes work that cannot
    /// have happened, so it is reported ahead of `UnreadableSessions`: state
    /// nobody can read is a session lost, while a log that pairs up wrong is a
    /// session about to be resumed from a lie.
    public struct BrokenProgress: Error, Equatable {
        public let broken: [String: ProgressLedger.BrokenLog]
    }

    /// A session recovery resolved, and the steps it has to redo before the
    /// pipeline takes it back.
    public struct Resumption: Sendable, Equatable {
        public let session: Session
        public let redo: [PipelineStep]
    }

    private let sessions: any SessionStoring
    private let progress: any ProgressLogging
    private let minimumDuration: TimeInterval

    public init(
        sessions: any SessionStoring,
        progress: any ProgressLogging,
        minimumDuration: TimeInterval
    ) {
        self.sessions = sessions
        self.progress = progress
        self.minimumDuration = minimumDuration
    }

    public func callAsFunction() async throws -> [Resumption] {
        let unfinished = try await sessions.unfinished()
        var resolved: [Resumption] = []
        var unreadable = unfinished.unreadable
        var broken: [String: ProgressLedger.BrokenLog] = [:]

        for session in unfinished.sessions {
            let ledger: ProgressLedger
            do {
                ledger = try ProgressLedger(await progress.checkpoints(for: session.id))
            } catch let failure as ProgressLedger.BrokenLog {
                broken[session.id] = failure
                continue
            } catch {
                // A log nobody can read is this session's progress lost, like
                // its state file: the meetings around it are still resumable.
                unreadable.append(session.id)
                continue
            }

            let outcome: Session?
            switch session.state {
            case .recording: outcome = try session.stopping(minimumDuration: minimumDuration)
            case .armed: outcome = try session.applying(.discard)
            default: outcome = nil
            }
            if let outcome {
                try await sessions.save(outcome)
            }

            // Nothing survives a session recovery ended, so a step it died
            // inside is work nobody will ever want rather than work to redo.
            let resumed = outcome ?? session
            let redo = resumed.state.isTerminal ? [] : ledger.interrupted
            guard outcome != nil || !redo.isEmpty else { continue }
            resolved.append(Resumption(session: resumed, redo: redo))
        }

        // Reported last, so what could be resolved is already saved: a session
        // nobody can read is still a session lost.
        guard broken.isEmpty else { throw BrokenProgress(broken: broken) }
        guard unreadable.isEmpty else { throw UnreadableSessions(ids: unreadable.sorted()) }
        return resolved
    }
}
