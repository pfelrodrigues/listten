import Foundation
import Testing

@testable import ListtenCore

private let rate: Double = 16000

private func audio(
    at hostTime: TimeInterval,
    seconds: TimeInterval = 1
) -> CapturedAudio {
    CapturedAudio(
        hostTime: hostTime,
        sampleRate: rate,
        samples: Array(repeating: 0.25, count: Int(rate * seconds))
    )
}

@Test("audio inside the window is all still there")
func audioInsideTheWindowIsKept() {
    var ring = PreRoll(window: 60)

    for second in 0..<3 {
        ring.append(audio(at: Double(second)), to: .microphone)
    }

    #expect(ring.draining().map(\.audio.hostTime) == [0, 1, 2])
}

@Test("audio older than the window is dropped as newer audio arrives")
func audioOlderThanTheWindowIsDropped() {
    var ring = PreRoll(window: 10)

    for second in 0...20 {
        ring.append(audio(at: Double(second)), to: .microphone)
    }

    // The newest stamp is 20 and the window is 10, so 10 is the oldest kept.
    #expect(ring.draining().map(\.audio.hostTime) == Array(stride(from: 10.0, through: 20, by: 1)))
}

/// A ring that grows is not a ring: what it holds has to plateau however long
/// the app runs, since nothing drains it until the user answers.
@Test("what the ring holds plateaus rather than growing with the meeting")
func whatTheRingHoldsPlateaus() {
    var ring = PreRoll(window: 60)
    var afterTwoMinutes = 0

    for buffer in 0..<1200 {
        let stamp = Double(buffer) * 0.5
        ring.append(audio(at: stamp, seconds: 0.5), to: .microphone)
        ring.append(audio(at: stamp, seconds: 0.5), to: .system)
        if stamp == 120 { afterTwoMinutes = ring.frames }
    }

    #expect(afterTwoMinutes > 0, "nothing was held two minutes in")
    #expect(ring.frames == afterTwoMinutes, "ten minutes in it holds more than it did at two")
    // The window plus the one buffer that carries its edge, on both tracks.
    #expect(ring.frames <= Int(2 * (60 + 0.5) * rate))
}

@Test("draining hands both tracks over oldest first, ties broken by track")
func drainingMergesBothTracksOldestFirst() {
    var ring = PreRoll(window: 60)

    ring.append(audio(at: 1), to: .system)
    ring.append(audio(at: 0), to: .microphone)
    ring.append(audio(at: 1), to: .microphone)
    ring.append(audio(at: 0.5), to: .system)

    #expect(
        ring.draining() == [
            PreRoll.Held(track: .microphone, audio: audio(at: 0)),
            PreRoll.Held(track: .system, audio: audio(at: 0.5)),
            PreRoll.Held(track: .microphone, audio: audio(at: 1)),
            PreRoll.Held(track: .system, audio: audio(at: 1)),
        ]
    )
}

@Test("draining empties the ring, so the same audio is never handed over twice")
func drainingEmptiesTheRing() {
    var ring = PreRoll(window: 60)
    ring.append(audio(at: 0), to: .microphone)

    _ = ring.draining()

    #expect(ring.frames == 0)
    #expect(ring.draining().isEmpty)
}

/// One horizon for both tracks. A tap that goes quiet stops delivering, and a
/// window measured per track would leave its last buffer in memory for the rest
/// of the meeting and anchor the drain at an instant an hour old.
@Test("a track that stopped delivering does not hold its stale audio open")
func aSilentTrackDoesNotHoldStaleAudio() {
    var ring = PreRoll(window: 10)
    ring.append(audio(at: 0), to: .system)

    for second in 1...20 {
        ring.append(audio(at: Double(second)), to: .microphone)
    }

    #expect(ring.draining().allSatisfy { $0.track == .microphone })
}
