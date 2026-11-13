import SwiftUI
import GRDB
import HFCore
import HFInsight
import HFBudget

enum PotsSheet: Identifiable {
    case new
    case edit(PotSummary)
    case move(PotSummary)

    var id: String {
        switch self {
        case .new: "new"
        case .edit(let pot): "edit-\(pot.id)"
        case .move(let pot): "move-\(pot.id)"
        }
    }
}

// MARK: - Pot maken of bewerken

struct PotsEditSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    /// nil = nieuwe pot.
    let pot: PotSummary?
    let accounts: [PotsAccountRef]
    let owners: [String]
    var onSaved: (Int64) -> Void

    @State private var name: String
    @State private var kind: PotKind
    @State private var owner: String
    @State private var monthly: Money?
    @State private var target: Money?
    @State private var accountId: Int64?

    init(pot: PotSummary?, accounts: [PotsAccountRef], defaultAccountId: Int64?, owners: [String],
         onSaved: @escaping (Int64) -> Void) {
        self.pot = pot; self.accounts = accounts; self.owners = owners; self.onSaved = onSaved
        _name = State(initialValue: pot?.name ?? "")
        _kind = State(initialValue: pot?.kind ?? .reservering)
        _owner = State(initialValue: pot?.owner ?? "")
        _monthly = State(initialValue: pot?.monthlyAmount ?? .zero)
        _target = State(initialValue: pot?.targetAmount)
        _accountId = State(initialValue: pot?.accountId ?? defaultAccountId ?? accounts.first?.id)
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSave: Bool { !trimmedName.isEmpty && monthly != nil && accountId != nil }

    var body: some View {
        VStack(spacing: 0) {
            Text(pot == nil ? "Nieuwe pot" : "Pot bewerken").font(.headline).padding(.top, 16)
            Form {
                Section {
                    TextField("Naam", text: $name, prompt: Text("bijv. Wegenbelasting"))
                    Picker("Soort", selection: $kind) {
                        Text("Reservering").tag(PotKind.reservering)
                        Text("Sparen").tag(PotKind.spaar)
                    }
                    .pickerStyle(.segmented)
                    if pot == nil && accounts.count > 1 {
                        Picker("Spaarrekening", selection: $accountId) {
                            ForEach(accounts) { Text($0.name).tag(Optional($0.id)) }
                        }
                    }
                } footer: {
                    Text(kind.potsExplanation).font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Section {
                    MoneyField("Per maand", value: $monthly)
                        .help("Het bedrag dat je elke maand in deze pot stort. Laat op 0,00 staan als je niet vast stort.")
                    MoneyField("Doelbedrag (mag leeg)", value: $target)
                        .help("Met een doelbedrag zie je hoe ver de pot is. Laat leeg als de pot geen doel heeft.")
                    TextField("Eigenaar (mag leeg)", text: $owner, prompt: Text("bijv. een gezinslid"))
                        .help("Spaarpotten worden per eigenaar gegroepeerd.")
                    if !owners.isEmpty {
                        HStack(spacing: 6) {
                            Text("Bestaande eigenaren:").font(.caption).foregroundStyle(.secondary)
                            ForEach(owners, id: \.self) { o in
                                Button(o) { owner = o }.buttonStyle(.link).font(.caption)
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)

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
        .frame(width: 460)
    }

    private func save() {
        guard let monthly, let accountId else { return }
        let ownerValue = owner.trimmingCharacters(in: .whitespacesAndNewlines)
        let targetValue = target.flatMap { $0 > .zero ? $0 : nil }
        var savedId: Int64?
        let ok = model.perform(pot == nil ? "Pot \(trimmedName) gemaakt" : "Pot \(trimmedName) bewaard") {
            try model.db.write { db in
                if let existing = pot {
                    guard var record = try Pot.fetchOne(db, key: existing.id) else {
                        throw InsightError.potNotFound(existing.id)
                    }
                    record.name = trimmedName
                    record.kind = kind
                    record.owner = ownerValue.isEmpty ? nil : ownerValue
                    record.monthlyAmount = monthly
                    record.targetAmount = targetValue
                    savedId = try PotService.update(db, record).id
                } else {
                    let record = Pot(accountId: accountId, name: trimmedName, kind: kind,
                                     owner: ownerValue.isEmpty ? nil : ownerValue,
                                     monthlyAmount: monthly, targetAmount: targetValue)
                    savedId = try PotService.create(db, record).id
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
