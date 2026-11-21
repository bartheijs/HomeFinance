import SwiftUI
import Charts
import HFCore
import HFInsight
import HFBudget

// MARK: - Pot in de min

enum PotsRecoveryText {
    /// "maart 2028"
    static func month(_ day: Day) -> String { "\(Day.monthNames[day.month - 1]) \(day.year)" }

    /// Eén rustige regel voor in de lijst.
    static func line(_ recovery: PotRecovery) -> String {
        let perMonth = recovery.perMonth > .zero ? " · \(PotsGoalText.short(recovery.perMonth)) per maand" : ""
        switch recovery.status {
        case .herstelt:
            return recovery.recoveryDate.map { "weer op nul rond \(month($0))\(perMonth)" } ?? "wordt aangevuld\(perMonth)"
        case .wordtNietAangevuld: return "wordt niet aangevuld"
        case .duurtLangerDan10Jaar: return "aanvullen duurt langer dan 10 jaar\(perMonth)"
        }
    }

    static func sentence(_ recovery: PotRecovery) -> String {
        switch recovery.status {
        case .herstelt: return "Dit potje staat in de min en wordt zolang gedekt door je andere potjes. Met wat er nu bij komt staat het vanzelf weer op nul."
        case .wordtNietAangevuld: return "Dit potje staat in de min en wordt zolang gedekt door je andere potjes. Er komt nu niets bij: zet een vaste overboeking of een verwachting, of verplaats geld uit een ander potje."
        case .duurtLangerDan10Jaar: return "Dit potje staat in de min en wordt zolang gedekt door je andere potjes. Met wat er nu bij komt duurt aanvullen langer dan 10 jaar."
        }
    }
}

/// Uitleg bij een pot met een negatief saldo: hoeveel, wat erbij komt en wanneer hij weer op nul staat.
struct PotsRecoveryBlock: View {
    let recovery: PotRecovery
    var onDistributions: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("In de min").font(.headline)
            Text(PotsRecoveryText.sentence(recovery))
                .font(.callout)
                .foregroundStyle(recovery.status == .herstelt ? Color.secondary : Theme.warning)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 6) {
                row("Gedekt door andere potjes", recovery.shortfall.formatted())
                row("Komt erbij per maand", recovery.perMonth.isZero ? "niets" : recovery.perMonth.formatted())
                row("Weer op nul", recovery.recoveryDate.map { "rond \(PotsRecoveryText.month($0))" }
                    ?? (recovery.status == .wordtNietAangevuld ? "wordt niet aangevuld" : "niet binnen 10 jaar"))
            }
            if recovery.status != .herstelt {
                Button("Automatisch sparen…", action: onDistributions)
                    .buttonStyle(.plain).foregroundStyle(Theme.accent).font(.callout)
            }
        }
        .help("Potjes die in de min staan, worden zolang gedekt door je andere potjes. Het geld staat nog op de spaarrekening, maar met een ander doel.")
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value).monospacedDigit()
        }
        .font(.callout)
    }
}

// MARK: - Spaardoel in gewone taal

enum PotsGoalText {
    /// Hele euro's zonder ",00"; anders het volledige bedrag.
    static func short(_ money: Money) -> String {
        let text = money.formatted()
        return text.hasSuffix(",00") ? String(text.dropLast(3)) : text
    }

    /// Eén korte regel voor in de lijst.
    static func line(_ goal: PotGoal) -> String {
        switch goal.status {
        case .bereikt: return "doel bereikt"
        case .opKoers: return "op koers"
        case .tekort:
            if let short = goal.shortfallPerMonth, short > .zero { return "\(self.short(short)) per maand te weinig" }
            return "nog niet op koers"
        case .verlopen: return "doeldatum voorbij"
        case .zonderDatum: return "nog \(short(goal.remaining)) te gaan"
        }
    }

    /// Vraagt deze stand aandacht?
    static func needsAttention(_ goal: PotGoal) -> Bool {
        goal.status == .tekort || goal.status == .verlopen
    }

    /// Eén zin voor in het detail.
    static func sentence(_ goal: PotGoal) -> String {
        switch goal.status {
        case .bereikt: return "Het doel is gehaald."
        case .opKoers: return "Je ligt op koers: met wat je nu stort haal je het doel op tijd."
        case .tekort:
            if let short = goal.shortfallPerMonth, short > .zero {
                return "Je stort \(self.short(short)) per maand te weinig om het doel op tijd te halen."
            }
            return "Met wat je nu stort haal je het doel niet op tijd."
        case .verlopen: return "De doeldatum is voorbij en het doel is nog niet gehaald."
        case .zonderDatum: return "Zet een doeldatum bij dit potje om te zien wat je per maand nodig hebt."
        }
    }
}

/// Het spaardoel van een pot, uitgeschreven.
struct PotsGoalBlock: View {
    let pot: PotSummary
    let goal: PotGoal
    var onDistributions: () -> Void
    @State private var showParts = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Spaardoel").font(.headline)
            PotsTargetBar(pot: pot)
            Text(PotsGoalText.sentence(goal))
                .font(.callout)
                .foregroundStyle(PotsGoalText.needsAttention(goal) ? Theme.warning : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 6) {
                row("Doel", goal.targetDate.map { "\(goal.targetAmount.formatted()) op \($0.short(withYear: true))" }
                    ?? "\(goal.targetAmount.formatted()), zonder datum")
                row("Nog nodig", goal.remaining.formatted())
                if let required = goal.requiredPerMonth {
                    row("Nodig per maand", required.formatted(),
                        help: "Wat je vanaf nu elke maand moet storten om het doel op de doeldatum te halen. Losse verwachtingen tot die datum zijn meegeteld.")
                }
                row("Je stort nu per maand", goal.currentPerMonth.isZero ? "niets" : goal.currentPerMonth.formatted(),
                    help: "Volgens je vaste overboekingen.")
                row("Doel gehaald op", reachText,
                    help: "De eerste dag waarop je het doel haalt als je zo blijft storten.")
            }
            if !goal.parts.isEmpty {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { showParts.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                            .rotationEffect(.degrees(showParts ? 90 : 0))
                        Text("Hoe is het doel opgebouwd?")
                    }
                    .font(.callout).foregroundStyle(.secondary).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if showParts {
                    VStack(spacing: 5) {
                        ForEach(goal.parts) { part in
                            HStack(alignment: .firstTextBaseline) {
                                Text(part.quantity > 1
                                     ? "\(part.quantity) × \(PotsGoalText.short(part.unitAmount)) \(part.label)"
                                     : (part.label.isEmpty ? "Zonder omschrijving" : part.label))
                                    .foregroundStyle(.secondary).lineLimit(2)
                                Spacer(minLength: 12)
                                Text(part.amount.formatted()).monospacedDigit()
                            }
                        }
                        Divider()
                        HStack {
                            Text("Samen").foregroundStyle(.secondary)
                            Spacer()
                            Text(goal.partsTotal.formatted()).monospacedDigit().fontWeight(.medium)
                        }
                    }
                    .font(.callout)
                    .padding(.leading, 16)
                }
            }
            if PotsGoalText.needsAttention(goal) || goal.currentPerMonth.isZero {
                Button("Automatisch sparen…", action: onDistributions)
                    .buttonStyle(.plain).foregroundStyle(Theme.accent).font(.callout)
                    .help("Pas aan wat er elke maand naar dit potje gaat.")
            }
        }
    }

    private var reachText: String {
        if goal.status == .bereikt { return "al gehaald" }
        if let day = goal.projectedReachDate { return day.short(withYear: true) }
        return "niet binnen 10 jaar"
    }

    private func row(_ title: String, _ value: String, help: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value).monospacedDigit().multilineTextAlignment(.trailing)
        }
        .font(.callout)
        .help(help ?? "")
    }
}

// MARK: - Vooruitblik

private struct PotsForecastChartPoint: Identifiable {
    let id: String
    let date: Date
    let balance: Double
}

struct PotsForecastDraft: Identifiable {
    let id = UUID()
    /// nil = nieuwe verwachting.
    var item: ForecastItem?
    /// Project dat bij een nieuwe verwachting al is ingevuld.
    var project = ""
}

/// Waar komt de pot naar verwachting uit: grafiek, stand op een gekozen dag en de verwachte bedragen.
struct PotsForecastSection: View {
    @Environment(AppModel.self) private var model
    let pot: PotSummary
    let history: [PotHistoryRow]
    var onDistributions: () -> Void

    /// nil = 6 maanden vooruit.
    @State private var standOn: Day?
    @State private var forecast: PotForecast?
    @State private var items: [ForecastItem] = []
    @State private var usage: [PotDistributionUsage] = []
    @State private var draft: PotsForecastDraft?
    @State private var showRealized = false
    @State private var projects: [ForecastProject] = []
    @State private var expandedProjects: Set<String> = []
    @State private var renaming: String?
    @State private var renameText = ""

    private struct Key: Hashable { let revision: Int, potId: Int64, until: Day }

    private var today: Day { model.today }
    private func ahead(months: Int) -> Day {
        Day(date: Calendar.current.date(byAdding: .month, value: months, to: today.date) ?? today.date)
    }
    private var until: Day { max(standOn ?? ahead(months: 6), today.adding(days: 1)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Vooruitblik").font(.headline)
                Text("Verwachtingen tellen nergens in mee; ze laten alleen zien waar je naar verwachting uitkomt.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let forecast {
                chart(forecast)
                stand(forecast)
                // Een pot die al in de min staat krijgt deze waarschuwing alleen als hij nog verder zakt.
                if forecast.lowestPoint.balance.isNegative,
                   !forecast.startBalance.isNegative || forecast.lowestPoint.balance < forecast.startBalance {
                    Label("Rond \(forecast.lowestPoint.day.short(withYear: true)) komt dit potje naar verwachting op \(forecast.lowestPoint.balance.formatted()).",
                          systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(Theme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
                expected(forecast)
            }
        }
        .task(id: Key(revision: model.revision, potId: pot.id, until: until)) { load() }
        .sheet(item: $draft) { draft in
            PotsForecastSheet(potId: pot.id, potName: pot.name, existing: draft.item, presetProject: draft.project,
                              today: today)
        }
        .alert("Project hernoemen", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Naam van het project", text: $renameText)
            Button("Hernoem") { renameProject() }
            Button("Annuleer", role: .cancel) {}
        } message: {
            Text("Alle regels van dit project krijgen de nieuwe naam. Bestaat die naam al, dan gaan de projecten samen.")
        }
    }

    private func load() {
        let potId = pot.id, today = today, until = until
        forecast = model.read(PotForecast?.none) { try Insight.potForecast($0, potId: potId, today: today, until: until) }
        items = model.read([]) { try Insight.forecastItems($0, potId: potId) }
        usage = model.read([]) { try Insight.distributionUsage($0, potId: potId) }
        projects = model.read([]) { try Insight.forecastProjects($0, potId: potId, today: today) }
    }

    // MARK: Grafiek

    private func chart(_ forecast: PotForecast) -> some View {
        let real = forecast.points.filter { !$0.isForecast }
            .map { PotsForecastChartPoint(id: $0.id, date: $0.day.date, balance: $0.balance.doubleValue) }
        var expected = forecast.points.filter(\.isForecast)
            .map { PotsForecastChartPoint(id: $0.id, date: $0.day.date, balance: $0.balance.doubleValue) }
        // De verwachting begint waar de werkelijkheid ophoudt.
        expected.insert(PotsForecastChartPoint(id: "start", date: forecast.today.date,
                                               balance: forecast.startBalance.doubleValue), at: 0)
        return Chart {
            ForEach(real) { point in
                LineMark(x: .value("Datum", point.date), y: .value("Saldo", point.balance),
                         series: .value("Reeks", "Werkelijk"))
                    .foregroundStyle(Theme.accent)
                    .lineStyle(StrokeStyle(lineWidth: 2))
            }
            ForEach(expected) { point in
                LineMark(x: .value("Datum", point.date), y: .value("Saldo", point.balance),
                         series: .value("Reeks", "Verwacht"))
                    .interpolationMethod(.stepEnd)
                    .foregroundStyle(Theme.accent.opacity(0.8))
                    .lineStyle(StrokeStyle(lineWidth: 2, dash: [5, 4]))
            }
            if let target = forecast.targetAmount, target > .zero {
                RuleMark(y: .value("Doel", target.doubleValue))
                    .foregroundStyle(Color.secondary.opacity(0.7))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
                    .annotation(position: .top, alignment: .leading, spacing: 2) {
                        Text("doel \(PotsGoalText.short(target))").font(.caption2).foregroundStyle(.secondary)
                    }
            }
            RuleMark(x: .value("Vandaag", forecast.today.date))
                .foregroundStyle(Color.secondary.opacity(0.5))
                .lineStyle(StrokeStyle(lineWidth: 1))
                .annotation(position: .top, alignment: .center, spacing: 2) {
                    Text("vandaag").font(.caption2).foregroundStyle(.secondary)
                }
            if forecast.lowestPoint.balance.isNegative {
                RuleMark(y: .value("Nul", 0)).foregroundStyle(Theme.warning.opacity(0.7))
                    .lineStyle(StrokeStyle(lineWidth: 1))
            }
            // De dag waarop een pot in de min weer op nul staat.
            if let day = pot.recovery?.recoveryDate, day <= forecast.until {
                PointMark(x: .value("Datum", day.date), y: .value("Saldo", 0))
                    .foregroundStyle(Theme.accent)
                    .symbolSize(60)
                    .annotation(position: .top, alignment: .center, spacing: 3) {
                        Text("op nul \(day.short())").font(.caption2).foregroundStyle(.secondary)
                    }
            }
        }
        .chartLegend(.hidden)
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine().foregroundStyle(Theme.hairline.opacity(0.4))
                AxisValueLabel {
                    if let v = value.as(Double.self) { Text(PotsFormat.wholeEuros(v)).monospacedDigit() }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) { value in
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        let day = Day(date: date)
                        Text("\(Day.monthNamesShort[day.month - 1]) '\(String(format: "%02d", day.year % 100))")
                    }
                }
            }
        }
        .frame(height: 160)
        .padding(.top, 10)
        .accessibilityLabel("Werkelijk en verwacht saldo van het potje \(pot.name)")
        .help("Doorgetrokken lijn: het echte saldo. Gestippeld: wat je verwacht, met je vaste overboekingen en losse verwachtingen.")
    }

    // MARK: Stand op een dag

    private func stand(_ forecast: PotForecast) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                DatePicker("Stand op", selection: Binding(get: { until.date }, set: { standOn = Day(date: $0) }),
                           in: today.adding(days: 1).date..., displayedComponents: .date)
                    .fixedSize()
                Spacer(minLength: 0)
                ForEach([3, 6, 12], id: \.self) { months in
                    Button("\(months) mnd") { standOn = ahead(months: months) }
                        .controlSize(.small)
                        .help("Kijk \(months) maanden vooruit.")
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text((forecast.balance(on: until) ?? forecast.endBalance).formatted())
                    .font(.system(size: 26, weight: .semibold, design: .rounded)).monospacedDigit()
                    .foregroundStyle((forecast.balance(on: until) ?? forecast.endBalance).isNegative ? Theme.warning : Color.primary)
                Text("verwacht op \(until.short(withYear: true))").font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Verwachte bedragen

    @ViewBuilder private func expected(_ forecast: PotForecast) -> some View {
        // Verwachtingen met een project staan in het blokje van dat project, niet in de losse lijsten.
        let loose = items.filter { $0.project.trimmingCharacters(in: .whitespaces).isEmpty }
        let overdue = forecast.overdue.filter { $0.project.trimmingCharacters(in: .whitespaces).isEmpty }
        let overdueIds = Set(overdue.compactMap(\.id))
        let open = loose.filter { !$0.isRealized && !overdueIds.contains($0.id ?? -1) }
        let realized = loose.filter(\.isRealized)
        let recurring = usage.filter { !$0.archived }

        VStack(alignment: .leading, spacing: 16) {
            if !overdue.isEmpty {
                group("Over tijd", note: "De datum is voorbij en ze zijn niet afgevinkt. Ze tellen niet mee in de lijn.",
                      attention: true) {
                    ForEach(overdue) { itemRow($0, overdue: true) }
                }
            }
            ForEach(projects) { projectBlock($0) }
            group("Losse verwachtingen", note: nil, attention: false) {
                if open.isEmpty {
                    Text("Nog geen. Denk aan een gift, vakantiegeld of een grote uitgave die eraan komt.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(open) { itemRow($0, overdue: false) }
                Button { draft = PotsForecastDraft(item: nil) } label: {
                    Label("Verwachting toevoegen…", systemImage: "plus")
                }
                .buttonStyle(.plain).foregroundStyle(Theme.accent).font(.callout)
                .padding(.top, 2)
            }
            group("Elke maand uit je vaste overboekingen", note: nil, attention: false) {
                if recurring.isEmpty {
                    Text("Er gaat nog geen vaste overboeking naar dit potje.").font(.callout).foregroundStyle(.secondary)
                }
                ForEach(recurring) { line in
                    HStack {
                        Text(line.name).lineLimit(1)
                        Spacer(minLength: 12)
                        Text("\(line.amount.formatted(alwaysSign: true)) per maand").monospacedDigit()
                    }
                    .font(.callout)
                    .help("Uit Automatisch sparen: \(line.name) van \(line.distributionTotal.formatted()) in totaal.")
                }
                Button("Automatisch sparen…", action: onDistributions)
                    .buttonStyle(.plain).foregroundStyle(Theme.accent).font(.callout)
                    .padding(.top, 2)
            }
            if !realized.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) { showRealized.toggle() }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                                .rotationEffect(.degrees(showRealized ? 90 : 0))
                            Text("Afgevinkt (\(realized.count))")
                        }
                        .font(.callout.weight(.medium)).foregroundStyle(.secondary)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if showRealized {
                        ForEach(realized) { item in
                            HStack {
                                Text(item.label.isEmpty ? "Zonder omschrijving" : item.label).lineLimit(1)
                                Spacer(minLength: 12)
                                Text(item.amount.formatted(alwaysSign: true)).monospacedDigit()
                                Button("Zet terug") { reopen(item) }
                                    .controlSize(.small)
                                    .help("Maakt deze verwachting weer open; een gekoppelde boeking wordt losgemaakt.")
                            }
                            .font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    // MARK: Projecten

    /// Eén project als kleine begroting: gepland, betaald, nog te komen, met de regels na een klik.
    private func projectBlock(_ project: ForecastProject) -> some View {
        let expanded = expandedProjects.contains(project.name)
        let share = project.planned.isZero ? 0 : min(1, max(0, project.realized.doubleValue / project.planned.doubleValue))
        return VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    if expanded { expandedProjects.remove(project.name) } else { expandedProjects.insert(project.name) }
                }
            } label: {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                        Text(project.name).font(.callout.weight(.semibold)).lineLimit(1)
                        if project.overdueCount > 0 {
                            Image(systemName: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(Theme.warning)
                                .help(project.overdueCount == 1 ? "1 regel is over tijd." : "\(project.overdueCount) regels zijn over tijd.")
                        }
                        Spacer(minLength: 8)
                        Text(project.count == 1 ? "1 regel" : "\(project.count) regels").font(.caption).foregroundStyle(.secondary)
                    }
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.primary.opacity(0.08))
                            Capsule().fill(Theme.accent.opacity(0.75)).frame(width: geo.size.width * share)
                        }
                    }
                    .frame(height: 4)
                    HStack(spacing: 0) {
                        projectFigure("Gepland", project.planned)
                        projectFigure("Betaald", project.realized)
                        projectFigure("Nog te komen", project.remaining)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button("Hernoem project…") { renameText = project.name; renaming = project.name }
                Button("Regel toevoegen…") { draft = PotsForecastDraft(item: nil, project: project.name) }
            }
            .help("Klik voor de regels van dit project. Rechtsklik om het project te hernoemen.")

            if expanded {
                ForEach(project.items) { row in
                    Divider()
                    if row.item.isRealized {
                        HStack {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.secondary)
                            Text(row.item.label.isEmpty ? "Zonder omschrijving" : row.item.label).lineLimit(1)
                            Spacer(minLength: 8)
                            Text((row.realizedAmount ?? row.item.amount).formatted(alwaysSign: true)).monospacedDigit()
                            Button("Zet terug") { reopen(row.item) }.controlSize(.small)
                        }
                        .font(.callout).foregroundStyle(.secondary)
                    } else {
                        itemRow(row.item, overdue: row.item.day <= today)
                    }
                }
                Divider()
                Button { draft = PotsForecastDraft(item: nil, project: project.name) } label: {
                    Label("Regel toevoegen…", systemImage: "plus")
                }
                .buttonStyle(.plain).foregroundStyle(Theme.accent).font(.callout)
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
    }

    private func projectFigure(_ title: String, _ amount: Money) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(amount.magnitude.formatted()).font(.callout).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func renameProject() {
        guard let from = renaming else { return }
        let to = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        renaming = nil
        guard !to.isEmpty, to != from else { return }
        let ok = model.perform("Project heet nu \(to)") {
            try model.db.write { db in _ = try ForecastService.renameProject(db, potId: pot.id, from: from, to: to) }
        }
        if ok, expandedProjects.remove(from) != nil { expandedProjects.insert(to) }
    }

    private func group<Content: View>(_ title: String, note: String?, attention: Bool,
                                      @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if attention { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning) }
                Text(title).font(.callout.weight(.medium))
                    .foregroundStyle(attention ? Theme.warning : Color.secondary)
            }
            if let note {
                Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            content()
        }
    }

    private func itemRow(_ item: ForecastItem, overdue: Bool) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(item.label.isEmpty ? "Zonder omschrijving" : item.label).lineLimit(1)
                Text(item.day.short(withYear: item.day.year != today.year))
                    .font(.caption).monospacedDigit()
                    .foregroundStyle(overdue ? Theme.warning : Color.secondary)
            }
            Spacer(minLength: 8)
            Text(item.amount.formatted(alwaysSign: true)).monospacedDigit()
            Button { markRealized(item) } label: { Image(systemName: "checkmark.circle") }
                .buttonStyle(.borderless)
                .help(item.amount.isNegative
                      ? "Betaald: vink af dat deze uitgave is gedaan. Past er een boeking bij, dan wordt die gekoppeld."
                      : "Ontvangen: vink af dat dit bedrag binnen is. Past er een boeking bij, dan wordt die gekoppeld.")
            Menu {
                Button(item.amount.isNegative ? "Betaald" : "Ontvangen", systemImage: "checkmark") { markRealized(item) }
                Button("Wijzig…", systemImage: "pencil") { draft = PotsForecastDraft(item: item) }
                Divider()
                Button("Verwijder", systemImage: "trash", role: .destructive) { delete(item) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        }
        .font(.callout)
    }

    // MARK: Schrijven

    /// Zoekt een echte boeking in de pot die bij deze verwachting past (zelfde teken, bedrag en datum in de buurt).
    private func matchingEntry(for item: ForecastItem) -> PotHistoryRow? {
        guard let itemId = item.id else { return nil }
        let candidates = history.reversed().filter { $0.entry.amount.isNegative == item.amount.isNegative }.prefix(60)
        return model.read(PotHistoryRow?.none) { db in
            for row in candidates
            where try ForecastService.suggestRealization(db, entryId: row.entry.id).first?.id == itemId {
                return row
            }
            return nil
        }
    }

    private func markRealized(_ item: ForecastItem) {
        guard let id = item.id else { return }
        let match = matchingEntry(for: item)
        var linked = false
        let ok = model.perform {
            try model.db.write { db in
                if let match {
                    do {
                        _ = try ForecastService.markRealized(db, forecastItemId: id, entryId: match.entry.id)
                        linked = true
                        return
                    } catch { /* koppelen lukte niet: dan alleen afvinken */ }
                }
                _ = try ForecastService.markRealized(db, forecastItemId: id)
            }
        }
        if ok {
            if linked, let match {
                model.toast = "Afgevinkt en gekoppeld aan de boeking van \(match.entry.day.short(withYear: true))"
            } else {
                model.toast = "Afgevinkt"
            }
        }
    }

    private func reopen(_ item: ForecastItem) {
        guard let id = item.id else { return }
        model.perform("Verwachting staat weer open") {
            try model.db.write { db in _ = try ForecastService.reopen(db, forecastItemId: id) }
        }
    }

    private func delete(_ item: ForecastItem) {
        guard let id = item.id else { return }
        model.perform("Verwachting verwijderd") {
            try model.db.write { db in try ForecastService.delete(db, forecastItemId: id) }
        }
    }
}

// MARK: - Verwachting toevoegen of wijzigen

struct PotsForecastSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let potId: Int64
    let potName: String
    let existing: ForecastItem?

    @State private var project: String
    @State private var knownProjects: [String] = []
    @State private var date: Date
    @State private var incoming: Bool
    @State private var amount: Money?
    @State private var label: String

    init(potId: Int64, potName: String, existing: ForecastItem?, presetProject: String = "", today: Day) {
        self.potId = potId; self.potName = potName; self.existing = existing
        _project = State(initialValue: existing?.project ?? presetProject)
        let fallback = Calendar.current.date(byAdding: .month, value: 1, to: today.date) ?? today.date
        _date = State(initialValue: existing?.day.date ?? fallback)
        _incoming = State(initialValue: !(existing?.amount.isNegative ?? false))
        _amount = State(initialValue: existing?.amount.magnitude)
        _label = State(initialValue: existing?.label ?? "")
    }

    private var canSave: Bool { (amount ?? .zero) > .zero }

    var body: some View {
        VStack(spacing: 0) {
            Text(existing == nil ? "Verwachting toevoegen" : "Verwachting wijzigen").font(.headline).padding(.top, 16)
            Form {
                Section {
                    LabeledContent("Potje", value: potName)
                    DatePicker("Datum", selection: $date, displayedComponents: .date)
                    Picker("Richting", selection: $incoming) {
                        Text("Erbij").tag(true)
                        Text("Eraf").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .help("Erbij: geld dat je in dit potje verwacht. Eraf: een uitgave die je uit dit potje verwacht.")
                    MoneyField("Bedrag", value: $amount)
                    TextField("Omschrijving", text: $label, prompt: Text(incoming ? "bijv. vakantiegeld" : "bijv. nieuwe banden"))
                    HStack {
                        TextField("Project (mag leeg)", text: $project, prompt: Text("bijv. Vakantie zomer"))
                            .help("Verwachtingen met hetzelfde project staan samen in één blokje, met wat gepland en betaald is.")
                        if !knownProjects.isEmpty {
                            Menu {
                                ForEach(knownProjects, id: \.self) { name in Button(name) { project = name } }
                                Divider()
                                Button("Geen project") { project = "" }
                            } label: {
                                Image(systemName: "chevron.down.circle")
                            }
                            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                            .help("Kies een bestaand project van dit potje.")
                        }
                    }
                } footer: {
                    Text("Een verwachting is geen boeking. Hij telt alleen mee in de vooruitblik van dit potje.")
                        .font(.callout).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            Divider()
            HStack {
                Spacer()
                Button("Annuleer", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(existing == nil ? "Voeg toe" : "Bewaar") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
            .padding(16)
        }
        .frame(width: 460)
        .onAppear {
            knownProjects = model.read([]) { try ForecastService.projects($0, potId: potId) }
        }
    }

    private func save() {
        guard let amount, amount > .zero else { return }
        let projectName = project.trimmingCharacters(in: .whitespacesAndNewlines)
        let signed = incoming ? amount : -amount
        let text = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let day = Day(date: date)
        let ok = model.perform(existing == nil ? "Verwachting toegevoegd" : "Verwachting bewaard") {
            try model.db.write { db in
                if var item = existing {
                    item.day = day; item.amount = signed; item.label = text; item.project = projectName
                    _ = try ForecastService.update(db, item)
                } else {
                    _ = try ForecastService.create(db, potId: potId, day: day, amount: signed, label: text,
                                                   project: projectName)
                }
            }
        }
        if ok { dismiss() }
    }
}
