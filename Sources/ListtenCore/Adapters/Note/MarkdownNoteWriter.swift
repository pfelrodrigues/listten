import Foundation

/// The note as plain markdown: a heading, the summary, action items and the
/// transcript. No frontmatter and no identifiers, so it reads on its own.
///
/// It is written under the session directory first and copied to the configured
/// folder afterwards, which is what makes an unavailable destination cost the
/// copy rather than the note.
public struct MarkdownNoteWriter: NoteWriting {
    public enum Failure: Error, Equatable {
        case destinationUnavailable(path: String)
    }

    /// One note per session directory, under a name that does not change with
    /// the title: a rewrite replaces the session's own note rather than piling
    /// up beside it.
    static let keptFileName = "note.md"

    private let sessionsRoot: URL
    private let destination: URL

    public init(sessionsRoot: URL, destination: URL) {
        self.sessionsRoot = sessionsRoot
        self.destination = destination
    }

    public func write(_ note: MeetingNote, for sessionID: String) async throws -> NoteLocation {
        // The session directory is this session's own, so it is created. The
        // destination never is: see `deliver`.
        let directory = sessionsRoot.appending(path: sessionID)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let kept = directory.appending(path: Self.keptFileName)

        try Data(Self.markdown(for: note).utf8).write(to: kept)

        do {
            return NoteLocation(kept: kept, delivered: try deliver(kept, as: note.title))
        } catch {
            throw NoteNotDelivered(kept: kept, underlying: error)
        }
    }

    private func deliver(_ kept: URL, as title: String) throws -> URL {
        var isDirectory: ObjCBool = false
        // Never created. An unmounted volume looks exactly like a folder that is
        // not there, and creating it would write a phantom note onto the boot
        // disk and report the meeting filed.
        guard
            FileManager.default.fileExists(atPath: destination.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else { throw Failure.destinationUnavailable(path: destination.path) }

        // Copied rather than rendered again, so what is delivered is the note
        // that was kept and not a second rendering of it.
        let target = firstFreeURL(for: Self.fileName(for: title))
        try FileManager.default.copyItem(at: kept, to: target)
        return target
    }

    /// Never overwrites: a note already there belongs to another meeting, and
    /// two meetings may share a title without either being a copy.
    private func firstFreeURL(for name: String) -> URL {
        var suffix = 1
        var candidate = destination.appending(path: "\(name).md")
        while FileManager.default.fileExists(atPath: candidate.path) {
            suffix += 1
            candidate = destination.appending(path: "\(name)-\(suffix).md")
        }
        return candidate
    }

    /// Named after the title, since that is what a human browses. Only what a
    /// path cannot hold is replaced; a name that would hide the file, or leave
    /// none at all, falls back.
    static func fileName(for title: String) -> String {
        let cleaned =
            title
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        return cleaned.isEmpty ? "note" : cleaned
    }

    static func markdown(for note: MeetingNote) -> String {
        let sections = [
            "# \(note.title)",
            note.summary,
            section("Action items", note.actionItems.map { "- [ ] \($0)" }),
            // A blank line between utterances, since markdown folds consecutive
            // lines into one paragraph and a transcript is not a paragraph.
            section(
                "Transcript",
                note.transcript.lines.map { "**\($0.speaker):** \($0.text)" },
                separatedBy: "\n\n"
            ),
        ]
        return sections.filter { !$0.isEmpty }.joined(separator: "\n\n") + "\n"
    }

    /// A heading over nothing is left out: an empty section reads as a note that
    /// lost its content rather than as a meeting with no actions.
    private static func section(
        _ heading: String,
        _ body: [String],
        separatedBy separator: String = "\n"
    ) -> String {
        body.isEmpty ? "" : "## \(heading)\n\n" + body.joined(separator: separator)
    }
}
