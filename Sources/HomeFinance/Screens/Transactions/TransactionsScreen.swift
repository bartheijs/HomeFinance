import SwiftUI
import HFCore
import HFInsight

/// Startscherm in de stijl van een bank-app: bovenaan de rekeningen met saldo, daaronder alle transacties
/// van de gekozen rekening van nieuw naar oud. Klik op een regel voor het detail.
struct TransactionsScreen: View {
    @Environment(AppModel.self) private var model
    @State private var store = TransactionsStore()
    @State private var showNewEntry = false
    @State private var searchedText = ""
    @FocusState private var searchFocused: Bool

    private struct ReloadKey: Equatable {
        var revision: Int
        var year: Int
        var accountId: Int64?
        var criteria: TransactionsCriteria
    }

    var body: some View {
        @Bindable var store = store
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                ScreenHeader("Transacties") {
                    Button {
                        showNewEntry = true
                    } label: {
                        Label("Nieuwe boeking", systemImage: "plus")
                    }
                    .keyboardShortcut("n", modifiers: .command)
                    .help("Iets met de hand toevoegen dat niet via de bank liep (⌘N)")
                }
                VStack(alignment: .leading, spacing: 14) {
                    accountCards
                    TransactionsFilterBar(store: store, searchFocused: $searchFocused)
                    if let summary = store.summary, summary.count > 0 {
                        TransactionsSummaryLine(store: store, summary: summary)
                    }
                    if !store.pendingAll.isEmpty { newBanner }
                    if store.kind == .betaal, store.loanOutstanding > .zero { loanBanner }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 8)
                content
            }
            .frame(maxWidth: .infinity)
            if store.showDetail {
                Divider()
                TransactionsDetailPanel(store: store)
                    .frame(width: 350)
                    .transition(.move(edge: .trailing))
            }
        }
        .animation(.easeInOut(duration: 0.18), value: store.showDetail)
        .background {
            Button("Zoek") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
        }
        .task(id: ReloadKey(revision: model.revision, year: model.year, accountId: store.accountId, criteria: store.criteria)) {
            // Tijdens het typen even wachten, zodat niet elke letter een zoekopdracht is.
            if store.criteria.text != searchedText {
                searchedText = store.criteria.text
                try? await Task.sleep(for: .milliseconds(220))
                if Task.isCancelled { return }
            }
            store.reload(model)
        }
        .onChange(of: store.selection) { _, _ in store.selectionChanged(model) }
        .sheet(isPresented: $showNewEntry) {
            TransactionsNewEntrySheet(store: store).environment(model)
        }
        .sheet(item: $store.splitTarget) { target in
            TransactionsSplitSheet(store: store, target: target).environment(model)
        }
        .sheet(item: $store.noteTarget) { row in
            TransactionsNoteSheet(store: store, row: row).environment(model)
        }
    }

    // MARK: Rekeningen

    private var accountCards: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(store.lookups.accounts) { account in
                    let selected = account.id == store.accountId
                    Button {
                        store.selectAccount(account.id)
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 6) {
                                Image(systemName: account.kind == .betaal ? "creditcard" : "banknote")
                                    .foregroundStyle(selected ? Theme.accent : Color.secondary)
                                Text(account.name).lineLimit(1)
                                    .foregroundStyle(selected ? Color.primary : Color.secondary)
                            }
                            .font(.callout)
                            Text(account.balance.formatted())
                                .font(.system(size: 24, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(account.balance.isNegative ? Theme.negative : Color.primary)
                            Text(account.newBankTransactionCount > 0
                                 ? "\(TransactionsFormat.number(account.newBankTransactionCount)) nieuw"
                                 : (account.kind == .betaal ? "Betaalrekening" : "Spaarrekening"))
                                .font(.caption)
                                .foregroundStyle(account.newBankTransactionCount > 0 ? Theme.info : Color.secondary)
                        }
                        .padding(.horizontal, 16).padding(.vertical, 12)
                        .frame(minWidth: 220, alignment: .leading)
                        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
                        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius)
                            .strokeBorder(selected ? Theme.accent : Theme.hairline.opacity(0.5), lineWidth: selected ? 2 : 1))
                        .contentShape(RoundedRectangle(cornerRadius: Theme.cardRadius))
                    }
                    .buttonStyle(.plain)
                    .help("Saldo van \(account.name) volgens de boekingen tot en met vandaag. Klik om de transacties van deze rekening te zien.")
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .padding(.vertical, 1)
        }
    }

    /// Eén regel boven de feed, alleen als er nieuwe transacties zijn.
    private var newBanner: some View {
        let count = store.pendingAll.count
        let certain = store.certainPending.count
        return HStack(spacing: 10) {
            Circle().fill(Theme.info).frame(width: 7, height: 7)
            Text("\(TransactionsFormat.number(count)) nieuwe \(count == 1 ? "transactie" : "transacties")")
                .fontWeight(.medium)
            if certain > 0 {
                Button(certain == count ? "Boek alle \(certain)" : "Boek de \(certain) zekere") { store.bookAllCertain(model) }
                    .buttonStyle(.link)
                    .help("Boekt in één keer de nieuwe transacties waarbij tegenpartij en bedrag precies bij een regel passen")
            }
            Spacer(minLength: 0)
            if store.criteria.status != .newOnly {
                Button("Toon alleen nieuw") { store.criteria.status = .newOnly }
                    .buttonStyle(.link)
            }
        }
        .font(.callout)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Theme.info.opacity(0.09), in: RoundedRectangle(cornerRadius: 9))
    }

    /// Eén rustige regel zolang er geld van spaar geleend is dat nog niet is teruggeboekt.
    private var loanBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "hourglass").foregroundStyle(.secondary)
            Text("\(store.loanOutstanding.formatted()) tijdelijk geleend van spaar staat nog uit")
            if !store.criteria.loanOnly {
                Button("Toon deze boekingen") { store.criteria.loanOnly = true }
                    .buttonStyle(.link)
                    .help("Filtert de lijst op de boekingen die als tijdelijk geleend gemarkeerd zijn")
            }
            Spacer(minLength: 0)
        }
        .font(.callout)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 9))
        .help(TransactionsFormat.loanHelp)
    }

    // MARK: Inhoud

    @ViewBuilder private var content: some View {
        if !store.hasLoaded {
            Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !store.items.isEmpty {
            TransactionsFeed(store: store)
                .padding(.horizontal, 8)
        } else if store.criteria.hasFilters {
            EmptyState(title: "Niets gevonden",
                       message: "Geen enkele transactie op deze rekening past bij je zoekopdracht of filters.",
                       icon: "magnifyingglass",
                       actionTitle: "Wis filters") { store.criteria.clear() }
        } else {
            EmptyState(title: "Nog geen transacties",
                       message: "Op \(store.account?.name ?? "deze rekening") staat nog niets. Importeer het afschrift van je bank; daarna zie je hier alle transacties en boek je ze met één klik.",
                       icon: "tray.and.arrow.down",
                       actionTitle: "Importeer je bankafschrift") { model.selection = .review }
        }
    }
}
