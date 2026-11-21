import Testing
import GRDB
import HFCore
@testable import HFRules

/// Voorgestelde omschrijving: de eigen tekst van een overboeking, anders de tegenpartij. Alle voorbeelden zijn verzonnen.
@Suite struct SuggestedLabelTests {
    let f = try! Fixture()

    @Test(arguments: [
        // Korte, eigen tekst bij een overboeking: die tekst.
        ("J. Voorbeeld", "Zakgeld", "OVB", "Zakgeld"),
        ("J. Voorbeeld", "zakgeld", "", "Zakgeld"),
        ("Familie Voorbeeld", "Cadeau verjaardag Kind A", "IOB", "Cadeau verjaardag Kind A"),
        ("Familie Voorbeeld", "Terug voor de pizza", "POV", "Terug voor de pizza"),
        ("Familie Voorbeeld", "Kleedgeld 2027", "OVB", "Kleedgeld 2027"),
    ])
    func ownTextOfATransfer(name: String, description: String, code: String, expected: String) {
        #expect(LabelCleaner.suggestedLabel(counterparty: name, description: description, transactionCode: code) == expected)
    }

    @Test(arguments: [
        // Pin, incasso, iDEAL: altijd de tegenpartij, ook met een korte tekst.
        ("SUPERMARKT VOORBEELD", "Boodschappen", "BEA", "Supermarkt Voorbeeld"),
        ("Sportclub Voorbeeld", "Contributie", "INC", "Sportclub Voorbeeld"),
        ("Webwinkel Voorbeeld", "Bestelling", "IDB", "Webwinkel Voorbeeld"),
        ("Winkel Voorbeeld", "Betaalautomaat Winkel Voorbeeld", "", "Winkel Voorbeeld"),
        // Gestructureerde teksten.
        ("Verzekeraar Voorbeeld", "/TRTP/SEPA Incasso/REMI/Premie", "", "Verzekeraar Voorbeeld"),
        ("Tandarts Voorbeeld", "Naam: Tandarts Voorbeeld", "", "Tandarts Voorbeeld"),
        ("Verhuurder Voorbeeld", "Kenmerk 1234567890", "OVB", "Verhuurder Voorbeeld"),
        ("Verhuurder Voorbeeld", "123456 789", "OVB", "Verhuurder Voorbeeld"),
        ("Stroomhuis BV", "Termijn maart", "OVB", "Stroomhuis"),
        ("Stroomhuis BV", "Factuur 2027 12", "OVB", "Stroomhuis"),
        ("Webwinkel Voorbeeld", "iDEAL Webwinkel", "", "Webwinkel Voorbeeld"),
        ("Webwinkel Voorbeeld", "zie www.voorbeeld.test", "", "Webwinkel Voorbeeld"),
        // Lange teksten.
        ("Familie Voorbeeld", "Terugbetaling van het weekendje weg met de hele groep", "OVB", "Familie Voorbeeld"),
        // Tekst gelijk aan (een deel van) de tegenpartij.
        ("STROOMHUIS BV", "Stroomhuis", "OVB", "Stroomhuis"),
        // Geen tekst.
        ("Familie Voorbeeld", "", "OVB", "Familie Voorbeeld"),
    ])
    func counterpartyOtherwise(name: String, description: String, code: String, expected: String) {
        #expect(LabelCleaner.suggestedLabel(counterparty: name, description: description, transactionCode: code) == expected)
    }

    @Test func withoutCounterpartyItIsTheOldBehaviour() {
        #expect(LabelCleaner.suggestedLabel(counterparty: "", description: "Bedankt voor het lenen", transactionCode: "OVB")
                == LabelCleaner.cleanLabel(counterparty: "", description: "Bedankt voor het lenen"))
        #expect(LabelCleaner.suggestedLabel(counterparty: "",
            description: "BEA, Betaalpas SLAGERIJ VOORBEELD,PAS123 NR:9Z8Y7X, 03.03.27/09:15 ZWOLLE") == "Slagerij Voorbeeld")
    }

    @Test func suggestionWithoutRuleUsesTheOwnText() throws {
        try f.db.write { d in
            let t = try f.tx(d, name: "J. Voorbeeld", iban: "NL00TEST0000000060", description: "Zakgeld", code: "OVB")
            #expect(try RuleEngine.suggest(for: t, d).label == "Zakgeld")
        }
    }

    @Test func labelChosenInARuleAlwaysWins() throws {
        try f.db.write { d in
            try f.rule(d, Rule(name: "Opa", counterpartyIban: "NL00TEST0000000061", entryLabel: "Gift van opa"))
            let t = try f.tx(d, name: "Opa Voorbeeld", iban: "NL00TEST0000000061", description: "Zakgeld", code: "OVB")
            #expect(try RuleEngine.suggest(for: t, d).label == "Gift van opa")
        }
    }

    @Test func ruleWithoutLabelGivesEachTransferItsOwnText() throws {
        try f.db.write { d in
            let first = try f.tx(d, name: "J. Voorbeeld", iban: "NL00TEST0000000062", description: "Zakgeld", code: "OVB")
            // De gebruiker neemt het voorstel over: de geleerde regel legt geen vaste omschrijving vast.
            let learned = try RuleEngine.learn(from: Correction(bankTransaction: first, entryLabel: "Zakgeld"), d)
            let rule = try #require(learned.rule)
            #expect(rule.entryLabel == nil)
            #expect(rule.counterpartyIban == "NL00TEST0000000062")

            // Matchen gaat nog steeds op de tegenpartij; de omschrijving volgt de nieuwe tekst.
            let next = try f.tx(d, name: "J. Voorbeeld", iban: "NL00TEST0000000062", description: "Kleedgeld",
                                day: "2027-04-05", code: "OVB")
            let s = try RuleEngine.suggest(for: next, d)
            #expect(s.ruleId == rule.id)
            #expect(s.label == "Kleedgeld")
        }
    }

    @Test func choosingTheCounterpartyOnPurposeIsRemembered() throws {
        try f.db.write { d in
            let t = try f.tx(d, name: "J. Voorbeeld", iban: "NL00TEST0000000063", description: "Zakgeld", code: "OVB")
            let learned = try RuleEngine.learn(from: Correction(bankTransaction: t, entryLabel: "J. Voorbeeld"), d)
            #expect(learned.rule?.entryLabel == "J. Voorbeeld")
        }
    }

    @Test func existingRuleWithoutLabelKeepsTheCounterpartyForPayments() throws {
        try f.db.write { d in
            try f.rule(d, Rule(name: "Supermarkt", counterpartyContains: "supermarkt voorbeeld"))
            let t = try f.tx(d, name: "SUPERMARKT VOORBEELD", description: "Boodschappen", code: "BEA")
            let s = try RuleEngine.suggest(for: t, d)
            #expect(s.ruleName == "Supermarkt")
            #expect(s.label == "Supermarkt Voorbeeld")
        }
    }
}
