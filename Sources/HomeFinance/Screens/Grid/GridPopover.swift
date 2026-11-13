import SwiftUI
import GRDB
import HFCore
import HFInsight
import HFBudget

/// Venstertje bij een cel: de boekingen erachter.
struct GridCellPopover: View {
    @Environment(AppModel.self) private var model

    var target: GridTarget
    var options: GridOptions
    /// Maandtotaal uit het grid (HFInsight).
    var total: Money
    var onAdd: () -> Void
    var onShowTransactions: () -> Void

    @State private var entries: [EntryRow] = []
    @State private var loaded = false

    private var cell: GridCell? {
        if case .item(let row) = target.kind { return row.cells.first { $0.month == target.month } }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(target.title).font(.headline)
                Text("\(Day.monthNames[target.month - 1].capitalized) \(String(options.year))")
                    .font(.subheadline).foregroundStyle(.secondary)
            }

            if let cell {
                HStack(spacing: 16) {
                    figure("Plan", cell.expected?.formatted() ?? "niet verwacht")
                    figure("Geboekt", cell.entryCount > 0 ? cell.sum.formatted() : "–")
                    if cell.entryCount > 0, cell.expected != nil {
                        figure("Verschil", cell.difference.isZero ? "geen" : cell.difference.formatted(alwaysSign: true),
                               color: cell.difference.isZero ? .secondary : (cell.difference.isNegative ? Theme.negative : Theme.positive))
                    }
                    Spacer(minLength: 0)
                    if !(options.isFuture(cell.month) && cell.entryCount == 0) {
                        Pill(cell.status.gridTitle, color: statusColor(cell.status))
                    }
                }
            }

            Divider()

            if entries.isEmpty {
                Text(loaded ? emptyText : " ")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(entries) { entry in
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Text(entry.day.short())
                                    .monospacedDigit().foregroundStyle(.secondary)
                                    .frame(width: 46, alignment: .leading)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(entry.label.isEmpty ? "(zonder omschrijving)" : entry.label).lineLimit(1)
                                    Text(detail(entry)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer(minLength: 8)
                                MoneyText(entry.amount, colored: true, symbol: false)
                            }
                            .font(.callout)
                            .padding(.vertical, 5)
                            if entry.id != entries.last?.id { Divider().opacity(0.5) }
                        }
                    }
                }
                .frame(maxHeight: 260)
                if entries.count > 1 {
                    HStack {
                        Text("\(entries.count) boekingen").foregroundStyle(.secondary)
                        Spacer()
                        MoneyText(total, symbol: false).fontWeight(.semibold)
                    }
                    .font(.callout)
                }
            }

            HStack {
                if case .item = target.kind {
                    Button("Boeking toevoegen…", action: onAdd)
                        .disabled(!options.editable)
                        .help(options.editable ? "Voeg met de hand een boeking toe voor deze post en maand."
                              : "Dit jaar is afgesloten; boekingen toevoegen kan niet.")
                }
                Spacer()
                Button("Toon in Transacties", action: onShowTransactions)
                    .keyboardShortcut(.defaultAction)
                    .help("Open het scherm Transacties om boekingen te zoeken en te wijzigen.")
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(width: 400)
        .task(id: model.revision) { load() }
    }

    private var emptyText: String {
        switch target.kind {
        case .item: "Nog geen boekingen in deze maand."
        case .divers(let positive): positive ? "Geen diverse inkomsten in deze maand." : "Geen diverse uitgaven in deze maand."
        }
    }

    private func detail(_ entry: EntryRow) -> String {
        var parts = [entry.accountName]
        if entry.bank == nil { parts.append("handinvoer") }
        if !entry.tags.isEmpty { parts.append(entry.tags.map(\.name).joined(separator: ", ")) }
        if !entry.reviewed { parts.append("nog nakijken") }
        return parts.joined(separator: " · ")
    }

    private func figure(_ title: String, _ value: String, color: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout.weight(.medium)).monospacedDigit().foregroundStyle(color)
        }
    }

    private func statusColor(_ status: CellStatus) -> Color {
        switch status {
        case .gelijk: Theme.positive
        case .afwijkend: Theme.warning
        case .teLaat: Theme.negative
        case .open: Theme.info
        case .nietVerwacht: .secondary
        }
    }

    private func load() {
        entries = model.read([]) { db in
            switch target.kind {
            case .item(let row):
                try Insight.cellEntries(db, itemId: row.id, year: options.year, month: target.month)
            case .divers(let positive):
                try Insight.diversEntries(db, year: options.year, month: target.month, positive: positive)
            }
        }
        loaded = true
    }
}

/// Klein formulier: met de hand een boeking toevoegen voor een post en maand.
struct GridEntryForm: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var row: GridItemRow
    var year: Int
    var month: Int

    @State private var amount: Money?
    @State private var day = 1
    @State private var label = ""
    @State private var accountId: Int64?
    @State private var accounts: [Account] = []
    @State private var ready = false

    private var lastDay: Int {
        (28...31).reversed().first { Day(year: year, month: month, day: $0) != nil } ?? 28
    }

    private var canSave: Bool {
        guard let amount, !amount.isZero, accountId != nil else { return false }
        return !label.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Boeking toevoegen").font(.title3.weight(.semibold))
                Text("\(row.label) · \(Day.monthNames[month - 1]) \(String(year))")
                    .font(.callout).foregroundStyle(.secondary)
            }

            if ready && accounts.isEmpty {
                Label("Er is nog geen betaalrekening. Maak er eerst een aan bij Instellingen.", systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.secondary)
            } else if ready {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 10) {
                    SwiftUI.GridRow {
                        Text("Bedrag").gridColumnAlignment(.trailing)
                        VStack(alignment: .leading, spacing: 3) {
                            MoneyField("Bedrag", value: $amount).frame(width: 130)
                            Text(row.direction == .IN ? "Inkomsten zijn positief." : "Uitgaven zijn negatief, bijvoorbeeld -45,00.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    SwiftUI.GridRow {
                        Text("Dag")
                        HStack(spacing: 6) {
                            Picker("Dag", selection: $day) {
                                ForEach(1...lastDay, id: \.self) { Text(String($0)).tag($0) }
                            }
                            .labelsHidden().frame(width: 64)
                            Text("\(Day.monthNames[month - 1]) \(String(year))").foregroundStyle(.secondary)
                        }
                    }
                    SwiftUI.GridRow {
                        Text("Omschrijving")
                        TextField("Omschrijving", text: $label).frame(minWidth: 220)
                    }
                    if accounts.count > 1 {
                        SwiftUI.GridRow {
                            Text("Rekening")
                            Picker("Rekening", selection: $accountId) {
                                ForEach(accounts) { Text($0.name).tag($0.id) }
                            }
                            .labelsHidden().frame(maxWidth: 240, alignment: .leading)
                        }
                    }
                }
                .textFieldStyle(.roundedBorder)
            }

            HStack {
                Text("Handinvoer telt direct mee in het grid en het saldo.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Annuleer") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Voeg toe") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear(perform: prepare)
    }

    private func prepare() {
        guard !ready else { return }
        accounts = model.read([]) { db in
            try Account.filter(Column("kind") == AccountKind.betaal.rawValue && Column("archived") == false)
                .order(Column("sortOrder")).fetchAll(db)
        }
        accountId = accounts.first?.id
        amount = row.cells.first { $0.month == month }?.expected ?? row.plan
        label = row.label
        let wanted = row.expectedDay ?? ((model.today.year == year && model.today.month == month) ? model.today.day : 1)
        day = min(max(wanted, 1), lastDay)
        ready = true
    }

    private func save() {
        guard let amount, let accountId, let date = Day(year: year, month: month, day: day) else { return }
        let draft = EntryDraft(accountId: accountId, day: date, amount: amount,
                               label: label.trimmingCharacters(in: .whitespaces), budgetItemId: row.id)
        let ok = model.perform("Boeking toegevoegd aan \(row.label)") {
            _ = try model.db.write { db in try EntryService.create(db, draft) }
        }
        if ok { dismiss() }
    }
}
