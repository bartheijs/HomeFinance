import SwiftUI
import GRDB
import HFCore
import HFInsight
import HFBudget

enum PotsSheet: Identifiable {
    case new
    case edit(PotSummary)
    case move(PotSummary)
    case openings(Int64)
    /// Hulpje "Nieuw jaarbedrag" (UX-stap B3).
    case annual

    var id: String {
        switch self {
        case .new: "new"
        case .edit(let pot): "edit-\(pot.id)"
        case .move(let pot): "move-\(pot.id)"
        case .openings(let id): "openings-\(id)"
        case .annual: "annual"
        }
    }
}

// MARK: - Pot maken of bewerken

/// Eén regel van een spaardoel dat uit onderdelen is opgebouwd.
private struct PotsGoalPartDraft: Identifiable, Equatable {
    let id = UUID()
    var label = ""
    var quantity = 1
    var unit: Money?

    var amount: Money { Money(cents: (unit ?? .zero).cents * Int64(max(1, quantity))) }
}

struct PotsEditSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    /// nil = nieuwe pot.
    let pot: PotSummary?
    let accounts: [PotsAccountRef]
    let owners: [String]
    var onSaved: (Int64) -> Void
    var onDistributions: () -> Void

    @State private var name: String
    @State private var kind: PotKind
    @State private var owner: String
    @State private var accountId: Int64?
    @State private var opening: Money? = .zero
    @State private var openingDate = Date()
    @State private var openingDateTouched = false
    @State private var target: Money?
    @State private var hasTargetDate: Bool
    /// Het doel is opgebouwd uit onderdelen in plaats van één bedrag.
    @State private var goalFromParts = false
    @State private var parts: [PotsGoalPartDraft] = []
    @State private var hadParts = false
    @State private var targetDate: Date
    /// Het beginbedrag zoals het was bij openen (om te zien of het gewijzigd is).
    @State private var originalOpening: Money = .zero
    @State private var loaded = false

    init(pot: PotSummary?, accounts: [PotsAccountRef], defaultAccountId: Int64?, owners: [String], today: Day,
         onSaved: @escaping (Int64) -> Void, onDistributions: @escaping () -> Void) {
        self.pot = pot; self.accounts = accounts; self.owners = owners
        self.onSaved = onSaved; self.onDistributions = onDistributions
        _name = State(initialValue: pot?.name ?? "")
        _kind = State(initialValue: pot?.kind ?? .reservering)
        _owner = State(initialValue: pot?.owner ?? "")
        _accountId = State(initialValue: pot?.accountId ?? defaultAccountId ?? accounts.first?.id)
        _target = State(initialValue: pot?.targetAmount)
        _hasTargetDate = State(initialValue: pot?.targetDate != nil)
        let fallback = Calendar.current.date(byAdding: .year, value: 1, to: today.date) ?? today.date
        _targetDate = State(initialValue: pot?.targetDate?.date ?? fallback)
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSave: Bool { !trimmedName.isEmpty && opening != nil && accountId != nil }
    private var account: PotsAccountRef? { accounts.first { $0.id == accountId } }

    var body: some View {
        VStack(spacing: 0) {
            Text(pot == nil ? "Nieuwe pot" : "Pot bewerken").font(.headline).padding(.top, 16)
            // De velden komen pas na het laden, zodat het beginbedrag meteen goed in het veld staat.
            if !loaded { Spacer() } else {
            Form {
                Section {
                    TextField("Naam", text: $name, prompt: Text("bijv. Wegenbelasting"))
                    Picker("Soort", selection: $kind) {
                        Text("Reservering").tag(PotKind.reservering)
                        Text("Sparen").tag(PotKind.spaar)
                    }
                    .pickerStyle(.segmented)
                    .help(kind.potsExplanation)
                    if pot == nil && accounts.count > 1 {
                        Picker("Spaarrekening", selection: $accountId) {
                            ForEach(accounts) { Text($0.name).tag(Optional($0.id)) }
                        }
                    }
                    TextField("Eigenaar (mag leeg)", text: $owner, prompt: Text("bijv. een gezinslid"))
                        .help("Spaarpotten worden per eigenaar gegroepeerd.")
                    if !owners.isEmpty {
                        HStack(spacing: 8) {
                            Text("Kies:").font(.callout).foregroundStyle(.secondary)
                            ForEach(owners, id: \.self) { o in
                                Button(o) { owner = o }.buttonStyle(.link).font(.callout)
                            }
                        }
                    }
                }
                Section {
                    MoneyField("Beginbedrag", value: $opening)
                    DatePicker("Geldt op", selection: Binding(get: { openingDate },
                                                             set: { openingDate = $0; openingDateTouched = true }),
                               displayedComponents: .date)
                } footer: {
                    Text("Wat er al in de pot zat toen je met de app begon. Laat op 0,00 staan als de pot leeg begint.")
                        .font(.callout).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Section("Spaardoel (mag leeg)") {
                    Picker("Doel", selection: $goalFromParts) {
                        Text("Eén bedrag").tag(false)
                        Text("Opbouwen uit onderdelen").tag(true)
                    }
                    .pickerStyle(.segmented).labelsHidden()
                    .help("Eén bedrag: je vult het doel zelf in. Onderdelen: je telt het doel op uit losse posten, zoals lessen en examens.")
                    if goalFromParts {
                        goalParts
                    } else {
                        MoneyField("Doelbedrag", value: $target)
                            .help("Het bedrag dat je in deze pot wilt hebben. Laat leeg als de pot geen doel heeft. Een som zoals 40*65 mag ook.")
                    }
                    Toggle("Met doeldatum", isOn: $hasTargetDate)
                    if hasTargetDate {
                        DatePicker("Doel halen op", selection: $targetDate, displayedComponents: .date)
                    }
                }
                if let pot {
                    Section {
                        LabeledContent("Per maand naar deze pot") {
                            Text(pot.distributionAmount.isZero ? "nog niets" : pot.distributionAmount.formatted())
                                .monospacedDigit()
                        }
                        Button("Vaste stortingen…") { onDistributions() }
                    } footer: {
                        Text("Dit bedrag volgt uit je vaste stortingen. Je wijzigt het daar.")
                            .font(.callout).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .formStyle(.grouped)
            }

            Divider()
            HStack {
                Spacer()
                Button("Annuleer", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(pot == nil ? "Maak pot" : "Bewaar") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
            .padding(16)
        }
        .frame(width: 520, height: pot == nil ? 600 : 700)
        .onAppear(perform: load)
        .onChange(of: accountId) { _, _ in
            if pot == nil, !openingDateTouched, let account { openingDate = account.openingDate.date }
        }
    }

    /// De onderdelen van het doel: omschrijving, aantal × bedrag per stuk, met het totaal eronder.
    @ViewBuilder private var goalParts: some View {
        if parts.isEmpty {
            Text("Nog geen onderdelen. Bijvoorbeeld: 40 lessen × € 65, theorie-examen, praktijkexamen.")
                .font(.callout).foregroundStyle(.secondary)
        }
        ForEach($parts) { $part in
            HStack(spacing: 6) {
                TextField("Omschrijving", text: $part.label, prompt: Text("bijv. lessen"))
                    .labelsHidden()
                TextField("Aantal", value: $part.quantity, format: .number)
                    .labelsHidden().multilineTextAlignment(.trailing).frame(width: 44)
                    .help("Hoe vaak. Laat op 1 staan voor een los bedrag.")
                Text("×").foregroundStyle(.secondary)
                MoneyField("Per stuk", value: $part.unit)
                    .labelsHidden().frame(width: 90)
                    .help("Het bedrag per stuk.")
                Button { parts.removeAll { $0.id == part.id } } label: {
                    Image(systemName: "minus.circle").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Haal dit onderdeel weg.")
            }
        }
        HStack {
            Button { parts.append(PotsGoalPartDraft()) } label: { Label("Onderdeel toevoegen", systemImage: "plus") }
            Spacer()
            Text("Doelbedrag").foregroundStyle(.secondary)
            Text(partsTotal.formatted()).monospacedDigit().fontWeight(.semibold)
        }
    }

    private var validParts: [PotsGoalPartDraft] { parts.filter { $0.unit != nil && $0.quantity >= 1 } }
    private var partsTotal: Money { validParts.map(\.amount).sum() }

    /// Haalt het huidige beginbedrag en de datum ervan op.
    private func load() {
        guard !loaded else { return }
        loaded = true
        if let account { openingDate = account.openingDate.date }
        guard let pot else { return }
        let existingParts = model.read([GoalPart]()) { try PotService.goalParts($0, potId: pot.id) }
        if !existingParts.isEmpty {
            hadParts = true
            goalFromParts = true
            parts = existingParts.map { PotsGoalPartDraft(label: $0.label, quantity: $0.quantity, unit: $0.unitAmount) }
        }
        let entry = model.read(Entry?.none) { db in
            try Entry.filter(Column("potId") == pot.id && Column("accountId") == pot.accountId
                             && Column("note") == PotService.openingNote).fetchOne(db)
        }
        if let entry {
            opening = entry.amount
            originalOpening = entry.amount
            openingDate = entry.day.date
        }
    }

    private func save() {
        guard let opening, let accountId else { return }
        let ownerValue = owner.trimmingCharacters(in: .whitespacesAndNewlines)
        let useParts = goalFromParts && !validParts.isEmpty
        let targetValue = useParts ? partsTotal : (goalFromParts ? nil : target.flatMap { $0 > .zero ? $0 : nil })
        let partDrafts = validParts
        let targetDay: Day? = (targetValue != nil && hasTargetDate) ? Day(date: targetDate) : nil
        let openingDay = Day(date: openingDate)
        var savedId: Int64?
        let ok = model.perform(pot == nil ? "Pot \(trimmedName) gemaakt" : "Pot \(trimmedName) bewaard") {
            try model.db.write { db in
                // Het beginsaldo van de rekening bij de bank blijft gelijk; alleen de verdeling verandert.
                let bankOpening = try PotService.openingSummary(db, accountId: accountId).total
                if let existing = pot {
                    guard var record = try Pot.fetchOne(db, key: existing.id) else {
                        throw InsightError.potNotFound(existing.id)
                    }
                    record.name = trimmedName
                    record.kind = kind
                    record.owner = ownerValue.isEmpty ? nil : ownerValue
                    record.targetAmount = targetValue
                    record.targetDate = targetDay
                    // Eerst de oude onderdelen weg, anders overschrijven ze het zelf ingevulde bedrag.
                    if hadParts && !useParts { _ = try PotService.setGoalParts(db, potId: existing.id, []) }
                    savedId = try PotService.update(db, record).id
                    if useParts {
                        _ = try PotService.setGoalParts(db, potId: existing.id, partDrafts.map {
                            GoalPart(potId: existing.id, label: $0.label.trimmingCharacters(in: .whitespacesAndNewlines),
                                     quantity: $0.quantity, unitAmount: $0.unit ?? .zero)
                        })
                    }
                    if opening != originalOpening || (openingDateTouched && !opening.isZero) {
                        _ = try PotService.setOpeningBalance(db, potId: existing.id, amount: opening, on: openingDay)
                        _ = try AccountService.setOpeningFromPots(db, accountId: accountId, totalOpening: bankOpening)
                    }
                } else {
                    let record = Pot(accountId: accountId, name: trimmedName, kind: kind,
                                     owner: ownerValue.isEmpty ? nil : ownerValue,
                                     targetAmount: targetValue, targetDate: targetDay)
                    savedId = try PotService.create(db, record, openingBalance: opening, on: openingDay).id
                    if useParts, let newId = savedId {
                        _ = try PotService.setGoalParts(db, potId: newId, partDrafts.map {
                            GoalPart(potId: newId, label: $0.label.trimmingCharacters(in: .whitespacesAndNewlines),
                                     quantity: $0.quantity, unitAmount: $0.unit ?? .zero)
                        })
                    }
                    if !opening.isZero {
                        _ = try AccountService.setOpeningFromPots(db, accountId: accountId, totalOpening: bankOpening)
                    }
                }
            }
        }
        if ok {
            if let savedId { onSaved(savedId) }
            dismiss()
        }
    }
}

// MARK: - Verplaatsen tussen potten

struct PotsMoveSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let from: PotSummary
    /// Andere potten op dezelfde rekening.
    let candidates: [PotSummary]

    @State private var toId: Int64?
    @State private var amount: Money?
    @State private var date: Date
    @State private var label = ""

    init(from: PotSummary, candidates: [PotSummary], today: Day) {
        self.from = from; self.candidates = candidates
        _date = State(initialValue: today.date)
    }

    private var to: PotSummary? { candidates.first { $0.id == toId } }
    private var defaultLabel: String { "Verplaatst van \(from.name) naar \(to?.name ?? "…")" }
    private var canSave: Bool { toId != nil && (amount ?? .zero) > .zero }

    var body: some View {
        VStack(spacing: 0) {
            Text("Verplaats naar andere pot").font(.headline).padding(.top, 16)
            Form {
                Section {
                    LabeledContent("Van") {
                        VStack(alignment: .trailing, spacing: 1) {
                            Text(from.name)
                            Text("saldo \(from.balance.formatted())").font(.caption).monospacedDigit()
                                .foregroundStyle(from.balance.isNegative ? Theme.negative : Color.secondary)
                        }
                    }
                    Picker("Naar", selection: $toId) {
                        Text("Kies een pot").tag(Int64?.none)
                        ForEach(PotKind.allCases, id: \.self) { kind in
                            let group = candidates.filter { $0.kind == kind }
                            if !group.isEmpty {
                                Section(kind == .reservering ? "Reserveringen" : "Sparen") {
                                    ForEach(group) { pot in
                                        Text("\(pot.name)  ·  \(pot.balance.formatted())").tag(Optional(pot.id))
                                    }
                                }
                            }
                        }
                    }
                }
                Section {
                    MoneyField("Bedrag", value: $amount)
                    DatePicker("Datum", selection: $date, displayedComponents: .date)
                    TextField("Omschrijving", text: $label, prompt: Text(defaultLabel))
                } footer: {
                    Text(footer).font(.caption)
                        .foregroundStyle(overdraws ? Theme.warning : Color.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)

            Divider()
            HStack {
                Spacer()
                Button("Annuleer", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Verplaats") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
            .padding(16)
        }
        .frame(width: 460)
    }

    private var overdraws: Bool {
        guard let amount else { return false }
        return amount > from.balance
    }

    private var footer: String {
        overdraws
            ? "Let op: dit is meer dan er in \(from.name) zit. De pot komt dan negatief te staan."
            : "Het saldo van de spaarrekening verandert niet; alleen de verdeling over de potten."
    }

    private func save() {
        guard let toId, let amount else { return }
        let text = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let ok = model.perform("\(amount.formatted()) verplaatst naar \(to?.name ?? "de andere pot")") {
            try model.db.write { db in
                _ = try PotService.moveBetweenPots(db, from: from.id, to: toId, amount: amount,
                                                   day: Day(date: date), label: text.isEmpty ? defaultLabel : text)
            }
        }
        if ok { dismiss() }
    }
}

// MARK: - Beginbedragen nalopen

/// Alle potten van een rekening onder elkaar met hun beginbedrag; één keer opslaan.
struct PotsOpeningSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let accountId: Int64
    let accountName: String

    private struct Row: Identifiable, Equatable {
        let id: Int64
        let name: String
        let original: Money
        var amount: Money?
    }

    @State private var rows: [Row] = []
    @State private var total: Money? = .zero
    @State private var loaded = false

    private var potSum: Money { rows.map { $0.amount ?? .zero }.sum() }
    private var unallocated: Money { (total ?? .zero) - potSum }
    private var valid: Bool { total != nil && rows.allSatisfy { $0.amount != nil } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Beginbedragen nalopen").font(.title3.weight(.semibold))
                Text("Vul per pot in wat erin zat op de dag dat je met \(accountName) in de app begon. Samen met wat nog geen pot heeft is dat het beginsaldo van de rekening.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
            Divider()
            if loaded {
                ScrollView {
                    VStack(spacing: 0) {
                        HStack {
                            Text("Beginsaldo van de rekening bij de bank").fontWeight(.medium)
                            Spacer()
                            MoneyField("Bedrag", value: $total)
                                .textFieldStyle(.roundedBorder).frame(width: 130)
                        }
                        .padding(.horizontal, 20).padding(.vertical, 10)
                        Divider()
                        ForEach($rows) { $row in
                            HStack {
                                Text(row.name).lineLimit(1)
                                Spacer()
                                MoneyField("Bedrag", value: $row.amount)
                                    .textFieldStyle(.roundedBorder).frame(width: 130)
                            }
                            .padding(.horizontal, 20).padding(.vertical, 5)
                        }
                    }
                    .padding(.vertical, 6)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            HStack(spacing: 6) {
                Text("Potten").foregroundStyle(.secondary)
                Text(potSum.formatted()).monospacedDigit()
                Text("+ niet toegewezen").foregroundStyle(.secondary)
                Text(unallocated.formatted()).monospacedDigit()
                    .foregroundStyle(unallocated.isZero ? Color.primary : Theme.warning)
                Text("= rekening").foregroundStyle(.secondary)
                Text((total ?? .zero).formatted()).monospacedDigit().fontWeight(.semibold)
                Spacer()
            }
            .font(.callout)
            .padding(.horizontal, 20).padding(.vertical, 12)
            .help("Niet toegewezen hoort € 0,00 te zijn: dan heeft elke euro van het beginsaldo een pot.")
            Divider()
            HStack {
                Spacer()
                Button("Annuleer", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Bewaar") { save() }.keyboardShortcut(.defaultAction).disabled(!valid)
            }
            .padding(16)
        }
        .frame(width: 520, height: 640)
        .onAppear(perform: load)
    }

    private func load() {
        guard !loaded else { return }
        let summary = model.read(PotOpeningSummary?.none) { try PotService.openingSummary($0, accountId: accountId) }
        if let summary {
            rows = summary.potOpenings.compactMap { opening in
                guard let id = opening.pot.id, !opening.pot.archived || !opening.amount.isZero else { return nil }
                return Row(id: id, name: opening.pot.name, original: opening.amount, amount: opening.amount)
            }
            total = summary.total
        }
        loaded = true
    }

    private func save() {
        guard let total else { return }
        let ok = model.perform("Beginbedragen bewaard") {
            try model.db.write { db in
                for row in rows {
                    guard let amount = row.amount, amount != row.original else { continue }
                    _ = try PotService.setOpeningBalance(db, potId: row.id, amount: amount)
                }
                _ = try AccountService.setOpeningFromPots(db, accountId: accountId, totalOpening: total)
            }
        }
        if ok { dismiss() }
    }
}
