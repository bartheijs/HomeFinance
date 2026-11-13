import SwiftUI
import HFCore
import HFInsight

/// Alles wat het scherm "Spaaroverboekingen" toont.
struct ReimbData: Equatable {
    /// Uitgaven die nog vergoed moeten worden (nil als lezen mislukte).
    var open: HFInsight.OpenReimbursements?
    /// Eerdere overboekingen, nieuwste eerst.
    var transfers: [SavingsTransferDetail] = []
    /// Potten waaruit vergoed kan worden.
    var pots: [PotSummary] = []

    var openEntries: [EntryRow] { open?.entries ?? [] }
    /// Vastgelegd, maar nog niet overgemaakt bij de bank.
    var pending: [SavingsTransferDetail] { transfers.filter { !$0.done } }

    @MainActor
    static func load(model: AppModel) -> ReimbData {
        model.read(ReimbData()) { db in
            ReimbData(open: try Insight.openReimbursements(db),
                      transfers: try Insight.savingsTransfers(db),
                      pots: try Insight.potOverview(db, today: model.today).accounts
                          .flatMap(\.pots).filter { !$0.archived })
        }
    }
}

/// Deel van een overboeking dat uit één pot komt. Alleen voor weergave van een selectie;
/// de bedragen zijn de boekingen zelf.
struct ReimbPotShare: Identifiable, Equatable {
    var id: Int64 { potId ?? 0 }
    let potId: Int64?
    let potName: String?
    /// Positief: wat er uit deze pot naar de betaalrekening gaat.
    var amount: Money
    var count: Int

    var title: String { potName.map { "uit pot \($0)" } ?? "nog geen pot gekozen" }

    static func shares(for entries: [EntryRow]) -> [ReimbPotShare] {
        var result: [ReimbPotShare] = []
        for entry in entries {
            if let index = result.firstIndex(where: { $0.potId == entry.potId }) {
                result[index].amount += -entry.amount
                result[index].count += 1
            } else {
                result.append(ReimbPotShare(potId: entry.potId, potName: entry.potName, amount: -entry.amount, count: 1))
            }
        }
        return result
    }
}

enum ReimbPending: Identifiable {
    case delete(SavingsTransferDetail)
    case reopen(SavingsTransferDetail)

    var id: String {
        switch self {
        case .delete(let t): "delete-\(t.id)"
        case .reopen(let t): "reopen-\(t.id)"
        }
    }
}

enum ReimbFormat {
    static func expenses(_ count: Int) -> String { count == 1 ? "1 uitgave" : "\(count) uitgaven" }
}
