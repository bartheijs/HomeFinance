import SwiftUI
import GRDB
import HFCore
import HFInsight

/// Te doen (was "Nog rechtzetten"): wat nog een handeling vraagt, in hoogstens drie kaartjes. Een kaartje staat er
/// alleen als er iets in staat. Alleen lezen uit HFInsight; de cijfers zijn dezelfde als op Nog overboeken, Tags
/// en Transacties. Rekent zelf niets.
struct SettleUpData: Equatable {
    /// Gemarkeerde boekingen die nog met spaar overgeboekt moeten worden (gesaldeerd).
    var open: OpenReimbursements?
    /// Vastgelegde overboekingen met spaar (nieuwste eerst).
    var transfers: [SavingsTransferDetail] = []
    /// Tags met "Krijg ik terug" waarvan nog iets terug te ontvangen is.
    var advances: [TagSettlementSummary] = []
    /// Tijdelijk van spaar geleend en nog niet teruggeboekt.
    var loan: Money = .zero

    /// Vastgelegd maar nog niet afgevinkt.
    var pendingTransfers: [SavingsTransferDetail] { transfers.filter { !$0.done } }
    /// Afgevinkt, maar nog niet aan beide kanten in een bankbestand gezien (oudste eerst).
    var waitingForBank: [SavingsTransferDetail] { transfers.filter { $0.done && !$0.bankConfirmed }.reversed() }
    /// Kaartje Nog overboeken: nog over te maken (open boekingen of een niet-afgevinkte overboeking), of afgevinkt
    /// en wachtend op de bank.
    var hasTransfer: Bool {
        !(open?.entries.isEmpty ?? true) || !pendingTransfers.isEmpty || !waitingForBank.isEmpty
    }

    /// De kaartjes die er staan, in volgorde (de zelftest kijkt of ze in beeld zijn).
    var cards: [String] {
        (hasTransfer ? ["Nog overboeken"] : []) + (advances.isEmpty ? [] : ["Terug te ontvangen"])
            + (loan > .zero ? ["Tijdelijk geleend van spaar"] : [])
    }

    /// Het aantal kaartjes (de teller in de zijbalk).
    var openBlockCount: Int { cards.count }

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

    private struct ReloadKey: Hashable { let revision: Int, year: Int }

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader("Te doen")
            if let data {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if data.cards.isEmpty {
                            Text("Er is niets te doen.").font(.title3)
                                .selfTestProbe("rechtzetten-blok-leeg")
                        }
                        if data.hasTransfer { transferBlock(data) }
                        if !data.advances.isEmpty { advancesBlock(data) }
                        if data.loan > .zero { loanBlock(data) }
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
            SelfTest.settleUpLoaded(blocks: max(data?.cards.count ?? 0, 1), open: data?.openBlockCount ?? 0)
        }
    }

    // MARK: Nog overboeken (met de status per regel)

    @ViewBuilder private func transferBlock(_ data: SettleUpData) -> some View {
        block("Nog overboeken", icon: "arrow.left.arrow.right.circle") {
            if let open = data.open, !open.entries.isEmpty {
                step(transferStep(open), detail: TransactionsFormat.entries(open.entries.count)) {
                    Button("Afvinken…") { model.selection = .reimbursements }
                        .help("Maak het bedrag over in je bank-app en vink het daarna af bij Nog overboeken.")
                }
            }
            ForEach(data.pendingTransfers) { transfer in
                step("Nog overmaken: \(transfer.transferAmount.formatted()) \(directionText(transfer.direction))",
                     detail: "Vastgelegd op \(transfer.day.short())") {
                    Button("Afvinken…") { model.selection = .reimbursements }
                }
            }
            ForEach(data.waitingForBank) { transfer in
                step("Afgevinkt, wacht op de bank: \(transfer.transferAmount.formatted()) \(directionText(transfer.direction))",
                     detail: transfer.day.short(), muted: true) {
                    EmptyView()
                }
            }
        }
    }

    private func transferStep(_ open: OpenReimbursements) -> String {
        switch open.direction {
        case .fromSavings: "Nog overmaken: \(open.transferAmount.formatted()) van spaar naar betaal"
        case .toSavings: "Nog overmaken: \(open.transferAmount.formatted()) van betaal naar spaar"
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

    // MARK: Terug te ontvangen

    @ViewBuilder private func advancesBlock(_ data: SettleUpData) -> some View {
        block("Terug te ontvangen", icon: "arrow.uturn.backward.circle") {
            ForEach(data.advances) { tag in
                step("\(tag.name): \(tag.outstanding.formatted())", detail: "Tag de terugbetaling met \(tag.name).") {
                    EmptyView()
                }
            }
        }
    }

    // MARK: Tijdelijk geleend van spaar

    @ViewBuilder private func loanBlock(_ data: SettleUpData) -> some View {
        block("Tijdelijk geleend van spaar", icon: "hourglass") {
            step("Nog terug naar spaar: \(data.loan.formatted())", detail: "Markeer die overboeking als tijdelijk geleend.") {
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

    // MARK: Opmaak

    private func block<Content: View>(_ title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: icon).foregroundStyle(Theme.accent)
                Text(title).font(.title3.weight(.semibold))
                Spacer(minLength: 0)
            }
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.hairline.opacity(0.5)))
        .selfTestProbe("rechtzetten-blok-\(title)")
    }

    private func step<Action: View>(_ text: String, detail: String, muted: Bool = false,
                                    @ViewBuilder action: () -> Action) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                stepText(text, detail: detail, muted: muted)
                Spacer(minLength: 8)
                action()
            }
            VStack(alignment: .leading, spacing: 6) {
                stepText(text, detail: detail, muted: muted)
                action()
            }
        }
    }

    /// Een afgevinkte regel die op de bank wacht, staat grijs.
    private func stepText(_ text: String, detail: String, muted: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(text).fontWeight(.medium).fixedSize(horizontal: false, vertical: true)
            Text(detail).font(.caption).fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(muted ? Color.secondary : Color.primary)
    }
}
