import Testing
import GRDB
import HFCore
@testable import HFRules

/// 6b: voorgestelde omschrijving — de eigen tekst van een overboeking, anders de tegenpartij; een omschrijving
/// uit een regel gaat altijd voor. Alle voorbeelden zijn verzonnen.
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
        ("Bank Voorbeeld", "Opname", "GEA", "Bank Voorbeeld"),
        ("Sportclub Voorbeeld", "Contributie", "INC", "Sportclub Voorbeeld"),
        ("Sportclub Voorbeeld", "Lidmaatschap", "INC", "Sportclub Voorbeeld"),
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
        ("J. Voorbeeld", "J. Voorbeeld", "OVB", "J. Voorbeeld"),
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

    // MARK: Voorstel van de regels

    @Test func suggestionWithoutRuleUsesTheOwnText() throws {
        try f.db.write { d in
            let t = try f.tx(d, name: "J. Voorbeeld", iban: "NL00TEST0000000060", description: "Zakgeld", code: "OVB")
            #expect(try RuleEngine.suggest(for: t, d).label == "Zakgeld")
            let pin = try f.tx(d, name: "SUPERMARKT VOORBEELD", description: "Boodschappen", code: "BEA")
            #expect(try RuleEngine.suggest(for: pin, d).label == "Supermarkt Voorbeeld")
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
            try f.rule(d, Rule(name: "J. Voorbeeld", counterpartyIban: "NL00TEST0000000062"))
            let next = try f.tx(d, name: "J. Voorbeeld", iban: "NL00TEST0000000062", description: "Kleedgeld", code: "OVB")
            #expect(try RuleEngine.suggest(for: next, d).label == "Kleedgeld")
        }
    }

    // MARK: Onthoud als regel (6i)

    @Test func takingTheOwnTextDoesNotFixItInTheRule() throws {
        try f.db.write { d in
            let t = try f.tx(d, name: "J. Voorbeeld", iban: "NL00TEST0000000063", description: "Zakgeld", code: "OVB")
            // Nakijken geeft geen omschrijving mee als de gebruiker het voorstel ("Zakgeld") laat staan; ook als
            // hij het zelf intypt, wordt de eigen tekst niet vastgelegd.
            for label in [nil, "Zakgeld"] as [String?] {
                let p = try RuleEngine.ruleProposal(for: Correction(bankTransaction: t, entryLabel: label), d)
                let draft = try #require(p.draft)
                #expect(draft.entryLabel == nil)
                #expect(RuleEngine.summary(of: draft, potName: nil, tagNames: []).contains("omschrijving") == false)
            }
        }
    }

    @Test func choosingTheCounterpartyOnPurposeIsRemembered() throws {
        try f.db.write { d in
            let t = try f.tx(d, name: "J. Voorbeeld", iban: "NL00TEST0000000064", description: "Zakgeld", code: "OVB")
            let p = try RuleEngine.ruleProposal(for: Correction(bankTransaction: t, entryLabel: "J. Voorbeeld"), d)
            let draft = try #require(p.draft)
            #expect(draft.entryLabel == "J. Voorbeeld")
            #expect(try RuleEngine.summary(of: draft, d).contains("omschrijving 'J. Voorbeeld'"))
        }
    }

    @Test func counterpartyLabelOfAPaymentIsNotFixed() throws {
        try f.db.write { d in
            let t = try f.tx(d, name: "SUPERMARKT VOORBEELD", description: "Boodschappen", code: "BEA")
            let p = try RuleEngine.ruleProposal(for: Correction(bankTransaction: t, entryLabel: "Supermarkt Voorbeeld"), d)
            #expect(try #require(p.draft).entryLabel == nil)
        }
    }

    @Test func updatingARuleKeepsItsOwnLabelUnlessChanged() throws {
        try f.db.write { d in
            let opa = try f.rule(d, Rule(name: "Opa", counterpartyIban: "NL00TEST0000000065", entryLabel: "Gift van opa"))
            let t = try f.tx(d, name: "Opa Voorbeeld", iban: "NL00TEST0000000065", description: "Zakgeld", code: "OVB")

            // Alleen een andere post: de omschrijving van de regel blijft.
            let other = try RuleEngine.ruleProposal(for: Correction(bankTransaction: t, itemLabel: "Energie"), d)
            #expect(other.isUpdate && other.offersChoice)
            #expect(other.draft?.id == opa.id)
            #expect(other.draft?.entryLabel == "Gift van opa")

            // De eigen tekst gekozen in plaats van de omschrijving van de regel: de regel legt niets meer vast.
            let own = try RuleEngine.ruleProposal(for: Correction(bankTransaction: t, entryLabel: "Zakgeld"), d)
            #expect(own.offersChoice)
            #expect(own.draft?.entryLabel == nil)

            // Precies het voorstel: niets aan te bieden.
            let same = try RuleEngine.ruleProposal(for: Correction(bankTransaction: t, entryLabel: "Gift van opa"), d)
            #expect(!same.offersChoice)
        }
    }
}
