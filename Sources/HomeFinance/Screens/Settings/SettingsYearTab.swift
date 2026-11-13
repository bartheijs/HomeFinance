import SwiftUI
import GRDB
import HFCore
import HFBudget
import HFInsight

/// Gegevens voor het tabblad "Jaar en posten". De plantotalen komen uit `Insight.monthGrid`.
struct SettingsYearData: Equatable {
    var year: BudgetYear?
    var items: [BudgetItem] = []
    var pots: [Pot] = []
    var allYears: [Int] = []
    var entryCounts: [Int64: Int] = [:]
    /// Plan per jaar, per richting (RES = de RES-regels, die niet meetellen in de uitgaven).
    var yearPlan: [Direction: Money] = [:]

    var plannedIncome: Money { yearPlan[.IN] ?? .zero }
    var plannedExpenses: Money { yearPlan[.UIT] ?? .zero }
    var surplusPerMonth: Money { Money(cents: (plannedIncome + plannedExpenses).cents / 12) }
    var reserveTotal: BudgetItem? { items.first(where: \.isReserveTotal) }

    func items(_ direction: Direction) -> [BudgetItem] { items.filter { $0.direction == direction } }

    static func load(_ db: Database, year: Int, today: Day) throws -> SettingsYearData {
        var d = SettingsYearData()
        d.allYears = try Int.fetchAll(db, sql: "SELECT year FROM budgetYear ORDER BY year")
        d.pots = try Pot.order(Column("accountId"), Column("sortOrder"), Column("id")).fetchAll(db)
        guard let record = try BudgetYear.filter(Column("year") == year).fetchOne(db), let yearId = record.id else { return d }
        d.year = record
        d.items = try BudgetItem.filter(Column("yearId") == yearId).order(Column("sortOrder"), Column("id")).fetchAll(db)
        for row in try Row.fetchAll(db, sql: """
            SELECT e.budgetItemId AS id, COUNT(*) AS n FROM entry e
            JOIN budgetItem b ON b.id = e.budgetItemId WHERE b.yearId = ? GROUP BY e.budgetItemId
            """, arguments: [yearId]) {
            d.entryCounts[row["id"]] = row["n"]
        }
        let grid = try Insight.monthGrid(db, year: year, today: today)
        for row in grid.rows {
            let key: Direction = row.kind == .reserveLine ? .RES : row.direction
            d.yearPlan[key, default: .zero] += row.planYearTotal
        }
        return d
    }
}

struct SettingsYearTab: View {
    @Environment(AppModel.self) private var model

    @State private var data = SettingsYearData()
    @State private var loaded = false
    @State private var resetToken = 0
    @State private var deleteTarget: BudgetItem?
    @State private var showNewYear = false
    @State private var confirmClose = false
    @State private var openGroups: Set<Direction> = [.IN, .UIT]
    @State private var expandedId: Int64?

    var body: some View {
        Group {
            if let year = data.year {
                content(year)
            } else if loaded {
                EmptyState(title: "Het jaar \(String(model.year)) bestaat nog niet",
                           message: "Maak het jaar aan om buffers en vaste posten in te stellen. Je kunt de posten van een eerder jaar kopiëren.",
                           icon: "calendar.badge.plus", actionTitle: "Nieuw jaar aanmaken…") { showNewYear = true }
            } else {
                Color.clear
            }
        }
        .task(id: SettingsReloadKey(revision: model.revision, year: model.year)) { load() }
        .sheet(isPresented: $showNewYear) {
            SettingsNewYearSheet(existingYears: data.allYears, suggested: suggestedNewYear)
        }
        .confirmationDialog(deleteTitle, isPresented: Binding(
            get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }), presenting: deleteTarget) { item in
            let count = data.entryCounts[item.id ?? -1] ?? 0
            if count > 0 {
                Button("Verwijder; boekingen worden divers", role: .destructive) { delete(item, convert: true) }
            } else {
                Button("Verwijder", role: .destructive) { delete(item, convert: false) }
            }
            Button("Annuleer", role: .cancel) {}
        } message: { item in
            let count = data.entryCounts[item.id ?? -1] ?? 0
            Text(count > 0
                 ? "Op deze post staan \(SettingsFormat.count(count, "boeking", "boekingen")). Die blijven bestaan en tellen daarna mee als divers."
                 : "Op deze post staan geen boekingen.")
        }
        .confirmationDialog("Jaar \(String(model.year)) afsluiten?", isPresented: $confirmClose) {
            Button("Sluit af") { setClosed(true) }
            Button("Annuleer", role: .cancel) {}
        } message: {
            Text("Een afgesloten jaar is alleen-lezen: boekingen, posten en buffers kunnen niet meer wijzigen. Heropenen kan altijd.")
        }
    }

    private var deleteTitle: String { "Post ‘\(deleteTarget?.label ?? "")’ verwijderen?" }
    private var suggestedNewYear: Int { (data.allYears.max() ?? model.year - 1) + 1 }

    // MARK: Inhoud

    private func content(_ year: BudgetYear) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if year.closed {
                    SettingsBanner(icon: "lock.fill",
                                   text: "**\(String(year.year)) is afgesloten** en daarom alleen-lezen. Heropen het jaar om iets te wijzigen.",
                                   color: Theme.warning)
                }
                yearLine(year)
                SettingsBuffersCard(year: year) { saveBuffers($0, $1) }
                    .id("buffers-\(year.year)-\(resetToken)")
                    .disabled(year.closed)
                VStack(alignment: .leading, spacing: 12) {
                    Text("Vaste posten").font(.title2.weight(.semibold))
                    Text("Klik op een post om hem te wijzigen.").font(.callout).foregroundStyle(.secondary)
                    group(.IN, title: "Inkomsten", year: year)
                    group(.UIT, title: "Uitgaven", year: year)
                    group(.RES, title: "Reserveringen", year: year)
                }
                .disabled(year.closed)
            }
            .frame(maxWidth: 780, alignment: .leading)
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { totalsBar }
    }

    private func yearLine(_ year: BudgetYear) -> some View {
        HStack(spacing: 10) {
            Text("Begrotingsjaar \(String(year.year))").font(.title2.weight(.semibold))
            Text(year.closed ? "afgesloten" : "open").font(.callout).foregroundStyle(.secondary)
            Spacer()
            Button("Nieuw jaar…") { showNewYear = true }
                .help("Maak een leeg jaar of kopieer de posten van een bestaand jaar")
            if year.closed {
                Button("Heropen jaar") { setClosed(false) }
            } else {
                Button("Jaar afsluiten…") { confirmClose = true }
                    .help("Een afgesloten jaar is alleen-lezen: er verandert achteraf niets meer aan. Heropenen kan altijd.")
            }
        }
    }

    private func groupHelp(_ direction: Direction) -> String {
        switch direction {
        case .IN: "Geld dat binnenkomt: salaris, toeslagen en andere vaste inkomsten."
        case .UIT: "Vaste lasten die van de betaalrekening gaan, plus de regel RESERVERINGEN."
        case .RES: "De onderdelen van de ene maandelijkse overboeking RESERVERINGEN naar de spaarrekening. Er wordt niet op geboekt; ze laten zien hoe dat bedrag is opgebouwd en welke pot ermee gevuld wordt."
        }
    }

    private func group(_ direction: Direction, title: String, year: BudgetYear) -> some View {
        let rows = data.items(direction)
        let isOpen = openGroups.contains(direction)
        let missingTotal = direction == .RES && data.reserveTotal == nil
        return VStack(spacing: 0) {
            Button {
                if isOpen { openGroups.remove(direction) } else { openGroups.insert(direction) }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "chevron.right").font(.callout.weight(.semibold)).foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                    Text(title).font(.title3.weight(.semibold))
                    Text(SettingsFormat.count(rows.count, "post", "posten")).font(.callout).foregroundStyle(.secondary)
                    if missingTotal {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
                    }
                    Spacer()
                    Text("\((data.yearPlan[direction] ?? .zero).magnitude.formatted()) per jaar")
                        .font(.title3).monospacedDigit().foregroundStyle(.secondary)
                }
                .padding(.horizontal, 18).padding(.vertical, 13)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(groupHelp(direction))

            if isOpen {
                if missingTotal {
                    Divider()
                    HStack(spacing: 10) {
                        Text("Er is nog geen regel RESERVERINGEN. Daarop boek je de maandelijkse overboeking naar de spaarrekening.")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button("Maak aan") { addReserveTotal(year: year) }
                    }
                    .padding(.horizontal, 18).padding(.vertical, 10)
                }
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, item in
                    Divider().padding(.leading, 18)
                    SettingsYearItemRow(item: item, pots: data.pots.filter { $0.kind == .reservering },
                                        reserveLineCount: data.items(.RES).count,
                                        entryCount: data.entryCounts[item.id ?? -1] ?? 0,
                                        isExpanded: expandedId == item.id,
                                        isFirst: index == 0, isLast: index == rows.count - 1,
                                        onToggle: { expandedId = expandedId == item.id ? nil : item.id },
                                        onSave: { save($0) }, onMove: { move(item, by: $0, in: rows) },
                                        onDelete: { deleteTarget = item })
                        .id("\(item.id ?? 0)-\(resetToken)")
                        .draggable("hf-item:\(item.id ?? -1)")
                        .dropDestination(for: String.self) { texts, _ in
                            guard let text = texts.first, text.hasPrefix("hf-item:"),
                                  let dragged = Int64(text.dropFirst("hf-item:".count)) else { return false }
                            return drop(dragged, before: item)
                        }
                }
                Divider().padding(.leading, 18)
                Button { add(direction, year: year) } label: {
                    Label("Post toevoegen", systemImage: "plus").padding(.horizontal, 18).padding(.vertical, 9)
                        .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(Theme.accent)
            }
        }
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius))
    }

    private var totalsBar: some View {
        HStack(spacing: 32) {
            total("Gepland inkomen per jaar", data.plannedIncome,
                  help: "Som van het plan van alle inkomstenposten, over het hele jaar")
            total("Geplande uitgaven per jaar", data.plannedExpenses.magnitude,
                  help: "Som van het plan van alle uitgavenposten, inclusief RESERVERINGEN")
            total("Gepland overschot per maand", data.surplusPerMonth,
                  color: data.surplusPerMonth.isNegative ? Theme.negative : Theme.positive,
                  help: "Gepland inkomen min geplande uitgaven, gedeeld door twaalf. Dit is de ruimte voor diverse uitgaven.")
            Spacer()
        }
        .padding(.horizontal, 24).padding(.vertical, 12)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private func total(_ title: String, _ amount: Money, color: Color = .primary, help: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.callout).foregroundStyle(.secondary)
            Text(amount.formatted()).font(.system(.title3, design: .rounded).weight(.semibold))
                .monospacedDigit().foregroundStyle(color)
        }
        .help(help)
    }

    // MARK: Lezen en schrijven

    private func load() {
        data = model.read(SettingsYearData()) { try SettingsYearData.load($0, year: model.year, today: model.today) }
        loaded = true
    }

    /// Schrijft, en zet bij een fout de velden terug naar wat er bewaard is.
    private func write(_ success: String? = nil, _ action: (Database) throws -> Void) {
        let ok = model.perform(success) { try model.db.write(action) }
        if !ok { resetToken += 1 }
        load()
    }

    private func saveBuffers(_ antiRood: Money, _ tijdelijk: Money) {
        write { db in
            _ = try YearService.updateBuffers(db, year: model.year, antiRood: antiRood,
                                              tijdelijkAntiRood: tijdelijk)
        }
    }

    private func save(_ item: BudgetItem) {
        write { db in _ = try YearService.updateItem(db, item) }
    }

    private func add(_ direction: Direction, year: BudgetYear) {
        guard let yearId = year.id else { return }
        var created: Int64?
        write { db in
            created = try YearService.createItem(db, BudgetItem(yearId: yearId, label: "Nieuwe post", direction: direction, planAmount: .zero)).id
        }
        if let created { expandedId = created }
    }

    private func addReserveTotal(year: BudgetYear) {
        guard let yearId = year.id else { return }
        write("RESERVERINGEN aangemaakt") { db in
            _ = try YearService.createItem(db, BudgetItem(yearId: yearId, label: "RESERVERINGEN", direction: .UIT,
                                                          planAmount: .zero, isReserveTotal: true))
        }
    }

    private func delete(_ item: BudgetItem, convert: Bool) {
        guard let id = item.id else { return }
        write("Post ‘\(item.label)’ verwijderd") { db in
            try YearService.deleteItem(db, itemId: id, convertEntriesToDivers: convert)
        }
    }

    private func move(_ item: BudgetItem, by delta: Int, in rows: [BudgetItem]) {
        guard let index = rows.firstIndex(of: item), rows.indices.contains(index + delta),
              let a = item.id, let b = rows[index + delta].id else { return }
        var ids = data.items.compactMap(\.id)
        guard let ia = ids.firstIndex(of: a), let ib = ids.firstIndex(of: b) else { return }
        ids.swapAt(ia, ib)
        reorder(ids)
    }

    private func drop(_ dragged: Int64, before target: BudgetItem) -> Bool {
        guard let targetId = target.id, dragged != targetId,
              let source = data.items.first(where: { $0.id == dragged }), source.direction == target.direction else { return false }
        var ids = data.items.compactMap(\.id)
        ids.removeAll { $0 == dragged }
        guard let to = ids.firstIndex(of: targetId) else { return false }
        ids.insert(dragged, at: to)
        reorder(ids)
        return true
    }

    private func reorder(_ ids: [Int64]) {
        guard let yearId = data.year?.id else { return }
        write { db in try YearService.reorderItems(db, yearId: yearId, orderedIds: ids) }
    }

    private func setClosed(_ closed: Bool) {
        let year = model.year
        write(closed ? "\(year) is afgesloten" : "\(year) is heropend") { db in
            if closed { try YearService.closeYear(db, year: year) } else { try YearService.reopenYear(db, year: year) }
        }
    }
}

// MARK: - Buffers

/// De anti-roodbuffer van het jaar, en wat er tijdelijk van spaar geleend is. Bewaart bij Enter of zodra je het veld verlaat.
struct SettingsBuffersCard: View {
    @Environment(AppModel.self) private var model
    let year: BudgetYear
    /// Uitstaand tijdelijk geleend bedrag; volgt uit de transacties.
    private var outstanding: Money {
        _ = model.revision
        return model.read(.zero) { try Insight.temporaryLoanOutstanding($0, on: model.today) }
    }
    var onSave: (Money, Money) -> Void

    private enum Field: Hashable { case antiRood }

    @State private var antiRood: Money?
    @FocusState private var focus: Field?

    init(year: BudgetYear, onSave: @escaping (Money, Money) -> Void) {
        self.year = year; self.onSave = onSave
        _antiRood = State(initialValue: year.antiRood)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsRow("Anti-rood", text: "Blijft altijd op de betaalrekening staan, zodat je nooit rood staat.") {
                field($antiRood, .antiRood)
            }
            .help("Deze buffer telt niet mee als besteedbaar.")
            .padding(.horizontal, 18).padding(.vertical, 12)
            Divider().padding(.leading, 18)
            SettingsRow("Tijdelijk geleend van spaar",
                        text: "Haal je even extra geld van spaar? Markeer die overboeking bij Transacties als ‘Tijdelijk geleend van spaar’, en het terugboeken ook. De app houdt bij wat er nog uitstaat.") {
                MoneyText(outstanding).foregroundStyle(outstanding.isZero ? .secondary : .primary)
            }
            .help("Wat er uitstaat telt niet mee als besteedbaar. Je vult hier niets in; het volgt uit je transacties.")
            .padding(.horizontal, 18).padding(.vertical, 12)
        }
        .font(.title3)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .onChange(of: focus) { old, new in if old != nil && old != new { commit() } }
    }

    private func field(_ value: Binding<Money?>, _ which: Field) -> some View {
        HStack(spacing: 4) {
            Text("€").foregroundStyle(.secondary)
            MoneyField("0,00", value: value)
                .focused($focus, equals: which)
                .onSubmit { commit() }
                .textFieldStyle(.roundedBorder)
                .frame(width: 120)
        }
    }

    private func commit() {
        guard let antiRood, antiRood != year.antiRood else { return }
        onSave(antiRood, .zero)
    }
}

// MARK: - Nieuw jaar

struct SettingsNewYearSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let existingYears: [Int]
    @State private var year: Int
    /// Het jaar waarvan gekopieerd wordt; nil = leeg jaar.
    @State private var source: Int?

    init(existingYears: [Int], suggested: Int) {
        self.existingYears = existingYears
        _year = State(initialValue: suggested)
        _source = State(initialValue: existingYears.max())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Nieuw begrotingsjaar").font(.title2.weight(.semibold))
            Form {
                LabeledContent("Jaar") {
                    HStack(spacing: 6) {
                        TextField("Jaar", value: $year, format: .number.grouping(.never))
                            .labelsHidden().multilineTextAlignment(.trailing).monospacedDigit().frame(width: 70)
                        Stepper("Jaar", value: $year, in: 1900...2200).labelsHidden()
                    }
                }
                Picker("Begin met", selection: $source) {
                    Text("Een leeg jaar").tag(Int?.none)
                    ForEach(existingYears.reversed(), id: \.self) { y in
                        Text("Een kopie van \(String(y))").tag(Optional(y))
                    }
                }
                .pickerStyle(.radioGroup)
            }
            Text(source == nil
                 ? "Je begint zonder posten en met buffers van € 0,00."
                 : "Buffers en alle vaste posten worden overgenomen. Boekingen gaan niet mee; die blijven in hun eigen jaar.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if existingYears.contains(year) {
                Label("\(String(year)) bestaat al.", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(Theme.warning)
            }
            HStack {
                Spacer()
                Button("Annuleer", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Maak aan") { create() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(existingYears.contains(year))
            }
        }
        .padding(24)
        .frame(width: 420)
    }

    private func create() {
        let newYear = year, from = source
        let ok = model.perform("Jaar \(newYear) aangemaakt") {
            try model.db.write { db in
                if let from {
                    _ = try YearService.createYear(db, year: newYear, copyingFrom: from)
                } else {
                    _ = try YearService.createYear(db, year: newYear)
                }
            }
        }
        if ok {
            model.year = newYear
            dismiss()
        }
    }
}
