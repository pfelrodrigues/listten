import Foundation

public struct SessionNotFound: Error, Equatable {
    public let id: String
}

/// The user accepted the prompt. From here on audio reaches disk, starting with
/// the pre-roll buffer drained into the first segment.
public struct ConfirmRecording: Sendable {
    private let sessions: any SessionStoring

    public init(sessions: any SessionStoring) {
        self.sessions = sessions
    }

    public func callAsFunction(sessionID: String) async throws -> Session {
        guard let session = try await sessions.load(id: sessionID) else {
            throw SessionNotFound(id: sessionID)
        }
        let confirmed = try session.applying(.confirm)
        try await sessions.save(confirmed)
        return confirmed
    }
}

/// Recording ended. Anything too short to be a meeting is discarded, which
/// stops the note without deleting the audio.
public struct StopRecording: Sendable {
    private let sessions: any SessionStoring
    private let minimumDuration: TimeInterval

    public init(sessions: any SessionStoring, minimumDuration: TimeInterval) {
        self.sessions = sessions
        self.minimumDuration = minimumDuration
    }

    public func callAsFunction(sessionID: String) async throws -> Session {
        guard let session = try await sessions.load(id: sessionID) else {
            throw SessionNotFound(id: sessionID)
        }
        let stopped = try session.stopping(minimumDuration: minimumDuration)
        try await sessions.save(stopped)
        return stopped
    }
}
