// Module HFBudget — alle schrijfacties van HomeFinance (boeken, potten, overboekingen, afstemming,
// jaar en posten, rekeningen en tags). Zie docs/api/HFBudget.md en docs/spec.
//
// Elke service is een `enum` met statische functies die een GRDB-`Database` krijgen. Elke functie
// draait in een eigen savepoint: hij slaagt helemaal of verandert niets. Roep ze aan binnen
// `AppDatabase.write { db in ... }`; meerdere aanroepen in één `write` vormen samen één transactie.
import Foundation
import GRDB
import HFCore

// MARK: - Fouten

/// Fout uit een schrijfactie, met een Nederlandse melding voor de gebruiker (`errorDescription`).
public enum BudgetError: LocalizedError, Equatable, Sendable {
    /// Een record met dit id bestaat niet (`what` is bv. "Rekening").
    case notFound(what: String, id: Int64)
    /// Algemene invoerfout met een kant-en-klare melding.
    case validation(String)
    /// Het jaar is afgesloten: boekingen en posten van dat jaar zijn alleen-lezen.
    case yearClosed(Int)
    case yearExists(Int)
    case yearMissing(Int)
    case allocationsEmpty
    /// De som van de splitsing is niet gelijk aan het bankbedrag.
    case allocationSumMismatch(expected: Money, actual: Money)
    case beforeOpeningDate(account: String, openingDate: Day)
    case itemWrongYear(item: String, day: Day)
    /// RES-regels krijgen geen boekingen; boek op de regel RESERVERINGEN.
    case resItemNoEntries(item: String)
    case budgetItemOnSavings
    case potRequiresReimburse
    case potWrongAccount(pot: String)
    case reimburseOnSavings
    case reimburseNotExpense
    case temporaryLoanOnSavings
    /// De boeking zit in een spaaroverboeking en mag daarom niet zo gewijzigd worden.
    case inSavingsTransfer
    /// Bedrag, dag en rekening van een boeking uit een banktransactie liggen vast.
    case bankEntryImmutable
    case bankEntryDelete
    case alreadyBooked
    case notSkipped
    case transferInvalid(String)
    case alreadyLinked
    case notLinked
    case potNotEmpty(pot: String, balance: Money)
    case potHasEntries(pot: String)
    case notReimbursable(entry: String)
    case signMismatch(direction: Direction)
    case reserveTotalExists(year: Int)
    case itemHasEntries(item: String, count: Int)
    case duplicateIban(String)
    case duplicateName(String)
    case accountInUse(account: String)

    public var errorDescription: String? {
        switch self {
        case let .notFound(what, id):
            return "\(what) met nummer \(id) bestaat niet (meer)."
        case let .validation(message):
            return message
        case let .yearClosed(year):
            return "Het jaar \(year) is afgesloten. Heropen het jaar om boekingen of posten te wijzigen."
        case let .yearExists(year):
            return "Het jaar \(year) bestaat al."
        case let .yearMissing(year):
            return "Het jaar \(year) bestaat nog niet."
        case .allocationsEmpty:
            return "Een boeking heeft minstens één regel nodig."
        case let .allocationSumMismatch(expected, actual):
            return "De regels tellen op tot \(actual.formatted()), maar de banktransactie is "
                + "\(expected.formatted()). Verschil: \((expected - actual).formatted())."
        case let .beforeOpeningDate(account, openingDate):
            return "De rekening \(account) begint op \(openingDate.dutch). Boekingen vóór die datum kunnen niet."
        case let .itemWrongYear(item, day):
            return "De post \(item) hoort niet bij het jaar \(day.year) van deze boeking (\(day.dutch))."
        case let .resItemNoEntries(item):
            return "Op de reserveringsregel \(item) kan niet geboekt worden. Boek op de regel RESERVERINGEN."
        case .budgetItemOnSavings:
            return "Een boeking op een spaarrekening kan geen vaste post hebben, alleen een pot."
        case .potRequiresReimburse:
            return "Op een betaalrekening kan een pot alleen gekozen worden bij 'vergoeden uit spaar'."
        case let .potWrongAccount(pot):
            return "De pot \(pot) hoort niet bij deze spaarrekening."
        case .reimburseOnSavings:
            return "'Vergoeden uit spaar' kan alleen bij een boeking op een betaalrekening."
        case .reimburseNotExpense:
            return "'Vergoeden uit spaar' kan alleen bij een uitgave (negatief bedrag)."
        case .temporaryLoanOnSavings:
            return "'Tijdelijk geleend van spaar' kan alleen bij een boeking op een betaalrekening."
        case .inSavingsTransfer:
            return "Deze boeking zit in een spaaroverboeking. Verwijder eerst die spaaroverboeking."
        case .bankEntryImmutable:
            return "Bedrag, datum en rekening van een boeking uit een banktransactie liggen vast. "
                + "Boek de transactie opnieuw om bedragen te wijzigen."
        case .bankEntryDelete:
            return "Deze boeking hoort bij een banktransactie. Maak de boeking van de transactie ongedaan."
        case .alreadyBooked:
            return "Deze transactie is al geboekt. Maak eerst de boeking ongedaan."
        case .notSkipped:
            return "Deze transactie is niet overgeslagen."
        case let .transferInvalid(message):
            return message
        case .alreadyLinked:
            return "Deze transactie is al gekoppeld als overboeking."
        case .notLinked:
            return "Deze transactie is niet gekoppeld als overboeking."
        case let .potNotEmpty(pot, balance):
            return "De pot \(pot) heeft nog een saldo van \(balance.formatted()). Archiveren kan pas bij € 0,00."
        case let .potHasEntries(pot):
            return "De pot \(pot) heeft boekingen en kan niet verwijderd worden. Archiveer de pot."
        case let .notReimbursable(entry):
            return "De boeking '\(entry)' staat niet (meer) open voor vergoeding uit spaar."
        case let .signMismatch(direction):
            switch direction {
            case .IN: return "Het planbedrag van een IN-post moet positief of nul zijn."
            case .UIT: return "Het planbedrag van een UIT-post moet negatief of nul zijn."
            case .RES: return "Het planbedrag van een reserveringsregel moet negatief of nul zijn."
            }
        case let .reserveTotalExists(year):
            return "Het jaar \(year) heeft al een regel RESERVERINGEN. Er kan er maar één zijn."
        case let .itemHasEntries(item, count):
            return "De post \(item) heeft \(count) boeking(en). Verwijderen kan alleen als die 'divers' worden."
        case let .duplicateIban(iban):
            return "Er bestaat al een rekening met IBAN \(iban)."
        case let .duplicateName(name):
            return "De naam '\(name)' is al in gebruik."
        case let .accountInUse(account):
            return "De rekening \(account) heeft boekingen, transacties of potten en kan niet verwijderd worden. "
                + "Archiveer de rekening."
        }
    }
}

// MARK: - Gedeelde hulpfuncties (intern)

/// Voert `block` uit in een savepoint: alles of niets. Opent zelf een transactie als die er nog niet is.
func atomic<T>(_ db: Database, _ block: () throws -> T) throws -> T {
    var result: T?
    try db.inSavepoint {
        result = try block()
        return .commit
    }
    return result!
}

enum Check {
    static func fetch<T: FetchableRecord & TableRecord>(_ db: Database, _ type: T.Type, _ id: Int64,
                                                        _ what: String) throws -> T {
        guard let record = try T.fetchOne(db, key: id) else { throw BudgetError.notFound(what: what, id: id) }
        return record
    }

    static func account(_ db: Database, _ id: Int64) throws -> Account { try fetch(db, Account.self, id, "Rekening") }
    static func pot(_ db: Database, _ id: Int64) throws -> Pot { try fetch(db, Pot.self, id, "Pot") }
    static func item(_ db: Database, _ id: Int64) throws -> BudgetItem { try fetch(db, BudgetItem.self, id, "Post") }
    static func entry(_ db: Database, _ id: Int64) throws -> Entry { try fetch(db, Entry.self, id, "Boeking") }
    static func tag(_ db: Database, _ id: Int64) throws -> Tag { try fetch(db, Tag.self, id, "Tag") }
    static func bankTransaction(_ db: Database, _ id: Int64) throws -> BankTransaction {
        try fetch(db, BankTransaction.self, id, "Banktransactie")
    }
    static func budgetYear(_ db: Database, id: Int64) throws -> BudgetYear {
        try fetch(db, BudgetYear.self, id, "Jaar")
    }
    static func budgetYear(_ db: Database, year: Int) throws -> BudgetYear {
        guard let record = try BudgetYear.fetchOne(db, sql: "SELECT * FROM budgetYear WHERE year = ?",
                                                   arguments: [year]) else { throw BudgetError.yearMissing(year) }
        return record
    }

    /// Weigert als het kalenderjaar van `day` een afgesloten begrotingsjaar is.
    static func yearOpen(_ db: Database, day: Day) throws {
        let closed = try Bool.fetchOne(db, sql: "SELECT closed FROM budgetYear WHERE year = ?",
                                       arguments: [day.year]) ?? false
        if closed { throw BudgetError.yearClosed(day.year) }
    }

    /// Haalt het jaar op en weigert als het afgesloten is.
    @discardableResult
    static func yearOpen(_ db: Database, yearId: Int64) throws -> BudgetYear {
        let year = try budgetYear(db, id: yearId)
        if year.closed { throw BudgetError.yearClosed(year.year) }
        return year
    }

    static func nonEmpty(_ text: String, _ field: String) throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw BudgetError.validation("\(field) mag niet leeg zijn.") }
        return trimmed
    }

    /// De regels voor waar een boeking aan toegewezen mag worden (post, pot, vergoeden).
    static func assignment(_ db: Database, account: Account, day: Day, amount: Money,
                           budgetItemId: Int64?, potId: Int64?, reimburse: Bool) throws {
        guard day >= account.openingDate else {
            throw BudgetError.beforeOpeningDate(account: account.name, openingDate: account.openingDate)
        }
        try yearOpen(db, day: day)
        switch account.kind {
        case .betaal:
            if let budgetItemId {
                let item = try item(db, budgetItemId)
                let year = try budgetYear(db, id: item.yearId)
                guard year.year == day.year else { throw BudgetError.itemWrongYear(item: item.label, day: day) }
                guard item.direction != .RES else { throw BudgetError.resItemNoEntries(item: item.label) }
            }
            if reimburse, !amount.isNegative { throw BudgetError.reimburseNotExpense }
            if let potId {
                guard reimburse else { throw BudgetError.potRequiresReimburse }
                _ = try pot(db, potId)
            }
        case .spaar:
            guard budgetItemId == nil else { throw BudgetError.budgetItemOnSavings }
            guard !reimburse else { throw BudgetError.reimburseOnSavings }
            if let potId {
                let pot = try pot(db, potId)
                guard pot.accountId == account.id else { throw BudgetError.potWrongAccount(pot: pot.name) }
            }
        }
    }

    static func tagsExist(_ db: Database, _ tagIds: [Int64]) throws {
        for id in Set(tagIds) { _ = try tag(db, id) }
    }

    static func replaceTags(_ db: Database, entryId: Int64, tagIds: [Int64]) throws {
        try db.execute(sql: "DELETE FROM entryTag WHERE entryId = ?", arguments: [entryId])
        var seen = Set<Int64>()
        for tagId in tagIds where seen.insert(tagId).inserted {
            try EntryTag(entryId: entryId, tagId: tagId).insert(db)
        }
    }

    /// Zet `sortOrder` 0, 1, 2, … in de volgorde van `orderedIds`; die moeten precies de bestaande id's zijn.
    static func reorder(_ db: Database, table: String, existingIds: [Int64], orderedIds: [Int64]) throws {
        guard Set(existingIds) == Set(orderedIds), existingIds.count == orderedIds.count else {
            throw BudgetError.validation("De nieuwe volgorde moet precies alle bestaande regels bevatten.")
        }
        for (index, id) in orderedIds.enumerated() {
            try db.execute(sql: "UPDATE \(table) SET sortOrder = ? WHERE id = ?", arguments: [index, id])
        }
    }

    static func nextSortOrder(_ db: Database, table: String, whereSQL: String = "1",
                              arguments: StatementArguments = []) throws -> Int {
        try Int.fetchOne(db, sql: "SELECT COALESCE(MAX(sortOrder), -1) + 1 FROM \(table) WHERE \(whereSQL)",
                         arguments: arguments) ?? 0
    }

    static func idList(_ ids: [Int64]) -> String { ids.map(String.init).joined(separator: ",") }
}
