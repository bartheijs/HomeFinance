import Foundation
import GRDB
import HFCore

// MARK: - Verrekenen per tag

/// Een verrekening met de gekoppelde storting en het verschil daarmee.
public struct SettlementResult: Equatable, Sendable {
    public var settlement: Settlement
    /// De gekoppelde bijschrijving (terugstorting), als die er is.
    public var deposit: Entry?
    /// Storting − verrekend bedrag: positief = te veel gestort, negatief = te weinig. nil zonder storting.
    public var difference: Money? { deposit.map { $0.amount - settlement.amount } }
}

/// Verrekenen per tag: uitgaven met een tag (bv. Tanken) die de gebruiker periodiek terugstort.
///
/// Openstaand voor een tag = − de som van de boekingen op betaalrekeningen met die tag en zonder
/// `settlementId`, plus het startbedrag van de tag zolang dat niet verrekend is (`Tag.startAmount`).
/// Een retour met dezelfde tag telt eraf. De terugstorting zelf krijgt de tag niet; zij wordt
/// gekoppeld via `Settlement.depositEntryId`. Een afgesloten jaar blokkeert het verrekenen niet.
public enum SettlementService {
    /// Aantal dagen terug waarin `suggestDeposit` naar een terugstorting zoekt.
    public static let suggestionDays = 45
    /// Hoeveel een voorgestelde storting mag afwijken van het openstaande bedrag.
    public static let suggestionTolerance = Money(cents: 100)

    /// Zet verrekenen aan voor een tag. Alle nog niet verrekende boekingen met die tag van vóór `from` gaan in
    /// één beginstand (`isOpening`, bedrag mag 0 zijn), zodat alleen boekingen vanaf `from` openstaan.
    /// Opnieuw aanroepen met een andere datum vervangt de beginstand; echte verrekeningen blijven staan.
    @discardableResult
    public static func enable(_ db: Database, tagId: Int64, from: Day) throws -> Settlement {
        try atomic(db) {
            _ = try Check.tag(db, tagId)
            try db.execute(sql: "UPDATE tag SET settles = 1 WHERE id = ?", arguments: [tagId])
            try db.execute(sql: """
                UPDATE entry SET settlementId = NULL
                WHERE settlementId IN (SELECT id FROM settlement WHERE tagId = ? AND isOpening = 1)
                """, arguments: [tagId])
            try db.execute(sql: "DELETE FROM settlement WHERE tagId = ? AND isOpening = 1", arguments: [tagId])
            let earlier = try openEntries(db, tagId: tagId).filter { $0.day < from }
            var opening = Settlement(tagId: tagId, day: from, amount: -earlier.map(\.amount).sum(), isOpening: true,
                                     note: "Beginstand")
            try opening.insert(db)
            try assign(db, earlier, to: opening.id!)
            return opening
        }
    }

    /// Legt het startbedrag van een tag vast: wat er bij de start van de app al openstond en nog terug moet komen
    /// (bv. uit de periode in Excel), met de dag. Het telt mee in het openstaande bedrag en gaat bij het
    /// verrekenen mee als een openstaande post (`settle(includeStart:)`). € 0,00 haalt het startbedrag weg.
    /// Alleen bij een tag met verrekenen aan, en niet meer als het startbedrag al verrekend is.
    @discardableResult
    public static func setStart(_ db: Database, tagId: Int64, amount: Money, day: Day) throws -> Tag {
        try atomic(db) {
            var tag = try Check.tag(db, tagId)
            guard tag.settles else { throw BudgetError.tagNotSettling(tag: tag.name) }
            guard tag.startSettlementId == nil else {
                throw BudgetError.validation("Het startbedrag van ‘\(tag.name)’ is al verrekend. Maak die verrekening "
                    + "eerst ongedaan om het te wijzigen.")
            }
            guard !amount.isNegative else {
                throw BudgetError.validation("Het startbedrag is wat er nog terug moet komen en kan niet negatief zijn.")
            }
            tag.startAmount = amount
            tag.startDay = amount.isZero ? nil : day
            try tag.update(db)
            return tag
        }
    }

    /// Zet verrekenen uit voor een tag. Bestaande verrekeningen (ook de beginstand) en het startbedrag blijven staan.
    public static func disable(_ db: Database, tagId: Int64) throws {
        try atomic(db) {
            _ = try Check.tag(db, tagId)
            try db.execute(sql: "UPDATE tag SET settles = 0 WHERE id = ?", arguments: [tagId])
        }
    }

    /// De openstaande boekingen van een tag (oudste eerst), het nog openstaande startbedrag (€ 0,00 als er geen is
    /// of als het verrekend is) en het openstaande bedrag samen (positief = nog terug te storten).
    public static func open(_ db: Database, tagId: Int64) throws -> (entries: [Entry], start: Money, amount: Money) {
        let entries = try openEntries(db, tagId: tagId)
        let tag = try Check.tag(db, tagId)
        let start = tag.startIsOpen ? tag.startAmount : .zero
        return (entries, start, start - entries.map(\.amount).sum())
    }

    /// Legt een verrekening vast voor de gekozen openstaande boekingen; het bedrag is − hun som, plus het
    /// startbedrag als `includeStart` (dat moet dan nog openstaan). Met `depositEntryId` wordt meteen de terugstorting gekoppeld; die hoeft niet exact gelijk te zijn aan het
    /// verrekende bedrag (zie `SettlementResult.difference`).
    @discardableResult
    public static func settle(_ db: Database, tagId: Int64, entryIds: [Int64], includeStart: Bool = false, day: Day,
                              depositEntryId: Int64? = nil, note: String = "") throws -> SettlementResult {
        try atomic(db) {
            var tag = try Check.tag(db, tagId)
            guard tag.settles else { throw BudgetError.tagNotSettling(tag: tag.name) }
            let ids = Array(Set(entryIds))
            guard !ids.isEmpty || includeStart else {
                throw BudgetError.validation("Kies minstens één boeking om te verrekenen.")
            }
            guard !includeStart || tag.startIsOpen else {
                throw BudgetError.validation("Het startbedrag van ‘\(tag.name)’ staat niet (meer) open.")
            }
            let openIds = Set(try openEntries(db, tagId: tagId).compactMap(\.id))
            var entries: [Entry] = []
            for id in ids {
                let entry = try Check.entry(db, id)
                guard openIds.contains(id) else { throw BudgetError.notSettleable(entry: entry.label, tag: tag.name) }
                entries.append(entry)
            }
            let amount = (includeStart ? tag.startAmount : .zero) - entries.map(\.amount).sum()
            guard !amount.isNegative else {
                throw BudgetError.validation("De gekozen boekingen leveren samen geen terug te storten bedrag op "
                    + "(\(amount.formatted())).")
            }
            var settlement = Settlement(tagId: tagId, day: day, amount: amount, note: note)
            try settlement.insert(db)
            try assign(db, entries, to: settlement.id!)
            if includeStart {
                tag.startSettlementId = settlement.id
                try tag.update(db)
            }
            if let depositEntryId {
                return try linkDeposit(db, settlementId: settlement.id!, depositEntryId: depositEntryId)
            }
            return SettlementResult(settlement: settlement, deposit: nil)
        }
    }

    /// Voorstellen voor de terugstorting: bijschrijvingen op betaalrekeningen van de laatste 45 dagen zonder vaste
    /// post, nog aan geen verrekening gekoppeld, met het openstaande bedrag (exact eerst, daarna binnen € 1,00),
    /// nieuwste eerst. Leeg als er niets openstaat.
    public static func suggestDeposit(_ db: Database, tagId: Int64, asOf today: Day = .today()) throws -> [Entry] {
        let amount = try open(db, tagId: tagId).amount
        guard amount > .zero else { return [] }
        return try Entry.fetchAll(db, sql: """
            SELECT entry.* FROM entry JOIN account ON account.id = entry.accountId
            WHERE account.kind = ? AND entry.amount > 0 AND entry.budgetItemId IS NULL
              AND entry.counterEntryId IS NULL AND entry.day >= ? AND entry.day <= ?
              AND ABS(entry.amount - ?) <= ?
              AND entry.id NOT IN (SELECT depositEntryId FROM settlement WHERE depositEntryId IS NOT NULL)
              AND entry.id NOT IN (SELECT entryId FROM entryTag WHERE tagId = ?)
            ORDER BY (entry.amount = ?) DESC, entry.day DESC, entry.id DESC
            """, arguments: [AccountKind.betaal, today.adding(days: -suggestionDays), today, amount,
                             suggestionTolerance, tagId, amount])
    }

    /// Koppelt een bijschrijving als terugstorting aan een verrekening (vervangt een eerdere koppeling);
    /// `nil` ontkoppelt. De storting is een positief bedrag op een betaalrekening, zonder de tag, en hoort bij
    /// hoogstens één verrekening.
    @discardableResult
    public static func linkDeposit(_ db: Database, settlementId: Int64, depositEntryId: Int64?) throws -> SettlementResult {
        try atomic(db) {
            var settlement = try Check.fetch(db, Settlement.self, settlementId, "Verrekening")
            guard !settlement.isOpening || depositEntryId == nil else {
                throw BudgetError.depositInvalid("Aan een beginstand kan geen storting gekoppeld worden.")
            }
            var deposit: Entry?
            if let depositEntryId {
                let entry = try Check.entry(db, depositEntryId)
                let account = try Check.account(db, entry.accountId)
                guard account.kind == .betaal, entry.amount > .zero else {
                    throw BudgetError.depositInvalid("De terugstorting moet een bijschrijving op een betaalrekening zijn.")
                }
                let hasTag = try Bool.fetchOne(db, sql: """
                    SELECT EXISTS(SELECT 1 FROM entryTag WHERE entryId = ? AND tagId = ?)
                    """, arguments: [depositEntryId, settlement.tagId]) ?? false
                guard !hasTag else {
                    throw BudgetError.depositInvalid("De terugstorting mag zelf niet de tag van de verrekening hebben; "
                        + "haal de tag van de bijschrijving af.")
                }
                let other = try Int64.fetchOne(db, sql: "SELECT id FROM settlement WHERE depositEntryId = ? AND id <> ?",
                                               arguments: [depositEntryId, settlementId])
                guard other == nil else {
                    throw BudgetError.depositInvalid("Deze bijschrijving is al aan een andere verrekening gekoppeld.")
                }
                deposit = entry
            }
            settlement.depositEntryId = depositEntryId
            try settlement.update(db)
            return SettlementResult(settlement: settlement, deposit: deposit)
        }
    }

    /// Verwijdert een verrekening; de boekingen (en een meegenomen startbedrag) staan daarna weer open. Een beginstand verwijder je niet zo:
    /// gebruik `enable` met een andere datum, of `disable`.
    public static func delete(_ db: Database, settlementId: Int64) throws {
        try atomic(db) {
            let settlement = try Check.fetch(db, Settlement.self, settlementId, "Verrekening")
            guard !settlement.isOpening else {
                throw BudgetError.validation("De beginstand kan niet verwijderd worden. Zet verrekenen opnieuw aan "
                    + "met een andere datum, of zet het uit.")
            }
            try db.execute(sql: "UPDATE entry SET settlementId = NULL WHERE settlementId = ?", arguments: [settlementId])
            try db.execute(sql: "UPDATE tag SET startSettlementId = NULL WHERE startSettlementId = ?",
                           arguments: [settlementId])
            try db.execute(sql: "DELETE FROM settlement WHERE id = ?", arguments: [settlementId])
        }
    }

    /// De verrekeningen van een tag, nieuwste eerst (de beginstand heeft `isOpening`).
    public static func history(_ db: Database, tagId: Int64) throws -> [Settlement] {
        try Settlement.fetchAll(db, sql: "SELECT * FROM settlement WHERE tagId = ? ORDER BY day DESC, id DESC",
                                arguments: [tagId])
    }

    /// De boekingen in een verrekening, oudste eerst.
    public static func entries(_ db: Database, settlementId: Int64) throws -> [Entry] {
        try Entry.fetchAll(db, sql: "SELECT * FROM entry WHERE settlementId = ? ORDER BY day, id",
                           arguments: [settlementId])
    }

    /// Een bestaande verrekening met haar storting en het verschil, bv. voor de historie.
    public static func result(_ db: Database, settlementId: Int64) throws -> SettlementResult {
        let settlement = try Check.fetch(db, Settlement.self, settlementId, "Verrekening")
        let deposit = try settlement.depositEntryId.flatMap { try Entry.fetchOne(db, key: $0) }
        return SettlementResult(settlement: settlement, deposit: deposit)
    }

    // MARK: Intern

    private static func openEntries(_ db: Database, tagId: Int64) throws -> [Entry] {
        try Entry.fetchAll(db, sql: """
            SELECT entry.* FROM entry
            JOIN entryTag ON entryTag.entryId = entry.id
            JOIN account ON account.id = entry.accountId
            WHERE entryTag.tagId = ? AND account.kind = ? AND entry.settlementId IS NULL
            ORDER BY entry.day, entry.id
            """, arguments: [tagId, AccountKind.betaal])
    }

    private static func assign(_ db: Database, _ entries: [Entry], to settlementId: Int64) throws {
        guard !entries.isEmpty else { return }
        try db.execute(sql: "UPDATE entry SET settlementId = ? WHERE id IN (\(Check.idList(entries.compactMap(\.id))))",
                       arguments: [settlementId])
    }

    /// Weigert als een van de boekingen (SQL-voorwaarde op `entry`) verrekend is of als terugstorting gekoppeld is.
    static func ensureFree(_ db: Database, entriesWhere condition: String, arguments: StatementArguments) throws {
        let settled = try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM entry WHERE (\(condition)) AND settlementId IS NOT NULL
            """, arguments: arguments) ?? 0
        guard settled == 0 else { throw BudgetError.inSettlement }
        let deposits = try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM settlement WHERE depositEntryId IN (SELECT id FROM entry WHERE \(condition))
            """, arguments: arguments) ?? 0
        guard deposits == 0 else { throw BudgetError.depositLinked }
    }

    /// Een verrekende boeking houdt zijn bedrag, zijn rekening en de tag van de verrekening.
    static func ensureUnchanged(_ db: Database, entry: Entry, amount: Money, accountId: Int64,
                                tagIds: [Int64]) throws {
        guard let settlementId = entry.settlementId,
              let settlement = try Settlement.fetchOne(db, key: settlementId) else { return }
        guard amount == entry.amount, accountId == entry.accountId, tagIds.contains(settlement.tagId) else {
            throw BudgetError.inSettlement
        }
    }
}
