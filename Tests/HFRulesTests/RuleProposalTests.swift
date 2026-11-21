import Foundation
import GRDB
import Testing
import HFCore
@testable import HFRules

// 6i: regels alleen met toestemming. Alle testdata is verzonnen.
@Suite struct RuleProposalTests {
    let f = try! Fixture()

    @Test func bookingWithoutRememberCreatesNoRule() throws {
        try f.db.write { d in
            let t = try f.tx(d, name: "Stichting Voorbeeld", iban: "NL00TEST0000000060", cents: -2500)
            let result = try RuleEngine.afterBooking(Correction(bankTransaction: t, itemLabel: "Energie"),
                                                     remember: nil, d)
            #expect(result.outcome == .unchanged)
            #expect(try Rule.fetchCount(d) == 0)
        }
    }

    @Test func proposalWithoutRuleIsNewRuleForCounterparty() throws {
        try f.db.write { d in
            let t = try f.tx(d, name: "STICHTING VOORBEELD", iban: "NL00TEST0000000060", cents: -2500)
            let p = try RuleEngine.ruleProposal(for: Correction(bankTransaction: t, itemLabel: "Energie", tagIds: [3]), d)
            let draft = try #require(p.draft)
            #expect(p.proposingRule == nil)
            #expect(!p.isUpdate)
            #expect(p.offersChoice)
            #expect(draft.id == nil)
            #expect(draft.counterpartyIban == "NL00TEST0000000060")
            #expect(draft.targetItemLabel == "Energie")
            #expect(draft.tagIdList == [3])
            #expect(draft.amount == nil)      // eerste keer gezien: geen bedrag als voorwaarde
            #expect(try Rule.fetchCount(d) == 0)   // een voorstel schrijft niets
        }
    }

    @Test func rememberSavesExactlyTheShownRule() throws {
        try f.db.write { d in
            let t = try f.tx(d, name: "Stichting Voorbeeld", iban: "NL00TEST0000000060", cents: -2500)
            let correction = Correction(bankTransaction: t, potId: f.potId, entryLabel: "Gift", reimburse: true)
            var shown = try #require(try RuleEngine.ruleProposal(for: correction, d).draft)
            // Aangepast in de editor: andere naam en een trefwoord erbij.
            shown.name = "Giften"
            shown.descriptionContains = "gift"
            let result = try RuleEngine.afterBooking(correction, remember: shown, d)
            #expect(result.outcome == .created)
            let saved = try #require(try Rule.fetchAll(d).first)
            var expected = shown
            expected.id = saved.id
            #expect(saved == expected)
            #expect(saved.reimburse)
            #expect(saved.reimburseDirection == .outgoing)
            #expect(saved.targetPotId == f.potId)
            #expect(result.message.hasPrefix("Regel bewaard: Voortaan bij"))

            // Ongedaan maken verwijdert de regel weer.
            try RuleEngine.undoLearning(result, d)
            #expect(try Rule.fetchCount(d) == 0)
        }
    }

    @Test func differentChoiceWithoutUpdateLeavesRuleUnchanged() throws {
        try f.db.write { d in
            let rule = try f.rule(d, Rule(name: "Zakgeld", origin: .geleerd, counterpartyIban: "NL00TEST0000000070",
                                          targetItemLabel: "Sportclub"))
            let t = try f.tx(d, name: "Kind Voorbeeld", iban: "NL00TEST0000000070", cents: -500)
            let correction = Correction(bankTransaction: t, potId: f.potId, reimburse: true)

            let p = try RuleEngine.ruleProposal(for: correction, d)
            #expect(p.proposingRule?.id == rule.id)
            #expect(!p.matchesProposal)
            #expect(p.isUpdate)
            #expect(p.offersChoice)
            // Het concept houdt de voorwaarden van de regel en neemt de keuze over.
            #expect(p.draft?.counterpartyIban == "NL00TEST0000000070")
            #expect(p.draft?.targetItemLabel == nil)
            #expect(p.draft?.reimburse == true)

            let result = try RuleEngine.afterBooking(correction, remember: nil, d)
            #expect(result.outcome == .unchanged)
            #expect(result.usedRuleId == nil)
            #expect(try Rule.fetchOne(d, key: rule.id!) == rule)   // ook niet als gebruikt geteld
        }
    }

    @Test func differentChoiceWithUpdateChangesRuleAndCanBeUndone() throws {
        try f.db.write { d in
            let rule = try f.rule(d, Rule(name: "Zakgeld", origin: .handmatig, counterpartyIban: "NL00TEST0000000070",
                                          targetItemLabel: "Sportclub"))
            let t = try f.tx(d, name: "Kind Voorbeeld", iban: "NL00TEST0000000070", cents: -500)
            let correction = Correction(bankTransaction: t, itemLabel: "Energie")
            let draft = try #require(try RuleEngine.ruleProposal(for: correction, d).draft)
            let result = try RuleEngine.afterBooking(correction, remember: draft, d)
            #expect(result.outcome == .updated)
            #expect(try Rule.fetchOne(d, key: rule.id!)?.targetItemLabel == "Energie")
            #expect(try Rule.fetchCount(d) == 1)
            try RuleEngine.undoLearning(result, d)
            #expect(try Rule.fetchOne(d, key: rule.id!) == rule)
        }
    }

    @Test func acceptingProposalCountsUseOnly() throws {
        try f.db.write { d in
            let rule = try f.rule(d, Rule(name: "Stroomhuis", origin: .geleerd, counterpartyIban: "NL00TEST0000000050",
                                          targetItemLabel: "Energie"))
            let t = try f.tx(d, name: "Stroomhuis", iban: "NL00TEST0000000050", cents: -15000)
            let correction = Correction(bankTransaction: t, itemLabel: "Energie")
            let p = try RuleEngine.ruleProposal(for: correction, d)
            #expect(p.matchesProposal)
            #expect(!p.offersChoice)

            let when = Date(timeIntervalSince1970: 1_800_000_000)
            let result = try RuleEngine.afterBooking(correction, remember: nil, d, now: when)
            #expect(result.usedRuleId == rule.id)
            let after = try #require(try Rule.fetchOne(d, key: rule.id!))
            #expect(after.hitCount == 1)
            #expect(after.lastUsed == when)
            var same = after
            same.hitCount = rule.hitCount; same.lastUsed = rule.lastUsed
            #expect(same == rule)
        }
    }

    @Test func noCounterpartyAndNoRuleOffersNothing() throws {
        try f.db.write { d in
            let t = try f.tx(d, description: "x", cents: -100)
            let p = try RuleEngine.ruleProposal(for: Correction(bankTransaction: t), d)
            #expect(p.draft == nil)
            #expect(!p.offersChoice)
        }
    }

    @Test func summarySentence() throws {
        var rule = Rule(name: "Stichting Voorbeeld", counterpartyContains: "Stichting Voorbeeld",
                        targetPotId: 9, entryLabel: "Gift", reimburse: true, reimburseDirection: .outgoing)
        #expect(RuleEngine.summary(of: rule, potName: "Vakantie", tagNames: [])
                == "Voortaan bij Stichting Voorbeeld: post Overig, nog overboeken met potje Vakantie bij geld eruit, omschrijving 'Gift'")

        rule = Rule(name: "Stroomhuis", counterpartyIban: "NL00 TEST 0000 0000 50", amount: Money(cents: -15000),
                    targetItemLabel: "Energie")
        #expect(RuleEngine.summary(of: rule, potName: nil, tagNames: ["Vast", "Huis"])
                == "Voortaan bij Stroomhuis (NL00TEST0000000050) bij -€ 150,00: post Energie, tags Vast, Huis")

        rule = Rule(name: "Spaar", descriptionContains: "vakantiegeld", targetPotId: 9)
        #expect(RuleEngine.summary(of: rule, potName: "Vakantie", tagNames: ["Reis"])
                == "Voortaan bij omschrijving met 'vakantiegeld': potje Vakantie, tag Reis")
    }

    @Test func summaryLooksUpPotAndTagNames() throws {
        try f.db.write { d in
            var tag = Tag(name: "Cadeau", color: "#000000")
            try tag.insert(d)
            let rule = Rule(name: "X", counterpartyContains: "Winkel Voorbeeld", targetPotId: f.potId,
                            tagIds: String(tag.id!), reimburse: true, reimburseDirection: .both)
            #expect(try RuleEngine.summary(of: rule, d)
                    == "Voortaan bij Winkel Voorbeeld: post Overig, nog overboeken met potje Vakantie, tag Cadeau")
        }
    }
}
