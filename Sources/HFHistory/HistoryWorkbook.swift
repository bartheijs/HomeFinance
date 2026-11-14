import Foundation
import HFCore

public enum HistoryReadError: LocalizedError, Equatable {
    case noSavingsSheet

    public var errorDescription: String? {
        switch self {
        case .noSavingsSheet:
            "In deze werkmap staat geen blad met de naam RES. Kies de spaarwerkmap."
        }
    }
}

/// Leest de Excel-werkmappen met de historie. Leest alleen; er wordt niets in de database gezet.
/// Alles wordt op label gevonden, nooit op een vast rijnummer.
public enum HistoryWorkbook {
    /// Jaarbladen van vóór dit jaar hebben een afwijkende indeling en worden niet ingelezen.
    public static let firstRegularYear = 2009

    // MARK: Begrotingswerkmap

    public static func readBudget(_ url: URL) throws -> HistoryBudget {
        budget(from: try XLSXWorkbook.read(url))
    }

    public static func budget(from workbook: XLSXWorkbook) -> HistoryBudget {
        var parts: [Int: [HistoryYear]] = [:]
        var failedYears: Set<Int> = []
        var unread: [HistoryUnreadSheet] = []

        for sheet in workbook.sheets {
            guard let year = year(fromSheetName: sheet.name) else {
                unread.append(HistoryUnreadSheet(name: sheet.name, reason: "niet ingelezen: geen jaarblad"))
                continue
            }
            guard year >= firstRegularYear else {
                unread.append(HistoryUnreadSheet(name: sheet.name, year: year, reason: "niet ingelezen: afwijkende indeling"))
                continue
            }
            do {
                parts[year, default: []].append(try parseYearSheet(sheet, year: year))
            } catch let problem as SheetProblem {
                failedYears.insert(year)
                unread.append(HistoryUnreadSheet(name: sheet.name, year: year, reason: "niet ingelezen: \(problem.reason)"))
            } catch {
                failedYears.insert(year)
                unread.append(HistoryUnreadSheet(name: sheet.name, year: year, reason: "niet ingelezen: \(error.localizedDescription)"))
            }
        }

        // Een jaar met twee bladen telt alleen als beide gelezen zijn.
        for year in failedYears {
            for part in parts[year] ?? [] {
                unread.append(HistoryUnreadSheet(name: part.sheetNames.first ?? "\(year)", year: year,
                                                 reason: "niet ingelezen: het andere blad van \(year) kon niet gelezen worden"))
            }
            parts[year] = nil
        }

        var years = parts.keys.sorted().map { year -> HistoryYear in
            let list = parts[year]!
            return list.count == 1 ? list[0] : merge(list)
        }

        // Het eindsaldo van een jaar hoort het beginsaldo van het volgende jaar te zijn.
        for index in years.indices.dropFirst() {
            let previous = years[index - 1]
            guard previous.year == years[index].year - 1,
                  let closing = previous.statedClosing, let opening = years[index].openingBalance,
                  closing != opening else { continue }
            years[index].chainDifference = opening - closing
            let sheet = years[index].sheetNames.first ?? "\(years[index].year)"
            years[index].warnings.append(HistoryNote(sheet: sheet, code: "keten", message:
                "Het beginsaldo (\(opening.formatted())) is niet gelijk aan het eindsaldo van \(previous.year) (\(closing.formatted())). Verschil \((opening - closing).formatted(alwaysSign: true))."))
        }
        return HistoryBudget(years: years.reversed(), unread: unread)
    }

    /// "2019" → 2019, "2018 Bank" → 2018, "Notities" → nil
    static func year(fromSheetName name: String) -> Int? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let digits = trimmed.prefix(4)
        guard digits.count == 4, digits.allSatisfy({ $0.isASCII && $0.isNumber }), let year = Int(digits),
              (1990...2100).contains(year) else { return nil }
        let rest = trimmed.dropFirst(4)
        guard rest.isEmpty || rest.first == " " else { return nil }
        return year
    }

    private struct SheetProblem: Error { let reason: String }

    private static let monthPrefixes: [String: Int] = [
        "jan": 1, "feb": 2, "mrt": 3, "maa": 3, "mar": 3, "apr": 4, "mei": 5, "may": 5, "jun": 6,
        "jul": 7, "aug": 8, "sep": 9, "okt": 10, "oct": 10, "nov": 11, "dec": 12,
    ]

    /// Tekst van een labelcel; getallen en datums worden tekst.
    private static func label(_ cell: XLSXCell) -> String? {
        switch cell.value {
        case .empty: nil
        case .text(let s): s
        case .number(let n): n == n.rounded() && abs(n) < 1e15 ? String(Int64(n)) : String(n)
        case .date(let day, _): day.dutch
        }
    }

    private static func isLabel(_ cell: XLSXCell, _ wanted: String) -> Bool {
        cell.text?.lowercased() == wanted.lowercased()
    }

    // MARK: Eén jaarblad

    private static func parseYearSheet(_ sheet: XLSXSheet, year: Int) throws -> HistoryYear {
        let name = sheet.name
        var result = HistoryYear(year: year, sheetNames: [name])
        func warn(_ code: String, _ row: Int?, _ message: String) {
            result.warnings.append(HistoryNote(sheet: name, row: row, code: code, message: message))
        }
        func skip(_ code: String, _ row: Int, _ label: String?, _ reason: String) {
            result.skippedRows.append(HistoryNote(sheet: name, row: row, code: code, message: (label.map { "‘\($0)’ " } ?? "") + reason))
        }

        // Kopregel: de twaalf maandkolommen zijn datums (één per maand) of de teksten jan … dec.
        func month(_ cell: XLSXCell) -> Int? {
            switch cell.value {
            case .empty: return nil
            case .date(let day, _): return day.month
            case .text(let s):
                let t = s.lowercased()
                return t.count >= 3 ? monthPrefixes[String(t.prefix(3))] : nil
            case .number(let n):
                // Een datum zonder herkenbare datumopmaak.
                guard n >= 20_000, n <= 80_000 else { return nil }
                return sheet.day(fromSerial: n)?.month
            }
        }
        var firstMonth: Int?
        if sheet.maxColumn >= 12 {
            for column in 1...(sheet.maxColumn - 11) where (0..<12).allSatisfy({ month(sheet[1, column + $0]) == $0 + 1 }) {
                firstMonth = column
                break
            }
        }
        guard let firstMonth else { throw SheetProblem(reason: "geen twaalf maandkolommen in rij 1") }
        let monthColumns = Array(firstMonth..<(firstMonth + 12))

        let before = firstMonth > 1 ? Array(1..<firstMonth) : []
        let planColumn = before.first { isLabel(sheet[1, $0], "plan") } ?? before.first { isLabel(sheet[1, $0], "nu") }
        if planColumn == nil { warn("geen-plankolom", 1, "Geen kolom ‘plan’ of ‘nu’ gevonden; het plan van alle posten is € 0,00.") }

        var trackingColumns: [(column: Int, name: String)] = []
        if sheet.maxColumn > firstMonth + 11 {
            for column in (firstMonth + 12)...sheet.maxColumn {
                if let text = sheet[1, column].text { trackingColumns.append((column, text)) }
            }
        }

        // De vaste rijen.
        let allRows = sheet.maxRow >= 2 ? Array(2...sheet.maxRow) : []
        guard let totalRow = allRows.first(where: { isLabel(sheet[$0, 1], "Totaal") }) else {
            throw SheetProblem(reason: "geen rij ‘Totaal’ gevonden")
        }
        guard let inVariousRow = allRows.first(where: { $0 > totalRow && isLabel(sheet[$0, 1], "IN Various") }) else {
            throw SheetProblem(reason: "geen rij ‘IN Various’ gevonden")
        }
        guard let outVariousRow = allRows.first(where: { $0 > inVariousRow && isLabel(sheet[$0, 1], "UIT Various") }) else {
            throw SheetProblem(reason: "geen rij ‘UIT Various’ gevonden")
        }
        let summaryRows = allRows.filter { $0 > outVariousRow }
        let summaryStart = summaryRows.first { sheet[$0, 1].text?.lowercased().hasPrefix("op de rekening") == true }

        func money(_ cell: XLSXCell, row: Int) -> Money? {
            guard let number = cell.number else { return nil }
            if Money.hasSubCents(number) {
                warn("afgerond", row, "Een bedrag met meer dan twee decimalen (\(number)) is afgerond op centen.")
            }
            let amount = Money(excel: number)
            return amount.isZero ? nil : amount
        }

        // Hoofdgrid: rij 2 tot de rij Totaal.
        var reserveTotalSeen = false
        for row in allRows where row < totalRow {
            guard let text = label(sheet[row, 1]) else { continue }
            let direction: Direction
            var itemLabel: String
            var isReserveTotal = false
            if text == "RESERVERINGEN" {
                direction = .UIT; itemLabel = text
                if reserveTotalSeen {
                    warn("tweede-reserveringen", row, "Er staat een tweede rij RESERVERINGEN; die is als gewone uitgavenpost overgenomen.")
                } else {
                    isReserveTotal = true; reserveTotalSeen = true
                }
            } else if text.lowercased() == "in various" || text.lowercased() == "uit various" {
                skip("various-in-grid", row, text, "staat in het grid: overgeslagen, de losse regels staan onder het grid")
                continue
            } else if text.hasPrefix("IN ") {
                direction = .IN; itemLabel = String(text.dropFirst(3))
            } else if text.hasPrefix("UIT ") {
                direction = .UIT; itemLabel = String(text.dropFirst(4))
            } else if text.hasPrefix("RES ") {
                direction = .RES; itemLabel = String(text.dropFirst(4))
            } else {
                skip("hulprij", row, text, "is een hulprij (geen IN, UIT of RES)")
                continue
            }
            itemLabel = itemLabel.trimmingCharacters(in: .whitespaces)
            guard !itemLabel.isEmpty else {
                skip("geen-naam", row, text, "heeft geen naam")
                continue
            }

            var plan = planColumn.flatMap { money(sheet[row, $0], row: row) } ?? .zero
            if (direction == .IN && plan < .zero) || (direction != .IN && plan > .zero) {
                warn("plan-teken", row, "Het plan van ‘\(text)’ (\(plan.formatted())) heeft het verkeerde teken voor \(direction.rawValue); overgenomen als \((-plan).formatted()).")
                plan = -plan
            }

            var item = HistoryItem(direction: direction, label: itemLabel, plan: plan, isReserveTotal: isReserveTotal,
                                   sheet: name, row: row)
            if direction != .RES {
                for (index, column) in monthColumns.enumerated() {
                    let cell = sheet[row, column]
                    if let amount = money(cell, row: row) {
                        item.monthAmounts[index] = amount
                        if direction == .UIT && amount > .zero {
                            warn("teken", row, "‘\(text)’ heeft in \(Day.monthNamesShort[index]) een positief bedrag (\(amount.formatted())); overgenomen zoals het er staat.")
                        } else if direction == .IN && amount < .zero {
                            warn("teken", row, "‘\(text)’ heeft in \(Day.monthNamesShort[index]) een negatief bedrag (\(amount.formatted())); overgenomen zoals het er staat.")
                        }
                    } else if let t = cell.text {
                        warn("tekst-in-cel", row, "‘\(text)’ heeft in \(Day.monthNamesShort[index]) tekst in plaats van een bedrag (‘\(t)’); genegeerd.")
                    }
                }
            }
            result.items.append(item)
        }

        let resPlan = result.items.filter { $0.direction == .RES }.map(\.plan).sum()
        if let total = result.items.first(where: \.isReserveTotal),
           result.items.contains(where: { $0.direction == .RES }), total.plan != resPlan {
            warn("reserveringen-plan", total.row, "Het plan van RESERVERINGEN (\(total.plan.formatted())) is niet de som van de RES-regels (\(resPlan.formatted())). De app gebruikt de som.")
        }

        // Losse regels: IN Various tot UIT Various, en UIT Various tot het saldoblok.
        func readVarious(rows: [Int], section: Direction) {
            for row in rows {
                let text = label(sheet[row, 1])
                var amounts: [(month: Int, amount: Money)] = []
                for (index, column) in monthColumns.enumerated() {
                    if let amount = money(sheet[row, column], row: row) { amounts.append((index + 1, amount)) }
                }
                if text == nil && amounts.isEmpty { continue }
                guard let text else {
                    skip("totaalrij", row, nil, "rij zonder omschrijving met bedragen: overgeslagen als totaalrij")
                    continue
                }
                if text.lowercased().hasPrefix("totaal") {
                    skip("totaalrij", row, text, "overgeslagen als totaalrij")
                    continue
                }
                guard !amounts.isEmpty else {
                    skip("geen-bedrag", row, text, "heeft geen bedrag in de maandkolommen")
                    continue
                }

                // Datum in kolom B (alleen als B vóór de maandkolommen ligt).
                var date: Day?
                if firstMonth > 2, let day = sheet[row, 2].day {
                    if day.year == year {
                        date = day
                    } else {
                        warn("datum-buiten-jaar", row, "De datum \(day.dutch) bij ‘\(text)’ valt buiten \(year); geboekt op de 15e van de maand.")
                    }
                }

                // Volgkolommen: alleen een waarde gelijk aan het bedrag (zonder teken) is een tag.
                var tagsPerAmount = Array(repeating: [String](), count: amounts.count)
                for tracking in trackingColumns {
                    guard let number = sheet[row, tracking.column].number else { continue }
                    let value = Money(excel: number)
                    guard !value.isZero else { continue }
                    if let index = amounts.firstIndex(where: { $0.amount.magnitude == value.magnitude }) {
                        tagsPerAmount[index].append(tracking.name)
                    } else if section == .UIT {
                        warn("volgkolom-ongelijk", row, "De waarde \(value.formatted()) in kolom ‘\(tracking.name)’ bij ‘\(text)’ is niet gelijk aan het bedrag; geen tag gezet.")
                    }
                }

                for (index, entry) in amounts.enumerated() {
                    var day = Day(year: year, month: entry.month, day: 15)!
                    var known = false
                    if let date, amounts.count == 1 || date.month == entry.month {
                        day = date; known = true
                        if date.month != entry.month {
                            warn("datum-andere-maand", row, "De datum \(date.dutch) bij ‘\(text)’ valt in een andere maand dan de kolom \(Day.monthNamesShort[entry.month - 1]); de datum is gebruikt.")
                        }
                    }
                    if section == .UIT && entry.amount > .zero {
                        warn("teken", row, "‘\(text)’ staat bij UIT Various met een positief bedrag (\(entry.amount.formatted())); overgenomen zoals het er staat.")
                    } else if section == .IN && entry.amount < .zero {
                        warn("teken", row, "‘\(text)’ staat bij IN Various met een negatief bedrag (\(entry.amount.formatted())); overgenomen zoals het er staat.")
                    }
                    result.various.append(HistoryVariousEntry(section: section, label: text, day: day, month: entry.month, dayIsKnown: known,
                                                              amount: entry.amount, tags: tagsPerAmount[index],
                                                              sheet: name, row: row))
                }
            }
        }
        readVarious(rows: allRows.filter { $0 > inVariousRow && $0 < outVariousRow }, section: .IN)
        readVarious(rows: allRows.filter { $0 > outVariousRow && $0 < (summaryStart ?? Int.max) }, section: .UIT)

        // Saldoblok: op label in kolom A, bedrag in kolom B (of anders het eerste getal in de rij).
        func summaryValue(_ matches: (String) -> Bool) -> Money? {
            guard let start = summaryStart,
                  let row = summaryRows.first(where: { r in r >= start && sheet[r, 1].text.map { matches($0.lowercased()) } == true })
            else { return nil }
            if let number = sheet[row, 2].number { return Money(excel: number) }
            let columns = (sheet.rows[row] ?? [:]).keys.sorted().filter { $0 > 1 }
            return columns.lazy.compactMap { sheet[row, $0].number }.first.map { Money(excel: $0) }
        }
        result.openingBalance = summaryValue { $0.hasPrefix("op de rekening op") }
        result.statedIncome = summaryValue { $0 == "in" }
        result.statedExpenses = summaryValue { $0 == "uit" }
        result.statedClosing = summaryValue { $0 == "op de rekening" }

        validate(&result)
        return result
    }

    /// Vergelijkt de berekende totalen met die in het blad. Er wordt nooit iets rechtgezet.
    private static func validate(_ year: inout HistoryYear) {
        let sheet = year.sheetNames.first ?? "\(year.year)"
        var differences: [HistoryDifference] = []

        // Excel kan IN en UIT op teken tellen (alle positieve / alle negatieve bedragen) of per blok
        // (IN-rijen en IN Various / UIT-rijen en UIT Various). De boekingen zijn in beide gevallen dezelfde.
        let bySign = (income: year.computedIncome, expenses: year.computedExpenses)
        let inBlock = year.items.filter { $0.direction == .IN }.flatMap { $0.monthAmounts.compactMap { $0 } }
            + year.various.filter { $0.section == .IN }.map(\.amount)
        let outBlock = year.items.filter { $0.direction == .UIT }.flatMap { $0.monthAmounts.compactMap { $0 } }
            + year.various.filter { $0.section == .UIT }.map(\.amount)
        let byBlock = (income: inBlock.sum(), expenses: outBlock.sum())

        let signMatches = year.statedIncome == bySign.income && year.statedExpenses == bySign.expenses
        let blockMatches = year.statedIncome == byBlock.income && year.statedExpenses == byBlock.expenses
        if !signMatches && blockMatches {
            year.warnings.append(HistoryNote(sheet: sheet, code: "per-blok-geteld", message:
                "IN en UIT kloppen met Excel als je per blok telt (een positief bedrag bij UIT of een negatief bedrag bij IN telt in Excel in zijn eigen blok mee)."))
        } else if !signMatches {
            if year.statedIncome != bySign.income {
                differences.append(HistoryDifference(title: "Inkomsten", computed: bySign.income, stated: year.statedIncome, kind: "inkomsten"))
            }
            if year.statedExpenses != bySign.expenses {
                differences.append(HistoryDifference(title: "Uitgaven", computed: bySign.expenses, stated: year.statedExpenses, kind: "uitgaven"))
            }
        }

        if let opening = year.openingBalance {
            let closing = opening + year.amounts.sum()
            if year.statedClosing != closing {
                differences.append(HistoryDifference(title: "Eindsaldo", computed: closing, stated: year.statedClosing, kind: "eindsaldo"))
            }
        } else {
            differences.append(HistoryDifference(title: "Beginsaldo", computed: .zero, stated: nil, kind: "beginsaldo"))
        }
        year.differences = differences
    }

    /// Voegt de bladen van één jaar samen (een jaar met twee banken).
    private static func merge(_ sheets: [HistoryYear]) -> HistoryYear {
        func firstMonth(_ part: HistoryYear) -> Int {
            let fromItems = part.items.compactMap { $0.monthAmounts.firstIndex { $0 != nil } }.map { $0 + 1 }
            return (fromItems + part.various.map(\.day.month)).min() ?? 13
        }
        // Het blad met de vroegste bedragen eerst; bij gelijke stand de volgorde van de tabbladen.
        let parts = sheets.enumerated().sorted { (firstMonth($0.element), $0.offset) < (firstMonth($1.element), $1.offset) }.map(\.element)
        var merged = HistoryYear(year: parts[0].year, sheetNames: parts.flatMap(\.sheetNames))
        let names = merged.sheetNames.joined(separator: " en ")

        for (partIndex, part) in parts.enumerated() {
            let sheet = part.sheetNames.first ?? ""
            for item in part.items {
                guard let index = merged.items.firstIndex(where: { $0.direction == item.direction && $0.label == item.label }) else {
                    merged.items.append(item)
                    continue
                }
                var existing = merged.items[index]
                if existing.plan != item.plan && !item.plan.isZero {
                    if !existing.plan.isZero {
                        merged.warnings.append(HistoryNote(sheet: sheet, row: item.row, code: "plan-verschilt", message:
                            "‘\(item.label)’ heeft in de bladen \(names) een verschillend plan (\(existing.plan.formatted()) en \(item.plan.formatted())); het plan uit blad \(sheet) is gebruikt."))
                    }
                    existing.plan = item.plan
                }
                for month in 0..<12 {
                    guard let amount = item.monthAmounts[month] else { continue }
                    if let other = existing.monthAmounts[month] {
                        merged.warnings.append(HistoryNote(sheet: sheet, row: item.row, code: "dubbele-maand", message:
                            "‘\(item.label)’ heeft in \(Day.monthNamesShort[month]) in beide bladen een bedrag; ze zijn opgeteld tot \((other + amount).formatted())."))
                        existing.monthAmounts[month] = other + amount
                    } else {
                        existing.monthAmounts[month] = amount
                    }
                }
                existing.isReserveTotal = existing.isReserveTotal || item.isReserveTotal
                merged.items[index] = existing
            }
            merged.various += part.various
            merged.warnings += part.warnings
            merged.skippedRows += part.skippedRows
            merged.differences += part.differences.map {
                HistoryDifference(title: "\($0.title) (blad \(sheet))", computed: $0.computed, stated: $0.stated, kind: $0.kind, part: partIndex + 1)
            }
        }

        func total(_ value: (HistoryYear) -> Money?) -> Money? {
            let values = parts.map(value)
            return values.contains { $0 == nil } ? nil : values.compactMap { $0 }.sum()
        }
        merged.statedIncome = total(\.statedIncome)
        merged.statedExpenses = total(\.statedExpenses)

        // Sluit het ene blad aan op het andere (eindsaldo = beginsaldo van het volgende), dan loopt het saldo
        // door. Anders liepen de rekeningen naast elkaar en tellen de saldi op.
        let chained = parts.count > 1 && zip(parts, parts.dropFirst()).allSatisfy {
            $0.statedClosing != nil && $0.statedClosing == $1.openingBalance && $0.statedClosing != .zero
        }
        if chained {
            merged.openingBalance = parts.first?.openingBalance
            merged.statedClosing = parts.last?.statedClosing
            merged.warnings.append(HistoryNote(sheet: names, code: "saldo-loopt-door", message:
                "Het eindsaldo van het eerste blad is het beginsaldo van het tweede; het saldo loopt door."))
        } else {
            merged.openingBalance = total(\.openingBalance)
            merged.statedClosing = total(\.statedClosing)
            merged.warnings.append(HistoryNote(sheet: names, code: "saldi-opgeteld", message:
                "De begin- en eindsaldi van de bladen zijn opgeteld (twee rekeningen naast elkaar)."))
        }
        return merged
    }

    // MARK: Spaarwerkmap

    public static func readSavings(_ url: URL) throws -> HistorySavings {
        try savings(from: try XLSXWorkbook.read(url))
    }

    // De optimizer van Swift 6.3 loopt vast op deze functie in een release-build (compilerfout, geen fout in
    // de code); daarom zonder optimalisatie. Het is een eenmalige import, snelheid speelt geen rol.
    @_optimize(none)
    public static func savings(from workbook: XLSXWorkbook) throws -> HistorySavings {
        guard let sheet = workbook.sheet(named: "RES") else { throw HistoryReadError.noSavingsSheet }
        let name = sheet.name
        var result = HistorySavings()
        result.unread = workbook.sheets.filter { $0.name != sheet.name }.map {
            HistoryUnreadSheet(name: $0.name, reason: "niet ingelezen: alleen het blad RES heeft een vaste indeling")
        }

        // Rij 1: de namen van de potten vanaf kolom B.
        var columns: [Int] = []
        if sheet.maxColumn >= 2 {
            for column in 2...sheet.maxColumn {
                guard let header = label(sheet[1, column]) else { continue }
                if ["totaal", "total", "som", "saldo"].contains(header.lowercased()) {
                    result.warnings.append(HistoryNote(sheet: name, row: 1, code: "geen-pot", message: "De kolom ‘\(header)’ is geen pot en is overgeslagen."))
                    continue
                }
                columns.append(column)
                result.pots.append(HistoryPot(name: header))
            }
        }
        guard !columns.isEmpty else { return result }

        var current: Day?
        for row in stride(from: 2, through: sheet.maxRow, by: 1) {
            // De totaalrij: formules in (meer dan de helft van) de potkolommen. Daar stopt het inlezen.
            let formulas = columns.filter { sheet[row, $0].hasFormula }.count
            if formulas * 2 > columns.count {
                result.stoppedAtRow = row
                for (index, column) in columns.enumerated() {
                    result.pots[index].statedBalance = sheet[row, column].number.map { Money(excel: $0) }
                }
                break
            }

            let first = sheet[row, 1]
            if let day = first.day {
                current = day
            } else if let n = first.number, n >= 20_000, n <= 80_000, let day = sheet.day(fromSerial: n) {
                // (Geen `if case` op `first.value` hier: dat laat de optimizer van Swift 6.3 vastlopen in een release-build.)
                current = day
            }

            var amounts: [(index: Int, amount: Money)] = []
            for (index, column) in columns.enumerated() {
                let cell = sheet[row, column]
                if let number = cell.number {
                    if Money.hasSubCents(number) {
                        result.warnings.append(HistoryNote(sheet: name, row: row, code: "afgerond", message:
                            "Een bedrag met meer dan twee decimalen (\(number)) bij pot ‘\(result.pots[index].name)’ is afgerond op centen."))
                    }
                    let amount = Money(excel: number)
                    if !amount.isZero { amounts.append((index, amount)) }
                } else if let text = cell.text {
                    result.warnings.append(HistoryNote(sheet: name, row: row, code: "tekst-in-cel", message:
                        "Tekst in plaats van een bedrag bij pot ‘\(result.pots[index].name)’ (‘\(text)’); genegeerd."))
                }
            }
            guard !amounts.isEmpty else { continue }
            guard let day = current else {
                result.skippedRows.append(HistoryNote(sheet: name, row: row, code: "geen-datum", message: "mutaties zonder datum, boven de eerste datum: overgeslagen"))
                continue
            }
            for entry in amounts {
                result.pots[entry.index].movements.append(HistoryMovement(day: day, amount: entry.amount, row: row))
            }
        }

        if result.stoppedAtRow == nil {
            result.warnings.append(HistoryNote(sheet: name, code: "geen-totaalrij", message: "Geen totaalrij met formules gevonden; de saldi van de potten zijn niet gecontroleerd."))
        }
        for (index, pot) in result.pots.enumerated() {
            if let stated = pot.statedBalance, stated != pot.balance {
                result.differences.append(HistoryDifference(title: "Pot \(pot.name)", computed: pot.balance, stated: stated, kind: "pot", part: index + 1))
            }
        }
        return result
    }
}
