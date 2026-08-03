import Testing

@testable import ListtenCore

private let chunk = PipelineStep.transcribingChunk(index: 0)
private let other = PipelineStep.transcribingChunk(index: 1)
private let segment = PipelineStep.closingSegment(track: .microphone, index: 0)

@Test("a log nobody wrote to leaves nothing to redo")
func emptyLogHasNothingToRedo() throws {
    let ledger = try ProgressLedger([])

    #expect(ledger.interrupted.isEmpty)
    #expect(ledger.finished.isEmpty)
}

/// The case the whole thing exists for: the process died between the two
/// entries, and the state alone cannot say whether the step ran.
@Test("an intent with no completion is a step that was interrupted")
func intentWithoutCompletionIsInterrupted() throws {
    let ledger = try ProgressLedger([.intent(chunk)])

    #expect(ledger.interrupted == [chunk])
    #expect(ledger.finished.isEmpty)
}

@Test("a step with both ends is finished, and never redone")
func intentAndCompletionIsFinished() throws {
    let ledger = try ProgressLedger([.intent(chunk), .completion(chunk)])

    #expect(ledger.finished == [chunk])
    #expect(ledger.interrupted.isEmpty)
}

/// Nothing writes a completion except the step that declared the intent, so a
/// log holding one is a log to disbelieve, not one to read around.
@Test("a completion nobody intended is a broken log, and it says which step")
func completionWithoutIntentIsBroken() throws {
    #expect(throws: ProgressLedger.BrokenLog(completionWithoutIntent: chunk)) {
        try ProgressLedger([.intent(other), .completion(other), .completion(chunk)])
    }
}

/// A completion consumes its intent, so the second one has none left to match.
@Test("a step completed twice on one intent is broken too")
func secondCompletionOnOneIntentIsBroken() throws {
    #expect(throws: ProgressLedger.BrokenLog(completionWithoutIntent: chunk)) {
        try ProgressLedger([.intent(chunk), .completion(chunk), .completion(chunk)])
    }
}

/// A redo declares its intent again, so a second one is the normal shape of a
/// step interrupted twice, not corruption. What it must not do is ask for the
/// same work twice over.
@Test("two intents for one step leave it interrupted once, not twice")
func repeatedIntentIsListedOnce() throws {
    let ledger = try ProgressLedger([.intent(chunk), .intent(chunk)])

    #expect(ledger.interrupted == [chunk])
}

/// The redo of a finished step: run again, it goes back to being in flight, and
/// a recovery that still called it finished would skip the work it just lost.
@Test("a step intended again after it finished is in flight again")
func intentAfterCompletionIsInterruptedAgain() throws {
    let ledger = try ProgressLedger([.intent(chunk), .completion(chunk), .intent(chunk)])

    #expect(ledger.interrupted == [chunk])
    #expect(ledger.finished.isEmpty)
}

/// Redoing a step to the end lands where one clean run lands: the pair replaces
/// the pair before it rather than accumulating.
@Test("a step redone to completion is finished once")
func redoneStepIsFinishedOnce() throws {
    let ledger = try ProgressLedger([
        .intent(chunk), .completion(chunk), .intent(chunk), .completion(chunk),
    ])

    #expect(ledger.finished == [chunk])
    #expect(ledger.interrupted.isEmpty)
}

/// Steps from two stages interleave, so the pairing is per step and the order
/// is the log's: recovery redoes what was interrupted first, first.
@Test("interleaved steps are matched to their own ends, in the order intended")
func interleavedStepsAreMatchedIndependently() throws {
    let ledger = try ProgressLedger([
        .intent(segment), .intent(chunk), .completion(chunk), .intent(other),
    ])

    #expect(ledger.interrupted == [segment, other])
    #expect(ledger.finished == [chunk])
}
