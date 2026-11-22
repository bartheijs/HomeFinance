import Foundation
import GRDB
import HFCore

// MARK: - Vaste storting herkennen bij een banktransactie

/// De kant van de overboeking die een banktransactie is.
public enum DistributionSide: String, Equatable, Sendable {
    /// De afschrijving op de betaalrekening (herkomst).
    case source
    /// De bijschrijving op de spaarrekening (doel).
    case destination
}

/// Een banktransactie die bij een vaste storting past.
public struct DistributionMatch: Equatable, Sendable {
    /// De passende storting(en). Meer dan één: de gebruiker kiest (zie `DistributionService.proposal`).
    public var distributions: [Distribution]
    public var side: DistributionSide
    /// Het bedrag van de transactie is precies het totaal van de storting. false bij meer kandidaten.
    public var exactAmount: Bool
    /// Overgeboekt bedrag − totaal van de storting (positief = meer dan de verdeling). Nul bij meer kandidaten.
    public var difference: Money
    /// Kant-en-klare regels. Doelkant: de verdeling over de potten (telt bij een afwijkend bedrag NIET op tot
    /// het bankbedrag). Herkomstkant: één regel op de gekoppelde post, of divers. Leeg bij meer kandidaten.
    public var allocations: [Allocation]
    /// Nederlandse waarschuwing voor de gebruiker, bv. als er geen post gekoppeld is.
    public var warning: String?
    /// Doelkant: het bedrag wijkt zo sterk af van het totaal van de storting (zie
    /// `DistributionService.isFarFromTotal`) dat het lijkt op een losse overboeking. Er is dan géén verdeling
    /// voorgesteld (`allocations` is leeg); de gebruiker kiest één pot, of toch de storting via `proposal`.
    public var looksSeparate: Bool = false

    /// De ene passende storting, of nil als de gebruiker moet kiezen.
    public var distribution: Distribution? { distributions.count == 1 ? distributions[0] : nil }
    public var isAmbiguous: Bool { distributions.count > 1 }

    public init(distributions: [Distribution], side: DistributionSide, exactAmount: Bool, difference: Money,
                allocations: [Allocation], warning: String?, looksSeparate: Bool = false) {
        self.distributions = distributions
        self.side = side
        self.exactAmount = exactAmount
        self.difference = difference
        self.allocations = allocations
        self.warning = warning
        self.looksSeparate = looksSeparate
    }
}

extension DistributionService {
    /// Herkent of een banktransactie bij een (niet-gearchiveerde) vaste storting hoort.
    ///
    /// - Doelkant (bijschrijving op de spaarrekening van de storting): past als de tegenrekening het IBAN van de
    ///   herkomstrekening is, ook bij een afwijkend bedrag. Is er geen herkomst ingesteld of ontbreekt een IBAN,
    ///   dan alleen bij een bedrag dat exact het totaal is.
    /// - Herkomstkant (afschrijving op de herkomstrekening): past als de tegenrekening het IBAN van de
    ///   spaarrekening is. De boeking hoort bij de post die in het jaar van de transactie aan de storting
    ///   gekoppeld is.
    /// - Passen er meer stortingen, dan wint de ene waarvan het totaal gelijk is aan het bedrag; is die er niet
    ///   precies één keer, dan komen alle kandidaten terug en kiest de gebruiker.
    /// - Doelkant met één storting en een bedrag dat sterk afwijkt (`isFarFromTotal`): geen verdeling maar een
    ///   twijfelgeval (`looksSeparate`), want het lijkt een losse overboeking.
    public static func recognize(_ db: Database, bankTransaction: BankTransaction) throws -> DistributionMatch? {
        try recognize(db, bankTransaction, context: try RecognitionContext(db))
    }

    /// `recognize` voor alle transacties met status `nieuw` van een rekening, per transactie-id.
    public static func recognizeAll(_ db: Database, accountId: Int64) throws -> [Int64: DistributionMatch] {
        let context = try RecognitionContext(db)
        let transactions = try BankTransaction.fetchAll(db, sql: """
            SELECT * FROM bankTransaction WHERE accountId = ? AND status = ? ORDER BY day, id
            """, arguments: [accountId, BankTransactionStatus.nieuw])
        var result: [Int64: DistributionMatch] = [:]
        for transaction in transactions {
            if let id = transaction.id, let match = try recognize(db, transaction, context: context) {
                result[id] = match
            }
        }
        return result
    }

    /// Een overgeboekt bedrag wijkt sterk af van het totaal van een vaste storting als het minder dan de helft
    /// of meer dan anderhalf keer dat totaal is. Dan lijkt het een losse overboeking en stelt `recognize` geen
    /// verdeling voor. Bij een totaal van nul of minder is er geen grens.
    public static func isFarFromTotal(_ amount: Money, total: Money) -> Bool {
        guard total > .zero else { return false }
        let amount = amount.magnitude.cents
        return amount * 2 < total.cents || amount * 2 > total.cents * 3
    }

    /// Het voorstel voor één gekozen storting bij een banktransactie (na een keuze uit meer kandidaten).
    /// De kant volgt uit de rekening van de transactie: de spaarrekening van de storting is de doelkant.
    public static func proposal(_ db: Database, distributionId: Int64,
                                for bankTransaction: BankTransaction) throws -> DistributionMatch {
        let distribution = try fetch(db, distributionId)
        let side: DistributionSide = bankTransaction.accountId == distribution.accountId ? .destination : .source
        return try match(db, distribution, side: side, transaction: bankTransaction)
    }

    // MARK: Intern

    private struct RecognitionContext {
        var distributions: [Distribution]
        var totals: [Int64: Money] = [:]
        var accounts: [Int64: Account] = [:]

        init(_ db: Database) throws {
            distributions = try DistributionService.all(db)
            for account in try Account.fetchAll(db) { accounts[account.id!] = account }
            for row in try Row.fetchAll(db, sql: """
                SELECT distributionId, SUM(amount) AS total FROM distributionLine GROUP BY distributionId
                """) {
                totals[row["distributionId"]] = row["total"]
            }
        }

        func iban(_ accountId: Int64?) -> String? {
            guard let accountId, let iban = accounts[accountId]?.iban else { return nil }
            let normalized = AccountService.normalizeIBAN(iban)
            return normalized.isEmpty ? nil : normalized
        }
    }

    private static func recognize(_ db: Database, _ transaction: BankTransaction,
                                  context: RecognitionContext) throws -> DistributionMatch? {
        guard let account = context.accounts[transaction.accountId], !transaction.amount.isZero else { return nil }
        let counterparty = AccountService.normalizeIBAN(transaction.counterpartyIban)
        let side: DistributionSide
        var candidates: [Distribution]
        if account.kind == .spaar, transaction.amount > .zero {
            side = .destination
            candidates = context.distributions.filter { distribution in
                guard distribution.accountId == transaction.accountId else { return false }
                if let source = context.iban(distribution.sourceAccountId), !counterparty.isEmpty {
                    return source == counterparty
                }
                return context.totals[distribution.id!] == transaction.amount
            }
        } else if account.kind == .betaal, transaction.amount.isNegative, !counterparty.isEmpty {
            side = .source
            candidates = context.distributions.filter { distribution in
                distribution.sourceAccountId == transaction.accountId
                    && context.iban(distribution.accountId) == counterparty
            }
        } else {
            return nil
        }
        if candidates.count > 1 {
            let exact = candidates.filter { context.totals[$0.id!] == transaction.amount.magnitude }
            if exact.count == 1 { candidates = exact }
        }
        guard let first = candidates.first else { return nil }
        guard candidates.count == 1 else {
            return DistributionMatch(distributions: candidates, side: side, exactAmount: false, difference: .zero,
                                     allocations: [], warning: "Er passen \(candidates.count) vaste overboekingen bij "
                                        + "deze transactie. Kies welke het is.")
        }
        if side == .destination, let total = context.totals[first.id!],
           isFarFromTotal(transaction.amount, total: total) {
            return DistributionMatch(distributions: [first], side: side, exactAmount: false,
                                     difference: transaction.amount - total, allocations: [],
                                     warning: "Dit lijkt een losse overboeking: \(transaction.amount.formatted()) is "
                                        + "heel anders dan Automatisch sparen: \(first.name) (\(total.formatted())). "
                                        + "Kies één potje, of kies toch de vaste overboeking.",
                                     looksSeparate: true)
        }
        return try match(db, first, side: side, transaction: transaction)
    }

    private static func match(_ db: Database, _ distribution: Distribution, side: DistributionSide,
                              transaction: BankTransaction) throws -> DistributionMatch {
        switch side {
        case .destination:
            let proposal = try allocations(db, distributionId: distribution.id!, for: transaction.amount)
            return DistributionMatch(distributions: [distribution], side: side, exactAmount: proposal.isExact,
                                     difference: proposal.difference, allocations: proposal.allocations,
                                     warning: proposal.isExact ? nil : "Het bedrag wijkt "
                                        + "\(proposal.difference.formatted(alwaysSign: true)) af van Automatisch sparen: "
                                        + "\(distribution.name) (\(proposal.total.formatted())). Kies waar het verschil heen gaat.")
        case .source:
            let total = try self.total(db, distributionId: distribution.id!)
            let difference = transaction.amount.magnitude - total
            let itemId = try Int64.fetchOne(db, sql: """
                SELECT budgetItem.id FROM budgetItem JOIN budgetYear ON budgetYear.id = budgetItem.yearId
                WHERE budgetItem.distributionId = ? AND budgetYear.year = ? ORDER BY budgetItem.sortOrder LIMIT 1
                """, arguments: [distribution.id, transaction.day.year])
            var warnings: [String] = []
            if itemId == nil {
                warnings.append("Er is in \(transaction.day.year) geen post aan Automatisch sparen: \(distribution.name) "
                    + "gekoppeld; de boeking wordt overig.")
            }
            if !difference.isZero {
                warnings.append("Het bedrag wijkt \(difference.formatted(alwaysSign: true)) af van Automatisch sparen: "
                    + "(\(total.formatted())).")
            }
            return DistributionMatch(distributions: [distribution], side: side, exactAmount: difference.isZero,
                                     difference: difference,
                                     allocations: [Allocation(amount: transaction.amount, label: distribution.name,
                                                              budgetItemId: itemId)],
                                     warning: warnings.isEmpty ? nil : warnings.joined(separator: " "))
        }
    }
}

// MARK: - Verwachte bedragen per pot (vooruitblik)

/// Verwachte bedragen bij een pot (gift, bonus, vakantiegeld, of een verwachte uitgave). Ze staan buiten de
/// werkelijkheid: ze tellen nergens in mee behalve in de vooruitblik. Terugkerende stortingen horen hier niet;
/// die volgen uit de vaste stortingen.
public enum ForecastService {
    /// Aantal dagen dat een boeking van de verwachte datum mag afliggen in `suggestRealization`.
    public static let suggestionDays = 45
    /// Hoeveel procent een boeking mag afwijken van het verwachte bedrag in `suggestRealization`.
    public static let suggestionPercent: Int64 = 5

    /// Maakt een verwachting bij een (niet-gearchiveerde) pot. Het bedrag heeft een teken en is niet nul; de
    /// omschrijving mag leeg zijn; een datum in het verleden mag (dan is hij over tijd). `project` groepeert
    /// verwachtingen (bv. een vakantie); het wordt getrimd en leeg betekent geen project.
    @discardableResult
    public static func create(_ db: Database, potId: Int64, day: Day, amount: Money,
                              label: String = "", project: String = "") throws -> ForecastItem {
        try atomic(db) {
            var item = ForecastItem(potId: potId, day: day, amount: amount, label: label, project: project)
            try validate(db, &item)
            try item.insert(db)
            return item
        }
    }

    /// Het hoogste aantal maanden dat `createMonthly` in één keer maakt.
    public static let monthlyLimit = 60

    /// Maakt een verwachting voor elke maand van `first` t/m `last`, steeds op dezelfde dag van de maand (in een
    /// kortere maand de laatste dag). Bijvoorbeeld een treinabonnement elke maand t/m juli. Zonder project krijgen
    /// ze de omschrijving als project, zodat ze samen in één blokje staan. Geen schemawijziging: het zijn gewone
    /// losse verwachtingen, elk apart af te vinken of te wijzigen.
    @discardableResult
    public static func createMonthly(_ db: Database, potId: Int64, first: Day, last: Day, amount: Money,
                                     label: String = "", project: String = "") throws -> [ForecastItem] {
        try atomic(db) {
            guard last >= first else {
                throw BudgetError.validation("De einddatum ligt vóór de eerste datum.")
            }
            let months = (last.year - first.year) * 12 + (last.month - first.month) + 1
            guard months <= monthlyLimit else {
                throw BudgetError.validation("Dat zijn \(months) maanden; het kan tot \(monthlyLimit) maanden in één keer.")
            }
            let trimmedProject = project.trimmingCharacters(in: .whitespaces)
            let group = trimmedProject.isEmpty ? label.trimmingCharacters(in: .whitespaces) : trimmedProject
            var items: [ForecastItem] = []
            for offset in 0..<months {
                let index = first.month - 1 + offset
                let year = first.year + index / 12, month = index % 12 + 1
                var day: Day?
                for d in stride(from: first.day, through: 1, by: -1) {
                    if let found = Day(year: year, month: month, day: d) { day = found; break }
                }
                guard let day, day <= last else { continue }
                var item = ForecastItem(potId: potId, day: day, amount: amount, label: label, project: group)
                try validate(db, &item)
                try item.insert(db)
                items.append(item)
            }
            return items
        }
    }

    /// Werkt pot, datum, bedrag, omschrijving en project bij. Of de verwachting is uitgekomen wijzigt alleen via
    /// `markRealized` en `reopen`.
    @discardableResult
    public static func update(_ db: Database, _ item: ForecastItem) throws -> ForecastItem {
        try atomic(db) {
            guard let id = item.id else { throw BudgetError.validation("Deze verwachting is nog niet opgeslagen.") }
            let existing = try fetch(db, id)
            var item = item
            try validate(db, &item)
            item.realizedEntryId = existing.realizedEntryId
            item.realizedAt = existing.realizedAt
            item.createdAt = existing.createdAt
            try item.update(db)
            return item
        }
    }

    /// Verwijdert een verwachting.
    public static func delete(_ db: Database, forecastItemId: Int64) throws {
        try atomic(db) {
            _ = try fetch(db, forecastItemId)
            try db.execute(sql: "DELETE FROM forecastItem WHERE id = ?", arguments: [forecastItemId])
        }
    }

    /// Markeert een verwachting als uitgekomen en koppelt optioneel de echte boeking. Die boeking staat op de
    /// spaarrekening van de pot en heeft hetzelfde teken; het bedrag mag afwijken. Een boeking hoort bij
    /// hoogstens één verwachting.
    @discardableResult
    public static func markRealized(_ db: Database, forecastItemId: Int64, entryId: Int64? = nil,
                                    at date: Date = Date()) throws -> ForecastItem {
        try atomic(db) {
            var item = try fetch(db, forecastItemId)
            if let entryId {
                let entry = try Check.entry(db, entryId)
                let pot = try Check.pot(db, item.potId)
                guard entry.accountId == pot.accountId else {
                    throw BudgetError.validation("De boeking staat niet op de spaarrekening van het potje \(pot.name).")
                }
                guard entry.amount.isNegative == item.amount.isNegative, !entry.amount.isZero else {
                    throw BudgetError.validation(item.amount.isNegative
                        ? "De verwachting is een uitgave; kies een boeking met een negatief bedrag."
                        : "De verwachting is een bijschrijving; kies een boeking met een positief bedrag.")
                }
                let other = try Int64.fetchOne(db, sql: """
                    SELECT id FROM forecastItem WHERE realizedEntryId = ? AND id <> ?
                    """, arguments: [entryId, forecastItemId])
                guard other == nil else {
                    throw BudgetError.validation("Deze boeking is al aan een andere verwachting gekoppeld.")
                }
            }
            item.realizedEntryId = entryId
            item.realizedAt = date
            try item.update(db)
            return item
        }
    }

    /// Maakt een uitgekomen verwachting weer open en verbreekt de koppeling met de boeking.
    @discardableResult
    public static func reopen(_ db: Database, forecastItemId: Int64) throws -> ForecastItem {
        try atomic(db) {
            var item = try fetch(db, forecastItemId)
            item.realizedEntryId = nil
            item.realizedAt = nil
            try item.update(db)
            return item
        }
    }

    /// Open verwachtingen die bij een boeking kunnen horen: van de pot van die boeking, met hetzelfde teken en
    /// bedrag (exact eerst, daarna binnen 5 % van het verwachte bedrag) en een datum binnen 45 dagen van de
    /// boeking. Leeg als de boeking geen pot heeft.
    public static func suggestRealization(_ db: Database, entryId: Int64) throws -> [ForecastItem] {
        let entry = try Check.entry(db, entryId)
        guard let potId = entry.potId else { return [] }
        func distance(_ item: ForecastItem) -> Int64 { abs(item.amount.cents - entry.amount.cents) }
        return try items(db, potId: potId)
            .filter { item in
                item.amount.isNegative == entry.amount.isNegative
                    && distance(item) * 100 <= abs(item.amount.cents) * suggestionPercent
                    && TransferService.daysApart(item.day, entry.day) <= suggestionDays
            }
            .sorted { a, b in
                (distance(a), TransferService.daysApart(a.day, entry.day), a.id!)
                    < (distance(b), TransferService.daysApart(b.day, entry.day), b.id!)
            }
    }

    /// De verwachtingen van een pot op datum, standaard alleen de open.
    public static func items(_ db: Database, potId: Int64, includeRealized: Bool = false) throws -> [ForecastItem] {
        try ForecastItem.fetchAll(db, sql: """
            SELECT * FROM forecastItem WHERE potId = ? AND (realizedAt IS NULL OR ?) ORDER BY day, id
            """, arguments: [potId, includeRealized])
    }

    private static func fetch(_ db: Database, _ id: Int64) throws -> ForecastItem {
        try Check.fetch(db, ForecastItem.self, id, "Verwachting")
    }

    private static func validate(_ db: Database, _ item: inout ForecastItem) throws {
        let pot = try Check.pot(db, item.potId)
        guard !pot.archived else {
            throw BudgetError.validation("Het potje \(pot.name) is gearchiveerd; daar kan geen verwachting bij.")
        }
        guard !item.amount.isZero else { throw BudgetError.validation("Het verwachte bedrag mag niet nul zijn.") }
        item.label = item.label.trimmingCharacters(in: .whitespacesAndNewlines)
        item.project = item.project.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Hernoemt een project van een pot (ook bij uitgekomen verwachtingen); geeft het aantal gewijzigde
    /// verwachtingen terug. Bestaat `to` al, dan gaan de twee projecten samen. Een lege `to` haalt de
    /// verwachtingen uit het project; een lege `from` wordt geweigerd.
    @discardableResult
    public static func renameProject(_ db: Database, potId: Int64, from: String, to: String) throws -> Int {
        try atomic(db) {
            _ = try Check.pot(db, potId)
            let from = from.trimmingCharacters(in: .whitespacesAndNewlines)
            let to = to.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !from.isEmpty else { throw BudgetError.validation("Geef het project op dat hernoemd moet worden.") }
            try db.execute(sql: "UPDATE forecastItem SET project = ? WHERE potId = ? AND project = ? AND project <> ?",
                           arguments: [to, potId, from, to])
            return db.changesCount
        }
    }

    /// De projecten van een pot (ook van uitgekomen verwachtingen), op naam.
    public static func projects(_ db: Database, potId: Int64) throws -> [String] {
        try String.fetchAll(db, sql: """
            SELECT DISTINCT project FROM forecastItem WHERE potId = ? AND project <> ''
            ORDER BY project COLLATE NOCASE, project
            """, arguments: [potId])
    }
}
