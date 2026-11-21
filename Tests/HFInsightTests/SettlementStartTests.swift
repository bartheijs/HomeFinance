import Foundation
import GRDB
import HFCore
import Testing
@testable import HFInsight

/// 6g: startbedrag op een verrekentag en "telt mee in nog te besteden" in besteedbaar en de kerncijfers.
/// Fixture: Tanken −60 (jan) en −55 (feb) op de betaalrekening; besteedbaar 3.040,00, nog te besteden 5.635,00.
@Suite struct SettlementStartInsightTests {
    let f: Fixture
    let today = Fixture.today
    init() throws {
        f = try Fixture()
        // Verrekenen aan voor tanken met een startbedrag van 40,00 (rechtstreeks: HFInsight kent HFBudget niet).
        try f.db.write { db in
            try db.execute(sql: "UPDATE tag SET settles = 1, startAmount = 4000, startDay = '2027-01-01' WHERE id = ?",
                           arguments: [f.tagTanken])
        }
    }

    private func setCounts(_ on: Bool) throws {
        try f.db.write { db in
            try db.execute(sql: "UPDATE tag SET countsInSpendable = ? WHERE id = ?", arguments: [on, f.tagTanken])
        }
    }

    @Test func overzichtMetStartbedrag() throws {
        let s = try f.db.read { try Insight.settlementOverview($0, today: today) }
        #expect(s.count == 1)
        #expect(s[0].outstanding == eur(155))   // 60 + 55 + 40
        #expect(s[0].openStart == eur(40))
        #expect(s[0].openCount == 3)
        #expect(s[0].oldestOpenDay == d("2027-01-01"))
        #expect(!s[0].countsInSpendable)
        let start = try f.db.read { try Insight.settlementStart($0, tagId: f.tagTanken) }
        #expect(start?.amount == eur(40) && start?.isOpen == true)
    }

    @Test func nogTeBestedenUit() throws {
        let s = try f.db.read { try Insight.spendable($0, year: 2027, today: today) }
        #expect(s.returningTags.isEmpty && s.returningTotal == .zero)
        #expect(s.spendable == eur(3040))
        #expect(s.spendableEndOfMonth == eur(5635))
    }

    @Test func nogTeBestedenAan() throws {
        try setCounts(true)
        let s = try f.db.read { try Insight.spendable($0, year: 2027, today: today) }
        #expect(s.returningTags.map(\.name) == ["tanken"])
        #expect(s.returningTotal == eur(155))
        #expect(s.spendable == eur(3195))
        #expect(s.spendableEndOfMonth == eur(5790))
        // Een voorbij jaar rekent het niet mee.
        let past = try f.db.read { try Insight.spendable($0, year: 2027, today: d("2028-02-01")) }
        #expect(past.returningTags.isEmpty && past.spendable == eur(3040))
        // Zonder verrekenen telt het ook niet mee.
        try f.db.write { try $0.execute(sql: "UPDATE tag SET settles = 0 WHERE id = ?", arguments: [f.tagTanken]) }
        #expect(try f.db.read { try Insight.spendable($0, year: 2027, today: today) }.spendable == eur(3040))
    }

    @Test func kerncijfers() throws {
        var v = try f.db.read { try Insight.keyFigures($0, today: today).values }
        let k = "tag.\(String(format: "%04lld", f.tagTanken))"
        #expect(v["kerncijfers.versie"] == "2")
        #expect(v["\(k).openstaand"] == "155.00")
        #expect(v["\(k).startbedrag"] == "40.00")
        #expect(v["\(k).teltMee"] == "nee")
        #expect(v["besteedbaarNu.terugTeKrijgen"] == "0.00")
        #expect(v["besteedbaarNu"] == "3040.00")
        try setCounts(true)
        v = try f.db.read { try Insight.keyFigures($0, today: today).values }
        #expect(v["\(k).teltMee"] == "ja")
        #expect(v["besteedbaarNu.terugTeKrijgen"] == "155.00")
        #expect(v["besteedbaarNu"] == "3195.00")
        #expect(v["nogTeBestedenDezeMaand"] == "5790.00")
    }
}
