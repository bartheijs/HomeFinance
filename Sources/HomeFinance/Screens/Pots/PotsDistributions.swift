import SwiftUI
import GRDB
import HFCore
import HFInsight
import HFBudget

// MARK: - Gegevens

private struct PotsDistData: Equatable {
    var summaries: [DistributionSummary] = []
    /// Herkomstrekening per storting (staat niet in het overzicht van Insight).
    var sources: [Int64: Int64] = [:]
    var accounts: [Account] = []
    var pots: [PotSummary] = []
    /// De UIT-posten van het lopende jaar.
    var items: [BudgetItem] = []
    /// De opbouw van RESERVERINGEN in het lopende jaar (om te zien of de RES-regels en de storting uit elkaar lopen).
    var buildup: ReserveBuildup?

    var checking: [Account] { accounts.filter { $0.kind == .betaal && !$0.archived } }
    var savings: [Account] { accounts.filter { $0.kind == .spaar && !$0.archived } }
    func accountName(_ id: Int64?) -> String? { accounts.first { $0.id == id }?.name }

    /// Spaarrekeningen met reserveringspotten die nog een maandbedrag hebben.
    var accountsWithMonthlyAmounts: [Account] {
        savings.filter { account in
            pots.contains { $0.accountId == account.id && !$0.archived && $0.kind == .reservering && $0.monthlyAmount > .zero }
        }
    }

    @MainActor
    static func load(model: AppModel) -> PotsDistData {
        let today = model.today
        return model.read(PotsDistData()) { db in
            var data = PotsDistData()
            data.summaries = try Insight.distributions(db, today: today)
            for record in try DistributionService.all(db, includeArchived: true) {
                if let id = record.id, let source = record.sourceAccountId { data.sources[id] = source }
            }
            data.accounts = try Account.order(Column("sortOrder"), Column("id")).fetchAll(db)
            data.pots = Insight.pickerOrder(try Insight.potOverview(db, today: today).accounts.flatMap(\.pots))
            data.items = Insight.itemPickerOrder(try BudgetItem.fetchAll(db, sql: """
                SELECT i.* FROM budgetItem i JOIN budgetYear y ON y.id = i.yearId
                WHERE y.year = ? AND i.direction = 'UIT' ORDER BY i.sortOrder, i.id
                """, arguments: [today.year]))
            data.buildup = try Insight.reserveBuildup(db, year: today.year)
            return data
        }
    }
}

private struct PotsDistLine: Identifiable, Equatable {
    /// Id van de pot.
    let id: Int64
    let name: String
    var amount: Money?
}

/// Wat er in het formulier staat; vergelijkbaar met het origineel om te zien of er iets gewijzigd is.
private struct PotsDistDraft: Equatable {
    var name = ""
    var sourceAccountId: Int64?
    var accountId: Int64?
    var lines: [PotsDistLine] = []
    var itemId: Int64?

    var total: Money { lines.map { $0.amount ?? .zero }.sum() }
    /// Potten zonder bedrag doen niet mee.
    var validLines: [(potId: Int64, amount: Money)] {
        lines.compactMap { line in line.amount.flatMap { $0 > .zero ? (potId: line.id, amount: $0) : nil } }
    }
}

private enum PotsDistSelection: Hashable {
    case existing(Int64)
    case new
}

// MARK: - Sheet

/// Vaste stortingen: wat er regelmatig van betaal naar spaar gaat en hoe dat over de potten verdeeld wordt.
struct PotsDistributionsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var data: PotsDistData?
    @State private var selection: PotsDistSelection?
    @State private var showArchived = false
    /// Loopt op na opslaan, zodat het formulier opnieuw wordt opgebouwd uit de bewaarde gegevens.
    @State private var generation = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Vaste stortingen").font(.title2.weight(.semibold))
                    Text("Een vaste storting is het bedrag dat je regelmatig van de betaalrekening naar de spaarrekening overmaakt, met de verdeling over je potten.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 16)
                Button("Klaar") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(20)
            Divider()
            if let data {
                HStack(spacing: 0) {
                    list(data).frame(width: 290)
                    Divider()
                    editor(data).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 880, height: 640)
        .task(id: model.revision) { reload() }
    }

    private func reload() {
        let loaded = PotsDistData.load(model: model)
        if case .existing(let id) = selection, !loaded.summaries.contains(where: { $0.id == id }) { selection = nil }
        if selection == nil, let first = loaded.summaries.first(where: { !$0.archived }) { selection = .existing(first.id) }
        data = loaded
    }

    // MARK: Lijst

    private func list(_ data: PotsDistData) -> some View {
        let shown = data.summaries.filter { showArchived || !$0.archived }
        return VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(shown) { summary in
                        listRow(summary, data: data)
                    }
                    if shown.isEmpty {
                        Text("Nog geen vaste storting.").font(.callout).foregroundStyle(.secondary).padding(12)
                    }
                }
                .padding(10)
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Button { selection = .new } label: { Label("Nieuwe storting", systemImage: "plus") }
                    .disabled(data.savings.isEmpty)
                if !data.summaries.contains(where: { !$0.archived }) {
                    ForEach(data.accountsWithMonthlyAmounts, id: \.id) { account in
                        Button { createFromPots(account) } label: {
                            Text("Maak een vaste storting van de bestaande maandbedragen")
                                .multilineTextAlignment(.leading)
                        }
                        .buttonStyle(.plain).foregroundStyle(Theme.accent).font(.callout)
                        .help("Neemt de maandbedragen van de reserveringspotten op \(account.name) over als één storting. Daarna pas je hem hier aan.")
                    }
                }
                if data.summaries.contains(where: \.archived) {
                    Toggle("Toon archief", isOn: $showArchived).toggleStyle(.checkbox).font(.callout)
                }
            }
            .padding(14)
        }
    }

    private func listRow(_ summary: DistributionSummary, data: PotsDistData) -> some View {
        let selected = selection == .existing(summary.id)
        let source = data.accountName(data.sources[summary.id]) ?? "herkomst onbekend"
        return Button { selection = .existing(summary.id) } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(summary.name).fontWeight(.medium).lineLimit(1)
                    if summary.planMatchesTotal == false {
                        Image(systemName: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(Theme.warning)
                    }
                    Spacer(minLength: 8)
                    Text(summary.total.formatted()).monospacedDigit()
                }
                Text("\(source) → \(summary.accountName)").font(.callout).foregroundStyle(.secondary).lineLimit(1)
                Text((summary.lines.count == 1 ? "1 pot" : "\(summary.lines.count) potten") + (summary.archived ? " · gearchiveerd" : ""))
                    .font(.callout).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Theme.accent.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
            .opacity(summary.archived ? 0.6 : 1)
        }
        .buttonStyle(.plain)
    }

    // MARK: Formulier

    @ViewBuilder private func editor(_ data: PotsDistData) -> some View {
        switch selection {
        case .existing(let id):
            if let summary = data.summaries.first(where: { $0.id == id }) {
                PotsDistributionEditor(data: data, summary: summary,
                                       onSaved: { _ in generation += 1 },
                                       onRemoved: { selection = nil })
                    .id("\(id)-\(generation)")
            }
        case .new:
            PotsDistributionEditor(data: data, summary: nil,
                                   onSaved: { id in selection = .existing(id); generation += 1 },
                                   onRemoved: { selection = nil })
                .id("new-\(generation)")
        case nil:
            ContentUnavailableView {
                Label("Nog geen vaste storting", systemImage: "arrow.triangle.branch")
            } description: {
                Text("Maak een storting en verdeel het bedrag over je potten. De app herkent de overboeking daarna bij het importeren en verdeelt hem vanzelf.")
            } actions: {
                Button("Nieuwe storting") { selection = .new }.disabled(data.savings.isEmpty)
            }
        }
    }

    private func createFromPots(_ account: Account) {
        guard let accountId = account.id else { return }
        var newId: Int64?
        let ok = model.perform("Vaste storting gemaakt van de maandbedragen") {
            try model.db.write { db in
                newId = try DistributionService.createFromPots(db, accountId: accountId, name: "Maandelijkse storting",
                                                               year: model.today.year).id
            }
        }
        if ok, let newId { selection = .existing(newId) }
    }
}

// MARK: - Eén storting bewerken

private struct PotsDistributionEditor: View {
    @Environment(AppModel.self) private var model

    let data: PotsDistData
    /// nil = nieuwe storting.
    let summary: DistributionSummary?
    var onSaved: (Int64) -> Void
    var onRemoved: () -> Void

    @State private var draft: PotsDistDraft
    private let original: PotsDistDraft
    @State private var confirmDelete = false

    init(data: PotsDistData, summary: DistributionSummary?, onSaved: @escaping (Int64) -> Void,
         onRemoved: @escaping () -> Void) {
        self.data = data; self.summary = summary; self.onSaved = onSaved; self.onRemoved = onRemoved
        var start = PotsDistDraft()
        if let summary {
            start.name = summary.name
            start.accountId = summary.accountId
            start.sourceAccountId = data.sources[summary.id]
            start.lines = summary.lines.map { PotsDistLine(id: $0.potId, name: $0.potName, amount: $0.amount) }
            start.itemId = summary.item?.id
        } else {
            start.accountId = data.savings.first?.id
            start.sourceAccountId = data.checking.first?.id
        }
        original = start
        _draft = State(initialValue: start)
    }

    private var trimmedName: String { draft.name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var dirty: Bool { draft != original }
    private var canSave: Bool {
        !trimmedName.isEmpty && draft.accountId != nil && (summary == nil || dirty)
    }
    /// Potten van de doelrekening die nog niet in de verdeling staan.
    private var addable: [PotSummary] {
        let used = Set(draft.lines.map(\.id))
        return data.pots.filter { $0.accountId == draft.accountId && !$0.archived && !used.contains($0.id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    fields
                    lines
                    link
                }
                .padding(20)
            }
            Divider()
            footer
        }
        .confirmationDialog("Vaste storting \(summary?.name ?? "") verwijderen?", isPresented: $confirmDelete) {
            Button("Verwijder", role: .destructive) { remove() }
            Button("Annuleer", role: .cancel) {}
        } message: {
            Text("De verdeling verdwijnt. Boekingen blijven staan en een gekoppelde post houdt zijn planbedrag.")
        }
    }

    private var fields: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
            GridRow {
                Text("Naam").foregroundStyle(.secondary)
                TextField("Naam", text: $draft.name, prompt: Text("bijv. Maandelijkse storting"))
                    .textFieldStyle(.roundedBorder)
            }
            GridRow {
                Text("Van").foregroundStyle(.secondary)
                Picker("Van", selection: $draft.sourceAccountId) {
                    Text("Niet ingesteld").tag(Int64?.none)
                    ForEach(data.checking, id: \.id) { Text($0.name).tag($0.id) }
                }
                .labelsHidden().fixedSize()
                .help("De betaalrekening waar het geld vandaan komt. Hiermee herkent de app de overboeking bij het importeren.")
            }
            GridRow {
                Text("Naar").foregroundStyle(.secondary)
                if summary == nil {
                    Picker("Naar", selection: $draft.accountId) {
                        ForEach(data.savings, id: \.id) { Text($0.name).tag($0.id) }
                    }
                    .labelsHidden().fixedSize()
                    .onChange(of: draft.accountId) { _, _ in draft.lines = [] }
                } else {
                    Text(summary?.accountName ?? "")
                        .help("De spaarrekening van een bestaande storting staat vast. Maak een nieuwe storting voor een andere rekening.")
                }
            }
        }
    }

    private var lines: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Verdeling over de potten").font(.headline)
            if draft.lines.isEmpty {
                Text("Nog geen potten. Voeg de potten toe waar deze storting naartoe gaat.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach($draft.lines) { $line in
                HStack(spacing: 10) {
                    Text(line.name).lineLimit(1)
                    Spacer(minLength: 12)
                    MoneyField("Bedrag", value: $line.amount)
                        .textFieldStyle(.roundedBorder).frame(width: 120)
                    Button { draft.lines.removeAll { $0.id == line.id } } label: {
                        Image(systemName: "minus.circle").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Haal \(line.name) uit deze storting.")
                }
            }
            HStack {
                Menu {
                    ForEach(PotKind.allCases, id: \.self) { kind in
                        let group = addable.filter { $0.kind == kind }
                        if !group.isEmpty {
                            Section(kind == .reservering ? "Reserveringen" : "Sparen") {
                                ForEach(group) { pot in
                                    Button(pot.name) { draft.lines.append(PotsDistLine(id: pot.id, name: pot.name, amount: nil)) }
                                }
                            }
                        }
                    }
                } label: {
                    Label("Pot toevoegen", systemImage: "plus")
                }
                .fixedSize()
                .disabled(addable.isEmpty)
                Spacer()
                Text("Totaal").foregroundStyle(.secondary)
                Text(draft.total.formatted())
                    .font(.title3.weight(.semibold)).monospacedDigit()
                    .frame(width: 120, alignment: .trailing)
                Color.clear.frame(width: 22, height: 1)
            }
            .padding(.top, 6)
            if draft.lines.contains(where: { ($0.amount ?? .zero).isZero }) {
                Text("Potten zonder bedrag doen niet mee en verdwijnen bij het bewaren.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var link: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Post op de betaalrekening").font(.headline)
            Picker("Hoort bij post", selection: $draft.itemId) {
                Text("Geen").tag(Int64?.none)
                ForEach(data.items, id: \.id) { item in
                    Text(item.label).tag(item.id)
                }
            }
            .fixedSize()
            Text("Het planbedrag van deze post volgt het totaal van de storting.")
                .font(.callout).foregroundStyle(.secondary)
            if let summary, let buildup = data.buildup, buildup.distribution?.id == summary.id, let warning = buildup.warning, !dirty {
                // RESERVERINGEN: het plan in het maandgrid komt nog uit de RES-regels; opnieuw bewaren helpt dan niet.
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let summary, summary.planMatchesTotal == false, let item = summary.item, !dirty {
                Label("Het plan van \(item.label) is \(item.plan.magnitude.formatted()), maar deze storting is \(summary.total.formatted()). Bewaar de storting opnieuw of pas de post aan.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if data.items.isEmpty {
                Text("Er zijn nog geen UIT-posten voor \(String(model.today.year)). Maak ze bij Instellingen.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if let summary {
                Menu {
                    Button("Dupliceer", systemImage: "plus.square.on.square") { duplicate(summary) }
                    Button(summary.archived ? "Haal uit archief" : "Archiveer", systemImage: "archivebox") {
                        setArchived(summary, !summary.archived)
                    }
                    Divider()
                    Button("Verwijder…", systemImage: "trash", role: .destructive) { confirmDelete = true }
                } label: {
                    Text("Meer")
                }
                .fixedSize()
            }
            Spacer()
            if summary != nil && dirty {
                Button("Zet terug") { draft = original }
            }
            Button(summary == nil ? "Maak storting" : "Bewaar") { save() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!canSave)
        }
        .padding(16)
    }

    // MARK: Schrijven

    private func save() {
        guard let accountId = draft.accountId else { return }
        let tuples = draft.validLines
        var savedId: Int64?
        let ok = model.perform("Vaste storting \(trimmedName) bewaard") {
            try model.db.write { db in
                let id: Int64
                if let summary {
                    id = summary.id
                    if trimmedName != original.name {
                        _ = try DistributionService.rename(db, distributionId: id, name: trimmedName)
                    }
                    if draft.sourceAccountId != original.sourceAccountId {
                        _ = try DistributionService.setSource(db, distributionId: id, sourceAccountId: draft.sourceAccountId)
                    }
                } else {
                    guard let newId = try DistributionService.create(db, name: trimmedName, accountId: accountId,
                                                                     sourceAccountId: draft.sourceAccountId).id else { return }
                    id = newId
                }
                _ = try DistributionService.setLines(db, distributionId: id, tuples)
                if draft.itemId != original.itemId {
                    if let old = original.itemId { _ = try DistributionService.unlink(db, budgetItemId: old) }
                    if let new = draft.itemId { _ = try DistributionService.link(db, distributionId: id, budgetItemId: new) }
                }
                savedId = id
            }
        }
        if ok, let savedId { onSaved(savedId) }
    }

    private func duplicate(_ summary: DistributionSummary) {
        var newId: Int64?
        let ok = model.perform("Kopie gemaakt van \(summary.name)") {
            try model.db.write { db in
                guard let id = try DistributionService.create(db, name: "\(summary.name) (kopie)", accountId: summary.accountId,
                                                              sourceAccountId: data.sources[summary.id]).id else { return }
                _ = try DistributionService.setLines(db, distributionId: id,
                                                     summary.lines.map { (potId: $0.potId, amount: $0.amount) })
                newId = id
            }
        }
        if ok, let newId { onSaved(newId) }
    }

    private func setArchived(_ summary: DistributionSummary, _ archived: Bool) {
        let ok = model.perform(archived ? "Vaste storting gearchiveerd" : "Vaste storting staat weer in de lijst") {
            try model.db.write { db in try DistributionService.setArchived(db, distributionId: summary.id, archived) }
        }
        if ok && archived { onRemoved() }
    }

    private func remove() {
        guard let summary else { return }
        let ok = model.perform("Vaste storting verwijderd") {
            try model.db.write { db in try DistributionService.delete(db, distributionId: summary.id) }
        }
        if ok { onRemoved() }
    }
}
