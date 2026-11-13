import Foundation
import GRDB
import HFCore

public enum HistoryError: LocalizedError, Equatable {
    case nothingToImport
    case accountNotFound
    case notACheckingAccount(String)
    case notASavingsAccount(String)
    case duplicateYear(Int)
    case invalidThroughMonth(year: Int, month: Int)
    case totalsDiffer(year: Int)
    case yearHasOtherEntries(year: Int, count: Int)
    case openingBalanceUnknown(year: Int)
    case openingBalanceChanges(HistoryOpeningChange)
    case savingsTotalsDiffer(count: Int)
    case savingsHasOtherEntries(count: Int, lastDay: Day)

    public var errorDescription: String? {
        switch self {
        case .nothingToImport:
            "Er is niets gekozen om te importeren."
        case .accountNotFound:
            "De gekozen rekening bestaat niet (meer)."
        case .notACheckingAccount(let name):
            "\(name) is geen betaalrekening. De begrotingshistorie hoort op een betaalrekening."
        case .notASavingsAccount(let name):
            "\(name) is geen spaarrekening. De potten horen op een spaarrekening."
        case .duplicateYear(let year):
            "Het jaar \(year) is twee keer gekozen."
        case .invalidThroughMonth(let year, let month):
            "De grens voor \(year) (maand \(month)) is geen maand van 1 t/m 12."
        case .totalsDiffer(let year):
            "De totalen van \(year) kloppen niet met Excel. Kies bij dat jaar ‘toch importeren’ als je het verschil accepteert."
        case .yearHasOtherEntries(let year, let count):
            "In \(year) \(count == 1 ? "staat al 1 boeking die" : "staan al \(count) boekingen die") niet uit de Excel-historie \(count == 1 ? "komt" : "komen"). Importeren zou dubbel tellen; \(year) is daarom niet geïmporteerd."
        case .openingBalanceUnknown(let year):
            "Het beginsaldo van \(year) is niet gevonden in het blad. Zonder beginsaldo kan de begindatum van de rekening niet naar 1 januari \(year)."
        case .openingBalanceChanges(let change):
            "Het saldo op \(change.oldDate.dutch) wordt \(change.balanceAtOldDate.formatted()) in plaats van \(change.oldBalance.formatted()). Bevestig dat eerst."
        case .savingsTotalsDiffer(let count):
            "Bij \(count == 1 ? "1 pot is" : "\(count) potten is") de som van de mutaties niet gelijk aan het saldo in Excel. Bevestig eerst dat je toch wilt importeren."
        case .savingsHasOtherEntries(let count, let lastDay):
            "Op deze spaarrekening \(count == 1 ? "staat al 1 boeking" : "staan al \(count) boekingen") op of vóór \(lastDay.dutch) die niet uit de Excel-historie \(count == 1 ? "komt" : "komen") (bijvoorbeeld een beginsaldo per pot). De hele historie importeren zou dubbel tellen. Verwijder die boekingen eerst of importeer de spaarhistorie niet."
        }
    }
}

/// Wat het verplaatsen van de begindatum van een rekening betekent.
public struct HistoryOpeningChange: Equatable, Sendable {
    public var oldDate: Day
    public var oldBalance: Money
    public var newDate: Day
    /// Het nieuwe beginsaldo op `newDate`.
    public var newBalance: Money
    /// Het saldo aan het begin van `oldDate` na de import (nieuw beginsaldo + de historie tot die dag).
    public var balanceAtOldDate: Money

    /// Nieuw berekend − oud. € 0,00 = de historie sluit precies aan.
    public var difference: Money { balanceAtOldDate - oldBalance }
}

/// Controle vooraf van de begrotingsimport: wat kan, wat niet, en wat het met het beginsaldo doet.
public struct HistoryBudgetCheck: Equatable, Sendable {
    /// Jaren die geweigerd worden, met de reden.
    public var refused: [Int: String]
    /// Jaren die al eerder uit Excel geïmporteerd zijn en vervangen worden.
    public var replaced: [Int]
    /// Jaren die al bestaan met eigen posten (zonder boekingen); die posten worden vervangen.
    public var existingItems: [Int: Int]
    /// Gevuld als de begindatum van de rekening verschuift.
    public var openingChange: HistoryOpeningChange?
    /// Fout bij het bepalen van het beginsaldo (bv. beginsaldo ontbreekt in het blad).
    public var openingProblem: String?
}

public struct HistorySavingsCheck: Equatable, Sendable {
    /// Reden waarom de import geweigerd wordt, of nil.
    public var refusal: String?
    /// Potten die nieuw aangemaakt worden.
    public var newPots: [String]
    /// Er staat al spaarhistorie uit Excel; die wordt vervangen.
    public var replaces: Bool
    public var openingChange: HistoryOpeningChange?
}

/// Wat te doen als het saldo op de oude begindatum van de spaarrekening verandert.
public enum HistoryOpeningDecision: Sendable, Equatable {
    /// Niet importeren (fout `openingBalanceChanges`).
    case stopIfDifferent
    /// Nieuw beginsaldo € 0,00 op de eerste datum; het saldo op de oude begindatum wordt de som van de historie.
    case acceptNewBalance
    /// Het saldo op de oude begindatum blijft gelijk; het verschil wordt het beginsaldo op de eerste datum
    /// (geld op de rekening dat niet in een pot uit het blad zit).
    case keepOldBalance
}

public struct HistoryImportResult: Equatable, Sendable {
    public var years: [Int] = []
    public var itemCount = 0
    public var entryCount = 0
    public var newTagCount = 0
    public var newPotCount = 0
    public var openingChange: HistoryOpeningChange?
}

/// Zet de gelezen historie in de database. Schrijft zelf met GRDB (hangt niet af van HFBudget) en houdt zich
/// aan dezelfde afspraken: geen boeking vóór de begindatum van de rekening, hoogstens één regel
/// RESERVERINGEN per jaar met als plan de som van de RES-regels, RES-regels zonder boekingen.
public enum HistoryImporter {
    /// De notitie waaraan boekingen uit de Excel-historie te herkennen zijn.
    public static let note = "Excel-historie"

    private static let tagColors = ["#2D6CDF", "#D98E04", "#B0447F", "#6B5BD2", "#3C9AA8", "#C0562B", "#1F7A5C", "#7A8590"]

    // MARK: Begroting

    /// Controleert zonder iets te wijzigen wat een import van deze jaren op deze betaalrekening zou doen.
    public static func checkBudget(_ db: Database, years: [HistoryYear], accountId: Int64,
                                   throughMonth: [Int: Int] = [:]) throws -> HistoryBudgetCheck {
        let account = try checkingAccount(db, accountId)
        var check = HistoryBudgetCheck(refused: [:], replaced: [], existingItems: [:])
        for year in years {
            let other = try otherEntryCount(db, year: year.year)
            if other > 0 {
                check.refused[year.year] = HistoryError.yearHasOtherEntries(year: year.year, count: other).localizedDescription
                continue
            }
            if try historyEntryCount(db, year: year.year) > 0 {
                check.replaced.append(year.year)
            } else {
                let items = try Int.fetchOne(db, sql: """
                    SELECT COUNT(*) FROM budgetItem WHERE yearId IN (SELECT id FROM budgetYear WHERE year = ?)
                    """, arguments: [year.year]) ?? 0
                if items > 0 { check.existingItems[year.year] = items }
            }
        }
        let allowed = years.filter { check.refused[$0.year] == nil }
        do {
            check.openingChange = try budgetOpeningChange(account: account, years: allowed, throughMonth: throughMonth)
        } catch {
            check.openingProblem = error.localizedDescription
        }
        return check
    }

    /// Importeert de gekozen jaren op een betaalrekening, in één transactie: alles of niets.
    ///
    /// - `forcedYears`: jaren waarvan de totalen niet kloppen met Excel en die de gebruiker toch wil importeren.
    /// - `throughMonth`: per jaar een grens (0–12): alleen de boekingen t/m die maand gaan mee. Posten en plan
    ///   komen altijd mee. Een jaar zonder grens wordt helemaal geïmporteerd. 0 = geen enkele boeking.
    /// - `confirmOpeningChange`: de gebruiker heeft gezien dat het saldo op de oude begindatum verandert.
    /// - `today`: het jaar van vandaag blijft open; de andere geïmporteerde jaren worden afgesloten.
    @discardableResult
    public static func importBudget(years: [HistoryYear], into database: AppDatabase, accountId: Int64,
                                    forcedYears: Set<Int> = [], throughMonth: [Int: Int] = [:],
                                    confirmOpeningChange: Bool = false,
                                    today: Day = .today()) throws -> HistoryImportResult {
        try database.write { db in
            try importBudget(db, years: years, accountId: accountId, forcedYears: forcedYears, throughMonth: throughMonth,
                             confirmOpeningChange: confirmOpeningChange, today: today)
        }
    }

    /// Als hierboven, binnen een bestaande transactie.
    @discardableResult
    public static func importBudget(_ db: Database, years: [HistoryYear], accountId: Int64,
                                    forcedYears: Set<Int> = [], throughMonth: [Int: Int] = [:],
                                    confirmOpeningChange: Bool = false,
                                    today: Day = .today()) throws -> HistoryImportResult {
        var result = HistoryImportResult()
        try db.inSavepoint {
            guard !years.isEmpty else { throw HistoryError.nothingToImport }
            var account = try checkingAccount(db, accountId)
            var seen: Set<Int> = []
            for year in years {
                guard seen.insert(year.year).inserted else { throw HistoryError.duplicateYear(year.year) }
                if let month = throughMonth[year.year], !(0...12).contains(month) {
                    throw HistoryError.invalidThroughMonth(year: year.year, month: month)
                }
                guard year.totalsMatch || forcedYears.contains(year.year) else { throw HistoryError.totalsDiffer(year: year.year) }
                let other = try otherEntryCount(db, year: year.year)
                guard other == 0 else { throw HistoryError.yearHasOtherEntries(year: year.year, count: other) }
            }

            if let change = try budgetOpeningChange(account: account, years: years, throughMonth: throughMonth) {
                guard change.difference.isZero || confirmOpeningChange else { throw HistoryError.openingBalanceChanges(change) }
                account.openingDate = change.newDate
                account.openingBalance = change.newBalance
                try account.update(db)
                result.openingChange = change
            }

            var tagIds: [String: Int64] = [:]
            for tag in try Tag.fetchAll(db) { tagIds[tag.name.lowercased()] = tag.id }
            var nextTagOrder = (try Int.fetchOne(db, sql: "SELECT MAX(sortOrder) FROM tag") ?? -1) + 1

            for year in years.sorted(by: { $0.year < $1.year }) {
                let first = Day(year: year.year, month: 1, day: 1)!, last = Day(year: year.year, month: 12, day: 31)!
                let limit = throughMonth[year.year] ?? 12

                // Opnieuw importeren: eerst de eerdere historie van dit jaar en de posten weg.
                try db.execute(sql: """
                    DELETE FROM entry WHERE note = ? AND bankTransactionId IS NULL AND day BETWEEN ? AND ?
                    AND accountId IN (SELECT id FROM account WHERE kind = 'betaal')
                    """, arguments: [note, first, last])
                var budgetYear = try BudgetYear.filter(Column("year") == year.year).fetchOne(db) ?? BudgetYear(year: year.year)
                budgetYear.closed = year.year != today.year
                try budgetYear.save(db)
                let yearId = budgetYear.id!
                try db.execute(sql: "DELETE FROM budgetItem WHERE yearId = ?", arguments: [yearId])

                let hasReserveLines = year.items.contains { $0.direction == .RES }
                let reservePlan = year.items.filter { $0.direction == .RES }.map(\.plan).sum()
                var reserveTotalUsed = false
                for (order, source) in year.items.enumerated() {
                    let isReserveTotal = source.isReserveTotal && !reserveTotalUsed
                    if isReserveTotal { reserveTotalUsed = true }
                    var item = BudgetItem(yearId: yearId, label: source.label, direction: source.direction,
                                          planAmount: isReserveTotal && hasReserveLines ? reservePlan : source.plan,
                                          frequency: .maand, isReserveTotal: isReserveTotal, sortOrder: order)
                    try item.insert(db)
                    result.itemCount += 1
                    guard source.direction != .RES else { continue }
                    for (index, amount) in source.monthAmounts.enumerated() where index + 1 <= limit {
                        guard let amount else { continue }
                        var entry = Entry(accountId: accountId, day: Day(year: year.year, month: index + 1, day: 15)!,
                                          amount: amount, label: source.label, budgetItemId: item.id,
                                          reviewed: true, note: note)
                        try entry.insert(db)
                        result.entryCount += 1
                    }
                }

                for source in year.various where source.lastMonth <= limit {
                    var entry = Entry(accountId: accountId, day: source.day, amount: source.amount, label: source.label,
                                      reviewed: true, note: note)
                    try entry.insert(db)
                    result.entryCount += 1
                    var linked: Set<Int64> = []
                    for name in source.tags {
                        let key = name.lowercased()
                        if tagIds[key] == nil {
                            var tag = Tag(name: name, color: tagColors[nextTagOrder % tagColors.count], sortOrder: nextTagOrder)
                            try tag.insert(db)
                            tagIds[key] = tag.id
                            nextTagOrder += 1
                            result.newTagCount += 1
                        }
                        if let tagId = tagIds[key], linked.insert(tagId).inserted {
                            try EntryTag(entryId: entry.id!, tagId: tagId).insert(db)
                        }
                    }
                }
                result.years.append(year.year)
            }
            return .commit
        }
        return result
    }

    // MARK: Spaarrekening

    public static func checkSavings(_ db: Database, savings: HistorySavings, accountId: Int64) throws -> HistorySavingsCheck {
        let account = try savingsAccount(db, accountId)
        var check = HistorySavingsCheck(refusal: nil, newPots: [], replaces: false)
        guard let lastDay = savings.lastDay else {
            check.refusal = HistoryError.nothingToImport.localizedDescription
            return check
        }
        let other = try otherSavingsEntryCount(db, accountId: accountId, upTo: lastDay)
        if other > 0 {
            check.refusal = HistoryError.savingsHasOtherEntries(count: other, lastDay: lastDay).localizedDescription
        }
        let existing = Set(try Pot.filter(Column("accountId") == accountId).fetchAll(db).map { $0.name.lowercased() })
        check.newPots = savings.pots.filter { !$0.movements.isEmpty && !existing.contains($0.name.lowercased()) }.map(\.name)
        check.replaces = (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM entry WHERE accountId = ? AND note = ? AND bankTransactionId IS NULL",
                                           arguments: [accountId, note]) ?? 0) > 0
        check.openingChange = savingsOpeningChange(account: account, savings: savings, keepOldBalance: false)
        return check
    }

    /// Importeert de potmutaties uit het blad RES op een spaarrekening, in één transactie.
    ///
    /// - `allowDifferences`: ook importeren als de som van een pot niet gelijk is aan het saldo in Excel.
    /// - `opening`: wat te doen als het saldo op de oude begindatum van de rekening verandert.
    @discardableResult
    public static func importSavings(_ savings: HistorySavings, into database: AppDatabase, accountId: Int64,
                                     allowDifferences: Bool = false,
                                     opening: HistoryOpeningDecision = .stopIfDifferent) throws -> HistoryImportResult {
        try database.write { db in
            try importSavings(db, savings: savings, accountId: accountId, allowDifferences: allowDifferences, opening: opening)
        }
    }

    @discardableResult
    public static func importSavings(_ db: Database, savings: HistorySavings, accountId: Int64,
                                     allowDifferences: Bool = false,
                                     opening: HistoryOpeningDecision = .stopIfDifferent) throws -> HistoryImportResult {
        var result = HistoryImportResult()
        try db.inSavepoint {
            var account = try savingsAccount(db, accountId)
            guard let lastDay = savings.lastDay else { throw HistoryError.nothingToImport }
            guard savings.totalsMatch || allowDifferences else {
                throw HistoryError.savingsTotalsDiffer(count: savings.differences.count)
            }
            let other = try otherSavingsEntryCount(db, accountId: accountId, upTo: lastDay)
            guard other == 0 else { throw HistoryError.savingsHasOtherEntries(count: other, lastDay: lastDay) }

            if let change = savingsOpeningChange(account: account, savings: savings, keepOldBalance: opening == .keepOldBalance) {
                guard change.difference.isZero || opening != .stopIfDifferent else {
                    throw HistoryError.openingBalanceChanges(change)
                }
                account.openingDate = change.newDate
                account.openingBalance = change.newBalance
                try account.update(db)
                result.openingChange = change
            }

            try db.execute(sql: "DELETE FROM entry WHERE accountId = ? AND note = ? AND bankTransactionId IS NULL",
                           arguments: [accountId, note])

            var pots: [String: Pot] = [:]
            for pot in try Pot.filter(Column("accountId") == accountId).order(Column("id")).fetchAll(db) where pots[pot.name.lowercased()] == nil {
                pots[pot.name.lowercased()] = pot
            }
            var nextOrder = (try Int.fetchOne(db, sql: "SELECT MAX(sortOrder) FROM pot WHERE accountId = ?", arguments: [accountId]) ?? -1) + 1

            for source in savings.pots where !source.movements.isEmpty {
                let key = source.name.lowercased()
                if pots[key] == nil {
                    var pot = Pot(accountId: accountId, name: source.name, kind: .reservering, sortOrder: nextOrder)
                    try pot.insert(db)
                    pots[key] = pot
                    nextOrder += 1
                    result.newPotCount += 1
                }
                let pot = pots[key]!
                for movement in source.movements {
                    var entry = Entry(accountId: accountId, day: movement.day, amount: movement.amount, label: pot.name,
                                      potId: pot.id, reviewed: true, note: note)
                    try entry.insert(db)
                    result.entryCount += 1
                }
            }
            return .commit
        }
        return result
    }

    // MARK: Hulpjes

    private static func checkingAccount(_ db: Database, _ id: Int64) throws -> Account {
        guard let account = try Account.fetchOne(db, key: id) else { throw HistoryError.accountNotFound }
        guard account.kind == .betaal else { throw HistoryError.notACheckingAccount(account.name) }
        return account
    }

    private static func savingsAccount(_ db: Database, _ id: Int64) throws -> Account {
        guard let account = try Account.fetchOne(db, key: id) else { throw HistoryError.accountNotFound }
        guard account.kind == .spaar else { throw HistoryError.notASavingsAccount(account.name) }
        return account
    }

    /// Boekingen in dit jaar die niet uit de historie komen: op een betaalrekening, of op een post van het jaar.
    private static func otherEntryCount(_ db: Database, year: Int) throws -> Int {
        let first = Day(year: year, month: 1, day: 1)!, last = Day(year: year, month: 12, day: 31)!
        return try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM entry
            WHERE (note <> ? OR bankTransactionId IS NOT NULL)
              AND ((day BETWEEN ? AND ? AND accountId IN (SELECT id FROM account WHERE kind = 'betaal'))
                   OR budgetItemId IN (SELECT i.id FROM budgetItem i JOIN budgetYear y ON y.id = i.yearId WHERE y.year = ?))
            """, arguments: [note, first, last, year]) ?? 0
    }

    private static func historyEntryCount(_ db: Database, year: Int) throws -> Int {
        let first = Day(year: year, month: 1, day: 1)!, last = Day(year: year, month: 12, day: 31)!
        return try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM entry WHERE note = ? AND bankTransactionId IS NULL AND day BETWEEN ? AND ?
            AND accountId IN (SELECT id FROM account WHERE kind = 'betaal')
            """, arguments: [note, first, last]) ?? 0
    }

    private static func otherSavingsEntryCount(_ db: Database, accountId: Int64, upTo lastDay: Day) throws -> Int {
        try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM entry WHERE accountId = ? AND day <= ? AND (note <> ? OR bankTransactionId IS NOT NULL)
            """, arguments: [accountId, lastDay, note]) ?? 0
    }

    /// Verschuift de begindatum naar 1 januari van het vroegste jaar als dat vóór de huidige begindatum ligt.
    private static func budgetOpeningChange(account: Account, years: [HistoryYear],
                                            throughMonth: [Int: Int]) throws -> HistoryOpeningChange? {
        guard let first = years.min(by: { $0.year < $1.year }) else { return nil }
        let newDate = Day(year: first.year, month: 1, day: 1)!
        guard newDate < account.openingDate else { return nil }
        guard let opening = first.openingBalance else { throw HistoryError.openingBalanceUnknown(year: first.year) }
        var before = Money.zero
        for year in years {
            let limit = throughMonth[year.year] ?? 12
            for item in year.items {
                for (index, amount) in item.monthAmounts.enumerated() where index + 1 <= limit {
                    if let amount, Day(year: year.year, month: index + 1, day: 15)! < account.openingDate { before += amount }
                }
            }
            before += year.various.filter { $0.lastMonth <= limit && $0.day < account.openingDate }.map(\.amount).sum()
        }
        return HistoryOpeningChange(oldDate: account.openingDate, oldBalance: account.openingBalance,
                                    newDate: newDate, newBalance: opening, balanceAtOldDate: opening + before)
    }

    private static func savingsOpeningChange(account: Account, savings: HistorySavings, keepOldBalance: Bool) -> HistoryOpeningChange? {
        guard let firstDay = savings.firstDay, firstDay < account.openingDate else { return nil }
        let before = savings.pots.flatMap(\.movements).filter { $0.day < account.openingDate }.map(\.amount).sum()
        let newBalance = keepOldBalance ? account.openingBalance - before : .zero
        return HistoryOpeningChange(oldDate: account.openingDate, oldBalance: account.openingBalance,
                                    newDate: firstDay, newBalance: newBalance, balanceAtOldDate: newBalance + before)
    }
}
