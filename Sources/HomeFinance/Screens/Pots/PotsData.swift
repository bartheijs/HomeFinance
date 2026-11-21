import SwiftUI
import GRDB
import HFCore
import HFInsight
import HFBudget

/// Alles wat het scherm Potten toont, in één keer gelezen.
struct PotsData: Equatable {
    var overview: PotOverview?
    /// Boekingen op de spaarrekening zonder pot.
    var unallocated: [EntryRow] = []
    /// Boekingen zonder pot die elkaar opheffen en dus geen pot nodig hebben.
    var cancelledPairs: [CancelledPair] = []
    /// Boekingen uit `unallocated` die precies de maandelijkse storting zijn en dus verdeeld kunnen worden.
    var distributable: Set<Int64> = []
    /// Saldo per maandeinde, per spaarrekening (voor het lijntje in de kop).
    var series: [Int64: [BalancePoint]] = [:]
    /// Alle spaarrekeningen (ook als het overzicht gefilterd is), voor de rekeningkeuze.
    var savingsAccounts: [PotsAccountRef] = []
    /// Beginstand per spaarrekening waar nog geen enkele banktransactie op staat (om na te lopen).
    var openings: [OpeningOverview] = []
    /// De dag waarop de saldi gelden.
    var asOf: Day
    /// De keten post ↔ vaste storting ↔ potje van het jaar van `asOf` (UX-stap B2).
    var chain: ChainOverview?

    static func empty(asOf: Day) -> PotsData { PotsData(asOf: asOf) }

    var allPots: [PotSummary] { overview?.accounts.flatMap(\.pots) ?? [] }
    /// Alle potten in de volgorde van een pot-kiezer (per soort op alfabet); het overzicht zelf blijft per persoon.
    var pickerPots: [PotSummary] { Insight.pickerOrder(allPots) }

    func pot(_ id: Int64?) -> PotSummary? {
        guard let id else { return nil }
        return allPots.first { $0.id == id }
    }

    func accountName(_ id: Int64) -> String {
        savingsAccounts.first { $0.id == id }?.name ?? ""
    }

    @MainActor
    static func load(model: AppModel, accountId: Int64?) -> PotsData {
        let today = model.today
        // Een voorbij jaar toont de stand op 31 december van dat jaar, net als de rest van de app.
        let asOf = model.year < today.year ? (Day(year: model.year, month: 12, day: 31) ?? today) : today
        return model.read(.empty(asOf: asOf)) { db in
            var data = PotsData(asOf: asOf)
            data.savingsAccounts = try Account
                .filter(Column("kind") == AccountKind.spaar.rawValue)
                .order(Column("sortOrder"), Column("id"))
                .fetchAll(db)
                .compactMap { a in a.id.map { PotsAccountRef(id: $0, name: a.name, archived: a.archived, openingDate: a.openingDate) } }
            let overview = try Insight.potOverview(db, accountId: accountId, today: asOf)
            data.overview = overview
            let unallocated = try Insight.unallocatedSavingsOverview(db, accountId: accountId)
            data.unallocated = unallocated.entries
            data.cancelledPairs = unallocated.cancelledPairs
            for entry in data.unallocated where entry.amount > .zero && entry.bank?.amount == entry.amount {
                if try PotService.distribution(db, for: entry.amount, accountId: entry.accountId) != nil {
                    data.distributable.insert(entry.id)
                }
            }
            for account in overview.accounts where !account.archived {
                let imported = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM bankTransaction WHERE accountId = ?",
                                                arguments: [account.id]) ?? 0
                if imported == 0 { data.openings.append(try Insight.openingOverview(db, accountId: account.id)) }
            }
            data.chain = try Insight.chain(db, year: asOf.year)
            if let start = Day(year: asOf.year, month: 1, day: 1) {
                for account in overview.accounts {
                    data.series[account.id] = try Insight.balanceSeries(db, accountId: account.id, from: start,
                                                                        to: asOf, step: .monthEnd)
                }
            }
            return data
        }
    }
}

struct PotsAccountRef: Identifiable, Equatable, Hashable {
    let id: Int64
    let name: String
    let archived: Bool
    let openingDate: Day
}

/// Eén stukje van de verdeling van het spaarsaldo over de potten.
struct PotsSlice: Identifiable, Equatable {
    let id: String
    let name: String
    let amount: Money
    let share: Double
    let color: Color
    /// De pot achter dit stukje (nil voor "Overige potten" en "Niet toegewezen").
    let potId: Int64?

    /// De grootste potten elk een eigen kleur, de rest samen, en als laatste wat nog geen pot heeft.
    /// Alleen voor weergave; de bedragen zelf komen uit `Insight.potOverview`.
    static func slices(for account: SavingsAccountPots, maxNamed: Int = 7) -> [PotsSlice] {
        let positive = account.pots.filter { $0.balance > .zero }.sorted { $0.balance > $1.balance }
        let unallocated = max(.zero, account.unallocated)
        let whole = positive.map(\.balance).sum() + unallocated
        guard whole > .zero else { return [] }
        func share(_ m: Money) -> Double { m.doubleValue / whole.doubleValue }
        var result: [PotsSlice] = []
        for (index, pot) in positive.prefix(maxNamed).enumerated() {
            result.append(PotsSlice(id: "pot-\(pot.id)", name: pot.name, amount: pot.balance, share: share(pot.balance),
                                    color: Theme.series[index % Theme.series.count], potId: pot.id))
        }
        let rest = positive.dropFirst(maxNamed)
        if !rest.isEmpty {
            let total = rest.map(\.balance).sum()
            result.append(PotsSlice(id: "rest", name: "\(rest.count) kleinere potjes", amount: total,
                                    share: share(total), color: Color.secondary.opacity(0.45), potId: nil))
        }
        if unallocated > .zero {
            result.append(PotsSlice(id: "unallocated", name: "Niet toegewezen", amount: unallocated,
                                    share: share(unallocated), color: Theme.warning, potId: nil))
        }
        return result
    }
}

/// Punt in de saldografiek van een pot.
struct PotsChartPoint: Identifiable, Equatable {
    var id: Date { date }
    let date: Date
    let balance: Double

    /// Het oplopende saldo uit de historie, één punt per dag, doorgetrokken tot de peildag.
    static func points(from history: [PotHistoryRow], asOf: Day) -> [PotsChartPoint] {
        var perDay: [(Day, Money)] = []
        for row in history {
            if let last = perDay.last, last.0 == row.entry.day {
                perDay[perDay.count - 1].1 = row.runningBalance
            } else {
                perDay.append((row.entry.day, row.runningBalance))
            }
        }
        if let last = perDay.last, last.0 < asOf { perDay.append((asOf, last.1)) }
        return perDay.map { PotsChartPoint(date: $0.0.date, balance: $0.1.doubleValue) }
    }
}

enum PotsFormat {
    /// Hele euro's voor assen van grafieken: "€ 1.200".
    static func wholeEuros(_ value: Double) -> String {
        let text = Money(cents: Int64((value * 100).rounded())).formatted()
        return text.hasSuffix(",00") ? String(text.dropLast(3)) : text
    }

    /// "nog te verrekenen: € 25,00 erbij" (positief = gaat de pot uit).
    static func pending(_ amount: Money) -> String {
        "nog over te boeken: \(amount.magnitude.formatted()) \(amount > .zero ? "eraf" : "erbij")"
    }

    static func percent(_ share: Double) -> String {
        let p = share * 100
        return p < 1 && p > 0 ? "<1%" : "\(Int(p.rounded()))%"
    }
}

extension PotKind {
    var potsTitle: String {
        switch self { case .reservering: "Reservering"; case .spaar: "Sparen" }
    }
    var potsExplanation: String {
        switch self {
        case .reservering: "Geld dat je elke maand opzij zet voor rekeningen die één keer per jaar of onregelmatig komen."
        case .spaar: "Geld dat je spaart voor een doel of voor een gezinslid."
        }
    }
}
