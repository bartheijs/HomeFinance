import Foundation
import GRDB
import HFCore

// MARK: - Typen

/// Laatste afstemming van een rekening.
public struct ReconciliationInfo: Equatable, Sendable {
    public let day: Day
    public let actualBalance: Money
    public let calculatedBalance: Money
    /// Berekend − werkelijk; hoort € 0,00 te zijn.
    public let difference: Money
    public let createdAt: Date
}

/// Laatste import van een rekening.
public struct ImportInfo: Equatable, Sendable {
    public let fileName: String
    public let importedAt: Date
    public let lastDay: Day?
    public let closingBalance: Money?
    public let newCount: Int
    public let chainOK: Bool
}

/// Eén rekening in het rekeningoverzicht.
public struct AccountOverview: Identifiable, Equatable, Sendable {
    public let id: Int64
    public let name: String
    public let iban: String?
    public let kind: AccountKind
    public let archived: Bool
    /// Saldo op de peildag.
    public let balance: Money
    public let lastReconciliation: ReconciliationInfo?
    /// Banktransacties met status `nieuw`.
    public let newBankTransactionCount: Int
    /// Boekingen die nog nagekeken moeten worden.
    public let unreviewedEntryCount: Int
    public let lastImport: ImportInfo?
}

/// Punt in een saldoreeks.
public struct BalancePoint: Identifiable, Equatable, Sendable {
    public var id: Day { day }
    public let day: Day
    public let balance: Money
}

/// Stapgrootte van een saldoreeks.
public enum SeriesStep: String, Sendable, CaseIterable {
    /// Elke dag.
    case daily
    /// Elk maandeinde, plus de einddag als die geen maandeinde is.
    case monthEnd
}

/// Vaste post die deze maand nog verwacht wordt (onderdeel van de simulatie "eind van de maand").
public struct ExpectedItem: Identifiable, Equatable, Sendable {
    public let id: Int64
    public let label: String
    public let direction: Direction
    public let plan: Money
    public let expectedDay: Int?
    /// De verwachte dag is al voorbij.
    public let isLate: Bool
}

/// Besteedbaar, met de simulatie tot het eind van de maand.
public struct Spendable: Equatable, Sendable {
    public let year: Int
    /// Peildag: vandaag, of 31-12 voor een voorbij jaar.
    public let asOf: Day
    /// Saldo van alle betaalrekeningen.
    public let balance: Money
    public let antiRood: Money
    /// Wat nu nog uitstaat van bedragen die tijdelijk van spaar geleend zijn (boekingen met `temporaryLoan`
    /// op betaalrekeningen, alle jaren t/m de peildag; nooit negatief).
    public let tijdelijkAntiRood: Money
    /// Besteedbaar = saldo − antiRood − tijdelijkAntiRood.
    /// Geld met een bestemming staat in potten op de spaarrekening, niet op de betaalrekening.
    public let spendable: Money
    /// Posten die deze maand verwacht worden en nog geen boeking hebben (leeg buiten het lopende jaar).
    public let expectedItems: [ExpectedItem]
    public let expectedTotal: Money
    /// Netto bedrag van alle open verrekeningen met spaar (gemarkeerde boekingen die nog niet in een afgevinkte
    /// verrekening zitten), met teken vanuit de betaalrekening: positief = er komt nog geld van spaar naar betaal,
    /// negatief = er moet nog geld van betaal naar spaar. Alleen in het lopende jaar, anders € 0,00.
    public let pendingSettlement: Money
    /// Besteedbaar eind van de maand = `spendable` + `expectedTotal` + `pendingSettlement`.
    public let spendableEndOfMonth: Money
}

/// Jaaroverzicht van de betaalrekening(en), zoals het jaarblad van de Excel.
public struct YearSummary: Equatable, Sendable {
    public let year: Int
    public let asOf: Day
    /// Op de rekening op 1-1 (inclusief het beginsaldo van rekeningen die in de loop van het jaar starten).
    public let openingBalance: Money
    /// Alle inkomsten t/m de peildag.
    public let income: Money
    /// Alle uitgaven t/m de peildag (negatief).
    public let expenses: Money
    /// IN + UIT (begrotingsjaar) − wat er volgens de datum in het jaar is geboekt: boekingen die via `period`
    /// over de jaargrens (of voorbij de peildag) zijn verschoven. Meestal € 0,00.
    public let shiftedAcrossYear: Money
    /// Op de rekening (volgt de datum) = begin + IN + UIT − `shiftedAcrossYear`.
    public let balance: Money
    public let antiRood: Money
    public let tijdelijkAntiRood: Money
    public let spendable: Money
    public let inDivers: Money
    public let uitDivers: Money
    /// Aantal (deels) verstreken maanden waarover het gemiddelde is berekend.
    public let elapsedMonths: Int
    public let averageIncome: Money
    public let averageExpenses: Money
    public let averageInDivers: Money
    public let averageUitDivers: Money

    public var result: Money { income + expenses }
    public var buffers: Money { antiRood + tijdelijkAntiRood }
}

/// Punt in de trend van besteedbaar.
public struct SpendablePoint: Identifiable, Equatable, Sendable {
    public var id: Day { day }
    public let day: Day
    public let balance: Money
    public let spendable: Money
}

// MARK: - Functies

extension Insight {
    /// Saldo van een rekening op een dag = beginsaldo + som van de boekingen t/m die dag.
    public static func balance(_ db: Database, accountId: Int64, on day: Day) throws -> Money {
        guard let m = try Money.fetchOne(db, sql: """
            SELECT a.openingBalance + COALESCE((SELECT SUM(e.amount) FROM entry e
                                                WHERE e.accountId = a.id AND e.day <= ?), 0)
            FROM account a WHERE a.id = ?
            """, arguments: [day, accountId]) else { throw InsightError.accountNotFound(accountId) }
        return m
    }

    /// Saldo van alle betaalrekeningen samen op een dag.
    public static func checkingBalance(_ db: Database, on day: Day) throws -> Money {
        try Money.fetchOne(db, sql: """
            SELECT COALESCE((SELECT SUM(openingBalance) FROM account WHERE kind = 'betaal'), 0)
                 + COALESCE((SELECT SUM(e.amount) FROM entry e WHERE e.accountId IN \(Q.betaal) AND e.day <= ?), 0)
            """, arguments: [day]) ?? .zero
    }

    /// Alle rekeningen (op `sortOrder`, ook gearchiveerde) met saldo, laatste afstemming, aantallen en laatste import.
    public static func accountOverview(_ db: Database, today: Day) throws -> [AccountOverview] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT a.id, a.name, a.iban, a.kind, a.archived,
                   a.openingBalance + COALESCE((SELECT SUM(e.amount) FROM entry e
                                                WHERE e.accountId = a.id AND e.day <= ?), 0) AS balance,
                   (SELECT COUNT(*) FROM bankTransaction b WHERE b.accountId = a.id AND b.status = 'nieuw') AS newCount,
                   (SELECT COUNT(*) FROM entry e WHERE e.accountId = a.id AND e.reviewed = 0) AS unreviewed,
                   (SELECT r.id FROM reconciliation r WHERE r.accountId = a.id
                    ORDER BY r.day DESC, r.createdAt DESC, r.id DESC LIMIT 1) AS recId,
                   (SELECT i.id FROM importBatch i WHERE i.accountId = a.id
                    ORDER BY i.importedAt DESC, i.id DESC LIMIT 1) AS batchId
            FROM account a ORDER BY a.sortOrder, a.id
            """, arguments: [today])
        let recIds = rows.compactMap { $0["recId"] as Int64? }
        let batchIds = rows.compactMap { $0["batchId"] as Int64? }
        let recs = Dictionary(uniqueKeysWithValues: try Reconciliation.filter(recIds.contains(Column("id"))).fetchAll(db).map { ($0.id!, $0) })
        let batches = Dictionary(uniqueKeysWithValues: try ImportBatch.filter(batchIds.contains(Column("id"))).fetchAll(db).map { ($0.id!, $0) })
        return rows.map { r in
            let rec = (r["recId"] as Int64?).flatMap { recs[$0] }
            let batch = (r["batchId"] as Int64?).flatMap { batches[$0] }
            return AccountOverview(
                id: r["id"], name: r["name"], iban: r["iban"], kind: r["kind"], archived: r["archived"],
                balance: r["balance"],
                lastReconciliation: rec.map {
                    ReconciliationInfo(day: $0.day, actualBalance: $0.actualBalance, calculatedBalance: $0.calculatedBalance,
                                       difference: $0.difference, createdAt: $0.createdAt)
                },
                newBankTransactionCount: r["newCount"], unreviewedEntryCount: r["unreviewed"],
                lastImport: batch.map {
                    ImportInfo(fileName: $0.fileName, importedAt: $0.importedAt, lastDay: $0.lastDay,
                               closingBalance: $0.closingBalance, newCount: $0.newCount, chainOK: $0.chainOK)
                })
        }
    }

    /// Peildagen van `from` t/m `to` voor een reeks.
    static func seriesDays(from: Day, to: Day, step: SeriesStep) -> [Day] {
        guard from <= to else { return [] }
        var days: [Day] = []
        switch step {
        case .daily:
            var d = from
            while d <= to { days.append(d); d = d.adding(days: 1) }
        case .monthEnd:
            var (y, m) = (from.year, from.month)
            while (y, m) <= (to.year, to.month) {
                let end = Q.lastDay(y, m)
                days.append(end <= to ? end : to)
                m += 1
                if m > 12 { m = 1; y += 1 }
            }
        }
        return days
    }

    /// Saldo op elk van de peildagen (oplopend) voor een set rekeningen; `accountClause` is een SQL-voorwaarde op `accountId`.
    static func balances(_ db: Database, accountClause: String, arguments: [(any DatabaseValueConvertible)?],
                         at points: [Day]) throws -> [Money] {
        guard let last = points.last else { return [] }
        let opening = try Money.fetchOne(db, sql: "SELECT COALESCE(SUM(openingBalance), 0) FROM account WHERE id \(accountClause)",
                                         arguments: StatementArguments(arguments)) ?? .zero
        let rows = try Row.fetchAll(db, sql: """
            SELECT day, SUM(amount) AS s FROM entry WHERE accountId \(accountClause) AND day <= ? GROUP BY day ORDER BY day
            """, arguments: StatementArguments(arguments + [last])).map { ($0["day"] as Day, $0["s"] as Money) }
        return Q.cumulative(rows, at: points, start: opening)
    }

    /// Saldoreeks van één rekening voor een grafiek, per dag of per maandeinde.
    public static func balanceSeries(_ db: Database, accountId: Int64, from: Day, to: Day,
                                     step: SeriesStep = .daily) throws -> [BalancePoint] {
        let days = seriesDays(from: from, to: to, step: step)
        let values = try balances(db, accountClause: "= ?", arguments: [accountId], at: days)
        return zip(days, values).map { BalancePoint(day: $0, balance: $1) }
    }

    /// Saldoreeks van alle betaalrekeningen samen.
    public static func checkingBalanceSeries(_ db: Database, from: Day, to: Day,
                                             step: SeriesStep = .daily) throws -> [BalancePoint] {
        let days = seriesDays(from: from, to: to, step: step)
        let values = try balances(db, accountClause: "IN \(Q.betaal)", arguments: [], at: days)
        return zip(days, values).map { BalancePoint(day: $0, balance: $1) }
    }

    /// Uitstaand tijdelijk anti-rood op een dag: som van de boekingen met `temporaryLoan` op betaalrekeningen
    /// t/m die dag (lenen is +, terugboeken is −), met nul als ondergrens.
    public static func temporaryLoanOutstanding(_ db: Database, on day: Day) throws -> Money {
        let sum = try Money.fetchOne(db, sql: """
            SELECT COALESCE(SUM(e.amount), 0) FROM entry e
            WHERE e.temporaryLoan = 1 AND e.accountId IN \(Q.betaal) AND e.day <= ?
            """, arguments: [day]) ?? .zero
        return max(sum, .zero)
    }

    /// De boekingen die als tijdelijk geleend zijn gemarkeerd, nieuwste eerst.
    public static func temporaryLoanEntries(_ db: Database) throws -> [EntryRow] {
        try entryRows(db, where: "e.temporaryLoan = 1", arguments: [], order: "e.day DESC, e.id DESC")
    }

    /// Besteedbaar van een jaar op de peildag, met de simulatie tot het eind van de lopende maand.
    /// Gooit `InsightError.yearNotFound` als het jaar nog geen begroting heeft.
    public static func spendable(_ db: Database, year: Int, today: Day) throws -> Spendable {
        let budgetYear = try Q.budgetYear(db, year)
        let asOf = Q.asOf(year, today)
        let balance = try checkingBalance(db, on: asOf)
        let borrowed = try temporaryLoanOutstanding(db, on: asOf)
        let spendable = balance - budgetYear.antiRood - borrowed

        var expected: [ExpectedItem] = []
        if today.year == year {
            let plans = PlanSet(try Q.items(db, yearId: budgetYear.id!))
            // "Geboekt" volgt de begrotingsmaand; een afgevinkte post geldt ook als voldaan.
            let booked = Set(try Int64.fetchAll(db, sql: """
                SELECT DISTINCT e.budgetItemId FROM entry e
                WHERE e.budgetItemId IS NOT NULL AND e.accountId IN \(Q.betaal) AND \(Q.period) = ? AND e.day <= ?
                """, arguments: [Q.periodKey(year, today.month), today]))
            let checks = try Q.checks(db, yearId: budgetYear.id!)
            for item in plans.items where !booked.contains(item.id!) && !checks.contains(ItemMonth(item.id!, today.month)) {
                guard let plan = plans.expected(item, month: today.month), !plan.isZero else { continue }
                expected.append(ExpectedItem(id: item.id!, label: item.label, direction: item.direction, plan: plan,
                                             expectedDay: item.expectedDay,
                                             isLate: item.expectedDay.map { today.day > $0 } ?? false))
            }
        }
        let expectedTotal = expected.map(\.plan).sum()
        let pending = today.year == year ? try pendingSettlementNet(db) : .zero
        return Spendable(year: year, asOf: asOf, balance: balance, antiRood: budgetYear.antiRood,
                         tijdelijkAntiRood: borrowed, spendable: spendable,
                         expectedItems: expected, expectedTotal: expectedTotal, pendingSettlement: pending,
                         spendableEndOfMonth: spendable + expectedTotal + pending)
    }

    /// Het jaaroverzicht (op de rekening op 1-1, IN, UIT, op de rekening, buffers, besteedbaar,
    /// divers en gemiddelden per verstreken maand).
    public static func yearSummary(_ db: Database, year: Int, today: Day) throws -> YearSummary {
        let s = try spendable(db, year: year, today: today)
        let r = try Row.fetchOne(db, sql: """
            SELECT COALESCE(SUM(CASE WHEN e.amount > 0 THEN e.amount ELSE 0 END), 0) AS pos,
                   COALESCE(SUM(CASE WHEN e.amount < 0 THEN e.amount ELSE 0 END), 0) AS neg,
                   COALESCE(SUM(CASE WHEN e.amount > 0 AND e.budgetItemId IS NULL THEN e.amount ELSE 0 END), 0) AS posD,
                   COALESCE(SUM(CASE WHEN e.amount < 0 AND e.budgetItemId IS NULL THEN e.amount ELSE 0 END), 0) AS negD
            FROM entry e WHERE e.accountId IN \(Q.betaal) AND \(Q.inPeriod(year).sql) AND e.day <= ?
            """, arguments: StatementArguments(Q.inPeriod(year).args + [today]))!
        let income: Money = r["pos"], expenses: Money = r["neg"], inD: Money = r["posD"], uitD: Money = r["negD"]
        // Wat er volgens de echte datum in het jaar is bij- en afgeschreven; bepaalt "op de rekening op 1-1".
        let byDate = try Money.fetchOne(db, sql: """
            SELECT COALESCE(SUM(e.amount), 0) FROM entry e
            WHERE e.accountId IN \(Q.betaal) AND e.day >= ? AND e.day <= ?
            """, arguments: [Q.yearStart(year), s.asOf]) ?? .zero
        let n = Q.elapsedMonths(year, today)
        return YearSummary(year: year, asOf: s.asOf, openingBalance: s.balance - byDate,
                           income: income, expenses: expenses, shiftedAcrossYear: income + expenses - byDate,
                           balance: s.balance,
                           antiRood: s.antiRood, tijdelijkAntiRood: s.tijdelijkAntiRood, spendable: s.spendable,
                           inDivers: inD, uitDivers: uitD, elapsedMonths: n,
                           averageIncome: Q.average(income, n), averageExpenses: Q.average(expenses, n),
                           averageInDivers: Q.average(inD, n), averageUitDivers: Q.average(uitD, n))
    }

    /// Besteedbaar per maandeinde van het jaar t/m de peildag (het laatste punt is de peildag zelf), voor een trendgrafiek.
    public static func spendableSeries(_ db: Database, year: Int, today: Day) throws -> [SpendablePoint] {
        let budgetYear = try Q.budgetYear(db, year)
        guard today.year >= year else { return [] }
        let asOf = Q.asOf(year, today)
        let days = seriesDays(from: Day(year: year, month: 1, day: 1)!, to: asOf, step: .monthEnd)
        let balances = try balances(db, accountClause: "IN \(Q.betaal)", arguments: [], at: days)
        let borrowed = try days.map { try temporaryLoanOutstanding(db, on: $0) }
        return days.indices.map {
            SpendablePoint(day: days[$0], balance: balances[$0],
                           spendable: balances[$0] - budgetYear.antiRood - borrowed[$0])
        }
    }
}
