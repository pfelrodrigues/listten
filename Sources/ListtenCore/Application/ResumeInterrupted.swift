import Foundation

/// Runs at startup over the unfinished sessions, resolving the two states no
/// later step can. Recovery is the normal path, not the exceptional one: a session
/// left recording by a crash keeps its closed segments, so it moves on as
/// recorded rather than being thrown away. It ends on the same terms a user
/// pressing Stop would get, so how the process died cannot change the verdict.
/// An armed one is discarded instead: its prompt did not survive the process, so
/// nobody can answer it any more, and nothing was recorded. Every other
/// unfinished state is left for the pipeline step that owns it.
public struct ResumeInterrupted: Sendable {
    /// Raised after the readable sessions are already resolved, so state that
    /// cannot be read costs the meeting it describes and no other.
    public struct UnreadableSessions: Error, Equatable {
        public let ids: [String]
    }

    private let sessions: any SessionStoring
    private let minimumDuration: TimeInterval

    public init(sessions: any SessionStoring, minimumDuration: TimeInterval) {
        self.sessions = sessions
        self.minimumDuration = minimumDuration
    }

    public func callAsFunction() async throws -> [Session] {
        let unfinished = try await sessions.unfinished()
        var resolved: [Session] = []
        for session in unfinished.sessions {
            let outcome: Session
            switch session.state {
            case .recording: outcome = try session.stopping(minimumDuration: minimumDuration)
            case .armed: outcome = try session.applying(.discard)
            default: continue
            }
            try await sessions.save(outcome)
            resolved.append(outcome)
        }

        // Reported last, so what could be resolved is already saved: a session
        // nobody can read is still a session lost.
        guard unfinished.unreadable.isEmpty else {
            throw UnreadableSessions(ids: unfinished.unreadable)
        }
        return resolved
    }
}
