import Foundation
import Testing

@testable import ListtenCore

/// The largest piece of the shipping wiring that runs without a microphone:
/// a real `SegmentedCapture` with a real `StreamingLiveAudioSink`, a real
/// `LiveTranscript` and the real JSONL bytes, driven by a real `SessionRecorder`.
/// Only the two Apple audio sources and the analyser are faked, and both of
/// those seams have a contract every implementation answers to.
///
/// Every other live test holds one piece against a fake of its neighbour. This
/// is the one that says the pieces are wired to each other — in particular that
/// the sink is finished by the capture in time for the recorder's await to
/// return, which is an ordering that lives in two files and no single test of
/// either would notice.
@Test(
    "a recording writes its live transcript through the wiring that ships",
    .timeLimit(.minutes(1))
)
func aRecordingWritesItsLiveTranscriptEndToEnd() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let subject = SessionRecorder(
        sessions: InMemorySessionStore(),
        progress: InMemoryProgressLog(),
        prompt: RecordingPromptSpy(),
        clock: FixedTimeSource(),
        minimumDuration: 1,
        capture: { sessionID in
            let sink = StreamingLiveAudioSink()
            return ArmedRecording(
                capture: SegmentedCapture(
                    sources: [
                        // Twelve tenths of a second each, delivered and finished
                        // as the capture starts.
                        .microphone: FakeAudioSource(buffers: 12),
                        .system: FakeAudioSource(buffers: 12),
                    ],
                    directory: root.appending(path: sessionID).appending(path: "audio"),
                    rotateEvery: 0.5,
                    live: sink
                ),
                live: LiveTranscript(
                    audio: sink.stream,
                    sink: sink,
                    backend: FakeLiveTranscriber(),
                    writer: SessionLiveTranscripts(root: root),
                    sessionID: sessionID,
                    language: "pt-BR",
                    settleEvery: 0.5
                )
            )
        },
        // A recording that stops now walks to a note, which this test is not
        // about: it answers at once so the live outcome is what is read.
        process: { _ in
            NoteLocation(
                kept: URL(filePath: "/memory/note.md"),
                delivered: URL(filePath: "/memory/note.md")
            )
        }
    )

    await subject.start()
    await subject.stop()

    // The write-up runs on a task of its own, so the state after stopping is
    // reached rather than returned.
    var reached = await subject.current()
    for _ in 0..<10_000 {
        guard case .processing = reached else { break }
        await Task.yield()
        reached = await subject.current()
    }
    guard case .processed(let id, _) = reached else {
        Issue.record("expected a written note, got \(reached)")
        return
    }

    let outcome = try #require(await subject.liveOutcome())
    #expect(outcome.dropped == 0, "the live side fell behind a recording it should keep up with")
    #expect(!outcome.endedEarly, "the sink was finished while the recording was still running")
    #expect(outcome.failure == nil, "the live transcript reported \(outcome.failure ?? "")")
    #expect(outcome.lines > 0, "the meeting produced no live lines at all")

    // Read off the bytes rather than off the writer, since the file is the
    // deliverable and another program is what reads it.
    let written = try JSONLLog<LiveLine>(
        url: SessionLiveTranscripts(root: root).url(for: id)
    )
    .entries()
    #expect(written.count == outcome.lines)
    #expect(
        Set(written.map { $0.track }) == Set(Track.allCases),
        "one of the tracks reached no line"
    )
    #expect(written.allSatisfy { $0.start >= 0 && $0.end >= $0.start })
}
