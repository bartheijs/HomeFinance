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
    /// Saldoverloop dit jaar per rekening, voor de kleine grafiekjes.
    var sparklines: [Int64: [BalancePoint]]
}

/// Wat er achter een klik op het dashboard zit.
enum DashboardDetail: String, Identifiable {
    case fixedItems, month, accounts, year
    var id: String { rawValue }

    var title: String {
        switch self {
        case .fixedItems: "Vaste posten"
        case .month: "Deze maand"
        case .accounts: "Rekeningen"
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
                    HStack(spacing: 8) {
                        Button { model.selection = .grid } label: {
                            Label("Maandgrid", systemImage: "tablecells")
                        }
                        .help("Open het maandoverzicht met alle vaste posten (⌘G)")
                        Button { model.selection = .review } label: {
                            Label("Importeren", systemImage: "tray.and.arrow.down")
                        }
                        .help("Importeer een bankbestand en kijk de nieuwe transacties na (⌘I)")
                    }
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
            var sparklines: [Int64: [BalancePoint]] = [:]
            if let start = Day(year: today.year, month: 1, day: 1) {
                for account in dashboard.accounts {
                    sparklines[account.id] = try Insight.balanceSeries(db, accountId: account.id, from: start, to: today, step: .daily)
                }
            }
            return DashboardData(dashboard: dashboard, chartYear: year, spendableSeries: series,
                                 monthlyResults: months, sparklines: sparklines)
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
                    DashboardAttentionCard(items: d.attention).frame(width: 400)
                }
            } else {
                hero
                DashboardAttentionCard(items: d.attention)
            }
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: Theme.spacing) {
                    if let fixed = d.fixedItems {
                        DashboardSummaryCard(title: "Vaste posten", value: "\(fixed.paidCount) van \(fixed.items.count) voldaan",
                                             help: "Vaste posten zijn de inkomsten en uitgaven die elke maand, elk kwartaal of elk jaar terugkomen.") {
                            if fixed.lateCount > 0 {
                                Text("\(fixed.lateCount) te laat").foregroundStyle(Theme.negative)
                                    + Text(" · \(fixed.openCount) open").foregroundStyle(.secondary)
                            } else {
                                Text(fixed.openCount == 0 ? "Alles is binnen" : "\(fixed.openCount) open").foregroundStyle(.secondary)
                            }
                        } action: { open(.fixedItems) }
                    }
                    DashboardSummaryCard(title: "Deze maand", value: "\(d.monthExpenses.magnitude.formatted()) uitgegeven",
                                         help: "Alles wat deze maand van de betaalrekening is gegaan.") {
                        Text(d.planExpenses.isZero ? "Geen plan voor deze maand"
                             : "\(DashboardFormat.percent(d.monthExpenses, of: d.planExpenses)) % van plan").foregroundStyle(.secondary)
                    } action: { open(.month) }
                    DashboardAccountsSummaryCard(accounts: d.accounts) { open(.accounts) }
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
                .foregroundStyle(.secondary)
                .help("Grafieken: besteedbaar per maand en IN en UIT per maand")
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
                    DashboardFixedItemsCard(overview: fixed, showAll: true).frame(width: min(width, 720))
                } else {
                    DashboardYearMissingCard(year: d.today.year)
                }
            case .month:
                row {
                    DashboardMonthCard(dashboard: d, result: data.chartYear == d.today.year
                                       ? data.monthlyResults.first { $0.month == d.today.month }?.result : nil)
                        .frame(width: half)
                    DashboardTopTagsCard(tags: d.topTags, month: d.today.month).frame(width: half)
                }
                DashboardRecentCard(entries: d.recentEntries, showAccount: width >= 900)
            case .accounts:
                DashboardAccountsCard(accounts: d.accounts, sparklines: data.sparklines).frame(width: min(width, 720))
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

/// Kleine samenvatting met één kerngetal; een klik opent de details.
struct DashboardSummaryCard<Caption: View>: View {
    let title: String
    let value: String
    var help: String?
    @ViewBuilder var caption: Caption
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.subheadline).foregroundStyle(.secondary)
                Text(value).font(.system(.title2, design: .rounded).weight(.semibold)).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.7)
                caption.font(.callout)
                Spacer(minLength: 8)
                DashboardViewLink()
            }
            .dashboardSummaryStyle(hovering: hovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help ?? "Bekijk de details")
    }
}

/// Samenvatting van de rekeningen: alleen naam en saldo.
struct DashboardAccountsSummaryCard: View {
    let accounts: [AccountOverview]
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Rekeningen").font(.subheadline).foregroundStyle(.secondary)
                if accounts.isEmpty {
                    Text("Nog geen rekeningen").font(.callout).foregroundStyle(.secondary)
                }
                ForEach(accounts.prefix(3)) { account in
                    HStack(alignment: .firstTextBaseline) {
                        Text(account.name).font(.callout).lineLimit(1)
                        Spacer(minLength: 8)
                        MoneyText(account.balance, colored: account.balance.isNegative)
                            .font(.system(.body, design: .rounded).weight(.semibold))
                    }
                }
                if accounts.count > 3 {
                    Text("en nog \(accounts.count - 3)").font(.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                DashboardViewLink()
            }
            .dashboardSummaryStyle(hovering: hovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Saldo, afstemming en verloop per rekening")
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
                Text(title).font(.headline).lineLimit(1)
                if let help {
                    Image(systemName: "info.circle").font(.caption).foregroundStyle(.tertiary).help(help)
                }
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

    /// "Juni 2027 · vrijdag 18 juni"
    static func headerSubtitle(_ today: Day) -> String {
        let month = Day.monthNames[today.month - 1]
        let weekday = weekdays[Calendar(identifier: .gregorian).component(.weekday, from: today.date) - 1]
        return "\(month.prefix(1).uppercased())\(month.dropFirst()) \(today.year) · \(weekday) \(today.day) \(month)"
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

    static func daysInMonth(_ day: Day) -> Int {
        Calendar(identifier: .gregorian).range(of: .day, in: .month, for: day.date)?.count ?? 30
    }
}
