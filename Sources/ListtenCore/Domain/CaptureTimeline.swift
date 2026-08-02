import Foundation

/// Places captured audio on the session timeline.
///
/// Position comes from a clock that keeps running while the audio device does
/// not; length comes from the audio itself. Deriving position by adding lengths
/// instead would pull everything after a device change earlier by the length of
/// the gap, and the two tracks would stop lining up.
public struct CaptureTimeline: Sendable, Equatable {
    public struct UnusableSampleRate: Error, Equatable {
        public let sampleRate: Double
    }

    /// The pre-roll buffer is drained by anchoring to its oldest sample, so
    /// audio older than the anchor means the anchor is wrong. Placing it at a
    /// negative instant would corrupt the order of the merged conversation.
    public struct AudioBeforeTheAnchor: Error, Equatable {
        public let hostTime: TimeInterval
        public let anchor: TimeInterval
    }

    /// The instant, on the shared clock, that both tracks call zero.
    public let anchor: TimeInterval

    public init(anchor: TimeInterval) {
        self.anchor = anchor
    }

    public func segment(
        index: Int,
        track: Track,
        hostTime: TimeInterval,
        frames: Int,
        sampleRate: Double
    ) throws -> Segment {
        guard sampleRate > 0 else {
            throw UnusableSampleRate(sampleRate: sampleRate)
        }
        guard hostTime >= anchor else {
            throw AudioBeforeTheAnchor(hostTime: hostTime, anchor: anchor)
        }
        return Segment(
            index: index,
            track: track,
            start: hostTime - anchor,
            duration: Double(frames) / sampleRate
        )
    }
}
