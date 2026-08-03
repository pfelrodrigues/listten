import Foundation

/// Which side of the conversation a segment came from.
public enum Track: String, Sendable, Codable, CaseIterable {
    case microphone
    case system
}

/// One rotated chunk of audio. Segments are closed on rotation so a crash costs
/// the tail of one chunk rather than the session.
public struct Segment: Sendable, Equatable, Codable {
    /// A value capture cannot produce, carrying what was offered.
    public enum Impossible: Error, Equatable {
        case negativeIndex(Int)
        case negativeStart(TimeInterval)
        case negativeDuration(TimeInterval)
    }

    public let index: Int
    public let track: Track
    public let start: TimeInterval
    public let duration: TimeInterval

    /// Capture numbers segments from zero, places them on a clock whose zero is
    /// the anchor, and measures length from frames, so none of the three can be
    /// negative. A negative duration is the one that spreads: `Session.duration`
    /// maxes over `end`, so a segment ending before it starts moves the session.
    public init(index: Int, track: Track, start: TimeInterval, duration: TimeInterval) throws {
        guard index >= 0 else { throw Impossible.negativeIndex(index) }
        guard start >= 0 else { throw Impossible.negativeStart(start) }
        guard duration >= 0 else { throw Impossible.negativeDuration(duration) }
        self.index = index
        self.track = track
        self.start = start
        self.duration = duration
    }

    /// Decoding is the other way in, so it goes through the same door: a state
    /// file read back at resume is exactly where a bad segment would surface.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            index: container.decode(Int.self, forKey: .index),
            track: container.decode(Track.self, forKey: .track),
            start: container.decode(TimeInterval.self, forKey: .start),
            duration: container.decode(TimeInterval.self, forKey: .duration)
        )
    }

    public var end: TimeInterval { start + duration }
}
