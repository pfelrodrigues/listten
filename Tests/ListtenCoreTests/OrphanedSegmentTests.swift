import Foundation
import Testing

@testable import ListtenCore

/// The crash the write-ahead log is for, followed by the gap it left: a file
/// closed on disk before anything recorded that it had.
@Test("a segment on disk that no checkpoint names is adopted, not lost")
func orphanedSegmentIsAdopted() async throws {
    let store = InMemorySessionStore()
    var session = try Session(id: "aaa", startedAt: .init(timeIntervalSince1970: 0))
        .applying(.confirm)
    session = try session.appending(
        Segment(index: 0, track: .microphone, start: 0, duration: 5)
    )
    try await store.save(session)

    // Index 1 reached disk; the process died before anything said so.
    let audio = FakeRecordedAudio(segments: [
        "aaa": [
            SegmentFile(
                track: .microphone,
                index: 0,
                duration: 5,
                url: URL(filePath: "/memory/0.caf")
            ),
            SegmentFile(
                track: .microphone,
                index: 1,
                duration: 3.2,
                url: URL(filePath: "/memory/1.caf")
            ),
        ]
    ])

    let recovery = try await ResumeInterrupted(
        sessions: store,
        progress: InMemoryProgressLog(),
        audio: audio,
        minimumDuration: 1
    )()

    let resumed = try #require(recovery.resumed.first?.session)
    #expect(resumed.segments.count == 2)
    #expect(resumed.duration == 8.2)
    #expect(try await store.load(id: "aaa")?.segments.count == 2)
}

@Test("adopting the same file twice does not count it twice")
func adoptionIsIdempotent() async throws {
    let store = InMemorySessionStore()
    try await store.save(
        try Session(id: "aaa", startedAt: .init(timeIntervalSince1970: 0)).applying(.confirm)
    )
    let audio = FakeRecordedAudio(segments: [
        "aaa": [
            SegmentFile(
                track: .microphone,
                index: 0,
                duration: 4,
                url: URL(filePath: "/memory/0.caf")
            )
        ]
    ])
    let resume = ResumeInterrupted(
        sessions: store,
        progress: InMemoryProgressLog(),
        audio: audio,
        minimumDuration: 1
    )

    _ = try await resume()
    _ = try await resume()

    #expect(try await store.load(id: "aaa")?.segments.count == 1)
}

/// An audio directory nobody can list is a session that might be missing a
/// segment nobody can find, which has to be said rather than assumed empty.
@Test("an audio directory that cannot be listed is named, and costs nothing else")
func unlistableAudioIsNamed() async throws {
    let store = InMemorySessionStore()
    try await store.save(
        try Session(id: "aaa", startedAt: .init(timeIntervalSince1970: 0))
            .applying(.confirm)
            .appending(Segment(index: 0, track: .microphone, start: 0, duration: 90))
    )

    let recovery = try await ResumeInterrupted(
        sessions: store,
        progress: InMemoryProgressLog(),
        audio: FailingRecordedAudio(),
        minimumDuration: 60
    )()

    #expect(recovery.unreadableAudio == ["aaa"])
    #expect(recovery.resumed.map(\.session.state) == [.recorded])
}
