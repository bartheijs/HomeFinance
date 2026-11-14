import Foundation
import GRDB
import HFCore

// MARK: - Typen

/// Status van een cel in het maandgrid (zie de spec, "Celstatus").
public enum CellStatus: String, Sendable, CaseIterable {
    /// Geboekt en gelijk aan het plan.
    case gelijk
    /// Geboekt, maar anders dan het plan (ook: geboekt in een maand waarin de post niet verwacht wordt).
    case afwijkend
    /// De post komt deze maand niet voor, of de maand ligt in de toekomst.
    case nietVerwacht
    /// Verwacht, nog niet geboekt, nog niet te laat.
    case open
    /// Verwacht, niet geboekt en de verwachte dag of de maand is voorbij.
    case teLaat
    /// Niet geboekt, maar met de hand afgevinkt: telt als voldaan.
    case afgevinkt
}

/// Soort rij in het maandgrid.
public enum GridRowKind: String, Sendable, CaseIterable {
    /// Gewone vaste post (IN of UIT).
    case item
    /// De regel RESERVERINGEN; plan = som van de RES-regels.
    case reserveTotal
    /// RES-regel: alleen ter informatie, telt niet mee in totalen.
    case reserveLine
}

/// Eén cel: een vaste post in één maand.
public struct GridCell: Equatable, Sendable {
    public let month: Int
    /// Som van de boekingen.
    public let sum: Money
    public let entryCount: Int
    public let status: CellStatus
    /// Verwacht bedrag, of nil als de post deze maand niet verwacht wordt.
    public let expected: Money?
    /// `sum` − verwacht bedrag (0 als er niets verwacht wordt).
    public let difference: Money
    /// De post is voor deze maand met de hand afgevinkt (`ItemCheck`), met of zonder boeking.
    public let isChecked: Bool
}

/// Eén rij van het maandgrid.
public struct GridRow: Identifiable, Equatable, Sendable {
    public let id: Int64
    public let label: String
    public let direction: Direction
    public let kind: GridRowKind
    /// Planbedrag per keer (bij RESERVERINGEN de som van de RES-regels).
    public let plan: Money
    public let frequency: Frequency
    public let expectedMonths: [Int]
    public let expectedDay: Int?
    public let potId: Int64?
    /// Twaalf cellen, januari t/m december.
    public let cells: [GridCell]
    /// Som van alle boekingen in het jaar.
    public let yearTotal: Money
    /// Plan × aantal verwachte maanden.
    public let planYearTotal: Money

    /// RES-regel: tonen als opbouw, niet meetellen.
    public var isInformational: Bool { kind == .reserveLine }
}

/// De totaalrijen van één maand (of van het hele jaar).
public struct GridTotals: Equatable, Sendable {
    /// 1–12, of 0 voor het jaartotaal.
    public let month: Int
    /// Som van de boekingen op vaste posten (zonder RES-regels).
    public let fixed: Money
    public let inDivers: Money
    public let uitDivers: Money
    public let nettoDivers: Money
    /// Alles: alle boekingen op betaalrekeningen.
    public let result: Money
    /// Som van het plan van de posten die deze maand verwacht worden (zonder RES-regels).
    public let planExpected: Money
    /// Ruimte t.o.v. maandbudget = `planExpected` + IN divers + UIT divers.
    public let ruimte: Money
}

/// Het maandgrid van één jaar.
public struct MonthGrid: Equatable, Sendable {
    public let year: Int
    public let closed: Bool
    public let rows: [GridRow]
    /// Twaalf totaalregels, januari t/m december.
    public let monthTotals: [GridTotals]
    public let yearTotals: GridTotals
}

/// Stand van een vaste post in een maand.
public enum FixedItemState: String, Sendable, CaseIterable {
    /// Betaald of ontvangen.
    case voldaan
    case open
    case teLaat
}

/// Eén verwachte vaste post in de gevraagde maand.
public struct FixedItemStatus: Identifiable, Equatable, Sendable {
    public let id: Int64
    public let label: String
    public let direction: Direction
    public let state: FixedItemState
    public let plan: Money
    /// Som van de boekingen (0 als er nog niets geboekt is).
    public let actual: Money
    /// `actual` − `plan`; alleen zinvol bij `voldaan`.
    public let difference: Money
    /// Dag van de (laatste) boeking, of nil.
    public let day: Day?
    public let expectedDay: Int?
    public let entryCount: Int
    /// Met de hand afgevinkt; zonder boeking is de stand dan `voldaan` met `actual` € 0,00.
    public let isChecked: Bool
}

/// Overzicht van de vaste posten van één maand.
public struct FixedItemsOverview: Equatable, Sendable {
    public let year: Int
    public let month: Int
    public let items: [FixedItemStatus]
    public let paidCount: Int
    public let openCount: Int
    public let lateCount: Int
    /// Plan van alle verwachte posten.
    public let planTotal: Money
    /// Wat er werkelijk geboekt is op de verwachte posten.
    public let actualTotal: Money
    /// Plan van de posten die nog open of te laat zijn.
    public let outstandingTotal: Money
}

// MARK: - Functies

extension Insight {
    static func cellStatus(count: Int, sum: Money, expected: Money?, year: Int, month: Int,
                           expectedDay: Int?, today: Day, checked: Bool = false) -> CellStatus {
        if count > 0 { return expected == sum ? .gelijk : .afwijkend }
        if checked { return .afgevinkt }
        guard let expected, !expected.isZero else { return .nietVerwacht }
        if (year, month) > (today.year, today.month) { return .nietVerwacht }
        if (year, month) < (today.year, today.month) { return .teLaat }
        if let d = expectedDay, today.day > d { return .teLaat }
        return .open
    }

    /// Het maandgrid van een jaar. Alleen boekingen op betaalrekeningen tellen mee.
    /// Gooit `InsightError.yearNotFound` als het jaar nog geen begroting heeft.
    public static func monthGrid(_ db: Database, year: Int, today: Day) throws -> MonthGrid {
        let budgetYear = try Q.budgetYear(db, year)
        let plans = PlanSet(try Q.items(db, yearId: budgetYear.id!))
        let reserveLineIds = Set(plans.items.filter(\.isReserveLine).compactMap(\.id))

        // Eén query: per post (NULL = divers) en maand de som, het aantal en de plus- en minkant.
        let rows = try Row.fetchAll(db, sql: """
            SELECT e.budgetItemId AS itemId, \(Q.periodMonth) AS m, SUM(e.amount) AS s, COUNT(*) AS c,
                   SUM(CASE WHEN e.amount > 0 THEN e.amount ELSE 0 END) AS pos,
                   SUM(CASE WHEN e.amount < 0 THEN e.amount ELSE 0 END) AS neg
            FROM entry e
            WHERE e.accountId IN \(Q.betaal) AND \(Q.inPeriod(year).sql)
            GROUP BY e.budgetItemId, m
            """, arguments: StatementArguments(Q.inPeriod(year).args))
        let checks = try Q.checks(db, yearId: budgetYear.id!)

        var cellSums: [Int64: [Int: (Money, Int)]] = [:]
        var fixed = [Money](repeating: .zero, count: 13)
        var inDivers = fixed, uitDivers = fixed, result = fixed
        for r in rows {
            let m: Int = r["m"]
            guard (1...12).contains(m) else { continue }
            let sum: Money = r["s"]
            result[m] += sum
            if let itemId: Int64 = r["itemId"] {
                cellSums[itemId, default: [:]][m] = (sum, r["c"])
                if !reserveLineIds.contains(itemId) { fixed[m] += sum }
            } else {
                inDivers[m] += r["pos"] as Money
                uitDivers[m] += r["neg"] as Money
            }
        }

        var planExpected = [Money](repeating: .zero, count: 13)
        let gridRows = plans.items.map { item -> GridRow in
            let sums = cellSums[item.id!] ?? [:]
            let cells = (1...12).map { m -> GridCell in
                let (sum, count) = sums[m] ?? (.zero, 0)
                let expected = plans.expected(item, month: m)
                let checked = checks.contains(ItemMonth(item.id!, m))
                if let expected { planExpected[m] += expected }
                return GridCell(month: m, sum: sum, entryCount: count,
                                status: cellStatus(count: count, sum: sum, expected: expected, year: year, month: m,
                                                   expectedDay: item.expectedDay, today: today, checked: checked),
                                expected: expected, difference: sum - (expected ?? .zero), isChecked: checked)
            }
            return GridRow(id: item.id!, label: item.label, direction: item.direction,
                           kind: item.isReserveTotal ? .reserveTotal : (item.isReserveLine ? .reserveLine : .item),
                           plan: plans.plan(item), frequency: item.frequency, expectedMonths: item.months,
                           expectedDay: item.expectedDay, potId: item.potId,
                           cells: cells, yearTotal: cells.map(\.sum).sum(),
                           planYearTotal: cells.compactMap(\.expected).sum())
        }

        func totals(_ m: Int, _ f: Money, _ i: Money, _ u: Money, _ r: Money, _ p: Money) -> GridTotals {
            GridTotals(month: m, fixed: f, inDivers: i, uitDivers: u, nettoDivers: i + u, result: r,
                       planExpected: p, ruimte: p + i + u)
        }
        let monthTotals = (1...12).map { totals($0, fixed[$0], inDivers[$0], uitDivers[$0], result[$0], planExpected[$0]) }
        return MonthGrid(year: year, closed: budgetYear.closed, rows: gridRows, monthTotals: monthTotals,
                         yearTotals: totals(0, fixed.sum(), inDivers.sum(), uitDivers.sum(), result.sum(), planExpected.sum()))
    }

    /// De boekingen achter één cel van het grid (oudste eerst).
    public static func cellEntries(_ db: Database, itemId: Int64, year: Int, month: Int) throws -> [EntryRow] {
        try entryRows(db, where: "e.budgetItemId = ? AND a.kind = 'betaal' AND \(Q.period) = ?",
                      arguments: [itemId, Q.periodKey(year, month)],
                      order: "e.day ASC, e.id ASC")
    }

    /// De diverse boekingen van een maand: `positive` true = IN divers, false = UIT divers (oudste eerst).
    public static func diversEntries(_ db: Database, year: Int, month: Int, positive: Bool) throws -> [EntryRow] {
        try entryRows(db, where: """
            e.budgetItemId IS NULL AND a.kind = 'betaal' AND \(Q.period) = ? AND e.amount \(positive ? ">" : "<") 0
            """, arguments: [Q.periodKey(year, month)], order: "e.day ASC, e.id ASC")
    }

    /// Per vaste post die in deze maand verwacht wordt: voldaan (met werkelijk bedrag, verschil en dag),
    /// open of te laat. RES-regels doen niet mee; RESERVERINGEN wel. Een toekomstige maand is `open`.
    public static func fixedItemsStatus(_ db: Database, year: Int, month: Int, today: Day) throws -> FixedItemsOverview {
        let budgetYear = try Q.budgetYear(db, year)
        let plans = PlanSet(try Q.items(db, yearId: budgetYear.id!))
        let rows = try Row.fetchAll(db, sql: """
            SELECT e.budgetItemId AS itemId, SUM(e.amount) AS s, COUNT(*) AS c, MAX(e.day) AS d
            FROM entry e
            WHERE e.accountId IN \(Q.betaal) AND e.budgetItemId IS NOT NULL AND \(Q.period) = ?
            GROUP BY e.budgetItemId
            """, arguments: [Q.periodKey(year, month)])
        let checks = try Q.checks(db, yearId: budgetYear.id!)
        var booked: [Int64: (Money, Int, Day?)] = [:]
        for r in rows { booked[r["itemId"]] = (r["s"], r["c"], r["d"]) }

        var items: [FixedItemStatus] = []
        for item in plans.items {
            guard let plan = plans.expected(item, month: month) else { continue }
            let (actual, count, day) = booked[item.id!] ?? (.zero, 0, nil)
            let checked = checks.contains(ItemMonth(item.id!, month))
            let state: FixedItemState
            if count > 0 || checked {
                state = .voldaan
            } else {
                if plan.isZero { continue }
                switch cellStatus(count: 0, sum: .zero, expected: plan, year: year, month: month,
                                  expectedDay: item.expectedDay, today: today) {
                case .teLaat: state = .teLaat
                default: state = .open
                }
            }
            items.append(FixedItemStatus(id: item.id!, label: item.label, direction: item.direction, state: state,
                                         plan: plan, actual: actual, difference: actual - plan, day: day,
                                         expectedDay: item.expectedDay, entryCount: count, isChecked: checked))
        }
        return FixedItemsOverview(
            year: year, month: month, items: items,
            paidCount: items.filter { $0.state == .voldaan }.count,
            openCount: items.filter { $0.state == .open }.count,
            lateCount: items.filter { $0.state == .teLaat }.count,
            planTotal: items.map(\.plan).sum(), actualTotal: items.map(\.actual).sum(),
            outstandingTotal: items.filter { $0.state != .voldaan }.map(\.plan).sum())
    }
}
