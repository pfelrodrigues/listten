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
