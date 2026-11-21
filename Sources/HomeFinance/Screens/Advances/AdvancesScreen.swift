import SwiftUI
import HFCore
import HFInsight

/// Voorgeschoten (UX-stap D3): per tag wat je nog terugkrijgt, met de openstaande boekingen en "Het is binnen…".
/// Alleen weergave: de cijfers komen uit HFInsight (`settlementOverview`, `openSettlementEntries`), het vastleggen
/// gaat via hetzelfde venster als in Transacties (`TransactionsSettleSheet`, dat `SettlementService` gebruikt).
struct AdvancesScreen: View {
    @Environment(AppModel.self) private var model

    @State private var tags: [TagSettlementSummary] = []
    @State private var open: [Int64: [EntryRow]] = [:]
    @State private var checkingAccountId: Int64?
    @State private var loaded = false
    /// Alleen voor het venster "Het geld is terug…": dezelfde acties als in Transacties.
    @State private var settleStore = TransactionsStore()
    @State private var expanded: Set<Int64> = []

    private struct ReloadKey: Hashable { let revision: Int, year: Int }

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader("Voorgeschoten",
                         subtitle: "Uitgaven die je voorschiet en terugkrijgt, zoals tankkosten van je werk. Per tag zie je wat er nog terug moet komen.")
            content
        }
        .task(id: ReloadKey(revision: model.revision, year: model.year)) { reload() }
        .sheet(item: $settleStore.settleTarget) { target in
            TransactionsSettleSheet(store: settleStore, target: target).environment(model)
        }
    }

    @ViewBuilder private var content: some View {
        if !loaded {
            Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if tags.isEmpty {
            EmptyState(title: "Nog niets voorgeschoten",
                       message: "Zet bij Instellingen › Tags ‘Voorgeschoten’ aan voor een tag (bijvoorbeeld Tanken). Geef je uitgaven die tag; hier zie je dan wat je nog terugkrijgt.",
                       icon: "arrow.uturn.backward.circle",
                       actionTitle: "Naar Instellingen › Tags") {
                model.settingsTab = "tags"
                model.selection = .settings
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(tags) { card($0) }
                }
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24).padding(.top, 8).padding(.bottom, 32)
            }
        }
    }

    private func card(_ tag: TagSettlementSummary) -> some View {
        let entries = open[tag.id] ?? []
        let hasOpen = tag.outstanding > .zero
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Circle().fill(Color(hex: tag.color)).frame(width: 9, height: 9)
                Text(tag.name).font(.title3.weight(.semibold))
                Spacer(minLength: 8)
                if hasOpen {
                    Text(tag.outstanding.formatted())
                        .font(.system(.title2, design: .rounded).weight(.semibold)).monospacedDigit()
                }
            }
            Text(statusLine(tag)).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                if hasOpen {
                    Button("Het is binnen…") { startSettle(tag) }
                        .buttonStyle(.borderedProminent)
                        .help("Geef aan dat je het voorgeschoten geld hebt teruggekregen, en koppel de bijschrijving waarmee het binnenkwam.")
                }
                if let accountId = checkingAccountId {
                    Button("Toon in Transacties") {
                        model.transactionsJump = TransactionsJump(accountId: accountId, tagId: tag.id)
                        model.selection = .transactions
                    }
                    .buttonStyle(.link)
                    .help("Alle boekingen met de tag \(tag.name)")
                }
                if !entries.isEmpty {
                    Button(expanded.contains(tag.id) ? "Verberg boekingen" : "Toon de \(entries.count) open boekingen") {
                        if expanded.contains(tag.id) { expanded.remove(tag.id) } else { expanded.insert(tag.id) }
                    }
                    .buttonStyle(.link)
                }
                Spacer(minLength: 0)
            }
            if expanded.contains(tag.id) {
                VStack(spacing: 4) {
                    if tag.openStart > .zero {
                        row(day: nil, label: "Startbedrag", amount: -tag.openStart)
                    }
                    ForEach(entries) { row(day: $0.day, label: $0.label, amount: $0.amount) }
                }
                .padding(10)
                .background(Theme.background, in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.hairline.opacity(0.5)))
    }

    private func row(day: Day?, label: String, amount: Money) -> some View {
        HStack {
            Text(day.map { $0.short(withYear: $0.year != model.today.year) } ?? "")
                .monospacedDigit().foregroundStyle(.secondary).frame(width: 84, alignment: .leading)
            Text(label).lineLimit(1)
            Spacer(minLength: 8)
            TransactionsAmountText(amount: amount)
        }
        .font(.callout)
    }

    /// "Je krijgt nog € … terug · 3 boekingen, de oudste van 2 jun · laatste terugbetaling 14 mei (€ …)".
    private func statusLine(_ tag: TagSettlementSummary) -> String {
        var parts: [String] = []
        if tag.outstanding > .zero {
            parts.append("Je krijgt nog \(tag.outstanding.formatted()) terug")
            parts.append(TransactionsFormat.entries(tag.openCount)
                         + (tag.oldestOpenDay.map { ", de oudste van \($0.short())" } ?? ""))
        } else {
            parts.append("Er staat niets open")
        }
        if let day = tag.lastSettlementDay, let amount = tag.lastSettlementAmount {
            parts.append("laatste terugbetaling \(day.short(withYear: day.year != model.today.year)) (\(amount.formatted()))")
        }
        if tag.countsInSpendable, tag.outstanding > .zero { parts.append("telt mee als inkomen dat nog komt") }
        return parts.joined(separator: " · ")
    }

    private func startSettle(_ tag: TagSettlementSummary) {
        settleStore.settleTarget = TransactionsSettleTarget(tagId: tag.id, tagName: tag.name)
    }

    private func reload() {
        tags = model.read([]) { try Insight.settlementOverview($0, today: model.today) }
        var byTag: [Int64: [EntryRow]] = [:]
        for tag in tags where tag.openCount > 0 {
            byTag[tag.id] = model.read([]) { try Insight.openSettlementEntries($0, tagId: tag.id) }
        }
        open = byTag
        checkingAccountId = model.read(nil as Int64?) {
            try Int64.fetchOne($0, sql: "SELECT id FROM account WHERE kind = 'betaal' AND archived = 0 ORDER BY sortOrder, id LIMIT 1")
        }
        loaded = true
    }
}
