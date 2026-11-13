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
            .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
            .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius))
            .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.hairline.opacity(0.6)))
    }
}

// MARK: - Kop per spaarrekening

/// Saldo − potten = niet toegewezen, met de verdeling over de potten eronder.
struct PotsAccountStrip: View {
    let account: SavingsAccountPots
    let series: [BalancePoint]
    let asOf: Day
    let selectedPotId: Int64?
    var onSelectPot: (Int64) -> Void

    private var activeCount: Int { account.pots.filter { !$0.archived }.count }

    var body: some View {
        PotsPanel {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 0) {
                    figure("Saldo \(account.name)", amount: account.balance,
                           caption: "volgens je boekingen, t/m \(asOf.short())",
                           help: "Het saldo van de spaarrekening: het beginsaldo plus alle boekingen tot en met vandaag.")
                    operatorSign("minus")
                    figure("In potten", amount: account.potTotal,
                           caption: activeCount == 1 ? "1 pot" : "\(activeCount) potten",
                           help: "De som van alle potten op deze rekening.")
                    operatorSign("equal")
                    unallocated
                    Spacer(minLength: 12)
                    if series.count > 1 { sparkline }
                }
                PotsDistributionBar(slices: PotsSlice.slices(for: account), selectedPotId: selectedPotId,
                                    onSelectPot: onSelectPot)
            }
            .padding(16)
        }
    }

    private func figure(_ title: String, amount: Money, caption: String, help: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            Text(amount.formatted())
                .font(.system(.title2, design: .rounded).weight(.semibold)).monospacedDigit()
                .foregroundStyle(amount.isNegative ? Theme.negative : Color.primary)
                .lineLimit(1).minimumScaleFactor(0.7)
            Text(caption).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .help(help)
    }

    private func operatorSign(_ name: String) -> some View {
        Image(systemName: name)
            .font(.title3.weight(.medium)).foregroundStyle(.tertiary)
            .frame(width: 44).padding(.top, 24)
            .accessibilityHidden(true)
    }

    private var unallocated: some View {
        let isZero = account.unallocated.isZero
        let tint = isZero ? Theme.positive : Theme.warning
        return VStack(alignment: .leading, spacing: 3) {
            Text("Niet toegewezen").font(.subheadline).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Text(account.unallocated.formatted())
                    .font(.system(.title2, design: .rounded).weight(.bold)).monospacedDigit()
                    .foregroundStyle(tint)
                    .lineLimit(1).minimumScaleFactor(0.7)
                Image(systemName: isZero ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(tint)
            }
            Text(isZero ? "elke euro heeft een pot"
                 : (account.unallocated.isNegative ? "de potten zijn samen meer dan het saldo" : "dit geld heeft nog geen pot"))
                .font(.caption).foregroundStyle(isZero ? Color.secondary : tint).lineLimit(1)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(tint.opacity(isZero ? 0.08 : 0.14), in: RoundedRectangle(cornerRadius: 10))
        .padding(.top, -8)
        .help("Niet toegewezen = saldo van de spaarrekening − de som van de potten. Dit hoort € 0,00 te zijn: dan heeft elke euro op de spaarrekening een pot. Is het positief, wijs dan de boekingen hieronder aan een pot toe. Is het negatief, dan zit er in de potten meer dan er op de rekening staat.")
    }

    private var sparkline: some View {
        VStack(alignment: .trailing, spacing: 3) {
            Text("Saldo in \(String(asOf.year))").font(.caption).foregroundStyle(.secondary)
            Chart(series) { point in
                AreaMark(x: .value("Dag", point.day.date), y: .value("Saldo", point.balance.doubleValue))
                    .foregroundStyle(LinearGradient(colors: [Theme.accent.opacity(0.25), Theme.accent.opacity(0.02)],
                                                    startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Dag", point.day.date), y: .value("Saldo", point.balance.doubleValue))
                    .foregroundStyle(Theme.accent)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                    .interpolationMethod(.monotone)
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartYScale(domain: .automatic(includesZero: false))
            .frame(width: 170, height: 44)
        }
        .help("Het saldo van de spaarrekening aan het eind van elke maand dit jaar.")
    }
}

/// Liggende balk: hoe het spaarsaldo over de potten verdeeld is.
struct PotsDistributionBar: View {
    let slices: [PotsSlice]
    let selectedPotId: Int64?
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
                                .opacity(selectedPotId == nil || slice.potId == nil || slice.potId == selectedPotId ? 1 : 0.45)
                                .frame(width: max(2, usable * slice.share))
                                .help("\(slice.name): \(slice.amount.formatted()) (\(PotsFormat.percent(slice.share)))")
                                .onTapGesture { if let id = slice.potId { onSelectPot(id) } }
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                }
                .frame(height: 12)
                .accessibilityLabel("Verdeling van het spaarsaldo over de potten")

                PotsFlowLayout(spacing: 14, lineSpacing: 4) {
                    ForEach(slices) { slice in
                        HStack(spacing: 5) {
                            Circle().fill(slice.color).frame(width: 8, height: 8)
                            Text(slice.name).foregroundStyle(.secondary)
                            Text(PotsFormat.percent(slice.share)).monospacedDigit()
                        }
                        .font(.caption)
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

// MARK: - Tabel met potten

/// Kolombreedtes van de pottentabel; in een smal venster vallen de jaarkolommen weg.
struct PotsColumns: Equatable {
    var compact: Bool
    var showTarget: Bool
    var year: Int

    static let balance: CGFloat = 108
    static let monthly: CGFloat = 86
    static let flow: CGFloat = 100
    static let last: CGFloat = 64
    var target: CGFloat { compact ? 110 : 170 }
}

struct PotsTableHeader: View {
    let columns: PotsColumns

    var body: some View {
        HStack(spacing: 12) {
            Text("Pot").frame(maxWidth: .infinity, alignment: .leading)
            if columns.showTarget {
                Text("Doel").frame(width: columns.target, alignment: .leading)
                    .help("Hoe ver de pot is ten opzichte van het doelbedrag.")
            }
            Text("Saldo").frame(width: PotsColumns.balance, alignment: .trailing)
                .help("Wat er nu in de pot zit: alle stortingen min alle opnames.")
            Text("Per maand").frame(width: PotsColumns.monthly, alignment: .trailing)
                .help("Het bedrag dat elke maand in deze pot gestort hoort te worden.")
            if !columns.compact {
                Text("Gestort \(String(columns.year))").frame(width: PotsColumns.flow, alignment: .trailing)
                    .help("Alles wat dit jaar in de pot is gestort.")
                Text("Opgenomen").frame(width: PotsColumns.flow, alignment: .trailing)
                    .help("Alles wat dit jaar uit de pot is gehaald.")
            }
            Text("Laatste").frame(width: PotsColumns.last, alignment: .trailing)
                .help("De datum van de laatste boeking in deze pot.")
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14).padding(.vertical, 6)
        .background(Color.primary.opacity(0.03))
    }
}

struct PotsRowView: View {
    let pot: PotSummary
    let columns: PotsColumns
    let selected: Bool
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                HStack(spacing: 6) {
                    Text(pot.name).lineLimit(1).truncationMode(.tail)
                    if pot.archived { Pill("Archief") }
                    if pot.balance.isNegative {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(Theme.negative)
                            .help("Deze pot staat negatief: er is meer uitgehaald dan erin zat. Vul hem aan vanuit een andere pot.")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if columns.showTarget {
                    PotsTargetBar(pot: pot).frame(width: columns.target, alignment: .leading)
                }
                Text(pot.balance.formatted())
                    .fontWeight(.semibold).monospacedDigit()
                    .foregroundStyle(pot.balance.isNegative ? Theme.negative : Color.primary)
                    .frame(width: PotsColumns.balance, alignment: .trailing)
                amount(pot.monthlyAmount, sign: false).frame(width: PotsColumns.monthly, alignment: .trailing)
                if !columns.compact {
                    amount(pot.depositsThisYear, sign: true, tint: Theme.positive)
                        .frame(width: PotsColumns.flow, alignment: .trailing)
                    amount(pot.withdrawalsThisYear, sign: false, tint: Theme.negative)
                        .frame(width: PotsColumns.flow, alignment: .trailing)
                }
                Text(pot.lastMovement?.short() ?? "–")
                    .monospacedDigit().foregroundStyle(.secondary)
                    .frame(width: PotsColumns.last, alignment: .trailing)
            }
            .font(.callout)
            .padding(.horizontal, 14).padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(background)
        .overlay(alignment: .leading) {
            if selected { Rectangle().fill(Theme.accent).frame(width: 3) }
        }
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var background: Color {
        if selected { return Theme.accent.opacity(0.14) }
        if hovering { return Color.primary.opacity(0.05) }
        if pot.balance.isNegative { return Theme.negative.opacity(0.07) }
        return .clear
    }

    @ViewBuilder private func amount(_ value: Money, sign: Bool, tint: Color = .primary) -> some View {
        if value.isZero {
            Text("–").foregroundStyle(.tertiary)
        } else {
            Text(value.formatted(alwaysSign: sign)).monospacedDigit().foregroundStyle(tint)
        }
    }
}

/// Voortgang naar het doelbedrag van een pot.
struct PotsTargetBar: View {
    let pot: PotSummary

    var body: some View {
        if let progress = pot.progress, let target = pot.targetAmount {
            HStack(spacing: 8) {
                ProgressView(value: min(1, max(0, progress)))
                    .progressViewStyle(.linear)
                    .tint(progress >= 1 ? Theme.positive : Theme.accent)
                Text(PotsFormat.percent(progress))
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    .frame(width: 36, alignment: .trailing)
            }
            .help(progress >= 1
                  ? "Doel van \(target.formatted()) gehaald."
                  : "Doel \(target.formatted()); nog \((pot.remainingToTarget ?? .zero).formatted()) te gaan.")
        } else {
            Text("geen doel").font(.caption).foregroundStyle(.tertiary)
        }
    }
}

/// Totaalregel of tussentotaal onder een groep potten.
struct PotsTotalRow: View {
    let title: String
    let pots: [PotSummary]
    let columns: PotsColumns
    var strong = true

    var body: some View {
        HStack(spacing: 12) {
            Text(title).frame(maxWidth: .infinity, alignment: .leading)
            if columns.showTarget { Color.clear.frame(width: columns.target, height: 1) }
            Text(pots.map(\.balance).sum().formatted())
                .frame(width: PotsColumns.balance, alignment: .trailing)
            Text(pots.map(\.monthlyAmount).sum().formatted())
                .frame(width: PotsColumns.monthly, alignment: .trailing)
            if !columns.compact {
                Text(pots.map(\.depositsThisYear).sum().formatted(alwaysSign: true))
                    .frame(width: PotsColumns.flow, alignment: .trailing)
                Text(pots.map(\.withdrawalsThisYear).sum().formatted())
                    .frame(width: PotsColumns.flow, alignment: .trailing)
            }
            Color.clear.frame(width: PotsColumns.last, height: 1)
        }
        .font(.callout.weight(strong ? .semibold : .medium))
        .monospacedDigit()
        .foregroundStyle(strong ? Color.primary : Color.secondary)
        .padding(.horizontal, 14).padding(.vertical, strong ? 8 : 5)
        .background(Color.primary.opacity(strong ? 0.04 : 0.0))
    }
}

/// Titelregel boven een tabel.
struct PotsSectionTitle: View {
    let title: String
    let count: Int
    let explanation: String
    let icon: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Label {
                Text(title).font(.headline)
            } icon: {
                Image(systemName: icon).foregroundStyle(Theme.accent)
            }
            Text("\(count)").font(.caption.weight(.medium)).monospacedDigit()
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(.quaternary, in: Capsule())
            Text(explanation).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 10)
    }
}

// MARK: - Boekingen zonder pot

struct PotsUnallocatedCard: View {
    let entries: [EntryRow]
    let distributable: Set<Int64>
    let pots: [PotSummary]
    var assign: (EntryRow, Int64) -> Void
    var distribute: (EntryRow) -> Void
    @State private var showAll = false

    private var visible: [EntryRow] { showAll ? entries : Array(entries.prefix(4)) }

    var body: some View {
        PotsPanel {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label {
                    Text("Niet toegewezen boekingen").font(.headline)
                } icon: {
                    Image(systemName: "tray.full").foregroundStyle(Theme.warning)
                }
                Text("\(entries.count)").font(.caption.weight(.medium)).monospacedDigit()
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Theme.warning.opacity(0.2), in: Capsule())
                Text("Kies per boeking de pot waar het geld bij hoort.")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 0)
                if entries.count > 4 {
                    Button(showAll ? "Toon minder" : "Toon alle \(entries.count)") { showAll.toggle() }
                        .buttonStyle(.link).font(.caption)
                }
            }
            .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 8)

            ForEach(visible) { entry in
                Divider().padding(.leading, 14)
                row(entry)
            }
        }
    }

    private func row(_ entry: EntryRow) -> some View {
        HStack(spacing: 12) {
            Text(entry.day.short(withYear: true))
                .monospacedDigit().foregroundStyle(.secondary)
                .frame(width: 92, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.label.isEmpty ? "Zonder omschrijving" : entry.label).lineLimit(1)
                if let name = entry.bank?.counterpartyName, !name.isEmpty, name != entry.label {
                    Text(name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            MoneyText(entry.amount, colored: true, alwaysSign: true)
                .frame(width: 104, alignment: .trailing)
            if distributable.contains(entry.id) {
                Button("Verdeel") { distribute(entry) }
                    .controlSize(.small)
                    .help("Dit bedrag is precies de som van de maandbedragen van de reserveringspotten. Verdeel het in één keer: elke pot krijgt zijn maandbedrag.")
            }
            Menu {
                let own = pots.filter { $0.accountId == entry.accountId && !$0.archived }
                ForEach(PotKind.allCases, id: \.self) { kind in
                    let group = own.filter { $0.kind == kind }
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
            .controlSize(.small)
            .fixedSize()
            .help("Wijs deze boeking toe aan een pot.")
        }
        .font(.callout)
        .padding(.horizontal, 14).padding(.vertical, 6)
    }
}
