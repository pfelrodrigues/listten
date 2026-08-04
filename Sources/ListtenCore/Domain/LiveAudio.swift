import Foundation

/// One buffer that reached disk, placed on the session clock.
///
/// It exists so that whatever follows the recording live is handed the same
/// instant the segments were placed on, rather than deriving a second one that
/// would have to be proven equal to the first.
public struct LiveAudio: Sendable, Equatable {
    public let track: Track
    public let audio: CapturedAudio
    /// Seconds from the session's zero to this buffer's first sample.
    public let start: TimeInterval

    public init(track: Track, audio: CapturedAudio, start: TimeInterval) {
        self.track = track
        self.audio = audio
        self.start = start
    }
}
