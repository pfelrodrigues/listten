import Foundation
import Testing

@testable import ListtenCore

private let glossary = Glossary(entries: [
    .init(term: "pull request", heardAs: ["pool request"])
])

private func line(_ text: String, speaker: String = "microphone") throws -> TranscriptLine {
    try TranscriptLine(speaker: speaker, start: 1.5, end: 2.5, text: text)
}

@Test("the corrected transcript applies the glossary and keeps the raw one")
func appliesTheGlossary() throws {
    let raw = Transcript(lines: [try line("open a pool request")])

    let correction = try CorrectedTranscript(raw: raw, glossary: glossary)

    #expect(correction.corrected.lines.map(\.text) == ["open a pull request"])
    #expect(correction.raw == raw)
}

@Test("the corrected transcript normalizes numbers and times")
func appliesNormalization() throws {
    let raw = Transcript(lines: [try line("we ship twenty five builds at three pm")])

    let correction = try CorrectedTranscript(raw: raw, glossary: Glossary(entries: []))

    #expect(correction.corrected.lines.map(\.text) == ["we ship 25 builds at 3 PM"])
    #expect(correction.raw.lines.map(\.text) == ["we ship twenty five builds at three pm"])
}

@Test("the glossary runs first, so a term fusing a letter and a digit survives")
func glossaryRunsFirst() throws {
    let numbered = Glossary(entries: [.init(term: "M4", heardAs: ["em four"])])
    let raw = Transcript(lines: [try line("the em four milestone")])

    let correction = try CorrectedTranscript(raw: raw, glossary: numbered)

    #expect(correction.corrected.lines.map(\.text) == ["the M4 milestone"])
}

@Test("normalization runs after the glossary, so it rewrites a term holding a number word")
func normalizationRewritesAGlossaryTerm() throws {
    let numbered = Glossary(entries: [.init(term: "zero trust", heardAs: ["hero trust"])])
    let raw = Transcript(lines: [try line("we use hero trust everywhere")])

    let correction = try CorrectedTranscript(raw: raw, glossary: numbered)

    #expect(correction.corrected.lines.map(\.text) == ["we use 0 trust everywhere"])
}

@Test("correction rewrites the words and nothing else about a line")
func keepsEverythingButTheWords() throws {
    let raw = Transcript(lines: [try line("open a pool request", speaker: "Ana")])

    let corrected = try CorrectedTranscript(raw: raw, glossary: glossary).corrected

    #expect(corrected.lines.count == 1)
    #expect(corrected.lines[0].speaker == "Ana")
    #expect(corrected.lines[0].start == 1.5)
    #expect(corrected.lines[0].end == 2.5)
}

@Test("a transcript with nothing to correct still carries both")
func carriesBothWhenNothingChanges() throws {
    let raw = Transcript(lines: [try line("ship it")])

    let correction = try CorrectedTranscript(raw: raw, glossary: glossary)

    #expect(correction.raw == raw)
    #expect(correction.corrected == raw)
}

@Test("what is stored holds the raw transcript beside the corrected one")
func storesBothTranscripts() throws {
    let raw = Transcript(lines: [try line("open a pool request")])
    let correction = try CorrectedTranscript(raw: raw, glossary: glossary)

    let stored = try JSONEncoder().encode(correction)

    #expect(try JSONDecoder().decode(CorrectedTranscript.self, from: stored) == correction)
    #expect(String(decoding: stored, as: UTF8.self).contains("pool request"))
}

@Test("a stored correction that lost its raw transcript does not decode")
func refusesToDecodeWithoutTheRawTranscript() throws {
    let withoutRaw = #"{"corrected":{"lines":[]}}"#

    #expect(throws: (any Error).self) {
        try JSONDecoder().decode(CorrectedTranscript.self, from: Data(withoutRaw.utf8))
    }
}
