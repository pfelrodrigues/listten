import AVFoundation
import Foundation
import Synchronization
import Testing

@testable import ListtenCore

private func withTemporaryDirectory<T>(_ body: (URL) async throws -> T) async throws -> T {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "listten-segments-\(UUID().uuidString)")
    let result = try await body(directory)
    try? FileManager.default.removeItem(at: directory)
    return result
}

private func capture(
    in directory: URL,
    buffers: Int = 12,
    rotateEvery: TimeInterval = 0.5
) -> SegmentedCapture {
    SegmentedCapture(
        sources: [
            .microphone: FakeAudioSource(buffers: buffers),
            .system: FakeAudioSource(buffers: buffers),
        ],
        directory: directory,
        rotateEvery: rotateEvery
    )
}

private func framesInFile(at url: URL) throws -> AVAudioFramePosition {
    try AVAudioFile(forReading: url).length
}

private func framesOnDisk(in directory: URL, of track: Track) throws -> AVAudioFramePosition {
    let prefix = track == .microphone ? "mic" : "sys"
    return try FileManager.default
        .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        .filter { $0.lastPathComponent.hasPrefix(prefix) }
        .reduce(0) { total, file in
            total + (try AVAudioFile(forReading: file).length)
        }
}

/// A stream nobody finished would hang the whole suite rather than fail one
/// test, so the wait has an end and the end is an issue.
private func drainedLive(
    _ sink: StreamingLiveAudioSink,
    sourceLocation: SourceLocation = #_sourceLocation
) async -> [LiveAudio] {
    let collecting = Task {
        var received: [LiveAudio] = []
        for await audio in sink.stream {
            received.append(audio)
        }
        return received
    }
    let deadline = Task {
        try await Task.sleep(for: .seconds(5))
        Issue.record("the live stream was never finished", sourceLocation: sourceLocation)
        collecting.cancel()
    }
    let received = await collecting.value
    deadline.cancel()
    return received
}

/// The buffers hand over on a task of the capture's own, so a test that asserts
/// straight after advancing the clock reads whichever half had arrived.
private func waitForLive(
    _ sink: InMemoryLiveAudioSink,
    toHold buffers: Int,
    sourceLocation: SourceLocation = #_sourceLocation
) async {
    for _ in 0..<1_000_000 {
        if sink.received.count >= buffers { return }
        await Task.yield()
    }
    Issue.record("the sink never reached \(buffers) buffers", sourceLocation: sourceLocation)
}

@Test("each track is written to its own numbered files")
func eachTrackGetsItsOwnNumberedFiles() async throws {
    try await withTemporaryDirectory { directory in
        let subject = capture(in: directory)

        for await _ in try await subject.start() {}
        _ = try await subject.stop()

        let written = try FileManager.default
            .contentsOfDirectory(atPath: directory.path)
            .sorted()
        #expect(
            written == [
                "mic-0001.caf", "mic-0002.caf", "mic-0003.caf",
                "sys-0001.caf", "sys-0002.caf", "sys-0003.caf",
            ]
        )
    }
}

/// The write-ahead claim, and the reason this issue exists: a file closed on
/// rotation is complete before anything else happens, so a process killed later
/// leaves it playable.
@Test("a segment closed on rotation is already complete on disk, before stopping")
func aClosedSegmentIsCompleteBeforeStopping() async throws {
    try await withTemporaryDirectory { directory in
        let subject = capture(in: directory)

        var closed: [Segment] = []
        for await segment in try await subject.start() {
            closed.append(segment)
            // Deliberately read the file while capture is still running.
            let url = subject.url(for: segment.track, index: segment.index)
            #expect(try framesInFile(at: url) > 0, "\(url.lastPathComponent) is not playable yet")
        }

        #expect(!closed.isEmpty)
        // Never stopped: everything above was readable mid-capture.
    }
}

@Test("stopping finalizes the file still open and hands it over")
func stoppingFinalizesTheOpenFile() async throws {
    try await withTemporaryDirectory { directory in
        // Five buffers of 0.1s against a 0.2s rotation: two close, one is left open.
        let subject = capture(in: directory, buffers: 5, rotateEvery: 0.2)

        for await _ in try await subject.start() {}
        let partials = try await subject.stop()

        #expect(partials.map(\.index) == [2, 2])
        for partial in partials {
            let url = subject.url(for: partial.track, index: partial.index)
            #expect(try framesInFile(at: url) > 0)
        }
    }
}

@Test("what a file holds is what the segment says it holds")
func fileLengthMatchesTheSegment() async throws {
    try await withTemporaryDirectory { directory in
        let subject = capture(in: directory, buffers: 12, rotateEvery: 0.5)

        var closed: [Segment] = []
        for await segment in try await subject.start() {
            closed.append(segment)
        }
        _ = try await subject.stop()

        for segment in closed {
            let url = subject.url(for: segment.track, index: segment.index)
            let seconds = Double(try framesInFile(at: url)) / 48000
            #expect(abs(seconds - segment.duration) < 0.001)
        }
    }
}

@Test("segmented capture honours the contract every implementation answers for")
func segmentedCaptureHonoursTheContract() async throws {
    try await withTemporaryDirectory { directory in
        try await verifyAudioCapturingContract {
            capture(in: directory.appending(path: UUID().uuidString))
        }
    }
}

/// The contract is the only place that stops a capture that never started and
/// stops a started one twice, which is exactly where a sink left open would
/// strand whatever is reading it. A sink is minted per capture and never reused,
/// so every one of them has to end.
@Test("a capture with a live sink attached honours the contract, and ends every sink")
func aCaptureWithALiveSinkHonoursTheContract() async throws {
    try await withTemporaryDirectory { directory in
        let minted = Mutex<[StreamingLiveAudioSink]>([])

        try await verifyAudioCapturingContract {
            let sink = StreamingLiveAudioSink()
            minted.withLock { $0.append(sink) }
            return SegmentedCapture(
                sources: [
                    .microphone: FakeAudioSource(buffers: 12),
                    .system: FakeAudioSource(buffers: 12),
                ],
                directory: directory.appending(path: UUID().uuidString),
                rotateEvery: 0.5,
                live: sink
            )
        }

        let sinks = minted.withLock { $0 }
        #expect(sinks.count == 3, "the contract stopped building captures")
        for sink in sinks {
            _ = await drainedLive(sink)
            #expect(!sink.endedEarly, "capture handed a buffer over after finishing its sink")
        }
    }
}

/// The live side and the recording describe one meeting: every buffer that
/// reached disk was handed over, on the same clock the segments are placed on.
@Test("what the live sink was handed is what reached disk, in order, on the session clock")
func theLiveSinkSeesWhatReachedDisk() async throws {
    try await withTemporaryDirectory { directory in
        let sink = StreamingLiveAudioSink()
        let subject = SegmentedCapture(
            sources: [
                .microphone: FakeAudioSource(buffers: 12),
                .system: FakeAudioSource(buffers: 12),
            ],
            directory: directory,
            rotateEvery: 0.5,
            live: sink
        )

        for await _ in try await subject.start() {}
        _ = try await subject.stop()
        let handed = await drainedLive(sink)

        #expect(sink.dropped == 0, "the recording outran a sink sized for it")
        for track in Track.allCases {
            let ofTrack = handed.filter { $0.track == track }
            #expect(
                ofTrack.map(\.start).map { ($0 * 10).rounded() } == (0..<12).map(Double.init),
                "\(track) was handed instants that are not the session clock"
            )
            #expect(
                ofTrack.reduce(0) { $0 + $1.audio.frames }
                    == Int(try framesOnDisk(in: directory, of: track)),
                "\(track) handed over a different amount of audio than it wrote"
            )
        }
    }
}

/// A live transcript that stops growing is a nuisance. A recording that stops
/// growing is the failure this whole project is against, so the sink is never
/// allowed to be the thing that ends one.
@Test("a live consumer that goes away mid-recording costs the transcript, never the audio")
func aLiveConsumerGoingAwayDoesNotStopTheRecording() async throws {
    try await withTemporaryDirectory { directory in
        let clock = ManualTimeSource()
        let devices = [
            Track.microphone: FakeAudioSource(clock: clock, sampleRate: 16000),
            Track.system: FakeAudioSource(clock: clock, sampleRate: 16000),
        ]
        let sink = InMemoryLiveAudioSink(capacity: 4096)
        let subject = SegmentedCapture(
            sources: devices,
            directory: directory,
            rotateEvery: 45,
            live: sink
        )

        let stream = try await subject.start()
        let closed = Task { await drained(stream) }

        for track in Track.allCases {
            await devices[track]?.advance(by: 1)
        }
        await waitForLive(sink, toHold: 20)

        // The consumer dies here. The recording has another second to run.
        sink.finish()
        for track in Track.allCases {
            await devices[track]?.advance(by: 1)
        }
        _ = try await subject.stop()
        _ = await closed.value

        #expect(sink.endedEarly, "audio arrived after the consumer went and nothing said so")
        for track in Track.allCases {
            #expect(
                try framesOnDisk(in: directory, of: track) == 32000,
                "\(track) stopped being recorded when its live consumer went away"
            )
        }
    }
}

/// A device that vanishes for good ends the stream without anyone stopping the
/// capture, and nothing else is coming after that. The capture is deliberately
/// never stopped here, so only the sources ending can end the sink.
@Test("sources that end on their own end the live stream")
func sourcesEndingOnTheirOwnEndTheLiveStream() async throws {
    try await withTemporaryDirectory { directory in
        let sink = StreamingLiveAudioSink()
        let subject = SegmentedCapture(
            sources: [.microphone: FakeAudioSource(buffers: 4)],
            directory: directory,
            rotateEvery: 45,
            live: sink
        )

        // Draining to completion is the proof the sources ended.
        _ = await drained(try await subject.start())

        #expect(await drainedLive(sink).count == 4)
    }
}

/// Stopping ends the sources, which ends the writers, which is what ends the
/// sink. Sources that finish their own stream would end it before anyone
/// stopped anything, so this drives them by hand.
@Test("stopping a running capture ends its live stream")
func stoppingEndsTheLiveStream() async throws {
    try await withTemporaryDirectory { directory in
        let clock = ManualTimeSource()
        let devices = [
            Track.microphone: FakeAudioSource(clock: clock, sampleRate: 16000)
        ]
        let sink = StreamingLiveAudioSink()
        let subject = SegmentedCapture(
            sources: devices,
            directory: directory,
            rotateEvery: 45,
            live: sink
        )

        let stream = try await subject.start()
        let closed = Task { await drained(stream) }
        await devices[.microphone]?.advance(by: 1)
        _ = try await subject.stop()
        _ = await closed.value

        #expect(await drainedLive(sink).count == 10)
    }
}

/// A start that unwound recorded nothing, so there is nothing coming. Leaving
/// the sink open strands whatever was going to read it for the life of the app.
@Test("a capture whose start was refused leaves no live stream open")
func aRefusedStartLeavesNoLiveStreamOpen() async throws {
    try await withTemporaryDirectory { directory in
        let sink = StreamingLiveAudioSink()
        let subject = SegmentedCapture(
            sources: [.microphone: RefusingAudioSource()],
            directory: directory,
            rotateEvery: 5,
            live: sink
        )

        await #expect(throws: RefusingAudioSource.Refused.self) { _ = try await subject.start() }

        #expect(await drainedLive(sink).isEmpty)
    }
}

private func drained(_ stream: AsyncStream<Segment>) async -> [Segment] {
    var received: [Segment] = []
    for await segment in stream {
        received.append(segment)
    }
    return received
}

/// Measured on a real recording: two devices start independently and race, and
/// the one that delivers first is not the one whose buffer is stamped earliest.
/// The system tap won by arriving while the microphone's buffer carried an
/// instant 28ms older, so anchoring on the winner made every microphone buffer
/// older than the anchor. The timeline refuses those rather than placing them
/// before zero, and the whole recording failed on which device was quicker.
@Test("a track that delivers late with an earlier instant does not fail the recording")
func anEarlierSecondTrackDoesNotFailTheRecording() async throws {
    let directory = temporaryRoot()
    defer { removeTemporaryTree(directory) }

    // Clock-driven, so the order of delivery is the test's to decide rather than
    // a dictionary's: the tap delivers first, stamped later than the microphone
    // that has not spoken yet.
    let tapClock = ManualTimeSource(now: Date(timeIntervalSince1970: 1000.03))
    let micClock = ManualTimeSource(now: Date(timeIntervalSince1970: 1000))
    let tap = FakeAudioSource(clock: tapClock)
    let microphone = FakeAudioSource(clock: micClock)

    let subject = SegmentedCapture(
        sources: [.system: tap, .microphone: microphone],
        directory: directory,
        rotateEvery: 0.3
    )

    // Started before anything is advanced, so both sources are running.
    let stream = try await subject.start()
    let draining = Task {
        var seen: [Segment] = []
        for await segment in stream { seen.append(segment) }
        return seen
    }
    // The tap first, so the anchor would be its instant if the first to arrive
    // were the one that set it.
    await tap.advance(by: 0.5)
    await microphone.advance(by: 0.5)
    await tap.stop()
    await microphone.stop()
    var closed = await draining.value
    closed += try await subject.stop()

    #expect(!closed.isEmpty, "nothing was captured, so nothing was proven")
    #expect(closed.allSatisfy { $0.start >= 0 })
    #expect(
        Set(closed.map(\.track)) == Set(Track.allCases),
        "one of the tracks lost every segment: \(closed.map { "\($0.track.rawValue)" })"
    )
}
