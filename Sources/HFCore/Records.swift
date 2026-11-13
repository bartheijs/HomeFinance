import Foundation
import GRDB

// Alle tabellen van HomeFinance. Het schema staat in Schema.swift.
// Conventie: uitgaven negatief, inkomsten positief (Money in centen).

// MARK: - Rekening

public enum AccountKind: String, Codable, Sendable, CaseIterable, DatabaseValueConvertible {
    case betaal, spaar
}

public struct Account: Codable, Identifiable, Equatable, Sendable, FetchableRecord, MutablePersistableRecord {
    public var id: Int64?
    public var name: String
    public var iban: String?
    public var kind: AccountKind
    /// Saldo aan het begin van `openingDate` (vóór de eerste boeking in de app).
    public var openingBalance: Money
    public var openingDate: Day
    public var sortOrder: Int
    public var archived: Bool

    public static let databaseTableName = "account"
    public init(id: Int64? = nil, name: String, iban: String? = nil, kind: AccountKind,
                openingBalance: Money = .zero, openingDate: Day, sortOrder: Int = 0, archived: Bool = false) {
        self.id = id; self.name = name; self.iban = iban; self.kind = kind
        self.openingBalance = openingBalance; self.openingDate = openingDate
        self.sortOrder = sortOrder; self.archived = archived
    }
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

// MARK: - Begroting

public struct BudgetYear: Codable, Identifiable, Equatable, Sendable, FetchableRecord, MutablePersistableRecord {
    public var id: Int64?
    public var year: Int
    /// Vaste buffer om niet rood te staan (positief bedrag).
    public var antiRood: Money
    /// Niet meer in gebruik (besluit 13-11-2026): tijdelijk anti-rood volgt uit boekingen met
    /// `Entry.temporaryLoan`. De kolom blijft bestaan omdat migraties niet worden aangepast.
    public var tijdelijkAntiRood: Money
    /// Niet meer in gebruik (besluit 13-11-2026): geld met een bestemming staat in een pot op de
    /// spaarrekening. De kolom blijft bestaan omdat migraties niet worden aangepast.
    public var reserveBase: Money
    /// Afgesloten jaar: alleen-lezen.
    public var closed: Bool

    public static let databaseTableName = "budgetYear"
    public init(id: Int64? = nil, year: Int, antiRood: Money = .zero, tijdelijkAntiRood: Money = .zero,
                reserveBase: Money = .zero, closed: Bool = false) {
        self.id = id; self.year = year; self.antiRood = antiRood
        self.tijdelijkAntiRood = tijdelijkAntiRood; self.reserveBase = reserveBase; self.closed = closed
    }
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

public enum Direction: String, Codable, Sendable, CaseIterable, DatabaseValueConvertible {
    /// Inkomsten.
    case IN
    /// Uitgaven.
    case UIT
    /// Reserveringsregel: onderdeel van de ene maandelijkse overboeking RESERVERINGEN.
    case RES
}

public enum Frequency: String, Codable, Sendable, CaseIterable, DatabaseValueConvertible {
    case maand, kwartaal, jaar
}

/// Een vaste post in de begroting van één jaar (een rij in het maandgrid).
public struct BudgetItem: Codable, Identifiable, Equatable, Sendable, FetchableRecord, MutablePersistableRecord {
    public var id: Int64?
    public var yearId: Int64
    public var label: String
    public var direction: Direction
    /// Verwacht bedrag per keer dat de post voorkomt, met teken (UIT/RES negatief, IN positief).
    public var planAmount: Money
    public var frequency: Frequency
    /// Maanden (1–12) waarin de post verwacht wordt bij kwartaal/jaar, bv. "1,4,7,10". Leeg bij maand.
    public var expectedMonths: String
    /// Dag van de maand waarop de post meestal komt (voor "te laat"), of nil.
    public var expectedDay: Int?
    /// De ene regel RESERVERINGEN: plan = som van alle RES-regels van het jaar. Hoogstens één per jaar.
    public var isReserveTotal: Bool
    /// Niet meer in gebruik (besluit 13-11-2026); zie `BudgetYear.reserveBase`.
    public var reducesReserve: Bool
    /// Voor RES-regels: de pot op de spaarrekening die hiermee gevuld wordt.
    public var potId: Int64?
    public var sortOrder: Int

    public static let databaseTableName = "budgetItem"
    public init(id: Int64? = nil, yearId: Int64, label: String, direction: Direction, planAmount: Money,
                frequency: Frequency = .maand, expectedMonths: String = "", expectedDay: Int? = nil,
                isReserveTotal: Bool = false, reducesReserve: Bool = false, potId: Int64? = nil, sortOrder: Int = 0) {
        self.id = id; self.yearId = yearId; self.label = label; self.direction = direction
        self.planAmount = planAmount; self.frequency = frequency; self.expectedMonths = expectedMonths
        self.expectedDay = expectedDay; self.isReserveTotal = isReserveTotal
        self.reducesReserve = reducesReserve; self.potId = potId; self.sortOrder = sortOrder
    }
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }

    /// Maanden waarin deze post verwacht wordt.
    public var months: [Int] {
        switch frequency {
        case .maand: return Array(1...12)
        case .kwartaal, .jaar:
            return expectedMonths.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        }
    }
}

// MARK: - Potten

public enum PotKind: String, Codable, Sendable, CaseIterable, DatabaseValueConvertible {
    /// Reserveringspot voor jaarlijkse of onregelmatige kosten.
    case reservering
    /// Spaarpot (bv. per gezinslid of doel).
    case spaar
}

/// Een pot is een deel van het saldo van een spaarrekening.
/// Saldo van een pot = som van alle boekingen (Entry) op die rekening met dit potId.
public struct Pot: Codable, Identifiable, Equatable, Sendable, FetchableRecord, MutablePersistableRecord {
    public var id: Int64?
    public var accountId: Int64
    public var name: String
    public var kind: PotKind
    /// Voor wie de pot is (vrije tekst), of nil.
    public var owner: String?
    /// Vaste maandelijkse storting (positief), gebruikt om een verzamelstorting te verdelen.
    public var monthlyAmount: Money
    /// Optioneel spaardoel.
    public var targetAmount: Money?
    public var sortOrder: Int
    public var archived: Bool

    public static let databaseTableName = "pot"
    public init(id: Int64? = nil, accountId: Int64, name: String, kind: PotKind, owner: String? = nil,
                monthlyAmount: Money = .zero, targetAmount: Money? = nil, sortOrder: Int = 0, archived: Bool = false) {
        self.id = id; self.accountId = accountId; self.name = name; self.kind = kind; self.owner = owner
        self.monthlyAmount = monthlyAmount; self.targetAmount = targetAmount
        self.sortOrder = sortOrder; self.archived = archived
    }
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

// MARK: - Bankimport

public struct ImportBatch: Codable, Identifiable, Equatable, Sendable, FetchableRecord, MutablePersistableRecord {
    public var id: Int64?
    public var accountId: Int64
    public var fileName: String
    public var importedAt: Date
    public var rowCount: Int
    public var newCount: Int
    public var duplicateCount: Int
    public var firstDay: Day?
    public var lastDay: Day?
    /// Saldo vóór de eerste regel en ná de laatste regel volgens het bestand, als de bank dat meelevert.
    public var openingBalance: Money?
    public var closingBalance: Money?
    /// De saldoketen in het bestand sluit (elk saldo-vóór + bedrag = volgend saldo-vóór).
    public var chainOK: Bool

    public static let databaseTableName = "importBatch"
    public init(id: Int64? = nil, accountId: Int64, fileName: String, importedAt: Date = Date(), rowCount: Int = 0,
                newCount: Int = 0, duplicateCount: Int = 0, firstDay: Day? = nil, lastDay: Day? = nil,
                openingBalance: Money? = nil, closingBalance: Money? = nil, chainOK: Bool = true) {
        self.id = id; self.accountId = accountId; self.fileName = fileName; self.importedAt = importedAt
        self.rowCount = rowCount; self.newCount = newCount; self.duplicateCount = duplicateCount
        self.firstDay = firstDay; self.lastDay = lastDay
        self.openingBalance = openingBalance; self.closingBalance = closingBalance; self.chainOK = chainOK
    }
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

public enum BankTransactionStatus: String, Codable, Sendable, CaseIterable, DatabaseValueConvertible {
    /// Geïmporteerd, nog niet geboekt: staat in de review.
    case nieuw
    /// Geboekt: er zijn boekingen (Entry) waarvan de som gelijk is aan het bedrag.
    case verwerkt
    /// Bewust overgeslagen (bv. al met de hand ingevoerd).
    case overgeslagen
}

/// Een regel uit een bankafschrift, precies zoals de bank hem leverde. Wordt nooit aangepast.
public struct BankTransaction: Codable, Identifiable, Equatable, Sendable, FetchableRecord, MutablePersistableRecord {
    public var id: Int64?
    public var accountId: Int64
    public var batchId: Int64?
    public var day: Day
    public var amount: Money
    /// Saldo van de rekening vóór deze mutatie, als de bank dat meelevert.
    public var balanceBefore: Money?
    public var counterpartyName: String
    public var counterpartyIban: String
    public var descriptionText: String
    public var reference: String
    public var transactionCode: String
    /// Volgnummer of ander uniek kenmerk van de bank; mag leeg zijn.
    public var sequence: String
    /// Unieke vingerafdruk voor het herkennen van dubbele import.
    public var fingerprint: String
    public var status: BankTransactionStatus

    public static let databaseTableName = "bankTransaction"
    public init(id: Int64? = nil, accountId: Int64, batchId: Int64? = nil, day: Day, amount: Money,
                balanceBefore: Money? = nil, counterpartyName: String = "", counterpartyIban: String = "",
                descriptionText: String = "", reference: String = "", transactionCode: String = "",
                sequence: String = "", fingerprint: String, status: BankTransactionStatus = .nieuw) {
        self.id = id; self.accountId = accountId; self.batchId = batchId; self.day = day; self.amount = amount
        self.balanceBefore = balanceBefore; self.counterpartyName = counterpartyName
        self.counterpartyIban = counterpartyIban; self.descriptionText = descriptionText
        self.reference = reference; self.transactionCode = transactionCode
        self.sequence = sequence; self.fingerprint = fingerprint; self.status = status
    }
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

// MARK: - Boekingen

public enum Confidence: String, Codable, Sendable, CaseIterable, DatabaseValueConvertible {
    case hoog, midden, laag, geen
}

/// Een boeking: een bedrag op een rekening, toegewezen aan een post of pot.
/// Een banktransactie heeft één boeking, of meer als hij gesplitst is (de som is dan het bankbedrag).
/// Een boeking zonder banktransactie is met de hand ingevoerd.
///
/// Betaalrekening: `budgetItemId` = de vaste post; nil = "divers" (IN divers bij +, UIT divers bij −).
/// Spaarrekening: `potId` = de pot waar het bedrag bij komt (+) of af gaat (−); nil = niet toegewezen.
public struct Entry: Codable, Identifiable, Equatable, Sendable, FetchableRecord, MutablePersistableRecord {
    public var id: Int64?
    public var accountId: Int64
    public var bankTransactionId: Int64?
    public var day: Day
    public var amount: Money
    /// Leesbare omschrijving (niet de ruwe banktekst).
    public var label: String
    public var budgetItemId: Int64?
    public var potId: Int64?
    /// Uitgave op de betaalrekening die uit de spaarrekening vergoed moet worden.
    /// `potId` zegt dan uit welke pot.
    public var reimburse: Bool
    /// De spaaroverboeking waarin deze uitgave is meegenomen, of nil als hij nog openstaat.
    public var savingsTransferId: Int64?
    /// De tegenboeking op de andere eigen rekening (overboeking tussen betaal en spaar).
    public var counterEntryId: Int64?
    /// Door de gebruiker nagekeken. Nieuwe boekingen uit een import staan op false ("rood").
    public var reviewed: Bool
    public var note: String
    /// De regel die het voorstel deed, en hoe zeker dat was.
    public var ruleId: Int64?
    public var confidence: Confidence?
    public var createdAt: Date
    /// Tijdelijk geleend van spaar (tijdelijk anti-rood): een bedrag dat op de betaalrekening staat maar terug
    /// moet. Erbij (+) bij het lenen, eraf (−) bij het terugboeken. Het uitstaande saldo telt niet als besteedbaar.
    public var temporaryLoan: Bool

    public static let databaseTableName = "entry"
    public init(id: Int64? = nil, accountId: Int64, bankTransactionId: Int64? = nil, day: Day, amount: Money,
                label: String, budgetItemId: Int64? = nil, potId: Int64? = nil, reimburse: Bool = false,
                savingsTransferId: Int64? = nil, counterEntryId: Int64? = nil, reviewed: Bool = true,
                note: String = "", ruleId: Int64? = nil, confidence: Confidence? = nil, createdAt: Date = Date(),
                temporaryLoan: Bool = false) {
        self.temporaryLoan = temporaryLoan
        self.id = id; self.accountId = accountId; self.bankTransactionId = bankTransactionId
        self.day = day; self.amount = amount; self.label = label
        self.budgetItemId = budgetItemId; self.potId = potId; self.reimburse = reimburse
        self.savingsTransferId = savingsTransferId; self.counterEntryId = counterEntryId
        self.reviewed = reviewed; self.note = note; self.ruleId = ruleId
        self.confidence = confidence; self.createdAt = createdAt
    }
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

/// Trackingcategorie (bv. tanken, uit eten). Telt niet als extra uitgave; alleen om te volgen.
public struct Tag: Codable, Identifiable, Equatable, Sendable, FetchableRecord, MutablePersistableRecord {
    public var id: Int64?
    public var name: String
    /// Kleur als hex "#RRGGBB".
    public var color: String
    public var sortOrder: Int

    public static let databaseTableName = "tag"
    public init(id: Int64? = nil, name: String, color: String = "#888888", sortOrder: Int = 0) {
        self.id = id; self.name = name; self.color = color; self.sortOrder = sortOrder
    }
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

public struct EntryTag: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public var entryId: Int64
    public var tagId: Int64
    public static let databaseTableName = "entryTag"
    public init(entryId: Int64, tagId: Int64) { self.entryId = entryId; self.tagId = tagId }
}

// MARK: - Regels

public enum RuleOrigin: String, Codable, Sendable, CaseIterable, DatabaseValueConvertible {
    case handmatig, geleerd
}

/// Een categorisatieregel. Alle ingevulde voorwaarden moeten kloppen (EN).
/// Tekstvergelijkingen zijn hoofdletterongevoelig en negeren accenten.
public struct Rule: Codable, Identifiable, Equatable, Sendable, FetchableRecord, MutablePersistableRecord {
    public var id: Int64?
    public var name: String
    /// Lager = eerder geprobeerd binnen dezelfde zekerheid.
    public var priority: Int
    public var enabled: Bool
    public var origin: RuleOrigin
    /// Alleen voor deze rekening, of nil voor alle rekeningen.
    public var accountId: Int64?

    // Voorwaarden
    public var counterpartyContains: String?
    public var counterpartyIban: String?
    public var descriptionContains: String?
    /// Exact bedrag met teken, of nil.
    public var amount: Money?

    // Resultaat
    /// Label van de vaste post (posten bestaan per jaar; het label koppelt ze over jaren). nil = divers.
    public var targetItemLabel: String?
    public var targetPotId: Int64?
    /// Leesbare omschrijving voor de boeking; nil = opgeschoonde naam van de tegenpartij.
    public var entryLabel: String?
    /// Tag-id's, gescheiden door komma's.
    public var tagIds: String
    public var reimburse: Bool

    public var hitCount: Int
    public var lastUsed: Date?

    public static let databaseTableName = "rule"
    public init(id: Int64? = nil, name: String, priority: Int = 100, enabled: Bool = true,
                origin: RuleOrigin = .handmatig, accountId: Int64? = nil,
                counterpartyContains: String? = nil, counterpartyIban: String? = nil,
                descriptionContains: String? = nil, amount: Money? = nil,
                targetItemLabel: String? = nil, targetPotId: Int64? = nil, entryLabel: String? = nil,
                tagIds: String = "", reimburse: Bool = false, hitCount: Int = 0, lastUsed: Date? = nil) {
        self.id = id; self.name = name; self.priority = priority; self.enabled = enabled
        self.origin = origin; self.accountId = accountId
        self.counterpartyContains = counterpartyContains; self.counterpartyIban = counterpartyIban
        self.descriptionContains = descriptionContains; self.amount = amount
        self.targetItemLabel = targetItemLabel; self.targetPotId = targetPotId; self.entryLabel = entryLabel
        self.tagIds = tagIds; self.reimburse = reimburse; self.hitCount = hitCount; self.lastUsed = lastUsed
    }
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }

    public var tagIdList: [Int64] {
        get { tagIds.split(separator: ",").compactMap { Int64($0) } }
        set { tagIds = newValue.map(String.init).joined(separator: ",") }
    }
}

// MARK: - Afstemming en spaaroverboekingen

/// Vastgelegde controle: berekend saldo tegen het werkelijke banksaldo op een dag.
public struct Reconciliation: Codable, Identifiable, Equatable, Sendable, FetchableRecord, MutablePersistableRecord {
    public var id: Int64?
    public var accountId: Int64
    public var day: Day
    public var actualBalance: Money
    public var calculatedBalance: Money
    public var createdAt: Date

    public static let databaseTableName = "reconciliation"
    public init(id: Int64? = nil, accountId: Int64, day: Day, actualBalance: Money, calculatedBalance: Money,
                createdAt: Date = Date()) {
        self.id = id; self.accountId = accountId; self.day = day
        self.actualBalance = actualBalance; self.calculatedBalance = calculatedBalance; self.createdAt = createdAt
    }
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
    public var difference: Money { calculatedBalance - actualBalance }
}

/// Eén overboeking van spaar naar betaal die een aantal gemarkeerde uitgaven vergoedt.
public struct SavingsTransfer: Codable, Identifiable, Equatable, Sendable, FetchableRecord, MutablePersistableRecord {
    public var id: Int64?
    public var day: Day
    /// Positief bedrag dat van spaar naar betaal gaat.
    public var amount: Money
    public var done: Bool
    public var doneAt: Date?
    public var note: String

    public static let databaseTableName = "savingsTransfer"
    public init(id: Int64? = nil, day: Day, amount: Money, done: Bool = false, doneAt: Date? = nil, note: String = "") {
        self.id = id; self.day = day; self.amount = amount; self.done = done; self.doneAt = doneAt; self.note = note
    }
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

/// Losse instelling (sleutel/waarde), voor alles wat geen eigen tabel verdient.
public struct Setting: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public var key: String
    public var value: String
    public static let databaseTableName = "setting"
    public init(key: String, value: String) { self.key = key; self.value = value }

    public static func get(_ db: Database, _ key: String) throws -> String? {
        try String.fetchOne(db, sql: "SELECT value FROM setting WHERE key = ?", arguments: [key])
    }
    public static func set(_ db: Database, _ key: String, _ value: String?) throws {
        if let value {
            try Setting(key: key, value: value).save(db)
        } else {
            try db.execute(sql: "DELETE FROM setting WHERE key = ?", arguments: [key])
        }
    }
}
