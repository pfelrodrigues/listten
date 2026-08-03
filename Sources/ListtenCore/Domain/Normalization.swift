import Foundation

/// Spelled-out numbers and meridiems written the way a reader expects them.
///
/// Deliberately conservative, since a recognizer's output is all there is to go
/// on: only lowercase English number words are touched, because casing is the
/// only signal that separates a quantity from a name, and a normalization
/// missed costs less than a name corrupted. Text in a language these rules were
/// not written for matches nothing and comes back untouched.
public enum Normalization {
    /// Numbers first: a meridiem is only recognised beside a digit, so the hour
    /// has to have become one before the marker is looked at.
    public static func normalizing(_ text: String) -> String {
        markingMeridiems(normalizingNumbers(text))
    }

    private static let values: [String: Int] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
        "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11,
        "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15,
        "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19,
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60,
        "seventy": 70, "eighty": 80, "ninety": 90,
    ]

    private static let tens: Set<String> = [
        "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty",
        "ninety",
    ]

    /// A word is a run of letters and digits, so what separates words comes back
    /// exactly as it was and a number word inside a longer one is never seen.
    private enum Piece {
        case word(String)
        case gap(String)

        var text: String {
            switch self {
            case .word(let text), .gap(let text): return text
            }
        }
    }

    private static func pieces(of text: String) -> [Piece] {
        var pieces: [Piece] = []
        var current = ""
        var currentIsWord = false

        for character in text {
            let isWord = character.isLetter || character.isNumber
            if !current.isEmpty, isWord != currentIsWord {
                pieces.append(currentIsWord ? .word(current) : .gap(current))
                current = ""
            }
            currentIsWord = isWord
            current.append(character)
        }
        if !current.isEmpty {
            pieces.append(currentIsWord ? .word(current) : .gap(current))
        }
        return pieces
    }

    private static func normalizingNumbers(_ text: String) -> String {
        let pieces = pieces(of: text)
        var result = ""
        var index = 0

        while index < pieces.count {
            let run = numberRun(in: pieces, from: index)
            guard !run.isEmpty else {
                result += pieces[index].text
                index += 1
                continue
            }
            let spanned = index..<(index + run.count * 2 - 1)
            result += digits(for: run) ?? pieces[spanned].map(\.text).joined()
            index = spanned.upperBound
        }

        return result
    }

    /// The number words from `index` onwards, joined by a single space or a
    /// hyphen. Adjacency is what tells a compound from two numbers a comma apart.
    private static func numberRun(in pieces: [Piece], from index: Int) -> [String] {
        var run: [String] = []
        var cursor = index

        while cursor < pieces.count, case .word(let word) = pieces[cursor], values[word] != nil {
            run.append(word)
            guard
                cursor + 2 < pieces.count, case .gap(let gap) = pieces[cursor + 1],
                gap == " " || gap == "-"
            else { break }
            cursor += 2
        }

        return run
    }

    /// A number on its own and a tens-and-unit compound become digits. A longer
    /// run stays as words: two numbers in a row are as often a spoken clock time
    /// as they are two numbers, and "10 30" reads worse than what was said.
    private static func digits(for run: [String]) -> String? {
        if run.count == 1, let value = values[run[0]] {
            return String(value)
        }
        if run.count == 2, tens.contains(run[0]), let ten = values[run[0]],
            let unit = values[run[1]], (1...9).contains(unit)
        {
            return String(ten + unit)
        }
        return nil
    }

    private static let meridiems: [(spoken: String, written: String)] = [
        ("a.m.", "AM"), ("p.m.", "PM"), ("am", "AM"), ("pm", "PM"),
    ]

    /// A marker only counts directly after a number: "am" is a verb far more
    /// often than it is a meridiem, and the digit beside it is the only thing
    /// that tells them apart.
    private static func markingMeridiems(_ text: String) -> String {
        var result = ""
        var index = text.startIndex

        while index < text.endIndex {
            if let match = meridiem(in: text, at: index) {
                let before = trimmingTrailingSpaces(result)
                if before.last?.isNumber == true {
                    result = before + " " + match.written
                    index = match.end
                    continue
                }
            }
            result.append(text[index])
            index = text.index(after: index)
        }

        return result
    }

    /// Anchored and bounded, so "5 ambulances" is not five in the morning.
    private static func meridiem(
        in text: String,
        at index: String.Index
    ) -> (written: String, end: String.Index)? {
        for form in meridiems {
            guard
                let found = text.range(
                    of: form.spoken,
                    options: [.caseInsensitive, .anchored],
                    range: index..<text.endIndex
                )
            else { continue }

            let after = found.upperBound
            guard after == text.endIndex || !(text[after].isLetter || text[after].isNumber) else {
                continue
            }
            return (form.written, after)
        }

        return nil
    }

    private static func trimmingTrailingSpaces(_ text: String) -> String {
        var trimmed = text
        while trimmed.last == " " { trimmed.removeLast() }
        return trimmed
    }
}
