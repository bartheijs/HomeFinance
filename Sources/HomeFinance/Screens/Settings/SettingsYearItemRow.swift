import SwiftUI
import HFCore
import HFInsight

/// Eén vaste post. Dicht: alleen naam en planbedrag. Open: alle instellingen van de post.
/// Tekstvelden bewaren bij Enter of zodra je het veld verlaat.
struct SettingsYearItemRow: View {
    let item: BudgetItem
    let pots: [Pot]
    /// Vaste stortingen waaraan een UIT-post gekoppeld kan worden (id en naam).
    let distributions: [SettingsDistributionOption]
    let reserveLineCount: Int
    let entryCount: Int
    let isExpanded: Bool
    /// De kolom "Wat als" is zichtbaar.
    var showScenario = false
    /// De post in de maandbalans (bedrag per maand); nil voor RES-regels.
    var balanceRow: PlanBalanceRow?
    /// Wat-als-bedrag zetten (met teken) of wissen (nil).
    var onScenario: (Money?) -> Void = { _ in }
    let isFirst: Bool
    let isLast: Bool
    var onToggle: () -> Void
    var onSave: (BudgetItem) -> Void
    /// Koppelen aan een vaste storting, of ontkoppelen (nil).
    var onLink: (Int64?) -> Void
    var onGoToPots: () -> Void
    var onMove: (Int) -> Void
    var onDelete: () -> Void

    private enum Field: Hashable { case label, plan, day, scenario }

    @State private var draft: BudgetItem
    @State private var plan: Money?
    @State private var scenario: Money?
    @State private var showMonths = false
    @FocusState private var focus: Field?

    init(item: BudgetItem, pots: [Pot], distributions: [SettingsDistributionOption], reserveLineCount: Int,
         entryCount: Int, isExpanded: Bool, isFirst: Bool, isLast: Bool, onToggle: @escaping () -> Void,
         onSave: @escaping (BudgetItem) -> Void, onLink: @escaping (Int64?) -> Void,
         onGoToPots: @escaping () -> Void, onMove: @escaping (Int) -> Void, onDelete: @escaping () -> Void) {
        self.distributions = distributions; self.onLink = onLink; self.onGoToPots = onGoToPots
        self.item = item; self.pots = pots; self.reserveLineCount = reserveLineCount; self.entryCount = entryCount
        self.isExpanded = isExpanded; self.isFirst = isFirst; self.isLast = isLast
        self.onToggle = onToggle; self.onSave = onSave; self.onMove = onMove; self.onDelete = onDelete
        _draft = State(initialValue: item)
        _plan = State(initialValue: item.planAmount.magnitude)
        _scenario = State(initialValue: item.scenarioAmount?.magnitude)
    }

    var body: some View {
        VStack(spacing: 0) {
            summary
            if isExpanded { details }
        }
        .onChange(of: item) { _, new in
            draft = new
            plan = new.planAmount.magnitude
            scenario = new.scenarioAmount?.magnitude
        }
        .onChange(of: focus) { old, new in
            guard old != nil, old != new else { return }
            if old == .scenario { commitScenario() } else { commit() }
        }
    }

    // MARK: Dicht

    private var summary: some View {
        HStack(spacing: 10) {
            Text(item.label).font(.title3)
            if let name = distributionName {
                Label(name, systemImage: "arrow.triangle.branch")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Color.primary.opacity(0.06), in: Capsule())
                    .help("Het planbedrag volgt de vaste storting ‘\(name)’")
            } else if item.isReserveTotal {
                Text("som van de reserveringen").font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 1) {
                Text(item.planAmount.magnitude.formatted()).font(.title3).monospacedDigit()
                if let row = balanceRow, row.frequency != .maand {
                    Text("\(row.planPerMonth.magnitude.formatted()) per maand")
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            if showScenario { scenarioColumn }
            Image(systemName: "chevron.right").font(.callout).foregroundStyle(.tertiary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
        }
        .padding(.horizontal, 18).padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggle)
        .help(isExpanded ? "Klik om te sluiten" : "Klik om naam, bedrag, frequentie en dag te wijzigen")
    }

    /// Het wat-als-bedrag van de post: leeg = gelijk aan het plan.
    @ViewBuilder private var scenarioColumn: some View {
        if item.direction == .RES {
            Color.clear.frame(width: SettingsYearItemRow.scenarioWidth, height: 1)
        } else {
            VStack(alignment: .trailing, spacing: 1) {
                MoneyField("= plan", value: $scenario)
                    .id(item.scenarioAmount)
                    .textFieldStyle(.roundedBorder)
                    .focused($focus, equals: .scenario)
                    .onSubmit { commitScenario() }
                    .help("Wat als dit bedrag anders was? Leeg = gelijk aan het plan. Een som als 3150+200 mag ook.")
                if let row = balanceRow, row.frequency != .maand, let perMonth = row.scenarioPerMonth {
                    Text("\(perMonth.magnitude.formatted()) per maand")
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            .frame(width: SettingsYearItemRow.scenarioWidth)
        }
    }

    static let scenarioWidth: CGFloat = 120

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

    /// Naam van de vaste storting waaraan deze post gekoppeld is, of nil.
    private var distributionName: String? {
        guard let id = item.distributionId else { return nil }
        return distributions.first { $0.id == id }?.name ?? "vaste storting"
    }

    @ViewBuilder private var planField: some View {
        if let name = distributionName {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(item.planAmount.magnitude.formatted()).monospacedDigit()
                    Image(systemName: "lock.fill").font(.caption).foregroundStyle(.tertiary)
                }
                Text("Volgt de vaste storting ‘\(name)’ (instellen bij Potten en sparen › Vaste stortingen)")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Naar Vaste stortingen", action: onGoToPots).controlSize(.small)
            }
        } else if item.isReserveTotal {
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
        if item.direction == .UIT, item.distributionId != nil || !distributions.isEmpty {
            GridRow {
                Text("Hoort bij vaste storting").foregroundStyle(.secondary)
                Picker("Vaste storting", selection: Binding(get: { item.distributionId }, set: { onLink($0) })) {
                    Text("Geen").tag(Int64?.none)
                    Divider()
                    ForEach(distributions.filter { !$0.archived || $0.id == item.distributionId }) { option in
                        Text(option.name).tag(Optional(option.id))
                    }
                }
                .labelsHidden().fixedSize()
                .help("Gekoppeld aan een vaste storting volgt het planbedrag vanzelf het totaal van die storting.")
            }
        } else if item.direction == .RES {
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

    private func commitScenario() {
        let signed = scenario.map { item.direction == .IN ? $0.magnitude : -$0.magnitude }
        guard signed != item.scenarioAmount else { return }
        onScenario(signed)
    }

    private func commit() {
        var next = draft
        next.label = next.label.trimmingCharacters(in: .whitespaces)
        guard !next.label.isEmpty else { draft.label = item.label; return }
        if !item.isReserveTotal && item.distributionId == nil {
            guard let plan else { return }
            next.planAmount = item.direction == .IN ? plan.magnitude : -plan.magnitude
        }
        if let day = next.expectedDay { next.expectedDay = min(max(day, 1), 31) }
        draft = next
        guard next != item else { return }
        onSave(next)
    }
}

/// Een vaste storting als keuze bij een post.
struct SettingsDistributionOption: Identifiable, Equatable {
    let id: Int64
    let name: String
    let archived: Bool
}
