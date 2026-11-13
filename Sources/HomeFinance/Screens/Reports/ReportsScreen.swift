import SwiftUI
import HFCore
import HFInsight

/// De rapporten in het scherm Rapporten.
enum ReportsTab: String, CaseIterable, Identifiable {
    case overview, spendable, tags, budget, divers, years
    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "Overzicht"
        case .spendable: "Besteedbaar"
        case .tags: "Categorieën"
        case .budget: "Budget tegen werkelijk"
        case .divers: "Diverse uitgaven"
        case .years: "Jaar op jaar"
        }
    }

    var help: String {
        switch self {
        case .overview: "Inkomsten, uitgaven en besteedbaar per maand"
        case .spendable: "Wat je vrij kunt uitgeven, door het jaar heen"
        case .tags: "Wat je per maand uitgeeft aan een categorie (tag), zoals tanken of uit eten"
        case .budget: "Per vaste post: wat was gepland en wat is het echt geworden"
        case .divers: "Waar de uitgaven zonder vaste post naartoe gingen"
        case .years: "De totalen van alle jaren naast elkaar"
        }
    }

    /// Begintab; `HF_REPORTS_TAB` kiest een ander tabblad voor een snapshot.
    static var initial: ReportsTab {
        ProcessInfo.processInfo.environment["HF_REPORTS_TAB"].flatMap(ReportsTab.init(rawValue:)) ?? .overview
    }
}

/// Alles wat de rapporten tonen, in één keer gelezen uit `HFInsight`.
struct ReportsData {
    var summary: YearSummary?
    var months: [MonthResult] = []
    var spendable: [SpendablePoint] = []
    var tags: [TagYearRow] = []
    var tagEntries: [EntryRow] = []
    var budget: [BudgetVsActualRow] = []
    var divers: DiversBreakdown?
    var topDivers: [EntryRow] = []
    var years: [YearTotals] = []

    /// Er zijn boekingen op de betaalrekening in dit jaar.
    var hasMovements: Bool { months.contains { !$0.income.isZero || !$0.expenses.isZero } }
    var hasBudget: Bool { summary != nil }
}

struct ReportsScreen: View {
    @Environment(AppModel.self) private var model
    @State private var tab = ReportsTab.initial
    @State private var data = ReportsData()
    @State private var loaded = false
    @State private var tagId: Int64?
    @State private var tagMonth: Int?
    @State private var diversMonth: Int?
    @State private var showAllBudget = false

    private struct LoadKey: Hashable {
        let revision: Int, year: Int, today: Day, tagId: Int64?, tagMonth: Int?, diversMonth: Int?
    }

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader("Rapporten", subtitle: subtitle) {
                Button { copyTable() } label: { Label("Kopieer als tabel", systemImage: "doc.on.doc") }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                    .help("Zet de cijfers van dit rapport op het klembord, om in Excel te plakken (⇧⌘C)")
            }
            HStack(spacing: 12) {
                Picker("Rapport", selection: $tab) {
                    ForEach(ReportsTab.allCases) { Text($0.title).tag($0).help($0.help) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                Spacer(minLength: 8)
                tabControls
            }
            .padding(.horizontal, 24).padding(.bottom, 12)
            .background { tabShortcuts }
            Divider()
            content
        }
        .background(Theme.background)
        .onChange(of: model.year) {
            tagMonth = nil
            diversMonth = nil
        }
        .onChange(of: tagId) { tagMonth = nil }
        .task(id: LoadKey(revision: model.revision, year: model.year, today: model.today, tagId: tagId,
                          tagMonth: tagMonth, diversMonth: diversMonth)) { load() }
    }

    private var subtitle: String {
        if tab == .years { return "Alle jaren naast elkaar" }
        guard let summary = data.summary else { return "Trends en waar het geld naartoe ging in \(String(model.year))" }
        return "Cijfers van \(String(model.year)) t/m \(summary.asOf.short())"
    }

    @ViewBuilder private var tabControls: some View {
        switch tab {
        case .divers:
            ReportsMonthPicker(month: $diversMonth)
        case .budget:
            Toggle("Toon alle posten", isOn: $showAllBudget).toggleStyle(.switch).controlSize(.small)
                .help("Standaard zie je alleen de posten die afwijken van het plan")
        default:
            EmptyView()
        }
    }

    /// ⌘1 t/m ⌘6 kiezen een rapport.
    private var tabShortcuts: some View {
        ForEach(Array(ReportsTab.allCases.enumerated()), id: \.element) { index, item in
            Button(item.title) { tab = item }
                .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
        }
        .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
    }

    @ViewBuilder private var content: some View {
        if !loaded {
            Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if tab == .years {
            scroll { ReportsYearsTab(years: data.years, currentYear: model.year) }
        } else if !data.hasMovements {
            EmptyState(title: "Nog geen cijfers voor \(String(model.year))",
                       message: "Zodra er boekingen in \(String(model.year)) staan, zie je hier trends en verdelingen. Importeer een bankbestand of kies een ander jaar in de zijbalk.",
                       icon: "chart.bar.xaxis", actionTitle: "Naar Importeren en nakijken") { model.selection = .review }
        } else {
            switch tab {
            case .overview:
                scroll { ReportsOverviewTab(data: data, year: model.year) }
            case .spendable:
                if let summary = data.summary, !data.spendable.isEmpty {
                    scroll { ReportsSpendableTab(summary: summary, points: data.spendable) }
                } else {
                    EmptyState(title: "Geen begroting voor \(String(model.year))",
                               message: "Besteedbaar is het saldo min de buffers. Daarvoor is een begroting voor dit jaar nodig.",
                               icon: "wallet.bifold", actionTitle: "Naar Instellingen") { model.selection = .settings }
                }
            case .tags:
                if data.tags.isEmpty {
                    EmptyState(title: "Nog geen tags",
                               message: "Met een tag (zoals Tanken of Uit eten) volg je een soort uitgave over de maanden. Geef boekingen een tag bij Transacties, of laat een regel dat automatisch doen.",
                               icon: "tag", actionTitle: "Naar Transacties") { model.selection = .transactions }
                } else {
                    scroll { ReportsTagsTab(data: data, year: model.year, tagId: $tagId, month: $tagMonth) }
                }
            case .budget:
                if data.budget.isEmpty {
                    EmptyState(title: "Geen begroting voor \(String(model.year))",
                               message: "Dit rapport vergelijkt de vaste posten met wat er echt is geboekt. Maak eerst een begroting voor dit jaar.",
                               icon: "list.bullet.clipboard", actionTitle: "Naar Instellingen") { model.selection = .settings }
                } else {
                    scroll { ReportsBudgetTab(rows: data.budget, showAll: $showAllBudget, asOf: data.summary?.asOf) }
                }
            case .divers:
                scroll { ReportsDiversTab(data: data, year: model.year, month: $diversMonth) }
            case .years:
                EmptyView()
            }
        }
    }

    private func scroll<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ScrollView {
            content().padding(.horizontal, 32).padding(.top, 24).padding(.bottom, 32)
        }
    }

    // MARK: Lezen

    private func load() {
        let year = model.year, today = model.today
        var result = ReportsData()
        var chosen = tagId
        model.read(()) { db in
            result.months = try Insight.monthlyResults(db, year: year)
            result.years = try Insight.yearOverYear(db)
            result.tags = try Insight.tagYear(db, year: year, today: today)
            // Zonder begroting voor dit jaar bestaan deze cijfers niet; de rest van het scherm werkt dan wel.
            result.summary = try Self.ifYearExists { try Insight.yearSummary(db, year: year, today: today) }
            result.spendable = try Self.ifYearExists { try Insight.spendableSeries(db, year: year, today: today) } ?? []
            result.budget = try Self.ifYearExists { try Insight.budgetVsActual(db, year: year, today: today) } ?? []
            if chosen == nil || !result.tags.contains(where: { $0.id == chosen }) {
                chosen = (result.tags.first { $0.entryCount > 0 } ?? result.tags.first)?.id
            }
            if let chosen, tagMonth != nil {
                result.tagEntries = try Insight.tagEntries(db, tagId: chosen, year: year, month: tagMonth)
            }
            result.divers = try Insight.diversByTag(db, year: year, month: diversMonth)
            result.topDivers = try Insight.topDiversExpenses(db, year: year, month: diversMonth, limit: 15)
        }
        data = result
        if tagId != chosen { tagId = chosen }
        loaded = true
    }

    private static func ifYearExists<T>(_ body: () throws -> T) throws -> T? {
        do { return try body() } catch InsightError.yearNotFound { return nil }
    }

    // MARK: Klembord

    private func copyTable() {
        let text = data.table(for: tab, year: model.year, tagId: tagId, tagMonth: tagMonth,
                              diversMonth: diversMonth)
        ReportsFormat.copyToClipboard(text)
        model.toast = "Tabel gekopieerd. Plak hem in Excel met ⌘V."
    }
}
