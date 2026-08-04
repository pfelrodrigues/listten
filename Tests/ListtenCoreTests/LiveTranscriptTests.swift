import Foundation
import Testing

@testable import ListtenCore

private let rate = 16000.0

/// Half a second of audio, placed where the capture said it sat.
private func heard(_ track: Track, at start: TimeInterval) -> LiveAudio {
    LiveAudio(
        track: track,
        audio: CapturedAudio(
            hostTime: 1000 + start,
            sampleRate: rate,
            samples: Array(repeating: 0, count: Int(rate / 2))
        ),
        start: start
    )
}

/// Everything is fed and the stream closed before `run` is called, so a test
/// asserts on a finished meeting rather than polling one.
private func recorded(_ buffers: [LiveAudio]) -> AsyncStream<LiveAudio> {
    AsyncStream { continuation in
        for buffer in buffers {
            continuation.yield(buffer)
        }
        continuation.finish()
    }
}

private func transcript(
    of buffers: [LiveAudio],
    backend: any LiveTranscribing = FakeLiveTranscriber(),
    writer: any LiveTranscriptWriting,
    sink: any LiveAudioSink = InMemoryLiveAudioSink(capacity: 4096),
    settleEvery: TimeInterval = 1
) -> LiveTranscript {
    LiveTranscript(
        audio: recorded(buffers),
        sink: sink,
        backend: backend,
        writer: writer,
        sessionID: "meeting",
        language: "pt-BR",
        settleEvery: settleEvery
    )
}

/// Two tracks, one file, and the attribution that comes free from having
/// recorded them separately. The instants are on the session clock, not on the
/// one each backend counts from, which is what lets a reader line a live line up
/// with the recording.
@Test("both tracks reach one file, tagged and placed on the session clock")
func bothTracksReachOneFileOnTheSessionClock() async throws {
    let writer = InMemoryLiveTranscripts()
    let subject = transcript(
        of: [
            heard(.microphone, at: 10),
            heard(.system, at: 20),
            heard(.microphone, at: 10.5),
            heard(.system, at: 20.5),
        ],
        writer: writer
    )

    await subject.run()

    let written = await writer.lines(for: "meeting")
    #expect(written.filter { $0.track == .microphone }.map(\.start) == [10])
    #expect(written.filter { $0.track == .microphone }.map(\.end) == [11])
    #expect(written.filter { $0.track == .system }.map(\.start) == [20])
    #expect(written.filter { $0.track == .system }.map(\.end) == [21])
    #expect(await subject.outcome().lines == 2)
}

/// Hypotheses arrive about three times a second carrying the whole accumulated
/// text. A file rewritten that often is not one a reader can follow, which is
/// the finding the cadence exists to answer.
@Test("hypotheses never reach the file")
func hypothesesNeverReachTheFile() async throws {
    let writer = InMemoryLiveTranscripts()
    let subject = transcript(
        of: (0..<6).map { heard(.microphone, at: Double($0) / 2) },
        writer: writer
    )

    await subject.run()

    let written = await writer.lines(for: "meeting")
    #expect(!written.isEmpty)
    #expect(
        written.allSatisfy { $0.text.hasPrefix("chunk") },
        "a hypothesis was written: \(written.map(\.text))"
    )
}

/// A refused session hands over no audio at all, so nothing is opened, no model
/// is made resident and there is nothing to tear down on a no.
@Test("no backend is opened for a track until a buffer for it arrives")
func noBackendIsOpenedUntilAudioArrives() async throws {
    let spy = LiveTranscriberSpy()
    let writer = InMemoryLiveTranscripts()

    await transcript(of: [], backend: FakeLiveTranscriber(spy: spy), writer: writer).run()
    #expect(spy.opened == 0, "a meeting that produced no audio opened a backend")

    await transcript(
        of: [heard(.microphone, at: 0), heard(.microphone, at: 0.5)],
        backend: FakeLiveTranscriber(spy: spy),
        writer: writer
    )
    .run()
    #expect(spy.opened == 1, "one track's audio opened \(spy.opened) backends")
}

/// The last thing anybody said is the part a reader most wants, and it is the
/// part that has not been settled yet when the meeting ends.
@Test("finishing writes the trailing lines before run returns")
func finishingWritesTheTrailingLines() async throws {
    let writer = InMemoryLiveTranscripts()
    // Three halves of a second against a one second cadence: one settle, and
    // half a second left over that only finishing can finalize.
    let subject = transcript(
        of: (0..<3).map { heard(.microphone, at: Double($0) / 2) },
        writer: writer
    )

    await subject.run()

    let written = await writer.lines(for: "meeting")
    #expect(written.map(\.start) == [0, 1])
    #expect(written.map(\.end) == [1, 1.5])
}

/// One line that could not be written is worth reporting and not worth ending
/// the transcript over: the next one may well land, and the audio is on disk
/// either way.
@Test("a line that could not be written is reported, and the next one still lands")
func aWriterThatFailsIsReportedRatherThanRaised() async throws {
    let writer = InMemoryLiveTranscripts()
    await writer.refuse(appends: [1])
    let subject = transcript(
        of: (0..<3).map { heard(.microphone, at: Double($0) / 2) },
        writer: writer,
        settleEvery: 0.5
    )

    await subject.run()

    let outcome = await subject.outcome()
    #expect(outcome.failure?.contains("Refused") == true, "the refusal was not reported")
    #expect(
        await writer.lines(for: "meeting").map(\.text) == ["chunk 0", "chunk 2"],
        "the transcript stopped at the line that failed"
    )
    #expect(outcome.lines == 2, "\(outcome.lines) lines were counted as written")
}

/// One analyser refusing costs that track and nothing else. Both tracks failing
/// together would be a transcript that quietly went missing.
@Test("one track's backend refusing leaves the other one writing")
func oneTrackRefusingLeavesTheOtherWriting() async throws {
    let writer = InMemoryLiveTranscripts()
    let spy = LiveTranscriberSpy()
    let subject = transcript(
        of: [
            heard(.microphone, at: 0),
            heard(.system, at: 0),
            heard(.microphone, at: 0.5),
            // A second buffer for the refused track, which must be passed over
            // rather than asked for a second analyser.
            heard(.system, at: 0.5),
        ],
        backend: FakeLiveTranscriber(spy: spy, openingFailsAfter: 1),
        writer: writer
    )

    await subject.run()

    let written = await writer.lines(for: "meeting")
    #expect(written.map(\.track) == [.microphone], "the refused track was transcribed anyway")
    #expect(await subject.outcome().failure != nil, "a track was dropped and nothing said so")
    #expect(spy.opened == 2, "a refused track was asked again, \(spy.opened) times in all")
}

/// A backend that dies mid-meeting stops that track's transcript where it
/// stopped. It is reported rather than raised, and run still returns.
@Test("a backend that stops mid-meeting is reported and the run still ends")
func aBackendThatStopsIsReported() async throws {
    let writer = InMemoryLiveTranscripts()
    let subject = transcript(
        of: (0..<6).map { heard(.microphone, at: Double($0) / 2) },
        backend: FakeLiveTranscriber(failingAfter: 1),
        writer: writer
    )

    await subject.run()

    let outcome = await subject.outcome()
    #expect(outcome.lines == 1)
    #expect(outcome.failure?.contains("LiveBackendStopped") == true, "got \(outcome.failure ?? "")")
}

/// The three ways a live transcript can be short, told apart. A hole in the
/// middle drifts every instant after it; a consumer that died loses everything
/// after it and drops nothing at all.
@Test("the outcome says what the sink lost and whether it stopped early")
func theOutcomeReportsWhatTheSinkLost() async throws {
    let sink = InMemoryLiveAudioSink(capacity: 1)
    for start in 0..<3 {
        sink.hand(heard(.microphone, at: Double(start)))
    }
    sink.finish()
    sink.hand(heard(.microphone, at: 3))

    let subject = transcript(of: [], writer: InMemoryLiveTranscripts(), sink: sink)
    await subject.run()

    #expect(
        await subject.outcome()
            == LiveTranscript.Outcome(lines: 0, dropped: 2, endedEarly: true, failure: nil)
    )
}

@Test("a cadence of zero is refused before the meeting rather than during it")
func aTranscriptWithNoCadenceIsRefused() async {
    await #expect(processExitsWith: .failure) {
        _ = LiveTranscript(
            audio: AsyncStream { $0.finish() },
            sink: InMemoryLiveAudioSink(),
            backend: FakeLiveTranscriber(),
            writer: InMemoryLiveTranscripts(),
            sessionID: "meeting",
            language: "pt-BR",
            settleEvery: 0
        )
    }
}

/// The queue in front of the analyser is bounded, so a backend that falls behind
/// loses audio rather than growing memory. What it must not do is lose it in
/// silence: `dropped` reporting zero while a minute is missing reads exactly
/// like a minute nobody spoke in, and this is the one place in the live path
/// that can drop without the sink knowing.
@Test("audio the backend could not keep up with is counted, not just discarded")
func audioTheBackendCannotKeepUpWithIsCounted() async throws {
    let sink = StreamingLiveAudioSink()
    let (audio, feeding) = AsyncStream<LiveAudio>.makeStream()
    let subject = LiveTranscript(
        audio: audio,
        sink: sink,
        // Never reads what it is handed, so the bounded queue in front of it
        // fills and everything after that is dropped.
        backend: DeafLiveTranscriber(),
        writer: InMemoryLiveTranscripts(),
        sessionID: "alpha",
        language: "pt-BR"
    )

    let running = Task { await subject.run() }
    // Comfortably past the backlog, which is 64.
    for index in 0..<200 {
        feeding.yield(
            LiveAudio(
                track: .microphone,
                audio: CapturedAudio(
                    hostTime: Double(index) / 10,
                    sampleRate: 16000,
                    samples: [Float](repeating: 0, count: 1600)
                ),
                start: Double(index) / 10
            )
        )
    }
    feeding.finish()
    await running.value

    #expect(
        await subject.outcome().dropped > 0,
        "a backend that heard nothing reported nothing dropped"
    )
}
