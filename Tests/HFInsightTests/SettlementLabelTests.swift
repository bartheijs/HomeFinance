import Foundation
import GRDB
import HFCore
import Testing
@testable import HFInsight

private let today = Fixture.today

/// Verrekenen per tag, bovenop de fixture. De tag "tanken" wordt verrekend:
///
///   20-12-2026  Tanken −35   → beginstand S0 (isOpening, geen storting)
///   15-01-2027  Tanken −60   → verrekening S1 van 1-2-2027, € 60,00, storting "Storting tanken" +60
///   20-02-2027  Tanken −55   open
///   05-03-2027  Retour tankpas +10 (tag tanken)  open, telt eraf
///   14-03-2027  Tanken −45   open
///   spaarrekening −20 met tag tanken: telt niet (geen betaalrekening)
///   openstaand = −(−55 + 10 − 45) = 90,00 · 3 boekingen · oudste 20-2
@Suite struct SettlementTests {
    let f: Fixture
    var parkeren: Int64 = 0
    var s0: Int64 = 0, s1: Int64 = 0

    init() throws {
        f = try Fixture()
        try f.db.write { db in
            try db.execute(sql: "UPDATE tag SET settles = 1 WHERE id = ?", arguments: [f.tagTanken])
            var p = Tag(name: "parkeren", color: "#445566", sortOrder: 9, settles: true)
            try p.insert(db); parkeren = p.id!

            func entry(_ account: Int64, _ day: String, _ amount: Int64, _ label: String, tag: Int64? = nil,
                       settlement: Int64? = nil) throws -> Int64 {
                var e = Entry(accountId: account, day: d(day), amount: eur(amount), label: label, settlementId: settlement)
                try e.insert(db)
                if let tag { try EntryTag(entryId: e.id!, tagId: tag).insert(db) }
                return e.id!
            }
            var opening = Settlement(tagId: f.tagTanken, day: d("2027-01-01"), amount: eur(35), isOpening: true, note: "beginstand")
            try opening.insert(db); s0 = opening.id!
            _ = try entry(f.betaal, "2026-12-20", -35, "Tanken", tag: f.tagTanken, settlement: s0)

            let deposit = try entry(f.betaal, "2027-02-01", 60, "Storting tanken")
            var real = Settlement(tagId: f.tagTanken, day: d("2027-02-01"), amount: eur(60), depositEntryId: deposit)
            try real.insert(db); s1 = real.id!
            try db.execute(sql: "UPDATE entry SET settlementId = ? WHERE label = 'Tanken' AND day = '2027-01-15'", arguments: [s1])

            _ = try entry(f.betaal, "2027-03-05", 10, "Retour tankpas", tag: f.tagTanken)
            _ = try entry(f.betaal, "2027-03-14", -45, "Tanken", tag: f.tagTanken)
            _ = try entry(f.spaar, "2027-03-06", -20, "Tanken van spaar", tag: f.tagTanken)
        }
    }

    @Test func overview() throws {
        let list = try f.db.read { try Insight.settlementOverview($0, today: today) }
        #expect(list.map(\.name) == ["tanken", "parkeren"])
        let t = list[0]
        #expect(t.id == f.tagTanken)
        #expect(t.outstanding == eur(90))
        #expect(t.openCount == 3)
        #expect(t.oldestOpenDay == d("2027-02-20"))
        #expect(t.lastSettlementDay == d("2027-02-01"))     // de beginstand van 1-1 telt niet
        #expect(t.lastSettlementAmount == eur(60))
        #expect(t.settledThisYear == eur(60))               // zonder de beginstand van 35
        let p = list[1]
        #expect(p.outstanding == .zero)
        #expect(p.openCount == 0)
        #expect(p.oldestOpenDay == nil)
        #expect(p.lastSettlementDay == nil)
        #expect(p.settledThisYear == .zero)
    }

    @Test func onlyOpeningSettlementMeansNoLastSettlement() throws {
        try f.db.write { db in try db.execute(sql: "DELETE FROM settlement WHERE id = ?", arguments: [s1]) }
        let t = try #require(try f.db.read { try Insight.settlementOverview($0, today: today) }.first)
        #expect(t.lastSettlementDay == nil)
        #expect(t.settledThisYear == .zero)
        // De boeking van 15-1 is weer open (settlementId is door de database leeggemaakt): 90 + 60 = 150.
        #expect(t.outstanding == eur(150))
        #expect(t.oldestOpenDay == d("2027-01-15"))
    }

    @Test func openEntries() throws {
        let open = try f.db.read { try Insight.openSettlementEntries($0, tagId: f.tagTanken) }
        #expect(open.map(\.day) == [d("2027-02-20"), d("2027-03-05"), d("2027-03-14")])
        #expect(open.map(\.amount) == [eur(-55), eur(10), eur(-45)])
        #expect(open.allSatisfy { $0.settlementId == nil })
        try #expect(f.db.read { try Insight.openSettlementEntries($0, tagId: parkeren) }.isEmpty)
    }

    @Test func history() throws {
        let h = try f.db.read { try Insight.settlementHistory($0, tagId: f.tagTanken) }
        #expect(h.map(\.id) == [s1, s0])                    // nieuwste eerst
        #expect(h[0].settlement.amount == eur(60))
        #expect(h[0].deposit?.label == "Storting tanken")
        #expect(h[0].deposit?.amount == eur(60))
        #expect(h[0].entries.map(\.amount) == [eur(-60)])
        #expect(h[0].entries.first?.settlementId == s1)
        #expect(h[0].entriesTotal == eur(-60))
        #expect(h[1].settlement.isOpening)
        #expect(h[1].deposit == nil)
        #expect(h[1].entries.map(\.day) == [d("2026-12-20")])
        #expect(h[1].entriesTotal == eur(-35))
        try #expect(f.db.read { try Insight.settlementHistory($0, tagId: parkeren) }.isEmpty)
    }

    @Test func depositMarkedWithSettlementIsNotASettledEntry() throws {
        try f.db.write { db in
            try db.execute(sql: "UPDATE entry SET settlementId = ? WHERE label = 'Storting tanken'", arguments: [s1])
        }
        let h = try f.db.read { try Insight.settlementHistory($0, tagId: f.tagTanken) }
        #expect(h[0].entries.map(\.amount) == [eur(-60)])
        #expect(h[0].deposit?.settlementId == s1)
    }

    @Test func unsettledFilter() throws {
        let r = try f.db.read { try Insight.searchEntries($0, filter: EntryFilter(unsettledOnly: true)) }
        #expect(r.totalCount == 3)
        #expect(r.totalSum == eur(-90))
        #expect(r.rows.map(\.label) == ["Tanken", "Retour tankpas", "Tanken"])
        // Boodschappen heeft een tag die niet verrekend wordt en staat er dus niet in.
        let settled = try f.db.read { try Insight.searchEntries($0, filter: EntryFilter(year: 2027, month: 1, tagId: f.tagTanken)) }
        #expect(settled.rows.map(\.settlementId) == [s1])
    }

    @Test func dashboardAttention() throws {
        let dash = try f.db.read { try Insight.dashboard($0, today: today) }
        let item = AttentionItem.openSettlement(tagId: f.tagTanken, tagName: "tanken", amount: eur(90), count: 3)
        #expect(dash.attention.contains(item))
        #expect(item.message == "tanken: nog terug te ontvangen: € 90,00 (3 boekingen).")
        #expect(AttentionItem.openSettlement(tagId: 1, tagName: "Tanken", amount: eur(45), count: 1).message
                == "Tanken: nog terug te ontvangen: € 45,00 (1 boeking).")
        // Parkeren heeft niets openstaan: geen aandachtspunt.
        #expect(dash.attention.filter { if case .openSettlement = $0 { return true }; return false }.count == 1)
    }

    @Test func noSettlingTagsGivesEmptyOverview() throws {
        let plain = try Fixture()
        try #expect(plain.db.read { try Insight.settlementOverview($0, today: today) }.isEmpty)
        try #expect(plain.db.read { try Insight.searchEntries($0, filter: EntryFilter(unsettledOnly: true)) }.totalCount == 0)
    }
}

/// Totalen per omschrijving, bovenop de fixture. Zakgeld is divers (geen vaste post):
///
///   03-11-2026  "Zakgeld Kind A"    −8
///   03-12-2026  "Zakgeld Kind A"    −8
///   03-01-2027  "Zakgeld Kind A"    −10   tag zakgeld
///   03-02-2027  "zakgeld  kind a"   −10   tag zakgeld
///   03-03-2027  " Zakgeld Kind A "  −12   tag boodschappen
///   2027: 3 boekingen, −32,00, gemiddeld −10,67 per maand; 2026: 2 boekingen, −16,00
///
/// Divers in de fixture t/m 15-3-2027: Boodschappen −80 −90 · Tanken −60 −55 · Marktplaats +40 · Cadeau −30 ·
/// Uit eten −75 · Tandarts −120 · Terugbetaling +20
@Suite struct LabelTests {
    let f: Fixture
    var tagZakgeld: Int64 = 0

    init() throws {
        f = try Fixture()
        try f.db.write { db in
            var t = Tag(name: "zakgeld", color: "#778899", sortOrder: 4)
            try t.insert(db); tagZakgeld = t.id!
            for (day, amount, label, tag) in [
                ("2026-11-03", Int64(-8), "Zakgeld Kind A", nil as Int64?),
                ("2026-12-03", -8, "Zakgeld Kind A", nil),
                ("2027-01-03", -10, "Zakgeld Kind A", tagZakgeld),
                ("2027-02-03", -10, "zakgeld  kind a", tagZakgeld),
                ("2027-03-03", -12, " Zakgeld Kind A ", f.tagBoodschappen),
            ] {
                var e = Entry(accountId: f.betaal, day: d(day), amount: eur(amount), label: label)
                try e.insert(db)
                if let tag { try EntryTag(entryId: e.id!, tagId: tag).insert(db) }
            }
        }
    }

    private func totals(_ filter: LabelFilter = LabelFilter()) throws -> [LabelTotal] {
        try f.db.read { try Insight.labelTotals($0, year: 2027, today: today, filter: filter) }
    }

    @Test func defaultListGroupsAndSorts() throws {
        let list = try totals()
        // Minimaal 2 boekingen: eenmalige (Marktplaats, Cadeau, Uit eten, Tandarts, Terugbetaling) vallen weg.
        #expect(list.map(\.label) == ["Boodschappen", "Tanken", "Zakgeld Kind A"])
        #expect(list.map(\.total) == [eur(-170), eur(-115), eur(-32)])
        let z = list[2]
        #expect(z.id == "zakgeld kind a")
        #expect(z.count == 3)
        #expect(z.months[0] == eur(-10)); #expect(z.months[1] == eur(-10)); #expect(z.months[2] == eur(-12))
        #expect(z.months[3] == .zero)
        #expect(z.activeMonths == 3)
        #expect(z.averagePerActiveMonth == Money(cents: -1067))   // −32,00 ÷ 3 = −10,67
        #expect(z.firstDay == d("2027-01-03"))
        #expect(z.lastDay == d("2027-03-03"))
        // zakgeld staat bij 2 van de 3 (meerderheid), boodschappen bij 1 van de 3 (niet).
        #expect(z.tags.map(\.name) == ["zakgeld"])
        let b = list[0]
        #expect(b.activeMonths == 2)                              // januari en maart
        #expect(b.averagePerActiveMonth == eur(-85))
        #expect(b.tags.map(\.name) == ["boodschappen"])
    }

    @Test func filters() throws {
        let income = try totals(LabelFilter(kind: .income, minCount: 1))
        #expect(income.map(\.label) == ["Marktplaats", "Terugbetaling"])
        #expect(income.map(\.total) == [eur(40), eur(20)])
        let expenses = try totals(LabelFilter(kind: .expenses, minCount: 1))
        #expect(expenses.map(\.label) == ["Boodschappen", "Tandarts", "Tanken", "Uit eten", "Zakgeld Kind A", "Cadeau"])
        #expect(try totals(LabelFilter(text: "ZAK")).map(\.label) == ["Zakgeld Kind A"])
        #expect(try totals(LabelFilter(minCount: 3)).map(\.label) == ["Zakgeld Kind A"])
        #expect(try totals(LabelFilter(minCount: 1)).count == 8)
        #expect(try totals(LabelFilter(text: "bestaat niet")).isEmpty)
    }

    @Test func refToDayAndOtherYears() throws {
        // Op 15 februari telt de boeking van 3 maart nog niet mee.
        let feb = try f.db.read { try Insight.labelTotals($0, year: 2027, today: d("2027-02-15"), filter: LabelFilter(text: "zakgeld")) }
        #expect(feb.first?.total == eur(-20))
        #expect(feb.first?.count == 2)
        // 2026 is een voorbij jaar: het hele jaar telt.
        let last = try f.db.read { try Insight.labelTotals($0, year: 2026, today: today) }
        #expect(last.map(\.label) == ["Zakgeld Kind A"])
        #expect(last.first?.total == eur(-16))
        #expect(last.first?.averagePerActiveMonth == eur(-8))
    }

    @Test func mostUsedSpellingWinsAndFixedItemsAreExcluded() throws {
        try f.db.write { db in
            for label in ["ZAKGELD KIND A", "ZAKGELD KIND A", "ZAKGELD KIND A"] {
                var e = Entry(accountId: f.betaal, day: d("2027-03-04"), amount: eur(-1), label: label)
                try e.insert(db)
            }
            // Zelfde omschrijving op een vaste post en op de spaarrekening: tellen niet mee.
            var fixed = Entry(accountId: f.betaal, day: d("2027-03-04"), amount: eur(-500), label: "Zakgeld Kind A", budgetItemId: f.huur)
            try fixed.insert(db)
            var savings = Entry(accountId: f.spaar, day: d("2027-03-04"), amount: eur(-500), label: "Zakgeld Kind A")
            try savings.insert(db)
        }
        let z = try #require(try totals(LabelFilter(text: "zakgeld")).first)
        #expect(z.label == "ZAKGELD KIND A")                      // 3× tegen 2× "Zakgeld Kind A"
        #expect(z.count == 6)
        #expect(z.total == eur(-35))
    }

    @Test func entriesAndYears() throws {
        try f.db.read { db in
            let rows = try Insight.labelEntries(db, year: 2027, label: "ZAKGELD   kind a")
            #expect(rows.map(\.amount) == [eur(-10), eur(-10), eur(-12)])
            #expect(rows.map(\.day) == [d("2027-01-03"), d("2027-02-03"), d("2027-03-03")])
            #expect(rows[0].tags.map(\.name) == ["zakgeld"])
            #expect(try Insight.labelEntries(db, year: nil, label: "Zakgeld Kind A").count == 5)
            #expect(try Insight.labelEntries(db, year: 2025, label: "Zakgeld Kind A").isEmpty)

            let years = try Insight.labelYears(db, label: "zakgeld kind a")
            #expect(years == [LabelYear(year: 2026, count: 2, total: eur(-16)),
                              LabelYear(year: 2027, count: 3, total: eur(-32))])
            #expect(try Insight.labelYears(db, label: "onbekend").isEmpty)
        }
    }

    @Test func textSearchReturnsCountAndSum() throws {
        // "zakgeld" vindt de 5 diverse boekingen (−48) en "Zakgeld sparen" +25 op de spaarrekening: 6 stuks, −23,00.
        let all = try f.db.read { try Insight.searchEntries($0, filter: EntryFilter(text: "zakgeld")) }
        #expect(all.totalCount == 6)
        #expect(all.totalSum == eur(-23))
        // Alleen de betaalrekening in 2027, met een pagina van 2: het totaal blijft over alle 3 gaan.
        let page = try f.db.read {
            try Insight.searchEntries($0, filter: EntryFilter(accountId: f.betaal, year: 2027, text: "Zakgeld", limit: 2))
        }
        #expect(page.rows.count == 2)
        #expect(page.totalCount == 3)
        #expect(page.totalSum == eur(-32))
    }
}
