import Foundation
import GRDB
import HFCore

// MARK: - Typen

/// Eén regel van een vaste storting: dit bedrag gaat naar deze pot.
public struct DistributionLineSummary: Identifiable, Equatable, Sendable {
    public let id: Int64
    public let potId: Int64
    public let potName: String
    public let amount: Money
}

/// De vaste post van het lopende jaar die aan een storting gekoppeld is.
public struct DistributionItemLink: Identifiable, Equatable, Sendable {
    public let id: Int64
    public let label: String
    /// Planbedrag met teken (bij RESERVERINGEN de som van de RES-regels).
    public let plan: Money
}

/// Een vaste storting naar een spaarrekening met de verdeling over potten.
public struct DistributionSummary: Identifiable, Equatable, Sendable {
    public let id: Int64
    public let name: String
    public let accountId: Int64
    public let accountName: String
    public let archived: Bool
    public let lines: [DistributionLineSummary]
    /// Som van de regels (positief).
    public let total: Money
    /// De gekoppelde post in het jaar van `today`, of nil.
    public let item: DistributionItemLink?
    /// Het plan van de post (zonder teken) is gelijk aan het totaal; nil zonder gekoppelde post.
    public let planMatchesTotal: Bool?
}

/// Een pot in één vaste storting (voor het potdetail).
public struct PotDistributionUsage: Identifiable, Equatable, Sendable {
    /// Id van de storting.
    public let id: Int64
    public let name: String
    public let archived: Bool
    /// Het bedrag dat in deze storting naar de pot gaat.
    public let amount: Money
    /// Totaal van de hele storting.
    public let distributionTotal: Money
}

/// Beginboeking van één pot.
public struct OpeningPotAmount: Identifiable, Equatable, Sendable {
    /// Id van de pot.
    public let id: Int64
    public let potName: String
    public let amount: Money
}

/// De beginstand van een rekening: beginsaldo = potten + niet toegewezen.
public struct OpeningOverview: Equatable, Sendable {
    public let accountId: Int64
    public let accountName: String
    public let openingDate: Day
    /// `Account.openingBalance`: het deel van de beginstand dat niet als boeking is vastgelegd.
    public let accountOpeningBalance: Money
    /// De beginboekingen per pot (boekingen met notitie "Beginsaldo"), op volgorde van de potten.
    public let pots: [OpeningPotAmount]
    /// Som van de beginboekingen met een pot.
    public let potTotal: Money
    /// Niet toegewezen = `total` − `potTotal`.
    public let unallocated: Money
    /// Beginsaldo van de rekening = `accountOpeningBalance` + alle beginboekingen (met en zonder pot).
    public let total: Money
}

// MARK: - Functies

extension Insight {
    /// De notitie waaraan een beginboeking te herkennen is.
    public static let openingNote = "Beginsaldo"

    /// Alle vaste stortingen (op `sortOrder`, ook gearchiveerde) met regels, totaal, de gekoppelde post van het
    /// jaar van `today` en of plan en totaal gelijk zijn.
    public static func distributions(_ db: Database, today: Day) throws -> [DistributionSummary] {
        var lines: [Int64: [DistributionLineSummary]] = [:]
        for r in try Row.fetchAll(db, sql: """
            SELECT l.id, l.distributionId, l.potId, p.name AS potName, l.amount
            FROM distributionLine l JOIN pot p ON p.id = l.potId ORDER BY l.sortOrder, l.id
            """) {
            lines[r["distributionId"], default: []].append(
                DistributionLineSummary(id: r["id"], potId: r["potId"], potName: r["potName"], amount: r["amount"]))
        }
        var links: [Int64: DistributionItemLink] = [:]
        if let year = try BudgetYear.filter(Column("year") == today.year).fetchOne(db) {
            let plans = PlanSet(try Q.items(db, yearId: year.id!))
            for item in plans.items {
                guard let distributionId = item.distributionId, links[distributionId] == nil else { continue }
                links[distributionId] = DistributionItemLink(id: item.id!, label: item.label, plan: plans.plan(item))
            }
        }
        return try Row.fetchAll(db, sql: """
            SELECT d.id, d.name, d.accountId, a.name AS accountName, d.archived
            FROM distribution d JOIN account a ON a.id = d.accountId ORDER BY d.sortOrder, d.id
            """).map { r in
            let id: Int64 = r["id"]
            let own = lines[id] ?? []
            let total = own.map(\.amount).sum()
            let link = links[id]
            return DistributionSummary(id: id, name: r["name"], accountId: r["accountId"], accountName: r["accountName"],
                                       archived: r["archived"], lines: own, total: total, item: link,
                                       planMatchesTotal: link.map { $0.plan.magnitude == total })
        }
    }

    /// In welke vaste stortingen een pot voorkomt en voor welk bedrag.
    public static func distributionUsage(_ db: Database, potId: Int64) throws -> [PotDistributionUsage] {
        try Row.fetchAll(db, sql: """
            SELECT d.id, d.name, d.archived, l.amount,
                   (SELECT COALESCE(SUM(x.amount), 0) FROM distributionLine x WHERE x.distributionId = d.id) AS total
            FROM distributionLine l JOIN distribution d ON d.id = l.distributionId
            WHERE l.potId = ? ORDER BY d.sortOrder, d.id
            """, arguments: [potId]).map {
            PotDistributionUsage(id: $0["id"], name: $0["name"], archived: $0["archived"], amount: $0["amount"],
                                 distributionTotal: $0["total"])
        }
    }

    /// De beginstand van een rekening: het beginsaldo, de beginboekingen per pot (notitie "Beginsaldo") en wat
    /// niet aan een pot is toegewezen, zodat geldt: `total` = `potTotal` + `unallocated`.
    public static func openingOverview(_ db: Database, accountId: Int64) throws -> OpeningOverview {
        guard let account = try Account.fetchOne(db, key: accountId) else { throw InsightError.accountNotFound(accountId) }
        let pots = try Row.fetchAll(db, sql: """
            SELECT p.id, p.name, SUM(e.amount) AS s
            FROM entry e JOIN pot p ON p.id = e.potId
            WHERE e.accountId = ? AND e.note = ? GROUP BY p.id ORDER BY p.sortOrder, p.id
            """, arguments: [accountId, openingNote]).map {
            OpeningPotAmount(id: $0["id"], potName: $0["name"], amount: $0["s"])
        }
        let loose = try Money.fetchOne(db, sql: """
            SELECT COALESCE(SUM(amount), 0) FROM entry WHERE accountId = ? AND note = ? AND potId IS NULL
            """, arguments: [accountId, openingNote]) ?? .zero
        let potTotal = pots.map(\.amount).sum()
        return OpeningOverview(accountId: accountId, accountName: account.name, openingDate: account.openingDate,
                               accountOpeningBalance: account.openingBalance, pots: pots, potTotal: potTotal,
                               unallocated: account.openingBalance + loose,
                               total: account.openingBalance + loose + potTotal)
    }
}
