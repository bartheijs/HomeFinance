import SwiftUI
import GRDB
import HFCore
import HFInsight

/// Alles wat het dashboard toont, in één keer gelezen.
struct DashboardData: Equatable {
    var dashboard: Dashboard
    /// Jaar van de twee jaargrafieken (het gekozen jaar in de zijbalk).
    var chartYear: Int
    var spendableSeries: [SpendablePoint]
    var monthlyResults: [MonthResult]
    /// De pagina Incidentele transacties van de lopende maand.
    var incidental: IncidentalMonth
}

/// Wat er achter een klik op het dashboard zit.
enum DashboardDetail: String, Identifiable {
    case fixedItems, incidental, year
    var id: String { rawValue }

    var title: String {
        switch self {
        case .fixedItems: "Vaste posten"
        case .incidental: "Incidentele transacties"
        case .year: "Verloop van het jaar"
        }
    }
}

/// Het startscherm: hoeveel kunnen we nog uitgeven, en moet ik iets doen? De rest zit achter een klik.
struct DashboardScreen: View {
    @Environment(AppModel.self) private var model
    @State private var data: DashboardData?
    @State private var detail: DashboardDetail?

    private struct ReloadKey: Hashable { let revision: Int; let year: Int; let today: Day }

    var body: some View {
        VStack(spacing: 0) {
            if let detail {
                detailHeader(detail)
            } else {
                ScreenHeader("Dashboard", subtitle: DashboardFormat.headerSubtitle(model.today)) {
                    Button { model.selection = .review } label: {
                        Label("Importeren", systemImage: "tray.and.arrow.down")
                    }
                    .help("Importeer een bankbestand en kijk de nieuwe transacties na (⌘I)")
                }
            }
            if let data {
                GeometryReader { geo in
                    ScrollView {
                        Group {
                            if let detail {
                                DashboardDetailView(detail: detail, data: data, width: min(max(geo.size.width - 48, 600), 1100))
                            } else {
                                DashboardHome(data: data, width: min(max(geo.size.width - 48, 600), 1100)) { detail = $0 }
                            }
                        }
                        .padding(.horizontal, 24)
                        .padding(.bottom, 24)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            } else {
                Spacer()
            }
        }
        .background(Theme.background)
        .task(id: ReloadKey(revision: model.revision, year: model.year, today: model.today)) { load() }
    }

    /// Kop van een detailweergave, met de weg terug.
    private func detailHeader(_ shown: DashboardDetail) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { detail = nil } label: {
                Label("Dashboard", systemImage: "chevron.left")
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(.cancelAction)
            .help("Terug naar het dashboard (Esc)")
            Text(shown.title).font(.system(.title, design: .rounded).weight(.bold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 24).padding(.top, 16).padding(.bottom, 14)
    }

    private func load() {
        let today = model.today
        let year = model.year
        data = model.read(data) { db in
            let dashboard = try Insight.dashboard(db, today: today, recentLimit: 12, tagLimit: 5)
            // Een jaar zonder begroting heeft geen besteedbaar; de grafiek toont dan een uitleg.
            let series = (try? Insight.spendableSeries(db, year: year, today: today)) ?? []
            let months = try Insight.monthlyResults(db, year: year)
            let incidental = try Insight.incidentalMonth(db, year: today.year, month: today.month)
            return DashboardData(dashboard: dashboard, chartYear: year, spendableSeries: series, monthlyResults: months,
                                 incidental: incidental)
        }
    }
}

/// De eerste aanblik: besteedbaar, aandacht en drie korte samenvattingen.
private struct DashboardHome: View {
    @Environment(AppModel.self) private var model
    let data: DashboardData
    let width: CGFloat
    let open: (DashboardDetail) -> Void

    private var wide: Bool { width >= 900 }

    var body: some View {
        let d = data.dashboard
        VStack(alignment: .leading, spacing: 40) {
            if wide {
                HStack(alignment: .top, spacing: 48) {
                    hero.frame(maxWidth: .infinity, alignment: .leading)
                    DashboardAttentionCard(items: d.attention) { open($0) }.frame(width: 400)
                }
            } else {
                hero
                DashboardAttentionCard(items: d.attention) { open($0) }
            }
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: Theme.spacing) {
                    if let fixed = d.fixedItems {
                        DashboardPeriodicCard(overview: fixed) { open(.fixedItems) }
                    }
                    DashboardIncidentalCard(summary: d.incidental) { open(.incidental) }
                    DashboardBalanceCard(dashboard: d)
                }
                .fixedSize(horizontal: false, vertical: true)
                Button { open(.year) } label: {
                    HStack(spacing: 4) {
                        Text("Verloop van het jaar")
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accent)
                .help("Grafieken: nog te besteden per maand en in en uit per maand")
            }
        }
        .padding(.top, 28)
        .frame(width: width, alignment: .leading)
    }

    @ViewBuilder private var hero: some View {
        if let spendable = data.dashboard.spendable {
            DashboardHero(spendable: spendable, unbooked: data.dashboard.unbookedCheckingTransactions)
        } else {
            DashboardYearMissingCard(year: data.dashboard.today.year)
        }
    }
}

/// De uitgebreide weergave achter een samenvatting.
private struct DashboardDetailView: View {
    let detail: DashboardDetail
    let data: DashboardData
    let width: CGFloat

    private let gap: CGFloat = Theme.spacing
    private var half: CGFloat { (width - gap) / 2 }

    var body: some View {
        let d = data.dashboard
        VStack(alignment: .leading, spacing: gap) {
            switch detail {
            case .fixedItems:
                if let fixed = d.fixedItems {
                    DashboardFixedItemsPage(overview: fixed).frame(width: min(width, 760))
                } else {
                    DashboardYearMissingCard(year: d.today.year)
                }
            case .incidental:
                DashboardIncidentalPage(month: data.incidental, width: width)
            case .year:
                DashboardSpendableChartCard(year: data.chartYear, points: data.spendableSeries)
                DashboardInOutChartCard(year: data.chartYear, months: data.monthlyResults)
            }
        }
        .frame(width: width, alignment: .leading)
    }

    /// Kaarten naast elkaar, even hoog.
    private func row<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: gap) { content() }
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Een kaartje op het dashboard met een titel en regels; met `action` is het aanklikbaar.
struct DashboardSummaryCard<Content: View>: View {
    let title: String
    var help: String?
    var action: (() -> Void)?
    @ViewBuilder var content: Content
    @State private var hovering = false

    var body: some View {
        if let action {
            Button(action: action) { card(link: true) }
                .buttonStyle(.plain)
                .onHover { hovering = $0 }
                .help(help ?? "Bekijk de details")
        } else {
            card(link: false)
        }
    }

    private func card(link: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            content.font(.callout)
            Spacer(minLength: 8)
            if link { DashboardViewLink() }
        }
        .dashboardSummaryStyle(hovering: link && hovering)
    }
}

/// Eén regel in een kaartje: tekst links, bedrag of aantal rechts.
struct DashboardCardRow<Value: View>: View {
    let title: String
    @ViewBuilder var value: Value

    init(_ title: String, @ViewBuilder value: () -> Value) { self.title = title; self.value = value() }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).lineLimit(1)
            Spacer(minLength: 8)
            value.monospacedDigit()
        }
    }
}

/// Periodieke transacties: de vaste posten van deze maand.
struct DashboardPeriodicCard: View {
    let overview: FixedItemsOverview
    let action: () -> Void

    var body: some View {
        DashboardSummaryCard(title: "Periodieke transacties",
                             help: "Vaste posten van deze maand: wat binnen is, wat te laat is en wat nog komt", action: action) {
            Text("\(overview.paidCount) van \(overview.items.count) voldaan")
                .font(.system(.title2, design: .rounded).weight(.semibold)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.7)
            DashboardCardRow("Te laat") {
                Text("\(overview.lateCount)").foregroundStyle(overview.lateCount > 0 ? Theme.negative : Color.primary)
            }
            DashboardCardRow("Nog verwacht") { Text("\(overview.openCount)") }
            Divider()
            DashboardCardRow("In") { MoneyText(overview.incomeBooked) }
            DashboardCardRow("Uit") { MoneyText(overview.expensesBooked.magnitude) }
        }
    }
}

/// Incidentele transacties: alles zonder vaste post deze maand, met de grootste uitgaven.
struct DashboardIncidentalCard: View {
    let summary: IncidentalSummary
    let action: () -> Void

    var body: some View {
        DashboardSummaryCard(title: "Incidentele transacties",
                             help: "Alles zonder vaste post deze maand", action: action) {
            DashboardCardRow("In") { MoneyText(summary.income) }
            DashboardCardRow("Uit") { MoneyText(summary.expenses.magnitude) }
            if !summary.largestExpenses.isEmpty {
                Divider()
                ForEach(summary.largestExpenses) { entry in
                    DashboardCardRow(DashboardFormat.entryTitle(entry)) {
                        MoneyText(entry.amount.magnitude)
                    }
                }
            }
        }
    }
}

/// Huidig saldo van betaal- en spaarrekeningen; niet aanklikbaar.
struct DashboardBalanceCard: View {
    let dashboard: Dashboard

    var body: some View {
        DashboardSummaryCard(title: "Huidig saldo") {
            DashboardCardRow("Betaal") { MoneyText(dashboard.checkingTotal, colored: dashboard.checkingTotal.isNegative) }
            DashboardCardRow("Spaar") { MoneyText(dashboard.savingsTotal, colored: dashboard.savingsTotal.isNegative) }
            Divider()
            DashboardCardRow("Totaal") {
                MoneyText(dashboard.accountsTotal, colored: dashboard.accountsTotal.isNegative).fontWeight(.semibold)
            }
        }
    }
}

private struct DashboardViewLink: View {
    var body: some View {
        HStack(spacing: 4) {
            Text("Bekijk")
            Image(systemName: "arrow.right").font(.caption.weight(.semibold))
        }
        .font(.callout.weight(.medium))
        .foregroundStyle(Theme.accent)
    }
}

private extension View {
    func dashboardSummaryStyle(hovering: Bool) -> some View {
        self.padding(18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Theme.card.opacity(hovering ? 1 : 0.6), in: RoundedRectangle(cornerRadius: Theme.cardRadius))
            .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.hairline.opacity(hovering ? 0.9 : 0.35)))
            .contentShape(RoundedRectangle(cornerRadius: Theme.cardRadius))
    }
}

/// Kaart van het dashboard: als `Card`, maar vult de hoogte van de rij en heeft ruimte voor iets rechts in de kop.
struct DashboardCard<Trailing: View, Content: View>: View {
    let title: String
    let icon: String
    var help: String?
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var content: Content

    init(_ title: String, icon: String, help: String? = nil,
         @ViewBuilder trailing: () -> Trailing = { EmptyView() }, @ViewBuilder content: () -> Content) {
        self.title = title; self.icon = icon; self.help = help
        self.trailing = trailing(); self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: icon).foregroundStyle(Theme.accent)
                Text(title).font(.headline).lineLimit(1).help(help ?? "")
                Spacer(minLength: 8)
                trailing
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.hairline.opacity(0.6)))
    }
}

/// Rustige melding in een kaart waar (nog) niets te tonen is.
struct DashboardQuietState: View {
    let icon: String
    let title: String
    var message: String?
    var tint: Color = .secondary

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 26)).foregroundStyle(tint)
            Text(title).font(.callout.weight(.medium))
            if let message {
                Text(message).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 12)
    }
}

/// Weergavehulpjes van het dashboard (alleen tekst en verhoudingen voor balken, geen rekenregels).
enum DashboardFormat {
    private static let weekdays = ["zondag", "maandag", "dinsdag", "woensdag", "donderdag", "vrijdag", "zaterdag"]

    /// "zaterdag 21 november 2026"
    static func headerSubtitle(_ today: Day) -> String {
        let weekday = weekdays[Calendar(identifier: .gregorian).component(.weekday, from: today.date) - 1]
        return "\(weekday) \(today.day) \(Day.monthNames[today.month - 1]) \(today.year)"
    }

    /// Aandeel van `part` in `whole` voor de breedte van een balk, tussen 0 en 1.
    static func fraction(_ part: Money, of whole: Money) -> Double {
        guard !whole.isZero else { return 0 }
        return min(max(part.magnitude.doubleValue / whole.magnitude.doubleValue, 0), 1)
    }

    /// Hele euro's voor de as van een grafiek: "€ 2.500".
    static func axisEuros(_ value: Double) -> String {
        let text = Money(cents: Int64((value * 100).rounded())).formatted()
        return text.hasSuffix(",00") ? String(text.dropLast(3)) : text
    }

    /// Hele procenten van `part` ten opzichte van `whole`, voor een toelichting ("51 % van plan").
    static func percent(_ part: Money, of whole: Money) -> Int {
        guard !whole.isZero else { return 0 }
        return Int((part.magnitude.doubleValue / whole.magnitude.doubleValue * 100).rounded())
    }

    /// De omschrijving van een boeking, of de tegenpartij als die leeg is.
    static func entryTitle(_ entry: EntryRow) -> String {
        entry.label.isEmpty ? (entry.bank?.counterpartyName ?? "Zonder omschrijving") : entry.label
    }

    static func daysInMonth(_ day: Day) -> Int {
        Calendar(identifier: .gregorian).range(of: .day, in: .month, for: day.date)?.count ?? 30
    }
}
