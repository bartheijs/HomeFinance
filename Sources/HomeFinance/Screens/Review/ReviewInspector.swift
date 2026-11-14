import SwiftUI
import HFCore
import HFInsight

/// Rechterpaneel: de ruwe bankgegevens van de gekozen transactie en het voorstel dat je kunt aanpassen.
struct ReviewInspector: View {
    @Environment(AppModel.self) private var model
    @Environment(ReviewStore.self) private var store

    var body: some View {
        VStack(spacing: 0) {
            if let row = store.singleRow {
                ReviewDetail(row: row).id(row.id)
            } else if store.selection.count > 1 {
                multiple
            } else {
                EmptyState(title: "Kies een transactie", message: "Klik links op een regel om het voorstel te bekijken.",
                           icon: "cursorarrow.click")
            }
        }
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius))
    }

    private var multiple: some View {
        let rows = store.selectedRows
        return VStack(spacing: 0) {
            VStack(spacing: 8) {
                Image(systemName: "checklist").font(.system(size: 34)).foregroundStyle(Theme.accent)
                Text("\(rows.count) transacties geselecteerd").font(.title3.weight(.semibold))
                MoneyText(rows.map(\.tx.amount).sum(), colored: true).font(.title3)
                Text("Elke transactie wordt geboekt met het voorstel dat erbij staat. Wat je niet zelf hebt aangepast, blijft in Transacties staan als 'nog na te kijken'.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .padding(24).frame(maxHeight: .infinity)
            HStack {
                Button("Sla selectie over") { store.skipSelection(model) }
                Spacer()
                Button("Boek selectie (\(rows.count))") { store.bookSelection(model) }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
    }
}

/// Eén transactie. Standaard alleen: wat is het, waar hoort het bij, Boek / Sla over.
/// Al het andere staat onder "Meer opties".
private struct ReviewDetail: View {
    @Environment(AppModel.self) private var model
    @Environment(ReviewStore.self) private var store
    let row: ReviewRow

    private var draft: Binding<ReviewDraft> {
        Binding(get: { store.draft(for: row) }, set: { store.setDraft($0, for: row) })
    }
    private var isExpense: Bool { row.tx.amount.isNegative }
    /// Eigen keuze van de gebruiker voor deze transactie; nil = volg de algemene stand.
    @State private var moreOpen: Bool?

    private var moreBinding: Binding<Bool> {
        Binding(get: { moreOpen ?? (store.showMore || store.looksLikeLoanReturn(row)) },
                set: { moreOpen = $0; store.showMore = $0 })
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    head
                    warning
                    target
                    DisclosureGroup(isExpanded: moreBinding) {
                        more.padding(.top, 14)
                    } label: {
                        Text("Meer opties").font(.callout).foregroundStyle(.secondary)
                    }
                }
                .padding(22)
            }
            actions
        }
    }

    // MARK: Wat is het

    private var head: some View {
        let tx = row.tx
        return VStack(alignment: .leading, spacing: 6) {
            Text("\(tx.day.day) \(Day.monthNames[tx.day.month - 1]) \(String(tx.day.year))")
                .font(.callout).foregroundStyle(.secondary)
            Text(row.cleanLabel).font(.system(.title2, design: .rounded).weight(.semibold)).lineLimit(2)
            Text(tx.amount.formatted(alwaysSign: !tx.amount.isNegative))
                .font(.system(size: 30, weight: .semibold, design: .rounded)).monospacedDigit()
                .foregroundStyle(tx.amount.isNegative ? Color.primary : Theme.positive)
        }
    }

    /// Hoogstens één melding: waarom je hier even moet opletten.
    @ViewBuilder private var warning: some View {
        let s = row.suggestion
        let text: String? = if let match = row.match {
            match.warning
        } else if s.amountDiffers, let expected = s.expectedAmount {
            "De regel verwacht \(expected.formatted()). Klopt de post nog?"
        } else if let first = s.warnings.first {
            first
        } else if store.kind == .betaal, !store.yearExists(row.tx.day.year) {
            "Het jaar \(String(row.tx.day.year)) bestaat nog niet. Je kunt alleen als divers boeken."
        } else { nil }
        if let text {
            Label(text, systemImage: "exclamationmark.triangle")
                .font(.callout).foregroundStyle(Theme.warning)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Waar hoort dit bij

    @ViewBuilder private var target: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Waar hoort dit bij?").font(.headline)
            if let match = row.match, match.isAmbiguous {
                Text("Er passen meer vaste stortingen bij deze overboeking. Kies welke het is.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                ForEach(match.distributions) { distribution in
                    Button(distribution.name) { store.chooseDistribution(distribution, for: row, model) }
                }
            }
            if let name = row.match?.distribution?.name, !store.isEdited(row) {
                Label("Vaste storting: \(name)", systemImage: "arrow.triangle.branch").fontWeight(.medium)
                    .help("Een vaste storting is een bedrag dat regelmatig van de betaalrekening naar de spaarrekening gaat en daar over potten wordt verdeeld.")
            }
            if draft.wrappedValue.isSplit {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(draft.wrappedValue.lines.filter { !$0.isDifference }) { line in
                        HStack {
                            Text(store.title(of: line.target, kind: store.kind)).lineLimit(1)
                            Spacer()
                            Text(line.amount?.formatted() ?? "—").monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                }
                if let index = draft.wrappedValue.lines.firstIndex(where: \.isDifference) {
                    differenceChoice(index)
                } else if row.match == nil || store.isEdited(row) {
                    Text("Deze transactie is gesplitst.").font(.callout).foregroundStyle(.secondary)
                }
                Button("Aanpassen…") { moreBinding.wrappedValue = true }.buttonStyle(.link)
            } else {
                ReviewTargetPicker(year: row.tx.day.year, selection: draft.target).controlSize(.large)
                Text(hint).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if store.kind == .betaal { periodChoice }
        }
    }

    /// Het gestorte bedrag wijkt af van de vaste storting: waar gaat het verschil heen?
    private func differenceChoice(_ index: Int) -> some View {
        let amount = draft.wrappedValue.lines[index].amount ?? .zero
        return VStack(alignment: .leading, spacing: 6) {
            Divider()
            HStack {
                Text(amount.isNegative ? "Minder gestort dan de verdeling" : "Meer gestort dan de verdeling")
                Spacer()
                Text(amount.formatted(alwaysSign: true)).monospacedDigit().fontWeight(.semibold).foregroundStyle(Theme.warning)
            }
            HStack {
                Text("Verschil naar").foregroundStyle(.secondary)
                ReviewTargetPicker(year: row.tx.day.year, selection: Binding(
                    get: { draft.wrappedValue.lines.indices.contains(index) ? draft.wrappedValue.lines[index].target : .none },
                    set: { if draft.wrappedValue.lines.indices.contains(index) { draft.wrappedValue.lines[index].target = $0 } }))
            }
            Text("De potten krijgen hun vaste bedrag. Kies een pot voor het verschil, of laat het niet toegewezen.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// In welke maand telt deze boeking mee voor de begroting?
    private var periodChoice: some View {
        HStack(spacing: 6) {
            Text("Telt mee in").foregroundStyle(.secondary)
            Picker("Telt mee in", selection: draft.period) {
                ForEach(store.periodChoices(for: row), id: \.period) { choice in
                    Text(choice.title).tag(choice.period)
                }
            }
            .labelsHidden().fixedSize()
        }
        .font(.callout).controlSize(.small)
        .help("Voor iets dat eind van de maand is betaald maar bij de volgende maand hoort.")
    }

    private var hint: String {
        if store.isEdited(row) { return "Je eigen keuze. De app onthoudt dit voor de volgende keer." }
        if let match = row.match, match.distribution != nil {
            return match.exactAmount ? "Herkend aan de rekeningen en het bedrag van de vaste storting."
                                     : "Herkend aan de rekeningen; het bedrag wijkt \(match.difference.formatted(alwaysSign: true)) af van de vaste storting."
        }
        if row.pair != nil, draft.wrappedValue.target == .none { return "Dit lijkt een overboeking tussen je eigen rekeningen." }
        switch row.suggestion.confidence {
        case .hoog: return "Voorstel van een regel: tegenpartij en bedrag kloppen."
        case .midden: return "Voorstel van een regel. Kijk even of het klopt."
        case .laag: return "Een gok op basis van het bedrag. Kijk even of het klopt."
        case .geen: return "Geen regel gevonden. Kies zelf; de app onthoudt je keuze."
        }
    }

    // MARK: Meer opties

    private var more: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Omschrijving").font(.callout).foregroundStyle(.secondary)
                ReviewLabelField(text: draft.label)
                    .help("De leesbare naam van deze boeking. De tekst van de bank blijft bewaard.")
            }
            if !store.tags.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Tags").font(.callout).foregroundStyle(.secondary)
                    ReviewFlow(spacing: 6) {
                        ForEach(store.tags) { tag in ReviewTagChip(tag: tag, isOn: tagBinding(tag.id ?? 0)) }
                    }
                }
                .help("Tags volgen een soort uitgave (tanken, uit eten) dwars door de posten heen. Ze tellen niet als extra uitgave.")
            }
            if store.kind == .betaal, isExpense, !draft.wrappedValue.isSplit {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Vergoeden uit spaar", isOn: draft.reimburse)
                        .help("Deze uitgave is voorgeschoten van de betaalrekening en wordt later vanaf de spaarrekening terugbetaald. Hij komt in Spaaroverboekingen te staan.")
                    if draft.wrappedValue.reimburse {
                        Picker("Uit pot", selection: draft.reimbursePotId) {
                            Text("Nog niet gekozen").tag(Int64?.none)
                            potSections()
                        }
                        .help("De pot op de spaarrekening die deze uitgave betaalt.")
                    }
                }
            }
            if store.kind == .betaal, !draft.wrappedValue.isSplit {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Tijdelijk geleend van spaar", isOn: draft.temporaryLoan)
                        .help("Geld dat je even van spaar haalt en later terugboekt. Het telt niet mee als besteedbaar zolang het uitstaat. Markeer ook de terugboeking.")
                    if store.looksLikeLoanReturn(row) {
                        Text("Er staat \(store.loanOutstanding.formatted()) uit; dit lijkt de terugboeking.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Splitsen over meer posten", isOn: splitBinding)
                    .help("Verdeel deze transactie over meer posten of potten, bijvoorbeeld boodschappen en een cadeau op één bon.")
                if draft.wrappedValue.isSplit { ReviewSplitEditor(row: row, draft: draft) }
            }
            TextField("Notitie", text: draft.note, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(1...3)
            if store.isEdited(row) {
                Button("Terug naar het voorstel") { store.resetDraft(for: row) }.buttonStyle(.link)
            }
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                Text("Waarom dit voorstel?").font(.callout).foregroundStyle(.secondary)
                Text(row.suggestion.reason.isEmpty ? "Geen regel herkent deze transactie." : row.suggestion.reason)
                Text("Zekerheid: \(row.suggestion.confidence.title.lowercased())").foregroundStyle(.secondary)
                    .help("Zeker: tegenpartij en bedrag kloppen met een regel. Waarschijnlijk: alleen de tegenpartij of een trefwoord. Gok: alleen het bedrag. Onbekend: geen regel.")
            }
            .font(.callout)
            bank
        }
    }

    @ViewBuilder private func potSections() -> some View {
        let reserve = store.pots(kind: .reservering), saving = store.pots(kind: .spaar)
        if !reserve.isEmpty {
            Section("Reserveringspotten") { ForEach(reserve) { Text($0.name).tag($0.id) } }
        }
        if !saving.isEmpty {
            Section("Spaarpotten") { ForEach(saving) { Text($0.name).tag($0.id) } }
        }
    }

    private var splitBinding: Binding<Bool> {
        Binding(get: { draft.wrappedValue.isSplit }, set: { on in
            var d = draft.wrappedValue
            d.isSplit = on
            if on, d.lines.isEmpty {
                d.lines = [ReviewSplitLine(amount: row.tx.amount, label: d.label, target: d.target),
                           ReviewSplitLine(amount: nil, label: "", target: .none)]
                d.reimburse = false
                d.temporaryLoan = false
            }
            if !on { d.lines = [] }
            draft.wrappedValue = d
        })
    }

    private func tagBinding(_ id: Int64) -> Binding<Bool> {
        Binding(get: { draft.wrappedValue.tagIds.contains(id) }, set: { on in
            if on { draft.wrappedValue.tagIds.insert(id) } else { draft.wrappedValue.tagIds.remove(id) }
        })
    }

    private var bank: some View {
        let tx = row.tx
        return VStack(alignment: .leading, spacing: 6) {
            Text("Van de bank").font(.callout).foregroundStyle(.secondary)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 4) {
                bankRow("Tegenpartij", tx.counterpartyName)
                bankRow("Tegenrekening", tx.counterpartyIban)
                bankRow("Omschrijving", tx.descriptionText)
                bankRow("Kenmerk", tx.reference)
                bankRow("Soort", tx.transactionCode)
                bankRow("Volgnummer", tx.sequence)
                if let before = tx.balanceBefore {
                    bankRow("Saldo vóór", before.formatted())
                    bankRow("Saldo ná", (before + tx.amount).formatted())
                }
            }
            .font(.callout)
        }
        .help("Zo leverde de bank deze regel aan. Dit wordt nooit aangepast.")
    }

    @ViewBuilder private func bankRow(_ label: String, _ value: String) -> some View {
        if !value.trimmingCharacters(in: .whitespaces).isEmpty {
            GridRow {
                Text(label).foregroundStyle(.secondary)
                Text(value).monospacedDigit().textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: Knoppen

    private var actions: some View {
        let problem = store.problem(for: row)
        return VStack(alignment: .leading, spacing: 8) {
            if let problem {
                Label(problem, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(Theme.warning)
            }
            HStack(spacing: 10) {
                Button { store.skipSelection(model) } label: { Text("Sla over").frame(maxWidth: .infinity) }
                    .keyboardShortcut("d", modifiers: .command)
                    .help("Niet boeken, bijvoorbeeld omdat je deze al met de hand hebt ingevoerd (⌘D). Een overgeslagen transactie telt niet mee in het saldo.")
                Button { store.bookCurrent(model) } label: { Text("Boek  ⏎").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(problem != nil)
                    .help("Boekt deze transactie en gaat naar de volgende (⏎). Wijkt je keuze af van het voorstel, dan leert de app een regel.")
            }
            .controlSize(.large)
        }
        .padding(.horizontal, 22).padding(.vertical, 16)
    }
}

// MARK: - Onderdelen

/// Keuzelijst met de vaste posten van het jaar (betaalrekening) of de potten (spaarrekening).
struct ReviewTargetPicker: View {
    @Environment(ReviewStore.self) private var store
    let year: Int
    @Binding var selection: ReviewTarget

    var body: some View {
        Picker("Doel", selection: $selection) {
            Text(store.title(of: .none, kind: store.kind)).tag(ReviewTarget.none)
            if store.kind == .betaal {
                let incoming = store.items(year: year, direction: .IN), outgoing = store.items(year: year, direction: .UIT)
                if !incoming.isEmpty {
                    Section("IN · vaste inkomsten") { ForEach(incoming) { Text($0.label).tag(ReviewTarget.item($0.id ?? 0)) } }
                }
                if !outgoing.isEmpty {
                    Section("UIT · vaste lasten") { ForEach(outgoing) { Text($0.label).tag(ReviewTarget.item($0.id ?? 0)) } }
                }
            } else {
                let reserve = store.pots(kind: .reservering, accountId: store.accountId)
                let saving = store.pots(kind: .spaar, accountId: store.accountId)
                if !reserve.isEmpty {
                    Section("Reserveringspotten") { ForEach(reserve) { Text($0.name).tag(ReviewTarget.pot($0.id ?? 0)) } }
                }
                if !saving.isEmpty {
                    Section("Spaarpotten") { ForEach(saving) { Text($0.name).tag(ReviewTarget.pot($0.id ?? 0)) } }
                }
            }
        }
        .labelsHidden()
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(store.kind == .betaal
              ? "Een vaste post is een rij in het maandgrid (salaris, huur). Divers is alles wat geen vaste post is."
              : "Een pot is een deel van het saldo van de spaarrekening. Niet toegewezen telt wel mee in het saldo, maar hoort bij geen pot.")
    }
}

/// Splitsen: regels met bedrag, omschrijving en doel; boeken kan pas als ze samen het bankbedrag zijn.
private struct ReviewSplitEditor: View {
    @Environment(ReviewStore.self) private var store
    let row: ReviewRow
    @Binding var draft: ReviewDraft

    var body: some View {
        let rest = store.remaining(draft, for: row)
        VStack(alignment: .leading, spacing: 6) {
            ForEach($draft.lines) { $line in
                HStack(spacing: 6) {
                    MoneyField("Bedrag", value: $line.amount)
                        .textFieldStyle(.roundedBorder).frame(width: 84)
                    VStack(spacing: 3) {
                        ReviewLabelField(text: $line.label)
                        ReviewTargetPicker(year: row.tx.day.year, selection: $line.target)
                    }
                    Button {
                        draft.lines.removeAll { $0.id == line.id }
                    } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless).disabled(draft.lines.count <= 1)
                        .help("Verwijder deze regel")
                }
                .controlSize(.small)
            }
            HStack {
                Button {
                    draft.lines.append(ReviewSplitLine(amount: rest.isZero ? nil : rest))
                } label: { Label("Regel toevoegen", systemImage: "plus") }
                    .controlSize(.small)
                    .help("Nieuwe regel; het bedrag dat nog over is wordt alvast ingevuld.")
                Spacer()
                if rest.isZero {
                    Label("Klopt precies", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.positive)
                } else {
                    Text("Nog te verdelen").foregroundStyle(.secondary)
                    Text(rest.formatted()).monospacedDigit().fontWeight(.semibold).foregroundStyle(Theme.warning)
                }
            }
            .font(.callout)
            if row.tx.amount.isNegative {
                Text("Dit is een uitgave: vul de bedragen met een min in, bijvoorbeeld -12,50.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// Tag als aan/uit-knop.
private struct ReviewTagChip: View {
    let tag: Tag
    @Binding var isOn: Bool

    var body: some View {
        let color = Color(hex: tag.color)
        Button { isOn.toggle() } label: {
            HStack(spacing: 4) {
                Circle().fill(isOn ? Color.white : color).frame(width: 7, height: 7)
                Text(tag.name)
            }
            .font(.caption.weight(.medium))
            .padding(.horizontal, 9).padding(.vertical, 4)
            .foregroundStyle(isOn ? Color.white : Color.primary)
            .background(isOn ? AnyShapeStyle(color) : AnyShapeStyle(.quaternary.opacity(0.6)), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// Zet onderdelen naast elkaar en breekt af naar een volgende regel als het niet past.
struct ReviewFlow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        return CGSize(width: proposal.width ?? rows.width, height: rows.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(width: bounds.width, subviews: subviews)
        for (index, point) in result.points.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), proposal: .unspecified)
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (points: [CGPoint], width: CGFloat, height: CGFloat) {
        var points: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            points.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            maxX = max(maxX, x - spacing)
        }
        return (points, maxX, y + rowHeight)
    }
}

/// Omschrijvingsveld dat aanvult uit bestaande omschrijvingen en waarschuwt bij een bijna-gelijke schrijfwijze.
struct ReviewLabelField: View {
    @Environment(ReviewStore.self) private var store
    @Binding var text: String

    var body: some View {
        let typed = text.trimmingCharacters(in: .whitespaces)
        VStack(alignment: .leading, spacing: 3) {
            TextField("Omschrijving", text: $text)
                .textFieldStyle(.roundedBorder)
                .textInputSuggestions {
                    if !typed.isEmpty {
                        ForEach(LabelMatcher.suggest(typed, from: store.labels, limit: 6).filter { $0.label != typed }) { suggestion in
                            Text(suggestion.label).textInputCompletion(suggestion.label)
                        }
                    }
                }
            if !typed.isEmpty, let existing = LabelMatcher.similar(typed, in: store.labels), existing.label != typed {
                Button("Bedoel je ‘\(existing.label)’?") { text = existing.label }
                    .buttonStyle(.link).font(.caption)
                    .help("Deze omschrijving bestaat al in bijna dezelfde schrijfwijze. Met dezelfde tekst tellen de boekingen bij elkaar op in de rapporten.")
            }
        }
    }
}
