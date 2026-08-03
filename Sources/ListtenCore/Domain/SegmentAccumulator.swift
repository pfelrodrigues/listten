import Foundation

/// Slices one track's buffers into numbered segments.
///
/// A segment closes on the buffer that carries it past the rotation, never in
/// the middle of one: a buffer is written whole, so splitting it would mean
/// writing half of it to each file. Segments therefore run slightly long, by at
/// most one buffer.
///
/// Position comes from the clock and length from the audio, so a device swapped
/// mid-recording leaves a gap between segments instead of shifting every
/// segment after it earlier.
public struct SegmentAccumulator: Sendable {
    /// Where a buffer belongs, and the segment its arrival completed.
    public struct Placement: Sendable, Equatable {
        public let index: Int
        public let closed: Segment?
    }

    private let track: Track
    private let timeline: CaptureTimeline
    private let rotateEvery: TimeInterval

    private var index = 0
    private var start: TimeInterval?
    private var accumulated: TimeInterval = 0

    /// `rotateEvery` has to be positive; a rotation of zero closes a segment per
    /// buffer. The only thing that builds one of these validates it, which keeps
    /// a branch no test can reach out of the domain.
    public init(track: Track, anchor: TimeInterval, rotateEvery: TimeInterval) {
        self.track = track
        self.timeline = CaptureTimeline(anchor: anchor)
        self.rotateEvery = rotateEvery
    }

    public mutating func placing(_ audio: CapturedAudio) throws -> Placement {
        let measured = try timeline.segment(
            index: index,
            track: track,
            hostTime: audio.hostTime,
            frames: audio.frames,
            sampleRate: audio.sampleRate
        )

        let belongsTo = index
        if start == nil { start = measured.start }
        accumulated += measured.duration

        guard accumulated >= rotateEvery else {
            return Placement(index: belongsTo, closed: nil)
        }
        return Placement(index: belongsTo, closed: try rotate())
    }

    /// Hands over the file still open, so stopping does not cost its audio.
    /// Nothing open means nothing to hand over, twice in a row included.
    public mutating func closing() throws -> Segment? {
        try rotate()
    }

    private mutating func rotate() throws -> Segment? {
        guard let start else { return nil }
        let segment = try Segment(
            index: index,
            track: track,
            start: start,
            duration: accumulated
        )
        index += 1
        self.start = nil
        accumulated = 0
        return segment
    }
}
