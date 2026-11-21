import SwiftUI
import HFCore
import HFInsight
import HFBudget

/// Alles wat het scherm "Verrekenen met spaar" toont.
struct ReimbData: Equatable {
    /// Gemarkeerde boekingen die nog verrekend moeten worden (nil als lezen mislukte).
    var open: HFInsight.OpenReimbursements?
    /// Eerdere verrekeningen, nieuwste eerst.
    var transfers: [SavingsTransferDetail] = []
    /// Potten waarmee verrekend kan worden.
    var pots: [PotSummary] = []
    /// Dezelfde potten in de volgorde van een pot-kiezer (per soort op alfabet).
    var potChoices: [PotSummary] { Insight.pickerOrder(pots) }
    /// Naam per spaarrekening.
    var savingsNames: [Int64: String] = [:]
    /// Afgevinkte verrekeningen die na 5 dagen nog niet in een bankbestand zijn gezien.
    var unconfirmed: Set<Int64> = []

    var openEntries: [EntryRow] { open?.entries ?? [] }
    /// Vastgelegd, maar nog niet verrekend (uit een oudere versie of half afgemaakt).
    var pending: [SavingsTransferDetail] { transfers.filter { !$0.done } }
    var history: [SavingsTransferDetail] { transfers.filter(\.done) }

    func pot(_ id: Int64?) -> PotSummary? {
        guard let id else { return nil }
        return pots.first { $0.id == id }
    }

    @MainActor
    static func load(model: AppModel) -> ReimbData {
        let today = model.today
        return model.read(ReimbData()) { db in
            let overview = try Insight.potOverview(db, today: today)
            var data = ReimbData(open: try Insight.openReimbursements(db),
                                 transfers: try Insight.savingsTransfers(db),
                                 pots: overview.accounts.flatMap(\.pots).filter { !$0.archived })
            for account in overview.accounts { data.savingsNames[account.id] = account.name }
            data.unconfirmed = Set(try SavingsTransferService.unconfirmed(db, today: today).compactMap(\.id))
            return data
        }
    }

    /// De open boekingen per paar van betaalrekening en spaarrekening. De service verrekent één paar tegelijk.
    /// Een boeking zonder pot telt mee bij het eerste paar van dezelfde betaalrekening.
    var groups: [ReimbGroup] {
        var result: [ReimbGroup] = []
        var loose: [EntryRow] = []
        for entry in openEntries {
            guard let savingsId = pot(entry.potId)?.accountId else { loose.append(entry); continue }
            if let index = result.firstIndex(where: { $0.checkingId == entry.accountId && $0.savingsId == savingsId }) {
                result[index].entries.append(entry)
            } else {
                result.append(ReimbGroup(checkingId: entry.accountId, checkingName: entry.accountName,
                                         savingsId: savingsId, savingsName: savingsNames[savingsId] ?? "spaar",
                                         entries: [entry]))
            }
        }
        for entry in loose {
            if let index = result.firstIndex(where: { $0.checkingId == entry.accountId }) {
                result[index].entries.append(entry)
            } else {
                result.append(ReimbGroup(checkingId: entry.accountId, checkingName: entry.accountName,
                                         savingsId: nil, savingsName: "spaar", entries: [entry]))
            }
        }
        for index in result.indices { result[index].entries.sort { ($0.day, $0.id) < ($1.day, $1.id) } }
        return result
    }
}

/// Boekingen die samen in één verrekening kunnen: één betaalrekening en één spaarrekening.
struct ReimbGroup: Identifiable, Equatable {
    var id: String { "\(checkingId)-\(savingsId ?? 0)" }
    let checkingId: Int64
    let checkingName: String
    let savingsId: Int64?
    let savingsName: String
    var entries: [EntryRow]

    var title: String { "\(checkingName) ↔ \(savingsName)" }
}

/// Wat er voor de aangevinkte boekingen één pot uit gaat of in komt.
struct ReimbPotShare: Identifiable, Equatable {
    var id: Int64 { potId ?? 0 }
    let potId: Int64?
    let potName: String?
    /// Positief: de pot uit. Negatief: de pot in.
    var amount: Money
    var count: Int
    /// Het potsaldo na het verrekenen; nil zonder pot.
    var balanceAfter: Money?
}

/// De aangevinkte boekingen opgeteld. Alleen weergave van een deelselectie; de bedragen zijn de boekingen zelf.
struct ReimbSelection: Equatable {
    let entries: [EntryRow]
    /// Som van de uitgaven (positief): komt uit spaar.
    let fromSavings: Money
    /// Som van de bijschrijvingen (positief): gaat naar spaar.
    let toSavings: Money
    let perPot: [ReimbPotShare]

    /// Positief = van spaar naar betaal, negatief = van betaal naar spaar.
    var net: Money { fromSavings - toSavings }
    var withoutPot: Int { entries.filter { $0.potId == nil }.count }
    var isEmpty: Bool { entries.isEmpty }

    init(entries: [EntryRow], pots: [PotSummary]) {
        self.entries = entries
        fromSavings = -entries.map(\.amount).filter { $0 < .zero }.sum()
        toSavings = entries.map(\.amount).filter { $0 > .zero }.sum()
        var shares: [ReimbPotShare] = []
        for entry in entries {
            if let index = shares.firstIndex(where: { $0.potId == entry.potId }) {
                shares[index].amount += -entry.amount
                shares[index].count += 1
            } else {
                shares.append(ReimbPotShare(potId: entry.potId, potName: entry.potName, amount: -entry.amount, count: 1))
            }
        }
        for index in shares.indices {
            if let pot = pots.first(where: { $0.id == shares[index].potId }) {
                shares[index].balanceAfter = pot.balance - shares[index].amount
            }
        }
        perPot = shares
    }
}

enum ReimbFormat {
    static func bookings(_ count: Int) -> String { count == 1 ? "1 boeking" : "\(count) boekingen" }

    /// "€ 310,00 van spaar naar betaal"
    static func direction(_ direction: SavingsTransferDirection) -> String {
        switch direction {
        case .fromSavings: "van spaar naar betaal"
        case .toSavings: "van betaal naar spaar"
        case .none: "alleen tussen potjes"
        }
    }
}
