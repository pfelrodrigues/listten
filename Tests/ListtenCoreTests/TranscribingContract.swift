import Foundation
import Testing

@testable import ListtenCore

/// Everything one transcription produced. Collected before anything is asserted,
/// so a rule about the run is checked against what arrived rather than inside a
/// loop that may never turn: a stream yielding nothing would otherwise run no
/// expectation at all and read as a pass.
struct Transcribed {
    let partials: [TranscriptLine]
    let finalized: [TranscriptLine]
}

func transcribed(
    _ stream: AsyncThrowingStream<TranscriptionEvent, any Error>
) async throws -> Transcribed {
    var partials: [TranscriptLine] = []
    var finalized: [TranscriptLine] = []
    for try await event in stream {
        switch event {
        case .partial(let line): partials.append(line)
        case .line(let line): finalized.append(line)
        }
    }
    return Transcribed(partials: partials, finalized: finalized)
}

/// One audio file per track. Where it points does not matter to an
/// implementation that transcribes nothing, and an implementation that reads it
/// is handed a path by whoever runs this.
let fakeAudio: [Track: URL] = [
    .microphone: URL(filePath: "/memory/audio/microphone.caf"),
    .system: URL(filePath: "/memory/audio/system.caf"),
]

/// The rules every `Transcribing` obeys, written once so the fake cannot promise
/// something a backend never agreed to. What is checked here is what a caller
/// reads the capabilities to decide: whether it must attribute speakers itself,
/// whether it must transcribe the tracks separately, whether hypotheses are
/// coming, and what happens to a request this backend cannot serve.
func verifyTranscribingContract(
    _ make: @Sendable () -> any Transcribing,
    sourceLocation: SourceLocation = #_sourceLocation
) async throws {
    let capabilities = make().capabilities

    #expect(
        !capabilities.languages.isEmpty,
        "a backend that names no language transcribes nothing",
        sourceLocation: sourceLocation
    )
    guard let language = capabilities.languages.sorted().first else { return }

    await #expect(
        throws: TranscriptionFailure.noAudio,
        "a request naming no audio was accepted",
        sourceLocation: sourceLocation
    ) {
        _ = try await make().transcribe(TranscriptionRequest(audio: [:], language: language))
    }

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
        _ = try await make()
            .transcribe(
                TranscriptionRequest(
                    audio: [.microphone: fakeAudio[.microphone]!],
                    language: unknown
                )
            )
    }

    let both = TranscriptionRequest(audio: fakeAudio, language: language)
    if capabilities.multitrack {
        let run = try await transcribed(await make().transcribe(both))
        #expect(
            !run.finalized.isEmpty,
            "a backend declaring multitrack produced nothing for two tracks",
            sourceLocation: sourceLocation
        )
    } else {
        await #expect(
            throws: TranscriptionFailure.multitrackUnsupported(tracks: 2),
            "two tracks went to a backend that takes one",
            sourceLocation: sourceLocation
        ) {
            _ = try await make().transcribe(both)
        }
    }

    let one = TranscriptionRequest(
        audio: [.microphone: fakeAudio[.microphone]!],
        language: language
    )
    let run = try await transcribed(await make().transcribe(one))

    #expect(
        !run.finalized.isEmpty,
        "a request it accepted produced no transcript",
        sourceLocation: sourceLocation
    )
    #expect(
        run.finalized.map(\.start) == run.finalized.map(\.start).sorted(),
        "finalized lines arrived out of order",
        sourceLocation: sourceLocation
    )
    if !capabilities.streaming {
        #expect(
            run.partials.isEmpty,
            "a backend declaring no streaming sent hypotheses",
            sourceLocation: sourceLocation
        )
    }
    if capabilities.diarization {
        #expect(
            run.finalized.allSatisfy { !$0.speaker.isEmpty },
            "a backend declaring diarization left a line unattributed",
            sourceLocation: sourceLocation
        )
    } else {
        #expect(
            run.finalized.allSatisfy { $0.speaker.isEmpty },
            "a backend that does not diarize named a speaker anyway",
            sourceLocation: sourceLocation
        )
    }
}

/// Every configuration the four capabilities are read in, since a rule that only
/// ever meets one of them is a rule for that one.
@Test(
    "the fake honours the contract in every configuration it declares",
    arguments: [
        TranscriptionCapabilities.fake,
        TranscriptionCapabilities(
            streaming: false,
            multitrack: false,
            diarization: false,
            languages: ["en-US"]
        ),
        TranscriptionCapabilities(
            streaming: true,
            multitrack: true,
            diarization: true,
            languages: ["en-US", "pt-BR"]
        ),
        TranscriptionCapabilities(
            streaming: false,
            multitrack: true,
            diarization: true,
            languages: ["pt-BR"]
        ),
    ]
)
func fakeTranscriberHonoursTheContract(capabilities: TranscriptionCapabilities) async throws {
    try await verifyTranscribingContract { FakeTranscriber(capabilities: capabilities) }
}
/// The retrying transcriber is a `Transcribing` too, so it answers to the same
/// rules: a wrapper that quietly widened what its backend accepts, or that
/// reported capabilities its backend does not have, fails here.
@Test(
    "retrying does not change what the backend promises",
    arguments: [
        TranscriptionCapabilities.fake,
        TranscriptionCapabilities(
            streaming: false,
            multitrack: true,
            diarization: true,
            languages: ["en-US"]
        ),
    ]
)
func retryingTranscriberHonoursTheContract(
    capabilities: TranscriptionCapabilities
) async throws {
    try await verifyTranscribingContract {
        RetryingTranscriber(
            wrapping: FakeTranscriber(capabilities: capabilities),
            sleeping: { _ in }
        )
    }
}
