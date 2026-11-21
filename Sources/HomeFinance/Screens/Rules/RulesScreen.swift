import SwiftUI
import GRDB
import HFCore
import HFRules

/// Regels beheren: de lijst links, de regel met een live voorbeeld rechts. Sinds UX-stap C1 een tabblad van
/// Instellingen (`embedded`): dan zonder eigen kop, want die heeft Instellingen al.
struct RulesScreen: View {
    @Environment(AppModel.self) private var model
    var embedded = false

    @State private var data = RulesData()
    @State private var loaded = false

    // Filter
    @State private var search = ""
    @State private var origin: RulesOriginFilter = .alle
    @State private var neverUsedOnly = false

    // Keuze en concept
    @State private var selectedId: Int64?
    @State private var isNew = false
    @State private var draft: Rule?
    @State private var saved: Rule?
    @State private var draftToken = 0
    @State private var hits: [RuleTestHit] = []

    // Dialogen
    @State private var confirmDelete = false
    @State private var pendingAction: RulesPendingAction?

    private var newRuleButton: some View {
        Button { request(.new) } label: { Label("Nieuwe regel", systemImage: "plus") }
            .keyboardShortcut("n", modifiers: .command)
            .help("Maak zelf een regel (⌘N)")
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                if embedded {
                    HStack {
                        Spacer()
                        newRuleButton
                    }
                    .padding(.horizontal, 24).padding(.vertical, 10)
                } else {
                    ScreenHeader("Regels",
                                 subtitle: "Een regel ontstaat als je in Nakijken ‘Onthoud als regel’ aanvinkt, of als je hem hier maakt.") {
                        newRuleButton
                    }
                }
                if loaded && data.rules.isEmpty && !isNew {
                    EmptyState(title: "Nog geen regels",
                               message: "Vink bij het boeken in Importeren en nakijken ‘Onthoud als regel’ aan, of maak hier zelf een regel.",
                               icon: "wand.and.stars", actionTitle: "Nieuwe regel") { request(.new) }
                } else {
                    VStack(spacing: 0) {
                        filterBar
                        table
                    }
                    .frame(maxWidth: 780)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
            if let binding = draftBinding {
                Divider()
                RulesEditor(draft: binding, data: data, hits: hits, year: model.year, isNew: isNew, isDirty: isDirty,
                            position: position, canMove: !isNew && !isDirty,
                            onSave: { save() }, onRevert: revert, onDuplicate: { request(.duplicate) },
                            onDelete: { confirmDelete = true }, onMove: { moveSelected(by: $0) },
                            onClose: { request(.close) })
                    .id(draftToken)
                    .frame(width: 390)
            }
        }
        .task(id: RulesReloadKey(revision: model.revision, year: model.year)) { load() }
        .onChange(of: draft) { _, _ in refreshHits() }
        .confirmationDialog("Regel ‘\(draft?.name ?? "")’ verwijderen?", isPresented: $confirmDelete) {
            Button("Verwijder", role: .destructive) { deleteSelected() }
            Button("Annuleer", role: .cancel) {}
        } message: {
            Text("Boekingen die met deze regel zijn gemaakt blijven staan. Nieuwe transacties krijgen dit voorstel niet meer.")
        }
        .confirmationDialog("Wijzigingen bewaren?", isPresented: Binding(
            get: { pendingAction != nil }, set: { if !$0 { pendingAction = nil } }), presenting: pendingAction) { action in
            Button("Bewaar") { if save() { run(action) } }
            Button("Niet bewaren", role: .destructive) { run(action) }
            Button("Annuleer", role: .cancel) {}
        } message: { _ in
            Text("De regel ‘\(draft?.name ?? "")’ is gewijzigd maar nog niet bewaard.")
        }
    }

    // MARK: Filter en tabel

    private var filterBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Zoek regel, tegenpartij of post", text: $search).textFieldStyle(.plain)
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.hairline))
            .frame(maxWidth: 320)

            Menu {
                Picker("Herkomst", selection: $origin) {
                    ForEach(RulesOriginFilter.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
                Toggle("Alleen nooit gebruikt", isOn: $neverUsedOnly)
                if origin != .alle || neverUsedOnly {
                    Divider()
                    Button("Wis filter") { origin = .alle; neverUsedOnly = false }
                }
            } label: {
                Label(filterLabel, systemImage: origin != .alle || neverUsedOnly
                      ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
            }
            .fixedSize()
            .help("Toon alleen zelf gemaakte of geleerde regels, of regels die nog nooit gebruikt zijn")

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24).padding(.bottom, 12)
    }

    private var summary: String {
        isFiltered ? "\(visible.count) van \(data.rules.count) regels" : "\(data.rules.count) regels"
    }

    private var filterLabel: String {
        var parts: [String] = []
        if origin != .alle { parts.append(origin.title) }
        if neverUsedOnly { parts.append("nooit gebruikt") }
        return parts.isEmpty ? "Filter" : parts.joined(separator: ", ")
    }

    private var table: some View {
        let rows = visible
        return VStack(spacing: 0) {
            if rows.isEmpty {
                EmptyState(title: "Geen regels gevonden", message: "Geen enkele regel past bij dit filter.",
                           icon: "line.3.horizontal.decrease.circle", actionTitle: "Wis filters") {
                    search = ""; origin = .alle; neverUsedOnly = false
                }
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(rows.enumerated()), id: \.element.id) { index, rule in
                                RulesRow(rule: rule, data: data, isSelected: !isNew && rule.id == selectedId,
                                         onToggle: { setEnabled(rule, $0) })
                                    .onTapGesture { if let id = rule.id { request(.select(id)) } }
                                    .draggable(RulesDragItem.string(for: rule))
                                    .dropDestination(for: String.self) { items, _ in
                                        guard !isFiltered, let dragged = items.first.flatMap(RulesDragItem.id(from:)) else { return false }
                                        return drop(dragged, before: rule)
                                    }
                                    .id(rule.id)
                                if index < rows.count - 1 { Divider().padding(.leading, 18) }
                            }
                        }
                    }
                    .onChange(of: selectedId) { _, id in
                        if let id { withAnimation { proxy.scrollTo(id) } }
                    }
                }
            }
            Divider()
            HStack {
                Text(summary).monospacedDigit()
                Spacer()
                Text("Klik op een regel voor de details")
            }
            .font(.callout).foregroundStyle(.secondary).lineLimit(1)
            .padding(.horizontal, 18).padding(.vertical, 9)
        }
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.hairline.opacity(0.6)))
        .padding(.horizontal, 24).padding(.bottom, 20)
        .focusable()
        .focusEffectDisabled()
        .onMoveCommand { direction in
            switch direction {
            case .up: stepSelection(-1)
            case .down: stepSelection(1)
            default: break
            }
        }
        .onDeleteCommand { if selectedId != nil && !isNew { confirmDelete = true } }
    }

    private var isFiltered: Bool {
        !search.trimmingCharacters(in: .whitespaces).isEmpty || origin != .alle || neverUsedOnly
    }

    private var visible: [Rule] {
        let needle = search.trimmingCharacters(in: .whitespaces).lowercased()
        return data.rules.filter { rule in
            if origin == .handmatig && rule.origin != .handmatig { return false }
            if origin == .geleerd && rule.origin != .geleerd { return false }
            if neverUsedOnly && rule.hitCount > 0 { return false }
            guard !needle.isEmpty else { return true }
            let haystack = [rule.name, rule.counterpartyContains, rule.counterpartyIban, rule.descriptionContains,
                            rule.targetItemLabel, rule.entryLabel, data.potName(rule.targetPotId)]
                .compactMap { $0 }.joined(separator: " ").lowercased()
            return haystack.contains(needle)
        }
    }

    // MARK: Concept

    private var draftBinding: Binding<Rule>? {
        guard let current = draft else { return nil }
        return Binding(get: { draft ?? current }, set: { draft = $0 })
    }

    private var isDirty: Bool { draft != saved }

    private func load() {
        data = model.read(RulesData()) { try RulesData.load($0, year: model.year) }
        loaded = true
        if isNew { refreshHits(); return }
        if let id = selectedId, let fresh = data.rules.first(where: { $0.id == id }) {
            // Gebruiksteller en volgorde bijwerken zonder eigen wijzigingen te verliezen.
            if !isDirty { draft = fresh; saved = fresh; draftToken += 1 } else { saved = fresh }
        } else {
            selectedId = nil; draft = nil; saved = nil
        }
        refreshHits()
    }

    private func refreshHits() {
        guard let rule = draft, RulesText.hasConditions(rule) else { hits = []; return }
        hits = model.read([]) { try RuleEngine.testRule(rule, against: $0) }
    }

    private func show(_ rule: Rule) {
        isNew = false
        selectedId = rule.id
        draft = rule; saved = rule
        draftToken += 1
    }

    private func startNew(from template: Rule? = nil) {
        var rule = template ?? Rule(name: "")
        rule.id = nil
        rule.origin = .handmatig
        rule.hitCount = 0
        rule.lastUsed = nil
        if template != nil {
            rule.name += " kopie"
        } else {
            rule.priority = ((data.rules.map(\.priority).max() ?? 0) / 10 + 1) * 10
        }
        isNew = true
        draft = rule; saved = rule
        draftToken += 1
    }

    /// Voert een actie uit, of vraagt eerst wat er met niet-bewaarde wijzigingen moet gebeuren.
    private func request(_ action: RulesPendingAction) {
        if case .select(let id) = action, id == selectedId, !isNew { return }
        if isDirty { pendingAction = action } else { run(action) }
    }

    private func run(_ action: RulesPendingAction) {
        pendingAction = nil
        switch action {
        case .select(let id):
            if let rule = data.rules.first(where: { $0.id == id }) { show(rule) }
        case .new:
            startNew()
        case .duplicate:
            startNew(from: saved ?? draft)
        case .close:
            isNew = false
            selectedId = nil; draft = nil; saved = nil
        }
    }

    private func stepSelection(_ delta: Int) {
        let rows = visible
        guard !rows.isEmpty else { return }
        let index = rows.firstIndex { $0.id == selectedId } ?? (delta > 0 ? -1 : rows.count)
        let next = min(max(index + delta, 0), rows.count - 1)
        if let id = rows[next].id { request(.select(id)) }
    }

    // MARK: Schrijven

    @discardableResult
    private func save() -> Bool {
        guard var rule = draft else { return false }
        let ok = model.perform("Regel ‘\(rule.name)’ bewaard") {
            try model.db.write { db in try RuleEngine.save(&rule, db) }
        }
        guard ok else { return false }
        isNew = false
        selectedId = rule.id
        draft = rule; saved = rule
        draftToken += 1
        load()
        return true
    }

    private func revert() {
        if isNew {
            isNew = false
            draft = nil; saved = nil
            if let id = selectedId, let rule = data.rules.first(where: { $0.id == id }) { show(rule) }
        } else {
            draft = saved
            draftToken += 1
        }
    }

    private func deleteSelected() {
        guard let id = selectedId, let name = saved?.name else { return }
        let ok = model.perform("Regel ‘\(name)’ verwijderd") {
            try model.db.write { db in _ = try RuleEngine.delete(ruleId: id, db) }
        }
        guard ok else { return }
        selectedId = nil; draft = nil; saved = nil
        load()
    }

    private func setEnabled(_ rule: Rule, _ enabled: Bool) {
        guard let id = rule.id else { return }
        model.perform { try model.db.write { db in try RuleEngine.setEnabled(ruleId: id, enabled, db) } }
        if id == selectedId, !isNew {
            draft?.enabled = enabled
            saved?.enabled = enabled
        }
        load()
    }

    /// Plek van de gekozen regel in de volgorde: (nummer vanaf 1, totaal).
    private var position: (index: Int, count: Int)? {
        guard let i = data.rules.firstIndex(where: { $0.id == selectedId }) else { return nil }
        return (i + 1, data.rules.count)
    }

    private func moveSelected(by delta: Int) {
        var ids = data.rules.compactMap(\.id)
        guard let id = selectedId, let index = ids.firstIndex(of: id) else { return }
        let target = index + delta
        guard ids.indices.contains(target) else { return }
        ids.swapAt(index, target)
        reorder(ids)
    }

    private func drop(_ dragged: Int64, before rule: Rule) -> Bool {
        var ids = data.rules.compactMap(\.id)
        guard let target = rule.id, dragged != target, let from = ids.firstIndex(of: dragged) else { return false }
        ids.remove(at: from)
        guard let to = ids.firstIndex(of: target) else { return false }
        ids.insert(dragged, at: to)
        reorder(ids)
        return true
    }

    private func reorder(_ ids: [Int64]) {
        model.perform { try model.db.write { db in try RuleEngine.reorder(ruleIds: ids, db) } }
        load()
    }
}

enum RulesPendingAction: Identifiable {
    case select(Int64), new, duplicate, close
    var id: String {
        switch self {
        case .select(let id): "select-\(id)"
        case .new: "new"
        case .duplicate: "duplicate"
        case .close: "close"
        }
    }
}

struct RulesReloadKey: Equatable {
    var revision: Int
    var year: Int
}

enum RulesDragItem {
    static func string(for rule: Rule) -> String { "hf-rule:\(rule.id ?? -1)" }
    static func id(from text: String) -> Int64? {
        text.hasPrefix("hf-rule:") ? Int64(text.dropFirst("hf-rule:".count)) : nil
    }
}
