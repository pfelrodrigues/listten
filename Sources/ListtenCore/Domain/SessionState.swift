/// What can happen to a session, in the order the pipeline produces it.
public enum SessionEvent: Sendable, CaseIterable {
    case confirm
    case discard
    case stopRecording
    case startTranscribing
    case finishTranscribing
    case startSummarizing
    case complete
    case fail
}

/// The lifecycle of one meeting. Transitions are explicit so an invalid one is
/// an error rather than a silently wrong state.
public enum SessionState: String, Sendable, Equatable, CaseIterable, Codable {
    case armed
    case recording
    case recorded
    case transcribing
    case transcribed
    case summarizing
    case completed
    case discarded
    case failed

    public static let initial = SessionState.armed

    public struct TransitionError: Error, Equatable {
        public let from: SessionState
        public let event: SessionEvent
    }

    /// Audio may only be written while recording. Everything else derives from
    /// what is already on disk.
    public var acceptsAudio: Bool { self == .recording }

    public var isTerminal: Bool {
        self == .completed || self == .discarded || self == .failed
    }

    public func applying(_ event: SessionEvent) throws -> SessionState {
        switch (self, event) {
        case (.armed, .confirm): return .recording
        case (.armed, .discard): return .discarded
        case (.recording, .stopRecording): return .recorded
        case (.recording, .discard): return .discarded
        case (.recorded, .startTranscribing): return .transcribing
        case (.recorded, .discard): return .discarded
        case (.transcribing, .finishTranscribing): return .transcribed
        case (.transcribed, .startSummarizing): return .summarizing
        case (.summarizing, .complete): return .completed
        case (_, .fail) where !isTerminal: return .failed
        default: throw TransitionError(from: self, event: event)
        }
    }
}
