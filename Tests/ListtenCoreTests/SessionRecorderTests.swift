import Foundation
import Testing

@testable import ListtenCore

private func recorder(
    store: InMemorySessionStore = InMemorySessionStore(),
    progress: InMemoryProgressLog = InMemoryProgressLog(),
    prompt: RecordingPromptSpy = RecordingPromptSpy(),
    capture: @escaping SessionRecorder.CaptureFactory
) -> SessionRecorder {
    SessionRecorder(
        sessions: store,
        progress: progress,
        prompt: prompt,
        clock: FixedTimeSource(),
        minimumDuration: 1,
        capture: capture
    )
}

private func fakeCapture(
    length: TimeInterval,
    rotateEvery: TimeInterval
) -> SessionRecorder.CaptureFactory {
    { _ in FakeAudioCapture(length: length, rotateEvery: rotateEvery) }
}

@Test("a recorder that has done nothing is idle")
func aFreshRecorderIsIdle() async {
    let subject = recorder(capture: fakeCapture(length: 10, rotateEvery: 5))

    #expect(await subject.current() == .idle)
}

/// The distinction a status light cannot make on its own: recording carries what
/// it has, so a caller can tell audio still arriving from a light left on.
@Test("recording reports what it has so far, not merely that it is on")
func recordingReportsWhatItHas() async throws {
    let store = InMemorySessionStore()
    let subject = recorder(store: store, capture: fakeCapture(length: 10, rotateEvery: 5))

    await subject.start()
    await subject.stop()

    guard case .finished(let id, let outcome, let seconds) = await subject.current() else {
        Issue.record("expected a finished recording, got \(await subject.current())")
        return
    }
    #expect(outcome == .recorded)
    #expect(seconds == 10)
    #expect(try await store.load(id: id)?.segments.count == 4)
}

@Test("every closed segment is kept, with an intent and a completion around it")
func everySegmentIsKeptWithItsPair() async throws {
    let progress = InMemoryProgressLog()
    let subject = recorder(progress: progress, capture: fakeCapture(length: 10, rotateEvery: 5))

    await subject.start()
    await subject.stop()

    guard case .finished(let id, _, _) = await subject.current() else {
        Issue.record("expected a finished recording")
        return
    }
    // Two tracks close at 5 and at 10, so four steps, each with both ends.
    let ledger = try ProgressLedger(await progress.checkpoints(for: id))
    #expect(ledger.interrupted.isEmpty)
    #expect(ledger.finished.count == 4)
}

@Test("a second start while recording is ignored rather than starting another")
func startingTwiceKeepsTheFirstRecording() async throws {
    let store = InMemorySessionStore()
    let subject = recorder(store: store, capture: fakeCapture(length: 10, rotateEvery: 5))

    await subject.start()
    let first = await subject.current()
    await subject.start()

    #expect(await subject.current() == first)
    #expect(try await store.unfinished().sessions.count == 1)
}

@Test("stopping something that never started does nothing")
func stoppingWhenIdleDoesNothing() async {
    let subject = recorder(capture: fakeCapture(length: 10, rotateEvery: 5))

    await subject.stop()

    #expect(await subject.current() == .idle)
}

/// The recording is short enough that the domain refuses it. The recorder still
/// reports what happened rather than reporting success.
@Test("a recording too short to be a meeting is reported as discarded")
func aRecordingTooShortIsReportedDiscarded() async {
    let subject = recorder(capture: fakeCapture(length: 0.4, rotateEvery: 5))

    await subject.start()
    await subject.stop()

    guard case .finished(_, let outcome, _) = await subject.current() else {
        Issue.record("expected a finished recording")
        return
    }
    #expect(outcome == .discarded)
}

@Test("a capture that refuses to start is named, not swallowed")
func aRefusedCaptureIsNamed() async {
    struct Refused: Error {}
    let subject = recorder(capture: { _ in throw Refused() })

    await subject.start()

    guard case .failed(let reason) = await subject.current() else {
        Issue.record("expected a failure, got \(await subject.current())")
        return
    }
    #expect(reason.contains("Refused"))
}

/// The prompt failing means nobody was asked, so there is no recording to hold.
@Test("a prompt that cannot be delivered stops the recording before it starts")
func anUndeliverablePromptStopsTheStart() async {
    let subject = recorder(
        prompt: RecordingPromptSpy(failure: PromptUndeliverable()),
        capture: fakeCapture(length: 10, rotateEvery: 5)
    )

    await subject.start()

    guard case .failed = await subject.current() else {
        Issue.record("expected a failure, got \(await subject.current())")
        return
    }
}

@Test("a recording can be started again after one finished")
func aSecondRecordingCanFollowTheFirst() async throws {
    let store = InMemorySessionStore()
    let subject = recorder(store: store, capture: fakeCapture(length: 10, rotateEvery: 5))

    await subject.start()
    await subject.stop()
    await subject.start()
    await subject.stop()

    guard case .finished(let second, _, _) = await subject.current() else {
        Issue.record("expected a second finished recording")
        return
    }
    // Both are recorded rather than gone: recorded is not terminal, it is where
    // a session waits for the pipeline that has not been built yet.
    let everything = try await store.unfinished()
    #expect(everything.sessions.count == 2)
    #expect(everything.sessions.allSatisfy { $0.state == .recorded })
    #expect(try await store.load(id: second)?.state == .recorded)
}

/// The audio is already on disk and recovery reads the directory, so a segment
/// that cannot be written into the session is not the end of the recording. It
/// still has to surface: a session quietly missing a minute is the failure this
/// design is against.
@Test("a segment that cannot be kept is reported rather than passed over")
func aSegmentThatCannotBeKeptIsReported() async {
    let subject = SessionRecorder(
        sessions: StoreThatRefusesToSave(),
        progress: InMemoryProgressLog(),
        prompt: RecordingPromptSpy(),
        clock: FixedTimeSource(),
        minimumDuration: 1,
        capture: fakeCapture(length: 10, rotateEvery: 5)
    )

    await subject.start()
    await subject.stop()

    guard case .failed(let reason) = await subject.current() else {
        Issue.record("expected a failure, got \(await subject.current())")
        return
    }
    #expect(reason.contains("could not be kept") || reason.contains("Refused"))
}

/// What the menu bar reads while a meeting is happening. Every other test stops
/// first, so the pump only ever runs against a recorder already finishing, and
/// the reporting that matters mid-recording goes unexercised.
@Test("segments are reported while the recording is still running")
func progressIsReportedDuringRecording() async {
    let subject = recorder(capture: fakeCapture(length: 10, rotateEvery: 5))
    await subject.start()

    // Yielding rather than sleeping: the pump only needs turns, and a bounded
    // loop that gives up is a test that fails rather than one that hangs.
    var reported: SessionRecorder.State = .idle
    for _ in 0..<1000 {
        reported = await subject.current()
        if case .recording(let segments, _) = reported, segments > 0 { break }
        await Task.yield()
    }

    guard case .recording(let segments, let seconds) = reported else {
        Issue.record("expected to still be recording, got \(reported)")
        return
    }
    #expect(segments > 0, "the recorder never reported a segment while recording")
    #expect(seconds > 0)
    await subject.stop()
}
