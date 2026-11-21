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

    /// Openstaand bij een tag waarvan "telt mee in nog te besteden" aan staat (zie `Insight.spendable`).
    public struct ReturningLine: Equatable, Sendable {
        public let name: String
        /// Positief: wat er nog terugkomt.
        public let amount: Money
    }

    /// Alles wat een begrotingsjaar nodig heeft.
    public struct Budget: Equatable, Sendable {
        /// Besteedbaar nu (inclusief wat er bij tags met "telt mee" nog terugkomt).
        public let spendable: Money
        /// Nog te besteden deze maand: besteedbaar nu plus wat er deze maand nog komt en gaat.
        public let spendableEndOfMonth: Money
        /// Tijdelijk geleend van spaar dat nog uitstaat (nul = niets).
        public let borrowed: Money
        /// Tags waarvan wat er nog terugkomt al meetelt; leeg als er geen zijn.
        public let returning: [ReturningLine]
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

    /// De potjes van één eigenaar (een kind), zoals gekozen bij Instellingen › Telefoon.
    public struct OwnerPots: Equatable, Sendable {
        public let owner: String
        public let total: Money
        public let pots: [PotLine]
    }

    /// Verwachte stand van een pot over een aantal maanden.
    public struct AheadPoint: Equatable, Sendable {
        public let months: Int
        public let day: Day
        public let balance: Money
    }

    /// De gekozen gezamenlijke spaarpot met vooruitblik.
    public struct SharedPot: Equatable, Sendable {
        public let name: String
        /// Saldo vandaag.
        public let balance: Money
        /// Verwachte stand over 3, 6 en 12 maanden.
        public let ahead: [AheadPoint]
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
    /// Potjes per gekozen eigenaar; leeg als het onderdeel uit staat of er niemand gekozen is.
    public let childPots: [OwnerPots]
    /// De gekozen spaarpot; nil als het onderdeel uit staat, er geen pot gekozen is of de pot niet meer bestaat.
    public let sharedPot: SharedPot?

    /// Dezelfde cijfers, los van het moment van maken. Hiermee slaat de app een nieuwe versie over als er
    /// niets veranderd is.
    public func hasSameNumbers(as other: PhoneSnapshot) -> Bool {
        today == other.today && budget == other.budget && accounts == other.accounts
            && potGroups == other.potGroups && unallocated == other.unallocated
            && openReimbursement == other.openReimbursement
            && childPots == other.childPots && sharedPot == other.sharedPot
    }
}

public enum PhoneDashboard {
    /// Hoeveel maanden vooruit de gezamenlijke spaarpot kijkt.
    public static let aheadMonths = [3, 6, 12]

    /// Leest de momentopname. Bestaat het begrotingsjaar van `today` niet, dan is `budget` nil; rekeningen en
    /// potten staan er dan nog wel in. `options` bepaalt welke eigenaren en welke spaarpot erin komen.
    public static func make(_ db: Database, today: Day, now: Date = Date(),
                            options: PublishOptions = PublishOptions()) throws -> PhoneSnapshot {
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
                returning: spendable.returningTags.map { PhoneSnapshot.ReturningLine(name: $0.name, amount: $0.amount) },
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
        var childPots: [PhoneSnapshot.OwnerPots] = []
        if options.includesChildPots {
            let chosen = Set(options.childOwners)
            childPots = pots.byOwner.compactMap { group in
                guard let owner = group.owner, chosen.contains(owner) else { return nil }
                let lines = group.pots.filter { !($0.archived && $0.balance.isZero) }
                    .map { PhoneSnapshot.PotLine(name: $0.name, balance: $0.balance) }
                guard !lines.isEmpty else { return nil }
                return PhoneSnapshot.OwnerPots(owner: owner, total: group.total, pots: lines)
            }
        }

        var sharedPot: PhoneSnapshot.SharedPot?
        if options.showSharedPot, let potId = options.sharedPotId, try Pot.fetchOne(db, key: potId) != nil {
            let days = aheadMonths.map { adding(months: $0, to: today) }
            let forecast = try Insight.potForecast(db, potId: potId, today: today, until: days.max() ?? today)
            sharedPot = PhoneSnapshot.SharedPot(
                name: forecast.potName, balance: forecast.startBalance,
                ahead: zip(aheadMonths, days).map { months, day in
                    PhoneSnapshot.AheadPoint(months: months, day: day,
                                             balance: forecast.balance(on: day) ?? forecast.endBalance)
                })
        }

        return PhoneSnapshot(
            today: today, generatedAt: now, budget: budget,
            accounts: dashboard.accounts.map { PhoneSnapshot.AccountLine(name: $0.name, kind: $0.kind, balance: $0.balance) },
            potGroups: groups, unallocated: pots.totalUnallocated,
            openReimbursement: try Insight.openReimbursements(db).transferAmount,
            childPots: childPots, sharedPot: sharedPot)
    }

    /// Dezelfde dag een aantal maanden later; bestaat die dag niet (31 januari + 1), dan de laatste dag van die
    /// maand. Zo rekent de vooruitblik bij een pot op de Mac ook.
    static func adding(months: Int, to day: Day) -> Day {
        let index = day.year * 12 + (day.month - 1) + months
        let year = index / 12, month = index % 12 + 1
        for d in stride(from: min(day.day, 31), through: 28, by: -1) {
            if let result = Day(year: year, month: month, day: d) { return result }
        }
        return Day(year: year, month: month, day: min(day.day, 28))!
    }

    /// Afgerond percentage van twee bedragen (zonder teken); nil als `plan` nul is.
    static func percent(_ amount: Money, of plan: Money) -> Int? {
        let p = abs(plan.cents)
        guard p > 0 else { return nil }
        return Int((abs(amount.cents) * 100 + p / 2) / p)
    }
}
