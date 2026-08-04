import AVFoundation
import Foundation
import Speech
import Testing

@testable import ListtenCore

/// The recording arrives as buffers, so a fixture on disk has to be turned back
/// into them: this is what the capture hands the live side, at the rate the
/// device produced rather than the one the analyser wants.
private func buffers(from url: URL, of seconds: TimeInterval = 0.5) throws -> [CapturedAudio] {
    let file = try AVAudioFile(forReading: url)
    let rate = file.processingFormat.sampleRate
    let chunk = AVAudioFrameCount(rate * seconds)

    var captured: [CapturedAudio] = []
    while file.framePosition < file.length {
        guard
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk)
        else { break }
        try file.read(into: buffer, frameCount: chunk)
        guard buffer.frameLength > 0, let channel = buffer.floatChannelData?[0] else { break }
        captured.append(
            CapturedAudio(
                hostTime: 1000 + Double(captured.count) * seconds,
                sampleRate: rate,
                samples: Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
            )
        )
    }
    return captured
}

private func discard(_ url: URL) {
    try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
}

/// The three the design turns on. Streaming true is why hypotheses are dropped
/// rather than written; diarization false is why there are two tracks at all.
@Test("the live backend declares streaming and no diarization, which is what it does")
func theLiveBackendDeclaresWhatItActuallyDoes() {
    let subject = SpeechLiveTranscription(languages: ["pt-BR"])

    #expect(subject.capabilities.streaming)
    #expect(!subject.capabilities.diarization)
    #expect(!subject.capabilities.multitrack)
}

/// Refused before an analyser is built, so a track in a language nobody has a
/// model for costs nothing rather than making one resident for the meeting.
@Test("a language whose model is not here is refused before anything is heard")
func theLiveBackendRefusesAnUndeclaredLanguage() async {
    let subject = SpeechLiveTranscription(languages: ["pt-BR"])
    let (audio, feeding) = AsyncStream<LiveAudioEvent>.makeStream()
    feeding.finish()

    await #expect(throws: TranscriptionFailure.unsupportedLanguage("zz-ZZ")) {
        _ = try await subject.transcribe(
            LiveTranscriptionRequest(language: "zz-ZZ"),
            hearing: audio
        )
    }
}

/// Opt-in like the rest: on a machine with no model the declared set and the
/// installed set are both empty, so the comparison holds while checking nothing.
@Test(
    "the live backend declares only the languages whose model is on this machine",
    .enabled(if: ProcessInfo.processInfo.environment["LISTTEN_SPEECH_MODEL"] == "1")
)
func theLiveBackendDeclaresInstalledLanguagesOnly() async {
    let subject = await SpeechLiveTranscription.installed()
    let installed = Set(await SpeechTranscriber.installedLocales.map { $0.identifier(.bcp47) })

    #expect(subject.capabilities.languages == installed)
    #expect(!subject.capabilities.languages.isEmpty, "no speech model is installed to test with")
}

/// The engine held to the same rules as the fake, which is rule five's whole
/// point. The fixture is one unbroken stretch of speech with no pause in it, so
/// the finals it produces can only have come from the settles: that is the
/// finding the whole design rests on and the one a fake cannot prove.
///
/// Needs a speech model, so it is opt-in with the rest.
@Test(
    "the live speech backend honours the same contract as the fake",
    .enabled(if: ProcessInfo.processInfo.environment["LISTTEN_SPEECH_MODEL"] == "1")
)
func theLiveSpeechBackendHonoursTheContract() async throws {
    let subject = await SpeechLiveTranscription.installed()
    try #require(subject.capabilities.languages.contains("pt-BR"))

    let audio = try await synthesised(
        "Bom dia pessoal, hoje vamos falar sobre a migração do banco de dados, "
            + "o prazo continua sendo o dia quinze e a Ana ficou de reservar a sala.",
        language: "pt-BR"
    )
    defer { discard(audio) }

    try await verifyLiveTranscribingContract(
        { subject },
        language: "pt-BR",
        speaking: { try buffers(from: audio) }
    )
}

/// Recognition returning something is not recognition working, and it is the
/// live path's own risk: it hears the same audio worse than the file backend
/// does. This is the only test that says the words that went in came back.
@Test(
    "what was spoken to the live backend comes back",
    .enabled(if: ProcessInfo.processInfo.environment["LISTTEN_SPEECH_MODEL"] == "1")
)
func spokenWordsComeBackFromTheLiveBackend() async throws {
    let subject = await SpeechLiveTranscription.installed()
    try #require(subject.capabilities.languages.contains("pt-BR"))

    let audio = try await synthesised(
        "Bom dia, vamos começar a reunião de hoje.",
        language: "pt-BR"
    )
    defer { discard(audio) }

    let (heard, feeding) = AsyncStream<LiveAudioEvent>.makeStream()
    let stream = try await subject.transcribe(
        LiveTranscriptionRequest(language: "pt-BR"),
        hearing: heard
    )
    let collected = LiveEvents()
    let reading = Task {
        for try await event in stream {
            collected.record(event)
        }
    }

    for buffer in try buffers(from: audio) {
        feeding.yield(.audio(buffer))
    }
    feeding.finish()
    _ = await reading.result

    let lines = collected.finalized
    let text = lines.map(\.text).joined(separator: " ")
    #expect(text.contains("reunião"), "heard \(text)")
    #expect(text.contains("Bom dia"), "heard \(text)")
    #expect(lines.allSatisfy { $0.speaker.isEmpty }, "diarization is declared false")
    #expect(lines.allSatisfy { $0.end >= $0.start })
}
