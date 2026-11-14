import SwiftUI
import Charts
import HFCore
import HFInsight
import HFBudget

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
        case .zonderDatum: return "Zet een doeldatum bij deze pot om te zien wat je per maand nodig hebt."
        }
    }
}

/// Het spaardoel van een pot, uitgeschreven.
struct PotsGoalBlock: View {
    let pot: PotSummary
    let goal: PotGoal
    var onDistributions: () -> Void

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
                    help: "Volgens je vaste stortingen.")
                row("Doel gehaald op", reachText,
                    help: "De eerste dag waarop je het doel haalt als je zo blijft storten.")
            }
            if PotsGoalText.needsAttention(goal) || goal.currentPerMonth.isZero {
                Button("Vaste stortingen…", action: onDistributions)
                    .buttonStyle(.plain).foregroundStyle(Theme.accent).font(.callout)
                    .help("Pas aan wat er elke maand naar deze pot gaat.")
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
                if forecast.lowestPoint.balance.isNegative {
                    Label("Rond \(forecast.lowestPoint.day.short(withYear: true)) komt deze pot naar verwachting op \(forecast.lowestPoint.balance.formatted()).",
                          systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(Theme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
                expected(forecast)
            }
        }
        .task(id: Key(revision: model.revision, potId: pot.id, until: until)) { load() }
        .sheet(item: $draft) { draft in
            PotsForecastSheet(potId: pot.id, potName: pot.name, existing: draft.item, today: today)
        }
    }

    private func load() {
        let potId = pot.id, today = today, until = until
        forecast = model.read(PotForecast?.none) { try Insight.potForecast($0, potId: potId, today: today, until: until) }
        items = model.read([]) { try Insight.forecastItems($0, potId: potId) }
        usage = model.read([]) { try Insight.distributionUsage($0, potId: potId) }
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
        .accessibilityLabel("Werkelijk en verwacht saldo van de pot \(pot.name)")
        .help("Doorgetrokken lijn: het echte saldo. Gestippeld: wat je verwacht, met je vaste stortingen en losse verwachtingen.")
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
        let overdueIds = Set(forecast.overdue.compactMap(\.id))
        let open = items.filter { !$0.isRealized && !overdueIds.contains($0.id ?? -1) }
        let realized = items.filter(\.isRealized)
        let recurring = usage.filter { !$0.archived }

        VStack(alignment: .leading, spacing: 16) {
            if !forecast.overdue.isEmpty {
                group("Over tijd", note: "De datum is voorbij en ze zijn niet afgevinkt. Ze tellen niet mee in de lijn.",
                      attention: true) {
                    ForEach(forecast.overdue) { itemRow($0, overdue: true) }
                }
            }
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
            group("Elke maand uit je vaste stortingen", note: nil, attention: false) {
                if recurring.isEmpty {
                    Text("Er gaat nog geen vaste storting naar deze pot.").font(.callout).foregroundStyle(.secondary)
                }
                ForEach(recurring) { line in
                    HStack {
                        Text(line.name).lineLimit(1)
                        Spacer(minLength: 12)
                        Text("\(line.amount.formatted(alwaysSign: true)) per maand").monospacedDigit()
                    }
                    .font(.callout)
                    .help("Uit de vaste storting \(line.name) van \(line.distributionTotal.formatted()) in totaal.")
                }
                Button("Vaste stortingen…", action: onDistributions)
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

    @State private var date: Date
    @State private var incoming: Bool
    @State private var amount: Money?
    @State private var label: String

    init(potId: Int64, potName: String, existing: ForecastItem?, today: Day) {
        self.potId = potId; self.potName = potName; self.existing = existing
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
                    LabeledContent("Pot", value: potName)
                    DatePicker("Datum", selection: $date, displayedComponents: .date)
                    Picker("Richting", selection: $incoming) {
                        Text("Erbij").tag(true)
                        Text("Eraf").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .help("Erbij: geld dat je in deze pot verwacht. Eraf: een uitgave die je uit deze pot verwacht.")
                    MoneyField("Bedrag", value: $amount)
                    TextField("Omschrijving", text: $label, prompt: Text(incoming ? "bijv. vakantiegeld" : "bijv. nieuwe banden"))
                } footer: {
                    Text("Een verwachting is geen boeking. Hij telt alleen mee in de vooruitblik van deze pot.")
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
        .frame(width: 440)
    }

    private func save() {
        guard let amount, amount > .zero else { return }
        let signed = incoming ? amount : -amount
        let text = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let day = Day(date: date)
        let ok = model.perform(existing == nil ? "Verwachting toegevoegd" : "Verwachting bewaard") {
            try model.db.write { db in
                if var item = existing {
                    item.day = day; item.amount = signed; item.label = text
                    _ = try ForecastService.update(db, item)
                } else {
                    _ = try ForecastService.create(db, potId: potId, day: day, amount: signed, label: text)
                }
            }
        }
        if ok { dismiss() }
    }
}
