import Foundation
import GRDB
import HFCore

// MARK: - Typen

/// Eén tag met de cijfers van een jaar.
public struct TagYearRow: Identifiable, Equatable, Sendable {
    public let id: Int64
    public let name: String
    public let color: String
    /// Twaalf maandtotalen, januari t/m december (t/m de peildag).
    public let months: [Money]
    /// Totaal van het jaar t/m de peildag.
    public let yearToDate: Money
    public let entryCount: Int
    /// `yearToDate` ÷ aantal (deels) verstreken maanden.
    public let averagePerMonth: Money
    /// Vorig jaar t/m dezelfde datum, of nil als de tag vorig jaar niet gebruikt is.
    public let previousYearToDate: Money?
    /// Heel vorig jaar, of nil als de tag vorig jaar niet gebruikt is.
    public let previousYearTotal: Money?
    /// `yearToDate` − `previousYearToDate`.
    public var changeFromPreviousYear: Money? { previousYearToDate.map { yearToDate - $0 } }
}

/// IN, UIT en resultaat van één maand op de betaalrekening(en).
public struct MonthResult: Identifiable, Equatable, Sendable {
    public var id: Int { month }
    public let month: Int
    public let income: Money
    public let expenses: Money
    public let result: Money
}

/// Plan tegen werkelijk voor één vaste post, t/m de peildag.
public struct BudgetVsActualRow: Identifiable, Equatable, Sendable {
    public let id: Int64
    public let label: String
    public let direction: Direction
    /// Plan × aantal verwachte maanden t/m de lopende maand.
    public let planToDate: Money
    public let actualToDate: Money
    /// `actualToDate` − `planToDate`.
    public let difference: Money
    /// Plan voor het hele jaar.
    public let planYear: Money
    /// Maanden met méér dan gepland in de richting van de post (UIT: meer uitgegeven; IN: meer ontvangen).
    public let monthsOver: Int
    /// Maanden met minder dan gepland (ook: verwacht in een voorbije maand maar niets geboekt).
    public let monthsUnder: Int
}

/// Deel van UIT divers voor één tag (`tagId` nil = zonder tag).
public struct DiversTagBucket: Identifiable, Equatable, Sendable {
    public var id: Int64 { tagId ?? 0 }
    public let tagId: Int64?
    public let name: String
    public let color: String?
    public let total: Money
    public let count: Int
}

/// Verdeling van UIT divers over tags. Een boeking met twee tags telt in beide tags mee;
/// `total` is het echte totaal van UIT divers.
public struct DiversBreakdown: Equatable, Sendable {
    public let buckets: [DiversTagBucket]
    public let total: Money
}

/// Jaartotalen van de betaalrekening(en), voor de vergelijking over jaren.
public struct YearTotals: Identifiable, Equatable, Sendable {
    public var id: Int { year }
    public let year: Int
    public let income: Money
    public let expenses: Money
    public let result: Money
    public let inDivers: Money
    public let uitDivers: Money
    /// Er bestaat een begroting voor dit jaar.
    public let hasBudget: Bool
}

/// Bedrag per tag (dashboard).
public struct TagAmount: Identifiable, Equatable, Sendable {
    public let id: Int64
    public let name: String
    public let color: String
    public let total: Money
    public let count: Int
}

// MARK: - Functies

extension Insight {
    /// Per tag (alle tags, op `sortOrder`) de maandtotalen van een jaar, het totaal t/m de peildag, het gemiddelde
    /// per verstreken maand en de vergelijking met vorig jaar.
    public static func tagYear(_ db: Database, year: Int, today: Day) throws -> [TagYearRow] {
        let asOf = Q.asOf(year, today)
        let rows = try Row.fetchAll(db, sql: """
            SELECT et.tagId, \(Q.periodMonth) AS m, SUM(e.amount) AS s, COUNT(*) AS c
            FROM entryTag et JOIN entry e ON e.id = et.entryId
            WHERE \(Q.inPeriod(year).sql) AND e.day <= ? GROUP BY et.tagId, m
            """, arguments: StatementArguments(Q.inPeriod(year).args + [today]))
        var months: [Int64: [Money]] = [:]
        var counts: [Int64: Int] = [:]
        for r in rows {
            let id: Int64 = r["tagId"], m: Int = r["m"]
            guard (1...12).contains(m) else { continue }
            months[id, default: [Money](repeating: .zero, count: 12)][m - 1] = r["s"]
            counts[id, default: 0] += r["c"] as Int
        }
        // "T/m dezelfde datum": eerdere begrotingsmaanden helemaal; in de maand van de peildag alleen t/m die dag
        // (een boeking die naar die maand verschoven is, telt helemaal).
        let dayOfMonth = String(format: "%02d", asOf.day)
        var previous: [Int64: (Money, Money)] = [:]
        for r in try Row.fetchAll(db, sql: """
            SELECT et.tagId, SUM(e.amount) AS full,
                   SUM(CASE WHEN \(Q.periodMonth) < ? OR (\(Q.periodMonth) = ?
                                 AND (e.period IS NOT NULL OR substr(e.day, 9, 2) <= ?))
                            THEN e.amount ELSE 0 END) AS toDate
            FROM entryTag et JOIN entry e ON e.id = et.entryId
            WHERE \(Q.inPeriod(year - 1).sql) GROUP BY et.tagId
            """, arguments: StatementArguments([asOf.month, asOf.month, dayOfMonth] + Q.inPeriod(year - 1).args)) {
            previous[r["tagId"]] = (r["toDate"], r["full"])
        }
        let n = Q.elapsedMonths(year, today)
        return try Tag.order(Column("sortOrder"), Column("name")).fetchAll(db).map { tag in
            let m = months[tag.id!] ?? [Money](repeating: .zero, count: 12)
            let total = m.sum()
            return TagYearRow(id: tag.id!, name: tag.name, color: tag.color, months: m, yearToDate: total,
                              entryCount: counts[tag.id!] ?? 0, averagePerMonth: Q.average(total, n),
                              previousYearToDate: previous[tag.id!]?.0, previousYearTotal: previous[tag.id!]?.1)
        }
    }

    /// De boekingen met een tag in een jaar, of in één maand daarvan (oudste eerst).
    public static func tagEntries(_ db: Database, tagId: Int64, year: Int, month: Int? = nil) throws -> [EntryRow] {
        let p = Q.inPeriod(year, month)
        return try entryRows(db, where: """
            EXISTS (SELECT 1 FROM entryTag et WHERE et.entryId = e.id AND et.tagId = ?) AND \(p.sql)
            """, arguments: [tagId] + p.args, order: "e.day ASC, e.id ASC")
    }

    /// Bedrag per tag in één maand, grootste eerst (voor het dashboard).
    public static func topTags(_ db: Database, year: Int, month: Int, limit: Int = 5) throws -> [TagAmount] {
        try Row.fetchAll(db, sql: """
            SELECT t.id, t.name, t.color, SUM(e.amount) AS s, COUNT(*) AS c
            FROM entryTag et JOIN entry e ON e.id = et.entryId JOIN tag t ON t.id = et.tagId
            WHERE \(Q.period) = ?
            GROUP BY t.id ORDER BY abs(SUM(e.amount)) DESC, t.name LIMIT ?
            """, arguments: [Q.periodKey(year, month), limit]).map {
            TagAmount(id: $0["id"], name: $0["name"], color: $0["color"], total: $0["s"], count: $0["c"])
        }
    }

    /// IN, UIT en resultaat per maand (altijd twaalf rijen) op de betaalrekening(en).
    public static func monthlyResults(_ db: Database, year: Int) throws -> [MonthResult] {
        var pos = [Money](repeating: .zero, count: 13), neg = pos
        for r in try Row.fetchAll(db, sql: """
            SELECT \(Q.periodMonth) AS m,
                   SUM(CASE WHEN e.amount > 0 THEN e.amount ELSE 0 END) AS pos,
                   SUM(CASE WHEN e.amount < 0 THEN e.amount ELSE 0 END) AS neg
            FROM entry e WHERE e.accountId IN \(Q.betaal) AND \(Q.inPeriod(year).sql) GROUP BY m
            """, arguments: StatementArguments(Q.inPeriod(year).args)) {
            let m: Int = r["m"]
            guard (1...12).contains(m) else { continue }
            pos[m] = r["pos"]; neg[m] = r["neg"]
        }
        return (1...12).map { MonthResult(month: $0, income: pos[$0], expenses: neg[$0], result: pos[$0] + neg[$0]) }
    }

    /// Plan tegen werkelijk per vaste post t/m de peildag (zonder RES-regels).
    public static func budgetVsActual(_ db: Database, year: Int, today: Day) throws -> [BudgetVsActualRow] {
        let budgetYear = try Q.budgetYear(db, year)
        let plans = PlanSet(try Q.items(db, yearId: budgetYear.id!))
        let checks = try Q.checks(db, yearId: budgetYear.id!)
        let elapsed = Q.elapsedMonths(year, today)
        var actual: [Int64: [Int: Money]] = [:]
        for r in try Row.fetchAll(db, sql: """
            SELECT e.budgetItemId AS itemId, \(Q.periodMonth) AS m, SUM(e.amount) AS s
            FROM entry e
            WHERE e.accountId IN \(Q.betaal) AND e.budgetItemId IS NOT NULL AND \(Q.inPeriod(year).sql) AND e.day <= ?
            GROUP BY e.budgetItemId, m
            """, arguments: StatementArguments(Q.inPeriod(year).args + [today])) {
            actual[r["itemId"], default: [:]][r["m"]] = r["s"]
        }
        return plans.items.filter { !$0.isReserveLine }.map { item in
            let sums = actual[item.id!] ?? [:]
            var planToDate = Money.zero, planYear = Money.zero, over = 0, under = 0
            for m in 1...12 {
                let expected = plans.expected(item, month: m)
                planYear += expected ?? .zero
                guard m <= elapsed else { continue }
                planToDate += expected ?? .zero
                let plan = expected ?? .zero
                guard let sum = sums[m] else {
                    // Niets geboekt: alleen een voorbije, verwachte maand telt als "minder dan gepland".
                    // Een afgevinkte maand geldt als voldaan.
                    if !plan.isZero, !(today.year == year && m == today.month),
                       !checks.contains(ItemMonth(item.id!, m)) { under += 1 }
                    continue
                }
                let more = item.direction == .IN ? sum > plan : sum < plan
                let less = item.direction == .IN ? sum < plan : sum > plan
                if more { over += 1 } else if less { under += 1 }
            }
            let actualToDate = sums.values.sum()
            return BudgetVsActualRow(id: item.id!, label: item.label, direction: item.direction,
                                     planToDate: planToDate, actualToDate: actualToDate,
                                     difference: actualToDate - planToDate, planYear: planYear,
                                     monthsOver: over, monthsUnder: under)
        }
    }

    /// De grootste diverse uitgaven van een jaar of van één maand (grootste uitgave eerst).
    public static func topDiversExpenses(_ db: Database, year: Int, month: Int? = nil, limit: Int = 10) throws -> [EntryRow] {
        let p = Q.inPeriod(year, month)
        return try entryRows(db, where: "a.kind = 'betaal' AND e.budgetItemId IS NULL AND e.amount < 0 AND \(p.sql)",
                             arguments: p.args, order: "e.amount ASC, e.day ASC, e.id ASC", limit: limit)
    }

    /// UIT divers van een jaar of maand verdeeld over tags (grootste eerst); zonder tag is een eigen groep.
    public static func diversByTag(_ db: Database, year: Int, month: Int? = nil) throws -> DiversBreakdown {
        let p = Q.inPeriod(year, month)
        let pArgs = StatementArguments(p.args)
        let base = "e.accountId IN \(Q.betaal) AND e.budgetItemId IS NULL AND e.amount < 0 AND \(p.sql)"
        var buckets = try Row.fetchAll(db, sql: """
            SELECT t.id, t.name, t.color, SUM(e.amount) AS s, COUNT(*) AS c
            FROM entry e JOIN entryTag et ON et.entryId = e.id JOIN tag t ON t.id = et.tagId
            WHERE \(base) GROUP BY t.id
            """, arguments: pArgs).map {
            DiversTagBucket(tagId: $0["id"] as Int64, name: $0["name"], color: $0["color"] as String, total: $0["s"], count: $0["c"])
        }
        let untagged = try Row.fetchOne(db, sql: """
            SELECT COALESCE(SUM(e.amount), 0) AS s, COUNT(*) AS c FROM entry e
            WHERE \(base) AND NOT EXISTS (SELECT 1 FROM entryTag et WHERE et.entryId = e.id)
            """, arguments: pArgs)!
        if (untagged["c"] as Int) > 0 {
            buckets.append(DiversTagBucket(tagId: nil, name: "Zonder tag", color: nil, total: untagged["s"], count: untagged["c"]))
        }
        buckets.sort { ($0.total, $0.name) < ($1.total, $1.name) }
        let total = try Money.fetchOne(db, sql: "SELECT COALESCE(SUM(e.amount), 0) FROM entry e WHERE \(base)",
                                       arguments: pArgs) ?? .zero
        return DiversBreakdown(buckets: buckets, total: total)
    }

    /// Jaartotalen voor alle jaren met boekingen op een betaalrekening (oudste eerst).
    public static func yearOverYear(_ db: Database) throws -> [YearTotals] {
        let budgetYears = Set(try Int.fetchAll(db, sql: "SELECT year FROM budgetYear"))
        return try Row.fetchAll(db, sql: """
            SELECT \(Q.periodYear) AS y,
                   SUM(CASE WHEN e.amount > 0 THEN e.amount ELSE 0 END) AS pos,
                   SUM(CASE WHEN e.amount < 0 THEN e.amount ELSE 0 END) AS neg,
                   SUM(CASE WHEN e.amount > 0 AND e.budgetItemId IS NULL THEN e.amount ELSE 0 END) AS posD,
                   SUM(CASE WHEN e.amount < 0 AND e.budgetItemId IS NULL THEN e.amount ELSE 0 END) AS negD
            FROM entry e WHERE e.accountId IN \(Q.betaal) GROUP BY y ORDER BY y
            """).map { r in
            let pos: Money = r["pos"], neg: Money = r["neg"], y: Int = r["y"]
            return YearTotals(year: y, income: pos, expenses: neg, result: pos + neg, inDivers: r["posD"],
                              uitDivers: r["negD"], hasBudget: budgetYears.contains(y))
        }
    }
}
