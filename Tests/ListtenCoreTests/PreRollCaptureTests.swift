import AVFoundation
import Foundation
import Testing

@testable import ListtenCore

/// A pre-roll is measured in minutes, so the buffers are coarse and the rate is
/// the one transcription wants: 55 seconds is 110 buffers rather than 2640.
private let rate: Double = 16000
private let bufferDuration: TimeInterval = 0.5

private func withTemporaryDirectory<T>(_ body: (URL) async throws -> T) async throws -> T {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "listten-preroll-\(UUID().uuidString)")
    let result = try await body(directory)
    try? FileManager.default.removeItem(at: directory)
    return result
}

/// Throws when the directory is not there, rather than reporting nothing. A
/// count that reads a missing path as zero would pass for every implementation.
private func bytesOnDisk(in directory: URL) throws -> Int {
    try FileManager.default
        .contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])
        .reduce(0) { total, file in
            total + (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        }
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

private func sources(driving clock: ManualTimeSource) -> [Track: FakeAudioSource] {
    [
        .microphone: FakeAudioSource(
            clock: clock,
            sampleRate: rate,
            bufferDuration: bufferDuration
        ),
        .system: FakeAudioSource(clock: clock, sampleRate: rate, bufferDuration: bufferDuration),
    ]
}

private func advance(_ sources: [Track: FakeAudioSource], by seconds: TimeInterval) async {
    for track in Track.allCases {
        await sources[track]?.advance(by: seconds)
    }
}

/// The sources hand buffers to a stream the capture drains on its own task, so
/// confirming straight after advancing would race the drain and assert on
/// whichever half arrived.
private func waitForRing(
    _ capture: SegmentedCapture,
    toHold seconds: TimeInterval,
    sourceLocation: SourceLocation = #_sourceLocation
) async {
    let frames = Int(seconds * rate) * Track.allCases.count
    for _ in 0..<1_000_000 {
        if await capture.preRollFrames >= frames { return }
        await Task.yield()
    }
    Issue.record("the ring never reached \(frames) frames", sourceLocation: sourceLocation)
}

private func capture(in directory: URL, from sources: [Track: FakeAudioSource]) -> SegmentedCapture
{
    SegmentedCapture(
        sources: sources,
        directory: directory,
        rotateEvery: 45,
        preRoll: 60
    )
}

/// The first acceptance of #12, read off the directory rather than off a flag:
/// a session nobody confirmed leaves the disk exactly as it found it.
@Test("a refused session leaves nothing on disk, and the ring keeps rolling")
func aRefusedSessionLeavesNothingOnDisk() async throws {
    try await withTemporaryDirectory { directory in
        let clock = ManualTimeSource()
        let devices = sources(driving: clock)
        let subject = capture(in: directory, from: devices)

        let stream = try await subject.start()
        let closed = Task { await drained(stream) }

        await advance(devices, by: 30)
        await waitForRing(subject, toHold: 30)
        #expect(try bytesOnDisk(in: directory) == 0, "audio reached disk before any answer")

        // Refused. The ring goes on holding the last minute, and holds no more
        // than that however long the meeting runs.
        await advance(devices, by: 60)
        await waitForRing(subject, toHold: 60)
        // The window and the one buffer carrying its edge, on both tracks.
        let held = await subject.preRollFrames
        #expect(held <= Int((60 + bufferDuration) * rate) * 2, "the ring grew past its window")

        let partials = try await subject.stop()
        #expect(partials.isEmpty, "a refused session handed over audio to keep")
        #expect(await closed.value.isEmpty, "a refused session closed a segment")
        #expect(try bytesOnDisk(in: directory) == 0, "a refused session left audio behind")
    }
}

/// The second acceptance: the answer arrives long after the meeting started,
/// and what reaches disk still begins where the meeting did.
@Test("confirming 55 seconds after the prompt still recovers the opening")
func confirmingLateStillRecoversTheOpening() async throws {
    try await withTemporaryDirectory { directory in
        let clock = ManualTimeSource()
        let devices = sources(driving: clock)
        let subject = capture(in: directory, from: devices)

        let stream = try await subject.start()
        let closed = Task { await drained(stream) }

        await advance(devices, by: 55)
        await waitForRing(subject, toHold: 55)
        try await subject.confirm()

        // Not throwing is the assertion: audio older than the anchor is refused,
        // so a drain anchored at the answer rather than at the opening reports
        // here instead of quietly writing the wrong timeline.
        let partials = try await subject.stop()
        let segments = await closed.value + partials

        #expect(await subject.preRollFrames == 0, "the ring still holds what it drained")
        #expect(try bytesOnDisk(in: directory) > 0)

        for track in Track.allCases {
            let ofTrack = segments.filter { $0.track == track }.sorted { $0.index < $1.index }
            #expect(ofTrack.map(\.index) == [0, 1], "\(track) is missing a segment")
            #expect(ofTrack.first?.start == 0, "\(track) does not start at the opening")
            let total = ofTrack.reduce(0) { $0 + $1.duration }
            #expect(abs(total - 55) < 0.001, "\(track) holds \(total)s of a 55s meeting")
            #expect(
                try framesOnDisk(in: directory, of: track) == AVAudioFramePosition(55 * rate),
                "\(track) has less than the meeting on disk"
            )
        }
    }
}

/// A drain has nowhere to yield a closed segment before the capture is running,
/// so it would leave audio on disk that no session accounts for. Refused rather
/// than ignored: silently holding on would record the meeting nowhere.
@Test("confirming a capture that is not running is refused")
func confirmingACaptureThatIsNotRunningIsRefused() async throws {
    try await withTemporaryDirectory { directory in
        let subject = capture(in: directory, from: sources(driving: ManualTimeSource()))

        await #expect(throws: SegmentedCapture.CaptureNotRunning.self) {
            try await subject.confirm()
        }
    }
}

private func drained(_ stream: AsyncStream<Segment>) async -> [Segment] {
    var received: [Segment] = []
    for await segment in stream {
        received.append(segment)
    }
    return received
}
