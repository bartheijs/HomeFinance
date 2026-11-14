import Foundation
import GRDB
import HFCore

// MARK: - Typen

/// Eén pot met saldo en voortgang.
public struct PotSummary: Identifiable, Equatable, Sendable {
    public let id: Int64
    public let accountId: Int64
    public let name: String
    public let kind: PotKind
    public let owner: String?
    public let archived: Bool
    /// Som van de boekingen op de spaarrekening met deze pot, t/m de peildag.
    public let balance: Money
    public let monthlyAmount: Money
    /// Som van de regels van deze pot in alle niet-gearchiveerde vaste stortingen.
    public let distributionAmount: Money
    public let targetAmount: Money?
    /// Doeldatum van het spaardoel, of nil.
    public let targetDate: Day?
    /// Het spaardoel uitgewerkt (status, nodig per maand, tekort), of nil zonder doelbedrag.
    public let goal: PotGoal?
    /// Saldo ÷ doel (0…1 en hoger), of nil zonder doel. Alleen voor weergave.
    public let progress: Double?
    /// Nog te sparen tot het doel (nooit negatief), of nil zonder doel.
    public let remainingToTarget: Money?
    /// Stortingen dit jaar (positief).
    public let depositsThisYear: Money
    /// Opnames dit jaar (negatief).
    public let withdrawalsThisYear: Money
    public let lastMovement: Day?
    /// Aantal losse verwachtingen (`ForecastItem`) die nog niet zijn uitgekomen.
    public let openForecastCount: Int
}

/// Een spaarrekening met zijn potten.
public struct SavingsAccountPots: Identifiable, Equatable, Sendable {
    public let id: Int64
    public let name: String
    public let archived: Bool
    /// Saldo van de rekening = beginsaldo + boekingen.
    public let balance: Money
    /// Som van alle potten.
    public let potTotal: Money
    /// Niet toegewezen = saldo − som van de potten.
    public let unallocated: Money
    public let pots: [PotSummary]
}

/// Potten van één soort.
public struct PotKindGroup: Identifiable, Equatable, Sendable {
    public var id: PotKind { kind }
    public let kind: PotKind
    public let total: Money
    public let monthlyTotal: Money
    public let pots: [PotSummary]
}

/// Potten van één eigenaar (`owner` nil = zonder eigenaar).
public struct PotOwnerGroup: Identifiable, Equatable, Sendable {
    public var id: String { owner ?? "" }
    public let owner: String?
    public let total: Money
    public let monthlyTotal: Money
    public let pots: [PotSummary]
}

/// Overzicht van potten en spaarrekeningen.
public struct PotOverview: Equatable, Sendable {
    public let accounts: [SavingsAccountPots]
    public let byKind: [PotKindGroup]
    public let byOwner: [PotOwnerGroup]
    public let totalBalance: Money
    public let totalPots: Money
    public let totalUnallocated: Money
}

/// Boeking van een pot met het saldo van de pot ná die boeking.
public struct PotHistoryRow: Identifiable, Equatable, Sendable {
    public var id: Int64 { entry.id }
    public let entry: EntryRow
    public let runningBalance: Money
}

/// Openstaand bedrag per pot (`potId` nil = geen pot gekozen).
public struct ReimbursementPotTotal: Identifiable, Equatable, Sendable {
    public var id: Int64 { potId ?? 0 }
    public let potId: Int64?
    public let potName: String?
    /// Som van de uitgaven (negatief).
    public let total: Money
    public let count: Int
}

/// Uitgaven die nog uit de spaarrekening vergoed moeten worden.
public struct OpenReimbursements: Equatable, Sendable {
    public let entries: [EntryRow]
    /// Som van de boekingen (negatief, want het zijn uitgaven).
    public let total: Money
    /// Over te boeken van spaar naar betaal (positief) = −`total`.
    public let transferAmount: Money
    public let perPot: [ReimbursementPotTotal]
}

/// Een spaaroverboeking met de uitgaven die hij vergoedt.
public struct SavingsTransferDetail: Identifiable, Equatable, Sendable {
    public let id: Int64
    public let day: Day
    public let amount: Money
    public let done: Bool
    public let doneAt: Date?
    public let note: String
    public let entries: [EntryRow]
    /// Som van de gekoppelde uitgaven (negatief); hoort −`amount` te zijn.
    public let entriesTotal: Money
}

// MARK: - Functies

extension Insight {
    /// Potten per spaarrekening, per soort en per eigenaar. `accountId` nil = alle spaarrekeningen.
    /// Saldi tellen boekingen t/m `today`; "dit jaar" is het jaar van `today`.
    public static func potOverview(_ db: Database, accountId: Int64? = nil, today: Day) throws -> PotOverview {
        var accountSQL = """
            SELECT a.id, a.name, a.archived,
                   a.openingBalance + COALESCE((SELECT SUM(e.amount) FROM entry e
                                                WHERE e.accountId = a.id AND e.day <= ?), 0) AS balance
            FROM account a WHERE a.kind = 'spaar'
            """
        var args: [(any DatabaseValueConvertible)?] = [today]
        if let accountId { accountSQL += " AND a.id = ?"; args.append(accountId) }
        accountSQL += " ORDER BY a.sortOrder, a.id"
        let accountRows = try Row.fetchAll(db, sql: accountSQL, arguments: StatementArguments(args))

        let yearStart = Q.yearStart(today.year)
        let potRows = try Row.fetchAll(db, sql: """
            SELECT p.*, COALESCE(SUM(e.amount), 0) AS bal,
                   COALESCE(SUM(CASE WHEN e.amount > 0 AND e.day >= ? THEN e.amount ELSE 0 END), 0) AS dep,
                   COALESCE(SUM(CASE WHEN e.amount < 0 AND e.day >= ? THEN e.amount ELSE 0 END), 0) AS wd,
                   MAX(e.day) AS lastDay,
                   (SELECT COALESCE(SUM(l.amount), 0) FROM distributionLine l
                    JOIN distribution d ON d.id = l.distributionId
                    WHERE l.potId = p.id AND d.archived = 0) AS distributed,
                   (SELECT COUNT(*) FROM forecastItem f WHERE f.potId = p.id AND f.realizedAt IS NULL) AS openForecasts
            FROM pot p
            LEFT JOIN entry e ON e.potId = p.id AND e.accountId = p.accountId AND e.day <= ?
            GROUP BY p.id ORDER BY p.sortOrder, p.id
            """, arguments: [yearStart, yearStart, today])
        let accountIds = Set(accountRows.map { $0["id"] as Int64 })
        // Eén keer laden voor alle potten; het spaardoel per pot rekent daarna zonder verdere queries.
        let forecast = try ForecastContext(db, today: today)
        let pots = try potRows.compactMap { r -> PotSummary? in
            let pot = try Pot(row: r)
            guard accountIds.contains(pot.accountId) else { return nil }
            let balance: Money = r["bal"]
            let target = pot.targetAmount.flatMap { $0 > .zero ? $0 : nil }
            return PotSummary(id: pot.id!, accountId: pot.accountId, name: pot.name, kind: pot.kind, owner: pot.owner,
                              archived: pot.archived, balance: balance, monthlyAmount: pot.monthlyAmount,
                              distributionAmount: r["distributed"], targetAmount: pot.targetAmount,
                              targetDate: pot.targetDate, goal: forecast.goal(pot: pot, balance: balance),
                              progress: target.map { max(0, balance.doubleValue / $0.doubleValue) },
                              remainingToTarget: target.map { max(.zero, $0 - balance) },
                              depositsThisYear: r["dep"], withdrawalsThisYear: r["wd"], lastMovement: r["lastDay"],
                              openForecastCount: r["openForecasts"])
        }

        let accounts = accountRows.map { r -> SavingsAccountPots in
            let id: Int64 = r["id"]
            let own = pots.filter { $0.accountId == id }
            let balance: Money = r["balance"]
            let potTotal = own.map(\.balance).sum()
            return SavingsAccountPots(id: id, name: r["name"], archived: r["archived"], balance: balance,
                                      potTotal: potTotal, unallocated: balance - potTotal, pots: own)
        }
        let byKind = PotKind.allCases.compactMap { kind -> PotKindGroup? in
            let group = pots.filter { $0.kind == kind }
            guard !group.isEmpty else { return nil }
            return PotKindGroup(kind: kind, total: group.map(\.balance).sum(),
                                monthlyTotal: group.map(\.monthlyAmount).sum(), pots: group)
        }
        let owners = Set(pots.map(\.owner)).sorted { a, b in
            switch (a, b) {
            case let (x?, y?): return x.localizedCaseInsensitiveCompare(y) == .orderedAscending
            case (nil, _): return false
            case (_, nil): return true
            }
        }
        let byOwner = owners.map { owner -> PotOwnerGroup in
            let group = pots.filter { $0.owner == owner }
            return PotOwnerGroup(owner: owner, total: group.map(\.balance).sum(),
                                 monthlyTotal: group.map(\.monthlyAmount).sum(), pots: group)
        }
        return PotOverview(accounts: accounts, byKind: byKind, byOwner: byOwner,
                           totalBalance: accounts.map(\.balance).sum(), totalPots: accounts.map(\.potTotal).sum(),
                           totalUnallocated: accounts.map(\.unallocated).sum())
    }

    /// Alle boekingen van een pot op zijn spaarrekening, oudste eerst, met het oplopende saldo.
    public static func potHistory(_ db: Database, potId: Int64) throws -> [PotHistoryRow] {
        guard let accountId = try Int64.fetchOne(db, sql: "SELECT accountId FROM pot WHERE id = ?", arguments: [potId]) else {
            throw InsightError.potNotFound(potId)
        }
        var running = Money.zero
        return try entryRows(db, where: "e.potId = ? AND e.accountId = ?", arguments: [potId, accountId],
                             order: "e.day ASC, e.id ASC").map {
            running += $0.amount
            return PotHistoryRow(entry: $0, runningBalance: running)
        }
    }

    /// Boekingen op spaarrekeningen zonder pot (nieuwste eerst). `accountId` nil = alle spaarrekeningen.
    public static func unallocatedSavingsEntries(_ db: Database, accountId: Int64? = nil) throws -> [EntryRow] {
        var clause = "a.kind = 'spaar' AND e.potId IS NULL"
        var args: [(any DatabaseValueConvertible)?] = []
        if let accountId { clause += " AND e.accountId = ?"; args.append(accountId) }
        return try entryRows(db, where: clause, arguments: args)
    }

    /// Openstaande te vergoeden uitgaven (`reimburse` zonder spaaroverboeking), met totaal en per pot.
    public static func openReimbursements(_ db: Database) throws -> OpenReimbursements {
        let entries = try entryRows(db, where: "e.reimburse = 1 AND e.savingsTransferId IS NULL",
                                    order: "e.day ASC, e.id ASC")
        var order: [Int64?] = []
        var groups: [Int64?: (String?, Money, Int)] = [:]
        for e in entries {
            if groups[e.potId] == nil { order.append(e.potId) }
            let g = groups[e.potId] ?? (e.potName, .zero, 0)
            groups[e.potId] = (g.0, g.1 + e.amount, g.2 + 1)
        }
        let total = entries.map(\.amount).sum()
        return OpenReimbursements(entries: entries, total: total, transferAmount: -total,
                                  perPot: order.map { ReimbursementPotTotal(potId: $0, potName: groups[$0]!.0,
                                                                            total: groups[$0]!.1, count: groups[$0]!.2) })
    }

    /// Alle spaaroverboekingen (nieuwste eerst) met de uitgaven die erin zitten.
    public static func savingsTransfers(_ db: Database) throws -> [SavingsTransferDetail] {
        let transfers = try SavingsTransfer.order(Column("day").desc, Column("id").desc).fetchAll(db)
        let entries = try entryRows(db, where: "e.savingsTransferId IS NOT NULL", order: "e.day ASC, e.id ASC")
        let grouped = Dictionary(grouping: entries, by: { $0.savingsTransferId! })
        return transfers.map { t in
            let own = grouped[t.id!] ?? []
            return SavingsTransferDetail(id: t.id!, day: t.day, amount: t.amount, done: t.done, doneAt: t.doneAt,
                                         note: t.note, entries: own, entriesTotal: own.map(\.amount).sum())
        }
    }
}
