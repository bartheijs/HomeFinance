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

/// Vaste posten van deze maand: hoeveel er binnen zijn en welke nog komen.
struct DashboardFixedItemsCard: View {
    @Environment(AppModel.self) private var model
    let overview: FixedItemsOverview
    /// Toon alle posten, ook de voldane (detailweergave).
    var showAll = false

    private var maxRows: Int { showAll ? Int.max : 4 }
    private var pending: [FixedItemStatus] {
        overview.items.filter { $0.state == .teLaat } + overview.items.filter { $0.state == .open }
            + (showAll ? overview.items.filter { $0.state == .voldaan } : [])
    }
    private var total: Int { overview.paidCount + overview.openCount + overview.lateCount }

    var body: some View {
        DashboardCard("Vaste posten deze maand", icon: "checklist",
                      help: "Vaste posten zijn de inkomsten en uitgaven die elke maand, elk kwartaal of elk jaar terugkomen, zoals salaris, huur en verzekeringen.") {
            Button { model.selection = .grid } label: {
                Image(systemName: "arrow.up.right")
            }
            .buttonStyle(.borderless)
            .help("Open het maandgrid")
        } content: {
            if total == 0 {
                DashboardQuietState(icon: "calendar", title: "Geen vaste posten deze maand",
                                    message: "Voeg vaste posten toe bij Posten.")
            } else {
                progress
                if pending.isEmpty {
                    DashboardQuietState(icon: "checkmark.circle.fill", title: "Alles is binnen",
                                        message: "Alle vaste posten van deze maand zijn geboekt.", tint: Theme.positive)
                } else {
                    list
                }
            }
        }
    }

    private var progress: some View {
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geo in
                let unit = (geo.size.width - 4) / CGFloat(max(total, 1))
                HStack(spacing: 2) {
                    segment(overview.paidCount, unit, Theme.positive)
                    segment(overview.lateCount, unit, Theme.negative)
                    segment(overview.openCount, unit, Color.secondary.opacity(0.3))
                }
                .clipShape(Capsule())
            }
            .frame(height: 8)
            HStack(spacing: 12) {
                legend(overview.paidCount, "voldaan", Theme.positive, "Geboekt: betaald of ontvangen.")
                legend(overview.lateCount, "te laat", Theme.negative, "De verwachte dag is voorbij en er is nog niets geboekt.")
                legend(overview.openCount, "nog verwacht", Color.secondary.opacity(0.5), "Wordt later deze maand verwacht.")
                Spacer(minLength: 0)
            }
        }
    }

    @ViewBuilder private func segment(_ count: Int, _ unit: CGFloat, _ color: Color) -> some View {
        if count > 0 { Rectangle().fill(color).frame(width: max(unit * CGFloat(count), 3)) }
    }

    private func legend(_ count: Int, _ text: String, _ color: Color, _ help: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text("\(count)").fontWeight(.semibold).monospacedDigit()
            Text(text).foregroundStyle(.secondary)
        }
        .font(.caption)
        .lineLimit(1)
        .help(help)
    }

    private func caption(_ item: FixedItemStatus) -> String {
        if item.state == .voldaan { return item.day.map { "geboekt op \($0.short())" } ?? "geboekt" }
        return item.expectedDay.map { "verwacht rond de \($0)e" } ?? "deze maand verwacht"
    }

    private var list: some View {
        VStack(spacing: 0) {
            ForEach(Array(pending.prefix(maxRows).enumerated()), id: \.element.id) { index, item in
                if index > 0 { Divider() }
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.label).font(.callout).lineLimit(1)
                        Text(caption(item)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    if item.state == .teLaat { Pill("te laat", color: Theme.negative, icon: "clock") }
                    if item.state == .voldaan {
                        Image(systemName: "checkmark").font(.caption).foregroundStyle(.secondary)
                    }
                    MoneyText(item.state == .voldaan ? item.actual : item.plan).font(.callout)
                }
                .padding(.vertical, 5)
            }
            Divider()
            HStack {
                if pending.count > maxRows {
                    Text("en nog \(pending.count - maxRows) in het maandgrid").foregroundStyle(.secondary)
                } else {
                    Text("Nog te verwachten").foregroundStyle(.secondary)
                }
                Spacer()
                MoneyText(overview.outstandingTotal, colored: true).fontWeight(.semibold)
            }
            .font(.caption)
            .padding(.top, 7)
            .help("Het plan van alle posten die nog open of te laat zijn.")
        }
    }
}

// MARK: - Deze maand

/// Inkomsten en uitgaven van deze maand tegen het plan.
struct DashboardMonthCard: View {
    let dashboard: Dashboard
    /// Resultaat van de lopende maand (IN + UIT), als het bekend is.
    let result: Money?

    private var monthProgress: Double {
        Double(dashboard.today.day) / Double(DashboardFormat.daysInMonth(dashboard.today))
    }

    var body: some View {
        DashboardCard("Deze maand", icon: "calendar",
                      help: "Alles wat deze maand op de betaalrekening is geboekt, vergeleken met het plan van de vaste posten die deze maand verwacht worden.") {
            Text("dag \(dashboard.today.day) van \(DashboardFormat.daysInMonth(dashboard.today))")
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
        } content: {
            VStack(alignment: .leading, spacing: 16) {
                bar("Inkomsten", actual: dashboard.monthIncome, plan: dashboard.planIncome, color: Theme.positive, isExpense: false)
                bar("Uitgaven", actual: dashboard.monthExpenses, plan: dashboard.planExpenses, color: Theme.negative, isExpense: true)
                if let result {
                    Divider()
                    HStack {
                        Text("Resultaat tot nu toe").font(.callout)
                        Spacer()
                        MoneyText(result, colored: true, alwaysSign: true).font(.callout.weight(.semibold))
                    }
                    .help("Inkomsten min uitgaven van deze maand tot en met vandaag.")
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func bar(_ title: String, actual: Money, plan: Money, color: Color, isExpense: Bool) -> some View {
        // De balk loopt tot het grootste van plan en werkelijk; een streepje geeft het plan aan.
        let scale = max(actual.magnitude, plan.magnitude)
        let over = isExpense && actual.magnitude > plan.magnitude && !plan.isZero
        return VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.callout)
                if over {
                    Pill("boven plan", color: Theme.warning)
                        .help("Er is meer uitgegeven dan de vaste posten van deze maand. Dat komt meestal door overige uitgaven.")
                }
                Spacer()
                Text(actual.magnitude.formatted()).font(.callout.weight(.semibold)).monospacedDigit()
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.15))
                    Capsule().fill(color)
                        .frame(width: actual.isZero ? 0 : max(6, geo.size.width * DashboardFormat.fraction(actual, of: scale)))
                    if !plan.isZero {
                        RoundedRectangle(cornerRadius: 1).fill(Color.primary.opacity(0.75))
                            .frame(width: 2, height: 16)
                            .offset(x: min(geo.size.width - 2, geo.size.width * DashboardFormat.fraction(plan, of: scale)))
                            .help("Plan: \(plan.magnitude.formatted())")
                    }
                }
                .frame(height: 16)
            }
            .frame(height: 16)
            HStack {
                Text(plan.isZero ? "geen plan deze maand" : "plan \(plan.magnitude.formatted())")
                Spacer()
                if !plan.isZero {
                    Text("\(Int((actual.magnitude.doubleValue / plan.magnitude.doubleValue * 100).rounded())) % van plan")
                }
            }
            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
    }
}

// MARK: - Top-tags

/// De grootste tags van deze maand.
struct DashboardTopTagsCard: View {
    @Environment(AppModel.self) private var model
    let tags: [TagAmount]
    let month: Int

    private var largest: Money { tags.map(\.total.magnitude).max() ?? .zero }

    var body: some View {
        DashboardCard("Top-tags deze maand", icon: "tag",
                      help: "Tags zijn labels op boekingen, zoals tanken of uit eten, om uitgaven te volgen die door meerdere posten heen lopen.") {
            Button { model.selection = .reports } label: { Image(systemName: "arrow.up.right") }
                .buttonStyle(.borderless)
                .help("Open Rapporten")
        } content: {
            if tags.isEmpty {
                DashboardQuietState(icon: "tag", title: "Nog geen tags in \(Day.monthNames[month - 1])",
                                    message: "Geef boekingen een tag bij het nakijken om hier je grootste uitgaven te zien.")
            } else {
                VStack(spacing: 10) {
                    ForEach(tags) { tag in
                        VStack(spacing: 4) {
                            HStack(spacing: 6) {
                                Circle().fill(Color(hex: tag.color)).frame(width: 8, height: 8)
                                Text(tag.name).font(.callout).lineLimit(1)
                                Text("\(tag.count)×").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                                Spacer(minLength: 4)
                                MoneyText(tag.total).font(.callout)
                            }
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(Color.secondary.opacity(0.12))
                                    Capsule().fill(Color(hex: tag.color).opacity(0.85))
                                        .frame(width: max(4, geo.size.width * DashboardFormat.fraction(tag.total, of: largest)))
                                }
                            }
                            .frame(height: 5)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }
}

// MARK: - Recente boekingen

/// De laatste boekingen; een klik opent Transacties.
struct DashboardRecentCard: View {
    @Environment(AppModel.self) private var model
    let entries: [EntryRow]
    let showAccount: Bool

    var body: some View {
        DashboardCard("Recente boekingen", icon: "clock") {
            Button("Alle transacties") { model.selection = .transactions }
                .buttonStyle(.borderless)
                .font(.callout)
        } content: {
            if entries.isEmpty {
                DashboardQuietState(icon: "tray", title: "Nog geen boekingen",
                                    message: "Importeer een bankbestand om te beginnen.")
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        if index > 0 { Divider() }
                        DashboardRecentRow(entry: entry, showAccount: showAccount)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }
}

private struct DashboardRecentRow: View {
    @Environment(AppModel.self) private var model
    let entry: EntryRow
    let showAccount: Bool
    @State private var hovering = false

    private var category: String {
        entry.itemLabel ?? entry.potName ?? (entry.amount.isNegative ? "UIT overig" : "IN overig")
    }

    var body: some View {
        Button { model.selection = .transactions } label: {
            HStack(spacing: 10) {
                Text(entry.day.short()).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    .frame(width: 44, alignment: .leading)
                Text(entry.label.isEmpty ? category : entry.label).font(.callout).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !entry.reviewed {
                    Image(systemName: "eye").font(.caption).foregroundStyle(Theme.info)
                        .help("Automatisch geboekt en nog niet door jou gecontroleerd.")
                }
                ForEach(entry.tags.prefix(showAccount ? 2 : 1)) { tag in
                    Pill(tag.name, color: Color(hex: tag.color))
                }
                Text(category == entry.label ? "Vaste post" : category).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    .frame(width: showAccount ? 150 : 100, alignment: .leading)
                if showAccount {
                    Text(entry.accountName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        .frame(width: 110, alignment: .leading)
                }
                MoneyText(entry.amount, colored: true).font(.callout)
                    .frame(width: 92, alignment: .trailing)
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 6)
            .background(hovering ? Color.primary.opacity(0.05) : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, -6)
        .onHover { hovering = $0 }
        .help("Open Transacties")
    }
}
