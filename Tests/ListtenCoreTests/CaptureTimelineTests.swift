import Foundation
import Testing

@testable import ListtenCore

private let rate = 48000.0
private let oneSecond = 48000

@Test("the first buffer of a session starts at zero")
func firstBufferStartsAtZero() throws {
    let timeline = CaptureTimeline(anchor: 1000)

    let segment = try timeline.segment(
        index: 0,
        track: .microphone,
        hostTime: 1000,
        frames: oneSecond,
        sampleRate: rate
    )

    #expect(segment.start == 0)
    #expect(segment.duration == 1)
}

/// The acceptance criterion of #11: a device change must not break alignment.
@Test("audio after a device change keeps its place instead of closing the gap")
func aGapDoesNotPullLaterAudioEarlier() throws {
    let timeline = CaptureTimeline(anchor: 1000)

    let before = try timeline.segment(
        index: 0,
        track: .microphone,
        hostTime: 1000,
        frames: oneSecond,
        sampleRate: rate
    )
    // Two seconds pass while the device is swapped and no audio arrives.
    let after = try timeline.segment(
        index: 1,
        track: .microphone,
        hostTime: 1003,
        frames: oneSecond,
        sampleRate: rate
    )

    #expect(before.end == 1)
    #expect(after.start == 3)
    #expect(after.duration == 1)
}

@Test("both tracks anchored together place simultaneous audio at the same instant")
func tracksOnOneAnchorLineUp() throws {
    let timeline = CaptureTimeline(anchor: 1000)

    let mine = try timeline.segment(
        index: 0,
        track: .microphone,
        hostTime: 1007,
        frames: oneSecond,
        sampleRate: rate
    )
    let theirs = try timeline.segment(
        index: 0,
        track: .system,
        hostTime: 1007,
        frames: oneSecond,
        sampleRate: rate
    )

    #expect(mine.start == theirs.start)
}

@Test("a sample rate that cannot produce a length is refused")
func unusableSampleRateIsRefused() {
    let timeline = CaptureTimeline(anchor: 0)

    #expect(throws: CaptureTimeline.UnusableSampleRate.self) {
        try timeline.segment(
            index: 0,
            track: .microphone,
            hostTime: 0,
            frames: oneSecond,
            sampleRate: 0
        )
    }
}

@Test("audio stamped before the session began is refused rather than placed at a negative instant")
func audioBeforeTheAnchorIsRefused() {
    let timeline = CaptureTimeline(anchor: 1000)

    #expect(throws: CaptureTimeline.AudioBeforeTheAnchor.self) {
        try timeline.segment(
            index: 0,
            track: .microphone,
            hostTime: 999,
            frames: oneSecond,
            sampleRate: rate
        )
    }
}
