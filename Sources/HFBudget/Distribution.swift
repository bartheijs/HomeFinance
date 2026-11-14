import Foundation
import GRDB
import HFCore

// MARK: - Vaste storting met verdeling

/// Voorstel om een storting op de spaarrekening te verdelen volgens een vaste storting.
public struct DistributionProposal: Equatable, Sendable {
    public var distribution: Distribution
    /// Eén regel per pot, met de bedragen van de verdeling (niet aangepast aan een afwijkend bedrag).
    public var allocations: [Allocation]
    /// Het totaal van de verdeling.
    public var total: Money
    /// Gestort bedrag − totaal. Niet nul: de gebruiker kiest waar het verschil heen gaat.
    public var difference: Money
    /// Het bedrag is precies het totaal; de regels kunnen zo geboekt worden.
    public var isExact: Bool { difference.isZero }
}

/// Vaste stortingen: een bedrag dat regelmatig van de betaalrekening naar een spaarrekening gaat en daar over
/// potten wordt verdeeld. Er kunnen er meer zijn.
///
/// Een post op de betaalrekening kan aan een storting gekoppeld zijn (`BudgetItem.distributionId`). Het plan van
/// zo'n post is altijd − het totaal van de storting, in elk niet afgesloten jaar.
public enum DistributionService {
    /// Maakt een vaste storting op een spaarrekening (nog zonder regels); komt achteraan in de volgorde.
    /// `sourceAccountId` is de betaalrekening waar het geld vandaan komt (optioneel; nodig om beide kanten van de
    /// overboeking te herkennen, zie `recognize`).
    @discardableResult
    public static func create(_ db: Database, name: String, accountId: Int64,
                              sourceAccountId: Int64? = nil) throws -> Distribution {
        try atomic(db) {
            var distribution = Distribution(name: try Check.nonEmpty(name, "De naam van de storting"),
                                            accountId: accountId, sourceAccountId: sourceAccountId)
            try savingsAccount(db, accountId)
            try validateSource(db, sourceAccountId, target: accountId)
            distribution.sortOrder = try Check.nextSortOrder(db, table: "distribution")
            try distribution.insert(db)
            return distribution
        }
    }

    /// Wijzigt de naam van een storting. De rekening, volgorde en archivering blijven gelijk.
    @discardableResult
    public static func rename(_ db: Database, distributionId: Int64, name: String) throws -> Distribution {
        try atomic(db) {
            var distribution = try fetch(db, distributionId)
            distribution.name = try Check.nonEmpty(name, "De naam van de storting")
            try distribution.update(db)
            return distribution
        }
    }

    /// Zet de herkomstrekening (een betaalrekening, niet dezelfde als het doel) of haalt haar weg met nil.
    @discardableResult
    public static func setSource(_ db: Database, distributionId: Int64, sourceAccountId: Int64?) throws -> Distribution {
        try atomic(db) {
            var distribution = try fetch(db, distributionId)
            try validateSource(db, sourceAccountId, target: distribution.accountId)
            distribution.sourceAccountId = sourceAccountId
            try distribution.update(db)
            return distribution
        }
    }

    /// Verwijdert een storting met haar regels. Gekoppelde posten raken de koppeling kwijt en houden hun plan.
    public static func delete(_ db: Database, distributionId: Int64) throws {
        try atomic(db) {
            _ = try fetch(db, distributionId)
            try db.execute(sql: "DELETE FROM distribution WHERE id = ?", arguments: [distributionId])
        }
    }

    /// Archiveert een storting of haalt haar terug. Een gearchiveerde storting wordt niet meer voorgesteld.
    public static func setArchived(_ db: Database, distributionId: Int64, _ archived: Bool) throws {
        try atomic(db) {
            _ = try fetch(db, distributionId)
            try db.execute(sql: "UPDATE distribution SET archived = ? WHERE id = ?", arguments: [archived, distributionId])
        }
    }

    /// Zet de stortingen in de gegeven volgorde (alle id's).
    public static func reorder(_ db: Database, orderedIds: [Int64]) throws {
        try atomic(db) {
            try Check.reorder(db, table: "distribution",
                              existingIds: try Int64.fetchAll(db, sql: "SELECT id FROM distribution"),
                              orderedIds: orderedIds)
        }
    }

    /// Alle stortingen op volgorde, standaard zonder de gearchiveerde.
    public static func all(_ db: Database, includeArchived: Bool = false) throws -> [Distribution] {
        try Distribution.fetchAll(db, sql: """
            SELECT * FROM distribution WHERE archived = 0 OR ? ORDER BY sortOrder, id
            """, arguments: [includeArchived])
    }

    // MARK: Regels

    /// De regels van een storting, op volgorde.
    public static func lines(_ db: Database, distributionId: Int64) throws -> [DistributionLine] {
        try DistributionLine.fetchAll(db, sql: """
            SELECT * FROM distributionLine WHERE distributionId = ? ORDER BY sortOrder, id
            """, arguments: [distributionId])
    }

    /// Vervangt de hele verdeling in één keer; de volgorde van de lijst wordt de volgorde van de regels.
    /// Elke pot hoort bij de spaarrekening van de storting en komt hoogstens één keer voor; bedragen zijn > 0.
    /// Werkt daarna het plan van de gekoppelde posten bij.
    @discardableResult
    public static func setLines(_ db: Database, distributionId: Int64,
                                _ lines: [(potId: Int64, amount: Money)]) throws -> [DistributionLine] {
        try atomic(db) {
            let distribution = try fetch(db, distributionId)
            var seen = Set<Int64>()
            for line in lines {
                let pot = try Check.pot(db, line.potId)
                guard pot.accountId == distribution.accountId else { throw BudgetError.potWrongAccount(pot: pot.name) }
                guard line.amount > .zero else {
                    throw BudgetError.validation("Het bedrag voor de pot \(pot.name) moet groter dan nul zijn.")
                }
                guard seen.insert(line.potId).inserted else {
                    throw BudgetError.validation("De pot \(pot.name) staat meer dan één keer in de verdeling.")
                }
            }
            try db.execute(sql: "DELETE FROM distributionLine WHERE distributionId = ?", arguments: [distributionId])
            for (index, line) in lines.enumerated() {
                var record = DistributionLine(distributionId: distributionId, potId: line.potId, amount: line.amount,
                                              sortOrder: index)
                try record.insert(db)
            }
            try syncLinkedPlans(db, distributionId: distributionId)
            return try self.lines(db, distributionId: distributionId)
        }
    }

    /// Zet het bedrag voor één pot: wijzigt de bestaande regel of voegt er een toe (achteraan).
    @discardableResult
    public static func setLine(_ db: Database, distributionId: Int64, potId: Int64,
                               amount: Money) throws -> [DistributionLine] {
        try atomic(db) {
            var current = try lines(db, distributionId: distributionId).map { (potId: $0.potId, amount: $0.amount) }
            if let index = current.firstIndex(where: { $0.potId == potId }) {
                current[index].amount = amount
            } else {
                current.append((potId, amount))
            }
            return try setLines(db, distributionId: distributionId, current)
        }
    }

    /// Haalt een pot uit de verdeling.
    @discardableResult
    public static func removeLine(_ db: Database, distributionId: Int64, potId: Int64) throws -> [DistributionLine] {
        try atomic(db) {
            let current = try lines(db, distributionId: distributionId).map { (potId: $0.potId, amount: $0.amount) }
            return try setLines(db, distributionId: distributionId, current.filter { $0.potId != potId })
        }
    }

    /// Het totaal van de storting: de som van haar regels.
    public static func total(_ db: Database, distributionId: Int64) throws -> Money {
        _ = try fetch(db, distributionId)
        return try Money.fetchOne(db, sql: """
            SELECT COALESCE(SUM(amount), 0) FROM distributionLine WHERE distributionId = ?
            """, arguments: [distributionId]) ?? .zero
    }

    // MARK: Koppeling met de post

    /// Koppelt een UIT-post op de betaalrekening aan de storting; zijn plan wordt − het totaal.
    @discardableResult
    public static func link(_ db: Database, distributionId: Int64, budgetItemId: Int64) throws -> BudgetItem {
        try atomic(db) {
            _ = try fetch(db, distributionId)
            let item = try Check.item(db, budgetItemId)
            try Check.yearOpen(db, yearId: item.yearId)
            guard item.direction == .UIT else {
                throw BudgetError.validation("Alleen een UIT-post kan aan een vaste storting gekoppeld worden; "
                    + "\(item.label) is \(item.direction.rawValue).")
            }
            try db.execute(sql: "UPDATE budgetItem SET distributionId = ? WHERE id = ?",
                           arguments: [distributionId, budgetItemId])
            try syncLinkedPlans(db, distributionId: distributionId)
            return try Check.item(db, budgetItemId)
        }
    }

    /// Verbreekt de koppeling van een post; het plan blijft zoals het was en is weer vrij te wijzigen.
    @discardableResult
    public static func unlink(_ db: Database, budgetItemId: Int64) throws -> BudgetItem {
        try atomic(db) {
            let item = try Check.item(db, budgetItemId)
            try Check.yearOpen(db, yearId: item.yearId)
            try db.execute(sql: "UPDATE budgetItem SET distributionId = NULL WHERE id = ?", arguments: [budgetItemId])
            try YearService.syncReserveTotal(db, yearId: item.yearId)
            return try Check.item(db, budgetItemId)
        }
    }

    /// De posten die aan een storting gekoppeld zijn (alle jaren, nieuwste jaar eerst).
    public static func linkedItems(_ db: Database, distributionId: Int64) throws -> [BudgetItem] {
        try BudgetItem.fetchAll(db, sql: """
            SELECT budgetItem.* FROM budgetItem JOIN budgetYear ON budgetYear.id = budgetItem.yearId
            WHERE budgetItem.distributionId = ? ORDER BY budgetYear.year DESC, budgetItem.sortOrder
            """, arguments: [distributionId])
    }

    // MARK: Voorstellen

    /// De regels van de storting als boekingsregels (label "<storting>: <pot>") voor een gestort bedrag.
    /// Is het bedrag gelijk aan het totaal, dan is het voorstel exact. Wijkt het af, dan blijven de regels de
    /// vaste verdeling en staat het verschil in `difference`; er wordt niets automatisch verrekend.
    public static func allocations(_ db: Database, distributionId: Int64, for amount: Money) throws -> DistributionProposal {
        let distribution = try fetch(db, distributionId)
        let rows = try Row.fetchAll(db, sql: """
            SELECT distributionLine.potId, distributionLine.amount, pot.name
            FROM distributionLine JOIN pot ON pot.id = distributionLine.potId
            WHERE distributionLine.distributionId = ? ORDER BY distributionLine.sortOrder, distributionLine.id
            """, arguments: [distributionId])
        let allocations = rows.map { row -> Allocation in
            let name: String = row["name"]
            return Allocation(amount: row["amount"], label: "\(distribution.name): \(name)", potId: row["potId"])
        }
        let total = allocations.map(\.amount).sum()
        return DistributionProposal(distribution: distribution, allocations: allocations, total: total,
                                    difference: amount - total)
    }

    /// De niet-gearchiveerde stortingen van een spaarrekening waarvan het totaal gelijk is aan het bedrag.
    public static func match(_ db: Database, accountId: Int64, amount: Money) throws -> [Distribution] {
        try Distribution.fetchAll(db, sql: """
            SELECT distribution.* FROM distribution
            WHERE accountId = ? AND archived = 0
              AND (SELECT SUM(amount) FROM distributionLine WHERE distributionId = distribution.id) = ?
            ORDER BY sortOrder, id
            """, arguments: [accountId, amount])
    }

    /// Eenmalige hulp voor bestaande administraties: maakt een storting uit de (niet-gearchiveerde)
    /// reserveringspotten met een maandbedrag, en koppelt de regel RESERVERINGEN van `year` (standaard het
    /// lopende jaar) als die bestaat en het jaar open is.
    @discardableResult
    public static func createFromPots(_ db: Database, accountId: Int64, name: String,
                                      year: Int = Day.today().year) throws -> Distribution {
        try atomic(db) {
            let pots = try Pot.fetchAll(db, sql: """
                SELECT * FROM pot WHERE accountId = ? AND kind = ? AND archived = 0 AND monthlyAmount > 0
                ORDER BY sortOrder, id
                """, arguments: [accountId, PotKind.reservering])
            guard !pots.isEmpty else {
                throw BudgetError.validation("Deze rekening heeft geen reserveringspotten met een maandbedrag.")
            }
            let distribution = try create(db, name: name, accountId: accountId)
            try setLines(db, distributionId: distribution.id!, pots.map { (potId: $0.id!, amount: $0.monthlyAmount) })
            let reserveItemId = try Int64.fetchOne(db, sql: """
                SELECT budgetItem.id FROM budgetItem JOIN budgetYear ON budgetYear.id = budgetItem.yearId
                WHERE budgetYear.year = ? AND budgetYear.closed = 0 AND budgetItem.isReserveTotal = 1
                """, arguments: [year])
            if let reserveItemId { try link(db, distributionId: distribution.id!, budgetItemId: reserveItemId) }
            return distribution
        }
    }

    // MARK: Intern

    private static func validateSource(_ db: Database, _ sourceAccountId: Int64?, target: Int64) throws {
        guard let sourceAccountId else { return }
        let source = try Check.account(db, sourceAccountId)
        guard sourceAccountId != target, source.kind == .betaal else {
            throw BudgetError.validation("De herkomst van een vaste storting moet een betaalrekening zijn, "
                + "en een andere dan de spaarrekening waar de storting op binnenkomt.")
        }
    }

    static func fetch(_ db: Database, _ id: Int64) throws -> Distribution {
        try Check.fetch(db, Distribution.self, id, "Vaste storting")
    }

    private static func savingsAccount(_ db: Database, _ accountId: Int64) throws {
        let account = try Check.account(db, accountId)
        guard account.kind == .spaar else {
            throw BudgetError.validation("Een vaste storting hoort bij een spaarrekening; \(account.name) is een betaalrekening.")
        }
    }

    /// Plan van de gekoppelde posten = − totaal, in niet afgesloten jaren. `distributionId` nil = alle stortingen.
    static func syncLinkedPlans(_ db: Database, distributionId: Int64? = nil, yearId: Int64? = nil) throws {
        try db.execute(sql: """
            UPDATE budgetItem SET planAmount =
                -(SELECT COALESCE(SUM(amount), 0) FROM distributionLine
                  WHERE distributionLine.distributionId = budgetItem.distributionId)
            WHERE distributionId IS NOT NULL
              AND (? IS NULL OR distributionId = ?) AND (? IS NULL OR yearId = ?)
              AND yearId IN (SELECT id FROM budgetYear WHERE closed = 0)
            """, arguments: [distributionId, distributionId, yearId, yearId])
    }
}

// MARK: - Post met de hand afvinken

/// Een vaste post met de hand afvinken voor een maand: hij geldt dan als voldaan, ook zonder boeking.
public enum ItemCheckService {
    /// Vinkt een post af voor een maand (1–12) van zijn jaar, of haalt het vinkje weg. Opnieuw afvinken werkt de
    /// notitie bij. Geweigerd in een afgesloten jaar en voor reserveringsregels (RES).
    public static func setChecked(_ db: Database, budgetItemId: Int64, month: Int, _ checked: Bool,
                                  note: String = "") throws {
        try atomic(db) {
            let item = try Check.item(db, budgetItemId)
            try Check.yearOpen(db, yearId: item.yearId)
            guard item.direction != .RES else {
                throw BudgetError.validation("De reserveringsregel \(item.label) kan niet afgevinkt worden; "
                    + "vink de regel RESERVERINGEN af.")
            }
            guard (1...12).contains(month) else {
                throw BudgetError.validation("De maand moet tussen 1 en 12 liggen.")
            }
            try db.execute(sql: "DELETE FROM itemCheck WHERE budgetItemId = ? AND month = ?",
                           arguments: [budgetItemId, month])
            if checked {
                var check = ItemCheck(budgetItemId: budgetItemId, month: month, note: note)
                try check.insert(db)
            }
        }
    }

    /// Alle vinkjes van een jaar, op post en maand.
    public static func checks(_ db: Database, yearId: Int64) throws -> [ItemCheck] {
        try ItemCheck.fetchAll(db, sql: """
            SELECT itemCheck.* FROM itemCheck JOIN budgetItem ON budgetItem.id = itemCheck.budgetItemId
            WHERE budgetItem.yearId = ? ORDER BY budgetItem.sortOrder, itemCheck.month
            """, arguments: [yearId])
    }
}

// MARK: - Omschrijvingen hernoemen en samenvoegen

/// Aantal aangepaste boekingen en regels na het hernoemen van een omschrijving.
public struct LabelRenameResult: Equatable, Sendable {
    public var entryCount: Int
    public var ruleCount: Int
    public init(entryCount: Int = 0, ruleCount: Int = 0) { self.entryCount = entryCount; self.ruleCount = ruleCount }
}

/// Omschrijvingen van boekingen gelijktrekken, zodat dezelfde omschrijving niet in twee schrijfwijzen bestaat.
///
/// Boekingen in een afgesloten jaar gaan mee: een omschrijving is een schrijfwijze, geen bedrag of toewijzing,
/// en anders blijft de dubbele schrijfwijze juist in de historie bestaan.
public enum LabelService {
    /// Vergelijkingsvorm van een omschrijving: zonder spaties vooraan en achteraan, meervoudige spaties
    /// samengevoegd, hoofdletterongevoelig.
    public static func normalize(_ label: String) -> String {
        clean(label).folding(options: .caseInsensitive, locale: nil)
    }

    /// Geeft alle boekingen waarvan de omschrijving (genormaliseerd) gelijk is aan `from` de omschrijving `to`,
    /// en doet hetzelfde voor `entryLabel` van regels. Bestaat `to` al, dan is dit samenvoegen.
    /// Geeft het aantal werkelijk gewijzigde boekingen en regels terug; een lege `to` wordt geweigerd.
    @discardableResult
    public static func renameLabel(_ db: Database, from: String, to: String) throws -> LabelRenameResult {
        try mergeLabels(db, [from], into: to)
    }

    /// Voegt meer schrijfwijzen in één keer samen tot `into`.
    @discardableResult
    public static func mergeLabels(_ db: Database, _ labels: [String], into: String) throws -> LabelRenameResult {
        try atomic(db) {
            let target = clean(into)
            guard !target.isEmpty else { throw BudgetError.validation("De nieuwe omschrijving mag niet leeg zijn.") }
            let wanted = Set(labels.map(normalize).filter { !$0.isEmpty })
            var result = LabelRenameResult()
            func rewrite(table: String, column: String) throws -> Int {
                let existing = try String.fetchAll(db, sql: """
                    SELECT DISTINCT \(column) FROM \(table) WHERE \(column) IS NOT NULL
                    """)
                var changed = 0
                for label in existing where label != target && wanted.contains(normalize(label)) {
                    try db.execute(sql: "UPDATE \(table) SET \(column) = ? WHERE \(column) = ?",
                                   arguments: [target, label])
                    changed += db.changesCount
                }
                return changed
            }
            result.entryCount = try rewrite(table: "entry", column: "label")
            result.ruleCount = try rewrite(table: "rule", column: "entryLabel")
            return result
        }
    }

    /// Groepen omschrijvingen van boekingen die alleen in hoofdletters of spaties verschillen, om op te ruimen.
    public static func spellingVariants(_ db: Database) throws -> [[String]] {
        let labels = try String.fetchAll(db, sql: "SELECT DISTINCT label FROM entry ORDER BY label")
        return Dictionary(grouping: labels, by: normalize).values
            .filter { $0.count > 1 }
            .map { $0.sorted() }
            .sorted { $0[0] < $1[0] }
    }

    private static func clean(_ label: String) -> String {
        label.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}
