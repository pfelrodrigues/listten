import Foundation
import Testing

@testable import ListtenCore

/// What the contract cannot ask of every implementation, because it is about
/// child processes: how the directory reaches the hook, and what a hook that is
/// not a program at all does.
@Test("the session directory arrives as the argument and in the environment")
func hookIsToldTheSessionDirectoryTwice() async throws {
    let root = temporaryRoot()
    defer { removeTemporaryTree(root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let script = root.appending(path: "reports-both.sh")
    try writeScript("printf '%s\\n%s\\n' \"$1\" \"$LISTTEN_SESSION_DIR\"\n", to: script)

    let sessionDirectory = root.appending(path: "Sessions/alpha")
    let outcome = await ProcessNoteHook(executable: script, timeout: .seconds(5))
        .run(after: sessionDirectory)

    #expect(outcome.result == .exited(code: 0))
    #expect(
        outcome.output.split(separator: "\n") == [
            Substring(sessionDirectory.path), Substring(sessionDirectory.path),
        ],
        "the hook saw \(outcome.output) rather than \(sessionDirectory.path) twice"
    )
}

@Test("the environment the hook inherits is this process's own")
func hookInheritsTheEnvironment() async throws {
    let root = temporaryRoot()
    defer { removeTemporaryTree(root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let script = root.appending(path: "reports-path.sh")
    try writeScript("echo \"$PATH\"\n", to: script)

    let outcome = await ProcessNoteHook(executable: script, timeout: .seconds(5))
        .run(after: root)

    let inherited = ProcessInfo.processInfo.environment["PATH"] ?? ""
    #expect(!inherited.isEmpty, "this process has no PATH, so the check measured nothing")
    #expect(
        outcome.output.trimmingCharacters(in: .newlines) == inherited,
        "the hook ran with \(outcome.output) instead of the environment it inherits"
    )
}

@Test("a hook that is a directory is reported, not launched")
func hookThatCannotBeLaunchedIsReported() async throws {
    let root = temporaryRoot()
    defer { removeTemporaryTree(root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    // A directory has the execute bit, so it passes both preflight checks and
    // only the launch itself can say what it is.
    let outcome = await ProcessNoteHook(executable: root, timeout: .seconds(5))
        .run(after: root)

    guard case .couldNotStart(let reason) = outcome.result else {
        Issue.record("a directory as a hook reported \(outcome.result)")
        return
    }
    #expect(!reason.isEmpty, "nothing was said about why it could not start")
}

/// A hook that says more than the pipe holds would block on its own output and
/// look exactly like a hook that hung, so the read runs alongside the wait.
@Test("a hook that says more than the pipe holds is not mistaken for one that hung")
func chattyHookIsNotMistakenForAHungOne() async throws {
    let root = temporaryRoot()
    defer { removeTemporaryTree(root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let lines = 20_000
    let script = root.appending(path: "chatty.sh")
    try writeScript(
        "awk 'BEGIN { for (i = 0; i < \(lines); i++) print \"0123456789\" }'\n",
        to: script
    )

    let outcome = await ProcessNoteHook(executable: script, timeout: .seconds(10))
        .run(after: root)

    #expect(outcome.result == .exited(code: 0))
    #expect(
        outcome.output.count == lines * 11,
        "\(outcome.output.count) characters came back out of \(lines * 11)"
    )
}

func writeScript(_ body: String, to url: URL) throws {
    try Data("#!/bin/sh\n\(body)".utf8).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
}
