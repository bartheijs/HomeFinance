import Foundation
import Testing
import GRDB
import HFCore
@testable import HFImport

// Alle gegevens hieronder zijn verzonnen.

private let checkingIban = "NL00TEST0000000001"
private let savingsIban = "NL00TEST0000000002"

private func line(_ date: String, _ before: String, _ amount: String, seq: String, own: String = checkingIban) -> String {
    "\(date),\(own),NL00TEST0000000005,'Winkel Test',,,,EUR,\(before),EUR,\(amount),\(date),\(date),IC,GC,\(seq),,'Test',1"
}

private let aroundNewYear = [
    line("30-12-2026", "1000.00", "-10.00", seq: "1"),
    line("31-12-2026", "990.00", "-20.00", seq: "2"),
    line("01-01-2027", "970.00", "100.00", seq: "3"),
    line("02-01-2027", "1070.00", "-5.00", seq: "4"),
]

private func csv(_ lines: [String]) -> Data { Data((lines.joined(separator: "\r\n") + "\r\n").utf8) }

private let cutover = Day(year: 2026, month: 12, day: 31)!
private let newYear = Day(year: 2027, month: 1, day: 1)!

private func makeDatabase() throws -> (BankImporter, checking: Int64, savings: Int64) {
    let db = try AppDatabase.inMemory()
    let ids = try db.write { db -> (Int64, Int64) in
        var checking = Account(name: "Betaalrekening", iban: checkingIban, kind: .betaal, openingDate: newYear)
        var savings = Account(name: "Spaarrekening", iban: savingsIban, kind: .spaar, openingDate: newYear)
        try checking.insert(db)
        try savings.insert(db)
        return (checking.id!, savings.id!)
    }
    return (BankImporter(database: db), ids.0, ids.1)
}

private func count(_ importer: BankImporter, _ table: String) throws -> Int {
    try importer.database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM \(table)")! }
}

@Suite struct CutoverTests {
    @Test func withoutParameterNothingChanges() throws {
        let (importer, account, _) = try makeDatabase()
        let preview = try importer.preview(data: csv(aroundNewYear), fileName: "a.csv", accountId: account)
        #expect(preview.skipThrough == nil && preview.cutoverSkippedCount == 0)
        #expect(preview.rows.allSatisfy { !$0.isBeforeCutover })
        #expect(preview.newCount == 4 && preview.warnings.isEmpty)
        #expect(preview.openingBalance == Money(euros: 1000) && preview.fileOpeningBalance == Money(euros: 1000))
        #expect(preview.firstDay == Day(year: 2026, month: 12, day: 30))
        let result = try importer.commit(preview)
        #expect(result.transactions.count == 4 && result.cutoverSkippedCount == 0)
        #expect(result.batch.openingBalance == Money(euros: 1000))
    }

    @Test func rowsOnOrBeforeCutoverAreSkipped() throws {
        let (importer, account, _) = try makeDatabase()
        // Nieuwste eerst, zoals de bank vaak levert.
        let preview = try importer.preview(data: csv(aroundNewYear.reversed()), fileName: "a.csv", accountId: account,
                                           skipThrough: cutover)
        #expect(preview.skipThrough == cutover)
        #expect(preview.rows.map(\.isBeforeCutover) == [false, false, true, true])
        #expect(preview.cutoverSkippedCount == 2 && preview.newCount == 2 && preview.duplicateCount == 0)
        #expect(preview.rowCount == 4)
        // De keten is over het hele bestand gecontroleerd; het beginsaldo is dat van de eerste regel die meegaat.
        #expect(preview.chainOK == true)
        #expect(preview.openingBalance == Money(euros: 970))
        #expect(preview.fileOpeningBalance == Money(euros: 1000))
        #expect(preview.closingBalance == Money(euros: 1065))
        #expect(preview.firstDay == newYear && preview.lastDay == Day(year: 2027, month: 1, day: 2))
        #expect(preview.warnings.map(\.kind) == [.beforeCutover])
        #expect(preview.warnings[0].message
                == "2 regels van 31-12-2026 of eerder zijn overgeslagen: die vallen vóór je beginsaldo.")
        #expect(preview.canCommit)

        let result = try importer.commit(preview)
        #expect(result.transactions.map(\.sequence) == ["3", "4"])
        #expect(result.cutoverSkippedCount == 2 && result.duplicateCount == 0)
        #expect(result.batch.rowCount == 4 && result.batch.newCount == 2 && result.batch.duplicateCount == 0)
        #expect(result.batch.openingBalance == Money(euros: 970) && result.batch.closingBalance == Money(euros: 1065))
        #expect(result.batch.firstDay == newYear && result.batch.chainOK)
        #expect(try count(importer, "bankTransaction") == 2)

        // Opnieuw: de late regels zijn dubbel, de vroege blijven overgeslagen.
        let again = try importer.preview(data: csv(aroundNewYear), fileName: "a.csv", accountId: account, skipThrough: cutover)
        #expect(again.newCount == 0 && again.duplicateCount == 2 && again.cutoverSkippedCount == 2)
        #expect(try importer.commit(again).transactions.isEmpty)
        #expect(try count(importer, "bankTransaction") == 2)
    }

    @Test func singleSkippedRowAndBrokenChainInSkippedPart() throws {
        let (importer, account, _) = try makeDatabase()
        var lines = aroundNewYear
        lines[1] = line("31-12-2026", "985.00", "-15.00", seq: "2")   // sluit niet aan op regel 1
        let preview = try importer.preview(data: csv(lines), fileName: "a.csv", accountId: account,
                                           skipThrough: Day(year: 2026, month: 12, day: 30)!)
        #expect(preview.cutoverSkippedCount == 1)
        #expect(preview.chainOK == false && preview.chainBreaks.map(\.lineNumber) == [2])
        #expect(preview.warnings.map(\.kind) == [.chainBroken, .beforeCutover])
        #expect(preview.warnings[1].message.hasPrefix("1 regel van 30-12-2026 of eerder is overgeslagen"))
        #expect(preview.openingBalance == Money(euros: 985))
    }

    @Test func laterFileGivesNoWarning() throws {
        let (importer, account, _) = try makeDatabase()
        let preview = try importer.preview(data: csv(Array(aroundNewYear.suffix(2))), fileName: "b.csv", accountId: account,
                                           skipThrough: cutover)
        #expect(preview.skipThrough == cutover && preview.cutoverSkippedCount == 0)
        #expect(preview.warnings.isEmpty && preview.newCount == 2)
        #expect(preview.openingBalance == Money(euros: 970) && preview.fileOpeningBalance == Money(euros: 970))
    }

    @Test func everythingBeforeCutover() throws {
        let (importer, account, _) = try makeDatabase()
        let preview = try importer.preview(data: csv(Array(aroundNewYear.prefix(2))), fileName: "c.csv", accountId: account,
                                           skipThrough: cutover)
        #expect(preview.newCount == 0 && preview.cutoverSkippedCount == 2)
        #expect(preview.firstDay == nil && preview.lastDay == nil)
        #expect(preview.openingBalance == Money(euros: 970) && preview.closingBalance == Money(euros: 970))
        let result = try importer.commit(preview)
        #expect(result.transactions.isEmpty && result.batch.newCount == 0)
        #expect(try count(importer, "bankTransaction") == 0)
    }

    @Test func historyCutoverFindsLastHistoryDay() throws {
        let (importer, account, savings) = try makeDatabase()
        #expect(try importer.historyCutover(accountId: account) == nil)
        try importer.database.write { db in
            func add(_ accountId: Int64, _ day: Day, note: String) throws {
                var entry = Entry(accountId: accountId, day: day, amount: Money(euros: -1), label: "Test", note: note)
                try entry.insert(db)
            }
            try add(account, Day(year: 2026, month: 11, day: 30)!, note: "Excel-historie")
            try add(account, cutover, note: "Excel-historie")
            try add(account, Day(year: 2027, month: 1, day: 5)!, note: "")
            try add(savings, Day(year: 2026, month: 10, day: 1)!, note: "Excel-historie")
        }
        #expect(try importer.historyCutover(accountId: account) == cutover)
        #expect(try importer.historyCutover(accountId: savings) == Day(year: 2026, month: 10, day: 1))

        // Met Excel-historie noemt de waarschuwing die historie.
        let preview = try importer.preview(data: csv(aroundNewYear), fileName: "a.csv", accountId: account,
                                           skipThrough: try importer.defaultSkipThrough(accountId: account))
        #expect(preview.warnings.map(\.message)
                == ["2 regels van 31-12-2026 of eerder zijn overgeslagen: die periode staat al in je Excel-historie."])
        let result = try importer.importFile(data: csv(aroundNewYear), fileName: "a.csv", accountId: account,
                                             skipThrough: try importer.historyCutover(accountId: account))
        #expect(result.transactions.map(\.day) == [newYear, Day(year: 2027, month: 1, day: 2)!])
    }

    @Test func pdfStatementWithCutover() throws {
        let (importer, _, savings) = try makeDatabase()
        let pdf = makePDF([[
            "Rekeningafschrift", "NL00 TEST 0000 0000 02",
            "Beginsaldo op 01-12-2026 € 100,00", "Eindsaldo op 05-01-2027 € 160,50",
            "Datum Bij/Af Bedrag (€) Omschrijving",
            "15-12-2026 Bij 50,00 Storting",
            "31-12-2026 Bij 0,50 Rente",
            "03-01-2027 Bij 10,00 Storting",
        ]])
        let preview = try importer.preview(data: pdf, fileName: "a.pdf", accountId: savings, skipThrough: cutover)
        #expect(preview.rows.map(\.isBeforeCutover) == [true, true, false])
        #expect(preview.chainOK == true)
        #expect(preview.openingBalance == Money(cents: 15050) && preview.fileOpeningBalance == Money(euros: 100))
        #expect(preview.closingBalance == Money(cents: 16050))
        #expect(preview.warnings.map(\.kind) == [.beforeCutover])
        let result = try importer.commit(preview)
        #expect(result.transactions.map(\.amount.cents) == [1000])
        #expect(result.transactions[0].balanceBefore == Money(cents: 15050))
    }

    @Test func archiveWithCutover() throws {
        let (importer, checking, savings) = try makeDatabase()
        let savingsLines = [
            line("31-12-2026", "500.00", "1.00", seq: "1", own: savingsIban),
            line("02-01-2027", "501.00", "25.00", seq: "2", own: savingsIban),
        ]
        let files = [
            ZipArchive.File(name: "\(checkingIban)-export.csv", data: csv(aroundNewYear), problem: nil),
            ZipArchive.File(name: "\(savingsIban)-export.csv", data: csv(savingsLines), problem: nil),
        ]
        // Eén overgangsdag voor alles.
        let archive = try importer.previewArchive(files: files, fileName: "x.zip", skipThrough: cutover, skipThroughByAccount: [:])
        #expect(archive.items.map(\.preview?.cutoverSkippedCount) == [2, 1])
        #expect(archive.cutoverSkippedCount == 3 && archive.newCount == 3)
        #expect(archive.items[1].preview?.openingBalance == Money(euros: 501))

        // Een eigen dag per rekening gaat voor.
        let perAccount = try importer.previewArchive(files: files, fileName: "x.zip", skipThrough: cutover,
                                                     skipThroughByAccount: [savings: Day(year: 2026, month: 12, day: 1)!])
        #expect(perAccount.items.map(\.preview?.cutoverSkippedCount) == [2, 0])

        let results = try importer.commitArchive(archive)
        #expect(results.map(\.result.transactions.count) == [2, 1])
        #expect(results.map(\.result.cutoverSkippedCount) == [2, 1])
        let days = try importer.database.read { try Day.fetchAll($0, sql: "SELECT day FROM bankTransaction ORDER BY day") }
        #expect(days.allSatisfy { $0 > cutover })
        #expect(results.map(\.account.id) == [checking, savings])
    }

    @Test func archiveFromZipPassesCutover() throws {
        let (importer, _, _) = try makeDatabase()
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent("hfimport-test-\(UUID().uuidString)")
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: directory) }
        try csv(aroundNewYear).write(to: directory.appendingPathComponent("\(checkingIban)-export.csv"))
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = directory
        zip.arguments = ["-q", "x.zip", "\(checkingIban)-export.csv"]
        try zip.run()
        zip.waitUntilExit()
        let archive = try importer.previewArchive(url: directory.appendingPathComponent("x.zip"), skipThrough: cutover)
        #expect(archive.cutoverSkippedCount == 2 && archive.newCount == 2)
        #expect(archive.items[0].preview?.warnings.map(\.kind) == [.beforeCutover])
    }
}
