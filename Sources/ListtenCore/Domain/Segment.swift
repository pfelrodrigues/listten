import Foundation

/// Which side of the conversation a segment came from.
public enum Track: String, Sendable, Codable, CaseIterable {
    case microphone
    case system
}

/// One rotated chunk of audio. Segments are closed on rotation so a crash costs
/// the tail of one chunk rather than the session.
public struct Segment: Sendable, Equatable, Codable {
    public let index: Int
    public let track: Track
    public let start: TimeInterval
    public let duration: TimeInterval

    public init(index: Int, track: Track, start: TimeInterval, duration: TimeInterval) {
        self.index = index
        self.track = track
        self.start = start
        self.duration = duration
    }

    public var end: TimeInterval { start + duration }
}
