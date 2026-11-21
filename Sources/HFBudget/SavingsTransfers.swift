import Foundation
import GRDB
import HFCore

// MARK: - Verrekenen met spaar

/// Wat er voor één pot verrekend wordt.
public struct PotMovement: Equatable, Sendable {
    /// De pot, of nil voor boekingen zonder pot ("niet toegewezen").
    public var pot: Pot?
    /// Positief = het bedrag gaat de pot UIT (uitgaven van de betaalrekening), negatief = het komt de pot IN
    /// (bijschrijvingen die doorgestort worden).
    public var amount: Money
    public var potId: Int64? { pot?.id }
}

/// De openstaande boekingen die met spaar verrekend moeten worden, gesaldeerd.
public struct OpenReimbursements: Equatable, Sendable {
    public var entries: [Entry]
    /// Som van de uitgaven (positief): dit moet van spaar naar betaal.
    public var fromSavings: Money
    /// Som van de bijschrijvingen (positief): dit moet van betaal naar spaar.
    public var toSavings: Money
    /// Per pot wat eruit gaat (positief) of erin komt (negatief); samen `net`.
    public var perPot: [PotMovement]
    /// `fromSavings − toSavings`: positief = overmaken van spaar naar betaal, negatief = van betaal naar spaar.
    public var net: Money { fromSavings - toSavings }
    /// Oude naam van `net` (was: het positieve totaal van de uitgaven).
    public var total: Money { net }
}

/// De kant van de verrekenoverboeking die een banktransactie is.
public enum SavingsTransferSide: String, Equatable, Sendable {
    /// De transactie op de betaalrekening.
    case checking
    /// De transactie op de spaarrekening.
    case savings
}

/// Een banktransactie die de echte overboeking van een verrekening met spaar kan zijn.
public struct SavingsTransferMatch: Equatable, Sendable {
    /// De passende verrekening(en). Meer dan één: de gebruiker kiest.
    public var transfers: [SavingsTransfer]
    public var side: SavingsTransferSide
    /// De ene passende verrekening, of nil als de gebruiker moet kiezen.
    public var transfer: SavingsTransfer? { transfers.count == 1 ? transfers[0] : nil }
    public var isAmbiguous: Bool { transfers.count > 1 }
    /// De ene passende verrekening is nog niet afgevinkt: bied "Afvinken en aanhangen" aan
    /// (`markDone` op de dag van de bankregel, daarna `attach`).
    public var needsMarkDone: Bool { transfer.map { !$0.done } ?? false }
}

/// Een vastgelegde verrekening met spaar met haar stand.
public struct SavingsTransferSummary: Equatable, Sendable {
    public var transfer: SavingsTransfer
    /// De gemarkeerde boekingen op de betaalrekening die verrekend worden.
    public var entries: [Entry]
    public var fromSavings: Money
    public var toSavings: Money
    public var perPot: [PotMovement]
    /// De boekingen die bij het afvinken zijn gemaakt (betaal- en spaarrekening); leeg zolang niet afgevinkt.
    public var bookedEntries: [Entry]
    /// De betaalrekening van de gemarkeerde boekingen en de spaarrekening van de potten, voor zover bekend.
    public var checkingAccountId: Int64?
    public var savingsAccountId: Int64?
    /// De aangehangen banktransactie op de betaalrekening en op de spaarrekening, als die er zijn.
    public var checkingTransactionId: Int64?
    public var savingsTransactionId: Int64?
    /// Netto met teken (= `transfer.amount`): positief = van spaar naar betaal.
    public var net: Money { transfer.amount }
    /// Bij netto nul is er geen bankoverboeking; afvinken boekt dan alleen de potmutaties.
    public var needsBankTransfer: Bool { !transfer.amount.isZero }
    /// Er hangt nog niet aan beide kanten een bankregel (alleen van belang bij `needsBankTransfer`).
    public var isConfirmed: Bool {
        !needsBankTransfer || (checkingTransactionId != nil && savingsTransactionId != nil)
    }
}

/// Verrekenen met spaar, in twee richtingen: uitgaven op de betaalrekening die uit een pot moeten komen, en
/// bijschrijvingen op de betaalrekening die naar een pot doorgestort moeten worden. De boekingen worden
/// gesaldeerd tot één overboeking.
///
/// Bij het AFVINKEN (`markDone`) wordt de verrekening meteen volledig geboekt: de potmutaties op de
/// spaarrekening en het netto bedrag op de betaalrekening, als handmatige boekingen. Komen de bankregels later
/// binnen, dan worden ze alleen nog herkend en aan die boekingen gehangen (`attach`); er komen geen boekingen bij.
///
/// Welke boekingen bij een verrekening horen staat in `Setting` (sleutel `savingsTransfer.<id>.entries`, de id's
/// van de boekingen) en bovendien leesbaar in hun notitie ("Verrekening #<id>"). De notitie is alleen voor de
/// gebruiker; de koppeling hangt er niet van af.
public enum SavingsTransferService {
    /// Aantal dagen dat een bankregel van de verrekening mag afliggen om herkend te worden.
    public static let recognitionDays = 7
    /// Na zoveel dagen zonder bankregel aan beide kanten geldt een afgevinkte verrekening als onbevestigd.
    public static let confirmationDays = 5

    /// Alle `reimburse`-boekingen die nog in geen overboeking zitten, gesaldeerd en per pot.
    public static func openReimbursements(_ db: Database) throws -> OpenReimbursements {
        let entries = try Entry.fetchAll(db, sql: """
            SELECT * FROM entry WHERE reimburse = 1 AND savingsTransferId IS NULL ORDER BY day, id
            """)
        let parts = try breakdown(db, entries)
        return OpenReimbursements(entries: entries, fromSavings: parts.from, toSavings: parts.to, perPot: parts.perPot)
    }

    /// Waarschuwing als de gebruiker "verrekenen met spaar" (of een pot) kiest bij een banktransactie op een
    /// betaalrekening waarvan de tegenrekening een eigen spaarrekening is. Zo'n boeking IS de overboeking:
    /// de pot kies je aan de spaarkant, verrekenen is voor geld dat nog moet verhuizen. Alleen een waarschuwing;
    /// boeken blijft mogelijk. Nil als `reimburse` uit staat of het geen overboeking met eigen spaar is.
    public static func ownSavingsWarning(_ db: Database, bankTransaction: BankTransaction,
                                         reimburse: Bool) throws -> String? {
        guard reimburse, !bankTransaction.amount.isZero,
              try Account.fetchOne(db, key: bankTransaction.accountId)?.kind == .betaal else { return nil }
        let counterparty = AccountService.normalizeIBAN(bankTransaction.counterpartyIban)
        guard !counterparty.isEmpty else { return nil }
        let ownSavings = try Account.filter(Column("kind") == AccountKind.spaar.rawValue).fetchAll(db)
            .contains { AccountService.normalizeIBAN($0.iban ?? "") == counterparty }
        guard ownSavings else { return nil }
        return (bankTransaction.amount.isNegative
                ? "Dit is een overboeking naar je eigen spaarrekening. "
                : "Dit is een overboeking van je eigen spaarrekening. ")
            + "Kies het potje aan de spaarkant; ‘Nog overboeken met spaar’ is voor geld dat nog moet verhuizen."
    }

    /// Openstaande boekingen zonder pot, zodat het scherm kan waarschuwen.
    public static func openWithoutPot(_ db: Database) throws -> [Entry] {
        try Entry.fetchAll(db, sql: """
            SELECT * FROM entry WHERE reimburse = 1 AND savingsTransferId IS NULL AND potId IS NULL ORDER BY day, id
            """)
    }

    /// Legt een verrekening vast voor de gekozen openstaande boekingen. `amount` is het NETTO bedrag met teken:
    /// positief = van spaar naar betaal, negatief = van betaal naar spaar, nul = alleen schuiven tussen potten.
    /// De boekingen moeten op één betaalrekening staan en hun potten op één spaarrekening; maak anders per
    /// rekeningpaar een aparte verrekening. Er wordt nog niets geboekt; dat gebeurt bij `markDone`.
    @discardableResult
    public static func createSavingsTransfer(_ db: Database, entryIds: [Int64], day: Day,
                                             note: String = "") throws -> SavingsTransfer {
        try atomic(db) {
            let ids = Array(Set(entryIds))
            guard !ids.isEmpty else {
                throw BudgetError.validation("Kies minstens één boeking om met spaar over te boeken.")
            }
            var chosen: [Entry] = []
            for id in ids {
                let entry = try Check.entry(db, id)
                guard entry.reimburse, entry.savingsTransferId == nil else {
                    throw BudgetError.notReimbursable(entry: entry.label)
                }
                chosen.append(entry)
            }
            _ = try accounts(db, marked: chosen)
            var transfer = SavingsTransfer(day: day, amount: -chosen.map(\.amount).sum(), note: note)
            try transfer.insert(db)
            try db.execute(sql: "UPDATE entry SET savingsTransferId = ? WHERE id IN (\(Check.idList(ids)))",
                           arguments: [transfer.id])
            return transfer
        }
    }

    /// Vinkt de verrekening af en boekt haar meteen volledig, op `day` (standaard vandaag):
    /// - spaarrekening: per pot één handmatige boeking (uit de pot negatief, erin positief) en één regel zonder
    ///   pot voor boekingen zonder pot; samen −netto;
    /// - betaalrekening: één handmatige diverse boeking van +netto ("Verrekening spaar"). Bij netto nul komt er
    ///   geen boeking op de betaalrekening en zijn de potmutaties samen nul.
    /// De betaal- en spaarkant verwijzen naar elkaar via `counterEntryId`. Een al geboekte verrekening blijft
    /// zoals ze is.
    @discardableResult
    public static func markDone(_ db: Database, savingsTransferId: Int64, on day: Day = .today(),
                                at date: Date = Date()) throws -> SavingsTransfer {
        try atomic(db) {
            var transfer = try fetch(db, savingsTransferId)
            if try bookedEntries(db, savingsTransferId).isEmpty {
                let marked = try entries(db, savingsTransferId: savingsTransferId)
                let parts = try breakdown(db, marked)
                let accounts = try accounts(db, marked: marked)
                let moves = parts.perPot.filter { !$0.amount.isZero }
                let note = bookingNote(savingsTransferId)
                var created: [Entry] = []
                if !moves.isEmpty {
                    guard let savingsId = accounts.savings else {
                        throw BudgetError.validation("Het is niet duidelijk op welke spaarrekening deze overboeking hoort. "
                            + "Kies bij de boekingen een potje.")
                    }
                    for move in moves {
                        created.append(try EntryService.create(db, EntryDraft(
                            accountId: savingsId, day: day, amount: -move.amount,
                            label: "Verrekening spaar: \(move.pot?.name ?? "niet toegewezen")",
                            potId: move.potId, note: note)))
                    }
                }
                if !transfer.amount.isZero {
                    guard let checkingId = accounts.checking else {
                        throw BudgetError.validation("Deze overboeking heeft geen boekingen meer op een betaalrekening.")
                    }
                    let checking = try EntryService.create(db, EntryDraft(
                        accountId: checkingId, day: day, amount: transfer.amount, label: "Verrekening spaar", note: note))
                    let savingsIds = created.compactMap(\.id)
                    try db.execute(sql: "UPDATE entry SET counterEntryId = ? WHERE id IN (\(Check.idList(savingsIds)))",
                                   arguments: [checking.id])
                    try db.execute(sql: "UPDATE entry SET counterEntryId = ? WHERE id = ?",
                                   arguments: [savingsIds.first, checking.id])
                    created.append(checking)
                }
                try Setting.set(db, entriesKey(savingsTransferId),
                                created.isEmpty ? nil : Check.idList(created.compactMap(\.id)))
            }
            transfer.done = true
            transfer.doneAt = date
            try transfer.update(db)
            return transfer
        }
    }

    /// Zet een afgevinkte verrekening terug op 'nog te doen' en verwijdert de boekingen van het afvinken.
    /// Geweigerd zolang er een bankregel aan hangt; koppel die eerst los (`detach`).
    @discardableResult
    public static func reopen(_ db: Database, savingsTransferId: Int64) throws -> SavingsTransfer {
        try atomic(db) {
            var transfer = try fetch(db, savingsTransferId)
            try removeBookedEntries(db, savingsTransferId)
            transfer.done = false
            transfer.doneAt = nil
            try transfer.update(db)
            return transfer
        }
    }

    /// Verwijdert de verrekening en de boekingen van het afvinken; de gemarkeerde boekingen staan daarna weer
    /// open. Geweigerd zolang er een bankregel aan hangt; koppel die eerst los (`detach`).
    public static func delete(_ db: Database, savingsTransferId: Int64) throws {
        try atomic(db) {
            _ = try fetch(db, savingsTransferId)
            try removeBookedEntries(db, savingsTransferId)
            try db.execute(sql: "UPDATE entry SET savingsTransferId = NULL WHERE savingsTransferId = ?",
                           arguments: [savingsTransferId])
            try db.execute(sql: "DELETE FROM savingsTransfer WHERE id = ?", arguments: [savingsTransferId])
        }
    }

    /// De gemarkeerde boekingen in een verrekening.
    public static func entries(_ db: Database, savingsTransferId: Int64) throws -> [Entry] {
        try Entry.fetchAll(db, sql: "SELECT * FROM entry WHERE savingsTransferId = ? ORDER BY day, id",
                           arguments: [savingsTransferId])
    }

    /// De stand van een verrekening: saldo, per pot, de boekingen van het afvinken en de aangehangen bankregels.
    public static func summary(_ db: Database, savingsTransferId: Int64) throws -> SavingsTransferSummary {
        let transfer = try fetch(db, savingsTransferId)
        let marked = try entries(db, savingsTransferId: savingsTransferId)
        let parts = try breakdown(db, marked)
        let booked = try bookedEntries(db, savingsTransferId)
        let accounts = try self.accounts(db, transfer: transfer, booked: booked)
        func transaction(_ accountId: Int64?) -> Int64? {
            booked.first { $0.accountId == accountId && $0.bankTransactionId != nil }?.bankTransactionId
        }
        return SavingsTransferSummary(transfer: transfer, entries: marked, fromSavings: parts.from, toSavings: parts.to,
                                      perPot: parts.perPot, bookedEntries: booked,
                                      checkingAccountId: accounts.checking, savingsAccountId: accounts.savings,
                                      checkingTransactionId: transaction(accounts.checking),
                                      savingsTransactionId: transaction(accounts.savings))
    }

    /// Afgevinkte verrekeningen (netto niet nul) waarvan `confirmationDays` dagen na het boeken nog niet aan
    /// beide kanten een bankregel hangt, oudste eerst. Voor een melding.
    public static func unconfirmed(_ db: Database, today: Day = .today()) throws -> [SavingsTransfer] {
        try SavingsTransfer.fetchAll(db, sql: """
            SELECT * FROM savingsTransfer WHERE done = 1 AND amount <> 0 ORDER BY day, id
            """).filter { transfer in
                let open = try bookedEntries(db, transfer.id!).filter { $0.bankTransactionId == nil }
                guard let bookedOn = open.map(\.day).min() else { return false }
                return bookedOn.adding(days: confirmationDays) <= today
            }
    }

    // MARK: Herkennen en aanhangen

    /// Herkent of een banktransactie de echte overboeking van een verrekening is. Er wordt niets geboekt.
    ///
    /// - Bedrag: op de betaalrekening +netto, op de spaarrekening −netto (netto niet nul).
    /// - Afgevinkte verrekening: haar boeking op deze rekening heeft nog geen banktransactie. Nog niet afgevinkte
    ///   verrekening: de rekening past bij haar boekingen en potten (`needsMarkDone` is dan true).
    /// - Heeft de transactie een tegenrekening, dan moet dat de andere eigen rekening van de verrekening zijn
    ///   (als daarvan het IBAN bekend is; anders een eigen rekening van de andere soort).
    /// - De dag ligt hoogstens `recognitionDays` dagen van de verrekening (de dag van het afvinken, anders de
    ///   dag van de verrekening).
    /// - Precies één kandidaat: een match. Meer: alle kandidaten, en de gebruiker kiest.
    public static func recognize(_ db: Database, bankTransaction: BankTransaction) throws -> SavingsTransferMatch? {
        try recognize(db, bankTransaction, context: try Context(db))
    }

    /// `recognize` voor alle transacties met status `nieuw` van een rekening, per transactie-id.
    public static func recognizeAll(_ db: Database, accountId: Int64) throws -> [Int64: SavingsTransferMatch] {
        let context = try Context(db)
        var result: [Int64: SavingsTransferMatch] = [:]
        for transaction in try newTransactions(db, accountId: accountId) {
            if let match = try recognize(db, transaction, context: context) { result[transaction.id!] = match }
        }
        return result
    }

    /// Hangt een nog niet geboekte banktransactie aan de boeking(en) van een afgevinkte verrekening op die
    /// rekening: zij krijgen de banktransactie en haar DAG, en de banktransactie wordt `verwerkt`. Er komen geen
    /// boekingen bij en het rekeningsaldo verandert niet (alleen de dag kan verschuiven). De som van de
    /// boekingen moet gelijk zijn aan het bankbedrag.
    @discardableResult
    public static func attach(_ db: Database, savingsTransferId: Int64,
                              bankTransactionId: Int64) throws -> SavingsTransferSummary {
        try atomic(db) {
            let transfer = try fetch(db, savingsTransferId)
            let transaction = try Check.bankTransaction(db, bankTransactionId)
            let account = try Check.account(db, transaction.accountId)
            let existing = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM entry WHERE bankTransactionId = ?",
                                            arguments: [bankTransactionId]) ?? 0
            guard transaction.status == .nieuw, existing == 0 else { throw BudgetError.alreadyBooked }
            guard transfer.done else {
                throw BudgetError.validation("Deze overboeking is nog niet afgevinkt. Vink hem eerst af; dan wordt hij "
                    + "geboekt en kan de banktransactie eraan gekoppeld worden.")
            }
            let booked = try bookedEntries(db, savingsTransferId).filter { $0.accountId == transaction.accountId }
            guard !booked.isEmpty else {
                throw BudgetError.validation("Deze overboeking heeft geen boeking op de rekening \(account.name).")
            }
            guard booked.allSatisfy({ $0.bankTransactionId == nil }) else {
                throw BudgetError.validation("Aan deze kant van de overboeking is al een banktransactie gekoppeld.")
            }
            let sum = booked.map(\.amount).sum()
            guard sum == transaction.amount else {
                throw BudgetError.validation("Het bedrag van de banktransactie (\(transaction.amount.formatted())) is niet gelijk aan "
                    + "de overboeking op deze rekening (\(sum.formatted())).")
            }
            guard transaction.day >= account.openingDate else {
                throw BudgetError.beforeOpeningDate(account: account.name, openingDate: account.openingDate)
            }
            try Check.yearOpen(db, day: transaction.day)
            for entry in booked { try Check.yearOpen(db, day: entry.day) }
            try db.execute(sql: """
                UPDATE entry SET bankTransactionId = ?, day = ? WHERE id IN (\(Check.idList(booked.compactMap(\.id))))
                """, arguments: [bankTransactionId, transaction.day])
            try BookingService.setStatus(db, bankTransactionId, .verwerkt)
            return try summary(db, savingsTransferId: savingsTransferId)
        }
    }

    /// Hangt alle eenduidige bankregels van een rekening aan hun afgevinkte verrekening; geeft het aantal
    /// aangehangen bankregels terug. Twijfelgevallen en nog niet afgevinkte verrekeningen blijven staan voor
    /// `recognizeAll`.
    @discardableResult
    public static func attachAll(_ db: Database, accountId: Int64) throws -> Int {
        try atomic(db) {
            var count = 0
            for transaction in try newTransactions(db, accountId: accountId) {
                // Telkens opnieuw herkennen: een eerdere koppeling in deze ronde kan een twijfelgeval oplossen.
                guard let match = try recognize(db, transaction, context: try Context(db)),
                      let transfer = match.transfer, transfer.done else { continue }
                try attach(db, savingsTransferId: transfer.id!, bankTransactionId: transaction.id!)
                count += 1
            }
            return count
        }
    }

    /// Koppelt een aangehangen bankregel weer los: de boekingen van de verrekening blijven staan (met de dag van
    /// de bankregel) en de banktransactie gaat terug naar `nieuw`.
    public static func detach(_ db: Database, bankTransactionId: Int64) throws {
        try atomic(db) {
            let transaction = try Check.bankTransaction(db, bankTransactionId)
            guard try ownsEntries(db, where: "bankTransactionId = ?", arguments: [bankTransactionId]) else {
                throw BudgetError.validation("Deze banktransactie is niet gekoppeld aan een overboeking met spaar.")
            }
            try Check.yearOpen(db, day: transaction.day)
            try db.execute(sql: "UPDATE entry SET bankTransactionId = NULL WHERE bankTransactionId = ?",
                           arguments: [bankTransactionId])
            try BookingService.setStatus(db, bankTransactionId, .nieuw)
        }
    }

    // MARK: Intern

    private static let settingPrefix = "savingsTransfer."
    private static let settingSuffix = ".entries"
    private static func entriesKey(_ id: Int64) -> String { "\(settingPrefix)\(id)\(settingSuffix)" }
    static func bookingNote(_ id: Int64) -> String { "Verrekening #\(id)" }

    /// De boekingen die bij het afvinken zijn gemaakt en nog bestaan.
    private static func bookedEntries(_ db: Database, _ id: Int64) throws -> [Entry] {
        let ids = (try Setting.get(db, entriesKey(id)) ?? "").split(separator: ",").compactMap { Int64($0) }
        guard !ids.isEmpty else { return [] }
        return try Entry.fetchAll(db, sql: "SELECT * FROM entry WHERE id IN (\(Check.idList(ids))) ORDER BY id")
    }

    /// Hoort een van deze boekingen (SQL-voorwaarde op `entry`) bij het afvinken van een verrekening?
    static func ownsEntries(_ db: Database, where condition: String, arguments: StatementArguments) throws -> Bool {
        let values = try String.fetchAll(db, sql: "SELECT value FROM setting WHERE key LIKE ?",
                                         arguments: ["\(settingPrefix)%\(settingSuffix)"])
        let owned = values.flatMap { $0.split(separator: ",").compactMap { Int64($0) } }
        guard !owned.isEmpty else { return false }
        let count = try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM entry WHERE (\(condition)) AND id IN (\(Check.idList(owned)))
            """, arguments: arguments) ?? 0
        return count > 0
    }

    /// Weigert als een van deze boekingen bij het afvinken van een verrekening hoort.
    static func ensureNotOwned(_ db: Database, where condition: String, arguments: StatementArguments) throws {
        if try ownsEntries(db, where: condition, arguments: arguments) { throw BudgetError.savingsTransferBooking }
    }

    private static func removeBookedEntries(_ db: Database, _ id: Int64) throws {
        let booked = try bookedEntries(db, id)
        guard booked.allSatisfy({ $0.bankTransactionId == nil }) else {
            throw BudgetError.validation("Aan deze overboeking is al een banktransactie gekoppeld. Koppel die eerst los; daarna kan "
                + "de overboeking heropend of verwijderd worden.")
        }
        for entry in booked { try Check.yearOpen(db, day: entry.day) }
        if !booked.isEmpty {
            try db.execute(sql: "DELETE FROM entry WHERE id IN (\(Check.idList(booked.compactMap(\.id))))")
        }
        try Setting.set(db, entriesKey(id), nil)
    }

    private static func fetch(_ db: Database, _ id: Int64) throws -> SavingsTransfer {
        try Check.fetch(db, SavingsTransfer.self, id, "Overboeking met spaar")
    }

    private static func newTransactions(_ db: Database, accountId: Int64) throws -> [BankTransaction] {
        try BankTransaction.fetchAll(db, sql: """
            SELECT * FROM bankTransaction WHERE accountId = ? AND status = ? ORDER BY day, id
            """, arguments: [accountId, BankTransactionStatus.nieuw])
    }

    private static func breakdown(_ db: Database, _ entries: [Entry]) throws -> (from: Money, to: Money, perPot: [PotMovement]) {
        let from = -entries.filter { $0.amount.isNegative }.map(\.amount).sum()
        let to = entries.filter { !$0.amount.isNegative }.map(\.amount).sum()
        var sums: [Int64?: Money] = [:]
        for entry in entries { sums[entry.potId, default: .zero] = sums[entry.potId, default: .zero] - entry.amount }
        var movements: [PotMovement] = []
        for (potId, amount) in sums {
            movements.append(PotMovement(pot: try potId.flatMap { try Pot.fetchOne(db, key: $0) }, amount: amount))
        }
        movements.sort { a, b in
            switch (a.pot, b.pot) {
            case let (x?, y?): return (x.sortOrder, x.id!) < (y.sortOrder, y.id!)
            case (_?, nil): return true
            default: return false
            }
        }
        return (from, to, movements)
    }

    /// De betaalrekening van de gemarkeerde boekingen en de spaarrekening van hun potten. Zonder potten is de
    /// spaarrekening de enige niet-gearchiveerde spaarrekening, als er precies één is. Weigert bij meer dan één
    /// betaalrekening of meer dan één spaarrekening.
    private static func accounts(_ db: Database, marked: [Entry]) throws -> (checking: Int64?, savings: Int64?) {
        let checking = Set(marked.map(\.accountId))
        var savings = Set<Int64>()
        for potId in Set(marked.compactMap(\.potId)) { savings.insert(try Check.pot(db, potId).accountId) }
        guard checking.count <= 1 else {
            throw BudgetError.validation("De gekozen boekingen staan op verschillende betaalrekeningen. "
                + "Maak per betaalrekening een aparte overboeking.")
        }
        guard savings.count <= 1 else {
            throw BudgetError.validation("De gekozen boekingen horen bij potjes op verschillende spaarrekeningen. "
                + "Maak per spaarrekening een aparte overboeking.")
        }
        if savings.isEmpty {
            let all = try Int64.fetchAll(db, sql: "SELECT id FROM account WHERE kind = ? AND archived = 0",
                                         arguments: [AccountKind.spaar])
            if all.count == 1 { savings = [all[0]] }
        }
        return (checking.first, savings.first)
    }

    /// De rekeningen van een verrekening: uit de boekingen van het afvinken als die er zijn, anders afgeleid.
    private static func accounts(_ db: Database, transfer: SavingsTransfer,
                                 booked: [Entry]) throws -> (checking: Int64?, savings: Int64?) {
        let derived = try accounts(db, marked: try entries(db, savingsTransferId: transfer.id!))
        guard !booked.isEmpty else { return derived }
        let kinds = try Account.fetchAll(db, sql: "SELECT * FROM account WHERE id IN (\(Check.idList(Array(Set(booked.map(\.accountId))))))")
        return (kinds.first { $0.kind == .betaal }?.id ?? derived.checking,
                kinds.first { $0.kind == .spaar }?.id ?? derived.savings)
    }

    private struct Context {
        var accounts: [Int64: Account] = [:]
        init(_ db: Database) throws {
            for account in try Account.fetchAll(db) { accounts[account.id!] = account }
        }
        func iban(_ accountId: Int64?) -> String? {
            guard let accountId, let iban = accounts[accountId]?.iban else { return nil }
            let normalized = AccountService.normalizeIBAN(iban)
            return normalized.isEmpty ? nil : normalized
        }
    }

    private static func recognize(_ db: Database, _ transaction: BankTransaction,
                                  context: Context) throws -> SavingsTransferMatch? {
        guard let account = context.accounts[transaction.accountId], !transaction.amount.isZero else { return nil }
        let side: SavingsTransferSide = account.kind == .betaal ? .checking : .savings
        let net = side == .checking ? transaction.amount : -transaction.amount
        let counterparty = AccountService.normalizeIBAN(transaction.counterpartyIban)
        let otherKind: AccountKind = side == .checking ? .spaar : .betaal
        let candidates = try SavingsTransfer.fetchAll(db, sql: """
            SELECT * FROM savingsTransfer WHERE amount = ? AND amount <> 0 ORDER BY day, id
            """, arguments: [net]).filter { transfer in
                let booked = try bookedEntries(db, transfer.id!)
                let accounts = try self.accounts(db, transfer: transfer, booked: booked)
                let own = side == .checking ? accounts.checking : accounts.savings
                let other = side == .checking ? accounts.savings : accounts.checking
                let referenceDay: Day
                if transfer.done {
                    // Afgevinkt: de boeking op deze rekening wacht nog op haar bankregel.
                    let waiting = booked.filter { $0.accountId == transaction.accountId }
                    guard let first = waiting.first, waiting.allSatisfy({ $0.bankTransactionId == nil }) else { return false }
                    referenceDay = first.day
                } else {
                    guard own == nil || own == transaction.accountId else { return false }
                    referenceDay = transfer.day
                }
                guard TransferService.daysApart(referenceDay, transaction.day) <= recognitionDays else { return false }
                guard !counterparty.isEmpty else { return true }
                if let expected = context.iban(other) { return expected == counterparty }
                return context.accounts.values.contains { $0.kind == otherKind && context.iban($0.id) == counterparty }
            }
        return candidates.isEmpty ? nil : SavingsTransferMatch(transfers: candidates, side: side)
    }
}
