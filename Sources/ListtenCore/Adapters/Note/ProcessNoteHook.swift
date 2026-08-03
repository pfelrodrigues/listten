import Foundation
import Synchronization

/// The hook as a child process: the session directory as its first argument and
/// as `LISTTEN_SESSION_DIR`, both its streams merged into the outcome.
///
/// Launched directly rather than through a shell, so a file without the execute
/// bit is reported as such instead of being run anyway by `sh`.
public struct ProcessNoteHook: NotePostProcessing {
    /// The name the session directory arrives under, beside the argument, so a
    /// hook that hands its arguments to something else can still find it.
    public static let environmentKey = "LISTTEN_SESSION_DIR"

    /// How long a hook that ignores `SIGTERM` keeps the wait, before `SIGKILL`.
    private static let graceAfterTerminate = Duration.milliseconds(200)

    /// Long enough for a hook's own output to arrive after it died, short enough
    /// that a grandchild holding the pipe open cannot hold the wait open too.
    private static let drainAfterExit = Duration.seconds(1)

    private let executable: URL
    private let timeout: Duration

    public init(executable: URL, timeout: Duration) {
        self.executable = executable
        self.timeout = timeout
    }

    public func run(after sessionDirectory: URL) async -> HookOutcome {
        guard FileManager.default.fileExists(atPath: executable.path) else {
            return HookOutcome(result: .notFound, output: "")
        }
        // False for a file that is not there too, which is why order matters.
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            return HookOutcome(result: .notExecutable, output: "")
        }

        let executable = executable
        let timeout = timeout
        return await withCheckedContinuation { continuation in
            // Off the cooperative pool: waiting on a child process blocks its
            // thread, and the pool has few of them.
            DispatchQueue.global()
                .async {
                    continuation.resume(
                        returning: Self.spawn(executable, for: sessionDirectory, timeout: timeout)
                    )
                }
        }
    }

    /// Everything the child touches happens here, on one thread.
    private static func spawn(
        _ executable: URL,
        for sessionDirectory: URL,
        timeout: Duration
    ) -> HookOutcome {
        let process = Process()
        process.executableURL = executable
        process.arguments = [sessionDirectory.path]
        var environment = ProcessInfo.processInfo.environment
        environment[environmentKey] = sessionDirectory.path
        process.environment = environment

        // One pipe for both streams: what the hook says goes to the log as it
        // said it, and a second reader is a second way to deadlock.
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        let collected = Mutex(Data())
        let drained = DispatchSemaphore(value: 0)
        // Read as it comes: a hook that fills the pipe buffer would otherwise
        // block on its own output and be reported as a hook that hung.
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                drained.signal()
                return
            }
            collected.withLock { $0.append(chunk) }
        }

        do {
            try process.run()
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            return HookOutcome(result: .couldNotStart(reason: "\(error)"), output: "")
        }

        let timedOut = wait(for: exited, process: process, timeout: timeout)
        _ = drained.wait(timeout: .now() + drainAfterExit.seconds)
        pipe.fileHandleForReading.readabilityHandler = nil

        let output = collected.withLock { String(decoding: $0, as: UTF8.self) }
        return HookOutcome(
            result: timedOut ? .timedOut : .exited(code: process.terminationStatus),
            output: output
        )
    }

    /// True when the hook had to be stopped. `SIGTERM` first so a hook can tidy
    /// up, `SIGKILL` after, since a hook that traps `SIGTERM` and keeps going is
    /// the one the timeout exists for.
    private static func wait(
        for exited: DispatchSemaphore,
        process: Process,
        timeout: Duration
    ) -> Bool {
        guard exited.wait(timeout: .now() + timeout.seconds) == .timedOut else { return false }

        process.terminate()
        if exited.wait(timeout: .now() + graceAfterTerminate.seconds) == .timedOut {
            kill(process.processIdentifier, SIGKILL)
            exited.wait()
        }
        return true
    }
}

extension Duration {
    fileprivate var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
