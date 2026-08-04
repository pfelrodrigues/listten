import Foundation

/// What a transcription backend can do, declared rather than assumed. Version 1
/// ships one engine; these exist so the caller adapts to a second one instead of
/// being rewritten for it, and every one of them changes what a caller must do.
public struct TranscriptionCapabilities: Sendable, Equatable {
    /// Hypotheses arrive before a line is finalized. A caller showing captions
    /// while the meeting runs reads this; one that only keeps the transcript
    /// takes the finalized lines and ignores the rest.
    public let streaming: Bool

    /// Both tracks go in one request. Where it is false the caller transcribes
    /// each track on its own and interleaves the results itself.
    public let multitrack: Bool

    /// Speakers are told apart inside a track. Where it is false every line
    /// comes back with no speaker and attribution is the caller's to do.
    public let diarization: Bool

    /// BCP-47 tags this backend transcribes. Anything else is refused, never
    /// transcribed in whichever language the engine happened to default to.
    public let languages: Set<String>

    public init(streaming: Bool, multitrack: Bool, diarization: Bool, languages: Set<String>) {
        self.streaming = streaming
        self.multitrack = multitrack
        self.diarization = diarization
        self.languages = languages
    }
}

/// One transcription: the audio of each track to read, and the language it is
/// in. Instants in the result are on the clock of the audio handed over, which
/// starts at zero: where that audio sits in the session is the caller's to
/// know, and a backend told otherwise would be trusted with a timeline it
/// cannot check.
public struct TranscriptionRequest: Sendable, Equatable {
    public let audio: [Track: URL]
    public let language: String

    public init(audio: [Track: URL], language: String) {
        self.audio = audio
        self.language = language
    }
}

/// What a transcription produces as it runs.
public enum TranscriptionEvent: Sendable, Equatable {
    /// A hypothesis a later one may replace. Never stored, never counted as the
    /// transcript: only `line` says the engine has settled.
    case partial(TranscriptLine)

    /// Finalized. Nothing after this revises it.
    case line(TranscriptLine)
}

/// Why a transcription did not happen, or stopped happening.
///
/// The first three are refusals: the request as written cannot be transcribed by
/// this backend, and repeating it changes nothing. The rest are transport, where
/// the next attempt may well succeed. `RetryingTranscriber` is what reads the
/// difference, so a backend that reported a rate limit as a malformed response
/// would cost a meeting the retry that would have saved it.
public enum TranscriptionFailure: Error, Equatable {
    case noAudio
    case unsupportedLanguage(String)
    case multitrackUnsupported(tracks: Int)
    /// Audio that cannot be opened or decoded. A refusal rather than transport:
    /// the file will not read any better on a second attempt. Added when the
    /// first backend that reads a file arrived, since a fake never had to.
    case unreadableAudio(String)
    case timedOut
    /// Seconds the backend asked to be left alone for, where it said.
    case rateLimited(retryAfter: TimeInterval?)
    case serverError(status: Int)
    case malformedResponse(String)
}

/// Turns recorded audio into transcript lines.
///
/// Held to these by `verifyTranscribingContract`:
///
/// - `capabilities.languages` names at least one language. A backend that
///   transcribes nothing is not a backend.
/// - What the capabilities rule out is refused by `transcribe` throwing, before
///   any audio is read: a request naming no audio, a language outside
///   `languages`, more than one track where `multitrack` is false. Everything
///   that goes wrong once transcription is under way arrives in the stream
///   instead, which is what lets a caller tell a request it must fix from a
///   failure it may retry.
/// - Where `streaming` is false no `partial` ever arrives. Where `diarization`
///   is false every finalized line carries an empty speaker, and where it is
///   true every finalized line names one.
/// - Finalized lines arrive in order of start instant.
public protocol Transcribing: Sendable {
    var capabilities: TranscriptionCapabilities { get }

    func transcribe(
        _ request: TranscriptionRequest
    ) async throws -> AsyncThrowingStream<TranscriptionEvent, any Error>
}

/// Works out which language a recording is in.
///
/// Kept apart from `Transcribing` because it answers a different question with a
/// different signal. Transcription hands back words; this needs to know how sure
/// the engine was of them, which is what tells a language apart from one that
/// merely sounds like it. Measured on a real recording: the same thirty seconds
/// of Portuguese produced thirty words under both pt-BR and en-US, so counting
/// words picked the wrong one, while the confidence was 0.93 against 0.29.
///
/// Held to these by `verifyLanguageDetectingContract`:
///
/// - `candidates` names at least one language, and every answer is one of them.
/// - A sample nothing was heard in answers nil rather than a language picked at
///   random. Most meetings open with a minute of nobody talking, and deciding
///   the whole recording on that would decide it on silence.
/// - The same sample answers the same way twice. A detector that varied would
///   transcribe half a meeting in one language and half in another.
public protocol LanguageDetecting: Sendable {
    var candidates: [String] { get }

    func language(of sample: SegmentFile) async throws -> String?
}
