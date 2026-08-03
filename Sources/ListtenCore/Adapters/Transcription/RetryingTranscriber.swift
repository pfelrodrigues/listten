import Foundation

/// A transcriber that gives a failing backend another go, for the failures a
/// second attempt can do something about: a timeout, a rate limit, a server
/// error. It changes nothing else, so what a caller may ask of the backend is
/// what it may ask of this.
///
/// Two things it will not retry. A refusal, because the request is what it
/// objected to and repeating it produces the same objection. And any failure
/// that arrived after a finalized line reached the caller, because starting over
/// would send those lines a second time and nothing downstream can tell a repeat
/// from a sentence that was said twice. A hypothesis is different: the port says
/// a later one may replace it and that nothing stores it, so a retry that
/// discards one costs the caller nothing.
public struct RetryingTranscriber: Transcribing {
    /// How many attempts in total, and the wait before the second of them. The
    /// wait doubles from there, and a backend that named its own delay overrides
    /// it: waiting less than it asked is how a rate limit turns into a ban.
    public struct Policy: Sendable, Equatable {
        public let attempts: Int
        public let backoff: TimeInterval

        public init(attempts: Int = 3, backoff: TimeInterval = 0.5) {
            self.attempts = attempts
            self.backoff = backoff
        }
    }

    private let backend: any Transcribing
    private let policy: Policy
    private let sleeping: @Sendable (Duration) async throws -> Void

    public var capabilities: TranscriptionCapabilities { backend.capabilities }

    /// `sleeping` is injected so a test can assert what was waited for without
    /// waiting for it.
    public init(
        wrapping backend: any Transcribing,
        policy: Policy = Policy(),
        sleeping: @escaping @Sendable (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        }
    ) {
        self.backend = backend
        self.policy = policy
        self.sleeping = sleeping
    }

    /// The first attempt is made here rather than inside the stream, so a
    /// refusal reaches the caller by throwing, exactly as the backend raised it.
    public func transcribe(
        _ request: TranscriptionRequest
    ) async throws -> AsyncThrowingStream<TranscriptionEvent, any Error> {
        let first = try await backend.transcribe(request)
        return AsyncThrowingStream { continuation in
            let attempting = Task {
                await attempt(request, from: first, into: continuation)
            }
            continuation.onTermination = { _ in attempting.cancel() }
        }
    }

    private func attempt(
        _ request: TranscriptionRequest,
        from first: AsyncThrowingStream<TranscriptionEvent, any Error>,
        into continuation: AsyncThrowingStream<TranscriptionEvent, any Error>.Continuation
    ) async {
        var current = first
        var attempts = 1

        while true {
            var handedOver = 0
            do {
                for try await event in current {
                    if case .line = event { handedOver += 1 }
                    continuation.yield(event)
                }
                continuation.finish()
                return
            } catch {
                guard
                    handedOver == 0, attempts < policy.attempts,
                    let wait = waitBefore(attempts + 1, after: error)
                else {
                    continuation.finish(throwing: error)
                    return
                }
                attempts += 1
                do {
                    try await sleeping(wait)
                    // A caller may have walked away while the retry waited, and
                    // a transcription nobody will read is work the backend does
                    // for nothing.
                    try Task.checkCancellation()
                    current = try await backend.transcribe(request)
                } catch {
                    continuation.finish(throwing: error)
                    return
                }
            }
        }
    }

    /// Nil where the failure is not one another attempt can answer, including
    /// anything the backend raised that this port does not describe: an error
    /// nobody classified is not known to be weather.
    private func waitBefore(_ attempt: Int, after error: any Error) -> Duration? {
        let backoff = Duration.seconds(policy.backoff * pow(2, Double(attempt - 2)))
        switch error as? TranscriptionFailure {
        case .rateLimited(let retryAfter):
            return retryAfter.map { Duration.seconds($0) } ?? backoff
        case .timedOut, .serverError:
            return backoff
        case .noAudio, .unsupportedLanguage, .multitrackUnsupported, .unreadableAudio,
            .malformedResponse, nil:
            return nil
        }
    }
}
