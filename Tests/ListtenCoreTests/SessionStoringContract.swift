import Foundation
import Testing

@testable import ListtenCore

/// The rules every `SessionStoring` obeys, written once so the in-memory fake
/// cannot drift away from the store that writes files. The ordering guarantee
/// went missing once already because only the tidier implementation was tested.
func verifySessionStoringContract(
    _ make: @Sendable () -> any SessionStoring,
    sourceLocation: SourceLocation = #_sourceLocation
) async throws {
    let empty = make()
    #expect(try await empty.load(id: "never-saved") == nil, sourceLocation: sourceLocation)
    #expect(try await empty.unfinished().isEmpty, sourceLocation: sourceLocation)

    let store = make()
    let recording = try armed("delta")
        .applying(.confirm)
        .appending(Segment(index: 0, track: .microphone, start: 0, duration: 45))
    try await store.save(recording)
    for id in ["foxtrot", "alpha", "bravo"] {
        try await store.save(armed(id))
    }
    // Saved in an order no listing is likely to reproduce, so an implementation
    // that leaves the order to its storage cannot pass by luck.
    for id in ["charlie", "echo"] {
        try await store.save(try armed(id).applying(.discard))
    }

    #expect(try await store.load(id: "delta") == recording, sourceLocation: sourceLocation)
    #expect(try await store.load(id: "never-saved") == nil, sourceLocation: sourceLocation)
    #expect(
        try await store.unfinished().map(\.id) == ["alpha", "bravo", "delta", "foxtrot"],
        "unfinished is ordered by id and leaves out terminal states",
        sourceLocation: sourceLocation
    )

    let stopped = try recording.stopping(minimumDuration: 30)
    try await store.save(stopped)
    #expect(try await store.load(id: "delta") == stopped, sourceLocation: sourceLocation)

    try await store.save(try stopped.applying(.discard))
    #expect(
        try await store.unfinished().map(\.id) == ["alpha", "bravo", "foxtrot"],
        "a session that reached a terminal state drops out of the listing",
        sourceLocation: sourceLocation
    )
}

private func armed(_ id: String) -> Session {
    Session(id: id, startedAt: .init(timeIntervalSince1970: 1))
}

@Test("the in-memory store honours the contract")
func inMemoryStoreHonoursTheContract() async throws {
    try await verifySessionStoringContract { InMemorySessionStore() }
}

@Test("the file store honours the same contract as the fake")
func fileStoreHonoursTheContract() async throws {
    let parent = temporaryRoot()
    try await verifySessionStoringContract {
        FileSessionStore(root: parent.appending(path: UUID().uuidString))
    }
    try FileManager.default.removeItem(at: parent)
}

/// Never created here: whether a store copes with a root that is not there yet
/// is part of what the tests ask.
func temporaryRoot() -> URL {
    FileManager.default.temporaryDirectory.appending(path: "listten-\(UUID().uuidString)")
}
