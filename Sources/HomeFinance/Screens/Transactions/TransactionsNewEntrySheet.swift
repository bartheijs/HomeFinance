import SwiftUI
import HFCore

/// Sheet voor een handmatige boeking (zonder banktransactie).
struct TransactionsNewEntrySheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let store: TransactionsStore
    @State private var accountId: Int64?
    @State private var draft = TransactionsDraft()
    @State private var prepared = false

    private var kind: AccountKind { store.lookups.account(accountId)?.kind ?? .betaal }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Nieuwe boeking").font(.title2.weight(.semibold))
                Text("Voor iets wat niet in een bankbestand staat, bv. contant geld of een correctie.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 4)

            Form {
                Section {
                    Picker("Rekening", selection: $accountId) {
                        ForEach(store.lookups.accounts) { Text($0.name).tag(Int64?.some($0.id)) }
                    }
                    LabeledContent("Datum") { TransactionsDayPicker(day: $draft.day) }
                    LabeledContent("Bedrag") {
                        TransactionsAmountInput(isIncome: $draft.isIncome, magnitude: $draft.magnitude)
                            .frame(maxWidth: 230)
                    }
                    LabeledContent("Omschrijving") {
                        TransactionsLabelField(title: "Bv. Zakgeld contant", text: $draft.label, labels: store.labels, autoFocus: true) { suggestion in
                            draft.adopt(suggestion, lookups: store.lookups, kind: kind)
                        }
                    }
                }
                Section {
                    switch kind {
                    case .betaal:
                        LabeledContent {
                            TransactionsItemPicker(items: store.lookups.items(year: draft.day.year), selection: $draft.itemId)
                        } label: {
                            Text("Post")
                            Text("Divers = hoort bij geen vaste post")
                        }
                    case .spaar:
                        LabeledContent {
                            TransactionsPotPicker(pots: store.lookups.pots(accountId: accountId),
                                                  noneTitle: "Niet toegewezen", selection: $draft.potId)
                        } label: {
                            Text("Pot")
                            Text("Waar het bedrag bij komt of af gaat")
                        }
                    }
                    LabeledContent("Tags") {
                        if kind == .betaal {
                            TransactionsTagEditor(tags: store.lookups.tags, selection: $draft.tagIds) { name, color, settles in
                                guard let id = store.createTag(model, name: name, color: color, settles: settles, ids: []) else { return false }
                                draft.tagIds.insert(id)
                                return true
                            }
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        } else {
                            Text(TagRuleText.savings).font(.callout).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                    }
                    TextField("Notitie", text: $draft.note, prompt: Text("Optioneel"), axis: .vertical)
                        .lineLimit(1...4)
                }
                if kind == .betaal {
                    Section {
                        Toggle(isOn: $draft.reimburse) {
                            Text("Verrekenen met spaar")
                            Text(draft.isIncome ? "Dit bedrag gaat later door naar de spaarrekening" : "Dit bedrag komt later terug van de spaarrekening")
                        }
                        .help(TransactionsFormat.settleHelp)
                        if draft.reimburse {
                            LabeledContent(draft.isIncome ? "Gaat naar pot" : "Komt uit pot") {
                                TransactionsPotPicker(pots: store.lookups.pots(accountId: nil),
                                                      noneTitle: "Nog niet gekozen", selection: $draft.potId)
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .scrollBounceBehavior(.basedOnSize)

            Divider()
            HStack {
                if store.lookups.closedYears.contains(draft.day.year) {
                    Label("\(String(draft.day.year)) is afgesloten", systemImage: "lock.fill")
                        .font(.callout).foregroundStyle(Theme.warning)
                        .help("In een afgesloten jaar kun je niet boeken. Kies een datum in een open jaar.")
                }
                Spacer()
                Button("Annuleer") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Voeg toe") { add() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(accountId == nil || !draft.isValid)
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
        }
        .frame(width: 520)
        .frame(minHeight: 480)
        .onAppear(perform: prepare)
        .onChange(of: accountId) { _, _ in
            // Post en pot horen bij de soort rekening.
            draft.itemId = nil; draft.potId = nil; draft.reimburse = false
        }
        .onChange(of: draft.reimburse) { _, on in
            if !on, kind == .betaal { draft.potId = nil }
        }
    }

    private func prepare() {
        guard !prepared else { return }
        prepared = true
        accountId = store.accountId ?? store.lookups.accounts.first?.id
        draft.day = model.today
    }

    private func add() {
        guard let accountId else { return }
        if store.create(model, accountId: accountId, kind: kind, draft: draft) { dismiss() }
    }
}
