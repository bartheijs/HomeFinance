import Foundation
import GRDB
import HFCore

// MARK: - Typen

/// Verwijzing naar een tag bij een boeking.
public struct TagRef: Identifiable, Equatable, Hashable, Sendable {
    public let id: Int64
    public let name: String
    public let color: String
}

/// De ruwe bankgegevens bij een boeking die uit een banktransactie komt.
public struct BankFields: Equatable, Sendable {
    public let counterpartyName: String
    public let counterpartyIban: String
    public let descriptionText: String
    public let reference: String
    public let transactionCode: String
    /// Het volledige bedrag van de banktransactie (bij splitsen groter dan de boeking).
    public let amount: Money
}

/// Een boeking met alles wat een lijst nodig heeft: rekening, post, pot, tags en bankgegevens.
public struct EntryRow: Identifiable, Equatable, Sendable {
    public let id: Int64
    public let accountId: Int64
    public let accountName: String
    public let accountKind: AccountKind
    public let day: Day
    public let amount: Money
    public let label: String
    public let note: String
    public let budgetItemId: Int64?
    public let itemLabel: String?
    public let potId: Int64?
    public let potName: String?
    public let reimburse: Bool
    /// Tijdelijk geleend van spaar (tijdelijk anti-rood).
    public let temporaryLoan: Bool
    public let savingsTransferId: Int64?
    public let counterEntryId: Int64?
    public let reviewed: Bool
    public let confidence: Confidence?
    public let bankTransactionId: Int64?
    /// nil bij handinvoer.
    public let bank: BankFields?
    public internal(set) var tags: [TagRef]

    /// Boeking op een betaalrekening zonder vaste post.
    public var isDivers: Bool { accountKind == .betaal && budgetItemId == nil }
}

/// Sortering van de transactielijst.
public enum EntrySort: String, Sendable, CaseIterable {
    case dayDescending, dayAscending, amountAscending, amountDescending, label
}

/// Teken van het bedrag.
public enum AmountSign: String, Sendable, CaseIterable {
    /// Inkomsten (> 0).
    case positive
    /// Uitgaven (< 0).
    case negative
}

/// Filter voor `Insight.searchEntries`. Alle ingevulde voorwaarden gelden tegelijk (EN).
public struct EntryFilter: Equatable, Sendable {
    public var accountId: Int64?
    public var year: Int?
    /// Maand 1–12; werkt alleen samen met `year`.
    public var month: Int?
    public var from: Day?
    public var to: Day?
    /// Zoekt in label, notitie, tegenpartij en bankomschrijving (hoofdletterongevoelig).
    public var text: String?
    public var budgetItemId: Int64?
    public var potId: Int64?
    public var tagId: Int64?
    /// Alleen boekingen op een betaalrekening zonder vaste post.
    public var diversOnly: Bool
    public var unreviewedOnly: Bool
    public var reimburseOnly: Bool
    /// Grenzen op het bedrag zonder teken (10 … 50 vindt ook −25,00).
    public var minAmount: Money?
    public var maxAmount: Money?
    public var sign: AmountSign?
    public var sort: EntrySort
    /// nil = alles.
    public var limit: Int?
    public var offset: Int

    public init(accountId: Int64? = nil, year: Int? = nil, month: Int? = nil, from: Day? = nil, to: Day? = nil,
                text: String? = nil, budgetItemId: Int64? = nil, potId: Int64? = nil, tagId: Int64? = nil,
                diversOnly: Bool = false, unreviewedOnly: Bool = false, reimburseOnly: Bool = false,
                minAmount: Money? = nil, maxAmount: Money? = nil, sign: AmountSign? = nil,
                sort: EntrySort = .dayDescending, limit: Int? = nil, offset: Int = 0) {
        self.accountId = accountId; self.year = year; self.month = month; self.from = from; self.to = to
        self.text = text; self.budgetItemId = budgetItemId; self.potId = potId; self.tagId = tagId
        self.diversOnly = diversOnly; self.unreviewedOnly = unreviewedOnly; self.reimburseOnly = reimburseOnly
        self.minAmount = minAmount; self.maxAmount = maxAmount; self.sign = sign
        self.sort = sort; self.limit = limit; self.offset = offset
    }
}

/// Resultaat van `Insight.searchEntries`: één pagina, met aantal en som van álle gevonden boekingen.
public struct EntrySearchResult: Equatable, Sendable {
    public let rows: [EntryRow]
    public let totalCount: Int
    public let totalSum: Money
}

/// Een banktransactie die nog geboekt moet worden (status `nieuw`).
public struct ReviewItem: Identifiable, Equatable, Sendable {
    public var id: Int64 { transaction.id ?? 0 }
    public let transaction: BankTransaction
    public let accountName: String
    /// Som van de boekingen die er al aan hangen (bij half gesplitste transacties).
    public let bookedAmount: Money
    /// Nog te boeken: bedrag − `bookedAmount`.
    public var remaining: Money { transaction.amount - bookedAmount }
}

// MARK: - Functies

extension Insight {
    static let entryFrom = """
        FROM entry e
        JOIN account a ON a.id = e.accountId
        LEFT JOIN budgetItem i ON i.id = e.budgetItemId
        LEFT JOIN pot p ON p.id = e.potId
        LEFT JOIN bankTransaction b ON b.id = e.bankTransactionId
        """

    static let entrySelect = """
        SELECT e.id, e.accountId, a.name AS accountName, a.kind AS accountKind, e.day, e.amount, e.label, e.note,
               e.budgetItemId, i.label AS itemLabel, e.potId, p.name AS potName, e.reimburse, e.temporaryLoan, e.savingsTransferId,
               e.counterEntryId, e.reviewed, e.confidence, e.bankTransactionId,
               b.counterpartyName AS bName, b.counterpartyIban AS bIban, b.descriptionText AS bDesc,
               b.reference AS bRef, b.transactionCode AS bCode, b.amount AS bAmount
        """

    /// Haalt boekingen op met alle koppelingen; tags komen in één extra query per 500 boekingen.
    static func entryRows(_ db: Database, where clause: String = "1", arguments: [(any DatabaseValueConvertible)?] = [],
                          order: String = "e.day DESC, e.id DESC", limit: Int? = nil, offset: Int = 0) throws -> [EntryRow] {
        var sql = "\(entrySelect) \(entryFrom) WHERE \(clause) ORDER BY \(order)"
        var args = arguments
        if let limit {
            sql += " LIMIT ? OFFSET ?"
            args.append(limit); args.append(offset)
        } else if offset > 0 {
            sql += " LIMIT -1 OFFSET ?"
            args.append(offset)
        }
        var rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args)).map { r -> EntryRow in
            let bankId: Int64? = r["bankTransactionId"]
            let bank: BankFields? = (bankId != nil && r["bAmount"] != nil)
                ? BankFields(counterpartyName: r["bName"], counterpartyIban: r["bIban"], descriptionText: r["bDesc"],
                             reference: r["bRef"], transactionCode: r["bCode"], amount: r["bAmount"])
                : nil
            return EntryRow(id: r["id"], accountId: r["accountId"], accountName: r["accountName"],
                            accountKind: r["accountKind"], day: r["day"], amount: r["amount"], label: r["label"],
                            note: r["note"], budgetItemId: r["budgetItemId"], itemLabel: r["itemLabel"],
                            potId: r["potId"], potName: r["potName"], reimburse: r["reimburse"],
                            temporaryLoan: r["temporaryLoan"], savingsTransferId: r["savingsTransferId"], counterEntryId: r["counterEntryId"],
                            reviewed: r["reviewed"], confidence: r["confidence"], bankTransactionId: bankId,
                            bank: bank, tags: [])
        }
        let tags = try tagsByEntry(db, ids: rows.map(\.id))
        if !tags.isEmpty {
            for i in rows.indices { rows[i].tags = tags[rows[i].id] ?? [] }
        }
        return rows
    }

    static func tagsByEntry(_ db: Database, ids: [Int64]) throws -> [Int64: [TagRef]] {
        var result: [Int64: [TagRef]] = [:]
        var start = 0
        while start < ids.count {
            let chunk = Array(ids[start..<min(start + 500, ids.count)])
            start += 500
            let marks = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            let rows = try Row.fetchAll(db, sql: """
                SELECT et.entryId, t.id, t.name, t.color FROM entryTag et JOIN tag t ON t.id = et.tagId
                WHERE et.entryId IN (\(marks)) ORDER BY t.sortOrder, t.name
                """, arguments: StatementArguments(chunk))
            for r in rows {
                result[r["entryId"], default: []].append(TagRef(id: r["id"], name: r["name"], color: r["color"]))
            }
        }
        return result
    }

    /// Transactielijst met filters, sortering en paginering. `totalCount` en `totalSum` gaan over alle
    /// gevonden boekingen, niet alleen over de pagina.
    public static func searchEntries(_ db: Database, filter: EntryFilter) throws -> EntrySearchResult {
        var parts: [String] = []
        var args: [(any DatabaseValueConvertible)?] = []
        if let v = filter.accountId { parts.append("e.accountId = ?"); args.append(v) }
        if let y = filter.year {
            let (a, b) = Q.range(y, filter.month)
            parts.append("e.day >= ? AND e.day <= ?"); args.append(a); args.append(b)
        }
        if let v = filter.from { parts.append("e.day >= ?"); args.append(v) }
        if let v = filter.to { parts.append("e.day <= ?"); args.append(v) }
        if let t = filter.text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
            let escaped = t.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
            let pattern = "%\(escaped)%"
            parts.append("""
                (e.label LIKE ? ESCAPE '\\' OR e.note LIKE ? ESCAPE '\\'
                 OR b.counterpartyName LIKE ? ESCAPE '\\' OR b.descriptionText LIKE ? ESCAPE '\\')
                """)
            for _ in 0..<4 { args.append(pattern) }
        }
        if let v = filter.budgetItemId { parts.append("e.budgetItemId = ?"); args.append(v) }
        if let v = filter.potId { parts.append("e.potId = ?"); args.append(v) }
        if let v = filter.tagId {
            parts.append("EXISTS (SELECT 1 FROM entryTag et WHERE et.entryId = e.id AND et.tagId = ?)"); args.append(v)
        }
        if filter.diversOnly { parts.append("a.kind = 'betaal' AND e.budgetItemId IS NULL") }
        if filter.unreviewedOnly { parts.append("e.reviewed = 0") }
        if filter.reimburseOnly { parts.append("e.reimburse = 1") }
        if let v = filter.minAmount { parts.append("abs(e.amount) >= ?"); args.append(v.magnitude) }
        if let v = filter.maxAmount { parts.append("abs(e.amount) <= ?"); args.append(v.magnitude) }
        switch filter.sign {
        case .positive?: parts.append("e.amount > 0")
        case .negative?: parts.append("e.amount < 0")
        case nil: break
        }
        let clause = parts.isEmpty ? "1" : parts.joined(separator: " AND ")
        let order: String
        switch filter.sort {
        case .dayDescending: order = "e.day DESC, e.id DESC"
        case .dayAscending: order = "e.day ASC, e.id ASC"
        case .amountAscending: order = "e.amount ASC, e.day DESC, e.id DESC"
        case .amountDescending: order = "e.amount DESC, e.day DESC, e.id DESC"
        case .label: order = "e.label COLLATE NOCASE ASC, e.day DESC, e.id DESC"
        }
        let total = try Row.fetchOne(db, sql: "SELECT COUNT(*) AS c, COALESCE(SUM(e.amount), 0) AS s \(entryFrom) WHERE \(clause)",
                                     arguments: StatementArguments(args))!
        let rows = try entryRows(db, where: clause, arguments: args, order: order, limit: filter.limit, offset: filter.offset)
        return EntrySearchResult(rows: rows, totalCount: total["c"], totalSum: total["s"])
    }

    /// Banktransacties met status `nieuw`, oudste eerst, met hun ruwe velden. `accountId` nil = alle rekeningen.
    public static func reviewQueue(_ db: Database, accountId: Int64? = nil) throws -> [ReviewItem] {
        var sql = """
            SELECT b.*, a.name AS accountName,
                   (SELECT COALESCE(SUM(e.amount), 0) FROM entry e WHERE e.bankTransactionId = b.id) AS booked
            FROM bankTransaction b JOIN account a ON a.id = b.accountId
            WHERE b.status = 'nieuw'
            """
        var args: [(any DatabaseValueConvertible)?] = []
        if let accountId { sql += " AND b.accountId = ?"; args.append(accountId) }
        sql += " ORDER BY b.day ASC, b.id ASC"
        return try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args)).map { r in
            ReviewItem(transaction: try BankTransaction(row: r), accountName: r["accountName"], bookedAmount: r["booked"])
        }
    }

    /// De laatste boekingen (op dag, nieuwste eerst), voor het dashboard.
    public static func recentEntries(_ db: Database, limit: Int = 10) throws -> [EntryRow] {
        try entryRows(db, limit: limit)
    }
}
