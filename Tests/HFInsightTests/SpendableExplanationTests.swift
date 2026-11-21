import Foundation
import HFCore
import Testing
@testable import HFInsight

/// De zin onder "nog te besteden deze maand": telt op tot hetzelfde getal en noemt de grootste inkomst.
@Suite struct SpendableExplanationTests {
    let f: Fixture
    init() throws { f = try Fixture() }

    @Test func explanationAddsUpToTheBigNumber() throws {
        let s = try f.db.read { try Insight.spendable($0, year: 2027, today: Fixture.today) }
        let e = SpendableExplanation(s)
        // saldo 3540; binnen: Salaris 3000 + open verrekening 195; af: Energie 150 + RESERVERINGEN 250 + Lening 200;
        // buffer: anti-rood 500. 3540 + 3195 − 600 − 500 = 5635.
        #expect(e.balance == eur(3540))
        #expect(e.incoming == eur(3195))
        #expect(e.outgoing == eur(600))
        #expect(e.keptAside == eur(500))
        #expect(e.balance + e.incoming - e.outgoing - e.keptAside == s.spendableEndOfMonth)
        #expect(e.total == s.spendableEndOfMonth)
        #expect(e.mainIncomeLabel == "Salaris")
        #expect(e.mainIncomeDay == d("2027-03-25"))
        #expect(e.sentence.contains("(o.a. Salaris, verwacht 25 mrt)"))
        #expect(e.sentence.hasPrefix("Nu staat er "))
    }

    @Test func pastYearHasNothingComing() throws {
        let s = try f.db.read { try Insight.spendable($0, year: 2027, today: d("2028-02-01")) }
        let e = SpendableExplanation(s)
        #expect(e.mainIncomeLabel == nil)
        #expect(e.sentence.contains("er komt deze maand niets meer binnen"))
        #expect(e.balance + e.incoming - e.outgoing - e.keptAside == s.spendableEndOfMonth)
    }

    @Test func dashboardCountsUnbookedCheckingTransactions() throws {
        let dash = try f.db.read { try Insight.dashboard($0, today: Fixture.today) }
        let expected = dash.accounts.filter { $0.kind == .betaal }.map(\.newBankTransactionCount).reduce(0, +)
        #expect(dash.unbookedCheckingTransactions == expected)
    }
}
