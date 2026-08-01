import Foundation

/// Domain terms a speech recognizer tends to render phonetically, and the forms
/// it produces. Correction is derived: the raw transcript is always kept.
public struct Glossary: Sendable, Equatable, Codable {
    public struct Entry: Sendable, Equatable, Codable {
        public let term: String
        public let heardAs: [String]

        public init(term: String, heardAs: [String]) {
            self.term = term
            self.heardAs = heardAs
        }
    }

    public let entries: [Entry]

    public init(entries: [Entry]) {
        self.entries = entries
    }

    public func correcting(_ text: String) -> String {
        entries.reduce(text) { corrected, entry in
            entry.heardAs.reduce(corrected) { partial, variant in
                Self.replacingWholeWords(of: variant, with: entry.term, in: partial)
            }
        }
    }

    /// Matching anywhere in the string would turn "branches" into "PRes", so
    /// the variant has to sit on word boundaries. Terms may contain spaces,
    /// which rules out splitting the text on whitespace.
    private static func replacingWholeWords(
        of variant: String,
        with term: String,
        in text: String
    ) -> String {
        var result = ""
        var index = text.startIndex

        while let found = text.range(
            of: variant,
            options: .caseInsensitive,
            range: index..<text.endIndex
        ) {
            result += text[index..<found.lowerBound]
            result += isWholeWord(found, in: text) ? term : String(text[found])
            index = found.upperBound
        }

        result += text[index...]
        return result
    }

    private static func isWholeWord(_ range: Range<String.Index>, in text: String) -> Bool {
        let before = range.lowerBound == text.startIndex
        let after = range.upperBound == text.endIndex
        return (before || !text[text.index(before: range.lowerBound)].isLetter)
            && (after || !text[range.upperBound].isLetter)
    }
}
