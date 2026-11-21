import SwiftUI
import GRDB
import HFCore
import HFBudget
import HFInsight

struct SettingsTagsData: Equatable {
    var tags: [Tag] = []
    /// Gebruik per tag, uitgesplitst naar betaal- en spaarrekening (uit `Insight.tagUsage`).
    var usage: [Int64: TagUsage] = [:]
    /// Openstaand bedrag per tag met verrekenen (uit `Insight.settlementOverview`).
    var outstanding: [Int64: Money] = [:]
    /// Dag van de beginstand per tag (vanaf wanneer verrekenen aan staat): de voorgestelde dag voor een startbedrag.
    var openingDay: [Int64: Day] = [:]

    static func load(_ db: Database, today: Day) throws -> SettingsTagsData {
        var d = SettingsTagsData()
        d.tags = try Tag.order(Column("sortOrder"), Column("id")).fetchAll(db)
        for s in try Settlement.filter(Column("isOpening") == true).fetchAll(db) { d.openingDay[s.tagId] = s.day }
        d.usage = try Insight.tagUsage(db)
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
                Text("**Voorgeschoten** is voor uitgaven die je voorschiet en terugkrijgt, zoals tankkosten van je werk. De app houdt bij wat je nog terugkrijgt.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text("Stond er bij de start van de app al iets open, zet dat dan als **startbedrag** bij de tag. Met **telt mee in nog te besteden** reken je het openstaande bedrag alvast mee als geld dat terugkomt.")
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
                            SettingsTagRow(tag: tag, usage: data.usage[tag.id ?? -1] ?? TagUsage(tagId: tag.id ?? -1),
                                           outstanding: data.outstanding[tag.id ?? -1] ?? .zero, today: model.today,
                                           openingDay: data.openingDay[tag.id ?? -1],
                                           isFirst: index == 0, isLast: index == data.tags.count - 1,
                                           onSave: { save($0) }, onSettle: { setSettles(tag, from: $0) },
                                           onStart: { setStart(tag, amount: $0, day: $1) },
                                           onCounts: { setCounts(tag, $0) },
                                           onMove: { move(tag, by: $0) }, onShow: { show(tag) },
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
            let n = data.usage[tag.id ?? -1]?.total ?? 0
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
            _ = write("Voorgeschoten staat aan voor ‘\(tag.name)’ vanaf \(from.short(withYear: true))") { db in
                _ = try SettlementService.enable(db, tagId: id, from: from)
            }
        } else {
            _ = write("Voorgeschoten staat uit voor ‘\(tag.name)’") { db in try SettlementService.disable(db, tagId: id) }
        }
    }

    /// Startbedrag vastleggen (€ 0,00 haalt het weg).
    private func setStart(_ tag: Tag, amount: Money, day: Day) {
        guard let id = tag.id else { return }
        let text = amount.isZero ? "Startbedrag van ‘\(tag.name)’ weggehaald"
            : "Startbedrag van ‘\(tag.name)’: \(amount.formatted()) op \(day.short(withYear: true))"
        _ = write(text) { db in _ = try SettlementService.setStart(db, tagId: id, amount: amount, day: day) }
    }

    /// "Telt mee in nog te besteden" aan of uit.
    private func setCounts(_ tag: Tag, _ on: Bool) {
        guard let id = tag.id else { return }
        let text = on ? "Openstaand bij ‘\(tag.name)’ telt mee in nog te besteden"
            : "Openstaand bij ‘\(tag.name)’ telt niet meer mee in nog te besteden"
        _ = write(text) { db in _ = try TagService.setCountsInSpendable(db, tagId: id, on) }
    }

    /// Opent Transacties op de betaalrekening met het filter op deze tag.
    private func show(_ tag: Tag) {
        guard let id = tag.id else { return }
        guard let target = model.read(nil, { try Insight.tagFilterTarget($0, tagId: id) }) else {
            model.toast = "Er is geen betaalrekening om de boekingen op te tonen"
            return
        }
        model.transactionsJump = TransactionsJump(accountId: target.accountId, tagId: target.tagId)
        model.selection = .transactions
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
    let usage: TagUsage
    let outstanding: Money
    let today: Day
    /// Dag van de beginstand, als voorstel voor de dag van het startbedrag.
    let openingDay: Day?
    let isFirst: Bool
    let isLast: Bool
    var onSave: (Tag) -> Void
    /// Verrekenen aan vanaf een dag, of uit (nil).
    var onSettle: (Day?) -> Void
    /// Startbedrag vastleggen (€ 0,00 = weghalen).
    var onStart: (Money, Day) -> Void
    /// "Telt mee in nog te besteden" aan of uit.
    var onCounts: (Bool) -> Void
    var onMove: (Int) -> Void
    /// Opent Transacties met het filter op deze tag.
    var onShow: () -> Void
    var onDelete: () -> Void

    @State private var name: String
    @State private var color: Color
    @FocusState private var focused: Bool
    @State private var askFrom = false
    @State private var fromDate = Date()
    @State private var editStart = false
    @State private var startValue: Money?
    @State private var startDate = Date()

    init(tag: Tag, usage: TagUsage, outstanding: Money, today: Day, openingDay: Day?, isFirst: Bool, isLast: Bool,
         onSave: @escaping (Tag) -> Void, onSettle: @escaping (Day?) -> Void,
         onStart: @escaping (Money, Day) -> Void, onCounts: @escaping (Bool) -> Void,
         onMove: @escaping (Int) -> Void, onShow: @escaping () -> Void, onDelete: @escaping () -> Void) {
        self.tag = tag; self.usage = usage; self.outstanding = outstanding; self.today = today
        self.openingDay = openingDay
        self.isFirst = isFirst; self.isLast = isLast
        self.onSave = onSave; self.onSettle = onSettle; self.onStart = onStart; self.onCounts = onCounts
        self.onMove = onMove; self.onShow = onShow
        self.onDelete = onDelete
        _name = State(initialValue: tag.name)
        _color = State(initialValue: Color(hex: tag.color))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            mainLine
            settleLine
            if tag.settles {
                startLine
                countsLine
            }
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
            Toggle("Voorgeschoten", isOn: Binding(get: { tag.settles }, set: { on in
                if on { fromDate = SettingsFormat.date(today); askFrom = true } else { onSettle(nil) }
            }))
            .toggleStyle(.switch).controlSize(.mini)
            .help("Voor uitgaven die je voorschiet en terugkrijgt, zoals tankkosten van je werk. De app houdt bij wat je nog terugkrijgt.")
            .popover(isPresented: $askFrom, arrowEdge: .bottom) { fromPopover }
            if tag.settles {
                Text("openstaand").foregroundStyle(.secondary)
                Text(outstanding.formatted()).monospacedDigit()
                    .foregroundStyle(outstanding.isZero ? Color.secondary : Color.primary)
                    .help("Nog terug te krijgen: de uitgaven met deze tag die nog niet terugbetaald zijn.")
            }
            Spacer(minLength: 0)
        }
        .font(.callout)
        .padding(.leading, 54)
    }

    /// Startbedrag: wat er bij de start van de app al openstond.
    private var startLine: some View {
        HStack(spacing: 8) {
            Text("Startbedrag").foregroundStyle(.secondary)
            if tag.startAmount.isZero {
                Text("geen").foregroundStyle(.secondary)
            } else {
                Text(tag.startAmount.formatted()).monospacedDigit()
                if let day = tag.startDay { Text("op \(day.short(withYear: true))").foregroundStyle(.secondary) }
                if tag.startSettlementId != nil { Text("· terugbetaald").foregroundStyle(.secondary) }
            }
            if tag.startSettlementId == nil {
                Button(tag.startAmount.isZero ? "Voeg toe…" : "Wijzig…") {
                    startValue = tag.startAmount.isZero ? nil : tag.startAmount
                    startDate = SettingsFormat.date(tag.startDay ?? openingDay ?? today)
                    editStart = true
                }
                .buttonStyle(.link)
                .help("Een bedrag dat bij de start van de app al openstond en nog terug moet komen")
                .popover(isPresented: $editStart, arrowEdge: .bottom) { startPopover }
            }
            Spacer(minLength: 0)
        }
        .font(.callout)
        .padding(.leading, 54)
    }

    private var startPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Startbedrag voor ‘\(tag.name)’").font(.headline)
            Text("Geld dat bij de start van de app al was voorgeschoten en nog terug moet komen. Het telt mee in wat je nog terugkrijgt en gaat mee als het geld terug is. Leeg of 0 haalt het weg.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Text("Bedrag")
                MoneyField("0,00", value: $startValue).textFieldStyle(.roundedBorder).frame(width: 120)
            }
            DatePicker("Op", selection: $startDate, displayedComponents: .date)
            HStack {
                Spacer()
                Button("Annuleer", role: .cancel) { editStart = false }
                Button("Bewaar") {
                    editStart = false
                    onStart(startValue ?? .zero, Day(date: startDate))
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 340)
    }

    /// Schakelaar "Telt mee in nog te besteden".
    private var countsLine: some View {
        HStack(spacing: 8) {
            Toggle("Telt mee in nog te besteden", isOn: Binding(get: { tag.countsInSpendable }, set: { onCounts($0) }))
                .toggleStyle(.switch).controlSize(.mini)
                .help("Rekent het openstaande bedrag alvast mee als geld dat terugkomt, in ‘besteedbaar nu’ en ‘nog te besteden deze maand’.")
            Spacer(minLength: 0)
        }
        .font(.callout)
        .padding(.leading, 54)
    }

    private var fromPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Voorgeschoten voor ‘\(tag.name)’").font(.headline)
            Text("Vanaf welke datum tellen uitgaven mee als openstaand? Alles van daarvoor geldt als al terugbetaald.")
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
            usageText.frame(width: 130, alignment: .trailing)
            HStack(spacing: 2) {
                Button { onMove(-1) } label: { Image(systemName: "chevron.up") }.disabled(isFirst).help("Omhoog")
                Button { onMove(1) } label: { Image(systemName: "chevron.down") }.disabled(isLast).help("Omlaag")
                Button(role: .destructive, action: onDelete) { Image(systemName: "trash") }.help("Tag verwijderen")
            }
            .buttonStyle(.borderless).controlSize(.small)
        }
    }

    /// "n boekingen" als link naar Transacties (betaalrekening, filter op de tag). Staan er ook boekingen
    /// van vroeger op een spaarrekening, dan staat dat eronder: die zijn daar te vinden via de spaarrekening.
    @ViewBuilder private var usageText: some View {
        if usage.total == 0 {
            Text("niet gebruikt").font(.callout).foregroundStyle(.secondary)
        } else {
            VStack(alignment: .trailing, spacing: 0) {
                Button(SettingsFormat.count(usage.total, "boeking", "boekingen"), action: onShow)
                    .buttonStyle(.link).font(.callout).monospacedDigit()
                    .help("Toon de boekingen met ‘\(tag.name)’ in Transacties (betaalrekening)")
                if usage.onSavings > 0 {
                    Text("waarvan \(usage.onSavings) op spaar").font(.caption).foregroundStyle(.secondary)
                        .help("Tags horen alleen op de betaalrekening. Deze boekingen staan op een spaarrekening; daar kun je de tag weghalen.")
                }
            }
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
