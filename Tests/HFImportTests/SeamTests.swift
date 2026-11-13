import Foundation
import Testing
import GRDB
import HFCore
@testable import HFImport

// Alle gegevens hieronder zijn verzonnen.

private let checkingIban = "NL00TEST0000000001"
private let savingsIban = "NL00TEST0000000002"

private func line(_ date: String, _ before: String, _ amount: String, seq: String, own: String = checkingIban) -> String {
    "\(date),\(own),NL00TEST0000000005,'Winkel Test',,,,EUR,\(before),EUR,\(amount),\(date),\(date),IC,GC,\(seq),,'Test \(seq)',1"
}

/// Drie regels op de overgangsdag: twee staan al in de administratie (saldo daarna € 940), één nog niet.
private let seamFile = [
    line("30-12-2026", "1000.00", "-10.00", seq: "1"),
    line("31-12-2026", "990.00", "-20.00", seq: "2"),
    line("31-12-2026", "970.00", "-30.00", seq: "3"),
    line("31-12-2026", "940.00", "100.00", seq: "4"),
    line("02-01-2027", "1040.00", "-5.00", seq: "5"),
]

private func csv(_ lines: [String]) -> Data { Data((lines.joined(separator: "\r\n") + "\r\n").utf8) }
private let cutover = Day(year: 2026, month: 12, day: 31)!

private func makeDatabase() throws -> (BankImporter, checking: Int64, savings: Int64) {
    let db = try AppDatabase.inMemory()
    let ids = try db.write { db -> (Int64, Int64) in
        let day = Day(year: 2027, month: 1, day: 1)!
        var checking = Account(name: "Betaalrekening", iban: checkingIban, kind: .betaal, openingDate: day)
        var savings = Account(name: "Spaarrekening", iban: savingsIban, kind: .spaar, openingDate: day)
        try checking.insert(db)
        try savings.insert(db)
        return (checking.id!, savings.id!)
    }
    return (BankImporter(database: db), ids.0, ids.1)
}

@Suite struct SeamTests {
    @Test func seamInTheMiddleOfADay() throws {
        let (importer, account, _) = try makeDatabase()
        // Nieuwste eerst; de datum alleen zou alle drie de regels van 31-12 overslaan.
        let preview = try importer.preview(data: csv(seamFile.reversed()), fileName: "a.csv", accountId: account,
                                           skipThrough: cutover, resumeFromBalance: Money(euros: 940))
        let seam = try #require(preview.seam)
        #expect(seam.method == .foundByBalance)
        #expect(seam.soughtBalance == Money(euros: 940) && seam.balance == Money(euros: 940))
        #expect(seam.lineNumber == 2 && seam.day == cutover && seam.skippedCount == 3)
        #expect(seam.seamCandidates == [2] && !seam.isAmbiguous && !seam.balanceNotFound)
        #expect(seam.fileOpeningBalance == Money(euros: 1000) && seam.fileClosingBalance == Money(euros: 1035))
        #expect(preview.rowsChronological.map(\.isBeforeCutover) == [true, true, true, false, false])
        #expect(preview.newCount == 2 && preview.cutoverSkippedCount == 3)
        #expect(preview.openingBalance == Money(euros: 940) && preview.closingBalance == Money(euros: 1035))
        #expect(preview.firstDay == cutover)
        #expect(preview.chainOK == true)
        #expect(preview.warnings.map(\.kind) == [.beforeCutover])
        #expect(preview.warnings[0].message.hasPrefix("3 regels vóór regel 2 (31-12-2026) zijn overgeslagen"))

        let result = try importer.commit(preview)
        #expect(result.transactions.map(\.sequence) == ["4", "5"])
        #expect(result.cutoverSkippedCount == 3 && result.batch.openingBalance == Money(euros: 940))
    }

    @Test func seamOnFirstRowSkipsNothing() throws {
        let (importer, account, _) = try makeDatabase()
        let preview = try importer.preview(data: csv(seamFile), fileName: "a.csv", accountId: account,
                                           resumeFromBalance: Money(euros: 1000))
        #expect(preview.seam?.method == .foundByBalance)
        #expect(preview.seam?.lineNumber == 1 && preview.seam?.skippedCount == 0)
        #expect(preview.newCount == 5 && preview.warnings.isEmpty)
        #expect(preview.openingBalance == Money(euros: 1000))
    }

    @Test func balanceOccursTwice() throws {
        let (importer, account, _) = try makeDatabase()
        var lines = [
            line("28-12-2026", "1000.00", "-10.00", seq: "1"),
            line("29-12-2026", "990.00", "10.00", seq: "2"),
            line("30-12-2026", "1000.00", "-50.00", seq: "3"),
            line("31-12-2026", "950.00", "-1.00", seq: "4"),
        ]
        // Sluitende keten: de vroegste kandidaat wint, met een waarschuwing.
        let preview = try importer.preview(data: csv(lines), fileName: "a.csv", accountId: account,
                                           resumeFromBalance: Money(euros: 1000))
        #expect(preview.seam?.seamCandidates == [1, 3] && preview.seam?.isAmbiguous == true)
        #expect(preview.seam?.lineNumber == 1 && preview.cutoverSkippedCount == 0)
        #expect(preview.warnings.map(\.kind) == [.seamAmbiguous])
        #expect(preview.warnings[0].message.contains("op 2 plekken"))

        // Breekt de keten na de eerste kandidaat, dan is de tweede de vroegste met een sluitende keten erna.
        lines[1] = line("29-12-2026", "985.00", "15.00", seq: "2")
        let broken = try importer.preview(data: csv(lines), fileName: "a.csv", accountId: account,
                                          resumeFromBalance: Money(euros: 1000))
        #expect(broken.chainOK == false)
        #expect(broken.seam?.seamCandidates == [1, 3])
        #expect(broken.seam?.lineNumber == 3 && broken.seam?.skippedCount == 2)
        #expect(broken.newCount == 2)
    }

    @Test func notFoundWithoutAndWithDate() throws {
        let (importer, account, _) = try makeDatabase()
        let preview = try importer.preview(data: csv(seamFile), fileName: "a.csv", accountId: account,
                                           resumeFromBalance: Money(euros: 123))
        let seam = try #require(preview.seam)
        #expect(seam.method == .notFound && seam.balanceNotFound && seam.seamCandidates.isEmpty)
        #expect(seam.soughtBalance == Money(euros: 123))
        #expect(seam.fileOpeningBalance == Money(euros: 1000) && seam.fileClosingBalance == Money(euros: 1035))
        #expect(seam.skippedCount == 0 && preview.newCount == 5)
        #expect(preview.warnings.map(\.kind) == [.seamNotFound])
        #expect(preview.warnings[0].message.hasPrefix(
            "Geen regel in dit bestand sluit aan op het saldo € 123,00 van je administratie."))
        #expect(preview.warnings[0].message.contains("€ 1.000,00") && preview.warnings[0].message.contains("€ 1.035,00"))

        // Met een datum als terugval.
        let byDate = try importer.preview(data: csv(seamFile), fileName: "a.csv", accountId: account,
                                          skipThrough: cutover, resumeFromBalance: Money(euros: 123))
        #expect(byDate.seam?.method == .byDate && byDate.seam?.balanceNotFound == true)
        #expect(byDate.seam?.skippedCount == 4 && byDate.newCount == 1)
        #expect(byDate.warnings.map(\.kind) == [.seamNotFound, .beforeCutover])
        #expect(byDate.openingBalance == Money(euros: 1040))

        // Alleen een datum: geen zoektocht op saldo, wel een naad op datum.
        let onlyDate = try importer.preview(data: csv(seamFile), fileName: "a.csv", accountId: account, skipThrough: cutover)
        #expect(onlyDate.seam?.method == .byDate && onlyDate.seam?.soughtBalance == nil)
        #expect(onlyDate.seam?.balanceNotFound == false)
        // Geen van beide: geen naad.
        #expect(try importer.preview(data: csv(seamFile), fileName: "a.csv", accountId: account).seam == nil)
    }

    @Test func fileWithoutBalancesFallsBackToDate() throws {
        let (importer, account, _) = try makeDatabase()
        let text = "Datum;Bedrag;Omschrijving\n31-12-2026;-2,50;Koffie\n02-01-2027;-3,00;Thee\n"
        let preview = try importer.preview(data: Data(text.utf8), fileName: "g.csv", accountId: account,
                                           skipThrough: cutover, resumeFromBalance: Money(euros: 10))
        #expect(preview.seam?.method == .byDate && preview.newCount == 1)
        #expect(preview.warnings.map(\.kind) == [.seamNotFound, .beforeCutover])
        #expect(preview.warnings[0].message.contains("geen saldo per regel"))
    }

    @Test func everythingAlreadyProcessed() throws {
        let (importer, account, _) = try makeDatabase()
        let preview = try importer.preview(data: csv(seamFile), fileName: "a.csv", accountId: account,
                                           resumeFromBalance: Money(euros: 1035))
        #expect(preview.seam?.method == .alreadyProcessed && preview.seam?.closingBalanceMatches == true)
        #expect(preview.seam?.lineNumber == nil && preview.seam?.skippedCount == 5)
        #expect(preview.newCount == 0 && preview.cutoverSkippedCount == 5)
        #expect(preview.openingBalance == Money(euros: 1035))
        #expect(preview.warnings.map(\.kind) == [.alreadyProcessed])
        #expect(preview.warnings[0].message.contains("alles in dit bestand is al verwerkt"))
        #expect(try importer.commit(preview).transactions.isEmpty)
    }

    @Test func manualChoicePerRow() throws {
        let (importer, account, _) = try makeDatabase()
        let preview = try importer.preview(data: csv(seamFile), fileName: "a.csv", accountId: account,
                                           resumeFromBalance: Money(euros: 123))
        // Niet gevonden: de gebruiker zet zelf de eerste twee regels uit.
        let chosen = preview.overriding(excludeLineNumbers: [1, 2])
        #expect(chosen.rows.map(\.isBeforeCutover) == [true, true, false, false, false])
        #expect(chosen.newCount == 3 && chosen.cutoverSkippedCount == 2)
        #expect(chosen.seam?.method == .manual && chosen.seam?.lineNumber == 3 && chosen.seam?.skippedCount == 2)
        #expect(chosen.openingBalance == Money(euros: 970) && chosen.fileOpeningBalance == Money(euros: 1000))
        #expect(chosen.warnings.map(\.kind) == [.seamNotFound, .manualSelection])
        #expect(preview.newCount == 5)   // het origineel is niet veranderd

        // Eén regel weer aanzetten.
        let adjusted = chosen.overriding(includeLineNumbers: [2])
        #expect(adjusted.rows.map(\.isBeforeCutover) == [true, false, false, false, false])
        #expect(adjusted.warnings.map(\.kind) == [.seamNotFound, .manualSelection])
        // Alles weer aan: geen melding meer over de keuze.
        let all = adjusted.overriding(includeLineNumbers: [1])
        #expect(all.cutoverSkippedCount == 0 && all.warnings.map(\.kind) == [.seamNotFound])
        #expect(all.openingBalance == Money(euros: 1000))

        let result = try importer.commit(adjusted)
        #expect(result.transactions.map(\.sequence) == ["2", "3", "4", "5"])

        // Een automatisch gevonden naad kan ook worden bijgesteld; ook zonder naad werkt de keuze.
        let found = try importer.preview(data: csv(seamFile), fileName: "b.csv", accountId: account,
                                         resumeFromBalance: Money(euros: 940)).overriding(includeLineNumbers: [3])
        #expect(found.seam?.method == .manual && found.seam?.soughtBalance == Money(euros: 940))
        #expect(found.rows.map(\.isBeforeCutover) == [true, true, false, false, false])
        let plain = try importer.preview(data: csv(seamFile), fileName: "b.csv", accountId: account)
            .overriding(excludeLineNumbers: [5])
        #expect(plain.seam?.method == .manual && plain.cutoverSkippedCount == 1)
    }

    @Test func archiveWithOwnBalancePerAccount() throws {
        let (importer, checking, savings) = try makeDatabase()
        let savingsLines = [
            line("30-12-2026", "500.00", "1.00", seq: "1", own: savingsIban),
            line("31-12-2026", "501.00", "25.00", seq: "2", own: savingsIban),
            line("02-01-2027", "526.00", "4.00", seq: "3", own: savingsIban),
        ]
        let files = [
            ZipArchive.File(name: "\(checkingIban)-export.csv", data: csv(seamFile), problem: nil),
            ZipArchive.File(name: "\(savingsIban)-export.csv", data: csv(savingsLines), problem: nil),
        ]
        let archive = try importer.previewArchive(
            files: files, fileName: "x.zip", skipThrough: nil, skipThroughByAccount: [:],
            resumeFromBalance: [checking: Money(euros: 940), savings: Money(euros: 501)])
        #expect(archive.items.map(\.preview?.seam?.method) == [.foundByBalance, .foundByBalance])
        #expect(archive.items.map(\.preview?.cutoverSkippedCount) == [3, 1])
        #expect(archive.items.map(\.preview?.openingBalance) == [Money(euros: 940), Money(euros: 501)])
        #expect(archive.newCount == 4 && archive.cutoverSkippedCount == 4)
        let results = try importer.commitArchive(archive)
        #expect(results.map(\.result.transactions.count) == [2, 2])

        // Alleen voor de rekening die het nodig heeft.
        let (other, checking2, _) = try makeDatabase()
        let partial = try other.previewArchive(files: files, fileName: "x.zip", skipThrough: nil, skipThroughByAccount: [:],
                                               resumeFromBalance: [checking2: Money(euros: 940)])
        #expect(partial.items[0].preview?.seam?.method == .foundByBalance)
        #expect(partial.items[1].preview?.seam == nil && partial.items[1].preview?.newCount == 3)
    }

    @Test func pdfStatementSeamByBalance() throws {
        let (importer, _, savings) = try makeDatabase()
        let pdf = makePDF([[
            "Rekeningafschrift", "NL00 TEST 0000 0000 02",
            "Beginsaldo op 01-12-2026 € 100,00", "Eindsaldo op 05-01-2027 € 160,50",
            "Datum Bij/Af Bedrag (€) Omschrijving",
            "15-12-2026 Bij 50,00 Storting", "31-12-2026 Bij 0,50 Rente", "03-01-2027 Bij 10,00 Storting",
        ]])
        let preview = try importer.preview(data: pdf, fileName: "a.pdf", accountId: savings,
                                           resumeFromBalance: Money(euros: 150))
        #expect(preview.seam?.method == .foundByBalance && preview.seam?.skippedCount == 1)
        #expect(preview.rows.map(\.isBeforeCutover) == [true, false, false])
    }

    @Test func needsSeamOnlyBeforeFirstBankImport() throws {
        let (importer, account, savings) = try makeDatabase()
        #expect(try importer.needsSeam(accountId: account) == false)   // geen Excel-historie
        try importer.database.write { db in
            var entry = Entry(accountId: account, day: cutover, amount: Money(euros: -1), label: "Test", note: "Excel-historie")
            try entry.insert(db)
        }
        #expect(try importer.needsSeam(accountId: account) == true)
        #expect(try importer.needsSeam(accountId: savings) == false)
        try importer.importFile(data: csv(seamFile), fileName: "a.csv", accountId: account, resumeFromBalance: Money(euros: 940))
        #expect(try importer.needsSeam(accountId: account) == false)   // daarna werkt de vingerafdruk
    }
}
