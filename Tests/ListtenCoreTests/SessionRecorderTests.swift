import Foundation
import Testing

@testable import ListtenCore

private let keptNote = URL(filePath: "/listten-tests/sessions/note.md")
private let deliveredNote = URL(filePath: "/listten-tests/notes/meeting.md")

/// Named rather than defaulted on the initializer: a default there would leave a
/// way of building a recorder that nothing exercises.
private let writesANote: SessionRecorder.ProcessingFactory = { _ in
    NoteLocation(kept: keptNote, delivered: deliveredNote)
}

private func recorder(
    store: any SessionStoring = InMemorySessionStore(),
    progress: InMemoryProgressLog = InMemoryProgressLog(),
    prompt: RecordingPromptSpy = RecordingPromptSpy(),
    capture: @escaping SessionRecorder.CaptureFactory,
    process: @escaping SessionRecorder.ProcessingFactory = writesANote
) -> SessionRecorder {
    SessionRecorder(
        sessions: store,
        progress: progress,
        prompt: prompt,
        clock: FixedTimeSource(),
        minimumDuration: 1,
        capture: capture,
        process: process
    )
}

private func fakeCapture(
    length: TimeInterval,
    rotateEvery: TimeInterval
) -> SessionRecorder.CaptureFactory {
    { _ in FakeAudioCapture(length: length, rotateEvery: rotateEvery) }
}

/// How many times the note was asked for, since some of these are about it not
/// being asked for at all.
private actor Attempts {
    private(set) var count = 0

    func next() -> Int {
        count += 1
        return count
    }
}

/// The note lands on a task of its own, so the state after stopping is reached
/// rather than returned. Yielding rather than sleeping, and bounded, so a
/// recorder that never settles fails this instead of hanging it.
private func settled(_ subject: SessionRecorder) async -> SessionRecorder.State {
    for _ in 0..<10_000 {
        let state = await subject.current()
        guard case .processing = state else { return state }
        await Task.yield()
    }
    return await subject.current()
}

@Test("a recorder that has done nothing is idle")
func aFreshRecorderIsIdle() async {
    let subject = recorder(capture: fakeCapture(length: 10, rotateEvery: 5))

    #expect(await subject.current() == .idle)
}

/// The whole of it: a meeting that stopped becomes a note without anybody asking
/// for one, and the recorder says where the note is rather than that it is done.
@Test("stopping a recording writes its note")
func stoppingWritesTheNote() async throws {
    let store = InMemorySessionStore()
    let subject = recorder(store: store, capture: fakeCapture(length: 10, rotateEvery: 5))

    await subject.start()
    await subject.stop()

    guard case .processed(let id, let note) = await settled(subject) else {
        Issue.record("expected a note, got \(await subject.current())")
        return
    }
    #expect(note == deliveredNote)
    #expect(try await store.load(id: id)?.segments.count == 4)
    #expect(try await store.load(id: id)?.duration == 10)
}

@Test("every closed segment is kept, with an intent and a completion around it")
func everySegmentIsKeptWithItsPair() async throws {
    let progress = InMemoryProgressLog()
    let subject = recorder(progress: progress, capture: fakeCapture(length: 10, rotateEvery: 5))

    await subject.start()
    await subject.stop()

    guard case .processed(let id, _) = await settled(subject) else {
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

    guard case .finished(let id, let outcome, let seconds) = await subject.current() else {
        Issue.record("expected a finished recording")
        return
    }
    #expect(outcome == .discarded)
    // The rest of the payload, which nothing else pins now that a recorded
    // session reaches .processed instead: a state naming the wrong session, or
    // no session, is what a caller would act on.
    #expect(!id.isEmpty)
    #expect(seconds == 0.4)
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

    guard case .processed(let second, _) = await settled(subject) else {
        Issue.record("expected a second finished recording")
        return
    }
    // Both are recorded rather than gone. Walking them on to completed belongs
    // to the pipeline, which is a closure here, so the store still holds what
    // the recording left.
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
        capture: fakeCapture(length: 10, rotateEvery: 5),
        process: writesANote
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
    _ = await settled(subject)
}

/// The pipeline refuses a discarded session, so asking it would report a failure
/// the user did nothing to cause and hide the one thing worth saying: the
/// recording was too short to be a meeting.
@Test("a recording too short to be a meeting is never written up")
func aDiscardedRecordingIsNotWrittenUp() async {
    let attempts = Attempts()
    let subject = recorder(
        capture: fakeCapture(length: 0.4, rotateEvery: 5),
        process: { _ in
            _ = await attempts.next()
            return NoteLocation(kept: keptNote, delivered: deliveredNote)
        }
    )

    await subject.start()
    await subject.stop()

    // Counted after the state settles rather than straight after stopping, so a
    // write-up that was asked for has had its turn to run before it is counted.
    let reached = await settled(subject)
    #expect(await attempts.count == 0)
    guard case .finished = reached else {
        Issue.record("expected a finished recording, got \(reached)")
        return
    }
}

/// Transcription is about forty seconds for an hour of meeting, measured, and
/// the menu reads the state every second. Stopping has to hand it back at once
/// or the menu sits on "Finishing…" for the whole run.
@Test("stopping hands the state back before the note is written")
func stoppingDoesNotWaitForTheNote() async throws {
    let gate = Gate()
    let subject = recorder(
        capture: fakeCapture(length: 10, rotateEvery: 5),
        process: { _ in
            await gate.wait()
            return NoteLocation(kept: keptNote, delivered: deliveredNote)
        }
    )

    await subject.start()

    // Released on a delay of its own rather than after the reading below, so a
    // recorder that awaited the note inside stop() finishes and fails this
    // instead of deadlocking it. Armed here rather than before the recording, so
    // the delay covers stopping and nothing else.
    let releaser = Task {
        try await Task.sleep(for: .milliseconds(200))
        await gate.open()
    }

    await subject.stop()
    let handedBack = await subject.current()
    try await releaser.value

    guard case .processing = handedBack else {
        Issue.record("stopping waited for the note: \(handedBack)")
        return
    }
    _ = await settled(subject)
}

/// Everything after the audio can be run again and the audio cannot, so the
/// meeting starting now wins. The note is still written to disk; what it loses
/// is the menu item pointing at it.
@Test("a recording started while a note is being written keeps the recording")
func aNewRecordingOutranksTheNoteBeingWritten() async {
    let gate = Gate()
    let written = Attempts()
    let subject = recorder(
        capture: fakeCapture(length: 10, rotateEvery: 5),
        process: { _ in
            await gate.wait()
            _ = await written.next()
            return NoteLocation(kept: keptNote, delivered: deliveredNote)
        }
    )

    await subject.start()
    await subject.stop()
    await subject.start()
    await gate.open()

    // Waited for rather than assumed: yielding alone would let this hold by
    // checking a note that never finished, which is the one way it could pass
    // for the wrong reason.
    for _ in 0..<10_000 {
        if await written.count > 0 { break }
        await Task.yield()
    }
    #expect(await written.count == 1, "the note never finished, so nothing was checked")

    // Turns enough for the finished note to overwrite the recording, if it were
    // going to.
    for _ in 0..<1000 { await Task.yield() }

    guard case .recording = await subject.current() else {
        Issue.record("the note overwrote a recording in progress: \(await subject.current())")
        return
    }
    await subject.stop()
    _ = await settled(subject)
}

/// Asking for a note over a running recording would move the recorder off
/// `.recording`, which is the only state stopping answers from, leaving a
/// capture nobody can end and the meeting in the room unfinishable.
@Test("asking for a note during a recording is ignored rather than ending it")
func aWriteUpDuringARecordingIsIgnored() async {
    let attempts = Attempts()
    let subject = recorder(
        capture: fakeCapture(length: 10, rotateEvery: 5),
        process: { _ in
            _ = await attempts.next()
            return NoteLocation(kept: keptNote, delivered: deliveredNote)
        }
    )

    await subject.start()
    await subject.process(id: "some-earlier-session")

    guard case .recording = await subject.current() else {
        Issue.record("the recording was displaced: \(await subject.current())")
        return
    }

    // Still stoppable, which is the thing the guard protects.
    await subject.stop()
    guard case .processed = await settled(subject) else {
        Issue.record("the recording could not be stopped: \(await subject.current())")
        return
    }
    #expect(await attempts.count == 1, "the displaced write-up ran anyway")
}

/// A failure carrying only a sentence leaves a retry with nothing to retry.
@Test("a write-up that failed names the session it failed on")
func aFailedWriteUpNamesItsSession() async throws {
    struct Refused: Error {}
    let store = InMemorySessionStore()
    let subject = recorder(
        store: store,
        capture: fakeCapture(length: 10, rotateEvery: 5),
        process: { _ in throw Refused() }
    )

    await subject.start()
    await subject.stop()

    guard case .processingFailed(let id, let reason) = await settled(subject) else {
        Issue.record("expected a failed write-up, got \(await subject.current())")
        return
    }
    #expect(reason.contains("Refused"))
    #expect(try await store.load(id: id) != nil, "the failure names a session nothing recorded")
}

/// The failure a user is most likely to meet, since the destination is the one
/// part of this that lives outside the app. Told the meeting was lost, they
/// would look for it in the one place it is not.
@Test("a note that could not be delivered says where it still is")
func anUndeliveredNoteSaysWhereItIs() async {
    struct Unmounted: Error {}
    let subject = recorder(
        capture: fakeCapture(length: 10, rotateEvery: 5),
        process: { _ in throw NoteNotDelivered(kept: keptNote, underlying: Unmounted()) }
    )

    await subject.start()
    await subject.stop()

    guard case .processingFailed(_, let reason) = await settled(subject) else {
        Issue.record("expected a failed write-up, got \(await subject.current())")
        return
    }
    #expect(reason.contains(keptNote.path))
    // The path alone is what Swift's reflection prints for any struct holding
    // one, so asking only for that would hold whether or not the error says
    // anything a reader can act on.
    #expect(reason.contains("could not be copied out"), "unreadable: \(reason)")
}

/// The pipeline reruns a session from its audio, so a retry is this and nothing
/// else: no second recording, and no partial state to clear first.
@Test("a write-up that failed runs again on demand")
func aFailedWriteUpRunsAgainOnDemand() async {
    struct Refused: Error {}
    let attempts = Attempts()
    let subject = recorder(
        capture: fakeCapture(length: 10, rotateEvery: 5),
        process: { _ in
            guard await attempts.next() > 1 else { throw Refused() }
            return NoteLocation(kept: keptNote, delivered: deliveredNote)
        }
    )

    await subject.start()
    await subject.stop()
    guard case .processingFailed(let id, _) = await settled(subject) else {
        Issue.record("expected a failed write-up, got \(await subject.current())")
        return
    }

    await subject.process(id: id)

    guard case .processed(let again, let note) = await settled(subject) else {
        Issue.record("expected a note on the second run, got \(await subject.current())")
        return
    }
    #expect(again == id)
    #expect(note == deliveredNote)
}

/// A failure that only lived in the current state would be lost to whatever
/// happened next, which for a recorder is the very next meeting. Losing it costs
/// a meeting its note with nothing said and no session left to run again.
@Test("a write-up that fails while the next meeting records is still reported")
func aFailedWriteUpSurvivesTheNextRecording() async {
    struct Refused: Error {}
    let released = Gate()
    let subject = recorder(
        capture: fakeCapture(length: 10, rotateEvery: 5),
        process: { _ in
            await released.wait()
            throw Refused()
        }
    )

    await subject.start()
    await subject.stop()
    let lost = await first(of: subject)

    // The next meeting takes the state over while the first is still settling.
    await subject.start()
    await released.open()

    // Waiting on the state would not do: the recording already took it, which
    // is the whole point of this test.
    var unwritten: [String: String] = [:]
    for _ in 0..<10_000 where unwritten[lost] == nil {
        unwritten = await subject.unwrittenNotes()
        await Task.yield()
    }
    #expect(unwritten[lost] != nil, "the failed write-up left nothing behind")
    #expect(unwritten[lost]?.contains("Refused") == true)
}

/// The state guard reads a value four suspension points do not reach until
/// later, so without a handle two clicks both arm a capture and the second
/// overwrites the first: a device nobody can stop, recording a meeting nothing
/// will finish.
@Test("two starts at once arm one recording, not two")
func concurrentStartsArmOneRecording() async {
    let armed = Attempts()
    let subject = recorder(capture: { id in
        _ = await armed.next()
        await Task.yield()
        return FakeAudioCapture(length: 10, rotateEvery: 5)
    })

    async let first: Void = subject.start()
    async let second: Void = subject.start()
    _ = await (first, second)

    let count = await armed.count
    #expect(count == 1, "armed \(count) captures")
}

/// Stopping and starting through one slow write-up used to spawn a pipeline per
/// stop, all over the same audio, with every result but one thrown away.
@Test("write-ups run one at a time, however often stopping asks for one")
func writeUpsDoNotPileUp() async {
    let running = Attempts()
    let overlapping = Overlap()
    let released = Gate()
    let subject = recorder(
        capture: fakeCapture(length: 10, rotateEvery: 5),
        process: { _ in
            await overlapping.entered()
            _ = await running.next()
            // Held until every stop has been asked for, so a queue shows one
            // inside and loose tasks show all three.
            await released.wait()
            await overlapping.left()
            return NoteLocation(kept: keptNote, delivered: deliveredNote)
        }
    )

    for _ in 0..<3 {
        await subject.start()
        await subject.stop()
    }
    await released.open()
    for _ in 0..<10_000 where await running.count < 3 {
        await Task.yield()
    }

    let ran = await running.count
    let most = await overlapping.most
    #expect(ran == 3, "ran \(ran) write-ups")
    #expect(most == 1, "\(most) ran at once")
}

/// How many ran at the same time, which is the whole question for a queue.
private actor Overlap {
    private var running = 0
    private(set) var most = 0

    func entered() {
        running += 1
        most = max(most, running)
    }

    func left() { running -= 1 }
}

/// The session a stop is settling, read before anything else takes the state.
private func first(of subject: SessionRecorder) async -> String {
    guard case .processing(let id) = await subject.current() else { return "" }
    return id
}

/// A segment that never reached the state file leaves audio the session does not
/// name, which recovery adopts and the pipeline refuses. Writing up anyway would
/// replace the real diagnosis with whatever the pipeline made of it, and offer a
/// retry that cannot work until recovery has run.
@Test("a recording that lost a segment is reported, not written up")
func aRecordingThatLostASegmentIsNotWrittenUp() async {
    let asked = Attempts()
    let subject = recorder(
        store: StoreThatRefusesOneSave(refusing: 3),
        capture: fakeCapture(length: 10, rotateEvery: 5),
        process: { _ in
            _ = await asked.next()
            return NoteLocation(kept: keptNote, delivered: deliveredNote)
        }
    )

    await subject.start()
    await subject.stop()

    guard case .failed(let reason) = await subject.current() else {
        Issue.record("expected a failure, got \(await subject.current())")
        return
    }
    #expect(reason.contains("segment could not be kept"), "reported \(reason)")
    #expect(await asked.count == 0, "a note was written from a session missing a segment")
}

/// Quitting during a write-up, or a crash, leaves a meeting recorded with no
/// note and nothing that ever looks at it again. The next launch has to find it.
@Test("a meeting left unwritten by a previous run is offered on the next one")
func anUnwrittenMeetingSurvivesARestart() async throws {
    let store = InMemorySessionStore()
    let stranded = try Session(id: "left-behind", startedAt: .init(timeIntervalSince1970: 0))
        .applying(.confirm)
        .appending(try Segment(index: 0, track: .microphone, start: 0, duration: 45))
        .applying(.stopRecording)
    try await store.save(stranded)
    // Halfway through the pipeline, which is where quitting leaves one.
    try await store.save(try stranded.applying(.startTranscribing))

    let subject = recorder(store: store, capture: fakeCapture(length: 10, rotateEvery: 5))
    await subject.writeUpWhatIsUnwritten()

    #expect(await subject.unwrittenNotes()["left-behind"] != nil)
}

/// A recording in progress belongs to recovery, not to this: adopting it as
/// unwritten would offer a note for a meeting still being held.
@Test("a session still recording is not offered as an unwritten note")
func aRecordingSessionIsNotOfferedAsUnwritten() async throws {
    let store = InMemorySessionStore()
    try await store.save(
        try Session(id: "in-progress", startedAt: .init(timeIntervalSince1970: 0))
            .applying(.confirm)
    )

    let subject = recorder(store: store, capture: fakeCapture(length: 10, rotateEvery: 5))
    await subject.writeUpWhatIsUnwritten()

    #expect(await subject.unwrittenNotes().isEmpty)
}

/// A sessions directory that will not read is worth saying out loud: the
/// meetings are there and nothing can find out what they are.
@Test("a store that cannot be listed is reported rather than passed over")
func anUnlistableStoreIsReported() async {
    let subject = recorder(
        store: StoreThatCannotBeListed(),
        capture: fakeCapture(length: 10, rotateEvery: 5)
    )

    await subject.writeUpWhatIsUnwritten()

    guard case .failed(let reason) = await subject.current() else {
        Issue.record("expected a failure, got \(await subject.current())")
        return
    }
    #expect(reason.contains("unwritten notes"))
}

/// Asked while a meeting is being recorded, which a launch cannot be but a
/// second call can. Adopting anything then would offer notes for a recording in
/// progress.
@Test("looking for unwritten notes does nothing while a recording runs")
func lookingForUnwrittenNotesIsIgnoredWhileRecording() async {
    let subject = recorder(capture: fakeCapture(length: 10, rotateEvery: 5))

    await subject.start()
    await subject.writeUpWhatIsUnwritten()

    #expect(await subject.unwrittenNotes().isEmpty)
    guard case .recording = await subject.current() else {
        Issue.record("the recording was disturbed: \(await subject.current())")
        return
    }
}
