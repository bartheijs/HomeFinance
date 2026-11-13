import Foundation
import GRDB
import HFCore

// MARK: - Typen

/// Stand van het verrekenen voor één tag met `Tag.settles`.
public struct TagSettlementSummary: Identifiable, Equatable, Sendable {
    /// Id van de tag.
    public let id: Int64
    public let name: String
    public let color: String
    /// Openstaand = − som van de boekingen op betaalrekeningen met deze tag en zonder verrekening
    /// (positief = nog terug te storten; een retour met dezelfde tag telt eraf).
    public let outstanding: Money
    /// Aantal openstaande boekingen.
    public let openCount: Int
    /// Dag van de oudste openstaande boeking, of nil.
    public let oldestOpenDay: Day?
    /// Dag en bedrag van de laatste echte verrekening (beginstanden tellen niet), of nil.
    public let lastSettlementDay: Day?
    public let lastSettlementAmount: Money?
    /// Totaal verrekend in het jaar van `today` (zonder beginstanden).
    public let settledThisYear: Money
}

/// Eén verrekening met de storting en de boekingen die ermee zijn afgerekend.
public struct SettlementDetail: Identifiable, Equatable, Sendable {
    public var id: Int64 { settlement.id ?? 0 }
    public let settlement: Settlement
    /// De gekoppelde bijschrijving op de betaalrekening, of nil (niet gekoppeld, of een beginstand).
    public let deposit: EntryRow?
    /// De verrekende boekingen, oudste eerst.
    public let entries: [EntryRow]
    /// Som van de verrekende boekingen (negatief); hoort −`settlement.amount` te zijn.
    public let entriesTotal: Money
}

// MARK: - Functies

extension Insight {
    /// Alle tags die verrekend worden (op `sortOrder`), met openstaand bedrag, aantal, oudste openstaande dag,
    /// de laatste echte verrekening en het totaal verrekend dit jaar.
    public static func settlementOverview(_ db: Database, today: Day) throws -> [TagSettlementSummary] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT t.id, t.name, t.color, COALESCE(SUM(e.amount), 0) AS s, COUNT(e.id) AS c, MIN(e.day) AS oldest
            FROM tag t
            LEFT JOIN entryTag et ON et.tagId = t.id
            LEFT JOIN entry e ON e.id = et.entryId AND e.settlementId IS NULL AND e.accountId IN \(Q.betaal)
            WHERE t.settles = 1
            GROUP BY t.id ORDER BY t.sortOrder, t.name
            """)
        guard !rows.isEmpty else { return [] }
        var last: [Int64: (Day, Money)] = [:]
        var thisYear: [Int64: Money] = [:]
        for r in try Row.fetchAll(db, sql: """
            SELECT tagId, day, amount FROM settlement WHERE isOpening = 0 ORDER BY day DESC, id DESC
            """) {
            let tagId: Int64 = r["tagId"], day: Day = r["day"], amount: Money = r["amount"]
            if last[tagId] == nil { last[tagId] = (day, amount) }
            if day.year == today.year { thisYear[tagId, default: .zero] += amount }
        }
        return rows.map { r in
            let id: Int64 = r["id"]
            return TagSettlementSummary(id: id, name: r["name"], color: r["color"], outstanding: -(r["s"] as Money),
                                        openCount: r["c"], oldestOpenDay: r["oldest"],
                                        lastSettlementDay: last[id]?.0, lastSettlementAmount: last[id]?.1,
                                        settledThisYear: thisYear[id] ?? .zero)
        }
    }

    /// De openstaande boekingen van een tag: op een betaalrekening, met die tag, zonder verrekening (oudste eerst).
    public static func openSettlementEntries(_ db: Database, tagId: Int64) throws -> [EntryRow] {
        try entryRows(db, where: """
            e.settlementId IS NULL AND a.kind = 'betaal'
            AND EXISTS (SELECT 1 FROM entryTag et WHERE et.entryId = e.id AND et.tagId = ?)
            """, arguments: [tagId], order: "e.day ASC, e.id ASC")
    }

    /// De verrekeningen van een tag, nieuwste eerst (ook beginstanden), elk met de gekoppelde storting en de
    /// verrekende boekingen.
    public static func settlementHistory(_ db: Database, tagId: Int64) throws -> [SettlementDetail] {
        let settlements = try Settlement.filter(Column("tagId") == tagId)
            .order(Column("day").desc, Column("id").desc).fetchAll(db)
        guard !settlements.isEmpty else { return [] }
        let entries = try entryRows(db, where: "e.settlementId IN (SELECT id FROM settlement WHERE tagId = ?)",
                                    arguments: [tagId], order: "e.day ASC, e.id ASC")
        let deposits = try entryRows(db, where: "e.id IN (SELECT depositEntryId FROM settlement WHERE tagId = ?)",
                                     arguments: [tagId])
        let depositById = Dictionary(uniqueKeysWithValues: deposits.map { ($0.id, $0) })
        let grouped = Dictionary(grouping: entries, by: { $0.settlementId! })
        return settlements.map { s in
            // De storting zelf hoort niet bij de verrekende boekingen, ook niet als hij de verrekening als kenmerk heeft.
            let own = (grouped[s.id!] ?? []).filter { $0.id != s.depositEntryId }
            return SettlementDetail(settlement: s, deposit: s.depositEntryId.flatMap { depositById[$0] },
                                    entries: own, entriesTotal: own.map(\.amount).sum())
        }
    }
}
