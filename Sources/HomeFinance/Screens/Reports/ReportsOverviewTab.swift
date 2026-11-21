import SwiftUI
import Charts
import HFCore
import HFInsight

/// Rapport Overzicht: hoeveel kwam erin en ging eruit per maand?
struct ReportsOverviewTab: View {
    let data: ReportsData
    let year: Int
    @State private var hover: String?

    private var elapsed: Int { data.summary?.elapsedMonths ?? 12 }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            ReportsQuestion("Hoeveel kwam erin en ging eruit per maand?",
                            detail: "Alles op de betaalrekening in \(String(year)). Beweeg over een maand voor de exacte bedragen.")
            if let s = data.summary {
                HStack(spacing: 56) {
                    ReportsKeyNumber(title: "IN", value: s.income.formatted())
                        .help("Alles wat dit jaar op de betaalrekening is binnengekomen, t/m \(s.asOf.short()).")
                    ReportsKeyNumber(title: "UIT", value: s.expenses.formatted())
                        .help("Alles wat dit jaar van de betaalrekening is afgegaan.")
                    ReportsKeyNumber(title: "Resultaat", value: s.result.formatted(alwaysSign: true),
                                     tint: s.result.isNegative ? ReportsColor.over : .primary)
                        .help("IN min UIT. Positief betekent dat er dit jaar geld is overgebleven.")
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 18) {
                    ReportsLegendItem(title: "IN", color: ReportsColor.accent)
                    ReportsLegendItem(title: "UIT", color: ReportsColor.neutral)
                }
                chart.frame(height: 340)
            }
            ReportsDisclosure("Toon cijfers") { table.frame(maxWidth: 640) }
        }
    }

    private var chart: some View {
        Chart {
            ForEach(data.months) { m in
                BarMark(x: .value("Maand", ReportsFormat.month(m.month)), y: .value("Bedrag", m.income.doubleValue))
                    .foregroundStyle(ReportsColor.accent.opacity(dim(m.month)))
                    .position(by: .value("Reeks", "IN"))
                    .cornerRadius(4)
                BarMark(x: .value("Maand", ReportsFormat.month(m.month)), y: .value("Bedrag", m.expenses.magnitude.doubleValue))
                    .foregroundStyle(ReportsColor.neutral.opacity(dim(m.month)))
                    .position(by: .value("Reeks", "UIT"))
                    .cornerRadius(4)
            }
            if let hover, let index = ReportsFormat.monthIndex(hover), let m = data.months.first(where: { $0.month == index }) {
                RuleMark(x: .value("Maand", hover))
                    .foregroundStyle(Color.clear)
                    .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                        ReportsTooltip(title: "\(ReportsFormat.monthName(index).capitalized) \(String(year))", lines: [
                            .init(label: "IN", color: ReportsColor.accent, value: m.income.formatted()),
                            .init(label: "UIT", color: ReportsColor.neutral, value: m.expenses.formatted()),
                            .init(label: "Resultaat", color: nil, value: m.result.formatted(alwaysSign: true)),
                        ])
                    }
            }
        }
        .chartXScale(domain: Day.monthNamesShort)
        .reportsCategoryAxis()
        .reportsEuroAxis()
        .reportsChartHover($hover)
    }

    private func dim(_ month: Int) -> Double {
        guard let hover else { return 1 }
        return ReportsFormat.month(month) == hover ? 1 : 0.4
    }

    private var table: some View {
        Grid(alignment: .trailing, horizontalSpacing: 24, verticalSpacing: 7) {
            GridRow {
                ReportsColumnTitle("Maand", alignment: .leading)
                ReportsColumnTitle("IN", help: "Inkomsten op de betaalrekening")
                ReportsColumnTitle("UIT", help: "Uitgaven van de betaalrekening")
                ReportsColumnTitle("Resultaat", help: "IN min UIT")
            }
            Divider()
            ForEach(data.months.filter { $0.month <= elapsed || !$0.income.isZero || !$0.expenses.isZero }) { m in
                GridRow {
                    Text(ReportsFormat.monthName(m.month)).frame(maxWidth: .infinity, alignment: .leading)
                    ReportsAmount(amount: m.income)
                    ReportsAmount(amount: m.expenses)
                    ReportsAmount(amount: m.result, redIfNegative: true, alwaysSign: true)
                }
            }
            if let s = data.summary {
                Divider()
                GridRow {
                    Text("Totaal").frame(maxWidth: .infinity, alignment: .leading)
                    ReportsAmount(amount: s.income)
                    ReportsAmount(amount: s.expenses)
                    ReportsAmount(amount: s.result, redIfNegative: true, alwaysSign: true)
                }
                .fontWeight(.semibold)
                GridRow {
                    Text("Gemiddeld per maand").frame(maxWidth: .infinity, alignment: .leading)
                    ReportsAmount(amount: s.averageIncome)
                    ReportsAmount(amount: s.averageExpenses)
                    Text("")
                }
                .foregroundStyle(.secondary)
            }
        }
    }
}

/// Rapport Besteedbaar: hoeveel kunnen we vrij uitgeven?
struct ReportsSpendableTab: View {
    let summary: YearSummary
    let points: [SpendablePoint]
    @State private var hover: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            ReportsQuestion("Hoeveel kunnen we vrij uitgeven?",
                            detail: "Vrij te besteden is wat er op de betaalrekening staat, min de buffers. Stand aan het eind van elke maand.")
            HStack(spacing: 56) {
                ReportsKeyNumber(title: "Vrij te besteden", value: summary.spendable.formatted(),
                                 tint: summary.spendable.isNegative ? ReportsColor.over : .primary)
                ReportsKeyNumber(title: "Op de rekening", value: summary.balance.formatted())
                ReportsKeyNumber(title: "Buffers", value: summary.buffers.formatted())
                    .help("Minimaal op je betaalrekening en tijdelijk geleend van spaar: dit blijft op de rekening staan en telt niet mee in vrij te besteden.")
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 18) {
                    ReportsLegendItem(title: "Vrij te besteden", color: ReportsColor.accent)
                    ReportsLegendItem(title: "Op de rekening", color: ReportsColor.neutral, dashed: true)
                }
                chart.frame(height: 340)
            }
            ReportsDisclosure("Toon cijfers") { table.frame(maxWidth: 640) }
        }
    }

    private var chart: some View {
        Chart {
            ForEach(points) { p in
                AreaMark(x: .value("Maand", ReportsFormat.month(p.day.month)), y: .value("Vrij te besteden", p.spendable.doubleValue))
                    .foregroundStyle(LinearGradient(colors: [ReportsColor.accent.opacity(0.22), ReportsColor.accent.opacity(0.02)],
                                                    startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Maand", ReportsFormat.month(p.day.month)), y: .value("Bedrag", p.spendable.doubleValue),
                         series: .value("Reeks", "Vrij te besteden"))
                    .foregroundStyle(ReportsColor.accent)
                    .lineStyle(StrokeStyle(lineWidth: 3))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Maand", ReportsFormat.month(p.day.month)), y: .value("Bedrag", p.balance.doubleValue),
                         series: .value("Reeks", "Op de rekening"))
                    .foregroundStyle(ReportsColor.neutral)
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    .interpolationMethod(.monotone)
            }
            if let hover, let p = points.first(where: { ReportsFormat.month($0.day.month) == hover }) {
                RuleMark(x: .value("Maand", hover))
                    .foregroundStyle(Color.secondary.opacity(0.3))
                    .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                        ReportsTooltip(title: "Stand op \(p.day.short())", lines: [
                            .init(label: "Op de rekening", color: ReportsColor.neutral, value: p.balance.formatted()),
                            .init(label: "Vrij te besteden", color: ReportsColor.accent, value: p.spendable.formatted()),
                        ])
                    }
            }
        }
        .chartXScale(domain: Day.monthNamesShort)
        .reportsCategoryAxis()
        .reportsEuroAxis()
        .reportsChartHover($hover)
    }

    private var table: some View {
        Grid(alignment: .trailing, horizontalSpacing: 24, verticalSpacing: 7) {
            GridRow {
                ReportsColumnTitle("Stand op", alignment: .leading)
                ReportsColumnTitle("Op de rekening", help: "Saldo van de betaalrekening(en)")
                ReportsColumnTitle("Vrij te besteden", help: "Op de rekening min buffers")
            }
            Divider()
            ForEach(points) { p in
                GridRow {
                    Text(p.day.short()).monospacedDigit().frame(maxWidth: .infinity, alignment: .leading)
                    ReportsAmount(amount: p.balance)
                    ReportsAmount(amount: p.spendable, redIfNegative: true)
                }
            }
        }
    }
}
