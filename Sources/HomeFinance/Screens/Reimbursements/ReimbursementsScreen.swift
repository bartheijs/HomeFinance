import SwiftUI
import HFCore
import HFInsight
import HFBudget

/// Verrekenen met spaar: boekingen op de betaalrekening die uit een pot komen of naar een pot gaan, opgeteld
/// tot één bedrag dat je in één keer overmaakt en hier op verrekend zet.
struct ReimbursementsScreen: View {
    @Environment(AppModel.self) private var model

    @State private var data: ReimbData?
    /// Boekingen die de gebruiker heeft uitgevinkt; alles wat hier niet in staat doet mee.
    @State private var deselected: Set<Int64> = []
    @State private var date = Date()
    @State private var dateTouched = false
    /// Het gekozen paar van betaal- en spaarrekening, als er meer dan één is.
    @State private var groupId: String?
    @State private var showPerPot = false
    @State private var historyOpen = false
    @State private var expanded: Set<Int64> = []
    @State private var toUndo: SavingsTransferDetail?

    private struct ReloadKey: Hashable { let revision: Int, year: Int }

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader("Nog overboeken",
                         subtitle: "Wat je van de betaalrekening betaalde maar uit een pot hoort te komen, en wat binnenkwam maar naar een pot moet: samen één bedrag om over te maken.")
            content
        }
        .task(id: ReloadKey(revision: model.revision, year: model.year)) { reload() }
        .confirmationDialog("Overboeking van \(toUndo?.transferAmount.formatted() ?? "") ongedaan maken?",
                            isPresented: Binding(get: { toUndo != nil }, set: { if !$0 { toUndo = nil } }),
                            presenting: toUndo) { transfer in
            Button("Maak ongedaan", role: .destructive) { undo(transfer) }
            Button("Annuleer", role: .cancel) {}
        } message: { transfer in
            Text("De boekingen van deze overboeking verdwijnen en de \(ReimbFormat.bookings(transfer.entries.count)) staan weer open. Heb je het bedrag al overgemaakt, dan zet je het daarna opnieuw op overgeboekt.")
        }
    }

    // MARK: Inhoud

    @ViewBuilder private var content: some View {
        if let data {
            let groups = data.groups
            let group = groups.first { $0.id == groupId } ?? groups.first
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    ForEach(data.pending) { pendingCard($0) }
                    if let group {
                        if groups.count > 1 { groupPicker(groups, current: group) }
                        let selection = ReimbSelection(entries: group.entries.filter { !deselected.contains($0.id) },
                                                       pots: data.pots)
                        hero(selection, group: group, data: data)
                        lists(group, data: data)
                        if !selection.isEmpty { perPot(selection) }
                    } else {
                        emptyOpen(hasMore: !data.pending.isEmpty || !data.history.isEmpty)
                    }
                    if !data.history.isEmpty { history(data) }
                }
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24).padding(.top, 8).padding(.bottom, 32)
            }
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func emptyOpen(hasMore: Bool) -> some View {
        ContentUnavailableView {
            Label("Er staat niets open", systemImage: "checkmark.circle")
        } description: {
            Text("Heb je iets van de betaalrekening betaald dat uit een pot hoort te komen, of kwam er iets binnen dat naar een pot moet? Zet dan bij die boeking ‘Nog overboeken met spaar’ aan in Nakijken of Transacties. Hij verschijnt daarna hier.")
        } actions: {
            HStack {
                Button("Naar Nakijken") { model.selection = .review }
                Button("Naar Transacties") { model.selection = .transactions }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, hasMore ? 24 : 80)
    }

    /// Meer dan één paar rekeningen: verreken ze één voor één.
    private func groupPicker(_ groups: [ReimbGroup], current: ReimbGroup) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Rekeningen", selection: Binding(get: { current.id }, set: { groupId = $0 })) {
                ForEach(groups) { Text("\($0.title) (\($0.entries.count))").tag($0.id) }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            Text("Er staan boekingen open voor meer dan één paar rekeningen. Je boekt ze per paar over.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    // MARK: Het bedrag en de knop

    private func hero(_ selection: ReimbSelection, group: ReimbGroup, data: ReimbData) -> some View {
        let net = selection.net
        let amount = net.isZero ? selection.fromSavings : net.magnitude
        let betweenPots = net.isZero && !selection.isEmpty
        return VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text(headline(selection)).font(.title3).foregroundStyle(.secondary)
                Text(amount.formatted())
                    .font(.system(size: 44, weight: .semibold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(selection.isEmpty ? Color.secondary : Color.primary)
                    .lineLimit(1).minimumScaleFactor(0.6)
                    .contentTransition(.numericText())
                    .help("Het saldo van de aangevinkte boekingen: wat uit de potten komt min wat naar de potten gaat.")
                if !selection.isEmpty {
                    Text("uit potten \(selection.fromSavings.formatted()) · naar potten \(selection.toSavings.formatted())")
                        .font(.body).monospacedDigit().foregroundStyle(.secondary)
                }
            }

            if !selection.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text(betweenPots
                         ? "Er hoeft niets overgemaakt te worden. Met de knop werkt de app je potten meteen bij."
                         : "Maak het bedrag eerst over in je bank-app. Daarna zet je het hier op overgeboekt; de app werkt je potten en beide rekeningen meteen bij en herkent de overboeking bij je volgende import.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 14) {
                        Button { settle(selection) } label: {
                            Text(betweenPots ? "Boek over tussen potten" : "Ik heb dit overgemaakt").padding(.horizontal, 6)
                        }
                        .buttonStyle(.borderedProminent).controlSize(.extraLarge)
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(selection.withoutPot > 0)
                        .help("Zet de aangevinkte boekingen op overgeboekt en boekt alles meteen (⌘↩).")
                        DatePicker(betweenPots ? "op" : "overgemaakt op",
                                   selection: Binding(get: { date }, set: { date = $0; dateTouched = true }),
                                   displayedComponents: .date)
                            .fixedSize()
                            .foregroundStyle(.secondary)
                            .help("De dag van de overboeking. Standaard vandaag.")
                    }
                    if selection.withoutPot > 0 {
                        Label(selection.withoutPot == 1
                              ? "Bij 1 boeking is nog geen pot gekozen. Kies de pot hieronder, of vink de boeking uit."
                              : "Bij \(selection.withoutPot) boekingen is nog geen pot gekozen. Kies de pot hieronder, of vink ze uit.",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.callout).foregroundStyle(Theme.warning)
                    }
                }
            }
        }
    }

    private func headline(_ selection: ReimbSelection) -> String {
        if selection.isEmpty { return "Niets aangevinkt om over te boeken" }
        if selection.net > .zero { return "Maak over van spaar naar betaal" }
        if selection.net < .zero { return "Maak over van betaal naar spaar" }
        return "Niets over te maken; wel te verschuiven tussen potten"
    }

    // MARK: De boekingen

    @ViewBuilder private func lists(_ group: ReimbGroup, data: ReimbData) -> some View {
        let out = group.entries.filter { $0.amount < .zero }
        let into = group.entries.filter { $0.amount > .zero }
        VStack(alignment: .leading, spacing: 22) {
            if !out.isEmpty {
                list("Komt uit een pot", help: "Uitgaven die je van de betaalrekening deed, maar die een pot betaalt.",
                     entries: out, data: data)
            }
            if !into.isEmpty {
                list("Gaat naar een pot", help: "Bijschrijvingen op de betaalrekening die je doorstort naar een pot.",
                     entries: into, data: data)
            }
        }
    }

    private func list(_ title: String, help: String, entries: [EntryRow], data: ReimbData) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title).font(.title3.weight(.semibold))
                Text("\(entries.count)").font(.callout).foregroundStyle(.secondary)
            }
            .help(help)
            ReimbPanel {
                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                    if index > 0 { Divider().padding(.leading, 18) }
                    ReimbOpenRow(entry: entry, selected: !deselected.contains(entry.id), pots: data.potChoices,
                                 toggle: { toggle(entry.id) },
                                 setPot: { setPot(entry, potId: $0) },
                                 stopSettling: { stopSettling(entry) })
                }
            }
        }
    }

    private func perPot(_ selection: ReimbSelection) -> some View {
        ReimbPanel {
            disclosureHeader("Per pot", count: selection.perPot.count, open: showPerPot,
                             help: "Wat elke pot uit gaat of in komt, en het saldo van de pot erna.") {
                showPerPot.toggle()
            }
            if showPerPot {
                Divider().padding(.leading, 18)
                ReimbPerPotList(shares: selection.perPot)
            }
        }
    }

    private func disclosureHeader(_ title: String, count: Int, open: Bool, help: String,
                                  action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { action() }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "chevron.right")
                    .font(.callout.weight(.semibold)).foregroundStyle(.secondary)
                    .rotationEffect(.degrees(open ? 90 : 0))
                    .frame(width: 14)
                Text(title).font(.title3.weight(.semibold))
                Text("\(count)").font(.callout).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 18).padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: Vastgelegd maar nog niet verrekend

    /// Een verrekening die wel is vastgelegd maar nog niet afgevinkt (uit een eerdere versie van de app).
    private func pendingCard(_ transfer: SavingsTransferDetail) -> some View {
        ReimbPanel(tint: Theme.warning) {
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Vastgelegd op \(transfer.day.short(withYear: true)), nog niet overgeboekt").font(.callout).foregroundStyle(.secondary)
                    Text("\(transfer.transferAmount.formatted()) \(ReimbFormat.direction(transfer.direction))")
                        .font(.title3.weight(.medium)).monospacedDigit()
                    Text(ReimbFormat.bookings(transfer.entries.count)).font(.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                Button("Toch niet…") { toUndo = transfer }
                    .help("Verwijdert deze overboeking; de boekingen staan dan weer open.")
                Button("Zet op overgeboekt") { markDone(transfer) }
                    .buttonStyle(.borderedProminent)
                    .help("Boekt deze overboeking op de gekozen datum en werkt de potten bij.")
            }
            .padding(18)
        }
    }

    // MARK: Eerdere verrekeningen

    private func history(_ data: ReimbData) -> some View {
        let waiting = data.history.filter { data.unconfirmed.contains($0.id) }.count
        return ReimbPanel {
            HStack(spacing: 0) {
                disclosureHeader("Eerdere overboekingen", count: data.history.count, open: historyOpen,
                                 help: "Klik om de eerdere overboekingen te tonen of te verbergen.") {
                    historyOpen.toggle()
                }
                if waiting > 0 && !historyOpen {
                    Label(waiting == 1 ? "1 nog niet gezien in de bank" : "\(waiting) nog niet gezien in de bank",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.callout).foregroundStyle(Theme.warning)
                        .padding(.trailing, 18)
                        .help("Deze overboekingen zijn meer dan 5 dagen geleden gedaan, maar de overboeking is nog niet in een bankbestand herkend.")
                }
            }
            if historyOpen {
                ForEach(data.history) { transfer in
                    Divider().padding(.leading, 18)
                    ReimbHistoryRow(transfer: transfer, unconfirmed: data.unconfirmed.contains(transfer.id),
                                    expanded: expanded.contains(transfer.id),
                                    toggle: { toggleExpanded(transfer.id) },
                                    onUndo: { toUndo = transfer })
                }
            }
        }
    }

    // MARK: Laden en kiezen

    private func reload() {
        let loaded = ReimbData.load(model: model)
        deselected.formIntersection(Set(loaded.openEntries.map(\.id)))
        if !dateTouched { date = model.today.date }
        if let id = groupId, !loaded.groups.contains(where: { $0.id == id }) { groupId = nil }
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

    /// Legt de verrekening vast en vinkt hem meteen af: alles wordt in één keer geboekt.
    private func settle(_ selection: ReimbSelection) {
        guard !selection.isEmpty else { return }
        let day = Day(date: date)
        let ids = selection.entries.map(\.id)
        model.perform("Overgeboekt. De potten zijn bijgewerkt.") {
            try model.db.write { db in
                let transfer = try SavingsTransferService.createSavingsTransfer(db, entryIds: ids, day: day)
                guard let id = transfer.id else { return }
                _ = try SavingsTransferService.markDone(db, savingsTransferId: id, on: day)
            }
        }
    }

    private func markDone(_ transfer: SavingsTransferDetail) {
        let day = Day(date: date)
        model.perform("Overgeboekt. De potten zijn bijgewerkt.") {
            try model.db.write { db in _ = try SavingsTransferService.markDone(db, savingsTransferId: transfer.id, on: day) }
        }
    }

    /// Heropenen en verwijderen in één keer. Hangt er al een bankregel aan, dan weigert de service met uitleg.
    private func undo(_ transfer: SavingsTransferDetail) {
        model.perform("Overboeking ongedaan gemaakt; de boekingen staan weer open") {
            try model.db.write { db in
                if transfer.done { _ = try SavingsTransferService.reopen(db, savingsTransferId: transfer.id) }
                try SavingsTransferService.delete(db, savingsTransferId: transfer.id)
            }
        }
    }

    private func setPot(_ entry: EntryRow, potId: Int64?) {
        model.perform {
            try model.db.write { db in _ = try EntryService.setReimburse(db, entryId: entry.id, true, potId: potId) }
        }
    }

    private func stopSettling(_ entry: EntryRow) {
        model.perform("\(entry.label) staat niet meer bij Nog overboeken") {
            try model.db.write { db in _ = try EntryService.setReimburse(db, entryId: entry.id, false, potId: nil) }
        }
    }
}
