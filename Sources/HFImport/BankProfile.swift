import Foundation
import HFCore

/// Verwijzing naar een kolom: op nummer (vanaf 0) of op naam in de kopregel.
/// In JSON een getal of een tekst.
public enum ColumnRef: Hashable, Sendable, Codable {
    case index(Int)
    case header(String)

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let i = try? c.decode(Int.self) { self = .index(i) } else { self = .header(try c.decode(String.self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .index(let i): try c.encode(i)
        case .header(let name): try c.encode(name)
        }
    }
}

/// Kolom die zegt of een bedrag af of bij is, voor banken die bedragen zonder teken leveren.
public struct DebitCreditIndicator: Codable, Equatable, Sendable {
    public var column: ColumnRef
    /// Waarden die "af" betekenen (hoofdletterongevoelig), bv. "Af", "D".
    public var debitValues: [String]
    /// Waarden die "bij" betekenen, bv. "Bij", "C".
    public var creditValues: [String]

    public init(column: ColumnRef, debitValues: [String] = ["af", "d", "debet", "debit", "db", "dr"],
                creditValues: [String] = ["bij", "c", "credit", "cr"]) {
        self.column = column; self.debitValues = debitValues; self.creditValues = creditValues
    }
}

/// Kolom met het saldo van de rekening vóór of ná de mutatie.
public struct BalanceColumn: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case before, after }
    public var column: ColumnRef
    public var kind: Kind

    public init(column: ColumnRef, kind: Kind) { self.column = column; self.kind = kind }
}

/// Beschrijft hoe het CSV-bestand van één bank in elkaar zit. Codable, zodat de app een eigen profiel
/// als JSON in `Setting` kan bewaren.
public struct BankProfile: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    /// Naam voor de gebruiker.
    public var name: String
    /// De eerste regel is een kopregel en geen transactie.
    public var hasHeader: Bool
    /// Vast scheidingsteken of aanhalingsteken; nil = raden uit het bestand.
    public var delimiter: String?
    public var quote: String?

    /// Boekingsdatum.
    public var day: ColumnRef
    /// Toegestane datumnotaties, in volgorde geprobeerd: "dd-MM-yyyy", "yyyy-MM-dd", "yyyyMMdd", "dd-MM-yy", …
    /// Bij een notatie met scheidingstekens mag het teken zelf afwijken (- / .).
    public var dateFormats: [String]
    /// Bedrag; wordt gelezen met `Money(parsing:)` (komma of punt als decimaalteken).
    public var amount: ColumnRef
    /// Alleen invullen als het bedrag geen teken heeft.
    public var debitCredit: DebitCreditIndicator?
    public var balance: BalanceColumn?

    /// IBAN van de eigen rekening, om te controleren of het bestand bij de rekening hoort.
    public var ownIban: ColumnRef?
    public var counterpartyIban: ColumnRef?
    public var counterpartyName: ColumnRef?
    /// Eén of meer kolommen; niet-lege waarden worden met een spatie samengevoegd.
    public var description: [ColumnRef]
    /// Betalingskenmerk.
    public var reference: ColumnRef?
    public var transactionCode: ColumnRef?
    /// Volgnummer van de transactie bij de bank.
    public var sequence: ColumnRef?
    /// Afschriftnummer.
    public var statementNumber: ColumnRef?

    public init(id: String, name: String, hasHeader: Bool, delimiter: String? = nil, quote: String? = nil,
                day: ColumnRef, dateFormats: [String] = ["dd-MM-yyyy"], amount: ColumnRef,
                debitCredit: DebitCreditIndicator? = nil, balance: BalanceColumn? = nil,
                ownIban: ColumnRef? = nil, counterpartyIban: ColumnRef? = nil, counterpartyName: ColumnRef? = nil,
                description: [ColumnRef] = [], reference: ColumnRef? = nil, transactionCode: ColumnRef? = nil,
                sequence: ColumnRef? = nil, statementNumber: ColumnRef? = nil) {
        self.id = id; self.name = name; self.hasHeader = hasHeader
        self.delimiter = delimiter; self.quote = quote
        self.day = day; self.dateFormats = dateFormats; self.amount = amount
        self.debitCredit = debitCredit; self.balance = balance
        self.ownIban = ownIban; self.counterpartyIban = counterpartyIban; self.counterpartyName = counterpartyName
        self.description = description; self.reference = reference; self.transactionCode = transactionCode
        self.sequence = sequence; self.statementNumber = statementNumber
    }

    // MARK: Ingebouwde profielen

    /// ASN Bank: geen kopregel, 19 kolommen, saldo vóór mutatie in kolom 8, bedrag met teken in kolom 10.
    /// Bevestigd met echte exports van de bank.
    public static let asn = BankProfile(
        id: "asn", name: "ASN Bank", hasHeader: false,
        day: .index(0), dateFormats: ["dd-MM-yyyy", "yyyy-MM-dd"], amount: .index(10),
        balance: BalanceColumn(column: .index(8), kind: .before),
        ownIban: .index(1), counterpartyIban: .index(2), counterpartyName: .index(3),
        description: [.index(17)], reference: .index(16), transactionCode: .index(14),
        sequence: .index(15), statementNumber: .index(18))

    /// Algemeen profiel voor een bestand met kopregel: herkent gangbare Nederlandse en Engelse kolomnamen
    /// (datum/date, bedrag/amount, naam/name, tegenrekening/iban, omschrijving/description, saldo, af/bij, …).
    /// Geeft nil als er geen datum- en bedragkolom te vinden is.
    public static func generic(headers: [String]) -> BankProfile? {
        let names = headers.map(normalizeHeader)
        var claimed = Set<Int>()

        func find(_ candidates: [String], contains: Bool = true) -> Int? {
            let passes: [(String, String) -> Bool] = contains
                ? [{ $0 == $1 }, { $0.hasPrefix($1) }, { $0.contains($1) }]
                : [{ $0 == $1 }, { $0.hasPrefix($1) }]
            for pass in passes {
                for candidate in candidates {
                    for (i, name) in names.enumerated() where !claimed.contains(i) && !name.isEmpty {
                        if pass(name, candidate) { claimed.insert(i); return i }
                    }
                }
            }
            return nil
        }

        // Eerst de uitgesproken naamkolommen, zodat "Naam tegenrekening" niet als IBAN wordt gezien.
        let specificName = find(["naamtegenpartij", "naamtegenrekening", "counterpartyname", "tegenpartijnaam"],
                                contains: false)
        let counterIban = find(["tegenrekening", "tegenrekeningiban", "ibantegenpartij", "ibantegenrekening",
                                "counterpartyiban", "counterpartyaccount", "counteraccount", "tegeniban"])
        let counterName = specificName
            ?? find(["tegenpartij", "naam", "name", "counterparty", "payee", "begunstigde"])
        let dayColumn = find(["datum", "date", "boekdatum", "boekingsdatum", "transactiedatum", "bookingdate",
                              "transactiondate"])
        let indicator = find(["afbij", "bijaf", "debitcredit", "creditdebit", "debetcredit", "creditdebet", "dc", "cd"],
                             contains: false)
        let amountColumn = find(["bedrag", "amount", "transactiebedrag"])
        let balanceBefore = find(["saldovoormutatie", "saldovoor", "balancebefore", "beginsaldo"])
        let balanceAfter = balanceBefore == nil
            ? find(["saldonamutatie", "saldonatrn", "saldona", "balanceafter", "eindsaldo", "saldo", "balance"])
            : nil
        let own = find(["rekening", "rekeningnummer", "iban", "ibanbban", "eigenrekening", "account",
                        "accountnumber"], contains: false)
        var descriptions: [Int] = []
        if let first = find(["omschrijving", "mededelingen", "description", "memo", "details", "notes", "kenmerken"]) {
            descriptions.append(first)
            // Banken die de omschrijving over meer kolommen verdelen (Omschrijving-1, -2, -3).
            for (i, name) in names.enumerated() where !claimed.contains(i) && name.hasPrefix("omschrijving") {
                claimed.insert(i); descriptions.append(i)
            }
            descriptions.sort()
        }
        let sequence = find(["volgnr", "volgnummer", "sequence", "transactionid", "transactieid"], contains: false)
        let reference = find(["betalingskenmerk", "kenmerk", "reference", "referentie"], contains: false)
        let code = find(["transactiecode", "code", "mutatiesoort", "transactioncode", "type"], contains: false)
        let statement = find(["afschriftnummer", "afschrift", "statementnumber", "statement"], contains: false)

        guard let dayColumn, let amountColumn else { return nil }
        func ref(_ i: Int?) -> ColumnRef? { i.map(ColumnRef.index) }
        return BankProfile(
            id: "generic", name: "Algemeen (met kopregel)", hasHeader: true,
            day: .index(dayColumn), dateFormats: ["dd-MM-yyyy", "yyyy-MM-dd", "yyyyMMdd"], amount: .index(amountColumn),
            debitCredit: indicator.map { DebitCreditIndicator(column: .index($0)) },
            balance: balanceBefore.map { BalanceColumn(column: .index($0), kind: .before) }
                ?? balanceAfter.map { BalanceColumn(column: .index($0), kind: .after) },
            ownIban: ref(own), counterpartyIban: ref(counterIban), counterpartyName: ref(counterName),
            description: descriptions.map(ColumnRef.index), reference: ref(reference), transactionCode: ref(code),
            sequence: ref(sequence), statementNumber: ref(statement))
    }

    /// Kiest het best passende profiel voor een bestand: het algemene profiel als de eerste regel een
    /// herkenbare kopregel is, anders ASN als de kolommen daarop lijken. nil = de gebruiker moet zelf
    /// kolommen kiezen (zie `CSVFile.rawRows`).
    public static func detect(for file: CSVFile) -> BankProfile? {
        guard let first = file.records.first else { return nil }
        let looksLikeData = first.fields.contains { parseDay($0, formats: ["dd-MM-yyyy", "yyyy-MM-dd", "yyyyMMdd"]) != nil }
        if !looksLikeData, let generic = generic(headers: first.fields) { return generic }
        let sample = file.records.prefix(20)
        let asnHits = sample.filter { r in
            r.fields.count >= 11
                && parseDay(r.fields[0], formats: asn.dateFormats) != nil
                && Money(parsing: r.fields[10]) != nil
        }.count
        if asnHits > 0, asnHits * 2 >= sample.count { return asn }
        return nil
    }

    // MARK: Datums

    /// Leest een datum volgens de eerste notatie die past.
    public static func parseDay(_ text: String, formats: [String]) -> Day? {
        for format in formats {
            if let day = parseDay(text, format: format) { return day }
        }
        return nil
    }

    static func parseDay(_ text: String, format: String) -> Day? {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = Array(format.lowercased())
        let letters = pattern.filter { "dmy".contains($0) }
        guard !letters.isEmpty else { return nil }
        var order: [Character] = []
        for c in letters where !order.contains(c) { order.append(c) }
        guard order.count == 3 else { return nil }
        let yearDigits = letters.filter { $0 == "y" }.count
        var parts: [Character: Int] = [:]

        if letters.count == pattern.count {
            // Zonder scheidingstekens: vaste breedtes.
            guard value.count == pattern.count, value.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
            let digits = Array(value)
            for c in order {
                let s = String(zip(pattern, digits).filter { $0.0 == c }.map(\.1))
                guard let v = Int(s) else { return nil }
                parts[c] = v
            }
        } else {
            // Een tijd achter de datum negeren ("2027-01-05 12:30" of "2027-01-05T12:30").
            if let cut = value.firstIndex(where: { $0 == " " || $0 == "T" }) { value = String(value[..<cut]) }
            let groups = value.split(whereSeparator: { !($0.isASCII && $0.isNumber) })
            guard groups.count == 3, value.first?.isNumber == true, value.last?.isNumber == true else { return nil }
            for (c, g) in zip(order, groups) {
                if c == "y" {
                    guard yearDigits == 2 ? g.count <= 2 : g.count == 4 else { return nil }
                } else {
                    guard g.count <= 2 else { return nil }
                }
                guard let v = Int(g) else { return nil }
                parts[c] = v
            }
        }
        guard var y = parts["y"], let m = parts["m"], let d = parts["d"] else { return nil }
        if yearDigits == 2 { y += 2000 }
        return Day(year: y, month: m, day: d)
    }

    static func normalizeHeader(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "nl_NL"))
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
    }
}

/// Kiest het best passende profiel voor een bestand; zie `BankProfile.detect(for:)`.
public func detectProfile(for file: CSVFile) -> BankProfile? {
    BankProfile.detect(for: file)
}
