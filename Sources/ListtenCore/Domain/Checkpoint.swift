import Foundation

/// One piece of work that finished, recorded as it happens so a resumed run
/// knows what it does not have to do again.
public enum Checkpoint: Sendable, Equatable, Codable {
    case segmentClosed(segment: Segment)
    case chunkTranscribed(index: Int)
}
