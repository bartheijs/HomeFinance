import SwiftUI
import GRDB
import HFCore
import HFInsight
import HFBudget
import HFRules

/// Venstertje bij een cel: de boekingen erachter.
struct GridCellPopover: View {
    @Environment(AppModel.self) private var model

    var target: GridTarget
    var options: GridOptions
    /// Maandtotaal uit het grid (HFInsight).
    var total: Money
    var onAdd: () -> Void
    var onSetChecked: (Bool) -> Void = { _ in }
    var onShowTransactions: () -> Void

    @State private var entries: [EntryRow] = []
    @State private var loaded = false
    /// Wachtende banktransacties die bij een post lijken te passen die te laat is; alleen gezocht bij openen.
    @State private var candidates: [WaitingCandidate] = []
    /// Bij een post met een vaste storting: via welke storting hij naar welke potjes gaat (UX-stap B2).
    @State private var chain: ItemChain?

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
                        Pill(statusWords(cell), color: statusColor(cell.status))
                    }
                }
            }

            if let chain { ItemChainView(chain: chain) }

            if let first = candidates.first { candidateHint(first) }

            if let cell {
                VStack(alignment: .leading, spacing: 2) {
                    Toggle("Voldaan (afvinken)", isOn: Binding(get: { cell.isChecked }, set: { onSetChecked($0) }))
                        .toggleStyle(.checkbox)
                        .disabled(!options.editable)
                    Text("Gebruik dit als de post betaald is maar de boeking niet in de app staat, of als hij deze maand vervalt.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 20)
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
                                Text(dateText(entry))
                                    .monospacedDigit().foregroundStyle(.secondary)
                                    .lineLimit(1).fixedSize()
                                    .frame(minWidth: 46, alignment: .leading)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(entry.label.isEmpty ? "(zonder omschrijving)" : entry.label).lineLimit(1)
                                    Text(detail(entry)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    periodMenu(entry)
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

    /// De woorden uit het begrippenvoorstel: Klopt / Wijkt af (± € X) / Nog verwacht / Te laat / Afgevinkt.
    private func statusWords(_ cell: GridCell) -> String {
        switch cell.status {
        case .gelijk: "Klopt"
        case .afwijkend: cell.expected == nil ? "Wijkt af (niet verwacht)" : "Wijkt af (\(cell.difference.formatted(alwaysSign: true)))"
        case .open: "Nog verwacht"
        case .teLaat: "Te laat"
        case .afgevinkt: "Afgevinkt"
        case .nietVerwacht: "Niet verwacht"
        }
    }

    /// "Er wacht een banktransactie die hierbij lijkt te passen", met een knop naar Nakijken.
    private func candidateHint(_ c: WaitingCandidate) -> some View {
        let why = switch c.reason {
        case .rule: "een regel stelt deze post voor"
        case .sameCounterparty: "dezelfde tegenrekening als eerder"
        case .sameAmount: "precies het geplande bedrag"
        }
        let more = candidates.count > 1 ? " (en nog \(candidates.count - 1))" : ""
        return VStack(alignment: .leading, spacing: 6) {
            Label {
                Text("Er wacht een banktransactie die hierbij lijkt te passen\(more): \(c.day.short()) · \(c.counterpartyName.isEmpty ? "zonder naam" : c.counterpartyName) · \(c.amount.formatted()) (\(why)). Boek hem in Nakijken; afvinken is dan niet nodig.")
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "tray.full").foregroundStyle(Theme.info)
            }
            .font(.callout)
            Button("Naar Nakijken") {
                model.reviewJump = ReviewJump(accountId: c.accountId, transactionId: c.id)
                model.selection = .review
            }
            .controlSize(.small)
            .help("Open Importeren en nakijken op deze banktransactie.")
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.info.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private var emptyText: String {
        switch target.kind {
        case .item: "Nog geen boekingen in deze maand."
        case .divers(let positive): positive ? "Geen overige inkomsten in deze maand." : "Geen overige uitgaven in deze maand."
        }
    }

    /// "28 nov", of "28 nov · telt in dec" als de boeking in een andere maand meetelt dan zijn datum.
    private func dateText(_ entry: EntryRow) -> String {
        let movesMonth = entry.budgetMonth != entry.day.month || entry.budgetYear != entry.day.year
        return entry.day.short() + (movesMonth ? " · telt in \(Day.monthNamesShort[entry.budgetMonth - 1])" : "")
    }

    /// Keuze van de maand waarin de boeking meetelt: de drie maanden rond de datum.
    private func periodMenu(_ entry: EntryRow) -> some View {
        Menu {
            ForEach(GridPeriod.around(entry.day), id: \.month) { choice in
                let isDateMonth = choice.year == entry.day.year && choice.month == entry.day.month
                let isCurrent = choice.year == entry.budgetYear && choice.month == entry.budgetMonth
                Button {
                    setPeriod(entry, year: isDateMonth ? nil : choice.year, month: isDateMonth ? nil : choice.month,
                              name: Day.monthNames[choice.month - 1])
                } label: {
                    let title = "\(Day.monthNames[choice.month - 1].capitalized) \(String(choice.year))" + (isDateMonth ? " (maand van de datum)" : "")
                    if isCurrent { Label(title, systemImage: "checkmark") } else { Text(title) }
                }
                .disabled(isCurrent)
            }
        } label: {
            Text("Hoort bij maand: \(Day.monthNames[entry.budgetMonth - 1])").font(.caption)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(!options.editable)
        .help("Laat deze boeking in een andere maand meetellen voor de begroting, bijvoorbeeld als de hypotheek van december al eind november is afgeschreven. Het saldo volgt altijd de datum.")
    }

    private func setPeriod(_ entry: EntryRow, year: Int?, month: Int?, name: String) {
        model.perform("Boeking telt nu mee in \(name)") {
            _ = try model.db.write { db in try EntryService.setPeriod(db, entryId: entry.id, year: year, month: month) }
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
        case .nietVerwacht, .afgevinkt: .secondary
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
        chain = nil
        if case .item(let row) = target.kind, row.kind != .reserveLine {
            let found = model.read(nil as ItemChain?) { db in try Insight.chain(db, year: options.year).item(row.id) }
            if found?.distribution != nil { chain = found }
        }
        candidates = []
        if case .item(let row) = target.kind, let cell, cell.status == .teLaat, let plan = cell.expected {
            candidates = model.read([]) { db in
                let suggested = try RuleEngine.suggestAll(db).compactMapValues(\.budgetItemId)
                return try Insight.waitingCandidates(db, itemId: row.id, year: options.year, month: target.month,
                                                     plan: plan, suggestedItems: suggested)
            }
        }
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
    @State private var date = Date()
    @State private var label = ""
    @State private var accountId: Int64?
    @State private var accounts: [Account] = []
    @State private var ready = false

    private var lastDay: Int {
        (28...31).reversed().first { Day(year: year, month: month, day: $0) != nil } ?? 28
    }

    private var chosenDay: Day { Day(date: date) }
    /// De datum valt in een andere maand dan de aangeklikte kolom.
    private var otherMonth: Bool { chosenDay.year != year || chosenDay.month != month }

    /// De periode mag hoogstens 2 maanden van de datum af liggen.
    private var dateRange: ClosedRange<Date> {
        let first = Day(year: year, month: month, day: 1)?.date ?? Date()
        let calendar = Calendar.current
        let from = calendar.date(byAdding: .month, value: -2, to: first) ?? first
        let afterEnd = calendar.date(byAdding: .month, value: 3, to: first) ?? first
        return from...(calendar.date(byAdding: .day, value: -1, to: afterEnd) ?? first)
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
                        Text("Datum")
                        VStack(alignment: .leading, spacing: 3) {
                            DatePicker("Datum", selection: $date, in: dateRange, displayedComponents: .date)
                                .labelsHidden().fixedSize()
                                .environment(\.locale, Locale(identifier: "nl_NL"))
                            if otherMonth {
                                Text("De datum valt in \(Day.monthNames[chosenDay.month - 1]); de boeking hoort bij \(Day.monthNames[month - 1]).")
                                    .font(.caption).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
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
        date = Day(year: year, month: month, day: min(max(wanted, 1), lastDay))?.date ?? Date()
        ready = true
    }

    private func save() {
        guard let amount, let accountId else { return }
        // Valt de datum buiten de aangeklikte maand, dan telt de boeking toch in die maand mee.
        let draft = EntryDraft(accountId: accountId, day: chosenDay, amount: amount,
                               label: label.trimmingCharacters(in: .whitespaces), budgetItemId: row.id,
                               period: otherMonth ? GridPeriod.key(year: year, month: month) : nil)
        let ok = model.perform("Boeking toegevoegd aan \(row.label)") {
            _ = try model.db.write { db in try EntryService.create(db, draft) }
        }
        if ok { dismiss() }
    }
}
