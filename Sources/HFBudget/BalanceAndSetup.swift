import Foundation
import GRDB
import HFCore

// MARK: - Saldo en afstemming

/// Uitkomst van de controle na een import (spec Import, stap 7).
public struct ImportCheck: Equatable, Sendable {
    public var batchId: Int64
    public var accountId: Int64
    /// Aantal transacties van deze import, en hoeveel daarvan nog `nieuw`, `verwerkt` of `overgeslagen` zijn.
    public var transactionCount: Int
    public var newCount: Int
    public var processedCount: Int
    public var skippedCount: Int
    /// De laatste dag van de import (uit de batch, anders uit zijn transacties).
    public var lastDay: Day?
    /// Eindsaldo volgens het bestand, als de bank dat meelevert.
    public var closingBalance: Money?
    /// Berekend saldo van de rekening op `lastDay`.
    public var calculatedBalance: Money?
    /// Transacties van de hele rekening t/m `lastDay` die nog `nieuw` zijn (ook uit eerdere imports).
    public var openUpToLastDay: Int
    /// Overgeslagen transacties van de rekening t/m `lastDay`; die tellen niet mee in het berekende saldo.
    public var skippedUpToLastDay: Int

    /// Elke regel van deze import is verwerkt of overgeslagen.
    public var allHandled: Bool { newCount == 0 }
    /// Berekend − eindsaldo van het bestand; nil als een van beide ontbreekt.
    public var difference: Money? {
        guard let calculatedBalance, let closingBalance else { return nil }
        return calculatedBalance - closingBalance
    }
    /// De saldovergelijking zegt alleen iets als er een eindsaldo is en alles t/m `lastDay` geboekt is.
    public var balanceIsMeaningful: Bool { difference != nil && openUpToLastDay == 0 }
    /// true/false als de vergelijking betekenis heeft, anders nil (nog niet te zeggen).
    public var balanceMatches: Bool? { balanceIsMeaningful ? difference == .zero : nil }

    /// Nederlandse samenvatting voor de gebruiker.
    public var summary: String {
        var lines: [String] = []
        lines.append(newCount == 0
            ? "Alle \(transactionCount) transacties van deze import zijn verwerkt of overgeslagen."
            : "Nog \(newCount) van de \(transactionCount) transacties van deze import zijn niet geboekt.")
        if closingBalance == nil || calculatedBalance == nil {
            lines.append("Het bestand heeft geen eindsaldo; het saldo kan niet gecontroleerd worden.")
        } else if openUpToLastDay > 0 {
            lines.append("Het saldo is nog niet te controleren: \(openUpToLastDay) transactie(s) t/m "
                + "\(lastDay?.dutch ?? "de laatste dag") zijn nog niet geboekt.")
        } else if let difference, difference.isZero {
            lines.append("Het berekende saldo is gelijk aan het eindsaldo van het bestand (\(closingBalance!.formatted())).")
        } else if let difference {
            var line = "Het berekende saldo (\(calculatedBalance!.formatted())) wijkt \(difference.formatted(alwaysSign: true)) "
                + "af van het eindsaldo van het bestand (\(closingBalance!.formatted()))."
            if skippedUpToLastDay > 0 {
                line += " Er zijn \(skippedUpToLastDay) overgeslagen transactie(s); die tellen niet mee in het saldo."
            }
            lines.append(line)
        }
        return lines.joined(separator: " ")
    }
}

/// Saldo van een rekening, afstemming met de bank en de controle na een import.
public enum BalanceService {
    /// Saldo op dag D = beginsaldo + som van de boekingen t/m D.
    public static func balance(_ db: Database, accountId: Int64, on day: Day) throws -> Money {
        let account = try Check.account(db, accountId)
        let sum = try Money.fetchOne(db, sql: """
            SELECT COALESCE(SUM(amount), 0) FROM entry WHERE accountId = ? AND day <= ?
            """, arguments: [accountId, day]) ?? .zero
        return account.openingBalance + sum
    }

    /// Legt een afstemming vast: berekend saldo tegen het werkelijke banksaldo.
    /// `difference` van het resultaat (berekend − werkelijk) hoort € 0,00 te zijn.
    @discardableResult
    public static func reconcile(_ db: Database, accountId: Int64, day: Day,
                                 actualBalance: Money) throws -> Reconciliation {
        try atomic(db) {
            let calculated = try balance(db, accountId: accountId, on: day)
            var reconciliation = Reconciliation(accountId: accountId, day: day, actualBalance: actualBalance,
                                                calculatedBalance: calculated)
            try reconciliation.insert(db)
            return reconciliation
        }
    }

    /// Eerdere afstemmingen van een rekening, nieuwste eerst.
    public static func history(_ db: Database, accountId: Int64) throws -> [Reconciliation] {
        try Reconciliation.fetchAll(db, sql: """
            SELECT * FROM reconciliation WHERE accountId = ? ORDER BY day DESC, id DESC
            """, arguments: [accountId])
    }

    /// Legt automatisch een afstemming vast als een import helemaal verwerkt is en het berekende saldo op de
    /// laatste dag van de import gelijk is aan het eindsaldo van het bestand (`importCheck` zegt dat het
    /// vergelijken zinvol is en dat het klopt). `day` is de laatste dag van de import, `actualBalance` het
    /// eindsaldo van het bestand. Doet niets (nil) als dat niet zo is, of als er voor die rekening op die dag al
    /// een afstemming is: de functie is dus veilig vaker aan te roepen.
    @discardableResult
    public static func autoReconcile(_ db: Database, batchId: Int64) throws -> Reconciliation? {
        try atomic(db) {
            let check = try importCheck(db, batchId: batchId)
            guard check.balanceIsMeaningful, check.balanceMatches == true,
                  let day = check.lastDay, let closing = check.closingBalance else { return nil }
            guard try !isReconciled(db, accountId: check.accountId, day: day) else { return nil }
            return try reconcile(db, accountId: check.accountId, day: day, actualBalance: closing)
        }
    }

    /// `autoReconcile` voor de imports van een rekening, nieuwste eerst (op laatste dag). Stopt bij de eerste
    /// import die al afgestemd is: wat daarvoor lag is dan al gecontroleerd. Geeft de nieuwe afstemmingen terug.
    @discardableResult
    public static func autoReconcileAll(_ db: Database, accountId: Int64) throws -> [Reconciliation] {
        try atomic(db) {
            let batches = try ImportBatch.fetchAll(db, sql: """
                SELECT * FROM importBatch WHERE accountId = ? AND lastDay IS NOT NULL AND closingBalance IS NOT NULL
                ORDER BY lastDay DESC, id DESC
                """, arguments: [accountId])
            var created: [Reconciliation] = []
            for batch in batches {
                guard let day = batch.lastDay, try !isReconciled(db, accountId: accountId, day: day) else { break }
                if let reconciliation = try autoReconcile(db, batchId: batch.id!) { created.append(reconciliation) }
            }
            return created
        }
    }

    private static func isReconciled(_ db: Database, accountId: Int64, day: Day) throws -> Bool {
        try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM reconciliation WHERE accountId = ? AND day = ?)",
                          arguments: [accountId, day]) ?? false
    }

    /// Controle na een import: zijn alle regels verwerkt of overgeslagen, en sluit het saldo?
    public static func importCheck(_ db: Database, batchId: Int64) throws -> ImportCheck {
        let batch = try Check.fetch(db, ImportBatch.self, batchId, "Import")
        func count(_ status: BankTransactionStatus) throws -> Int {
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM bankTransaction WHERE batchId = ? AND status = ?",
                             arguments: [batchId, status]) ?? 0
        }
        let new = try count(.nieuw), processed = try count(.verwerkt), skipped = try count(.overgeslagen)
        let lastDay = try batch.lastDay
            ?? Day.fetchOne(db, sql: "SELECT MAX(day) FROM bankTransaction WHERE batchId = ?", arguments: [batchId])
        var check = ImportCheck(batchId: batchId, accountId: batch.accountId,
                                transactionCount: new + processed + skipped, newCount: new,
                                processedCount: processed, skippedCount: skipped, lastDay: lastDay,
                                closingBalance: batch.closingBalance, calculatedBalance: nil,
                                openUpToLastDay: new, skippedUpToLastDay: skipped)
        if let lastDay {
            func upTo(_ status: BankTransactionStatus) throws -> Int {
                try Int.fetchOne(db, sql: """
                    SELECT COUNT(*) FROM bankTransaction WHERE accountId = ? AND status = ? AND day <= ?
                    """, arguments: [batch.accountId, status, lastDay]) ?? 0
            }
            check.calculatedBalance = try balance(db, accountId: batch.accountId, on: lastDay)
            check.openUpToLastDay = try upTo(.nieuw)
            check.skippedUpToLastDay = try upTo(.overgeslagen)
        }
        return check
    }
}

// MARK: - Jaar en posten

/// Uitkomst van `YearService.applyScenario`.
public struct ScenarioApplyResult: Equatable, Sendable {
    /// Aantal posten waarvan het wat-als-bedrag het plan is geworden.
    public var appliedCount: Int
    /// Posten met een wat-als-bedrag dat niet is toegepast, omdat hun plan berekend wordt.
    public var skipped: [BudgetItem]
}

/// Begrotingsjaren en vaste posten beheren.
public enum YearService {
    /// Maakt een leeg begrotingsjaar met zijn buffers.
    @discardableResult
    public static func createYear(_ db: Database, year: Int, antiRood: Money = .zero,
                                  tijdelijkAntiRood: Money = .zero) throws -> BudgetYear {
        // `tijdelijkAntiRood` wordt niet meer gebruikt (volgt uit boekingen met `temporaryLoan`); de parameter
        // blijft voor bestaande aanroepen.
        try atomic(db) {
            guard (1900...2200).contains(year) else { throw BudgetError.validation("\(year) is geen geldig jaar.") }
            let exists = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM budgetYear WHERE year = ?)",
                                           arguments: [year]) ?? false
            guard !exists else { throw BudgetError.yearExists(year) }
            try validateBuffers(antiRood, tijdelijkAntiRood)
            var record = BudgetYear(year: year, antiRood: antiRood, tijdelijkAntiRood: tijdelijkAntiRood)
            try record.insert(db)
            return record
        }
    }

    /// Maakt een nieuw jaar als kopie van een bestaand jaar: de buffers en alle posten (label, richting, plan,
    /// frequentie, verwachte maanden en dag, vlaggen, potkoppeling, koppeling met een vaste storting, volgorde).
    /// Boekingen en vinkjes gaan niet mee. Het plan van gekoppelde posten volgt het huidige totaal van de storting.
    @discardableResult
    public static func createYear(_ db: Database, year: Int, copyingFrom sourceYear: Int) throws -> BudgetYear {
        try atomic(db) {
            let source = try Check.budgetYear(db, year: sourceYear)
            let target = try createYear(db, year: year, antiRood: source.antiRood,
                                        tijdelijkAntiRood: source.tijdelijkAntiRood)
            let items = try BudgetItem.fetchAll(db, sql: "SELECT * FROM budgetItem WHERE yearId = ? ORDER BY sortOrder, id",
                                                arguments: [source.id])
            for var item in items {
                item.id = nil
                item.yearId = target.id!
                item.scenarioAmount = nil   // wat-als-bedragen gaan niet mee naar een nieuw jaar
                try item.insert(db)
            }
            try syncReserveTotal(db, yearId: target.id!)
            return target
        }
    }

    /// Werkt de buffers van een (niet afgesloten) jaar bij.
    @discardableResult
    public static func updateBuffers(_ db: Database, year: Int, antiRood: Money,
                                     tijdelijkAntiRood: Money) throws -> BudgetYear {
        try atomic(db) {
            var record = try Check.budgetYear(db, year: year)
            guard !record.closed else { throw BudgetError.yearClosed(year) }
            try validateBuffers(antiRood, tijdelijkAntiRood)
            record.antiRood = antiRood; record.tijdelijkAntiRood = tijdelijkAntiRood
            try record.update(db)
            return record
        }
    }

    /// Sluit een jaar af: boekingen en posten van dat jaar zijn daarna alleen-lezen.
    public static func closeYear(_ db: Database, year: Int) throws { try setClosed(db, year, true) }

    /// Heropent een afgesloten jaar.
    public static func reopenYear(_ db: Database, year: Int) throws { try setClosed(db, year, false) }

    // MARK: Posten

    /// Maakt een vaste post; komt achteraan in de volgorde. Het plan van de regel RESERVERINGEN wordt berekend.
    @discardableResult
    public static func createItem(_ db: Database, _ item: BudgetItem) throws -> BudgetItem {
        try atomic(db) {
            var item = item
            item.id = nil
            item.scenarioAmount = nil
            try validate(db, &item)
            item.sortOrder = try Check.nextSortOrder(db, table: "budgetItem", whereSQL: "yearId = ?",
                                                     arguments: [item.yearId])
            try item.insert(db)
            try syncReserveTotal(db, yearId: item.yearId)
            return try Check.item(db, item.id!)
        }
    }

    /// Werkt een vaste post bij (niet het jaar of de volgorde). Is de post aan een vaste storting gekoppeld
    /// (`distributionId`), dan wordt een zelf ingevuld plan niet geweigerd maar overschreven met − het totaal
    /// van de storting.
    @discardableResult
    public static func updateItem(_ db: Database, _ item: BudgetItem) throws -> BudgetItem {
        try atomic(db) {
            guard let id = item.id else { throw BudgetError.validation("Deze post is nog niet opgeslagen.") }
            let existing = try Check.item(db, id)
            var item = item
            guard item.yearId == existing.yearId else {
                throw BudgetError.validation("Een post kan niet naar een ander jaar verhuizen.")
            }
            try validate(db, &item)
            if item.direction == .RES, existing.direction != .RES {
                let count = try entryCount(db, itemId: id)
                guard count == 0 else { throw BudgetError.itemHasEntries(item: existing.label, count: count) }
            }
            item.sortOrder = existing.sortOrder
            // Het wat-als-bedrag wijzigt alleen via `setScenario`; bij een andere richting vervalt het.
            item.scenarioAmount = item.direction == existing.direction ? existing.scenarioAmount : nil
            try item.update(db)
            try syncReserveTotal(db, yearId: item.yearId)
            return try Check.item(db, id)
        }
    }

    /// Verwijdert een vaste post. Heeft de post boekingen, dan alleen met `convertEntriesToDivers: true`;
    /// die boekingen blijven staan en worden "divers".
    public static func deleteItem(_ db: Database, itemId: Int64, convertEntriesToDivers: Bool = false) throws {
        try atomic(db) {
            let item = try Check.item(db, itemId)
            try Check.yearOpen(db, yearId: item.yearId)
            let count = try entryCount(db, itemId: itemId)
            guard count == 0 || convertEntriesToDivers else {
                throw BudgetError.itemHasEntries(item: item.label, count: count)
            }
            try db.execute(sql: "UPDATE entry SET budgetItemId = NULL WHERE budgetItemId = ?", arguments: [itemId])
            try db.execute(sql: "DELETE FROM budgetItem WHERE id = ?", arguments: [itemId])
            try syncReserveTotal(db, yearId: item.yearId)
        }
    }

    // MARK: Wat-als

    /// Zet het wat-als-bedrag van een post (nil = wissen). Zelfde tekenregels als het plan (IN ≥ 0, UIT ≤ 0);
    /// niet voor reserveringsregels (RES). Een post met een vaste storting mag een wat-als-bedrag hebben; zijn
    /// plan blijft de storting volgen. Geweigerd in een afgesloten jaar.
    @discardableResult
    public static func setScenario(_ db: Database, itemId: Int64, amount: Money?) throws -> BudgetItem {
        try atomic(db) {
            let item = try Check.item(db, itemId)
            try Check.yearOpen(db, yearId: item.yearId)
            if let amount {
                switch item.direction {
                case .RES:
                    throw BudgetError.validation("De reserveringsregel \(item.label) kan geen wat-als-bedrag hebben.")
                case .IN: guard !amount.isNegative else { throw BudgetError.signMismatch(direction: .IN) }
                case .UIT: guard amount <= .zero else { throw BudgetError.signMismatch(direction: .UIT) }
                }
            }
            try db.execute(sql: "UPDATE budgetItem SET scenarioAmount = ? WHERE id = ?", arguments: [amount, itemId])
            return try Check.item(db, itemId)
        }
    }

    /// Wist alle wat-als-bedragen van een jaar; geeft het aantal gewiste bedragen terug.
    @discardableResult
    public static func clearScenario(_ db: Database, yearId: Int64) throws -> Int {
        try atomic(db) {
            try Check.yearOpen(db, yearId: yearId)
            try db.execute(sql: """
                UPDATE budgetItem SET scenarioAmount = NULL WHERE yearId = ? AND scenarioAmount IS NOT NULL
                """, arguments: [yearId])
            return db.changesCount
        }
    }

    /// Maakt van elk ingevuld wat-als-bedrag het planbedrag en wist daarna alle wat-als-bedragen van het jaar.
    /// Posten waarvan het plan berekend wordt (gekoppeld aan een vaste storting, of de regel RESERVERINGEN)
    /// worden overgeslagen en staan in `skipped`, met het niet toegepaste bedrag nog in `scenarioAmount`.
    @discardableResult
    public static func applyScenario(_ db: Database, yearId: Int64) throws -> ScenarioApplyResult {
        try atomic(db) {
            try Check.yearOpen(db, yearId: yearId)
            let items = try BudgetItem.fetchAll(db, sql: """
                SELECT * FROM budgetItem WHERE yearId = ? AND scenarioAmount IS NOT NULL ORDER BY sortOrder, id
                """, arguments: [yearId])
            let skipped = items.filter { $0.distributionId != nil || $0.isReserveTotal }
            try db.execute(sql: """
                UPDATE budgetItem SET planAmount = scenarioAmount
                WHERE yearId = ? AND scenarioAmount IS NOT NULL AND distributionId IS NULL AND isReserveTotal = 0
                """, arguments: [yearId])
            let applied = db.changesCount
            try db.execute(sql: "UPDATE budgetItem SET scenarioAmount = NULL WHERE yearId = ?", arguments: [yearId])
            try syncReserveTotal(db, yearId: yearId)
            return ScenarioApplyResult(appliedCount: applied, skipped: skipped)
        }
    }

    /// Zet de posten van een jaar in de gegeven volgorde (alle post-id's van dat jaar).
    public static func reorderItems(_ db: Database, yearId: Int64, orderedIds: [Int64]) throws {
        try atomic(db) {
            try Check.yearOpen(db, yearId: yearId)
            let existing = try Int64.fetchAll(db, sql: "SELECT id FROM budgetItem WHERE yearId = ?", arguments: [yearId])
            try Check.reorder(db, table: "budgetItem", existingIds: existing, orderedIds: orderedIds)
        }
    }

    // MARK: Intern

    private static func setClosed(_ db: Database, _ year: Int, _ closed: Bool) throws {
        try atomic(db) {
            _ = try Check.budgetYear(db, year: year)
            try db.execute(sql: "UPDATE budgetYear SET closed = ? WHERE year = ?", arguments: [closed, year])
        }
    }

    private static func validateBuffers(_ antiRood: Money, _ tijdelijk: Money) throws {
        guard !antiRood.isNegative, !tijdelijk.isNegative else {
            throw BudgetError.validation("De buffers (minimaal op je betaalrekening) mogen niet negatief zijn.")
        }
    }

    private static func entryCount(_ db: Database, itemId: Int64) throws -> Int {
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM entry WHERE budgetItemId = ?", arguments: [itemId]) ?? 0
    }

    private static func validate(_ db: Database, _ item: inout BudgetItem) throws {
        let year = try Check.yearOpen(db, yearId: item.yearId)
        item.label = try Check.nonEmpty(item.label, "Het label van de post")
        if item.isReserveTotal {
            guard item.direction == .UIT else {
                throw BudgetError.validation("De regel RESERVERINGEN moet een UIT-post zijn.")
            }
            let other = try Int64.fetchOne(db, sql: """
                SELECT id FROM budgetItem WHERE yearId = ? AND isReserveTotal = 1 AND id IS NOT ?
                """, arguments: [item.yearId, item.id])
            guard other == nil else { throw BudgetError.reserveTotalExists(year: year.year) }
        }
        if let distributionId = item.distributionId {
            guard item.direction == .UIT else {
                throw BudgetError.validation("Alleen een UIT-post kan aan een vaste overboeking gekoppeld zijn.")
            }
            // Het plan van een gekoppelde post volgt de storting; een zelf ingevuld plan wordt overschreven.
            item.planAmount = -(try DistributionService.total(db, distributionId: distributionId))
        }
        switch item.direction {
        case .IN: guard !item.planAmount.isNegative else { throw BudgetError.signMismatch(direction: .IN) }
        case .UIT, .RES:
            guard item.planAmount <= .zero else { throw BudgetError.signMismatch(direction: item.direction) }
        }
        switch item.frequency {
        case .maand:
            item.expectedMonths = ""
        case .kwartaal, .jaar:
            let parts = item.expectedMonths.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            let months = parts.compactMap { Int($0) }
            guard !months.isEmpty, months.count == parts.count, months.allSatisfy({ (1...12).contains($0) }) else {
                throw BudgetError.validation("Geef bij een kwartaal- of jaarpost de verwachte maanden op (1 t/m 12).")
            }
            item.expectedMonths = Array(Set(months)).sorted().map(String.init).joined(separator: ",")
        }
        if let day = item.expectedDay, !(1...31).contains(day) {
            throw BudgetError.validation("De verwachte dag moet tussen 1 en 31 liggen.")
        }
        if let potId = item.potId { _ = try Check.pot(db, potId) }
    }

    /// Houdt het plan van de regel RESERVERINGEN gelijk aan de som van het plan van alle RES-regels, en het
    /// plan van posten met een vaste storting gelijk aan − het totaal van die storting (de storting gaat voor).
    static func syncReserveTotal(_ db: Database, yearId: Int64) throws {
        try db.execute(sql: """
            UPDATE budgetItem SET planAmount =
                (SELECT COALESCE(SUM(planAmount), 0) FROM budgetItem WHERE yearId = ? AND direction = ?)
            WHERE yearId = ? AND isReserveTotal = 1 AND distributionId IS NULL
            """, arguments: [yearId, Direction.RES, yearId])
        try DistributionService.syncLinkedPlans(db, yearId: yearId)
    }
}

// MARK: - Rekeningen

/// Rekeningen beheren.
public enum AccountService {
    /// IBAN zonder spaties en in hoofdletters.
    public static func normalizeIBAN(_ iban: String) -> String {
        iban.uppercased().filter { !$0.isWhitespace }
    }

    /// Maakt een rekening; het IBAN wordt genormaliseerd en moet uniek zijn. Komt achteraan in de volgorde.
    @discardableResult
    public static func create(_ db: Database, _ account: Account) throws -> Account {
        try atomic(db) {
            var account = account
            account.id = nil
            try validate(db, &account)
            account.sortOrder = try Check.nextSortOrder(db, table: "account")
            try account.insert(db)
            return account
        }
    }

    /// Werkt een rekening bij (niet de volgorde of archivering). Het soort kan niet meer wijzigen zodra de
    /// rekening boekingen of potten heeft; de begindatum mag niet ná een bestaande boeking komen te liggen.
    @discardableResult
    public static func update(_ db: Database, _ account: Account) throws -> Account {
        try atomic(db) {
            guard let id = account.id else { throw BudgetError.validation("Deze rekening is nog niet opgeslagen.") }
            let existing = try Check.account(db, id)
            var account = account
            try validate(db, &account)
            if account.kind != existing.kind, try usage(db, id, tables: ["entry", "pot"]) > 0 {
                throw BudgetError.validation("Het soort rekening kan niet meer wijzigen: \(existing.name) heeft al boekingen of potjes.")
            }
            let earlier = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM entry WHERE accountId = ? AND day < ?",
                                           arguments: [id, account.openingDate]) ?? 0
            guard earlier == 0 else {
                throw BudgetError.validation("Er zijn \(earlier) boeking(en) vóór \(account.openingDate.dutch); de begindatum kan niet later.")
            }
            account.sortOrder = existing.sortOrder
            account.archived = existing.archived
            try account.update(db)
            return account
        }
    }

    /// Verwijdert een rekening die nog nergens gebruikt wordt; anders archiveren.
    public static func delete(_ db: Database, accountId: Int64) throws {
        try atomic(db) {
            let account = try Check.account(db, accountId)
            guard try usage(db, accountId, tables: ["entry", "bankTransaction", "pot", "importBatch"]) == 0 else {
                throw BudgetError.accountInUse(account: account.name)
            }
            try db.execute(sql: "DELETE FROM account WHERE id = ?", arguments: [accountId])
        }
    }

    /// Zet het beginsaldo van een spaarrekening op het NIET toegewezen deel: het werkelijke beginsaldo van de
    /// bank (`totalOpening`) min de beginboekingen van de potten. Die beginboekingen tellen zelf al mee in het
    /// rekeningsaldo, dus zo blijft het saldo gelijk aan de bank. Zie `PotService.openingSummary`.
    @discardableResult
    public static func setOpeningFromPots(_ db: Database, accountId: Int64, totalOpening: Money) throws -> Account {
        try atomic(db) {
            var account = try Check.account(db, accountId)
            let summary = try PotService.openingSummary(db, accountId: accountId)
            account.openingBalance = totalOpening - summary.potTotal
            try account.update(db)
            return account
        }
    }

    /// Archiveert een rekening of haalt hem terug.
    public static func setArchived(_ db: Database, accountId: Int64, _ archived: Bool) throws {
        try atomic(db) {
            _ = try Check.account(db, accountId)
            try db.execute(sql: "UPDATE account SET archived = ? WHERE id = ?", arguments: [archived, accountId])
        }
    }

    /// Zet de rekeningen in de gegeven volgorde (alle rekening-id's).
    public static func reorder(_ db: Database, orderedIds: [Int64]) throws {
        try atomic(db) {
            try Check.reorder(db, table: "account", existingIds: try Int64.fetchAll(db, sql: "SELECT id FROM account"),
                              orderedIds: orderedIds)
        }
    }

    private static func usage(_ db: Database, _ accountId: Int64, tables: [String]) throws -> Int {
        try tables.reduce(0) { total, table in
            try total + (Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table) WHERE accountId = ?",
                                      arguments: [accountId]) ?? 0)
        }
    }

    private static func validate(_ db: Database, _ account: inout Account) throws {
        account.name = try Check.nonEmpty(account.name, "De naam van de rekening")
        let iban = account.iban.map(normalizeIBAN) ?? ""
        account.iban = iban.isEmpty ? nil : iban
        if let iban = account.iban {
            guard (15...34).contains(iban.count), iban.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else {
                throw BudgetError.validation("'\(iban)' is geen geldig IBAN.")
            }
            let other = try Int64.fetchOne(db, sql: "SELECT id FROM account WHERE iban = ? AND id IS NOT ?",
                                           arguments: [iban, account.id])
            guard other == nil else { throw BudgetError.duplicateIban(iban) }
        }
    }
}

// MARK: - Tags

/// Tags (trackingcategorieën) beheren.
public enum TagService {
    /// Maakt een tag met een unieke naam; komt achteraan in de volgorde.
    @discardableResult
    public static func create(_ db: Database, name: String, color: String = "#888888") throws -> Tag {
        try atomic(db) {
            var tag = Tag(name: name, color: color)
            try validate(db, &tag)
            tag.sortOrder = try Check.nextSortOrder(db, table: "tag")
            try tag.insert(db)
            return tag
        }
    }

    /// Werkt naam en kleur van een tag bij. `settles` wijzigt alleen via `SettlementService`.
    @discardableResult
    public static func update(_ db: Database, _ tag: Tag) throws -> Tag {
        try atomic(db) {
            guard let id = tag.id else { throw BudgetError.validation("Deze tag is nog niet opgeslagen.") }
            let existing = try Check.tag(db, id)
            var tag = tag
            try validate(db, &tag)
            tag.sortOrder = existing.sortOrder
            tag.settles = existing.settles   // alleen via SettlementService.enable/disable
            tag.startAmount = existing.startAmount   // alleen via SettlementService.setStart
            tag.startDay = existing.startDay
            tag.startSettlementId = existing.startSettlementId
            tag.countsInSpendable = existing.countsInSpendable   // alleen via setCountsInSpendable
            try tag.update(db)
            return tag
        }
    }

    /// Zet "telt mee in nog te besteden" aan of uit. Staat het aan (en verrekent de tag), dan telt het openstaande
    /// bedrag van de tag mee als verwachte inkomst in `Insight.spendable`. Kan ook als verrekenen uit staat; het
    /// telt dan pas mee zodra verrekenen weer aan gaat.
    @discardableResult
    public static func setCountsInSpendable(_ db: Database, tagId: Int64, _ on: Bool) throws -> Tag {
        try atomic(db) {
            var tag = try Check.tag(db, tagId)
            tag.countsInSpendable = on
            try tag.update(db)
            return tag
        }
    }

    /// Verwijdert een tag; hij verdwijnt ook van alle boekingen. Geweigerd als de tag verrekeningen heeft
    /// (echte verrekeningen, of een beginstand met boekingen): anders zou die historie stil verdwijnen.
    /// Een lege beginstand (verrekenen aangezet zonder dat er iets verrekend is) houdt het verwijderen niet tegen.
    public static func delete(_ db: Database, tagId: Int64) throws {
        try atomic(db) {
            let tag = try Check.tag(db, tagId)
            let settlements = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM settlement
                WHERE tagId = ? AND (isOpening = 0 OR EXISTS (SELECT 1 FROM entry WHERE entry.settlementId = settlement.id))
                """, arguments: [tagId]) ?? 0
            guard settlements == 0 else { throw BudgetError.tagHasSettlements(tag: tag.name, count: settlements) }
            try db.execute(sql: "DELETE FROM tag WHERE id = ?", arguments: [tagId])
        }
    }

    /// Zet de tags in de gegeven volgorde (alle tag-id's).
    public static func reorder(_ db: Database, orderedIds: [Int64]) throws {
        try atomic(db) {
            try Check.reorder(db, table: "tag", existingIds: try Int64.fetchAll(db, sql: "SELECT id FROM tag"),
                              orderedIds: orderedIds)
        }
    }

    private static func validate(_ db: Database, _ tag: inout Tag) throws {
        tag.name = try Check.nonEmpty(tag.name, "De naam van de tag")
        let other = try Int64.fetchOne(db, sql: "SELECT id FROM tag WHERE name = ? COLLATE NOCASE AND id IS NOT ?",
                                       arguments: [tag.name, tag.id])
        guard other == nil else { throw BudgetError.duplicateName(tag.name) }
        let hex = tag.color.uppercased()
        guard hex.count == 7, hex.hasPrefix("#"), hex.dropFirst().allSatisfy({ $0.isHexDigit }) else {
            throw BudgetError.validation("De kleur moet de vorm #RRGGBB hebben.")
        }
        tag.color = hex
    }
}
