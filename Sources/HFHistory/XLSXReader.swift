import Foundation
import HFCore

// Minimale lezer voor .xlsx-bestanden, zonder code van derden.
// Een .xlsx is een zip met XML. We pakken hem uit in een tijdelijke map, lezen de werkbladen en ruimen de map
// daarna op. Van formules lezen we de waarde die Excel als laatste berekend en bewaard heeft.

public enum XLSXError: LocalizedError, Equatable {
    case fileMissing(String)
    case notAnXLSX(String)
    case damaged(String)

    public var errorDescription: String? {
        switch self {
        case .fileMissing(let name):
            "Het bestand \(name) is niet gevonden."
        case .notAnXLSX(let name):
            "\(name) is geen Excel-bestand van het type .xlsx. Open het in Excel en kies Bewaar als › Excel-werkmap (.xlsx)."
        case .damaged(let detail):
            "Het Excel-bestand kon niet gelezen worden (\(detail))."
        }
    }
}

/// De inhoud van één cel.
public enum XLSXValue: Equatable, Sendable {
    case empty
    case text(String)
    case number(Double)
    /// Een getal met een datumopmaak. `serial` is het oorspronkelijke getal.
    case date(Day, serial: Double)
}

public struct XLSXCell: Equatable, Sendable {
    public var value: XLSXValue
    /// De cel bevat een formule; `value` is de bewaarde uitkomst.
    public var hasFormula: Bool

    public static let empty = XLSXCell(value: .empty, hasFormula: false)

    public init(value: XLSXValue, hasFormula: Bool = false) {
        self.value = value; self.hasFormula = hasFormula
    }

    public var isEmpty: Bool { value == .empty }

    /// Tekst zonder spaties eromheen, of nil als de cel geen tekst bevat.
    public var text: String? {
        if case .text(let s) = value { return s }
        return nil
    }

    /// Het getal in de cel; ook voor een cel met datumopmaak.
    public var number: Double? {
        switch value {
        case .number(let d): d
        case .date(_, let serial): serial
        default: nil
        }
    }

    public var day: Day? {
        if case .date(let d, _) = value { return d }
        return nil
    }
}

public struct XLSXSheet: Sendable {
    public let name: String
    /// rij (vanaf 1) → kolom (vanaf 1, A = 1) → cel. Lege cellen ontbreken.
    public let rows: [Int: [Int: XLSXCell]]
    public let maxRow: Int
    public let maxColumn: Int
    /// De werkmap telt datums vanaf 1904 (oude Mac-werkmappen) in plaats van 1900.
    public let date1904: Bool

    public init(name: String, rows: [Int: [Int: XLSXCell]], date1904: Bool = false) {
        self.name = name; self.rows = rows; self.date1904 = date1904
        self.maxRow = rows.keys.max() ?? 0
        self.maxColumn = rows.values.compactMap { $0.keys.max() }.max() ?? 0
    }

    public subscript(row: Int, column: Int) -> XLSXCell {
        rows[row]?[column] ?? .empty
    }

    /// Zet een Excel-datumgetal om naar een dag, of nil als het geen aannemelijke datum is.
    public func day(fromSerial serial: Double) -> Day? {
        XLSXWorkbook.day(fromSerial: serial, date1904: date1904)
    }
}

public struct XLSXWorkbook: Sendable {
    /// Alle werkbladen, in de volgorde van de tabbladen.
    public let sheets: [XLSXSheet]

    public func sheet(named name: String) -> XLSXSheet? {
        let wanted = name.lowercased()
        return sheets.first { $0.name.trimmingCharacters(in: .whitespaces).lowercased() == wanted }
    }

    /// Leest een .xlsx-bestand. Het bestand zelf wordt niet gewijzigd; de tijdelijke kopie wordt opgeruimd.
    public static func read(_ url: URL) throws -> XLSXWorkbook {
        try read(url, temporaryRoot: FileManager.default.temporaryDirectory)
    }

    /// Als `read(_:)`, met de map waarin de tijdelijke kopie komt (voor tests).
    static func read(_ url: URL, temporaryRoot: URL) throws -> XLSXWorkbook {
        let fm = FileManager.default
        let fileName = url.lastPathComponent
        guard fm.fileExists(atPath: url.path) else { throw XLSXError.fileMissing(fileName) }

        let folder = temporaryRoot.appendingPathComponent("hfhistory-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: folder) }

        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", url.path, folder.path]
        unzip.standardOutput = FileHandle.nullDevice
        unzip.standardError = FileHandle.nullDevice
        do { try unzip.run() } catch { throw XLSXError.damaged("uitpakken lukte niet") }
        unzip.waitUntilExit()
        guard unzip.terminationStatus == 0 else { throw XLSXError.notAnXLSX(fileName) }

        func data(_ path: String) -> Data? {
            try? Data(contentsOf: folder.appendingPathComponent(path))
        }
        guard let workbookData = data("xl/workbook.xml") else { throw XLSXError.notAnXLSX(fileName) }

        let workbook = WorkbookParser()
        try parse(workbookData, with: workbook, what: "werkmap")

        let rels = RelsParser()
        if let d = data("xl/_rels/workbook.xml.rels") { try parse(d, with: rels, what: "verwijzingen") }

        let strings = SharedStringsParser()
        if let d = data("xl/sharedStrings.xml") { try parse(d, with: strings, what: "teksten") }

        let styles = StylesParser()
        if let d = data("xl/styles.xml") { try parse(d, with: styles, what: "opmaak") }
        let dateStyles = styles.dateStyles

        var sheets: [XLSXSheet] = []
        for (index, entry) in workbook.sheets.enumerated() {
            var path: String
            if let target = rels.targets[entry.relationId] {
                path = target.hasPrefix("/") ? String(target.dropFirst()) : "xl/" + target
            } else {
                path = "xl/worksheets/sheet\(index + 1).xml"
            }
            path = path.replacingOccurrences(of: "xl/./", with: "xl/")
            guard let d = data(path) else {
                sheets.append(XLSXSheet(name: entry.name, rows: [:], date1904: workbook.date1904))
                continue
            }
            let parser = SheetParser(sharedStrings: strings.strings, dateStyles: dateStyles, date1904: workbook.date1904)
            try parse(d, with: parser, what: "blad \(index + 1)")
            sheets.append(XLSXSheet(name: entry.name, rows: parser.rows, date1904: workbook.date1904))
        }
        return XLSXWorkbook(sheets: sheets)
    }

    private static func parse(_ data: Data, with delegate: XMLParserDelegate, what: String) throws {
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = delegate
        guard parser.parse() else { throw XLSXError.damaged(what) }
    }

    /// Excel telt dagen vanaf 1900 (met de bekende niet-bestaande 29-2-1900) of vanaf 1904.
    public static func day(fromSerial serial: Double, date1904: Bool) -> Day? {
        guard serial.isFinite, serial >= 1, serial < 110_000 else { return nil }
        let days = Int(serial.rounded(.down))
        if date1904 {
            return Day(year: 1904, month: 1, day: 1)?.adding(days: days)
        }
        guard days != 60 else { return nil }
        return Day(year: 1900, month: 1, day: 1)?.adding(days: days < 60 ? days - 1 : days - 2)
    }

    /// Het Excel-datumgetal van een dag (1900-telling). Handig voor wie zelf een testbestand maakt.
    public static func serial(for day: Day) -> Double {
        let base = Day(year: 1900, month: 1, day: 1)!
        let diff = Int((day.date.timeIntervalSince(base.date) / 86_400).rounded())
        return Double(diff + (diff >= 59 ? 2 : 1))
    }

    /// Is een opmaakcode een datumopmaak? Teksten tussen aanhalingstekens en blokken als [Red] tellen niet mee.
    static func isDateFormat(_ code: String) -> Bool {
        var stripped = ""
        var inQuote = false, inBracket = false, skipNext = false
        for ch in code {
            if skipNext { skipNext = false; continue }
            if inQuote { if ch == "\"" { inQuote = false }; continue }
            if inBracket { if ch == "]" { inBracket = false }; continue }
            switch ch {
            case "\"": inQuote = true
            case "[": inBracket = true
            case "\\", "_", "*": skipNext = true
            default: stripped.append(ch)
            }
        }
        let s = stripped.lowercased()
        // "mmm" is altijd een maandnaam (minuten zijn hoogstens "mm").
        return s.contains("d") || s.contains("y") || s.contains("mmm")
    }

    /// "BC12" → (kolom 55, rij 12)
    static func position(of reference: String) -> (column: Int, row: Int)? {
        var column = 0, row = 0
        for scalar in reference.unicodeScalars {
            switch scalar.value {
            case 65...90: column = column * 26 + Int(scalar.value - 64)
            case 97...122: column = column * 26 + Int(scalar.value - 96)
            case 48...57: row = row * 10 + Int(scalar.value - 48)
            case 36: continue   // $
            default: return nil
            }
        }
        return column > 0 && row > 0 ? (column, row) : nil
    }
}

// MARK: - XML-lezers

private final class WorkbookParser: NSObject, XMLParserDelegate {
    var sheets: [(name: String, relationId: String)] = []
    var date1904 = false

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes: [String: String] = [:]) {
        switch elementName {
        case "sheet":
            let rid = attributes.first { $0.key == "r:id" || $0.key.hasSuffix(":id") }?.value ?? ""
            sheets.append((attributes["name"] ?? "", rid))
        case "workbookPr":
            let v = attributes["date1904"]?.lowercased()
            date1904 = v == "1" || v == "true"
        default: break
        }
    }
}

private final class RelsParser: NSObject, XMLParserDelegate {
    var targets: [String: String] = [:]

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes: [String: String] = [:]) {
        if elementName == "Relationship", let id = attributes["Id"], let target = attributes["Target"] {
            targets[id] = target
        }
    }
}

private final class SharedStringsParser: NSObject, XMLParserDelegate {
    var strings: [String] = []
    private var current = ""
    private var inText = false
    private var phoneticDepth = 0

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes: [String: String] = [:]) {
        switch elementName {
        case "si": current = ""
        case "rPh": phoneticDepth += 1
        case "t": inText = phoneticDepth == 0
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inText { current += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        switch elementName {
        case "si": strings.append(current)
        case "rPh": phoneticDepth -= 1
        case "t": inText = false
        default: break
        }
    }
}

private final class StylesParser: NSObject, XMLParserDelegate {
    private var customFormats: [Int: String] = [:]
    private var cellFormatIds: [Int] = []
    private var inCellXfs = false

    /// Per stijlnummer (attribuut `s` van een cel): is het een datumopmaak?
    var dateStyles: [Bool] {
        cellFormatIds.map { id in
            if (14...22).contains(id) { return true }
            if let code = customFormats[id] { return XLSXWorkbook.isDateFormat(code) }
            return false
        }
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes: [String: String] = [:]) {
        switch elementName {
        case "numFmt":
            if let id = attributes["numFmtId"].flatMap(Int.init), let code = attributes["formatCode"] {
                customFormats[id] = code
            }
        case "cellXfs": inCellXfs = true
        case "xf":
            if inCellXfs { cellFormatIds.append(attributes["numFmtId"].flatMap(Int.init) ?? 0) }
        default: break
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "cellXfs" { inCellXfs = false }
    }
}

private final class SheetParser: NSObject, XMLParserDelegate {
    let sharedStrings: [String]
    let dateStyles: [Bool]
    let date1904: Bool
    var rows: [Int: [Int: XLSXCell]] = [:]

    private var row = 0, column = 0
    private var type = "", style: Int?
    private var valueText = "", inlineText = ""
    private var hasFormula = false
    private var inCell = false, inValue = false, inInlineText = false

    init(sharedStrings: [String], dateStyles: [Bool], date1904: Bool) {
        self.sharedStrings = sharedStrings; self.dateStyles = dateStyles; self.date1904 = date1904
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes: [String: String] = [:]) {
        switch elementName {
        case "row":
            row = attributes["r"].flatMap(Int.init) ?? row + 1
            column = 0
        case "c":
            if let ref = attributes["r"], let pos = XLSXWorkbook.position(of: ref) {
                column = pos.column; row = pos.row
            } else {
                column += 1
            }
            type = attributes["t"] ?? "n"
            style = attributes["s"].flatMap(Int.init)
            valueText = ""; inlineText = ""; hasFormula = false; inCell = true
        case "f": if inCell { hasFormula = true }
        case "v": inValue = inCell
        case "t": inInlineText = inCell
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inValue { valueText += string } else if inInlineText { inlineText += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        switch elementName {
        case "v": inValue = false
        case "t": inInlineText = false
        case "c":
            inCell = false
            let value = cellValue()
            if value != .empty || hasFormula {
                rows[row, default: [:]][column] = XLSXCell(value: value, hasFormula: hasFormula)
            }
        default: break
        }
    }

    private func cellValue() -> XLSXValue {
        func text(_ s: String) -> XLSXValue {
            let cleaned = s.replacingOccurrences(of: "\u{00A0}", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            return cleaned.isEmpty ? .empty : .text(cleaned)
        }
        switch type {
        case "s":
            guard let index = Int(valueText.trimmingCharacters(in: .whitespaces)), sharedStrings.indices.contains(index) else { return .empty }
            return text(sharedStrings[index])
        case "inlineStr": return text(inlineText)
        case "str", "e": return text(valueText)
        case "b": return text(valueText == "1" ? "WAAR" : "ONWAAR")
        case "d":
            if let day = Day(iso: String(valueText.prefix(10))) { return .date(day, serial: XLSXWorkbook.serial(for: day)) }
            return text(valueText)
        default:
            guard let number = Double(valueText.trimmingCharacters(in: .whitespaces)) else { return .empty }
            if let style, dateStyles.indices.contains(style), dateStyles[style],
               let day = XLSXWorkbook.day(fromSerial: number, date1904: date1904) {
                return .date(day, serial: number)
            }
            return .number(number)
        }
    }
}
