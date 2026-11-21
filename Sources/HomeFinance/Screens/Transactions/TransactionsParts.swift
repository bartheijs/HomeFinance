import SwiftUI
import HFCore
import HFInsight

/// Zet onderdelen achter elkaar en breekt af naar een volgende regel als de breedte op is.
struct TransactionsFlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + CGFloat(max(rows.count - 1, 0)) * spacing
        return CGSize(width: proposal.width.map { min($0, max(width, 0)) } ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                                      proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Line { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Line] {
        var lines: [Line] = []
        var current = Line()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > width, !current.indices.isEmpty {
                lines.append(current)
                current = Line(indices: [index], width: size.width, height: size.height)
            } else {
                current.indices.append(index)
                current.width = needed
                current.height = max(current.height, size.height)
            }
        }
        if !current.indices.isEmpty { lines.append(current) }
        return lines
    }
}

/// Een tag als rustig pilletje: gekleurde stip, tekst in de gewone tekstkleur (leesbaar in licht en donker).
struct TransactionsTagPill: View {
    let name: String
    let color: Color
    var compact = true

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(name).lineLimit(1)
        }
        .font(compact ? .caption : .callout)
        .padding(.horizontal, compact ? 6 : 9).padding(.vertical, compact ? 2 : 4)
        .background(color.opacity(0.16), in: Capsule())
        .fixedSize()
    }
}

/// Neutraal pilletje, bv. "Divers".
struct TransactionsSubtlePill: View {
    let text: String
    var icon: String?
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: 3) {
            if let icon { Image(systemName: icon).imageScale(.small) }
            Text(text).lineLimit(1)
        }
        .font(.caption)
        .foregroundStyle(tint)
        .padding(.horizontal, 7).padding(.vertical, 2)
        .background(tint.opacity(0.12), in: Capsule())
        .fixedSize()
    }
}

/// Vaste kleuren voor nieuwe tags.
enum TransactionsTagPalette {
    static let colors = ["#1F7A5C", "#2D6CDF", "#D98E04", "#B0447F", "#6B5BD2", "#3C9AA8", "#C0562B", "#7A8590"]
}

/// Formulier voor een nieuwe tag: naam, kleur uit een vast palet en de schakelaar Verrekenen.
/// `create` geeft terug of het gelukt is; bij een fout (bv. naam bestaat al) blijft het formulier open.
struct TransactionsNewTagForm: View {
    let tagCount: Int
    var autoFocus = true
    let create: (_ name: String, _ color: String, _ settles: Bool) -> Bool

    @State private var name = ""
    @State private var color = ""
    @State private var settles = false
    @FocusState private var focused: Bool

    private var trimmed: String { name.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Nieuwe tag").font(.headline)
            TextField("Naam, bv. Tanken", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(add)
            HStack(spacing: 8) {
                ForEach(TransactionsTagPalette.colors, id: \.self) { hex in
                    Button { color = hex } label: {
                        Circle().fill(Color(hex: hex)).frame(width: 18, height: 18)
                            .overlay(Circle().strokeBorder(Color.primary.opacity(color == hex ? 0.9 : 0), lineWidth: 2).padding(-3))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Kleur \(hex)")
                    .accessibilityAddTraits(color == hex ? .isSelected : [])
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Toggle("Krijg ik terug", isOn: $settles)
                Text("Uitgaven die je voorschiet en terugkrijgt, zoals tankkosten van je werk; wat je nog terugkrijgt zie je boven de lijst.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Maak aan", action: add)
                    .buttonStyle(.borderedProminent)
                    .disabled(trimmed.isEmpty)
            }
        }
        .padding(14)
        .frame(width: 280)
        .onAppear {
            if color.isEmpty { color = TransactionsTagPalette.colors[tagCount % TransactionsTagPalette.colors.count] }
            if autoFocus { focused = true }
        }
    }

    private func add() {
        guard !trimmed.isEmpty else { return }
        if create(trimmed, color, settles) { name = ""; settles = false }
    }
}

/// De chip "+ Nieuwe tag…" met zijn popover.
struct TransactionsNewTagChip: View {
    let tagCount: Int
    let create: (_ name: String, _ color: String, _ settles: Bool) -> Bool
    @State private var open = false

    var body: some View {
        Button { open = true } label: {
            HStack(spacing: 4) {
                Image(systemName: "plus").imageScale(.small)
                Text("Nieuwe tag…")
            }
            .font(.callout)
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 9).padding(.vertical, 3)
            .overlay(Capsule().strokeBorder(Theme.accent.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Maak een nieuwe tag en zet hem meteen op deze boeking")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            TransactionsNewTagForm(tagCount: tagCount) { name, color, settles in
                let ok = create(name, color, settles)
                if ok { open = false }
                return ok
            }
        }
    }
}

/// Tags aan- en uitzetten door erop te klikken, altijd met de chip om een nieuwe tag te maken.
struct TransactionsTagEditor: View {
    let tags: [HFCore.Tag]
    @Binding var selection: Set<Int64>
    var disabled = false
    /// Maakt een nieuwe tag; nil laat de chip weg.
    var onCreate: ((_ name: String, _ color: String, _ settles: Bool) -> Bool)?

    var body: some View {
        TransactionsFlowLayout(spacing: 6) {
            ForEach(tags) { tag in
                let id = tag.id ?? 0
                let isOn = selection.contains(id)
                let color = Color(hex: tag.color)
                Button {
                    if isOn { selection.remove(id) } else { selection.insert(id) }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                            .imageScale(.small)
                            .foregroundStyle(isOn ? color : Color.secondary.opacity(0.6))
                        Text(tag.name).lineLimit(1)
                    }
                    .font(.callout)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(isOn ? color.opacity(0.18) : Color.primary.opacity(0.05), in: Capsule())
                    .overlay(Capsule().strokeBorder(isOn ? color.opacity(0.5) : Color.clear))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(disabled)
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
            if let onCreate, !disabled {
                TransactionsNewTagChip(tagCount: tags.count, create: onCreate)
            }
        }
    }
}

/// Datumkiezer voor een `Day`.
struct TransactionsDayPicker: View {
    @Binding var day: Day

    var body: some View {
        DatePicker("Datum", selection: Binding(
            get: { Calendar.current.date(from: DateComponents(year: day.year, month: day.month, day: day.day)) ?? Date() },
            set: { day = Day(date: $0) }), displayedComponents: .date)
            .labelsHidden()
            .environment(\.locale, Locale(identifier: "nl_NL"))
    }
}

/// Bedrag met een schakelaar Uit/In, zodat je geen minteken hoeft te typen.
struct TransactionsAmountInput: View {
    @Binding var isIncome: Bool
    @Binding var magnitude: Money?

    var body: some View {
        HStack(spacing: 8) {
            Picker("Richting", selection: $isIncome) {
                Text("Uit").tag(false)
                Text("In").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Uit = uitgave (wordt negatief geboekt), In = inkomsten")
            HStack(spacing: 4) {
                Text("€").foregroundStyle(.secondary)
                MoneyField("0,00", value: $magnitude)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 80)
            }
        }
    }
}

/// Keuze van de vaste post: Divers, daarna de posten gegroepeerd in IN en UIT.
struct TransactionsItemPicker: View {
    let items: [BudgetItem]
    @Binding var selection: Int64?

    var body: some View {
        Picker("Post", selection: $selection) {
            Text("Overig (geen vaste post)").tag(Int64?.none)
            let income = items.filter { $0.direction == .IN }
            let expense = items.filter { $0.direction == .UIT }
            if !expense.isEmpty {
                Section("UIT") { ForEach(expense) { Text($0.label).tag($0.id) } }
            }
            if !income.isEmpty {
                Section("IN") { ForEach(income) { Text($0.label).tag($0.id) } }
            }
            // Een post die niet (meer) in de lijst staat toch kunnen tonen.
            if let selection, !items.contains(where: { $0.id == selection }) {
                Text("Onbekende post").tag(Optional(selection))
            }
        }
        .labelsHidden()
    }
}

/// Keuze van een pot.
struct TransactionsPotPicker: View {
    let pots: [Pot]
    let noneTitle: String
    @Binding var selection: Int64?

    var body: some View {
        Picker("Potje", selection: $selection) {
            Text(noneTitle).tag(Int64?.none)
            let reserve = pots.filter { $0.kind == .reservering }
            let saving = pots.filter { $0.kind == .spaar }
            if !reserve.isEmpty {
                Section("Reserveringspotjes") { ForEach(reserve) { Text($0.name).tag($0.id) } }
            }
            if !saving.isEmpty {
                Section("Spaarpotjes") { ForEach(saving) { Text($0.name).tag($0.id) } }
            }
            if let selection, !pots.contains(where: { $0.id == selection }) {
                Text("Onbekend potje").tag(Optional(selection))
            }
        }
        .labelsHidden()
    }
}

/// Bedrag in de lijst: inkomsten groen met een plus, uitgaven in de gewone tekstkleur.
struct TransactionsAmountText: View {
    let amount: Money

    var body: some View {
        Text(amount.formatted(alwaysSign: true))
            .monospacedDigit()
            .foregroundStyle(amount.isNegative || amount.isZero ? Color.primary : Theme.positive)
            .lineLimit(1)
    }
}

/// Rond knopje met een pictogram, voor de snelle acties.
struct TransactionsIconLabel: View {
    let icon: String
    var active = false
    var size: CGFloat = 26

    var body: some View {
        Image(systemName: icon)
            .font(.system(size: size * 0.48, weight: .medium))
            .foregroundStyle(active ? Theme.accent : Color.secondary)
            .frame(width: size, height: size)
            .background(active ? Theme.accent.opacity(0.16) : Color.primary.opacity(0.07), in: Circle())
            .contentShape(Circle())
    }
}
