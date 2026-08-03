import Foundation
import Testing

@testable import ListtenCore

private func session(_ id: String) -> Session {
    Session(id: id, startedAt: .init(timeIntervalSince1970: 1))
}

private func stateFile(in root: URL, id: String) -> URL {
    root.appending(path: id).appending(path: FileSessionStore.stateFileName)
}

/// Permission tests are vacuous as root, which is exactly the shape of guard
/// this project keeps being bitten by, so the barrier is asserted before it is
/// leaned on.
private func expectNotWritable(_ url: URL, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(
        !FileManager.default.isWritableFile(atPath: url.path),
        "\(url.lastPathComponent) is writable, so the failure it stands for never happened",
        sourceLocation: sourceLocation
    )
}

private func expectNotReadable(_ url: URL, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(
        !FileManager.default.isReadableFile(atPath: url.path),
        "\(url.lastPathComponent) is readable, so the failure it stands for never happened",
        sourceLocation: sourceLocation
    )
}

@Test("a root that does not exist yet reads as empty and is created on the first save")
func missingRootIsCreatedOnDemand() async throws {
    let root = temporaryRoot()
    let store = FileSessionStore(root: root)

    #expect(try await store.load(id: "2026-01-01") == nil)
    #expect(try await store.unfinished() == UnfinishedSessions(sessions: []))

    try await store.save(session("2026-01-01"))

    #expect(try await store.load(id: "2026-01-01") == session("2026-01-01"))
    try FileManager.default.removeItem(at: root)
}

@Test("a truncated state file is an error rather than a session that was never saved")
func truncatedStateFileIsAnError() async throws {
    let root = temporaryRoot()
    let store = FileSessionStore(root: root)
    try await store.save(session("2026-01-01"))
    try await store.save(session("2026-01-02"))
    try Data(#"{"id":"2026-01-01","started"#.utf8).write(to: stateFile(in: root, id: "2026-01-01"))

    let failure = await #expect(throws: FileSessionStore.UnreadableSession.self) {
        _ = try await store.load(id: "2026-01-01")
    }

    // Named, not merely thrown: an error that cannot say which session it lost
    // leaves the caller nothing to report.
    #expect(failure?.id == "2026-01-01")
    #expect(failure?.underlying is DecodingError)

    // A second session in the root, so the listing can tell "this one is
    // unreadable" apart from "nothing here can be read".
    let scan = try await store.unfinished()
    #expect(scan.sessions == [session("2026-01-02")])
    #expect(scan.unreadable == ["2026-01-01"])
    try FileManager.default.removeItem(at: root)
}

@Test("a state file that cannot be read is named like one that cannot be parsed")
func unreadableStateFileIsAnError() async throws {
    let root = temporaryRoot()
    let store = FileSessionStore(root: root)
    try await store.save(session("2026-01-01"))
    try await store.save(session("2026-01-02"))

    let file = stateFile(in: root, id: "2026-01-01")
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
    expectNotReadable(file)

    let failure = await #expect(throws: FileSessionStore.UnreadableSession.self) {
        _ = try await store.load(id: "2026-01-01")
    }

    #expect(failure?.id == "2026-01-01")
    #expect((failure?.underlying as? CocoaError)?.code == .fileReadNoPermission)
    #expect(
        try await store.unfinished()
            == UnfinishedSessions(sessions: [session("2026-01-02")], unreadable: ["2026-01-01"]),
        "a file that cannot be read takes none of its neighbours with it"
    )

    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    try FileManager.default.removeItem(at: root)
}

/// The first save is the one that can leave a directory holding no state: it
/// creates the directory before the temporary file it renames into place.
@Test("a session directory holding only what a crash left behind reads as nothing saved")
func sessionDirectoryWithoutStateFileIsNothingSaved() async throws {
    let root = temporaryRoot()
    let store = FileSessionStore(root: root)
    let directory = root.appending(path: "2026-01-01")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let leftover = FileSessionStore.temporaryURL(for: stateFile(in: root, id: "2026-01-01"))
    try Data(#"{"id":"2026-01-01","started"#.utf8).write(to: leftover)

    #expect(try await store.load(id: "2026-01-01") == nil)
    #expect(try await store.unfinished() == UnfinishedSessions(sessions: []))
    try FileManager.default.removeItem(at: root)
}

@Test("a session directory that cannot be entered is an error rather than nothing saved")
func unreadableSessionDirectoryIsAnError() async throws {
    let root = temporaryRoot()
    let store = FileSessionStore(root: root)
    try await store.save(session("2026-01-01"))
    try await store.save(session("2026-01-02"))

    let directory = root.appending(path: "2026-01-01")
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: directory.path)
    expectNotReadable(directory)

    let failure = await #expect(throws: FileSessionStore.UnreadableSession.self) {
        _ = try await store.load(id: "2026-01-01")
    }

    #expect(failure?.id == "2026-01-01")
    #expect((failure?.underlying as? CocoaError)?.code == .fileReadNoPermission)
    #expect(
        try await store.unfinished()
            == UnfinishedSessions(sessions: [session("2026-01-02")], unreadable: ["2026-01-01"]),
        "state behind a directory nobody can enter is named, not dropped from both lists"
    )

    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    try FileManager.default.removeItem(at: root)
}

@Test("a write that fails leaves the previous state readable")
func failedWriteKeepsThePreviousState() async throws {
    let root = temporaryRoot()
    let store = FileSessionStore(root: root)
    let saved = session("2026-01-01")
    try await store.save(saved)

    let directory = root.appending(path: saved.id)
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
    expectNotWritable(directory)

    await #expect(throws: (any Error).self) {
        try await store.save(try saved.applying(.confirm))
    }
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)

    #expect(try await store.load(id: saved.id) == saved)
    try FileManager.default.removeItem(at: root)
}

/// The other half of a failed write: the temporary file lands and the move is
/// what fails, which is the only path through the rename guard.
@Test("a move that fails reports where it failed and what the system said")
func failedMoveReportsTheReason() async throws {
    let root = temporaryRoot()
    let store = FileSessionStore(root: root)
    let saved = session("2026-01-01")
    try await store.save(saved)

    // A rename onto a directory cannot succeed, whatever the temporary write did.
    let file = stateFile(in: root, id: saved.id)
    try FileManager.default.removeItem(at: file)
    try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)

    let failure = await #expect(throws: FileSessionStore.WriteFailed.self) {
        try await store.save(try saved.applying(.confirm))
    }

    #expect(failure?.path == file.path)
    #expect(failure?.code == EISDIR)
    try FileManager.default.removeItem(at: root)
}

/// The discriminating case: `rename` needs the directory, not the file, so it
/// replaces state a plain write could not open.
@Test("a state file that cannot be opened for writing is still replaced")
func readOnlyStateFileIsStillReplaced() async throws {
    let root = temporaryRoot()
    let store = FileSessionStore(root: root)
    let saved = session("2026-01-01")
    try await store.save(saved)

    let file = stateFile(in: root, id: saved.id)
    try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: file.path)
    expectNotWritable(file)

    let recording = try saved.applying(.confirm)
    try await store.save(recording)

    #expect(try await store.load(id: saved.id) == recording)
    try FileManager.default.removeItem(at: root)
}

@Test("a crash between the temporary write and the rename leaves the previous state intact")
func crashBeforeTheRenameKeepsThePreviousState() async throws {
    let root = temporaryRoot()
    let store = FileSessionStore(root: root)
    let saved = session("2026-01-01")
    try await store.save(saved)

    let file = stateFile(in: root, id: saved.id)
    let interrupted = try JSONEncoder().encode(try saved.applying(.confirm))
    let leftover = FileSessionStore.temporaryURL(for: file)
    try interrupted.write(to: leftover)
    #expect(FileManager.default.fileExists(atPath: leftover.path), "the crash left nothing behind")

    #expect(try await store.load(id: saved.id) == saved)
    #expect(try await store.unfinished() == UnfinishedSessions(sessions: [saved]))
    try FileManager.default.removeItem(at: root)
}

@Test("a save that succeeds leaves no temporary file behind")
func successfulSaveLeavesNoTemporaryFile() async throws {
    let root = temporaryRoot()
    let store = FileSessionStore(root: root)
    try await store.save(session("2026-01-01"))
    try await store.save(try session("2026-01-01").applying(.confirm))

    let written = try FileManager.default.contentsOfDirectory(
        atPath: root.appending(path: "2026-01-01").path
    )

    #expect(written == [FileSessionStore.stateFileName])
    try FileManager.default.removeItem(at: root)
}

@Test("an entry in the root that holds no state file is not a session")
func entryWithoutStateFileIsIgnored() async throws {
    let root = temporaryRoot()
    let store = FileSessionStore(root: root)
    try await store.save(session("2026-01-01"))
    try Data().write(to: root.appending(path: ".DS_Store"))

    let scan = try await store.unfinished()
    #expect(scan.sessions.map(\.id) == ["2026-01-01"])
    #expect(scan.unreadable.isEmpty, "an entry that is not a session directory is not lost state")
    try FileManager.default.removeItem(at: root)
}
