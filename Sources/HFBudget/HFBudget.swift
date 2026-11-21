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
    /// 'Verrekenen met spaar' op een bedrag van nul. (De naam stamt uit de tijd dat het alleen bij uitgaven kon.)
    case reimburseNotExpense
    case temporaryLoanOnSavings
    /// Tags kunnen alleen op boekingen van een betaalrekening (een tag die er al stond mag blijven of weg).
    case tagOnSavings
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
    /// De boeking zit in een verrekening (per tag) en mag daarom niet zo gewijzigd worden.
    case inSettlement
    /// De boeking is als terugstorting aan een verrekening gekoppeld.
    case depositLinked
    case tagNotSettling(tag: String)
    /// De tag heeft verrekeningen en kan daarom niet verwijderd worden.
    case tagHasSettlements(tag: String, count: Int)
    case notSettleable(entry: String, tag: String)
    case depositInvalid(String)
    /// De boeking hoort bij het afvinken van een verrekening met spaar en wordt daar beheerd.
    case savingsTransferBooking
    /// De periode is geen geldige "yyyy-MM".
    case periodInvalid(String)
    /// De periode ligt meer dan 2 maanden van de datum van de boeking.
    case periodTooFar(period: String, day: Day)
    /// De vaste post bestaat niet (onder hetzelfde label) in het jaar van de periode.
    case itemMissingInYear(item: String, year: Int)

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
            return "Op een betaalrekening kan een pot alleen gekozen worden bij ‘Nog overboeken met spaar’."
        case let .potWrongAccount(pot):
            return "De pot \(pot) hoort niet bij deze spaarrekening."
        case .reimburseOnSavings:
            return "‘Nog overboeken met spaar’ kan alleen bij een boeking op een betaalrekening."
        case .reimburseNotExpense:
            return "‘Nog overboeken met spaar’ kan niet bij een bedrag van nul."
        case .temporaryLoanOnSavings:
            return "'Tijdelijk geleend van spaar' kan alleen bij een boeking op een betaalrekening."
        case .tagOnSavings:
            return "Tags kunnen alleen op boekingen van de betaalrekening, niet op een spaarrekening. "
                + "Haal de tag weg; een tag die er al stond mag blijven."
        case .inSavingsTransfer:
            return "Deze boeking zit in een overboeking met spaar. Maak die eerst ongedaan bij Nog overboeken."
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
            return "De boeking '\(entry)' staat niet (meer) open bij Nog overboeken."
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
        case .inSettlement:
            return "Deze voorgeschoten boeking is terugbetaald. Bedrag, rekening en de tag liggen vast; "
                + "verwijder eerst de terugbetaling."
        case .depositLinked:
            return "Deze bijschrijving is gekoppeld als terugbetaling van voorgeschoten geld. Ontkoppel haar eerst."
        case let .tagHasSettlements(tag, count):
            return "De tag \(tag) heeft \(count) terugbetaling(en) en kan niet verwijderd worden; de historie zou "
                + "verloren gaan. Zet ‘Voorgeschoten’ voor deze tag uit als je hem niet meer gebruikt."
        case let .tagNotSettling(tag):
            return "Voor de tag \(tag) staat ‘Voorgeschoten’ niet aan."
        case let .notSettleable(entry, tag):
            return "De boeking '\(entry)' staat niet open als voorgeschoten voor \(tag): ze heeft de tag niet, "
                + "staat niet op een betaalrekening of is al terugbetaald."
        case let .depositInvalid(message):
            return message
        case .savingsTransferBooking:
            return "Dit is een boeking van een overboeking met spaar. Maak die ongedaan bij Nog overboeken "
                + "(banktransactie loskoppelen, heropenen of verwijderen)."
        case let .periodInvalid(period):
            return "'\(period)' is geen geldige maand. Gebruik de vorm jjjj-mm, bv. 2027-12."
        case let .periodTooFar(period, day):
            return "De maand \(period) ligt meer dan 2 maanden van de datum van de boeking (\(day.dutch)). "
                + "Een boeking kan hoogstens 2 maanden eerder of later meetellen."
        case let .itemMissingInYear(item, year):
            return "De post \(item) bestaat niet in \(year). Maak de post in dat jaar aan of kies een andere maand."
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

    /// Weigert als dit kalenderjaar een afgesloten begrotingsjaar is.
    static func yearOpen(_ db: Database, year: Int) throws {
        let closed = try Bool.fetchOne(db, sql: "SELECT closed FROM budgetYear WHERE year = ?",
                                       arguments: [year]) ?? false
        if closed { throw BudgetError.yearClosed(year) }
    }

    /// "yyyy-MM" voor een jaar en maand.
    static func periodString(year: Int, month: Int) -> String { String(format: "%04d-%02d", year, month) }

    /// Controleert een periode ("yyyy-MM", hoogstens 2 maanden van `day`). Geeft nil als het de maand van `day` is.
    static func normalizedPeriod(_ period: String?, day: Day) throws -> (text: String, year: Int)? {
        guard let period else { return nil }
        let parts = period.split(separator: "-", omittingEmptySubsequences: false)
        guard period.count == 7, parts.count == 2, parts[0].count == 4, let year = Int(parts[0]),
              let month = Int(parts[1]), (1...12).contains(month), (1900...2200).contains(year) else {
            throw BudgetError.periodInvalid(period)
        }
        let distance = (year * 12 + month) - (day.year * 12 + day.month)
        guard abs(distance) <= 2 else { throw BudgetError.periodTooFar(period: period, day: day) }
        return distance == 0 ? nil : (periodString(year: year, month: month), year)
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
    ///
    /// Met een `period` in een ander jaar dan `day` (december ↔ januari) moet de post in het jaar van de periode
    /// bestaan; een post uit het andere jaar wordt vervangen door de post met hetzelfde label in dat jaar.
    /// Geeft de te bewaren post en periode terug (periode nil = de maand van `day`).
    @discardableResult
    static func assignment(_ db: Database, account: Account, day: Day, amount: Money,
                           budgetItemId: Int64?, potId: Int64?, reimburse: Bool, period: String? = nil,
                           allowYearSwitch: Bool = false) throws -> (budgetItemId: Int64?, period: String?) {
        guard day >= account.openingDate else {
            throw BudgetError.beforeOpeningDate(account: account.name, openingDate: account.openingDate)
        }
        try yearOpen(db, day: day)
        let normalized = try normalizedPeriod(period, day: day)
        let targetYear = normalized?.year ?? day.year
        if targetYear != day.year { try yearOpen(db, year: targetYear) }
        var resolvedItemId = budgetItemId
        switch account.kind {
        case .betaal:
            if let budgetItemId {
                var item = try item(db, budgetItemId)
                let year = try budgetYear(db, id: item.yearId)
                if year.year != targetYear {
                    guard allowYearSwitch || normalized != nil else {
                        throw BudgetError.itemWrongYear(item: item.label, day: day)
                    }
                    guard let other = try BudgetItem.fetchOne(db, sql: """
                        SELECT budgetItem.* FROM budgetItem JOIN budgetYear ON budgetYear.id = budgetItem.yearId
                        WHERE budgetYear.year = ? AND budgetItem.label = ? ORDER BY budgetItem.sortOrder LIMIT 1
                        """, arguments: [targetYear, item.label]) else {
                        throw BudgetError.itemMissingInYear(item: item.label, year: targetYear)
                    }
                    item = other
                    resolvedItemId = other.id
                }
                guard item.direction != .RES else { throw BudgetError.resItemNoEntries(item: item.label) }
            }
            // Verrekenen met spaar: een uitgave komt uit de pot, een bijschrijving wordt doorgestort naar de pot.
            if reimburse, amount.isZero { throw BudgetError.reimburseNotExpense }
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
        return (resolvedItemId, normalized?.text)
    }

    static func tagsExist(_ db: Database, _ tagIds: [Int64]) throws {
        for id in Set(tagIds) { _ = try tag(db, id) }
    }

    /// Tags alleen op een betaalrekening. Op een spaarrekening mag alleen een deel van de tags blijven die
    /// de boeking al had (`existing`): niets nieuws erbij, weghalen mag altijd.
    static func tagsAllowed(account: Account, tagIds: [Int64], existing: [Int64] = []) throws {
        guard account.kind != .betaal else { return }
        guard Set(tagIds).isSubset(of: Set(existing)) else { throw BudgetError.tagOnSavings }
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
