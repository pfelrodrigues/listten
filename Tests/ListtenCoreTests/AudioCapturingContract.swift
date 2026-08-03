import Foundation
import Testing

@testable import ListtenCore

/// The rules every `AudioCapturing` obeys, written once so a fake cannot hand
/// the aggregate a value the device would never produce. The session identifies
/// a segment by `(track, index)`, so a capture may not repeat one.
func verifyAudioCapturingContract(
    _ make: @Sendable () -> any AudioCapturing,
    sourceLocation: SourceLocation = #_sourceLocation
) async throws {
    let unstarted = make()
    #expect(
        try await unstarted.stop().isEmpty,
        "stopping a capture that never started reported audio",
        sourceLocation: sourceLocation
    )

    let restarted = make()
    _ = try await restarted.start()
    await #expect(throws: CaptureAlreadyStarted.self, sourceLocation: sourceLocation) {
        _ = try await restarted.start()
    }
    _ = try await restarted.stop()
    #expect(
        try await restarted.stop().isEmpty,
        "stopping twice reported the same audio again",
        sourceLocation: sourceLocation
    )

    let capture = make()

    var produced: [Segment] = []
    for await segment in try await capture.start() {
        produced.append(segment)
    }
    produced += try await capture.stop()

    #expect(
        !produced.isEmpty,
        "a capture that delivered nothing proves nothing",
        sourceLocation: sourceLocation
    )
    // Appending them all is how a caller consumes a capture, and the aggregate refuses a repeat.
    var session = try Session(id: "contract", startedAt: .init(timeIntervalSince1970: 0))
        .applying(.confirm)
    for segment in produced {
        session = try session.appending(segment)
    }
}

/// Rotations that do not divide the length exactly are the interesting ones:
/// they are where an index derived from accumulated time repeats itself.
@Test(
    "the fake capture honours the contract, whatever the rotation divides into",
    arguments: [(100.0, 45.0), (1.0, 0.1), (3.0, 0.3), (2.0, 0.2)]
)
func fakeCaptureHonoursTheContract(length: TimeInterval, rotateEvery: TimeInterval) async throws {
    try await verifyAudioCapturingContract {
        FakeAudioCapture(length: length, rotateEvery: rotateEvery)
    }
}
