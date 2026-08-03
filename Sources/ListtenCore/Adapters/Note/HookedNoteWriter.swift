import Foundation

/// A note writer with the user's hook behind it: the note is written, read back
/// from where it was delivered, and only then is the hook told about it.
///
/// The order is the point. A hook exists to move the note somewhere else, so a
/// hook that ran before delivery was verified would act on a note that may not
/// be there. In the other direction, nothing the hook does can cost the note:
/// the write has already happened and `NotePostProcessing` cannot throw, so a
/// hook that fails, hangs or shouts is logged and the session stands.
///
/// It reads bytes back from disk, so it wraps writers that put them there. The
/// session directory it hands the hook is the one the note is kept in, which is
/// what `NoteLocation` promises `kept` sits inside.
public struct HookedNoteWriter: NoteWriting {
    public enum Failure: Error, Equatable {
        /// The note reported as delivered is not the note that was kept.
        case deliveredNoteDiffers(path: String)
    }

    private let writer: any NoteWriting
    private let hook: any NotePostProcessing
    private let log: @Sendable (HookOutcome) -> Void

    public init(
        writing writer: any NoteWriting,
        hook: any NotePostProcessing,
        log: @escaping @Sendable (HookOutcome) -> Void
    ) {
        self.writer = writer
        self.hook = hook
        self.log = log
    }

    public func write(_ note: MeetingNote, for sessionID: String) async throws -> NoteLocation {
        let location = try await writer.write(note, for: sessionID)

        // Read back rather than trusted: a copy that was reported and a copy
        // that is there are the same thing right up until they are not, and the
        // hook is what acts on the claim.
        guard
            let delivered = FileManager.default.contents(atPath: location.delivered.path),
            delivered == FileManager.default.contents(atPath: location.kept.path)
        else {
            throw NoteNotDelivered(
                kept: location.kept,
                underlying: Failure.deliveredNoteDiffers(path: location.delivered.path)
            )
        }

        log(await hook.run(after: location.kept.deletingLastPathComponent()))
        return location
    }
}
