import Foundation

/// One live transcription. There is no audio in it: the audio arrives as it is
/// heard, and instants in the result are relative to the first buffer this call
/// was handed. Where that sits in the session is the caller's to know, the same
/// bargain `TranscriptionRequest` makes.
public struct LiveTranscriptionRequest: Sendable, Equatable {
    public let language: String

    public init(language: String) {
        self.language = language
    }
}

/// What a live backend is fed.
///
/// `settle` is an instruction rather than a clock. Measured: results are
/// finalized on pauses, so a speaker who does not stop produces none, and
/// forcing one every five seconds produces punctuated lines regardless. Making
/// it an event leaves the cadence with the caller, so no backend holds a wall
/// clock and a test can drive one by hand.
public enum LiveAudioEvent: Sendable, Equatable {
    case audio(CapturedAudio)
    case settle
}

/// Turns audio arriving now into transcript lines. One call per track, since the
/// tracks are what tell the user apart from everyone else.
///
/// Separate from `Transcribing` rather than a second backend behind it, because
/// that port is defined in terms of files: its request carries `[Track: URL]`
/// and its contract requires finalized lines out of one. A live backend has
/// neither, so it would have to be held to a contract it cannot meet.
///
/// Of the failures `TranscriptionFailure` names, only `unsupportedLanguage` is
/// reachable here, and it is thrown before any audio is read. `noAudio`,
/// `multitrackUnsupported` and `unreadableAudio` describe a request naming
/// files. Everything that goes wrong once transcription is under way arrives in
/// the stream, which is where a networked backend would report a timeout or a
/// rate limit.
///
/// Held to these by `verifyLiveTranscribingContract`:
///
/// - `capabilities.languages` names at least one language.
/// - A language outside `languages` is refused by `transcribe` throwing, before
///   any audio is heard.
/// - Where `streaming` is true at least one `partial` arrives; where it is false
///   none ever does.
/// - `settle` finalizes what has been heard since the last one, while the input
///   is still open, so a speaker who never pauses still produces lines.
/// - Finishing the input finalizes what is left and then ends the output stream.
/// - Finalized lines arrive in order of start instant, and none of them reaches
///   past the audio this call was handed.
/// - Where `diarization` is false every finalized line carries an empty speaker,
///   and where it is true every one names somebody.
public protocol LiveTranscribing: Sendable {
    var capabilities: TranscriptionCapabilities { get }

    func transcribe(
        _ request: LiveTranscriptionRequest,
        hearing audio: AsyncStream<LiveAudioEvent>
    ) async throws -> AsyncThrowingStream<TranscriptionEvent, any Error>
}
