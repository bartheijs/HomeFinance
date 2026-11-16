import SwiftUI
import HFCore
import HFInsight
import HFBudget

/// Potten en sparen: vervangt de Excel-werkmap van de spaarrekening.
/// Eerste aanblik: drie getallen en de potten met hun saldo. Een klik op een pot opent rechts de details.
struct PotsScreen: View {
    @Environment(AppModel.self) private var model

    @State private var data: PotsData?
    @State private var history: [PotHistoryRow] = []
    /// nil = alle spaarrekeningen.
    @State private var accountId: Int64?
    @State private var selectedPotId: Int64?
    @State private var reserveCollapsed = false
    @State private var savingsCollapsed = false
    @State private var showArchived = false
    @State private var sheet: PotsSheet?
    @State private var potToDelete: PotSummary?
    @FocusState private var listFocused: Bool

    private struct ReloadKey: Hashable {
        let revision: Int, year: Int, accountId: Int64?, potId: Int64?
    }

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader("Potten en sparen", subtitle: subtitle) { headerControls }
            content
        }
        .task(id: ReloadKey(revision: model.revision, year: model.year, accountId: accountId, potId: selectedPotId)) {
            reload()
        }
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .new:
                PotsEditSheet(pot: nil, accounts: activeAccounts, defaultAccountId: accountId, owners: owners,
                              today: model.today, onSaved: { _ in }, onDistributions: { self.sheet = .distributions })
            case .edit(let pot):
                PotsEditSheet(pot: pot, accounts: data?.savingsAccounts ?? [], defaultAccountId: pot.accountId, owners: owners,
                              today: model.today, onSaved: { _ in }, onDistributions: { self.sheet = .distributions })
            case .distributions:
                PotsDistributionsSheet()
            case .openings(let id):
                PotsOpeningSheet(accountId: id, accountName: data?.accountName(id) ?? "de spaarrekening")
            case .move(let pot):
                PotsMoveSheet(from: pot,
                              candidates: (data?.allPots ?? []).filter { $0.accountId == pot.accountId && $0.id != pot.id && !$0.archived },
                              today: model.today)
            }
        }
        .confirmationDialog("Pot \(potToDelete?.name ?? "") verwijderen?",
                            isPresented: Binding(get: { potToDelete != nil }, set: { if !$0 { potToDelete = nil } }),
                            presenting: potToDelete) { pot in
            Button("Verwijder", role: .destructive) { delete(pot) }
            Button("Annuleer", role: .cancel) {}
        } message: { _ in
            Text("De pot heeft geen boekingen en verdwijnt helemaal. Dit kun je niet terugdraaien.")
        }
    }

    // MARK: Kop

    private var subtitle: String {
        "Elke euro op de spaarrekening hoort bij een pot. Klik op een pot voor de details."
    }

    private var activeAccounts: [PotsAccountRef] { (data?.savingsAccounts ?? []).filter { !$0.archived } }

    private var owners: [String] {
        Array(Set((data?.allPots ?? []).compactMap(\.owner).filter { !$0.isEmpty })).sorted()
    }

    @ViewBuilder private var headerControls: some View {
        if let data {
            if data.asOf != model.today {
                Pill("Stand per \(data.asOf.short(withYear: true))", color: Theme.info, icon: "calendar")
                    .help("Je bekijkt een eerder begrotingsjaar. De saldi zijn die van de laatste dag van dat jaar.")
            }
            if data.savingsAccounts.count > 1 {
                Picker("Rekening", selection: $accountId) {
                    Text("Alle spaarrekeningen").tag(Int64?.none)
                    ForEach(data.savingsAccounts) { Text($0.name).tag(Optional($0.id)) }
                }
                .labelsHidden().fixedSize()
            }
            if data.allPots.contains(where: \.archived) {
                Toggle("Toon archief", isOn: $showArchived)
                    .toggleStyle(.checkbox)
                    .help("Laat ook de potten zien die je gearchiveerd hebt.")
            }
            if !data.savingsAccounts.isEmpty {
                Button("Vaste stortingen") { sheet = .distributions }
                    .help("Wat je regelmatig van betaal naar spaar overmaakt, en hoe dat over de potten verdeeld wordt.")
                Button { sheet = .new } label: { Label("Nieuwe pot…", systemImage: "plus") }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut("n", modifiers: .command)
                    .help("Maak een nieuwe reservering of spaarpot (⌘N)")
            }
        }
    }

    // MARK: Inhoud

    @ViewBuilder private var content: some View {
        if let data {
            if data.savingsAccounts.isEmpty {
                EmptyState(title: "Nog geen spaarrekening",
                           message: "Potten verdelen het saldo van een spaarrekening. Voeg eerst bij Instellingen een spaarrekening toe; daarna maak je hier je potten.",
                           icon: "building.columns", actionTitle: "Naar Instellingen") {
                    model.settingsTab = "rekeningen"
                    model.selection = .settings
                }
            } else if data.allPots.isEmpty {
                VStack(spacing: 0) {
                    if let overview = data.overview {
                        VStack(spacing: Theme.spacing) {
                            ForEach(overview.accounts) { account in
                                PotsAccountStrip(account: account, series: data.series[account.id] ?? [], asOf: data.asOf,
                                                 showName: overview.accounts.count > 1, onSelectPot: { _ in })
                            }
                        }
                        .padding(.horizontal, 24)
                    }
                    EmptyState(title: "Nog geen potten",
                               message: "Maak een pot voor elk doel waar je geld voor opzij zet, bijvoorbeeld Wegenbelasting, Vakantie of een spaarpot per kind. Daarna wijs je de boekingen op de spaarrekening aan een pot toe.",
                               icon: "square.grid.3x3.topleft.filled", actionTitle: "Nieuwe pot…") { sheet = .new }
                }
            } else {
                GeometryReader { geo in
                    let compact = geo.size.width < 1080
                    HStack(spacing: 0) {
                        ScrollView {
                            overviewColumn(data)
                                .padding(.horizontal, 24).padding(.top, 8).padding(.bottom, 32)
                        }
                        .frame(maxWidth: .infinity)
                        .focusable()
                        .focusEffectDisabled()
                        .focused($listFocused)
                        .onKeyPress(.downArrow) { step(1, in: data); return .handled }
                        .onKeyPress(.upArrow) { step(-1, in: data); return .handled }
                        if data.pot(selectedPotId) != nil {
                            Divider()
                            detailPanel(data).frame(width: compact ? 380 : 440)
                                .transition(.move(edge: .trailing))
                        }
                    }
                }
                .onAppear { listFocused = true }
            }
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func visible(_ pots: [PotSummary]) -> [PotSummary] {
        showArchived ? pots : pots.filter { !$0.archived }
    }

    private func reservations(_ data: PotsData) -> [PotSummary] {
        visible(data.allPots.filter { $0.kind == .reservering })
    }

    /// Spaarpotten per eigenaar; potten zonder eigenaar als laatste groep.
    private func savingsGroups(_ data: PotsData) -> [(owner: String?, pots: [PotSummary])] {
        (data.overview?.byOwner ?? []).compactMap { group in
            let pots = visible(group.pots.filter { $0.kind == .spaar })
            return pots.isEmpty ? nil : (group.owner, pots)
        }
    }

    private func orderedPots(_ data: PotsData) -> [PotSummary] {
        (reserveCollapsed ? [] : reservations(data)) + (savingsCollapsed ? [] : savingsGroups(data).flatMap(\.pots))
    }

    @ViewBuilder private func overviewColumn(_ data: PotsData) -> some View {
        let reserve = reservations(data)
        let groups = savingsGroups(data)
        let savings = groups.flatMap(\.pots)
        VStack(alignment: .leading, spacing: 28) {
            if let overview = data.overview {
                ForEach(overview.accounts) { account in
                    PotsAccountStrip(account: account, series: data.series[account.id] ?? [], asOf: data.asOf,
                                     showName: overview.accounts.count > 1, onSelectPot: select)
                }
            }

            ForEach(data.openings, id: \.accountId) { opening in
                PotsOpeningBlock(opening: opening, showName: data.openings.count > 1 || (data.overview?.accounts.count ?? 0) > 1) {
                    sheet = .openings(opening.accountId)
                }
            }

            if !data.cancelledPairs.isEmpty {
                PotsCancelledLine(pairs: data.cancelledPairs)
            }

            if !data.unallocated.isEmpty {
                PotsUnallocatedCard(entries: data.unallocated, distributable: data.distributable,
                                    pots: data.allPots, assign: assign, distribute: distribute)
            }

            if !reserve.isEmpty {
                PotsPanel {
                    PotsGroupHeader(title: "Reserveringen",
                                    explanation: "Geld dat je elke maand opzij zet voor rekeningen die per jaar of onregelmatig komen.",
                                    pots: reserve, expanded: !reserveCollapsed) {
                        withAnimation(.easeInOut(duration: 0.2)) { reserveCollapsed.toggle() }
                    }
                    if !reserveCollapsed {
                        ForEach(reserve) { pot in
                            Divider().padding(.leading, 18)
                            PotsRowView(pot: pot, selected: pot.id == selectedPotId) { select(pot.id) }
                        }
                    }
                }
            }

            if !savings.isEmpty {
                PotsPanel {
                    PotsGroupHeader(title: "Sparen",
                                    explanation: "Spaarpotten per gezinslid, met het doel als dat er is.",
                                    pots: savings, expanded: !savingsCollapsed) {
                        withAnimation(.easeInOut(duration: 0.2)) { savingsCollapsed.toggle() }
                    }
                    if !savingsCollapsed {
                        ForEach(groups, id: \.owner) { group in
                            Divider().padding(.leading, 18)
                            PotsOwnerLabel(owner: group.owner)
                            ForEach(group.pots) { pot in
                                PotsRowView(pot: pot, selected: pot.id == selectedPotId) { select(pot.id) }
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: 760, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func detailPanel(_ data: PotsData) -> some View {
        if let pot = data.pot(selectedPotId) {
            PotsDetailPanel(pot: pot, accountName: data.accountName(pot.accountId), history: history, asOf: data.asOf,
                            onMove: { sheet = .move(pot) },
                            onEdit: { sheet = .edit(pot) },
                            onArchive: { archive(pot) },
                            onUnarchive: { unarchive(pot) },
                            onDelete: { potToDelete = pot },
                            onClose: { withAnimation(.easeInOut(duration: 0.2)) { selectedPotId = nil } },
                            onDistributions: { sheet = .distributions })
                .id(pot.id)
        }
    }

    // MARK: Laden en kiezen

    private func reload() {
        var loaded = PotsData.load(model: model, accountId: accountId)
        // Een rekening die niet meer bestaat: terug naar alle rekeningen.
        if let id = accountId, !loaded.savingsAccounts.contains(where: { $0.id == id }) {
            accountId = nil
            loaded = PotsData.load(model: model, accountId: nil)
        }
        if let id = selectedPotId, loaded.pot(id) == nil { selectedPotId = nil }
        if let id = selectedPotId, loaded.pot(id) != nil {
            history = model.read([]) { try Insight.potHistory($0, potId: id) }
        } else {
            history = []
        }
        data = loaded
    }

    private func select(_ id: Int64) {
        withAnimation(.easeInOut(duration: 0.2)) { selectedPotId = id }
        listFocused = true
    }

    private func step(_ delta: Int, in data: PotsData) {
        let pots = orderedPots(data)
        guard !pots.isEmpty else { return }
        let current = pots.firstIndex { $0.id == selectedPotId }
        let next = min(pots.count - 1, max(0, (current ?? (delta > 0 ? -1 : pots.count)) + delta))
        select(pots[next].id)
    }

    // MARK: Schrijven

    private func assign(_ entry: EntryRow, to potId: Int64) {
        let name = data?.pot(potId)?.name ?? "de pot"
        model.perform("Toegewezen aan \(name)") {
            try model.db.write { db in
                var draft = try EntryService.draft(db, entryId: entry.id)
                draft.potId = potId
                try EntryService.update(db, entryId: entry.id, draft)
            }
        }
    }

    private func distribute(_ entry: EntryRow) {
        guard let bankTransactionId = entry.bankTransactionId else { return }
        model.perform("Verdeeld over de reserveringspotten") {
            try model.db.write { db in
                guard let split = try PotService.distribution(db, for: entry.amount, accountId: entry.accountId) else { return }
                // De gebruiker verdeelt zelf, dus de regels zijn meteen nagekeken.
                let reviewed = split.map { line -> Allocation in var l = line; l.reviewed = true; return l }
                try BookingService.book(db, bankTransactionId: bankTransactionId, allocations: reviewed)
            }
        }
    }

    private func archive(_ pot: PotSummary) {
        model.perform("Pot \(pot.name) gearchiveerd") {
            try model.db.write { db in try PotService.archive(db, potId: pot.id) }
        }
    }

    private func unarchive(_ pot: PotSummary) {
        model.perform("Pot \(pot.name) staat weer in de lijst") {
            try model.db.write { db in try PotService.unarchive(db, potId: pot.id) }
        }
    }

    private func delete(_ pot: PotSummary) {
        model.perform("Pot \(pot.name) verwijderd") {
            try model.db.write { db in try PotService.delete(db, potId: pot.id) }
        }
    }
}
