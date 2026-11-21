import SwiftUI
import Charts
import HFCore
import HFInsight

/// Rapport Jaar op jaar: hoe doet dit jaar het tegenover eerdere jaren?
struct ReportsYearsTab: View {
    let years: [YearTotals]
    let currentYear: Int
    @State private var hover: String?

    private var detail: String {
        years.count == 1
            ? "Er is nu één jaar met boekingen. Bij elk jaar dat erbij komt, zie je hier de vergelijking. De historie uit Excel inlezen komt later."
            : "IN en UIT op de betaalrekening per jaar. Het lopende jaar telt t/m vandaag."
    }

    var body: some View {
        if years.isEmpty {
            EmptyState(title: "Nog geen jaren om te vergelijken",
                       message: "Zodra er boekingen op de betaalrekening staan, zie je hier de totalen per jaar.",
                       icon: "calendar")
                .frame(minHeight: 360)
        } else {
            VStack(alignment: .leading, spacing: 24) {
                ReportsQuestion("Hoe doet dit jaar het tegenover eerdere jaren?", detail: detail)
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 18) {
                        ReportsLegendItem(title: "IN", color: ReportsColor.accent)
                        ReportsLegendItem(title: "UIT", color: ReportsColor.neutral)
                    }
                    chart.frame(maxWidth: years.count < 5 ? CGFloat(years.count) * 220 + 90 : .infinity).frame(height: 340)
                }
                ReportsDisclosure("Toon cijfers") { table.frame(maxWidth: 900) }
            }
        }
    }

    /// Met weinig jaren blijven de staven slank.
    private var barWidth: MarkDimension { years.count < 5 ? .fixed(52) : .ratio(0.8) }
    private func dim(_ name: String) -> Double { hover == nil || hover == name ? 1 : 0.4 }

    private var chart: some View {
        Chart {
            ForEach(years) { y in
                let name = String(y.year)
                BarMark(x: .value("Jaar", name), y: .value("Bedrag", y.income.doubleValue), width: barWidth)
                    .foregroundStyle(ReportsColor.accent.opacity(dim(name)))
                    .position(by: .value("Reeks", "1 IN")).cornerRadius(5)
                BarMark(x: .value("Jaar", name), y: .value("Bedrag", y.expenses.magnitude.doubleValue), width: barWidth)
                    .foregroundStyle(ReportsColor.neutral.opacity(dim(name)))
                    .position(by: .value("Reeks", "2 UIT")).cornerRadius(5)
            }
            if let hover, let y = years.first(where: { String($0.year) == hover }) {
                RuleMark(x: .value("Jaar", hover))
                    .foregroundStyle(Color.clear)
                    .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                        ReportsTooltip(title: hover, lines: [
                            .init(label: "IN", color: ReportsColor.accent, value: y.income.formatted()),
                            .init(label: "UIT", color: ReportsColor.neutral, value: y.expenses.formatted()),
                            .init(label: "Resultaat", color: nil, value: y.result.formatted(alwaysSign: true)),
                        ])
                    }
            }
        }
        .reportsCategoryAxis()
        .reportsEuroAxis()
        .reportsChartHover($hover)
    }

    private var table: some View {
        Grid(alignment: .trailing, horizontalSpacing: 24, verticalSpacing: 7) {
            GridRow {
                ReportsColumnTitle("Jaar", alignment: .leading)
                ReportsColumnTitle("IN", help: "Alle inkomsten op de betaalrekening")
                ReportsColumnTitle("UIT", help: "Alle uitgaven van de betaalrekening")
                ReportsColumnTitle("Resultaat", help: "IN min UIT")
                ReportsColumnTitle("IN overig", help: "Inkomsten zonder vaste post")
                ReportsColumnTitle("UIT overig", help: "Uitgaven zonder vaste post")
            }
            Divider()
            ForEach(years) { y in
                GridRow {
                    Text(String(y.year) + (y.hasBudget ? "" : " (zonder begroting)")).monospacedDigit()
                        .fontWeight(y.year == currentYear ? .semibold : .regular)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    ReportsAmount(amount: y.income)
                    ReportsAmount(amount: y.expenses)
                    ReportsAmount(amount: y.result, redIfNegative: true, alwaysSign: true)
                    ReportsAmount(amount: y.inDivers)
                    ReportsAmount(amount: y.uitDivers)
                }
            }
        }
    }
}
