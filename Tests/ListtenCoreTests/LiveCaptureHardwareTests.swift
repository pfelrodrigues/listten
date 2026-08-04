import AVFoundation
import Foundation
import Testing

@testable import ListtenCore

/// #90's first acceptance, and the one that outranks the others: capture loses
/// nothing while a live transcript is being written from the same audio. Audio
/// is the only thing in this system that cannot be reproduced, so a non-zero
/// drop count fails this outright.
///
/// It builds the two sources itself rather than going through `Composition`,
/// because `droppedBuffers` and `restarts` live on the concrete actors and
/// nothing hands them back through `AudioCapturing`. Forwarding them so the
/// whole criterion can be read off the shipping wiring is worth its own issue;
/// it is not worth widening a port inside this one. The live half is read off
/// the same objects the product builds.
///
/// Needs a microphone, the audio capture permission and a speech model, so it
/// is opt-in twice over:
/// `LISTTEN_AUDIO_HARDWARE=1 LISTTEN_SPEECH_MODEL=1 swift test`.
@Test(
    "capture loses nothing while a live transcript is being written",
    .enabled(if: ProcessInfo.processInfo.environment["LISTTEN_AUDIO_HARDWARE"] == "1"),
    .enabled(if: ProcessInfo.processInfo.environment["LISTTEN_SPEECH_MODEL"] == "1"),
    .timeLimit(.minutes(2))
)
func captureLosesNothingWhileTranscribingLive() async throws {
    let backend = await SpeechLiveTranscription.installed()
    let language = try #require(backend.capabilities.languages.sorted().first)

    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let session = "hardware"

    let microphone = MicrophoneCapture()
    let tap = SystemAudioCapture()
    let sink = StreamingLiveAudioSink()
    let capture = SegmentedCapture(
        sources: [.microphone: microphone, .system: tap],
        directory: root.appending(path: session).appending(path: "audio"),
        rotateEvery: 45,
        live: sink
    )
    let transcript = LiveTranscript(
        audio: sink.stream,
        sink: sink,
        backend: backend,
        writer: SessionLiveTranscripts(root: root),
        sessionID: session,
        language: language
    )

    let segments = try await capture.start()
    let closing = Task { for await _ in segments {} }
    let running = Task { await transcript.run() }

    // Long enough for several settles at the five second cadence, and for a
    // drop to show up if the conversion or the analysers cost more than the
    // writer's slack.
    try await Task.sleep(for: .seconds(30))
    _ = try await capture.stop()
    await closing.value
    await running.value

    #expect(await microphone.droppedBuffers == 0, "the microphone lost audio to the live path")
    #expect(await microphone.restarts == 0, "the microphone had to be brought back")
    #expect(await tap.droppedBuffers == 0, "the system tap lost audio to the live path")
    #expect(await tap.restarts == 0, "the system tap had to be brought back")

    let outcome = await transcript.outcome()
    #expect(outcome.dropped == 0, "the live side fell behind by \(outcome.dropped) buffers")
    #expect(!outcome.endedEarly, "the live transcript stopped before the recording did")
    #expect(outcome.failure == nil, "the live transcript reported \(outcome.failure ?? "")")
}
