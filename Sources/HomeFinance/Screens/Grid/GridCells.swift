import SwiftUI
import HFCore
import HFInsight

/// Eén getalcel: rechts uitgelijnd, vaste cijferbreedte, optioneel met tint, stip of hoekje.
struct GridNumberCell: View {
    var content: GridCellContent
    var width: CGFloat
    var height: CGFloat
    var fontSize: CGFloat
    var selected = false

    var body: some View {
        Text(content.text)
            .font(.system(size: fontSize, weight: content.strong ? .semibold : .regular))
            .italic(content.italic)
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.82)
            .foregroundStyle(color)
            .padding(.trailing, 6)
            .padding(.leading, content.dot == nil && !content.check ? 4 : 12)
            .frame(width: width, height: height, alignment: .trailing)
            .background {
                if let tint = content.tint {
                    RoundedRectangle(cornerRadius: 3).fill(tint).padding(.horizontal, 1).padding(.vertical, 1)
                }
            }
            .overlay(alignment: .leading) {
                if let dot = content.dot {
                    Circle().fill(dot).frame(width: 4.5, height: 4.5).padding(.leading, 4)
                }
            }
            .overlay(alignment: .leading) {
                if content.check {
                    Image(systemName: "checkmark").font(.system(size: 7.5, weight: .bold))
                        .foregroundStyle(.secondary).padding(.leading, 4)
                }
            }
            .overlay(alignment: .topTrailing) {
                if content.multiple {
                    GridCornerMark().fill(Color.secondary.opacity(0.7)).frame(width: 5, height: 5).padding(2)
                }
            }
            .overlay {
                if selected {
                    RoundedRectangle(cornerRadius: 3).strokeBorder(Theme.accent, lineWidth: 1.5)
                }
            }
    }

    private var color: Color {
        switch content.tone {
        case .normal: .primary
        case .secondary: .secondary
        case .ghost: Color.secondary.opacity(0.55)
        case .late: Theme.negative.opacity(0.85)
        case .positive: Theme.positive
        case .negative: Theme.negative
        }
    }
}

/// Driehoekje rechtsboven: meer dan één boeking in de cel.
struct GridCornerMark: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

/// Achtergrond van een maandkolom: lopende maand licht gekleurd, toekomst iets gedempt.
struct GridColumnWash: View {
    var month: Int
    var options: GridOptions

    var body: some View {
        if options.isCurrent(month) {
            Theme.accent.opacity(0.06)
        } else if options.isFuture(month) {
            Color.primary.opacity(0.025)
        } else {
            Color.clear
        }
    }
}

/// Dunne lijn onder een rij.
struct GridRowLine: View {
    var strong = false
    var body: some View {
        Rectangle().fill(Theme.hairline.opacity(strong ? 1 : 0.45)).frame(height: strong ? 1 : 0.5)
    }
}

/// Verticale scheiding (na de vaste kolom, na Plan, vóór Jaar).
struct GridColumnLine: View {
    var body: some View {
        Rectangle().fill(Theme.hairline.opacity(0.9)).frame(width: 0.5)
    }
}

// MARK: - Lagen van het grid

/// De getallen van alle posten (plan, 12 maanden, jaar). Schuift mee in beide richtingen.
struct GridBodyLayer: View, Equatable {
    var lines: [GridLine]
    var layout: GridLayout
    var options: GridOptions
    var selectedId: String?
    var onClick: (GridTarget, Int) -> Void
    var onDoubleClick: (GridTarget) -> Void
    var onSetChecked: (GridTarget, Bool) -> Void

    nonisolated static func == (a: GridBodyLayer, b: GridBodyLayer) -> Bool {
        a.lines == b.lines && a.layout == b.layout && a.options == b.options && a.selectedId == b.selectedId
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                switch line {
                case .section:
                    Color.clear.frame(width: layout.numbersWidth, height: layout.rowHeight)
                        .background(GridPalette.sectionBand)
                        .overlay(alignment: .bottom) { GridRowLine() }
                case .row(let row):
                    rowView(row, index: index)
                }
            }
        }
        .background(alignment: .topLeading) { washes }
        .overlay(alignment: .topLeading) { separators }
    }

    private func rowView(_ row: GridItemRow, index: Int) -> some View {
        HStack(spacing: 0) {
            GridNumberCell(content: planContent(row), width: layout.columnWidth, height: layout.rowHeight, fontSize: layout.fontSize)
                .help(planHelp(row))
            ForEach(row.cells, id: \.month) { cell in
                let target = GridTarget(kind: .item(row), month: cell.month)
                GridNumberCell(content: .cell(cell, row: row, options: options), width: layout.columnWidth,
                               height: layout.rowHeight, fontSize: layout.fontSize, selected: selectedId == target.id)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { if row.kind != .reserveLine { onDoubleClick(target) } }
                    .onTapGesture { if row.kind != .reserveLine { onClick(target, index) } }
                    .help(GridCellContent.help(cell, row: row, options: options))
                    .contextMenu {
                        if row.kind != .reserveLine {
                            Button("Toon boekingen") { onClick(target, index) }
                            Button("Boeking toevoegen…") { onDoubleClick(target) }.disabled(!options.editable)
                            Divider()
                            Button(cell.isChecked ? "Vinkje weghalen" : "Afvinken als voldaan") {
                                onSetChecked(target, !cell.isChecked)
                            }
                            .disabled(!options.editable)
                        }
                    }
            }
            GridNumberCell(content: yearContent(row), width: layout.yearWidth, height: layout.rowHeight, fontSize: layout.fontSize)
                .help(yearHelp(row))
        }
        .background(row.kind == .reserveLine ? GridPalette.reserveBand : Color.clear)
        .overlay(alignment: .bottom) { GridRowLine() }
    }

    private var washes: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: layout.columnWidth)
            ForEach(1...12, id: \.self) { month in
                GridColumnWash(month: month, options: options).frame(width: layout.columnWidth)
            }
        }
        .allowsHitTesting(false)
    }

    private var separators: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: layout.columnWidth - 0.5)
            GridColumnLine()
            Color.clear.frame(width: layout.columnWidth * 12 - 0.5)
            GridColumnLine()
        }
        .allowsHitTesting(false)
    }

    private func planContent(_ row: GridItemRow) -> GridCellContent {
        var c = GridCellContent(text: row.plan.formatted(symbol: false), tone: .secondary)
        if row.kind == .reserveLine { c.tone = .ghost; c.italic = true }
        return c
    }

    private func yearContent(_ row: GridItemRow) -> GridCellContent {
        if row.kind == .reserveLine {
            let text = row.planYearTotal.isZero ? "" : row.planYearTotal.formatted(symbol: false)
            return GridCellContent(text: text, tone: .ghost, italic: true)
        }
        return GridCellContent(text: row.yearTotal.formatted(symbol: false), strong: true)
    }

    private func planHelp(_ row: GridItemRow) -> String {
        let moment: String
        switch row.frequency {
        case .maand: moment = "elke maand"
        case .kwartaal, .jaar:
            moment = "in " + row.expectedMonths.map { Day.monthNamesShort[$0 - 1] }.joined(separator: ", ")
        }
        let day = row.expectedDay.map { ", rond dag \($0)" } ?? ""
        if row.kind == .reserveTotal {
            return "Plan per keer: \(row.plan.formatted()), \(moment)\(day).\nDit is de som van de RES-regels."
        }
        return "Plan per keer: \(row.plan.formatted()), \(moment)\(day)."
    }

    private func yearHelp(_ row: GridItemRow) -> String {
        if row.kind == .reserveLine {
            return "\(row.label) is een onderdeel van RESERVERINGEN. Telt niet mee in de totalen."
        }
        return "\(row.label) in \(options.year)\nGeboekt: \(row.yearTotal.formatted())\nPlan heel jaar: \(row.planYearTotal.formatted())"
    }
}

/// De vaste eerste kolom met de namen van de posten.
struct GridLabelLayer: View, Equatable {
    var lines: [GridLine]
    var layout: GridLayout
    var reserveExpanded: Bool
    var hasReserveLines: Bool
    /// Per post-id: de uitleg van de gekoppelde vaste storting (naam en verdeling over potten).
    var distributionHelp: [Int64: String] = [:]
    var onToggleReserve: () -> Void

    nonisolated static func == (a: GridLabelLayer, b: GridLabelLayer) -> Bool {
        a.distributionHelp == b.distributionHelp && a.lines == b.lines && a.layout == b.layout && a.reserveExpanded == b.reserveExpanded && a.hasReserveLines == b.hasReserveLines
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(lines) { line in
                Group {
                    switch line {
                    case .section(let title, let help):
                        Text(title.uppercased())
                            .font(.system(size: 10, weight: .semibold))
                            .kerning(0.6)
                            .foregroundStyle(.secondary)
                            .padding(.leading, 12)
                            .frame(width: layout.labelWidth, height: layout.rowHeight, alignment: .leading)
                            .background(GridPalette.sectionBand)
                            .help(help)
                    case .row(let row):
                        label(row)
                    }
                }
                .overlay(alignment: .bottom) { GridRowLine() }
            }
        }
        .background(GridPalette.surface)
        .overlay(alignment: .trailing) { GridColumnLine() }
    }

    @ViewBuilder private func label(_ row: GridItemRow) -> some View {
        switch row.kind {
        case .reserveLine:
            HStack(spacing: 5) {
                Text(row.label).italic().lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 2)
                Text("RES").font(.system(size: 8.5, weight: .semibold)).foregroundStyle(.tertiary)
            }
            .font(.system(size: layout.fontSize))
            .foregroundStyle(.secondary)
            .padding(.leading, 30).padding(.trailing, 8)
            .frame(width: layout.labelWidth, height: layout.rowHeight, alignment: .leading)
            .background(GridPalette.reserveBand)
            .help("\(row.label) is een RES-regel: een onderdeel van de maandelijkse overboeking RESERVERINGEN. Ter informatie; telt niet mee in de totalen.")
        case .reserveTotal:
            Button(action: onToggleReserve) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8.5, weight: .bold))
                        .rotationEffect(.degrees(reserveExpanded ? 90 : 0))
                        .foregroundStyle(hasReserveLines ? Color.secondary : Color.clear)
                        .frame(width: 10)
                    Text(row.label).fontWeight(.medium).lineLimit(1)
                    Spacer(minLength: 2)
                }
                .font(.system(size: layout.fontSize + 0.5))
                .padding(.leading, 10).padding(.trailing, 8)
                .frame(width: layout.labelWidth, height: layout.rowHeight, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!hasReserveLines)
            .help(distributionHelp[row.id].map { "\(row.label)\n\($0)" }
                  ?? "De ene maandelijkse overboeking naar de spaarrekening. Het plan is de som van de RES-regels. Klik om de opbouw te tonen of te verbergen.")
        case .item:
            HStack(spacing: 5) {
                Text(row.label).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 2)
                if row.frequency != .maand {
                    Text(row.frequency == .kwartaal ? "kwartaal" : "jaar")
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                }
                if distributionHelp[row.id] != nil {
                    Image(systemName: "arrow.triangle.branch").font(.system(size: 8.5)).foregroundStyle(.secondary)
                }
            }
            .font(.system(size: layout.fontSize + 0.5))
            .padding(.leading, 24).padding(.trailing, 8)
            .frame(width: layout.labelWidth, height: layout.rowHeight, alignment: .leading)
            .help(itemHelp(row))
        }
    }

    private func itemHelp(_ row: GridItemRow) -> String {
        var text = row.label
        switch row.frequency {
        case .maand: text += "\nElke maand"
        case .kwartaal: text += "\nPer kwartaal: " + row.expectedMonths.map { Day.monthNamesShort[$0 - 1] }.joined(separator: ", ")
        case .jaar: text += "\nPer jaar: " + row.expectedMonths.map { Day.monthNamesShort[$0 - 1] }.joined(separator: ", ")
        }
        if let day = row.expectedDay { text += ", rond dag \(day)" }
        if let distribution = distributionHelp[row.id] { text += "\n" + distribution }
        return text
    }
}

/// De vaste koprij: Plan, jan … dec, Jaar.
struct GridHeaderLayer: View, Equatable {
    var layout: GridLayout
    var options: GridOptions

    var body: some View {
        HStack(spacing: 0) {
            head("Plan", width: layout.columnWidth, color: .secondary)
                .help("Het geplande bedrag per keer.")
            ForEach(1...12, id: \.self) { month in
                head(Day.monthNamesShort[month - 1], width: layout.columnWidth,
                     color: options.isCurrent(month) ? Theme.accent : (options.isFuture(month) ? Color.secondary.opacity(0.6) : .primary),
                     strong: options.isCurrent(month))
                    .background(options.isCurrent(month) ? Theme.accent.opacity(0.06) : Color.clear)
                    .overlay(alignment: .bottom) {
                        if options.isCurrent(month) { Rectangle().fill(Theme.accent).frame(height: 2) }
                    }
                    .help(options.isCurrent(month) ? "\(Day.monthNames[month - 1]) \(options.year): de lopende maand"
                          : "\(Day.monthNames[month - 1]) \(options.year)")
            }
            head("Jaar", width: layout.yearWidth, color: .primary, strong: true)
                .help("Alles wat dit jaar op de post is geboekt.")
        }
        .frame(height: layout.headerHeight)
        .background(GridPalette.header)
        .overlay(alignment: .bottom) { GridRowLine(strong: true) }
    }

    private func head(_ text: String, width: CGFloat, color: Color, strong: Bool = false) -> some View {
        Text(text)
            .font(.system(size: 11, weight: strong ? .semibold : .medium))
            .foregroundStyle(color)
            .padding(.trailing, 6)
            .frame(width: width, height: layout.headerHeight, alignment: .trailing)
    }
}

/// De getallen van de totaalrijen onderaan.
struct GridFooterLayer: View, Equatable {
    var grid: MonthGrid
    var layout: GridLayout
    var options: GridOptions
    var selectedId: String?
    var onClick: (GridTarget, Int) -> Void

    nonisolated static func == (a: GridFooterLayer, b: GridFooterLayer) -> Bool {
        a.grid == b.grid && a.layout == b.layout && a.options == b.options && a.selectedId == b.selectedId
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(GridTotalLine.allCases) { line in
                HStack(spacing: 0) {
                    Color.clear.frame(width: layout.columnWidth, height: layout.rowHeight)
                    ForEach(grid.monthTotals, id: \.month) { totals in
                        monthCell(line, totals)
                    }
                    GridNumberCell(content: content(line, grid.yearTotals, future: false, year: true),
                                   width: layout.yearWidth, height: layout.rowHeight, fontSize: layout.fontSize)
                        .help("\(line.title) over heel \(options.year): \(line.value(grid.yearTotals).formatted())")
                }
                .overlay(alignment: .top) { if line == .result { GridRowLine(strong: true) } }
                .overlay(alignment: .bottom) { GridRowLine() }
            }
        }
        .background(GridPalette.footer)
        .overlay(alignment: .top) { GridRowLine(strong: true) }
    }

    @ViewBuilder private func monthCell(_ line: GridTotalLine, _ totals: GridTotals) -> some View {
        let future = options.isFuture(totals.month)
        let month = "\(Day.monthNames[totals.month - 1]) \(options.year)"
        if let positive = line.diversPositive {
            let target = GridTarget(kind: .divers(positive: positive), month: totals.month)
            GridNumberCell(content: content(line, totals, future: future, year: false), width: layout.columnWidth,
                           height: layout.rowHeight, fontSize: layout.fontSize, selected: selectedId == target.id)
                .contentShape(Rectangle())
                .onTapGesture { onClick(target, line.rawValue) }
                .help("\(line.title) · \(month): \(line.value(totals).formatted())\nKlik voor de boekingen.")
        } else {
            GridNumberCell(content: content(line, totals, future: future, year: false), width: layout.columnWidth,
                           height: layout.rowHeight, fontSize: layout.fontSize)
                .help(line == .ruimte
                      ? "Ruimte · \(month): \(totals.ruimte.formatted(alwaysSign: true))\nPlan van de verwachte posten \(totals.planExpected.formatted()) + IN divers \(totals.inDivers.formatted()) + UIT divers \(totals.uitDivers.formatted())"
                      : "\(line.title) · \(month): \(line.value(totals).formatted())")
        }
    }

    private func content(_ line: GridTotalLine, _ totals: GridTotals, future: Bool, year: Bool) -> GridCellContent {
        let value = line.value(totals)
        var c = GridCellContent(text: value.formatted(symbol: false), strong: line.isStrong || year)
        if future {
            c.tone = .ghost
            c.strong = false
            if value.isZero { c.text = "" }
            if line == .ruimte { c.italic = true }
        } else if line == .ruimte {
            c.text = value.formatted(symbol: false, alwaysSign: true)
            c.tone = value.isZero ? .secondary : (value.isNegative ? .negative : .positive)
        } else if value.isZero {
            c.tone = .ghost
        }
        return c
    }
}

/// De namen van de totaalrijen (vaste kolom, onderaan).
struct GridFooterLabelLayer: View, Equatable {
    var layout: GridLayout

    var body: some View {
        VStack(spacing: 0) {
            ForEach(GridTotalLine.allCases) { line in
                HStack(spacing: 4) {
                    Text(line.title).fontWeight(line.isStrong ? .semibold : .medium).lineLimit(1).minimumScaleFactor(0.85)
                    if line == .ruimte {
                        Image(systemName: "info.circle").font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .font(.system(size: layout.fontSize + 0.5))
                .padding(.leading, 12).padding(.trailing, 6)
                .frame(width: layout.labelWidth, height: layout.rowHeight, alignment: .leading)
                .help(line.help)
                .overlay(alignment: .top) { if line == .result { GridRowLine(strong: true) } }
                .overlay(alignment: .bottom) { GridRowLine() }
            }
        }
        .background(GridPalette.footer)
        .overlay(alignment: .top) { GridRowLine(strong: true) }
        .overlay(alignment: .trailing) { GridColumnLine() }
    }
}

/// Dekkende vlakken van het grid (de vaste lagen mogen niet doorschijnen).
enum GridPalette {
    static let surface = Theme.card
    static let header = Theme.card
    static let footer = Theme.card
    static let sectionBand = Theme.card
    static let reserveBand = Color(light: 0xFAFAF9, dark: 0x222423)
}
