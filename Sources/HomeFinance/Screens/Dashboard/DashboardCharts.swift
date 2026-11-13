import SwiftUI
import Charts
import HFCore
import HFInsight

/// Besteedbaar per maandeinde, met het saldo van de betaalrekening als achtergrond.
struct DashboardSpendableChartCard: View {
    let year: Int
    let points: [SpendablePoint]

    /// Plek op de x-as: 0 = 1 januari, 12 = eind december.
    private func position(_ day: Day) -> Double {
        Double(day.month - 1) + Double(day.day) / Double(DashboardFormat.daysInMonth(day))
    }

    var body: some View {
        DashboardCard("Verloop besteedbaar \(String(year))", icon: "chart.xyaxis.line",
                      help: "Besteedbaar aan het eind van elke maand. De grijze lijn is het saldo van de betaalrekening; het verschil is gereserveerd geld en buffers.") {
            HStack(spacing: 12) {
                legend("Besteedbaar", Theme.accent, dashed: false)
                legend("Saldo", Color.secondary, dashed: true)
            }
        } content: {
            if points.isEmpty {
                DashboardQuietState(icon: "chart.xyaxis.line", title: "Geen verloop voor \(String(year))",
                                    message: "Dit jaar heeft nog geen begroting of nog geen boekingen.")
                    .frame(height: 190)
            } else {
                chart.frame(height: 190)
            }
        }
    }

    private var chart: some View {
        Chart {
            RuleMark(y: .value("Nul", 0))
                .foregroundStyle(Color.secondary.opacity(0.4))
                .lineStyle(StrokeStyle(lineWidth: 1))
            ForEach(points) { point in
                AreaMark(x: .value("Maand", position(point.day)), y: .value("Besteedbaar", point.spendable.doubleValue))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(LinearGradient(colors: [Theme.accent.opacity(0.28), Theme.accent.opacity(0.02)],
                                                    startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("Maand", position(point.day)), y: .value("Bedrag", point.balance.doubleValue),
                         series: .value("Reeks", "Saldo"))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(Color.secondary.opacity(0.7))
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                LineMark(x: .value("Maand", position(point.day)), y: .value("Bedrag", point.spendable.doubleValue),
                         series: .value("Reeks", "Besteedbaar"))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(Theme.accent)
                    .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                PointMark(x: .value("Maand", position(point.day)), y: .value("Bedrag", point.spendable.doubleValue))
                    .foregroundStyle(Theme.accent)
                    .symbolSize(point.id == points.last?.id ? 70 : 22)
            }
        }
        .chartXScale(domain: 0.0...12.0)
        .chartXAxis {
            AxisMarks(values: (0..<12).map { Double($0) + 0.5 }) { value in
                AxisValueLabel {
                    if let x = value.as(Double.self) { Text(Day.monthNamesShort[min(max(Int(x), 0), 11)]) }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine().foregroundStyle(Theme.hairline.opacity(0.6))
                AxisValueLabel {
                    if let amount = value.as(Double.self) { Text(DashboardFormat.axisEuros(amount)).monospacedDigit() }
                }
            }
        }
        .chartLegend(.hidden)
    }

    private func legend(_ text: String, _ color: Color, dashed: Bool) -> some View {
        HStack(spacing: 5) {
            Capsule().stroke(color, style: StrokeStyle(lineWidth: 2, dash: dashed ? [3, 2] : []))
                .frame(width: 14, height: 1)
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Inkomsten en uitgaven per maand naast elkaar.
struct DashboardInOutChartCard: View {
    let year: Int
    let months: [MonthResult]

    private struct Bar: Identifiable {
        let id: String
        let month: String
        let series: String
        let value: Double
    }

    private var bars: [Bar] {
        months.flatMap { m -> [Bar] in
            let name = Day.monthNamesShort[m.month - 1]
            return [Bar(id: "\(m.month)-in", month: name, series: "IN", value: m.income.magnitude.doubleValue),
                    Bar(id: "\(m.month)-uit", month: name, series: "UIT", value: m.expenses.magnitude.doubleValue)]
        }
    }

    private var hasData: Bool { months.contains { !$0.income.isZero || !$0.expenses.isZero } }

    var body: some View {
        DashboardCard("IN en UIT per maand \(String(year))", icon: "chart.bar",
                      help: "Alle inkomsten (IN) en uitgaven (UIT) op de betaalrekening per maand.") {
            HStack(spacing: 12) {
                legend("IN", Theme.positive)
                legend("UIT", Theme.negative)
            }
        } content: {
            if hasData {
                chart.frame(height: 190)
            } else {
                DashboardQuietState(icon: "chart.bar", title: "Nog geen boekingen in \(String(year))",
                                    message: "Na de eerste import zie je hier de maanden naast elkaar.")
                    .frame(height: 190)
            }
        }
    }

    private var chart: some View {
        Chart(bars) { bar in
            BarMark(x: .value("Maand", bar.month), y: .value("Bedrag", bar.value), width: .ratio(0.8))
                .position(by: .value("Soort", bar.series), axis: .horizontal, span: .ratio(0.72))
                .foregroundStyle(by: .value("Soort", bar.series))
                .cornerRadius(2.5)
        }
        .chartForegroundStyleScale(["IN": Theme.positive, "UIT": Theme.negative])
        .chartXScale(domain: Day.monthNamesShort)
        .chartXAxis {
            AxisMarks { _ in AxisValueLabel() }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine().foregroundStyle(Theme.hairline.opacity(0.6))
                AxisValueLabel {
                    if let amount = value.as(Double.self) { Text(DashboardFormat.axisEuros(amount)).monospacedDigit() }
                }
            }
        }
        .chartLegend(.hidden)
    }

    private func legend(_ text: String, _ color: Color) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 9, height: 9)
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
    }
}
