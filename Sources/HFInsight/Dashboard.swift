import Foundation
import GRDB
import HFCore

/// Iets op het dashboard dat aandacht vraagt.
public enum AttentionItem: Equatable, Sendable {
    /// Banktransacties die nog geboekt moeten worden.
    case newBankTransactions(count: Int)
    /// Boekingen die nog nagekeken moeten worden.
    case unreviewedEntries(count: Int)
    /// Uitgaven die nog uit spaar vergoed moeten worden (`amount` = over te boeken, positief).
    case openReimbursements(amount: Money, count: Int)
    /// De laatste afstemming van een rekening sloot niet op € 0,00.
    case reconciliationDiffers(accountId: Int64, accountName: String, difference: Money, day: Day)
    /// De laatste afstemming is ouder dan 35 dagen (`lastDay` nil = nog nooit afgestemd).
    case reconciliationOld(accountId: Int64, accountName: String, lastDay: Day?, daysAgo: Int)
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
        case .openReimbursements(let amount, let n):
            return "\(amount.formatted()) nog over te boeken van spaar (\(n) \(n == 1 ? "uitgave" : "uitgaven"))."
        case .reconciliationDiffers(_, let name, let difference, let day):
            return "\(name): afstemming van \(day.dutch) heeft een verschil van \(difference.formatted())."
        case .reconciliationOld(_, let name, let lastDay, let days):
            if let lastDay { return "\(name): laatst afgestemd op \(lastDay.dutch) (\(days) dagen geleden)." }
            return "\(name): nog nooit afgestemd."
        case .yearMissing(let year):
            return "Er is nog geen begroting voor \(year)."
        case .temporaryLoanOutstanding(let amount):
            return "\(amount.formatted()) tijdelijk geleend van spaar staat nog uit."
        case .openSettlement(_, let name, let amount, let n):
            return "\(amount.formatted()) \(name) nog terug te storten (\(n) \(n == 1 ? "boeking" : "boekingen"))."
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
            SELECT COALESCE(SUM(amount), 0) AS s, COUNT(*) AS c FROM entry WHERE reimburse = 1 AND savingsTransferId IS NULL
            """)!
        if (open["c"] as Int) > 0 {
            attention.append(.openReimbursements(amount: -(open["s"] as Money), count: open["c"]))
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
            FROM entry e WHERE e.accountId IN \(Q.betaal) AND e.day >= ? AND e.day <= ?
            """, arguments: [Q.monthStart(today.year, today.month), Q.monthEnd(today.year, today.month)])!
        let plans = fixed?.items.map(\.plan) ?? []
        return Dashboard(today: today, spendable: spendable, accounts: accounts, fixedItems: fixed,
                         attention: attention, recentEntries: try recentEntries(db, limit: recentLimit),
                         monthIncome: month["pos"], monthExpenses: month["neg"],
                         planIncome: plans.filter { $0 > .zero }.sum(), planExpenses: plans.filter { $0 < .zero }.sum(),
                         topTags: try topTags(db, year: today.year, month: today.month, limit: tagLimit))
    }
}
