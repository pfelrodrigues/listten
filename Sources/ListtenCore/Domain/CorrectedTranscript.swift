import Foundation

/// A transcript and what correction made of it, held together.
///
/// Correction is derived, never destructive: the raw transcript stays beside the
/// corrected one the way audio stays authoritative over the transcript. There is
/// no way to build one of these from a corrected transcript alone, and a stored
/// one that has lost its raw transcript does not decode, so what a glossary got
/// wrong is always still recoverable from what was heard.
///
/// The stored corrected transcript is kept rather than derived again on load:
/// the rules change as terms are added, and re-deriving would silently rewrite
/// the text a note was already written from.
public struct CorrectedTranscript: Sendable, Equatable, Codable {
    public let raw: Transcript
    public let corrected: Transcript

    /// The only way in, so `corrected` cannot be anything but what the rules
    /// made of `raw`.
    ///
    /// The glossary is the whole of correction for now. Normalizing number words
    /// was measured at about a fifth of what the glossary is worth and shipped
    /// with a cost it could not pay: a word list cannot tell "zero trust", which
    /// is a term, from "zero licences", which is a count, so it corrupted user
    /// vocabulary to normalize a count. Correction that makes text worse is not
    /// correction, so it is out until it can read a span the glossary owns.
    /// See #80.
    ///
    /// Correction touches the words alone, and each line goes back through the
    /// door that validates its instants.
    public init(raw: Transcript, glossary: Glossary) throws {
        self.raw = raw
        self.corrected = Transcript(
            lines: try raw.lines.map { line in
                try TranscriptLine(
                    speaker: line.speaker,
                    start: line.start,
                    end: line.end,
                    text: glossary.correcting(line.text)
                )
            }
        )
    }
}
