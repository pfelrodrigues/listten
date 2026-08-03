import Foundation
import Testing

@testable import ListtenCore

/// The bug this milestone starts from: a recording that ends before the first
/// rotation had nothing closed, so it measured zero and was thrown away whole.
@Test("stopping before the first rotation still yields the audio captured so far")
func stoppingBeforeTheFirstRotationKeepsItsAudio() async throws {
    let capture: any AudioCapturing = FakeAudioCapture(length: 40, rotateEvery: 45)

    var rotated: [Segment] = []
    for await segment in try await capture.start() {
        rotated.append(segment)
    }
    let finalised = try await capture.stop()

    #expect(rotated.isEmpty)
    #expect(finalised.map(\.duration) == [40, 40])

    var session = try Session(id: "s1", startedAt: .init(timeIntervalSince1970: 0))
        .applying(.confirm)
    for segment in rotated + finalised {
        session = try session.appending(segment)
    }
    #expect(session.duration == 40)
}

@Test("a recording longer than one rotation closes segments and finalizes the remainder")
func longerRecordingRotatesThenFinalizes() async throws {
    let capture: any AudioCapturing = FakeAudioCapture(length: 100, rotateEvery: 45)

    var rotated: [Segment] = []
    for await segment in try await capture.start() {
        rotated.append(segment)
    }
    let finalised = try await capture.stop()

    #expect(rotated.filter { $0.track == .microphone }.map(\.start) == [0, 45])
    #expect(finalised.map(\.start) == [90, 90])
    #expect((rotated + finalised).map(\.end).max() == 100)
}

@Test("a recording ending exactly on a rotation leaves nothing to finalize")
func recordingEndingOnARotationHasNoRemainder() async throws {
    let capture: any AudioCapturing = FakeAudioCapture(length: 90, rotateEvery: 45)

    for await _ in try await capture.start() {}

    #expect(try await capture.stop().isEmpty)
}

@Test("both tracks close on the same instants, which is what makes them interleavable")
func bothTracksShareTheSameClock() async throws {
    let capture: any AudioCapturing = FakeAudioCapture(length: 100, rotateEvery: 45)

    var all: [Segment] = []
    for await segment in try await capture.start() {
        all.append(segment)
    }
    all += try await capture.stop()

    let spans = { (track: Track) in
        all.filter { $0.track == track }.map { [$0.start, $0.end] }
    }
    #expect(spans(.microphone) == spans(.system))
}
