import Foundation
import Testing

@testable import ListtenCore

@Test("a segment knows when it ends")
func segmentEnd() throws {
    let segment = try Segment(index: 1, track: .microphone, start: 10, duration: 45)
    #expect(segment.end == 55)
}

@Test("a segment before the first one cannot exist")
func negativeIndexIsRefused() {
    #expect(throws: Segment.Impossible.negativeIndex(-1)) {
        try Segment(index: -1, track: .microphone, start: 100, duration: 50)
    }
}

@Test("a segment starting before the session cannot exist")
func negativeStartIsRefused() {
    #expect(throws: Segment.Impossible.negativeStart(-1)) {
        try Segment(index: 0, track: .microphone, start: -1, duration: 50)
    }
}

/// The one the issue leads with: `end` would precede `start`, and `Session.duration`
/// takes a maximum over `end`, so one bad value moves the whole session.
@Test("a segment that ends before it starts cannot exist")
func negativeDurationIsRefused() {
    #expect(throws: Segment.Impossible.negativeDuration(-50)) {
        try Segment(index: 0, track: .microphone, start: 100, duration: -50)
    }
}

/// A rotation can fall on a buffer carrying no frames, so an empty segment is a
/// real file on disk rather than a value to refuse.
@Test("a segment that caught no audio is still a segment")
func zeroDurationIsAccepted() throws {
    let segment = try Segment(index: 0, track: .microphone, start: 10, duration: 0)
    #expect(segment.end == 10)
}

@Test("a segment read back from a state file answers to the same rules")
func decodingASegmentRefusesWhatConstructionRefuses() {
    let stored = Data(#"{"index":0,"track":"microphone","start":100,"duration":-50}"#.utf8)

    #expect(throws: Segment.Impossible.negativeDuration(-50)) {
        try JSONDecoder().decode(Segment.self, from: stored)
    }
}

@Test("a segment survives the round trip it is stored by")
func segmentRoundTrips() throws {
    let segment = try Segment(index: 2, track: .system, start: 90, duration: 45)

    let decoded = try JSONDecoder()
        .decode(
            Segment.self,
            from: try JSONEncoder().encode(segment)
        )

    #expect(decoded == segment)
}
