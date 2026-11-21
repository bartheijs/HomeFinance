import SwiftUI
import HFCore
import HFInsight

/// Rustig vlak zonder rand.
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

/// Eén open boeking met vinkje en potkeuze.
struct ReimbOpenRow: View {
    let entry: EntryRow
    let selected: Bool
    let pots: [PotSummary]
    var toggle: () -> Void
    var setPot: (Int64?) -> Void
    var stopSettling: () -> Void
    @State private var hovering = false

    private var incoming: Bool { entry.amount > .zero }

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
            MoneyText(entry.amount, alwaysSign: incoming)
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
            Button("Niet meer bij Nog overboeken", systemImage: "xmark.circle", action: stopSettling)
        }
    }

    private var detail: String? {
        var parts: [String] = [entry.accountName]
        if let name = entry.bank?.counterpartyName, !name.isEmpty, name != entry.label { parts.append(name) }
        if let item = entry.itemLabel { parts.append(item) }
        if !entry.tags.isEmpty { parts.append(entry.tags.map(\.name).joined(separator: ", ")) }
        return parts.joined(separator: " · ")
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
                Text(incoming ? "naar pot \(name)" : "uit pot \(name)").foregroundStyle(.secondary)
            } else {
                Label("Kies een pot…", systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(incoming ? "De pot op de spaarrekening waar dit bedrag naartoe gaat."
              : "De pot op de spaarrekening die deze uitgave betaalt.")
    }
}

/// Wat elke pot uit gaat of in komt, met het saldo erna.
struct ReimbPerPotList: View {
    let shares: [ReimbPotShare]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(shares.enumerated()), id: \.element.id) { index, share in
                if index > 0 { Divider().padding(.leading, 18) }
                HStack(spacing: 12) {
                    Text(share.potName ?? "Nog geen pot gekozen")
                        .foregroundStyle(share.potId == nil ? Theme.warning : Color.primary)
                        .lineLimit(1)
                    Spacer(minLength: 12)
                    Text(movement(share)).monospacedDigit()
                    Group {
                        if let after = share.balanceAfter {
                            Text("saldo erna \(after.formatted())").monospacedDigit()
                                .foregroundStyle(after.isNegative ? Theme.warning : Color.secondary)
                        } else {
                            Text("")
                        }
                    }
                    .font(.callout)
                    .frame(width: 180, alignment: .trailing)
                }
                .font(.body)
                .padding(.horizontal, 18).padding(.vertical, 8)
                .help(ReimbFormat.bookings(share.count))
            }
        }
    }

    private func movement(_ share: ReimbPotShare) -> String {
        if share.amount.isZero { return "per saldo niets" }
        return share.amount > .zero ? "\(share.amount.formatted()) eruit" : "\(share.amount.magnitude.formatted()) erbij"
    }
}

/// Eén eerdere verrekening, uitklapbaar naar de boekingen en de potmutaties.
struct ReimbHistoryRow: View {
    let transfer: SavingsTransferDetail
    /// Na 5 dagen nog niet in een bankbestand gezien.
    let unconfirmed: Bool
    let expanded: Bool
    var toggle: () -> Void
    var onUndo: () -> Void
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
                    Text(ReimbFormat.bookings(transfer.entries.count)).font(.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength: 6)
                status
                VStack(alignment: .trailing, spacing: 2) {
                    MoneyText(transfer.transferAmount)
                    Text(ReimbFormat.direction(transfer.direction)).font(.callout).foregroundStyle(.secondary)
                }
                .frame(width: 170, alignment: .trailing)
                Menu {
                    Button("Ongedaan maken…", systemImage: "arrow.uturn.backward", role: .destructive, action: onUndo)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("Overboeking ongedaan maken")
            }
            .font(.body)
            .padding(.horizontal, 18).padding(.vertical, 9)
            .background(hovering ? Color.primary.opacity(0.04) : .clear)
            .contentShape(Rectangle())
            .onTapGesture(perform: toggle)
            .onHover { hovering = $0 }

            if expanded { details }
        }
    }

    @ViewBuilder private var status: some View {
        if transfer.direction == .none {
            Text("geen overboeking nodig").font(.callout).foregroundStyle(.secondary)
                .help("Per saldo hoefde er niets overgemaakt te worden; alleen de potten zijn bijgewerkt.")
        } else if transfer.bankConfirmed {
            Label("gezien in de bank", systemImage: "checkmark").font(.callout).foregroundStyle(.secondary)
                .help("De overboeking is aan beide kanten in een bankbestand herkend.")
        } else if unconfirmed {
            Label("nog niet gezien in een bankbestand", systemImage: "exclamationmark.triangle.fill")
                .font(.callout).foregroundStyle(Theme.warning)
                .help(bankHelp + " Het is al meer dan 5 dagen geleden: heb je het bedrag echt overgemaakt, en heb je daarna geïmporteerd?")
        } else {
            Label("wacht op de bank", systemImage: "clock").font(.callout).foregroundStyle(.secondary)
                .help(bankHelp)
        }
    }

    private var bankHelp: String {
        switch (transfer.checkingBankConfirmed, transfer.savingsBankConfirmed) {
        case (true, false): "Gezien op de betaalrekening, nog niet op de spaarrekening. De app herkent de banktransactie bij je volgende import."
        case (false, true): "Gezien op de spaarrekening, nog niet op de betaalrekening. De app herkent de banktransactie bij je volgende import."
        default: "De app herkent de overboeking bij je volgende import en koppelt hem aan deze overboeking."
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Overgeboekte boekingen").font(.callout.weight(.medium)).foregroundStyle(.secondary).padding(.bottom, 2)
            ForEach(transfer.entries) { entry in
                line(entry.day, entry.label.isEmpty ? "Zonder omschrijving" : entry.label,
                     entry.potName.map { entry.amount > .zero ? "naar pot \($0)" : "uit pot \($0)" } ?? "geen pot", entry.amount)
            }
            if !transfer.potEntries.isEmpty {
                Text("Geboekt op de spaarrekening").font(.callout.weight(.medium)).foregroundStyle(.secondary)
                    .padding(.top, 10).padding(.bottom, 2)
                ForEach(transfer.potEntries) { entry in
                    line(entry.day, entry.potName ?? "Zonder pot", entry.label, entry.amount)
                }
            }
            if !transfer.note.isEmpty {
                Text(transfer.note).font(.callout).foregroundStyle(.secondary).padding(.top, 6)
            }
        }
        .padding(.leading, 40).padding(.trailing, 50).padding(.bottom, 12)
    }

    private func line(_ day: Day, _ title: String, _ subtitle: String, _ amount: Money) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(day.short()).monospacedDigit().foregroundStyle(.secondary).frame(width: 50, alignment: .leading)
            VStack(alignment: .leading, spacing: 0) {
                Text(title).lineLimit(1)
                Text(subtitle).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            MoneyText(amount, alwaysSign: true)
        }
        .font(.callout)
        .padding(.vertical, 4)
    }
}
