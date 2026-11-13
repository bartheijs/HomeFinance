import Foundation
import HFCore

// Wat er uit de Excel-werkmappen gelezen is, vóór er iets in de database komt.

/// Een opmerking bij het inlezen: een waarschuwing of een overgeslagen rij.
public struct HistoryNote: Equatable, Sendable {
    public var sheet: String
    /// Rijnummer in het blad, of nil als de opmerking over het hele blad gaat.
    public var row: Int?
    public var message: String
    /// Korte, vaste soortnaam zonder inhoud uit het blad (bv. "teken", "hulprij"); voor de samenvatting.
    public var code: String

    public init(sheet: String, row: Int? = nil, code: String = "overig", message: String) {
        self.sheet = sheet; self.row = row; self.message = message; self.code = code
    }

    /// "Blad 2019, rij 14: …"
    public var text: String {
        "Blad \(sheet)" + (row.map { ", rij \($0)" } ?? "") + ": " + message
    }
}

/// Een vaste post uit het hoofdgrid van een jaarblad.
public struct HistoryItem: Equatable, Sendable {
    public var direction: Direction
    /// Het label zonder het voorvoegsel IN, UIT of RES.
    public var label: String
    /// Plan met het teken van de richting (IN ≥ 0, UIT en RES ≤ 0).
    public var plan: Money
    /// De regel RESERVERINGEN.
    public var isReserveTotal: Bool
    /// Twaalf maanden (index 0 = januari); nil = niets betaald of ontvangen. Altijd leeg bij RES-regels.
    public var monthAmounts: [Money?]
    public var sheet: String
    public var row: Int

    public init(direction: Direction, label: String, plan: Money, isReserveTotal: Bool = false,
                monthAmounts: [Money?] = Array(repeating: nil, count: 12), sheet: String = "", row: Int = 0) {
        self.direction = direction; self.label = label; self.plan = plan
        self.isReserveTotal = isReserveTotal; self.monthAmounts = monthAmounts
        self.sheet = sheet; self.row = row
    }
}

/// Een losse inkomst of uitgave uit het blok IN Various of UIT Various.
public struct HistoryVariousEntry: Equatable, Sendable {
    /// Het blok waarin de rij stond: `.IN` of `.UIT`.
    public var section: Direction
    public var label: String
    public var day: Day
    /// De maandkolom (1–12) waarin het bedrag stond. Kan afwijken van de maand van `day`.
    public var month: Int
    /// false: er stond geen bruikbare datum in kolom B; de dag is de 15e van de maand.
    public var dayIsKnown: Bool
    public var amount: Money
    /// De laatste maand waar deze regel bij hoort: de maandkolom of de maand van de datum, wat later is.
    public var lastMonth: Int { max(month, day.month) }
    /// Namen van de volgkolommen waarin hetzelfde bedrag stond.
    public var tags: [String]
    public var sheet: String
    public var row: Int

    public init(section: Direction, label: String, day: Day, month: Int? = nil, dayIsKnown: Bool, amount: Money,
                tags: [String] = [], sheet: String = "", row: Int = 0) {
        self.section = section; self.label = label; self.day = day; self.month = month ?? day.month
        self.dayIsKnown = dayIsKnown
        self.amount = amount; self.tags = tags; self.sheet = sheet; self.row = row
    }
}

/// Een totaal dat niet gelijk is aan het totaal in het blad.
public struct HistoryDifference: Equatable, Sendable {
    /// Bv. "Inkomsten", "Uitgaven", "Eindsaldo".
    public var title: String
    public var computed: Money
    /// Het bedrag in het blad; nil = niet gevonden.
    public var stated: Money?
    /// Vaste soortnaam zonder inhoud uit het blad: "inkomsten", "uitgaven", "eindsaldo", "beginsaldo" of "pot".
    public var kind: String
    /// Volgnummer (vanaf 1) van het blad binnen het jaar of van de pot in het blad RES, als dat ertoe doet.
    public var part: Int?

    public init(title: String, computed: Money, stated: Money?, kind: String = "", part: Int? = nil) {
        self.title = title; self.computed = computed; self.stated = stated; self.kind = kind; self.part = part
    }

    /// Berekend − Excel.
    public var difference: Money? { stated.map { computed - $0 } }

    public var text: String {
        guard let stated, let difference else {
            return "\(title): niet gevonden in het blad (berekend \(computed.formatted()))."
        }
        return "\(title): berekend \(computed.formatted()), in Excel \(stated.formatted()). Verschil \(difference.formatted(alwaysSign: true))."
    }
}

/// Eén jaar uit de begrotingswerkmap.
public struct HistoryYear: Equatable, Sendable, Identifiable {
    public var year: Int
    /// De bladen waaruit het jaar komt (twee bij een jaar met twee banken).
    public var sheetNames: [String]
    public var items: [HistoryItem]
    public var various: [HistoryVariousEntry]
    /// Saldo op 1 januari volgens het blad.
    public var openingBalance: Money?
    public var statedIncome: Money?
    public var statedExpenses: Money?
    public var statedClosing: Money?
    /// Totalen die niet kloppen met het blad. Leeg = alles klopt.
    public var differences: [HistoryDifference]
    /// Beginsaldo van dit jaar − eindsaldo van het vorige jaar, als die niet gelijk zijn.
    public var chainDifference: Money?
    public var warnings: [HistoryNote]
    public var skippedRows: [HistoryNote]

    public var id: Int { year }

    public init(year: Int, sheetNames: [String] = [], items: [HistoryItem] = [], various: [HistoryVariousEntry] = [],
                openingBalance: Money? = nil, statedIncome: Money? = nil, statedExpenses: Money? = nil,
                statedClosing: Money? = nil, differences: [HistoryDifference] = [], chainDifference: Money? = nil,
                warnings: [HistoryNote] = [], skippedRows: [HistoryNote] = []) {
        self.year = year; self.sheetNames = sheetNames; self.items = items; self.various = various
        self.openingBalance = openingBalance; self.statedIncome = statedIncome
        self.statedExpenses = statedExpenses; self.statedClosing = statedClosing
        self.differences = differences; self.chainDifference = chainDifference
        self.warnings = warnings; self.skippedRows = skippedRows
    }

    /// Alle bedragen van het jaar: de gevulde maandcellen van het grid en de losse regels.
    public var amounts: [Money] {
        items.flatMap { $0.monthAmounts.compactMap { $0 } } + various.map(\.amount)
    }

    /// Som van alle positieve bedragen.
    public var computedIncome: Money { amounts.filter { $0 > .zero }.sum() }
    /// Som van alle negatieve bedragen.
    public var computedExpenses: Money { amounts.filter { $0 < .zero }.sum() }
    /// Beginsaldo + alle bedragen, of nil als het beginsaldo ontbreekt.
    public var computedClosing: Money? { openingBalance.map { $0 + amounts.sum() } }

    /// Aantal boekingen dat een import van dit jaar maakt.
    public var entryCount: Int { amounts.count }

    /// De berekende totalen zijn gelijk aan die in het blad.
    public var totalsMatch: Bool { differences.isEmpty }

    /// Aantal losse regels zonder datum (geboekt op de 15e van de maand).
    public var unknownDayCount: Int { various.filter { !$0.dayIsKnown }.count }

    // MARK: Grens: importeren tot en met een maand

    /// De bedragen die een import t/m `month` meeneemt (nil = hele jaar; 0 = geen enkele boeking).
    /// Een losse regel valt buiten de grens als zijn maandkolom óf zijn datum na de grens ligt.
    public func amounts(through month: Int?) -> [Money] {
        guard let month else { return amounts }
        return items.flatMap { $0.monthAmounts.prefix(max(0, month)).compactMap { $0 } }
            + various.filter { $0.lastMonth <= month }.map(\.amount)
    }

    public func entryCount(through month: Int?) -> Int { amounts(through: month).count }

    /// Aantal bedragen dat door de grens buiten de import blijft.
    public func excludedCount(through month: Int?) -> Int { entryCount - entryCount(through: month) }

    /// Saldo aan het eind van de maand: beginsaldo + alles t/m die maand. nil als het beginsaldo ontbreekt.
    /// Dit is het saldo waarop de eerste bankimport moet aansluiten als je t/m die maand importeert.
    public func balanceThrough(month: Int) -> Money? {
        openingBalance.map { $0 + amounts(through: month).sum() }
    }

    /// Het saldo aan het eind van elke maand (index 0 = januari), of nil als het beginsaldo ontbreekt.
    public var monthEndBalances: [Money]? {
        guard openingBalance != nil else { return nil }
        return (1...12).compactMap { balanceThrough(month: $0) }
    }

    /// Bedragen in maanden ná `month`: het aantal en de maanden waarin ze staan. In het lopende jaar zijn
    /// bedragen na de maand van vandaag waarschijnlijk vergeten verwachtingen.
    public func amountsAfter(month: Int) -> (count: Int, months: [Int]) {
        var months: Set<Int> = []
        var count = 0
        for item in items {
            for (index, amount) in item.monthAmounts.enumerated() where amount != nil && index + 1 > month {
                months.insert(index + 1); count += 1
            }
        }
        for entry in various where entry.lastMonth > month {
            months.insert(entry.lastMonth); count += 1
        }
        return (count, months.sorted())
    }

    /// De grens die het venster voorstelt: nil (alles), behalve als het jaar van vandaag bedragen bevat in
    /// maanden na de maand van vandaag; dan de maand van vandaag, zodat die bedragen standaard niet meegaan.
    public func suggestedThroughMonth(today: Day) -> Int? {
        guard year == today.year, amountsAfter(month: today.month).count > 0 else { return nil }
        return today.month
    }
}

/// Een blad dat niet ingelezen is, met de reden.
public struct HistoryUnreadSheet: Equatable, Sendable {
    public var name: String
    public var year: Int?
    public var reason: String

    public init(name: String, year: Int? = nil, reason: String) {
        self.name = name; self.year = year; self.reason = reason
    }
}

/// De begrotingswerkmap: de gelezen jaren (nieuwste eerst) en de bladen die niet gelezen zijn.
public struct HistoryBudget: Equatable, Sendable {
    public var years: [HistoryYear]
    public var unread: [HistoryUnreadSheet]

    public init(years: [HistoryYear] = [], unread: [HistoryUnreadSheet] = []) {
        self.years = years; self.unread = unread
    }

    public func year(_ year: Int) -> HistoryYear? { years.first { $0.year == year } }
}

/// Een mutatie van een pot op een dag (positief = erbij, negatief = eraf).
public struct HistoryMovement: Equatable, Sendable {
    public var day: Day
    public var amount: Money
    public var row: Int

    public init(day: Day, amount: Money, row: Int = 0) {
        self.day = day; self.amount = amount; self.row = row
    }
}

/// Een pot uit het blad RES van de spaarwerkmap.
public struct HistoryPot: Equatable, Sendable {
    public var name: String
    public var movements: [HistoryMovement]
    /// Het saldo in de totaalrij onder de mutaties, of nil als die rij er niet is.
    public var statedBalance: Money?

    public init(name: String, movements: [HistoryMovement] = [], statedBalance: Money? = nil) {
        self.name = name; self.movements = movements; self.statedBalance = statedBalance
    }

    public var balance: Money { movements.map(\.amount).sum() }
}

/// De spaarwerkmap: de potten uit het blad RES.
public struct HistorySavings: Equatable, Sendable {
    public var pots: [HistoryPot]
    /// Potten waarvan de som van de mutaties niet gelijk is aan het saldo in de totaalrij.
    public var differences: [HistoryDifference]
    public var warnings: [HistoryNote]
    public var skippedRows: [HistoryNote]
    /// Bladen die niet ingelezen zijn (alles behalve RES).
    public var unread: [HistoryUnreadSheet]
    /// De rij waar het inlezen stopte (de eerste rij met formules in de potkolommen), of nil.
    public var stoppedAtRow: Int?

    public init(pots: [HistoryPot] = [], differences: [HistoryDifference] = [], warnings: [HistoryNote] = [],
                skippedRows: [HistoryNote] = [], unread: [HistoryUnreadSheet] = [], stoppedAtRow: Int? = nil) {
        self.pots = pots; self.differences = differences; self.warnings = warnings
        self.skippedRows = skippedRows; self.unread = unread; self.stoppedAtRow = stoppedAtRow
    }

    public var movementCount: Int { pots.reduce(0) { $0 + $1.movements.count } }
    public var firstDay: Day? { pots.flatMap(\.movements).map(\.day).min() }
    public var lastDay: Day? { pots.flatMap(\.movements).map(\.day).max() }
    public var totalsMatch: Bool { differences.isEmpty }
}

extension Money {
    /// Een getal uit Excel afgerond op centen. De bladen bevatten afrondingsresten van zwevendekommagetallen
    /// (bv. -120,10000000000001), dus eerst een fractie richting de dichtstbijzijnde cent.
    public init(excel value: Double) {
        let scaled = value * 100
        self.init(cents: Int64((scaled + (scaled < 0 ? -1e-6 : 1e-6)).rounded()))
    }

    /// Heeft het getal echt meer dan twee decimalen (dus geen afrondingsrest)?
    static func hasSubCents(_ value: Double) -> Bool {
        let scaled = value * 100
        return abs(scaled - scaled.rounded()) > 1e-4
    }
}
