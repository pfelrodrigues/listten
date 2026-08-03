import Foundation

/// One utterance. `speaker` is an open string so named diarization can arrive
/// later without migrating stored transcripts.
public struct TranscriptLine: Sendable, Equatable, Codable {
    /// An utterance no transcriber can produce, carrying what was offered.
    public enum Impossible: Error, Equatable {
        case negativeStart(TimeInterval)
        case endBeforeStart(start: TimeInterval, end: TimeInterval)
    }

    public let speaker: String
    public let start: TimeInterval
    public let end: TimeInterval
    public let text: String

    /// Both instants are on the session clock, which starts at zero and runs
    /// forwards. Speaker and text are left open: diarization may not have named
    /// anyone yet, and a recognizer reporting nothing still reports an instant.
    public init(speaker: String, start: TimeInterval, end: TimeInterval, text: String) throws {
        guard start >= 0 else { throw Impossible.negativeStart(start) }
        guard end >= start else { throw Impossible.endBeforeStart(start: start, end: end) }
        self.speaker = speaker
        self.start = start
        self.end = end
        self.text = text
    }

    /// Decoding is the other way in, so it goes through the same door.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            speaker: container.decode(String.self, forKey: .speaker),
            start: container.decode(TimeInterval.self, forKey: .start),
            end: container.decode(TimeInterval.self, forKey: .end),
            text: container.decode(String.self, forKey: .text)
        )
    }
}

public struct Transcript: Sendable, Equatable, Codable {
    public let lines: [TranscriptLine]

    public init(lines: [TranscriptLine]) {
        self.lines = lines
    }

    /// Both tracks are stamped on the same clock at capture, which is what makes
    /// interleaving them by start instant produce the actual conversation.
    /// Ties are broken towards the microphone, since Swift's sort is not
    /// guaranteed to be stable and overlapping speech is common.
    public static func merging(
        microphone: [TranscriptLine],
        system: [TranscriptLine]
    ) -> Transcript {
        struct Ranked {
            let line: TranscriptLine
            let priority: Int
        }

        var ranked: [Ranked] = microphone.map { Ranked(line: $0, priority: 0) }
        ranked += system.map { Ranked(line: $0, priority: 1) }

        ranked.sort { left, right in
            if left.line.start == right.line.start {
                return left.priority < right.priority
            }
            return left.line.start < right.line.start
        }

        return Transcript(lines: ranked.map(\.line))
    }
}
