import Testing

@testable import ListtenCore

@Test("a buffer knows how many frames it holds")
func bufferCountsItsFrames() {
    let audio = CapturedAudio(hostTime: 0, sampleRate: 48000, samples: [0.1, -0.2, 0.3])

    #expect(audio.frames == 3)
}

/// A device that is connected but delivering nothing looks identical to a
/// working one until you look at the level.
@Test("peak level ignores sign, so a loud negative sample counts")
func peakIgnoresSign() {
    let audio = CapturedAudio(hostTime: 0, sampleRate: 48000, samples: [0.1, -0.9, 0.3])

    #expect(audio.peak == 0.9)
}

@Test("silence peaks at zero, and so does an empty buffer")
func silenceAndEmptinessPeakAtZero() {
    #expect(CapturedAudio(hostTime: 0, sampleRate: 48000, samples: [0, 0]).peak == 0)
    #expect(CapturedAudio(hostTime: 0, sampleRate: 48000, samples: []).peak == 0)
}
