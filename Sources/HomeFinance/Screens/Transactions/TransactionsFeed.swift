import SwiftUI
import HFCore
import HFInsight

/// De feed: alle transacties van de gekozen rekening, nieuwste boven, gegroepeerd per dag.
/// Nieuwe (nog niet geboekte) transacties staan er gewoon tussen, met het voorstel als knop.
struct TransactionsFeed: View {
    @Environment(AppModel.self) private var model
    @Bindable var store: TransactionsStore

    var body: some View {
        List(selection: $store.selection) {
            ForEach(store.groups) { group in
                Text(TransactionsFormat.dayTitle(group.day, today: model.today))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.top, 14).padding(.bottom, 2)
                    .listRowSeparator(.hidden)
                    .selectionDisabled()
                ForEach(group.items) { item in
                    TransactionsFeedRow(store: store, item: item)
                        .listRowSeparator(.hidden)
                        .onAppear { if item.id == store.items.last?.id { store.loadMore(model) } }
                }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .contextMenu(forSelectionType: TransactionsItemID.self) { ids in
            if !ids.isEmpty { TransactionsContextMenu(store: store, ids: Array(ids)) }
        } primaryAction: { _ in
            store.showDetail = true
        }
        .onKeyPress(keys: [.return]) { press in
            guard !store.selection.isEmpty else { return .ignored }
            if press.modifiers.contains(.command) {
                store.bookSuggested(model, ids: Array(store.selection))
            } else {
                store.showDetail = true
            }
            return .handled
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "tTvV")) { press in
            guard !store.selection.isEmpty, press.modifiers.isDisjoint(with: [.command, .option, .control]) else { return .ignored }
            if press.characters.lowercased() == "t" {
                store.showTagPicker = true
            } else {
                store.toggleReimburse(model, ids: Array(store.selection))
            }
            return .handled
        }
        .popover(isPresented: $store.showTagPicker, attachmentAnchor: .point(.top), arrowEdge: .top) {
            TransactionsTagPopover(store: store)
        }
    }
}

// MARK: - Regel

private struct TransactionsFeedRow: View {
    @Environment(AppModel.self) private var model
    let store: TransactionsStore
    let item: TransactionsFeedItem
    @State private var hovering = false

    private var locked: Bool { store.isLocked(item) }

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(dotColor)
                .frame(width: 7, height: 7)
                .help(dotHelp)
            avatar
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).lineLimit(1)
                subtitle
            }
            Spacer(minLength: 8)
            if hovering, !locked, store.selection.count <= 1, item.entry?.isSettlementBooking != true, item.pending?.transferMatch == nil {
                quickActions.transition(.opacity)
            }
            TransactionsAmountText(amount: item.amount)
                .font(.body.weight(.medium))
        }
        .frame(minHeight: 44)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help(tooltip)
    }

    private var dotColor: Color {
        if item.pending != nil { return Theme.info }
        if let row = item.entry, !row.reviewed { return Theme.warning }
        return .clear
    }

    private var dotHelp: String {
        if item.pending != nil { return "Nieuw: deze transactie van de bank is nog niet geboekt" }
        if let row = item.entry, !row.reviewed { return "Nog nakijken: automatisch geboekt en nog niet door jou gecontroleerd" }
        return ""
    }

    private var avatar: some View {
        ZStack {
            Circle().fill(Color.primary.opacity(0.06))
            if item.entry?.isSettlementBooking == true || item.pending?.transferMatch != nil {
                Image(systemName: "arrow.triangle.swap").font(.system(size: 13, weight: .semibold))
            } else if item.entry?.counterEntryId != nil {
                Image(systemName: "arrow.left.arrow.right").font(.system(size: 12, weight: .semibold))
            } else {
                Text(String(item.title.first { $0.isLetter || $0.isNumber } ?? "•").uppercased())
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
            }
        }
        .foregroundStyle(.secondary)
        .frame(width: 34, height: 34)
    }

    // MARK: Onderregel

    @ViewBuilder private var subtitle: some View {
        if let p = item.pending {
            suggestionButton(p)
        } else if let row = item.entry {
            Text(entrySubtitle(row))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private func entrySubtitle(_ row: EntryRow) -> String {
        var parts: [String] = []
        switch row.accountKind {
        case .betaal: parts.append(row.itemLabel ?? "Divers")
        case .spaar: parts.append(row.potName.map { "Pot \($0)" } ?? "Nog geen pot")
        }
        // Een verrekende boeking krijgt een vinkje bij zijn tag.
        parts.append(contentsOf: row.tags.map { tag in
            row.settlementId != nil && store.lookups.tag(tag.id)?.settles == true ? "\(tag.name) ✓" : tag.name
        })
        if let month = TransactionsFormat.month(of: row.period) { parts.append("telt in \(Day.monthNamesShort[month - 1])") }
        if let direction = row.settlementDirection {
            if let id = row.savingsTransferId, store.lookups.doneTransferIds.contains(id) {
                parts.append("verrekend")
            } else {
                let pot = row.potName.map { "pot \($0)" } ?? "spaar"
                parts.append(direction == .fromPot ? "uit \(pot)" : "naar \(pot)")
            }
        }
        if row.temporaryLoan { parts.append(row.amount.isNegative ? "terug naar spaar" : "tijdelijk geleend") }
        if let bank = row.bank, bank.amount != row.amount { parts.append("gesplitst") }
        if row.bankTransactionId == nil { parts.append("handinvoer") }
        if !row.reviewed { parts.append("nog nakijken") }
        return parts.joined(separator: " · ")
    }

    /// Wat de regels voorstellen, als tekst; nil als er iets te kiezen valt.
    private func suggestionTarget(_ p: TransactionsPending) -> String? {
        guard p.hasSuggestion else { return nil }
        if let match = p.bookableMatch, let distribution = match.distribution {
            if match.side == .destination { return "\(distribution.name): verdeeld over \(match.allocations.count) potten" }
            return store.lookups.item(match.allocations.first?.budgetItemId)?.label ?? distribution.name
        }
        switch store.kind {
        case .betaal: return p.suggestion.targetItemLabel ?? "Divers"
        case .spaar: return store.lookups.pot(p.suggestion.potId)?.name
        }
    }

    @ViewBuilder private func suggestionButton(_ p: TransactionsPending) -> some View {
        if locked {
            Label("Jaar afgesloten", systemImage: "lock.fill").font(.caption).foregroundStyle(.secondary)
        } else if let transferMatch = p.transferMatch {
            Button {
                if let transfer = transferMatch.transfer {
                    store.attachTransfer(model, p, transfer: transfer)
                } else {
                    store.selection = [item.id]
                    store.showDetail = true
                }
            } label: {
                Text(transferMatch.isAmbiguous ? "Kies welke verrekening…"
                     : (transferMatch.needsMarkDone ? "Afvinken en aanhangen" : "Aanhangen aan verrekening"))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 9).padding(.vertical, 3)
                    .background(Theme.accent.opacity(0.15), in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("Dit is de overboeking van een verrekening met spaar. Hij wordt niet opnieuw geboekt, maar aan de verrekening gehangen.")
        } else if let match = p.match, p.bookableMatch == nil {
            // Vaste storting herkend, maar er valt nog iets te kiezen: het detail laat de verdeling zien.
            Button {
                store.selection = [item.id]
                store.showDetail = true
            } label: {
                Text(match.isAmbiguous ? "Vaste storting: kies welke…" : "\(match.distribution?.name ?? "Vaste storting"): bedrag wijkt af…")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Theme.warning)
                    .padding(.horizontal, 9).padding(.vertical, 3)
                    .background(Theme.warning.opacity(0.13), in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("Deze transactie past bij een vaste storting, maar niet precies. Klik om de verdeling te zien en te kiezen waar het verschil heen gaat.")
        } else if let target = suggestionTarget(p) {
            Button {
                store.bookSuggested(model, [p])
            } label: {
                HStack(spacing: 4) {
                    Text(target).lineLimit(1)
                    Image(systemName: p.isCertain ? "checkmark" : "questionmark").font(.system(size: 9, weight: .bold))
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(Theme.accent)
                .padding(.horizontal, 9).padding(.vertical, 3)
                .background(Theme.accent.opacity(p.isCertain ? 0.15 : 0.08), in: Capsule())
                .overlay(Capsule().strokeBorder(Theme.accent.opacity(p.isCertain ? 0 : 0.35), style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("\(p.suggestion.reason)\nKlik om zo te boeken (⌘⏎). \(p.isCertain ? "" : "De regels zijn hier niet zeker van.")")
        } else {
            Menu {
                TransactionsAssignMenuItems(store: store, ids: [item.id])
            } label: {
                Text(store.kind == .betaal ? "Kies post…" : "Kies pot…")
                    .font(.caption.weight(.medium))
            }
            .menuStyle(.button)
            .buttonStyle(.bordered)
            .controlSize(.mini)
            .fixedSize()
            .help(p.suggestion.warnings.isEmpty ? "Geen regel herkent deze transactie. Kies waar hij bij hoort; de app onthoudt het."
                                                : p.suggestion.warnings.joined(separator: "\n"))
        }
    }

    private var tooltip: String {
        if let p = item.pending {
            return [p.transaction.counterpartyName, p.transaction.descriptionText].filter { !$0.isEmpty }.joined(separator: "\n")
        }
        guard let row = item.entry else { return "" }
        var lines: [String] = []
        if let bank = row.bank {
            if !bank.counterpartyName.isEmpty { lines.append(bank.counterpartyName) }
            if !bank.descriptionText.isEmpty { lines.append(bank.descriptionText) }
        }
        if !row.note.isEmpty { lines.append("Notitie: \(row.note)") }
        return lines.joined(separator: "\n")
    }

    // MARK: Snelle acties bij aanwijzen

    private var quickActions: some View {
        HStack(spacing: 5) {
            if let p = item.pending {
                if p.hasSuggestion {
                    Button { store.bookSuggested(model, [p]) } label: { TransactionsIconLabel(icon: "checkmark") }
                        .help("Boek volgens voorstel")
                }
                iconMenu(store.kind == .betaal ? "tablecells" : "tray.full", help: store.kind == .betaal ? "Toewijzen aan post…" : "Toewijzen aan pot…") {
                    TransactionsAssignMenuItems(store: store, ids: [item.id])
                }
                iconMenu("ellipsis", help: "Meer acties") {
                    Button("Splitsen…", systemImage: "square.split.2x1") { store.startSplit(model, item) }
                    Button("Sla over", systemImage: "forward.end") { store.skip(model, ids: [item.id]) }
                }
            } else if let row = item.entry {
                iconMenu(store.kind == .betaal ? "tablecells" : "tray.full", help: store.kind == .betaal ? "Toewijzen aan post…" : "Toewijzen aan pot…") {
                    TransactionsAssignMenuItems(store: store, ids: [item.id])
                }
                iconMenu("tag", help: "Tag aan of uit") {
                    TransactionsTagMenuItems(store: store, ids: [item.id])
                }
                if row.accountKind == .betaal, !row.amount.isZero {
                    Menu {
                        TransactionsSettleMenuItems(store: store, ids: [item.id])
                    } label: {
                        TransactionsIconLabel(icon: "arrow.triangle.swap", active: row.reimburse)
                    }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                    .help("Verrekenen met spaar… " + TransactionsFormat.settleHelp)
                }
                iconMenu("ellipsis", help: "Meer acties") {
                    if row.bankTransactionId != nil {
                        Button("Splitsen…", systemImage: "square.split.2x1") { store.startSplit(model, item) }
                    }
                    Button("Notitie…", systemImage: "note.text") { store.startNote(model, ids: [item.id]) }
                    if row.accountKind == .betaal {
                        Button(row.temporaryLoan ? "Niet meer tijdelijk geleend" : "Tijdelijk geleend van spaar", systemImage: "hourglass") {
                            store.toggleTemporaryLoan(model, ids: [item.id])
                        }
                        .help(TransactionsFormat.loanHelp)
                    }
                    Button(row.reviewed ? "Zet terug op nakijken" : "Nagekeken", systemImage: row.reviewed ? "circle.dotted" : "checkmark.circle") {
                        store.setReviewed(model, ids: [item.id], !row.reviewed)
                    }
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func iconMenu<Content: View>(_ icon: String, help: String, @ViewBuilder content: () -> Content) -> some View {
        Menu(content: content) { TransactionsIconLabel(icon: icon) }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(help)
    }
}

// MARK: - Menu's

/// Inhoud van "Toewijzen aan post/pot": het voorstel en de laatst gebruikte keuzes bovenaan.
struct TransactionsAssignMenuItems: View {
    @Environment(AppModel.self) private var model
    let store: TransactionsStore
    let ids: [TransactionsItemID]

    var body: some View {
        let chosen = store.items.filter { ids.contains($0.id) }
        let suggestion = chosen.count == 1 ? chosen[0].pending.flatMap { $0.hasSuggestion ? $0.suggestion : nil } : nil
        switch store.kind {
        case .betaal:
            let items = store.lookups.items(year: chosen.first?.day.year ?? model.year)
            if let label = suggestion?.targetItemLabel {
                Section("Voorstel") { Button(label) { store.assign(model, ids: ids, itemLabel: label) } }
            }
            let recents = store.recentItemLabels.filter { label in items.contains { $0.label == label } }
            if !recents.isEmpty {
                Section("Laatst gebruikt") {
                    ForEach(recents, id: \.self) { label in Button(label) { store.assign(model, ids: ids, itemLabel: label) } }
                }
            }
            Section {
                Button("Divers (geen vaste post)") { store.assign(model, ids: ids, itemLabel: nil) }
            }
            let expense = items.filter { $0.direction == .UIT }, income = items.filter { $0.direction == .IN }
            if !expense.isEmpty {
                Section("UIT") { ForEach(expense) { item in Button(item.label) { store.assign(model, ids: ids, itemLabel: item.label) } } }
            }
            if !income.isEmpty {
                Section("IN") { ForEach(income) { item in Button(item.label) { store.assign(model, ids: ids, itemLabel: item.label) } } }
            }
        case .spaar:
            let pots = store.lookups.pots(accountId: store.accountId)
            if let pot = store.lookups.pot(suggestion?.potId) {
                Section("Voorstel") { Button(pot.name) { store.assign(model, ids: ids, potId: pot.id) } }
            }
            let recents = store.recentPotIds.compactMap { id in pots.first { $0.id == id } }
            if !recents.isEmpty {
                Section("Laatst gebruikt") {
                    ForEach(recents) { pot in Button(pot.name) { store.assign(model, ids: ids, potId: pot.id) } }
                }
            }
            Section {
                Button("Niet toegewezen") { store.assign(model, ids: ids, potId: nil) }
            }
            Section("Potten") {
                ForEach(pots) { pot in Button(pot.name) { store.assign(model, ids: ids, potId: pot.id) } }
            }
        }
    }
}

/// Tags aan en uit; een vinkje als alle gekozen boekingen de tag hebben.
struct TransactionsTagMenuItems: View {
    @Environment(AppModel.self) private var model
    let store: TransactionsStore
    let ids: [TransactionsItemID]

    var body: some View {
        let rows = store.items.filter { ids.contains($0.id) }.compactMap(\.entry)
        ForEach(store.lookups.tags) { tag in
            let id = tag.id ?? 0
            let isOn = !rows.isEmpty && rows.allSatisfy { $0.tags.contains { $0.id == id } }
            Button {
                store.toggleTag(model, ids: ids, tagId: id)
            } label: {
                if isOn { Label(tag.name, systemImage: "checkmark") } else { Text(tag.name) }
            }
        }
        if store.lookups.tags.isEmpty {
            Text("Nog geen tags; maak ze bij Instellingen › Tags")
        }
    }
}

/// Het contextmenu van één of meer regels: dezelfde acties als de knoppen bij aanwijzen en in het detail.
struct TransactionsContextMenu: View {
    @Environment(AppModel.self) private var model
    let store: TransactionsStore
    let ids: [TransactionsItemID]

    var body: some View {
        let chosen = store.items.filter { ids.contains($0.id) }
        let rows = chosen.compactMap(\.entry)
        let news = chosen.compactMap(\.pending)
        let expenses = rows.filter { $0.accountKind == .betaal && !$0.amount.isZero }
        let locked = chosen.contains { store.isLocked($0) }
        if chosen.contains(where: { $0.entry?.isSettlementBooking == true || $0.pending?.transferMatch != nil }) {
            Button("Naar Spaaroverboekingen", systemImage: "arrow.triangle.swap") { model.selection = .reimbursements }
        } else {
        Group {
            if news.contains(where: \.hasSuggestion) {
                Button(news.count > 1 ? "Boek volgens voorstel (\(news.filter(\.hasSuggestion).count))" : "Boek volgens voorstel",
                       systemImage: "checkmark.circle") {
                    store.bookSuggested(model, ids: ids)
                }
            }
            Menu(store.kind == .betaal ? "Toewijzen aan post" : "Toewijzen aan pot", systemImage: store.kind == .betaal ? "tablecells" : "tray.full") {
                TransactionsAssignMenuItems(store: store, ids: ids)
            }
            if !rows.isEmpty {
                Menu("Tag", systemImage: "tag") { TransactionsTagMenuItems(store: store, ids: ids) }
            }
            if !expenses.isEmpty {
                Menu("Verrekenen met spaar…", systemImage: "arrow.triangle.swap") {
                    TransactionsSettleMenuItems(store: store, ids: ids)
                }
            }
            if rows.contains(where: { $0.accountKind == .betaal }) {
                Button(rows.filter { $0.accountKind == .betaal }.allSatisfy(\.temporaryLoan) ? "Niet meer tijdelijk geleend" : "Tijdelijk geleend van spaar",
                       systemImage: "hourglass") {
                    store.toggleTemporaryLoan(model, ids: ids)
                }
                .help(TransactionsFormat.loanHelp)
            }
            if chosen.count == 1, let row = rows.first, row.accountKind == .betaal, !row.amount.isNegative {
                ForEach(store.lookups.tags.filter(\.settles)) { tag in
                    Button("Verrekening \(tag.name)…", systemImage: "arrow.left.arrow.right") {
                        store.startSettle(tagId: tag.id ?? 0, deposit: row)
                    }
                    .help("Deze bijschrijving is de terugstorting voor \(tag.name)")
                }
            }
            if chosen.count == 1, let item = chosen.first {
                Divider()
                if item.bankTransactionId != nil {
                    Button("Splitsen…", systemImage: "square.split.2x1") { store.startSplit(model, item) }
                }
                if item.entry != nil {
                    Button("Notitie…", systemImage: "note.text") { store.startNote(model, ids: ids) }
                }
            }
            Divider()
            if rows.contains(where: { !$0.reviewed }) {
                Button("Nagekeken", systemImage: "checkmark.circle") { store.setReviewed(model, ids: ids, true) }
            }
            if rows.contains(where: \.reviewed) {
                Button("Zet terug op nakijken", systemImage: "circle.dotted") { store.setReviewed(model, ids: ids, false) }
            }
            if !news.isEmpty {
                Button(news.count > 1 ? "Sla over (\(news.count))" : "Sla over", systemImage: "forward.end") {
                    store.skip(model, ids: ids)
                }
            }
        }
        .disabled(locked)
        }
    }
}

/// Inhoud van "Verrekenen met spaar…": de pot kiezen (uitgave: komt uit pot, bijschrijving: gaat naar pot) of uitzetten.
struct TransactionsSettleMenuItems: View {
    @Environment(AppModel.self) private var model
    let store: TransactionsStore
    let ids: [TransactionsItemID]

    var body: some View {
        let rows = store.items.filter { ids.contains($0.id) }.compactMap(\.entry)
            .filter { $0.accountKind == .betaal && !$0.amount.isZero }
        let allOut = rows.allSatisfy { $0.amount.isNegative }, allIn = rows.allSatisfy { !$0.amount.isNegative }
        let current = rows.count == 1 && rows[0].reimburse ? rows[0].potId : nil
        Section(allOut ? "Komt uit pot" : (allIn ? "Gaat naar pot" : "Verrekenen met pot")) {
            ForEach(store.lookups.pots(accountId: nil, keeping: current)) { pot in
                Button {
                    store.setReimbursePot(model, ids: ids, potId: pot.id)
                } label: {
                    if current != nil, current == pot.id { Label(pot.name, systemImage: "checkmark") } else { Text(pot.name) }
                }
            }
        }
        Section {
            Button("Pot later kiezen") { store.setReimbursePot(model, ids: ids, potId: nil) }
            if rows.contains(where: \.reimburse) {
                Button("Niet meer verrekenen met spaar") {
                    // Staat het overal aan, dan zet de schakelaar het uit.
                    if rows.allSatisfy(\.reimburse) { store.toggleReimburse(model, ids: ids) }
                    else { store.toggleReimburse(model, ids: rows.filter(\.reimburse).map { .entry($0.id) }) }
                }
            }
        }
    }
}

/// Tagkeuze die opent met de toets T.
private struct TransactionsTagPopover: View {
    @Environment(AppModel.self) private var model
    let store: TransactionsStore

    var body: some View {
        let ids = Array(store.selection)
        let rows = store.selectedItems.compactMap(\.entry)
        VStack(alignment: .leading, spacing: 4) {
            Text(rows.count > 1 ? "Tags voor \(TransactionsFormat.entries(rows.count))" : "Tags")
                .font(.headline).padding(.bottom, 4)
            if rows.isEmpty {
                Text("Boek de transactie eerst; daarna kun je tags zetten.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(store.lookups.tags) { tag in
                let id = tag.id ?? 0
                let isOn = !rows.isEmpty && rows.allSatisfy { $0.tags.contains { $0.id == id } }
                Button {
                    store.toggleTag(model, ids: ids, tagId: id)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(isOn ? Color(hex: tag.color) : Color.secondary)
                        Text(tag.name)
                        Spacer()
                    }
                    .padding(.vertical, 3)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(rows.isEmpty)
            }
        }
        .padding(14)
        .frame(width: 220)
    }
}
