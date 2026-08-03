import Foundation
import Synchronization
import Testing

@testable import ListtenCore

private let meeting = MeetingNote(
    title: "Weekly sync",
    summary: "Migration slipped a week. The room booking is still open.",
    actionItems: ["Paulo drafts the migration plan"],
    transcript: Transcript(lines: [
        try! TranscriptLine(speaker: "microphone", start: 0, end: 2, text: "Shall we start?")
    ])
)

/// Where the outcomes the writer logs are kept, since the sink is called from
/// whichever thread the hook finished on.
private final class HookLog: Sendable {
    private let outcomes = Mutex<[HookOutcome]>([])

    func append(_ outcome: HookOutcome) {
        outcomes.withLock { $0.append(outcome) }
    }

    var everything: [HookOutcome] {
        outcomes.withLock { $0 }
    }
}

/// A hook, a destination and somewhere to keep what the hook said.
private struct Wired {
    let writer: HookedNoteWriter
    let sessionsRoot: URL
    let destination: URL
    let logged: HookLog

    func outcomes() -> [HookOutcome] {
        logged.everything
    }

    func sessionDirectory(_ sessionID: String) -> URL {
        sessionsRoot.appending(path: sessionID)
    }
}

/// `hook` is the script body; the shebang and the execute bit are added here.
/// A nil body means no hook file at all, which is how a misconfigured path
/// looks from the outside.
private func wire(
    in root: URL,
    hook body: String?,
    timeout: Duration = .seconds(5)
) throws -> Wired {
    let sessionsRoot = root.appending(path: "Sessions")
    let destination = root.appending(path: "Notes")
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

    let script = root.appending(path: "hook.sh")
    if let body {
        try writeScript(body, to: script)
    }

    let logged = HookLog()
    return Wired(
        writer: HookedNoteWriter(
            writing: MarkdownNoteWriter(sessionsRoot: sessionsRoot, destination: destination),
            hook: ProcessNoteHook(executable: script, timeout: timeout),
            log: { logged.append($0) }
        ),
        sessionsRoot: sessionsRoot,
        destination: destination,
        logged: logged
    )
}

private func contents(of url: URL) -> String? {
    FileManager.default.contents(atPath: url.path).map { String(decoding: $0, as: UTF8.self) }
}

/// The strongest statement of the rule the design turns on: with a hook that
/// fails behind it, the writer still owes exactly what the port promises.
@Test("a writer with a failing hook behind it honours the note contract unchanged")
func hookedWriterHonoursTheNoteContract() async throws {
    let parent = temporaryRoot()
    defer { removeTemporaryTree(parent) }
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

    let script = parent.appending(path: "always-fails.sh")
    try writeScript("echo 'the hook fell over' >&2\nexit 1\n", to: script)

    try await verifyNoteWritingContract {
        let root = parent.appending(path: UUID().uuidString)
        let destination = root.appending(path: "Notes")
        try! FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let writer = HookedNoteWriter(
            writing: MarkdownNoteWriter(
                sessionsRoot: root.appending(path: "Sessions"),
                destination: destination
            ),
            hook: ProcessNoteHook(executable: script, timeout: .seconds(5)),
            log: { _ in }
        )
        return NoteWriterUnderTest(
            writer: writer,
            contents: { contents(of: $0) },
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

@Test("a hook that fails runs, is logged, and leaves the note where it is")
func failingHookIsLoggedAndCostsNothing() async throws {
    let root = temporaryRoot()
    defer { removeTemporaryTree(root) }

    let wired = try wire(in: root, hook: "touch \"$1/hook-ran\"\nexit 1\n")
    let location = try await wired.writer.write(meeting, for: "alpha")

    #expect(
        FileManager.default.fileExists(
            atPath: wired.sessionDirectory("alpha").appending(path: "hook-ran").path
        ),
        "the hook never ran, so nothing here says what happens when it fails"
    )
    #expect(wired.outcomes().map(\.result) == [.exited(code: 1)])
    #expect(contents(of: location.delivered)?.contains(meeting.summary) == true)
}

@Test("a hook that hangs is stopped and the note is still delivered")
func hangingHookIsStoppedAndTheNoteSurvives() async throws {
    let root = temporaryRoot()
    defer { removeTemporaryTree(root) }

    let wired = try wire(
        in: root,
        hook: "touch \"$1/hook-ran\"\ntrap '' TERM\nsleep 30\n",
        timeout: .seconds(2)
    )

    let started = ContinuousClock.now
    let location = try await wired.writer.write(meeting, for: "alpha")
    let took = ContinuousClock.now - started

    #expect(
        FileManager.default.fileExists(
            atPath: wired.sessionDirectory("alpha").appending(path: "hook-ran").path
        ),
        "the hook never ran, so the timeout was never what returned"
    )
    #expect(took < .seconds(6), "the write waited \(took) on a hook with a 2s timeout")
    #expect(wired.outcomes().map(\.result) == [.timedOut])
    #expect(contents(of: location.delivered)?.contains(meeting.summary) == true)
}

@Test("a hook that is not there is logged, not raised")
func missingHookIsLoggedNotRaised() async throws {
    let root = temporaryRoot()
    defer { removeTemporaryTree(root) }

    let wired = try wire(in: root, hook: nil)
    let location = try await wired.writer.write(meeting, for: "alpha")

    #expect(wired.outcomes().map(\.result) == [.notFound])
    #expect(contents(of: location.delivered)?.contains(meeting.summary) == true)
}

/// The hook reads the note back, so this fails for a hook run any earlier than
/// the moment the note is complete on disk.
@Test("the hook sees the finished note, not a note being written")
func hookRunsAfterTheNoteIsComplete() async throws {
    let root = temporaryRoot()
    defer { removeTemporaryTree(root) }

    let wired = try wire(in: root, hook: "cat \"$1/note.md\"\n")
    let location = try await wired.writer.write(meeting, for: "alpha")

    // Against what the note says, never against the file as it stands now: a
    // hook that read a half-written note and a file that is half-written match
    // each other perfectly.
    let said = wired.outcomes().map(\.output).joined()
    for expected in meeting.everythingItSays {
        #expect(said.contains(expected), "the note the hook read leaves out \(expected)")
    }
    #expect(said == contents(of: location.delivered), "the hook read \(said)")
}

@Test("what the hook says goes to the log and never into the note")
func hookOutputStaysOutOfTheNote() async throws {
    let root = temporaryRoot()
    defer { removeTemporaryTree(root) }

    let shouted = "HOOK SAID THIS"
    let wired = try wire(in: root, hook: "echo '\(shouted)'\necho '\(shouted)' >&2\n")
    let location = try await wired.writer.write(meeting, for: "alpha")

    #expect(wired.outcomes().map(\.output) == ["\(shouted)\n\(shouted)\n"])
    #expect(contents(of: location.kept)?.contains(shouted) == false)
    #expect(contents(of: location.delivered)?.contains(shouted) == false)
}

@Test("a note that never reached the destination does not run the hook")
func undeliveredNoteDoesNotRunTheHook() async throws {
    let root = temporaryRoot()
    defer { removeTemporaryTree(root) }

    let wired = try wire(in: root, hook: "touch \"$1/hook-ran\"\n")
    try FileManager.default.removeItem(at: wired.destination)

    await #expect(throws: NoteNotDelivered.self) {
        try await wired.writer.write(meeting, for: "alpha")
    }
    #expect(
        !FileManager.default.fileExists(
            atPath: wired.sessionDirectory("alpha").appending(path: "hook-ran").path
        ),
        "the hook ran for a note that was never delivered"
    )
    #expect(wired.outcomes().isEmpty)
}

/// A writer that says the note was delivered when it was not. Nothing about a
/// copy is certain until the bytes are read back, and the hook is the thing
/// that acts on the claim.
private struct MisreportingWriter: NoteWriting {
    enum Delivery {
        case differs, missing
    }

    let root: URL
    let delivery: Delivery

    func write(_ note: MeetingNote, for sessionID: String) async throws -> NoteLocation {
        let directory = root.appending(path: sessionID)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let kept = directory.appending(path: "note.md")
        try Data("# \(note.title)\n\n\(note.summary)\n".utf8).write(to: kept)

        let delivered = directory.appending(path: "delivered.md")
        if delivery == .differs {
            try Data("# \(note.title)\n".utf8).write(to: delivered)
        }
        return NoteLocation(kept: kept, delivered: delivered)
    }
}

@Test(
    "a delivered note that is not the note kept is a failure, and the hook does not run",
    arguments: [MisreportingWriter.Delivery.differs, .missing]
)
private func unverifiedDeliveryStopsTheHook(delivery: MisreportingWriter.Delivery) async throws {
    let root = temporaryRoot()
    defer { removeTemporaryTree(root) }

    let script = root.appending(path: "hook.sh")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try writeScript("touch \"$1/hook-ran\"\n", to: script)

    let logged = HookLog()
    let writer = HookedNoteWriter(
        writing: MisreportingWriter(root: root, delivery: delivery),
        hook: ProcessNoteHook(executable: script, timeout: .seconds(5)),
        log: { logged.append($0) }
    )

    await #expect(throws: NoteNotDelivered.self) {
        try await writer.write(meeting, for: "alpha")
    }
    #expect(
        !FileManager.default.fileExists(
            atPath: root.appending(path: "alpha/hook-ran").path
        ),
        "the hook ran for a note whose delivery was never verified"
    )
    #expect(logged.everything.isEmpty)
}

private let repositoryRoot = URL(filePath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()

/// The example in the repository is the first hook anyone runs. One that no
/// longer works is a defect like any other, so it runs here too.
///
/// Launched here rather than through `ProcessNoteHook`, because telling it
/// where to copy means setting a variable, and `setenv` would reach into the
/// environment every other test in this file is reading at the same time.
@Test("the example hook that ships copies the note where it is told")
func exampleHookCopiesTheNote() async throws {
    let root = temporaryRoot()
    defer { removeTemporaryTree(root) }

    let copiedTo = root.appending(path: "Copied")
    let destination = root.appending(path: "Notes")
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

    let location = try await MarkdownNoteWriter(
        sessionsRoot: root.appending(path: "Sessions"),
        destination: destination
    )
    .write(meeting, for: "alpha")
    let sessionDirectory = location.kept.deletingLastPathComponent()

    let example = Process()
    example.executableURL = repositoryRoot.appending(path: "scripts/hooks/example.sh")
    example.arguments = [sessionDirectory.path]
    example.environment = [
        "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
        ProcessNoteHook.environmentKey: sessionDirectory.path,
        "LISTTEN_HOOK_DESTINATION": copiedTo.path,
    ]
    let said = Pipe()
    example.standardOutput = said
    example.standardError = said
    try example.run()
    let output = said.fileHandleForReading.readDataToEndOfFile()
    example.waitUntilExit()

    #expect(
        example.terminationStatus == 0,
        "the example exited \(example.terminationStatus) saying \(String(decoding: output, as: UTF8.self))"
    )
    let copied = contents(of: copiedTo.appending(path: "alpha.md"))
    for expected in meeting.everythingItSays {
        #expect(
            copied?.contains(expected) == true,
            "what the example copied leaves out \(expected)"
        )
    }
    #expect(copied == contents(of: location.delivered))
}
