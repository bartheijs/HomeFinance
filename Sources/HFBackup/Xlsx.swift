import Foundation
import HFCore

// Kleine xlsx-schrijver zonder code van derden: schrijft de XML-delen zelf en pakt ze in met /usr/bin/zip.
// Genoeg voor de jaarexport: tekst, bedragen, hele getallen, datums, formules met bewaarde uitkomst,
// vet, inspringen, bevroren rij en kolom, kolombreedtes en een autofilter.

/// Eén cel van een werkblad.
struct XlsxCell: Equatable {
    enum Value: Equatable {
        case empty
        case text(String)
        /// Bedrag als echt getal, met twee decimalen.
        case money(Money)
        case integer(Int)
        /// Echte datumcel, opgemaakt als dd-mm-jjjj.
        case date(Day)
        /// Formule (zonder "=") met de uitkomst erbij, zodat het bestand ook zonder herberekenen klopt.
        case formula(String, cached: Money)
    }

    var value: Value
    var bold = false
    var indent = false

    static let empty = XlsxCell(value: .empty)
    static func text(_ text: String, bold: Bool = false, indent: Bool = false) -> XlsxCell {
        XlsxCell(value: text.isEmpty ? .empty : .text(text), bold: bold, indent: indent)
    }
    static func money(_ money: Money, bold: Bool = false) -> XlsxCell { XlsxCell(value: .money(money), bold: bold) }
    static func integer(_ value: Int, bold: Bool = false) -> XlsxCell { XlsxCell(value: .integer(value), bold: bold) }
    static func date(_ day: Day, bold: Bool = false) -> XlsxCell { XlsxCell(value: .date(day), bold: bold) }
    static func formula(_ formula: String, _ cached: Money, bold: Bool = false) -> XlsxCell {
        XlsxCell(value: .formula(formula, cached: cached), bold: bold)
    }
}

/// Eén tabblad.
struct XlsxSheet {
    var name: String
    var rows: [[XlsxCell]] = []
    /// Kolombreedtes in tekens, vanaf kolom A.
    var widths: [Double] = []
    var freezeRows = 1
    var freezeColumns = 1
    /// Autofilter op de eerste rij, over alle rijen.
    var autoFilter = false

    /// Voegt een rij toe en geeft het rijnummer (vanaf 1) terug.
    @discardableResult
    mutating func add(_ cells: [XlsxCell]) -> Int {
        rows.append(cells)
        return rows.count
    }
}

enum Xlsx {
    // Stijlnummers (index in cellXfs van styles.xml).
    static let styleBold = 1, styleMoney = 2, styleMoneyBold = 3, styleDate = 4, styleDateBold = 5, styleIndent = 6

    /// "A", "B", … "Z", "AA", … voor kolomindex 0, 1, …
    static func column(_ index: Int) -> String {
        var n = index, name = ""
        repeat {
            name = String(UnicodeScalar(UInt8(65 + n % 26))) + name
            n = n / 26 - 1
        } while n >= 0
        return name
    }

    /// Celverwijzing, bv. `ref(2, 5)` = "C5" (kolomindex vanaf 0, rij vanaf 1).
    static func ref(_ column: Int, _ row: Int) -> String { "\(Self.column(column))\(row)" }

    /// Tekst veilig voor XML: tekens met een bijzondere betekenis vervangen, ongeldige stuurtekens weglaten.
    static func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&apos;"
            case "\t", "\n", "\r": out.unicodeScalars.append(scalar)
            default:
                if scalar.value < 0x20 || scalar.value == 0xFFFE || scalar.value == 0xFFFF { continue }
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    /// Centen als decimaal getal met punt, bv. "-1234.56". Nooit via Double.
    static func number(_ money: Money) -> String {
        let a = money.cents.magnitude
        return (money.cents < 0 ? "-" : "") + "\(a / 100)." + String(format: "%02d", Int(a % 100))
    }

    /// Volgnummer van een dag zoals Excel het telt (1 = 1-1-1900; 25569 = 1-1-1970).
    static func serial(_ day: Day) -> Int {
        Int((day.date.timeIntervalSince1970 / 86_400).rounded()) + 25_569
    }

    /// Naam van een tabblad: hoogstens 31 tekens, zonder tekens die Excel niet toestaat.
    static func sheetName(_ name: String) -> String {
        let cleaned = String(name.map { "[]:*?/\\".contains($0) ? " " : $0 }.prefix(31))
        return cleaned.isEmpty ? "Blad" : cleaned
    }

    /// Alle onderdelen van het bestand als (pad, inhoud), in de volgorde waarin ze in de zip komen.
    static func parts(_ sheets: [XlsxSheet]) -> [(path: String, xml: String)] {
        let header = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
        let main = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
        let relNS = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
        let pkgRel = "http://schemas.openxmlformats.org/package/2006/relationships"

        // Gedeelde teksten: elke tekst één keer, cellen verwijzen ernaar met een nummer.
        var stringIndex: [String: Int] = [:]
        var strings: [String] = []
        var stringUses = 0
        func shared(_ text: String) -> Int {
            stringUses += 1
            if let index = stringIndex[text] { return index }
            stringIndex[text] = strings.count
            strings.append(text)
            return strings.count - 1
        }

        var sheetXML: [String] = []
        for (sheetNumber, sheet) in sheets.enumerated() {
            var xml = header + "<worksheet xmlns=\"\(main)\">"
            let columnCount = max(sheet.rows.map(\.count).max() ?? 0, 1)
            xml += "<dimension ref=\"A1:\(ref(columnCount - 1, max(sheet.rows.count, 1)))\"/>"
            xml += "<sheetViews><sheetView workbookViewId=\"0\"\(sheetNumber == 0 ? " tabSelected=\"1\"" : "")>"
            if sheet.freezeRows > 0 || sheet.freezeColumns > 0 {
                var pane = "<pane"
                if sheet.freezeColumns > 0 { pane += " xSplit=\"\(sheet.freezeColumns)\"" }
                if sheet.freezeRows > 0 { pane += " ySplit=\"\(sheet.freezeRows)\"" }
                let active = sheet.freezeRows > 0 && sheet.freezeColumns > 0 ? "bottomRight"
                    : (sheet.freezeRows > 0 ? "bottomLeft" : "topRight")
                pane += " topLeftCell=\"\(ref(sheet.freezeColumns, sheet.freezeRows + 1))\" activePane=\"\(active)\" state=\"frozen\"/>"
                xml += pane + "<selection pane=\"\(active)\"/>"
            }
            xml += "</sheetView></sheetViews><sheetFormatPr defaultRowHeight=\"15\"/>"
            if !sheet.widths.isEmpty {
                xml += "<cols>"
                for (index, width) in sheet.widths.enumerated() {
                    xml += "<col min=\"\(index + 1)\" max=\"\(index + 1)\" width=\"\(width)\" customWidth=\"1\"/>"
                }
                xml += "</cols>"
            }
            xml += "<sheetData>"
            for (rowIndex, row) in sheet.rows.enumerated() {
                let r = rowIndex + 1
                var cells = ""
                for (columnIndex, cell) in row.enumerated() {
                    let at = "r=\"\(ref(columnIndex, r))\""
                    switch cell.value {
                    case .empty:
                        continue
                    case .text(let text):
                        let style = cell.bold ? styleBold : (cell.indent ? styleIndent : 0)
                        cells += "<c \(at) s=\"\(style)\" t=\"s\"><v>\(shared(text))</v></c>"
                    case .money(let money):
                        cells += "<c \(at) s=\"\(cell.bold ? styleMoneyBold : styleMoney)\"><v>\(number(money))</v></c>"
                    case .integer(let value):
                        cells += "<c \(at) s=\"\(cell.bold ? styleBold : 0)\"><v>\(value)</v></c>"
                    case .date(let day):
                        cells += "<c \(at) s=\"\(cell.bold ? styleDateBold : styleDate)\"><v>\(serial(day))</v></c>"
                    case .formula(let formula, let cached):
                        cells += "<c \(at) s=\"\(cell.bold ? styleMoneyBold : styleMoney)\"><f>\(escape(formula))</f>"
                            + "<v>\(number(cached))</v></c>"
                    }
                }
                if !cells.isEmpty { xml += "<row r=\"\(r)\">\(cells)</row>" }
            }
            xml += "</sheetData>"
            if sheet.autoFilter, !sheet.rows.isEmpty {
                xml += "<autoFilter ref=\"A1:\(ref((sheet.rows.first?.count ?? 1) - 1, sheet.rows.count))\"/>"
            }
            xml += "<pageMargins left=\"0.7\" right=\"0.7\" top=\"0.75\" bottom=\"0.75\" header=\"0.3\" footer=\"0.3\"/>"
            xml += "</worksheet>"
            sheetXML.append(xml)
        }

        var contentTypes = header + "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">"
            + "<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/>"
            + "<Default Extension=\"xml\" ContentType=\"application/xml\"/>"
            + "<Override PartName=\"/xl/workbook.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml\"/>"
        var workbook = header + "<workbook xmlns=\"\(main)\" xmlns:r=\"\(relNS)\"><bookViews><workbookView/></bookViews><sheets>"
        var workbookRels = header + "<Relationships xmlns=\"\(pkgRel)\">"
        for (index, sheet) in sheets.enumerated() {
            let n = index + 1
            contentTypes += "<Override PartName=\"/xl/worksheets/sheet\(n).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>"
            workbook += "<sheet name=\"\(escape(sheetName(sheet.name)))\" sheetId=\"\(n)\" r:id=\"rId\(n)\"/>"
            workbookRels += "<Relationship Id=\"rId\(n)\" Type=\"\(relNS)/worksheet\" Target=\"worksheets/sheet\(n).xml\"/>"
        }
        contentTypes += "<Override PartName=\"/xl/styles.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml\"/>"
            + "<Override PartName=\"/xl/sharedStrings.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sharedStrings+xml\"/>"
            + "</Types>"
        workbook += "</sheets></workbook>"
        workbookRels += "<Relationship Id=\"rId\(sheets.count + 1)\" Type=\"\(relNS)/styles\" Target=\"styles.xml\"/>"
            + "<Relationship Id=\"rId\(sheets.count + 2)\" Type=\"\(relNS)/sharedStrings\" Target=\"sharedStrings.xml\"/>"
            + "</Relationships>"

        let rootRels = header + "<Relationships xmlns=\"\(pkgRel)\">"
            + "<Relationship Id=\"rId1\" Type=\"\(relNS)/officeDocument\" Target=\"xl/workbook.xml\"/></Relationships>"

        // Getalopmaak 4 is de ingebouwde "#,##0.00" (duizendtalscheiding en twee decimalen volgens de taal van
        // het programma); 164 is de eigen datumopmaak.
        let font = "<sz val=\"11\"/><name val=\"Calibri\"/><family val=\"2\"/>"
        let styles = header + "<styleSheet xmlns=\"\(main)\">"
            + "<numFmts count=\"1\"><numFmt numFmtId=\"164\" formatCode=\"dd\\-mm\\-yyyy\"/></numFmts>"
            + "<fonts count=\"2\"><font>\(font)</font><font><b/>\(font)</font></fonts>"
            + "<fills count=\"2\"><fill><patternFill patternType=\"none\"/></fill><fill><patternFill patternType=\"gray125\"/></fill></fills>"
            + "<borders count=\"1\"><border><left/><right/><top/><bottom/><diagonal/></border></borders>"
            + "<cellStyleXfs count=\"1\"><xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\"/></cellStyleXfs>"
            + "<cellXfs count=\"7\">"
            + "<xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\" xfId=\"0\"/>"
            + "<xf numFmtId=\"0\" fontId=\"1\" fillId=\"0\" borderId=\"0\" xfId=\"0\" applyFont=\"1\"/>"
            + "<xf numFmtId=\"4\" fontId=\"0\" fillId=\"0\" borderId=\"0\" xfId=\"0\" applyNumberFormat=\"1\"/>"
            + "<xf numFmtId=\"4\" fontId=\"1\" fillId=\"0\" borderId=\"0\" xfId=\"0\" applyNumberFormat=\"1\" applyFont=\"1\"/>"
            + "<xf numFmtId=\"164\" fontId=\"0\" fillId=\"0\" borderId=\"0\" xfId=\"0\" applyNumberFormat=\"1\"/>"
            + "<xf numFmtId=\"164\" fontId=\"1\" fillId=\"0\" borderId=\"0\" xfId=\"0\" applyNumberFormat=\"1\" applyFont=\"1\"/>"
            + "<xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\" xfId=\"0\" applyAlignment=\"1\"><alignment indent=\"1\"/></xf>"
            + "</cellXfs>"
            + "<cellStyles count=\"1\"><cellStyle name=\"Normal\" xfId=\"0\" builtinId=\"0\"/></cellStyles>"
            + "</styleSheet>"

        var sharedStrings = header + "<sst xmlns=\"\(main)\" count=\"\(stringUses)\" uniqueCount=\"\(strings.count)\">"
        for text in strings {
            sharedStrings += "<si><t xml:space=\"preserve\">\(escape(text))</t></si>"
        }
        sharedStrings += "</sst>"

        var result: [(String, String)] = [
            ("[Content_Types].xml", contentTypes), ("_rels/.rels", rootRels),
            ("xl/workbook.xml", workbook), ("xl/_rels/workbook.xml.rels", workbookRels),
            ("xl/styles.xml", styles), ("xl/sharedStrings.xml", sharedStrings),
        ]
        for (index, xml) in sheetXML.enumerated() {
            result.append(("xl/worksheets/sheet\(index + 1).xml", xml))
        }
        return result
    }

    /// Schrijft de tabbladen als één .xlsx-bestand naar `url` (een bestaand bestand wordt vervangen).
    static func write(_ sheets: [XlsxSheet], to url: URL) throws {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("HomeFinance-xlsx-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        let content = work.appendingPathComponent("inhoud", isDirectory: true)
        let files = parts(sheets)
        for file in files {
            let target = content.appendingPathComponent(file.path)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(file.xml.utf8).write(to: target)
        }

        // Inpakken: zonder extra macOS-kenmerken (-X) en zonder mapregels (-D), [Content_Types].xml eerst.
        let archive = work.appendingPathComponent("uit.xlsx")
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = content
        zip.arguments = ["-X", "-D", "-q", archive.path] + files.map(\.path)
        let errors = Pipe()
        zip.standardError = errors
        zip.standardOutput = Pipe()
        do {
            try zip.run()
        } catch {
            throw ExportError.writeFailed("zip kon niet worden gestart")
        }
        let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        zip.waitUntilExit()
        guard zip.terminationStatus == 0, fm.fileExists(atPath: archive.path) else {
            throw ExportError.writeFailed(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if fm.fileExists(atPath: url.path) {
            _ = try fm.replaceItemAt(url, withItemAt: archive)
        } else {
            try fm.moveItem(at: archive, to: url)
        }
    }
}
