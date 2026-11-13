import SwiftUI
import HFCore
import HFInsight

/// Signaal bij een post die maand na maand afwijkt.
enum ReportsBudgetFlag {
    case overBudget, lowIncome

    var title: String {
        switch self {
        case .overBudget: "Structureel boven plan"
        case .lowIncome: "Structureel lager dan plan"
        }
    }

    var help: String {
        switch self {
        case .overBudget: "Deze post was drie maanden of vaker duurder dan gepland. Misschien moet het plan omhoog."
        case .lowIncome: "Hier kwam drie maanden of vaker minder binnen dan gepland. Misschien moet het plan omlaag."
        }
    }
}

extension BudgetVsActualRow {
    /// Weergaveregel: opvallend als de post in drie of meer maanden de verkeerde kant op afweek én in totaal ongunstig staat.
    var reportsFlag: ReportsBudgetFlag? {
        guard difference.isNegative else { return nil }
        switch direction {
        case .UIT: return monthsOver >= 3 ? .overBudget : nil
        case .IN: return monthsUnder >= 3 ? .lowIncome : nil
        case .RES: return nil
        }
    }
}

/// Rapport Budget tegen werkelijk: welke vaste posten wijken af van het plan?
struct ReportsBudgetTab: View {
    let rows: [BudgetVsActualRow]
    @Binding var showAll: Bool
    let asOf: Day?

    /// Grootste overschrijding eerst. Een negatief verschil is altijd ongunstig:
    /// meer uitgegeven (UIT) of minder ontvangen (IN) dan gepland.
    static func ordered(_ rows: [BudgetVsActualRow]) -> [BudgetVsActualRow] {
        rows.sorted { $0.difference < $1.difference }
    }

    private var deviating: [BudgetVsActualRow] { rows.filter { !$0.difference.isZero } }
    private var shown: [BudgetVsActualRow] { Self.ordered(showAll ? rows : deviating) }
    private var scale: Double { rows.map { $0.difference.magnitude.doubleValue }.max() ?? 0 }

    private var detail: String {
        let worse = rows.filter { $0.difference.isNegative }.count
        let date = asOf.map { " t/m \($0.short())" } ?? ""
        return "\(worse) van de \(rows.count) posten staan ongunstig\(date); \(rows.count - deviating.count) lopen precies volgens plan. Grootste overschrijding bovenaan."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            ReportsQuestion("Welke vaste posten wijken af van het plan?", detail: detail)
            if shown.isEmpty {
                Label("Alle vaste posten lopen precies volgens plan.", systemImage: "checkmark.circle")
                    .font(.title3).foregroundStyle(.secondary).padding(.vertical, 24)
            } else {
                VStack(spacing: 0) {
                    header.padding(.bottom, 8)
                    Divider()
                    ForEach(shown) { row in
                        ReportsBudgetRow(row: row, scale: scale).padding(.vertical, 9)
                        Divider().opacity(0.5)
                    }
                }
                .frame(maxWidth: 980)
            }
            if !showAll, deviating.count < rows.count {
                Button("Toon alle \(rows.count) posten") { showAll = true }
                    .buttonStyle(.plain).font(.body.weight(.medium)).foregroundStyle(Theme.accent)
                    .help("Laat ook de posten zien die precies volgens plan lopen")
            }
            Label("De lopende maand telt in het plan al helemaal mee. Een post die later deze maand komt, zoals salaris, staat daardoor tijdelijk achter.",
                  systemImage: "info.circle")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private var header: some View {
        HStack(spacing: 20) {
            ReportsColumnTitle("Vaste post", alignment: .leading)
            ReportsColumnTitle("Plan", help: "Het geplande bedrag keer het aantal maanden waarin de post tot nu toe verwacht werd")
                .frame(width: ReportsBudgetRow.amountWidth)
            ReportsColumnTitle("Werkelijk", help: "Wat er dit jaar echt op deze post is geboekt")
                .frame(width: ReportsBudgetRow.amountWidth)
            ReportsColumnTitle("Verschil", help: "Werkelijk min plan. Balk naar links (rood): duurder of minder ontvangen dan gepland. Balk naar rechts: een meevaller.", alignment: .leading)
                .frame(width: ReportsBudgetRow.barWidth + ReportsBudgetRow.amountWidth + 20)
        }
    }
}

struct ReportsBudgetRow: View {
    static let amountWidth: CGFloat = 110
    static let barWidth: CGFloat = 220

    let row: BudgetVsActualRow
    let scale: Double

    private var monthsHelp: String {
        row.direction == .UIT
            ? "\(row.monthsOver) maanden meer uitgegeven dan gepland, \(row.monthsUnder) maanden minder. Plan voor het hele jaar: \(row.planYear.formatted())."
            : "\(row.monthsOver) maanden meer ontvangen dan gepland, \(row.monthsUnder) maanden minder. Plan voor het hele jaar: \(row.planYear.formatted())."
    }

    var body: some View {
        HStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.label).lineLimit(1)
                if let flag = row.reportsFlag {
                    Label(flag.title, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout).foregroundStyle(ReportsColor.over).help(flag.help)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            ReportsAmount(amount: row.planToDate).foregroundStyle(.secondary)
                .frame(width: Self.amountWidth, alignment: .trailing)
            ReportsAmount(amount: row.actualToDate)
                .frame(width: Self.amountWidth, alignment: .trailing)
            bar.frame(width: Self.barWidth, height: 12)
            Group {
                if row.difference.isZero {
                    Text("volgens plan").foregroundStyle(.tertiary)
                } else {
                    ReportsAmount(amount: row.difference, redIfNegative: true, alwaysSign: true).fontWeight(.medium)
                }
            }
            .frame(width: Self.amountWidth, alignment: .trailing)
        }
        .help(monthsHelp)
    }

    /// Balk vanuit het midden: links (rood) ongunstig, rechts (accent) gunstig.
    private var bar: some View {
        GeometryReader { geo in
            let half = geo.size.width / 2
            let length = scale > 0 ? max(row.difference.isZero ? 0 : 3, half * row.difference.magnitude.doubleValue / scale) : 0
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(row.difference.isNegative ? ReportsColor.over : ReportsColor.accent.opacity(0.7))
                    .frame(width: length)
                    .offset(x: row.difference.isNegative ? half - length : half)
                Rectangle().fill(Color.secondary.opacity(0.5)).frame(width: 1).offset(x: half)
            }
        }
    }
}
