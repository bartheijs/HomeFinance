import SwiftUI
import HFCore
import HFInsight

/// Kaart zonder binnenmarge.
struct ReimbPanel<Content: View>: View {
    var tint: Color?
    @ViewBuilder var content: Content

    init(tint: Color? = nil, @ViewBuilder content: () -> Content) {
        self.tint = tint; self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background((tint ?? Color.primary).opacity(tint == nil ? 0.035 : 0.1),
                        in: RoundedRectangle(cornerRadius: Theme.cardRadius))
            .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius))
    }
}

/// "uit pot Auto € 412,00 · uit pot Kleding € 80,00"
struct ReimbShareLine: View {
    let shares: [ReimbPotShare]

    var body: some View {
        ReimbFlowLayout(spacing: 18, lineSpacing: 4) {
            ForEach(shares) { share in
                HStack(spacing: 6) {
                    Text(share.title)
                    Text(share.amount.formatted()).monospacedDigit().foregroundStyle(.primary)
                }
                .font(.body)
                .lineLimit(1)
                .foregroundStyle(share.potId == nil ? AnyShapeStyle(Theme.warning) : AnyShapeStyle(.secondary))
                .help(share.potId == nil
                      ? "Bij \(ReimbFormat.expenses(share.count)) is nog niet gekozen welke pot betaalt. Kies de pot in de lijst."
                      : "\(ReimbFormat.expenses(share.count)) uit deze pot.")
            }
        }
    }
}

/// Opdracht voor de bank-app bij een vastgelegde, nog niet uitgevoerde overboeking.
struct ReimbInstructionCard: View {
    let transfer: SavingsTransferDetail
    var onDone: () -> Void
    var onCancel: () -> Void

    var body: some View {
        ReimbPanel(tint: Theme.accent) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "iphone.gen3")
                    .font(.system(size: 26)).foregroundStyle(Theme.accent)
                    .frame(width: 34).padding(.top, 2)
                VStack(alignment: .leading, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Nu doen").font(.callout.weight(.semibold)).foregroundStyle(Theme.accent)
                        Text("Maak in je bank-app \(Text(transfer.amount.formatted()).fontWeight(.bold).monospacedDigit()) over van spaar naar betaal")
                            .font(.title3)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("Vastgelegd voor \(transfer.day.short(withYear: true)) · \(ReimbFormat.expenses(transfer.entries.count))")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    ReimbShareLine(shares: ReimbPotShare.shares(for: transfer.entries))
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 8) {
                    Button(action: onDone) { Label("Gedaan", systemImage: "checkmark") }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                        .help("Vink af zodra je het bedrag bij de bank hebt overgemaakt.")
                    Button("Toch niet…", action: onCancel)
                        .buttonStyle(.plain).font(.callout).foregroundStyle(.secondary)
                        .help("Verwijdert deze overboeking; de uitgaven staan dan weer open.")
                }
            }
            .padding(18)
            .help("Komt de opname later binnen op de spaarrekening, boek hem dan bij het nakijken op deze potten.")
        }
    }
}

/// Eén openstaande uitgave met vinkje en potkeuze.
struct ReimbOpenRow: View {
    let entry: EntryRow
    let selected: Bool
    let pots: [PotSummary]
    var toggle: () -> Void
    var setPot: (Int64?) -> Void
    var stopReimbursing: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            Toggle("Meenemen in de overboeking", isOn: Binding(get: { selected }, set: { _ in toggle() }))
                .toggleStyle(.checkbox).labelsHidden()
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.label.isEmpty ? "Zonder omschrijving" : entry.label).lineLimit(1)
                Text(entry.day.short(withYear: true)).font(.callout).monospacedDigit().foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(detail ?? "")
            potMenu
            MoneyText(entry.amount)
                .frame(width: 100, alignment: .trailing)
        }
        .font(.body)
        .opacity(selected ? 1 : 0.5)
        .padding(.horizontal, 18).padding(.vertical, 9)
        .background(hovering ? Color.primary.opacity(0.04) : .clear)
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
        .onHover { hovering = $0 }
        .contextMenu {
            Button(selected ? "Niet meenemen" : "Meenemen", action: toggle)
            Divider()
            Button("Niet meer vergoeden uit spaar", systemImage: "xmark.circle", action: stopReimbursing)
        }
    }

    private var detail: String? {
        var parts: [String] = []
        if let name = entry.bank?.counterpartyName, !name.isEmpty, name != entry.label { parts.append(name) }
        if let item = entry.itemLabel { parts.append(item) }
        if !entry.tags.isEmpty { parts.append(entry.tags.map(\.name).joined(separator: ", ")) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var potMenu: some View {
        Menu {
            ForEach(PotKind.allCases, id: \.self) { kind in
                let group = pots.filter { $0.kind == kind }
                if !group.isEmpty {
                    Section(kind == .reservering ? "Reserveringen" : "Sparen") {
                        ForEach(group) { pot in
                            Button { setPot(pot.id) } label: {
                                if pot.id == entry.potId { Label(pot.name, systemImage: "checkmark") } else { Text(pot.name) }
                            }
                        }
                    }
                }
            }
            if entry.potId != nil {
                Divider()
                Button("Geen pot") { setPot(nil) }
            }
        } label: {
            if let name = entry.potName {
                Text("uit pot \(name)").foregroundStyle(.secondary)
            } else {
                Label("Kies pot…", systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("De pot op de spaarrekening die deze uitgave betaalt.")
    }
}

/// Eén eerdere overboeking, uitklapbaar naar de uitgaven.
struct ReimbHistoryRow: View {
    let transfer: SavingsTransferDetail
    let expanded: Bool
    var toggle: () -> Void
    var onDone: () -> Void
    var onReopen: () -> Void
    var onDelete: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .frame(width: 12)
                VStack(alignment: .leading, spacing: 2) {
                    Text(transfer.day.short(withYear: true)).monospacedDigit()
                    Text(ReimbFormat.expenses(transfer.entries.count)).font(.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength: 6)
                if transfer.done {
                    Label("gedaan", systemImage: "checkmark").font(.callout).foregroundStyle(.secondary)
                        .help(transfer.doneAt.map { "Afgevinkt op \(Day(date: $0).short(withYear: true))." } ?? "Overgemaakt bij de bank.")
                } else {
                    Pill("Open", color: Theme.warning, icon: "clock")
                        .help("Vastgelegd, maar nog niet overgemaakt bij de bank.")
                }
                MoneyText(transfer.amount)
                    .frame(width: 100, alignment: .trailing)
                Menu {
                    if transfer.done {
                        Button("Heropenen…", systemImage: "arrow.uturn.backward", action: onReopen)
                    } else {
                        Button("Gedaan", systemImage: "checkmark", action: onDone)
                    }
                    Divider()
                    Button("Verwijderen…", systemImage: "trash", role: .destructive, action: onDelete)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("Heropenen of verwijderen")
            }
            .font(.body)
            .padding(.horizontal, 18).padding(.vertical, 9)
            .background(hovering ? Color.primary.opacity(0.04) : .clear)
            .contentShape(Rectangle())
            .onTapGesture(perform: toggle)
            .onHover { hovering = $0 }

            if expanded {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(transfer.entries) { entry in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(entry.day.short()).monospacedDigit().foregroundStyle(.secondary)
                                .frame(width: 46, alignment: .leading)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(entry.label.isEmpty ? "Zonder omschrijving" : entry.label).lineLimit(1)
                                Text(entry.potName.map { "uit pot \($0)" } ?? "geen pot gekozen")
                                    .foregroundStyle(entry.potName == nil ? Theme.warning : Color.secondary)
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            MoneyText(entry.amount)
                        }
                        .font(.callout)
                        .padding(.vertical, 4)
                    }
                    if !transfer.note.isEmpty {
                        Text(transfer.note).font(.caption).foregroundStyle(.secondary).padding(.top, 4)
                    }
                    if transfer.entriesTotal != -transfer.amount {
                        Label("De uitgaven tellen op tot \((-transfer.entriesTotal).formatted()), niet tot het bedrag van de overboeking.",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(Theme.warning).padding(.top, 4)
                    }
                }
                .padding(.leading, 40).padding(.trailing, 50).padding(.bottom, 10)
            }
        }
    }
}

/// Zet onderdelen achter elkaar en breekt af naar een nieuwe regel als de breedte op is.
struct ReimbFlowLayout: Layout {
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
