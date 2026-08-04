import Foundation

/// When enough audio has been heard to ask a live backend to settle what it has.
///
/// Live results are finalized on pauses, so a speaker who does not stop produces
/// no lines at all — precisely when there is most to say. Asking on a cadence
/// costs a sentence cut in half now and then and gives a reader something to
/// follow.
///
/// The cadence is counted in frames rather than kept on a timer. Live audio
/// arrives in real time, so five seconds of audio is five seconds of wall clock,
/// and counting the buffers keeps a clock out of this layer and makes a test
/// deterministic. It is the split `SegmentAccumulator` already makes: position
/// from the clock, length from the audio.
/// It accumulates rather than describes, so it is not `Equatable`, for the same
/// reason `SegmentAccumulator` is not.
public struct SettleCadence: Sendable {
    private let interval: TimeInterval
    private var heard: TimeInterval = 0

    /// A cadence of zero settles on every buffer, so it is refused. The message
    /// is left off deliberately: an unmet one runs an autoclosure no test in
    /// this process reaches, and this layer is held to every line being run.
    public init(every seconds: TimeInterval) {
        precondition(seconds > 0)
        interval = seconds
    }

    /// Whether the audio heard since the last settle now reaches the interval.
    ///
    /// What is left over carries into the next interval rather than resetting to
    /// zero, which would drift by most of a buffer every time. A buffer whose
    /// rate cannot produce a length is no audio at all, so it settles nothing:
    /// a track that has gone quiet must not be asked for finals it would answer
    /// with punctuation.
    public mutating func admitting(_ audio: CapturedAudio) -> Bool {
        guard audio.sampleRate > 0 else { return false }
        heard += Double(audio.frames) / audio.sampleRate
        guard heard >= interval else { return false }
        heard -= interval
        return true
    }
}
