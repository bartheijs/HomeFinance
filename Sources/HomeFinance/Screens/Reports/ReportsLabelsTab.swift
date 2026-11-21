import SwiftUI
import Charts
import HFCore
import HFInsight
import HFBudget

/// Rapport Per omschrijving: losse boekingen (geen vaste post) met dezelfde omschrijving opgeteld, bv. zakgeld.
struct ReportsLabelsTab: View {
    @Environment(AppModel.self) private var model
    let year: Int
    /// De cijfers van dit tabblad voor "Kopieer als tabel".
    @Binding var table: String

    @State private var kind = LabelKind.expenses
    @State private var search = ""
    @State private var includeSingles = false
    @State private var totals: [LabelTotal] = []
    @State private var selectedId: String?
    @State private var years: [LabelYear] = []
    @State private var entries: [EntryRow] = []
    @State private var groups: [[LabelSuggestion]] = []
    @State private var showMerge = false
    @State private var renaming: LabelTotal?
    @State private var renameText = ""
    @State private var hover: String?

    private struct LoadKey: Hashable {
        let revision: Int, year: Int, today: Day, kind: LabelKind, search: String, singles: Bool, selected: String?
    }

    private var selected: LabelTotal? { totals.first { $0.id == selectedId } }

    var body: some View {
        Group {
            if ReportsDebug.showsMerge {
                ReportsMergeView(groups: groups) {}
            } else {
                main
            }
        }
        .task(id: LoadKey(revision: model.revision, year: year, today: model.today, kind: kind, search: search,
                          singles: includeSingles, selected: selectedId)) { load() }
        .sheet(isPresented: $showMerge) {
            ReportsMergeView(groups: groups) { showMerge = false }
                .frame(width: 560, height: 560)
        }
        .alert("Omschrijving hernoemen", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Nieuwe omschrijving", text: $renameText)
            Button("Hernoemen") { rename() }
            Button("Annuleer", role: .cancel) { renaming = nil }
        } message: {
            Text("Alle boekingen met deze omschrijving krijgen de nieuwe naam, ook in eerdere jaren. Bestaat de nieuwe naam al, dan worden ze samengevoegd.")
        }
    }

    private var main: some View {
        VStack(alignment: .leading, spacing: 24) {
            ReportsQuestion("Waar gaat het losse geld naartoe?",
                            detail: "Boekingen zonder vaste post, opgeteld per omschrijving. Zo zie je wat bijvoorbeeld zakgeld in totaal kost.")
            HStack(alignment: .top, spacing: 36) {
                list.frame(width: 300)
                if let selected {
                    detail(selected).frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Label(search.isEmpty ? "Geen omschrijvingen die vaker dan één keer voorkomen in \(String(year))."
                                         : "Niets gevonden voor “\(search)”.", systemImage: "tray")
                        .font(.title3).foregroundStyle(.secondary).padding(.top, 40)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    // MARK: Lijst

    private var list: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Soort", selection: $kind) {
                Text("Uitgaven").tag(LabelKind.expenses)
                Text("Inkomsten").tag(LabelKind.income)
            }
            .pickerStyle(.segmented).labelsHidden()
            .help("Toon losse uitgaven of losse inkomsten")
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Zoek een omschrijving", text: $search).textFieldStyle(.plain)
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help("Wis de zoektekst")
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            LazyVStack(spacing: 2) {
                ForEach(totals) { item in row(item) }
            }
            Toggle("Toon ook eenmalige", isOn: $includeSingles)
                .toggleStyle(.checkbox)
                .help("Standaard staan hier alleen omschrijvingen die minstens twee keer voorkomen")
            if !groups.isEmpty {
                Button { showMerge = true } label: {
                    Label("Dubbele schrijfwijzen opruimen (\(groups.count))", systemImage: "arrow.triangle.merge")
                }
                .help("Er zijn omschrijvingen die bijna hetzelfde gespeld zijn. Voeg ze samen, zodat de totalen kloppen.")
            }
        }
    }

    private func row(_ item: LabelTotal) -> some View {
        Button { selectedId = item.id } label: {
            HStack(spacing: 8) {
                Text(item.label.isEmpty ? "Zonder omschrijving" : item.label)
                    .fontWeight(item.id == selectedId ? .semibold : .regular).lineLimit(1)
                Text("\(item.count)×").font(.callout).foregroundStyle(.tertiary).monospacedDigit()
                Spacer(minLength: 6)
                ReportsAmount(amount: item.total).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(item.id == selectedId ? Theme.accent.opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Hernoemen…") {
                renameText = item.label
                renaming = item
            }
        }
        .help("\(item.count) keer in \(String(year)). Rechtsklik om te hernoemen.")
    }

    // MARK: Detail

    /// Uitgaven zijn negatief; in de grafiek staan ze als staven omhoog.
    private func barValue(_ amount: Money, _ item: LabelTotal) -> Double {
        item.total.isNegative ? -amount.doubleValue : amount.doubleValue
    }

    private func detail(_ item: LabelTotal) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            Text(item.label.isEmpty ? "Zonder omschrijving" : item.label).font(.title3.weight(.semibold))
            HStack(spacing: 56) {
                ReportsKeyNumber(title: "Totaal in \(String(year))", value: item.total.formatted())
                ReportsKeyNumber(title: "Aantal keer", value: "\(item.count)")
                ReportsKeyNumber(title: "Gemiddeld per maand", value: item.averagePerActiveMonth.formatted())
                    .help("Gemiddelde over de \(item.activeMonths) maanden waarin deze omschrijving voorkwam.")
            }
            chart(item).frame(height: 280)
            if years.count > 1 {
                HStack(alignment: .firstTextBaseline, spacing: 24) {
                    Text("Door de jaren").foregroundStyle(.secondary)
                    ForEach(years) { y in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(String(y.year)).font(.callout).foregroundStyle(.secondary).monospacedDigit()
                            ReportsAmount(amount: y.total).fontWeight(y.year == year ? .semibold : .regular)
                            Text("\(y.count)×").font(.callout).foregroundStyle(.tertiary).monospacedDigit()
                        }
                    }
                }
                .help("Het totaal van deze omschrijving per jaar, alle soorten boekingen samen")
            }
            ReportsDisclosure("Toon de \(entries.count) boekingen") {
                ReportsEntryList(entries: entries).frame(maxWidth: 760)
            }
        }
    }

    private func chart(_ item: LabelTotal) -> some View {
        Chart {
            if !item.averagePerActiveMonth.isZero {
                RuleMark(y: .value("Gemiddeld", barValue(item.averagePerActiveMonth, item)))
                    .foregroundStyle(Color.primary.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1.2, dash: [5, 4]))
                    .annotation(position: .top, alignment: .trailing, spacing: 3) {
                        Text("gemiddeld \(ReportsFormat.euros(item.averagePerActiveMonth.magnitude))")
                            .font(.callout).foregroundStyle(.secondary)
                    }
            }
            ForEach(Array(item.months.enumerated()), id: \.offset) { index, amount in
                let name = ReportsFormat.month(index + 1)
                BarMark(x: .value("Maand", name), y: .value("Bedrag", barValue(amount, item)), width: .ratio(0.6))
                    .foregroundStyle(ReportsColor.accent.opacity(hover == nil || hover == name ? 0.9 : 0.4))
                    .cornerRadius(5)
                    .annotation(position: .top, spacing: 4) {
                        if !amount.isZero {
                            Text(ReportsFormat.euros(amount.magnitude)).font(.callout).monospacedDigit().foregroundStyle(.secondary)
                                .padding(.horizontal, 3).background(Theme.background)
                        }
                    }
            }
            if let hover, let index = ReportsFormat.monthIndex(hover) {
                RuleMark(x: .value("Maand", hover))
                    .foregroundStyle(Color.clear)
                    .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                        ReportsTooltip(title: "\(ReportsFormat.monthName(index).capitalized) \(String(year))", lines: [
                            .init(label: item.label, color: ReportsColor.accent, value: item.months[index - 1].formatted()),
                        ])
                    }
            }
        }
        .chartXScale(domain: Day.monthNamesShort)
        .reportsCategoryAxis()
        .reportsEuroAxis()
        .reportsChartHover($hover)
    }

    // MARK: Lezen en schrijven

    private func load() {
        let today = model.today
        let text = search.trimmingCharacters(in: .whitespaces)
        let filter = LabelFilter(kind: kind, minCount: includeSingles ? 1 : 2, text: text.isEmpty ? nil : text)
        var newTotals: [LabelTotal] = [], newYears: [LabelYear] = [], newEntries: [EntryRow] = []
        var newGroups: [[LabelSuggestion]] = []
        var chosen = selectedId
        model.read(()) { db in
            newTotals = try Insight.labelTotals(db, year: year, today: today, filter: filter)
            newGroups = try Insight.similarLabelGroups(db, accountKind: .betaal)
            if chosen == nil || !newTotals.contains(where: { $0.id == chosen }) { chosen = newTotals.first?.id }
            if let item = newTotals.first(where: { $0.id == chosen }) {
                newYears = try Insight.labelYears(db, label: item.label)
                newEntries = try Insight.labelEntries(db, year: year, label: item.label)
            }
        }
        totals = newTotals; years = newYears; entries = newEntries; groups = newGroups
        if selectedId != chosen { selectedId = chosen }
        table = makeTable()
    }

    private func rename() {
        guard let item = renaming else { return }
        let target = renameText
        renaming = nil
        let done = model.perform("Omschrijving hernoemd naar “\(target.trimmingCharacters(in: .whitespaces))”.") {
            try model.db.write { db in _ = try LabelService.renameLabel(db, from: item.label, to: target) }
        }
        if done { selectedId = Insight.normalizedLabel(target) }
    }

    private func makeTable() -> String {
        let p = ReportsFormat.plain
        var rows = totals.map { t in
            [t.label, String(t.count)] + t.months.map(p) + [p(t.total), p(t.averagePerActiveMonth)]
        }
        if let item = selected, !entries.isEmpty {
            rows.append([])
            rows.append(["Boekingen \(item.label), \(year)"])
            rows.append(["Datum", "Omschrijving", "Bedrag"])
            rows += entries.map { [$0.day.dutch, $0.label, p($0.amount)] }
        }
        return ReportsFormat.tsv(["Omschrijving", "Aantal"] + Day.monthNamesShort + ["Totaal", "Gemiddeld per maand"], rows)
    }
}

// MARK: - Samenvoegen

/// Venster "Dubbele schrijfwijzen opruimen": per groep bijna-gelijke omschrijvingen kiezen welke overblijft.
struct ReportsMergeView: View {
    @Environment(AppModel.self) private var model
    let groups: [[LabelSuggestion]]
    let close: () -> Void
    /// Groepen die de gebruiker voor deze keer heeft overgeslagen.
    @State private var skipped: Set<String> = []

    private static func key(_ group: [LabelSuggestion]) -> String { group.map(\.id).sorted().joined(separator: "|") }
    private var open: [[LabelSuggestion]] { groups.filter { !skipped.contains(Self.key($0)) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Dubbele schrijfwijzen opruimen").font(.title2.weight(.semibold))
                Text("Deze omschrijvingen lijken sterk op elkaar. Voeg ze samen, dan tellen ze als één in de totalen.")
                    .foregroundStyle(.secondary)
            }
            .padding(20)
            Divider()
            if open.isEmpty {
                EmptyState(title: "Alles is opgeruimd", message: "Er zijn geen dubbele schrijfwijzen meer.", icon: "checkmark.circle")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        ForEach(open, id: \.self.first?.id) { group in
                            ReportsMergeGroup(group: group,
                                              merge: { target in merge(group, into: target) },
                                              skip: { skipped.insert(Self.key(group)) })
                            Divider()
                        }
                    }
                    .padding(20)
                }
            }
            Divider()
            HStack {
                Spacer()
                Button("Klaar", action: close).keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
    }

    private func merge(_ group: [LabelSuggestion], into target: String) {
        model.perform("Samengevoegd tot “\(target.trimmingCharacters(in: .whitespaces))”.") {
            try model.db.write { db in _ = try LabelService.mergeLabels(db, group.map(\.label), into: target) }
        }
    }
}

/// Eén groep schrijfwijzen met de keuze welke overblijft.
struct ReportsMergeGroup: View {
    let group: [LabelSuggestion]
    let merge: (String) -> Void
    let skip: () -> Void
    /// De gekozen schrijfwijze; nil = zelf typen.
    @State private var choice: String?
    @State private var custom = ""
    @State private var didSetDefault = false

    /// De meest gebruikte schrijfwijze is de standaardkeuze.
    private var mostUsed: String { group.max { $0.count < $1.count }?.label ?? "" }
    private var target: String { choice ?? custom }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Deze schrijfwijze blijft over", selection: $choice) {
                ForEach(group) { item in
                    Text("\(item.label)  ·  \(item.count)×").tag(String?.some(item.label))
                }
                Text("Anders, namelijk:").tag(String?.none)
            }
            .pickerStyle(.radioGroup)
            if choice == nil {
                TextField("Nieuwe omschrijving", text: $custom).textFieldStyle(.roundedBorder).frame(maxWidth: 320)
            }
            HStack(spacing: 10) {
                Button("Samenvoegen") { merge(target) }
                    .buttonStyle(.borderedProminent)
                    .disabled(target.trimmingCharacters(in: .whitespaces).isEmpty)
                    .help("Geeft alle boekingen in deze groep de gekozen omschrijving, ook in eerdere jaren")
                Button("Dit zijn verschillende dingen", action: skip)
                    .help("Laat deze groep voor nu staan; er verandert niets")
            }
        }
        .onAppear {
            if !didSetDefault { choice = mostUsed; didSetDefault = true }
        }
    }
}
