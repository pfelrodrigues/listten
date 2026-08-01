import Foundation

/// One meeting, from detection to note. The aggregate owns its invariants: a
/// caller cannot put it into a state the pipeline does not allow.
public struct Session: Sendable, Equatable, Codable {
    public enum RuleViolation: Error, Equatable {
        case audioWhileNotRecording(SessionState)
    }

    public let id: String
    public let startedAt: Date
    public private(set) var state: SessionState
    public private(set) var segments: [Segment]

    public init(id: String, startedAt: Date) {
        self.id = id
        self.startedAt = startedAt
        self.state = .initial
        self.segments = []
    }

    /// Derived, never set from outside.
    public var duration: TimeInterval {
        segments.map(\.end).max() ?? 0
    }

    public func appending(_ segment: Segment) throws -> Session {
        guard state.acceptsAudio else {
            throw RuleViolation.audioWhileNotRecording(state)
        }
        var copy = self
        copy.segments.append(segment)
        return copy
    }

    /// Whether a recording was long enough to be a meeting is a rule about the
    /// session, so it lives here rather than in whichever caller ends it.
    public func stopping(minimumDuration: TimeInterval) throws -> Session {
        try applying(duration < minimumDuration ? .discard : .stopRecording)
    }

    /// Transitions delegate to the state machine, so the aggregate has a single
    /// definition of what may follow what.
    public func applying(_ event: SessionEvent) throws -> Session {
        var copy = self
        copy.state = try state.applying(event)
        return copy
    }
}
