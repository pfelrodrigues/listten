import Foundation

/// What the hook did, said in enough detail to log and in none to act on.
public struct HookOutcome: Sendable, Equatable {
    public enum Result: Sendable, Equatable {
        /// Nothing at the configured path.
        case notFound
        /// There, but without the execute bit.
        case notExecutable
        /// It ran to completion. A non-zero code is still an outcome, not a failure of the run.
        case exited(code: Int32)
        /// It outlived the timeout and was stopped.
        case timedOut
        /// The path is a file nothing could launch: a directory, a bad interpreter line.
        case couldNotStart(reason: String)
    }

    public let result: Result
    /// Everything the hook wrote, both streams merged, so nothing it says is lost.
    public let output: String

    public init(result: Result, output: String) {
        self.result = result
        self.output = output
    }
}

/// Runs whatever the user wired after a note was written and verified.
///
/// The method cannot throw, and that is the whole design: a hook is somebody
/// else's script, and a meeting that was recorded, transcribed and filed must
/// not be lost to it. Every way a hook can go wrong is an outcome to be logged.
/// Held to these by `verifyNotePostProcessingContract`:
///
/// - It always returns, whatever the hook does. A hook that hangs is stopped
///   and reported as `.timedOut`, within its timeout rather than eventually.
/// - A hook that is not there is `.notFound` and one without the execute bit is
///   `.notExecutable`. Neither is an error: a hook is configuration, and
///   configuration that is wrong costs the hook and nothing else.
/// - A hook that exits non-zero is `.exited` with its code, not a failure.
/// - Whatever the hook wrote is in `output`, so it can go to the log. It never
///   reaches the note: the note was finished before the hook was told about it.
/// - The session directory is given to the hook, which is the only thing it is
///   told about the session.
public protocol NotePostProcessing: Sendable {
    func run(after sessionDirectory: URL) async -> HookOutcome
}
