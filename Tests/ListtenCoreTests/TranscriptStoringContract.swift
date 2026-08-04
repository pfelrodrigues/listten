import Foundation
import Testing

@testable import ListtenCore

/// Built through the only door there is: correction is derived from a glossary,
/// so the two transcripts differ exactly where a store that kept one of them
/// would be caught.
private func transcript(_ heard: String, corrected: String) throws -> CorrectedTranscript {
    try CorrectedTranscript(
        raw: Transcript(lines: [
            try TranscriptLine(speaker: "", start: 0, end: 2, text: heard)
        ]),
        glossary: heard == corrected
            ? Glossary(entries: [])
            : Glossary(entries: [.init(term: corrected, heardAs: [heard])])
    )
}

/// An implementation plus the one thing no caller can do to it: damage what is
/// on disk. Nil means no transcript was ever made, so a store that read a
/// damaged one as nil would transcribe again and overwrite it.
struct TranscriptStoreUnderTest {
    let store: any TranscriptStoring
    let damage: @Sendable (String) async throws -> Void
}

/// The rules every `TranscriptStoring` obeys, written once so the in-memory fake
/// cannot drift away from the store that touches disk. What is checked is what a
/// caller depends on: both transcripts survive, absence reads as absence, and
/// one session's transcript is never another's.
func verifyTranscriptStoringContract(
    _ make: @Sendable () -> TranscriptStoreUnderTest,
    sourceLocation: SourceLocation = #_sourceLocation
) async throws {
    let subject = make().store

    #expect(
        try await subject.load(for: "never-saved") == nil,
        "a session nothing was saved for came back with something",
        sourceLocation: sourceLocation
    )

    let alpha = try transcript("the migration", corrected: "the cutover")
    // Otherwise every check below holds for a store that keeps one transcript
    // and hands it back twice.
    try #require(
        alpha.raw != alpha.corrected,
        "the fixture cannot tell the two transcripts apart",
        sourceLocation: sourceLocation
    )
    try await subject.save(alpha, for: "alpha")

    let read = try #require(
        await subject.load(for: "alpha"),
        "what was saved did not come back",
        sourceLocation: sourceLocation
    )
    #expect(
        read.raw == alpha.raw,
        "the raw transcript did not survive",
        sourceLocation: sourceLocation
    )
    #expect(
        read.corrected == alpha.corrected,
        "the corrected transcript did not survive",
        sourceLocation: sourceLocation
    )

    // Another session, so a store keyed on nothing at all is caught here rather
    // than by a user finding one meeting's words under another's name.
    let bravo = try transcript("the room booking", corrected: "the room booking")
    try await subject.save(bravo, for: "bravo")
    #expect(
        try await subject.load(for: "alpha")?.raw == alpha.raw,
        "saving one session overwrote another",
        sourceLocation: sourceLocation
    )
    #expect(try await subject.load(for: "bravo")?.raw == bravo.raw, sourceLocation: sourceLocation)

    // Running processing again produces a new transcript for the same session,
    // and the older one is not what a note should be written from.
    let redone = try transcript("the migration slipped", corrected: "the cutover slipped")
    try await subject.save(redone, for: "alpha")
    #expect(
        try await subject.load(for: "alpha")?.corrected == redone.corrected,
        "a second run left the first run's transcript in place",
        sourceLocation: sourceLocation
    )

    let damaged = make()
    try await damaged.store.save(alpha, for: "alpha")
    try await damaged.damage("alpha")
    await #expect(
        throws: (any Error).self,
        "a damaged transcript was read as one that was never made",
        sourceLocation: sourceLocation
    ) {
        _ = try await damaged.store.load(for: "alpha")
    }
}

@Test("the in-memory transcript store honours the contract")
func inMemoryTranscriptsHonourTheContract() async throws {
    try await verifyTranscriptStoringContract {
        let store = InMemoryTranscripts()
        return TranscriptStoreUnderTest(store: store, damage: { await store.corrupt($0) })
    }
}

@Test("the file transcript store honours the same contract as the fake")
func fileTranscriptsHonourTheContract() async throws {
    let root = temporaryRoot()
    defer { removeTemporaryTree(root) }

    try await verifyTranscriptStoringContract {
        // A tree of its own per implementation under test, so the damaged one
        // does not decide what the next one reads.
        let storeRoot = root.appending(path: UUID().uuidString)
        return TranscriptStoreUnderTest(
            store: FileTranscripts(root: storeRoot),
            damage: { session in
                try Data("half a file".utf8)
                    .write(
                        to: storeRoot.appending(path: session).appending(path: "transcript.json")
                    )
            }
        )
    }
}

/// Written temp-then-rename, so a reader mid-save sees the whole previous
/// transcript or the whole new one. What is checked here is the part that is
/// checkable without a crash: nothing is left behind for the next run to read.
@Test("saving leaves no partial file beside the transcript")
func savingLeavesNothingHalfWritten() async throws {
    let root = temporaryRoot()
    defer { removeTemporaryTree(root) }
    let subject = FileTranscripts(root: root)

    try await subject.save(try transcript("one", corrected: "one"), for: "alpha")
    try await subject.save(try transcript("two", corrected: "two"), for: "alpha")

    let left = try FileManager.default.contentsOfDirectory(
        atPath: root.appending(path: "alpha").path
    )
    #expect(left == ["transcript.json"], "left behind \(left)")
}
