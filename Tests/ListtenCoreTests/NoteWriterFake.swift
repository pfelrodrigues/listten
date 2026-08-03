import Foundation

@testable import ListtenCore

/// A destination that is not a disk. It renders in its own plain format on
/// purpose: what the contract asks of a note is what it says, not how a
/// markdown file is laid out.
actor InMemoryNoteWriter: NoteWriting {
    /// Stands for whatever the filesystem refuses with.
    struct Unavailable: Error, Equatable {
        let reason: String
    }

    private enum Destination {
        case open, readOnly, missing
    }

    private static let sessions = URL(filePath: "/memory/sessions")
    private static let notes = URL(filePath: "/memory/notes")

    private var stored: [URL: String] = [:]
    private var destination = Destination.open

    func makeDestinationReadOnly() {
        destination = .readOnly
    }

    func removeDestination() {
        destination = .missing
        stored = stored.filter { !$0.key.path.hasPrefix(Self.notes.path) }
    }

    func contents(of url: URL) -> String? {
        stored[url]
    }

    func write(_ note: MeetingNote, for sessionID: String) async throws -> NoteLocation {
        let written = Self.render(note)
        let kept = Self.sessions.appending(path: sessionID).appending(path: "note.md")
        stored[kept] = written

        guard destination == .open else {
            throw NoteNotDelivered(kept: kept, underlying: Unavailable(reason: "\(destination)"))
        }

        var suffix = 1
        var delivered = Self.notes.appending(path: "\(note.title).md")
        while stored[delivered] != nil {
            suffix += 1
            delivered = Self.notes.appending(path: "\(note.title)-\(suffix).md")
        }
        // Copied from what was kept, like the writer that moves bytes.
        stored[delivered] = written
        return NoteLocation(kept: kept, delivered: delivered)
    }

    /// Spelled out rather than derived from what the contract expects, so a fake
    /// that stopped saying one of those things can still fail.
    private static func render(_ note: MeetingNote) -> String {
        var written = [note.title, note.summary] + note.actionItems
        written += note.transcript.lines.map { "\($0.speaker): \($0.text)" }
        return written.joined(separator: "\n")
    }
}
