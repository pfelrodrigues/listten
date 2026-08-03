import Foundation
import Testing

@testable import ListtenCore

private let grace = 3.0
private let tolerance = 2.0

private func detector() -> StallDetector {
    StallDetector(startedAt: 100, grace: grace, tolerance: tolerance)
}

@Test("a device that has not warmed up yet is not stalled")
func silenceInsideTheGraceIsNotAStall() {
    var subject = detector()

    #expect(subject.verdict(at: 102) == .running)
}

/// A device that never delivers a single buffer is the worst case: the session
/// believes it is recording and there is nothing to recover afterwards.
@Test("a device that never delivers anything is stalled once the grace runs out")
func silenceBeyondTheGraceIsAStall() {
    var subject = detector()

    #expect(subject.verdict(at: 104) == .stalled)
}

/// Starting a device costs more than keeping one running, so the first buffer
/// gets a longer rope than every buffer after it.
@Test("the wait for a first buffer is more generous than the wait for the next one")
func graceIsMoreGenerousThanTolerance() {
    var cold = detector()
    var warm = detector()
    warm.received(at: 100)

    #expect(cold.verdict(at: 102.5) == .running)
    #expect(warm.verdict(at: 102.5) == .stalled)
}

@Test("audio arriving keeps the detector quiet")
func recentAudioIsNotAStall() {
    var subject = detector()
    subject.received(at: 110)

    #expect(subject.verdict(at: 111) == .running)
}

@Test("audio that stops for longer than the tolerance is a stall")
func silenceAfterAudioIsAStall() {
    var subject = detector()
    subject.received(at: 110)

    #expect(subject.verdict(at: 113) == .stalled)
}

/// Reporting the same stall on every tick would restart the engine over and
/// over while it is still coming back up.
@Test("a stall is not reported again while the restart is still settling")
func aStallIsNotReportedWhileRecovering() {
    var subject = detector()
    subject.received(at: 110)

    #expect(subject.verdict(at: 113) == .stalled)
    #expect(subject.verdict(at: 114) == .waitingToRecover)
}

/// Giving up after one restart would leave a session recording nothing in
/// silence, which is the failure this whole thing exists to prevent.
@Test("a restart that did not bring audio back is tried again")
func aFailedRecoveryIsRetried() {
    var subject = detector()
    subject.received(at: 110)

    #expect(subject.verdict(at: 113) == .stalled)
    #expect(subject.verdict(at: 114) == .waitingToRecover)
    #expect(subject.verdict(at: 116) == .stalled)
    #expect(subject.verdict(at: 119) == .stalled)
}

@Test("audio returning after a restart arms the detector again")
func recoveryRearmsTheDetector() {
    var subject = detector()
    subject.received(at: 110)
    #expect(subject.verdict(at: 113) == .stalled)

    subject.received(at: 115)

    #expect(subject.verdict(at: 116) == .running)
    #expect(subject.verdict(at: 118) == .stalled)
}
