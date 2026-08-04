import Foundation

@testable import ListtenCore

/// A backend that transcribes nothing and says what a backend says. It returns a
/// known transcript so a test names the lines it expects, and it can fail the
/// way a real one does: a timeout, a rate limit, a server error, a response
/// nothing can read.
///
/// Held to `verifyTranscribingContract`, like every implementation.
actor FakeTranscriber: Transcribing {
    nonisolated let capabilities: TranscriptionCapabilities

    /// One fault per attempt, in order. An attempt past the end succeeds, which
    /// is what makes a retry observable rather than assumed.
    private var faults: [TranscriptionFailure]

    /// Events handed over before the fault lands, so a failure that arrives
    /// after the caller already has lines can be told from one that arrives
    /// before it.
    private let deliveredBeforeFault: Int

    /// Every call, refused or not, so a caller that retried is visible. A
    /// refusal counts here and never counts against a retry budget.
    private(set) var attempts: [TranscriptionRequest] = []

    /// Whether it returns any lines at all. A backend asked for a language
    /// nobody in the room is speaking finishes cleanly with nothing, which is
    /// how a meeting becomes an empty note.
    private let hears: Bool

    init(
        capabilities: TranscriptionCapabilities = .fake,
        faults: [TranscriptionFailure] = [],
        deliveredBeforeFault: Int = 0,
        hears: Bool = true
    ) {
        self.capabilities = capabilities
        self.faults = faults
        self.deliveredBeforeFault = deliveredBeforeFault
        self.hears = hears
    }

    func transcribe(
        _ request: TranscriptionRequest
    ) async throws -> AsyncThrowingStream<TranscriptionEvent, any Error> {
        attempts.append(request)

        // Refused before anything is read, so the caller can tell a request it
        // must fix from a failure it may retry.
        guard !request.audio.isEmpty else { throw TranscriptionFailure.noAudio }
        guard capabilities.languages.contains(request.language) else {
            throw TranscriptionFailure.unsupportedLanguage(request.language)
        }
        guard capabilities.multitrack || request.audio.count == 1 else {
            throw TranscriptionFailure.multitrackUnsupported(tracks: request.audio.count)
        }

        let events = hears ? Self.events(for: request, capabilities: capabilities) : []
        let fault = faults.isEmpty ? nil : faults.removeFirst()

        return AsyncThrowingStream { continuation in
            for event in fault == nil ? events : Array(events.prefix(deliveredBeforeFault)) {
                continuation.yield(event)
            }
            continuation.finish(throwing: fault)
        }
    }

    /// The transcript it returns, per track, so a test asserting on what came
    /// back names lines rather than inventing them. The two tracks alternate on
    /// one clock, which is the shape a merged transcript is read from.
    static let spoken: [Track: [TranscriptLine]] = [
        .microphone: [
            line("you", 0, 2, "Shall we start with the migration?"),
            line("you", 4, 6, "I will draft the plan today."),
        ],
        .system: [
            line("others", 2, 4, "The migration slipped a week."),
            line("others", 6, 8, "The room booking is still open."),
        ],
    ]

    /// What this fake produces for a request, which is the fixture for every
    /// track asked for, in order of start instant.
    static func expected(
        for request: TranscriptionRequest,
        diarization: Bool
    ) -> [TranscriptLine] {
        request.audio.keys
            .flatMap { spoken[$0] ?? [] }
            .map { diarization ? $0 : withoutSpeaker($0) }
            .sorted { $0.start < $1.start }
    }

    private static func events(
        for request: TranscriptionRequest,
        capabilities: TranscriptionCapabilities
    ) -> [TranscriptionEvent] {
        expected(for: request, diarization: capabilities.diarization)
            .flatMap { line -> [TranscriptionEvent] in
                // A hypothesis of the first half, the way an engine revises what
                // it heard before it settles.
                guard capabilities.streaming else { return [.line(line)] }
                return [.partial(halfHeard(line)), .line(line)]
            }
    }

    private static func halfHeard(_ heard: TranscriptLine) -> TranscriptLine {
        line(
            heard.speaker,
            heard.start,
            heard.end,
            String(heard.text.prefix(heard.text.count / 2))
        )
    }

    private static func withoutSpeaker(_ line: TranscriptLine) -> TranscriptLine {
        Self.line("", line.start, line.end, line.text)
    }

    /// The fixture is written here, so a line it could not hold would fail the
    /// suite rather than be caught somewhere a caller cannot see.
    private static func line(
        _ speaker: String,
        _ start: TimeInterval,
        _ end: TimeInterval,
        _ text: String
    ) -> TranscriptLine {
        try! TranscriptLine(speaker: speaker, start: start, end: end, text: text)
    }
}

extension TranscriptionCapabilities {
    /// What the fake declares unless a test asks for something else: the shape
    /// #18 will ship, which streams, takes one track at a time and leaves
    /// attribution to the caller.
    static let fake = TranscriptionCapabilities(
        streaming: true,
        multitrack: false,
        diarization: false,
        languages: ["en-US", "pt-BR"]
    )
}
