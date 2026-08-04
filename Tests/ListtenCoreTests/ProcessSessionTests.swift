import Foundation
import Testing

@testable import ListtenCore

private let language = "pt-BR"

private func recordedSession(
    id: String = "s1",
    segments: [Segment]
) throws -> Session {
    var session = try Session(id: id, startedAt: .init(timeIntervalSince1970: 0))
        .applying(.confirm)
    for segment in segments {
        session = try session.appending(segment)
    }
    return try session.applying(.stopRecording)
}

private func segment(
    _ track: Track,
    _ index: Int,
    start: TimeInterval,
    _ duration: TimeInterval
)
    throws -> Segment
{
    try Segment(index: index, track: track, start: start, duration: duration)
}

private func file(_ track: Track, _ index: Int, _ duration: TimeInterval) -> SegmentFile {
    SegmentFile(
        track: track,
        index: index,
        duration: duration,
        url: URL(filePath: "/memory/\(track.rawValue)-\(index).caf")
    )
}

private func keptNote(_ id: String) -> URL {
    URL(filePath: "/memory/sessions").appending(path: id).appending(path: "note.md")
}

private struct Wired {
    let process: ProcessSession
    let store: InMemorySessionStore
    let progress: InMemoryProgressLog
    let transcripts: InMemoryTranscripts
    let notes: InMemoryNoteWriter
}

private func wire(
    session: Session,
    files: [SegmentFile],
    glossary: Glossary = Glossary(entries: []),
    transcriber: any Transcribing = FakeTranscriber()
) async throws -> Wired {
    let store = InMemorySessionStore()
    try await store.save(session)
    let progress = InMemoryProgressLog()
    let transcripts = InMemoryTranscripts()
    let notes = InMemoryNoteWriter()

    return Wired(
        process: ProcessSession(
            sessions: store,
            progress: progress,
            audio: FakeRecordedAudio(segments: [session.id: files]),
            transcripts: transcripts,
            transcriber: transcriber,
            notes: notes,
            glossary: glossary,
            language: language
        ),
        store: store,
        progress: progress,
        transcripts: transcripts,
        notes: notes
    )
}

@Test("a recorded session comes out completed, with a note")
func aRecordedSessionBecomesANote() async throws {
    let session = try recordedSession(segments: [try segment(.microphone, 0, start: 0, 45)])
    let wired = try await wire(session: session, files: [file(.microphone, 0, 45)])

    let location = try await wired.process(sessionID: session.id)

    #expect(try await wired.store.load(id: session.id)?.state == .completed)
    let kept = try #require(await wired.notes.contents(of: keptNote(session.id)))
    #expect(kept.contains(session.id), "the note does not name its meeting")
    #expect(location.delivered.lastPathComponent.hasSuffix(".md"))
}

/// The constraint the design turns on: the raw transcript survives whatever
/// correction made of it, so a glossary entry that was wrong is recoverable.
@Test("both transcripts are kept, not just the corrected one")
func bothTranscriptsAreKept() async throws {
    let session = try recordedSession(segments: [try segment(.microphone, 0, start: 0, 45)])
    // A glossary that actually changes the words, so the two transcripts differ.
    // Comparing their line counts would hold even if the raw one were replaced
    // by the corrected one, which is exactly the loss this guards against.
    let glossary = Glossary(entries: [.init(term: "cutover", heardAs: ["migration"])])
    let wired = try await wire(
        session: session,
        files: [file(.microphone, 0, 45)],
        glossary: glossary
    )

    _ = try await wired.process(sessionID: session.id)

    let kept = try #require(await wired.transcripts.load(for: session.id))
    let raw = kept.raw.lines.map(\.text).joined(separator: " ")
    let corrected = kept.corrected.lines.map(\.text).joined(separator: " ")

    #expect(raw.contains("migration"), "the raw transcript no longer holds what was heard")
    #expect(!raw.contains("cutover"), "the raw transcript was overwritten by the corrected one")
    #expect(corrected.contains("cutover"))
    #expect(!corrected.contains("migration"))
}

/// A file knows nothing of where it sits in the meeting, so the caller places
/// it. Deriving that from the index would assume every segment is the same
/// length, which the last one never is.
@Test("lines are placed where their segment sits, not where its index suggests")
func linesArePlacedByTheSegmentStart() async throws {
    // A gap: the second segment starts at 100, not at 45.
    let session = try recordedSession(segments: [
        try segment(.microphone, 0, start: 0, 45),
        try segment(.microphone, 1, start: 100, 45),
    ])
    let wired = try await wire(
        session: session,
        files: [file(.microphone, 0, 45), file(.microphone, 1, 45)]
    )

    _ = try await wired.process(sessionID: session.id)

    let kept = try #require(await wired.transcripts.load(for: session.id))
    let starts = kept.raw.lines.map(\.start)
    #expect(starts == starts.sorted(), "lines came back out of order")
    #expect(
        starts.contains { $0 >= 100 },
        "the second segment was placed at its index, not its start"
    )
}

@Test("every segment transcribed leaves an intent and a completion behind")
func everySegmentLeavesItsPair() async throws {
    let session = try recordedSession(segments: [
        try segment(.microphone, 0, start: 0, 45),
        try segment(.system, 0, start: 0, 45),
    ])
    let wired = try await wire(
        session: session,
        files: [file(.microphone, 0, 45), file(.system, 0, 45)]
    )

    _ = try await wired.process(sessionID: session.id)

    let ledger = try ProgressLedger(await wired.progress.checkpoints(for: session.id))
    #expect(ledger.interrupted.isEmpty)
    #expect(ledger.finished.contains(.transcribingSegment(track: .microphone, index: 0)))
    #expect(ledger.finished.contains(.transcribingSegment(track: .system, index: 0)))
    #expect(ledger.finished.contains(.writingNote))
}

@Test("a session that has not finished recording is refused")
func aSessionStillRecordingIsRefused() async throws {
    let recording = try Session(id: "s1", startedAt: .init(timeIntervalSince1970: 0))
        .applying(.confirm)
    let wired = try await wire(session: recording, files: [file(.microphone, 0, 45)])

    await #expect(throws: ProcessSession.NotRecorded(id: "s1", state: .recording)) {
        _ = try await wired.process(sessionID: "s1")
    }
}

@Test("a session nobody stored is refused by name")
func anUnknownSessionIsRefused() async throws {
    let session = try recordedSession(segments: [try segment(.microphone, 0, start: 0, 45)])
    let wired = try await wire(session: session, files: [])

    await #expect(throws: SessionNotFound(id: "nope")) {
        _ = try await wired.process(sessionID: "nope")
    }
}

/// Not the same as a meeting with nothing said: audio that vanished is a session
/// that cannot be processed, and saying so beats writing an empty note.
@Test("a session whose audio is gone is refused rather than turned into an empty note")
func aSessionWithNoAudioIsRefused() async throws {
    let session = try recordedSession(segments: [try segment(.microphone, 0, start: 0, 45)])
    let wired = try await wire(session: session, files: [])

    await #expect(throws: ProcessSession.NoAudio(id: session.id)) {
        _ = try await wired.process(sessionID: session.id)
    }
    #expect(try await wired.store.load(id: session.id)?.state == .recorded)
}

/// Audio is the source of truth and everything after it is reproducible, so a
/// step that fails must leave the session where running this again can pick it
/// up rather than half-written.
@Test("a transcription that fails leaves the note unwritten and the audio untouched")
func aFailedTranscriptionWritesNoNote() async throws {
    let session = try recordedSession(segments: [try segment(.microphone, 0, start: 0, 45)])
    let wired = try await wire(
        session: session,
        files: [file(.microphone, 0, 45)],
        transcriber: FakeTranscriber(faults: [.serverError(status: 500)])
    )

    await #expect(throws: (any Error).self) { _ = try await wired.process(sessionID: session.id) }

    #expect(
        await wired.notes.contents(of: keptNote(session.id)) == nil,
        "a note was written from a failed transcription"
    )
    #expect(try await wired.transcripts.load(for: session.id) == nil)
    #expect(try await wired.store.load(id: session.id)?.state == .transcribing)
}

@Test("a segment on disk the session never recorded is not transcribed")
func anUnrecordedFileIsIgnored() async throws {
    let session = try recordedSession(segments: [try segment(.microphone, 0, start: 0, 45)])
    let wired = try await wire(
        session: session,
        files: [file(.microphone, 0, 45), file(.microphone, 7, 45)]
    )

    _ = try await wired.process(sessionID: session.id)

    let ledger = try ProgressLedger(await wired.progress.checkpoints(for: session.id))
    #expect(!ledger.finished.contains(.transcribingSegment(track: .microphone, index: 7)))
}

/// The other direction from the test above, and the one that matters: a segment
/// the session recorded whose file is gone. Transcribing around it would hand
/// back a note quietly missing that stretch of the meeting.
@Test("a recorded segment whose file is gone stops the run rather than leaving a hole")
func aMissingSegmentFileStopsTheRun() async throws {
    let session = try recordedSession(segments: [
        try segment(.microphone, 0, start: 0, 45),
        try segment(.microphone, 1, start: 45, 45),
    ])
    let wired = try await wire(session: session, files: [file(.microphone, 0, 45)])

    await #expect(
        throws: ProcessSession.SegmentMissing(id: session.id, track: .microphone, index: 1)
    ) {
        _ = try await wired.process(sessionID: session.id)
    }
    #expect(
        await wired.notes.contents(of: keptNote(session.id)) == nil,
        "a note was written from a transcript missing a segment"
    )
}

/// One track and not the other, which is what a muted microphone in a call
/// looks like once the system tap exists.
@Test("a session holding only the system track still becomes a note")
func aSystemOnlySessionBecomesANote() async throws {
    let session = try recordedSession(segments: [try segment(.system, 0, start: 0, 45)])
    let wired = try await wire(session: session, files: [file(.system, 0, 45)])

    _ = try await wired.process(sessionID: session.id)

    let kept = try #require(await wired.transcripts.load(for: session.id))
    #expect(!kept.corrected.lines.isEmpty)
    #expect(try await wired.store.load(id: session.id)?.state == .completed)
}
