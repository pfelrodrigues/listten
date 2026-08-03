import Foundation

/// Folds a device's channels into the one channel everything downstream wants.
///
/// Speech recognition works on mono and the storage budget assumes it, but
/// taking the first channel and discarding the rest loses whatever landed on
/// the others — on a device that puts the voice on the right, that is the whole
/// recording. Averaging keeps it wherever it arrived.
///
/// Written against raw pointers because this runs on the audio thread, where a
/// Swift array would allocate.
enum ChannelMixdown {
    static func mix(
        _ channels: UnsafePointer<UnsafeMutablePointer<Float>>,
        channels count: Int,
        frames: Int,
        into destination: UnsafeMutablePointer<Float>
    ) {
        guard count > 1 else {
            destination.update(from: channels[0], count: frames)
            return
        }

        let scale = 1 / Float(count)
        for frame in 0..<frames {
            var sum: Float = 0
            for channel in 0..<count {
                sum += channels[channel][frame]
            }
            destination[frame] = sum * scale
        }
    }
}

/// Owns the buffer the tap folds into, so it is allocated once and freed once.
/// A class because an actor's deinit cannot touch a raw pointer, and unchecked
/// because only the audio thread ever writes it.
final class MonoScratch: @unchecked Sendable {
    let samples: UnsafeMutablePointer<Float>

    init(frames: Int) {
        samples = .allocate(capacity: frames)
        samples.initialize(repeating: 0, count: frames)
    }

    deinit {
        samples.deallocate()
    }
}
