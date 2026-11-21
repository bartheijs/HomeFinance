import Foundation
import HFCore
import Testing
@testable import HFInsight

/// De pagina Incidentele transacties: totalen kloppen met de lijst, filter en sortering.
@Suite struct IncidentalMonthTests {
    let f: Fixture
    init() throws { f = try Fixture() }

    @Test func totalsMatchTheList() throws {
        let m = try f.db.read { try Insight.incidentalMonth($0, year: 2027, month: 3) }
        #expect(!m.entries.isEmpty)
        #expect(m.entries.allSatisfy { $0.isDivers })
        #expect(m.summary.income == m.entries.map(\.amount).filter { $0 > .zero }.sum())
        #expect(m.summary.expenses == m.entries.map(\.amount).filter { $0 < .zero }.sum())
        #expect(m.summary.net == m.entries.map(\.amount).sum())
        #expect(m.expensesByTag.total == m.summary.expenses)
        #expect(m.summary.largestExpenses.count <= 5)
        #expect(m.summary.largestExpenses.map(\.amount) == m.summary.largestExpenses.map(\.amount).sorted())
    }

    @Test func filterAndSort() throws {
        let m = try f.db.read { try Insight.incidentalMonth($0, year: 2027, month: 3) }
        #expect(m.list(sign: .positive, sort: .dayDescending).allSatisfy { $0.amount > .zero })
        #expect(m.list(sign: .negative, sort: .dayDescending).allSatisfy { $0.amount < .zero })
        #expect(m.list(sign: nil, sort: .dayDescending).count == m.entries.count)
        let up = m.list(sign: nil, sort: .amountAscending).map(\.amount)
        #expect(up == up.sorted())
        let down = m.list(sign: nil, sort: .amountDescending).map(\.amount)
        #expect(down == up.sorted().reversed())
        let days = m.list(sign: nil, sort: .dayAscending).map(\.day)
        #expect(days == days.sorted())
    }
}
