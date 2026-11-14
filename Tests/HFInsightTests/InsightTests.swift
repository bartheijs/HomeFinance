import Foundation
import GRDB
import HFCore
import Testing
@testable import HFInsight

private let today = Fixture.today

@Suite struct MonthGridTests {
    let f: Fixture
    init() throws { f = try Fixture() }

    private func grid() throws -> MonthGrid { try f.db.read { try Insight.monthGrid($0, year: 2027, today: today) } }
    private func row(_ id: Int64) throws -> GridRow { try #require(try grid().rows.first { $0.id == id }) }

    @Test func rowsFollowSortOrderAndFlagReserveLines() throws {
        let g = try grid()
        #expect(g.rows.map(\.label) == ["Salaris", "Huur", "Energie", "Verzekering", "RESERVERINGEN", "Auto",
                                        "Vakantie", "Lening", "Wegenbelasting"])
        #expect(g.rows.map(\.kind) == [.item, .item, .item, .item, .reserveTotal, .reserveLine, .reserveLine, .item, .item])
        #expect(g.rows.filter(\.isInformational).map(\.id) == [f.resAuto, f.resVakantie])
    }

    @Test func everyCellStatus() throws {
        // gelijk: Huur januari (−1200 = plan)
        let huur = try row(f.huur)
        #expect(huur.cells[0].status == .gelijk)
        #expect(huur.cells[0].difference == .zero)
        // afwijkend: Energie januari (−160 tegen −150, verschil −10)
        let energie = try row(f.energie)
        #expect(energie.cells[0].status == .afwijkend)
        #expect(energie.cells[0].sum == eur(-160))
        #expect(energie.cells[0].expected == eur(-150))
        #expect(energie.cells[0].difference == eur(-10))
        // teLaat: Energie februari (verwacht, niets geboekt, maand voorbij)
        #expect(energie.cells[1].status == .teLaat)
        // open: Energie maart (dag 20, vandaag is de 15e)
        #expect(energie.cells[2].status == .open)
        // nietVerwacht: toekomstige maand
        #expect(energie.cells[3].status == .nietVerwacht)
        // teLaat in de lopende maand: RESERVERINGEN maart (dag 5 is voorbij)
        try #expect(row(f.reserveringen).cells[2].status == .teLaat)
        // open: Salaris maart (dag 25)
        try #expect(row(f.salaris).cells[2].status == .open)
        // gelijk met twee boekingen: Lening februari (−100 + −100)
        let lening = try row(f.lening)
        #expect(lening.cells[1].status == .gelijk)
        #expect(lening.cells[1].entryCount == 2)
    }

    @Test func quarterlyAndYearlyItems() throws {
        let v = try row(f.verzekering)
        #expect(v.expectedMonths == [1, 4, 7, 10])
        #expect(v.cells[0].status == .gelijk)          // januari: −300
        #expect(v.cells[1].status == .afwijkend)       // februari: −50 geboekt, niet verwacht
        #expect(v.cells[1].expected == nil)
        #expect(v.cells[1].difference == eur(-50))
        #expect(v.cells[2].status == .nietVerwacht)    // maart: niet verwacht
        #expect(v.cells[3].status == .nietVerwacht)    // april: verwacht, maar toekomst
        #expect(v.cells[3].expected == eur(-300))
        #expect(v.yearTotal == eur(-350))
        #expect(v.planYearTotal == eur(-1200))         // 4 × −300
        let w = try row(f.wegenbelasting)
        #expect(w.planYearTotal == eur(-90))
        #expect(w.cells.allSatisfy { $0.status == .nietVerwacht })
    }

    @Test func quarterlyItemLateAfterItsMonth() throws {
        // Op 15 mei is de verzekering van april (verwacht, niet geboekt) te laat.
        let g = try f.db.read { try Insight.monthGrid($0, year: 2027, today: d("2027-05-15")) }
        let v = try #require(g.rows.first { $0.id == f.verzekering })
        #expect(v.cells[3].status == .teLaat)
        #expect(v.cells[4].status == .nietVerwacht)
    }

    @Test func reserveTotalPlanIsSumOfReserveLines() throws {
        let r = try row(f.reserveringen)
        #expect(r.plan == eur(-250))                   // −100 + −150
        #expect(r.cells[0].expected == eur(-250))
        #expect(r.cells[0].status == .gelijk)
        #expect(r.planYearTotal == eur(-3000))
        let line = try row(f.resAuto)
        #expect(line.plan == eur(-100))
        #expect(line.cells.allSatisfy { $0.status == .nietVerwacht && $0.expected == nil })
        #expect(line.planYearTotal == .zero)
    }

    @Test func monthTotalsAndRuimte() throws {
        let g = try grid()
        // Januari: plan verwacht = 3000 − 1200 − 150 − 300 − 250 − 200 = 900; ruimte = 900 + 40 − 170 = 770
        let jan = g.monthTotals[0]
        #expect(jan.fixed == eur(890))
        #expect(jan.inDivers == eur(40))
        #expect(jan.uitDivers == eur(-170))
        #expect(jan.nettoDivers == eur(-130))
        #expect(jan.result == eur(760))
        #expect(jan.planExpected == eur(900))
        #expect(jan.ruimte == eur(770))
        // Februari: plan verwacht = 3000 − 1200 − 150 − 250 − 200 = 1200; ruimte = 1200 − 130 = 1070
        let feb = g.monthTotals[1]
        #expect(feb.fixed == eur(1300))
        #expect(feb.inDivers == .zero)
        #expect(feb.uitDivers == eur(-130))
        #expect(feb.result == eur(1170))
        #expect(feb.ruimte == eur(1070))
        // Maart: ruimte = 1200 + 20 − 210 = 1010
        let mrt = g.monthTotals[2]
        #expect(mrt.fixed == eur(-1200))
        #expect(mrt.result == eur(-1390))
        #expect(mrt.ruimte == eur(1010))
        // Jaar
        #expect(g.yearTotals.fixed == eur(990))
        #expect(g.yearTotals.inDivers == eur(60))
        #expect(g.yearTotals.uitDivers == eur(-510))
        #expect(g.yearTotals.result == eur(540))
    }

    @Test func savingsEntriesDoNotCountInGrid() throws {
        // De stortingen op de spaarrekening (+525) zitten niet in het resultaat van de betaalrekening.
        try #expect(grid().monthTotals.map(\.result).sum() == eur(540))
    }

    @Test func drillDown() throws {
        try f.db.read { db in
            let cell = try Insight.cellEntries(db, itemId: f.lening, year: 2027, month: 2)
            #expect(cell.map(\.label) == ["Lening deel 1", "Lening deel 2"])
            #expect(cell.first?.itemLabel == "Lening")
            let uit = try Insight.diversEntries(db, year: 2027, month: 1, positive: false)
            #expect(uit.map(\.amount) == [eur(-80), eur(-60), eur(-30)])
            let inn = try Insight.diversEntries(db, year: 2027, month: 1, positive: true)
            #expect(inn.map(\.label) == ["Marktplaats"])
        }
    }

    @Test func missingYearThrowsDutchError() throws {
        #expect(throws: InsightError.yearNotFound(2030)) {
            try f.db.read { try Insight.monthGrid($0, year: 2030, today: today) }
        }
        #expect(InsightError.yearNotFound(2030).localizedDescription == "Er is nog geen begroting voor het jaar 2030.")
    }

    @Test func fixedItemsStatus() throws {
        let mrt = try f.db.read { try Insight.fixedItemsStatus($0, year: 2027, month: 3, today: today) }
        #expect(mrt.items.map(\.label) == ["Salaris", "Huur", "Energie", "RESERVERINGEN", "Lening"])
        #expect(mrt.items.map(\.state) == [.open, .voldaan, .open, .teLaat, .open])
        #expect((mrt.paidCount, mrt.openCount, mrt.lateCount) == (1, 3, 1))
        #expect(mrt.planTotal == eur(1200))
        #expect(mrt.actualTotal == eur(-1200))
        #expect(mrt.outstandingTotal == eur(2400))     // 3000 − 150 − 250 − 200

        let jan = try f.db.read { try Insight.fixedItemsStatus($0, year: 2027, month: 1, today: today) }
        #expect(jan.paidCount == 6)
        let energie = try #require(jan.items.first { $0.id == f.energie })
        #expect(energie.state == .voldaan)
        #expect(energie.actual == eur(-160))
        #expect(energie.plan == eur(-150))
        #expect(energie.difference == eur(-10))
        #expect(energie.day == d("2027-01-20"))

        let feb = try f.db.read { try Insight.fixedItemsStatus($0, year: 2027, month: 2, today: today) }
        // Verzekering is in februari niet verwacht en staat er dus niet in; Energie is te laat.
        #expect(feb.items.map(\.label) == ["Salaris", "Huur", "Energie", "RESERVERINGEN", "Lening"])
        #expect(feb.lateCount == 1)
    }
}

@Suite struct BalanceTests {
    let f: Fixture
    init() throws { f = try Fixture() }

    @Test func balanceOnDay() throws {
        try f.db.read { db in
            try #expect(Insight.balance(db, accountId: f.betaal, on: d("2027-01-01")) == eur(3000))
            try #expect(Insight.balance(db, accountId: f.betaal, on: d("2027-01-31")) == eur(3760))
            try #expect(Insight.balance(db, accountId: f.betaal, on: d("2027-02-28")) == eur(4930))
            try #expect(Insight.balance(db, accountId: f.betaal, on: today) == eur(3540))
            try #expect(Insight.balance(db, accountId: f.spaar, on: today) == eur(5335))
            #expect(throws: InsightError.accountNotFound(999)) { try Insight.balance(db, accountId: 999, on: today) }
        }
    }

    @Test func accountOverview() throws {
        let list = try f.db.read { try Insight.accountOverview($0, today: today) }
        #expect(list.map(\.name) == ["Betaalrekening", "Spaarrekening"])
        let b = list[0]
        #expect(b.balance == eur(3540))
        #expect(b.newBankTransactionCount == 2)
        #expect(b.unreviewedEntryCount == 1)
        #expect(b.lastReconciliation?.difference == .zero)
        #expect(b.lastImport?.fileName == "test-maart.csv")
        #expect(b.lastImport?.closingBalance == eur(3482, 50))
        let s = list[1]
        #expect(s.lastReconciliation?.day == d("2027-01-31"))
        #expect(s.lastReconciliation?.difference == eur(5))    // berekend 5275 − werkelijk 5270
        #expect(s.lastImport == nil)
        #expect(s.newBankTransactionCount == 0)
    }

    @Test func balanceSeries() throws {
        try f.db.read { db in
            let daily = try Insight.balanceSeries(db, accountId: f.betaal, from: d("2027-01-01"), to: d("2027-01-05"))
            #expect(daily.map(\.balance) == [eur(3000), eur(1800), eur(1800), eur(1800), eur(1550)])
            let monthly = try Insight.balanceSeries(db, accountId: f.betaal, from: d("2027-01-01"), to: today, step: .monthEnd)
            #expect(monthly.map(\.day) == [d("2027-01-31"), d("2027-02-28"), today])
            #expect(monthly.map(\.balance) == [eur(3760), eur(4930), eur(3540)])
            let all = try Insight.checkingBalanceSeries(db, from: d("2027-02-28"), to: d("2027-02-28"))
            #expect(all.map(\.balance) == [eur(4930)])
        }
    }

    @Test func spendableAndSimulation() throws {
        let s = try f.db.read { try Insight.spendable($0, year: 2027, today: today) }
        // saldo betaalrekening                      3.540,00
        // antiRood                                    500,00
        // besteedbaar = 3540 − 500                  3.040,00
        #expect(s.balance == eur(3540))
        #expect(s.spendable == eur(3040))
        // Simulatie maart: nog verwacht en niet geboekt:
        //   Salaris +3000 · Energie −150 · RESERVERINGEN −250 (som RES-regels) · Lening −200 = +2400
        //   (Huur is al geboekt, Verzekering is in maart niet verwacht, RES-regels tellen niet mee)
        // besteedbaar eind van de maand = 3040 + 2400 = 5.440,00
        #expect(s.expectedItems.map(\.label) == ["Salaris", "Energie", "RESERVERINGEN", "Lening"])
        #expect(s.expectedItems.map(\.plan) == [eur(3000), eur(-150), eur(-250), eur(-200)])
        #expect(s.expectedItems.map(\.isLate) == [false, false, true, false])
        #expect(s.expectedTotal == eur(2400))
        #expect(s.spendableEndOfMonth == eur(5440))
    }

    @Test func spendableForPastYearUsesYearEnd() throws {
        let s = try f.db.read { try Insight.spendable($0, year: 2027, today: d("2028-02-01")) }
        #expect(s.asOf == d("2027-12-31"))
        #expect(s.spendable == eur(3040))
        #expect(s.expectedItems.isEmpty)
        #expect(s.spendableEndOfMonth == eur(3040))
    }

    @Test func yearSummary() throws {
        let y = try f.db.read { try Insight.yearSummary($0, year: 2027, today: today) }
        // IN  = 3000 + 40 + 3000 + 20 = 6060
        // UIT = −2280 (jan) − 1830 (feb) − 1410 (mrt) = −5520
        #expect(y.openingBalance == eur(3000))
        #expect(y.income == eur(6060))
        #expect(y.expenses == eur(-5520))
        #expect(y.balance == eur(3540))
        #expect(y.result == eur(540))
        #expect(y.buffers == eur(500))
        #expect(y.spendable == eur(3040))
        #expect(y.inDivers == eur(60))
        #expect(y.uitDivers == eur(-510))
        #expect(y.elapsedMonths == 3)
        #expect(y.averageIncome == eur(2020))
        #expect(y.averageExpenses == eur(-1840))
        #expect(y.averageInDivers == eur(20))
        #expect(y.averageUitDivers == eur(-170))
    }

    @Test func spendableSeries() throws {
        let s = try f.db.read { try Insight.spendableSeries($0, year: 2027, today: today) }
        #expect(s.map(\.day) == [d("2027-01-31"), d("2027-02-28"), today])
        // 31-1: 3760 − 500 = 3260 · 28-2: 4930 − 500 = 4430 · 15-3: 3540 − 500 = 3040
        #expect(s.map(\.spendable) == [eur(3260), eur(4430), eur(3040)])
    }
}

@Suite struct PotTests {
    let f: Fixture
    init() throws { f = try Fixture() }

    @Test func potBalancesAndUnallocated() throws {
        let o = try f.db.read { try Insight.potOverview($0, today: today) }
        let account = try #require(o.accounts.first)
        #expect(o.accounts.count == 1)
        #expect(account.balance == eur(5335))
        #expect(account.potTotal == eur(325))
        #expect(account.unallocated == eur(5010))
        // De uitgave "Uit eten" op de betaalrekening met pot Vakantie telt niet in het potsaldo.
        #expect(account.pots.map(\.balance) == [eur(200), eur(100), eur(25)])
        let auto = account.pots[0]
        #expect(auto.monthlyAmount == eur(100))
        #expect(auto.targetAmount == eur(2400))
        let progress = try #require(auto.progress); #expect(abs(progress - 200.0 / 2400.0) < 0.0001)
        #expect(auto.remainingToTarget == eur(2200))
        let vakantie = account.pots[1]
        #expect(vakantie.depositsThisYear == eur(300))
        #expect(vakantie.withdrawalsThisYear == eur(-200))
        #expect(vakantie.lastMovement == d("2027-02-15"))
        #expect(vakantie.progress == nil)
    }

    @Test func groupsByKindAndOwner() throws {
        let o = try f.db.read { try Insight.potOverview($0, accountId: f.spaar, today: today) }
        #expect(o.byKind.map(\.kind) == [.reservering, .spaar])
        #expect(o.byKind.map(\.total) == [eur(300), eur(25)])
        #expect(o.byKind[0].monthlyTotal == eur(250))
        #expect(o.byOwner.map(\.owner) == ["Kind A", nil])
        #expect(o.byOwner.map(\.total) == [eur(25), eur(300)])
        #expect(o.totalUnallocated == eur(5010))
    }

    @Test func potHistoryAndUnallocatedEntries() throws {
        try f.db.read { db in
            let h = try Insight.potHistory(db, potId: f.potVakantie)
            #expect(h.map(\.entry.amount) == [eur(150), eur(150), eur(-200)])
            #expect(h.map(\.runningBalance) == [eur(150), eur(300), eur(100)])
            let loose = try Insight.unallocatedSavingsEntries(db)
            #expect(loose.map(\.label) == ["Rente"])
            #expect(throws: InsightError.potNotFound(999)) { try Insight.potHistory(db, potId: 999) }
        }
    }

    @Test func reimbursements() throws {
        try f.db.read { db in
            let open = try Insight.openReimbursements(db)
            #expect(open.entries.map(\.label) == ["Uit eten", "Tandarts"])
            #expect(open.total == eur(-195))
            #expect(open.transferAmount == eur(195))
            #expect(open.perPot.map(\.potName) == ["Vakantie", nil])
            #expect(open.perPot.map(\.total) == [eur(-75), eur(-120)])

            let transfers = try Insight.savingsTransfers(db)
            #expect(transfers.count == 1)
            #expect(transfers[0].amount == eur(30))
            #expect(transfers[0].done)
            #expect(transfers[0].entries.map(\.label) == ["Cadeau"])
            #expect(transfers[0].entriesTotal == eur(-30))
        }
    }
}

@Suite struct ReportTests {
    let f: Fixture
    init() throws { f = try Fixture() }

    @Test func tagTotals() throws {
        let tags = try f.db.read { try Insight.tagYear($0, year: 2027, today: today) }
        #expect(tags.map(\.name) == ["boodschappen", "tanken", "uit eten"])
        let b = tags[0]
        #expect(b.months[0] == eur(-80))
        #expect(b.months[1] == .zero)
        #expect(b.months[2] == eur(-90))
        #expect(b.yearToDate == eur(-170))
        #expect(b.averagePerMonth == Money(cents: -5667))   // −170,00 ÷ 3 = −56,67
        #expect(b.previousYearToDate == nil)
        #expect(tags[1].yearToDate == eur(-115))
        #expect(tags[1].entryCount == 2)
        #expect(tags[2].yearToDate == eur(-75))

        let entries = try f.db.read { try Insight.tagEntries($0, tagId: f.tagTanken, year: 2027, month: 2) }
        #expect(entries.map(\.amount) == [eur(-55)])
        #expect(entries[0].tags.map(\.name) == ["tanken"])
        try #expect(f.db.read { try Insight.tagEntries($0, tagId: f.tagTanken, year: 2027) }.count == 2)
    }

    @Test func previousYearComparison() throws {
        // Vorig jaar (2026) tanken: −50 op 10-2 en −70 op 1-6. T/m 15-3 dus −50, heel 2026 −120.
        try f.db.write { db in
            for (day, amount) in [("2026-02-10", Int64(-50)), ("2026-06-01", -70)] {
                var e = Entry(accountId: f.betaal, day: d(day), amount: eur(amount), label: "Tanken")
                try e.insert(db)
                try EntryTag(entryId: e.id!, tagId: f.tagTanken).insert(db)
            }
        }
        let tags = try f.db.read { try Insight.tagYear($0, year: 2027, today: today) }
        #expect(tags[1].previousYearToDate == eur(-50))
        #expect(tags[1].previousYearTotal == eur(-120))
        #expect(tags[1].changeFromPreviousYear == eur(-65))  // −115 − (−50)
        #expect(tags[0].previousYearTotal == nil)

        let years = try f.db.read { try Insight.yearOverYear($0) }
        #expect(years.map(\.year) == [2026, 2027])
        #expect(years[0].expenses == eur(-120))
        #expect(!years[0].hasBudget)
        #expect(years[1].income == eur(6060))
        #expect(years[1].expenses == eur(-5520))
        #expect(years[1].result == eur(540))
        #expect(years[1].uitDivers == eur(-510))
        #expect(years[1].hasBudget)
    }

    @Test func monthlyResults() throws {
        let m = try f.db.read { try Insight.monthlyResults($0, year: 2027) }
        #expect(m.count == 12)
        #expect(m[0].income == eur(3040)); #expect(m[0].expenses == eur(-2280)); #expect(m[0].result == eur(760))
        #expect(m[1].result == eur(1170))
        #expect(m[2].income == eur(20)); #expect(m[2].expenses == eur(-1410))
        #expect(m[3].result == .zero)
    }

    @Test func budgetVersusActual() throws {
        let rows = try f.db.read { try Insight.budgetVsActual($0, year: 2027, today: today) }
        #expect(!rows.contains { $0.id == f.resAuto })
        let energie = try #require(rows.first { $0.id == f.energie })
        // plan t/m maart 3 × −150 = −450; werkelijk −160; jan meer uitgegeven, feb niets geboekt, mrt loopt nog
        #expect(energie.planToDate == eur(-450))
        #expect(energie.actualToDate == eur(-160))
        #expect(energie.difference == eur(290))
        #expect(energie.planYear == eur(-1800))
        #expect((energie.monthsOver, energie.monthsUnder) == (1, 1))
        let verzekering = try #require(rows.first { $0.id == f.verzekering })
        #expect(verzekering.planToDate == eur(-300))
        #expect(verzekering.actualToDate == eur(-350))
        #expect((verzekering.monthsOver, verzekering.monthsUnder) == (1, 0))   // februari: −50 onverwacht
        let salaris = try #require(rows.first { $0.id == f.salaris })
        #expect(salaris.planToDate == eur(9000))
        #expect(salaris.actualToDate == eur(6000))
        #expect((salaris.monthsOver, salaris.monthsUnder) == (0, 0))
        let res = try #require(rows.first { $0.id == f.reserveringen })
        #expect(res.planToDate == eur(-750))
        #expect(res.actualToDate == eur(-500))
    }

    @Test func topDiversAndBreakdown() throws {
        try f.db.read { db in
            let top = try Insight.topDiversExpenses(db, year: 2027, limit: 3)
            #expect(top.map(\.label) == ["Tandarts", "Boodschappen", "Boodschappen"])
            #expect(top.map(\.amount) == [eur(-120), eur(-90), eur(-80)])
            let feb = try Insight.topDiversExpenses(db, year: 2027, month: 2)
            #expect(feb.map(\.amount) == [eur(-75), eur(-55)])

            // boodschappen −170 · zonder tag −150 (Cadeau −30 + Tandarts −120) · tanken −115 · uit eten −75
            let b = try Insight.diversByTag(db, year: 2027)
            #expect(b.total == eur(-510))
            #expect(b.buckets.map(\.name) == ["boodschappen", "Zonder tag", "tanken", "uit eten"])
            #expect(b.buckets.map(\.total) == [eur(-170), eur(-150), eur(-115), eur(-75)])
            #expect(b.buckets[1].tagId == nil)
            #expect(b.buckets[1].count == 2)
            let mrt = try Insight.diversByTag(db, year: 2027, month: 3)
            #expect(mrt.buckets.map(\.total) == [eur(-120), eur(-90)])
        }
    }
}

@Suite struct SearchTests {
    let f: Fixture
    init() throws { f = try Fixture() }

    private func search(_ filter: EntryFilter) throws -> EntrySearchResult {
        try f.db.read { try Insight.searchEntries($0, filter: filter) }
    }

    @Test func filters() throws {
        try #expect(search(EntryFilter()).totalCount == 29)
        let betaal = try search(EntryFilter(accountId: f.betaal))
        #expect(betaal.totalCount == 22)
        #expect(betaal.totalSum == eur(540))
        try #expect(search(EntryFilter(accountId: f.betaal, year: 2027, month: 2)).totalCount == 8)
        try #expect(search(EntryFilter(year: 2027)).totalCount == 29)
        try #expect(search(EntryFilter(from: d("2027-03-01"), to: d("2027-03-10"))).totalCount == 4)
        let divers = try search(EntryFilter(diversOnly: true))
        #expect(divers.totalCount == 9)
        #expect(divers.totalSum == eur(-450))          // 60 − 510
        try #expect(search(EntryFilter(text: "tank")).totalCount == 2)
        try #expect(search(EntryFilter(text: "lange rit")).rows.map(\.amount) == [eur(-55)])        // notitie
        try #expect(search(EntryFilter(text: "testmarkt")).rows.map(\.label) == ["Boodschappen"])   // tegenpartij
        try #expect(search(EntryFilter(text: "pinbetaling 03")).totalCount == 1)                    // bankomschrijving
        try #expect(search(EntryFilter(text: "100%")).totalCount == 0)
        try #expect(search(EntryFilter(budgetItemId: f.lening)).totalCount == 3)
        try #expect(search(EntryFilter(potId: f.potVakantie)).totalCount == 4)
        try #expect(search(EntryFilter(tagId: f.tagTanken)).totalSum == eur(-115))
        try #expect(search(EntryFilter(unreviewedOnly: true)).rows.map(\.label) == ["Boodschappen"])
        try #expect(search(EntryFilter(reimburseOnly: true)).totalCount == 3)
        try #expect(search(EntryFilter(accountId: f.betaal, sign: .positive)).totalCount == 4)
        try #expect(search(EntryFilter(accountId: f.betaal, sign: .negative)).totalCount == 18)
        // Bedrag zonder teken tussen 50 en 100 op de betaalrekening: 80, 60, 50, 100, 100, 75, 55, 90
        try #expect(search(EntryFilter(accountId: f.betaal, minAmount: eur(50), maxAmount: eur(100))).totalCount == 8)
    }

    @Test func joinedFields() throws {
        let row = try #require(try search(EntryFilter(unreviewedOnly: true)).rows.first)
        #expect(row.accountName == "Betaalrekening")
        #expect(row.isDivers)
        #expect(row.tags.map(\.name) == ["boodschappen"])
        #expect(row.bank?.counterpartyName == "Supermarkt Testmarkt")
        #expect(row.bank?.descriptionText == "Pinbetaling 03-03")
        #expect(row.bank?.amount == eur(-90))
        let uitEten = try #require(try search(EntryFilter(tagId: f.tagUitEten)).rows.first)
        #expect(uitEten.potName == "Vakantie")
        #expect(uitEten.bank == nil)
        let huur = try #require(try search(EntryFilter(budgetItemId: f.huur)).rows.first)
        #expect(huur.itemLabel == "Huur")
        #expect(!huur.isDivers)
    }

    @Test func sortingAndPaging() throws {
        let page1 = try search(EntryFilter(accountId: f.betaal, sort: .dayAscending, limit: 5))
        #expect(page1.rows.map(\.label) == ["Huur", "Reserveringen", "Verzekering", "Boodschappen", "Tanken"])
        #expect(page1.totalCount == 22)
        #expect(page1.totalSum == eur(540))
        let page2 = try search(EntryFilter(accountId: f.betaal, sort: .dayAscending, limit: 5, offset: 5))
        #expect(page2.rows.map(\.label) == ["Marktplaats", "Energie", "Cadeau", "Salaris", "Lening"])
        let last = try search(EntryFilter(accountId: f.betaal, sort: .dayAscending, limit: 5, offset: 20))
        #expect(last.rows.count == 2)
        try #expect(search(EntryFilter(sort: .dayAscending, offset: 27)).rows.count == 2)
        let byAmount = try search(EntryFilter(accountId: f.betaal, sort: .amountAscending, limit: 2))
        #expect(byAmount.rows.map(\.amount) == [eur(-1200), eur(-1200)])
        #expect(byAmount.rows.map(\.day) == [d("2027-03-01"), d("2027-02-01")])
        let newest = try search(EntryFilter(limit: 1))
        #expect(newest.rows.map(\.label) == ["Terugbetaling"])
    }

    @Test func reviewQueue() throws {
        try f.db.read { db in
            let q = try Insight.reviewQueue(db, accountId: f.betaal)
            #expect(q.map(\.transaction.counterpartyName) == ["Bakker Test", "Kiosk Test"])
            #expect(q.map(\.remaining) == [eur(-45), eur(-12, 50)])
            #expect(q[0].accountName == "Betaalrekening")
            try #expect(Insight.reviewQueue(db, accountId: f.spaar).isEmpty)
            try #expect(Insight.reviewQueue(db).count == 2)
        }
    }
}

@Suite struct DashboardTests {
    let f: Fixture
    init() throws { f = try Fixture() }

    @Test func dashboard() throws {
        let dash = try f.db.read { try Insight.dashboard($0, today: today, recentLimit: 3) }
        #expect(dash.spendable?.spendable == eur(3040))
        #expect(dash.spendable?.spendableEndOfMonth == eur(5440))
        #expect(dash.accounts.map(\.balance) == [eur(3540), eur(5335)])
        #expect((dash.paidCount, dash.openCount, dash.lateCount) == (1, 3, 1))
        #expect(dash.recentEntries.map(\.label) == ["Terugbetaling", "Tandarts", "Boodschappen"])
        // Maart: IN 20, UIT −1200 − 90 − 120 = −1410; plan IN 3000, plan UIT −1200 − 150 − 250 − 200 = −1800
        #expect(dash.monthIncome == eur(20))
        #expect(dash.monthExpenses == eur(-1410))
        #expect(dash.planIncome == eur(3000))
        #expect(dash.planExpenses == eur(-1800))
        #expect(dash.topTags.map(\.name) == ["boodschappen"])
        #expect(dash.topTags.first?.total == eur(-90))
    }

    @Test func attentionItems() throws {
        let dash = try f.db.read { try Insight.dashboard($0, today: today) }
        #expect(dash.attention == [
            .newBankTransactions(count: 2),
            .unreviewedEntries(count: 1),
            .openReimbursements(amount: eur(195), count: 2, direction: .fromSavings),
            // De overboeking van 31-1 (30,00) is afgevinkt maar nog in geen bankbestand gezien.
            .unconfirmedSettlement(amount: eur(30), day: d("2027-01-31")),
            // Spaarrekening: afstemming van 31-1 heeft € 5 verschil en is 43 dagen oud (> 35).
            .reconciliationDiffers(accountId: f.spaar, accountName: "Spaarrekening", difference: eur(5), day: d("2027-01-31")),
            .reconciliationOld(accountId: f.spaar, accountName: "Spaarrekening", lastDay: d("2027-01-31"), daysAgo: 43),
        ])
        #expect(dash.attention[0].message == "2 banktransacties moeten nog geboekt worden.")
        #expect(dash.attention[2].message == "€ 195,00 over te maken van spaar naar betaal (2 boekingen).")
    }

    @Test func missingYearForToday() throws {
        let day = d("2028-01-10")
        let dash = try f.db.read { try Insight.dashboard($0, today: day) }
        #expect(dash.attention.first == .yearMissing(year: 2028))
        #expect(dash.spendable == nil)
        #expect(dash.fixedItems == nil)
        // Beide afstemmingen zijn nu ouder dan 35 dagen.
        #expect(dash.attention.contains { if case .reconciliationOld(let id, _, _, _) = $0 { return id == f.betaal }; return false })
        #expect(dash.accounts.map(\.balance) == [eur(3540), eur(5335)])
    }

    @Test func neverReconciledAccount() throws {
        try f.db.write { db in try db.execute(sql: "DELETE FROM reconciliation") }
        let dash = try f.db.read { try Insight.dashboard($0, today: today) }
        // Geopend op 1-1-2027, 73 dagen geleden, nooit afgestemd.
        #expect(dash.attention.contains(.reconciliationOld(accountId: f.betaal, accountName: "Betaalrekening",
                                                           lastDay: nil, daysAgo: 73)))
    }

    @Test func functionsWorkOnEmptyDatabase() throws {
        let empty = try AppDatabase.inMemory()
        try empty.read { db in
            let dash = try Insight.dashboard(db, today: today)
            #expect(dash.attention == [.yearMissing(year: 2027)])
            #expect(dash.accounts.isEmpty)
            try #expect(Insight.potOverview(db, today: today).accounts.isEmpty)
            try #expect(Insight.searchEntries(db, filter: EntryFilter()).totalCount == 0)
            try #expect(Insight.yearOverYear(db).isEmpty)
            try #expect(Insight.checkingBalance(db, on: today) == .zero)
            try #expect(Insight.openReimbursements(db).total == .zero)
        }
    }
}

@Suite struct TemporaryLoanTests {
    @Test func outstandingLoanIsNotSpendable() throws {
        let f = try Fixture()
        let today = d("2027-03-15")
        let before = try f.db.read { try Insight.spendable($0, year: 2027, today: today) }
        let betaal = try f.db.read { try Account.filter(Column("kind") == "betaal").fetchOne($0)! }
        try f.db.write { db in
            // 1 maart: € 1.000 tijdelijk van spaar gehaald; 10 maart: € 400 teruggeboekt.
            var lend = Entry(accountId: betaal.id!, day: d("2027-03-01"), amount: eur(1000), label: "Tijdelijk van spaar",
                             temporaryLoan: true)
            try lend.insert(db)
            var back = Entry(accountId: betaal.id!, day: d("2027-03-10"), amount: eur(-400), label: "Terug naar spaar",
                             temporaryLoan: true)
            try back.insert(db)
        }
        let after = try f.db.read { try Insight.spendable($0, year: 2027, today: today) }
        // Saldo +600, uitstaand 600: besteedbaar verandert niet.
        #expect(after.balance == before.balance + eur(600))
        #expect(after.tijdelijkAntiRood == eur(600))
        #expect(after.spendable == before.spendable)
        // Op 5 maart stond nog de volle € 1.000 uit.
        #expect(try f.db.read { try Insight.temporaryLoanOutstanding($0, on: d("2027-03-05")) } == eur(1000))
        let dash = try f.db.read { try Insight.dashboard($0, today: today) }
        #expect(dash.attention.contains(.temporaryLoanOutstanding(amount: eur(600))))
        #expect(try f.db.read { try Insight.temporaryLoanEntries($0) }.count == 2)
    }
}
