import Foundation
import HFCore
import Testing
@testable import HFInsight

/// De rekensom onder "Nog te besteden deze maand": de regels tellen exact op tot het grote getal.
@Suite struct SpendableBreakdownTests {
    let f: Fixture
    init() throws { f = try Fixture() }

    @Test func linesAddUpToTheBigNumber() throws {
        let s = try f.db.read { try Insight.spendable($0, year: 2027, today: Fixture.today) }
        let b = SpendableBreakdown(s)
        // saldo 3540 − buffer 500 + nog verwacht (Salaris 3000 + open verrekening 195 − Energie 150
        // − RESERVERINGEN 250 − Lening 200 = 2595) = 5635.
        #expect(b.lines.map(\.kind) == [.balance, .buffer, .expected])
        #expect(b.lines.map(\.amount) == [eur(3540), eur(-500), eur(2595)])
        #expect(b.expectedNet == eur(2595))
        #expect(b.expectedIncome.map(\.amount).sum() == eur(3195))
        #expect(b.expectedExpenses.map(\.amount).sum() == eur(-600))
        #expect(b.expectedIncome.allSatisfy { $0.amount > .zero })
        #expect(b.expectedExpenses.allSatisfy { $0.amount < .zero })
        #expect(b.total == s.spendableEndOfMonth)
        #expect(b.addsUp)
        #expect(b.lines.map(\.amount).sum() == eur(5635))
    }

    @Test func pastYearHasNothingExpected() throws {
        let s = try f.db.read { try Insight.spendable($0, year: 2027, today: d("2028-02-01")) }
        let b = SpendableBreakdown(s)
        #expect(b.expectedIncome.isEmpty)
        #expect(b.addsUp)
    }

    @Test func dashboardCountsUnbookedCheckingTransactions() throws {
        let dash = try f.db.read { try Insight.dashboard($0, today: Fixture.today) }
        let expected = dash.accounts.filter { $0.kind == .betaal }.map(\.newBankTransactionCount).reduce(0, +)
        #expect(dash.unbookedCheckingTransactions == expected)
    }
}
