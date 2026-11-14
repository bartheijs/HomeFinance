import Foundation
import GRDB
import HFCore
import Testing
@testable import HFInsight

private let today = Fixture.today

/// Maandbalans van de fixture (2027):
///   Salaris +3000 per maand
///   Huur −1200 · Energie −150 · Verzekering −300 per kwartaal (4×) = −100 per maand ·
///   RESERVERINGEN −250 (som RES-regels) · Lening −200 · Wegenbelasting −90 per jaar (1×) = −7,50 per maand
///   uitgaven −1907,50 per maand · overschot 1092,50 per maand
///   per jaar: 36000 − (14400 + 1800 + 1200 + 3000 + 2400 + 90 = 22890) = 13110
@Suite struct PlanBalanceTests {
    let f: Fixture
    init() throws { f = try Fixture() }

    private func balance() throws -> PlanBalance { try f.db.read { try Insight.planBalance($0, year: 2027) } }
    private func scenario(_ item: Int64, _ amount: Int64?) throws {
        try f.db.write { db in
            try db.execute(sql: "UPDATE budgetItem SET scenarioAmount = ? WHERE id = ?", arguments: [amount.map { eur($0) }, item])
        }
    }

    @Test func planPerMonthAndTotals() throws {
        let b = try balance()
        // Eerst inkomsten, dan uitgaven, op sortOrder; RES-regels (Auto, Vakantie) doen niet mee.
        #expect(b.rows.map(\.label) == ["Salaris", "Huur", "Energie", "Verzekering", "RESERVERINGEN", "Lening", "Wegenbelasting"])
        #expect(b.incomeRows.map(\.label) == ["Salaris"])
        #expect(b.expenseRows.count == 6)
        let verzekering = try #require(b.rows.first { $0.id == f.verzekering })
        #expect(verzekering.frequency == .kwartaal)
        #expect(verzekering.timesPerYear == 4)
        #expect(verzekering.plan == eur(-300))
        #expect(verzekering.planPerMonth == eur(-100))          // −300 × 4 ÷ 12
        #expect(verzekering.scenario == nil)
        #expect(verzekering.scenarioPerMonth == nil)
        #expect(verzekering.difference == nil)
        let weg = try #require(b.rows.first { $0.id == f.wegenbelasting })
        #expect(weg.timesPerYear == 1)
        #expect(weg.planPerMonth == eur(-7, 50))                // −90 ÷ 12
        let res = try #require(b.rows.first { $0.id == f.reserveringen })
        #expect(res.isReserveTotal)
        #expect(res.plan == eur(-250))
        #expect(res.planPerMonth == eur(-250))

        #expect(!b.hasScenario)
        #expect(b.plan == PlanBalanceTotals(income: eur(3000), expenses: eur(-1907, 50), surplus: eur(1092, 50)))
        #expect(b.scenario == b.plan)                           // niets ingevuld: variant = plan
        #expect(b.difference == PlanBalanceTotals(income: .zero, expenses: .zero, surplus: .zero))
        #expect(b.planYear == PlanBalanceTotals(income: eur(36000), expenses: eur(-22890), surplus: eur(13110)))
        #expect(b.scenarioYear == b.planYear)
    }

    @Test func quarterlyAmountIsRoundedToCents() throws {
        try f.db.write { db in
            let yearId = try Int64.fetchOne(db, sql: "SELECT id FROM budgetYear WHERE year = 2027")!
            var item = BudgetItem(yearId: yearId, label: "Abonnement", direction: .UIT, planAmount: eur(-100),
                                  frequency: .kwartaal, expectedMonths: "1,4,7,10", sortOrder: 30)
            try item.insert(db)
        }
        let b = try balance()
        let row = try #require(b.rows.last)
        #expect(row.label == "Abonnement")
        #expect(row.planPerMonth == eur(-33, 33))               // −400 ÷ 12 = −33,333…
        #expect(b.plan.expenses == eur(-1940, 83))              // −1907,50 − 33,33
        #expect(b.planYear.expenses == eur(-23290))             // per jaar zonder afronding: −22890 − 400
    }

    @Test func whatIfOnOneSalary() throws {
        try scenario(f.salaris, 2400)
        let b = try balance()
        // Loon 2400 in plaats van 3000: overschot 2400 − 1907,50 = 492,50 per maand, 600 minder.
        #expect(b.hasScenario)
        let salaris = try #require(b.rows.first)
        #expect(salaris.scenario == eur(2400))
        #expect(salaris.scenarioPerMonth == eur(2400))
        #expect(salaris.difference == eur(-600))
        #expect(b.rows.dropFirst().allSatisfy { $0.scenario == nil })
        #expect(b.plan.surplus == eur(1092, 50))
        #expect(b.scenario == PlanBalanceTotals(income: eur(2400), expenses: eur(-1907, 50), surplus: eur(492, 50)))
        #expect(b.difference == PlanBalanceTotals(income: eur(-600), expenses: .zero, surplus: eur(-600)))
        #expect(b.scenarioYear == PlanBalanceTotals(income: eur(28800), expenses: eur(-22890), surplus: eur(5910)))
        #expect(b.differenceYear.surplus == eur(-7200))
    }

    @Test func whatIfOnQuarterlyItemAndReserveLine() throws {
        try scenario(f.verzekering, -360)       // per kwartaal: −120 per maand, 20 duurder
        try scenario(f.resAuto, -50)            // RES-regel Auto 50 in plaats van 100: RESERVERINGEN −200
        let b = try balance()
        let verzekering = try #require(b.rows.first { $0.id == f.verzekering })
        #expect(verzekering.scenarioPerMonth == eur(-120))
        #expect(verzekering.difference == eur(-20))
        let res = try #require(b.rows.first { $0.id == f.reserveringen })
        #expect(res.scenario == eur(-200))      // −50 + −150
        #expect(res.difference == eur(50))
        #expect(b.difference.surplus == eur(30))                // −20 + 50
        #expect(b.scenario.surplus == eur(1122, 50))
        #expect(b.differenceYear.surplus == eur(360))           // −240 + 600
    }

    @Test func missingYear() throws {
        #expect(throws: InsightError.yearNotFound(2031)) { try f.db.read { try Insight.planBalance($0, year: 2031) } }
    }
}

@Suite struct GoalPartTests {
    @Test func goalFromParts() throws {
        let f = try Fixture()
        try f.db.write { db in
            // Rijbewijs: 30 lessen × 55 = 1650 + examen 300 = 1950.
            var lessons = GoalPart(potId: f.potKind, label: "Rijlessen", quantity: 30, unitAmount: eur(55), sortOrder: 1)
            try lessons.insert(db)
            var exam = GoalPart(potId: f.potKind, label: "Examen", unitAmount: eur(300), sortOrder: 2)
            try exam.insert(db)
            try db.execute(sql: "UPDATE pot SET targetAmount = ? WHERE id = ?", arguments: [eur(1950), f.potKind])
        }
        try f.db.read { db in
            let g = try #require(try Insight.potGoal(db, potId: f.potKind, today: today))
            #expect(g.parts.map(\.label) == ["Rijlessen", "Examen"])
            #expect(g.parts.map(\.quantity) == [30, 1])
            #expect(g.parts.map(\.unitAmount) == [eur(55), eur(300)])
            #expect(g.parts.map(\.amount) == [eur(1650), eur(300)])
            #expect(g.partsTotal == eur(1950))
            #expect(g.remaining == eur(1925))
            // Zonder onderdelen blijft het doel werken.
            let auto = try #require(try Insight.potGoal(db, potId: f.potAuto, today: today))
            #expect(auto.parts.isEmpty)
            #expect(auto.partsTotal == .zero)
            #expect(auto.targetAmount == eur(2400))
            // In de pottenlijst zitten de onderdelen ook.
            let pots = try Insight.potOverview(db, today: today).accounts[0].pots
            #expect(pots[2].goal?.partsTotal == eur(1950))
        }
    }
}

/// Projecten in pot Vakantie:
///   "Zomer 2027":  1-3 Borg −50 (open, over tijd) · 1-4 Aanbetaling −300 (afgevinkt, echte boeking −310) ·
///                  1-5 Vlucht −200 (afgevinkt zonder boeking) · 1-7 Huisje −900 (open)
///                  gepland −1450 · betaald −310 − 200 = −510 · nog te komen −50 − 900 = −950
///   "Winter 2028": 10-1-2028 Skipas −500 (open)
///   zonder project: 1-6 Vakantiegeld +400
@Suite struct ForecastProjectTests {
    let f: Fixture
    init() throws {
        f = try Fixture()
        try f.db.write { db in
            var paid = Entry(accountId: f.spaar, day: d("2027-04-02"), amount: eur(-310), label: "Aanbetaling huisje", potId: f.potVakantie)
            try paid.insert(db)
            let done = Date(timeIntervalSince1970: 1_800_000_000)
            let rows: [(String, Int64, String, String, Int64?, Date?)] = [
                ("2027-03-01", -50, "Borg", "Zomer 2027", nil, nil),
                ("2027-04-01", -300, "Aanbetaling", "Zomer 2027", paid.id, done),
                ("2027-05-01", -200, "Vlucht", "Zomer 2027", nil, done),
                ("2027-07-01", -900, "Huisje", " Zomer 2027 ", nil, nil),
                ("2028-01-10", -500, "Skipas", "Winter 2028", nil, nil),
                ("2027-06-01", 400, "Vakantiegeld", "", nil, nil),
            ]
            for (day, amount, label, project, entry, realizedAt) in rows {
                var i = ForecastItem(potId: f.potVakantie, day: d(day), amount: eur(amount), label: label,
                                     realizedEntryId: entry, realizedAt: realizedAt, project: project)
                try i.insert(db)
            }
        }
    }

    @Test func projectsWithPartlyPaidLines() throws {
        let projects = try f.db.read { try Insight.forecastProjects($0, potId: f.potVakantie, today: today) }
        #expect(projects.map(\.name) == ["Winter 2028", "Zomer 2027"])      // nieuwste eerst
        let zomer = projects[1]
        #expect(zomer.items.map(\.item.label) == ["Borg", "Aanbetaling", "Vlucht", "Huisje"])
        #expect(zomer.items.map(\.realizedAmount) == [nil, eur(-310), eur(-200), nil])
        #expect(zomer.planned == eur(-1450))
        #expect(zomer.realized == eur(-510))
        #expect(zomer.remaining == eur(-950))
        #expect(zomer.count == 4)
        #expect(zomer.openCount == 2)
        #expect(zomer.overdueCount == 1)
        #expect(zomer.firstDay == d("2027-03-01"))
        #expect(zomer.lastDay == d("2027-07-01"))
        let winter = projects[0]
        #expect(winter.planned == eur(-500))
        #expect(winter.realized == .zero)
        #expect(winter.remaining == eur(-500))
        #expect(winter.overdueCount == 0)
        try #expect(f.db.read { try Insight.forecastProjects($0, potId: f.potAuto, today: today) }.isEmpty)
    }

    @Test func eventsCarryTheirProject() throws {
        let p = try f.db.read { try Insight.potForecast($0, potId: f.potVakantie, today: today, until: d("2027-12-31")) }
        // De echte boeking van −310 op 2-4 ligt na de peildag en telt nog niet: het saldo is 100.
        #expect(p.startBalance == eur(100))
        #expect(p.events.map(\.label) == ["Vakantiegeld", "Huisje"])
        #expect(p.events.map(\.project) == [nil, "Zomer 2027"])
        #expect(p.events.map(\.balanceAfter) == [eur(500), eur(-400)])
        #expect(p.overdue.map(\.label) == ["Borg"])
    }
}
