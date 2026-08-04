import Foundation

/// Which language to transcribe in, out of the models the machine actually
/// holds.
///
/// A tag outside that set is refused per segment rather than degraded, so a
/// guess costs the whole meeting. Any dialect of the same language beats
/// refusing: a machine holding pt-BR transcribes a pt-PT speaker well enough to
/// read, and holding nothing at all is a different problem with a different
/// answer.
///
/// The dialect is not arbitrary, because the exact tag misses more often than it
/// looks. Measured on the machine this was written on: an English Mac in Brazil
/// reports en-BR, which no model is published for, and picking the first of the
/// nine installed English dialects would have transcribed every meeting with
/// en-AU while en-US sat beside it.
public struct ChooseLanguage: Sendable {
    /// Named with both sides, because "unsupported language" on its own leaves
    /// the user nothing to act on, and this is what a machine that has never
    /// downloaded a model meets on its first meeting.
    public struct NoModelInstalled: Error, Equatable, CustomStringConvertible {
        public let wanted: String
        public let installed: [String]

        public var description: String {
            installed.isEmpty
                ? "No speech model is installed, so \(wanted) cannot be transcribed."
                : "No speech model for \(wanted). Installed: \(installed.joined(separator: ", "))."
        }
    }

    private let installed: [String]

    /// Sorted here rather than where a dialect is picked: a set has no order, so
    /// a machine holding several dialects of one language would otherwise
    /// transcribe the same meeting differently from one run to the next.
    public init(installed: Set<String>) {
        self.installed = installed.sorted()
    }

    public func callAsFunction(preferring wanted: String) throws -> String {
        if installed.contains(wanted) { return wanted }

        let spoken = Self.spoken(wanted)
        if let likely = Self.likely(spoken), installed.contains(likely) { return likely }

        guard let dialect = installed.first(where: { Self.spoken($0) == spoken }) else {
            throw NoModelInstalled(wanted: wanted, installed: installed)
        }
        return dialect
    }

    /// The language a tag is in, dropping the region. Taken as a prefix rather
    /// than by splitting, which needs a fallback for a tag with no separator
    /// that nothing can reach.
    private static func spoken(_ tag: String) -> Substring {
        tag.prefix { $0 != "-" }
    }

    /// Where a language is spoken when nothing else says: Unicode's own answer,
    /// which is en-US for English and pt-BR for Portuguese. Nil for a code the
    /// system does not know, which is not something to invent a region for.
    private static func likely(_ spoken: Substring) -> String? {
        let maximal = Locale.Language(identifier: String(spoken)).maximalIdentifier
        return Locale.Language(identifier: maximal).region.map { "\(spoken)-\($0.identifier)" }
    }
}
