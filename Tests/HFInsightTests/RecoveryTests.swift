import Foundation
import GRDB
import HFCore
import Testing
@testable import HFInsight

private let today = Fixture.today   // 15 maart 2027

/// Potten in de min, bovenop de fixture (Auto 200, Vakantie 100, Kind A 25; niet toegewezen 5010):
///   Telefoon: −600 op 1-3-2027 (vooruit gekocht), vaste storting "Telefoon" 50 per maand, nog nooit gestort → de 25e
///   Zorg:     −300 op 1-3-2027, geen vaste storting
@Suite struct RecoveryTests {
    let f: Fixture
    var telefoon: Int64 = 0, zorg: Int64 = 0

    init() throws {
        f = try Fixture()
        try f.db.write { db in
            func pot(_ name: String, _ amount: Int64, order: Int) throws -> Int64 {
                var p = Pot(accountId: f.spaar, name: name, kind: .reservering, sortOrder: order)
                try p.insert(db)
                var e = Entry(accountId: f.spaar, day: d("2027-03-01"), amount: eur(amount), label: "Vooruit betaald", potId: p.id)
                try e.insert(db)
                return p.id!
            }
            telefoon = try pot("Telefoon", -600, order: 10)
            zorg = try pot("Zorg", -300, order: 11)
            var dist = Distribution(name: "Telefoon", accountId: f.spaar)
            try dist.insert(db)
            var line = DistributionLine(distributionId: dist.id!, potId: telefoon, amount: eur(50))
            try line.insert(db)
        }
    }

    private func pots() throws -> [PotSummary] {
        try f.db.read { try Insight.potOverview($0, today: today) }.accounts[0].pots
    }
    private func item(_ pot: Int64, _ day: String, _ amount: Int64) throws {
        try f.db.write { db in
            var i = ForecastItem(potId: pot, day: d(day), amount: eur(amount), label: "Verwacht")
            try i.insert(db)
        }
    }

    @Test func recoversAfterTwelveDeposits() throws {
        let r = try #require(try pots().first { $0.id == telefoon }?.recovery)
        // −600 + 12 × 50 = 0. Stortingen op de 25e: de 1e op 25-3-2027, de 12e 11 maanden later op 25-2-2028.
        #expect(r.shortfall == eur(600))
        #expect(r.perMonth == eur(50))
        #expect(r.recoveryDate == d("2028-02-25"))
        #expect(r.status == .herstelt)
        // Gelijk aan de vooruitblik: op 25-1-2028 nog −50, op 25-2-2028 precies 0.
        let p = try f.db.read { try Insight.potForecast($0, potId: telefoon, today: today, until: d("2028-03-31")) }
        #expect(p.balance(on: d("2028-01-25")) == eur(-50))
        #expect(p.balance(on: d("2028-02-25")) == .zero)
    }

    @Test func potWithoutDepositIsNotRefilled() throws {
        let r = try #require(try pots().first { $0.id == zorg }?.recovery)
        #expect(r.shortfall == eur(300))
        #expect(r.perMonth == .zero)
        #expect(r.recoveryDate == nil)
        #expect(r.status == .wordtNietAangevuld)
        // Een verwachting die het tekort niet oplost verandert daar niets aan.
        try item(zorg, "2027-05-01", 100)
        #expect(try pots().first { $0.id == zorg }?.recovery?.status == .wordtNietAangevuld)
        // Een verwachting die het wel oplost: hersteld op die dag, ook zonder vaste storting.
        try item(zorg, "2027-06-01", 200)
        let solved = try #require(try pots().first { $0.id == zorg }?.recovery)
        #expect(solved.status == .herstelt)
        #expect(solved.recoveryDate == d("2027-06-01"))
        #expect(solved.perMonth == .zero)
    }

    @Test func expectedDepositRecoversEarlier() throws {
        try item(telefoon, "2027-06-10", 400)
        let r = try #require(try pots().first { $0.id == telefoon }?.recovery)
        // −600 → −550 (25-3) → −500 (25-4) → −450 (25-5) → −50 (10-6, verwacht +400) → 0 (25-6)
        #expect(r.recoveryDate == d("2027-06-25"))
        #expect(r.status == .herstelt)
        #expect(r.shortfall == eur(600))
    }

    @Test func takesLongerThanTenYears() throws {
        try f.db.write { db in
            var e = Entry(accountId: f.spaar, day: d("2027-03-02"), amount: eur(-9400), label: "Grote uitgave", potId: telefoon)
            try e.insert(db)
        }
        let r = try #require(try pots().first { $0.id == telefoon }?.recovery)
        // −10.000 met 50 per maand = 200 maanden: meer dan 10 jaar.
        #expect(r.shortfall == eur(10000))
        #expect(r.recoveryDate == nil)
        #expect(r.status == .duurtLangerDan10Jaar)
    }

    @Test func overviewWithTwoNegativePots() throws {
        let o = try f.db.read { try Insight.potOverview($0, today: today) }
        let account = o.accounts[0]
        // Geleend van de andere potten: 600 + 300 = 900. Potten samen 325 − 900 = −575; saldo 5335 − 900 = 4435.
        #expect(account.borrowedFromOtherPots == eur(900))
        #expect(account.negativePotCount == 2)
        #expect(account.potTotal == eur(-575))
        #expect(account.balance == eur(4435))
        #expect(account.unallocated == eur(5010))
        #expect(o.borrowedFromOtherPots == eur(900))
        #expect(o.negativePotCount == 2)
        // Potten die niet in de min staan hebben geen herstel.
        #expect(account.pots.map { $0.recovery != nil } == [false, false, false, true, true])
        // Zonder negatieve potten: nul.
        let plain = try Fixture().db.read { try Insight.potOverview($0, today: today) }
        #expect(plain.borrowedFromOtherPots == .zero)
        #expect(plain.negativePotCount == 0)
        #expect(plain.accounts[0].pots.allSatisfy { $0.recovery == nil })
    }
}
