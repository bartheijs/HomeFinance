import SwiftUI
import GRDB
import HFCore
import HFInsight

/// Maandgrid: het jaarblad uit Excel, maar dan live. Rijen = vaste posten, kolommen = plan, jan … dec, jaar.
struct GridScreen: View {
    @Environment(AppModel.self) private var model

    @State private var grid: MonthGrid?
    @State private var summary: YearSummary?
    /// Vaste posten van de maand boven het grid ("5 van 15 voldaan · 3 te laat").
    @State private var monthStatus: FixedItemsOverview?
    @State private var loaded = false
    /// Per post-id: naam en verdeling van de gekoppelde vaste storting, voor de tooltip van het label.
    @State private var distributionHelp: [Int64: String] = [:]
    @State private var showDifference = false
    @State private var showLegend = false
    @State private var showOverview = false
    @AppStorage("grid.toonResRegels") private var showReserveLines = false
    @AppStorage("grid.dichtheid") private var densityRaw = GridDensity.normal.rawValue

    private var density: GridDensity { GridDensity(rawValue: densityRaw) ?? .normal }

    private struct ReloadKey: Equatable { var revision: Int; var year: Int; var today: Day }

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader("Maandgrid", subtitle: subtitle) { toolbar }
            if let grid, !grid.rows.isEmpty {
                content(grid)
            } else if loaded {
                EmptyState(title: "Nog geen vaste posten in \(String(model.year))",
                           message: "Het maandgrid zet je vaste inkomsten en uitgaven per maand naast het plan, zoals het jaarblad in Excel. "
                               + "Maak eerst het begrotingsjaar en de vaste posten aan.",
                           icon: "tablecells",
                           actionTitle: "Naar Instellingen",
                           action: { model.settingsTab = "jaar"; model.selection = .settings })
            } else {
                Spacer()
            }
        }
        .task(id: ReloadKey(revision: model.revision, year: model.year, today: model.today)) { load() }
    }

    private var subtitle: String {
        showDifference ? "Begroting \(String(model.year)) · je ziet het verschil met het plan" : "Begroting \(String(model.year))"
    }

    private func load() {
        // Een jaar dat nog niet bestaat is geen fout: dan tonen we de uitleg.
        grid = try? model.db.read { try Insight.monthGrid($0, year: model.year, today: model.today) }
        summary = try? model.db.read { try Insight.yearSummary($0, year: model.year, today: model.today) }
        monthStatus = try? model.db.read { try Insight.fixedItemsStatus($0, year: model.year, month: statusMonth, today: model.today) }
        distributionHelp = (try? model.db.read { db in try Self.distributionHelp(db, today: model.today) }) ?? [:]
        loaded = true
    }

    /// Tekst per gekoppelde post: "Vaste storting <naam>: <totaal>" en daaronder potnaam en bedrag.
    private static func distributionHelp(_ db: Database, today: Day) throws -> [Int64: String] {
        let summaries = Dictionary(uniqueKeysWithValues: try Insight.distributions(db, today: today).map { ($0.id, $0) })
        var result: [Int64: String] = [:]
        for item in try BudgetItem.filter(Column("distributionId") != nil).fetchAll(db) {
            guard let id = item.id, let distributionId = item.distributionId, let summary = summaries[distributionId] else { continue }
            let lines = summary.lines.map { "• \($0.potName): \($0.amount.formatted())" }
            result[id] = (["Gekoppeld aan de vaste storting \(summary.name) naar \(summary.accountName): \(summary.total.formatted())"]
                + lines).joined(separator: "\n")
        }
        return result
    }

    /// De maand van de samenvatting boven het grid: de lopende maand, of december (voorbij jaar) of januari
    /// (toekomstig jaar).
    private var statusMonth: Int {
        let today = model.today
        if model.year == today.year { return today.month }
        return model.year < today.year ? 12 : 1
    }

    private var options: GridOptions {
        let today = model.today
        let firstFuture: Int = model.year < today.year ? 13 : (model.year > today.year ? 1 : today.month + 1)
        return GridOptions(year: model.year, showDifference: showDifference,
                           currentMonth: model.year == today.year ? today.month : nil,
                           firstFutureMonth: firstFuture, editable: !(grid?.closed ?? false))
    }

    // MARK: Onderdelen

    @ViewBuilder private var toolbar: some View {
        if let grid, !grid.rows.isEmpty {
            HStack(spacing: 10) {
                if grid.closed {
                    Pill("Afgesloten", color: .secondary, icon: "lock.fill")
                        .help("\(String(model.year)) is afgesloten. Je kunt alles bekijken, maar geen boekingen toevoegen. Heropenen kan bij Instellingen.")
                }
                Button { showLegend.toggle() } label: {
                    Image(systemName: "info.circle").font(.system(size: 14))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Uitleg van de kleuren en tekens in het grid")
                .popover(isPresented: $showLegend, arrowEdge: .bottom) {
                    GridLegend(editable: !grid.closed)
                }

                Button("Jaaroverzicht") { showOverview.toggle() }
                    .keyboardShortcut("j", modifiers: .command)
                    .help("Van 'op de rekening op 1-1' naar 'besteedbaar': het blok dat in Excel onderaan het jaarblad staat (⌘J).")
                    .popover(isPresented: $showOverview, arrowEdge: .bottom) {
                        if let summary { GridYearOverview(summary: summary) }
                    }

                Menu {
                    Toggle("Toon afwijkingen van het plan", isOn: $showDifference)
                    Toggle("Toon RES-regels", isOn: $showReserveLines)
                        .disabled(!grid.rows.contains { $0.kind == .reserveLine })
                    Divider()
                    Picker("Rijhoogte", selection: $densityRaw) {
                        Text("Compact").tag(GridDensity.compact.rawValue)
                        Text("Ruim").tag(GridDensity.normal.rawValue)
                    }
                    .pickerStyle(.inline)
                } label: {
                    Text("Weergave")
                }
                .fixedSize()
                .help("Afwijkingen van het plan tonen (⌘D), RES-regels tonen (⌘R) en de rijhoogte kiezen.")
            }
            .background {
                // Sneltoetsen voor de keuzes in het menu Weergave.
                Group {
                    Button("") { showDifference.toggle() }.keyboardShortcut("d", modifiers: .command)
                    Button("") { showReserveLines.toggle() }.keyboardShortcut("r", modifiers: .command)
                }
                .opacity(0).frame(width: 0, height: 0).allowsHitTesting(false).accessibilityHidden(true)
            }
        }
    }

    private func content(_ grid: MonthGrid) -> some View {
        let lines = GridLine.build(from: grid, showReserveLines: showReserveLines)
        return VStack(alignment: .leading, spacing: 0) {
            if let monthStatus, !monthStatus.items.isEmpty {
                (Text("\(Day.monthNames[statusMonth - 1].capitalized): ").fontWeight(.semibold)
                    + Text("\(monthStatus.paidCount) van \(monthStatus.items.count) voldaan")
                    + (monthStatus.lateCount > 0
                       ? Text(" · ").foregroundColor(.secondary) + Text("\(monthStatus.lateCount) te laat").foregroundColor(Theme.negative)
                       : Text("")))
                    .font(.callout)
                    .lineLimit(1)
                    .padding(.bottom, 8)
                    .help("Vaste posten die in \(Day.monthNames[statusMonth - 1]) verwacht worden: hoeveel er al geboekt of afgevinkt zijn, en hoeveel te laat zijn.")
            }
            GridTable(grid: grid, lines: lines, density: density, options: options,
                      reserveExpanded: showReserveLines, distributionHelp: distributionHelp,
                      onToggleReserve: { withAnimation(.easeInOut(duration: 0.15)) { showReserveLines.toggle() } })
                .frame(maxHeight: GridTable.contentHeight(lineCount: lines.count, density: density))
                .background(GridPalette.surface)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.hairline.opacity(0.8)))
            GridLegendLine()
                .padding(.top, 8)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.top, 4)
        .padding(.bottom, 16)
    }
}

/// Het blok dat in Excel onderaan het jaarblad staat: van "op de rekening op 1-1" naar "besteedbaar".
struct GridYearOverview: View {
    var summary: YearSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Jaaroverzicht \(String(summary.year))").font(.headline)
            Text("Stand per \(summary.asOf.short(withYear: true))").font(.caption).foregroundStyle(.secondary)
                .padding(.bottom, 10)
            line("Op de rekening op 1-1", summary.openingBalance,
                 help: "Wat er op 1 januari op de betaalrekening(en) stond.")
            line("IN", summary.income, sign: "+", help: "Alle inkomsten tot en met de peildag, vaste posten en divers samen.")
            line("UIT", summary.expenses.magnitude, sign: "−", help: "Alle uitgaven tot en met de peildag, vaste posten en divers samen.")
            Divider().padding(.vertical, 5)
            line("Op de rekening", summary.balance, strong: true, help: "Het berekende saldo van de betaalrekening(en).")
            line("Anti-rood", summary.buffers, sign: "−",
                 help: "Buffer die je op de rekening wilt laten staan: anti-rood \(summary.antiRood.formatted()) plus tijdelijk anti-rood \(summary.tijdelijkAntiRood.formatted()).")
            Divider().padding(.vertical, 5)
            line("Besteedbaar", summary.spendable, strong: true,
                 color: summary.spendable.isNegative ? Theme.negative : Theme.accent,
                 help: "Op de rekening min anti-rood: wat je vrij kunt uitgeven.")
        }
        .padding(16)
        .frame(width: 300)
    }

    private func line(_ title: String, _ amount: Money, sign: String = "", strong: Bool = false,
                      color: Color = .primary, help: String) -> some View {
        HStack(spacing: 6) {
            Text(sign).foregroundStyle(.tertiary).frame(width: 10)
            Text(title).fontWeight(strong ? .semibold : .regular)
            Spacer(minLength: 12)
            Text(amount.formatted()).monospacedDigit().fontWeight(strong ? .semibold : .regular).foregroundStyle(color)
        }
        .font(.callout)
        .padding(.vertical, 3)
        .help(help)
    }
}

/// Vaste legenda van één regel onder het grid, met de woorden van de statussen. Past hij niet, dan zonder
/// "(± € X)".
struct GridLegendLine: View {
    var body: some View {
        ViewThatFits(in: .horizontal) {
            line(full: true)
            line(full: false)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .help("Wat de kleuren en tekens in het grid betekenen. Meer uitleg achter het ⓘ-knopje rechtsboven.")
    }

    private func line(full: Bool) -> some View {
        HStack(spacing: 14) {
            item("Klopt") { GridSwatch(tint: nil) }
            item(full ? "Wijkt af (± € X)" : "Wijkt af") { GridSwatch(tint: CellStatus.afwijkend.gridTint) }
            item("Nog verwacht") { Circle().fill(Color.secondary.opacity(0.6)).frame(width: 5, height: 5) }
            item("Te laat") { GridSwatch(tint: CellStatus.teLaat.gridTint) }
            item("Afgevinkt") { Image(systemName: "checkmark").font(.system(size: 8, weight: .bold)) }
        }
        .lineLimit(1)
        .fixedSize()
    }

    private func item<Mark: View>(_ title: String, @ViewBuilder mark: () -> Mark) -> some View {
        HStack(spacing: 5) {
            mark()
            Text(title)
        }
    }
}

/// Een gekleurd vakje zoals een cel in het grid.
struct GridSwatch: View {
    var tint: Color?
    var body: some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(tint ?? .clear)
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Theme.hairline))
            .frame(width: 18, height: 10)
    }
}

/// Uitleg van de celkleuren en tekens, achter de (i)-knop.
struct GridLegend: View {
    var editable: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Zo lees je het grid").font(.headline)
            row("Geen kleur", "Geboekt en gelijk aan het plan.") { swatch(nil) }
            row("Geel", "Geboekt, maar een ander bedrag dan gepland.") { swatch(CellStatus.afwijkend.gridTint) }
            row("Rood", "Te laat: verwacht, maar nog niet geboekt.") { swatch(CellStatus.teLaat.gridTint) }
            row("Vinkje", "Met de hand afgevinkt als voldaan, zonder boeking.") {
                Image(systemName: "checkmark").font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
            }
            row("Grijs puntje", "Wordt deze maand nog verwacht.") {
                Circle().fill(Color.secondary.opacity(0.6)).frame(width: 5, height: 5)
            }
            row("Schuin en grijs", "Het plan voor een maand die nog moet komen.") {
                Text("12,50").font(.caption).italic().monospacedDigit().foregroundStyle(Color.secondary.opacity(0.6))
            }
            row("Hoekje", "Er zitten meerdere boekingen in de cel.") {
                GridCornerMark().fill(Color.secondary.opacity(0.7)).frame(width: 6, height: 6)
            }
            Divider()
            Text(editable ? "Klik op een cel voor de boekingen en om af te vinken. Dubbelklik om een boeking toe te voegen. Rechtsklik voor alle keuzes."
                 : "Klik op een cel voor de boekingen.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 300, alignment: .leading)
    }

    private func row<Mark: View>(_ title: String, _ text: String, @ViewBuilder mark: () -> Mark) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            mark().frame(width: 34, alignment: .center)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.callout.weight(.medium))
                Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func swatch(_ tint: Color?) -> some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(tint ?? .clear)
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Theme.hairline))
            .frame(width: 22, height: 12)
    }
}
