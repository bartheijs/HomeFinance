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

/// Het startscherm: hoeveel kunnen we nog uitgeven, en moet ik iets doen?
struct DashboardScreen: View {
    @Environment(AppModel.self) private var model
    @State private var data: DashboardData?

    private struct ReloadKey: Hashable { let revision: Int; let year: Int; let today: Day }

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader("Dashboard", subtitle: DashboardFormat.headerSubtitle(model.today)) {
                HStack(spacing: 8) {
                    Button { model.selection = .grid } label: {
                        Label("Maandgrid", systemImage: "tablecells")
                    }
                    .help("Open het maandoverzicht met alle vaste posten (⌘G)")
                    Button { model.selection = .review } label: {
                        Label("Importeren", systemImage: "tray.and.arrow.down")
                    }
                    .buttonStyle(.borderedProminent)
                    .help("Importeer een bankbestand en kijk de nieuwe transacties na (⌘I)")
                }
            }
            if let data {
                GeometryReader { geo in
                    ScrollView {
                        DashboardContent(data: data, width: max(geo.size.width - 48, 600))
                            .padding(.horizontal, 24)
                            .padding(.bottom, 24)
                    }
                }
            } else {
                Spacer()
            }
        }
        .background(Theme.background)
        .task(id: ReloadKey(revision: model.revision, year: model.year, today: model.today)) { load() }
    }

    private func load() {
        let today = model.today
        let year = model.year
        data = model.read(data) { db in
            let dashboard = try Insight.dashboard(db, today: today, recentLimit: 8, tagLimit: 5)
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

/// De kaarten in een raster dat meeschaalt: drie kolommen als er ruimte is, anders twee.
private struct DashboardContent: View {
    @Environment(AppModel.self) private var model
    let data: DashboardData
    let width: CGFloat

    private let gap: CGFloat = Theme.spacing
    private var wide: Bool { width >= 1020 }
    private var third: CGFloat { (width - 2 * gap) / 3 }
    private var twoThirds: CGFloat { 2 * third + gap }
    private var half: CGFloat { (width - gap) / 2 }

    var body: some View {
        let d = data.dashboard
        VStack(alignment: .leading, spacing: gap) {
            if wide {
                row {
                    hero.frame(width: twoThirds)
                    DashboardAttentionCard(items: d.attention).frame(width: third)
                }
                row {
                    if let fixed = d.fixedItems { DashboardFixedItemsCard(overview: fixed).frame(width: third) }
                    monthCard.frame(width: d.fixedItems == nil ? half : third)
                    accounts.frame(width: d.fixedItems == nil ? half : third)
                }
            } else {
                hero
                row {
                    DashboardAttentionCard(items: d.attention).frame(width: half)
                    if let fixed = d.fixedItems {
                        DashboardFixedItemsCard(overview: fixed).frame(width: half)
                    } else {
                        accounts.frame(width: half)
                    }
                }
                if d.fixedItems != nil {
                    row {
                        monthCard.frame(width: half)
                        accounts.frame(width: half)
                    }
                } else {
                    monthCard
                }
            }
            row {
                DashboardSpendableChartCard(year: data.chartYear, points: data.spendableSeries).frame(width: half)
                DashboardInOutChartCard(year: data.chartYear, months: data.monthlyResults).frame(width: half)
            }
            row {
                DashboardTopTagsCard(tags: d.topTags, month: d.today.month).frame(width: wide ? third : half)
                DashboardRecentCard(entries: d.recentEntries, showAccount: wide).frame(width: wide ? twoThirds : half)
            }
        }
        .frame(width: width, alignment: .leading)
    }

    @ViewBuilder private var hero: some View {
        if let spendable = data.dashboard.spendable {
            DashboardHeroCard(spendable: spendable)
        } else {
            DashboardYearMissingCard(year: data.dashboard.today.year)
        }
    }

    private var monthCard: some View {
        DashboardMonthCard(dashboard: data.dashboard,
                           result: data.chartYear == data.dashboard.today.year
                               ? data.monthlyResults.first { $0.month == data.dashboard.today.month }?.result : nil)
    }

    private var accounts: some View {
        DashboardAccountsCard(accounts: data.dashboard.accounts, sparklines: data.sparklines)
    }

    /// Kaarten naast elkaar, allemaal even hoog.
    private func row<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: gap) { content() }
            .fixedSize(horizontal: false, vertical: true)
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

    static func daysInMonth(_ day: Day) -> Int {
        Calendar(identifier: .gregorian).range(of: .day, in: .month, for: day.date)?.count ?? 30
    }
}
