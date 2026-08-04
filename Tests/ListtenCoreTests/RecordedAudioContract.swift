import Foundation
import Testing

@testable import ListtenCore

/// An implementation plus a way to put audio where it will find it, since one
/// reads a directory and the other is handed a dictionary.
struct RecordedAudioUnderTest {
    let audio: any RecordedAudio
    /// Puts some audio where this implementation will find it and answers with
    /// what it actually wrote. The contract does not get to choose: a real
    /// capture closes the segments it closes, and holding it to a list the test
    /// invented would test the test.
    let record: @Sendable (String) async throws -> [Segment]
}

/// The rules every `RecordedAudio` obeys, written once so the fakes cannot drift
/// away from the reader that touches disk. This port had no contract: its one
/// rule lived as a test against `SegmentFiles` alone, which left the fakes free
/// to answer an empty session differently from production.
func verifyRecordedAudioContract(
    _ make: @Sendable () -> RecordedAudioUnderTest,
    sourceLocation: SourceLocation = #_sourceLocation
) async throws {
    let empty = make()
    #expect(
        try await empty.audio.segments(for: "never-recorded").isEmpty,
        "a session that recorded nothing answered with something",
        sourceLocation: sourceLocation
    )

    let subject = make()
    let written = try await subject.record("alpha")
    try #require(
        !written.isEmpty,
        "nothing was recorded, so this compared two empty lists",
        sourceLocation: sourceLocation
    )

    let read = try await subject.audio.segments(for: "alpha")
    #expect(
        read.map { "\($0.track.rawValue)-\($0.index)" }.sorted()
            == written.map { "\($0.track.rawValue)-\($0.index)" }.sorted(),
        "what was recorded is not what came back",
        sourceLocation: sourceLocation
    )
    #expect(
        read.allSatisfy { $0.duration > 0 },
        "a segment came back with no duration",
        sourceLocation: sourceLocation
    )
    #expect(
        read.allSatisfy { !$0.url.lastPathComponent.isEmpty },
        "a segment came back naming no file",
        sourceLocation: sourceLocation
    )

    // One session is not another's. A reader keyed on nothing would be caught
    // here rather than by a user finding one meeting's audio under another name.
    #expect(
        try await subject.audio.segments(for: "bravo").isEmpty,
        "a session nothing recorded answered with another session's audio",
        sourceLocation: sourceLocation
    )
}

@Test("the in-memory recorded audio honours the contract")
func fakeRecordedAudioHonoursTheContract() async throws {
    // A fake is handed what it should answer with, so recording is storing.
    let store = FakeRecordedAudioStore()
    try await verifyRecordedAudioContract {
        RecordedAudioUnderTest(
            audio: store,
            record: { session in
                let segments = [
                    try Segment(index: 0, track: .microphone, start: 0, duration: 0.5),
                    try Segment(index: 1, track: .microphone, start: 0.5, duration: 0.5),
                    try Segment(index: 0, track: .system, start: 0, duration: 0.5),
                ]
                await store.put(
                    segments.map {
                        SegmentFile(
                            track: $0.track,
                            index: $0.index,
                            duration: $0.duration,
                            url: URL(filePath: "/memory/\($0.track.rawValue)-\($0.index).caf")
                        )
                    },
                    for: session
                )
                return segments
            }
        )
    }
}

@Test("the file reader honours the same contract as the fake")
func segmentFilesHonoursTheContract() async throws {
    let parent = temporaryRoot()
    defer { removeTemporaryTree(parent) }

    try await verifyRecordedAudioContract {
        let root = parent.appending(path: UUID().uuidString)
        return RecordedAudioUnderTest(
            audio: SegmentFiles(root: root),
            // Written by the capture that names them, so the reader is held to
            // what the writer actually produces rather than to a layout the
            // test invented.
            record: { session in
                let capture = SegmentedCapture(
                    sources: [
                        .microphone: FakeAudioSource(buffers: 12),
                        .system: FakeAudioSource(buffers: 12),
                    ],
                    directory: root.appending(path: session).appending(path: "audio"),
                    rotateEvery: 0.5
                )
                var closed: [Segment] = []
                for await segment in try await capture.start() { closed.append(segment) }
                closed += try await capture.stop()
                return closed
            }
        )
    }
}
