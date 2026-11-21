import SwiftUI
import Charts
import HFCore
import HFInsight

// MARK: - Aandacht

/// Wat er nog moet gebeuren, elk met een knop naar het juiste scherm.
struct DashboardAttentionCard: View {
    @Environment(AppModel.self) private var model
    let items: [AttentionItem]
    /// Opent een detail van het dashboard (bv. de vaste posten).
    var openDetail: (DashboardDetail) -> Void = { _ in }

    var body: some View {
        DashboardCard("Aandacht", icon: "bell.badge") {
            if !items.isEmpty { Text("\(items.count)").font(.callout).foregroundStyle(.secondary).monospacedDigit() }
        } content: {
            if items.isEmpty {
                DashboardQuietState(icon: "checkmark.circle.fill", title: "Alles is bijgewerkt", tint: Theme.accent)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                        if index > 0 { Divider().padding(.leading, 38) }
                        row(item)
                    }
                }
            }
        }
    }

    private func row(_ item: AttentionItem) -> some View {
        let look = DashboardAttentionLook(item)
        return HStack(alignment: .center, spacing: 10) {
            Image(systemName: look.icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(look.tint)
                .frame(width: 28, height: 28)
                .background(look.tint.opacity(0.12), in: Circle())
            Text(item.message)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let action = look.action {
                Button(action) { go(look) }
                    .controlSize(.small)
                    .help(look.help)
            }
        }
        .padding(.vertical, 9)
    }

    private func go(_ look: DashboardAttentionLook) {
        if let detail = look.detail { openDetail(detail); return }
        if let tab = look.settingsTab { model.settingsTab = tab }
        model.selection = look.target
    }
}

/// Pictogram, kleur en bestemming van een aandachtspunt.
private struct DashboardAttentionLook {
    let icon: String
    let tint: Color
    /// Tekst van de knop; nil = geen knop.
    let action: String?
    let help: String
    let target: Screen
    var settingsTab: String?
    /// Opent dit detail van het dashboard in plaats van `target`.
    var detail: DashboardDetail?

    init(_ item: AttentionItem) {
        switch item {
        case .newBankTransactions:
            icon = "tray.full"; tint = .secondary; action = "Boeken"; target = .review
            help = "Ga naar Importeren en nakijken om deze banktransacties een post of potje te geven."
        case .unreviewedEntries:
            icon = "eye"; tint = .secondary; action = "Controleren"; target = .transactions
            help = "Ga naar Transacties om de automatisch geboekte regels te controleren."
        case .openReimbursements:
            icon = "arrow.left.arrow.right"; tint = .secondary; action = "Overboeken"; target = .reimbursements
            help = "Uitgaven die je van de betaalrekening hebt betaald maar die uit een spaarpotje horen te komen."
        case .reconciliationDiffers:
            icon = "exclamationmark.triangle.fill"; tint = Theme.negative; action = "Afstemmen"; target = .settings
            settingsTab = "rekeningen"
            help = "Afstemmen is het berekende saldo vergelijken met het saldo bij de bank. Het verschil hoort € 0,00 te zijn."
        case .reconciliationOld:
            icon = "clock.arrow.circlepath"; tint = .secondary; action = "Afstemmen"; target = .settings
            settingsTab = "rekeningen"
            help = "Afstemmen is het berekende saldo vergelijken met het saldo bij de bank. Doe dit ongeveer elke maand."
        case .openSettlement:
            icon = "arrow.uturn.left.circle"; tint = .secondary; action = "Bekijk"; target = .tags
            help = "Uitgaven met deze tag waarvan je het geld nog terugkrijgt."
        case .unconfirmedSettlement, .unconfirmedSettlements:
            icon = "questionmark.circle"; tint = Theme.warning; action = "Bekijk"; target = .reimbursements
            help = "Je hebt deze overboeking met spaar afgevinkt, maar hij is nog niet in een bankbestand gezien. Controleer of je hem hebt overgemaakt, of importeer een nieuw bankbestand."
        case .temporaryLoanOutstanding:
            icon = "arrow.uturn.backward.circle"; tint = Theme.warning; action = "Bekijk"; target = .transactions
            help = "Dit bedrag heb je tijdelijk van spaar naar de betaalrekening gehaald. Het telt niet mee in vrij te besteden tot je het terugboekt en die boeking ook markeert als tijdelijk geleend."
        case .yearMissing:
            icon = "calendar.badge.plus"; tint = .secondary; action = "Aanmaken"; target = .budget
            help = "Maak het begrotingsjaar aan bij Posten."
        case .fixedItemsLate:
            icon = "clock"; tint = Theme.negative; action = "Bekijk"; target = .dashboard; detail = .fixedItems
            help = "De verwachte dag is voorbij en er is nog niets geboekt."
        case .largeExpenseComing:
            icon = "exclamationmark.circle"; tint = Theme.warning; action = "Bekijk"; target = .dashboard; detail = .fixedItems
            help = "Een grote uitgave die niet elke maand komt, wordt later deze maand verwacht."
        case .bufferNotReached:
            icon = "exclamationmark.triangle.fill"; tint = Theme.negative; action = nil; target = .dashboard
            help = "Nog te besteden deze maand is negatief."
        case .potGoalsBehind:
            icon = "target"; tint = Theme.warning; action = "Bekijk"; target = .pots
            help = "Met de huidige stortingen haal je dit spaardoel niet op tijd."
        case .importBalanceDiffers:
            icon = "exclamationmark.triangle.fill"; tint = Theme.negative; action = "Afstemmen"; target = .settings
            settingsTab = "rekeningen"
            help = "Het eindsaldo in het bankbestand is niet gelijk aan het saldo volgens de app."
        case .importOld:
            icon = "tray.and.arrow.down"; tint = .secondary; action = "Importeren"; target = .review
            help = "Importeer een nieuw bankbestand."
        }
    }
}

// MARK: - Vaste posten

/// Filter in / uit / alles op de pagina's achter de kaartjes.
enum DashboardInOutFilter: String, CaseIterable, Identifiable {
    case alles, inkomsten, uitgaven
    var id: String { rawValue }
    var title: String {
        switch self {
        case .alles: "Alles"
        case .inkomsten: "In"
        case .uitgaven: "Uit"
        }
    }
}

/// De pagina achter het kaartje Periodieke transacties: wat er nog komt en wat al verwerkt is, inkomsten en
/// uitgaven apart. Nooit € 0,00: altijd het plan, en bij een verwerkte post het werkelijke bedrag.
struct DashboardFixedItemsPage: View {
    let overview: FixedItemsOverview
    @State private var filter: DashboardInOutFilter = .alles

    private var incomeItems: [FixedItemStatus] { overview.items.filter { $0.direction == .IN } }
    private var expenseItems: [FixedItemStatus] { overview.items.filter { $0.direction != .IN } }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacing) {
            summary
            Picker("Toon", selection: $filter) {
                ForEach(DashboardInOutFilter.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 240)
            if overview.items.isEmpty {
                DashboardQuietState(icon: "calendar", title: "Geen vaste posten deze maand")
            }
            if filter != .uitgaven, !incomeItems.isEmpty { section("Inkomsten", incomeItems) }
            if filter != .inkomsten, !expenseItems.isEmpty { section("Uitgaven", expenseItems) }
        }
    }

    /// Nog binnen te komen, nog af te gaan en het saldo daarvan.
    private var summary: some View {
        HStack(spacing: Theme.spacing) {
            figure("Nog binnen te komen", overview.incomeExpected)
            figure("Nog af te gaan", overview.expensesExpected.magnitude)
            figure("Saldo", overview.expectedNet, colored: true)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func figure(_ title: String, _ amount: Money, colored: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.callout)
            MoneyText(amount, colored: colored, alwaysSign: colored)
                .font(.system(.title2, design: .rounded).weight(.semibold))
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.hairline.opacity(0.6)))
    }

    private func section(_ title: String, _ items: [FixedItemStatus]) -> some View {
        let coming = items.filter { $0.state == .teLaat } + items.filter { $0.state == .open }
        let done = items.filter { $0.state == .voldaan }
        return DashboardCard(title, icon: title == "Inkomsten" ? "arrow.down.circle" : "arrow.up.circle") {
            EmptyView()
        } content: {
            VStack(alignment: .leading, spacing: 0) {
                if !coming.isEmpty {
                    groupTitle("Nog te komen")
                    rows(coming)
                }
                if !done.isEmpty {
                    groupTitle("Verwerkt").padding(.top, coming.isEmpty ? 0 : 10)
                    rows(done)
                }
            }
        }
    }

    private func groupTitle(_ text: String) -> some View {
        Text(text).font(.callout.weight(.semibold)).padding(.bottom, 4)
    }

    private func rows(_ items: [FixedItemStatus]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                if index > 0 { Divider() }
                row(item)
            }
        }
    }

    private func row(_ item: FixedItemStatus) -> some View {
        HStack(spacing: 8) {
            Text(item.label).font(.callout).lineLimit(1)
            Spacer(minLength: 4)
            status(item)
            amounts(item).frame(minWidth: 180, alignment: .trailing)
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder private func status(_ item: FixedItemStatus) -> some View {
        switch item.state {
        case .teLaat:
            Pill("te laat", color: Theme.negative, icon: "clock")
        case .open:
            Text(item.expectedDay.map { "rond de \($0)e" } ?? "deze maand").font(.callout)
        case .voldaan:
            if item.entryCount == 0 {
                Pill("afgevinkt", color: Theme.info, icon: "checkmark")
            } else {
                Text(item.day.map { "verwerkt \($0.short())" } ?? "verwerkt").font(.callout)
            }
        }
    }

    /// Plan, en bij een verwerkte post met boeking het werkelijke bedrag.
    @ViewBuilder private func amounts(_ item: FixedItemStatus) -> some View {
        if item.state == .voldaan, item.entryCount > 0, item.actual != item.plan {
            HStack(spacing: 6) {
                if !item.plan.isZero {
                    Text("plan \(item.plan.formatted())").font(.caption).monospacedDigit()
                }
                MoneyText(item.actual, colored: true).font(.callout.weight(.semibold))
            }
        } else {
            MoneyText(item.plan, colored: true).font(.callout.weight(item.state == .voldaan ? .semibold : .regular))
        }
    }
}

// MARK: - Incidentele transacties

/// De pagina achter het kaartje Incidentele transacties: drie kaartjes (totalen, uitgaven per tag, de vijf
/// grootste uitgaven) en daaronder alle transacties, te sorteren en te filteren. Geen links naar andere pagina's.
struct DashboardIncidentalPage: View {
    let month: IncidentalMonth
    let width: CGFloat
    @State private var filter: DashboardInOutFilter = .alles
    @State private var sort: EntrySort = .dayDescending

    private static let sorts: [(EntrySort, String)] = [
        (.dayDescending, "Datum, nieuwste eerst"), (.dayAscending, "Datum, oudste eerst"),
        (.amountAscending, "Bedrag, oplopend"), (.amountDescending, "Bedrag, aflopend"),
    ]

    private var sign: AmountSign? {
        switch filter {
        case .alles: nil
        case .inkomsten: .positive
        case .uitgaven: .negative
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacing) {
            if width >= 900 {
                HStack(alignment: .top, spacing: Theme.spacing) { totals; byTag; largest }
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                totals; byTag; largest
            }
            list
        }
    }

    private var totals: some View {
        DashboardCard("Totalen", icon: "sum") {
            VStack(alignment: .leading, spacing: 6) {
                DashboardCardRow("In") { MoneyText(month.summary.income) }
                DashboardCardRow("Uit") { MoneyText(month.summary.expenses.magnitude) }
                Divider()
                DashboardCardRow("Saldo") { MoneyText(month.summary.net, colored: true, alwaysSign: true).fontWeight(.semibold) }
            }
            .font(.callout)
        }
    }

    private var byTag: some View {
        DashboardCard("Uitgaven per tag", icon: "tag") {
            VStack(alignment: .leading, spacing: 6) {
                if month.expensesByTag.buckets.isEmpty { Text("Geen uitgaven") }
                ForEach(month.expensesByTag.buckets) { bucket in
                    HStack(spacing: 6) {
                        Circle().fill(bucket.color.map { Color(hex: $0) } ?? Color.secondary.opacity(0.4))
                            .frame(width: 8, height: 8)
                        DashboardCardRow(bucket.name) { MoneyText(bucket.total.magnitude) }
                    }
                }
            }
            .font(.callout)
        }
    }

    private var largest: some View {
        DashboardCard("5 grootste uitgaven", icon: "arrow.up.circle") {
            VStack(alignment: .leading, spacing: 6) {
                if month.summary.largestExpenses.isEmpty { Text("Geen uitgaven") }
                ForEach(month.summary.largestExpenses) { entry in
                    DashboardCardRow(DashboardFormat.entryTitle(entry)) { MoneyText(entry.amount.magnitude) }
                }
            }
            .font(.callout)
        }
    }

    private var list: some View {
        let rows = month.list(sign: sign, sort: sort)
        return DashboardCard("Alle transacties", icon: "list.bullet") {
            HStack(spacing: 10) {
                Picker("Toon", selection: $filter) {
                    ForEach(DashboardInOutFilter.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 200)
                Picker("Sorteer", selection: $sort) {
                    ForEach(Self.sorts, id: \.0) { Text($0.1).tag($0.0) }
                }
                .labelsHidden().frame(width: 190)
            }
        } content: {
            if rows.isEmpty {
                DashboardQuietState(icon: "tray", title: "Geen transacties")
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, entry in
                        if index > 0 { Divider() }
                        HStack(spacing: 10) {
                            Text(entry.day.short()).monospacedDigit().frame(width: 52, alignment: .leading)
                            Text(DashboardFormat.entryTitle(entry)).lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            ForEach(entry.tags.prefix(2)) { Pill($0.name, color: Color(hex: $0.color)) }
                            MoneyText(entry.amount, colored: true).frame(width: 100, alignment: .trailing)
                        }
                        .font(.callout)
                        .padding(.vertical, 5)
                    }
                }
            }
        }
    }
}
