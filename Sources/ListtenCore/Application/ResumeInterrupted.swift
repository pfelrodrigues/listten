import Foundation

/// Runs at startup. Recovery is the normal path, not the exceptional one: a
/// session left recording by a crash keeps its closed segments, so it moves on
/// as recorded rather than being thrown away. It ends on the same terms a user
/// pressing Stop would get, so how the process died cannot change the verdict.
public struct ResumeInterrupted: Sendable {
    private let sessions: any SessionStoring
    private let minimumDuration: TimeInterval

    public init(sessions: any SessionStoring, minimumDuration: TimeInterval) {
        self.sessions = sessions
        self.minimumDuration = minimumDuration
    }

    public func callAsFunction() async throws -> [Session] {
        var resumed: [Session] = []
        for session in try await sessions.unfinished() {
            guard session.state == .recording else { continue }
            let recovered = try session.stopping(minimumDuration: minimumDuration)
            try await sessions.save(recovered)
            resumed.append(recovered)
        }
        return resumed
    }
}
