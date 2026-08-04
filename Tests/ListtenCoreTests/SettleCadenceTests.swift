import Foundation
import Testing

@testable import ListtenCore

private let rate = 16000.0

/// Buffer lengths here are exact in binary, so what a test asserts is the
/// cadence rather than how fifty tenths of a second add up in a Double.
private func buffer(seconds: TimeInterval) -> CapturedAudio {
    CapturedAudio(
        hostTime: 1000,
        sampleRate: rate,
        samples: Array(repeating: 0.1, count: Int(seconds * rate))
    )
}

@Test("audio short of the interval settles nothing")
func audioShortOfTheIntervalSettlesNothing() {
    var subject = SettleCadence(every: 5)

    let settled = (0..<9).map { _ in subject.admitting(buffer(seconds: 0.5)) }

    #expect(!settled.contains(true), "4.5 seconds of audio settled a 5 second cadence")
}

@Test("the buffer that carries the interval over settles")
func theBufferThatReachesTheIntervalSettles() {
    var subject = SettleCadence(every: 5)

    let settled = (0..<10).map { _ in subject.admitting(buffer(seconds: 0.5)) }

    #expect(settled == Array(repeating: false, count: 9) + [true])
}

/// Resetting to zero instead of carrying the leftover drifts by most of a buffer
/// every interval, which over an hour of meeting is minutes of cadence lost.
@Test("what is left over counts towards the next interval")
func leftoverCountsTowardsTheNextInterval() {
    var subject = SettleCadence(every: 2)

    // Three quarters of a second at a time: the intervals fall due after 2.25s,
    // 2.5s and 2.0s of audio, so where each one lands says whether the leftover
    // was carried.
    var settledOn: [Int] = []
    for tick in 0..<8 where subject.admitting(buffer(seconds: 0.75)) {
        settledOn.append(tick)
    }

    #expect(settledOn == [2, 5, 7])
}

/// A track whose device has gone quiet delivers nothing, so it asks for nothing:
/// settling silence produces a line holding only punctuation.
@Test("a buffer carrying no audio settles nothing")
func aBufferCarryingNoAudioSettlesNothing() {
    var subject = SettleCadence(every: 5)

    let settled = subject.admitting(buffer(seconds: 0))

    #expect(!settled)
}

/// The interval is tiny so that a rate of zero, left unguarded, would divide
/// into an infinity that clears any cadence at all.
@Test("a buffer whose rate cannot produce a length settles nothing")
func aBufferWithNoUsableRateSettlesNothing() {
    var subject = SettleCadence(every: 0.001)

    let settled = subject.admitting(
        CapturedAudio(hostTime: 1000, sampleRate: 0, samples: [0.1])
    )

    #expect(!settled)
}

@Test("a cadence of zero is refused, since it would settle on every buffer")
func aCadenceOfZeroIsRefused() async {
    await #expect(processExitsWith: .failure) {
        _ = SettleCadence(every: 0)
    }
}
