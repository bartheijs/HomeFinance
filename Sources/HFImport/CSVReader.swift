import Foundation

/// Scheidingsteken en aanhalingsteken van een CSV-bestand.
public struct CSVDialect: Codable, Equatable, Sendable {
    /// Eén teken: ",", ";" of tab.
    public var delimiter: String
    /// Eén teken: "\"" of "'".
    public var quote: String

    public init(delimiter: String = ";", quote: String = "\"") {
        self.delimiter = delimiter
        self.quote = quote
    }
}

/// Eén regel uit een CSV-bestand, in velden gesplitst.
public struct CSVRecord: Equatable, Sendable {
    /// Regelnummer in het bestand (vanaf 1) waar deze regel begint.
    public var lineNumber: Int
    public var fields: [String]
    /// Een veld begon met een aanhalingsteken dat nergens werd afgesloten.
    public var unterminatedQuote: Bool

    public init(lineNumber: Int, fields: [String], unterminatedQuote: Bool = false) {
        self.lineNumber = lineNumber
        self.fields = fields
        self.unterminatedQuote = unterminatedQuote
    }
}

/// Leest CSV-tekst: codering raden, scheidingsteken raden, regels splitsen.
public enum CSVReader {
    /// Zet bytes om naar tekst. Probeert UTF-8 (met of zonder BOM), dan Windows-1252, dan ISO-8859-1.
    public static func decode(_ data: Data) -> (text: String, encoding: String.Encoding)? {
        let bytes = [UInt8](data.prefix(3))
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
            if let s = String(data: data.dropFirst(3), encoding: .utf8) { return (s, .utf8) }
        }
        if bytes.starts(with: [0xFF, 0xFE]) || bytes.starts(with: [0xFE, 0xFF]) {
            if let s = String(data: data, encoding: .utf16) { return (stripBOM(s), .utf16) }
        }
        for encoding in [String.Encoding.utf8, .windowsCP1252, .isoLatin1] {
            if let s = String(data: data, encoding: encoding) { return (stripBOM(s), encoding) }
        }
        return nil
    }

    private static func stripBOM(_ s: String) -> String {
        s.hasPrefix("\u{FEFF}") ? String(s.dropFirst()) : s
    }

    /// Raadt scheidingsteken (`,` `;` tab) en aanhalingsteken (`"` `'`) uit de eerste regels.
    public static func detectDialect(_ text: String) -> CSVDialect {
        var best = CSVDialect()
        var bestScore = -1.0
        for delimiter in [";", ",", "\t"] {
            // Per scheidingsteken eerst het aanhalingsteken kiezen: niet-afgesloten verliest, dan de
            // meest gelijkmatige kolomtelling, dan het teken dat echt gebruikt wordt.
            var chosen: (dialect: CSVDialect, score: Double, key: (Int, Double, Int))?
            for quote in ["\"", "'"] {
                let dialect = CSVDialect(delimiter: delimiter, quote: quote)
                let (records, quoted) = tokenize(text, dialect: dialect, limit: 100)
                guard !records.isEmpty else { continue }
                var frequency: [Int: Int] = [:]
                for r in records { frequency[r.fields.count, default: 0] += 1 }
                // Meest voorkomende aantal kolommen; bij gelijke stand het grootste.
                let modal = frequency.max { ($0.value, $0.key) < ($1.value, $1.key) }!
                let fraction = Double(modal.value) / Double(records.count)
                let unterminated = records.contains(where: \.unterminatedQuote)
                let score = fraction * Double(modal.key - 1) * (unterminated ? 0.5 : 1)
                let key = (unterminated ? 0 : 1, fraction, quoted)
                if chosen == nil || key > chosen!.key { chosen = (dialect, score, key) }
            }
            if let chosen, chosen.score > bestScore + 1e-9 {
                best = chosen.dialect; bestScore = chosen.score
            }
        }
        return best
    }

    /// Splitst tekst in regels en velden. Lege regels worden overgeslagen. Velden tussen aanhalingstekens
    /// mogen het scheidingsteken, regeleinden en een verdubbeld aanhalingsteken bevatten.
    public static func parse(_ text: String, dialect: CSVDialect, limit: Int? = nil) -> [CSVRecord] {
        tokenize(text, dialect: dialect, limit: limit).records
    }

    static func tokenize(_ text: String, dialect: CSVDialect, limit: Int?) -> (records: [CSVRecord], quotedFields: Int) {
        let delimiter = dialect.delimiter.first ?? ";"
        let quote = dialect.quote.first ?? "\""
        let chars = Array(text)
        let n = chars.count

        var records: [CSVRecord] = []
        var fields: [String] = []
        var field = ""
        var line = 1
        var recordLine = 1
        var inQuotes = false
        var fieldWasQuoted = false
        var quotedFields = 0

        func isNewline(_ c: Character) -> Bool { c == "\n" || c == "\r\n" || c == "\r" }
        func isBlank(_ c: Character) -> Bool { c == " " || (c == "\t" && delimiter != "\t") }

        func endField() {
            fields.append(field)
            field = ""
            fieldWasQuoted = false
        }
        func endRecord(unterminated: Bool) {
            endField()
            let empty = fields.allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty }
            // Een regel zonder enige inhoud (leeg, of alleen scheidingstekens) is geen regel.
            if !empty || unterminated {
                records.append(CSVRecord(lineNumber: recordLine, fields: fields, unterminatedQuote: unterminated))
            }
            fields = []
        }

        var i = 0
        while i < n {
            if let limit, records.count >= limit { return (records, quotedFields) }
            let c = chars[i]
            if inQuotes {
                if c == quote {
                    if i + 1 < n, chars[i + 1] == quote {
                        field.append(quote); i += 2; continue
                    }
                    // Sluit alleen als hierna (na eventuele spaties) het veld ook echt eindigt.
                    var j = i + 1
                    while j < n, isBlank(chars[j]) { j += 1 }
                    if j == n || chars[j] == delimiter || isNewline(chars[j]) {
                        inQuotes = false; i = j; continue
                    }
                    field.append(c); i += 1; continue
                }
                if isNewline(c) { line += 1 }
                field.append(c); i += 1; continue
            }
            if c == quote, !fieldWasQuoted, field.allSatisfy(isBlank) {
                inQuotes = true; fieldWasQuoted = true; quotedFields += 1
                field = ""; i += 1; continue
            }
            if c == delimiter { endField(); i += 1; continue }
            if isNewline(c) {
                endRecord(unterminated: false)
                line += 1; recordLine = line
                i += 1; continue
            }
            field.append(c); i += 1
        }
        if inQuotes || !field.isEmpty || !fields.isEmpty {
            if let limit, records.count >= limit { return (records, quotedFields) }
            endRecord(unterminated: inQuotes)
        }
        return (records, quotedFields)
    }
}

/// Een ingelezen CSV-bestand: tekst, gevonden codering en scheidingsteken, en alle regels.
public struct CSVFile: Equatable, Sendable {
    public var encoding: String.Encoding
    public var dialect: CSVDialect
    public var records: [CSVRecord]
    let text: String

    /// Leest een bestand. Zonder `dialect` wordt het scheidingsteken geraden.
    public init(data: Data, dialect: CSVDialect? = nil) throws {
        guard let decoded = CSVReader.decode(data) else { throw ImportError.unreadable }
        self.init(text: decoded.text, encoding: decoded.encoding, dialect: dialect)
    }

    /// Leest tekst die al gedecodeerd is.
    public init(text: String, encoding: String.Encoding = .utf8, dialect: CSVDialect? = nil) {
        let text = text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
        let d = dialect ?? CSVReader.detectDialect(text)
        self.text = text
        self.encoding = encoding
        self.dialect = d
        self.records = CSVReader.parse(text, dialect: d)
    }

    /// Hetzelfde bestand, opnieuw gesplitst met een ander scheidingsteken of aanhalingsteken.
    public func reparsed(with dialect: CSVDialect) -> CSVFile {
        CSVFile(text: text, encoding: encoding, dialect: dialect)
    }

    /// De eerste regels onbewerkt, zodat een scherm de gebruiker kolommen kan laten kiezen.
    public func rawRows(limit: Int = 10) -> [[String]] {
        records.prefix(limit).map(\.fields)
    }

    /// Het grootste aantal kolommen in het bestand.
    public var columnCount: Int { records.map(\.fields.count).max() ?? 0 }

    /// Naam van de codering voor weergave.
    public var encodingName: String {
        switch encoding {
        case .utf8: return "UTF-8"
        case .utf16: return "UTF-16"
        case .windowsCP1252: return "Windows-1252"
        case .isoLatin1: return "ISO-8859-1"
        default: return "onbekend"
        }
    }
}
