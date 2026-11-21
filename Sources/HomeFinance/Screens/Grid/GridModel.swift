import SwiftUI
import HFCore
import HFInsight

// Hulptypen voor het maandgrid: maten, weergave-opties en wat er in een cel komt te staan.
// Hier wordt niet gerekend: alle bedragen komen uit HFInsight.

/// Rijhoogte en lettergrootte.
enum GridDensity: String, CaseIterable, Identifiable {
    case compact, normal
    var id: String { rawValue }
    var title: String { self == .compact ? "Compact" : "Ruim" }
    var rowHeight: CGFloat { self == .compact ? 22 : 25 }
    var fontSize: CGFloat { self == .compact ? 11 : 11.5 }
}

/// Alle maten van het grid op één plek, zodat vaste kolom, kop en cellen exact op elkaar aansluiten.
struct GridLayout: Equatable {
    var rowHeight: CGFloat
    var fontSize: CGFloat
    var headerHeight: CGFloat = 28
    var labelWidth: CGFloat = 196
    var columnWidth: CGFloat
    var yearWidth: CGFloat

    static let minColumnWidth: CGFloat = 66
    static let yearExtra: CGFloat = 12

    init(density: GridDensity, availableWidth: CGFloat) {
        rowHeight = density.rowHeight
        fontSize = density.fontSize
        let free = availableWidth - 196 - Self.yearExtra
        columnWidth = max(Self.minColumnWidth, (free / 14).rounded(.down))
        yearWidth = columnWidth + Self.yearExtra
    }

    /// Breedte van plan + 12 maanden + jaar.
    var numbersWidth: CGFloat { columnWidth * 13 + yearWidth }
    var contentWidth: CGFloat { labelWidth + numbersWidth }

    /// Linkerkant van een maandkolom (1–12) binnen het hele grid.
    func monthX(_ month: Int) -> CGFloat { labelWidth + columnWidth * CGFloat(month) }
}

/// Wat het grid toont, los van de gegevens.
struct GridOptions: Equatable {
    var year: Int
    var showDifference: Bool
    /// De lopende maand (1–12), of nil als het jaar niet het lopende jaar is.
    var currentMonth: Int?
    /// Eerste maand die in de toekomst ligt (13 = geen).
    var firstFutureMonth: Int
    var editable: Bool
    /// Extra uitleg bij het plan van RESERVERINGEN (bv. dat de RES-regels en de vaste storting uit elkaar lopen).
    var reserveNote: String? = nil

    func isFuture(_ month: Int) -> Bool { month >= firstFutureMonth }
    func isCurrent(_ month: Int) -> Bool { month == currentMonth }
}

/// Een regel in het grid: een tussenkop of een vaste post.
enum GridLine: Identifiable, Equatable {
    case section(title: String, help: String)
    case row(GridItemRow)

    var id: String {
        switch self {
        case .section(let title, _): "kop-\(title)"
        case .row(let row): "post-\(row.id)"
        }
    }

    /// Zet de posten in de vertrouwde volgorde: inkomsten, uitgaven, met de opbouw onder RESERVERINGEN. Is
    /// RESERVERINGEN aan een vaste storting gekoppeld, dan is `buildupRows` de verdeling van die storting en
    /// vervangt die de RES-regels (één bron voor de verdeling); anders tonen we de RES-regels.
    static func build(from grid: MonthGrid, showReserveLines: Bool, buildupRows: [GridItemRow]? = nil) -> [GridLine] {
        let income = grid.rows.filter { $0.direction == .IN && $0.kind == .item }
        let expenses = grid.rows.filter { $0.direction == .UIT }
        let reserveLines = buildupRows ?? grid.rows.filter { $0.kind == .reserveLine }
        var lines: [GridLine] = []
        if !income.isEmpty {
            lines.append(.section(title: "Inkomsten", help: "Vaste inkomsten (IN): wat er elke maand, elk kwartaal of elk jaar binnenkomt."))
            lines += income.map(GridLine.row)
        }
        if !expenses.isEmpty {
            lines.append(.section(title: "Uitgaven", help: "Vaste uitgaven (UIT): wat er vast van de betaalrekening af gaat. Uitgaven staan met een min."))
            for row in expenses {
                lines.append(.row(row))
                if row.kind == .reserveTotal && showReserveLines { lines += reserveLines.map(GridLine.row) }
            }
        }
        if showReserveLines && !reserveLines.isEmpty && !expenses.contains(where: { $0.kind == .reserveTotal }) {
            lines.append(.section(title: "Reserveringen", help: "Opbouw van de reserveringen. Deze regels tellen niet mee in de totalen."))
            lines += reserveLines.map(GridLine.row)
        }
        return lines
    }
}

/// De totaalrijen onder het grid.
enum GridTotalLine: Int, CaseIterable, Identifiable {
    case fixed, inDivers, uitDivers, nettoDivers, result, ruimte
    var id: Int { rawValue }

    var title: String {
        switch self {
        case .fixed: "Vaste posten"
        case .inDivers: "IN divers"
        case .uitDivers: "UIT divers"
        case .nettoDivers: "Netto divers"
        case .result: "Resultaat"
        case .ruimte: "Ruimte t.o.v. maandbudget"
        }
    }

    var help: String {
        switch self {
        case .fixed: "Alles wat op vaste posten is geboekt: inkomsten min uitgaven. De RES-regels tellen niet mee."
        case .inDivers: "Inkomsten die niet bij een vaste post horen. Klik op een maand voor de boekingen."
        case .uitDivers: "Uitgaven die niet bij een vaste post horen, zoals tanken of een cadeau. Klik op een maand voor de boekingen."
        case .nettoDivers: "IN divers plus UIT divers."
        case .result: "Alles wat er die maand bij kwam min alles wat er af ging."
        case .ruimte:
            "Het plan van de vaste posten die deze maand verwacht worden (zonder RES-regels), plus IN divers en UIT divers. "
                + "Positief: je blijft binnen je maandbudget. Negatief: je geeft meer uit dan er binnenkomt."
        }
    }

    func value(_ totals: GridTotals) -> Money {
        switch self {
        case .fixed: totals.fixed
        case .inDivers: totals.inDivers
        case .uitDivers: totals.uitDivers
        case .nettoDivers: totals.nettoDivers
        case .result: totals.result
        case .ruimte: totals.ruimte
        }
    }

    var isStrong: Bool { self == .result || self == .ruimte }
    /// IN divers en UIT divers hebben boekingen om te tonen.
    var diversPositive: Bool? {
        switch self { case .inDivers: true; case .uitDivers: false; default: nil }
    }
}

/// Waar de gebruiker op klikte: een cel van een post of een cel van IN/UIT divers.
struct GridTarget: Identifiable, Equatable {
    enum Kind: Equatable {
        case item(GridItemRow)
        case divers(positive: Bool)
    }
    var kind: Kind
    var month: Int

    var id: String {
        switch kind {
        case .item(let row): "post-\(row.id)-\(month)"
        case .divers(let positive): "divers-\(positive)-\(month)"
        }
    }

    var title: String {
        switch kind {
        case .item(let row): row.label
        case .divers(let positive): positive ? "IN divers" : "UIT divers"
        }
    }
}

extension CellStatus {
    var gridTitle: String {
        switch self {
        case .gelijk: "Gelijk aan plan"
        case .afwijkend: "Wijkt af van plan"
        case .open: "Verwacht, nog niet geboekt"
        case .teLaat: "Te laat"
        case .nietVerwacht: "Niet verwacht"
        case .afgevinkt: "Afgevinkt"
        }
    }

    var gridExplanation: String {
        switch self {
        case .gelijk: "Geboekt en precies gelijk aan het plan."
        case .afwijkend: "Geboekt, maar een ander bedrag dan gepland (of geboekt in een maand waarin de post niet verwacht werd)."
        case .open: "Deze post wordt deze maand nog verwacht."
        case .teLaat: "Verwacht, maar niet geboekt terwijl de verwachte dag of de maand al voorbij is."
        case .nietVerwacht: "De post komt deze maand niet voor, of de maand ligt in de toekomst."
        case .afgevinkt: "Met de hand afgevinkt als voldaan, zonder boeking."
        }
    }

    /// Achtergrondtint van de cel; nil = geen tint.
    var gridTint: Color? {
        switch self {
        case .afwijkend: Theme.warning.opacity(0.16)
        case .teLaat: Theme.negative.opacity(0.10)
        case .gelijk, .open, .nietVerwacht, .afgevinkt: nil
        }
    }
}

/// Wat er in één cel getekend wordt.
struct GridCellContent: Equatable {
    enum Tone: Equatable { case normal, secondary, ghost, late, positive, negative }
    var text = ""
    var tone: Tone = .normal
    var tint: Color?
    var dot: Color?
    var italic = false
    var strong = false
    /// Meer dan één boeking in de cel (hoekje, zoals een opmerking in Excel).
    var multiple = false
    /// Met de hand afgevinkt zonder boeking: een klein vinkje voor het planbedrag.
    var check = false

    static let empty = GridCellContent()

    /// Cel van een vaste post in een maand.
    static func cell(_ cell: GridCell, row: GridItemRow, options: GridOptions) -> GridCellContent {
        var c = GridCellContent()
        if row.kind == .reserveLine {
            // RES-regels krijgen geen boekingen: toon alleen de opbouw.
            // Het bedrag is het plan van de regel zelf, in de maanden waarin hij verwacht wordt.
            let planned = cell.expected ?? (row.expectedMonths.contains(cell.month) ? row.plan : .zero)
            if !planned.isZero {
                c.text = planned.formatted(symbol: false)
                c.tone = .ghost
                c.italic = true
            }
            return c
        }
        if cell.entryCount > 0 {
            c.text = options.showDifference
                ? (cell.difference.isZero ? "0,00" : cell.difference.formatted(symbol: false, alwaysSign: true))
                : cell.sum.formatted(symbol: false)
            c.tint = cell.status.gridTint
            c.multiple = cell.entryCount > 1
            if options.showDifference {
                c.tone = cell.difference.isZero ? .secondary : (cell.difference.isNegative ? .negative : .positive)
            }
            return c
        }
        let planned = (cell.expected.map { $0.isZero ? "" : $0.formatted(symbol: false) }) ?? ""
        switch cell.status {
        case .open:
            c.dot = Color.secondary.opacity(0.6)
            if !options.showDifference { c.text = planned; c.tone = .ghost; c.italic = true }
        case .teLaat:
            c.tint = cell.status.gridTint
            if !options.showDifference { c.text = planned; c.tone = .late; c.italic = true }
        case .nietVerwacht:
            if !options.showDifference && options.isFuture(cell.month) { c.text = planned; c.tone = .ghost; c.italic = true }
        case .afgevinkt:
            c.check = true
            if !options.showDifference { c.text = planned; c.tone = .secondary }
        case .gelijk, .afwijkend:
            break
        }
        return c
    }

    /// Uitleg bij een cel, in gewone taal.
    static func help(_ cell: GridCell, row: GridItemRow, options: GridOptions) -> String {
        let month = "\(Day.monthNames[cell.month - 1]) \(options.year)"
        if row.kind == .reserveLine {
            let amount = (cell.expected ?? row.plan).formatted()
            return "\(row.label) · \(month)\nOnderdeel van RESERVERINGEN: \(amount) per keer.\nTelt niet mee in de totalen."
        }
        var lines = ["\(row.label) · \(month)"]
        if let expected = cell.expected {
            lines.append("Plan: \(expected.formatted())")
        } else {
            lines.append("Plan: niet verwacht in deze maand")
        }
        if cell.entryCount > 0 {
            let count = cell.entryCount == 1 ? "1 boeking" : "\(cell.entryCount) boekingen"
            lines.append("Geboekt: \(cell.sum.formatted()) (\(count))")
            if cell.expected != nil {
                lines.append(cell.difference.isZero ? "Verschil: geen" : "Verschil: \(cell.difference.formatted(alwaysSign: true))")
            }
        } else {
            lines.append("Geboekt: nog niets")
        }
        if cell.status == .afgevinkt {
            lines.append("Met de hand afgevinkt als voldaan.")
        } else if options.isFuture(cell.month) && cell.entryCount == 0 && cell.expected != nil {
            lines.append("Deze maand moet nog komen; het schuine bedrag is het plan.")
        } else {
            lines.append("\(cell.status.gridTitle). \(cell.status.gridExplanation)")
        }
        if cell.isChecked && cell.status != .afgevinkt { lines.append("Ook met de hand afgevinkt als voldaan.") }
        if options.editable { lines.append("Klik voor de boekingen, dubbelklik om een boeking toe te voegen.") }
        return lines.joined(separator: "\n")
    }
}

/// De rij uit HFInsight; `GridRow` zonder voorvoegsel botst met die van SwiftUI.
typealias GridItemRow = HFInsight.GridRow

/// De begrotingsmaand als "yyyy-MM", zoals `Entry.period`.
enum GridPeriod {
    static func key(year: Int, month: Int) -> String { String(format: "%04d-%02d", year, month) }

    /// De maand vóór, de maand van en de maand na een datum.
    static func around(_ day: Day) -> [(year: Int, month: Int)] {
        [-1, 0, 1].map { shift in
            let index = day.year * 12 + (day.month - 1) + shift
            return (year: index / 12, month: index % 12 + 1)
        }
    }
}
