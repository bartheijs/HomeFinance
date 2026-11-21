import Foundation
import GRDB
import Testing
import HFCore
@testable import HFRules

// 6f: verrekenen met spaar en de pot alleen in de richting waarin de gebruiker het koos. Alle data is verzonnen.

@Suite struct ReimburseDirectionTests {
    let f = try! Fixture()
    let childIban = "NL00TEST0000000031"

    @Test func learnedOnIncomingIsNotSuggestedOnOutgoing() throws {
        try f.db.write { d in
            // Het kind stort geld voor haar spaarpot: de gebruiker kiest verrekenen met spaar en de pot.
            let incoming = try f.tx(d, name: "Kind Test", iban: childIban, cents: 2500, day: "2027-02-01")
            let learned = try RuleEngine.learn(from: Correction(bankTransaction: incoming, potId: f.potId,
                                                                reimburse: true), d)
            let rule = try #require(learned.rule)
            #expect(learned.outcome == .created)
            #expect(rule.reimburse)
            #expect(rule.targetPotId == f.potId)
            #expect(rule.reimburseDirection == .incoming)
            #expect(learned.message.hasSuffix("verrekenen met spaar bij geld erin"))

            // Weer geld erin: verrekenen en pot worden voorgesteld, zonder melding.
            let again = try f.tx(d, name: "Kind Test", iban: childIban, cents: 1000, day: "2027-03-01")
            let sIn = try RuleEngine.suggest(for: again, d)
            #expect(sIn.reimburse)
            #expect(sIn.potId == f.potId)
            #expect(sIn.confidence == .midden)
            #expect(sIn.warnings.isEmpty)

            // Zakgeld naar het kind (geld eruit): wel een voorstel, maar zonder verrekenen en zonder pot,
            // met lagere zekerheid en een melding (twijfelgeval).
            let pocketMoney = try f.tx(d, name: "Kind Test", iban: childIban, cents: -1500, day: "2027-03-02")
            let sOut = try RuleEngine.suggest(for: pocketMoney, d)
            #expect(sOut.ruleId == rule.id)
            #expect(!sOut.reimburse)
            #expect(sOut.potId == nil)
            #expect(sOut.confidence == .laag)
            #expect(sOut.warnings.count == 1)
            #expect(sOut.label == "Kind Test")
        }
    }

    @Test func otherDirectionKeepsPostAndLabel() throws {
        try f.db.write { d in
            try f.rule(d, Rule(name: "Kind", origin: .handmatig, counterpartyIban: childIban, targetItemLabel: "Energie",
                               targetPotId: f.potId, entryLabel: "Kind", reimburse: true, reimburseDirection: .outgoing))
            let incoming = try f.tx(d, name: "Kind Test", iban: childIban, cents: 2000)
            let s = try RuleEngine.suggest(for: incoming, d)
            #expect(s.budgetItemId == f.energieId)
            #expect(s.label == "Kind")
            #expect(!s.reimburse)
            #expect(s.potId == nil)
            #expect(!s.warnings.isEmpty)
        }
    }

    @Test func bothDirectionsAndPotWithoutReimburseAreUnchanged() throws {
        try f.db.write { d in
            try f.rule(d, Rule(name: "Beide", counterpartyIban: "NL00TEST0000000032", targetPotId: f.potId,
                               reimburse: true, reimburseDirection: .both))
            try f.rule(d, Rule(name: "Spaarpot", counterpartyIban: "NL00TEST0000000033", targetPotId: f.potId,
                               reimburseDirection: .incoming))
            for cents in [Int64(500), -500] {
                let a = try RuleEngine.suggest(for: f.tx(d, iban: "NL00TEST0000000032", cents: cents), d)
                #expect(a.reimburse && a.potId == f.potId && a.warnings.isEmpty)
                // Zonder verrekenen geldt de pot (bv. op spaar) altijd, ongeacht de richting.
                let b = try RuleEngine.suggest(for: f.tx(d, iban: "NL00TEST0000000033", cents: cents,
                                                         account: f.savingsId), d)
                #expect(!b.reimburse && b.potId == f.potId && b.warnings.isEmpty)
            }
        }
    }

    @Test func bookingOtherDirectionWithoutReimburseKeepsRuleReimburse() throws {
        try f.db.write { d in
            let incoming = try f.tx(d, name: "Kind Test", iban: childIban, cents: 2500, day: "2027-02-01")
            let created = try RuleEngine.learn(from: Correction(bankTransaction: incoming, potId: f.potId,
                                                                reimburse: true), d)
            // Zakgeld zonder verrekenen boeken zoals voorgesteld: de regel verandert niet.
            let out = try f.tx(d, name: "Kind Test", iban: childIban, cents: -1500, day: "2027-03-02")
            let same = try RuleEngine.learn(from: Correction(bankTransaction: out), d)
            #expect(same.outcome == .unchanged)
            #expect(same.usedRuleId == created.rule?.id)

            // Zakgeld op een post boeken: post wordt geleerd, verrekenen bij geld erin blijft.
            let out2 = try f.tx(d, name: "Kind Test", iban: childIban, cents: -1500, day: "2027-04-02")
            let updated = try RuleEngine.learn(from: Correction(bankTransaction: out2, itemLabel: "Sportclub"), d)
            let rule = try #require(updated.rule)
            #expect(updated.outcome == .updated)
            #expect(rule.targetItemLabel == "Sportclub")
            #expect(rule.reimburse)
            #expect(rule.targetPotId == f.potId)
            #expect(rule.reimburseDirection == .incoming)
        }
    }

    @Test func choosingReimburseInOtherDirectionMakesBoth() throws {
        try f.db.write { d in
            let incoming = try f.tx(d, name: "Kind Test", iban: childIban, cents: 2500, day: "2027-02-01")
            _ = try RuleEngine.learn(from: Correction(bankTransaction: incoming, potId: f.potId, reimburse: true), d)
            let out = try f.tx(d, name: "Kind Test", iban: childIban, cents: -1500, day: "2027-03-02")
            let r = try RuleEngine.learn(from: Correction(bankTransaction: out, potId: f.potId, reimburse: true), d)
            #expect(r.outcome == .updated)
            #expect(r.rule?.reimburseDirection == .both)

            // Daarna in één richting toch zonder verrekenen: alleen de andere richting blijft over.
            let in2 = try f.tx(d, name: "Kind Test", iban: childIban, cents: 3000, day: "2027-04-02")
            let r2 = try RuleEngine.learn(from: Correction(bankTransaction: in2), d)
            #expect(r2.rule?.reimburse == true)
            #expect(r2.rule?.reimburseDirection == .outgoing)
        }
    }

    @Test func turningOffInOwnDirectionTurnsReimburseOff() throws {
        try f.db.write { d in
            let incoming = try f.tx(d, name: "Kind Test", iban: childIban, cents: 2500, day: "2027-02-01")
            _ = try RuleEngine.learn(from: Correction(bankTransaction: incoming, potId: f.potId, reimburse: true), d)
            let in2 = try f.tx(d, name: "Kind Test", iban: childIban, cents: 2500, day: "2027-03-01")
            let r = try RuleEngine.learn(from: Correction(bankTransaction: in2), d)
            #expect(r.outcome == .updated)
            #expect(r.rule?.reimburse == false)
            #expect(r.rule?.targetPotId == nil)
        }
    }
}
