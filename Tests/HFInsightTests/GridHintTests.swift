import Foundation
import GRDB
import HFCore
import Testing
@testable import HFInsight

/// De hint in het celvenster: wachtende banktransacties die bij een post lijken te passen.
@Suite struct GridHintTests {
    let f: Fixture
    init() throws { f = try Fixture() }

    private func addNew(_ day: String, _ amount: Money, account: Int64? = nil, iban: String = "NL00TEST0000000077") throws -> Int64 {
        try f.db.write { db in
            var b = BankTransaction(accountId: account ?? f.betaal, day: d(day), amount: amount,
                                    counterpartyName: "Energie Test", counterpartyIban: iban,
                                    fingerprint: "hint-\(day)-\(amount.cents)-\(account ?? f.betaal)")
            try b.insert(db); return b.id!
        }
    }

    @Test func exactPlanAmountIsACandidate() throws {
        let id = try addNew("2027-03-14", eur(-150))
        let c = try f.db.read { try Insight.waitingCandidates($0, itemId: f.energie, year: 2027, month: 3, plan: eur(-150)) }
        #expect(c.map(\.id) == [id])
        #expect(c.first?.reason == .sameAmount)
    }

    @Test func ruleSuggestionComesFirstAndOtherDirectionOrAccountIsIgnored() throws {
        let byAmount = try addNew("2027-03-02", eur(-150))
        let byRule = try addNew("2027-03-14", eur(-147, 30))
        _ = try addNew("2027-03-14", eur(150))                       // andere richting
        _ = try addNew("2027-03-05", eur(-150), account: f.spaar)    // spaarrekening
        _ = try addNew("2027-04-02", eur(-150))                      // na de maand
        let c = try f.db.read {
            try Insight.waitingCandidates($0, itemId: f.energie, year: 2027, month: 3, plan: eur(-150),
                                          suggestedItems: [byRule: f.energie])
        }
        #expect(c.map(\.id) == [byRule, byAmount])
        #expect(c.map(\.reason) == [.rule, .sameAmount])
    }

    @Test func existingNewTransactionsWithOtherAmountsDoNotMatch() throws {
        // De fixture heeft al twee nieuwe pinbetalingen (−45 en −12,50) zonder koppeling met Energie.
        let c = try f.db.read { try Insight.waitingCandidates($0, itemId: f.energie, year: 2027, month: 3, plan: eur(-150)) }
        #expect(c.isEmpty)
    }

    @Test func sameCounterpartyAsEarlierBookingsMatches() throws {
        let old = try addNew("2027-01-20", eur(-160), iban: "NL00TEST0000000055")
        try f.db.write { db in
            try db.execute(sql: "UPDATE bankTransaction SET status = 'verwerkt' WHERE id = ?", arguments: [old])
            try db.execute(sql: "UPDATE entry SET bankTransactionId = ? WHERE budgetItemId = ? AND day = '2027-01-20'",
                           arguments: [old, f.energie])
        }
        let id = try addNew("2027-03-14", eur(-171, 15), iban: "NL00TEST0000000055")
        let c = try f.db.read { try Insight.waitingCandidates($0, itemId: f.energie, year: 2027, month: 3, plan: eur(-150)) }
        #expect(c.map(\.id) == [id])
        #expect(c.first?.reason == .sameCounterparty)
    }

    @Test func summaryLine() throws {
        let o = try f.db.read { try Insight.fixedItemsStatus($0, year: 2027, month: 3, today: Fixture.today) }
        #expect(o.summaryLine.hasPrefix("\(o.paidCount) van \(o.items.count) voldaan"))
        #expect(o.summaryLine.contains("te laat") == (o.lateCount > 0))
    }
}
