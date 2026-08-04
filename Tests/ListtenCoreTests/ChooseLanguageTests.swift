import Foundation
import Testing

@testable import ListtenCore

/// Both installed tags are the same language, so only an exact match answers
/// pt-PT: falling through to the dialect rule would answer pt-BR and this would
/// hold for the wrong reason.
@Test("the language asked for is used when its model is installed")
func theInstalledLanguageIsUsed() throws {
    let choose = ChooseLanguage(installed: ["pt-BR", "pt-PT"])

    #expect(try choose(preferring: "pt-PT") == "pt-PT")
}

/// Refusing here would cost the whole meeting over a region code, when the model
/// on the machine transcribes the same language.
@Test("a dialect of the same language is used where the exact one is not there")
func aDialectStandsInForTheExactTag() throws {
    let choose = ChooseLanguage(installed: ["en-US", "pt-PT"])

    #expect(try choose(preferring: "pt-AO") == "pt-PT")
}

/// The measured case. This machine reports en-BR, which no model is published
/// for, with nine English dialects installed beside it: taking whichever sorted
/// first would have transcribed every meeting in en-AU.
@Test("the region a language is usually spoken in beats whichever dialect sorts first")
func theLikelyRegionBeatsTheFirstDialect() throws {
    let choose = ChooseLanguage(installed: ["en-AU", "en-GB", "en-US", "pt-BR"])

    #expect(try choose(preferring: "en-BR") == "en-US")
}

/// A set has no order, so the answer has to come from somewhere that does.
/// Reading it off the set would transcribe the same meeting in a different
/// dialect from one run to the next, and nothing would say why.
@Test("where several dialects are installed, the choice is alphabetical rather than incidental")
func theDialectChosenDoesNotDependOnTheSet() throws {
    let choose = ChooseLanguage(installed: ["pt-PT", "pt-AO", "pt-MZ"])

    #expect(try choose(preferring: "pt-XX") == "pt-AO")
}

@Test("a language with no model at all is refused, and the refusal says what is there")
func anUninstalledLanguageIsRefused() {
    let choose = ChooseLanguage(installed: ["en-US", "de-DE"])

    #expect(
        throws: ChooseLanguage.NoModelInstalled(wanted: "ja-JP", installed: ["de-DE", "en-US"])
    ) {
        try choose(preferring: "ja-JP")
    }
}

/// The two refusals read differently on purpose: one is a language to download,
/// the other is a machine that has never downloaded any, and the second is what
/// a first run meets.
@Test(
    "a refusal names what to do about it",
    arguments: [
        (Set<String>(), "No speech model is installed, so ja-JP cannot be transcribed."),
        (Set(["en-US", "de-DE"]), "No speech model for ja-JP. Installed: de-DE, en-US."),
    ]
)
func aRefusalNamesWhatToDoAboutIt(installed: Set<String>, said: String) {
    let choose = ChooseLanguage(installed: installed)

    do {
        let chosen = try choose(preferring: "ja-JP")
        Issue.record("expected a refusal, got \(chosen)")
    } catch let refusal as ChooseLanguage.NoModelInstalled {
        #expect(String(describing: refusal) == said)
    } catch {
        Issue.record("expected a refusal that names the models, got \(error)")
    }
}
