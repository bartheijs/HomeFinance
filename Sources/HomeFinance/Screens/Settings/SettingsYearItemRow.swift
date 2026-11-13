import SwiftUI
import HFCore

/// Eén vaste post. Dicht: alleen naam en planbedrag. Open: alle instellingen van de post.
/// Tekstvelden bewaren bij Enter of zodra je het veld verlaat.
struct SettingsYearItemRow: View {
    let item: BudgetItem
    let pots: [Pot]
    let reserveLineCount: Int
    let entryCount: Int
    let isExpanded: Bool
    let isFirst: Bool
    let isLast: Bool
    var onToggle: () -> Void
    var onSave: (BudgetItem) -> Void
    var onMove: (Int) -> Void
    var onDelete: () -> Void

    private enum Field: Hashable { case label, plan, day }

    @State private var draft: BudgetItem
    @State private var plan: Money?
    @State private var showMonths = false
    @FocusState private var focus: Field?

    init(item: BudgetItem, pots: [Pot], reserveLineCount: Int, entryCount: Int, isExpanded: Bool,
         isFirst: Bool, isLast: Bool, onToggle: @escaping () -> Void,
         onSave: @escaping (BudgetItem) -> Void, onMove: @escaping (Int) -> Void, onDelete: @escaping () -> Void) {
        self.item = item; self.pots = pots; self.reserveLineCount = reserveLineCount; self.entryCount = entryCount
        self.isExpanded = isExpanded; self.isFirst = isFirst; self.isLast = isLast
        self.onToggle = onToggle; self.onSave = onSave; self.onMove = onMove; self.onDelete = onDelete
        _draft = State(initialValue: item)
        _plan = State(initialValue: item.planAmount.magnitude)
    }

    var body: some View {
        VStack(spacing: 0) {
            summary
            if isExpanded { details }
        }
        .onChange(of: item) { _, new in
            draft = new
            plan = new.planAmount.magnitude
        }
        .onChange(of: focus) { old, new in
            if old != nil && old != new { commit() }
        }
    }

    // MARK: Dicht

    private var summary: some View {
        Button(action: onToggle) {
            HStack(spacing: 10) {
                Text(item.label).font(.title3)
                if item.isReserveTotal {
                    Text("som van de reserveringen").font(.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Text(item.planAmount.magnitude.formatted()).font(.title3).monospacedDigit()
                Image(systemName: "chevron.right").font(.callout).foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
            .padding(.horizontal, 18).padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isExpanded ? "Klik om te sluiten" : "Klik om naam, bedrag, frequentie en dag te wijzigen")
    }

    // MARK: Open

    private var details: some View {
        VStack(alignment: .leading, spacing: 12) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 10) {
                GridRow {
                    Text("Naam").foregroundStyle(.secondary)
                    TextField("Naam van de post", text: $draft.label)
                        .textFieldStyle(.roundedBorder)
                        .focused($focus, equals: .label)
                        .onSubmit { commit() }
                }
                GridRow {
                    Text("Plan per keer").foregroundStyle(.secondary)
                    planField
                }
                GridRow {
                    Text("Hoe vaak").foregroundStyle(.secondary)
                    HStack(spacing: 10) {
                        frequencyPicker
                        monthsButton
                    }
                }
                GridRow {
                    Text("Verwachte dag").foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        TextField("–", value: $draft.expectedDay, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.trailing).monospacedDigit().frame(width: 52)
                            .focused($focus, equals: .day)
                            .onSubmit { commit() }
                        Text("van de maand. Daarna telt de post als ‘te laat’.").font(.callout).foregroundStyle(.secondary)
                    }
                }
                extraRow
            }
            HStack(spacing: 8) {
                Button { onMove(-1) } label: { Label("Omhoog", systemImage: "chevron.up") }.disabled(isFirst)
                Button { onMove(1) } label: { Label("Omlaag", systemImage: "chevron.down") }.disabled(isLast)
                Spacer()
                Button(role: .destructive, action: onDelete) { Label("Verwijder post", systemImage: "trash") }
                    .help(entryCount > 0 ? "De \(SettingsFormat.count(entryCount, "boeking", "boekingen")) op deze post kunnen divers worden"
                                         : "Op deze post staan geen boekingen")
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 18).padding(.top, 6).padding(.bottom, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.03))
    }

    @ViewBuilder private var planField: some View {
        if item.isReserveTotal {
            HStack(spacing: 6) {
                Text(item.planAmount.magnitude.formatted()).monospacedDigit()
                Image(systemName: "lock.fill").font(.caption).foregroundStyle(.tertiary)
                Text("Wordt vanzelf berekend: de som van \(SettingsFormat.count(reserveLineCount, "reservering", "reserveringen")).")
                    .font(.callout).foregroundStyle(.secondary)
            }
        } else {
            HStack(spacing: 6) {
                Text("€").foregroundStyle(.secondary)
                MoneyField("0,00", value: $plan)
                    .id(item.planAmount)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 120)
                    .focused($focus, equals: .plan)
                    .onSubmit { commit() }
            }
        }
    }

    private var frequencyPicker: some View {
        Picker("Hoe vaak", selection: Binding(get: { draft.frequency }, set: { setFrequency($0) })) {
            Text("Elke maand").tag(Frequency.maand)
            Text("Per kwartaal").tag(Frequency.kwartaal)
            Text("Per jaar").tag(Frequency.jaar)
        }
        .pickerStyle(.segmented).labelsHidden().fixedSize()
    }

    @ViewBuilder private var monthsButton: some View {
        if draft.frequency != .maand {
            Button { showMonths = true } label: {
                HStack(spacing: 4) {
                    Text(monthSummary).lineLimit(1)
                    Image(systemName: "chevron.down").font(.caption2)
                }
            }
            .help("Kies de maanden waarin deze post verwacht wordt")
            .popover(isPresented: $showMonths, arrowEdge: .bottom) { monthsPopover }
        }
    }

    private var monthSummary: String {
        let months = draft.months.sorted()
        return months.isEmpty ? "kies maanden" : "in " + months.map { Day.monthNamesShort[$0 - 1] }.joined(separator: ", ")
    }

    private var monthsPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Verwacht in").font(.headline)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(64), alignment: .leading), count: 4), alignment: .leading, spacing: 8) {
                ForEach(1...12, id: \.self) { month in
                    Toggle(Day.monthNamesShort[month - 1], isOn: Binding(
                        get: { draft.months.contains(month) }, set: { setMonth(month, $0) }))
                        .toggleStyle(.checkbox)
                }
            }
        }
        .padding(16)
    }

    @ViewBuilder private var extraRow: some View {
        if item.direction == .RES {
            GridRow {
                Text("Vult pot").foregroundStyle(.secondary)
                Picker("Pot", selection: Binding(get: { draft.potId }, set: { draft.potId = $0; commit() })) {
                    Text("Geen pot").tag(Int64?.none)
                    Divider()
                    ForEach(pots.filter { !$0.archived || $0.id == draft.potId }) { pot in
                        Text(pot.name).tag(pot.id)
                    }
                }
                .labelsHidden().fixedSize()
                .help("De pot op de spaarrekening die met dit deel van de reservering gevuld wordt")
            }
        }
    }

    // MARK: Bewaren

    private func setFrequency(_ frequency: Frequency) {
        draft.frequency = frequency
        switch frequency {
        case .maand: draft.expectedMonths = ""
        case .kwartaal: if draft.months.count != 4 { draft.expectedMonths = "1,4,7,10" }
        case .jaar: draft.expectedMonths = draft.months.first.map(String.init) ?? "1"
        }
        commit()
    }

    private func setMonth(_ month: Int, _ on: Bool) {
        var months = Set(draft.months)
        if on { months.insert(month) } else { months.remove(month) }
        draft.expectedMonths = months.sorted().map(String.init).joined(separator: ",")
        if !months.isEmpty { commit() }
    }

    private func commit() {
        var next = draft
        next.label = next.label.trimmingCharacters(in: .whitespaces)
        guard !next.label.isEmpty else { draft.label = item.label; return }
        if !item.isReserveTotal {
            guard let plan else { return }
            next.planAmount = item.direction == .IN ? plan.magnitude : -plan.magnitude
        }
        if let day = next.expectedDay { next.expectedDay = min(max(day, 1), 31) }
        draft = next
        guard next != item else { return }
        onSave(next)
    }
}
