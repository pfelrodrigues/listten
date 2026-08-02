import Foundation
import Testing

@testable import ListtenCore

/// The rules every `AudioSource` obeys, written once so the fake cannot drift
/// away from the real device. Three times now a fake has defined behaviour the
/// production side never agreed to; this is the answer to that.
func verifyAudioSourceContract(
    _ make: @Sendable () -> any AudioSource,
    sourceLocation: SourceLocation = #_sourceLocation
) async throws {
    let stoppingUnstarted = make()
    await stoppingUnstarted.stop()

    let doubleStart = make()
    _ = try await doubleStart.start()
    await #expect(throws: CaptureAlreadyStarted.self, sourceLocation: sourceLocation) {
        _ = try await doubleStart.start()
    }
    await doubleStart.stop()
    await doubleStart.stop()

    let delivering = make()
    let stream = try await delivering.start()
    let stopper = Task {
        try? await Task.sleep(for: .milliseconds(300))
        await delivering.stop()
    }
    for await audio in stream {
        #expect(
            audio.sampleRate > 0,
            "a buffer with no usable rate",
            sourceLocation: sourceLocation
        )
        #expect(audio.hostTime > 0, "a buffer with no stamp", sourceLocation: sourceLocation)
    }
    stopper.cancel()
}

@Test("the fake source honours the contract")
func fakeSourceHonoursTheContract() async throws {
    try await verifyAudioSourceContract { FakeAudioSource(buffers: 3) }
}

/// Needs a real input device and a granted permission, so it is opt-in:
/// `LISTTEN_AUDIO_HARDWARE=1 swift test`.
@Test(
    "the microphone honours the same contract as the fake",
    .enabled(if: ProcessInfo.processInfo.environment["LISTTEN_AUDIO_HARDWARE"] == "1")
)
func microphoneHonoursTheContract() async throws {
    try await verifyAudioSourceContract { MicrophoneCapture() }
}
