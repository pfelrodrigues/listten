import Foundation
import Testing

@testable import ListtenCore

/// The rules every `AudioSource` obeys, written once so the fake cannot drift
/// away from the real device. Three times now a fake has defined behaviour the
/// production side never agreed to; this is the answer to that.
///
/// `delivering` is how this source is made to produce: a device produces on its
/// own and only needs time to pass, while a source driven by a hand-moved clock
/// hears nothing until it is pushed. `expectingAudio` says that push must have
/// arrived, so a driven source whose control surface stopped working fails here
/// instead of passing an empty loop.
func verifyAudioSourceContract<Source: AudioSource>(
    _ make: @Sendable () -> Source,
    delivering deliver: @escaping @Sendable (Source) async -> Void = { _ in
        try? await Task.sleep(for: .milliseconds(300))
    },
    expectingAudio: Bool = false,
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
        await deliver(delivering)
        await delivering.stop()
    }
    var received = 0
    for await audio in stream {
        received += 1
        #expect(
            audio.sampleRate > 0,
            "a buffer with no usable rate",
            sourceLocation: sourceLocation
        )
        #expect(audio.hostTime > 0, "a buffer with no stamp", sourceLocation: sourceLocation)
    }
    stopper.cancel()
    // Only where delivery was driven: hardware can be silent for 300ms and
    // asserting on it there would be a flake rather than a guarantee.
    if expectingAudio {
        #expect(received > 0, "a driven source delivered nothing", sourceLocation: sourceLocation)
    }
}

@Test("the fake source honours the contract")
func fakeSourceHonoursTheContract() async throws {
    // A fake built from a count delivers that many or it is broken, so the
    // per-buffer expectations above are held to having run.
    try await verifyAudioSourceContract({ FakeAudioSource(buffers: 3) }, expectingAudio: true)
}

@Test("the clock-driven fake honours the same contract")
func clockDrivenFakeHonoursTheContract() async throws {
    try await verifyAudioSourceContract(
        { FakeAudioSource(clock: ManualTimeSource()) },
        delivering: { await $0.advance(by: 0.3) },
        expectingAudio: true
    )
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

private func drained(_ stream: AsyncStream<CapturedAudio>) async -> [CapturedAudio] {
    var received: [CapturedAudio] = []
    for await audio in stream {
        received.append(audio)
    }
    return received
}

@Test("the clock-driven fake delivers nothing until its clock is advanced")
func clockDrivenFakeDeliversNothingUntilAdvanced() async throws {
    let source = FakeAudioSource(clock: ManualTimeSource())

    let stream = try await source.start()
    await source.stop()

    #expect(await drained(stream).isEmpty)
}

@Test("advancing the clock delivers one buffer for every buffer's worth of time that passed")
func advancingTheClockDeliversABufferPerInterval() async throws {
    let source = FakeAudioSource(clock: ManualTimeSource(now: .init(timeIntervalSince1970: 1000)))

    let stream = try await source.start()
    // Three whole buffers, however narrowly three tenths misses in a Double.
    await source.advance(by: 0.3)
    await source.stop()

    let stamps = await drained(stream).map(\.hostTime)
    #expect(stamps.count == 3)
    #expect(zip(stamps, [1000, 1000.1, 1000.2]).allSatisfy { abs($0 - $1) < 1e-9 })
}

@Test("time left over from one advance counts towards the next")
func leftoverTimeCountsTowardsTheNextAdvance() async throws {
    let source = FakeAudioSource(clock: ManualTimeSource(now: .init(timeIntervalSince1970: 1000)))

    let stream = try await source.start()
    // Two whole buffers and a quarter of a third, which the second call completes.
    await source.advance(by: 0.25)
    await source.advance(by: 0.05)
    await source.stop()

    let stamps = await drained(stream).map(\.hostTime)
    #expect(stamps.count == 3)
    #expect(zip(stamps, [1000, 1000.1, 1000.2]).allSatisfy { abs($0 - $1) < 1e-9 })
}

/// The point of the clock being a `TimeSource` rather than a counter the fake
/// keeps to itself: whatever measures the capture reads the instant the test
/// advanced to, so #12 can ask what the pre-roll held at that moment.
@Test("the clock a collaborator reads is the one the test advanced")
func advancingMovesTheClockACollaboratorReads() async throws {
    let clock = ManualTimeSource(now: .init(timeIntervalSince1970: 1000))
    let source = FakeAudioSource(clock: clock)

    _ = try await source.start()
    await source.advance(by: 0.25)

    #expect(clock.now == Date(timeIntervalSince1970: 1000.25))
}
