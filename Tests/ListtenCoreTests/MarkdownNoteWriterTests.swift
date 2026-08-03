import Foundation
import Testing

@testable import ListtenCore

// A computed property because building a line can throw, and a file-scope
// constant has nowhere to throw to.
private var meeting: MeetingNote {
    get throws {
        MeetingNote(
            title: "Weekly sync",
            summary: "Migration slipped a week.",
            actionItems: ["Paulo drafts the migration plan", "Ana books the room"],
            transcript: Transcript(lines: [
                try TranscriptLine(
                    speaker: "microphone",
                    start: 0,
                    end: 2,
                    text: "Shall we start?"
                ),
                try TranscriptLine(
                    speaker: "system",
                    start: 2,
                    end: 4,
                    text: "Give me a second."
                ),
            ])
        )
    }
}

@Test("the note is markdown a person can read with nothing else installed")
func noteReadsAsMarkdown() throws {
    let rendered = try MarkdownNoteWriter.markdown(for: meeting)
    #expect(
        rendered == """
            # Weekly sync

            Migration slipped a week.

            ## Action items

            - [ ] Paulo drafts the migration plan
            - [ ] Ana books the room

            ## Transcript

            **microphone:** Shall we start?

            **system:** Give me a second.

            """
    )
}

@Test("a section with nothing in it is left out rather than left empty")
func emptySectionsAreLeftOut() {
    let quiet = MeetingNote(
        title: "Standup",
        summary: "Nobody was blocked.",
        actionItems: [],
        transcript: Transcript(lines: [])
    )
    #expect(
        MarkdownNoteWriter.markdown(for: quiet) == """
            # Standup

            Nobody was blocked.

            """
    )
}

@Test(
    "the file is named after the title, minus what a path cannot hold",
    arguments: [
        ("Weekly sync", "Weekly sync"),
        ("1:1 with Ana", "1-1 with Ana"),
        ("Roadmap Q3/Q4", "Roadmap Q3-Q4"),
        (".env migration", "env migration"),
        ("  Retro  ", "Retro"),
        ("...", "note"),
        ("", "note"),
    ]
)
func fileIsNamedAfterTheTitle(title: String, expected: String) {
    #expect(MarkdownNoteWriter.fileName(for: title) == expected)
}

@Test("a destination that is not there is left alone, not created")
func missingDestinationIsNeverCreated() async throws {
    let root = temporaryRoot()
    let destination = root.appending(path: "Volumes/Archive/Notes")
    let writer = MarkdownNoteWriter(
        sessionsRoot: root.appending(path: "Sessions"),
        destination: destination
    )

    do {
        let landed = try await writer.write(try meeting, for: "alpha")
        Issue.record("the note was delivered to \(landed.delivered.path)")
    } catch let failure as NoteNotDelivered {
        #expect(
            failure.underlying as? MarkdownNoteWriter.Failure
                == .destinationUnavailable(path: destination.path)
        )
    }

    #expect(
        !FileManager.default.fileExists(atPath: destination.path),
        "an unmounted volume looks like this, and it now holds a note nobody will find"
    )
    removeTemporaryTree(root)
}

/// Otherwise both adversarial cases could be taking the same branch: a folder
/// that refuses the write reported as a folder that is not there would still
/// keep the note, and the copy would never be exercised at all.
@Test("a destination that is there but refuses the write fails on the copy")
func readOnlyDestinationFailsOnTheCopy() async throws {
    let root = temporaryRoot()
    defer { removeTemporaryTree(root) }

    let destination = root.appending(path: "Notes")
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o500],
        ofItemAtPath: destination.path
    )
    let writer = MarkdownNoteWriter(
        sessionsRoot: root.appending(path: "Sessions"),
        destination: destination
    )

    do {
        let landed = try await writer.write(try meeting, for: "alpha")
        Issue.record("the note was delivered to \(landed.delivered.path)")
    } catch let failure as NoteNotDelivered {
        #expect(
            failure.underlying as? MarkdownNoteWriter.Failure == nil,
            "a folder that is there was reported as one that is not"
        )
    }
}

@Test("rewriting a session replaces its own note instead of piling up beside it")
func rewritingASessionReplacesItsNote() async throws {
    let root = temporaryRoot()
    defer { removeTemporaryTree(root) }

    let destination = root.appending(path: "Notes")
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    let sessions = root.appending(path: "Sessions")
    let writer = MarkdownNoteWriter(sessionsRoot: sessions, destination: destination)

    let first = try await writer.write(try meeting, for: "alpha")
    let second = try await writer.write(try meeting, for: "alpha")

    #expect(first.kept == second.kept)
    #expect(
        try FileManager.default.contentsOfDirectory(atPath: sessions.appending(path: "alpha").path)
            == [MarkdownNoteWriter.keptFileName]
    )
}
