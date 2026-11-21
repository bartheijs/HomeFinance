import Foundation
import GRDB
import Testing
import HFCore
@testable import HFRules

@Suite struct LearningTests {
    let f = try! Fixture()

    @Test func createsLearnedRuleByIbanWithoutAmountOnFirstSighting() throws {
        try f.db.write { d in
            let t = try f.tx(d, name: "STROOMHUIS B.V.", iban: "NL00TEST0000000050", cents: -15000)
            let result = try RuleEngine.learn(from: Correction(bankTransaction: t, itemLabel: "Energie"), d)
            let rule = try #require(result.rule)
            #expect(result.outcome == .created)
            #expect(rule.id != nil)
            #expect(rule.origin == .geleerd)
            #expect(rule.name == "Stroomhuis")
            #expect(rule.counterpartyIban == "NL00TEST0000000050")
            #expect(rule.counterpartyContains == nil)
            #expect(rule.amount == nil)
            #expect(rule.targetItemLabel == "Energie")
            #expect(rule.entryLabel == nil)
            #expect(result.message == "Regel geleerd: 'Stroomhuis' → post 'Energie'")

            // De volgende transactie van deze tegenpartij krijgt nu een voorstel (midden).
            let next = try f.tx(d, name: "Stroomhuis", iban: "NL00 TEST 0000 0000 50", cents: -14000, day: "2027-04-05")
            let s = try RuleEngine.suggest(for: next, d)
            #expect(s.confidence == .midden)
            #expect(s.budgetItemId == f.energieId)
        }
    }

    @Test func createsByNameWhenNoIban() throws {
        try f.db.write { d in
            let t = try f.tx(d, name: "Bakkerij  de Korenaar")
            let result = try RuleEngine.learn(from: Correction(bankTransaction: t, entryLabel: "Brood", tagIds: [2], reimburse: true), d)
            let rule = try #require(result.rule)
            #expect(result.outcome == .created)
            #expect(rule.counterpartyContains == "Bakkerij de Korenaar")
            #expect(rule.counterpartyIban == nil)
            #expect(rule.entryLabel == "Brood")
            #expect(rule.tagIdList == [2])
            #expect(rule.reimburse)
            #expect(rule.amount == nil)
            #expect(rule.reimburseDirection == .outgoing)
            #expect(result.message == "Regel geleerd: 'Bakkerij de Korenaar' → overig, nog overboeken met spaar bij geld eruit")
        }
    }

    @Test func secondSightingAddsAmountForFixedItem() throws {
        try f.db.write { d in
            let first = try f.tx(d, name: "Stroomhuis", iban: "NL00TEST0000000050", cents: -15000, day: "2027-01-05")
            let created = try RuleEngine.learn(from: Correction(bankTransaction: first, itemLabel: "Energie"), d)
            #expect(created.rule?.amount == nil)

            let second = try f.tx(d, name: "Stroomhuis", iban: "NL00TEST0000000050", cents: -15000, day: "2027-02-05")
            #expect(try RuleEngine.suggest(for: second, d).confidence == .midden)
            // De gebruiker bevestigt hetzelfde: de regel krijgt nu het bedrag.
            let updated = try RuleEngine.learn(from: Correction(bankTransaction: second, itemLabel: "Energie"), d)
            #expect(updated.outcome == .updated)
            #expect(updated.rule?.id == created.rule?.id)
            #expect(updated.rule?.amount == Money(euros: -150))
            #expect(updated.previousRule?.amount == nil)
            #expect(updated.message == "Regel bijgewerkt: 'Stroomhuis' → post 'Energie' (bedrag -€ 150,00)")
            #expect(try RuleEngine.rules(d).count == 1)

            let third = try f.tx(d, name: "Stroomhuis", iban: "NL00TEST0000000050", cents: -15000, day: "2027-03-05")
            #expect(try RuleEngine.suggest(for: third, d).confidence == .hoog)
            // Nog een bevestiging verandert niets meer; alleen het gebruik wordt geteld.
            let again = try RuleEngine.learn(from: Correction(bankTransaction: third, itemLabel: "Energie"), d)
            #expect(again.outcome == .unchanged)
            #expect(again.usedRuleId == created.rule?.id)
            #expect(again.rule?.hitCount == 1)
        }
    }

    @Test func noAmountForDiversEvenWhenSeenTwice() throws {
        try f.db.write { d in
            try f.tx(d, name: "Bakkerij de Korenaar", cents: -450, day: "2027-01-05", status: .verwerkt)
            let t = try f.tx(d, name: "BAKKERIJ DE KORENAAR", cents: -450)
            let result = try RuleEngine.learn(from: Correction(bankTransaction: t, tagIds: [1]), d)
            #expect(result.outcome == .created)
            #expect(result.rule?.amount == nil)
        }
    }

    @Test func changedAmountDropsAmountCondition() throws {
        try f.db.write { d in
            let learned = try f.rule(d, Rule(name: "Stroomhuis", origin: .geleerd, counterpartyIban: "NL00TEST0000000050",
                                             amount: Money(euros: -150), targetItemLabel: "Energie"))
            let t = try f.tx(d, name: "Stroomhuis", iban: "NL00TEST0000000050", cents: -16500)
            #expect(try RuleEngine.suggest(for: t, d).amountDiffers)
            let result = try RuleEngine.learn(from: Correction(bankTransaction: t, itemLabel: "Energie"), d)
            #expect(result.outcome == .updated)
            #expect(result.rule?.id == learned.id)
            #expect(result.rule?.amount == nil)
        }
    }

    @Test func updatesExistingLearnedRuleAndCanUndo() throws {
        try f.db.write { d in
            let t = try f.tx(d, name: "Sportvereniging Voorbeeld", iban: "NL00TEST0000000077", cents: -3000)
            let created = try RuleEngine.learn(from: Correction(bankTransaction: t), d)
            #expect(created.rule?.targetItemLabel == nil)

            let updated = try RuleEngine.learn(from: Correction(bankTransaction: t, itemLabel: "Sportclub", tagIds: [4]), d)
            #expect(updated.outcome == .updated)
            #expect(updated.rule?.id == created.rule?.id)
            #expect(updated.rule?.targetItemLabel == "Sportclub")
            #expect(updated.rule?.tagIdList == [4])
            #expect(updated.previousRule == created.rule)
            #expect(try RuleEngine.rules(d).count == 1)

            try RuleEngine.undoLearning(updated, d)
            #expect(try RuleEngine.rules(d) == [created.rule!])
            try RuleEngine.undoLearning(created, d)
            #expect(try RuleEngine.rules(d).isEmpty)
        }
    }

    @Test func sameChoiceAsManualRuleOnlyRecordsUse() throws {
        try f.db.write { d in
            let manual = try f.rule(d, Rule(name: "Energie", counterpartyContains: "Stroomhuis", targetItemLabel: "Energie"))
            let t = try f.tx(d, name: "Stroomhuis", iban: "NL00TEST0000000050", cents: -15000)
            let result = try RuleEngine.learn(from: Correction(bankTransaction: t, itemLabel: "energie"), d)
            #expect(result.outcome == .unchanged)
            #expect(result.usedRuleId == manual.id)
            #expect(result.rule?.hitCount == 1)
            #expect(result.rule?.lastUsed != nil)
            #expect(try RuleEngine.rules(d).count == 1)
            #expect(result.message.contains("gelijk aan het voorstel"))
        }
    }

    @Test func neverOverwritesManualRule() throws {
        try f.db.write { d in
            let manual = try f.rule(d, Rule(name: "Energie", counterpartyContains: "Stroomhuis", targetItemLabel: "Energie"))
            let t = try f.tx(d, name: "Stroomhuis", cents: -2500)
            let result = try RuleEngine.learn(from: Correction(bankTransaction: t, itemLabel: "Sportclub"), d)
            #expect(result.outcome == .created)
            #expect(result.rule?.id != manual.id)
            #expect(result.rule?.origin == .geleerd)
            #expect(try RuleEngine.rule(id: manual.id!, d) == manual)
            // De geleerde regel gaat voor de handmatige, anders zou de correctie geen effect hebben.
            #expect(result.rule?.priority == manual.priority - 1)
            let next = try f.tx(d, name: "Stroomhuis", cents: -2600)
            #expect(try RuleEngine.suggest(for: next, d).ruleId == result.rule?.id)
        }
    }

    @Test func neverLearnsAmountOnlyRule() throws {
        try f.db.write { d in
            try f.tx(d, description: "Bedankt voor het lenen", cents: -1200, day: "2027-01-02", status: .verwerkt)
            let t = try f.tx(d, description: "Bedankt voor het lenen", cents: -1200)
            let result = try RuleEngine.learn(from: Correction(bankTransaction: t, itemLabel: "Sportclub"), d)
            #expect(result.outcome == .unchanged)
            #expect(result.rule == nil)
            #expect(result.message.hasPrefix("Niets geleerd"))
            #expect(try RuleEngine.rules(d).isEmpty)
        }
    }

    @Test func learnsKeywordFromCardPaymentWithoutCounterparty() throws {
        try f.db.write { d in
            let t = try f.tx(d, description: "BEA, Betaalpas SLAGERIJ VOORBEELD,PAS123 NR:9Z8Y7X, 03.03.27/09:15 ZWOLLE", cents: -1875)
            let result = try RuleEngine.learn(from: Correction(bankTransaction: t, tagIds: [7]), d)
            let rule = try #require(result.rule)
            #expect(result.outcome == .created)
            #expect(rule.descriptionContains == "Slagerij Voorbeeld")
            #expect(rule.counterpartyContains == nil && rule.counterpartyIban == nil && rule.amount == nil)

            let next = try f.tx(d, description: "BEA, Betaalpas SLAGERIJ VOORBEELD,PAS123 NR:1Q2W3E, 10.03.27/17:40 ZWOLLE", cents: -990)
            let s = try RuleEngine.suggest(for: next, d)
            #expect(s.confidence == .midden)
            #expect(s.tagIds == [7])
            #expect(s.label == "Slagerij Voorbeeld")
            // Een tweede correctie past dezelfde regel aan.
            let updated = try RuleEngine.learn(from: Correction(bankTransaction: next, tagIds: [8]), d)
            #expect(updated.outcome == .updated)
            #expect(updated.rule?.id == rule.id)
        }
    }

    @Test func disabledLearnedRuleIsLeftAlone() throws {
        try f.db.write { d in
            let off = try f.rule(d, Rule(name: "Bakker", enabled: false, origin: .geleerd, counterpartyContains: "Bakkerij de Korenaar"))
            let t = try f.tx(d, name: "Bakkerij de Korenaar")
            let result = try RuleEngine.learn(from: Correction(bankTransaction: t, itemLabel: "Sportclub"), d)
            #expect(result.outcome == .unchanged)
            #expect(try RuleEngine.rules(d) == [off])
        }
    }

    @Test func potTargetInMessage() throws {
        try f.db.write { d in
            let t = try f.tx(d, name: "Reisbureau Voorbeeld", cents: -40000)
            let result = try RuleEngine.learn(from: Correction(bankTransaction: t, potId: f.potId, reimburse: true), d)
            #expect(result.rule?.targetPotId == f.potId)
            #expect(result.message == "Regel geleerd: 'Reisbureau Voorbeeld' → potje 'Vakantie', nog overboeken met spaar bij geld eruit")
        }
    }
}
