import AVFoundation
import Foundation
import Testing

@testable import ListtenCore

private let session = "2026-08-04T10-00-00Z"

private func withTemporaryRoot<T>(_ body: (URL) async throws -> T) async throws -> T {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "listten-segment-files-\(UUID().uuidString)")
    let result = try await body(root)
    try FileManager.default.removeItem(at: root)
    return result
}

private func capture(under root: URL) -> SegmentedCapture {
    SegmentedCapture(
        sources: [
            .microphone: FakeAudioSource(buffers: 12),
            .system: FakeAudioSource(buffers: 12),
        ],
        directory: root.appending(path: session).appending(path: "audio"),
        rotateEvery: 0.5
    )
}

private func named(_ track: Track, _ index: Int) -> String { "\(track.rawValue)-\(index)" }

/// The two halves of the product meeting for the first time: the recorder names
/// the files and the pipeline reads them back by name. Every segment has to
/// arrive as the same `(track, index)` it was written as, because processing
/// refuses a session where a file and a segment do not line up, and an index off
/// by one fails an hour of meeting rather than one line of it.
@Test("what the capture wrote is what the pipeline reads back")
func theWriterAndTheReaderAgreeOnEverySegment() async throws {
    try await withTemporaryRoot { root in
        let subject = capture(under: root)

        var recorded: [Segment] = []
        for await segment in try await subject.start() { recorded.append(segment) }
        recorded += try await subject.stop()

        let read = try await SegmentFiles(root: root).segments(for: session)

        #expect(!recorded.isEmpty, "nothing was captured, so this compared two empty lists")
        #expect(
            read.map { named($0.track, $0.index) }.sorted()
                == recorded.map { named($0.track, $0.index) }.sorted()
        )
    }
}

private func writeCAF(_ name: String, seconds: Double, in directory: URL) throws {
    guard
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1),
        let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(seconds * 16000)
        )
    else { throw CocoaError(.fileWriteUnknown) }
    buffer.frameLength = buffer.frameCapacity

    let file = try AVAudioFile(
        forWriting: directory.appending(path: name),
        settings: format.settings
    )
    try file.write(from: buffer)
}

private func withAudioDirectory<T>(_ body: (URL, URL) async throws -> T) async throws -> T {
    let root = temporaryRoot()
    let audio = root.appending(path: "aaa").appending(path: "audio")
    try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)
    let result = try await body(root, audio)
    try FileManager.default.removeItem(at: root)
    return result
}

@Test("the files a capture wrote are read back, with the durations the files hold")
func theFilesACaptureWroteAreReadBack() async throws {
    try await withAudioDirectory { root, audio in
        try writeCAF("mic-0001.caf", seconds: 2, in: audio)
        try writeCAF("sys-0002.caf", seconds: 3, in: audio)

        let found = try await SegmentFiles(root: root).segments(for: "aaa")
            .sorted { $0.track.rawValue < $1.track.rawValue }

        #expect(found.map(\.track) == [.microphone, .system])
        #expect(found.map(\.index) == [0, 1])
        #expect(found.map { ($0.duration * 10).rounded() } == [20, 30])
    }
}

/// The live transcript lives in this directory, and processing stops on a file
/// it cannot account for rather than writing a note around it. So this invariant
/// is what keeps every session that has a live transcript processable at all,
/// and it was worth stating out loud rather than inferring from a name.
@Test("a live transcript sitting beside the audio is not mistaken for a segment")
func aLiveTranscriptIsNotMistakenForASegment() async throws {
    try await withAudioDirectory { root, audio in
        try SessionLiveTranscripts(root: root)
            .append(
                try LiveLine(track: .microphone, start: 0, end: 1, text: "bom dia"),
                for: "aaa"
            )
        #expect(
            FileManager.default.fileExists(
                atPath: audio.appending(path: SessionLiveTranscripts.fileName).path
            ),
            "the live transcript did not land where recovery would look"
        )

        #expect(try await SegmentFiles(root: root).segments(for: "aaa").isEmpty)
    }
}

/// Everything else it might find there. A name that is nearly right is the one
/// that would slip through, so the list is nearly-right names.
@Test(
    "a file that is not a segment is left alone",
    arguments: [
        "live.jsonl", "progress.jsonl", "note.md", "mic-0001.caf.tmp",
        "mic.caf", "mic-0000.caf", "mic-abc.caf", "tap-0001.caf", "mic-0001",
    ]
)
func aFileThatIsNotASegmentIsLeftAlone(name: String) async throws {
    try await withAudioDirectory { root, audio in
        try Data("not a segment\n".utf8).write(to: audio.appending(path: name))

        #expect(try await SegmentFiles(root: root).segments(for: "aaa").isEmpty, "\(name) was read")
    }
}
