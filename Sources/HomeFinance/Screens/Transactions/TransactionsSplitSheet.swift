import SwiftUI
import HFCore
import HFInsight

/// Eén banktransactie verdelen over meer regels (bv. boodschappen en een cadeau op één bon).
struct TransactionsSplitSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let store: TransactionsStore
    let target: TransactionsSplitTarget
    @State private var parts: [TransactionsSplitPart] = []

    private var total: Money { target.transaction.amount.magnitude }
    /// Wat nog niet over de regels verdeeld is (zonder teken).
    private var remaining: Money { total - parts.compactMap { $0.draft.magnitude?.magnitude }.sum() }
    private var canSave: Bool {
        remaining.isZero && parts.allSatisfy {
            guard let m = $0.draft.magnitude else { return false }
            return m.isZero || !$0.draft.label.trimmingCharacters(in: .whitespaces).isEmpty
        } && parts.contains { !($0.draft.magnitude?.isZero ?? true) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Splitsen").font(.title2.weight(.semibold))
                Text("\(target.transaction.counterpartyName.isEmpty ? "Transactie" : target.transaction.counterpartyName) · \(target.transaction.day.short(withYear: true)) · \(target.transaction.amount.formatted())")
                    .font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 12)

            ScrollView {
                VStack(spacing: 8) {
                    ForEach($parts) { $part in
                        HStack(spacing: 8) {
                            TextField("Omschrijving", text: $part.draft.label)
                                .textFieldStyle(.roundedBorder)
                                .frame(minWidth: 150)
                            Group {
                                switch target.kind {
                                case .betaal:
                                    TransactionsItemPicker(items: store.lookups.items(year: target.transaction.day.year),
                                                           selection: $part.draft.itemId)
                                case .spaar:
                                    TransactionsPotPicker(pots: store.lookups.pots(accountId: target.transaction.accountId, keeping: part.draft.potId),
                                                          noneTitle: "Niet toegewezen", selection: $part.draft.potId)
                                }
                            }
                            .frame(width: 190)
                            HStack(spacing: 4) {
                                Text("€").foregroundStyle(.secondary)
                                MoneyField("0,00", value: $part.draft.magnitude)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 90)
                            }
                            Button {
                                parts.removeAll { $0.id == part.id }
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                            .disabled(parts.count <= 1)
                            .help("Deze regel weghalen")
                        }
                    }
                }
                .padding(.horizontal, 20).padding(.vertical, 4)
            }
            .frame(minHeight: 110, maxHeight: 300)

            HStack(spacing: 12) {
                Button("Regel toevoegen", systemImage: "plus") {
                    var d = TransactionsDraft()
                    d.day = target.transaction.day
                    d.isIncome = !target.transaction.amount.isNegative
                    d.magnitude = remaining > .zero ? remaining : nil
                    parts.append(TransactionsSplitPart(draft: d))
                }
                Spacer()
                if remaining.isZero {
                    Label("Alles verdeeld", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.positive)
                } else {
                    Text(remaining > .zero ? "Nog te verdelen: \(remaining.formatted())" : "Te veel verdeeld: \(remaining.magnitude.formatted())")
                        .foregroundStyle(Theme.warning).monospacedDigit()
                }
            }
            .font(.callout)
            .padding(.horizontal, 20).padding(.vertical, 10)

            Divider()
            HStack {
                Text("De delen samen zijn precies het bankbedrag. Bedragen typ je zonder minteken.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Annuleer") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Splits") {
                    if store.split(model, target, parts: parts) { dismiss() }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!canSave)
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
        }
        .frame(width: 640)
        .onAppear { if parts.isEmpty { parts = target.parts } }
    }
}

/// Kleine sheet voor de notitie bij een boeking.
struct TransactionsNoteSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let store: TransactionsStore
    let row: EntryRow
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Notitie bij ‘\(row.label)’").font(.headline).lineLimit(1)
            TextField("Notitie", text: $text, axis: .vertical)
                .lineLimit(3...6)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
            HStack {
                Spacer()
                Button("Annuleer") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Bewaar") {
                    store.setNote(model, row: row, text.trimmingCharacters(in: .whitespacesAndNewlines))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear { text = row.note; focused = true }
    }
}
