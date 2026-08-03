import Foundation

/// Decides when a capture has gone quiet for the wrong reason.
///
/// The worst failure this product can have is not a crash, which leaves audio to
/// recover, but a session that believes it is recording while nothing arrives.
/// A device can stop delivering without saying so: an engine that wedges, a
/// driver that hangs, a device that vanishes without posting a configuration
/// change.
public struct StallDetector: Sendable, Equatable {
    public enum Verdict: Sendable, Equatable {
        case running
        /// Restart the source now.
        case stalled
        /// Already asked for a restart; audio has not come back yet.
        case waitingToRecover
    }

    /// How long a device is allowed to take before its first buffer.
    private let grace: TimeInterval
    /// How long a silence is allowed to last once audio has been flowing.
    private let tolerance: TimeInterval
    private let startedAt: TimeInterval
    private var lastDelivery: TimeInterval?
    private var lastReport: TimeInterval?

    public init(startedAt: TimeInterval, grace: TimeInterval, tolerance: TimeInterval) {
        self.startedAt = startedAt
        self.grace = grace
        self.tolerance = tolerance
    }

    public mutating func received(at instant: TimeInterval) {
        lastDelivery = instant
        lastReport = nil
    }

    public mutating func verdict(at instant: TimeInterval) -> Verdict {
        let since = lastDelivery ?? startedAt
        let allowed = lastDelivery == nil ? grace : tolerance
        guard instant - since > allowed else { return .running }

        // A restart is given the same tolerance to work as a running device is
        // given to stay quiet. Past that it has failed, and asking once and
        // never again would leave a session recording silence.
        if let lastReport, instant - lastReport <= tolerance {
            return .waitingToRecover
        }

        lastReport = instant
        return .stalled
    }
}
