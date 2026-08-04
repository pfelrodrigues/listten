import Foundation
import Testing

@testable import ListtenCore

private func mixed(_ channels: [[Float]]) -> [Float] {
    let frames = channels[0].count
    var out = [Float](repeating: .nan, count: frames)
    var storage = channels
    out.withUnsafeMutableBufferPointer { destination in
        var pointers = storage.indices.map { index in
            storage[index].withUnsafeMutableBufferPointer { $0.baseAddress! }
        }
        pointers.withUnsafeMutableBufferPointer { sources in
            ChannelMixdown.mix(
                sources.baseAddress!,
                channels: sources.count,
                frames: frames,
                into: destination.baseAddress!
            )
        }
    }
    return out
}

@Test("one channel comes through untouched")
func monoIsUnchanged() {
    #expect(mixed([[0.1, -0.2, 0.3]]) == [0.1, -0.2, 0.3])
}

/// Taking the first channel loses whatever landed on the others, which on a
/// device that puts the voice on the right is the whole recording.
@Test("two channels average, so a voice on either one survives")
func stereoAverages() {
    #expect(mixed([[0, 0, 0], [1, -1, 0.5]]) == [0.5, -0.5, 0.25])
}

@Test("more than two channels average too")
func manyChannelsAverage() {
    #expect(mixed([[1, 0], [1, 0], [1, 0], [1, 0]]) == [1, 0])
}

@Test("channels that cancel each other average to silence, not to one side")
func opposingChannelsCancel() {
    #expect(mixed([[1, 0.5], [-1, -0.5]]) == [0, 0])
}

/// A process tap delivers one buffer whose channels alternate sample by sample.
private func mixed(interleaved samples: [Float], channels: Int) -> [Float] {
    let frames = samples.count / channels
    var out = [Float](repeating: .nan, count: frames)
    var storage = samples
    out.withUnsafeMutableBufferPointer { destination in
        storage.withUnsafeMutableBufferPointer { source in
            ChannelMixdown.mix(
                interleaved: source.baseAddress!,
                channels: channels,
                frames: frames,
                into: destination.baseAddress!
            )
        }
    }
    return out
}

@Test("one interleaved channel comes through untouched")
func interleavedMonoIsUnchanged() {
    #expect(mixed(interleaved: [0.1, -0.2, 0.3], channels: 1) == [0.1, -0.2, 0.3])
}

/// The whole reason this exists: read as if the channels were separate, the
/// first half of the buffer would become the recording and the rest would be
/// thrown away. That plays and transcribes as nonsense rather than failing.
@Test("interleaved stereo averages each frame, not each half of the buffer")
func interleavedStereoAveragesByFrame() {
    // Frames are (0, 1), (0, -1), (0, 0.5): left silent, right carrying it all.
    #expect(mixed(interleaved: [0, 1, 0, -1, 0, 0.5], channels: 2) == [0.5, -0.5, 0.25])
}

@Test("more than two interleaved channels average too")
func interleavedManyChannelsAverage() {
    #expect(mixed(interleaved: [1, 1, 1, 1, 0, 0, 0, 0], channels: 4) == [1, 0])
}

/// The tap's own layout: stereo at 48kHz. A frame count that does not divide
/// the buffer evenly would read past the end, so the caller derives it.
@Test("interleaved channels that cancel each other average to silence")
func interleavedOpposingChannelsCancel() {
    #expect(mixed(interleaved: [1, -1, 0.5, -0.5], channels: 2) == [0, 0])
}
