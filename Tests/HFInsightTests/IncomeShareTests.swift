import Foundation
import GRDB
import HFCore
import Testing
@testable import HFInsight

/// Kwartaal- en jaarinkomsten tellen elke maand een deel mee in "nog te besteden deze maand" (wens gebruiker
/// 22-11-2026). Kinderbijslag € 300 per kwartaal (jan, apr, jul, okt); vakantiegeld € 1.200 per jaar (mei).
@Suite struct IncomeShareTests {
    let f: Fixture
    init() throws {
        f = try Fixture()
        try f.db.write { db in
            let y = try Int64.fetchOne(db, sql: "SELECT id FROM budgetYear WHERE year = 2027")!
            var k = BudgetItem(yearId: y, label: "Kinderbijslag", direction: .IN, planAmount: eur(300),
                               frequency: .kwartaal, expectedMonths: "1,4,7,10", expectedDay: 1, sortOrder: 90)
            try k.insert(db)
            var v = BudgetItem(yearId: y, label: "Vakantiegeld", direction: .IN, planAmount: eur(1200),
                               frequency: .jaar, expectedMonths: "5", expectedDay: 25, sortOrder: 91)
            try v.insert(db)
        }
    }

    private func shares(_ day: String) throws -> [String: Money] {
        let s = try f.db.read { try Insight.spendable($0, year: 2027, today: d(day)) }
        return Dictionary(uniqueKeysWithValues: s.expectedItems.filter { $0.share != nil }.map { ($0.label, $0.plan) })
    }

    @Test func sharesGrowUntilThePayment() throws {
        // Februari: 1 van 3 delen kinderbijslag; vakantiegeld 9 van 12 (na mei vorig jaar).
        #expect(try shares("2027-02-10") == ["Kinderbijslag": eur(100), "Vakantiegeld": eur(900)])
        // Maart: 2 van 3 en 10 van 12.
        #expect(try shares("2027-03-15") == ["Kinderbijslag": eur(200), "Vakantiegeld": eur(1000)])
        // November: na oktober weer 1 van 3, op weg naar januari.
        #expect(try shares("2027-11-05")["Kinderbijslag"] == eur(100))
    }

    @Test func paymentMonthCountsTheFullAmountOnce() throws {
        // April: kinderbijslag wordt verwacht en telt als gewone verwachte post, niet als deel.
        let s = try f.db.read { try Insight.spendable($0, year: 2027, today: d("2027-04-01")) }
        let k = s.expectedItems.filter { $0.label == "Kinderbijslag" }
        #expect(k.count == 1)
        #expect(k.first?.plan == eur(300))
        #expect(k.first?.share == nil)
    }

    @Test func breakdownStillAddsUp() throws {
        let s = try f.db.read { try Insight.spendable($0, year: 2027, today: d("2027-03-15")) }
        let without = try Fixture().db.read { try Insight.spendable($0, year: 2027, today: d("2027-03-15")) }
        #expect(s.spendableEndOfMonth == without.spendableEndOfMonth + eur(1200))
        #expect(s.spendable == without.spendable)       // besteedbaar nu verandert niet
        let b = SpendableBreakdown(s)
        #expect(b.addsUp)
        #expect(b.expectedIncome.contains { $0.title == "Kinderbijslag (2 van 3 delen, komt in apr)" })
    }

    @Test func expensesAreNotSpread() throws {
        // Verzekering (uitgave per kwartaal) telt alleen in de maand dat hij komt.
        let s = try f.db.read { try Insight.spendable($0, year: 2027, today: d("2027-03-15")) }
        #expect(!s.expectedItems.contains { $0.label == "Verzekering" })
    }
}
