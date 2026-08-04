import Foundation
import Testing

@testable import ListtenCore

private let rate = 48000.0
private let tenthOfASecond = 4800

private func accumulator(rotateEvery: TimeInterval = 0.45) -> SegmentAccumulator {
    SegmentAccumulator(track: .microphone, anchor: 1000, rotateEvery: rotateEvery)
}

private func buffer(at hostTime: TimeInterval, frames: Int = tenthOfASecond) -> CapturedAudio {
    CapturedAudio(
        hostTime: hostTime,
        sampleRate: rate,
        samples: Array(repeating: 0.1, count: frames)
    )
}

@Test("audio under the rotation goes into the first file and closes nothing")
func audioUnderTheRotationClosesNothing() throws {
    var subject = accumulator()

    let first = try subject.placing(buffer(at: 1000))
    let second = try subject.placing(buffer(at: 1000.1))

    #expect(first.index == 0)
    #expect(second.index == 0)
    #expect(first.closed == nil)
    #expect(second.closed == nil)
}

/// A buffer is written whole, so a segment closes on the buffer that carries it
/// past the rotation rather than being split at the exact instant.
@Test("the buffer that carries the segment past the rotation closes it")
func theBufferThatCrossesTheRotationClosesTheSegment() throws {
    var subject = accumulator()

    var closed: Segment?
    for tick in 0..<5 {
        closed = try subject.placing(buffer(at: 1000 + Double(tick) / 10)).closed
    }

    let expected = try Segment(index: 0, track: .microphone, start: 0, duration: 0.5)
    #expect(closed == expected)
}

/// Anything following the same audio live reads its instant from here, so the
/// placement carries where the buffer sits rather than only which file it went
/// into. A second anchor derived elsewhere would have to be proven equal to this
/// one, and the two tracks line up only because there is one.
@Test("a placement says where on the session clock the buffer starts")
func aPlacementCarriesTheBuffersInstant() throws {
    var subject = accumulator()

    let first = try subject.placing(buffer(at: 1000))
    let afterAGap = try subject.placing(buffer(at: 1002.5))

    #expect(first.start == 0)
    #expect(abs(afterAGap.start - 2.5) < 0.001)
}

@Test("the next buffer after a rotation opens the next file")
func theNextBufferOpensTheNextFile() throws {
    var subject = accumulator()
    for tick in 0..<5 {
        _ = try subject.placing(buffer(at: 1000 + Double(tick) / 10))
    }

    let next = try subject.placing(buffer(at: 1000.5))

    #expect(next.index == 1)
    #expect(next.closed == nil)
}

/// Duration is the audio that arrived; position is the clock. A device swapped
/// mid-recording leaves a gap between segments rather than shifting them.
@Test("a gap between buffers moves the next segment, it does not stretch this one")
func aGapMovesTheNextSegmentRatherThanStretchingThisOne() throws {
    var subject = accumulator(rotateEvery: 0.2)

    _ = try subject.placing(buffer(at: 1000))
    let beforeGap = try subject.placing(buffer(at: 1000.1)).closed

    // Two seconds of nothing while the device is swapped.
    let reopened = try subject.placing(buffer(at: 1002.1))
    let afterGap = try subject.placing(buffer(at: 1002.2)).closed

    let expectedBeforeGap = try Segment(index: 0, track: .microphone, start: 0, duration: 0.2)
    #expect(beforeGap == expectedBeforeGap)
    #expect(reopened.index == 1)
    // Start moved by the whole gap; duration is still only the audio that came.
    // Compared with a tolerance because the start is a difference of clock
    // instants, which no exact decimal survives.
    #expect(afterGap?.index == 1)
    #expect(abs((afterGap?.start ?? 0) - 2.1) < 0.001)
    #expect(abs((afterGap?.duration ?? 0) - 0.2) < 0.001)
}

@Test("closing hands over the file still open, so stopping costs nothing")
func closingHandsOverTheOpenFile() throws {
    var subject = accumulator()
    _ = try subject.placing(buffer(at: 1000))
    _ = try subject.placing(buffer(at: 1000.1))

    let handedOver = try subject.closing()
    let expected = try Segment(index: 0, track: .microphone, start: 0, duration: 0.2)
    #expect(handedOver == expected)
}

@Test("closing an accumulator that took nothing hands over nothing")
func closingWithNothingOpenHandsOverNothing() throws {
    var subject = accumulator()

    #expect(try subject.closing() == nil)
}

@Test("closing twice does not hand the same file over again")
func closingTwiceHandsOverNothingTheSecondTime() throws {
    var subject = accumulator()
    _ = try subject.placing(buffer(at: 1000))

    #expect(try subject.closing() != nil)
    #expect(try subject.closing() == nil)
}

@Test("a buffer whose rate cannot produce a length is refused")
func unusableRateIsRefused() {
    var subject = accumulator()

    #expect(throws: CaptureTimeline.UnusableSampleRate.self) {
        try subject.placing(
            CapturedAudio(hostTime: 1000, sampleRate: 0, samples: [0.1])
        )
    }
}
