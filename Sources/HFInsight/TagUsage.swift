import Foundation
import GRDB
import HFCore

// MARK: - Gebruik van tags en het filter bij "n boekingen"

/// Hoe vaak een tag gebruikt wordt, uitgesplitst naar soort rekening.
public struct TagUsage: Equatable, Sendable {
    public var tagId: Int64
    /// Boekingen met deze tag op een betaalrekening.
    public var onPayment: Int
    /// Boekingen met deze tag op een spaarrekening (van vóór de regel "tags alleen op de betaalrekening").
    public var onSavings: Int
    public var total: Int { onPayment + onSavings }

    public init(tagId: Int64, onPayment: Int = 0, onSavings: Int = 0) {
        self.tagId = tagId; self.onPayment = onPayment; self.onSavings = onSavings
    }
}

/// Waar Transacties naartoe gaat bij een klik op "n boekingen" van een tag: deze rekening, filter op deze tag.
public struct TagFilterTarget: Equatable, Sendable {
    public var accountId: Int64
    public var tagId: Int64
    public init(accountId: Int64, tagId: Int64) { self.accountId = accountId; self.tagId = tagId }
}

extension Insight {
    /// Gebruik per tag (alleen tags met minstens één boeking).
    public static func tagUsage(_ db: Database) throws -> [Int64: TagUsage] {
        var result: [Int64: TagUsage] = [:]
        for row in try Row.fetchAll(db, sql: """
            SELECT entryTag.tagId AS tagId, account.kind AS kind, COUNT(*) AS n
            FROM entryTag
            JOIN entry ON entry.id = entryTag.entryId
            JOIN account ON account.id = entry.accountId
            GROUP BY entryTag.tagId, account.kind
            """) {
            let tagId: Int64 = row["tagId"]
            let n: Int = row["n"]
            var usage = result[tagId] ?? TagUsage(tagId: tagId)
            if (row["kind"] as String) == AccountKind.betaal.rawValue { usage.onPayment += n } else { usage.onSavings += n }
            result[tagId] = usage
        }
        return result
    }

    /// Het filter voor Transacties bij een klik op "n boekingen" van een tag: altijd een betaalrekening (tags
    /// horen daar), en wel die met de meeste boekingen met deze tag. Zonder zulke boekingen de eerste
    /// betaalrekening die niet gearchiveerd is (op volgorde). nil als er geen betaalrekening is.
    public static func tagFilterTarget(_ db: Database, tagId: Int64) throws -> TagFilterTarget? {
        let accountId = try Int64.fetchOne(db, sql: """
            SELECT account.id FROM account
            LEFT JOIN (
                SELECT entry.accountId AS accountId, COUNT(*) AS n
                FROM entryTag JOIN entry ON entry.id = entryTag.entryId
                WHERE entryTag.tagId = ?
                GROUP BY entry.accountId
            ) used ON used.accountId = account.id
            WHERE account.kind = ?
            ORDER BY COALESCE(used.n, 0) DESC, account.archived, account.sortOrder, account.id
            LIMIT 1
            """, arguments: [tagId, AccountKind.betaal.rawValue])
        return accountId.map { TagFilterTarget(accountId: $0, tagId: tagId) }
    }
}
