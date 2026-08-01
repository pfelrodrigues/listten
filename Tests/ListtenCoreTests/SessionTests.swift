import Foundation
import Testing

@testable import ListtenCore

@Test("a new session is armed and has recorded nothing")
func newSessionIsArmed() {
    let session = Session(id: "s1", startedAt: Date(timeIntervalSince1970: 0))

    #expect(session.state == .armed)
    #expect(session.segments.isEmpty)
    #expect(session.duration == 0)
}

@Test("an armed session refuses audio, because nothing may touch disk yet")
func armedSessionRefusesSegments() {
    let session = Session(id: "s1", startedAt: Date(timeIntervalSince1970: 0))

    #expect(throws: Session.RuleViolation.self) {
        try session.appending(Segment(index: 0, track: .microphone, start: 0, duration: 45))
    }
}

@Test("a recording session accepts audio and derives its duration")
func recordingSessionAccumulatesAudio() throws {
    var session = try Session(id: "s1", startedAt: .init(timeIntervalSince1970: 0))
        .applying(.confirm)

    session = try session.appending(Segment(index: 0, track: .microphone, start: 0, duration: 45))
    session = try session.appending(Segment(index: 1, track: .microphone, start: 45, duration: 30))

    #expect(session.segments.count == 2)
    #expect(session.duration == 75)
}

@Test("a finalized session refuses further audio")
func finalizedSessionRefusesAudio() throws {
    let session = try Session(id: "s1", startedAt: .init(timeIntervalSince1970: 0))
        .applying(.confirm)
        .applying(.stopRecording)

    #expect(throws: Session.RuleViolation.self) {
        try session.appending(Segment(index: 0, track: .microphone, start: 0, duration: 45))
    }
}

@Test("a recording shorter than the minimum is discarded when it stops")
func stoppingDiscardsWhatIsTooShort() throws {
    var session = try Session(id: "s1", startedAt: .init(timeIntervalSince1970: 0))
        .applying(.confirm)
    session = try session.appending(Segment(index: 0, track: .microphone, start: 0, duration: 20))

    #expect(try session.stopping(minimumDuration: 60).state == .discarded)
}

@Test("a recording that reaches the minimum moves on to processing when it stops")
func stoppingKeepsWhatIsLongEnough() throws {
    var session = try Session(id: "s1", startedAt: .init(timeIntervalSince1970: 0))
        .applying(.confirm)
    session = try session.appending(Segment(index: 0, track: .microphone, start: 0, duration: 90))

    #expect(try session.stopping(minimumDuration: 60).state == .recorded)
}

@Test("an invalid transition leaves the session untouched")
func invalidTransitionIsRefused() throws {
    let session = Session(id: "s1", startedAt: .init(timeIntervalSince1970: 0))

    #expect(throws: SessionState.TransitionError.self) {
        try session.applying(.complete)
    }
}

@Test("the duration of a session with two tracks spans the longer one")
func durationSpansBothTracks() throws {
    var session = try Session(id: "s1", startedAt: .init(timeIntervalSince1970: 0))
        .applying(.confirm)

    session = try session.appending(Segment(index: 0, track: .microphone, start: 0, duration: 20))
    session = try session.appending(Segment(index: 0, track: .system, start: 0, duration: 50))

    #expect(session.duration == 50)
}
