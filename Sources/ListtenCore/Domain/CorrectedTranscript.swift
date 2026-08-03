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
    /// The glossary runs first: its variants are what the recognizer wrote, and
    /// normalizing "em four" to "em 4" first would leave nothing for a term
    /// holding a number to match. The cost runs the other way: normalization then
    /// reads what the glossary produced, so a term whose own spelling holds a
    /// standalone number word comes back with digits. Correction touches the
    /// words alone, and each line goes back through the door that validates its
    /// instants.
    public init(raw: Transcript, glossary: Glossary) throws {
        self.raw = raw
        self.corrected = Transcript(
            lines: try raw.lines.map { line in
                try TranscriptLine(
                    speaker: line.speaker,
                    start: line.start,
                    end: line.end,
                    text: Normalization.normalizing(glossary.correcting(line.text))
                )
            }
        )
    }
}
