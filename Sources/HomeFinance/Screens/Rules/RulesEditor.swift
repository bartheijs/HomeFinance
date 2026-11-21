import SwiftUI
import HFCore
import HFRules
import HFInsight

/// Inspecteur rechts: één regel bewerken, met direct zicht op wat hij zou doen.
struct RulesEditor: View {
    @Binding var draft: Rule
    let data: RulesData
    let hits: [RuleTestHit]
    let year: Int
    let isNew: Bool
    let isDirty: Bool
    /// Plek in de volgorde (vanaf 1) en het aantal regels; nil bij een nieuwe regel.
    let position: (index: Int, count: Int)?
    let canMove: Bool
    var onSave: () -> Void
    var onRevert: () -> Void
    var onDuplicate: () -> Void
    var onDelete: () -> Void
    var onMove: (Int) -> Void
    var onClose: () -> Void

    @State private var showConfidenceHelp = false
    @FocusState private var labelFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            Divider()
            Form {
                ruleSection
                conditionSection
                previewSection
                resultSection
                if !isNew { aboutSection }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            Divider()
            actionBar
        }
        .background(Theme.background)
    }

    // MARK: Kop en knoppen

    private var titleBar: some View {
        HStack(spacing: 8) {
            Image(systemName: isNew ? "plus.circle.fill" : "slider.horizontal.3").foregroundStyle(Theme.accent)
            Text(isNew ? "Nieuwe regel" : "Regel bewerken").font(.headline)
            Spacer()
            if isDirty { Pill("niet bewaard", color: Theme.warning) }
            Button(action: onClose) { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .keyboardShortcut(.cancelAction)
                .help("Sluit dit paneel (Esc)")
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
    }

    private var actionBar: some View {
        HStack(spacing: 8) {
            if !isNew {
                Button(role: .destructive, action: onDelete) { Image(systemName: "trash") }
                    .help("Regel verwijderen")
                Button(action: onDuplicate) { Image(systemName: "plus.square.on.square") }
                    .keyboardShortcut("d", modifiers: .command)
                    .help("Maak een kopie van deze regel (⌘D)")
            }
            Spacer()
            Button(isNew ? "Annuleer" : "Herstel", action: onRevert)
                .disabled(!isNew && !isDirty)
                .help(isNew ? "Deze nieuwe regel niet bewaren" : "Zet de regel terug zoals hij bewaard is")
            Button("Bewaar", action: onSave)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!isDirty && !isNew)
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
    }

    // MARK: Onderdelen

    private var ruleSection: some View {
        Section {
            TextField("Naam", text: $draft.name, prompt: Text("Bijvoorbeeld Energie"))
            Picker("Rekening", selection: $draft.accountId) {
                Text("Alle rekeningen").tag(Int64?.none)
                Divider()
                ForEach(data.accounts) { account in
                    Text(account.name).tag(account.id)
                }
            }
            .help("Laat de regel alleen gelden voor transacties op deze rekening")
            LabeledContent("Prioriteit") {
                HStack(spacing: 6) {
                    TextField("Prioriteit", value: $draft.priority, format: .number)
                        .labelsHidden().multilineTextAlignment(.trailing).monospacedDigit().frame(width: 60)
                    Stepper("Prioriteit", value: $draft.priority, in: 0...9990, step: 10).labelsHidden()
                }
            }
            .help("Een lager getal wordt eerder geprobeerd. Telt alleen als twee regels even zeker zijn.")
        }
    }

    private var conditionSection: some View {
        Section {
            TextField("Tegenpartij bevat", text: $draft.counterpartyContains.rulesText, prompt: Text("elke naam").foregroundStyle(.tertiary))
            TextField("IBAN tegenpartij", text: $draft.counterpartyIban.rulesText, prompt: Text("elk IBAN").foregroundStyle(.tertiary))
            TextField("Omschrijving bevat", text: $draft.descriptionContains.rulesText, prompt: Text("elke tekst").foregroundStyle(.tertiary))
            MoneyField("Bedrag is precies", value: $draft.amount)
                .help("Uitgaven met een min ervoor, bijvoorbeeld -120,00. Leeg laten = elk bedrag.")
        } header: {
            Text("Als")
        } footer: {
            Text("Alle ingevulde voorwaarden moeten kloppen. Hoofdletters en accenten maken niet uit.")
        }
    }

    private var previewSection: some View {
        Section {
            let basis = RulesText.expectedBasis(draft)
            LabeledContent {
                HStack(spacing: 6) {
                    if let basis {
                        Pill(basis.confidence.title, color: basis.confidence.color)
                    } else {
                        Pill("Geen voorstel", color: .secondary)
                    }
                    Button { showConfidenceHelp = true } label: { Image(systemName: "questionmark.circle") }
                        .buttonStyle(.borderless)
                        .help("Uitleg over zekerheid")
                        .popover(isPresented: $showConfidenceHelp, arrowEdge: .leading) { RulesConfidenceHelp() }
                }
            } label: {
                Text("Zekerheid")
                Text(RulesText.basisExplanation(basis))
            }
            hitSummary
            ForEach(Array(hits.prefix(5).enumerated()), id: \.offset) { _, hit in
                RulesHitRow(hit: hit, accountName: data.accountName(hit.transaction.accountId))
            }
            if hits.count > 5 {
                Text("en nog \(hits.count - 5) andere").font(.callout).foregroundStyle(.secondary)
            }
        } header: {
            Text("Voorbeeld")
        }
    }

    @ViewBuilder private var hitSummary: some View {
        if !RulesText.hasConditions(draft) {
            Label("Vul een voorwaarde in om te zien welke transacties passen.", systemImage: "arrow.up")
                .foregroundStyle(.secondary)
        } else if hits.isEmpty {
            Label("Deze regel past op geen enkele eerdere transactie.", systemImage: "magnifyingglass")
                .foregroundStyle(.secondary)
        } else {
            let differs = hits.filter(\.amountDiffers).count
            VStack(alignment: .leading, spacing: 2) {
                Label {
                    Text("Deze regel past op **\(hits.count)** eerdere \(hits.count == 1 ? "transactie" : "transacties")")
                } icon: {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.positive)
                }
                if differs > 0 {
                    Text("waarvan \(differs) met een ander bedrag (die worden ‘Waarschijnlijk’)")
                        .font(.callout).foregroundStyle(.secondary).padding(.leading, 24)
                }
            }
        }
    }

    private var resultSection: some View {
        Section {
            Picker("Post", selection: $draft.targetItemLabel) {
                Text("Divers").tag(String?.none)
                Divider()
                ForEach(postOptions, id: \.self) { label in
                    Text(label).tag(Optional(label))
                }
                if let missing = missingTarget {
                    Divider()
                    Text("\(missing) (niet in \(String(year)))").tag(Optional(missing))
                }
            }
            .help("De vaste post van \(String(year)) waarop geboekt wordt. Divers = geen vaste post.")
            Picker("Pot", selection: $draft.targetPotId) {
                Text("Geen").tag(Int64?.none)
                Divider()
                ForEach(data.pots.filter { !$0.archived || $0.id == draft.targetPotId }) { pot in
                    Text(pot.name).tag(pot.id)
                }
            }
            .help("Spaarrekening: de pot waar het bedrag bij of af gaat. Betaalrekening: de pot die de uitgave vergoedt.")
            TextField("Omschrijving", text: $draft.entryLabel.rulesText, prompt: Text("naam van de tegenpartij"))
                .focused($labelFocused)
                .help("De leesbare tekst van de boeking. Leeg = de opgeschoonde naam van de tegenpartij.")
            labelHelp
            if !data.tags.isEmpty {
                LabeledContent("Tags") {
                    RulesFlow(spacing: 6) {
                        ForEach(data.tags) { tag in tagChip(tag) }
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            Toggle(isOn: $draft.reimburse) {
                Text("Vergoeden uit spaar")
                Text("De uitgave komt op de lijst Spaaroverboekingen.")
            }
        } header: {
            Text("Dan")
        }
    }

    private var aboutSection: some View {
        Section {
            LabeledContent("Herkomst",
                           value: draft.origin == .geleerd ? "geleerd van een correctie" : "zelf gemaakt")
                .help(draft.origin == .geleerd
                      ? "Deze regel past zich aan als je dezelfde tegenpartij weer anders boekt."
                      : "Een zelf gemaakte regel wordt nooit automatisch aangepast.")
            LabeledContent("Gebruikt",
                           value: draft.hitCount == 0 ? "nog nooit"
                                : "\(draft.hitCount)×, laatst op \(RulesText.lastUsed(draft.lastUsed))")
            if let position {
                LabeledContent {
                    HStack(spacing: 6) {
                        Text("\(position.index) van \(position.count)").monospacedDigit().foregroundStyle(.secondary)
                        Button { onMove(-1) } label: { Image(systemName: "chevron.up") }
                            .disabled(!canMove || position.index == 1).help("Eerder proberen")
                        Button { onMove(1) } label: { Image(systemName: "chevron.down") }
                            .disabled(!canMove || position.index == position.count).help("Later proberen")
                    }
                } label: {
                    Text("Volgorde")
                    Text(canMove ? "Bij gelijke zekerheid wint de bovenste regel. Slepen in de lijst kan ook."
                                 : "Bewaar eerst je wijzigingen.")
                }
            }
        } header: {
            Text("Over deze regel")
        }
    }

    /// Aanvullen uit bestaande omschrijvingen, en een melding bij een bijna-gelijke omschrijving.
    @ViewBuilder private var labelHelp: some View {
        let text = RulesText.filled(draft.entryLabel) ?? ""
        if !text.isEmpty {
            if let near = LabelMatcher.similar(text, in: data.labels) {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
                    Text("Bedoel je ‘\(near.label)’? Die omschrijving bestaat al (\(near.count)× gebruikt).")
                        .font(.callout).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Button("Gebruik") { draft.entryLabel = near.label }.controlSize(.small)
                }
            }
            let options = LabelMatcher.suggest(text, from: data.labels, limit: 4)
                .filter { $0.label.caseInsensitiveCompare(text) != .orderedSame }
            if labelFocused && !options.isEmpty {
                RulesFlow(spacing: 6) {
                    ForEach(options) { option in
                        Button(option.label) { draft.entryLabel = option.label }
                            .buttonStyle(.bordered).controlSize(.small)
                            .help("Bestaande omschrijving, \(option.count)× gebruikt")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    private var postOptions: [String] { data.itemLabels }

    /// Een doelpost die in het gekozen jaar niet (meer) bestaat, blijft kiesbaar.
    private var missingTarget: String? {
        guard let label = RulesText.filled(draft.targetItemLabel),
              !data.itemLabels.contains(label) else { return nil }
        return label
    }

    private func tagChip(_ tag: Tag) -> some View {
        let isOn = tag.id.map(draft.tagIdList.contains) ?? false
        let color = Color(hex: tag.color)
        return Button {
            guard let id = tag.id else { return }
            var ids = draft.tagIdList
            if let index = ids.firstIndex(of: id) { ids.remove(at: index) } else { ids.append(id) }
            draft.tagIdList = ids
        } label: {
            HStack(spacing: 4) {
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle").foregroundStyle(isOn ? color : .secondary)
                Text(tag.name)
            }
            .font(.callout)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(isOn ? color.opacity(0.16) : Color.secondary.opacity(0.08), in: Capsule())
        }
        .buttonStyle(.plain)
        .help(isOn ? "Tag \(tag.name) wordt gezet" : "Klik om de tag \(tag.name) te zetten")
    }
}

/// Eén eerdere banktransactie die de regel herkent.
struct RulesHitRow: View {
    let hit: RuleTestHit
    let accountName: String?

    var body: some View {
        let tx = hit.transaction
        HStack(spacing: 8) {
            Text(tx.day.short()).font(.callout).monospacedDigit().foregroundStyle(.secondary)
                .frame(width: 48, alignment: .leading)
            VStack(alignment: .leading, spacing: 0) {
                Text(tx.counterpartyName.isEmpty ? tx.descriptionText : tx.counterpartyName).lineLimit(1)
                if hit.amountDiffers {
                    Text("ander bedrag").font(.caption).foregroundStyle(Theme.warning)
                }
            }
            Spacer(minLength: 4)
            MoneyText(tx.amount, colored: true).font(.callout)
        }
        .help([accountName, tx.descriptionText].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
    }
}
