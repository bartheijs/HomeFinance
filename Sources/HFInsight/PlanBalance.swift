import Foundation
import GRDB
import HFCore

// MARK: - Typen

/// Eén vaste post in de maandbalans.
public struct PlanBalanceRow: Identifiable, Equatable, Sendable {
    public let id: Int64
    public let label: String
    public let direction: Direction
    public let frequency: Frequency
    /// Aantal maanden per jaar waarin de post verwacht wordt (12 bij een maandpost).
    public let timesPerYear: Int
    public let isReserveTotal: Bool
    /// Plan per keer, met teken (bij RESERVERINGEN de som van de RES-regels).
    public let plan: Money
    /// Plan omgerekend naar een maand: plan × `timesPerYear` ÷ 12, afgerond op centen.
    public let planPerMonth: Money
    /// Wat-als-bedrag per keer, of nil als het niet is ingevuld.
    public let scenario: Money?
    /// Wat-als omgerekend naar een maand, of nil.
    public let scenarioPerMonth: Money?
    /// `scenarioPerMonth` − `planPerMonth`, of nil zonder wat-als-bedrag.
    public let difference: Money?

    /// Inkomsten (richting IN); al het andere telt als uitgave.
    public var isIncome: Bool { direction == .IN }
}

/// Inkomsten, uitgaven en overschot (per maand of per jaar).
public struct PlanBalanceTotals: Equatable, Sendable {
    public let income: Money
    /// Negatief.
    public let expenses: Money
    /// `income` + `expenses`: wat er overblijft.
    public let surplus: Money
}

/// De maandbalans van een jaar: wat blijft er per maand over van de vaste posten, voor het plan en voor de
/// wat-als-variant.
public struct PlanBalance: Equatable, Sendable {
    public let year: Int
    /// Eerst de inkomsten, dan de uitgaven; binnen elke groep op `sortOrder`. Zonder RES-regels.
    public let rows: [PlanBalanceRow]
    /// Er is bij minstens één post een wat-als-bedrag ingevuld.
    public let hasScenario: Bool
    /// Per maand.
    public let plan: PlanBalanceTotals
    /// Per maand; posten zonder wat-als-bedrag tellen met hun plan.
    public let scenario: PlanBalanceTotals
    /// `scenario` − `plan`, per maand.
    public let difference: PlanBalanceTotals
    /// Per jaar (plan × aantal keer per jaar, zonder afronding per maand).
    public let planYear: PlanBalanceTotals
    public let scenarioYear: PlanBalanceTotals
    public let differenceYear: PlanBalanceTotals

    public var incomeRows: [PlanBalanceRow] { rows.filter(\.isIncome) }
    public var expenseRows: [PlanBalanceRow] { rows.filter { !$0.isIncome } }
}

// MARK: - Functies

extension Insight {
    /// De maandbalans van een jaar. RES-regels doen niet mee; RESERVERINGEN en posten bij een vaste storting wel.
    /// Gooit `InsightError.yearNotFound` als het jaar nog geen begroting heeft.
    public static func planBalance(_ db: Database, year: Int) throws -> PlanBalance {
        let budgetYear = try Q.budgetYear(db, year)
        let plans = PlanSet(try Q.items(db, yearId: budgetYear.id!))
        let reserveLines = plans.items.filter(\.isReserveLine)
        // Wat-als voor RESERVERINGEN: het eigen bedrag, anders de som van de RES-regels als daar iets is ingevuld.
        let reserveScenario: Money? = reserveLines.contains { $0.scenarioAmount != nil }
            ? reserveLines.map { $0.scenarioAmount ?? $0.planAmount }.sum() : nil

        struct Sums { var income = Money.zero, expenses = Money.zero }
        var planMonth = Sums(), scenarioMonth = Sums(), planYear = Sums(), scenarioYear = Sums()
        func add(_ sums: inout Sums, _ amount: Money, income: Bool) {
            if income { sums.income += amount } else { sums.expenses += amount }
        }
        func times(_ amount: Money, _ n: Int) -> Money { Money(cents: amount.cents * Int64(n)) }

        var rows: [PlanBalanceRow] = []
        for item in plans.items where !item.isReserveLine {
            let n = Set(item.months.filter { (1...12).contains($0) }).count
            let plan = plans.plan(item)
            let scenario = item.scenarioAmount ?? (item.isReserveTotal ? reserveScenario : nil)
            let planPerMonth = Q.average(times(plan, n), 12)
            let scenarioPerMonth = scenario.map { Q.average(times($0, n), 12) }
            let row = PlanBalanceRow(id: item.id!, label: item.label, direction: item.direction, frequency: item.frequency,
                                     timesPerYear: n, isReserveTotal: item.isReserveTotal, plan: plan,
                                     planPerMonth: planPerMonth, scenario: scenario, scenarioPerMonth: scenarioPerMonth,
                                     difference: scenarioPerMonth.map { $0 - planPerMonth })
            rows.append(row)
            add(&planMonth, planPerMonth, income: row.isIncome)
            add(&scenarioMonth, scenarioPerMonth ?? planPerMonth, income: row.isIncome)
            add(&planYear, times(plan, n), income: row.isIncome)
            add(&scenarioYear, times(scenario ?? plan, n), income: row.isIncome)
        }
        func totals(_ s: Sums) -> PlanBalanceTotals {
            PlanBalanceTotals(income: s.income, expenses: s.expenses, surplus: s.income + s.expenses)
        }
        func minus(_ a: PlanBalanceTotals, _ b: PlanBalanceTotals) -> PlanBalanceTotals {
            PlanBalanceTotals(income: a.income - b.income, expenses: a.expenses - b.expenses, surplus: a.surplus - b.surplus)
        }
        let (pm, sm, py, sy) = (totals(planMonth), totals(scenarioMonth), totals(planYear), totals(scenarioYear))
        return PlanBalance(year: year, rows: rows.filter(\.isIncome) + rows.filter { !$0.isIncome },
                           hasScenario: rows.contains { $0.scenario != nil },
                           plan: pm, scenario: sm, difference: minus(sm, pm),
                           planYear: py, scenarioYear: sy, differenceYear: minus(sy, py))
    }
}
