import Foundation
import GRDB
import HFCore

/// Incidentele transacties van één maand: alles op de betaalrekening(en) zonder vaste post ("divers").
public struct IncidentalSummary: Equatable, Sendable {
    public let year: Int
    public let month: Int
    /// Som van de bijschrijvingen (positief).
    public let income: Money
    /// Som van de uitgaven (negatief).
    public let expenses: Money
    /// De grootste uitgaven, grootste eerst.
    public let largestExpenses: [EntryRow]

    /// In + uit.
    public var net: Money { income + expenses }
}

extension FixedItemsOverview {
    private var incomeItems: [FixedItemStatus] { items.filter { $0.direction == .IN } }
    private var expenseItems: [FixedItemStatus] { items.filter { $0.direction != .IN } }

    /// Wat er deze maand al geboekt is op de inkomende vaste posten.
    public var incomeBooked: Money { incomeItems.map(\.actual).sum() }
    /// Wat er deze maand al geboekt is op de uitgaande vaste posten (negatief).
    public var expensesBooked: Money { expenseItems.map(\.actual).sum() }
    /// Plan van de inkomende posten die nog moeten komen (open of te laat).
    public var incomeExpected: Money { incomeItems.filter { $0.state != .voldaan }.map(\.plan).sum() }
    /// Plan van de uitgaande posten die nog moeten komen (negatief).
    public var expensesExpected: Money { expenseItems.filter { $0.state != .voldaan }.map(\.plan).sum() }
    /// Nog binnen + nog af.
    public var expectedNet: Money { incomeExpected + expensesExpected }
}

extension Dashboard {
    /// Saldo van alle betaalrekeningen.
    public var checkingTotal: Money { accounts.filter { $0.kind == .betaal }.map(\.balance).sum() }
    /// Saldo van alle spaarrekeningen.
    public var savingsTotal: Money { accounts.filter { $0.kind != .betaal }.map(\.balance).sum() }
    /// Betaal + spaar.
    public var accountsTotal: Money { accounts.map(\.balance).sum() }
}

extension Insight {
    /// In, uit en de grootste uitgaven zonder vaste post op de betaalrekening(en) in één begrotingsmaand.
    public static func incidentalSummary(_ db: Database, year: Int, month: Int, largest: Int = 3) throws -> IncidentalSummary {
        let p = inPeriodDivers(year, month)
        let row = try Row.fetchOne(db, sql: """
            SELECT COALESCE(SUM(CASE WHEN e.amount > 0 THEN e.amount ELSE 0 END), 0) AS pos,
                   COALESCE(SUM(CASE WHEN e.amount < 0 THEN e.amount ELSE 0 END), 0) AS neg
            FROM entry e WHERE \(p.sql)
            """, arguments: StatementArguments(p.args))!
        return IncidentalSummary(year: year, month: month, income: row["pos"], expenses: row["neg"],
                                 largestExpenses: try topDiversExpenses(db, year: year, month: month, limit: largest))
    }

    /// Voorwaarde voor "zonder vaste post op een betaalrekening in deze begrotingsmaand".
    static func inPeriodDivers(_ year: Int, _ month: Int) -> (sql: String, args: [(any DatabaseValueConvertible)?]) {
        let p = Q.inPeriod(year, month)
        return ("e.accountId IN \(Q.betaal) AND e.budgetItemId IS NULL AND \(p.sql)", p.args)
    }
}
