import SwiftUI
import HFCore
import HFInsight
import HFBudget
import HFRules

/// Het paneel rechts: één transactie in detail, of de acties voor een selectie van meer regels.
struct TransactionsDetailPanel: View {
    @Bindable var store: TransactionsStore

    var body: some View {
        Group {
            if store.selection.count > 1 {
                TransactionsMultiDetail(store: store)
            } else if let item = store.single {
                TransactionsSingleDetail(store: store, item: item)
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.card)
    }
}

private struct TransactionsCloseButton: View {
    let store: TransactionsStore
    var body: some View {
        Button { store.closeDetail() } label: {
            Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .background(Color.primary.opacity(0.07), in: Circle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.cancelAction)
        .help("Sluit het detail (esc)")
    }
}

// MARK: - Eén transactie

private struct TransactionsSingleDetail: View {
    @Environment(AppModel.self) private var model
    @Bindable var store: TransactionsStore
    let item: TransactionsFeedItem
    @State private var confirmUnbook = false
    @State private var confirmDelete = false
    /// Het regelconcept van "Voortaan zo indelen" in de regeleditor.
    @State private var editingRule: TransactionsRuleEdit?

    private var row: EntryRow? { item.entry }
    private var pending: TransactionsPending? { item.pending }
    private var locked: Bool { store.isLocked(item) }
    private var isManual: Bool { row != nil && row?.bankTransactionId == nil }
    private var inTransfer: Bool { row?.savingsTransferId != nil }
    private var ids: [TransactionsItemID] { [item.id] }
    private var canSettle: Bool { store.kind == .betaal && !item.amount.isZero }
    private var isSettlementBooking: Bool { row?.isSettlementBooking == true }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    if locked {
                        Label("Het jaar \(String(item.day.year)) is afgesloten: bekijken kan, wijzigen niet.", systemImage: "lock.fill")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    if isSettlementBooking {
                        settlementBookingBox
                    } else if let p = pending, let transferMatch = p.transferMatch {
                        transferSection(p, transferMatch)
                    } else {
                        if let row, let forecast = store.forecast { forecastBox(forecast, row: row) }
                        if let progress = store.extra.progress { progressBox(progress) }
                        // Dezelfde extra herkenning als in Nakijken (D2).
                        if let p = pending, let proposal = p.proposal {
                            WaitingExtras(proposal: proposal, onDeposit: { store.bookAsDeposit(model, p, $0) },
                                          onShowOther: { store.showOtherHalf(model, of: p) })
                                .disabled(locked)
                        }
                        Group {
                            actionRow
                            if let p = pending, let match = store.matchChoice {
                                TransactionsDistributionSection(store: store, pending: p, match: match)
                                tagsRow
                            } else {
                                assignment
                                tagsRow
                                if canSettle { settleRow }
                            }
                            if store.kind == .betaal {
                                VStack(alignment: .leading, spacing: 3) {
                                    periodRow
                                    Text(TransactionsFormat.periodExplanation)
                                        .font(.caption).foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            more
                        }
                        .disabled(locked)
                    }
                }
                .padding(18)
            }
            Divider()
            footer
        }
        .sheet(item: $editingRule) { edit in
            RuleEditorSheet(rule: edit.rule, isNew: edit.rule.id == nil, year: item.day.year,
                            intro: "Deze regel wordt bewaard als je de transactie boekt.", saveTitle: "Gebruik") { rule in
                guard let p = pending else { return nil }
                return store.setCustomRule(rule, for: p)
            }
        }
        .confirmationDialog("Deze boeking ongedaan maken?", isPresented: $confirmUnbook) {
            Button("Maak ongedaan", role: .destructive) { if let row { store.unbook(model, row: row) } }
            Button("Annuleer", role: .cancel) {}
        } message: {
            Text(store.extra.parts.count > 1
                 ? "Alle \(store.extra.parts.count) delen van deze transactie verdwijnen. De transactie staat daarna weer als nieuw in de lijst."
                 : "De boeking verdwijnt en de transactie staat daarna weer als nieuw in de lijst, klaar om opnieuw te boeken.")
        }
        .confirmationDialog("Deze boeking verwijderen?", isPresented: $confirmDelete) {
            Button("Verwijder", role: .destructive) { if let row { store.delete(model, row: row) } }
            Button("Annuleer", role: .cancel) {}
        } message: {
            Text("‘\(item.title)’ van \(item.amount.formatted()) wordt verwijderd. Dit kun je niet ongedaan maken.")
        }
    }

    // MARK: Kop

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top) {
                Text(item.amount.formatted(alwaysSign: true))
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(item.amount.isNegative ? Color.primary : Theme.positive)
                    .lineLimit(1).minimumScaleFactor(0.7)
                Spacer()
                TransactionsCloseButton(store: store)
            }
            Text(item.title).font(.title3.weight(.medium)).lineLimit(2)
            Text("\(TransactionsFormat.dayTitle(item.day, today: model.today)) · \(store.account?.name ?? "")")
                .font(.callout).foregroundStyle(.secondary)
            if pending != nil {
                Pill("Nieuw, nog niet geboekt", color: Theme.info).padding(.top, 4)
            } else if row?.reviewed == false {
                Pill("Nog niet gecontroleerd", color: Theme.warning).padding(.top, 4)
                    .help("Automatisch geboekt en nog niet door jou gecontroleerd")
            }
        }
    }

    // MARK: Snelle acties

    private var actionRow: some View {
        HStack(spacing: 8) {
            if let p = pending {
                action("checkmark", "Boek volgens voorstel (⌘⏎)", disabled: !p.hasSuggestion) { store.bookSuggested(model, [p]) }
                actionMenu(store.kind == .betaal ? "tablecells" : "tray.full", store.kind == .betaal ? "Indelen bij post…" : "Indelen bij potje…") {
                    TransactionsAssignMenuItems(store: store, ids: ids)
                }
                action("square.split.2x1", "Splitsen…") { store.startSplit(model, item) }
                action("forward.end", "Sla over: niet boeken, bv. omdat je hem al met de hand hebt ingevoerd") { store.skip(model, ids: ids) }
            } else if let row {
                actionMenu(store.kind == .betaal ? "tablecells" : "tray.full", store.kind == .betaal ? "Indelen bij post…" : "Indelen bij potje…") {
                    TransactionsAssignMenuItems(store: store, ids: ids)
                }
                if store.tagsAllowed || !row.tags.isEmpty {
                    actionMenu("tag", store.tagsAllowed ? "Tag aan of uit (T)" : "Tag verwijderen") {
                        TransactionsTagMenuItems(store: store, ids: ids)
                    }
                }
                if canSettle {
                    actionMenu("arrow.triangle.swap", "Nog overboeken met spaar… (V)") { TransactionsSettleMenuItems(store: store, ids: ids) }
                }
                if row.accountKind == .betaal {
                    action("hourglass", (row.temporaryLoan ? "Tijdelijk geleend van spaar staat aan. " : "Tijdelijk geleend van spaar. ") + TransactionsFormat.loanHelp, active: row.temporaryLoan) {
                        store.toggleTemporaryLoan(model, ids: ids)
                    }
                }
                if row.bankTransactionId != nil {
                    action("square.split.2x1", "Splitsen…", disabled: inTransfer) { store.startSplit(model, item) }
                }
                action("note.text", row.note.isEmpty ? "Notitie…" : "Notitie: \(row.note)", active: !row.note.isEmpty) { store.startNote(model, ids: ids) }
                action(row.reviewed ? "checkmark.circle.fill" : "checkmark.circle", row.reviewed ? "Gecontroleerd; klik om terug te zetten op niet gecontroleerd" : "Markeer als gecontroleerd", active: row.reviewed) {
                    store.setReviewed(model, ids: ids, !row.reviewed)
                }
            }
            Spacer(minLength: 0)
        }
        .buttonStyle(.plain)
    }

    private func action(_ icon: String, _ help: String, active: Bool = false, disabled: Bool = false, _ run: @escaping () -> Void) -> some View {
        Button(action: run) { TransactionsIconLabel(icon: icon, active: active, size: 32) }
            .disabled(disabled)
            .opacity(disabled ? 0.4 : 1)
            .help(help)
    }

    private func actionMenu<Content: View>(_ icon: String, _ help: String, @ViewBuilder content: () -> Content) -> some View {
        Menu(content: content) { TransactionsIconLabel(icon: icon, size: 32) }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .help(help)
    }

    // MARK: Waar hoort dit bij?

    private var itemBinding: Binding<Int64?> {
        if pending != nil { return $store.draft.itemId }
        return Binding(get: { row?.budgetItemId },
                       set: { store.assign(model, ids: ids, itemLabel: store.lookups.item($0)?.label) })
    }

    private var potBinding: Binding<Int64?> {
        if pending != nil { return $store.draft.potId }
        return Binding(get: { row?.potId }, set: { store.assign(model, ids: ids, potId: $0) })
    }

    private var assignment: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Waar hoort dit bij?").font(.headline)
            switch store.kind {
            case .betaal:
                TransactionsItemPicker(items: store.lookups.items(year: item.day.year), selection: itemBinding)
                    .help("De vaste post uit je begroting van \(String(item.day.year)). Overig = hoort bij geen vaste post.")
            case .spaar:
                TransactionsPotPicker(pots: store.lookups.pots(accountId: store.accountId, keeping: row?.potId),
                                      noneTitle: "Niet toegewezen", selection: potBinding)
                    .help("Het potje op deze spaarrekening waar het bedrag bij komt of af gaat.")
            }
            if let p = pending {
                Text(p.suggestion.confidence == .geen ? "Geen regel herkent deze transactie. Wat je kiest geldt alleen voor deze boeking."
                                                      : "Voorstel (\(p.suggestion.confidence.title.lowercased())): \(p.suggestion.reason)")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(p.suggestion.warnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(Theme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // Hetzelfde vinkje als in Nakijken (UX-stap D1).
                if let option = store.ruleOption(for: p, model) {
                    RuleConsentChoice(option: option, setOn: { store.setRemember($0) }, edit: { editingRule = TransactionsRuleEdit(rule: $0) })
                        .padding(.top, 4)
                }
            }
        }
    }

    // MARK: Tags

    /// Altijd zichtbaar, ook zonder tags: kiezen of meteen een nieuwe maken.
    private var tagsRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text("Tags").font(.headline)
                Image(systemName: "questionmark.circle").font(.caption).foregroundStyle(.tertiary)
                    .help("Tags volgen waar het geld heen gaat (bv. tanken). Ze tellen niet als extra uitgave.")
            }
            if store.tagsAllowed {
                TransactionsTagEditor(tags: store.lookups.tags, selection: tagBinding, disabled: locked) { name, color, settles in
                    guard let id = store.createTag(model, name: name, color: color, settles: settles, ids: ids) else { return false }
                    // Een nieuwe transactie is nog niet geboekt: de tag gaat mee in de keuzes bij het boeken.
                    if pending != nil { store.draft.tagIds.insert(id) }
                    return true
                }
            } else {
                TransactionsSavingsTags(tags: store.tagsPresent(in: ids)) { store.removeTag(model, ids: ids, tagId: $0) }
            }
        }
    }

    // MARK: Voortgang

    /// Eén regel: wat er nog openstaat voor deze boeking, met een knop naar de plek waar je het rechtzet.
    private func progressBox(_ progress: EntryProgress) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(progress.line).font(.callout.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            Text(progress.explanation).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            switch progress.kind {
            case .toTransfer:
                Button("Naar Nog overboeken") { model.selection = .reimbursements }
                    .controlSize(.small)
                    .help("Open het scherm waar je de overboeking met spaar afvinkt")
            case .toReceive(let tagId, let name):
                Button("Het geld is terug…") { store.startSettle(tagId: tagId) }
                    .controlSize(.small)
                    .help("Open het venster waarin je aangeeft dat je het geld voor \(name) hebt teruggekregen")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.info.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: Verrekenen met spaar

    private var settleRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Nog overboeken met spaar", isOn: reimburseBinding)
                .disabled(inTransfer)
                .help(TransactionsFormat.settleHelp + " (V)")
            if reimburseBinding.wrappedValue {
                HStack(spacing: 8) {
                    Text(item.amount.isNegative ? "Komt uit potje" : "Gaat naar potje").font(.callout).foregroundStyle(.secondary)
                    TransactionsPotPicker(pots: store.lookups.pots(accountId: nil, keeping: reimbursePotBinding.wrappedValue),
                                          noneTitle: "Nog niet gekozen", selection: reimbursePotBinding)
                        .disabled(inTransfer)
                }
            }
            if inTransfer {
                Text(transferText).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Een boeking die een verrekening zelf heeft gemaakt: niets te bewerken hier.
    private var settlementBookingBox: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Hoort bij een overboeking met spaar; ongedaan maken doe je bij Nog overboeken", systemImage: "arrow.triangle.swap")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            if let pot = row?.potName {
                Text("Potje \(pot)").font(.callout).foregroundStyle(.secondary)
            }
            Button("Naar Nog overboeken") { model.selection = .reimbursements }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.background, in: RoundedRectangle(cornerRadius: 8))
    }

    /// Een bankregel die de overboeking van een verrekening met spaar is: aanhangen, niet boeken.
    private func transferSection(_ p: TransactionsPending, _ match: SavingsTransferMatch) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Overboeking met spaar").font(.headline)
            Text(match.isAmbiguous
                 ? "Dit bedrag past bij meer overboekingen bij Nog overboeken. Kies bij welke deze banktransactie hoort."
                 : "Dit is een overboeking met spaar die je bij Nog overboeken hebt vastgelegd. Hij wordt niet opnieuw geboekt, maar eraan gekoppeld.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(match.transfers) { transfer in
                Button {
                    store.attachTransfer(model, p, transfer: transfer)
                } label: {
                    Text("\(transfer.done ? "Koppelen" : "Afvinken en koppelen"): overboeking van \(transfer.day.short(withYear: true)), \(transfer.amount.magnitude.formatted())")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .help(transfer.done ? "Koppelt deze banktransactie aan de boekingen van de afgevinkte overboeking"
                                    : "Vinkt de overboeking af op de dag van deze banktransactie (dan wordt hij geboekt) en koppelt de banktransactie eraan")
            }
            Button("Naar Nog overboeken") { model.selection = .reimbursements }
                .buttonStyle(.link).font(.caption)
        }
        .disabled(locked)
    }

    // MARK: Telt mee in

    private var periodBinding: Binding<String?> {
        if pending != nil { return $store.draft.period }
        return Binding(get: { row?.period }, set: { store.setPeriod(model, ids: ids, period: $0) })
    }

    private var periodRow: some View {
        let current = periodBinding.wrappedValue
        let options = [-1, 0, 1].map { TransactionsFormat.period(item.day, offset: $0) }
        return HStack(spacing: 8) {
            Text("Hoort bij maand").font(.callout).foregroundStyle(.secondary)
            Picker("Hoort bij maand", selection: periodBinding) {
                ForEach(options, id: \.month) { option in
                    Text(Day.monthNames[option.month - 1] + (option.year == item.day.year ? "" : " \(String(option.year))"))
                        .tag(option.key)
                }
                // Een eerder gekozen maand verder weg blijft zichtbaar.
                if let current, !options.contains(where: { $0.key == current }), let month = TransactionsFormat.month(of: current) {
                    Text(Day.monthNames[month - 1]).tag(String?.some(current))
                }
            }
            .labelsHidden()
            .fixedSize()
            Spacer(minLength: 0)
        }
        .help(TransactionsFormat.periodHelp)
    }

    private func forecastBox(_ forecast: ForecastItem, row: EntryRow) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Is dit de verwachte \(forecast.label.isEmpty ? "boeking" : "‘\(forecast.label)’") van \(forecast.amount.magnitude.formatted())?")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Button("Ja, afvinken") { store.realizeForecast(model, forecast, row: row) }
                .help("Vinkt de verwachting van \(forecast.day.short(withYear: true)) af en koppelt deze boeking eraan; hij telt dan niet meer mee in de vooruitblik")
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.info.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: Meer

    private var tagBinding: Binding<Set<Int64>> {
        if pending != nil { return $store.draft.tagIds }
        return Binding(get: { Set(row?.tags.map(\.id) ?? []) },
                       set: { if let row { store.setTags(model, row: row, $0) } })
    }

    private var reimburseBinding: Binding<Bool> {
        if pending != nil { return $store.draft.reimburse }
        return Binding(get: { row?.reimburse ?? false }, set: { _ in store.toggleReimburse(model, ids: ids) })
    }

    private var loanBinding: Binding<Bool> {
        if pending != nil { return $store.draft.temporaryLoan }
        return Binding(get: { row?.temporaryLoan ?? false }, set: { _ in store.toggleTemporaryLoan(model, ids: ids) })
    }

    private var reimbursePotBinding: Binding<Int64?> {
        if pending != nil { return $store.draft.potId }
        return Binding(get: { row?.potId }, set: { store.setReimbursePot(model, ids: ids, potId: $0) })
    }

    private var moreSummary: String {
        var parts: [String] = []
        if !(row?.note ?? store.draft.note).isEmpty { parts.append("notitie") }
        if row?.temporaryLoan ?? store.draft.temporaryLoan { parts.append("tijdelijk geleend van spaar") }
        if store.extra.parts.count > 1 { parts.append("gesplitst") }
        return parts.joined(separator: " · ")
    }

    private var more: some View {
        DisclosureGroup(isExpanded: $store.showMore) {
            VStack(alignment: .leading, spacing: 14) {
                field("Omschrijving") {
                    TransactionsLabelField(title: "Omschrijving", text: $store.draft.label, labels: store.labels, onPick: { suggestion in
                        if let row { store.applyLabel(model, row: row, suggestion) }
                        else { store.draft.adopt(suggestion, lookups: store.lookups, kind: store.kind) }
                    }, onSubmit: { store.saveText(model) })
                }
                if isManual {
                    field("Datum") { TransactionsDayPicker(day: $store.draft.day) }
                    field("Bedrag") {
                        TransactionsAmountInput(isIncome: $store.draft.isIncome, magnitude: $store.draft.magnitude)
                            .id(store.draftVersion)
                    }
                }
                field("Notitie") {
                    TextField("Notitie", text: $store.draft.note, axis: .vertical)
                        .lineLimit(1...4)
                        .textFieldStyle(.roundedBorder)
                }
                if store.kind == .betaal {
                    Toggle("Tijdelijk geleend van spaar", isOn: loanBinding)
                        .help(TransactionsFormat.loanHelp)
                }
                if item.bankTransactionId != nil {
                    Button("Splitsen…", systemImage: "square.split.2x1") { store.startSplit(model, item) }
                        .disabled(inTransfer)
                        .help("Verdeel deze transactie over meer posten, bv. boodschappen en een cadeau op één bon")
                }
                if let row, row.accountKind == .betaal, !row.amount.isNegative {
                    ForEach(store.lookups.tags.filter(\.settles)) { tag in
                        Button("Terugbetaling \(tag.name)…", systemImage: "arrow.left.arrow.right") {
                            store.startSettle(tagId: tag.id ?? 0, deposit: row)
                        }
                        .help("Deze bijschrijving is de terugbetaling van wat je voor \(tag.name) terugkrijgt")
                    }
                }
                if store.extra.parts.count > 1 { partsSection }
                if let counter = store.extra.counter { counterSection(counter) }
                bankSection
                if let row, !locked {
                    Divider()
                    if row.bankTransactionId == nil {
                        Button("Verwijder deze boeking…", role: .destructive) { confirmDelete = true }
                            .disabled(inTransfer)
                    } else {
                        Button("Boeking ongedaan maken…") { confirmUnbook = true }
                            .disabled(inTransfer)
                            .help(inTransfer ? "Kan niet zolang de boeking in een overboeking met spaar zit"
                                             : "Haalt de boeking weg; de transactie staat daarna weer als nieuw in de lijst")
                    }
                }
            }
            .padding(.top, 12)
        } label: {
            HStack(spacing: 8) {
                Text("Meer").font(.headline)
                if !store.showMore, !moreSummary.isEmpty {
                    Text(moreSummary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.easeInOut(duration: 0.15)) { store.showMore.toggle() } }
        }
    }

    private var transferText: String {
        guard let transfer = store.extra.savingsTransfer else { return "Zit in een overboeking met spaar; uitzetten kan bij Nog overboeken." }
        return "Zit in de overboeking van \(transfer.day.short(withYear: true))" + (transfer.done ? " (gedaan)." : " (nog niet gedaan).")
            + " Uitzetten kan bij Nog overboeken."
    }

    private func field<Content: View>(_ title: String, help: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                if let help {
                    Image(systemName: "questionmark.circle").font(.caption2).foregroundStyle(.tertiary).help(help)
                }
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Alleen-lezen delen

    private var bankRows: [(String, String)] {
        if let t = pending?.transaction {
            return [("Tegenpartij", t.counterpartyName), ("Rekening", t.counterpartyIban), ("Omschrijving", t.descriptionText),
                    ("Kenmerk", t.reference), ("Soort", t.transactionCode)]
        }
        guard let bank = row?.bank else { return [] }
        var rows = [("Tegenpartij", bank.counterpartyName), ("Rekening", bank.counterpartyIban), ("Omschrijving", bank.descriptionText),
                    ("Kenmerk", bank.reference), ("Soort", bank.transactionCode)]
        if bank.amount != row?.amount { rows.append(("Bankbedrag", bank.amount.formatted())) }
        return rows
    }

    @ViewBuilder private var bankSection: some View {
        let rows = bankRows.filter { !$0.1.trimmingCharacters(in: .whitespaces).isEmpty }
        if rows.isEmpty {
            Text("Met de hand ingevoerd; er zijn geen gegevens van de bank.").font(.caption).foregroundStyle(.secondary)
        } else {
            field("Gegevens van de bank", help: "Zo leverde de bank deze regel aan. Deze gegevens veranderen nooit.") {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 4) {
                    ForEach(rows, id: \.0) { title, value in
                        GridRow {
                            Text(title).foregroundStyle(.secondary)
                            Text(value).textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .font(.callout)
            }
        }
    }

    private var partsSection: some View {
        field("Gesplitst in \(store.extra.parts.count) delen") {
            VStack(spacing: 0) {
                ForEach(store.extra.parts) { part in
                    let isCurrent = part.id == row?.id
                    Button {
                        if let id = part.id, !isCurrent { store.selection = [.entry(id)] }
                    } label: {
                        HStack(spacing: 6) {
                            Text(part.label).lineLimit(1).fontWeight(isCurrent ? .semibold : .regular)
                            Spacer(minLength: 6)
                            TransactionsAmountText(amount: part.amount)
                        }
                        .font(.callout)
                        .padding(.vertical, 3)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(isCurrent)
                    .help(isCurrent ? "Deze boeking" : "Ga naar dit deel")
                }
            }
        }
    }

    private func counterSection(_ counter: Entry) -> some View {
        field("Overboeking eigen rekening", help: "De andere kant van deze overboeking staat op je andere rekening. Samen is het nul.") {
            HStack {
                Text((counter.amount.isNegative ? "Van " : "Naar ") + (store.extra.counterAccountName ?? "andere rekening"))
                Spacer()
                TransactionsAmountText(amount: counter.amount)
            }
            .font(.callout)
        }
    }

    // MARK: Voet

    private var footer: some View {
        HStack(spacing: 8) {
            if isSettlementBooking || pending?.transferMatch != nil {
                Text("Overboekingen met spaar beheer je bij Nog overboeken").font(.caption).foregroundStyle(.secondary)
                Spacer()
            } else if let p = pending {
                Button("Sla over") { store.skip(model, ids: ids) }
                    .help("Niet boeken, bv. omdat je hem al met de hand hebt ingevoerd")
                Spacer()
                Button("Boek") {
                    if store.matchChoice != nil { store.bookDistribution(model, p) } else { store.book(model, p, with: store.draft) }
                }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(locked || (store.matchChoice.map { $0.distribution == nil }
                                         ?? store.draft.label.trimmingCharacters(in: .whitespaces).isEmpty))
                    .help("Boekt de transactie met deze keuzes (⌘⏎). Een regel wordt alleen bewaard als ‘Voortaan zo indelen’ aan staat.")
            } else {
                Text(store.isTextDirty ? "Getypte tekst is nog niet bewaard" : "Keuzes worden meteen bewaard")
                    .font(.caption).foregroundStyle(store.isTextDirty ? Theme.warning : Color.secondary)
                Spacer()
                Button("Bewaar") { store.saveText(model) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(locked || !store.isTextDirty || !store.draft.isValid)
                    .help("Bewaart omschrijving en notitie (⌘S)")
            }
        }
        .controlSize(.large)
        .padding(.horizontal, 18).padding(.vertical, 12)
    }
}

// MARK: - Meer regels tegelijk

private struct TransactionsMultiDetail: View {
    @Environment(AppModel.self) private var model
    let store: TransactionsStore

    var body: some View {
        let chosen = store.selectedItems
        let ids = chosen.map(\.id)
        let rows = chosen.compactMap(\.entry)
        let news = chosen.compactMap(\.pending)
        let bookable = news.filter(\.hasSuggestion).count
        let locked = chosen.contains { store.isLocked($0) }
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .top) {
                    Text(chosen.map(\.amount).sum().formatted(alwaysSign: true))
                        .font(.system(size: 30, weight: .semibold, design: .rounded)).monospacedDigit()
                        .lineLimit(1).minimumScaleFactor(0.7)
                    Spacer()
                    TransactionsCloseButton(store: store)
                }
                Text("\(TransactionsFormat.number(chosen.count)) transacties gekozen").font(.title3.weight(.medium))
                if !news.isEmpty {
                    Text("\(TransactionsFormat.number(news.count)) nieuw, \(TransactionsFormat.number(rows.count)) geboekt")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            if locked {
                Label("Er zit een afgesloten jaar in de selectie; wijzigen kan niet.", systemImage: "lock.fill")
                    .font(.callout).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 8) {
                if bookable > 0 {
                    Button {
                        store.bookSuggested(model, ids: ids)
                    } label: {
                        Label("Boek volgens voorstel (\(bookable))", systemImage: "checkmark").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .help("Boekt de nieuwe transacties in de selectie volgens het voorstel (⌘⏎)")
                }
                Menu {
                    TransactionsAssignMenuItems(store: store, ids: ids)
                } label: {
                    Label(store.kind == .betaal ? "Indelen bij post" : "Indelen bij potje", systemImage: store.kind == .betaal ? "tablecells" : "tray.full")
                }
                if !rows.isEmpty, store.tagsAllowed || !store.tagsPresent(in: ids).isEmpty {
                    Menu {
                        TransactionsTagMenuItems(store: store, ids: ids)
                    } label: {
                        Label(store.tagsAllowed ? "Tag" : "Tag verwijderen", systemImage: "tag")
                    }
                    .help(store.tagsAllowed ? "Tag aan of uit voor alle gekozen boekingen (T)" : TagRuleText.savings)
                    if rows.contains(where: { $0.accountKind == .betaal && !$0.amount.isZero }) {
                        Button { store.toggleReimburse(model, ids: ids) } label: {
                            Label("Nog overboeken met spaar aan/uit", systemImage: "arrow.triangle.swap").frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .help("Zet ‘Nog overboeken met spaar’ aan voor alle gekozen boekingen; staat het overal al aan, dan gaat het uit (V). Het potje kies je per boeking of via rechtsklik.")
                    }
                    if rows.contains(where: { $0.accountKind == .betaal }) {
                        Button { store.toggleTemporaryLoan(model, ids: ids) } label: {
                            Label("Tijdelijk geleend van spaar aan/uit", systemImage: "hourglass").frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .help(TransactionsFormat.loanHelp)
                    }
                    if rows.contains(where: { !$0.reviewed }) {
                        Button { store.setReviewed(model, ids: ids, true) } label: {
                            Label("Gecontroleerd", systemImage: "checkmark.circle").frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                if !news.isEmpty {
                    Button { store.skip(model, ids: ids) } label: {
                        Label("Sla over (\(news.count))", systemImage: "forward.end").frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .help("De nieuwe transacties in de selectie niet boeken")
                }
            }
            .controlSize(.large)
            .disabled(locked)
            Spacer()
        }
        .padding(18)
    }
}

/// Het regelconcept dat in de regeleditor openstaat (vanuit "Voortaan zo indelen").
private struct TransactionsRuleEdit: Identifiable {
    let id = UUID()
    let rule: Rule
}
