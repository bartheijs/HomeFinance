import SwiftUI
import Charts
import HFCore
import HFInsight

/// Rapport Categorieën: hoeveel geven we per maand uit aan één tag?
struct ReportsTagsTab: View {
    let data: ReportsData
    let year: Int
    /// "Dit jaar verrekend" geldt voor het lopende jaar; bij een ander jaar blijft het weg.
    var showsSettledThisYear = true
    @Binding var tagId: Int64?
    @Binding var month: Int?
    @State private var hover: String?

    private var selected: TagYearRow? { data.tags.first { $0.id == tagId } }

    var body: some View {
        HStack(alignment: .top, spacing: 36) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Dit jaar t/m nu").font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.horizontal, 10).padding(.bottom, 4)
                ForEach(data.tags) { tag in
                    Button { tagId = tag.id } label: {
                        HStack {
                            Text(tag.name).fontWeight(tag.id == tagId ? .semibold : .regular).lineLimit(1)
                            Spacer(minLength: 8)
                            ReportsAmount(amount: tag.yearToDate).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .background(tag.id == tagId ? Theme.accent.opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Toon het verloop van \(tag.name) per maand")
                }
            }
            .frame(width: 240)
            if let selected {
                detail(selected).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// Uitgaven zijn negatief; in de grafiek staan ze als staven omhoog.
    private func barValue(_ amount: Money, _ tag: TagYearRow) -> Double {
        tag.yearToDate.isNegative ? -amount.doubleValue : amount.doubleValue
    }

    private func summaryLine(_ tag: TagYearRow) -> String {
        guard tag.entryCount > 0 else { return "Deze tag is in \(String(year)) nog niet gebruikt." }
        var text = "Gemiddeld \(tag.averagePerMonth.magnitude.formatted()) per maand."
        if let previous = tag.previousYearToDate {
            text += " Vorig jaar t/m dezelfde datum: \(previous.magnitude.formatted())."
        }
        return text
    }

    private func settlementLine(_ s: TagSettlementSummary) -> String {
        var text = s.openCount == 0
            ? "Verrekenen: er staat niets open."
            : "Verrekenen: \(s.outstanding.formatted()) staat nog open (\(s.openCount) \(s.openCount == 1 ? "boeking" : "boekingen"))."
        if showsSettledThisYear { text += " Dit jaar verrekend: \(s.settledThisYear.formatted())." }
        return text
    }

    private func detail(_ tag: TagYearRow) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            ReportsQuestion("Hoeveel \(tag.yearToDate.isNegative || tag.yearToDate.isZero ? "geven we per maand uit aan" : "komt er per maand binnen via") \(tag.name)?",
                            detail: summaryLine(tag))
            if let settlement = data.settlements.first(where: { $0.id == tag.id }) {
                Label(settlementLine(settlement), systemImage: "arrow.left.arrow.right")
                    .foregroundStyle(.secondary)
                    .help("Verrekenen: deze uitgaven worden later teruggestort op de betaalrekening. Openstaand is wat nog niet is teruggestort.")
            }
            chart(tag).frame(height: 320)
            if let month {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Boekingen in \(ReportsFormat.monthName(month))").font(.headline)
                        Spacer()
                        ReportsAmount(amount: tag.months[month - 1]).font(.headline)
                        Button { self.month = nil } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                            .keyboardShortcut(.cancelAction)
                            .help("Sluit de boekingen (Esc)")
                    }
                    if data.tagEntries.isEmpty {
                        Text("Geen boekingen met deze tag in \(ReportsFormat.monthName(month)).").foregroundStyle(.secondary)
                    } else {
                        ReportsEntryList(entries: data.tagEntries)
                    }
                }
            } else if tag.entryCount > 0 {
                Label("Klik op een staaf om de boekingen van die maand te zien.", systemImage: "hand.point.up.left")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func chart(_ tag: TagYearRow) -> some View {
        Chart {
            ForEach(Array(tag.months.enumerated()), id: \.offset) { index, amount in
                let name = ReportsFormat.month(index + 1)
                BarMark(x: .value("Maand", name), y: .value("Bedrag", barValue(amount, tag)), width: .ratio(0.6))
                    .foregroundStyle(ReportsColor.accent.opacity(opacity(index + 1, name)))
                    .cornerRadius(5)
                    .annotation(position: .top, spacing: 4) {
                        if !amount.isZero {
                            Text(ReportsFormat.euros(amount.magnitude)).font(.callout).monospacedDigit()
                                .foregroundStyle(month == index + 1 ? Color.primary : Color.secondary)
                        }
                    }
            }
            if !tag.averagePerMonth.isZero {
                RuleMark(y: .value("Gemiddeld", barValue(tag.averagePerMonth, tag)))
                    .foregroundStyle(Color.primary.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1.2, dash: [5, 4]))
                    .annotation(position: .top, alignment: .trailing, spacing: 3) {
                        Text("gemiddeld \(ReportsFormat.euros(tag.averagePerMonth.magnitude))")
                            .font(.callout).foregroundStyle(.secondary)
                    }
            }
        }
        .chartXScale(domain: Day.monthNamesShort)
        .reportsCategoryAxis()
        .reportsEuroAxis()
        .reportsChartHover($hover) { name in
            guard let index = ReportsFormat.monthIndex(name) else { return }
            month = month == index ? nil : index
        }
    }

    private func opacity(_ index: Int, _ name: String) -> Double {
        if month == index { return 1 }
        if hover == name { return 0.8 }
        return month == nil ? 0.9 : 0.3
    }
}
