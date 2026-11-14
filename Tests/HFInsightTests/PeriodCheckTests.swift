import Foundation
import GRDB
import HFCore
import Testing
@testable import HFInsight

private let today = Fixture.today

private func insert(_ f: Fixture, _ day: String, _ amount: Int64, _ label: String, item: Int64? = nil,
                    period: String? = nil, account: Int64? = nil, pot: Int64? = nil, note: String = "") throws {
    try f.db.write { db in
        var e = Entry(accountId: account ?? f.betaal, day: d(day), amount: eur(amount), label: label,
                      budgetItemId: item, potId: pot, note: note, period: period)
        try e.insert(db)
    }
}

/// Begrotingsmaand: het salaris van december komt al op 28 november binnen (periode "2027-12").
/// Het telt in december voor grid en status, maar staat vanaf 28 november op de rekening.
@Suite struct PeriodTests {
    let f: Fixture
    init() throws {
        f = try Fixture()
        try insert(f, "2027-11-28", 3000, "Salaris december", item: f.salaris, period: "2027-12")
    }

    @Test func gridAndStatusFollowPeriod() throws {
        let day = d("2027-12-05")
        let g = try f.db.read { try Insight.monthGrid($0, year: 2027, today: day) }
        let salaris = try #require(g.rows.first { $0.id == f.salaris })
        #expect(salaris.cells[10].status == .teLaat)        // november: niets geboekt
        #expect(salaris.cells[10].sum == .zero)
        #expect(salaris.cells[11].status == .gelijk)        // december: +3000
        #expect(salaris.cells[11].entryCount == 1)
        #expect(g.monthTotals[10].result == .zero)
        #expect(g.monthTotals[11].result == eur(3000))

        let nov = try f.db.read { try Insight.fixedItemsStatus($0, year: 2027, month: 11, today: day) }
        #expect(nov.items.first { $0.id == f.salaris }?.state == .teLaat)
        let dec = try f.db.read { try Insight.fixedItemsStatus($0, year: 2027, month: 12, today: day) }
        let s = try #require(dec.items.first { $0.id == f.salaris })
        #expect(s.state == .voldaan)
        #expect(s.day == d("2027-11-28"))                   // de echte datum
        #expect(s.actual == eur(3000))
    }

    @Test func balanceFollowsDay() throws {
        try f.db.read { db in
            // 3540 (stand na maart) + 3000 op 28 november
            try #expect(Insight.balance(db, accountId: f.betaal, on: d("2027-11-27")) == eur(3540))
            try #expect(Insight.balance(db, accountId: f.betaal, on: d("2027-11-30")) == eur(6540))
            let series = try Insight.balanceSeries(db, accountId: f.betaal, from: d("2027-11-01"), to: d("2027-12-31"), step: .monthEnd)
            #expect(series.map(\.balance) == [eur(6540), eur(6540)])
        }
    }

    @Test func simulationUsesPeriod() throws {
        // 29 november: het salaris van november is nog niet geboekt (de boeking van de 28e hoort bij december).
        let nov = try f.db.read { try Insight.spendable($0, year: 2027, today: d("2027-11-29")) }
        #expect(nov.balance == eur(6540))
        #expect(nov.expectedItems.map(\.label) == ["Salaris", "Huur", "Energie", "RESERVERINGEN", "Lening"])
        // 5 december: salaris is al binnen; nog verwacht: Huur −1200, Energie −150, RESERVERINGEN −250, Lening −200.
        let dec = try f.db.read { try Insight.spendable($0, year: 2027, today: d("2027-12-05")) }
        #expect(dec.expectedItems.map(\.label) == ["Huur", "Energie", "RESERVERINGEN", "Lening"])
        #expect(dec.expectedTotal == eur(-1800))
    }

    @Test func drillDownSearchAndReports() throws {
        try f.db.read { db in
            let cell = try Insight.cellEntries(db, itemId: f.salaris, year: 2027, month: 12)
            #expect(cell.map(\.label) == ["Salaris december"])
            #expect(cell[0].period == "2027-12")
            #expect(cell[0].day.month == 11)
            #expect((cell[0].budgetYear, cell[0].budgetMonth) == (2027, 12))
            try #expect(Insight.cellEntries(db, itemId: f.salaris, year: 2027, month: 11).isEmpty)

            // Jaar/maand filtert op begrotingsmaand, van/tot op de datum.
            try #expect(Insight.searchEntries(db, filter: EntryFilter(year: 2027, month: 12)).totalSum == eur(3000))
            try #expect(Insight.searchEntries(db, filter: EntryFilter(year: 2027, month: 11)).totalCount == 0)
            try #expect(Insight.searchEntries(db, filter: EntryFilter(from: d("2027-11-01"), to: d("2027-11-30"))).totalCount == 1)

            let months = try Insight.monthlyResults(db, year: 2027)
            #expect(months[10].income == .zero)
            #expect(months[11].income == eur(3000))

            let bva = try Insight.budgetVsActual(db, year: 2027, today: d("2027-12-05"))
            let salaris = try #require(bva.first { $0.id == f.salaris })
            #expect(salaris.actualToDate == eur(9000))      // jan, feb, dec
            #expect(salaris.planToDate == eur(36000))

            let dash = try Insight.dashboard(db, today: d("2027-12-05"))
            #expect(dash.monthIncome == eur(3000))
            #expect(try Insight.dashboard(db, today: d("2027-11-29")).monthIncome == .zero)
        }
    }

    @Test func entryWithoutPeriodUsesDay() throws {
        let row = try #require(try f.db.read { try Insight.cellEntries($0, itemId: f.huur, year: 2027, month: 3) }.first)
        #expect(row.period == nil)
        #expect((row.budgetYear, row.budgetMonth) == (2027, 3))
    }
}

/// Over de jaargrens:
///   29-12-2026  Vroege teruggave +50, periode 2027-01  (telt in 2027, staat in 2026 op de rekening)
///   30-12-2027  Vooruitbetaald −100, periode 2028-01   (telt in 2028, gaat in 2027 van de rekening)
/// Jaaroverzicht 2027 (peildag in 2028): IN 6060 + 50 = 6110 · UIT −5520
///   op de rekening 31-12 = 3000 + 50 + 540 − 100 = 3490 · op 1-1 = 3050
///   verschoven = (6110 − 5520) − (540 − 100) = 150 · 3050 + 6110 − 5520 − 150 = 3490
@Suite struct PeriodYearBoundaryTests {
    let f: Fixture
    init() throws {
        f = try Fixture()
        try insert(f, "2026-12-29", 50, "Vroege teruggave", period: "2027-01")
        try insert(f, "2027-12-30", -100, "Vooruitbetaald", period: "2028-01")
    }

    @Test func yearSummaryIsClosing() throws {
        let y = try f.db.read { try Insight.yearSummary($0, year: 2027, today: d("2028-02-01")) }
        #expect(y.income == eur(6110))
        #expect(y.expenses == eur(-5520))
        #expect(y.balance == eur(3490))
        #expect(y.openingBalance == eur(3050))
        #expect(y.shiftedAcrossYear == eur(150))
        #expect(y.openingBalance + y.income + y.expenses - y.shiftedAcrossYear == y.balance)
        #expect(y.inDivers == eur(110))
    }

    @Test func yearSummaryWithoutShiftIsZero() throws {
        let plain = try Fixture()
        let y = try plain.db.read { try Insight.yearSummary($0, year: 2027, today: today) }
        #expect(y.shiftedAcrossYear == .zero)
        #expect(y.openingBalance == eur(3000))
    }

    @Test func gridAndYearsFollowPeriod() throws {
        try f.db.read { db in
            let g = try Insight.monthGrid(db, year: 2027, today: d("2028-02-01"))
            #expect(g.monthTotals[0].inDivers == eur(90))   // 40 + 50
            #expect(g.monthTotals[11].uitDivers == .zero)   // de −100 hoort bij 2028
            #expect(g.yearTotals.result == eur(590))        // 540 + 50

            let inn = try Insight.diversEntries(db, year: 2027, month: 1, positive: true)
            #expect(inn.map(\.label) == ["Vroege teruggave", "Marktplaats"])

            let years = try Insight.yearOverYear(db)
            #expect(years.map(\.year) == [2027, 2028])
            #expect(years[0].income == eur(6110))
            #expect(years[0].expenses == eur(-5520))
            #expect(years[1].expenses == eur(-100))

            let next = try Insight.searchEntries(db, filter: EntryFilter(year: 2028))
            #expect(next.rows.map(\.label) == ["Vooruitbetaald"])
            #expect(next.rows[0].budgetYear == 2028)
            #expect(next.rows[0].budgetMonth == 1)
            try #expect(Insight.labelYears(db, label: "vooruitbetaald") == [LabelYear(year: 2028, count: 1, total: eur(-100))])
            try #expect(Insight.labelTotals(db, year: 2027, today: d("2028-02-01"), filter: LabelFilter(minCount: 1, text: "vroege"))
                .first?.months[0] == eur(50))
            try #expect(Insight.topDiversExpenses(db, year: 2028).map(\.amount) == [eur(-100)])
        }
    }
}

/// Afvinken: Energie februari (niets geboekt), Huur januari (geboekt, gelijk), Energie januari (geboekt, afwijkend),
/// Lening maart (niets geboekt, lopende maand).
@Suite struct CheckTests {
    let f: Fixture
    init() throws {
        f = try Fixture()
        try f.db.write { db in
            for (item, month) in [(f.energie, 2), (f.huur, 1), (f.energie, 1), (f.lening, 3)] {
                var c = ItemCheck(budgetItemId: item, month: month, note: "contant betaald")
                try c.insert(db)
            }
        }
    }

    @Test func gridCells() throws {
        let g = try f.db.read { try Insight.monthGrid($0, year: 2027, today: today) }
        let energie = try #require(g.rows.first { $0.id == f.energie })
        #expect(energie.cells[1].status == .afgevinkt)      // was teLaat
        #expect(energie.cells[1].isChecked)
        #expect(energie.cells[1].sum == .zero)
        #expect(energie.cells[0].status == .afwijkend)      // met boeking: gewone status
        #expect(energie.cells[0].isChecked)
        #expect(energie.cells[2].status == .open)
        #expect(!energie.cells[2].isChecked)
        let huur = try #require(g.rows.first { $0.id == f.huur })
        #expect(huur.cells[0].status == .gelijk)
        #expect(huur.cells[0].isChecked)
        #expect(!huur.cells[1].isChecked)
        #expect(try #require(g.rows.first { $0.id == f.lening }).cells[2].status == .afgevinkt)
        // Totalen veranderen niet door afvinken.
        #expect(g.monthTotals[1].fixed == eur(1300))
    }

    @Test func fixedItemsCountCheckedAsPaid() throws {
        let feb = try f.db.read { try Insight.fixedItemsStatus($0, year: 2027, month: 2, today: today) }
        let energie = try #require(feb.items.first { $0.id == f.energie })
        #expect(energie.state == .voldaan)
        #expect(energie.isChecked)
        #expect(energie.actual == .zero)
        #expect(energie.entryCount == 0)
        #expect((feb.paidCount, feb.openCount, feb.lateCount) == (5, 0, 0))
        #expect(feb.outstandingTotal == .zero)

        // Maart: Huur geboekt, Lening afgevinkt; open: Salaris en Energie; te laat: RESERVERINGEN.
        let mrt = try f.db.read { try Insight.fixedItemsStatus($0, year: 2027, month: 3, today: today) }
        #expect((mrt.paidCount, mrt.openCount, mrt.lateCount) == (2, 2, 1))
        #expect(mrt.outstandingTotal == eur(2600))          // 3000 − 150 − 250
        let jan = try f.db.read { try Insight.fixedItemsStatus($0, year: 2027, month: 1, today: today) }
        #expect(jan.items.filter(\.isChecked).map(\.label) == ["Huur", "Energie"])
    }

    @Test func checkedItemIsNotExpectedAnymore() throws {
        let s = try f.db.read { try Insight.spendable($0, year: 2027, today: today) }
        // Zonder afvinken +2400; Lening (−200) is afgevinkt: 3000 − 150 − 250 = +2600.
        #expect(s.expectedItems.map(\.label) == ["Salaris", "Energie", "RESERVERINGEN"])
        #expect(s.expectedTotal == eur(2600))
        let dash = try f.db.read { try Insight.dashboard($0, today: today) }
        #expect((dash.paidCount, dash.openCount, dash.lateCount) == (2, 2, 1))
    }

    @Test func checkedMonthIsNotUnderBudget() throws {
        let rows = try f.db.read { try Insight.budgetVsActual($0, year: 2027, today: today) }
        let energie = try #require(rows.first { $0.id == f.energie })
        #expect((energie.monthsOver, energie.monthsUnder) == (1, 0))   // februari telt niet meer als "minder"
    }
}

/// Vaste stortingen op de spaarrekening:
///   Maandstorting: Auto 100 + Vakantie 150 = 250, gekoppeld aan RESERVERINGEN (plan −250) → gelijk
///   Kinderspaar:   Kind A 25 + Auto 10 = 35, gekoppeld aan "Sparen kind" (plan −30) → wijkt af
///   Oud (gearchiveerd): Auto 500, geen post
@Suite struct DistributionTests {
    let f: Fixture
    var d1: Int64 = 0, d2: Int64 = 0, d3: Int64 = 0

    init() throws {
        f = try Fixture()
        try f.db.write { db in
            func make(_ name: String, _ order: Int, archived: Bool = false, _ lines: [(Int64, Int64)]) throws -> Int64 {
                var dist = Distribution(name: name, accountId: f.spaar, sortOrder: order, archived: archived)
                try dist.insert(db)
                for (i, (pot, amount)) in lines.enumerated() {
                    var l = DistributionLine(distributionId: dist.id!, potId: pot, amount: eur(amount), sortOrder: i)
                    try l.insert(db)
                }
                return dist.id!
            }
            d1 = try make("Maandstorting", 1, [(f.potAuto, 100), (f.potVakantie, 150)])
            d2 = try make("Kinderspaar", 2, [(f.potKind, 25), (f.potAuto, 10)])
            d3 = try make("Oud", 3, archived: true, [(f.potAuto, 500)])
            try db.execute(sql: "UPDATE budgetItem SET distributionId = ? WHERE id = ?", arguments: [d1, f.reserveringen])
            let yearId = try Int64.fetchOne(db, sql: "SELECT id FROM budgetYear WHERE year = 2027")!
            var item = BudgetItem(yearId: yearId, label: "Sparen kind", direction: .UIT, planAmount: eur(-30),
                                  sortOrder: 20, distributionId: d2)
            try item.insert(db)
        }
    }

    @Test func summaries() throws {
        let list = try f.db.read { try Insight.distributions($0, today: today) }
        #expect(list.map(\.name) == ["Maandstorting", "Kinderspaar", "Oud"])
        let a = list[0]
        #expect(a.accountName == "Spaarrekening")
        #expect(a.lines.map(\.potName) == ["Auto", "Vakantie"])
        #expect(a.lines.map(\.amount) == [eur(100), eur(150)])
        #expect(a.total == eur(250))
        #expect(a.item?.label == "RESERVERINGEN")
        #expect(a.item?.plan == eur(-250))
        #expect(a.planMatchesTotal == true)
        let b = list[1]
        #expect(b.total == eur(35))
        #expect(b.item?.plan == eur(-30))
        #expect(b.planMatchesTotal == false)
        let c = list[2]
        #expect(c.archived)
        #expect(c.item == nil)
        #expect(c.planMatchesTotal == nil)
        // In een jaar zonder begroting is er geen gekoppelde post.
        let later = try f.db.read { try Insight.distributions($0, today: d("2029-01-01")) }
        #expect(later.allSatisfy { $0.item == nil })
    }

    @Test func usageAndPotAmount() throws {
        try f.db.read { db in
            let usage = try Insight.distributionUsage(db, potId: f.potAuto)
            #expect(usage.map(\.name) == ["Maandstorting", "Kinderspaar", "Oud"])
            #expect(usage.map(\.amount) == [eur(100), eur(10), eur(500)])
            #expect(usage.map(\.distributionTotal) == [eur(250), eur(35), eur(500)])
            #expect(usage.map(\.archived) == [false, false, true])
            try #expect(Insight.distributionUsage(db, potId: f.potVakantie).map(\.id) == [d1])

            let pots = try #require(try Insight.potOverview(db, today: today).accounts.first).pots
            // Auto: 100 + 10 (de gearchiveerde 500 telt niet) · Vakantie 150 · Kind A 25
            #expect(pots.map(\.distributionAmount) == [eur(110), eur(150), eur(25)])
            #expect(pots.map(\.monthlyAmount) == [eur(100), eur(150), eur(25)])
        }
    }
}

/// Beginstand van een tweede spaarrekening: beginsaldo 200 op de rekening zelf, beginboekingen ("Beginsaldo")
/// Fiets 1000, Reis 500 en 300 zonder pot; totaal 2000 = potten 1500 + niet toegewezen 500.
@Suite struct OpeningTests {
    @Test func openingOverview() throws {
        let f = try Fixture()
        var account: Int64 = 0, fiets: Int64 = 0, reis: Int64 = 0
        try f.db.write { db in
            var a = Account(name: "Spaarrekening 2", iban: "NL00TEST0000000003", kind: .spaar,
                            openingBalance: eur(200), openingDate: d("2027-01-01"), sortOrder: 3)
            try a.insert(db); account = a.id!
            var p1 = Pot(accountId: account, name: "Fiets", kind: .spaar, sortOrder: 1)
            try p1.insert(db); fiets = p1.id!
            var p2 = Pot(accountId: account, name: "Reis", kind: .spaar, sortOrder: 2)
            try p2.insert(db); reis = p2.id!
        }
        try insert(f, "2027-01-01", 1000, "Beginsaldo Fiets", account: account, pot: fiets, note: "Beginsaldo")
        try insert(f, "2027-01-01", 500, "Beginsaldo Reis", account: account, pot: reis, note: "Beginsaldo")
        try insert(f, "2027-01-01", 300, "Beginsaldo overig", account: account, note: "Beginsaldo")
        try insert(f, "2027-02-01", 50, "Storting Fiets", account: account, pot: fiets)

        try f.db.read { db in
            let o = try Insight.openingOverview(db, accountId: account)
            #expect(o.accountName == "Spaarrekening 2")
            #expect(o.accountOpeningBalance == eur(200))
            #expect(o.pots.map(\.potName) == ["Fiets", "Reis"])
            #expect(o.pots.map(\.amount) == [eur(1000), eur(500)])   // de storting van 50 is geen beginboeking
            #expect(o.potTotal == eur(1500))
            #expect(o.unallocated == eur(500))                       // 200 + 300
            #expect(o.total == eur(2000))
            #expect(o.total == o.potTotal + o.unallocated)
            // Sluit aan op het saldo: begin 2000 + storting 50.
            try #expect(Insight.balance(db, accountId: account, on: today) == eur(2050))

            // Rekening zonder beginboekingen: alles is niet toegewezen.
            let plain = try Insight.openingOverview(db, accountId: f.spaar)
            #expect(plain.pots.isEmpty)
            #expect(plain.unallocated == eur(5000))
            #expect(plain.total == eur(5000))
            #expect(throws: InsightError.accountNotFound(999)) { try Insight.openingOverview(db, accountId: 999) }
        }
    }
}
