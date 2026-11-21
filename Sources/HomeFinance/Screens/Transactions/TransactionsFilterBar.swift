import SwiftUI
import HFCore

/// Zoekveld en de knop Filters; actieve filters staan eronder als weg te klikken chips.
struct TransactionsFilterBar: View {
    @Environment(AppModel.self) private var model
    @Bindable var store: TransactionsStore
    var searchFocused: FocusState<Bool>.Binding
    @State private var showFilters = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                searchField
                Button {
                    showFilters.toggle()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "line.3.horizontal.decrease")
                        Text("Filters")
                        if store.criteria.filterCount > 0 {
                            Text("\(store.criteria.filterCount)")
                                .font(.caption.weight(.semibold)).monospacedDigit()
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Theme.accent.opacity(0.2), in: Capsule())
                        }
                    }
                }
                .controlSize(.large)
                .help("Filter op maand, post, potje, tag of status")
                .popover(isPresented: $showFilters, arrowEdge: .bottom) {
                    TransactionsFilterPopover(store: store)
                }
                Spacer(minLength: 0)
            }
            if store.criteria.hasFilters {
                HStack(spacing: 8) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) { chips }
                    }
                    Button("Wis filters") { store.criteria.clear() }
                        .buttonStyle(.link)
                        .controlSize(.small)
                        .keyboardShortcut(.delete, modifiers: [.command, .shift])
                        .help("Alle filters weghalen (⇧⌘⌫)")
                }
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Zoek in transacties", text: $store.criteria.text)
                .textFieldStyle(.plain)
                .focused(searchFocused)
                .onExitCommand { store.criteria.text = "" }
            if !store.criteria.text.isEmpty {
                Button { store.criteria.text = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help("Zoektekst wissen")
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(searchFocused.wrappedValue ? Theme.accent.opacity(0.7) : Theme.hairline.opacity(0.7)))
        .frame(minWidth: 200, maxWidth: 420)
        .help("Zoeken in omschrijving, notitie, tegenpartij en bankomschrijving (⌘F)")
    }

    @ViewBuilder private var chips: some View {
        let c = store.criteria
        let lookups = store.lookups
        if !c.trimmedText.isEmpty {
            TransactionsFilterChip(text: "‘\(c.trimmedText)’", icon: "magnifyingglass") { store.criteria.text = "" }
        }
        if let month = c.month {
            TransactionsFilterChip(text: "\(Day.monthNames[month - 1]) \(model.year)", icon: "calendar") { store.criteria.month = nil }
        }
        if let item = lookups.item(c.itemId) {
            TransactionsFilterChip(text: "Post: \(item.label)", icon: "tablecells") { store.criteria.itemId = nil }
        }
        if let pot = lookups.pot(c.potId) {
            TransactionsFilterChip(text: "Potje: \(pot.name)", icon: "tray.full") { store.criteria.potId = nil }
        }
        if let tag = lookups.tag(c.tagId) {
            TransactionsFilterChip(text: tag.name, icon: "tag", tint: Color(hex: tag.color)) { store.criteria.tagId = nil }
        }
        if c.status != .all {
            TransactionsFilterChip(text: c.status.title, icon: "circle.dotted") { store.criteria.status = .all }
        }
        if c.diversOnly {
            TransactionsFilterChip(text: "Overig", icon: "square.dashed") { store.criteria.diversOnly = false }
        }
        if c.loanOnly {
            TransactionsFilterChip(text: "Tijdelijk geleend van spaar", icon: "hourglass") { store.criteria.loanOnly = false }
        }
        if c.reimburseOnly {
            TransactionsFilterChip(text: "Nog overboeken", icon: "arrow.triangle.swap") { store.criteria.reimburseOnly = false }
        }
    }
}

/// De filters zelf, achter de knop Filters.
private struct TransactionsFilterPopover: View {
    @Environment(AppModel.self) private var model
    @Bindable var store: TransactionsStore

    var body: some View {
        let lookups = store.lookups
        let items = lookups.items(year: model.year)
        Form {
            Picker("Toon", selection: $store.criteria.status) {
                ForEach(TransactionsStatusFilter.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .help("Alleen nieuw = nog niet geboekt. Na te kijken = automatisch geboekt en nog niet door jou gecontroleerd.")
            Picker("Maand", selection: $store.criteria.month) {
                Text("Alle maanden").tag(Int?.none)
                Divider()
                ForEach(1...12, id: \.self) { m in
                    Text("\(Day.monthNames[m - 1]) \(String(model.year))").tag(Int?.some(m))
                }
            }
            if store.kind == .betaal {
                Picker("Post", selection: $store.criteria.itemId) {
                    Text("Alle posten").tag(Int64?.none)
                    Section("UIT") { ForEach(items.filter { $0.direction == .UIT }) { Text($0.label).tag($0.id) } }
                    Section("IN") { ForEach(items.filter { $0.direction == .IN }) { Text($0.label).tag($0.id) } }
                }
                .help("Vaste post: een regel uit je begroting van \(String(model.year))")
            } else {
                Picker("Potje", selection: $store.criteria.potId) {
                    Text("Alle potjes").tag(Int64?.none)
                    Divider()
                    ForEach(lookups.pots(accountId: store.accountId, keeping: store.criteria.potId)) { Text($0.name).tag($0.id) }
                }
                .help("Potje: een deel van het saldo op de spaarrekening met een eigen doel")
            }
            Picker("Tag", selection: $store.criteria.tagId) {
                Text("Alle tags").tag(Int64?.none)
                Divider()
                ForEach(lookups.tags) { Text($0.name).tag($0.id) }
            }
            .help("Tag: een label om uitgaven te volgen, bv. tanken of uit eten")
            if store.kind == .betaal {
                Toggle("Alleen overig", isOn: $store.criteria.diversOnly)
                    .help("Losse uitgaven en ontvangsten zonder vaste post")
                Toggle("Alleen nog overboeken met spaar", isOn: $store.criteria.reimburseOnly)
                    .help("Boekingen die je met een potje op de spaarrekening rechtzet (Nog overboeken)")
                Toggle("Alleen tijdelijk geleend van spaar", isOn: $store.criteria.loanOnly)
                    .help(TransactionsFormat.loanHelp)
            }
            HStack {
                Spacer()
                Button("Wis filters") { store.criteria.clear() }
                    .disabled(!store.criteria.hasFilters)
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .frame(width: 380)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Een actief filter dat je met het kruisje weghaalt.
private struct TransactionsFilterChip: View {
    let text: String
    let icon: String
    var tint: Color = Theme.accent
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon).imageScale(.small).foregroundStyle(tint)
            Text(text).lineLimit(1)
            Button(action: remove) {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                    .padding(3)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Dit filter weghalen")
            .accessibilityLabel("Filter \(text) weghalen")
        }
        .font(.caption.weight(.medium))
        .padding(.leading, 8).padding(.trailing, 4).padding(.vertical, 3)
        .background(tint.opacity(0.13), in: Capsule())
        .fixedSize()
    }
}

/// Eén regel boven de feed bij zoeken of filteren: aantal en totaal van alle gevonden boekingen.
/// Bij een filter op tag, post of pot ook het totaal en het gemiddelde per maand in het begrotingsjaar.
struct TransactionsSummaryLine: View {
    @Environment(AppModel.self) private var model
    let store: TransactionsStore

    var body: some View {
        HStack(spacing: 14) {
            Text("\(TransactionsFormat.entries(store.totalEntryCount)) · \(store.foundSum.formatted())")
                .fontWeight(.medium).monospacedDigit()
                .help("Aantal en totaal van alle gevonden boekingen, ook van de regels die nog niet geladen zijn")
            if let summary = store.summary, summary.count > 0 {
                if store.criteria.month == nil {
                    fact("In \(String(model.year))", summary.sum.formatted())
                }
                if let average = summary.average, let months = summary.months {
                    fact("Gemiddeld per maand", average.formatted())
                        .help(months == 12
                              ? "Het totaal van \(String(model.year)) gedeeld door 12 maanden"
                              : "Het totaal van \(String(model.year)) gedeeld door de \(months) maanden tot en met \(Day.monthNames[months - 1])")
                }
            }
            Spacer(minLength: 0)
        }
        .font(.callout)
        .lineLimit(1)
    }

    private func fact(_ title: String, _ value: String) -> some View {
        HStack(spacing: 5) {
            Text(title).foregroundStyle(.secondary)
            Text(value).monospacedDigit().fontWeight(.medium)
        }
    }
}
