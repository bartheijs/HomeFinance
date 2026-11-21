import Foundation
import GRDB
import HFCore

/// Een banktransactie die nog wacht om geboekt te worden en lijkt te passen bij een vaste post die te laat is.
public struct WaitingCandidate: Identifiable, Equatable, Sendable {
    /// Id van de banktransactie.
    public let id: Int64
    public let accountId: Int64
    public let day: Day
    public let amount: Money
    public let counterpartyName: String
    public let reason: Reason

    /// Waarom de transactie lijkt te passen (sterkste reden eerst).
    public enum Reason: Int, Comparable, Sendable {
        /// Een regel stelt deze post voor.
        case rule = 0
        /// Dezelfde tegenrekening als eerdere boekingen op deze post.
        case sameCounterparty = 1
        /// Precies het geplande bedrag.
        case sameAmount = 2
        public static func < (l: Reason, r: Reason) -> Bool { l.rawValue < r.rawValue }
    }
}

extension Insight {
    /// Wachtende banktransacties (status `nieuw`, op een betaalrekening) die lijken te passen bij een vaste post in
    /// een maand: met dezelfde richting als het plan, gedateerd van 7 dagen vóór de maand t/m het eind van de maand,
    /// en met een regel die deze post voorstelt (`suggestedItems`: transactie-id → post-id, van de regels), dezelfde
    /// tegenrekening als eerdere boekingen op de post, of precies het geplande bedrag. Sterkste reden eerst, daarna
    /// op datum. Alleen bedoeld voor het celvenster van het maandgrid; leest, schrijft niets.
    public static func waitingCandidates(_ db: Database, itemId: Int64, year: Int, month: Int, plan: Money,
                                         suggestedItems: [Int64: Int64] = [:], limit: Int = 3) throws -> [WaitingCandidate] {
        guard !plan.isZero, let first = Day(year: year, month: month, day: 1) else { return [] }
        let next = month == 12 ? Day(year: year + 1, month: 1, day: 1)! : Day(year: year, month: month + 1, day: 1)!
        let from = first.adding(days: -7)
        let ibans = Set(try String.fetchAll(db, sql: """
            SELECT DISTINCT b.counterpartyIban FROM entry e JOIN bankTransaction b ON b.id = e.bankTransactionId
            WHERE e.budgetItemId IN (SELECT id FROM budgetItem WHERE label = (SELECT label FROM budgetItem WHERE id = ?))
              AND b.counterpartyIban <> ''
            """, arguments: [itemId]))
        let rows = try BankTransaction.fetchAll(db, sql: """
            SELECT * FROM bankTransaction
            WHERE status = 'nieuw' AND accountId IN \(Q.betaal) AND day >= ? AND day < ?
              AND ((amount < 0) = ?)
            ORDER BY day, id
            """, arguments: [from, next, plan.isNegative])
        let found: [WaitingCandidate] = rows.compactMap { tx in
            guard let id = tx.id else { return nil }
            let reason: WaitingCandidate.Reason
            if suggestedItems[id] == itemId { reason = .rule }
            else if ibans.contains(tx.counterpartyIban) { reason = .sameCounterparty }
            else if tx.amount == plan { reason = .sameAmount }
            else { return nil }
            return WaitingCandidate(id: id, accountId: tx.accountId, day: tx.day, amount: tx.amount,
                                    counterpartyName: tx.counterpartyName, reason: reason)
        }
        return Array(found.enumerated().sorted { a, b in
            a.element.reason != b.element.reason ? a.element.reason < b.element.reason : a.offset < b.offset
        }.map(\.element).prefix(limit))
    }
}

extension FixedItemsOverview {
    /// Bijvoorbeeld "5 van 15 voldaan · 3 te laat", of "5 van 15 voldaan" als er niets te laat is.
    public var summaryLine: String {
        let base = "\(paidCount) van \(items.count) voldaan"
        return lateCount > 0 ? "\(base) · \(lateCount) te laat" : base
    }
}
