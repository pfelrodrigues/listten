import Testing

@testable import ListtenCore

@Test("a session starts armed, with nothing on disk yet")
func startsArmed() {
    #expect(SessionState.initial == .armed)
}

@Test("confirming an armed session starts recording")
func armedConfirmsIntoRecording() throws {
    #expect(try SessionState.armed.applying(.confirm) == .recording)
}

@Test("an ignored session is discarded without recording")
func armedCanBeDiscarded() throws {
    #expect(try SessionState.armed.applying(.discard) == .discarded)
}

@Test("recording cannot be confirmed again")
func recordingRejectsConfirm() {
    #expect(throws: SessionState.TransitionError.self) {
        try SessionState.recording.applying(.confirm)
    }
}

@Test("the happy path runs from armed to completed")
func happyPath() throws {
    var state = SessionState.initial
    for event in [
        SessionEvent.confirm, .stopRecording, .startTranscribing, .finishTranscribing,
        .startSummarizing, .complete,
    ] {
        state = try state.applying(event)
    }
    #expect(state == .completed)
}

@Test(
    "a session can be discarded up to the point where processing starts",
    arguments: [SessionState.armed, .recording, .recorded]
)
func discardableStates(state: SessionState) throws {
    #expect(try state.applying(.discard) == .discarded)
}

@Test(
    "processing states cannot be discarded, only failed",
    arguments: [SessionState.transcribing, .transcribed, .summarizing]
)
func processingStatesRejectDiscard(state: SessionState) throws {
    #expect(throws: SessionState.TransitionError.self) { try state.applying(.discard) }
    #expect(try state.applying(.fail) == .failed)
}

@Test("any state that is not terminal can fail")
func nonTerminalStatesCanFail() throws {
    for state in SessionState.allCases where !state.isTerminal {
        #expect(try state.applying(.fail) == .failed)
    }
}

@Test(
    "terminal states accept no further transition",
    arguments: [SessionState.completed, .discarded, .failed]
)
func terminalStatesAreFinal(state: SessionState) {
    #expect(state.isTerminal)
    for event in SessionEvent.allCases {
        #expect(throws: SessionState.TransitionError.self) { try state.applying(event) }
    }
}

@Test("the transition error carries what was attempted")
func transitionErrorIsDescriptive() {
    do {
        _ = try SessionState.completed.applying(.confirm)
        Issue.record("expected the transition to be refused")
    } catch let error as SessionState.TransitionError {
        #expect(error.from == .completed)
        #expect(error.event == .confirm)
    } catch {
        Issue.record("unexpected error: \(error)")
    }
}

@Test("audio is only written while recording")
func onlyRecordingWritesAudio() {
    for state in SessionState.allCases {
        #expect(state.acceptsAudio == (state == .recording))
    }
}
