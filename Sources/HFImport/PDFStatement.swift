import Foundation
import PDFKit
import HFCore

/// PDF-rekeningafschrift van de bank: herkennen en de tekstlaag lezen.
public enum PDFStatement {
    /// Het bestand is een PDF (begint met `%PDF` of heeft de extensie .pdf).
    public static func isPDF(data: Data, fileName: String) -> Bool {
        data.starts(with: Data("%PDF".utf8)) || fileName.lowercased().hasSuffix(".pdf")
    }

    /// De tekst per pagina.
    static func pages(of data: Data) throws -> [String] {
        guard let document = PDFDocument(data: data) else { throw ImportError.pdfUnreadable }
        let pages = (0..<document.pageCount).map { document.page(at: $0)?.string ?? "" }
        guard pages.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw ImportError.pdfWithoutText
        }
        return pages
    }
}

public extension BankProfile {
    /// Het profiel dat een voorbeeld uit een PDF-rekeningafschrift meekrijgt (kolommen Datum, Bij/Af, Bedrag,
    /// Omschrijving). Alleen ter informatie; een PDF wordt niet via kolommen gelezen.
    static let pdfStatement = BankProfile(
        id: "pdf", name: "Rekeningafschrift (PDF)", hasHeader: true, day: .index(0), amount: .index(2),
        debitCredit: DebitCreditIndicator(column: .index(1)), description: [.index(3)])
}

/// Wat er uit de tekst van een rekeningafschrift is gelezen.
struct BankStatement: Equatable {
    struct Line: Equatable {
        var lineNumber: Int
        var day: Day
        var amount: Money
        /// Eerste regel plus vervolgregels van de omschrijving.
        var description: [String]
    }
    var ownIban = ""
    var openingBalance: Money?
    var openingDay: Day?
    var closingBalance: Money?
    var closingDay: Day?
    var lines: [Line] = []
    var errors: [ImportRowError] = []
}

/// Leest de tekstlaag van een rekeningafschrift. Zoekt op patronen, niet op regelnummers, omdat de
/// kopregels in de tekstlaag door elkaar kunnen staan.
enum StatementParser {
    /// `pages`: de tekst per pagina. Regelnummers tellen door over de pagina's (vanaf 1).
    static func parse(pages: [String]) throws -> BankStatement {
        let transaction = #/^(\d{1,2}-\d{1,2}-\d{4})\s+(\S+)\s+(\S+)(?:\s+(.*))?$/#
        let startsWithDate = #/^\d{1,2}-\d{1,2}-\d{4}(\s|$)/#
        let balanceLabel = #/(?i)(begin|eind)saldo(?:\s+op)?(?:\s+(\d{1,2}-\d{1,2}-\d{4}))?\s*(.*)$/#
        let period = #/\d{1,2}-\d{1,2}-\d{4}\s+t\/m(\s|$)/#
        let pageOf = #/(?i)^(blad|pagina)?\s*\d+\s+van\s+\d+$/#

        let pageLines = pages.map { page in
            page.components(separatedBy: .newlines).map(collapseWhitespace)
        }
        func isTableHeader(_ line: String) -> Bool {
            let l = line.lowercased()
            return l.contains("datum") && (l.contains("bij/af") || l.contains("af/bij") || l.contains("bedrag"))
        }
        func isBoilerplate(_ line: String) -> Bool {
            let l = line.lowercased()
            return l.hasPrefix("blad") || l.contains("rekeningafschrift") || l.hasPrefix("kredietlimiet")
                || l.hasPrefix("rekeninghouder") || line.contains(period) || line.wholeMatch(of: pageOf) != nil
        }
        func amountOnly(_ line: String) -> Money? {
            guard line.contains("€") || line.wholeMatch(of: #/[-+]?[\d.]+,\d{2}-?/#) != nil else { return nil }
            return Money(parsing: line)
        }

        let anyHeader = pageLines.contains { $0.contains(where: isTableHeader) }
        var statement = BankStatement()
        var pendingBalances: [Bool] = []   // true = beginsaldo wacht op een bedrag, false = eindsaldo
        var tableSeen = false
        var current: Int?                  // index in statement.lines die vervolgregels krijgt
        var lineNumber = 0

        for lines in pageLines {
            // Een pagina zonder tabelkop is een vervolgpagina; anders begint de tabel pas na de kop.
            var inTable = anyHeader ? (tableSeen && !lines.contains(where: isTableHeader)) : true
            if !anyHeader { current = nil }

            for line in lines {
                lineNumber += 1
                if line.isEmpty { continue }

                if isTableHeader(line) {
                    inTable = true; tableSeen = true; pendingBalances = []
                    continue
                }
                if let m = line.firstMatch(of: balanceLabel) {
                    let isOpening = m.1.lowercased() == "begin"
                    let day = m.2.flatMap { Day(dutch: String($0)) }
                    let known = isOpening ? statement.openingBalance != nil : statement.closingBalance != nil
                    if !known {
                        if isOpening { statement.openingDay = day ?? statement.openingDay }
                        else { statement.closingDay = day ?? statement.closingDay }
                        if let amount = Money(parsing: String(m.3)) {
                            if isOpening { statement.openingBalance = amount } else { statement.closingBalance = amount }
                        } else if !pendingBalances.contains(isOpening) {
                            pendingBalances.append(isOpening)
                        }
                    }
                    continue
                }
                if let amount = amountOnly(line) {
                    if !pendingBalances.isEmpty {
                        if pendingBalances.removeFirst() { statement.openingBalance = amount }
                        else { statement.closingBalance = amount }
                        continue
                    }
                    if line.hasPrefix("€") { continue }
                }
                if !inTable || current == nil, statement.ownIban.isEmpty, let iban = findIban(in: line) {
                    statement.ownIban = iban.iban
                    if !inTable { continue }
                }
                guard inTable else { continue }
                if isBoilerplate(line) { continue }

                if line.contains(startsWithDate) {
                    pendingBalances = []
                    switch readTransaction(line, lineNumber: lineNumber, pattern: transaction) {
                    case .success(let t):
                        statement.lines.append(t); current = statement.lines.count - 1
                    case .failure(let message):
                        statement.errors.append(ImportRowError(lineNumber: lineNumber, message: message.text, fields: [line]))
                        current = nil
                    }
                } else if let current {
                    statement.lines[current].description.append(line)
                }
            }
        }

        guard tableSeen || !statement.lines.isEmpty || !statement.errors.isEmpty else {
            throw ImportError.noTransactionTable
        }
        return statement
    }

    private static func readTransaction(_ line: String, lineNumber: Int,
                                        pattern: Regex<(Substring, Substring, Substring, Substring, Substring?)>)
        -> Result<BankStatement.Line, RowMessage> {
        guard let m = line.wholeMatch(of: pattern) else {
            return .failure(RowMessage(text: "De regel begint met een datum maar is geen leesbare transactie: \"\(line)\"."))
        }
        guard let day = Day(dutch: String(m.1)) else {
            return .failure(RowMessage(text: "Ongeldige datum \"\(m.1)\"."))
        }
        let negative: Bool
        switch m.2.lowercased() {
        case "bij": negative = false
        case "af": negative = true
        default: return .failure(RowMessage(text: "Onbekende af/bij-aanduiding \"\(m.2)\"."))
        }
        guard let amount = Money(parsing: String(m.3)) else {
            return .failure(RowMessage(text: "Ongeldig bedrag \"\(m.3)\"."))
        }
        let first = m.4.map(String.init) ?? ""
        return .success(BankStatement.Line(lineNumber: lineNumber, day: day,
                                           amount: negative ? -amount.magnitude : amount.magnitude,
                                           description: first.isEmpty ? [] : [first]))
    }

    /// Eerste IBAN in een regel (met of zonder spaties), genormaliseerd, plus de rest van de regel.
    static func findIban(in line: String) -> (iban: String, rest: String)? {
        let patterns = [
            #/\b[A-Z]{2}\d{2}[A-Z]{4}\d{10}\b/#,
            #/\b[A-Z]{2}\d{2} [A-Z]{4} \d{4} \d{4} \d{2}\b/#,
            #/\b[A-Z]{2}\d{2}[A-Z0-9]{11,30}\b/#,
        ]
        for pattern in patterns {
            if let m = line.firstMatch(of: pattern) {
                var rest = line
                rest.removeSubrange(m.range)
                return (normalizeIban(String(m.0)), collapseWhitespace(rest))
            }
        }
        return nil
    }

    /// Haalt waar herkenbaar de tegenpartij uit de omschrijving: het eerste IBAN dat niet het eigen IBAN is,
    /// en als naam de overige tekst op die regel (of een regel "Naam: …").
    static func counterparty(in description: [String], ownIban: String) -> (name: String, iban: String) {
        var name = "", iban = ""
        for line in description {
            if iban.isEmpty, let found = findIban(in: line), found.iban != ownIban {
                iban = found.iban
                if name.isEmpty { name = cleanName(found.rest) }
            }
            if let m = line.firstMatch(of: #/(?i)\bnaam\s*:\s*(.+)$/#) { name = cleanName(String(m.1)) }
        }
        return (name, iban)
    }

    private static func cleanName(_ s: String) -> String {
        var t = s
        for label in ["IBAN", "Tegenrekening", "Naam", "van", "aan"] {
            if let r = t.range(of: "^\(label)\\b[: ]*", options: [.regularExpression, .caseInsensitive]) { t.removeSubrange(r) }
        }
        return t.trimmingCharacters(in: CharacterSet(charactersIn: " ,;:-/"))
    }

    static func collapseWhitespace(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}

extension ImportPreview {
    /// Bouwt het voorbeeld uit een gelezen rekeningafschrift. Het saldo vóór elke regel wordt uitgerekend
    /// vanaf het beginsaldo; de keten sluit als beginsaldo + som van de regels gelijk is aan het eindsaldo.
    static func build(statement: BankStatement, fileName: String, account: Account,
                      existingFingerprints: Set<String> = []) -> ImportPreview {
        let accountId = account.id ?? 0
        var rows = statement.lines.map { line -> ImportRow in
            let party = StatementParser.counterparty(in: line.description, ownIban: statement.ownIban)
            return ImportRow(
                lineNumber: line.lineNumber, day: line.day, amount: line.amount, balanceBefore: nil,
                counterpartyName: party.name, counterpartyIban: party.iban,
                descriptionText: line.description.joined(separator: " "), reference: "", transactionCode: "",
                sequence: "", statementNumber: "", ownIban: statement.ownIban, fingerprint: "", isDuplicate: false)
        }
        assignFingerprints(&rows, accountId: accountId, existing: existingFingerprints)

        // Oplopend of aflopend bestand: de datums bepalen de richting.
        let indices = Array(rows.indices)
        let order = (rows.first?.day ?? .today()) > (rows.last?.day ?? .today()) ? Array(indices.reversed()) : indices

        var warnings: [ImportWarning] = []
        if let warning = ibanWarning(account: account, rows: rows) { warnings.append(warning) }

        var chainOK: Bool?
        let total = rows.map(\.amount).sum()
        if let opening = statement.openingBalance {
            var balance = opening
            for i in order {
                rows[i].balanceBefore = balance
                balance = balance + rows[i].amount
            }
            if let closing = statement.closingBalance {
                chainOK = balance == closing
                if balance != closing {
                    warnings.append(ImportWarning(kind: .chainBroken, message:
                        "Beginsaldo \(opening.formatted()) plus de gelezen regels (\(total.formatted(alwaysSign: true))) geeft "
                        + "\(balance.formatted()), maar het afschrift noemt eindsaldo \(closing.formatted()). "
                        + "Verschil \((closing - balance).formatted()). Mogelijk ontbreken er regels."))
                }
            }
        }
        if chainOK == nil {
            warnings.append(ImportWarning(kind: .chainNotChecked, message:
                "Het saldo is niet gecontroleerd: het begin- of eindsaldo is niet in het afschrift gevonden."))
        }

        return ImportPreview(
            accountId: accountId, fileName: fileName, profile: .pdfStatement, encodingName: "PDF",
            dialect: CSVDialect(delimiter: " ", quote: "\""), rows: rows, errors: statement.errors,
            chronologicalIndices: order, chainOK: chainOK, chainBreaks: [],
            openingBalance: statement.openingBalance, closingBalance: statement.closingBalance,
            firstDay: rows.map(\.day).min(), lastDay: rows.map(\.day).max(), warnings: warnings)
    }
}
