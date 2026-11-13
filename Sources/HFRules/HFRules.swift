import Foundation
import GRDB
import HFCore

// Module HFRules: regels toepassen op banktransacties, voorstellen met zekerheid, leren van correcties.
// Deze module stelt alleen voor en beheert regels; boeken (Entry) doet HFBudget.
// Publieke API: zie docs/api/HFRules.md.

/// Fouten van het regelbeheer, met een melding voor de gebruiker.
public enum RuleError: Error, LocalizedError, Equatable {
    case emptyName
    case noConditions
    case notFound(Int64)

    public var errorDescription: String? {
        switch self {
        case .emptyName: return "Geef de regel een naam."
        case .noConditions:
            return "Een regel heeft minstens één voorwaarde nodig (tegenpartij, IBAN, trefwoord of bedrag)."
        case .notFound(let id): return "Regel \(id) bestaat niet (meer)."
        }
    }
}

/// Een banktransactie die door een regel herkend wordt (voorbeeld in de regeleditor).
public struct RuleTestHit: Equatable, Sendable {
    public var transaction: BankTransaction
    public var match: RuleMatch
    public var confidence: Confidence { match.confidence }
    public var amountDiffers: Bool { match.amountDiffers }
}

/// Ingang van de module. Alle functies werken binnen een bestaande databasetransactie
/// (`appDatabase.read { db in … }` of `appDatabase.write { db in … }`).
public enum RuleEngine {

    // MARK: Voorstellen

    /// Voorstel voor één banktransactie.
    public static func suggest(for transaction: BankTransaction, _ db: Database) throws -> Suggestion {
        try RuleMatcher(db).suggest(for: transaction)
    }

    /// Voorstellen voor alle transacties met status `nieuw`, per transactie-id.
    /// `accountId` beperkt tot één rekening. De regels worden één keer geladen.
    public static func suggestAll(_ db: Database, accountId: Int64? = nil) throws -> [Int64: Suggestion] {
        let matcher = try RuleMatcher(db)
        var request = BankTransaction.filter(Column("status") == BankTransactionStatus.nieuw)
        if let accountId { request = request.filter(Column("accountId") == accountId) }
        var result: [Int64: Suggestion] = [:]
        for tx in try request.fetchAll(db) {
            if let id = tx.id { result[id] = matcher.suggest(for: tx) }
        }
        return result
    }

    /// Legt vast dat een regel gebruikt is: `hitCount` + 1 en `lastUsed`.
    public static func recordUse(ruleId: Int64, _ db: Database, at date: Date = Date()) throws {
        try db.execute(sql: "UPDATE rule SET hitCount = hitCount + 1, lastUsed = ? WHERE id = ?",
                       arguments: [date, ruleId])
    }

    // MARK: Regelbeheer

    /// Alle regels in volgorde van `priority` (daarna id).
    public static func rules(_ db: Database) throws -> [Rule] {
        try Rule.order(Column("priority"), Column("id")).fetchAll(db)
    }

    /// Eén regel, of nil.
    public static func rule(id: Int64, _ db: Database) throws -> Rule? {
        try Rule.fetchOne(db, key: id)
    }

    /// Controleert een regel zonder hem op te slaan: naam en minstens één voorwaarde.
    public static func validate(_ rule: Rule) throws {
        guard RuleMatcher.filled(rule.name) != nil else { throw RuleError.emptyName }
        guard RuleMatcher.filled(rule.counterpartyContains) != nil || RuleMatcher.filled(rule.counterpartyIban) != nil
                || RuleMatcher.filled(rule.descriptionContains) != nil || rule.amount != nil
        else { throw RuleError.noConditions }
    }

    /// Slaat een nieuwe of gewijzigde regel op (na `validate`). Lege tekstvoorwaarden worden nil,
    /// een IBAN wordt zonder spaties en in hoofdletters bewaard.
    public static func save(_ rule: inout Rule, _ db: Database) throws {
        try validate(rule)
        rule.name = TextNormalizer.collapse(rule.name)
        rule.counterpartyContains = RuleMatcher.filled(rule.counterpartyContains)
        rule.counterpartyIban = RuleMatcher.filled(rule.counterpartyIban).map(TextNormalizer.normalizeIban)
        rule.descriptionContains = RuleMatcher.filled(rule.descriptionContains)
        rule.targetItemLabel = RuleMatcher.filled(rule.targetItemLabel)
        rule.entryLabel = RuleMatcher.filled(rule.entryLabel)
        try rule.save(db)
    }

    /// Verwijdert een regel. Geeft false als hij niet bestond.
    @discardableResult
    public static func delete(ruleId: Int64, _ db: Database) throws -> Bool {
        try Rule.deleteOne(db, key: ruleId)
    }

    /// Zet een regel aan of uit.
    public static func setEnabled(ruleId: Int64, _ enabled: Bool, _ db: Database) throws {
        try db.execute(sql: "UPDATE rule SET enabled = ? WHERE id = ?", arguments: [enabled, ruleId])
        if db.changesCount == 0 { throw RuleError.notFound(ruleId) }
    }

    /// Nieuwe volgorde: de genoemde regels krijgen priority 10, 20, 30 … in deze volgorde;
    /// regels die niet genoemd zijn volgen daarna in hun oude volgorde.
    public static func reorder(ruleIds: [Int64], _ db: Database) throws {
        let all = try rules(db).compactMap(\.id)
        let known = Set(all)
        var seen = Set<Int64>()
        var order = ruleIds.filter { known.contains($0) && seen.insert($0).inserted }
        order += all.filter { !seen.contains($0) }
        for (index, id) in order.enumerated() {
            try db.execute(sql: "UPDATE rule SET priority = ? WHERE id = ?", arguments: [(index + 1) * 10, id])
        }
    }

    /// Welke bestaande banktransacties zou deze (eventueel nog niet opgeslagen) regel herkennen?
    /// Nieuwste eerst. Of de regel aan of uit staat telt hier niet mee.
    public static func testRule(_ rule: Rule, against db: Database, limit: Int? = nil) throws -> [RuleTestHit] {
        var hits: [RuleTestHit] = []
        let cursor = try BankTransaction.order(Column("day").desc, Column("id").desc).fetchCursor(db)
        while let tx = try cursor.next() {
            if let match = RuleMatcher.match(rule, tx, ignoreEnabled: true) {
                hits.append(RuleTestHit(transaction: tx, match: match))
                if let limit, hits.count >= limit { break }
            }
        }
        return hits
    }
}
