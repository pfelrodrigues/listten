import AVFoundation
import Foundation
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
