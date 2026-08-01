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
