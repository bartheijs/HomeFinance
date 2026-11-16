import Foundation
import GRDB
import HFCore
import Testing
@testable import HFInsight

/// Boekingen zonder pot op de spaarrekening. De fixture heeft al "Rente" +10 op 2-3-2027 zonder pot.
@Suite struct UnallocatedSavingsTests {
    let f: Fixture
    init() throws { f = try Fixture() }

    @discardableResult
    private func add(_ day: String, _ amount: Money, _ label: String, account: Int64? = nil, pot: Int64? = nil) throws -> Int64 {
        try f.db.write { db in
            var e = Entry(accountId: account ?? f.spaar, day: d(day), amount: amount, label: label, potId: pot)
            try e.insert(db); return e.id!
        }
    }
    private func overview(_ account: Int64? = nil) throws -> UnallocatedSavings {
        try f.db.read { try Insight.unallocatedSavingsOverview($0, accountId: account) }
    }

    @Test func noPairs() throws {
        let o = try overview()
        #expect(o.entries.map(\.label) == ["Rente"])
        #expect(o.cancelledPairs.isEmpty)
        #expect(o.remainingTotal == eur(10))
        #expect(o.cancelledCount == 0)
    }

    @Test func onePairCancels() throws {
        let plus = try add("2027-03-05", Money(cents: 105_851), "Voorgeschoten terug")
        let minus = try add("2027-03-05", Money(cents: -105_851), "Voorgeschoten")
        let o = try overview()
        // +1.058,51 en −1.058,51 op dezelfde dag heffen elkaar op; alleen de rente blijft over.
        #expect(o.cancelledPairs.count == 1)
        #expect(Set([o.cancelledPairs[0].first.id, o.cancelledPairs[0].second.id]) == [plus, minus])
        #expect(o.cancelledPairs[0].amount == Money(cents: 105_851))
        #expect(o.cancelledCount == 2)
        #expect(o.entries.map(\.label) == ["Rente"])
        #expect(o.remainingTotal == eur(10))
        // De rekenregel verandert niet: niet toegewezen is saldo − potten, met de opgeheven boekingen erin.
        let pots = try f.db.read { try Insight.potOverview($0, today: Fixture.today) }.accounts[0]
        #expect(pots.unallocated == eur(5010))
        // De oude functie geeft alleen de overgebleven boekingen.
        #expect(try f.db.read { try Insight.unallocatedSavingsEntries($0) }.map(\.label) == ["Rente"])
    }

    @Test func pairPlusLooseInterest() throws {
        try add("2027-03-10", eur(250), "Bijgestort")
        try add("2027-03-12", eur(-250), "Teruggestort")
        try add("2027-03-14", Money(cents: 337), "Rente")
        let o = try overview()
        #expect(o.cancelledPairs.count == 1)
        #expect(o.cancelledPairs[0].first.label == "Bijgestort")      // de oudste van het paar
        #expect(o.cancelledPairs[0].second.label == "Teruggestort")
        #expect(o.entries.map(\.label) == ["Rente", "Rente"])         // nieuwste eerst
        #expect(o.remainingTotal == Money(cents: 1337))               // 10,00 + 3,37
        #expect(o.cancelledCount == 2)
    }

    @Test func twoPairsWithSameAmountMatchNearestDay() throws {
        // +100 op 1-3 en 20-3; −100 op 3-3 en 22-3: dichtstbij is 1-3↔3-3 (2 dagen) en 20-3↔22-3 (2 dagen).
        let a = try add("2027-03-01", eur(100), "A plus")
        let b = try add("2027-03-03", eur(-100), "A min")
        let c = try add("2027-03-20", eur(100), "B plus")
        let e = try add("2027-03-22", eur(-100), "B min")
        let o = try overview()
        #expect(o.cancelledPairs.count == 2)
        #expect(o.cancelledPairs.map { [$0.first.id, $0.second.id] } == [[c, e], [a, b]])   // nieuwste paar eerst
        #expect(o.cancelledCount == 4)
        #expect(o.entries.map(\.label) == ["Rente"])
    }

    @Test func oddOneOutStaysWhenThreeShareAnAmount() throws {
        // Twee keer +50 en één keer −50: de −50 hoort bij de dichtstbijzijnde +50 (4 dagen), de andere blijft over.
        let near = try add("2027-03-04", eur(50), "Dichtbij")
        _ = try add("2027-02-20", eur(50), "Verder weg")
        let minus = try add("2027-03-08", eur(-50), "Terug")
        let o = try overview()
        #expect(o.cancelledPairs.count == 1)
        #expect(Set([o.cancelledPairs[0].first.id, o.cancelledPairs[0].second.id]) == [near, minus])
        #expect(o.entries.map(\.label) == ["Rente", "Verder weg"])
        #expect(o.remainingTotal == eur(60))
    }

    @Test func pairFurtherThanFortyFiveDaysApartStays() throws {
        // 15-1 en 1-3: 45 dagen is nog toegestaan; 14-1 en 1-3: 46 dagen niet.
        try add("2027-01-15", eur(70), "Net binnen")
        try add("2027-03-01", eur(-70), "Net binnen terug")
        try add("2027-01-14", eur(80), "Net buiten")
        try add("2027-03-01", eur(-80), "Net buiten terug")
        let o = try overview()
        #expect(o.cancelledPairs.count == 1)
        #expect(o.cancelledPairs[0].first.label == "Net binnen")
        #expect(o.entries.map(\.label).sorted() == ["Net buiten", "Net buiten terug", "Rente"])
        #expect(o.remainingTotal == eur(10))   // +80 −80 +10
    }

    @Test func entriesWithPotDoNotCount() throws {
        try add("2027-03-05", eur(100), "Met pot", pot: f.potAuto)
        try add("2027-03-05", eur(-100), "Zonder pot")
        let o = try overview()
        #expect(o.cancelledPairs.isEmpty)
        #expect(o.entries.map(\.label) == ["Zonder pot", "Rente"])
        #expect(o.cancelledCount == 0)
    }

    @Test func pairsAreNotMatchedAcrossAccounts() throws {
        let second: Int64 = try f.db.write { db in
            var a = Account(name: "Spaarrekening 2", iban: "NL00TEST0000000003", kind: .spaar,
                            openingDate: d("2027-01-01"), sortOrder: 3)
            try a.insert(db); return a.id!
        }
        try add("2027-03-05", eur(100), "Op rekening 1")
        try add("2027-03-05", eur(-100), "Op rekening 2", account: second)
        // Samen: niet gekoppeld, want de rekeningen verschillen.
        let all = try overview()
        #expect(all.cancelledPairs.isEmpty)
        #expect(all.entries.count == 3)
        // Per rekening bekeken ook niet.
        #expect(try overview(f.spaar).entries.map(\.label) == ["Op rekening 1", "Rente"])
        #expect(try overview(second).entries.map(\.label) == ["Op rekening 2"])
        // Een betaalrekening telt nooit mee.
        try add("2027-03-05", eur(-100), "Betaal", account: f.betaal)
        #expect(try overview().entries.count == 3)
    }
}
