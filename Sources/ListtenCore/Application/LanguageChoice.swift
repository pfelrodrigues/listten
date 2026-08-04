import Foundation

/// What language to transcribe a meeting in: said outright, or worked out from
/// the audio.
///
/// There is no third option worth having. The interface language is not
/// evidence — an English Mac in Brazil reports en-BR, which no model exists for,
/// and settling for en-US transcribed a meeting held in Portuguese into nothing
/// at all. The region is no better: people hold meetings in a language other
/// than the one spoken around them every day.
public enum LanguageChoice: Sendable, Equatable {
    /// The user said so, and nothing overrules that.
    case fixed(String)

    /// Worked out by transcribing a little of the meeting in each installed
    /// language and keeping the one the engine was surest of. Costs about a
    /// quarter of a second per candidate, once per session.
    case detected

    /// Nothing was recognisable in any language, in any segment. A meeting of
    /// silence reaches this, and so does a machine holding only models for
    /// languages nobody in the room speaks.
    public struct Undetectable: Error, Equatable {
        public let tried: [String]
    }

    func resolved(
        against files: [SegmentFile],
        using detector: any LanguageDetecting
    ) async throws -> String {
        if case .fixed(let language) = self { return language }
        // Segment by segment until one is not silence. A meeting that opens with
        // people waiting for the last person to join would otherwise be decided
        // by a minute of nobody talking.
        for file in files.sorted(by: {
            ($0.index, $0.track.rawValue) < ($1.index, $1.track.rawValue)
        }) {
            if let heard = try await detector.language(of: file) { return heard }
        }
        throw Undetectable(tried: detector.candidates)
    }
}
