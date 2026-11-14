import Foundation
import GRDB
import HFCore

// MARK: - Typen

/// Welke boekingen meetellen in `Insight.labelTotals`.
public enum LabelKind: String, Sendable, CaseIterable {
    /// Alleen uitgaven (< 0).
    case expenses
    /// Alleen inkomsten (> 0).
    case income
    /// Uitgaven en inkomsten samen (het totaal is dan het saldo).
    case both
}

/// Filter voor `Insight.labelTotals`.
public struct LabelFilter: Equatable, Sendable {
    public var kind: LabelKind
    /// Minimaal aantal boekingen; standaard 2, zodat eenmalige aankopen de lijst niet vullen.
    public var minCount: Int
    /// Zoektekst in de omschrijving (hoofdletter- en accentongevoelig), of nil.
    public var text: String?

    public init(kind: LabelKind = .both, minCount: Int = 2, text: String? = nil) {
        self.kind = kind; self.minCount = minCount; self.text = text
    }
}

/// Totaal van de diverse boekingen met dezelfde omschrijving in één jaar.
public struct LabelTotal: Identifiable, Equatable, Sendable {
    /// De genormaliseerde omschrijving (kleine letters, enkele spaties).
    public let id: String
    /// De meest gebruikte schrijfwijze.
    public let label: String
    public let count: Int
    public let total: Money
    /// Twaalf maandtotalen, januari t/m december.
    public let months: [Money]
    /// Aantal maanden waarin iets geboekt is.
    public let activeMonths: Int
    /// `total` ÷ `activeMonths`.
    public let averagePerActiveMonth: Money
    public let firstDay: Day
    public let lastDay: Day
    /// De tags die bij meer dan de helft van de boekingen staan.
    public let tags: [TagRef]
}

/// Eén jaar in het verloop van een omschrijving.
public struct LabelYear: Identifiable, Equatable, Sendable {
    public var id: Int { year }
    public let year: Int
    public let count: Int
    public let total: Money
}

// MARK: - Functies

extension Insight {
    /// Omschrijving zonder spaties aan de randen en met enkele spaties.
    static func cleanLabel(_ label: String) -> String {
        label.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// Sleutel om omschrijvingen te groeperen: opgeschoond en in kleine letters.
    public static func normalizedLabel(_ label: String) -> String {
        cleanLabel(label).lowercased()
    }

    private static let diversBase = "e.accountId IN \(Q.betaal) AND e.budgetItemId IS NULL"

    /// Diverse boekingen (betaalrekening, geen vaste post) van een jaar t/m de peildag, gegroepeerd op omschrijving.
    /// Hoofdletters en extra spaties maken geen verschil. Gesorteerd op grootste absolute totaal.
    public static func labelTotals(_ db: Database, year: Int, today: Day,
                                   filter: LabelFilter = LabelFilter()) throws -> [LabelTotal] {
        var clause = "\(diversBase) AND \(Q.inPeriod(year).sql) AND e.day <= ?"
        switch filter.kind {
        case .expenses: clause += " AND e.amount < 0"
        case .income: clause += " AND e.amount > 0"
        case .both: break
        }
        let args = StatementArguments(Q.inPeriod(year).args + [today])

        struct Group {
            var spellings: [String: Int] = [:]
            var ids: [Int64] = []
            var total = Money.zero
            var months = [Money](repeating: .zero, count: 12)
            var active = Set<Int>()
            var first: Day, last: Day
        }
        var groups: [String: Group] = [:]
        for r in try Row.fetchAll(db, sql: "SELECT e.id, e.day, e.amount, e.label, \(Q.periodMonth) AS m FROM entry e WHERE \(clause) ORDER BY e.day, e.id",
                                  arguments: args) {
            let clean = cleanLabel(r["label"]), key = clean.lowercased()
            let day: Day = r["day"], amount: Money = r["amount"]
            var g = groups[key] ?? Group(first: day, last: day)
            g.spellings[clean, default: 0] += 1
            g.ids.append(r["id"])
            g.total += amount
            let month: Int = r["m"]
            guard (1...12).contains(month) else { continue }
            g.months[month - 1] += amount
            g.active.insert(month)
            g.last = day
            groups[key] = g
        }

        let needle = filter.text.map { cleanLabel($0) }.flatMap { $0.isEmpty ? nil : $0 }
        let kept = groups.filter { key, g in
            g.ids.count >= filter.minCount
                && (needle.map { key.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil } ?? true)
        }
        guard !kept.isEmpty else { return [] }

        // Tags van alle diverse boekingen in de periode, in één query.
        var tagsByEntry: [Int64: [TagRef]] = [:]
        for r in try Row.fetchAll(db, sql: """
            SELECT et.entryId, t.id, t.name, t.color FROM entry e
            JOIN entryTag et ON et.entryId = e.id JOIN tag t ON t.id = et.tagId
            WHERE \(clause) ORDER BY t.sortOrder, t.name
            """, arguments: args) {
            tagsByEntry[r["entryId"], default: []].append(TagRef(id: r["id"], name: r["name"], color: r["color"]))
        }

        return kept.map { key, g -> LabelTotal in
            let label = g.spellings.sorted { ($1.value, $0.key) < ($0.value, $1.key) }.first?.key ?? key
            var tagCounts: [TagRef: Int] = [:]
            var tagOrder: [TagRef] = []
            for id in g.ids {
                for t in tagsByEntry[id] ?? [] {
                    if tagCounts[t] == nil { tagOrder.append(t) }
                    tagCounts[t, default: 0] += 1
                }
            }
            let activeMonths = g.active.count
            return LabelTotal(id: key, label: label, count: g.ids.count, total: g.total, months: g.months,
                              activeMonths: activeMonths, averagePerActiveMonth: Q.average(g.total, activeMonths),
                              firstDay: g.first, lastDay: g.last,
                              tags: tagOrder.filter { tagCounts[$0]! * 2 > g.ids.count })
        }
        .sorted { ($0.total.magnitude, $1.label) > ($1.total.magnitude, $0.label) }
    }

    /// De diverse boekingen achter één omschrijving (oudste eerst). `year` nil = alle jaren.
    public static func labelEntries(_ db: Database, year: Int?, label: String) throws -> [EntryRow] {
        let key = normalizedLabel(label)
        var clause = diversBase
        var args: [(any DatabaseValueConvertible)?] = []
        if let year { clause += " AND \(Q.inPeriod(year).sql)"; args += Q.inPeriod(year).args }
        let ids = try Row.fetchAll(db, sql: "SELECT e.id, e.label FROM entry e WHERE \(clause)",
                                   arguments: StatementArguments(args))
            .filter { normalizedLabel($0["label"]) == key }.map { $0["id"] as Int64 }
        return try entryRows(db, ids: ids)
    }

    /// Het verloop van één omschrijving over de jaren: per jaar het aantal en het totaal (oudste jaar eerst).
    public static func labelYears(_ db: Database, label: String) throws -> [LabelYear] {
        let key = normalizedLabel(label)
        var years: [Int: (Int, Money)] = [:]
        for r in try Row.fetchAll(db, sql: "SELECT \(Q.periodYear) AS y, e.amount, e.label FROM entry e WHERE \(diversBase)")
        where normalizedLabel(r["label"]) == key {
            let year: Int = r["y"]
            let y = years[year] ?? (0, .zero)
            years[year] = (y.0 + 1, y.1 + (r["amount"] as Money))
        }
        return years.keys.sorted().map { LabelYear(year: $0, count: years[$0]!.0, total: years[$0]!.1) }
    }
}
