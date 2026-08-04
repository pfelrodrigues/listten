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

/// Recovery and processing both read this before anything is known to exist, so
/// nothing on disk has to be told apart from a directory that cannot be read.
@Test("a session that recorded nothing reads as no segments rather than as a failure")
func aSessionWithNoAudioReadsAsEmpty() async throws {
    try await withTemporaryRoot { root in
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        #expect(try await SegmentFiles(root: root).segments(for: session).isEmpty)
    }
}
