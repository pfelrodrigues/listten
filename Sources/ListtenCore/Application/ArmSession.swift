import Foundation

/// A meeting was detected. The pre-roll buffer is already running; this only
/// records the intent and asks the user, without writing audio.
public struct ArmSession: Sendable {
    private let sessions: any SessionStoring
    private let prompt: any RecordingPrompting
    private let clock: any TimeSource

    public init(sessions: any SessionStoring, prompt: any RecordingPrompting, clock: any TimeSource)
    {
        self.sessions = sessions
        self.prompt = prompt
        self.clock = clock
    }

    public func callAsFunction() async throws -> Session {
        let now = clock.now
        let session = Session(id: Self.identifier(for: now), startedAt: now)
        try await sessions.save(session)
        await prompt.askWhetherToRecord(sessionID: session.id)
        return session
    }

    /// Sortable by time so a directory listing reads chronologically, with a
    /// random suffix because a timestamp alone collides for two meetings
    /// detected within the same second.
    private static func identifier(for date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let stamp = formatter.string(from: date)
            .replacingOccurrences(of: ":", with: "-")
        let suffix = String(UUID().uuidString.prefix(8)).lowercased()
        return "\(stamp)-\(suffix)"
    }
}
