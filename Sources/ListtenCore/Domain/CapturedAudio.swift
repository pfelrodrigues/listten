import Foundation

/// One buffer as it left the audio device, before anything decides where it
/// belongs. `hostTime` is on the machine clock shared by both tracks.
public struct CapturedAudio: Sendable, Equatable {
    public let hostTime: TimeInterval
    public let sampleRate: Double
    public let samples: [Float]

    public init(hostTime: TimeInterval, sampleRate: Double, samples: [Float]) {
        self.hostTime = hostTime
        self.sampleRate = sampleRate
        self.samples = samples
    }

    public var frames: Int { samples.count }

    /// Loudest sample in the buffer, which is how a smoke test tells real audio
    /// from a device that is connected but delivering silence.
    public var peak: Float { samples.map(abs).max() ?? 0 }
}
