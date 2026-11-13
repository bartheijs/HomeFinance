import Foundation
import GRDB
import HFCore
import HFInsight

/// De cijfers op de pagina voor de telefoon: een kleine momentopname, gelezen via `HFInsight`.
public struct PhoneSnapshot: Equatable, Sendable {
    public struct AccountLine: Equatable, Sendable {
        public let name: String
        public let kind: AccountKind
        public let balance: Money
    }

    /// Uitgaven van de lopende maand tegen het plan van de posten die deze maand verwacht worden.
    public struct MonthSpending: Equatable, Sendable {
        public let month: Int
        /// Negatief (uitgaven).
        public let expenses: Money
        /// Negatief; nul als er niets gepland is.
        public let planExpenses: Money
        /// Uitgegeven als percentage van het plan, afgerond; nil zonder plan.
        public let percent: Int?
    }

    public struct LateItem: Equatable, Sendable {
        public let label: String
        public let plan: Money
    }

    public struct FixedItems: Equatable, Sendable {
        public let paidCount: Int
        public let openCount: Int
        public let lateCount: Int
        public let late: [LateItem]
    }

    public struct TrendPoint: Equatable, Sendable {
        public let day: Day
        public let spendable: Money
    }

    /// Alles wat een begrotingsjaar nodig heeft.
    public struct Budget: Equatable, Sendable {
        public let spendable: Money
        public let spendableEndOfMonth: Money
        /// Tijdelijk geleend van spaar dat nog uitstaat (nul = niets).
        public let borrowed: Money
        public let month: MonthSpending
        public let fixedItems: FixedItems
        /// Besteedbaar per maandeinde t/m vandaag.
        public let trend: [TrendPoint]
    }

    public struct PotLine: Equatable, Sendable {
        public let name: String
        public let balance: Money
    }

    public struct PotGroup: Equatable, Sendable {
        public let kind: PotKind
        public let total: Money
        public let pots: [PotLine]

        public var title: String { kind == .reservering ? "Reserveringen" : "Sparen" }
    }

    public let today: Day
    /// Moment waarop de momentopname gemaakt is.
    public let generatedAt: Date
    /// nil als er voor het jaar van `today` nog geen begroting is.
    public let budget: Budget?
    public let accounts: [AccountLine]
    public let potGroups: [PotGroup]
    /// Saldo op de spaarrekening(en) zonder pot.
    public let unallocated: Money
    /// Nog over te boeken van spaar naar betaal (positief; nul = niets open).
    public let openReimbursement: Money

    /// Dezelfde cijfers, los van het moment van maken. Hiermee slaat de app een nieuwe versie over als er
    /// niets veranderd is.
    public func hasSameNumbers(as other: PhoneSnapshot) -> Bool {
        today == other.today && budget == other.budget && accounts == other.accounts
            && potGroups == other.potGroups && unallocated == other.unallocated
            && openReimbursement == other.openReimbursement
    }
}

public enum PhoneDashboard {
    /// Leest de momentopname. Bestaat het begrotingsjaar van `today` niet, dan is `budget` nil; rekeningen en
    /// potten staan er dan nog wel in.
    public static func make(_ db: Database, today: Day, now: Date = Date()) throws -> PhoneSnapshot {
        let dashboard = try Insight.dashboard(db, today: today, recentLimit: 1, tagLimit: 1)

        var budget: PhoneSnapshot.Budget?
        if let spendable = dashboard.spendable, let fixed = dashboard.fixedItems {
            let late = fixed.items.filter { $0.state == .teLaat }
                .map { PhoneSnapshot.LateItem(label: $0.label, plan: $0.plan) }
            let trend = try Insight.spendableSeries(db, year: today.year, today: today)
                .map { PhoneSnapshot.TrendPoint(day: $0.day, spendable: $0.spendable) }
            budget = PhoneSnapshot.Budget(
                spendable: spendable.spendable,
                spendableEndOfMonth: spendable.spendableEndOfMonth,
                borrowed: try Insight.temporaryLoanOutstanding(db, on: today),
                month: PhoneSnapshot.MonthSpending(month: today.month, expenses: dashboard.monthExpenses,
                                                   planExpenses: dashboard.planExpenses,
                                                   percent: percent(dashboard.monthExpenses, of: dashboard.planExpenses)),
                fixedItems: PhoneSnapshot.FixedItems(paidCount: fixed.paidCount, openCount: fixed.openCount,
                                                     lateCount: fixed.lateCount, late: late),
                trend: trend)
        }

        let pots = try Insight.potOverview(db, today: today)
        let groups = pots.byKind.map { group in
            PhoneSnapshot.PotGroup(kind: group.kind, total: group.total,
                                   pots: group.pots.filter { !($0.archived && $0.balance.isZero) }
                                       .map { PhoneSnapshot.PotLine(name: $0.name, balance: $0.balance) })
        }
        return PhoneSnapshot(
            today: today, generatedAt: now, budget: budget,
            accounts: dashboard.accounts.map { PhoneSnapshot.AccountLine(name: $0.name, kind: $0.kind, balance: $0.balance) },
            potGroups: groups, unallocated: pots.totalUnallocated,
            openReimbursement: try Insight.openReimbursements(db).transferAmount)
    }

    /// Afgerond percentage van twee bedragen (zonder teken); nil als `plan` nul is.
    static func percent(_ amount: Money, of plan: Money) -> Int? {
        let p = abs(plan.cents)
        guard p > 0 else { return nil }
        return Int((abs(amount.cents) * 100 + p / 2) / p)
    }
}
