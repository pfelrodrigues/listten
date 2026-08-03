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

    /// One left-to-right pass over the original text: a stretch already
    /// rewritten is never looked at again, so no entry can rewrite what another
    /// produced. Where several variants match at one position the longest wins,
    /// which is what keeps the result independent of the order entries are
    /// declared in.
    public func correcting(_ text: String) -> String {
        var result = ""
        var index = text.startIndex

        while index < text.endIndex {
            if let match = longestMatch(in: text, at: index) {
                result += match.term
                index = match.end
            } else {
                result.append(text[index])
                index = text.index(after: index)
            }
        }

        return result
    }

    /// The longest variant starting exactly at `index` and standing as a whole
    /// word, first declaration winning ties.
    private func longestMatch(
        in text: String,
        at index: String.Index
    ) -> (term: String, end: String.Index)? {
        var best: (term: String, end: String.Index)?

        for entry in entries {
            for variant in entry.heardAs {
                guard
                    let found = text.range(
                        of: variant,
                        options: [.caseInsensitive, .anchored],
                        range: index..<text.endIndex
                    ), Self.isWholeWord(found, in: text)
                else { continue }

                if let current = best, found.upperBound <= current.end { continue }
                best = (entry.term, found.upperBound)
            }
        }

        return best
    }

    /// Matching anywhere would turn "branches" into "PRes", and terms may hold
    /// spaces, which rules out splitting the text on whitespace.
    private static func isWholeWord(_ range: Range<String.Index>, in text: String) -> Bool {
        let before = range.lowerBound == text.startIndex
        let after = range.upperBound == text.endIndex
        return (before || !text[text.index(before: range.lowerBound)].isLetter)
            && (after || !text[range.upperBound].isLetter)
    }
}
