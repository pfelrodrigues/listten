import Foundation
import Testing

@testable import ListtenCore

/// Waiting, without the wait. What matters about backoff is how long it asked
/// for and how many times, and a test that really slept would only prove the
/// machine can count.
actor SleepRecorder {
    private(set) var waits: [Duration] = []

    nonisolated var sleeping: @Sendable (Duration) async throws -> Void {
        { await self.record($0) }
    }

    private func record(_ duration: Duration) {
        waits.append(duration)
    }
}

private let english = TranscriptionRequest(
    audio: [.microphone: fakeAudio[.microphone]!],
    language: "en-US"
)

private func run(
    _ transcriber: RetryingTranscriber,
    _ request: TranscriptionRequest = english
) async throws -> Transcribed {
    try await transcribed(await transcriber.transcribe(request))
}

@Test("a timeout is tried again, and the transcript comes back from the attempt that worked")
func aTimeoutIsTriedAgain() async throws {
    let backend = FakeTranscriber(faults: [.timedOut])
    let waited = SleepRecorder()
    let transcriber = RetryingTranscriber(wrapping: backend, sleeping: waited.sleeping)

    let run = try await run(transcriber)

    #expect(await backend.attempts.count == 2)
    #expect(
        run.finalized == FakeTranscriber.expected(for: english, diarization: false),
        "the retry did not produce the transcript the backend had"
    )
    #expect(await waited.waits == [.seconds(0.5)])
}

@Test("the wait doubles with every attempt that failed")
func theWaitDoublesBetweenAttempts() async throws {
    let backend = FakeTranscriber(faults: [.timedOut, .serverError(status: 503)])
    let waited = SleepRecorder()
    let transcriber = RetryingTranscriber(wrapping: backend, sleeping: waited.sleeping)

    let run = try await run(transcriber)

    #expect(await backend.attempts.count == 3)
    #expect(!run.finalized.isEmpty)
    #expect(await waited.waits == [.seconds(0.5), .seconds(1)])
}

@Test("a rate limit is waited out for as long as it asked")
func aRateLimitIsWaitedOutForAsLongAsItAsked() async throws {
    let backend = FakeTranscriber(faults: [.rateLimited(retryAfter: 7)])
    let waited = SleepRecorder()
    let transcriber = RetryingTranscriber(wrapping: backend, sleeping: waited.sleeping)

    let run = try await run(transcriber)

    #expect(!run.finalized.isEmpty)
    #expect(await waited.waits == [.seconds(7)], "the backend's own delay was ignored")
}

@Test("a rate limit that names no delay falls back to the backoff")
func aRateLimitWithoutADelayFallsBackToTheBackoff() async throws {
    let backend = FakeTranscriber(faults: [.rateLimited(retryAfter: nil)])
    let waited = SleepRecorder()
    let transcriber = RetryingTranscriber(wrapping: backend, sleeping: waited.sleeping)

    let run = try await run(transcriber)

    #expect(!run.finalized.isEmpty)
    #expect(await waited.waits == [.seconds(0.5)])
}

@Test("the attempts run out and the last failure is what the caller hears")
func theAttemptsRunOut() async throws {
    let backend = FakeTranscriber(faults: [.timedOut, .timedOut, .serverError(status: 500)])
    let waited = SleepRecorder()
    let transcriber = RetryingTranscriber(wrapping: backend, sleeping: waited.sleeping)

    await #expect(throws: TranscriptionFailure.serverError(status: 500)) {
        _ = try await run(transcriber)
    }

    #expect(await backend.attempts.count == 3, "the policy allows three attempts, no more")
    #expect(await waited.waits == [.seconds(0.5), .seconds(1)])
}

/// A response nothing could parse is a bug in the exchange, not weather. The
/// next attempt produces the same unreadable answer, and spending the budget on
/// it delays the failure the caller has to see.
@Test("a response nothing can read is not tried again")
func aMalformedResponseIsNotTriedAgain() async throws {
    let backend = FakeTranscriber(faults: [.malformedResponse("lines: [")])
    let waited = SleepRecorder()
    let transcriber = RetryingTranscriber(wrapping: backend, sleeping: waited.sleeping)

    await #expect(throws: TranscriptionFailure.malformedResponse("lines: [")) {
        _ = try await run(transcriber)
    }

    #expect(await backend.attempts.count == 1)
    #expect(await waited.waits.isEmpty)
}

/// A refusal is about the request, so retrying it is spending the budget on the
/// same answer. It also reaches the caller by the same door the backend used.
@Test("a refusal is thrown as it was raised, and never retried")
func aRefusalIsNotRetried() async throws {
    let backend = FakeTranscriber()
    let waited = SleepRecorder()
    let transcriber = RetryingTranscriber(wrapping: backend, sleeping: waited.sleeping)
    let unsupported = TranscriptionRequest(
        audio: [.microphone: fakeAudio[.microphone]!],
        language: "zz-ZZ"
    )

    await #expect(throws: TranscriptionFailure.unsupportedLanguage("zz-ZZ")) {
        _ = try await transcriber.transcribe(unsupported)
    }

    #expect(await backend.attempts.count == 1)
    #expect(await waited.waits.isEmpty)
}

/// Restarting would send those lines a second time, and the caller has no way to
/// tell a repeat from a sentence that was said twice.
@Test("a failure after a line was handed over is not retried, and that line is kept")
func aFailureAfterALineIsNotRetried() async throws {
    // One hypothesis and the line that settled it, then the failure.
    let backend = FakeTranscriber(faults: [.timedOut], deliveredBeforeFault: 2)
    let waited = SleepRecorder()
    let transcriber = RetryingTranscriber(wrapping: backend, sleeping: waited.sleeping)

    var delivered: [TranscriptionEvent] = []
    await #expect(throws: TranscriptionFailure.timedOut) {
        for try await event in try await transcriber.transcribe(english) {
            delivered.append(event)
        }
    }

    #expect(delivered.count == 2, "what the backend had already handed over was dropped")
    #expect(await backend.attempts.count == 1)
    #expect(await waited.waits.isEmpty)
}

/// A hypothesis is revisable by the port's own terms and nothing stores one, so
/// a retry that replaces it costs the caller nothing.
@Test("a failure after nothing but a hypothesis is retried")
func aFailureAfterOnlyAHypothesisIsRetried() async throws {
    let backend = FakeTranscriber(faults: [.timedOut], deliveredBeforeFault: 1)
    let waited = SleepRecorder()
    let transcriber = RetryingTranscriber(wrapping: backend, sleeping: waited.sleeping)

    let run = try await run(transcriber)

    #expect(await backend.attempts.count == 2)
    #expect(
        run.finalized == FakeTranscriber.expected(for: english, diarization: false),
        "the retry did not produce the transcript the backend had"
    )
    #expect(await waited.waits == [.seconds(0.5)])
}

@Test("what the backend can do is what the caller is told, retries or not")
func capabilitiesAreTheBackendsOwn() async {
    let capabilities = TranscriptionCapabilities(
        streaming: false,
        multitrack: true,
        diarization: true,
        languages: ["pt-BR"]
    )
    let transcriber = RetryingTranscriber(
        wrapping: FakeTranscriber(capabilities: capabilities),
        sleeping: { _ in }
    )

    #expect(transcriber.capabilities == capabilities)
}

@Test("a backend that does not fail is not waited on")
func aBackendThatWorksIsNotWaitedOn() async throws {
    let backend = FakeTranscriber()
    let waited = SleepRecorder()
    let transcriber = RetryingTranscriber(wrapping: backend, sleeping: waited.sleeping)

    let run = try await run(transcriber)

    #expect(await backend.attempts.count == 1)
    #expect(await waited.waits.isEmpty)
    #expect(run.finalized == FakeTranscriber.expected(for: english, diarization: false))
    #expect(run.partials.count == run.finalized.count, "the hypotheses were swallowed")
}

/// A transcription costs the backend real work, and a caller that walked away
/// will not read it. The retry waits, which is exactly where a caller that
/// stopped listening becomes visible.
@Test("a caller that stopped listening is not retried for")
func aCallerThatStoppedListeningIsNotRetriedFor() async throws {
    let backend = FakeTranscriber(faults: [.timedOut], deliveredBeforeFault: 1)
    let gate = Gate()
    let transcriber = RetryingTranscriber(wrapping: backend, sleeping: gate.sleeping)

    var received: [TranscriptionEvent] = []
    for try await event in try await transcriber.transcribe(english) {
        received.append(event)
        break
    }
    await gate.open()
    // A retry that was going to happen is one hop away by now, and nothing else
    // in this test is waiting on anything.
    try await Task.sleep(for: .milliseconds(50))

    #expect(received.count == 1)
    #expect(
        await backend.attempts.count == 1,
        "a caller that left still cost the backend a whole transcription"
    )
}
