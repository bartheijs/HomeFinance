import Foundation
import GRDB
import HFCore

/// Eén regel van een boeking: een deel van het bankbedrag met zijn toewijzing.
public struct Allocation: Equatable, Sendable {
    public var amount: Money
    public var label: String
    /// Vaste post (alleen betaalrekening); nil = divers.
    public var budgetItemId: Int64?
    /// Pot: op een spaarrekening de pot zelf; op een betaalrekening (alleen met `reimburse`) de pot waarmee
    /// verrekend wordt: bij een uitgave komt het uit die pot, bij een bijschrijving wordt het ernaar doorgestort.
    public var potId: Int64?
    public var reimburse: Bool
    public var tagIds: [Int64]
    public var note: String
    /// De regel die het voorstel deed, en de zekerheid daarvan.
    public var ruleId: Int64?
    public var confidence: Confidence?
    /// Nagekeken; standaard false ("nog nakijken") voor boekingen uit een import.
    public var reviewed: Bool
    /// Tijdelijk geleend van spaar (tijdelijk anti-rood); alleen op een betaalrekening.
    public var temporaryLoan: Bool
    /// De maand waarin de boeking meetelt ("yyyy-MM"), hoogstens 2 maanden van de datum; nil = de maand van de datum.
    public var period: String?

    public init(amount: Money, label: String, budgetItemId: Int64? = nil, potId: Int64? = nil,
                reimburse: Bool = false, tagIds: [Int64] = [], note: String = "", ruleId: Int64? = nil,
                confidence: Confidence? = nil, reviewed: Bool = false, temporaryLoan: Bool = false,
                period: String? = nil) {
        self.temporaryLoan = temporaryLoan
        self.period = period
        self.amount = amount; self.label = label; self.budgetItemId = budgetItemId; self.potId = potId
        self.reimburse = reimburse; self.tagIds = tagIds; self.note = note; self.ruleId = ruleId
        self.confidence = confidence; self.reviewed = reviewed
    }
}

/// Eén banktransactie met zijn regels, voor boeken in bulk.
public struct BookingRequest: Equatable, Sendable {
    public var bankTransactionId: Int64
    public var allocations: [Allocation]
    public init(bankTransactionId: Int64, allocations: [Allocation]) {
        self.bankTransactionId = bankTransactionId; self.allocations = allocations
    }
}

/// Banktransacties boeken, splitsen, ongedaan maken en overslaan.
public enum BookingService {
    /// Boekt een banktransactie als één of meer regels die samen precies het bankbedrag zijn.
    /// Vervangt bestaande boekingen van de transactie en zet de status op `verwerkt`.
    @discardableResult
    public static func book(_ db: Database, bankTransactionId: Int64, allocations: [Allocation]) throws -> [Entry] {
        try atomic(db) {
            let transaction = try Check.bankTransaction(db, bankTransactionId)
            let account = try Check.account(db, transaction.accountId)
            guard !allocations.isEmpty else { throw BudgetError.allocationsEmpty }
            let total = allocations.map(\.amount).sum()
            guard total == transaction.amount else {
                throw BudgetError.allocationSumMismatch(expected: transaction.amount, actual: total)
            }
            var resolved: [(budgetItemId: Int64?, period: String?)] = []
            // Tags die de huidige boekingen van deze transactie al hebben (alleen van belang op spaar).
            let existingTags = account.kind == .betaal ? [] : try Int64.fetchAll(db, sql: """
                SELECT DISTINCT tagId FROM entryTag JOIN entry ON entry.id = entryTag.entryId
                WHERE entry.bankTransactionId = ?
                """, arguments: [bankTransactionId])
            for allocation in allocations {
                resolved.append(try Check.assignment(db, account: account, day: transaction.day,
                                                     amount: allocation.amount, budgetItemId: allocation.budgetItemId,
                                                     potId: allocation.potId, reimburse: allocation.reimburse,
                                                     period: allocation.period))
                if allocation.temporaryLoan, account.kind != .betaal { throw BudgetError.temporaryLoanOnSavings }
                try Check.tagsExist(db, allocation.tagIds)
                try Check.tagsAllowed(account: account, tagIds: allocation.tagIds, existing: existingTags)
                if let ruleId = allocation.ruleId { _ = try Check.fetch(db, Rule.self, ruleId, "Regel") }
            }
            try removeEntries(db, of: transaction)
            var entries: [Entry] = []
            for (allocation, target) in zip(allocations, resolved) {
                var entry = Entry(accountId: transaction.accountId, bankTransactionId: bankTransactionId,
                                  day: transaction.day, amount: allocation.amount, label: allocation.label,
                                  budgetItemId: target.budgetItemId, potId: allocation.potId,
                                  reimburse: allocation.reimburse, reviewed: allocation.reviewed,
                                  note: allocation.note, ruleId: allocation.ruleId, confidence: allocation.confidence,
                                  temporaryLoan: allocation.temporaryLoan, period: target.period)
                try entry.insert(db)
                try Check.replaceTags(db, entryId: entry.id!, tagIds: allocation.tagIds)
                entries.append(entry)
            }
            try setStatus(db, bankTransactionId, .verwerkt)
            return entries
        }
    }

    /// Boekt veel transacties in één keer: alles of niets. Geeft alle nieuwe boekingen terug.
    @discardableResult
    public static func bookAll(_ db: Database, _ requests: [BookingRequest]) throws -> [Entry] {
        try atomic(db) {
            try requests.flatMap { try book(db, bankTransactionId: $0.bankTransactionId, allocations: $0.allocations) }
        }
    }

    /// Maakt de boeking ongedaan: verwijdert de boekingen en zet de status op `nieuw`.
    public static func unbook(_ db: Database, bankTransactionId: Int64) throws {
        try atomic(db) {
            let transaction = try Check.bankTransaction(db, bankTransactionId)
            try Check.yearOpen(db, day: transaction.day)
            try removeEntries(db, of: transaction)
            try setStatus(db, bankTransactionId, .nieuw)
        }
    }

    /// Slaat een nog niet geboekte transactie bewust over (status `overgeslagen`, geen boekingen).
    public static func skip(_ db: Database, bankTransactionId: Int64) throws {
        try atomic(db) {
            let transaction = try Check.bankTransaction(db, bankTransactionId)
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM entry WHERE bankTransactionId = ?",
                                         arguments: [bankTransactionId]) ?? 0
            guard transaction.status != .verwerkt, count == 0 else { throw BudgetError.alreadyBooked }
            try setStatus(db, bankTransactionId, .overgeslagen)
        }
    }

    /// Zet een overgeslagen transactie terug op `nieuw`.
    public static func unskip(_ db: Database, bankTransactionId: Int64) throws {
        try atomic(db) {
            let transaction = try Check.bankTransaction(db, bankTransactionId)
            guard transaction.status == .overgeslagen else { throw BudgetError.notSkipped }
            try setStatus(db, bankTransactionId, .nieuw)
        }
    }

    // MARK: Intern

    static func removeEntries(_ db: Database, of transaction: BankTransaction) throws {
        try Check.yearOpen(db, day: transaction.day)
        let inTransfer = try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM entry WHERE bankTransactionId = ? AND savingsTransferId IS NOT NULL
            """, arguments: [transaction.id]) ?? 0
        guard inTransfer == 0 else { throw BudgetError.inSavingsTransfer }
        try SavingsTransferService.ensureNotOwned(db, where: "bankTransactionId = ?", arguments: [transaction.id])
        try SettlementService.ensureFree(db, entriesWhere: "bankTransactionId = ?", arguments: [transaction.id])
        // Koppelingen (counterEntryId) naar deze boekingen vervallen vanzelf (ON DELETE SET NULL).
        try db.execute(sql: "DELETE FROM entry WHERE bankTransactionId = ?", arguments: [transaction.id])
    }

    static func setStatus(_ db: Database, _ id: Int64, _ status: BankTransactionStatus) throws {
        try db.execute(sql: "UPDATE bankTransaction SET status = ? WHERE id = ?", arguments: [status, id])
    }
}

// MARK: - Losse boekingen

/// Invoer voor een handmatige boeking, of de nieuwe waarden van een bestaande boeking.
public struct EntryDraft: Equatable, Sendable {
    public var accountId: Int64
    public var day: Day
    public var amount: Money
    public var label: String
    public var budgetItemId: Int64?
    public var potId: Int64?
    public var reimburse: Bool
    public var tagIds: [Int64]
    public var note: String
    /// Handinvoer is standaard nagekeken.
    public var reviewed: Bool
    /// Tijdelijk geleend van spaar (tijdelijk anti-rood); alleen op een betaalrekening.
    public var temporaryLoan: Bool
    /// De maand waarin de boeking meetelt ("yyyy-MM"), hoogstens 2 maanden van de datum; nil = de maand van de datum.
    public var period: String?

    public init(accountId: Int64, day: Day, amount: Money, label: String, budgetItemId: Int64? = nil,
                potId: Int64? = nil, reimburse: Bool = false, tagIds: [Int64] = [], note: String = "",
                reviewed: Bool = true, temporaryLoan: Bool = false, period: String? = nil) {
        self.temporaryLoan = temporaryLoan
        self.period = period
        self.accountId = accountId; self.day = day; self.amount = amount; self.label = label
        self.budgetItemId = budgetItemId; self.potId = potId; self.reimburse = reimburse
        self.tagIds = tagIds; self.note = note; self.reviewed = reviewed
    }
}

/// Handmatige boekingen en het bijwerken van bestaande boekingen (label, post, pot, tags, nagekeken).
public enum EntryService {
    /// Maakt een boeking zonder banktransactie (handinvoer).
    @discardableResult
    public static func create(_ db: Database, _ draft: EntryDraft) throws -> Entry {
        try atomic(db) {
            let account = try Check.account(db, draft.accountId)
            let target = try Check.assignment(db, account: account, day: draft.day, amount: draft.amount,
                                              budgetItemId: draft.budgetItemId, potId: draft.potId,
                                              reimburse: draft.reimburse, period: draft.period)
            if draft.temporaryLoan, account.kind != .betaal { throw BudgetError.temporaryLoanOnSavings }
            try Check.tagsExist(db, draft.tagIds)
            try Check.tagsAllowed(account: account, tagIds: draft.tagIds)
            var entry = Entry(accountId: draft.accountId, day: draft.day, amount: draft.amount, label: draft.label,
                              budgetItemId: target.budgetItemId, potId: draft.potId, reimburse: draft.reimburse,
                              reviewed: draft.reviewed, note: draft.note, temporaryLoan: draft.temporaryLoan,
                              period: target.period)
            try entry.insert(db)
            try Check.replaceTags(db, entryId: entry.id!, tagIds: draft.tagIds)
            return entry
        }
    }

    /// De huidige waarden van een boeking als `EntryDraft`, om te bewerken en terug te geven aan `update`.
    public static func draft(_ db: Database, entryId: Int64) throws -> EntryDraft {
        let entry = try Check.entry(db, entryId)
        return EntryDraft(accountId: entry.accountId, day: entry.day, amount: entry.amount, label: entry.label,
                          budgetItemId: entry.budgetItemId, potId: entry.potId, reimburse: entry.reimburse,
                          tagIds: try tagIds(db, entryId: entryId), note: entry.note, reviewed: entry.reviewed,
                          temporaryLoan: entry.temporaryLoan, period: entry.period)
    }

    /// Werkt een boeking bij. Bij een boeking uit een banktransactie liggen bedrag, dag en rekening vast.
    /// `reimburse` (en het bedrag) wijzigen wordt geweigerd als de boeking in een spaaroverboeking zit.
    /// Een verrekende boeking houdt zijn bedrag, zijn rekening en de tag van de verrekening.
    @discardableResult
    public static func update(_ db: Database, entryId: Int64, _ draft: EntryDraft) throws -> Entry {
        try atomic(db) {
            var entry = try Check.entry(db, entryId)
            try Check.yearOpen(db, day: entry.day)
            if entry.bankTransactionId != nil {
                guard draft.accountId == entry.accountId, draft.day == entry.day, draft.amount == entry.amount else {
                    throw BudgetError.bankEntryImmutable
                }
            }
            if entry.savingsTransferId != nil {
                guard draft.reimburse, draft.amount == entry.amount else { throw BudgetError.inSavingsTransfer }
            }
            // Een boeking van het afvinken van een verrekening houdt bedrag, rekening, dag en pot.
            if draft.amount != entry.amount || draft.accountId != entry.accountId || draft.day != entry.day
                || draft.potId != entry.potId {
                try SavingsTransferService.ensureNotOwned(db, where: "id = ?", arguments: [entryId])
            }
            try SettlementService.ensureUnchanged(db, entry: entry, amount: draft.amount, accountId: draft.accountId,
                                                  tagIds: draft.tagIds)
            let account = try Check.account(db, draft.accountId)
            if let old = entry.period, let oldYear = Int(old.prefix(4)) { try Check.yearOpen(db, year: oldYear) }
            let target = try Check.assignment(db, account: account, day: draft.day, amount: draft.amount,
                                              budgetItemId: draft.budgetItemId, potId: draft.potId,
                                              reimburse: draft.reimburse, period: draft.period,
                                              allowYearSwitch: entry.period != nil)
            if draft.temporaryLoan, account.kind != .betaal { throw BudgetError.temporaryLoanOnSavings }
            try Check.tagsExist(db, draft.tagIds)
            // Bestaande tags mogen blijven zolang de boeking op dezelfde rekening blijft.
            try Check.tagsAllowed(account: account, tagIds: draft.tagIds,
                                  existing: draft.accountId == entry.accountId ? try tagIds(db, entryId: entryId) : [])
            entry.temporaryLoan = draft.temporaryLoan
            entry.period = target.period
            entry.accountId = draft.accountId; entry.day = draft.day; entry.amount = draft.amount
            entry.label = draft.label; entry.budgetItemId = target.budgetItemId; entry.potId = draft.potId
            entry.reimburse = draft.reimburse; entry.note = draft.note; entry.reviewed = draft.reviewed
            try entry.update(db)
            try Check.replaceTags(db, entryId: entryId, tagIds: draft.tagIds)
            return entry
        }
    }

    /// Zet alleen 'verrekenen met spaar' aan of uit, met optioneel de pot (uitgave: uit die pot; bijschrijving:
    /// doorstorten naar die pot).
    @discardableResult
    public static func setReimburse(_ db: Database, entryId: Int64, _ reimburse: Bool,
                                    potId: Int64? = nil) throws -> Entry {
        try atomic(db) {
            var draft = try self.draft(db, entryId: entryId)
            guard draft.reimburse != reimburse || draft.potId != potId else { return try Check.entry(db, entryId) }
            let entry = try Check.entry(db, entryId)
            if entry.savingsTransferId != nil, !reimburse { throw BudgetError.inSavingsTransfer }
            draft.reimburse = reimburse
            draft.potId = reimburse ? potId : nil
            return try update(db, entryId: entryId, draft)
        }
    }

    /// Markeert een boeking op een betaalrekening als tijdelijk geleend van spaar, of haalt de markering weg.
    /// Gebruik dit bij de overboeking van spaar (+) én bij het terugboeken (−).
    @discardableResult
    public static func setTemporaryLoan(_ db: Database, entryId: Int64, _ temporaryLoan: Bool) throws -> Entry {
        try atomic(db) {
            var draft = try self.draft(db, entryId: entryId)
            guard draft.temporaryLoan != temporaryLoan else { return try Check.entry(db, entryId) }
            draft.temporaryLoan = temporaryLoan
            return try update(db, entryId: entryId, draft)
        }
    }

    /// Laat een boeking in een andere maand meetellen voor de begroting (hoogstens 2 maanden van de datum).
    /// `year`/`month` nil = terug naar de maand van de datum. Het rekeningsaldo volgt altijd de datum.
    /// Valt de periode in een ander jaar dan de datum, dan verhuist de boeking naar de post met hetzelfde label
    /// in dat jaar (en terug); bestaat die niet, dan wordt het geweigerd. Beide jaren moeten open zijn.
    @discardableResult
    public static func setPeriod(_ db: Database, entryId: Int64, year: Int?, month: Int?) throws -> Entry {
        try atomic(db) {
            var draft = try self.draft(db, entryId: entryId)
            if let year, let month {
                draft.period = Check.periodString(year: year, month: month)
            } else {
                guard year == nil, month == nil else {
                    throw BudgetError.validation("Geef een jaar én een maand op, of geen van beide.")
                }
                draft.period = nil
            }
            return try update(db, entryId: entryId, draft)
        }
    }

    /// Verwijdert een handmatige boeking. Boekingen uit een banktransactie verwijder je met `BookingService.unbook`.
    public static func delete(_ db: Database, entryId: Int64) throws {
        try atomic(db) {
            let entry = try Check.entry(db, entryId)
            try SavingsTransferService.ensureNotOwned(db, where: "id = ?", arguments: [entryId])
            guard entry.bankTransactionId == nil else { throw BudgetError.bankEntryDelete }
            guard entry.savingsTransferId == nil else { throw BudgetError.inSavingsTransfer }
            try SettlementService.ensureFree(db, entriesWhere: "id = ?", arguments: [entryId])
            try Check.yearOpen(db, day: entry.day)
            try db.execute(sql: "DELETE FROM entry WHERE id = ?", arguments: [entryId])
        }
    }

    /// Markeert boekingen als nagekeken of juist niet.
    public static func setReviewed(_ db: Database, entryIds: [Int64], _ reviewed: Bool) throws {
        try atomic(db) {
            for id in entryIds {
                let entry = try Check.entry(db, id)
                try Check.yearOpen(db, day: entry.day)
                try db.execute(sql: "UPDATE entry SET reviewed = ? WHERE id = ?", arguments: [reviewed, id])
            }
        }
    }

    /// Markeert alle boekingen van een rekening als nagekeken (afgesloten jaren worden overgeslagen).
    /// Geeft het aantal gewijzigde boekingen terug.
    @discardableResult
    public static func markAllReviewed(_ db: Database, accountId: Int64) throws -> Int {
        try atomic(db) {
            _ = try Check.account(db, accountId)
            try db.execute(sql: """
                UPDATE entry SET reviewed = 1
                WHERE accountId = ? AND reviewed = 0
                  AND CAST(substr(day, 1, 4) AS INTEGER) NOT IN (SELECT year FROM budgetYear WHERE closed = 1)
                """, arguments: [accountId])
            return db.changesCount
        }
    }

    /// Vervangt de tags van een boeking.
    public static func setTags(_ db: Database, entryId: Int64, tagIds: [Int64]) throws {
        try atomic(db) {
            let entry = try Check.entry(db, entryId)
            try Check.yearOpen(db, day: entry.day)
            try SettlementService.ensureUnchanged(db, entry: entry, amount: entry.amount, accountId: entry.accountId,
                                                  tagIds: tagIds)
            try Check.tagsExist(db, tagIds)
            try Check.tagsAllowed(account: try Check.account(db, entry.accountId), tagIds: tagIds,
                                  existing: try self.tagIds(db, entryId: entryId))
            try Check.replaceTags(db, entryId: entryId, tagIds: tagIds)
        }
    }

    /// Kunnen boekingen op deze rekening een tag krijgen? Alleen op een betaalrekening.
    public static func tagsAllowed(_ db: Database, accountId: Int64) throws -> Bool {
        try Check.account(db, accountId).kind == .betaal
    }

    /// De tag-id's van een boeking.
    public static func tagIds(_ db: Database, entryId: Int64) throws -> [Int64] {
        try Int64.fetchAll(db, sql: """
            SELECT tagId FROM entryTag JOIN tag ON tag.id = tagId WHERE entryId = ? ORDER BY tag.sortOrder, tag.id
            """, arguments: [entryId])
    }
}
