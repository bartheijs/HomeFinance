import SwiftUI
import HFCore
import HFInsight
import HFBudget

/// Spaaroverboekingen: uitgaven van de betaalrekening die uit een spaarpot terugbetaald worden.
struct ReimbursementsScreen: View {
    @Environment(AppModel.self) private var model

    @State private var data: ReimbData?
    /// Uitgaven die de gebruiker heeft uitgevinkt; alles wat hier niet in staat doet mee.
    @State private var deselected: Set<Int64> = []
    @State private var date = Date()
    @State private var dateTouched = false
    @State private var expanded: Set<Int64> = []
    @State private var historyOpen = false
    @State private var pendingAction: ReimbPending?

    private struct ReloadKey: Hashable { let revision: Int, year: Int }

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader("Spaaroverboekingen",
                         subtitle: "Uitgaven die je van de betaalrekening hebt betaald, maar die uit een spaarpot horen te komen. Hier maak je er één overboeking van.")
            content
        }
        .task(id: ReloadKey(revision: model.revision, year: model.year)) { reload() }
        .confirmationDialog(dialogTitle,
                            isPresented: Binding(get: { pendingAction != nil }, set: { if !$0 { pendingAction = nil } }),
                            presenting: pendingAction) { action in
            switch action {
            case .delete(let transfer):
                Button("Verwijder overboeking", role: .destructive) { delete(transfer) }
            case .reopen(let transfer):
                Button("Heropen") { reopen(transfer) }
            }
            Button("Annuleer", role: .cancel) {}
        } message: { action in
            switch action {
            case .delete(let transfer):
                Text("De \(ReimbFormat.expenses(transfer.entries.count)) staan daarna weer open om te vergoeden. De boekingen zelf blijven bestaan.")
            case .reopen:
                Text("De overboeking staat daarna weer op 'open', alsof je het bedrag nog niet hebt overgemaakt.")
            }
        }
    }

    private var dialogTitle: String {
        switch pendingAction {
        case .delete(let t): "Overboeking van \(t.amount.formatted()) verwijderen?"
        case .reopen(let t): "Overboeking van \(t.amount.formatted()) heropenen?"
        case nil: ""
        }
    }

    // MARK: Inhoud

    @ViewBuilder private var content: some View {
        if let data {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    ForEach(data.pending) { transfer in
                        ReimbInstructionCard(transfer: transfer,
                                             onDone: { markDone(transfer) },
                                             onCancel: { pendingAction = .delete(transfer) })
                    }
                    if data.openEntries.isEmpty {
                        emptyOpen(hasPending: !data.pending.isEmpty)
                    } else {
                        hero(data)
                        openList(data)
                    }
                    if !data.transfers.isEmpty { history(data) }
                }
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24).padding(.top, 8).padding(.bottom, 32)
            }
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func selectedEntries(_ data: ReimbData) -> [EntryRow] {
        data.openEntries.filter { !deselected.contains($0.id) }
    }

    /// Alles gekozen: het totaal van Insight; anders de som van de aangevinkte boekingen.
    private func amount(_ data: ReimbData, chosen: [EntryRow]) -> Money {
        chosen.count == data.openEntries.count ? (data.open?.transferAmount ?? .zero) : -chosen.map(\.amount).sum()
    }

    private func emptyOpen(hasPending: Bool) -> some View {
        ContentUnavailableView {
            Label("Er staat niets open om te vergoeden", systemImage: "checkmark.circle")
        } description: {
            Text("Heb je iets van de betaalrekening betaald dat uit een spaarpot hoort te komen? Zet dan bij die uitgave 'Vergoeden uit spaar' aan in Nakijken of Transacties. Hij verschijnt daarna hier.")
        } actions: {
            HStack {
                Button("Naar Nakijken") { model.selection = .review }
                Button("Naar Transacties") { model.selection = .transactions }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, hasPending ? 24 : 80)
    }

    /// Eén groot getal met één knop.
    private func hero(_ data: ReimbData) -> some View {
        let chosen = selectedEntries(data)
        let amount = amount(data, chosen: chosen)
        return HStack(alignment: .center, spacing: 24) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Nog over te boeken van spaar").font(.body).foregroundStyle(.secondary)
                Text(amount.formatted())
                    .font(.system(size: 44, weight: .semibold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(chosen.isEmpty ? Color.secondary : Color.primary)
                    .lineLimit(1).minimumScaleFactor(0.6)
                    .contentTransition(.numericText())
                    .help("De som van de aangevinkte uitgaven. Dit bedrag maak je in één keer over van de spaarrekening naar de betaalrekening.")
                if !chosen.isEmpty {
                    ReimbShareLine(shares: ReimbPotShare.shares(for: chosen))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button { create(chosen, amount: amount) } label: {
                Text("Overboeking maken").padding(.horizontal, 6)
            }
            .buttonStyle(.borderedProminent).controlSize(.extraLarge)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(chosen.isEmpty)
            .help("Legt de overboeking vast voor de aangevinkte uitgaven (⌘↩). Daarna maak je het bedrag over in je bank-app.")
        }
    }

    /// De openstaande uitgaven, kort: vinkje, omschrijving, pot en bedrag.
    private func openList(_ data: ReimbData) -> some View {
        let all = data.openEntries
        let chosen = selectedEntries(data)
        return VStack(alignment: .leading, spacing: 10) {
            Text(chosen.count == all.count
                 ? (all.count == 1 ? "Deze uitgave staat open" : "Deze \(all.count) uitgaven staan open")
                 : "\(chosen.count) van \(ReimbFormat.expenses(all.count)) gekozen")
                .font(.title3.weight(.semibold))
            ReimbPanel {
                ForEach(Array(all.enumerated()), id: \.element.id) { index, entry in
                    if index > 0 { Divider().padding(.leading, 18) }
                    ReimbOpenRow(entry: entry, selected: !deselected.contains(entry.id), pots: data.pots,
                                 toggle: { toggle(entry.id) },
                                 setPot: { setPot(entry, potId: $0) },
                                 stopReimbursing: { stopReimbursing(entry) })
                }
            }
            HStack(spacing: 8) {
                Text("Vink uit wat je nu nog niet wilt overboeken.").foregroundStyle(.secondary)
                Spacer(minLength: 12)
                DatePicker("Datum van de overboeking", selection: Binding(get: { date }, set: { date = $0; dateTouched = true }),
                           displayedComponents: .date)
                    .fixedSize()
                    .foregroundStyle(.secondary)
                    .help("De dag waarop je het bedrag overmaakt. Standaard vandaag.")
            }
            .font(.callout)
            .padding(.horizontal, 4)
        }
    }

    /// Eerdere overboekingen, standaard ingeklapt.
    private func history(_ data: ReimbData) -> some View {
        ReimbPanel {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { historyOpen.toggle() }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: "chevron.right")
                        .font(.callout.weight(.semibold)).foregroundStyle(.secondary)
                        .rotationEffect(.degrees(historyOpen ? 90 : 0))
                        .frame(width: 14)
                    Text("Eerdere overboekingen").font(.title3.weight(.semibold))
                    Text("\(data.transfers.count)").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 18).padding(.vertical, 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Klik om de eerdere overboekingen te tonen of te verbergen.")

            if historyOpen {
                ForEach(data.transfers) { transfer in
                    Divider().padding(.leading, 18)
                    ReimbHistoryRow(transfer: transfer, expanded: expanded.contains(transfer.id),
                                    toggle: { toggleExpanded(transfer.id) },
                                    onDone: { markDone(transfer) },
                                    onReopen: { pendingAction = .reopen(transfer) },
                                    onDelete: { pendingAction = .delete(transfer) })
                }
            }
        }
    }

    // MARK: Laden en kiezen

    private func reload() {
        let loaded = ReimbData.load(model: model)
        deselected.formIntersection(Set(loaded.openEntries.map(\.id)))
        if !dateTouched { date = model.today.date }
        data = loaded
    }

    private func toggle(_ id: Int64) {
        if deselected.contains(id) { deselected.remove(id) } else { deselected.insert(id) }
    }

    private func toggleExpanded(_ id: Int64) {
        withAnimation(.easeInOut(duration: 0.15)) {
            if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
        }
    }

    // MARK: Schrijven

    private func create(_ entries: [EntryRow], amount: Money) {
        guard !entries.isEmpty else { return }
        var newId: Int64?
        let ok = model.perform("Overboeking van \(amount.formatted()) vastgelegd") {
            try model.db.write { db in
                newId = try SavingsTransferService.createSavingsTransfer(db, entryIds: entries.map(\.id),
                                                                         day: Day(date: date)).id
            }
        }
        _ = (ok, newId)
    }

    private func markDone(_ transfer: SavingsTransferDetail) {
        model.perform("Overboeking van \(transfer.amount.formatted()) is gedaan") {
            try model.db.write { db in _ = try SavingsTransferService.markDone(db, savingsTransferId: transfer.id) }
        }
    }

    private func reopen(_ transfer: SavingsTransferDetail) {
        model.perform("Overboeking staat weer open") {
            try model.db.write { db in _ = try SavingsTransferService.reopen(db, savingsTransferId: transfer.id) }
        }
    }

    private func delete(_ transfer: SavingsTransferDetail) {
        model.perform("Overboeking verwijderd; de uitgaven staan weer open") {
            try model.db.write { db in try SavingsTransferService.delete(db, savingsTransferId: transfer.id) }
        }
    }

    private func setPot(_ entry: EntryRow, potId: Int64?) {
        model.perform {
            try model.db.write { db in _ = try EntryService.setReimburse(db, entryId: entry.id, true, potId: potId) }
        }
    }

    private func stopReimbursing(_ entry: EntryRow) {
        model.perform("\(entry.label) wordt niet meer vergoed") {
            try model.db.write { db in _ = try EntryService.setReimburse(db, entryId: entry.id, false, potId: nil) }
        }
    }
}
