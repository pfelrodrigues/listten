import AVFoundation
import Foundation
import Speech
import Synchronization
import Testing

@testable import ListtenCore

/// Written into a temporary file rather than checked in: a fixture that has to
/// be regenerated to change is a fixture nobody changes.
private func spoken(seconds: Double, at rate: Double = 16000) throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appending(path: "speech-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appending(path: "mic-0001.caf")

    guard
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1),
        let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(seconds * rate)
        ),
        let channel = buffer.floatChannelData?[0]
    else {
        throw CocoaError(.fileWriteUnknown)
    }
    buffer.frameLength = buffer.frameCapacity
    for frame in 0..<Int(buffer.frameLength) {
        channel[frame] = 0
    }

    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    try file.write(from: buffer)
    return url
}

/// Spoken by the system rather than checked in, so the fixture is deterministic
/// without a binary in the repository and without a microphone. What goes in is
/// what should come out, which is the only way to tell recognition working from
/// recognition merely returning something.
private func synthesised(_ sentence: String, language: String) async throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appending(path: "speech-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appending(path: "mic-0001.caf")

    let synthesiser = AVSpeechSynthesizer()
    let utterance = AVSpeechUtterance(string: sentence)
    utterance.voice = AVSpeechSynthesisVoice(language: language)

    let written = Mutex<AVAudioFile?>(nil)
    let finished = Mutex(false)
    await withCheckedContinuation { (resume: CheckedContinuation<Void, Never>) in
        synthesiser.write(utterance) { buffer in
            guard let pcm = buffer as? AVAudioPCMBuffer else { return }
            guard pcm.frameLength > 0 else {
                let first = finished.withLock { done -> Bool in
                    guard !done else { return false }
                    done = true
                    return true
                }
                if first { resume.resume() }
                return
            }
            written.withLock { file in
                if file == nil {
                    file = try? AVAudioFile(forWriting: url, settings: pcm.format.settings)
                }
                try? file?.write(from: pcm)
            }
        }
    }
    return url
}

private func remove(_ url: URL) {
    try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
}

@Test("the backend declares only the languages whose model is on this machine")
func declaresInstalledLanguagesOnly() async {
    let subject = await SpeechTranscription.installed()
    let installed = Set(await SpeechTranscriber.installedLocales.map { $0.identifier(.bcp47) })

    #expect(subject.capabilities.languages == installed)
    #expect(!subject.capabilities.languages.isEmpty, "no speech model is installed to test with")
}

/// The two the design turns on. Streaming false is why the caller keeps only
/// finalized lines; diarization false is why two tracks exist at all.
@Test("it declares no streaming and no diarization, which is what it does")
func declaresWhatItActuallyDoes() {
    let subject = SpeechTranscription(languages: ["pt-BR"])

    #expect(!subject.capabilities.streaming)
    #expect(!subject.capabilities.diarization)
    #expect(!subject.capabilities.multitrack)
}

@Test("a request naming no audio is refused before anything is read")
func refusesARequestWithNoAudio() async {
    let subject = SpeechTranscription(languages: ["pt-BR"])

    await #expect(throws: TranscriptionFailure.noAudio) {
        _ = try await subject.transcribe(TranscriptionRequest(audio: [:], language: "pt-BR"))
    }
}

@Test("a language whose model is not here is refused rather than guessed at")
func refusesAnUndeclaredLanguage() async throws {
    let subject = SpeechTranscription(languages: ["pt-BR"])
    let audio = try spoken(seconds: 0.5)
    defer { remove(audio) }

    await #expect(throws: TranscriptionFailure.unsupportedLanguage("zz-ZZ")) {
        _ = try await subject.transcribe(
            TranscriptionRequest(audio: [.microphone: audio], language: "zz-ZZ")
        )
    }
}

@Test("two tracks are refused by a backend that takes one")
func refusesTwoTracks() async throws {
    let subject = SpeechTranscription(languages: ["pt-BR"])
    let audio = try spoken(seconds: 0.5)
    defer { remove(audio) }

    await #expect(throws: TranscriptionFailure.multitrackUnsupported(tracks: 2)) {
        _ = try await subject.transcribe(
            TranscriptionRequest(
                audio: [.microphone: audio, .system: audio],
                language: "pt-BR"
            )
        )
    }
}

/// The failure the fake never had to describe, because a fake never opens a
/// file. It is a refusal rather than transport: the path will not read any
/// better on a second attempt.
@Test("audio that cannot be opened is refused, and named")
func refusesUnreadableAudio() async {
    let subject = SpeechTranscription(languages: ["pt-BR"])
    let missing = URL(filePath: "/nowhere/mic-0001.caf")

    await #expect(throws: TranscriptionFailure.unreadableAudio("mic-0001.caf")) {
        _ = try await subject.transcribe(
            TranscriptionRequest(audio: [.microphone: missing], language: "pt-BR")
        )
    }
}

/// Silence produces no words, and the engine marks a silent stretch with
/// punctuation. A transcript made of full stops is noise a reader steps over.
@Test("silence yields no lines rather than lines holding punctuation")
func silenceYieldsNothing() async throws {
    let subject = await SpeechTranscription.installed()
    try #require(subject.capabilities.languages.contains("pt-BR"))
    let audio = try spoken(seconds: 2)
    defer { remove(audio) }

    let stream = try await subject.transcribe(
        TranscriptionRequest(audio: [.microphone: audio], language: "pt-BR")
    )

    var lines: [TranscriptLine] = []
    for try await event in stream {
        if case .line(let line) = event { lines.append(line) }
    }
    #expect(lines.isEmpty, "silence produced \(lines.map(\.text))")
}

/// The backend held to the same rules as the fake, which is rule five's whole
/// point: a contract only a fake ever met is a contract production never agreed
/// to. Opt-in because it needs a speech model on the machine.
@Test(
    "the speech backend honours the same contract as the fake",
    .enabled(if: ProcessInfo.processInfo.environment["LISTTEN_SPEECH_MODEL"] == "1")
)
func speechBackendHonoursTheContract() async throws {
    let subject = await SpeechTranscription.installed()
    try #require(subject.capabilities.languages.contains("pt-BR"))

    let audio = try await synthesised(
        "Bom dia, vamos começar a reunião de hoje.",
        language: "pt-BR"
    )
    defer { remove(audio) }

    try await verifyTranscribingContract(
        { subject },
        audio: [.microphone: audio, .system: audio],
        language: "pt-BR"
    )
}

/// Recognition returning something is not recognition working. This is the only
/// test that says the words that went in came back out.
@Test(
    "what was spoken is what comes back",
    .enabled(if: ProcessInfo.processInfo.environment["LISTTEN_SPEECH_MODEL"] == "1")
)
func spokenWordsComeBack() async throws {
    let subject = await SpeechTranscription.installed()
    try #require(subject.capabilities.languages.contains("pt-BR"))

    let audio = try await synthesised(
        "Bom dia, vamos começar a reunião de hoje.",
        language: "pt-BR"
    )
    defer { remove(audio) }

    let stream = try await subject.transcribe(
        TranscriptionRequest(audio: [.microphone: audio], language: "pt-BR")
    )
    var lines: [TranscriptLine] = []
    for try await event in stream {
        if case .line(let line) = event { lines.append(line) }
    }

    let heard = lines.map(\.text).joined(separator: " ")
    #expect(heard.contains("reunião"), "heard \(heard)")
    #expect(heard.contains("Bom dia"), "heard \(heard)")
    #expect(lines.allSatisfy { $0.speaker.isEmpty }, "diarization is declared false")
    #expect(lines.allSatisfy { $0.end >= $0.start })
}

/// Observed on a real recording: after the words, a second finalized result
/// arrived reading "." and spanning eight seconds. It cannot be provoked on
/// demand — padding speech with silence does not do it — so the rule is checked
/// directly rather than resting on a fixture nobody can regenerate.
@Test(
    "a result carries words, or it is not a transcript line",
    arguments: [
        ("Bom dia", true),
        ("Teste 123", true),
        ("123", true),
        (".", false),
        ("...", false),
        (" ", false),
        ("", false),
        ("?!", false),
        ("— ,", false),
    ]
)
func onlyResultsWithWordsBecomeLines(text: String, kept: Bool) {
    #expect(SpeechTranscription.carriesWords(text) == kept)
}
