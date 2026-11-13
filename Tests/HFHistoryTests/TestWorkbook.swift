import Foundation
import HFCore
@testable import HFHistory

// Bouwt verzonnen .xlsx-bestanden voor de tests: de XML-delen worden hier geschreven en met /usr/bin/zip ingepakt.

enum TCell {
    /// Tekst via de gedeelde tekstentabel (zoals Excel het doet).
    case text(String)
    /// Tekst in de cel zelf (inlineStr).
    case inline(String)
    case num(Double)
    /// Datum met standaardopmaak (numFmtId 14).
    case date(Day)
    /// Datum met eigen opmaak "mmm" (toont alleen de maandnaam).
    case monthDate(Day)
    /// Datumgetal zonder datumopmaak.
    case rawDate(Day)
    /// Formule met bewaarde uitkomst.
    case formula(String, Double)
}

struct TSheet {
    var name: String
    var cells: [Int: [Int: TCell]] = [:]

    init(_ name: String) { self.name = name }

    mutating func set(_ row: Int, _ column: Int, _ cell: TCell) {
        cells[row, default: [:]][column] = cell
    }

    /// Zet een rij waarden vanaf een kolom; nil = lege cel.
    mutating func row(_ row: Int, from column: Int = 1, _ values: [TCell?]) {
        for (offset, value) in values.enumerated() {
            if let value { set(row, column + offset, value) }
        }
    }
}

enum TestWorkbook {
    static func columnName(_ column: Int) -> String {
        var n = column, s = ""
        while n > 0 {
            let r = (n - 1) % 26
            s = String(UnicodeScalar(UInt8(65 + r))) + s
            n = (n - 1) / 26
        }
        return s
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Schrijft de werkmap naar een tijdelijk bestand en geeft de URL. De aanroeper ruimt de map op (`cleanUp`).
    static func write(_ sheets: [TSheet], date1904: Bool = false) throws -> URL {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("hfhistory-test-\(UUID().uuidString)", isDirectory: true)
        let root = base.appendingPathComponent("src", isDirectory: true)
        try fm.createDirectory(at: root.appendingPathComponent("_rels"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("xl/_rels"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("xl/worksheets"), withIntermediateDirectories: true)

        var shared: [String] = []
        func sharedIndex(_ s: String) -> Int {
            if let i = shared.firstIndex(of: s) { return i }
            shared.append(s)
            return shared.count - 1
        }
        let header = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
        let mainNS = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
        let relNS = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"

        for (index, sheet) in sheets.enumerated() {
            var xml = header + "<worksheet xmlns=\"\(mainNS)\"><sheetData>"
            for row in sheet.cells.keys.sorted() {
                xml += "<row r=\"\(row)\">"
                for column in sheet.cells[row]!.keys.sorted() {
                    let ref = "\(columnName(column))\(row)"
                    switch sheet.cells[row]![column]! {
                    case .text(let s): xml += "<c r=\"\(ref)\" t=\"s\"><v>\(sharedIndex(s))</v></c>"
                    case .inline(let s): xml += "<c r=\"\(ref)\" t=\"inlineStr\"><is><t>\(escape(s))</t></is></c>"
                    case .num(let d): xml += "<c r=\"\(ref)\"><v>\(d)</v></c>"
                    case .date(let day): xml += "<c r=\"\(ref)\" s=\"1\"><v>\(Int(XLSXWorkbook.serial(for: day)))</v></c>"
                    case .monthDate(let day): xml += "<c r=\"\(ref)\" s=\"2\"><v>\(Int(XLSXWorkbook.serial(for: day)))</v></c>"
                    case .rawDate(let day): xml += "<c r=\"\(ref)\"><v>\(Int(XLSXWorkbook.serial(for: day)))</v></c>"
                    case .formula(let f, let d): xml += "<c r=\"\(ref)\"><f>\(escape(f))</f><v>\(d)</v></c>"
                    }
                }
                xml += "</row>"
            }
            xml += "</sheetData></worksheet>"
            try xml.write(to: root.appendingPathComponent("xl/worksheets/sheet\(index + 1).xml"), atomically: true, encoding: .utf8)
        }

        var workbook = header + "<workbook xmlns=\"\(mainNS)\" xmlns:r=\"\(relNS)\">"
        workbook += "<workbookPr\(date1904 ? " date1904=\"1\"" : "")/><sheets>"
        var rels = header + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
        var types = header + "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">"
            + "<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/>"
            + "<Default Extension=\"xml\" ContentType=\"application/xml\"/>"
            + "<Override PartName=\"/xl/workbook.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml\"/>"
            + "<Override PartName=\"/xl/styles.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml\"/>"
            + "<Override PartName=\"/xl/sharedStrings.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sharedStrings+xml\"/>"
        for (index, sheet) in sheets.enumerated() {
            workbook += "<sheet name=\"\(escape(sheet.name))\" sheetId=\"\(index + 1)\" r:id=\"rId\(index + 1)\"/>"
            rels += "<Relationship Id=\"rId\(index + 1)\" Type=\"\(relNS)/worksheet\" Target=\"worksheets/sheet\(index + 1).xml\"/>"
            types += "<Override PartName=\"/xl/worksheets/sheet\(index + 1).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>"
        }
        workbook += "</sheets></workbook>"
        rels += "<Relationship Id=\"rId900\" Type=\"\(relNS)/styles\" Target=\"styles.xml\"/>"
            + "<Relationship Id=\"rId901\" Type=\"\(relNS)/sharedStrings\" Target=\"sharedStrings.xml\"/></Relationships>"
        types += "</Types>"

        // Stijl 0 = standaard, 1 = datum (14), 2 = eigen opmaak "mmm", 3 = getal met tekst "dagen" (geen datum).
        let styles = header + "<styleSheet xmlns=\"\(mainNS)\">"
            + "<numFmts count=\"2\"><numFmt numFmtId=\"164\" formatCode=\"mmm\"/>"
            + "<numFmt numFmtId=\"165\" formatCode=\"0.00 &quot;dagen&quot;\"/></numFmts>"
            + "<fonts count=\"1\"><font/></fonts><fills count=\"1\"><fill/></fills><borders count=\"1\"><border/></borders>"
            + "<cellStyleXfs count=\"1\"><xf numFmtId=\"14\"/></cellStyleXfs>"
            + "<cellXfs count=\"4\"><xf numFmtId=\"0\"/><xf numFmtId=\"14\"/><xf numFmtId=\"164\"/><xf numFmtId=\"165\"/></cellXfs>"
            + "</styleSheet>"
        var strings = header + "<sst xmlns=\"\(mainNS)\" count=\"\(shared.count)\" uniqueCount=\"\(shared.count)\">"
        for s in shared { strings += "<si><t xml:space=\"preserve\">\(escape(s))</t></si>" }
        strings += "</sst>"
        let rootRels = header + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
            + "<Relationship Id=\"rId1\" Type=\"\(relNS)/officeDocument\" Target=\"xl/workbook.xml\"/></Relationships>"

        try types.write(to: root.appendingPathComponent("[Content_Types].xml"), atomically: true, encoding: .utf8)
        try rootRels.write(to: root.appendingPathComponent("_rels/.rels"), atomically: true, encoding: .utf8)
        try workbook.write(to: root.appendingPathComponent("xl/workbook.xml"), atomically: true, encoding: .utf8)
        try rels.write(to: root.appendingPathComponent("xl/_rels/workbook.xml.rels"), atomically: true, encoding: .utf8)
        try styles.write(to: root.appendingPathComponent("xl/styles.xml"), atomically: true, encoding: .utf8)
        try strings.write(to: root.appendingPathComponent("xl/sharedStrings.xml"), atomically: true, encoding: .utf8)

        let out = base.appendingPathComponent("werkmap.xlsx")
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = root
        zip.arguments = ["-q", "-r", "-X", out.path, "."]
        zip.standardOutput = FileHandle.nullDevice
        zip.standardError = FileHandle.nullDevice
        try zip.run()
        zip.waitUntilExit()
        guard zip.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
        return out
    }

    static func cleanUp(_ url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    /// Schrijft, leest als begrotingswerkmap en ruimt op.
    static func budget(_ sheets: [TSheet]) throws -> HistoryBudget {
        let url = try write(sheets)
        defer { cleanUp(url) }
        return try HistoryWorkbook.readBudget(url)
    }

    static func savings(_ sheets: [TSheet]) throws -> HistorySavings {
        let url = try write(sheets)
        defer { cleanUp(url) }
        return try HistoryWorkbook.readSavings(url)
    }
}

func eur(_ value: Double) -> Money { Money(cents: Int64((value * 100).rounded())) }
func day(_ y: Int, _ m: Int, _ d: Int) -> Day { Day(year: y, month: m, day: d)! }

/// Het "rijke" jaarblad met alle bijzonderheden van de echte indeling, met verzonnen inhoud.
/// Inkomsten 5.550,00; uitgaven -2.385,60; 6 posten; 6 gridboekingen en 6 losse regels.
struct RichYear {
    var year = 2020
    var name: String?
    /// Kolom van januari (3 = C, 4 = D, 6 = F).
    var firstMonthColumn = 3
    var monthsAsDates = true
    /// "plan", "nu" of nil (geen plankolom).
    var planHeader: String? = "plan"
    /// Datums in kolom B bij de losse regels.
    var datedVarious = false
    var opening = 1000.0
    var statedIncome = 5550.0
    var statedExpenses = -2385.6
    var closing: Double?

    static let income = 5550.0, expenses = -2385.6

    func sheet() -> TSheet {
        var s = TSheet(name ?? "\(year)")
        let m = firstMonthColumn
        func col(_ month: Int) -> Int { m + month - 1 }
        let uitEten = m + 12, tanken = m + 13
        let hasPlan = planHeader != nil

        if let planHeader { s.set(1, 2, .text(planHeader)) }
        if m == 6 {
            s.row(1, from: 3, [.text("scenario A"), .text("scenario B"), .text("scenario C")])
            s.row(2, from: 3, [.num(2600), .num(2700), .num(2800)])
            s.row(3, from: 3, [.num(-950), .num(-975), .num(-990)])
        }
        for month in 1...12 {
            if monthsAsDates {
                s.set(1, col(month), month % 2 == 0 ? .monthDate(day(year, month, 1)) : .date(day(year, month, 1)))
            } else {
                s.set(1, col(month), .text(Day.monthNamesShort[month - 1]))
            }
        }
        s.set(1, uitEten, .text("Uit eten"))
        s.set(1, tanken, .inline("Tanken"))

        func plan(_ row: Int, _ value: Double) { if hasPlan { s.set(row, 2, .num(value)) } }
        s.set(2, 1, .text("IN Salaris")); plan(2, 2500)
        s.set(2, col(1), .num(2500)); s.set(2, col(2), .formula("1250*2", 2500))
        s.set(3, 1, .text("UIT Huur")); plan(3, -900)
        s.set(3, col(1), .num(-900)); s.set(3, col(2), .num(-900))
        s.set(4, 1, .text("Hulpregel")); s.set(4, col(1), .num(123))
        s.set(5, 1, .text("RESERVERINGEN")); plan(5, -300); s.set(5, col(1), .num(-300))
        s.set(6, 1, .text("RES Auto")); plan(6, -200); s.set(6, col(1), .num(-200))
        s.set(7, 1, .text("RES Vakantie")); plan(7, -100)
        s.set(8, 1, .text("UIT Energie")); plan(8, -120); s.set(8, col(3), .num(-120.10000000000001))
        s.set(9, 1, .text("Totaal")); s.set(9, col(1), .formula("SUM(X2:X8)", 1300))
        s.set(10, 1, .text("UIT")); s.set(10, 2, .num(-1320))
        s.set(11, 1, .text("IN")); s.set(11, 2, .num(2500))

        s.set(12, 1, .text("IN Various"))
        s.set(13, 1, .text("Verkoop fiets")); s.set(13, col(5), .num(150))
        s.set(14, 1, .text("Belastingteruggave")); s.set(14, col(6), .num(400)); s.set(14, tanken, .num(999))
        s.set(15, col(5), .formula("SUM(X13:X14)", 150)); s.set(15, col(6), .formula("SUM(X13:X14)", 400))

        s.set(16, 1, .text("UIT Various"))
        s.set(17, 1, .text("Tankbeurt")); s.set(17, col(3), .num(-60)); s.set(17, tanken, .num(-60))
        s.set(18, 1, .text("Restaurant")); s.set(18, col(4), .num(-45.5)); s.set(18, uitEten, .num(45.5))
        s.set(19, 1, .text("Cadeau")); s.set(19, col(7), .num(-25)); s.set(19, col(8), .num(-35)); s.set(19, tanken, .num(12))
        s.set(20, col(3), .formula("SUM(X17:X19)", -60)); s.set(20, col(4), .formula("SUM(X17:X19)", -45.5))
        if datedVarious {
            s.set(13, 2, .date(day(year, 5, 20)))
            s.set(17, 2, .date(day(year, 3, 7)))
            s.set(18, 2, .date(day(year - 1, 4, 2)))   // buiten het jaar: niet bruikbaar
        }

        s.set(21, 1, .text("Op de rekening op 01-01-99")); s.set(21, 2, .num(opening))
        s.set(22, 1, .text("IN")); s.set(22, 2, .formula("SUM(X2:X20)", statedIncome))
        s.set(23, 1, .text("UIT")); s.set(23, 2, .num(statedExpenses))
        s.set(24, 1, .text("Op de rekening")); s.set(24, 2, .num(closing ?? opening + Self.income + Self.expenses))
        s.set(25, 1, .text("Besteedbaar")); s.set(25, 2, .num(100))
        return s
    }
}

/// Een eenvoudig jaarblad: posten met bedragen per maand en losse regels. De totalen worden uitgerekend.
struct SimpleYear {
    var name: String
    var opening = 0.0
    /// (label met voorvoegsel, plan, [maand: bedrag])
    var items: [(String, Double, [Int: Double])] = []
    var incomeVarious: [(String, Int, Double)] = []
    var expenseVarious: [(String, Int, Double)] = []
    var statedIncome: Double?
    var statedExpenses: Double?
    var closing: Double?

    func sheet() -> TSheet {
        var s = TSheet(name)
        s.set(1, 2, .text("plan"))
        for month in 1...12 { s.set(1, 2 + month, .text(Day.monthNamesShort[month - 1])) }
        var row = 2
        var all: [Double] = []
        for (label, plan, months) in items {
            s.set(row, 1, .text(label)); s.set(row, 2, .num(plan))
            for (month, amount) in months { s.set(row, 2 + month, .num(amount)); if !label.hasPrefix("RES ") { all.append(amount) } }
            row += 1
        }
        s.set(row, 1, .text("Totaal")); row += 1
        s.set(row, 1, .text("IN Various")); row += 1
        for (label, month, amount) in incomeVarious {
            s.set(row, 1, .text(label)); s.set(row, 2 + month, .num(amount)); all.append(amount); row += 1
        }
        s.set(row, 1, .text("UIT Various")); row += 1
        for (label, month, amount) in expenseVarious {
            s.set(row, 1, .text(label)); s.set(row, 2 + month, .num(amount)); all.append(amount); row += 1
        }
        let income = all.filter { $0 > 0 }.reduce(0, +), expenses = all.filter { $0 < 0 }.reduce(0, +)
        s.set(row, 1, .text("Op de rekening op 1-1")); s.set(row, 2, .num(opening)); row += 1
        s.set(row, 1, .text("IN")); s.set(row, 2, .num(statedIncome ?? income)); row += 1
        s.set(row, 1, .text("UIT")); s.set(row, 2, .num(statedExpenses ?? expenses)); row += 1
        s.set(row, 1, .text("Op de rekening")); s.set(row, 2, .num(closing ?? opening + income + expenses))
        return s
    }
}
