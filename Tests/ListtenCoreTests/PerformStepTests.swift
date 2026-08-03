import Foundation
import Testing

@testable import ListtenCore

private let step = PipelineStep.transcribingChunk(index: 2)

private struct Boom: Error, Equatable {}

/// A log that refuses every append, standing for a full disk or a session
/// directory that is no longer there.
private actor RefusingProgressLog: ProgressLogging {
    func append(_ checkpoint: Checkpoint, for sessionID: String) async throws {
        throw Boom()
    }

    func checkpoints(for sessionID: String) async throws -> [Checkpoint] {
        []
    }
}

/// Work that can be run twice without doubling anything: it writes what it was
/// given and counts how often it was asked. Redo is only safe for work shaped
/// like this, and the count is what proves the redo really ran.
private actor TranscribedChunk {
    private(set) var text = ""
    private(set) var runs = 0

    func transcribe(_ heard: String) {
        text = heard
        runs += 1
    }
}

/// The order is the whole point: work that ran before its intent reached the log
/// is work a crash hides completely.
@Test("the intent is readable before the work runs")
func intentIsWrittenBeforeTheWork() async throws {
    let progress = InMemoryProgressLog()

    let duringWork = try await PerformStep(progress: progress)(step, of: "s1") {
        try await progress.checkpoints(for: "s1")
    }

    #expect(duringWork == [.intent(step)])
}

@Test("a step that returned is finished, and its result is the caller's")
func completedStepIsFinished() async throws {
    let progress = InMemoryProgressLog()

    let result = try await PerformStep(progress: progress)(step, of: "s1") { 41 + 1 }

    #expect(result == 42)
    let ledger = try ProgressLedger(await progress.checkpoints(for: "s1"))
    #expect(ledger.finished == [step])
    #expect(ledger.interrupted.isEmpty)
}

/// Work that threw is work that did not finish, so the step reads exactly like
/// one a crash cut short: the next run redoes it.
@Test("work that threw leaves the step interrupted, and the failure reaches the caller")
func failedWorkLeavesTheStepInterrupted() async throws {
    let progress = InMemoryProgressLog()

    await #expect(throws: Boom()) {
        try await PerformStep(progress: progress)(step, of: "s1") { throw Boom() }
    }

    let ledger = try ProgressLedger(await progress.checkpoints(for: "s1"))
    #expect(ledger.interrupted == [step])
    #expect(ledger.finished.isEmpty)
}

/// Work done behind an intent that never landed is work no recovery can see, so
/// the step does not start at all.
@Test("an intent that cannot be written stops the step from running")
func refusedIntentStopsTheWork() async throws {
    let chunk = TranscribedChunk()

    await #expect(throws: Boom()) {
        try await PerformStep(progress: RefusingProgressLog())(step, of: "s1") {
            await chunk.transcribe("never heard")
        }
    }

    #expect(await chunk.runs == 0)
}

/// The redo of a step interrupted once: it runs a second time, which is the
/// point, and what it leaves behind is what one run leaves behind. The ledger
/// answers for the same thing on its side, holding one finished step rather
/// than a pair for every attempt.
@Test("a redone step runs again and lands where a single run would have")
func redoneStepIsIdempotent() async throws {
    let progress = InMemoryProgressLog()
    let chunk = TranscribedChunk()
    let perform = PerformStep(progress: progress)

    // The interrupted attempt, then the redo the ledger below asks for.
    await #expect(throws: Boom()) {
        try await perform(step, of: "s1") {
            await chunk.transcribe("the meeting")
            throw Boom()
        }
    }
    #expect(try ProgressLedger(await progress.checkpoints(for: "s1")).interrupted == [step])

    try await perform(step, of: "s1") { await chunk.transcribe("the meeting") }

    #expect(await chunk.runs == 2)
    #expect(await chunk.text == "the meeting")
    let ledger = try ProgressLedger(await progress.checkpoints(for: "s1"))
    #expect(ledger.finished == [step])
    #expect(ledger.interrupted.isEmpty)
}
