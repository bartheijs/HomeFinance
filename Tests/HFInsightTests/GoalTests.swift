import Foundation
import GRDB
import HFCore
import Testing
@testable import HFInsight

private let today = Fixture.today   // 15 maart 2027

/// Spaardoel per pot. Spaarpot Kind A staat op 25,00 (één storting van 25 op 10-1-2027).
/// Met de vaste storting "Kinderspaar" (25 per maand) zijn de stortmomenten na 15 maart:
/// 16-3 (maart is nog niet binnen en de 10e is voorbij), 10-4, 10-5, 10-6, …
@Suite struct GoalTests {
    let f: Fixture
    init() throws { f = try Fixture() }

    private func setGoal(_ pot: Int64, _ amount: Int64?, _ date: String?) throws {
        try f.db.write { db in
            try db.execute(sql: "UPDATE pot SET targetAmount = ?, targetDate = ? WHERE id = ?",
                           arguments: [amount.map { eur($0) }, date, pot])
        }
    }

    private func kinderspaar() throws -> Int64 {
        try f.db.write { db in
            var dist = Distribution(name: "Kinderspaar", accountId: f.spaar)
            try dist.insert(db)
            var line = DistributionLine(distributionId: dist.id!, potId: f.potKind, amount: eur(25))
            try line.insert(db)
            return dist.id!
        }
    }

    private func item(_ day: String, _ amount: Int64, _ label: String) throws {
        try f.db.write { db in
            var i = ForecastItem(potId: f.potKind, day: d(day), amount: eur(amount), label: label)
            try i.insert(db)
        }
    }

    private func goal(_ pot: Int64, today day: Day = today) throws -> PotGoal? {
        try f.db.read { try Insight.potGoal($0, potId: pot, today: day) }
    }

    /// Een klein tekort binnen de marge (standaard 0,5 % van het doel) telt als op koers; met marge 0 % niet.
    @Test func smallShortfallWithinMarginIsOnTrack() throws {
        _ = try kinderspaar()
        try f.db.write { db in
            try db.execute(sql: "UPDATE pot SET targetAmount = ?, targetDate = ? WHERE id = ?",
                           arguments: [eur(150, 50), d("2027-07-31"), f.potKind])
        }
        // Verwacht op de doeldatum: 25 + 5 × 25 = 150,00; 0,50 tekort. Marge 0,5 % van 150,50 = 0,75.
        let g = try #require(try goal(f.potKind))
        #expect(g.projectedOnTargetDate == eur(150))
        #expect(g.margin == eur(0, 75))
        #expect(g.status == .opKoers)
        #expect(g.isWithinMargin)
        #expect(g.shortfallPerMonth == eur(0, 10))   // het tekort per maand blijft gewoon zichtbaar
        try f.db.write { try GoalMargin.setBasisPoints($0, 0) }
        let strict = try #require(try goal(f.potKind))
        #expect(strict.status == .tekort)
        #expect(!strict.isWithinMargin)
        #expect(GoalMargin.text(50) == "0,5 %")
        #expect(GoalMargin.text(100) == "1 %")
        #expect(GoalMargin.text(25) == "0,25 %")
    }

    @Test func noTargetAmountGivesNil() throws {
        #expect(try goal(f.potVakantie) == nil)
        #expect(throws: InsightError.potNotFound(999)) { try f.db.read { try Insight.potGoal($0, potId: 999, today: today) } }
    }

    @Test func alreadyReached() throws {
        try setGoal(f.potAuto, 150, "2027-12-31")           // saldo Auto is 200
        let g = try #require(try goal(f.potAuto))
        #expect(g.status == .bereikt)
        #expect(g.balance == eur(200))
        #expect(g.remaining == .zero)
        #expect(g.requiredPerMonth == .zero)
        #expect(g.projectedReachDate == today)
    }

    @Test func onTrackWithRecurringDepositOnly() throws {
        _ = try kinderspaar()
        try setGoal(f.potKind, 150, "2027-07-31")
        let g = try #require(try goal(f.potKind))
        // Nog 125 nodig; stortmomenten 16-3, 10-4, 10-5, 10-6, 10-7 = 5 → 25,00 per maand; er gaat 25,00 per maand heen.
        #expect(g.targetAmount == eur(150))
        #expect(g.targetDate == d("2027-07-31"))
        #expect(g.remaining == eur(125))
        #expect(g.expectedOneOffs == .zero)
        #expect(g.monthsLeft == 5)
        #expect(g.requiredPerMonth == eur(25))
        #expect(g.currentPerMonth == eur(25))
        #expect(g.shortfallPerMonth == .zero)
        #expect(g.projectedOnTargetDate == eur(150))        // 25 + 5 × 25
        #expect(g.status == .opKoers)
        #expect(g.projectedReachDate == d("2027-07-10"))
    }

    @Test func shortfall() throws {
        _ = try kinderspaar()
        try setGoal(f.potKind, 1000, "2027-12-31")
        let g = try #require(try goal(f.potKind))
        // Nog 975 nodig; 16-3 en de 10e van april t/m december = 10 momenten → 97,50; nu 25,00 → 72,50 te weinig.
        #expect(g.remaining == eur(975))
        #expect(g.monthsLeft == 10)
        #expect(g.requiredPerMonth == eur(97, 50))
        #expect(g.shortfallPerMonth == eur(72, 50))
        #expect(g.projectedOnTargetDate == eur(275))        // 25 + 10 × 25
        #expect(g.status == .tekort)
        // 975 ÷ 25 = 39 stortingen: de 1e op 16-3-2027, de 39e 38 maanden na maart 2027 = 10 mei 2030.
        #expect(g.projectedReachDate == d("2030-05-10"))
    }

    @Test func requiredAmountRoundsUp() throws {
        _ = try kinderspaar()
        try setGoal(f.potKind, 125, "2027-05-31")
        let g = try #require(try goal(f.potKind))
        // Nog 100 nodig in 3 momenten (16-3, 10-4, 10-5): 33,333… → 33,34; tekort 8,34 per maand.
        #expect(g.monthsLeft == 3)
        #expect(g.requiredPerMonth == eur(33, 34))
        #expect(g.shortfallPerMonth == eur(8, 34))
        #expect(g.projectedOnTargetDate == eur(100))
        #expect(g.status == .tekort)
    }

    @Test func expectedGiftLowersMonthlyAmount() throws {
        _ = try kinderspaar()
        try setGoal(f.potKind, 1000, "2027-12-31")
        try item("2027-06-01", 475, "Gift oma")
        try item("2027-09-01", -50, "Schoolreis")
        try item("2028-01-05", 100, "Na de doeldatum")      // telt niet
        try item("2027-03-01", 20, "Over tijd")             // telt niet (dag is al voorbij)
        let g = try #require(try goal(f.potKind))
        // Los verwacht 475 − 50 = 425 → (975 − 425) ÷ 10 = 55,00 per maand; tekort 30,00.
        #expect(g.expectedOneOffs == eur(425))
        #expect(g.requiredPerMonth == eur(55))
        #expect(g.shortfallPerMonth == eur(30))
        #expect(g.projectedOnTargetDate == eur(700))        // 25 + 250 + 425
        #expect(g.status == .tekort)

        // Een gift die groter is dan wat nog nodig is: niets meer nodig per maand, ruimte over.
        try item("2027-07-01", 600, "Erfenis")
        let rich = try #require(try goal(f.potKind))
        #expect(rich.requiredPerMonth == .zero)
        #expect(rich.shortfallPerMonth == eur(-25))
        #expect(rich.status == .opKoers)
        // 25 → 50 (16-3) → 75 (10-4) → 100 (10-5) → 575 (1-6) → 600 (10-6) → 1200 (1-7)
        #expect(rich.projectedReachDate == d("2027-07-01"))
    }

    @Test func targetDatePassed() throws {
        _ = try kinderspaar()
        try setGoal(f.potKind, 1000, "2027-03-01")
        let g = try #require(try goal(f.potKind))
        #expect(g.status == .verlopen)
        #expect(g.monthsLeft == 0)
        #expect(g.requiredPerMonth == nil)
        #expect(g.shortfallPerMonth == nil)
        #expect(g.projectedOnTargetDate == eur(25))
        #expect(g.remaining == eur(975))
        #expect(g.projectedReachDate == d("2030-05-10"))    // met de huidige storting alsnog
    }

    @Test func withoutTargetDate() throws {
        _ = try kinderspaar()                               // de fixture heeft doel 1000 zonder datum
        let g = try #require(try goal(f.potKind))
        #expect(g.status == .zonderDatum)
        #expect(g.targetDate == nil)
        #expect(g.monthsLeft == 0)
        #expect(g.requiredPerMonth == nil)
        #expect(g.projectedOnTargetDate == nil)
        #expect(g.currentPerMonth == eur(25))
        #expect(g.projectedReachDate == d("2030-05-10"))
    }

    @Test func withoutRecurringDeposit() throws {
        try setGoal(f.potKind, 1000, "2027-12-31")
        let g = try #require(try goal(f.potKind))
        // Geen vaste storting: stortmomenten op de 25e, maart t/m december = 10 → 97,50 per maand, alles is tekort.
        #expect(g.monthsLeft == 10)
        #expect(g.requiredPerMonth == eur(97, 50))
        #expect(g.currentPerMonth == .zero)
        #expect(g.shortfallPerMonth == eur(97, 50))
        #expect(g.projectedOnTargetDate == eur(25))
        #expect(g.status == .tekort)
        #expect(g.projectedReachDate == nil)                // wordt zo nooit gehaald
        // Op 26 maart is de 25e voorbij, maar in maart kan nog gestort worden: nog steeds 10 momenten.
        #expect(try #require(try goal(f.potKind, today: d("2027-03-26"))).monthsLeft == 10)
        // Op de laatste dag van maart niet meer: april t/m december = 9.
        #expect(try #require(try goal(f.potKind, today: d("2027-03-31"))).monthsLeft == 9)
    }

    @Test func potListAndForecastCarryTheGoal() throws {
        _ = try kinderspaar()
        try setGoal(f.potKind, 1000, "2027-12-31")
        try f.db.read { db in
            let pots = try Insight.potOverview(db, today: today).accounts[0].pots
            // Auto: doel 2400 zonder datum (fixture) · Vakantie: geen doel · Kind A: tekort van 72,50 per maand
            #expect(pots.map { $0.goal?.status } == [.zonderDatum, nil, .tekort])
            #expect(pots[2].targetDate == d("2027-12-31"))
            #expect(pots[2].goal?.shortfallPerMonth == eur(72, 50))
            #expect(pots[2].goal == (try Insight.potGoal(db, potId: f.potKind, today: today)))
            #expect(pots[0].goal?.remaining == eur(2200))
            #expect(pots[0].goal?.projectedReachDate == nil)

            let forecast = try Insight.potForecast(db, potId: f.potKind, today: today, until: d("2027-12-31"))
            #expect(forecast.targetAmount == eur(1000))
            #expect(forecast.targetDate == d("2027-12-31"))
            #expect(forecast.endBalance == eur(275))        // gelijk aan projectedOnTargetDate
            #expect(forecast.events.count == 10)
            let none = try Insight.potForecast(db, potId: f.potVakantie, today: today, until: d("2027-12-31"))
            #expect(none.targetAmount == nil)
            #expect(none.targetDate == nil)
        }
    }
}
