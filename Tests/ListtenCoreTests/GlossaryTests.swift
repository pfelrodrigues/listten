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
