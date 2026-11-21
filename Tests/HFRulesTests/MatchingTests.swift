import Foundation
import GRDB
import Testing
import HFCore
@testable import HFRules

@Suite struct MatchingTests {
    let f = try! Fixture()

    @Test func counterpartyAndAmountIsHoog() throws {
        try f.db.write { d in
            let r = try f.rule(d, Rule(name: "Energie", counterpartyContains: "stroomhuis", amount: Money(euros: -150),
                                       targetItemLabel: "Energie", entryLabel: "Energie maand"))
            let t = try f.tx(d, name: "STROOMHUIS B.V.", cents: -15000)
            let s = try RuleEngine.suggest(for: t, d)
            #expect(s.confidence == .hoog)
            #expect(s.ruleId == r.id)
            #expect(s.budgetItemId == f.energieId)
            #expect(s.label == "Energie maand")
            #expect(s.reason == "Regel 'Energie': tegenpartij en bedrag")
            #expect(!s.amountDiffers && s.expectedAmount == nil && s.warnings.isEmpty)
            #expect(s.bankTransactionId == t.id)
        }
    }

    @Test func ibanAndAmountIsHoogIgnoringSpacesAndCase() throws {
        try f.db.write { d in
            try f.rule(d, Rule(name: "Sport", counterpartyIban: "nl00 test 0000 0000 77", amount: Money(euros: -30),
                               targetItemLabel: "sportclub"))
            let t = try f.tx(d, name: "Sportvereniging Voorbeeld", iban: "NL00TEST0000000077", cents: -3000)
            let s = try RuleEngine.suggest(for: t, d)
            #expect(s.confidence == .hoog)
            #expect(s.budgetItemId == f.sportId)   // label hoofdletterongevoelig
            #expect(s.label == "Sportvereniging Voorbeeld")
        }
    }

    /// 6j: een pinnaam met plaats en datum na ">" matcht op de ruwe tekst; het voorstel is de nette naam.
    @Test func pinNameWithPlaceAndDateStillMatches() throws {
        try f.db.write { d in
            try f.rule(d, Rule(name: "Winkel", counterpartyContains: "Winkel Voorbeeld", targetItemLabel: "Energie"))
            let t = try f.tx(d, name: "857 WINKEL VOORBEELD S>DORPSTAD13.11.2027", cents: -1250, code: "BA")
            let s = try RuleEngine.suggest(for: t, d)
            #expect(s.confidence == .midden)
            #expect(s.budgetItemId == f.energieId)
            #expect(s.label == "Winkel Voorbeeld")
        }
    }

    @Test func counterpartyWithoutAmountIsMidden() throws {
        try f.db.write { d in
            try f.rule(d, Rule(name: "Bakker", counterpartyContains: "Korenaar", tagIds: "3,5", reimburse: true))
            let t = try f.tx(d, name: "Bakkerij de  Korenaar", cents: -450)
            let s = try RuleEngine.suggest(for: t, d)
            #expect(s.confidence == .midden)
            #expect(s.budgetItemId == nil && s.targetItemLabel == nil)
            #expect(s.tagIds == [3, 5])
            #expect(s.reimburse)
            #expect(s.reason == "Regel 'Bakker': tegenpartij")
        }
    }

    @Test func amountDiffersIsMiddenWithExpectedAmount() throws {
        try f.db.write { d in
            let r = try f.rule(d, Rule(name: "Energie", counterpartyContains: "Stroomhuis", amount: Money(euros: -150),
                                       targetItemLabel: "Energie"))
            let t = try f.tx(d, name: "Stroomhuis", cents: -16250)
            let s = try RuleEngine.suggest(for: t, d)
            #expect(s.confidence == .midden)
            #expect(s.ruleId == r.id)
            #expect(s.amountDiffers)
            #expect(s.expectedAmount == Money(euros: -150))
            #expect(s.budgetItemId == f.energieId)
            #expect(s.reason == "Regel 'Energie': tegenpartij klopt, bedrag wijkt af (verwacht -€ 150,00)")
        }
    }

    @Test func keywordIsMiddenAlsoWithAmount() throws {
        try f.db.write { d in
            try f.rule(d, Rule(name: "Zwemles", descriptionContains: "zwemles"))
            try f.rule(d, Rule(name: "Contributie", descriptionContains: "contributie", amount: Money(euros: -25)))
            let a = try f.tx(d, name: "Onbekende partij", description: "Factuur ZWEMLES maart")
            #expect(try RuleEngine.suggest(for: a, d).confidence == .midden)
            #expect(try RuleEngine.suggest(for: a, d).reason == "Regel 'Zwemles': trefwoord in omschrijving")
            let b = try f.tx(d, description: "Contributie 2027", cents: -2500)
            #expect(try RuleEngine.suggest(for: b, d).confidence == .midden)
            // Trefwoord met een ander bedrag: geen match (alleen bij een tegenpartij geldt "bedrag wijkt af").
            let c = try f.tx(d, description: "Contributie 2027", cents: -2600)
            #expect(try RuleEngine.suggest(for: c, d).confidence == .geen)
        }
    }

    @Test func amountOnlyIsLaag() throws {
        try f.db.write { d in
            try f.rule(d, Rule(name: "Zakgeld", amount: Money(euros: -12)))
            let t = try f.tx(d, name: "Iemand", cents: -1200)
            let s = try RuleEngine.suggest(for: t, d)
            #expect(s.confidence == .laag)
            #expect(s.reason == "Regel 'Zakgeld': alleen bedrag")
        }
    }

    @Test func noRuleIsGeenWithCleanLabel() throws {
        try f.db.write { d in
            let t = try f.tx(d, name: "FIETSENMAKER VOORBEELD VOF")
            let s = try RuleEngine.suggest(for: t, d)
            #expect(s.confidence == .geen)
            #expect(s.ruleId == nil)
            #expect(s.label == "Fietsenmaker Voorbeeld")
            #expect(s.reason == "Geen regel gevonden")
            let empty = try f.tx(d)
            #expect(try RuleEngine.suggest(for: empty, d).label == "Onbekend")
        }
    }

    @Test func disabledEmptyAndOtherAccountRulesNeverMatch() throws {
        try f.db.write { d in
            try f.rule(d, Rule(name: "Uit", enabled: false, counterpartyContains: "Winkel"))
            try f.rule(d, Rule(name: "Leeg"))
            try f.rule(d, Rule(name: "Spaties", counterpartyContains: "   ", descriptionContains: ""))
            try f.rule(d, Rule(name: "Alleen rekening", accountId: f.accountId))
            try f.rule(d, Rule(name: "Andere rekening", accountId: f.savingsId, counterpartyContains: "Winkel"))
            let t = try f.tx(d, name: "Winkel Voorbeeld")
            #expect(try RuleEngine.suggest(for: t, d).confidence == .geen)
        }
    }

    @Test func allFilledConditionsMustHold() throws {
        try f.db.write { d in
            try f.rule(d, Rule(name: "Streng", counterpartyContains: "Verzekeraar", descriptionContains: "polis 123"))
            let no = try f.tx(d, name: "Verzekeraar Voorbeeld", description: "Polis 999")
            #expect(try RuleEngine.suggest(for: no, d).confidence == .geen)
            let yes = try f.tx(d, name: "Verzekeraar Voorbeeld", description: "Premie  POLIS 123")
            #expect(try RuleEngine.suggest(for: yes, d).confidence == .midden)
        }
    }

    @Test func textIsDiacriticAndCaseInsensitive() throws {
        try f.db.write { d in
            try f.rule(d, Rule(name: "Cafe", counterpartyContains: "cafe de brug"))
            let t = try f.tx(d, name: "CAFÉ   De Brug")
            #expect(try RuleEngine.suggest(for: t, d).confidence == .midden)
        }
    }

    // MARK: Volgorde

    @Test func higherConfidenceBeatsPriority() throws {
        try f.db.write { d in
            try f.rule(d, Rule(name: "Algemeen", priority: 1, counterpartyContains: "Stroomhuis"))
            let exact = try f.rule(d, Rule(name: "Exact", priority: 500, counterpartyContains: "Stroomhuis", amount: Money(euros: -150)))
            let t = try f.tx(d, name: "Stroomhuis", cents: -15000)
            #expect(try RuleEngine.suggest(for: t, d).ruleId == exact.id)
        }
    }

    @Test func lowestPriorityWinsWithinConfidence() throws {
        try f.db.write { d in
            try f.rule(d, Rule(name: "Specifiek", priority: 50, counterpartyContains: "Winkel", descriptionContains: "bon"))
            let first = try f.rule(d, Rule(name: "Eerst", priority: 10, counterpartyContains: "Winkel"))
            let t = try f.tx(d, name: "Winkel Voorbeeld", description: "Bon 12")
            #expect(try RuleEngine.suggest(for: t, d).ruleId == first.id)
        }
    }

    @Test func mostSpecificWinsOnEqualPriority() throws {
        try f.db.write { d in
            try f.rule(d, Rule(name: "Breed", counterpartyContains: "Winkel"))
            let specific = try f.rule(d, Rule(name: "Smal", counterpartyContains: "Winkel", descriptionContains: "bon"))
            let scoped = try f.rule(d, Rule(name: "Rekening", accountId: f.accountId, counterpartyContains: "Markt"))
            try f.rule(d, Rule(name: "Markt", counterpartyContains: "Markt"))
            let t = try f.tx(d, name: "Winkel Voorbeeld", description: "Bon 12")
            #expect(try RuleEngine.suggest(for: t, d).ruleId == specific.id)
            let m = try f.tx(d, name: "Markt Voorbeeld")
            #expect(try RuleEngine.suggest(for: m, d).ruleId == scoped.id)
        }
    }

    @Test func lowestIdWinsOnFullTie() throws {
        try f.db.write { d in
            let a = try f.rule(d, Rule(name: "A", counterpartyContains: "Winkel"))
            try f.rule(d, Rule(name: "B", counterpartyContains: "Voorbeeld"))
            let t = try f.tx(d, name: "Winkel Voorbeeld")
            #expect(try RuleEngine.suggest(for: t, d).ruleId == a.id)
        }
    }

    @Test func fullMatchBeatsAmountDiffersOnEqualPriority() throws {
        try f.db.write { d in
            try f.rule(d, Rule(name: "Met bedrag", counterpartyContains: "Stroomhuis", amount: Money(euros: -150)))
            let plain = try f.rule(d, Rule(name: "Zonder bedrag", counterpartyContains: "Stroomhuis"))
            let t = try f.tx(d, name: "Stroomhuis", cents: -9900)
            let s = try RuleEngine.suggest(for: t, d)
            #expect(s.ruleId == plain.id)
            #expect(!s.amountDiffers)
        }
    }

    // MARK: Jaar en post

    @Test func missingYearGivesWarning() throws {
        try f.db.write { d in
            try f.rule(d, Rule(name: "Energie", counterpartyContains: "Stroomhuis", targetItemLabel: "Energie"))
            let t = try f.tx(d, name: "Stroomhuis", day: "2028-01-04")
            let s = try RuleEngine.suggest(for: t, d)
            #expect(s.confidence == .midden)
            #expect(s.budgetItemId == nil)
            #expect(s.targetItemLabel == "Energie")
            #expect(s.warnings == ["Het jaar 2028 bestaat nog niet; de post 'Energie' kan niet gekoppeld worden."])
        }
    }

    @Test func missingLabelGivesWarning() throws {
        try f.db.write { d in
            try f.rule(d, Rule(name: "Oud", counterpartyContains: "Stroomhuis", targetItemLabel: "Gas en licht"))
            let t = try f.tx(d, name: "Stroomhuis")
            let s = try RuleEngine.suggest(for: t, d)
            #expect(s.budgetItemId == nil)
            #expect(s.warnings == ["De post 'Gas en licht' bestaat niet in 2027."])
        }
    }

    @Test func itemIsResolvedInTheYearOfTheTransaction() throws {
        try f.db.write { d in
            var y = BudgetYear(year: 2028)
            try y.insert(d)
            var item = BudgetItem(yearId: y.id!, label: "Energie", direction: .UIT, planAmount: Money(euros: -160))
            try item.insert(d)
            try f.rule(d, Rule(name: "Energie", counterpartyContains: "Stroomhuis", targetItemLabel: "Energie"))
            let t27 = try f.tx(d, name: "Stroomhuis", day: "2027-12-31")
            let t28 = try f.tx(d, name: "Stroomhuis", day: "2028-01-01")
            #expect(try RuleEngine.suggest(for: t27, d).budgetItemId == f.energieId)
            #expect(try RuleEngine.suggest(for: t28, d).budgetItemId == item.id)
        }
    }

    @Test func potTargetIsPassedOn() throws {
        try f.db.write { d in
            try f.rule(d, Rule(name: "Vakantie", accountId: f.savingsId, descriptionContains: "vakantie", targetPotId: f.potId))
            let t = try f.tx(d, description: "Storting vakantie", cents: 5000, account: f.savingsId)
            let s = try RuleEngine.suggest(for: t, d)
            #expect(s.potId == f.potId)
            #expect(s.warnings.isEmpty)
        }
    }

    // MARK: suggestAll, gebruik, beheer

    @Test func suggestAllCoversOnlyNewTransactions() throws {
        try f.db.write { d in
            try f.rule(d, Rule(name: "Bakker", counterpartyContains: "Korenaar"))
            let a = try f.tx(d, name: "Bakkerij de Korenaar")
            let b = try f.tx(d, name: "Onbekend Iets")
            let done = try f.tx(d, name: "Bakkerij de Korenaar", status: .verwerkt)
            let skipped = try f.tx(d, name: "Bakkerij de Korenaar", status: .overgeslagen)
            let other = try f.tx(d, name: "Bakkerij de Korenaar", account: f.savingsId)
            let all = try RuleEngine.suggestAll(d)
            #expect(Set(all.keys) == [a.id!, b.id!, other.id!])
            #expect(all[a.id!]?.confidence == .midden)
            #expect(all[b.id!]?.confidence == .geen)
            #expect(all[done.id!] == nil && all[skipped.id!] == nil)
            let one = try RuleEngine.suggestAll(d, accountId: f.savingsId)
            #expect(Array(one.keys) == [other.id!])
        }
    }

    @Test func recordUseCountsAndStamps() throws {
        try f.db.write { d in
            let r = try f.rule(d, Rule(name: "Bakker", counterpartyContains: "Korenaar"))
            let when = Date(timeIntervalSince1970: 1_800_000_000)
            try RuleEngine.recordUse(ruleId: r.id!, d, at: when)
            try RuleEngine.recordUse(ruleId: r.id!, d, at: when)
            let stored = try #require(try RuleEngine.rule(id: r.id!, d))
            #expect(stored.hitCount == 2)
            #expect(stored.lastUsed == when)
        }
    }

    @Test func saveValidatesAndNormalises() throws {
        try f.db.write { d in
            var empty = Rule(name: "Leeg", counterpartyContains: "  ")
            #expect(throws: RuleError.noConditions) { try RuleEngine.save(&empty, d) }
            var nameless = Rule(name: " ", amount: Money(euros: -1))
            #expect(throws: RuleError.emptyName) { try RuleEngine.save(&nameless, d) }
            #expect(RuleError.noConditions.errorDescription?.contains("voorwaarde") == true)

            var r = Rule(name: "  Sport  club ", counterpartyIban: "nl00 test 0000 0000 77", descriptionContains: " ")
            try RuleEngine.save(&r, d)
            #expect(r.id != nil)
            #expect(r.name == "Sport club")
            #expect(r.counterpartyIban == "NL00TEST0000000077")
            #expect(r.descriptionContains == nil)

            r.targetItemLabel = "Sportclub"
            try RuleEngine.save(&r, d)
            #expect(try RuleEngine.rules(d).count == 1)
            try RuleEngine.setEnabled(ruleId: r.id!, false, d)
            #expect(try RuleEngine.rule(id: r.id!, d)?.enabled == false)
            #expect(throws: RuleError.notFound(999)) { try RuleEngine.setEnabled(ruleId: 999, true, d) }
            #expect(try RuleEngine.delete(ruleId: r.id!, d))
            #expect(try !RuleEngine.delete(ruleId: r.id!, d))
        }
    }

    @Test func reorderRenumbersPriorities() throws {
        try f.db.write { d in
            let a = try f.rule(d, Rule(name: "A", priority: 5, amount: Money(cents: 1)))
            let b = try f.rule(d, Rule(name: "B", priority: 6, amount: Money(cents: 2)))
            let c = try f.rule(d, Rule(name: "C", priority: 7, amount: Money(cents: 3)))
            try RuleEngine.reorder(ruleIds: [c.id!, a.id!, c.id!, 999], d)
            let rules = try RuleEngine.rules(d)
            #expect(rules.map(\.name) == ["C", "A", "B"])
            #expect(rules.map(\.priority) == [10, 20, 30])
            _ = b
        }
    }

    @Test func testRuleShowsMatchesForUnsavedRule() throws {
        try f.db.write { d in
            let old = try f.tx(d, name: "Stroomhuis", cents: -15000, day: "2027-01-05", status: .verwerkt)
            let new = try f.tx(d, name: "STROOMHUIS BV", cents: -16000, day: "2027-02-05")
            try f.tx(d, name: "Iets Anders", cents: -15000)
            let draft = Rule(name: "Concept", enabled: false, counterpartyContains: "stroomhuis", amount: Money(euros: -150))
            let hits = try RuleEngine.testRule(draft, against: d)
            #expect(hits.map(\.transaction.id) == [new.id, old.id])
            #expect(hits[0].amountDiffers && hits[0].confidence == .midden)
            #expect(!hits[1].amountDiffers && hits[1].confidence == .hoog)
            #expect(try RuleEngine.testRule(draft, against: d, limit: 1).count == 1)
            #expect(try RuleEngine.testRule(Rule(name: "Leeg"), against: d).isEmpty)
        }
    }
}
