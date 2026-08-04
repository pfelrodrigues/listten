import Foundation
import Synchronization
import Testing

@testable import ListtenCore

/// Everything a live transcription has produced so far, readable while it is
/// still producing: the rule that a settle finalizes a line before the meeting
/// ends cannot be checked on a run that has already finished.
final class LiveEvents: Sendable {
    private let stored = Mutex<[TranscriptionEvent]>([])

    func record(_ event: TranscriptionEvent) {
        stored.withLock { $0.append(event) }
    }

    var finalized: [TranscriptLine] {
        stored.withLock { $0 }
            .compactMap {
                guard case .line(let line) = $0 else { return nil }
                return line
            }
    }

    var partials: [TranscriptLine] {
        stored.withLock { $0 }
            .compactMap {
                guard case .partial(let line) = $0 else { return nil }
                return line
            }
    }
}

/// Yields first and sleeps later: a fake settles within a turn, while the engine
/// takes about a second to say its first word and is measured, not guessed at.
func waitFor(
    _ reached: @Sendable () -> Bool,
    _ what: String,
    sourceLocation: SourceLocation = #_sourceLocation
) async {
    for attempt in 0..<4000 {
        if reached() { return }
        if attempt < 100 {
            await Task.yield()
        } else {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
    Issue.record("\(what) never happened", sourceLocation: sourceLocation)
}

/// Half a second of nothing, repeated. The fake derives its lines from the
/// audio it heard, so silence is a fixture; a backend that needs words is handed
/// them by whoever runs this.
func silence(seconds: TimeInterval, at rate: Double = 16000) -> [CapturedAudio] {
    (0..<Int(seconds * 2))
        .map { index in
            CapturedAudio(
                hostTime: 1000 + Double(index) / 2,
                sampleRate: rate,
                samples: Array(repeating: 0, count: Int(rate / 2))
            )
        }
}

/// The rules every `LiveTranscribing` obeys, written once so the fake cannot
/// promise something the engine never agreed to. `speaking` is how this backend
/// is given something to hear, since one that recognises words needs words.
func verifyLiveTranscribingContract(
    _ make: @Sendable () -> any LiveTranscribing,
    language: String? = nil,
    speaking: @Sendable () async throws -> [CapturedAudio] = { silence(seconds: 6) },
    sourceLocation: SourceLocation = #_sourceLocation
) async throws {
    let capabilities = make().capabilities

    #expect(
        !capabilities.languages.isEmpty,
        "a backend that names no language transcribes nothing",
        sourceLocation: sourceLocation
    )
    guard let language = language ?? capabilities.languages.sorted().first else { return }

    let unknown = "zz-ZZ"
    #expect(
        !capabilities.languages.contains(unknown),
        "the language this checks refusal with is one the backend supports",
        sourceLocation: sourceLocation
    )
    await #expect(
        throws: TranscriptionFailure.unsupportedLanguage(unknown),
        "a language outside the declared ones was transcribed anyway",
        sourceLocation: sourceLocation
    ) {
        let (audio, feeding) = AsyncStream<LiveAudioEvent>.makeStream()
        feeding.finish()
        _ = try await make()
            .transcribe(LiveTranscriptionRequest(language: unknown), hearing: audio)
    }

    let spoken = try await speaking()
    let heard = spoken.reduce(0.0) { $0 + Double($1.frames) / $1.sampleRate }

    let (audio, feeding) = AsyncStream<LiveAudioEvent>.makeStream()
    let stream = try await make()
        .transcribe(LiveTranscriptionRequest(language: language), hearing: audio)
    let collected = LiveEvents()
    let reading = Task {
        for try await event in stream {
            collected.record(event)
        }
    }

    for buffer in spoken {
        feeding.yield(.audio(buffer))
    }
    feeding.yield(.settle)

    // The input is deliberately still open. This is the whole reason `settle`
    // exists: a speaker who does not pause would otherwise leave the file
    // untouched for as long as they keep talking.
    await waitFor(
        { !collected.finalized.isEmpty },
        "a settle finalized a line while the meeting was still running",
        sourceLocation: sourceLocation
    )
    let settledEarly = collected.finalized.count

    if capabilities.streaming {
        #expect(
            !collected.partials.isEmpty,
            "a backend declaring streaming sent no hypothesis",
            sourceLocation: sourceLocation
        )
    } else {
        #expect(
            collected.partials.isEmpty,
            "a backend declaring no streaming sent hypotheses",
            sourceLocation: sourceLocation
        )
    }

    // A second stretch with no settle behind it: finishing has to finalize what
    // is left, or the last thing anybody said is lost.
    for buffer in spoken {
        feeding.yield(.audio(buffer))
    }
    feeding.finish()

    await waitFor(
        { reading.isCancelled || collected.finalized.count > settledEarly },
        "finishing the input finalized what was left",
        sourceLocation: sourceLocation
    )
    await endsWithin(reading, sourceLocation: sourceLocation)

    let finalized = collected.finalized
    #expect(
        finalized.count > settledEarly,
        "finishing the input lost what had not been settled yet",
        sourceLocation: sourceLocation
    )
    #expect(
        finalized.map(\.start) == finalized.map(\.start).sorted(),
        "finalized lines arrived out of order",
        sourceLocation: sourceLocation
    )
    #expect(
        finalized.allSatisfy { $0.start >= 0 && $0.end <= 2 * heard + 1 },
        "a line landed outside the audio this call was handed",
        sourceLocation: sourceLocation
    )
    if capabilities.diarization {
        #expect(
            finalized.allSatisfy { !$0.speaker.isEmpty },
            "a backend declaring diarization left a line unattributed",
            sourceLocation: sourceLocation
        )
    } else {
        #expect(
            finalized.allSatisfy { $0.speaker.isEmpty },
            "a backend that does not diarize named a speaker anyway",
            sourceLocation: sourceLocation
        )
    }
}

/// A backend that never ends its stream would hang the suite rather than fail
/// one test.
private func endsWithin(
    _ reading: Task<Void, any Error>,
    sourceLocation: SourceLocation = #_sourceLocation
) async {
    let deadline = Task {
        try await Task.sleep(for: .seconds(30))
        Issue.record("the output stream was never ended", sourceLocation: sourceLocation)
        reading.cancel()
    }
    _ = await reading.result
    deadline.cancel()
}

/// Every configuration the capabilities are read in, since a rule that only ever
/// meets one of them is a rule for that one.
@Test(
    "the live fake honours the contract in every configuration it declares",
    arguments: [
        TranscriptionCapabilities.fakeLive,
        TranscriptionCapabilities(
            streaming: false,
            multitrack: false,
            diarization: false,
            languages: ["pt-BR"]
        ),
        TranscriptionCapabilities(
            streaming: true,
            multitrack: false,
            diarization: true,
            languages: ["en-US", "pt-BR"]
        ),
        TranscriptionCapabilities(
            streaming: false,
            multitrack: false,
            diarization: true,
            languages: ["en-US"]
        ),
    ]
)
func fakeLiveTranscriberHonoursTheContract(
    capabilities: TranscriptionCapabilities
) async throws {
    try await verifyLiveTranscribingContract { FakeLiveTranscriber(capabilities: capabilities) }
}
