import Foundation

/// One finalized line of the transcript that grows while the meeting runs.
///
/// It carries a track rather than a speaker. The tracks were separate before
/// transcription started, so the microphone is the user and the system is
/// everyone else, and no engine had to tell voices apart to say so.
public struct LiveLine: Sendable, Equatable, Codable {
    /// A line no live backend can produce, carrying what was offered.
    public enum Impossible: Error, Equatable {
        case negativeStart(TimeInterval)
        case endBeforeStart(start: TimeInterval, end: TimeInterval)
    }

    public let track: Track
    public let start: TimeInterval
    public let end: TimeInterval
    public let text: String

    /// Both instants are on the session clock, the same one the segments are
    /// placed on, so a reader can line a live line up with the recording.
    public init(track: Track, start: TimeInterval, end: TimeInterval, text: String) throws {
        guard start >= 0 else { throw Impossible.negativeStart(start) }
        guard end >= start else { throw Impossible.endBeforeStart(start: start, end: end) }
        self.track = track
        self.start = start
        self.end = end
        self.text = text
    }

    /// Decoding is the other way in, so it goes through the same door. It is the
    /// door that matters most here: the file is written for a program this
    /// project did not write, and reading it back is how the shape is checked.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            track: container.decode(Track.self, forKey: .track),
            start: container.decode(TimeInterval.self, forKey: .start),
            end: container.decode(TimeInterval.self, forKey: .end),
            text: container.decode(String.self, forKey: .text)
        )
    }
}
