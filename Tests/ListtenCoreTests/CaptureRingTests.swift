import Foundation
import Testing

@testable import ListtenCore

private func write(_ ring: CaptureRing, _ samples: [Float], hostTime: TimeInterval) -> Bool {
    samples.withUnsafeBufferPointer { buffer in
        ring.write(
            samples: buffer.baseAddress!,
            frames: buffer.count,
            hostTime: hostTime,
            sampleRate: 48000
        )
    }
}

@Test("audio comes back out exactly as it went in")
func writtenAudioReadsBackUnchanged() {
    let ring = CaptureRing(slots: 4, framesPerSlot: 8)

    #expect(write(ring, [0.1, -0.2, 0.3], hostTime: 1000))

    let audio = ring.read()
    #expect(audio?.samples == [0.1, -0.2, 0.3])
    #expect(audio?.hostTime == 1000)
    #expect(audio?.sampleRate == 48000)
}

@Test("an empty ring has nothing to hand over")
func emptyRingReadsNil() {
    #expect(CaptureRing(slots: 4, framesPerSlot: 8).read() == nil)
}

/// Dropping is the only honest answer on a thread that may not allocate or
/// wait. What matters is that it is counted rather than silent.
@Test("a full ring drops the newest audio and counts it, and keeps working after")
func fullRingDropsAndCounts() {
    let ring = CaptureRing(slots: 2, framesPerSlot: 8)

    #expect(write(ring, [1], hostTime: 1))
    #expect(write(ring, [2], hostTime: 2))
    #expect(!write(ring, [3], hostTime: 3))
    #expect(ring.dropped == 1)

    #expect(ring.read()?.samples == [1])
    #expect(write(ring, [4], hostTime: 4))
    #expect(ring.read()?.samples == [2])
    #expect(ring.read()?.samples == [4])
    #expect(ring.dropped == 1)
}

@Test("indices wrap, so a long recording reuses the same memory")
func indicesWrapAround() {
    let ring = CaptureRing(slots: 2, framesPerSlot: 8)

    for round in 0..<20 {
        #expect(write(ring, [Float(round)], hostTime: TimeInterval(round)))
        #expect(ring.read()?.samples == [Float(round)])
    }
    #expect(ring.dropped == 0)
}

/// A device delivering more than the slot was sized for must be visible, not
/// written past the end of the slab.
@Test("a buffer larger than a slot is refused and counted")
func oversizedBufferIsRefused() {
    let ring = CaptureRing(slots: 2, framesPerSlot: 2)

    #expect(!write(ring, [1, 2, 3], hostTime: 1))
    #expect(ring.dropped == 1)
    #expect(ring.read() == nil)
}
