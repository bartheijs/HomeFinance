import Foundation
import GRDB
import HFCore

/// Alle leesfuncties van HomeFinance: `Insight.monthGrid(db, ...)`, `Insight.spendable(db, ...)` enz.
///
/// Elke functie krijgt een GRDB `Database` (bruikbaar in `read` en in `ValueObservation`), schrijft nooit
/// en geeft gewone `Sendable` waarden terug. "Vandaag" is altijd een parameter.
public enum Insight {}

/// Fouten van HFInsight, met een Nederlandse melding voor de gebruiker.
public enum InsightError: Error, Equatable, Sendable, LocalizedError {
    /// Er is geen begroting (BudgetYear) voor dit jaar.
    case yearNotFound(Int)
    /// De rekening bestaat niet.
    case accountNotFound(Int64)
    /// De pot bestaat niet.
    case potNotFound(Int64)

    public var errorDescription: String? {
        switch self {
        case .yearNotFound(let y): return "Er is nog geen begroting voor het jaar \(y)."
        case .accountNotFound: return "De rekening bestaat niet (meer)."
        case .potNotFound: return "De pot bestaat niet (meer)."
        }
    }
}

// MARK: - Interne hulpmiddelen

enum Q {
    /// Subquery met de id's van alle betaalrekeningen.
    static let betaal = "(SELECT id FROM account WHERE kind = 'betaal')"
    /// Maandnummer (1–12) van een dagkolom.
    static func month(_ column: String) -> String { "CAST(substr(\(column), 6, 2) AS INTEGER)" }

    static func yearStart(_ y: Int) -> String { String(format: "%04d-01-01", y) }
    static func yearEnd(_ y: Int) -> String { String(format: "%04d-12-31", y) }
    static func monthStart(_ y: Int, _ m: Int) -> String { String(format: "%04d-%02d-01", y, m) }
    /// Bovengrens voor tekstvergelijking; "-31" werkt ook voor kortere maanden.
    static func monthEnd(_ y: Int, _ m: Int) -> String { String(format: "%04d-%02d-31", y, m) }

    /// Begin en eind (ISO) van een jaar of van één maand daarin.
    static func range(_ year: Int, _ month: Int?) -> (String, String) {
        if let month { return (monthStart(year, month), monthEnd(year, month)) }
        return (yearStart(year), yearEnd(year))
    }

    static func lastDay(_ y: Int, _ m: Int) -> Day {
        for d in [31, 30, 29, 28] { if let day = Day(year: y, month: m, day: d) { return day } }
        preconditionFailure("ongeldige maand \(y)-\(m)")
    }

    /// De peildag voor cijfers van een jaar: vandaag in het lopende jaar, 31-12 voor een voorbij jaar.
    /// Voor een toekomstig jaar is het vandaag (er zijn dan nog geen boekingen in dat jaar).
    static func asOf(_ year: Int, _ today: Day) -> Day {
        today.year > year ? Day(year: year, month: 12, day: 31)! : today
    }

    /// Aantal (deels) verstreken maanden van het jaar op de peildag: 0 voor een toekomstig jaar.
    static func elapsedMonths(_ year: Int, _ today: Day) -> Int {
        if today.year > year { return 12 }
        if today.year < year { return 0 }
        return today.month
    }

    /// Gemiddelde in hele centen, afgerond op de dichtstbijzijnde cent.
    static func average(_ total: Money, _ n: Int) -> Money {
        guard n > 0 else { return .zero }
        let a = abs(total.cents), d = Int64(n)
        let q = (2 * a + d) / (2 * d)
        return Money(cents: total.cents < 0 ? -q : q)
    }

    static func daysBetween(_ a: Day, _ b: Day) -> Int {
        Int((b.date.timeIntervalSince(a.date) / 86_400).rounded())
    }

    static func budgetYear(_ db: Database, _ year: Int) throws -> BudgetYear {
        guard let y = try BudgetYear.filter(Column("year") == year).fetchOne(db) else {
            throw InsightError.yearNotFound(year)
        }
        return y
    }

    static func items(_ db: Database, yearId: Int64) throws -> [BudgetItem] {
        try BudgetItem.filter(Column("yearId") == yearId).order(Column("sortOrder"), Column("id")).fetchAll(db)
    }

    /// Loopt (dag, bedrag)-rijen op volgorde van dag af en geeft per peildag het cumulatief t/m die dag.
    static func cumulative(_ rows: [(Day, Money)], at points: [Day], start: Money = .zero) -> [Money] {
        var result: [Money] = []
        var running = start
        var i = 0
        for p in points {
            while i < rows.count, rows[i].0 <= p { running += rows[i].1; i += 1 }
            result.append(running)
        }
        return result
    }
}

extension BudgetItem {
    /// RES-regel die alleen de opbouw van RESERVERINGEN toont.
    var isReserveLine: Bool { direction == .RES && !isReserveTotal }
}

/// Posten van een jaar met het effectieve plan (RESERVERINGEN = som van de RES-regels).
struct PlanSet {
    let items: [BudgetItem]
    let reservePlan: Money

    init(_ items: [BudgetItem]) {
        self.items = items
        reservePlan = items.filter(\.isReserveLine).map(\.planAmount).sum()
    }

    func plan(_ item: BudgetItem) -> Money { item.isReserveTotal ? reservePlan : item.planAmount }

    /// Verwacht bedrag in een maand, of nil als de post die maand niet verwacht wordt (RES-regels: altijd nil).
    func expected(_ item: BudgetItem, month: Int) -> Money? {
        guard !item.isReserveLine, item.months.contains(month) else { return nil }
        return plan(item)
    }
}
