import Foundation
import HFCore
import HFInsight

/// "Kopieer als tabel": de cijfers van een rapport als tekst met tabs, om in Excel te plakken.
extension ReportsData {
    func table(for tab: ReportsTab, year: Int, tagId: Int64?, tagMonth: Int?, diversMonth: Int?) -> String {
        let p = ReportsFormat.plain
        switch tab {
        case .overview:
            var rows = months.map { [ReportsFormat.month($0.month), p($0.income), p($0.expenses), p($0.result)] }
            if let s = summary {
                rows.append(["Totaal t/m \(s.asOf.dutch)", p(s.income), p(s.expenses), p(s.result)])
                rows.append(["Gemiddeld per maand", p(s.averageIncome), p(s.averageExpenses), ""])
            }
            return ReportsFormat.tsv(["Maand", "IN", "UIT", "Resultaat"], rows)

        case .spendable:
            let rows = spendable.map { [$0.day.dutch, p($0.balance), p($0.spendable)] }
            return ReportsFormat.tsv(["Datum", "Op de rekening", "Besteedbaar"], rows)

        case .tags:
            let header = ["Tag"] + Day.monthNamesShort + ["Dit jaar t/m nu", "Gemiddeld per maand", "Vorig jaar t/m zelfde datum", "Heel vorig jaar"]
            var rows = tags.map { t in
                [t.name] + t.months.map(p) + [p(t.yearToDate), p(t.averagePerMonth),
                                              t.previousYearToDate.map(p) ?? "", t.previousYearTotal.map(p) ?? ""]
            }
            if let tag = tags.first(where: { $0.id == tagId }), !tagEntries.isEmpty {
                rows.append([])
                rows.append(["Boekingen \(tag.name), \(ReportsFormat.period(year: year, month: tagMonth))"])
                rows.append(["Datum", "Omschrijving", "Bedrag"])
                rows += tagEntries.map { [$0.day.dutch, $0.label, p($0.amount)] }
            }
            return ReportsFormat.tsv(header, rows)

        case .labels:
            return ""   // het tabblad levert zijn eigen tabel

        case .budget:
            let rows = ReportsBudgetTab.ordered(budget).map { r in
                [r.label, r.direction.rawValue, p(r.planToDate), p(r.actualToDate), p(r.difference), p(r.planYear),
                 String(r.monthsOver), String(r.monthsUnder), r.reportsFlag?.title ?? ""]
            }
            return ReportsFormat.tsv(["Post", "Richting", "Plan t/m nu", "Werkelijk t/m nu", "Verschil", "Plan heel jaar",
                                      "Maanden meer dan plan", "Maanden minder dan plan", "Opvallend"], rows)

        case .divers:
            var rows = (divers?.buckets ?? []).map { [$0.name, String($0.count), p($0.total)] }
            rows.append(["Totaal UIT divers", "", p(divers?.total ?? .zero)])
            rows.append([])
            rows.append(["Grootste diverse uitgaven, \(ReportsFormat.period(year: year, month: diversMonth))"])
            rows.append(["Datum", "Omschrijving", "Bedrag", "Tags"])
            rows += topDivers.map { [$0.day.dutch, $0.label, p($0.amount), $0.tags.map(\.name).joined(separator: ", ")] }
            return ReportsFormat.tsv(["Tag", "Aantal", "Bedrag"], rows)

        case .years:
            let rows = years.map { y in
                [String(y.year), p(y.income), p(y.expenses), p(y.result), p(y.inDivers), p(y.uitDivers), y.hasBudget ? "ja" : "nee"]
            }
            return ReportsFormat.tsv(["Jaar", "IN", "UIT", "Resultaat", "IN divers", "UIT divers", "Begroting"], rows)
        }
    }
}
