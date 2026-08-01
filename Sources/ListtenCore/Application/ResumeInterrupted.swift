import Foundation

/// Runs at startup. Recovery is the normal path, not the exceptional one: a
/// session left recording by a crash keeps its closed segments, so it moves on
/// as recorded rather than being thrown away.
public struct ResumeInterrupted: Sendable {
    private let sessions: any SessionStoring

    public init(sessions: any SessionStoring) {
        self.sessions = sessions
    }

    public func callAsFunction() async throws -> [Session] {
        var resumed: [Session] = []
        for session in try await sessions.unfinished() {
            guard session.state == .recording else { continue }
            let recovered = try session.applying(.stopRecording)
            try await sessions.save(recovered)
            resumed.append(recovered)
        }
        return resumed
    }
}
