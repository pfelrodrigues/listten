import Testing

@testable import ListtenCore

@Test("a known mishearing is replaced by the intended term")
func replacesKnownMishearing() {
    let glossary = Glossary(entries: [.init(term: "pull request", heardAs: ["pool request"])])

    #expect(glossary.correcting("open a pool request") == "open a pull request")
}

@Test("text with no known mishearing is returned untouched")
func leavesUnknownTextAlone() {
    let glossary = Glossary(entries: [.init(term: "pull request", heardAs: ["pool request"])])

    #expect(glossary.correcting("ship it") == "ship it")
}

@Test("an empty glossary corrects nothing")
func emptyGlossaryIsIdentity() {
    #expect(Glossary(entries: []).correcting("anything") == "anything")
}

@Test("a term inside a longer word is left alone")
func doesNotCorrectSubstrings() {
    let glossary = Glossary(entries: [.init(term: "PR", heardAs: ["branch"])])

    #expect(glossary.correcting("the branches are ready") == "the branches are ready")
}

@Test("a multi-word term is still corrected")
func correctsMultiWordTerms() {
    let glossary = Glossary(entries: [.init(term: "pull request", heardAs: ["pool request"])])

    #expect(glossary.correcting("open a pool request now") == "open a pull request now")
}

@Test("correction is case-insensitive but keeps the intended casing")
func correctionIsCaseInsensitive() {
    let glossary = Glossary(entries: [.init(term: "Delphi", heardAs: ["delphy"])])

    #expect(glossary.correcting("the DELPHY code") == "the Delphi code")
}

@Test("a term at the very start or end of the text is corrected")
func correctsAtTextBoundaries() {
    let glossary = Glossary(entries: [.init(term: "PR", heardAs: ["pee arr"])])

    #expect(glossary.correcting("pee arr") == "PR")
    #expect(glossary.correcting("open pee arr") == "open PR")
    #expect(glossary.correcting("pee arr merged") == "PR merged")
}

@Test("a term next to punctuation is still a whole word")
func correctsNextToPunctuation() {
    let glossary = Glossary(entries: [.init(term: "Delphi", heardAs: ["delphy"])])

    #expect(glossary.correcting("in delphy, yes") == "in Delphi, yes")
}

@Test("a term one entry produced is not rewritten by another, in either order")
func doesNotCorrectWhatItJustCorrected() {
    let entries: [Glossary.Entry] = [
        .init(term: "pull request", heardAs: ["pool request"]),
        .init(term: "PR", heardAs: ["pull request"]),
    ]

    #expect(Glossary(entries: entries).correcting("open a pool request") == "open a pull request")
    #expect(
        Glossary(entries: entries.reversed()).correcting("open a pool request")
            == "open a pull request"
    )
}

@Test("the longest variant matching at a position wins, in either order")
func longestVariantWins() {
    let entries: [Glossary.Entry] = [
        .init(term: "PR", heardAs: ["pee arr"]),
        .init(term: "pull request", heardAs: ["pee arr request"]),
    ]

    #expect(
        Glossary(entries: entries).correcting("open a pee arr request") == "open a pull request"
    )
    #expect(
        Glossary(entries: entries.reversed()).correcting("open a pee arr request")
            == "open a pull request"
    )
}

@Test("two variants covering the same stretch go to the first declared entry")
func sameLengthVariantsGoToFirstDeclared() {
    let entries: [Glossary.Entry] = [
        .init(term: "PR", heardAs: ["pee arr"]),
        .init(term: "public relations", heardAs: ["pee arr"]),
    ]

    #expect(Glossary(entries: entries).correcting("pee arr") == "PR")
    #expect(Glossary(entries: entries.reversed()).correcting("pee arr") == "public relations")
}

@Test("text the pass walks over character by character survives multi-byte characters")
func keepsMultiByteCharactersIntact() {
    let glossary = Glossary(entries: [.init(term: "Delphi", heardAs: ["delphy"])])

    #expect(glossary.correcting("café 👨‍👩‍👧 delphy é") == "café 👨‍👩‍👧 Delphi é")
}
