import Foundation
import Testing

@testable import ListtenCore

/// The ways a hook goes wrong, named rather than written as scripts here: an
/// implementation that does not spawn processes still has all five to answer
/// for, and the contract asks the same questions of every one.
enum HookBehaviour: Sendable {
    /// Writes the directory it was told about, so the caller can see it arrived.
    case reportsWhatItWasTold
    /// Says something on stderr and nothing on stdout.
    case writesToStandardError
    case exitsNonZero
    /// Outlives any sane timeout, and ignores being asked to stop.
    case hangs
    case missing
    case notExecutable
}

/// The rules every `NotePostProcessing` obeys. They exist because a hook is a
/// script somebody else wrote: the meeting is already recorded, transcribed and
/// filed by the time it runs, and none of the five behaviours above may cost
/// any of that.
func verifyNotePostProcessingContract(
    timeout: Duration,
    _ make: @Sendable (HookBehaviour) throws -> any NotePostProcessing,
    sourceLocation: SourceLocation = #_sourceLocation
) async throws {
    let sessionDirectory = URL(filePath: "/some/session/directory")

    let told = try await make(.reportsWhatItWasTold).run(after: sessionDirectory)
    #expect(
        told.result == .exited(code: 0),
        "a hook that ran to completion reported \(told.result)",
        sourceLocation: sourceLocation
    )
    #expect(
        told.output.contains(sessionDirectory.path),
        "the hook was not told which session it was run for: \(told.output)",
        sourceLocation: sourceLocation
    )

    let complained = try await make(.writesToStandardError).run(after: sessionDirectory)
    #expect(
        complained.result == .exited(code: 0),
        "a hook that only complained reported \(complained.result)",
        sourceLocation: sourceLocation
    )
    #expect(
        complained.output.contains("something is wrong"),
        "what the hook said on stderr was dropped: \(complained.output)",
        sourceLocation: sourceLocation
    )

    let failed = try await make(.exitsNonZero).run(after: sessionDirectory)
    #expect(
        failed.result == .exited(code: 1),
        "a hook that exited 1 reported \(failed.result)",
        sourceLocation: sourceLocation
    )

    // Bounded, not merely eventual: a hook that is stopped only when it feels
    // like stopping is the hook that takes the meeting down.
    let started = ContinuousClock.now
    let hung = try await make(.hangs).run(after: sessionDirectory)
    let took = ContinuousClock.now - started
    #expect(
        hung.result == .timedOut,
        "a hook that never finishes reported \(hung.result)",
        sourceLocation: sourceLocation
    )
    #expect(
        // Loose enough to survive a machine that was slow to spawn the hook at
        // all, which is not what this is measuring: the hook it waits on sleeps
        // for thirty seconds.
        took < timeout + .seconds(4),
        "the hook was waited on for \(took), well past its \(timeout) timeout",
        sourceLocation: sourceLocation
    )

    let absent = try await make(.missing).run(after: sessionDirectory)
    #expect(
        absent.result == .notFound,
        "a hook that is not there reported \(absent.result)",
        sourceLocation: sourceLocation
    )

    let unrunnable = try await make(.notExecutable).run(after: sessionDirectory)
    #expect(
        unrunnable.result == .notExecutable,
        "a hook without the execute bit reported \(unrunnable.result)",
        sourceLocation: sourceLocation
    )
}

@Test("the process hook honours the contract")
func processNoteHookHonoursTheContract() async throws {
    let root = temporaryRoot()
    defer { removeTemporaryTree(root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    // Generous next to the scripts, which finish in milliseconds: the timeout is
    // there to catch a hook that never ends, not one a loaded machine was slow
    // to start. The hook that hangs sleeps for thirty seconds, so the bound
    // below still means something.
    //
    // Three seconds was not generous enough. It passed alone and failed inside
    // the full suite whenever something else on the machine was busy, which is
    // a test that reports the load rather than the code. Ten still proves the
    // timeout, and no longer fails for being run alongside its own suite.
    let timeout = Duration.seconds(10)
    try await verifyNotePostProcessingContract(timeout: timeout) { behaviour in
        ProcessNoteHook(
            executable: try hookScript(behaviour, in: root),
            timeout: timeout
        )
    }
}

/// The five behaviours as real scripts. `hangs` traps `TERM` on purpose: a hook
/// that declines to stop when asked is exactly the one the timeout exists for.
func hookScript(_ behaviour: HookBehaviour, in directory: URL) throws -> URL {
    let body =
        switch behaviour {
        case .reportsWhatItWasTold: "echo \"$1\"\n"
        case .writesToStandardError: "echo 'something is wrong' >&2\n"
        case .exitsNonZero: "exit 1\n"
        case .hangs: "trap '' TERM\nsleep 30\n"
        case .missing, .notExecutable: "exit 0\n"
        }

    let script = directory.appending(path: "hook-\(UUID().uuidString).sh")
    guard behaviour != .missing else { return script }

    try Data("#!/bin/sh\n\(body)".utf8).write(to: script)
    try FileManager.default.setAttributes(
        [.posixPermissions: behaviour == .notExecutable ? 0o600 : 0o700],
        ofItemAtPath: script.path
    )
    return script
}
