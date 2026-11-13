import Foundation
import GRDB
import Testing
import HFCore
@testable import HFRules

// Alle testdata is verzonnen.
@Suite struct HistoryRuleSeederTests {
    let f = try! Fixture()

    /// Historieboeking zoals de Excel-import hem maakt.
    @discardableResult
    func hist(_ d: Database, _ day: String, _ cents: Int64, _ label: String, item: Int64? = nil,
              tags: [Int64] = [], note: String = "Excel-historie", account: Int64? = nil) throws -> Entry {
        var e = Entry(accountId: account ?? f.accountId, day: Day(iso: day)!, amount: Money(cents: cents),
                      label: label, budgetItemId: item, note: note)
        try e.insert(d)
        for t in tags { try EntryTag(entryId: e.id!, tagId: t).insert(d) }
        return e
    }

    /// Losse bankregel uit de export (niet opgeslagen).
    func bank(_ day: String, _ cents: Int64, name: String = "", iban: String = "", description: String = "") -> BankTransaction {
        BankTransaction(accountId: f.accountId, day: Day(iso: day)!, amount: Money(cents: cents),
                        counterpartyName: name, counterpartyIban: iban, descriptionText: description,
                        fingerprint: UUID().uuidString)
    }

    func tag(_ d: Database, _ name: String) throws -> Int64 {
        var t = Tag(name: name)
        try t.insert(d)
        return t.id!
    }

    func propose(_ d: Database, _ candidates: [BankTransaction]) throws -> SeedResult {
        try HistoryRuleSeeder.propose(d, candidates: candidates, accountId: f.accountId)
    }

    // MARK: Koppelen

    @Test func matchesDiversOnExactDay() throws {
        try f.db.write { d in
            try hist(d, "2026-03-07", -450, "Brood")
            try hist(d, "2026-04-11", -520, "Brood")
            let r = try propose(d, [bank("2026-03-07", -450, name: "BAKKERIJ DE KORENAAR"),
                                    bank("2026-04-11", -520, name: "Bakkerij de Korenaar")])
            #expect(r.matchedCount == 2 && r.ambiguousCount == 0 && r.noCandidateCount == 0)
            let p = try #require(r.proposals.first)
            #expect(r.proposals.count == 1)
            #expect(p.rule.origin == .geleerd && p.rule.id == nil)
            #expect(p.rule.counterpartyContains == "BAKKERIJ DE KORENAAR")
            #expect(p.rule.name == "Bakkerij de Korenaar")
            #expect(p.rule.targetItemLabel == nil)
            #expect(p.rule.entryLabel == "Brood")
            #expect(p.rule.amount == nil)
            #expect(!p.rule.reimburse)
            #expect(p.matchCount == 2)
            #expect(p.explanation == "2 keer gekoppeld aan divers")
            #expect(p.examples == [SeedExample(day: Day(iso: "2026-03-07")!, amount: Money(cents: -450), historyLabel: "Brood"),
                                   SeedExample(day: Day(iso: "2026-04-11")!, amount: Money(cents: -520), historyLabel: "Brood")])
        }
    }

    @Test func matchesDiversWithinTwoDaysButNotThree() throws {
        try f.db.write { d in
            try hist(d, "2026-03-07", -450, "Brood")
            try hist(d, "2026-04-11", -520, "Brood")
            try hist(d, "2026-05-02", -610, "Brood")
            let r = try propose(d, [bank("2026-03-09", -450, name: "Bakkerij de Korenaar"),
                                    bank("2026-04-10", -520, name: "Bakkerij de Korenaar"),
                                    bank("2026-05-05", -610, name: "Bakkerij de Korenaar")])
            #expect(r.matchedCount == 2)
            #expect(r.noCandidateCount == 1)
            #expect(r.proposals.first?.matchCount == 2)
        }
    }

    @Test func exactDayWinsOverNearbyDay() throws {
        try f.db.write { d in
            try hist(d, "2026-03-07", -450, "Brood")
            try hist(d, "2026-03-08", -450, "Taart")
            let r = try propose(d, [bank("2026-03-08", -450, name: "Bakkerij de Korenaar"),
                                    bank("2026-03-07", -450, name: "Bakkerij de Korenaar")])
            #expect(r.matchedCount == 2 && r.ambiguousCount == 0)
            // Twee verschillende labels: geen omschrijving in de regel.
            #expect(r.proposals.first?.rule.entryLabel == nil)
            #expect(r.proposals.first?.examples.map(\.historyLabel) == ["Taart", "Brood"])
        }
    }

    @Test func matchesFixedItemInSameMonthWithAmount() throws {
        try f.db.write { d in
            try hist(d, "2027-01-15", -15000, "Energie", item: f.energieId)
            try hist(d, "2027-02-15", -15000, "Energie", item: f.energieId)
            let r = try propose(d, [bank("2027-01-03", -15000, name: "STROOMHUIS B.V.", iban: "NL00 TEST 0000 0000 50"),
                                    bank("2027-02-27", -15000, name: "Stroomhuis BV", iban: "NL00TEST0000000050")])
            #expect(r.matchedCount == 2)
            let p = try #require(r.proposals.first)
            #expect(p.id == "iban:NL00TEST0000000050")
            #expect(p.rule.counterpartyIban == "NL00TEST0000000050")
            #expect(p.rule.counterpartyContains == nil)
            #expect(p.rule.targetItemLabel == "Energie")
            #expect(p.rule.entryLabel == "Energie")
            #expect(p.rule.amount == Money(euros: -150))
            #expect(p.rule.name == "Stroomhuis")
            #expect(p.counterpartyIban == "NL00TEST0000000050")
            #expect(p.explanation == "2 keer gekoppeld aan post Energie")
        }
    }

    @Test func matchesFixedItemInAdjacentMonthOnlyWhenOwnMonthIsEmpty() throws {
        try f.db.write { d in
            try hist(d, "2027-02-15", -3000, "Sportclub", item: f.sportId)
            try hist(d, "2027-04-15", -3100, "Sportclub", item: f.sportId)
            let r = try propose(d, [bank("2027-01-30", -3000, name: "Sportvereniging Voorbeeld"),   // maand ervoor
                                    bank("2027-05-01", -3100, name: "Sportvereniging Voorbeeld"),   // maand erna
                                    bank("2027-07-01", -3100, name: "Sportvereniging Voorbeeld")])  // te ver
            #expect(r.matchedCount == 2)
            #expect(r.noCandidateCount == 1)
            let p = try #require(r.proposals.first)
            #expect(p.rule.targetItemLabel == "Sportclub")
            // Verschillende bedragen: geen bedrag in de regel.
            #expect(p.rule.amount == nil)
        }
    }

    @Test func ownMonthIsPreferredOverAdjacentMonth() throws {
        try f.db.write { d in
            let jan = try hist(d, "2027-01-15", -3000, "Sportclub", item: f.sportId)
            try hist(d, "2027-02-15", -3000, "Sportclub", item: f.sportId)
            // De bankregel van februari staat vóór die van januari in het bestand.
            let r = try propose(d, [bank("2027-02-01", -3000, name: "Sportvereniging Voorbeeld"),
                                    bank("2027-01-02", -3000, name: "Sportvereniging Voorbeeld")])
            #expect(r.matchedCount == 2)
            #expect(r.proposals.first?.matchCount == 2)
            _ = jan
        }
    }

    @Test func dayFifteenIsTreatedAsUnknownDate() throws {
        try f.db.write { d in
            try hist(d, "2026-06-15", -2500, "Cadeau")
            try hist(d, "2026-07-15", -2600, "Cadeau")
            let r = try propose(d, [bank("2026-06-28", -2500, name: "Speelgoedwinkel Voorbeeld"),
                                    bank("2026-07-02", -2600, name: "Speelgoedwinkel Voorbeeld")])
            #expect(r.matchedCount == 2)
            #expect(r.proposals.first?.rule.entryLabel == "Cadeau")
        }
    }

    @Test func twoCandidatesWithoutHelpAreAmbiguous() throws {
        try f.db.write { d in
            try hist(d, "2026-03-15", -2000, "Cadeau oma")
            try hist(d, "2026-03-15", -2000, "Schoolreis")
            let r = try propose(d, [bank("2026-03-20", -2000, name: "Winkel Voorbeeld")])
            #expect(r.ambiguousCount == 1)
            #expect(r.matchedCount == 0)
            #expect(r.proposals.isEmpty)
        }
    }

    @Test func descriptionHelpsToChooseBetweenCandidates() throws {
        try f.db.write { d in
            try hist(d, "2026-03-15", -2000, "Cadeau oma")
            try hist(d, "2026-03-15", -2000, "Schoolreis")
            try hist(d, "2026-04-15", -2200, "Schoolreis")
            try hist(d, "2026-04-15", -2200, "Cadeau opa")
            let r = try propose(d, [bank("2026-03-20", -2000, name: "Basisschool Voorbeeld", description: "Bijdrage SCHOOLREIS groep 6"),
                                    bank("2026-04-20", -2200, name: "Basisschool Voorbeeld", description: "schoolreis groep 7")])
            #expect(r.matchedCount == 2 && r.ambiguousCount == 0)
            #expect(r.proposals.first?.rule.entryLabel == "Schoolreis")
        }
    }

    @Test func interchangeableCandidatesAreNotAmbiguous() throws {
        try f.db.write { d in
            try hist(d, "2027-03-15", -3000, "Sportclub", item: f.sportId)
            try hist(d, "2027-03-15", -3000, "Sportclub", item: f.sportId)
            let r = try propose(d, [bank("2027-03-02", -3000, name: "Sportvereniging Voorbeeld"),
                                    bank("2027-03-20", -3000, name: "Sportvereniging Voorbeeld")])
            #expect(r.matchedCount == 2 && r.ambiguousCount == 0)
        }
    }

    @Test func eachHistoryEntryIsUsedOnce() throws {
        try f.db.write { d in
            try hist(d, "2026-03-07", -450, "Brood")
            let r = try propose(d, [bank("2026-03-07", -450, name: "Bakkerij de Korenaar"),
                                    bank("2026-03-07", -450, name: "Bakkerij de Korenaar")])
            #expect(r.matchedCount == 1)
            #expect(r.noCandidateCount == 1)
            #expect(r.proposals.isEmpty)       // één diverse koppeling is te weinig
            #expect(r.insufficientCount == 1)
        }
    }

    @Test func onlyHistoryOfThisAccountWithoutBankTransactionCounts() throws {
        try f.db.write { d in
            try hist(d, "2026-03-07", -450, "Brood", note: "")                    // gewone handinvoer
            try hist(d, "2026-03-07", -450, "Brood", account: f.savingsId)        // andere rekening
            let r = try propose(d, [bank("2026-03-07", -450, name: "Bakkerij de Korenaar")])
            #expect(r.matchedCount == 0 && r.noCandidateCount == 1)
        }
    }

    // MARK: Groeperen

    @Test func groupsByIbanAndByName() throws {
        try f.db.write { d in
            for (day, cents) in [("2026-03-07", Int64(-450)), ("2026-03-14", -460), ("2026-03-21", -470), ("2026-03-28", -480)] {
                try hist(d, day, cents, "Boodschappen")
            }
            let r = try propose(d, [
                bank("2026-03-07", -450, name: "Supermarkt Voorbeeld Noord", iban: "NL00TEST0000000031"),
                bank("2026-03-14", -460, name: "Supermarkt Voorbeeld Zuid", iban: "nl00test0000000031"),
                bank("2026-03-21", -470, name: "GROENTEBOER  VOORBEELD"),
                bank("2026-03-28", -480, name: "Groenteboer Voorbeeld"),
            ])
            #expect(r.proposals.count == 2)
            #expect(Set(r.proposals.map(\.id)) == ["iban:NL00TEST0000000031", "naam:groenteboer voorbeeld"])
            let byName = try #require(r.proposals.first { $0.id.hasPrefix("naam:") })
            #expect(byName.rule.counterpartyContains == "GROENTEBOER VOORBEELD")
            #expect(byName.rule.counterpartyIban == nil)
            #expect(byName.rule.name == "Groenteboer Voorbeeld")
        }
    }

    @Test func transactionsWithoutCounterpartyNeedAKeyword() throws {
        try f.db.write { d in
            try hist(d, "2026-03-07", -1875, "Vlees")
            try hist(d, "2026-03-14", -990, "Vlees")
            try hist(d, "2026-03-21", -1200, "Geleend")
            let r = try propose(d, [
                bank("2026-03-07", -1875, description: "BEA, Betaalpas SLAGERIJ VOORBEELD,PAS123 NR:9Z8Y7X, 07.03.26/09:15 ZWOLLE"),
                bank("2026-03-14", -990, description: "BEA, Betaalpas SLAGERIJ VOORBEELD,PAS123 NR:1Q2W3E, 14.03.26/17:40 ZWOLLE"),
                bank("2026-03-21", -1200, description: "Bedankt voor het lenen"),
            ])
            #expect(r.skippedCount == 1)
            #expect(r.matchedCount == 2)
            let p = try #require(r.proposals.first)
            #expect(p.rule.descriptionContains == "Slagerij Voorbeeld")
            #expect(p.rule.counterpartyContains == nil && p.rule.counterpartyIban == nil)
            #expect(p.rule.entryLabel == "Vlees")
        }
    }

    @Test func majorityWinsAndMixedIsReported() throws {
        try f.db.write { d in
            // Twee derde naar Energie, één divers: voorstel voor Energie.
            try hist(d, "2027-01-15", -15000, "Energie", item: f.energieId)
            try hist(d, "2027-02-15", -15500, "Energie", item: f.energieId)
            try hist(d, "2027-03-09", -4000, "Naheffing")
            // Eén Sportclub en één divers: gemengd.
            try hist(d, "2027-01-15", -3000, "Sportclub", item: f.sportId)
            try hist(d, "2027-02-08", -1250, "Toernooi")
            let r = try propose(d, [
                bank("2027-01-04", -15000, name: "Stroomhuis"), bank("2027-02-04", -15500, name: "Stroomhuis"),
                bank("2027-03-09", -4000, name: "Stroomhuis"),
                bank("2027-01-05", -3000, name: "Sportvereniging Voorbeeld"),
                bank("2027-02-08", -1250, name: "Sportvereniging Voorbeeld"),
            ])
            #expect(r.matchedCount == 5)
            #expect(r.proposals.count == 1)
            let p = try #require(r.proposals.first)
            #expect(p.rule.targetItemLabel == "Energie")
            #expect(p.matchCount == 2)
            #expect(p.rule.amount == nil)   // twee verschillende bedragen
            #expect(p.explanation == "2 keer gekoppeld aan post Energie; 1 keer aan iets anders")
            #expect(r.mixedCount == 1)
            #expect(r.mixed.first?.counterparty == "Sportvereniging Voorbeeld")
            #expect(r.mixed.first?.matchCount == 2)
            #expect(r.mixed.first?.detail == "Verdeeld over meer doelen: 1 × post Sportclub, 1 × divers.")
        }
    }

    @Test func singleMatchOnlyWhenAmountEqualsPlan() throws {
        try f.db.write { d in
            try hist(d, "2027-01-15", -15000, "Energie", item: f.energieId)     // plan −150,00
            try hist(d, "2027-01-15", -2900, "Sportclub", item: f.sportId)      // plan −30,00
            let r = try propose(d, [bank("2027-01-04", -15000, name: "Stroomhuis"),
                                    bank("2027-01-05", -2900, name: "Sportvereniging Voorbeeld")])
            #expect(r.matchedCount == 2)
            #expect(r.proposals.count == 1)
            let p = try #require(r.proposals.first)
            #expect(p.rule.targetItemLabel == "Energie")
            #expect(p.rule.amount == nil)       // bedrag pas bij minstens twee koppelingen
            #expect(p.explanation == "1 keer gekoppeld aan post Energie (bedrag gelijk aan het plan)")
            #expect(r.insufficientCount == 1)
        }
    }

    @Test func diversLabelOnlyWhenNearlyEqual() throws {
        try f.db.write { d in
            try hist(d, "2026-03-07", -450, "Brood")
            try hist(d, "2026-03-14", -460, " brood ")
            try hist(d, "2026-03-21", -470, "Taart verjaardag")
            try hist(d, "2026-04-04", -1100, "Bloemen")
            try hist(d, "2026-04-11", -1200, "Plant")
            let r = try propose(d, [
                bank("2026-03-07", -450, name: "Bakkerij de Korenaar"), bank("2026-03-14", -460, name: "Bakkerij de Korenaar"),
                bank("2026-03-21", -470, name: "Bakkerij de Korenaar"),
                bank("2026-04-04", -1100, name: "Bloemist Voorbeeld"), bank("2026-04-11", -1200, name: "Bloemist Voorbeeld"),
            ])
            let bakker = try #require(r.proposals.first { $0.rule.name == "Bakkerij de Korenaar" })
            let bloemist = try #require(r.proposals.first { $0.rule.name == "Bloemist Voorbeeld" })
            #expect(bakker.rule.entryLabel == "Brood")      // 2 van de 3
            #expect(bloemist.rule.entryLabel == nil)        // elk een eigen label
            #expect(r.proposals.first?.rule.name == "Bakkerij de Korenaar")   // meeste koppelingen eerst
            #expect(bakker.examples.count == 3)
        }
    }

    @Test func tagsNeedTwoThirds() throws {
        try f.db.write { d in
            let tanken = try tag(d, "tanken"), auto = try tag(d, "auto"), vakantie = try tag(d, "vakantie")
            try hist(d, "2026-03-07", -5000, "Tanken", tags: [tanken, auto])
            try hist(d, "2026-03-14", -5100, "Tanken", tags: [tanken, auto])
            try hist(d, "2026-03-21", -5200, "Tanken", tags: [tanken, vakantie])
            let r = try propose(d, [bank("2026-03-07", -5000, name: "Tankstation Voorbeeld"),
                                    bank("2026-03-14", -5100, name: "Tankstation Voorbeeld"),
                                    bank("2026-03-21", -5200, name: "Tankstation Voorbeeld")])
            #expect(r.proposals.first?.rule.tagIdList == [tanken, auto].sorted())
        }
    }

    // MARK: Bestaande regels en opslaan

    @Test func existingRuleMeansAlreadyCovered() throws {
        try f.db.write { d in
            try f.rule(d, Rule(name: "Energie handmatig", enabled: false, counterpartyContains: "stroomhuis", amount: Money(euros: -1)))
            try f.rule(d, Rule(name: "Sport geleerd", origin: .geleerd, counterpartyIban: "NL00TEST0000000077"))
            try f.rule(d, Rule(name: "Trefwoord", descriptionContains: "termijn"))
            try hist(d, "2027-01-15", -15000, "Energie", item: f.energieId)
            try hist(d, "2027-02-15", -15000, "Energie", item: f.energieId)
            try hist(d, "2027-01-15", -3000, "Sportclub", item: f.sportId)
            try hist(d, "2027-01-15", -9900, "Verzekering")
            try hist(d, "2027-02-15", -9900, "Verzekering")
            let r = try propose(d, [
                bank("2027-01-04", -15000, name: "STROOMHUIS BV"), bank("2027-02-04", -15000, name: "STROOMHUIS BV"),
                bank("2027-01-05", -3000, name: "Sportvereniging Voorbeeld", iban: "NL00TEST0000000077"),
                // Een trefwoordregel dekt een tegenpartij met naam niet.
                bank("2027-01-06", -9900, name: "Verzekeraar Voorbeeld", description: "Termijn januari"),
                bank("2027-02-06", -9900, name: "Verzekeraar Voorbeeld", description: "Termijn februari"),
            ])
            #expect(r.alreadyCoveredCount == 2)
            #expect(r.alreadyCovered.map(\.counterparty) == ["Stroomhuis", "Sportvereniging Voorbeeld"])
            #expect(r.alreadyCovered.first?.detail == "Er bestaat al een regel: 'Energie handmatig'.")
            #expect(r.proposals.map(\.rule.name) == ["Verzekeraar Voorbeeld"])
        }
    }

    @Test func applyStoresLearnedRulesAndIsIdempotent() throws {
        try f.db.write { d in
            try hist(d, "2027-01-15", -15000, "Energie", item: f.energieId)
            try hist(d, "2027-02-15", -15000, "Energie", item: f.energieId)
            try hist(d, "2026-03-07", -450, "Brood")
            try hist(d, "2026-03-14", -460, "Brood")
            try hist(d, "2026-03-21", -1875, "Vlees")
            try hist(d, "2026-03-28", -990, "Vlees")
            let candidates = [
                bank("2027-01-04", -15000, name: "Stroomhuis", iban: "NL00TEST0000000050"),
                bank("2027-02-04", -15000, name: "Stroomhuis", iban: "NL00TEST0000000050"),
                bank("2026-03-07", -450, name: "Bakkerij de Korenaar"), bank("2026-03-14", -460, name: "Bakkerij de Korenaar"),
                bank("2026-03-21", -1875, description: "BEA, Betaalpas SLAGERIJ VOORBEELD,PAS123 NR:9Z8Y7X, 21.03.26/09:15 ZWOLLE"),
                bank("2026-03-28", -990, description: "BEA, Betaalpas SLAGERIJ VOORBEELD,PAS123 NR:1Q2W3E, 28.03.26/17:40 ZWOLLE"),
            ]
            let entriesBefore = try Entry.fetchCount(d)
            let r = try propose(d, candidates)
            #expect(r.proposals.count == 3)
            #expect(try Rule.fetchCount(d) == 0)      // propose schrijft niets

            let created = try HistoryRuleSeeder.apply(d, proposals: r.proposals)
            #expect(created.count == 3)
            #expect(created.allSatisfy { $0.id != nil && $0.origin == .geleerd && !$0.reimburse })
            #expect(try Rule.fetchCount(d) == 3)

            // Nog een keer: niets nieuws, ook niet via een nieuw voorstel.
            #expect(try HistoryRuleSeeder.apply(d, proposals: r.proposals).isEmpty)
            #expect(try Rule.fetchCount(d) == 3)
            let again = try propose(d, candidates)
            #expect(again.proposals.isEmpty)
            #expect(again.alreadyCoveredCount == 3)

            // Geen boekingen en geen banktransacties geschreven.
            #expect(try Entry.fetchCount(d) == entriesBefore)
            #expect(try BankTransaction.fetchCount(d) == 0)

            // De regels werken daarna voor echte import.
            let t = try f.tx(d, name: "Stroomhuis", iban: "NL00TEST0000000050", cents: -15000, day: "2027-03-04")
            let s = try RuleEngine.suggest(for: t, d)
            #expect(s.confidence == .hoog)
            #expect(s.budgetItemId == f.energieId)
            #expect(s.label == "Energie")
        }
    }

    @Test func applySkipsDuplicateProposalsInOneCall() throws {
        try f.db.write { d in
            try hist(d, "2026-03-07", -450, "Brood")
            try hist(d, "2026-03-14", -460, "Brood")
            let r = try propose(d, [bank("2026-03-07", -450, name: "Bakkerij de Korenaar"),
                                    bank("2026-03-14", -460, name: "Bakkerij de Korenaar")])
            let created = try HistoryRuleSeeder.apply(d, proposals: r.proposals + r.proposals)
            #expect(created.count == 1)
        }
    }
}
