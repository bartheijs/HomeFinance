import Foundation
import GRDB
import HFCore

// MARK: - Overboekingen tussen eigen rekeningen

/// Twee banktransacties die samen één overboeking tussen eigen rekeningen zijn.
public struct TransferPair: Equatable, Sendable {
    /// De afschrijving (negatief bedrag).
    public var from: BankTransaction
    /// De bijschrijving (positief bedrag) op de andere eigen rekening.
    public var to: BankTransaction
}

/// Overboekingen tussen eigen rekeningen herkennen en koppelen (`counterEntryId`).
public enum TransferService {
    /// Aantal dagen dat tussen de twee kanten van een overboeking mag zitten.
    public static let maxDaysApart = 3

    /// Zoekt nog niet gekoppelde paren: tegengesteld bedrag op twee eigen rekeningen, de tegenrekening is
    /// de andere eigen rekening, hoogstens 3 dagen uit elkaar. Elke transactie zit in hoogstens één paar.
    public static func findTransferPairs(_ db: Database) throws -> [TransferPair] {
        let accounts = try Account.fetchAll(db, sql: "SELECT * FROM account WHERE iban IS NOT NULL")
        var accountByIban: [String: Account] = [:]
        var ibanByAccount: [Int64: String] = [:]
        for account in accounts {
            guard let id = account.id, let iban = account.iban else { continue }
            let normalized = AccountService.normalizeIBAN(iban)
            accountByIban[normalized] = account
            ibanByAccount[id] = normalized
        }
        let linked = Set(try Int64.fetchAll(db, sql: """
            SELECT DISTINCT bankTransactionId FROM entry
            WHERE counterEntryId IS NOT NULL AND bankTransactionId IS NOT NULL
            """))
        let candidates = try BankTransaction.fetchAll(db, sql: """
            SELECT * FROM bankTransaction
            WHERE status <> ? AND counterpartyIban <> '' AND amount <> 0 ORDER BY day, id
            """, arguments: [BankTransactionStatus.overgeslagen])
            .filter { transaction in
                guard let id = transaction.id, !linked.contains(id),
                      let other = accountByIban[AccountService.normalizeIBAN(transaction.counterpartyIban)]
                else { return false }
                return other.id != transaction.accountId
            }
        let incoming = candidates.filter { !$0.amount.isNegative }
        var used = Set<Int64>()
        var pairs: [TransferPair] = []
        for out in candidates where out.amount.isNegative {
            guard let target = accountByIban[AccountService.normalizeIBAN(out.counterpartyIban)],
                  let ownIban = ibanByAccount[out.accountId] else { continue }
            let match = incoming
                .filter { candidate in
                    candidate.accountId == target.id && candidate.amount == -out.amount
                        && !used.contains(candidate.id!)
                        && AccountService.normalizeIBAN(candidate.counterpartyIban) == ownIban
                        && daysApart(out.day, candidate.day) <= maxDaysApart
                }
                .min { a, b in
                    (daysApart(out.day, a.day), a.id!) < (daysApart(out.day, b.day), b.id!)
                }
            if let match {
                used.insert(match.id!)
                pairs.append(TransferPair(from: out, to: match))
            }
        }
        return pairs
    }

    /// Koppelt twee banktransacties als overboeking. Een kant die nog niet geboekt is, wordt geboekt als één
    /// regel "Overboeking naar/van <rekening>" (nog na te kijken). De boekingen verwijzen over en weer naar
    /// elkaar; bij een gesplitste kant verwijst elke regel naar de eerste regel van de andere kant.
    public static func linkTransfer(_ db: Database, fromBankTransactionId: Int64,
                                    toBankTransactionId: Int64) throws {
        try atomic(db) {
            let a = try Check.bankTransaction(db, fromBankTransactionId)
            let b = try Check.bankTransaction(db, toBankTransactionId)
            guard a.id != b.id, a.accountId != b.accountId else {
                throw BudgetError.transferInvalid("Een overboeking heeft twee transacties op verschillende eigen rekeningen nodig.")
            }
            guard !a.amount.isZero, a.amount + b.amount == .zero else {
                throw BudgetError.transferInvalid("De bedragen van de twee transacties zijn niet elkaars tegengestelde.")
            }
            guard a.status != .overgeslagen, b.status != .overgeslagen else {
                throw BudgetError.transferInvalid("Een overgeslagen transactie kan niet gekoppeld worden.")
            }
            try Check.yearOpen(db, day: a.day)
            try Check.yearOpen(db, day: b.day)
            let accountA = try Check.account(db, a.accountId)
            let accountB = try Check.account(db, b.accountId)
            let entriesA = try entries(db, bookingIfNeeded: a, otherAccount: accountB)
            let entriesB = try entries(db, bookingIfNeeded: b, otherAccount: accountA)
            guard (entriesA + entriesB).allSatisfy({ $0.counterEntryId == nil }) else { throw BudgetError.alreadyLinked }
            try setCounter(db, of: entriesA, to: entriesB[0].id!)
            try setCounter(db, of: entriesB, to: entriesA[0].id!)
        }
    }

    /// Verbreekt de koppeling van een overboeking (beide kanten). De boekingen zelf blijven staan.
    public static func unlinkTransfer(_ db: Database, bankTransactionId: Int64) throws {
        try atomic(db) {
            let transaction = try Check.bankTransaction(db, bankTransactionId)
            try Check.yearOpen(db, day: transaction.day)
            let ids = try Int64.fetchAll(db, sql: """
                SELECT id FROM entry WHERE bankTransactionId = ? AND counterEntryId IS NOT NULL
                """, arguments: [bankTransactionId])
            guard !ids.isEmpty else { throw BudgetError.notLinked }
            let all = try Int64.fetchAll(db, sql: "SELECT id FROM entry WHERE bankTransactionId = ?",
                                         arguments: [bankTransactionId])
            let list = Check.idList(all)
            try db.execute(sql: "UPDATE entry SET counterEntryId = NULL WHERE id IN (\(list)) OR counterEntryId IN (\(list))")
        }
    }

    // MARK: Intern

    static func daysApart(_ a: Day, _ b: Day) -> Int {
        abs(Int((b.date.timeIntervalSince(a.date) / 86_400).rounded()))
    }

    private static func entries(_ db: Database, bookingIfNeeded transaction: BankTransaction,
                                otherAccount: Account) throws -> [Entry] {
        let existing = try Entry.fetchAll(db, sql: "SELECT * FROM entry WHERE bankTransactionId = ? ORDER BY id",
                                          arguments: [transaction.id])
        if !existing.isEmpty { return existing }
        let label = (transaction.amount.isNegative ? "Overboeking naar " : "Overboeking van ") + otherAccount.name
        return try BookingService.book(db, bankTransactionId: transaction.id!,
                                       allocations: [Allocation(amount: transaction.amount, label: label)])
    }

    private static func setCounter(_ db: Database, of entries: [Entry], to counterId: Int64) throws {
        try db.execute(sql: "UPDATE entry SET counterEntryId = ? WHERE id IN (\(Check.idList(entries.map { $0.id! })))",
                       arguments: [counterId])
    }
}

// MARK: - Potten

/// Potten op een spaarrekening beheren, stortingen verdelen en geld tussen potten verplaatsen.
public enum PotService {
    /// Maakt een pot op een spaarrekening; komt achteraan in de volgorde.
    @discardableResult
    public static func create(_ db: Database, _ pot: Pot) throws -> Pot {
        try atomic(db) {
            var pot = pot
            try validate(db, &pot)
            pot.id = nil
            pot.sortOrder = try Check.nextSortOrder(db, table: "pot", whereSQL: "accountId = ?",
                                                    arguments: [pot.accountId])
            try pot.insert(db)
            return pot
        }
    }

    /// Werkt naam, soort, eigenaar, maandbedrag en doel bij. Rekening, volgorde en archivering blijven gelijk.
    @discardableResult
    public static func update(_ db: Database, _ pot: Pot) throws -> Pot {
        try atomic(db) {
            guard let id = pot.id else { throw BudgetError.validation("Deze pot is nog niet opgeslagen.") }
            let existing = try Check.pot(db, id)
            var pot = pot
            guard pot.accountId == existing.accountId else {
                throw BudgetError.validation("Een pot kan niet naar een andere rekening verhuizen.")
            }
            try validate(db, &pot)
            pot.sortOrder = existing.sortOrder
            pot.archived = existing.archived
            try pot.update(db)
            return pot
        }
    }

    /// Verwijdert een pot zonder boekingen. Een pot met boekingen kun je alleen archiveren.
    public static func delete(_ db: Database, potId: Int64) throws {
        try atomic(db) {
            let pot = try Check.pot(db, potId)
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM entry WHERE potId = ?", arguments: [potId]) ?? 0
            guard count == 0 else { throw BudgetError.potHasEntries(pot: pot.name) }
            try db.execute(sql: "DELETE FROM pot WHERE id = ?", arguments: [potId])
        }
    }

    /// Zet de potten van een rekening in de gegeven volgorde (alle pot-id's van die rekening).
    public static func reorder(_ db: Database, accountId: Int64, orderedIds: [Int64]) throws {
        try atomic(db) {
            let existing = try Int64.fetchAll(db, sql: "SELECT id FROM pot WHERE accountId = ?", arguments: [accountId])
            try Check.reorder(db, table: "pot", existingIds: existing, orderedIds: orderedIds)
        }
    }

    /// Archiveert een pot; kan alleen als het saldo € 0,00 is.
    public static func archive(_ db: Database, potId: Int64) throws {
        try atomic(db) {
            let pot = try Check.pot(db, potId)
            let balance = try balance(db, potId: potId)
            guard balance.isZero else { throw BudgetError.potNotEmpty(pot: pot.name, balance: balance) }
            try db.execute(sql: "UPDATE pot SET archived = 1 WHERE id = ?", arguments: [potId])
        }
    }

    /// Haalt een pot terug uit het archief.
    public static func unarchive(_ db: Database, potId: Int64) throws {
        try atomic(db) {
            _ = try Check.pot(db, potId)
            try db.execute(sql: "UPDATE pot SET archived = 0 WHERE id = ?", arguments: [potId])
        }
    }

    /// Saldo van een pot: som van de boekingen op zijn spaarrekening met deze pot.
    public static func balance(_ db: Database, potId: Int64) throws -> Money {
        let pot = try Check.pot(db, potId)
        return try Money.fetchOne(db, sql: """
            SELECT COALESCE(SUM(amount), 0) FROM entry WHERE potId = ? AND accountId = ?
            """, arguments: [potId, pot.accountId]) ?? .zero
    }

    /// Voorstel om een storting te verdelen: als `amount` gelijk is aan de som van de maandbedragen van de
    /// (niet-gearchiveerde) reserveringspotten van de rekening, één regel per pot. Anders nil.
    public static func distribution(_ db: Database, for amount: Money, accountId: Int64) throws -> [Allocation]? {
        let pots = try Pot.fetchAll(db, sql: """
            SELECT * FROM pot WHERE accountId = ? AND kind = ? AND archived = 0 AND monthlyAmount > 0
            ORDER BY sortOrder, id
            """, arguments: [accountId, PotKind.reservering])
        guard !pots.isEmpty, pots.map(\.monthlyAmount).sum() == amount else { return nil }
        return pots.map { Allocation(amount: $0.monthlyAmount, label: $0.name, potId: $0.id) }
    }

    /// Verplaatst een (positief) bedrag van de ene pot naar de andere op dezelfde rekening, als twee
    /// handmatige boekingen die samen nul zijn. Geeft (af, bij) terug.
    @discardableResult
    public static func moveBetweenPots(_ db: Database, from fromPotId: Int64, to toPotId: Int64, amount: Money,
                                       day: Day, label: String) throws -> (from: Entry, to: Entry) {
        try atomic(db) {
            let from = try Check.pot(db, fromPotId)
            let to = try Check.pot(db, toPotId)
            guard fromPotId != toPotId else { throw BudgetError.validation("Kies twee verschillende potten.") }
            guard from.accountId == to.accountId else {
                throw BudgetError.validation("De potten \(from.name) en \(to.name) staan niet op dezelfde rekening.")
            }
            guard amount > .zero else { throw BudgetError.validation("Het te verplaatsen bedrag moet positief zijn.") }
            let out = try EntryService.create(db, EntryDraft(accountId: from.accountId, day: day, amount: -amount,
                                                             label: label, potId: fromPotId))
            let into = try EntryService.create(db, EntryDraft(accountId: to.accountId, day: day, amount: amount,
                                                              label: label, potId: toPotId))
            return (out, into)
        }
    }

    private static func validate(_ db: Database, _ pot: inout Pot) throws {
        pot.name = try Check.nonEmpty(pot.name, "De naam van de pot")
        let account = try Check.account(db, pot.accountId)
        guard account.kind == .spaar else {
            throw BudgetError.validation("Een pot hoort bij een spaarrekening; \(account.name) is een betaalrekening.")
        }
        guard !pot.monthlyAmount.isNegative else {
            throw BudgetError.validation("Het maandbedrag van een pot mag niet negatief zijn.")
        }
        if let target = pot.targetAmount, target.isNegative {
            throw BudgetError.validation("Het spaardoel van een pot mag niet negatief zijn.")
        }
    }
}

// MARK: - Spaaroverboekingen (vergoeden uit spaar)

/// De openstaande uitgaven die uit spaar vergoed moeten worden, met het over te boeken totaal.
public struct OpenReimbursements: Equatable, Sendable {
    public var entries: [Entry]
    /// Positief bedrag dat van spaar naar betaal moet.
    public var total: Money
}

/// Spaaroverboekingen: uitgaven die uit de spaarrekening vergoed worden bundelen en afhandelen.
public enum SavingsTransferService {
    /// Alle `reimburse`-boekingen die nog in geen spaaroverboeking zitten, met het totaal.
    public static func openReimbursements(_ db: Database) throws -> OpenReimbursements {
        let entries = try Entry.fetchAll(db, sql: """
            SELECT * FROM entry WHERE reimburse = 1 AND savingsTransferId IS NULL ORDER BY day, id
            """)
        return OpenReimbursements(entries: entries, total: -entries.map(\.amount).sum())
    }

    /// Legt een spaaroverboeking vast voor de gekozen openstaande boekingen; het bedrag is hun (positieve) totaal.
    @discardableResult
    public static func createSavingsTransfer(_ db: Database, entryIds: [Int64], day: Day,
                                             note: String = "") throws -> SavingsTransfer {
        try atomic(db) {
            let ids = Array(Set(entryIds))
            guard !ids.isEmpty else {
                throw BudgetError.validation("Kies minstens één boeking voor de spaaroverboeking.")
            }
            var total = Money.zero
            for id in ids {
                let entry = try Check.entry(db, id)
                guard entry.reimburse, entry.savingsTransferId == nil else {
                    throw BudgetError.notReimbursable(entry: entry.label)
                }
                total = total - entry.amount
            }
            guard total > .zero else {
                throw BudgetError.validation("Het totaal van de spaaroverboeking moet positief zijn.")
            }
            var transfer = SavingsTransfer(day: day, amount: total, note: note)
            try transfer.insert(db)
            try db.execute(sql: "UPDATE entry SET savingsTransferId = ? WHERE id IN (\(Check.idList(ids)))",
                           arguments: [transfer.id])
            return transfer
        }
    }

    /// Markeert de spaaroverboeking als gedaan.
    @discardableResult
    public static func markDone(_ db: Database, savingsTransferId: Int64, at date: Date = Date()) throws -> SavingsTransfer {
        try atomic(db) {
            var transfer = try Check.fetch(db, SavingsTransfer.self, savingsTransferId, "Spaaroverboeking")
            transfer.done = true
            transfer.doneAt = date
            try transfer.update(db)
            return transfer
        }
    }

    /// Zet een gedane spaaroverboeking terug op 'nog te doen'.
    @discardableResult
    public static func reopen(_ db: Database, savingsTransferId: Int64) throws -> SavingsTransfer {
        try atomic(db) {
            var transfer = try Check.fetch(db, SavingsTransfer.self, savingsTransferId, "Spaaroverboeking")
            transfer.done = false
            transfer.doneAt = nil
            try transfer.update(db)
            return transfer
        }
    }

    /// Verwijdert de spaaroverboeking; de boekingen staan daarna weer open.
    public static func delete(_ db: Database, savingsTransferId: Int64) throws {
        try atomic(db) {
            _ = try Check.fetch(db, SavingsTransfer.self, savingsTransferId, "Spaaroverboeking")
            try db.execute(sql: "UPDATE entry SET savingsTransferId = NULL WHERE savingsTransferId = ?",
                           arguments: [savingsTransferId])
            try db.execute(sql: "DELETE FROM savingsTransfer WHERE id = ?", arguments: [savingsTransferId])
        }
    }

    /// De boekingen in een spaaroverboeking.
    public static func entries(_ db: Database, savingsTransferId: Int64) throws -> [Entry] {
        try Entry.fetchAll(db, sql: "SELECT * FROM entry WHERE savingsTransferId = ? ORDER BY day, id",
                           arguments: [savingsTransferId])
    }
}
