import Foundation
import Testing

@testable import ListtenCore

/// An implementation plus the two ways a destination goes away, since neither
/// can be written once: a folder is chmodded or deleted, a fake is told.
struct NoteWriterUnderTest {
    let writer: any NoteWriting
    /// Reads back what actually landed, so kept and delivered are compared as
    /// they were stored rather than as the writer remembers them.
    let contents: @Sendable (URL) async throws -> String?
    let makeDestinationReadOnly: @Sendable () async throws -> Void
    let removeDestination: @Sendable () async throws -> Void
}

/// The rules every `NoteWriting` obeys, written once so the in-memory fake
/// cannot drift away from the writer that touches disk. What matters here is
/// what a note says and what survives an unavailable destination; how the note
/// is laid out belongs to whichever adapter renders it.
func verifyNoteWritingContract(
    _ make: @Sendable () -> NoteWriterUnderTest,
    sourceLocation: SourceLocation = #_sourceLocation
) async throws {
    let note = MeetingNote(
        title: "Weekly sync",
        summary: "Migration slipped a week. The room booking is still open.",
        actionItems: ["Paulo drafts the migration plan", "Ana books the room"],
        transcript: Transcript(lines: [
            try TranscriptLine(speaker: "microphone", start: 0, end: 2, text: "Shall we start?"),
            try TranscriptLine(speaker: "system", start: 2, end: 4, text: "Give me a second."),
        ])
    )

    let subject = make()
    let first = try await subject.writer.write(note, for: "alpha")
    let kept = try await subject.contents(first.kept)
    let delivered = try await subject.contents(first.delivered)

    #expect(
        kept != nil,
        "nothing was kept in the session directory",
        sourceLocation: sourceLocation
    )
    #expect(
        kept == delivered,
        "what was delivered is not what was kept",
        sourceLocation: sourceLocation
    )
    for said in note.everythingItSays {
        #expect(
            kept?.contains(said) == true,
            "the note leaves out \(said)",
            sourceLocation: sourceLocation
        )
    }

    // Another meeting under the same title, saying something else: the
    // destination already holds a note of that name, and the earlier one is not
    // this one's to lose. Two titles that match are not one meeting.
    let namesake = MeetingNote(
        title: note.title,
        summary: "The room is booked. Migration is done.",
        actionItems: ["Ana closes the ticket"],
        transcript: Transcript(lines: [
            try TranscriptLine(speaker: "microphone", start: 0, end: 1, text: "That is everything.")
        ])
    )
    let second = try await subject.writer.write(namesake, for: "bravo")
    #expect(
        second.delivered != first.delivered,
        "the second note took the first one's name",
        sourceLocation: sourceLocation
    )
    #expect(
        try await subject.contents(first.delivered) == delivered,
        "the first note was overwritten by the second",
        sourceLocation: sourceLocation
    )
    for said in namesake.everythingItSays {
        #expect(
            try await subject.contents(second.delivered)?.contains(said) == true,
            "the second note did not land beside the first, or lost \(said)",
            sourceLocation: sourceLocation
        )
    }

    /// Delivery has to fail loudly and leave the whole note behind, since a
    /// caller that is told nothing has nothing to retry with.
    func expectTheNoteSurvives(
        _ broken: NoteWriterUnderTest,
        session: String,
        because reason: String
    ) async throws {
        do {
            let landed = try await broken.writer.write(note, for: session)
            Issue.record(
                "a \(reason) destination reported the note delivered to \(landed.delivered.path)",
                sourceLocation: sourceLocation
            )
        } catch let failure as NoteNotDelivered {
            #expect(
                try await broken.contents(failure.kept) == delivered,
                "a \(reason) destination cost the note itself",
                sourceLocation: sourceLocation
            )
        }
    }

    let readOnly = make()
    try await readOnly.makeDestinationReadOnly()
    try await expectTheNoteSurvives(readOnly, session: "charlie", because: "read-only")

    let absent = make()
    try await absent.removeDestination()
    try await expectTheNoteSurvives(absent, session: "delta", because: "missing")
}

extension MeetingNote {
    /// Everything the port promises a reader will find, whatever the layout.
    var everythingItSays: [String] {
        [title, summary] + actionItems
            + transcript.lines.flatMap { [$0.speaker, $0.text] }
    }
}

@Test("the in-memory writer honours the contract")
func inMemoryNoteWriterHonoursTheContract() async throws {
    try await verifyNoteWritingContract {
        let writer = InMemoryNoteWriter()
        return NoteWriterUnderTest(
            writer: writer,
            contents: { await writer.contents(of: $0) },
            makeDestinationReadOnly: { await writer.makeDestinationReadOnly() },
            removeDestination: { await writer.removeDestination() }
        )
    }
}

@Test("the markdown writer honours the same contract as the fake")
func markdownNoteWriterHonoursTheContract() async throws {
    let parent = temporaryRoot()
    // Deferred because the read-only case leaves a directory nothing can
    // delete, and a contract that throws would hand that on to the next run.
    defer { removeTemporaryTree(parent) }

    try await verifyNoteWritingContract {
        let root = parent.appending(path: UUID().uuidString)
        let destination = root.appending(path: "Notes")
        // Created here because the writer never creates it: whether it exists is
        // exactly what the contract asks about.
        try! FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        return NoteWriterUnderTest(
            writer: MarkdownNoteWriter(
                sessionsRoot: root.appending(path: "Sessions"),
                destination: destination
            ),
            contents: { url in
                FileManager.default.contents(atPath: url.path)
                    .map { String(decoding: $0, as: UTF8.self) }
            },
            makeDestinationReadOnly: {
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o500],
                    ofItemAtPath: destination.path
                )
            },
            removeDestination: { try FileManager.default.removeItem(at: destination) }
        )
    }
}

/// A tree these tests may have made undeletable. Write permission goes back
/// before anything is removed, since a read-only directory cannot be emptied,
/// and a cleanup that quietly failed would leave the next run to trip over it.
/// Root would not notice any of this, and CI does not run as root.
func removeTemporaryTree(_ root: URL) {
    struct NothingToRestore: Error {
        let path: String
    }

    do {
        guard
            let entries = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        else { throw NothingToRestore(path: root.path) }
        for case let entry as URL in entries {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: entry.path
            )
        }
        try FileManager.default.removeItem(at: root)
    } catch {
        Issue.record("the temporary tree at \(root.path) survived: \(error)")
    }
}
