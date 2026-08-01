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
                partial.replacingOccurrences(
                    of: variant,
                    with: entry.term,
                    options: [.caseInsensitive]
                )
            }
        }
    }
}
