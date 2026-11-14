import Foundation
import GRDB
import HFCore

/// Fouten van de Excel-export, met een Nederlandse melding voor de gebruiker.
public enum ExportError: Error, LocalizedError, Equatable, Sendable {
    /// Er is geen begroting voor dit jaar.
    case yearNotFound(Int)
    /// Het bestand kon niet worden geschreven; `detail` is de technische reden.
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .yearNotFound(let year):
            return "Er is geen begroting voor het jaar \(year). Kies een jaar dat in HomeFinance bestaat."
        case .writeFailed(let detail):
            return "Het Excel-bestand kon niet worden geschreven" + (detail.isEmpty ? "." : " (\(detail)).")
        }
    }
}

extension Backup {
    /// Bestandsnaam van de jaarexport: `HomeFinance <jaar>.xlsx`.
    public static func excelFileName(year: Int) -> String { "HomeFinance \(year).xlsx" }

    /// Exporteert één begrotingsjaar als leesbaar Excel-bestand (`HomeFinance <jaar>.xlsx`) in `folder`, met de
    /// tabbladen Maandgrid, Transacties, Potten, Vaste stortingen en Toelichting. Een bestaand bestand met die
    /// naam wordt vervangen. Dit is een leesbare kopie, geen back-up.
    /// Gooit `ExportError.yearNotFound` als het jaar geen begroting heeft.
    @discardableResult
    public static func exportYearAsExcel(_ db: AppDatabase, year: Int, to folder: URL, now: Date = Date()) throws -> URL {
        // Alles in één leestransactie, zodat de tabbladen bij elkaar horen.
        let sheets = try db.read { try yearSheets($0, year: year, exportDay: Day(date: now)) }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            throw BackupError.folderUnavailable(folder.path)
        }
        let url = folder.appendingPathComponent(excelFileName(year: year))
        try Xlsx.write(sheets, to: url)
        return url
    }

    // MARK: Tabbladen

    private static let checking = "(SELECT id FROM account WHERE kind = 'betaal')"
    /// De begrotingsmaand van een boeking: `period` als die gezet is, anders de maand van `day`.
    private static let period = "COALESCE(e.period, substr(e.day, 1, 7))"

    static func yearSheets(_ db: Database, year: Int, exportDay: Day) throws -> [XlsxSheet] {
        guard let budgetYear = try BudgetYear.filter(Column("year") == year).fetchOne(db) else {
            throw ExportError.yearNotFound(year)
        }
        // Peildag: de exportdag in het lopende (of een toekomstig) jaar, 31-12 voor een voorbij jaar.
        let asOf = exportDay.year > year ? Day(year: year, month: 12, day: 31)! : exportDay
        return [
            try gridSheet(db, budgetYear: budgetYear, exportDay: exportDay, asOf: asOf),
            try entriesSheet(db, year: year),
            try potsSheet(db, year: year, asOf: asOf),
            try distributionsSheet(db),
            notesSheet(year: year, exportDay: exportDay),
        ]
    }

    // MARK: Maandgrid

    private static func gridSheet(_ db: Database, budgetYear: BudgetYear, exportDay: Day, asOf: Day) throws -> XlsxSheet {
        let year = budgetYear.year
        let first = String(format: "%04d-01", year), last = String(format: "%04d-12", year)
        let items = try BudgetItem.filter(Column("yearId") == budgetYear.id).order(Column("sortOrder"), Column("id")).fetchAll(db)
        func isReserveLine(_ item: BudgetItem) -> Bool { item.direction == .RES && !item.isReserveTotal }
        let reservePlan = items.filter(isReserveLine).map(\.planAmount).sum()

        // Per post (NULL = divers) en begrotingsmaand: som, aantal, en de plus- en minkant.
        var sums: [Int64: [Int: Money]] = [:]
        var inDivers = [Money](repeating: .zero, count: 13), uitDivers = inDivers
        for row in try Row.fetchAll(db, sql: """
            SELECT e.budgetItemId AS itemId, CAST(substr(\(period), 6, 2) AS INTEGER) AS m, SUM(e.amount) AS s,
                   SUM(CASE WHEN e.amount > 0 THEN e.amount ELSE 0 END) AS pos,
                   SUM(CASE WHEN e.amount < 0 THEN e.amount ELSE 0 END) AS neg
            FROM entry e
            WHERE e.accountId IN \(checking) AND \(period) >= ? AND \(period) <= ?
            GROUP BY e.budgetItemId, m
            """, arguments: [first, last]) {
            let m: Int = row["m"]
            guard (1...12).contains(m) else { continue }
            if let itemId: Int64 = row["itemId"] {
                sums[itemId, default: [:]][m] = row["s"]
            } else {
                inDivers[m] += row["pos"] as Money
                uitDivers[m] += row["neg"] as Money
            }
        }
        let checks = Set(try Row.fetchAll(db, sql: """
            SELECT c.budgetItemId, c.month FROM itemCheck c JOIN budgetItem i ON i.id = c.budgetItemId WHERE i.yearId = ?
            """, arguments: [budgetYear.id]).map { "\($0["budgetItemId"] as Int64)-\($0["month"] as Int)" })

        var sheet = XlsxSheet(name: "Maandgrid", widths: [34, 13] + [Double](repeating: 12, count: 12) + [14])
        sheet.add([.text("Post", bold: true), .text("Plan", bold: true)]
                  + Day.monthNamesShort.map { .text($0, bold: true) } + [.text("Jaar", bold: true)])

        // De posten op volgorde, gegroepeerd in inkomsten en uitgaven. RES-regels zijn informatief: ze tonen
        // alleen hun plan (en een maandbedrag als er toch iets op geboekt is).
        var firstItemRow: Int?, lastItemRow = 0
        var fixed = [Money](repeating: .zero, count: 13)
        let groups: [(String, [BudgetItem])] = [
            ("Inkomsten", items.filter { $0.direction == .IN }),
            ("Uitgaven", items.filter { $0.direction != .IN }),
        ]
        for (title, group) in groups where !group.isEmpty {
            sheet.add([.text(title, bold: true)])
            for item in group {
                let row = sheet.rows.count + 1
                let reserveLine = isReserveLine(item)
                var cells: [XlsxCell] = [
                    .text(item.label, indent: reserveLine),
                    .money(item.isReserveTotal ? reservePlan : item.planAmount),
                ]
                var total = Money.zero
                var hasAmount = false
                for m in 1...12 {
                    if let sum = sums[item.id!]?[m] {
                        cells.append(.money(sum))
                        total += sum
                        fixed[m] += sum
                        hasAmount = true
                    } else if checks.contains("\(item.id!)-\(m)") {
                        cells.append(.text("afgevinkt"))
                    } else {
                        cells.append(.empty)
                    }
                }
                cells.append(reserveLine && !hasAmount ? .empty
                             : .formula("SUM(\(Xlsx.ref(2, row)):\(Xlsx.ref(13, row)))", total))
                sheet.add(cells)
                firstItemRow = firstItemRow ?? row
                lastItemRow = row
            }
        }

        // Totaalrijen. Elke rij telt zijn eigen jaarkolom op.
        func totalRow(_ label: String, _ month: (Int) -> XlsxCell, _ values: [Money]) -> Int {
            let row = sheet.rows.count + 1
            let cells: [XlsxCell] = [.text(label, bold: true), .empty] + (1...12).map(month)
                + [.formula("SUM(\(Xlsx.ref(2, row)):\(Xlsx.ref(13, row)))", values[1...12].sum(), bold: true)]
            return sheet.add(cells)
        }
        sheet.add([])
        let fixedRow = totalRow("Vaste posten", { m in
            guard let firstItemRow else { return .money(.zero, bold: true) }
            return .formula("SUM(\(Xlsx.ref(m + 1, firstItemRow)):\(Xlsx.ref(m + 1, lastItemRow)))", fixed[m], bold: true)
        }, fixed)
        let inRow = totalRow("IN divers", { .money(inDivers[$0], bold: true) }, inDivers)
        let uitRow = totalRow("UIT divers", { .money(uitDivers[$0], bold: true) }, uitDivers)
        let netto = (0...12).map { inDivers[$0] + uitDivers[$0] }
        let nettoRow = totalRow("Netto divers", { m in
            .formula("SUM(\(Xlsx.ref(m + 1, inRow)):\(Xlsx.ref(m + 1, uitRow)))", netto[m], bold: true)
        }, netto)
        let result = (0...12).map { fixed[$0] + netto[$0] }
        _ = totalRow("Resultaat", { m in
            .formula("SUM(\(Xlsx.ref(m + 1, fixedRow)),\(Xlsx.ref(m + 1, nettoRow)))", result[m], bold: true)
        }, result)

        // Jaaroverzicht op de peildag.
        func money(_ sql: String, _ arguments: StatementArguments = []) throws -> Money {
            try Money.fetchOne(db, sql: sql, arguments: arguments) ?? .zero
        }
        let balance = try money("SELECT COALESCE(SUM(openingBalance), 0) FROM account WHERE kind = 'betaal'")
            + money("SELECT COALESCE(SUM(e.amount), 0) FROM entry e WHERE e.accountId IN \(checking) AND e.day <= ?", [asOf])
        let byDate = try money("""
            SELECT COALESCE(SUM(e.amount), 0) FROM entry e WHERE e.accountId IN \(checking) AND e.day >= ? AND e.day <= ?
            """, [Day(year: year, month: 1, day: 1)!, asOf])
        func flow(_ comparison: String) throws -> Money {
            try money("""
                SELECT COALESCE(SUM(e.amount), 0) FROM entry e
                WHERE e.accountId IN \(checking) AND \(period) >= ? AND \(period) <= ? AND e.day <= ? AND e.amount \(comparison) 0
                """, [first, last, exportDay])
        }
        let borrowed = max(try money("""
            SELECT COALESCE(SUM(e.amount), 0) FROM entry e
            WHERE e.temporaryLoan = 1 AND e.accountId IN \(checking) AND e.day <= ?
            """, [asOf]), .zero)

        sheet.add([])
        sheet.add([.text("Jaaroverzicht per", bold: true), .date(asOf, bold: true)])
        sheet.add([.text("Op de rekening op 1-1"), .money(balance - byDate)])
        sheet.add([.text("IN"), .money(try flow(">"))])
        sheet.add([.text("UIT"), .money(try flow("<"))])
        let balanceRow = sheet.add([.text("Op de rekening"), .money(balance)])
        let antiRoodRow = sheet.add([.text("Anti-rood"), .money(budgetYear.antiRood)])
        let borrowedRow = sheet.add([.text("Tijdelijk geleend"), .money(borrowed)])
        sheet.add([.text("Besteedbaar", bold: true),
                   .formula("\(Xlsx.ref(1, balanceRow))-\(Xlsx.ref(1, antiRoodRow))-\(Xlsx.ref(1, borrowedRow))",
                            balance - budgetYear.antiRood - borrowed, bold: true)])
        return sheet
    }

    // MARK: Transacties

    private static func entriesSheet(_ db: Database, year: Int) throws -> XlsxSheet {
        var sheet = XlsxSheet(name: "Transacties", widths: [12, 11, 22, 34, 28, 8, 20, 13, 11, 11, 11, 30, 28, 40],
                              freezeColumns: 0, autoFilter: true)
        sheet.add(["Datum", "Telt mee in", "Rekening", "Omschrijving", "Post of pot", "Divers", "Tags", "Bedrag",
                   "Vergoeden uit spaar", "Tijdelijk geleend", "Nagekeken", "Notitie", "Tegenpartij",
                   "Bankomschrijving"].map { .text($0, bold: true) })
        let rows = try Row.fetchCursor(db, sql: """
            SELECT e.day, \(period) AS period, a.name AS account, a.kind AS kind, e.label, i.label AS item, p.name AS pot,
                   e.amount, e.reimburse, e.temporaryLoan, e.reviewed, e.note,
                   t.counterpartyName AS counterparty, t.descriptionText AS bankText,
                   (SELECT group_concat(name, ', ') FROM (
                        SELECT g.name AS name FROM entryTag et JOIN tag g ON g.id = et.tagId
                        WHERE et.entryId = e.id ORDER BY g.sortOrder, g.name)) AS tags
            FROM entry e
            JOIN account a ON a.id = e.accountId
            LEFT JOIN budgetItem i ON i.id = e.budgetItemId
            LEFT JOIN pot p ON p.id = e.potId
            LEFT JOIN bankTransaction t ON t.id = e.bankTransactionId
            WHERE \(period) >= ? AND \(period) <= ?
            ORDER BY e.day, e.id
            """, arguments: [String(format: "%04d-01", year), String(format: "%04d-12", year)])
        func yesNo(_ value: Bool) -> XlsxCell { .text(value ? "ja" : "nee") }
        while let row = try rows.next() {
            let item: String? = row["item"], pot: String? = row["pot"]
            let target: String
            switch (item, pot) {
            case let (item?, pot?): target = "\(item) (pot: \(pot))"
            case let (item?, nil): target = item
            case let (nil, pot?): target = pot
            case (nil, nil): target = ""
            }
            let onChecking = (row["kind"] as String) == AccountKind.betaal.rawValue
            sheet.add([
                .date(row["day"]), .text(row["period"]), .text(row["account"]), .text(row["label"]), .text(target),
                onChecking ? yesNo(item == nil) : .empty, .text(row["tags"] ?? ""), .money(row["amount"]),
                yesNo(row["reimburse"]), yesNo(row["temporaryLoan"]), yesNo(row["reviewed"]), .text(row["note"]),
                .text(row["counterparty"] ?? ""), .text(row["bankText"] ?? ""),
            ])
        }
        return sheet
    }

    // MARK: Potten

    private static func potsSheet(_ db: Database, year: Int, asOf: Day) throws -> XlsxSheet {
        var sheet = XlsxSheet(name: "Potten", widths: [34, 14, 16, 16, 16, 16, 14, 13])
        sheet.add(["Pot", "Soort", "Eigenaar", "Saldo op \(asOf.dutch)", "Gestort in \(year)", "Opgenomen in \(year)",
                   "Doelbedrag", "Doeldatum"].map { .text($0, bold: true) })
        let yearStart = Day(year: year, month: 1, day: 1)!
        // Per pot: saldo t/m de peildag en wat er dit jaar bij kwam en af ging (op de rekening van de pot).
        var figures: [Int64: (balance: Money, deposited: Money, withdrawn: Money)] = [:]
        for row in try Row.fetchAll(db, sql: """
            SELECT p.id, COALESCE(SUM(e.amount), 0) AS balance,
                   COALESCE(SUM(CASE WHEN e.day >= ? AND e.amount > 0 THEN e.amount ELSE 0 END), 0) AS deposited,
                   COALESCE(SUM(CASE WHEN e.day >= ? AND e.amount < 0 THEN e.amount ELSE 0 END), 0) AS withdrawn
            FROM pot p JOIN entry e ON e.potId = p.id AND e.accountId = p.accountId AND e.day <= ?
            GROUP BY p.id
            """, arguments: [yearStart, yearStart, asOf]) {
            figures[row["id"]] = (row["balance"], row["deposited"], row["withdrawn"])
        }
        let pots = try Pot.order(Column("sortOrder"), Column("id")).fetchAll(db)
        let accounts = try Account.order(Column("sortOrder"), Column("id")).fetchAll(db)
        for account in accounts where account.kind == .spaar || pots.contains(where: { $0.accountId == account.id }) {
            let accountBalance = account.openingBalance + (try Money.fetchOne(db, sql:
                "SELECT COALESCE(SUM(amount), 0) FROM entry WHERE accountId = ? AND day <= ?",
                arguments: [account.id, asOf]) ?? .zero)
            sheet.add([.text(account.name, bold: true)])
            var firstRow: Int?, lastRow = 0
            var total = (balance: Money.zero, deposited: Money.zero, withdrawn: Money.zero)
            for pot in pots where pot.accountId == account.id {
                let f = figures[pot.id!] ?? (.zero, .zero, .zero)
                // Een gearchiveerde pot zonder saldo of beweging hoort niet meer in het overzicht.
                if pot.archived && f.balance.isZero && f.deposited.isZero && f.withdrawn.isZero { continue }
                let row = sheet.add([
                    .text(pot.name + (pot.archived ? " (gearchiveerd)" : ""), indent: true), .text(pot.kind.rawValue),
                    .text(pot.owner ?? ""), .money(f.balance), .money(f.deposited), .money(f.withdrawn),
                    pot.targetAmount.map { .money($0) } ?? .empty, pot.targetDate.map { .date($0) } ?? .empty,
                ])
                firstRow = firstRow ?? row
                lastRow = row
                total.balance += f.balance; total.deposited += f.deposited; total.withdrawn += f.withdrawn
            }
            func sum(_ column: Int, _ value: Money) -> XlsxCell {
                guard let firstRow else { return .money(.zero, bold: true) }
                return .formula("SUM(\(Xlsx.ref(column, firstRow)):\(Xlsx.ref(column, lastRow)))", value, bold: true)
            }
            let totalRow = sheet.add([.text("Totaal potten", bold: true), .empty, .empty,
                                      sum(3, total.balance), sum(4, total.deposited), sum(5, total.withdrawn)])
            let unassignedRow = sheet.add([.text("Niet toegewezen"), .empty, .empty, .money(accountBalance - total.balance)])
            sheet.add([.text("Saldo \(account.name)", bold: true), .empty, .empty,
                       .formula("SUM(\(Xlsx.ref(3, totalRow)):\(Xlsx.ref(3, unassignedRow)))", accountBalance, bold: true)])
            sheet.add([])
        }
        return sheet
    }

    // MARK: Vaste stortingen

    private static func distributionsSheet(_ db: Database) throws -> XlsxSheet {
        var sheet = XlsxSheet(name: "Vaste stortingen", widths: [34, 34, 14])
        sheet.add(["Storting", "Pot", "Bedrag"].map { .text($0, bold: true) })
        let distributions = try Row.fetchAll(db, sql: """
            SELECT d.id, d.name, d.archived, a.name AS account FROM distribution d
            JOIN account a ON a.id = d.accountId ORDER BY d.archived, d.sortOrder, d.id
            """)
        for distribution in distributions {
            let name: String = distribution["name"]
            let archived: Bool = distribution["archived"]
            sheet.add([.text(name + (archived ? " (gearchiveerd)" : ""), bold: true),
                       .text("naar \(distribution["account"] as String)")])
            var firstRow: Int?, lastRow = 0
            var total = Money.zero
            for line in try Row.fetchAll(db, sql: """
                SELECT p.name AS pot, l.amount FROM distributionLine l JOIN pot p ON p.id = l.potId
                WHERE l.distributionId = ? ORDER BY l.sortOrder, l.id
                """, arguments: [distribution["id"] as Int64]) {
                let amount: Money = line["amount"]
                let row = sheet.add([.empty, .text(line["pot"]), .money(amount)])
                firstRow = firstRow ?? row
                lastRow = row
                total += amount
            }
            sheet.add([.text("Totaal \(name)", bold: true), .empty,
                       firstRow.map { .formula("SUM(\(Xlsx.ref(2, $0)):\(Xlsx.ref(2, lastRow)))", total, bold: true) }
                           ?? .money(.zero, bold: true)])
            sheet.add([])
        }
        return sheet
    }

    // MARK: Toelichting

    private static func notesSheet(year: Int, exportDay: Day) -> XlsxSheet {
        var sheet = XlsxSheet(name: "Toelichting", widths: [24, 14], freezeRows: 0, freezeColumns: 0)
        sheet.add([.text("HomeFinance \(year)", bold: true)])
        sheet.add([.text("Geëxporteerd op"), .date(exportDay)])
        sheet.add([.text("Jaar"), .integer(year)])
        sheet.add([])
        sheet.add([.text("Dit bestand is een leesbare kopie van de administratie van \(year), om te bekijken en door "
                         + "te rekenen; het is geen back-up.")])
        sheet.add([.text("De back-up is het databasebestand (HomeFinance-….sqlite) in de back-upmap; alleen daarmee "
                         + "kan de administratie worden hersteld.")])
        return sheet
    }
}
