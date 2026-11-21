import SwiftUI
import GRDB
import HFCore
import HFInsight

/// Wat er nog rechtgezet moet worden, in vier blokken (UX-stap D4). Alleen lezen uit HFInsight; de cijfers zijn
/// dezelfde als op Nog overboeken, Voorgeschoten en Transacties. Rekent zelf niets.
struct SettleUpData: Equatable {
    /// Gemarkeerde boekingen die nog met spaar overgeboekt moeten worden (gesaldeerd).
    var open: OpenReimbursements?
    /// Vastgelegde overboekingen met spaar (nieuwste eerst).
    var transfers: [SavingsTransferDetail] = []
    /// Tags waarvan je nog voorgeschoten geld terugkrijgt.
    var advances: [TagSettlementSummary] = []
    /// Tijdelijk van spaar geleend en nog niet teruggeboekt.
    var loan: Money = .zero

    /// Blok 1: open boekingen, of een vastgelegde overboeking die nog niet is afgevinkt.
    var pendingTransfers: [SavingsTransferDetail] { transfers.filter { !$0.done } }
    var hasTransfer: Bool { !(open?.entries.isEmpty ?? true) || !pendingTransfers.isEmpty }
    /// Blok 4: afgevinkt, maar nog niet aan beide kanten in een bankbestand gezien (oudste eerst).
    var waitingForBank: [SavingsTransferDetail] { transfers.filter { $0.done && !$0.bankConfirmed }.reversed() }

    /// Het aantal blokken waar iets openstaat (de teller in de zijbalk).
    var openBlockCount: Int {
        [hasTransfer, !advances.isEmpty, loan > .zero, !waitingForBank.isEmpty].filter { $0 }.count
    }

    static func read(_ db: Database, today: Day) throws -> SettleUpData {
        SettleUpData(open: try Insight.openReimbursements(db),
                     transfers: try Insight.savingsTransfers(db),
                     advances: try Insight.settlementOverview(db, today: today).filter { $0.outstanding > .zero },
                     loan: try Insight.temporaryLoanOutstanding(db, on: today))
    }
}

struct SettleUpScreen: View {
    @Environment(AppModel.self) private var model
    @State private var data: SettleUpData?
    /// Alleen voor het venster "Het geld is terug…": dezelfde acties als in Transacties.
    @State private var settleStore = TransactionsStore()

    private struct ReloadKey: Hashable { let revision: Int, year: Int }

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader("Nog rechtzetten",
                         subtitle: "Alles wat nog een handeling van jou vraagt, of nog terug moet komen. Per blok staat de volgende stap.")
            if let data {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        transferBlock(data)
                        advancesBlock(data)
                        loanBlock(data)
                        bankBlock(data)
                    }
                    .frame(maxWidth: 760, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24).padding(.top, 8).padding(.bottom, 32)
                }
            } else {
                Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: ReloadKey(revision: model.revision, year: model.year)) {
            data = model.read(SettleUpData()) { try SettleUpData.read($0, today: model.today) }
            SelfTest.settleUpLoaded(blocks: 4, open: data?.openBlockCount ?? 0)
        }
        .sheet(item: $settleStore.settleTarget) { target in
            TransactionsSettleSheet(store: settleStore, target: target).environment(model)
        }
    }

    // MARK: 1. Nog overboeken

    @ViewBuilder private func transferBlock(_ data: SettleUpData) -> some View {
        block("Nog overboeken", icon: "arrow.left.arrow.right.circle", isOpen: data.hasTransfer,
              explanation: "Betaald vanaf je betaalrekening terwijl het bij een potje hoort (of andersom). Je zet het in één overboeking recht.",
              empty: "Er hoeft niets van of naar spaar overgeboekt te worden.") {
            if let open = data.open, !open.entries.isEmpty {
                step(transferStep(open), detail: TransactionsFormat.entries(open.entries.count)) {
                    Button("Afvinken bij Nog overboeken…") { model.selection = .reimbursements }
                        .help("Maak het bedrag over in je bank-app en vink het daarna af; dan worden de potjes geboekt.")
                }
            }
            ForEach(data.pendingTransfers) { transfer in
                step("Vastgelegd op \(transfer.day.short()): maak \(transfer.transferAmount.formatted()) over \(directionText(transfer.direction)) en vink af",
                     detail: TransactionsFormat.entries(transfer.entries.count)) {
                    Button("Naar Nog overboeken") { model.selection = .reimbursements }
                }
            }
        }
    }

    private func transferStep(_ open: OpenReimbursements) -> String {
        switch open.direction {
        case .fromSavings: "Maak \(open.transferAmount.formatted()) over van spaar naar betaal"
        case .toSavings: "Maak \(open.transferAmount.formatted()) over van betaal naar spaar"
        case .none: "Alleen tussen potjes: niets over te maken, wel afvinken"
        }
    }

    private func directionText(_ direction: SavingsTransferDirection) -> String {
        switch direction {
        case .fromSavings: "van spaar naar betaal"
        case .toSavings: "van betaal naar spaar"
        case .none: "tussen potjes"
        }
    }

    // MARK: 2. Voorgeschoten

    @ViewBuilder private func advancesBlock(_ data: SettleUpData) -> some View {
        block("Voorgeschoten", icon: "arrow.uturn.backward.circle", isOpen: !data.advances.isEmpty,
              explanation: "Uitgaven die je voorschiet en terugkrijgt, zoals tankkosten van je werk.",
              empty: "Je krijgt niets meer terug van voorgeschoten geld.") {
            ForEach(data.advances) { tag in
                step("Je krijgt nog \(tag.outstanding.formatted()) terug (\(tag.name))",
                     detail: TransactionsFormat.entries(tag.openCount) + (tag.oldestOpenDay.map { ", de oudste van \($0.short())" } ?? "")) {
                    Button("Het is binnen…") {
                        settleStore.settleTarget = TransactionsSettleTarget(tagId: tag.id, tagName: tag.name)
                    }
                    .help("Geef aan dat je het geld van \(tag.name) hebt teruggekregen, en met welke bijschrijving.")
                }
            }
            Button("Naar Voorgeschoten") { model.selection = .advances }.buttonStyle(.link)
        }
    }

    // MARK: 3. Tijdelijk geleend van spaar

    @ViewBuilder private func loanBlock(_ data: SettleUpData) -> some View {
        block("Tijdelijk geleend van spaar", icon: "hourglass", isOpen: data.loan > .zero,
              explanation: TransactionsFormat.loanHelp,
              empty: "Er staat niets uit van spaar.") {
            step("Er staat nog \(data.loan.formatted()) uit", detail: "Zet het terug naar spaar en markeer die overboeking als tijdelijk geleend.") {
                Button("Toon de boekingen") {
                    if let id = model.read(nil as Int64?, {
                        try Int64.fetchOne($0, sql: "SELECT id FROM account WHERE kind = 'betaal' AND archived = 0 ORDER BY sortOrder, id LIMIT 1")
                    }) {
                        model.transactionsJump = TransactionsJump(accountId: id, loanOnly: true)
                    }
                    model.selection = .transactions
                }
            }
        }
    }

    // MARK: 4. Wacht op de bank

    @ViewBuilder private func bankBlock(_ data: SettleUpData) -> some View {
        block("Wacht op de bank", icon: "building.columns", isOpen: !data.waitingForBank.isEmpty,
              explanation: "Overboekingen met spaar die je hebt afgevinkt, maar die nog niet in een bankbestand zijn gezien. Ze gaan vanzelf weg na het importeren.",
              empty: "Alles wat je hebt afgevinkt, is ook bij de bank gezien.") {
            ForEach(data.waitingForBank) { transfer in
                step("Afgevinkt: \(transfer.transferAmount.formatted()) \(directionText(transfer.direction)) (\(transfer.day.short()))",
                     detail: transfer.unconfirmedSince.map { since in
                         since.adding(days: 5) <= model.today ? "Al meer dan 5 dagen niet gezien. Klopt de overboeking bij de bank?" : "Nog niet in een bankbestand gezien."
                     } ?? "Nog niet in een bankbestand gezien.") {
                    Button("Importeer een bankbestand") { model.selection = .review }
                }
            }
        }
    }

    // MARK: Opmaak

    private func block<Content: View>(_ title: String, icon: String, isOpen: Bool, explanation: String, empty: String,
                                      @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: isOpen ? icon : "checkmark.circle").foregroundStyle(isOpen ? Theme.accent : Theme.positive)
                Text(title).font(.title3.weight(.semibold))
                Spacer(minLength: 0)
            }
            Text(explanation).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if isOpen {
                content()
            } else {
                Text(empty).font(.callout)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.hairline.opacity(0.5)))
        .selfTestProbe("rechtzetten-blok-\(title)")
    }

    private func step<Action: View>(_ text: String, detail: String, @ViewBuilder action: () -> Action) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                stepText(text, detail: detail)
                Spacer(minLength: 8)
                action()
            }
            VStack(alignment: .leading, spacing: 6) {
                stepText(text, detail: detail)
                action()
            }
        }
    }

    private func stepText(_ text: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(text).fontWeight(.medium).fixedSize(horizontal: false, vertical: true)
            Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
