import Foundation
import GRDB
import HFCore

/// Iets op het dashboard dat aandacht vraagt.
public enum AttentionItem: Equatable, Sendable {
    /// Banktransacties die nog geboekt moeten worden.
    case newBankTransactions(count: Int)
    /// Boekingen die nog nagekeken moeten worden.
    case unreviewedEntries(count: Int)
    /// Boekingen die nog met spaar verrekend moeten worden: `amount` is het netto over te maken bedrag zonder
    /// teken, `direction` de richting (`.none` = netto nul, alleen tussen potten verrekenen).
    case openReimbursements(amount: Money, count: Int, direction: SavingsTransferDirection)
    /// De laatste afstemming van een rekening sloot niet op € 0,00.
    case reconciliationDiffers(accountId: Int64, accountName: String, difference: Money, day: Day)
    /// De laatste afstemming is ouder dan 35 dagen (`lastDay` nil = nog nooit afgestemd).
    case reconciliationOld(accountId: Int64, accountName: String, lastDay: Day?, daysAgo: Int)
    /// Een afgevinkte verrekening met spaar is na 5 dagen nog niet aan beide kanten in een bankbestand gezien.
    case unconfirmedSettlement(amount: Money, day: Day)
    /// Meer dan één afgevinkte verrekening is nog niet in een bankbestand gezien: aantal, samen (zonder teken) en
    /// de dag van de oudste.
    case unconfirmedSettlements(count: Int, total: Money, oldestDay: Day)
    /// Er is nog geen begroting voor het jaar van vandaag.
    case yearMissing(year: Int)
    /// Er staat nog een bedrag uit dat tijdelijk van spaar geleend is.
    case temporaryLoanOutstanding(amount: Money)
    /// Voor een tag die verrekend wordt staat nog een bedrag open (`amount` = terug te storten, positief).
    case openSettlement(tagId: Int64, tagName: String, amount: Money, count: Int)

    /// Nederlandse tekst voor de gebruiker.
    public var message: String {
        switch self {
        case .newBankTransactions(let n):
            return n == 1 ? "1 banktransactie moet nog geboekt worden." : "\(n) banktransacties moeten nog geboekt worden."
        case .unreviewedEntries(let n):
            return n == 1 ? "1 boeking moet nog nagekeken worden." : "\(n) boekingen moeten nog nagekeken worden."
        case .openReimbursements(let amount, let n, let direction):
            let count = "\(n) \(n == 1 ? "boeking" : "boekingen")"
            switch direction {
            case .fromSavings: return "\(amount.formatted()) over te maken van spaar naar betaal (\(count))."
            case .toSavings: return "\(amount.formatted()) over te maken van betaal naar spaar (\(count))."
            case .none: return "\(count) over te boeken tussen potten."
            }
        case .reconciliationDiffers(_, let name, let difference, let day):
            return "\(name): afstemming van \(day.dutch) heeft een verschil van \(difference.formatted())."
        case .reconciliationOld(_, let name, let lastDay, let days):
            if let lastDay { return "\(name): laatst afgestemd op \(lastDay.dutch) (\(days) dagen geleden)." }
            return "\(name): nog nooit afgestemd."
        case .unconfirmedSettlement(let amount, let day):
            return "Overboeking met spaar van \(amount.formatted()) op \(day.dutch) is nog niet gezien in een bankbestand."
        case .unconfirmedSettlements(let count, let total, let oldest):
            return "\(count) overboekingen met spaar (samen \(total.formatted())) zijn nog niet gezien in een bankbestand, de oudste van \(oldest.dutch)."
        case .yearMissing(let year):
            return "Er is nog geen begroting voor \(year)."
        case .temporaryLoanOutstanding(let amount):
            return "\(amount.formatted()) tijdelijk geleend van spaar staat nog uit."
        case .openSettlement(_, let name, let amount, let n):
            return "Voorgeschoten (\(name)): nog terug te krijgen: \(amount.formatted()) (\(n) \(n == 1 ? "boeking" : "boekingen"))."
        }
    }
}

/// Alles wat het dashboard nodig heeft, in één keer.
public struct Dashboard: Equatable, Sendable {
    public let today: Day
    /// Besteedbaar nu en gesimuleerd tot het eind van de maand; nil als het jaar nog niet bestaat.
    public let spendable: Spendable?
    /// Rekeningen die niet gearchiveerd zijn, met saldo.
    public let accounts: [AccountOverview]
    /// Vaste posten van de lopende maand; nil als het jaar nog niet bestaat.
    public let fixedItems: FixedItemsOverview?
    public let attention: [AttentionItem]
    public let recentEntries: [EntryRow]
    /// IN en UIT van de lopende maand op de betaalrekening(en).
    public let monthIncome: Money
    public let monthExpenses: Money
    /// Plan van de posten die deze maand verwacht worden: de positieve en de negatieve kant.
    public let planIncome: Money
    public let planExpenses: Money
    public let topTags: [TagAmount]

    public var paidCount: Int { fixedItems?.paidCount ?? 0 }
    public var openCount: Int { fixedItems?.openCount ?? 0 }
    public var lateCount: Int { fixedItems?.lateCount ?? 0 }
}

extension Insight {
    /// Aantal dagen waarna een afgevinkte verrekening in een bankbestand gezien hoort te zijn.
    public static let settlementConfirmationDays = 5

    /// Aantal dagen waarna een afstemming als "oud" geldt.
    public static let reconciliationMaxAgeDays = 35

    /// Het dashboard: besteedbaar, saldi, vaste posten van deze maand, aandachtspunten, laatste boekingen,
    /// IN/UIT tegen plan en de grootste tags van deze maand.
    public static func dashboard(_ db: Database, today: Day, recentLimit: Int = 10, tagLimit: Int = 5) throws -> Dashboard {
        let yearExists = try BudgetYear.filter(Column("year") == today.year).fetchCount(db) > 0
        let spendable = yearExists ? try spendable(db, year: today.year, today: today) : nil
        let fixed = yearExists ? try fixedItemsStatus(db, year: today.year, month: today.month, today: today) : nil
        let accounts = try accountOverview(db, today: today).filter { !$0.archived }

        var attention: [AttentionItem] = []
        if !yearExists { attention.append(.yearMissing(year: today.year)) }
        let newCount = accounts.map(\.newBankTransactionCount).reduce(0, +)
        if newCount > 0 { attention.append(.newBankTransactions(count: newCount)) }
        let unreviewed = accounts.map(\.unreviewedEntryCount).reduce(0, +)
        if unreviewed > 0 { attention.append(.unreviewedEntries(count: unreviewed)) }
        let open = try Row.fetchOne(db, sql: """
            SELECT COALESCE(SUM(amount), 0) AS s, COUNT(*) AS c FROM entry
            WHERE reimburse = 1 AND savingsTransferId IS NULL AND accountId IN \(Q.betaal)
            """)!
        if (open["c"] as Int) > 0 {
            let net = -(open["s"] as Money)
            attention.append(.openReimbursements(amount: net.magnitude, count: open["c"],
                                                 direction: SavingsTransferDirection(net: net)))
        }
        // Zoals `SavingsTransferService.unconfirmed`: `settlementConfirmationDays` dagen na het boeken nog geen bankregel.
        let unconfirmed: [(amount: Money, day: Day)] = try savingsTransfers(db).reversed().compactMap { t in
            guard t.done, !t.amount.isZero, let since = t.unconfirmedSince,
                  since.adding(days: settlementConfirmationDays) <= today else { return nil }
            return (t.transferAmount, since)
        }
        if unconfirmed.count == 1, let t = unconfirmed.first {
            attention.append(.unconfirmedSettlement(amount: t.amount, day: t.day))
        } else if let oldest = unconfirmed.map(\.day).min() {
            attention.append(.unconfirmedSettlements(count: unconfirmed.count,
                                                     total: unconfirmed.map(\.amount).sum(), oldestDay: oldest))
        }
        let borrowed = try temporaryLoanOutstanding(db, on: today)
        if !borrowed.isZero { attention.append(.temporaryLoanOutstanding(amount: borrowed)) }
        for s in try settlementOverview(db, today: today) where !s.outstanding.isZero {
            attention.append(.openSettlement(tagId: s.id, tagName: s.name, amount: s.outstanding, count: s.openCount))
        }
        let openingDates = Dictionary(uniqueKeysWithValues: try Row.fetchAll(db, sql: "SELECT id, openingDate FROM account")
            .map { ($0["id"] as Int64, $0["openingDate"] as Day) })
        for a in accounts {
            if let rec = a.lastReconciliation, !rec.difference.isZero {
                attention.append(.reconciliationDiffers(accountId: a.id, accountName: a.name,
                                                        difference: rec.difference, day: rec.day))
            }
            let reference = a.lastReconciliation?.day ?? openingDates[a.id] ?? today
            let age = Q.daysBetween(reference, today)
            if age > reconciliationMaxAgeDays {
                attention.append(.reconciliationOld(accountId: a.id, accountName: a.name,
                                                    lastDay: a.lastReconciliation?.day, daysAgo: age))
            }
        }

        let month = try Row.fetchOne(db, sql: """
            SELECT COALESCE(SUM(CASE WHEN e.amount > 0 THEN e.amount ELSE 0 END), 0) AS pos,
                   COALESCE(SUM(CASE WHEN e.amount < 0 THEN e.amount ELSE 0 END), 0) AS neg
            FROM entry e WHERE e.accountId IN \(Q.betaal) AND \(Q.period) = ?
            """, arguments: [Q.periodKey(today.year, today.month)])!
        let plans = fixed?.items.map(\.plan) ?? []
        return Dashboard(today: today, spendable: spendable, accounts: accounts, fixedItems: fixed,
                         attention: attention, recentEntries: try recentEntries(db, limit: recentLimit),
                         monthIncome: month["pos"], monthExpenses: month["neg"],
                         planIncome: plans.filter { $0 > .zero }.sum(), planExpenses: plans.filter { $0 < .zero }.sum(),
                         topTags: try topTags(db, year: today.year, month: today.month, limit: tagLimit))
    }
}
