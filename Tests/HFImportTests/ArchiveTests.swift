import Foundation
import Testing
import GRDB
import HFCore
@testable import HFImport

// Alle gegevens hieronder zijn verzonnen.

private let checkingIban = "NL00TEST0000000001"
private let savingsIban = "NL00TEST0000000002"
private let unknownIban = "NL00TEST0000000009"

private func line(_ own: String, _ date: String, _ before: String, _ amount: String, seq: String,
                  counter: String = "NL00TEST0000000005", name: String = "Winkel Test", text: String = "Test") -> String {
    "\(date),\(own),\(counter),'\(name)',,,,EUR,\(before),EUR,\(amount),\(date),\(date),IC,GC,\(seq),,'\(text)',1"
}

private let checkingCSV = [
    line(checkingIban, "04-01-2027", "1000.00", "-25.50", seq: "1"),
    line(checkingIban, "05-01-2027", "974.50", "-100.00", seq: "2", counter: savingsIban, name: "Eigen spaar"),
].joined(separator: "\r\n") + "\r\n"

// Spaarrekening: een renteregel zonder tegenrekening.
private let savingsCSV = [
    line(savingsIban, "01-01-2027", "5000.00", "12.34", seq: "1", counter: "", name: "", text: "Rente"),
    line(savingsIban, "05-01-2027", "5012.34", "100.00", seq: "2", counter: checkingIban, name: "Eigen betaal"),
].joined(separator: "\r\n") + "\r\n"

private let unknownCSV = line(unknownIban, "04-01-2027", "10.00", "-1.00", seq: "1") + "\r\n"

/// Maakt een zip met de gegeven bestanden (naam → inhoud) via /usr/bin/zip.
private func makeZip(_ files: [String: Data], extraArguments: [String] = []) throws -> Data {
    let fm = FileManager.default
    let directory = fm.temporaryDirectory.appendingPathComponent("hfimport-test-\(UUID().uuidString)")
    let content = directory.appendingPathComponent("inhoud")
    try fm.createDirectory(at: content, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: directory) }
    for (name, data) in files {
        let url = content.appendingPathComponent(name)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
    process.currentDirectoryURL = content
    process.arguments = ["-q", "-r", "../test.zip"] + (extraArguments.isEmpty ? ["."] : extraArguments)
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    return try Data(contentsOf: directory.appendingPathComponent("test.zip"))
}

private func makeDatabase() throws -> (BankImporter, checking: Int64, savings: Int64) {
    let db = try AppDatabase.inMemory()
    let ids = try db.write { db -> (Int64, Int64) in
        let day = Day(year: 2027, month: 1, day: 1)!
        var checking = Account(name: "Betaalrekening", iban: "NL00 TEST 0000 0000 01", kind: .betaal, openingDate: day)
        var savings = Account(name: "Spaarrekening", iban: savingsIban, kind: .spaar, openingDate: day)
        try checking.insert(db)
        try savings.insert(db)
        return (checking.id!, savings.id!)
    }
    return (BankImporter(database: db), ids.0, ids.1)
}

private func count(_ importer: BankImporter, _ table: String) throws -> Int {
    try importer.database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM \(table)")! }
}

private let bankFiles: [String: Data] = [
    "\(checkingIban)-13-11-2026T13_33_15.csv": Data(checkingCSV.utf8),
    "\(savingsIban)-13-11-2026T13_33_15.csv": Data(savingsCSV.utf8),
    "\(unknownIban)-13-11-2026T13_33_15.csv": Data(unknownCSV.utf8),
]

@Suite struct ArchiveTests {
    @Test func routesEachFileToItsAccount() throws {
        let (importer, checking, savings) = try makeDatabase()
        var files = bankFiles
        files["leeg.csv"] = Data()
        files["leesmij.docx"] = Data("tekst".utf8)
        let archive = try importer.previewArchive(data: try makeZip(files), fileName: "export.zip")

        #expect(archive.items.count == 5)
        let byName = Dictionary(uniqueKeysWithValues: archive.items.map { ($0.fileName, $0) })
        let a = try #require(byName["\(checkingIban)-13-11-2026T13_33_15.csv"])
        #expect(a.iban == checkingIban && a.account?.id == checking && a.message == nil && a.isImportable)
        #expect(a.preview?.accountId == checking && a.preview?.newCount == 2 && a.preview?.chainOK == true)
        #expect(a.preview?.warnings.isEmpty == true)
        let b = try #require(byName["\(savingsIban)-13-11-2026T13_33_15.csv"])
        #expect(b.account?.id == savings && b.preview?.rows.count == 2 && b.preview?.errors.isEmpty == true)
        #expect(b.preview?.rows[0].counterpartyIban == "" && b.preview?.closingBalance == Money(cents: 511234))
        let c = try #require(byName["\(unknownIban)-13-11-2026T13_33_15.csv"])
        #expect(c.iban == unknownIban && c.account == nil && c.preview == nil && !c.isImportable)
        #expect(c.message == "Geen rekening met IBAN \(unknownIban) gevonden.")
        #expect(byName["leeg.csv"]?.message == "Het bestand is leeg.")
        #expect(byName["leesmij.docx"]?.message?.contains("niet ondersteund") == true)
        #expect(archive.importableItems.count == 2 && archive.skippedItems.count == 3)
        #expect(archive.newCount == 4 && archive.canCommit)
        #expect(try count(importer, "bankTransaction") == 0)

        let results = try importer.commitArchive(archive)
        #expect(results.map(\.account.id) == [checking, savings])
        #expect(results.map(\.result.transactions.count) == [2, 2])
        #expect(try count(importer, "importBatch") == 2)
        let perAccount = try importer.database.read { db in
            try Int.fetchAll(db, sql: "SELECT COUNT(*) FROM bankTransaction GROUP BY accountId ORDER BY accountId")
        }
        #expect(perAccount == [2, 2])

        // Dezelfde zip opnieuw: niets dubbel.
        let again = try importer.previewArchive(data: try makeZip(files), fileName: "export.zip")
        #expect(again.newCount == 0 && again.duplicateCount == 4)
        #expect(try importer.commitArchive(again).allSatisfy { $0.result.transactions.isEmpty })
        #expect(try count(importer, "bankTransaction") == 4)
    }

    @Test func previewArchiveFromURL() throws {
        let (importer, checking, _) = try makeDatabase()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hfimport-test-\(UUID().uuidString).zip")
        try makeZip(["map/\(checkingIban)-export.csv": Data(checkingCSV.utf8)]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let archive = try importer.previewArchive(url: url)
        #expect(archive.fileName == url.lastPathComponent)
        #expect(archive.items.map(\.fileName) == ["map/\(checkingIban)-export.csv"])
        #expect(archive.items[0].account?.id == checking)
    }

    @Test func allOrNothing() throws {
        let (importer, _, _) = try makeDatabase()
        var archive = try importer.previewArchive(data: try makeZip(bankFiles), fileName: "export.zip")
        // Forceer een fout in het tweede bestand: twee regels met dezelfde vingerafdruk.
        let i = try #require(archive.items.firstIndex { $0.iban == savingsIban })
        archive.items[i].preview!.rows[1].fingerprint = archive.items[i].preview!.rows[0].fingerprint
        #expect(throws: (any Error).self) { try importer.commitArchive(archive) }
        #expect(try count(importer, "bankTransaction") == 0)
        #expect(try count(importer, "importBatch") == 0)
    }

    @Test func faultyRowsBlockTheWholeArchive() throws {
        let (importer, _, _) = try makeDatabase()
        var files = bankFiles
        files["\(savingsIban)-13-11-2026T13_33_15.csv"] = Data((savingsCSV
            + line(savingsIban, "06-01-2027", "5112.34", "kapot", seq: "3") + "\r\n").utf8)
        let archive = try importer.previewArchive(data: try makeZip(files), fileName: "export.zip")
        #expect(archive.errorCount == 1 && !archive.canCommit)
        #expect(throws: ImportError.rowErrors(1)) { try importer.commitArchive(archive) }
        #expect(try count(importer, "bankTransaction") == 0)
        let results = try importer.commitArchive(archive, skipFaultyRows: true)
        #expect(results.map(\.result.transactions.count) == [2, 2])
        #expect(results[1].result.skippedErrorCount == 1)
    }

    @Test func fileNameAndPDFRouting() throws {
        let (importer, checking, savings) = try makeDatabase()
        // Geen IBAN-kolom: de bestandsnaam bepaalt de rekening.
        let generic = "Datum;Bedrag;Omschrijving\n04-01-2027;-2,50;Koffie\n"
        let pdf = makePDF([[
            "Rekeningafschrift", "NL00 TEST 0000 0000 02", "Beginsaldo op 01-11-2026 € 10,00",
            "Eindsaldo op 13-11-2026 € 10,98", "Datum Bij/Af Bedrag (€) Omschrijving", "05-11-2026 Bij 0,98 Rente",
        ]])
        let archive = try importer.previewArchive(data: try makeZip([
            "\(checkingIban.lowercased())-export.csv": Data(generic.utf8),
            "afschrift.pdf": pdf,
            "onbekend.csv": Data(generic.utf8),
        ]), fileName: "export.zip")
        let byName = Dictionary(uniqueKeysWithValues: archive.items.map { ($0.fileName, $0) })
        #expect(byName["\(checkingIban.lowercased())-export.csv"]?.account?.id == checking)
        #expect(byName["afschrift.pdf"]?.account?.id == savings)
        #expect(byName["afschrift.pdf"]?.preview?.chainOK == true)
        #expect(byName["onbekend.csv"]?.iban == "")
        #expect(byName["onbekend.csv"]?.message?.contains("geen IBAN") == true)
        #expect(try importer.commitArchive(archive).count == 2)
    }

    @Test func refusesUnsafeAndBrokenArchives() throws {
        let (importer, _, _) = try makeDatabase()
        // Een pad dat buiten de uitpakmap uitkomt.
        let unsafe = try makeZip(["x/\(checkingIban).csv": Data(checkingCSV.utf8)],
                                 extraArguments: ["../inhoud/x/\(checkingIban).csv"])
        #expect(throws: ImportError.archiveUnsafePath("../inhoud/x/\(checkingIban).csv")) {
            try importer.previewArchive(data: unsafe, fileName: "eng.zip")
        }
        #expect(throws: ImportError.archiveUnreadable) {
            try importer.previewArchive(data: Data("geen zip".utf8), fileName: "kapot.zip")
        }
        let nothing = try importer.previewArchive(data: try makeZip(["a.csv": Data(unknownCSV.utf8)]), fileName: "a.zip")
        #expect(throws: ImportError.nothingToImport) { try importer.commitArchive(nothing) }
        #expect(ImportError.archiveUnsafePath("../x").errorDescription?.contains("onveilig pad") == true)
    }

    @Test func matchAccountAndSuggestion() throws {
        let (importer, checking, savings) = try makeDatabase()
        // Op bestandsnaam.
        let byName = try importer.matchAccount(forFileNamed: "\(savingsIban)-13-11-2026T13_33_15.csv")
        #expect(byName.iban == savingsIban && byName.account?.id == savings && byName.message == nil)
        // Op inhoud: die wint van de naam.
        let byData = try importer.matchAccount(data: Data(checkingCSV.utf8), fileName: "\(savingsIban).csv")
        #expect(byData.account?.id == checking)
        let none = try importer.matchAccount(forFileNamed: "export.csv")
        #expect(none.iban == "" && none.account == nil && none.message?.contains("geen IBAN") == true)
        #expect(try importer.matchAccount(forFileNamed: "\(unknownIban).csv").message
                == "Geen rekening met IBAN \(unknownIban) gevonden.")

        // Betaal-CSV in de spaarrekening: waarschuwing met de juiste rekening als voorstel.
        let preview = try importer.preview(data: Data(checkingCSV.utf8), fileName: "x.csv", accountId: savings)
        #expect(preview.warnings.map(\.kind) == [.ibanMismatch])
        #expect(preview.warnings[0].suggestedAccount?.id == checking)
        #expect(preview.warnings[0].message.contains("Het hoort bij rekening Betaalrekening."))
        #expect(try importer.matchAccount(forFileNamed: "x.csv", rows: preview.rows).account?.id == checking)
        // Onbekend IBAN: wel een waarschuwing, geen voorstel.
        let unknown = try importer.preview(data: Data(unknownCSV.utf8), fileName: "y.csv", accountId: savings)
        #expect(unknown.warnings[0].suggestedAccount == nil)
    }
}
