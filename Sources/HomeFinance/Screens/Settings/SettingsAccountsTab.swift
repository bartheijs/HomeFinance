import SwiftUI
import GRDB
import HFCore
import HFBudget
import HFInsight

struct SettingsAccountsData: Equatable {
    var accounts: [Account] = []
    var balances: [Int64: Money] = [:]
    var history: [Int64: [Reconciliation]] = [:]
    /// Beginstand van spaarrekeningen: potten + niet toegewezen.
    var opening: [Int64: OpeningOverview] = [:]

    static func load(_ db: Database, today: Day) throws -> SettingsAccountsData {
        var d = SettingsAccountsData()
        d.accounts = try Account.order(Column("sortOrder"), Column("id")).fetchAll(db)
        for overview in try Insight.accountOverview(db, today: today) { d.balances[overview.id] = overview.balance }
        for account in d.accounts {
            guard let id = account.id else { continue }
            d.history[id] = try BalanceService.history(db, accountId: id)
            if account.kind == .spaar { d.opening[id] = try Insight.openingOverview(db, accountId: id) }
        }
        return d
    }
}

struct SettingsAccountsTab: View {
    @Environment(AppModel.self) private var model
    @State private var data = SettingsAccountsData()
    @State private var loaded = false
    @State private var adding = false
    @State private var resetToken = 0
    @State private var expandedId: Int64?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.spacing) {
                HStack(alignment: .top) {
                    Text("Klik op een rekening om de gegevens te wijzigen of het saldo met de bank te vergelijken.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button { adding = true } label: { Label("Rekening toevoegen", systemImage: "plus") }
                        .disabled(adding)
                }
                if loaded && data.accounts.isEmpty && !adding {
                    Card {
                        EmptyState(title: "Nog geen rekeningen",
                                   message: "Voeg je betaalrekening toe met het saldo op de dag waarop je begint. Daarna kun je afschriften importeren.",
                                   icon: "creditcard", actionTitle: "Rekening toevoegen") { adding = true }
                            .frame(minHeight: 240)
                    }
                }
                ForEach(data.accounts) { account in
                    SettingsAccountCard(account: account, isNew: false, isExpanded: expandedId == account.id,
                                        onToggle: { expandedId = expandedId == account.id ? nil : account.id },
                                        balance: data.balances[account.id ?? -1] ?? .zero,
                                        history: data.history[account.id ?? -1] ?? [],
                                        openingSplit: data.opening[account.id ?? -1],
                                        onChanged: { failed in if failed { resetToken += 1 }; load() },
                                        onCancel: {})
                        .id("\(account.id ?? 0)-\(resetToken)")
                }
                if adding {
                    SettingsAccountCard(account: Account(name: "", kind: data.accounts.isEmpty ? .betaal : .spaar,
                                                         openingDate: model.today),
                                        isNew: true, isExpanded: true, onToggle: {}, balance: .zero, history: [],
                                        onChanged: { failed in if !failed { adding = false }; load() },
                                        onCancel: { adding = false })
                }
            }
            .frame(maxWidth: 780, alignment: .leading)
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: SettingsReloadKey(revision: model.revision, year: model.year)) { load() }
    }

    private func load() {
        data = model.read(SettingsAccountsData()) { try SettingsAccountsData.load($0, today: model.today) }
        loaded = true
    }
}

/// Eén rekening: gegevens links, afstemmen met de bank rechts.
struct SettingsAccountCard: View {
    @Environment(AppModel.self) private var model

    let account: Account
    let isNew: Bool
    let isExpanded: Bool
    var onToggle: () -> Void
    let balance: Money
    let history: [Reconciliation]
    /// Alleen bij een spaarrekening: het beginsaldo uitgesplitst.
    var openingSplit: OpeningOverview?
    /// Aangeroepen na een schrijfactie; `true` als die mislukte.
    var onChanged: (Bool) -> Void
    var onCancel: () -> Void

    @State private var draft: Account
    @State private var opening: Money?
    @State private var reconcileDay: Date
    @State private var actual: Money?
    @State private var confirmDelete = false

    init(account: Account, isNew: Bool, isExpanded: Bool, onToggle: @escaping () -> Void, balance: Money,
         history: [Reconciliation], openingSplit: OpeningOverview? = nil,
         onChanged: @escaping (Bool) -> Void, onCancel: @escaping () -> Void) {
        self.openingSplit = openingSplit
        self.account = account; self.isNew = isNew; self.isExpanded = isExpanded; self.onToggle = onToggle
        self.balance = balance; self.history = history
        self.onChanged = onChanged; self.onCancel = onCancel
        _draft = State(initialValue: account)
        _opening = State(initialValue: account.openingBalance)
        _reconcileDay = State(initialValue: Date())
    }

    var body: some View {
        VStack(spacing: 0) {
            Button(action: onToggle) { header.contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .help(isExpanded ? "Klik om te sluiten" : "Klik voor gegevens en afstemmen")
            if isExpanded {
                Divider().padding(.leading, 18)
                details.padding(18).frame(maxWidth: .infinity, alignment: .topLeading)
                if !isNew {
                    Divider().padding(.leading, 18)
                    reconcile.padding(18).frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
        }
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius))
        .onAppear { reconcileDay = SettingsFormat.date(model.today) }
        .confirmationDialog("Rekening ‘\(account.name)’ verwijderen?", isPresented: $confirmDelete) {
            Button("Verwijder", role: .destructive) { delete() }
            Button("Annuleer", role: .cancel) {}
        } message: {
            Text("Dat kan alleen als de rekening nergens gebruikt wordt. Heeft hij boekingen, archiveer hem dan.")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: draft.kind == .betaal ? "creditcard" : "banknote")
                .foregroundStyle(.secondary).font(.title3).frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(isNew ? "Nieuwe rekening" : account.name).font(.title3.weight(.medium))
                Text(isNew ? "Vul de gegevens in" : (account.kind == .betaal ? "Betaalrekening" : "Spaarrekening"))
                    .font(.callout).foregroundStyle(.secondary)
            }
            if account.archived {
                Pill("gearchiveerd", color: .secondary, icon: "archivebox")
            }
            Spacer()
            if !isNew {
                MoneyText(balance).font(.title3).help("Saldo vandaag: beginsaldo plus alle boekingen")
                Image(systemName: "chevron.right").font(.callout).foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 13)
    }

    // MARK: Gegevens

    private var details: some View {
        VStack(alignment: .leading, spacing: 10) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 9) {
                GridRow {
                    Text("Naam").foregroundStyle(.secondary)
                    TextField("Bijvoorbeeld Betaalrekening", text: $draft.name).textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("IBAN").foregroundStyle(.secondary)
                    TextField("NL00 BANK 0000 0000 00", text: Binding(
                        get: { draft.iban ?? "" }, set: { draft.iban = $0.isEmpty ? nil : $0 }))
                        .textFieldStyle(.roundedBorder).font(.body.monospaced())
                        .help("Hiermee herkent de import voor welke rekening een bestand is, en overboekingen tussen je eigen rekeningen.")
                }
                GridRow {
                    Text("Soort").foregroundStyle(.secondary)
                    Picker("Soort", selection: $draft.kind) {
                        Text("Betaalrekening").tag(AccountKind.betaal)
                        Text("Spaarrekening").tag(AccountKind.spaar)
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                    .help("Betaalrekening: boekingen op vaste posten en overig. Spaarrekening: boekingen in potjes.")
                }
                GridRow {
                    Text("Beginsaldo").foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        MoneyField("0,00", value: $opening).textFieldStyle(.roundedBorder).frame(width: 120)
                        Text("op").foregroundStyle(.secondary)
                        DatePicker("Begindatum", selection: Binding(
                            get: { SettingsFormat.date(draft.openingDate) }, set: { draft.openingDate = Day(date: $0) }),
                                   displayedComponents: .date)
                            .labelsHidden().fixedSize()
                    }
                    .help("Het saldo aan het begin van die dag, vóór de eerste boeking in HomeFinance.")
                }
                if let split = openingSplit, !isNew {
                    GridRow {
                        Text("Verdeling").foregroundStyle(.secondary)
                        HStack(spacing: 10) {
                            Text(Self.splitText(split)).monospacedDigit()
                                .help("Het beginsaldo van deze spaarrekening: het deel dat bij het begin over potjes is verdeeld en het deel dat nog geen potje heeft.")
                            Button("Naar Potjes") { model.selection = .pots }.controlSize(.small)
                        }
                    }
                }
            }
            HStack(spacing: 8) {
                Button(isNew ? "Voeg toe" : "Bewaar") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!isNew && !isDirty)
                if isNew {
                    Button("Annuleer", action: onCancel)
                } else {
                    Button("Herstel") { draft = account; opening = account.openingBalance; onChanged(true) }
                        .disabled(!isDirty)
                    Spacer()
                    Button(account.archived ? "Uit archief halen" : "Archiveer") { setArchived(!account.archived) }
                        .help("Een gearchiveerde rekening verdwijnt uit de keuzelijsten; de boekingen blijven.")
                    Button(role: .destructive) { confirmDelete = true } label: { Image(systemName: "trash") }
                        .help("Rekening verwijderen (alleen als hij nergens gebruikt wordt)")
                }
            }
            .padding(.top, 4)
        }
    }

    private static func splitText(_ split: OpeningOverview) -> String {
        let pots = split.potTotal.formatted()
        let rest = split.unallocated.formatted()
        return "potjes \(pots) + niet toegewezen \(rest)"
    }

    private var isDirty: Bool {
        draft != account || opening != account.openingBalance
    }

    // MARK: Afstemmen

    private var reconcile: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text("Afstemmen met de bank").font(.headline)
                Image(systemName: "questionmark.circle").foregroundStyle(.tertiary)
                    .help("Vul het saldo in dat je bank op een dag toont. HomeFinance vergelijkt het met het berekende saldo. Het verschil hoort € 0,00 te zijn.")
            }
            HStack(spacing: 8) {
                DatePicker("Dag", selection: $reconcileDay, displayedComponents: .date).labelsHidden().fixedSize()
                MoneyField("Saldo volgens de bank", value: $actual).textFieldStyle(.roundedBorder).frame(width: 150)
                    .onSubmit { runReconcile() }
                Button("Stem af") { runReconcile() }.disabled(actual == nil)
            }
            Text("Berekend saldo op \(Day(date: reconcileDay).short(withYear: true)): \(calculated.formatted())")
                .font(.callout).monospacedDigit().foregroundStyle(.secondary)
            if let last = history.first {
                SettingsReconcileResult(last: last)
                if history.count > 1 { historyList }
            } else {
                Text("Nog nooit afgestemd. Doe dit na elke import: dan weet je zeker dat er niets ontbreekt.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var calculated: Money {
        guard let id = account.id else { return .zero }
        let day = Day(date: reconcileDay)
        return model.read(.zero) { try BalanceService.balance($0, accountId: id, on: day) }
    }

    private var historyList: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Eerdere controles").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(history.dropFirst().prefix(5)) { item in
                HStack {
                    Image(systemName: item.difference.isZero ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .foregroundStyle(item.difference.isZero ? Theme.positive : Theme.negative)
                    Text(item.day.short(withYear: true)).monospacedDigit()
                    Spacer()
                    Text("bank \(item.actualBalance.formatted())").monospacedDigit().foregroundStyle(.secondary)
                    Text("verschil \(item.difference.formatted())").monospacedDigit()
                        .foregroundStyle(item.difference.isZero ? Color.secondary : Theme.negative)
                        .frame(width: 150, alignment: .trailing)
                }
                .font(.callout)
            }
            if history.count > 6 {
                Text("en \(history.count - 6) oudere").font(.caption).foregroundStyle(.tertiary)
            }
        }
        .padding(.top, 2)
    }

    // MARK: Schrijven

    private func save() {
        var next = draft
        guard let opening else {
            model.errorMessage = "Vul een geldig beginsaldo in, bijvoorbeeld 1.250,00."
            return
        }
        next.openingBalance = opening
        let ok = model.perform(isNew ? "Rekening toegevoegd" : "Rekening bewaard") {
            try model.db.write { db in
                if isNew { _ = try AccountService.create(db, next) } else { _ = try AccountService.update(db, next) }
            }
        }
        onChanged(!ok)
    }

    private func setArchived(_ archived: Bool) {
        guard let id = account.id else { return }
        let ok = model.perform(archived ? "Rekening gearchiveerd" : "Rekening uit het archief gehaald") {
            try model.db.write { db in try AccountService.setArchived(db, accountId: id, archived) }
        }
        onChanged(!ok)
    }

    private func delete() {
        guard let id = account.id else { return }
        let ok = model.perform("Rekening verwijderd") {
            try model.db.write { db in try AccountService.delete(db, accountId: id) }
        }
        onChanged(!ok)
    }

    private func runReconcile() {
        guard let id = account.id, let actual else { return }
        let day = Day(date: reconcileDay)
        let ok = model.perform {
            try model.db.write { db in _ = try BalanceService.reconcile(db, accountId: id, day: day, actualBalance: actual) }
        }
        onChanged(!ok)
    }
}

/// De laatste controle, groot: groen bij € 0,00, anders rood met een aanwijzing.
struct SettingsReconcileResult: View {
    let last: Reconciliation

    var body: some View {
        let ok = last.difference.isZero
        let color = ok ? Theme.positive : Theme.negative
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: ok ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .font(.title).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(last.difference.formatted(alwaysSign: true))
                        .font(.system(.title, design: .rounded).weight(.bold)).monospacedDigit().foregroundStyle(color)
                    Text("verschil op \(last.day.short(withYear: true))").font(.callout).foregroundStyle(.secondary)
                }
                Text("Berekend \(last.calculatedBalance.formatted()) · bank \(last.actualBalance.formatted())")
                    .font(.callout).monospacedDigit().foregroundStyle(.secondary)
                Text(ok ? "Het saldo sluit met de bank."
                        : "Het berekende saldo is \(last.difference.magnitude.formatted()) \(last.difference.isNegative ? "lager" : "hoger") dan de bank. Controleer of alle afschriften t/m deze dag zijn geïmporteerd, of er nog transacties bij Nakijken staan of zijn overgeslagen, en of het beginsaldo klopt.")
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
    }
}
