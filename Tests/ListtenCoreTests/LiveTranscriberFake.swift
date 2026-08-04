import Foundation
import Synchronization

@testable import ListtenCore

/// Counts the calls, so a test can prove no analyser was opened for a track
/// before a buffer for it arrived. Opening one early makes a model resident for
/// a meeting nobody confirmed.
final class LiveTranscriberSpy: Sendable {
    private let calls = Mutex<[String]>([])

    var opened: Int { calls.withLock { $0.count } }
    var languages: [String] { calls.withLock { $0 } }

    func record(_ language: String) {
        calls.withLock { $0.append(language) }
    }
}

/// What the live backends stop doing at, so a caller's handling of a transcript
/// that died mid-meeting is one both a fake and a real failure reach.
struct LiveBackendStopped: Error, Equatable {}

/// An analyser that could not be built, which is what a second one competing for
/// the same resources looks like from here.
struct LiveBackendRefusedTheTrack: Error, Equatable {}

/// A count every copy of the struct holding it shares, since one backend value
/// is asked for a transcription once per track.
private final class Opens: Sendable {
    private let count = Mutex(0)

    func next() -> Int {
        count.withLock {
            $0 += 1
            return $0
        }
    }
}

/// A live backend that transcribes nothing and behaves the way one does: it
/// hears audio, revises what it has while it hears, settles what it heard when
/// asked, and finalizes the remainder when the input ends.
///
/// It derives its lines from the audio it was fed rather than from a fixture, so
/// the rule that no line reaches past the audio heard means the same thing for
/// it as for the engine. Held to `verifyLiveTranscribingContract`, like every
/// implementation.
struct FakeLiveTranscriber: LiveTranscribing {
    let capabilities: TranscriptionCapabilities
    let spy: LiveTranscriberSpy?
    /// Finals to hand over before the stream fails, so a transcript that stops
    /// mid-meeting is something a test can stage.
    let failingAfter: Int?
    /// Transcriptions to accept before refusing to start another, which is how
    /// one track losing its analyser is staged without losing the other.
    let openingFailsAfter: Int?

    private let opens = Opens()

    init(
        capabilities: TranscriptionCapabilities = .fakeLive,
        spy: LiveTranscriberSpy? = nil,
        failingAfter: Int? = nil,
        openingFailsAfter: Int? = nil
    ) {
        self.capabilities = capabilities
        self.spy = spy
        self.failingAfter = failingAfter
        self.openingFailsAfter = openingFailsAfter
    }

    func transcribe(
        _ request: LiveTranscriptionRequest,
        hearing audio: AsyncStream<LiveAudioEvent>
    ) async throws -> AsyncThrowingStream<TranscriptionEvent, any Error> {
        spy?.record(request.language)
        guard capabilities.languages.contains(request.language) else {
            throw TranscriptionFailure.unsupportedLanguage(request.language)
        }
        if let openingFailsAfter, opens.next() > openingFailsAfter {
            throw LiveBackendRefusedTheTrack()
        }

        let capabilities = capabilities
        let failingAfter = failingAfter
        return AsyncThrowingStream { continuation in
            let work = Task {
                var heard: TimeInterval = 0
                var settled: TimeInterval = 0
                var finals = 0

                func settle() -> Bool {
                    guard heard > settled else { return true }
                    continuation.yield(
                        .line(
                            line(capabilities, from: settled, to: heard, "chunk \(finals)")
                        )
                    )
                    settled = heard
                    finals += 1
                    guard finals != failingAfter else {
                        continuation.finish(throwing: LiveBackendStopped())
                        return false
                    }
                    return true
                }

                for await event in audio {
                    switch event {
                    case .audio(let buffer):
                        guard buffer.sampleRate > 0 else { continue }
                        heard += Double(buffer.frames) / buffer.sampleRate
                        guard capabilities.streaming else { continue }
                        continuation.yield(
                            .partial(line(capabilities, from: settled, to: heard, "still hearing"))
                        )
                    case .settle:
                        guard settle() else { return }
                    }
                }

                guard settle() else { return }
                continuation.finish()
            }
            continuation.onTermination = { _ in work.cancel() }
        }
    }
}

/// Written here, so a line this fake could not hold fails the suite rather than
/// being caught somewhere a caller cannot see.
private func line(
    _ capabilities: TranscriptionCapabilities,
    from start: TimeInterval,
    to end: TimeInterval,
    _ text: String
) -> TranscriptLine {
    try! TranscriptLine(
        speaker: capabilities.diarization ? "someone" : "",
        start: start,
        end: end,
        text: text
    )
}

extension TranscriptionCapabilities {
    /// What the live fake declares unless a test asks otherwise: the shape
    /// `SpeechLiveTranscription` ships, which streams, takes one track and
    /// leaves attribution to the caller.
    static let fakeLive = TranscriptionCapabilities(
        streaming: true,
        multitrack: false,
        diarization: false,
        languages: ["en-US", "pt-BR"]
    )
}

/// Accepts a transcription, produces nothing, and never reads the audio handed
/// to it. The bounded queue in front of it fills and everything after that is
/// dropped, which is what a backend falling behind looks like from the
/// orchestrator.
struct DeafLiveTranscriber: LiveTranscribing {
    let capabilities: TranscriptionCapabilities = .fakeLive

    func transcribe(
        _ request: LiveTranscriptionRequest,
        hearing audio: AsyncStream<LiveAudioEvent>
    ) async throws -> AsyncThrowingStream<TranscriptionEvent, any Error> {
        AsyncThrowingStream { $0.finish() }
    }
}
