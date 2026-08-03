import Testing

@testable import ListtenCore

@Test("a spelled-out number becomes digits")
func spelledNumberBecomesDigits() {
    #expect(Normalization.normalizing("we need seven licences") == "we need 7 licences")
    #expect(Normalization.normalizing("zero regressions") == "0 regressions")
    #expect(Normalization.normalizing("seventeen open issues") == "17 open issues")
}

@Test("a tens-and-unit compound is one number, spaced or hyphenated")
func compoundIsOneNumber() {
    #expect(Normalization.normalizing("twenty five minutes") == "25 minutes")
    #expect(Normalization.normalizing("twenty-five minutes") == "25 minutes")
    #expect(Normalization.normalizing("ninety nine problems") == "99 problems")
    #expect(Normalization.normalizing("forty on its own") == "40 on its own")
}

@Test("a number already written as digits is left alone")
func digitsAreLeftAlone() {
    #expect(Normalization.normalizing("we need 7 licences") == "we need 7 licences")
    #expect(Normalization.normalizing("25 minutes") == "25 minutes")
}

@Test("a number word inside a longer word is not a number")
func numberInsideALongerWordIsLeftAlone() {
    #expect(Normalization.normalizing("we often listen to someone") == "we often listen to someone")
    #expect(Normalization.normalizing("nineteenth") == "nineteenth")
}

@Test("a capitalized number word is left alone, since it is likely a name")
func capitalizedNumberIsLeftAlone() {
    #expect(Normalization.normalizing("we met at Seven Eleven") == "we met at Seven Eleven")
    #expect(Normalization.normalizing("ask Six about it") == "ask Six about it")
}

@Test("two adjacent number words that are not a compound stay words")
func adjacentNumbersStayWords() {
    #expect(Normalization.normalizing("the call is at ten thirty") == "the call is at ten thirty")
    #expect(Normalization.normalizing("at three thirty pm") == "at three thirty pm")
    #expect(Normalization.normalizing("one two three") == "one two three")
}

@Test("numbers separated by punctuation are separate numbers")
func punctuationSeparatesNumbers() {
    #expect(Normalization.normalizing("ten, thirty, forty") == "10, 30, 40")
}

@Test("a meridiem right after a number is written in full")
func meridiemAfterANumberIsWritten() {
    #expect(Normalization.normalizing("at 3 pm") == "at 3 PM")
    #expect(Normalization.normalizing("at 3 p.m.") == "at 3 PM")
    #expect(Normalization.normalizing("at three pm") == "at 3 PM")
    #expect(Normalization.normalizing("at eleven a.m. sharp") == "at 11 AM sharp")
    #expect(Normalization.normalizing("at 3pm") == "at 3 PM")
    #expect(Normalization.normalizing("at 3 PM") == "at 3 PM")
}

@Test("a meridiem that is not after a number is left alone")
func meridiemNeedsANumberBeforeIt() {
    #expect(Normalization.normalizing("I am ready") == "I am ready")
    #expect(Normalization.normalizing("am I late") == "am I late")
    #expect(Normalization.normalizing("I am seven") == "I am 7")
}

@Test("a meridiem inside a longer word is left alone")
func meridiemInsideALongerWordIsLeftAlone() {
    #expect(Normalization.normalizing("5 ambulances") == "5 ambulances")
    #expect(Normalization.normalizing("7 pmi certificates") == "7 pmi certificates")
}

@Test("text in a language the rules were not written for is untouched")
func foreignTextIsUntouched() {
    let portuguese = "a reunião é às três e meia, com sete pessoas 👨‍👩‍👧"

    #expect(Normalization.normalizing(portuguese) == portuguese)
}

@Test("normalizing what was already normalized changes nothing further")
func normalizationIsIdempotent() {
    let once = Normalization.normalizing("at three pm we ship twenty five builds")

    #expect(once == "at 3 PM we ship 25 builds")
    #expect(Normalization.normalizing(once) == once)
}

@Test("a line the recognizer left empty stays empty")
func emptyTextStaysEmpty() {
    #expect(Normalization.normalizing("") == "")
}
