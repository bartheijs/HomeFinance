import SwiftUI
import Charts
import HFCore
import HFInsight

/// Rechterpaneel: één pot met saldografiek, mutaties en acties.
struct PotsDetailPanel: View {
    @Environment(AppModel.self) private var model
    let pot: PotSummary
    let accountName: String
    let history: [PotHistoryRow]
    let asOf: Day
    var onMove: () -> Void
    var onEdit: () -> Void
    var onArchive: () -> Void
    var onUnarchive: () -> Void
    var onDelete: () -> Void
    var onClose: () -> Void
    var onDistributions: () -> Void
    /// Via welke vaste stortingen dit potje geld krijgt, en bij welke post die horen.
    var chain: PotChain? = nil
    @State private var showAllMovements = false

    private var points: [PotsChartPoint] { PotsChartPoint.points(from: history, asOf: asOf) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                head
                if let recovery = pot.recovery { PotsRecoveryBlock(recovery: recovery, onDistributions: onDistributions) }
                if let goal = pot.goal { PotsGoalBlock(pot: pot, goal: goal, onDistributions: onDistributions) }
                if history.isEmpty {
                    Text("Dit potje heeft nog geen boekingen. Hij krijgt saldo zodra je een boeking op de spaarrekening aan dit potje toewijst, of geld uit een ander potje hierheen verplaatst.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    chart
                }
                if !pot.archived {
                    PotsForecastSection(pot: pot, history: history, onDistributions: onDistributions)
                }
                if !history.isEmpty { movements }
            }
            .padding(18)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.card)
    }

    // MARK: Kop

    private var head: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(pot.name).font(.title3.weight(.semibold)).lineLimit(2)
                    HStack(spacing: 6) {
                        Pill(pot.kind.potsTitle, color: pot.kind == .spaar ? Theme.info : Theme.accent)
                            .help(pot.kind.potsExplanation)
                        if let owner = pot.owner, !owner.isEmpty { Pill(owner, icon: "person.fill") }
                        if pot.archived { Pill("Gearchiveerd", icon: "archivebox") }
                    }
                }
                Spacer(minLength: 4)
                Menu {
                    Button("Bewerk…", systemImage: "pencil", action: onEdit)
                    Button("Verplaats naar ander potje…", systemImage: "arrow.left.arrow.right", action: onMove)
                        .disabled(pot.archived)
                    Divider()
                    if pot.archived {
                        Button("Haal uit archief", systemImage: "archivebox", action: onUnarchive)
                    } else {
                        Button(pot.balance.isZero ? "Opheffen" : "Opheffen…", systemImage: "archivebox", action: onArchive)
                            .disabled(pot.balance.isNegative)
                    }
                    if history.isEmpty {
                        Button("Verwijder…", systemImage: "trash", role: .destructive, action: onDelete)
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("Meer acties voor dit potje")
                Button(action: onClose) { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                    .buttonStyle(.borderless)
                    .keyboardShortcut(.cancelAction)
                    .help("Sluit het paneel (Esc)")
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(pot.balance.formatted())
                    .font(.system(size: 32, weight: .bold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(pot.balance.isNegative ? Theme.warning : Color.primary)
                    .lineLimit(1).minimumScaleFactor(0.6)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }

            if !pot.pendingSettlement.isZero {
                HStack(spacing: 10) {
                    Text(PotsFormat.pending(pot.pendingSettlement)).font(.callout).foregroundStyle(.secondary)
                    Button("Naar Nog overboeken") { model.selection = .reimbursements }
                        .buttonStyle(.plain).foregroundStyle(Theme.accent).font(.callout)
                        .help("Open Nog overboeken om deze boekingen met het potje recht te zetten.")
                }
            }

            HStack(spacing: 0) {
                fact("Per maand", pot.distributionAmount.isZero ? "–" : pot.distributionAmount.formatted())
                    .help("Wat er volgens je vaste overboekingen elke maand naar dit potje gaat.")
                Divider().frame(height: 26).padding(.horizontal, 10)
                fact("Gestort \(String(asOf.year))", pot.depositsThisYear.isZero ? "–" : pot.depositsThisYear.formatted(alwaysSign: true))
                Divider().frame(height: 26).padding(.horizontal, 10)
                fact("Opgenomen", pot.withdrawalsThisYear.isZero ? "–" : pot.withdrawalsThisYear.formatted())
            }

            if let chain, !pot.archived { PotChainView(chain: chain) }

            HStack(spacing: 8) {
                Button(action: onMove) {
                    Label("Verplaats naar ander potje…", systemImage: "arrow.left.arrow.right")
                }
                .disabled(pot.archived)
                .help("Zet een bedrag over van dit potje naar een ander potje. Het saldo van de spaarrekening verandert niet.")
                Button("Bewerk", action: onEdit)
                    .keyboardShortcut("e", modifiers: .command)
                    .help("Naam, soort, eigenaar, beginbedrag en spaardoel wijzigen (⌘E)")
                if !pot.archived && !pot.balance.isNegative {
                    Button(pot.balance.isZero ? "Opheffen" : "Opheffen…", action: onArchive)
                        .help("Het potje verdwijnt uit de lijst; de boekingen blijven bewaard. Staat er nog geld in, dan kies je waar het heen gaat.")
                }
            }
            .controlSize(.regular)
        }
    }

    private var subtitle: String {
        if pot.balance.isNegative { return "Dit potje staat in de min · \(accountName)" }
        return "Saldo op \(asOf.short(withYear: true)) · \(accountName)"
    }

    private func fact(_ title: String, _ value: String, tint: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Text(value).font(.callout.weight(.medium)).monospacedDigit().foregroundStyle(tint)
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Grafiek

    private var chart: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Saldoverloop").font(.headline)
            Chart {
                ForEach(points) { point in
                    AreaMark(x: .value("Datum", point.date), y: .value("Saldo", point.balance))
                        .interpolationMethod(.stepEnd)
                        .foregroundStyle(LinearGradient(colors: [Theme.accent.opacity(0.28), Theme.accent.opacity(0.03)],
                                                        startPoint: .top, endPoint: .bottom))
                    LineMark(x: .value("Datum", point.date), y: .value("Saldo", point.balance))
                        .interpolationMethod(.stepEnd)
                        .foregroundStyle(Theme.accent)
                        .lineStyle(StrokeStyle(lineWidth: 1.8))
                }
                if let target = pot.targetAmount, target > .zero {
                    RuleMark(y: .value("Doel", target.doubleValue))
                        .foregroundStyle(Theme.info.opacity(0.7))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .annotation(position: .bottom, alignment: .trailing, spacing: 2) {
                            Text("doel").font(.caption2).foregroundStyle(Theme.info)
                        }
                }
                if points.contains(where: { $0.balance < 0 }) {
                    RuleMark(y: .value("Nul", 0)).foregroundStyle(Theme.negative.opacity(0.6))
                        .lineStyle(StrokeStyle(lineWidth: 1))
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine().foregroundStyle(Theme.hairline.opacity(0.5))
                    AxisValueLabel {
                        if let v = value.as(Double.self) {
                            Text(PotsFormat.wholeEuros(v)).monospacedDigit()
                        }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 5)) { value in
                    AxisGridLine().foregroundStyle(Theme.hairline.opacity(0.3))
                    AxisValueLabel {
                        if let date = value.as(Date.self) {
                            Text(Day(date: date).short())
                        }
                    }
                }
            }
            .frame(height: 150)
            .accessibilityLabel("Saldo van het potje \(pot.name) in de tijd")
        }
    }

    // MARK: Mutaties

    private var movements: some View {
        let rows = Array(history.reversed())
        let shown = showAllMovements ? rows : Array(rows.prefix(5))
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Mutaties").font(.headline)
                Text("\(history.count)").font(.callout).monospacedDigit().foregroundStyle(.secondary)
                Spacer()
                Text("saldo erna").font(.caption).foregroundStyle(.secondary)
                    .help("Het saldo van het potje direct na deze boeking.")
            }
            .padding(.bottom, 6)
            ForEach(shown) { row in
                Divider()
                movementRow(row)
            }
            if rows.count > 5 {
                Divider()
                Button(showAllMovements ? "Toon minder" : "Toon alle \(rows.count) mutaties") { showAllMovements.toggle() }
                    .buttonStyle(.plain).foregroundStyle(Theme.accent).font(.callout)
                    .padding(.top, 8)
            }
        }
    }

    private func movementRow(_ row: PotHistoryRow) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(row.entry.day.short(withYear: row.entry.day.year != asOf.year))
                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                .frame(width: 58, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.entry.label.isEmpty ? "Zonder omschrijving" : row.entry.label).lineLimit(1)
                if row.entry.bankTransactionId == nil {
                    Text("handmatig").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 1) {
                MoneyText(row.entry.amount, alwaysSign: true)
                Text(row.runningBalance.formatted(symbol: false))
                    .font(.caption).monospacedDigit()
                    .foregroundStyle(row.runningBalance.isNegative ? Theme.negative : Color.secondary)
            }
        }
        .font(.callout)
        .padding(.vertical, 6)
        .help(row.entry.note.isEmpty ? row.entry.day.dutch : "\(row.entry.day.dutch) · \(row.entry.note)")
    }
}
