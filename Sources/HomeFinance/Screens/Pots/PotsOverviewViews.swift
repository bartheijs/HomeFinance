import SwiftUI
import Charts
import HFCore
import HFInsight

// MARK: - Vlak

/// Kaart zonder binnenmarge, voor tabellen die tot de rand lopen.
struct PotsPanel<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: Theme.cardRadius))
            .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius))
    }
}

// MARK: - Kop per spaarrekening

/// Drie getallen: saldo, in potten en niet toegewezen. De verdeling zit achter "Toon verdeling".
struct PotsAccountStrip: View {
    let account: SavingsAccountPots
    let series: [BalancePoint]
    let asOf: Day
    /// Toon de naam van de rekening (bij meer dan één spaarrekening).
    let showName: Bool
    var onSelectPot: (Int64) -> Void
    @State private var showDistribution = false

    private var activeCount: Int { account.pots.filter { !$0.archived }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if showName { Text(account.name).font(.headline) }
            HStack(alignment: .top, spacing: 40) {
                figure("Op de spaarrekening", amount: account.balance, caption: "t/m \(asOf.short())",
                       help: "Het saldo van de spaarrekening: het beginsaldo plus alle boekingen tot en met vandaag.")
                figure("In potten", amount: account.potTotal,
                       caption: activeCount == 1 ? "1 pot" : "\(activeCount) potten",
                       help: "De som van alle potten op deze rekening.")
                unallocated
                if account.negativePotCount > 0 {
                    figure("Geleend uit andere potten", amount: account.borrowedFromOtherPots,
                           caption: account.negativePotCount == 1 ? "1 pot in de min" : "\(account.negativePotCount) potten in de min",
                           help: "Potten die in de min staan lenen van je andere potten. Het geld staat nog op de spaarrekening, maar met een ander doel.")
                }
                Spacer(minLength: 0)
            }
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { showDistribution.toggle() }
            } label: {
                Label(showDistribution ? "Verberg verdeling" : "Toon verdeling",
                      systemImage: showDistribution ? "chevron.up" : "chart.bar.xaxis")
            }
            .buttonStyle(.plain).foregroundStyle(Theme.accent)
            .help("Laat zien hoe het spaarsaldo over de potten verdeeld is en hoe het saldo dit jaar verliep.")

            if showDistribution {
                VStack(alignment: .leading, spacing: 16) {
                    PotsDistributionBar(slices: PotsSlice.slices(for: account), onSelectPot: onSelectPot)
                    if series.count > 1 { balanceChart }
                }
                .padding(18)
                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: Theme.cardRadius))
            }
        }
    }

    private func figure(_ title: String, amount: Money, caption: String, help: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.body).foregroundStyle(.secondary).lineLimit(1)
            Text(amount.formatted())
                .font(.system(size: 28, weight: .semibold, design: .rounded)).monospacedDigit()
                .foregroundStyle(amount.isNegative ? Theme.negative : Color.primary)
                .lineLimit(1).minimumScaleFactor(0.7)
            Text(caption).font(.callout).foregroundStyle(.secondary).lineLimit(1)
        }
        .help(help)
    }

    private var unallocated: some View {
        let isZero = account.unallocated.isZero
        return VStack(alignment: .leading, spacing: 4) {
            Text("Niet toegewezen").font(.body).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Text(account.unallocated.formatted())
                    .font(.system(size: 28, weight: .semibold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(isZero ? Color.primary : Theme.warning)
                    .lineLimit(1).minimumScaleFactor(0.7)
                if !isZero {
                    Image(systemName: "exclamationmark.triangle.fill").font(.title3).foregroundStyle(Theme.warning)
                }
            }
            Text(isZero ? "elke euro heeft een pot"
                 : (account.unallocated.isNegative ? "de potten zijn samen meer dan het saldo" : "dit geld heeft nog geen pot"))
                .font(.callout).foregroundStyle(isZero ? AnyShapeStyle(.secondary) : AnyShapeStyle(Theme.warning)).lineLimit(1)
        }
        .help("Niet toegewezen = saldo van de spaarrekening − de som van de potten. Dit hoort € 0,00 te zijn: dan heeft elke euro op de spaarrekening een pot. Is het positief, wijs dan de boekingen zonder pot aan een pot toe. Is het negatief, dan zit er in de potten meer dan er op de rekening staat.")
    }

    private var balanceChart: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Saldo van de spaarrekening in \(String(asOf.year))").font(.callout).foregroundStyle(.secondary)
            Chart(series) { point in
                LineMark(x: .value("Dag", point.day.date), y: .value("Saldo", point.balance.doubleValue))
                    .foregroundStyle(Theme.accent)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                    .interpolationMethod(.monotone)
            }
            .chartYScale(domain: .automatic(includesZero: false))
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine().foregroundStyle(Theme.hairline.opacity(0.4))
                    AxisValueLabel {
                        if let v = value.as(Double.self) { Text(PotsFormat.wholeEuros(v)).monospacedDigit() }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 6)) { value in
                    AxisValueLabel {
                        if let date = value.as(Date.self) { Text(Day.monthNamesShort[Day(date: date).month - 1]) }
                    }
                }
            }
            .frame(height: 110)
        }
    }
}

/// Liggende balk: hoe het spaarsaldo over de potten verdeeld is.
struct PotsDistributionBar: View {
    let slices: [PotsSlice]
    var onSelectPot: (Int64) -> Void

    var body: some View {
        if slices.isEmpty {
            Text("Er staat nog geen geld in de potten.").font(.caption).foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                GeometryReader { geo in
                    let gap: CGFloat = 2
                    let usable = max(0, geo.size.width - gap * CGFloat(slices.count - 1))
                    HStack(spacing: gap) {
                        ForEach(slices) { slice in
                            Rectangle()
                                .fill(slice.color)
                                .frame(width: max(2, usable * slice.share))
                                .help("\(slice.name): \(slice.amount.formatted()) (\(PotsFormat.percent(slice.share)))")
                                .onTapGesture { if let id = slice.potId { onSelectPot(id) } }
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                }
                .frame(height: 10)
                .accessibilityLabel("Verdeling van het spaarsaldo over de potten")

                PotsFlowLayout(spacing: 16, lineSpacing: 6) {
                    ForEach(slices) { slice in
                        HStack(spacing: 5) {
                            Circle().fill(slice.color).frame(width: 8, height: 8)
                            Text(slice.name).foregroundStyle(.secondary)
                            Text(PotsFormat.percent(slice.share)).monospacedDigit()
                        }
                        .font(.callout)
                        .lineLimit(1)
                        .help(slice.amount.formatted())
                    }
                }
            }
        }
    }
}

/// Zet onderdelen achter elkaar en breekt af naar een nieuwe regel als de breedte op is.
struct PotsFlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        return CGSize(width: proposal.width ?? rows.width, height: rows.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(width: bounds.width, subviews: subviews)
        for (index, point) in result.points.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y),
                                  proposal: .unspecified)
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (points: [CGPoint], width: CGFloat, height: CGFloat) {
        var points: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, maxX: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width {
                x = 0; y += lineHeight + lineSpacing; lineHeight = 0
            }
            points.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            maxX = max(maxX, x - spacing)
        }
        return (points, maxX, y + lineHeight)
    }
}

// MARK: - Lijst met potten

/// Kop van een inklapbare groep: naam, aantal en het totaal.
struct PotsGroupHeader: View {
    let title: String
    let explanation: String
    let pots: [PotSummary]
    let expanded: Bool
    var toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "chevron.right")
                    .font(.callout.weight(.semibold)).foregroundStyle(.secondary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .frame(width: 14)
                Text(title).font(.title3.weight(.semibold))
                Text(pots.count == 1 ? "1 pot" : "\(pots.count) potten").font(.callout).foregroundStyle(.secondary)
                Spacer(minLength: 12)
                Text(pots.map(\.balance).sum().formatted())
                    .font(.title3.weight(.semibold)).monospacedDigit()
            }
            .padding(.horizontal, 18).padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(explanation) Klik om de groep in of uit te klappen.")
    }
}

/// Tussenkopje met de eigenaar van een groepje spaarpotten.
struct PotsOwnerLabel: View {
    let owner: String?
    var body: some View {
        Text(owner ?? "Gezamenlijk")
            .font(.callout.weight(.medium)).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18).padding(.top, 12).padding(.bottom, 2)
    }
}

/// Eén pot: naam en saldo, met een dunne balk als de pot een doel heeft.
struct PotsRowView: View {
    let pot: PotSummary
    let selected: Bool
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Text(pot.name).lineLimit(1).truncationMode(.tail)
                        if pot.archived { Text("gearchiveerd").font(.callout).foregroundStyle(.tertiary) }
                    }
                    if !pot.pendingSettlement.isZero {
                        Text(PotsFormat.pending(pot.pendingSettlement))
                            .font(.callout).foregroundStyle(.secondary).lineLimit(1)
                            .help("Er staan boekingen op de betaalrekening open die nog met deze pot verrekend moeten worden. Dat doe je bij Verrekenen met spaar.")
                    }
                    if let recovery = pot.recovery {
                        Text(PotsRecoveryText.line(recovery))
                            .font(.callout)
                            .foregroundStyle(recovery.status == .herstelt ? Color.secondary : Theme.warning)
                            .lineLimit(1)
                            .help("Deze pot staat in de min: het geld is geleend van je andere potten.")
                    } else if let goal = pot.goal {
                        HStack(spacing: 10) {
                            PotsTargetBar(pot: pot, barOnly: true).frame(width: 140)
                            Text(PotsGoalText.line(goal))
                                .font(.callout)
                                .foregroundStyle(PotsGoalText.needsAttention(goal) ? Theme.warning : Color.secondary)
                                .lineLimit(1)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(pot.balance.formatted())
                    .monospacedDigit()
                    .foregroundStyle(pot.balance.isNegative ? Theme.warning : Color.primary)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.quaternary)
            }
            .font(.body)
            .padding(.horizontal, 18).padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(selected ? Theme.accent.opacity(0.12) : (hovering ? Color.primary.opacity(0.04) : .clear))
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help("Klik voor het verloop, de mutaties en de acties van deze pot.")
    }
}

/// Voortgang naar het doelbedrag van een pot.
struct PotsTargetBar: View {
    let pot: PotSummary
    /// Toont ook het doelbedrag als tekst.
    var showTarget = false
    /// Alleen de balk, zonder percentage.
    var barOnly = false

    var body: some View {
        if let progress = pot.progress, let target = pot.targetAmount {
            HStack(spacing: 8) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.08))
                        Capsule().fill(progress >= 1 ? Theme.positive : Theme.accent.opacity(0.75))
                            .frame(width: max(4, geo.size.width * min(1, max(0, progress))))
                    }
                }
                .frame(height: 4)
                if !barOnly {
                Text(showTarget ? "\(PotsFormat.percent(progress)) van \(PotsFormat.wholeEuros(target.doubleValue))"
                     : PotsFormat.percent(progress))
                    .font(.callout).monospacedDigit().foregroundStyle(.secondary)
                    .fixedSize()
                }
            }
            .help(progress >= 1
                  ? "Doel van \(target.formatted()) gehaald."
                  : "Doel \(target.formatted()); nog \((pot.remainingToTarget ?? .zero).formatted()) te gaan.")
        }
    }
}

// MARK: - Boekingen zonder pot

/// Compacte melding; de lijst komt pas na "Wijs toe…".
struct PotsUnallocatedCard: View {
    let entries: [EntryRow]
    let distributable: Set<Int64>
    let pots: [PotSummary]
    var assign: (EntryRow, Int64) -> Void
    var distribute: (EntryRow) -> Void
    @State private var expanded = false

    var body: some View {
        PotsPanel {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
                Text(entries.count == 1 ? "1 boeking op de spaarrekening heeft nog geen pot"
                     : "\(entries.count) boekingen op de spaarrekening hebben nog geen pot")
                    .font(.body)
                Spacer(minLength: 12)
                Button(expanded ? "Sluit" : "Wijs toe…") {
                    withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
                }
                .help("Kies per boeking de pot waar het geld bij hoort.")
            }
            .padding(.horizontal, 18).padding(.vertical, 12)

            if expanded {
                ForEach(entries) { entry in
                    Divider().padding(.leading, 18)
                    row(entry)
                }
            }
        }
    }

    private func row(_ entry: EntryRow) -> some View {
        HStack(spacing: 14) {
            Text(entry.day.short(withYear: true))
                .monospacedDigit().foregroundStyle(.secondary)
                .frame(width: 100, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.label.isEmpty ? "Zonder omschrijving" : entry.label).lineLimit(1)
                if let name = entry.bank?.counterpartyName, !name.isEmpty, name != entry.label {
                    Text(name).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            MoneyText(entry.amount, alwaysSign: true)
            if distributable.contains(entry.id) {
                Button("Verdeel") { distribute(entry) }
                    .help("Dit bedrag is precies de som van de maandbedragen van de reserveringspotten. Verdeel het in één keer: elke pot krijgt zijn maandbedrag.")
            }
            Menu {
                let own = pots.filter { $0.accountId == entry.accountId && !$0.archived }
                ForEach(PotKind.allCases, id: \.self) { kind in
                    let group = Insight.pickerOrder(own.filter { $0.kind == kind })
                    if !group.isEmpty {
                        Section(kind == .reservering ? "Reserveringen" : "Sparen") {
                            ForEach(group) { pot in
                                Button(pot.name) { assign(entry, pot.id) }
                            }
                        }
                    }
                }
            } label: {
                Text("Kies pot…")
            }
            .fixedSize()
            .help("Wijs deze boeking toe aan een pot.")
        }
        .font(.body)
        .padding(.horizontal, 18).padding(.vertical, 9)
    }
}

// MARK: - Boekingen die elkaar opheffen

/// Eén rustige, grijze regel: deze boekingen hebben geen pot nodig. Geen waarschuwing.
struct PotsCancelledLine: View {
    let pairs: [CancelledPair]
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    Text(pairs.count == 1 ? "2 boekingen heffen elkaar op en hebben geen pot nodig"
                         : "\(pairs.count * 2) boekingen heffen elkaar op en hebben geen pot nodig")
                }
                .font(.callout).foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Twee boekingen zonder pot met precies tegengestelde bedragen strepen elkaar weg. Ze veranderen niets aan de verdeling over de potten.")

            if expanded {
                VStack(spacing: 0) {
                    ForEach(pairs) { pair in
                        VStack(spacing: 0) {
                            line(pair.first)
                            line(pair.second)
                        }
                        .padding(.vertical, 4)
                        if pair.id != pairs.last?.id { Divider() }
                    }
                }
                .padding(.leading, 20)
            }
        }
    }

    private func line(_ entry: EntryRow) -> some View {
        HStack(spacing: 12) {
            Text(entry.day.short(withYear: true)).monospacedDigit().frame(width: 100, alignment: .leading)
            Text(entry.label.isEmpty ? "Zonder omschrijving" : entry.label).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(entry.amount.formatted(alwaysSign: true)).monospacedDigit()
        }
        .font(.callout).foregroundStyle(.secondary)
        .padding(.vertical, 2)
    }
}

// MARK: - Beginstand

/// Rustig blok zolang er nog niets geïmporteerd is: potten + niet toegewezen = rekening.
struct PotsOpeningBlock: View {
    let opening: OpeningOverview
    let showName: Bool
    var review: () -> Void

    var body: some View {
        PotsPanel {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(showName ? "Beginstand \(opening.accountName)" : "Beginstand").font(.callout).foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        Text("potten").foregroundStyle(.secondary)
                        Text(opening.potTotal.formatted()).monospacedDigit()
                        Text("+ niet toegewezen").foregroundStyle(.secondary)
                        Text(opening.unallocated.formatted()).monospacedDigit()
                            .foregroundStyle(opening.unallocated.isZero ? Color.primary : Theme.warning)
                        Text("= rekening").foregroundStyle(.secondary)
                        Text(opening.total.formatted()).monospacedDigit().fontWeight(.semibold)
                    }
                    .font(.body)
                    .lineLimit(1).minimumScaleFactor(0.8)
                }
                Spacer(minLength: 12)
                Button("Beginbedragen nalopen", action: review)
                    .help("Vul per pot in wat erin zat op \(opening.openingDate.short(withYear: true)), de dag waarop je met deze rekening in de app begon.")
            }
            .padding(.horizontal, 18).padding(.vertical, 12)
        }
        .help("Dit blok verdwijnt zodra je de eerste transacties van deze spaarrekening hebt geïmporteerd.")
    }
}
