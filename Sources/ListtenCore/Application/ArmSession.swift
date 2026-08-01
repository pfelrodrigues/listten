import Foundation

/// A meeting was detected. The pre-roll buffer is already running; this only
/// records the intent and asks the user, without writing audio.
public struct ArmSession: Sendable {
    private let sessions: any SessionStoring
    private let prompt: any RecordingPrompting
    private let clock: any Clock

    public init(sessions: any SessionStoring, prompt: any RecordingPrompting, clock: any Clock) {
        self.sessions = sessions
        self.prompt = prompt
        self.clock = clock
    }

    public func callAsFunction() async throws -> Session {
        let now = clock.now
        let session = Session(id: ISO8601DateFormatter().string(from: now), startedAt: now)
        try await sessions.save(session)
        await prompt.askWhetherToRecord(sessionID: session.id)
        return session
    }
}
