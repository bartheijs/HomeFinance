import SwiftUI
import HFCore
import HFInsight
import HFBudget

// MARK: - Omschrijving met aanvullen

/// Tekstveld voor de omschrijving dat bestaande omschrijvingen voorstelt terwijl je typt (pijltjes en ⏎),
/// en waarschuwt als je iets typt dat bijna gelijk is aan een bestaande ("Bedoel je ‘Zakgeld’?").
struct TransactionsLabelField: View {
    let title: String
    @Binding var text: String
    let labels: [LabelSuggestion]
    var autoFocus = false
    var onPick: (LabelSuggestion) -> Void
    var onSubmit: () -> Void = {}

    @FocusState private var focused: Bool
    @State private var highlighted: Int?
    /// De tekst waarbij het lijstje is gesloten (na kiezen of esc); typen opent het weer.
    @State private var closedFor: String?

    private var trimmed: String { text.trimmingCharacters(in: .whitespaces) }

    private var suggestions: [LabelSuggestion] {
        guard focused, !trimmed.isEmpty, closedFor != text else { return [] }
        return LabelMatcher.suggest(text, from: labels, limit: 6).filter { $0.label != trimmed }.prefix(5).map { $0 }
    }

    private var similar: LabelSuggestion? {
        trimmed.count >= 3 ? LabelMatcher.similar(text, in: labels) : nil
    }

    var body: some View {
        let list = suggestions
        VStack(alignment: .leading, spacing: 4) {
            TextField(title, text: $text)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onKeyPress(.downArrow) { move(1, in: list) }
                .onKeyPress(.upArrow) { move(-1, in: list) }
                .onKeyPress(.return) {
                    guard let i = highlighted, list.indices.contains(i) else { return .ignored }
                    pick(list[i])
                    return .handled
                }
                .onKeyPress(.escape) {
                    guard !list.isEmpty else { return .ignored }
                    closedFor = text
                    return .handled
                }
                .onSubmit(onSubmit)
                .onChange(of: text) { _, _ in highlighted = nil }
                .onAppear { if autoFocus { focused = true } }
            if !list.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(list.enumerated()), id: \.element.id) { index, suggestion in
                        Button { pick(suggestion) } label: {
                            HStack(spacing: 6) {
                                Text(suggestion.label).lineLimit(1)
                                Spacer(minLength: 6)
                                Text(detail(suggestion)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(highlighted == index ? Theme.accent.opacity(0.18) : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 5))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(3)
                .background(Theme.background, in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.hairline.opacity(0.7)))
                .help("Bestaande omschrijvingen. Kies met ↓ ↑ en ⏎, of klik.")
            }
            if let similar, !list.contains(where: { $0.id == similar.id }) || !focused {
                Button("Bedoel je ‘\(similar.label)’?") { pick(similar) }
                    .buttonStyle(.link)
                    .font(.caption)
                    .help("Deze omschrijving bestaat al, bijna hetzelfde geschreven. Klik om hem over te nemen, zodat je geen dubbele krijgt.")
            }
        }
    }

    private func detail(_ s: LabelSuggestion) -> String {
        [s.itemLabel, s.count > 0 ? "\(s.count)×" : nil].compactMap { $0 }.joined(separator: " · ")
    }

    private func move(_ step: Int, in list: [LabelSuggestion]) -> KeyPress.Result {
        guard !list.isEmpty else { return .ignored }
        let next = (highlighted ?? (step > 0 ? -1 : list.count)) + step
        highlighted = min(max(next, 0), list.count - 1)
        return .handled
    }

    private func pick(_ suggestion: LabelSuggestion) {
        onPick(suggestion)
        closedFor = suggestion.label
        highlighted = nil
    }
}

// MARK: - Vaste storting bij een nieuwe transactie

/// Toont de verdeling van een herkende vaste storting, met de keuze waar een verschil heen gaat.
struct TransactionsDistributionSection: View {
    @Environment(AppModel.self) private var model
    @Bindable var store: TransactionsStore
    let pending: TransactionsPending
    let match: DistributionMatch

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Vaste storting").font(.headline)
            if match.isAmbiguous {
                Text("Dit past bij meer vaste stortingen. Kies welke het is.")
                    .font(.callout).foregroundStyle(.secondary)
                ForEach(match.distributions) { distribution in
                    Button(distribution.name) {
                        if let id = distribution.id { store.chooseDistribution(model, pending, distributionId: id) }
                    }
                }
            } else if let distribution = match.distribution {
                Text(match.side == .destination
                     ? "‘\(distribution.name)’: verdeeld over \(match.allocations.count) potten"
                     : "‘\(distribution.name)’: de overboeking naar de spaarrekening")
                    .font(.callout)
                VStack(spacing: 2) {
                    ForEach(Array(match.allocations.enumerated()), id: \.offset) { _, allocation in
                        HStack {
                            Text(name(allocation)).lineLimit(1)
                            Spacer(minLength: 6)
                            TransactionsAmountText(amount: allocation.amount)
                        }
                        .font(.callout)
                    }
                }
                .padding(10)
                .background(Theme.background, in: RoundedRectangle(cornerRadius: 8))
                let rest = store.distributionRest(pending)
                if !rest.isZero {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Het bedrag is \(rest.magnitude.formatted()) \(rest > .zero ? "hoger" : "lager") dan de vaste verdeling.",
                              systemImage: "exclamationmark.triangle")
                            .font(.callout).foregroundStyle(Theme.warning)
                            .fixedSize(horizontal: false, vertical: true)
                        if match.side == .destination {
                            HStack(spacing: 8) {
                                Text("Verschil naar").font(.callout).foregroundStyle(.secondary)
                                TransactionsPotPicker(pots: store.lookups.pots(accountId: pending.transaction.accountId),
                                                      noneTitle: "Niet toegewezen", selection: $store.differencePotId)
                            }
                            .help("Het verschil wordt een extra regel van \(rest.formatted()) op deze pot, of blijft niet toegewezen.")
                        }
                    }
                }
                if let warning = match.warning {
                    Label(warning, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Button("Toch zelf kiezen") { store.matchChoice = nil }
                .buttonStyle(.link).font(.caption)
                .help("Negeer de vaste storting en kies zelf waar deze transactie bij hoort")
        }
    }

    private func name(_ allocation: Allocation) -> String {
        if let pot = store.lookups.pot(allocation.potId), match.side == .destination { return pot.name }
        if let item = store.lookups.item(allocation.budgetItemId) { return item.label }
        return allocation.label
    }
}

// MARK: - Verrekenen

/// Sheet om de openstaande boekingen van een tag (bv. Tanken) te verrekenen met een terugstorting.
struct TransactionsSettleSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let store: TransactionsStore
    let target: TransactionsSettleTarget

    @State private var open: [EntryRow] = []
    @State private var checked: Set<Int64> = []
    /// Het startbedrag van de tag als dat nog openstaat (uit `Insight.settlementStart`).
    @State private var start: SettlementStart?
    @State private var startChecked = false
    @State private var candidates: [Entry] = []
    @State private var depositId: Int64?
    @State private var history: [SettlementDetail] = []
    @State private var showHistory = false
    @State private var loaded = false

    private var chosen: [EntryRow] { open.filter { checked.contains($0.id) } }
    private var includeStart: Bool { start != nil && startChecked }
    /// Aantal gekozen posten: boekingen, plus het startbedrag.
    private var chosenCount: Int { chosen.count + (includeStart ? 1 : 0) }
    /// Het te verrekenen bedrag (positief): wat er terug moet komen. Optellen voor de weergave; de echte
    /// verrekening rekent `SettlementService.settle`.
    private var total: Money { (includeStart ? start?.amount ?? .zero : .zero) - chosen.map(\.amount).sum() }
    private var nothingOpen: Bool { open.isEmpty && start == nil }
    private var deposit: (amount: Money, day: Day, label: String)? {
        if let d = target.deposit { return (d.amount, d.day, d.label) }
        return candidates.first { $0.id == depositId }.map { ($0.amount, $0.day, $0.label) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Voorgeschoten: \(target.tagName)").font(.title2.weight(.semibold))
                Text("Uitgaven met deze tag die je hebt voorgeschoten. Kies welke je hebt teruggekregen; daarna staan ze niet meer open.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 12)

            if nothingOpen {
                Text(loaded ? "Er staat niets open voor \(target.tagName)." : "")
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 20).padding(.vertical, 12)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        if let start {
                            Toggle(isOn: $startChecked) {
                                HStack {
                                    Text(start.day.map { $0.short(withYear: $0.year != model.today.year) } ?? "")
                                        .monospacedDigit().foregroundStyle(.secondary)
                                        .frame(width: 84, alignment: .leading)
                                    Text("Startbedrag").lineLimit(1)
                                    Spacer(minLength: 8)
                                    TransactionsAmountText(amount: -start.amount)
                                }
                            }
                            .toggleStyle(.checkbox)
                            .padding(.vertical, 2)
                            .help("Wat er bij de start van de app al openstond (Instellingen › Tags)")
                        }
                        ForEach(open) { row in
                            Toggle(isOn: Binding(
                                get: { checked.contains(row.id) },
                                set: { if $0 { checked.insert(row.id) } else { checked.remove(row.id) } })) {
                                HStack {
                                    Text(row.day.short(withYear: row.day.year != model.today.year))
                                        .monospacedDigit().foregroundStyle(.secondary)
                                        .frame(width: 84, alignment: .leading)
                                    Text(row.label).lineLimit(1)
                                    Spacer(minLength: 8)
                                    TransactionsAmountText(amount: row.amount)
                                }
                            }
                            .toggleStyle(.checkbox)
                            .padding(.vertical, 2)
                        }
                    }
                    .padding(.horizontal, 20)
                }
                .frame(maxHeight: 220)
                HStack {
                    Text(includeStart ? "\(chosenCount) gekozen (met startbedrag)" : "\(TransactionsFormat.entries(chosen.count)) gekozen")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("Terug te storten").foregroundStyle(.secondary)
                    Text(total.formatted()).font(.title3.weight(.semibold)).monospacedDigit()
                }
                .padding(.horizontal, 20).padding(.vertical, 10)
                Divider()
                depositSection.padding(.horizontal, 20).padding(.vertical, 12)
            }

            if !history.isEmpty {
                Divider()
                DisclosureGroup("Eerder terugbetaald (\(history.count))", isExpanded: $showHistory) {
                    VStack(spacing: 6) {
                        ForEach(history) { detail in historyRow(detail) }
                    }
                    .padding(.top, 6)
                }
                .padding(.horizontal, 20).padding(.vertical, 10)
            }

            Divider()
            HStack {
                Spacer()
                Button(nothingOpen ? "Sluit" : "Annuleer") { dismiss() }.keyboardShortcut(.cancelAction)
                if !nothingOpen {
                    Button("Het geld is terug") {
                        let ids = chosen.map(\.id)
                        let depositEntryId = target.deposit?.id ?? depositId
                        if store.settle(model, tagId: target.tagId, entryIds: ids, includeStart: includeStart,
                                        day: deposit?.day ?? model.today, depositEntryId: depositEntryId) { dismiss() }
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(chosenCount == 0 || total.isNegative)
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
        }
        .frame(width: 560)
        .task(id: model.revision) { load() }
    }

    @ViewBuilder private var depositSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let d = target.deposit {
                Text("Terugbetaling: \(d.amount.formatted()) op \(d.day.short()) · \(d.label)")
            } else if candidates.isEmpty {
                Text("Nog niet terugbetaald: alleen vastleggen")
                Text("Er is in de laatste \(SettlementService.suggestionDays) dagen geen bijschrijving van dit bedrag gevonden. Koppelen kan later: rechtsklik op de bijschrijving en kies ‘Terugbetaling \(target.tagName)…’.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Picker("Terugbetaling", selection: $depositId) {
                    ForEach(candidates) { entry in
                        Text("Is dit je terugbetaling? \(entry.amount.formatted()) op \(entry.day.short()) · \(entry.label)")
                            .tag(entry.id)
                    }
                    Text("Nog niet terugbetaald: alleen vastleggen").tag(Int64?.none)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            }
            if let deposit, chosenCount > 0, deposit.amount != total {
                let difference = deposit.amount - total
                Label("De storting is \(difference.magnitude.formatted()) \(difference > .zero ? "hoger" : "lager") dan het voorgeschoten bedrag. Dat kan gewoon; het verschil wordt vastgelegd.",
                      systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func historyRow(_ detail: SettlementDetail) -> some View {
        let s = detail.settlement
        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text("\(s.day.short(withYear: true)) · \(s.amount.formatted())").monospacedDigit()
                Text(s.isOpening ? "Beginstand" :
                        (detail.startAmount.isZero ? "" : "startbedrag \(detail.startAmount.formatted()) + ")
                        + "\(TransactionsFormat.entries(detail.entries.count)) · " + (detail.deposit.map { "storting \($0.amount.formatted()) op \($0.day.short())" } ?? "nog geen storting gekoppeld"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let d = target.deposit, detail.deposit == nil, !s.isOpening, let id = s.id {
                Button("Koppel deze storting") { store.linkDeposit(model, settlementId: id, depositEntryId: d.id) }
                    .help("Koppelt de bijschrijving van \(d.amount.formatted()) als terugbetaling")
            }
            if !s.isOpening, let id = s.id {
                Button("Maak ongedaan") { store.deleteSettlement(model, settlementId: id) }
                    .help("Verwijdert deze terugbetaling; de boekingen staan daarna weer open")
            }
        }
        .controlSize(.small)
        .font(.callout)
    }

    private func load() {
        let tagId = target.tagId
        open = model.read([]) { try Insight.openSettlementEntries($0, tagId: tagId) }
        start = model.read(nil as SettlementStart?) { try Insight.settlementStart($0, tagId: tagId) }.flatMap { $0.isOpen ? $0 : nil }
        history = model.read([]) { try Insight.settlementHistory($0, tagId: tagId) }
        candidates = target.deposit == nil
            ? model.read([]) { try SettlementService.suggestDeposit($0, tagId: tagId, asOf: model.today) } : []
        if !loaded {
            checked = Set(open.map(\.id))
            startChecked = start != nil
            depositId = candidates.first?.id
            loaded = true
        } else {
            checked.formIntersection(open.map(\.id))
            if !candidates.contains(where: { $0.id == depositId }) { depositId = candidates.first?.id }
        }
    }
}
