import Foundation
import CryptoKit
import HFCore

/// Fouten die de import als geheel tegenhouden. De tekst is voor de gebruiker.
public enum ImportError: Error, Equatable, LocalizedError, Sendable {
    case unreadable
    case emptyFile
    case noProfile
    case accountNotFound
    case columnNotFound(String)
    case rowErrors(Int)
    case pdfUnreadable
    case pdfWithoutText
    case noTransactionTable
    case archiveUnreadable
    case archiveUnsafePath(String)
    case nothingToImport

    public var errorDescription: String? {
        switch self {
        case .unreadable: return "Het bestand kan niet worden gelezen (onbekende tekencodering)."
        case .emptyFile: return "Het bestand bevat geen transacties."
        case .noProfile: return "De indeling van het bestand is niet herkend. Kies zelf de kolommen."
        case .accountNotFound: return "De rekening bestaat niet."
        case .columnNotFound(let name): return "De kolom \"\(name)\" staat niet in de kopregel van het bestand."
        case .pdfUnreadable: return "De PDF kan niet worden geopend."
        case .pdfWithoutText: return "De PDF bevat geen leesbare tekst (mogelijk een scan). Download het afschrift opnieuw bij de bank."
        case .noTransactionTable: return "In de PDF is geen rekeningafschrift met transacties herkend."
        case .archiveUnreadable: return "Het zip-bestand kan niet worden uitgepakt."
        case .archiveUnsafePath(let name):
            return "Het zip-bestand bevat een onveilig pad (\"\(name)\") en is niet uitgepakt."
        case .nothingToImport: return "Er is geen bestand dat bij een rekening hoort; er is niets geïmporteerd."
        case .rowErrors(let n):
            return n == 1
                ? "Het bestand bevat 1 regel met een fout. Er is niets geïmporteerd."
                : "Het bestand bevat \(n) regels met een fout. Er is niets geïmporteerd."
        }
    }
}

/// Een regel die niet gelezen kon worden.
public struct ImportRowError: Identifiable, Equatable, Sendable {
    /// Regelnummer in het bestand (vanaf 1).
    public var lineNumber: Int
    /// Nederlandse uitleg, zonder regelnummer.
    public var message: String
    /// De velden van de regel, onbewerkt.
    public var fields: [String]

    public var id: Int { lineNumber }
    /// "Regel 12: Ongeldig bedrag …"
    public var description: String { "Regel \(lineNumber): \(message)" }
}

/// Een gelezen transactie uit het bestand, nog niet in de database.
public struct ImportRow: Identifiable, Equatable, Sendable {
    public var lineNumber: Int
    public var day: Day
    public var amount: Money
    public var balanceBefore: Money?
    public var counterpartyName: String
    public var counterpartyIban: String
    public var descriptionText: String
    public var reference: String
    public var transactionCode: String
    public var sequence: String
    public var statementNumber: String
    /// IBAN van de eigen rekening volgens het bestand (leeg als de bank die niet levert).
    public var ownIban: String
    public var fingerprint: String
    /// Staat al in de database en wordt bij importeren overgeslagen.
    public var isDuplicate: Bool

    public var id: Int { lineNumber }
    /// Saldo ná deze mutatie, als het saldo vóór bekend is.
    public var balanceAfter: Money? { balanceBefore.map { $0 + amount } }
}

/// Een plek waar de saldoketen niet sluit.
public struct ChainBreak: Equatable, Sendable {
    /// De regel waarvan het saldo-vóór niet klopt, en de regel ervoor (in tijdsvolgorde).
    public var lineNumber: Int
    public var previousLineNumber: Int
    /// Saldo-vóór plus bedrag van de vorige regel.
    public var expected: Money
    /// Saldo-vóór van deze regel.
    public var found: Money

    public var message: String {
        "Regel \(lineNumber): saldo vóór mutatie is \(found.formatted()), verwacht \(expected.formatted()) "
            + "(na regel \(previousLineNumber)). Verschil \((found - expected).formatted())."
    }
}

/// Waarschuwing bij een voorbeeld; houdt het importeren niet tegen.
public struct ImportWarning: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case ibanMismatch, chainBroken, chainNotChecked }
    public var kind: Kind
    public var message: String
    /// Bij `ibanMismatch`: de rekening waar het bestand volgens het IBAN wel bij hoort, als die bestaat.
    public var suggestedAccount: Account? = nil
}

/// Het resultaat van het lezen van een bestand, vóór het importeren. Elke regel van het bestand is een
/// `ImportRow` of een `ImportRowError`.
public struct ImportPreview: Equatable, Sendable {
    public var accountId: Int64
    public var fileName: String
    public var profile: BankProfile
    public var encodingName: String
    public var dialect: CSVDialect
    /// Gelezen transacties, in de volgorde van het bestand.
    public var rows: [ImportRow]
    public var errors: [ImportRowError]
    /// Indexen in `rows`, van oud naar nieuw.
    public var chronologicalIndices: [Int]
    /// true/false als de saldoketen gecontroleerd is; nil als het bestand geen saldo levert.
    public var chainOK: Bool?
    public var chainBreaks: [ChainBreak]
    /// Saldo vóór de eerste en ná de laatste transactie volgens het bestand.
    public var openingBalance: Money?
    public var closingBalance: Money?
    public var firstDay: Day?
    public var lastDay: Day?
    public var warnings: [ImportWarning]

    /// Aantal regels met een transactie in het bestand (goed en fout).
    public var rowCount: Int { rows.count + errors.count }
    public var newCount: Int { rows.count - duplicateCount }
    public var duplicateCount: Int { rows.filter(\.isDuplicate).count }
    public var errorCount: Int { errors.count }
    /// Transacties van oud naar nieuw.
    public var rowsChronological: [ImportRow] { chronologicalIndices.map { rows[$0] } }
    /// Importeren kan zonder de keuze om foute regels over te slaan.
    public var canCommit: Bool { errors.isEmpty && !rows.isEmpty }
}

/// Vingerafdruk van een bankregel, om dubbele import te herkennen.
public enum Fingerprint {
    /// SHA-256 (hex) over rekening, dag, bedrag, tegenrekening, volgnummer, afschriftnummer en omschrijving,
    /// plus `occurrence`: het hoeveelste voorkomen dit is van verder gelijke regels in hetzelfde bestand (vanaf 0).
    public static func make(accountId: Int64, day: Day, amount: Money, counterpartyIban: String, sequence: String,
                            statementNumber: String, description: String, occurrence: Int = 0) -> String {
        let key = baseKey(accountId: accountId, day: day, amount: amount, counterpartyIban: counterpartyIban,
                          sequence: sequence, statementNumber: statementNumber, description: description)
        return hash(key, occurrence: occurrence)
    }

    static func baseKey(accountId: Int64, day: Day, amount: Money, counterpartyIban: String, sequence: String,
                        statementNumber: String, description: String) -> String {
        ["v1", String(accountId), day.iso, String(amount.cents), normalizeIban(counterpartyIban),
         sequence.trimmingCharacters(in: .whitespaces), statementNumber.trimmingCharacters(in: .whitespaces),
         description.trimmingCharacters(in: .whitespaces)]
            .joined(separator: "\u{1F}")
    }

    static func hash(_ key: String, occurrence: Int) -> String {
        let digest = SHA256.hash(data: Data((key + "\u{1F}" + String(occurrence)).utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

func normalizeIban(_ s: String) -> String {
    s.uppercased().filter { !$0.isWhitespace }
}

// MARK: - Bestand naar voorbeeld

extension ImportPreview {
    /// Bouwt het voorbeeld uit een gelezen bestand. `existingFingerprints` zijn de vingerafdrukken die al
    /// in de database staan. Raakt de database niet aan; `BankImporter.preview` doet dat erbij.
    public static func build(file: CSVFile, fileName: String, account: Account, profile: BankProfile,
                             existingFingerprints: Set<String> = []) throws -> ImportPreview {
        var file = file
        let wanted = CSVDialect(delimiter: profile.delimiter ?? file.dialect.delimiter,
                                quote: profile.quote ?? file.dialect.quote)
        if wanted != file.dialect { file = file.reparsed(with: wanted) }

        var records = file.records
        var headers: [String] = []
        if profile.hasHeader, !records.isEmpty { headers = records.removeFirst().fields }
        let columns = try ResolvedColumns(profile: profile, headers: headers)
        let accountId = account.id ?? 0

        var rows: [ImportRow] = []
        var errors: [ImportRowError] = []
        for record in records {
            switch columns.read(record, profile: profile) {
            case .failure(let message):
                errors.append(ImportRowError(lineNumber: record.lineNumber, message: message.text, fields: record.fields))
            case .success(let row):
                rows.append(row)
            }
        }
        assignFingerprints(&rows, accountId: accountId, existing: existingFingerprints)

        let chain = BalanceChain(rows: rows)
        var warnings: [ImportWarning] = []

        if let warning = ibanWarning(account: account, rows: rows) { warnings.append(warning) }
        if chain.ok == false {
            let n = chain.breaks.count
            warnings.append(ImportWarning(kind: .chainBroken, message:
                "De saldoketen sluit niet op \(n) \(n == 1 ? "plek" : "plekken"). Mogelijk ontbreken er regels."))
        } else if chain.ok == nil, profile.balance != nil, !rows.isEmpty {
            warnings.append(ImportWarning(kind: .chainNotChecked, message:
                "De saldoketen is niet gecontroleerd: niet elke regel heeft een saldo."))
        }

        return ImportPreview(
            accountId: accountId, fileName: fileName, profile: profile, encodingName: file.encodingName,
            dialect: file.dialect, rows: rows, errors: errors, chronologicalIndices: chain.order,
            chainOK: chain.ok, chainBreaks: chain.breaks,
            openingBalance: chain.opening, closingBalance: chain.closing,
            firstDay: rows.map(\.day).min(), lastDay: rows.map(\.day).max(), warnings: warnings)
    }
}

extension ImportPreview {
    /// Geeft elke regel zijn vingerafdruk (met volgnummer voor verder gelijke regels) en de dubbel-vlag.
    static func assignFingerprints(_ rows: inout [ImportRow], accountId: Int64, existing: Set<String>) {
        var occurrences: [String: Int] = [:]
        for i in rows.indices {
            let row = rows[i]
            let key = Fingerprint.baseKey(accountId: accountId, day: row.day, amount: row.amount,
                                          counterpartyIban: row.counterpartyIban, sequence: row.sequence,
                                          statementNumber: row.statementNumber, description: row.descriptionText)
            let occurrence = occurrences[key, default: 0]
            occurrences[key] = occurrence + 1
            rows[i].fingerprint = Fingerprint.hash(key, occurrence: occurrence)
            rows[i].isDuplicate = existing.contains(rows[i].fingerprint)
        }
    }

    /// Waarschuwing als het bestand van een andere rekening is dan waarin geïmporteerd wordt.
    static func ibanWarning(account: Account, rows: [ImportRow]) -> ImportWarning? {
        guard let iban = account.iban.map(normalizeIban), !iban.isEmpty else { return nil }
        var seen = Set<String>()
        let others = rows.map(\.ownIban).filter { !$0.isEmpty && $0 != iban && seen.insert($0).inserted }
        guard !others.isEmpty else { return nil }
        return ImportWarning(kind: .ibanMismatch, message:
            "Het bestand is van rekening \(others.joined(separator: ", ")), maar je importeert in "
            + "\(account.name) (\(iban)).")
    }
}

struct RowMessage: Error { var text: String }

/// De kolommen van een profiel, omgezet naar kolomnummers voor één bestand.
struct ResolvedColumns {
    var day: Int
    var amount: Int
    var indicator: Int?
    var balance: Int?
    var ownIban: Int?
    var counterpartyIban: Int?
    var counterpartyName: Int?
    var description: [Int]
    var reference: Int?
    var transactionCode: Int?
    var sequence: Int?
    var statementNumber: Int?

    init(profile: BankProfile, headers: [String]) throws {
        let names = headers.map(BankProfile.normalizeHeader)
        func resolve(_ ref: ColumnRef) throws -> Int {
            switch ref {
            case .index(let i): return i
            case .header(let name):
                guard let i = names.firstIndex(of: BankProfile.normalizeHeader(name)) else {
                    throw ImportError.columnNotFound(name)
                }
                return i
            }
        }
        day = try resolve(profile.day)
        amount = try resolve(profile.amount)
        indicator = try profile.debitCredit.map { try resolve($0.column) }
        balance = try profile.balance.map { try resolve($0.column) }
        ownIban = try profile.ownIban.map(resolve)
        counterpartyIban = try profile.counterpartyIban.map(resolve)
        counterpartyName = try profile.counterpartyName.map(resolve)
        description = try profile.description.map(resolve)
        reference = try profile.reference.map(resolve)
        transactionCode = try profile.transactionCode.map(resolve)
        sequence = try profile.sequence.map(resolve)
        statementNumber = try profile.statementNumber.map(resolve)
    }

    func read(_ record: CSVRecord, profile: BankProfile) -> Result<ImportRow, RowMessage> {
        let f = record.fields
        func text(_ i: Int?) -> String {
            guard let i, f.indices.contains(i) else { return "" }
            return f[i].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func fail(_ s: String) -> Result<ImportRow, RowMessage> { .failure(RowMessage(text: s)) }

        if record.unterminatedQuote {
            return fail("Een aanhalingsteken op deze regel wordt nergens afgesloten; de rest van het bestand is niet gelezen.")
        }
        let needed = [day, amount, indicator].compactMap { $0 }.max()! + 1
        guard f.count >= needed else {
            return fail("De regel heeft \(f.count) \(f.count == 1 ? "kolom" : "kolommen"); minstens \(needed) verwacht.")
        }
        guard let dayValue = BankProfile.parseDay(text(day), formats: profile.dateFormats) else {
            return fail("Ongeldige datum \"\(text(day))\".")
        }
        guard var amountValue = Money(parsing: text(amount)) else {
            return fail("Ongeldig bedrag \"\(text(amount))\".")
        }
        if let dc = profile.debitCredit {
            let value = text(indicator).lowercased()
            if dc.debitValues.contains(where: { $0.lowercased() == value }) {
                amountValue = -amountValue.magnitude
            } else if dc.creditValues.contains(where: { $0.lowercased() == value }) {
                amountValue = amountValue.magnitude
            } else {
                return fail("Onbekende af/bij-aanduiding \"\(text(indicator))\".")
            }
        }
        var balanceBefore: Money?
        if let kind = profile.balance?.kind, !text(balance).isEmpty {
            guard let b = Money(parsing: text(balance)) else {
                return fail("Ongeldig saldo \"\(text(balance))\".")
            }
            balanceBefore = kind == .before ? b : b - amountValue
        }
        let descriptionText = description.map { text($0) }.filter { !$0.isEmpty }.joined(separator: " ")
        return .success(ImportRow(
            lineNumber: record.lineNumber, day: dayValue, amount: amountValue, balanceBefore: balanceBefore,
            counterpartyName: text(counterpartyName), counterpartyIban: normalizeIban(text(counterpartyIban)),
            descriptionText: descriptionText, reference: text(reference), transactionCode: text(transactionCode),
            sequence: text(sequence), statementNumber: text(statementNumber), ownIban: normalizeIban(text(ownIban)),
            fingerprint: "", isDuplicate: false))
    }
}

/// Zet de regels in tijdsvolgorde en controleert de saldoketen.
struct BalanceChain {
    var order: [Int]
    var ok: Bool?
    var breaks: [ChainBreak] = []
    var opening: Money?
    var closing: Money?

    init(rows: [ImportRow]) {
        let indices = Array(rows.indices)
        guard !rows.isEmpty else { order = []; ok = nil; return }

        guard rows.allSatisfy({ $0.balanceBefore != nil }) else {
            // Geen (volledig) saldo: alleen de richting van het bestand bepalen.
            order = rows.first!.day > rows.last!.day ? indices.reversed() : indices
            ok = nil
            return
        }

        func sequenceLess(_ a: ImportRow, _ b: ImportRow) -> Bool? {
            if a.sequence == b.sequence { return nil }
            if let x = Int(a.sequence), let y = Int(b.sequence) { return x < y }
            return a.sequence < b.sequence
        }
        func sorted(bySequence: Bool, fileAscending: Bool) -> [Int] {
            indices.sorted { i, j in
                let a = rows[i], b = rows[j]
                if a.day != b.day { return a.day < b.day }
                if bySequence, let less = sequenceLess(a, b) { return less }
                return fileAscending ? i < j : i > j
            }
        }
        func findBreaks(_ order: [Int]) -> [ChainBreak] {
            var result: [ChainBreak] = []
            for (p, n) in zip(order, order.dropFirst()) {
                let expected = rows[p].balanceBefore! + rows[p].amount
                let found = rows[n].balanceBefore!
                if expected != found {
                    result.append(ChainBreak(lineNumber: rows[n].lineNumber, previousLineNumber: rows[p].lineNumber,
                                             expected: expected, found: found))
                }
            }
            return result
        }

        // Banken sorteren verschillend (oud→nieuw, nieuw→oud, binnen een dag op volgnummer). De dag is
        // altijd leidend; binnen een dag wint de volgorde met de minste breuken.
        let candidates = [
            sorted(bySequence: true, fileAscending: true), sorted(bySequence: true, fileAscending: false),
            sorted(bySequence: false, fileAscending: true), sorted(bySequence: false, fileAscending: false),
        ]
        var best = candidates[0]
        var bestBreaks = findBreaks(best)
        for candidate in candidates.dropFirst() where !bestBreaks.isEmpty {
            let b = findBreaks(candidate)
            if b.count < bestBreaks.count { best = candidate; bestBreaks = b }
        }
        order = best
        breaks = bestBreaks
        ok = bestBreaks.isEmpty
        opening = rows[best.first!].balanceBefore
        closing = rows[best.last!].balanceAfter
    }
}
