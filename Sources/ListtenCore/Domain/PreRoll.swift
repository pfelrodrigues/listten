import Foundation

/// The last minute of both tracks, held in memory while the user is deciding.
///
/// Opt-in recording asks after the meeting has started, so the answer arrives
/// with the opening already spoken. This holds that opening until there is
/// somewhere to put it, and hands it over in one piece when there is.
///
/// What it holds plateaus: every buffer stamped further back than the window
/// goes as newer audio arrives, so the app running all day costs what a minute
/// costs. That is `window` seconds of both tracks, plus the one buffer carrying
/// the window's edge, at four bytes a sample: a minute of two 16 kHz tracks is
/// about 7.7 MB in the `Float` samples a device delivers.
///
/// The horizon is one instant for both tracks rather than one each. A tap that
/// goes quiet stops delivering, and a window measured per track would keep its
/// last buffer for the rest of the meeting and anchor the drain at it.
public struct PreRoll: Sendable {
    /// One buffer and the track it came from, since a drain interleaves both.
    public struct Held: Sendable, Equatable {
        public let track: Track
        public let audio: CapturedAudio

        public init(track: Track, audio: CapturedAudio) {
            self.track = track
            self.audio = audio
        }
    }

    private let window: TimeInterval
    private var held: [Track: [CapturedAudio]] = [:]
    private var newest: TimeInterval = 0

    /// `window` has to be positive; a window of zero holds nothing to drain.
    /// The only thing that builds one of these validates it, which keeps a
    /// branch no test can reach out of the domain.
    public init(window: TimeInterval) {
        self.window = window
    }

    /// Frames held across both tracks. A count that keeps climbing is the ring
    /// failing to be one.
    public var frames: Int {
        held.values.flatMap { $0 }.reduce(0) { $0 + $1.frames }
    }

    public mutating func append(_ audio: CapturedAudio, to track: Track) {
        held[track, default: []].append(audio)
        newest = max(newest, audio.hostTime)

        // A buffer is dropped whole, so the ring reaches back slightly further
        // than the window rather than handing over half of one.
        let horizon = newest - window
        held = held.mapValues { Array($0.drop { $0.hostTime < horizon }) }
    }

    /// Everything held, oldest first, and the ring is empty afterwards: the
    /// opening reaches disk once. Ties are broken by track rather than left to
    /// the sort, which Swift does not promise to be stable.
    public mutating func draining() -> [Held] {
        let drained =
            held
            .flatMap { track, buffers in buffers.map { Held(track: track, audio: $0) } }
            .sorted {
                ($0.audio.hostTime, $0.track.rawValue) < ($1.audio.hostTime, $1.track.rawValue)
            }
        held = [:]
        return drained
    }
}
