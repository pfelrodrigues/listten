import Foundation
import Testing

@testable import ListtenCore

/// The fakes are how the suite stays predictable, so their own guarantees are
/// worth a test.
@Test("the store lists unfinished sessions in a stable order")
func unfinishedSessionsComeBackInAStableOrder() async throws {
    let store = InMemorySessionStore()
    for id in ["delta", "alpha", "charlie", "bravo", "echo", "foxtrot"] {
        try await store.save(Session(id: id, startedAt: .init(timeIntervalSince1970: 0)))
    }

    let listed = try await store.unfinished().map(\.id)

    #expect(listed == ["alpha", "bravo", "charlie", "delta", "echo", "foxtrot"])
}
