import SwiftUI
import GRDB
import HFCore
import HFBudget
import HFInsight

struct SettingsTagsData: Equatable {
    var tags: [Tag] = []
    var usage: [Int64: Int] = [:]
    /// Openstaand bedrag per tag met verrekenen (uit `Insight.settlementOverview`).
    var outstanding: [Int64: Money] = [:]

    static func load(_ db: Database, today: Day) throws -> SettingsTagsData {
        var d = SettingsTagsData()
        d.tags = try Tag.order(Column("sortOrder"), Column("id")).fetchAll(db)
        for row in try Row.fetchAll(db, sql: "SELECT tagId AS id, COUNT(*) AS n FROM entryTag GROUP BY tagId") {
            d.usage[row["id"]] = row["n"]
        }
        for summary in try Insight.settlementOverview(db, today: today) { d.outstanding[summary.id] = summary.outstanding }
        return d
    }
}

struct SettingsTagsTab: View {
    @Environment(AppModel.self) private var model
    @State private var data = SettingsTagsData()
    @State private var loaded = false
    @State private var resetToken = 0
    @State private var newName = ""
    @State private var deleteTarget: Tag?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.spacing) {
                Text("Met tags volg je waar geld aan opgaat, dwars door posten heen: tanken, uit eten, vakantie. Een tag is geen extra uitgave; hij telt alleen mee in de rapporten.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text("**Verrekenen** is voor uitgaven die je later terugstort op de betaalrekening, zoals tanken. De app houdt bij wat er nog openstaat.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Card(padding: 0) {
                    VStack(spacing: 0) {
                        if loaded && data.tags.isEmpty {
                            Text("Nog geen tags. Voeg hieronder je eerste toe, bijvoorbeeld ‘Tanken’.")
                                .font(.callout).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(14)
                            Divider()
                        }
                        ForEach(Array(data.tags.enumerated()), id: \.element.id) { index, tag in
                            SettingsTagRow(tag: tag, usage: data.usage[tag.id ?? -1] ?? 0,
                                           outstanding: data.outstanding[tag.id ?? -1] ?? .zero, today: model.today,
                                           isFirst: index == 0, isLast: index == data.tags.count - 1,
                                           onSave: { save($0) }, onSettle: { setSettles(tag, from: $0) },
                                           onMove: { move(tag, by: $0) },
                                           onDelete: { deleteTarget = tag })
                                .id("\(tag.id ?? 0)-\(resetToken)")
                            Divider().padding(.leading, 14)
                        }
                        addRow
                    }
                }
                .frame(maxWidth: 640)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: SettingsReloadKey(revision: model.revision, year: model.year)) { load() }
        .confirmationDialog("Tag ‘\(deleteTarget?.name ?? "")’ verwijderen?", isPresented: Binding(
            get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }), presenting: deleteTarget) { tag in
            Button("Verwijder", role: .destructive) { delete(tag) }
            Button("Annuleer", role: .cancel) {}
        } message: { tag in
            let n = data.usage[tag.id ?? -1] ?? 0
            Text(n > 0 ? "De tag verdwijnt van \(SettingsFormat.count(n, "boeking", "boekingen")). De boekingen zelf blijven."
                       : "Deze tag wordt nergens gebruikt.")
        }
    }

    private var addRow: some View {
        HStack(spacing: 10) {
            Circle().fill(Color(hex: nextColor)).frame(width: 14, height: 14).padding(.horizontal, 15)
            TextField("Nieuwe tag", text: $newName)
                .textFieldStyle(.roundedBorder)
                .onSubmit { add() }
            Button("Voeg toe") { add() }
                .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private var nextColor: String {
        SettingsFormat.tagPalette[data.tags.count % SettingsFormat.tagPalette.count]
    }

    private func load() {
        data = model.read(SettingsTagsData()) { try SettingsTagsData.load($0, today: model.today) }
        loaded = true
    }

    private func write(_ success: String? = nil, _ action: (Database) throws -> Void) -> Bool {
        let ok = model.perform(success) { try model.db.write(action) }
        if !ok { resetToken += 1 }
        load()
        return ok
    }

    private func add() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let color = nextColor
        if write(nil, { db in _ = try TagService.create(db, name: name, color: color) }) { newName = "" }
    }

    private func save(_ tag: Tag) {
        _ = write { db in _ = try TagService.update(db, tag) }
    }

    /// Verrekenen aanzetten vanaf een dag, of uitzetten (`from == nil`).
    private func setSettles(_ tag: Tag, from: Day?) {
        guard let id = tag.id else { return }
        if let from {
            _ = write("Verrekenen staat aan voor ‘\(tag.name)’ vanaf \(from.short(withYear: true))") { db in
                _ = try SettlementService.enable(db, tagId: id, from: from)
            }
        } else {
            _ = write("Verrekenen staat uit voor ‘\(tag.name)’") { db in try SettlementService.disable(db, tagId: id) }
        }
    }

    private func delete(_ tag: Tag) {
        guard let id = tag.id else { return }
        _ = write("Tag ‘\(tag.name)’ verwijderd") { db in try TagService.delete(db, tagId: id) }
    }

    private func move(_ tag: Tag, by delta: Int) {
        var ids = data.tags.compactMap(\.id)
        guard let id = tag.id, let index = ids.firstIndex(of: id), ids.indices.contains(index + delta) else { return }
        ids.swapAt(index, index + delta)
        _ = write { db in try TagService.reorder(db, orderedIds: ids) }
    }
}

struct SettingsTagRow: View {
    let tag: Tag
    let usage: Int
    let outstanding: Money
    let today: Day
    let isFirst: Bool
    let isLast: Bool
    var onSave: (Tag) -> Void
    /// Verrekenen aan vanaf een dag, of uit (nil).
    var onSettle: (Day?) -> Void
    var onMove: (Int) -> Void
    var onDelete: () -> Void

    @State private var name: String
    @State private var color: Color
    @FocusState private var focused: Bool
    @State private var askFrom = false
    @State private var fromDate = Date()

    init(tag: Tag, usage: Int, outstanding: Money, today: Day, isFirst: Bool, isLast: Bool,
         onSave: @escaping (Tag) -> Void, onSettle: @escaping (Day?) -> Void,
         onMove: @escaping (Int) -> Void, onDelete: @escaping () -> Void) {
        self.tag = tag; self.usage = usage; self.outstanding = outstanding; self.today = today
        self.isFirst = isFirst; self.isLast = isLast
        self.onSave = onSave; self.onSettle = onSettle; self.onMove = onMove; self.onDelete = onDelete
        _name = State(initialValue: tag.name)
        _color = State(initialValue: Color(hex: tag.color))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            mainLine
            settleLine
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
        .onChange(of: color) { _, _ in commit() }
        .onChange(of: tag) { _, new in
            name = new.name
            if SettingsFormat.hex(color) != new.color.uppercased() { color = Color(hex: new.color) }
        }
    }

    /// Schakelaar "Verrekenen"; bij aanzetten eerst de vraag vanaf welke datum.
    private var settleLine: some View {
        HStack(spacing: 8) {
            Toggle("Verrekenen", isOn: Binding(get: { tag.settles }, set: { on in
                if on { fromDate = SettingsFormat.date(today); askFrom = true } else { onSettle(nil) }
            }))
            .toggleStyle(.switch).controlSize(.mini)
            .help("Voor uitgaven die je later terugstort op de betaalrekening, zoals tanken. De app houdt bij wat er nog openstaat.")
            .popover(isPresented: $askFrom, arrowEdge: .bottom) { fromPopover }
            if tag.settles {
                Text("openstaand").foregroundStyle(.secondary)
                Text(outstanding.formatted()).monospacedDigit()
                    .foregroundStyle(outstanding.isZero ? Color.secondary : Color.primary)
                    .help("Wat je nog moet terugstorten: de uitgaven met deze tag die nog niet verrekend zijn.")
            }
            Spacer(minLength: 0)
        }
        .font(.callout)
        .padding(.leading, 54)
    }

    private var fromPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Verrekenen voor ‘\(tag.name)’").font(.headline)
            Text("Vanaf welke datum tellen uitgaven mee als openstaand? Alles van daarvoor geldt als al verrekend.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            DatePicker("Vanaf", selection: $fromDate, displayedComponents: .date)
            HStack {
                Spacer()
                Button("Annuleer", role: .cancel) { askFrom = false }
                Button("Zet aan") {
                    askFrom = false
                    onSettle(Day(date: fromDate))
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 320)
    }

    private var mainLine: some View {
        HStack(spacing: 10) {
            ColorPicker("Kleur van \(tag.name)", selection: $color, supportsOpacity: false)
                .labelsHidden()
                .help("Kleur van de tag in lijsten en grafieken")
            TextField("Naam", text: $name)
                .focused($focused)
                .onSubmit { commit() }
                .settingsInlineField()
            Text(usage == 0 ? "niet gebruikt" : SettingsFormat.count(usage, "boeking", "boekingen"))
                .font(.callout).monospacedDigit().foregroundStyle(.secondary)
                .frame(width: 110, alignment: .trailing)
            HStack(spacing: 2) {
                Button { onMove(-1) } label: { Image(systemName: "chevron.up") }.disabled(isFirst).help("Omhoog")
                Button { onMove(1) } label: { Image(systemName: "chevron.down") }.disabled(isLast).help("Omlaag")
                Button(role: .destructive, action: onDelete) { Image(systemName: "trash") }.help("Tag verwijderen")
            }
            .buttonStyle(.borderless).controlSize(.small)
        }
    }

    private func commit() {
        var next = tag
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { name = tag.name } else { next.name = trimmed }
        next.color = SettingsFormat.hex(color)
        guard next.name != tag.name || next.color != tag.color.uppercased() else { return }
        onSave(next)
    }
}
