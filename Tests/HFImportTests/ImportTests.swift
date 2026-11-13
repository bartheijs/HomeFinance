import Foundation
import Testing
import GRDB
import HFCore
@testable import HFImport

// Alle gegevens hieronder zijn verzonnen.

private let ownIban = "NL00TEST0000000001"

/// Eén regel in ASN-indeling (19 kolommen, komma als scheidingsteken).
private func asn(_ date: String, _ before: String, _ amount: String, seq: String, name: String = "Bakkerij Test",
                 iban: String = "NL00TEST0000000002", text: String = "Brood", own: String = ownIban) -> String {
    "\(date),\(own),\(iban),'\(name)',,,,EUR,\(before),EUR,\(amount),\(date),\(date),IC,GC,\(seq),,'\(text)',1"
}

private let oldestFirst = [
    asn("04-01-2027", "1000.00", "-25.50", seq: "101"),
    asn("05-01-2027", "974.50", "100.00", seq: "102", name: "Werkgever Test", iban: "NL00TEST0000000003", text: "Salaris"),
    asn("06-01-2027", "1074.50", "-10.00", seq: "103", name: "Kiosk Test", text: "Krant"),
]

private func csv(_ lines: [String]) -> Data { Data((lines.joined(separator: "\r\n") + "\r\n").utf8) }

private func makeDatabase(iban: String? = ownIban) throws -> (BankImporter, Int64) {
    let db = try AppDatabase.inMemory()
    let id = try db.write { db -> Int64 in
        var account = Account(name: "Betaalrekening", iban: iban, kind: .betaal,
                              openingDate: Day(year: 2027, month: 1, day: 1)!)
        try account.insert(db)
        return account.id!
    }
    return (BankImporter(database: db), id)
}

private func count(_ importer: BankImporter, _ table: String) throws -> Int {
    try importer.database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM \(table)")! }
}

@Suite struct CSVReaderTests {
    @Test func quotesDelimitersAndNewlines() {
        let text = "\u{FEFF}a;\"b;c\";\"regel 1\nregel 2\";\"zei \"\"hoi\"\"\"\r\nd;e;f;g\r\n\r\n\r\n"
        let file = CSVFile(text: text)
        #expect(file.dialect == CSVDialect(delimiter: ";", quote: "\""))
        #expect(file.records.count == 2)
        #expect(file.records[0].fields == ["a", "b;c", "regel 1\nregel 2", "zei \"hoi\""])
        #expect(file.records[0].lineNumber == 1)
        #expect(file.records[1].fields == ["d", "e", "f", "g"])
        #expect(file.records[1].lineNumber == 3)
    }

    @Test func detectsDelimitersAndSingleQuotes() {
        #expect(CSVReader.detectDialect("a,b,c\n1,2,3\n").delimiter == ",")
        #expect(CSVReader.detectDialect("a\tb\tc\n1\t2\t3\n").delimiter == "\t")
        #expect(CSVReader.detectDialect("datum;bedrag\n01-01-2027;12,50\n02-01-2027;3,10\n").delimiter == ";")
        let single = CSVFile(text: "1,'Jansen, Test','O''Test'\n2,'x','y'\n")
        #expect(single.dialect == CSVDialect(delimiter: ",", quote: "'"))
        #expect(single.records[0].fields == ["1", "Jansen, Test", "O'Test"])
    }

    @Test func apostropheInsideQuotedFieldIsKept() {
        let records = CSVReader.parse("'Test's winkel',5\n", dialect: CSVDialect(delimiter: ",", quote: "'"))
        #expect(records[0].fields == ["Test's winkel", "5"])
    }

    @Test func unterminatedQuoteIsFlagged() {
        let records = CSVReader.parse("a;\"b\nc;d\n", dialect: CSVDialect())
        #expect(records.count == 1)
        #expect(records[0].unterminatedQuote)
    }

    @Test func decodesEncodings() throws {
        let utf8 = try #require(CSVReader.decode(Data("café".utf8)))
        #expect(utf8.text == "café" && utf8.encoding == .utf8)
        let bom = try #require(CSVReader.decode(Data([0xEF, 0xBB, 0xBF]) + Data("x;y".utf8)))
        #expect(bom.text == "x;y")
        let cp = try #require(CSVReader.decode("café €".data(using: .windowsCP1252)!))
        #expect(cp.text == "café €" && cp.encoding == .windowsCP1252)
    }

    @Test func rawRowsForManualMapping() {
        let file = CSVFile(text: "x;y;z\n1;2;3\n4;5;6\n")
        #expect(file.rawRows(limit: 2) == [["x", "y", "z"], ["1", "2", "3"]])
        #expect(file.columnCount == 3)
        #expect(detectProfile(for: file) == nil)
    }
}

@Suite struct ProfileTests {
    @Test func parsesDates() {
        let day = Day(year: 2027, month: 1, day: 5)!
        #expect(BankProfile.parseDay("05-01-2027", formats: ["dd-MM-yyyy"]) == day)
        #expect(BankProfile.parseDay("5/1/2027", formats: ["dd-MM-yyyy"]) == day)
        #expect(BankProfile.parseDay("2027-01-05", formats: ["dd-MM-yyyy", "yyyy-MM-dd"]) == day)
        #expect(BankProfile.parseDay("20270105", formats: ["yyyyMMdd"]) == day)
        #expect(BankProfile.parseDay("01/05/2027", formats: ["MM/dd/yyyy"]) == day)
        #expect(BankProfile.parseDay("05-01-27", formats: ["dd-MM-yy"]) == day)
        #expect(BankProfile.parseDay("2027-01-05 13:45:00", formats: ["yyyy-MM-dd"]) == day)
        #expect(BankProfile.parseDay("31-02-2027", formats: ["dd-MM-yyyy"]) == nil)
        #expect(BankProfile.parseDay("gisteren", formats: ["dd-MM-yyyy", "yyyyMMdd"]) == nil)
    }

    @Test func profileRoundTripsAsJSON() throws {
        var profile = BankProfile.asn
        profile.day = .header("Datum")
        profile.debitCredit = DebitCreditIndicator(column: .index(5), debitValues: ["D"], creditValues: ["C"])
        let data = try JSONEncoder().encode(profile)
        #expect(try JSONDecoder().decode(BankProfile.self, from: data) == profile)
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains("\"day\":\"Datum\""))
        #expect(json.contains("\"amount\":10"))
    }

    @Test func genericRecognisesBankHeaders() throws {
        let profile = try #require(BankProfile.generic(headers: [
            "IBAN/BBAN", "Munt", "Volgnr", "Datum", "Rentedatum", "Bedrag", "Saldo na trn",
            "Tegenrekening IBAN/BBAN", "Naam tegenpartij", "Omschrijving-1", "Omschrijving-2",
        ]))
        #expect(profile.ownIban == .index(0))
        #expect(profile.sequence == .index(2))
        #expect(profile.day == .index(3))
        #expect(profile.amount == .index(5))
        #expect(profile.balance == BalanceColumn(column: .index(6), kind: .after))
        #expect(profile.counterpartyIban == .index(7))
        #expect(profile.counterpartyName == .index(8))
        #expect(profile.description == [.index(9), .index(10)])
        #expect(profile.debitCredit == nil)

        let english = try #require(BankProfile.generic(headers: ["Date", "Description", "Amount", "Balance", "Name"]))
        #expect(english.day == .index(0) && english.amount == .index(2) && english.counterpartyName == .index(4))
        #expect(BankProfile.generic(headers: ["foo", "bar"]) == nil)
    }
}

@Suite struct PreviewTests {
    @Test func asnFileParses() throws {
        let (importer, account) = try makeDatabase()
        let preview = try importer.preview(data: csv(oldestFirst), fileName: "jan.csv", accountId: account)
        #expect(preview.profile.id == "asn")
        #expect(preview.rows.count == 3 && preview.errors.isEmpty)
        #expect(preview.rowCount == 3 && preview.newCount == 3 && preview.duplicateCount == 0)
        let first = preview.rows[0]
        #expect(first.day == Day(year: 2027, month: 1, day: 4))
        #expect(first.amount == Money(cents: -2550))
        #expect(first.balanceBefore == Money(euros: 1000))
        #expect(first.counterpartyName == "Bakkerij Test")
        #expect(first.counterpartyIban == "NL00TEST0000000002")
        #expect(first.descriptionText == "Brood")
        #expect(first.sequence == "101" && first.statementNumber == "1" && first.transactionCode == "GC")
        #expect(first.ownIban == ownIban)
        #expect(preview.chainOK == true && preview.chainBreaks.isEmpty)
        #expect(preview.openingBalance == Money(euros: 1000))
        #expect(preview.closingBalance == Money(cents: 106450))
        #expect(preview.firstDay == Day(year: 2027, month: 1, day: 4))
        #expect(preview.lastDay == Day(year: 2027, month: 1, day: 6))
        #expect(preview.warnings.isEmpty)
        #expect(preview.canCommit)
        #expect(try count(importer, "bankTransaction") == 0)
    }

    @Test func dutchAndDotDecimals() throws {
        let (importer, account) = try makeDatabase()
        let lines = [
            "04-01-2027;\(ownIban);NL00TEST0000000002;A;;;;EUR;1.000,00;EUR;-25,50;;;;;1;;x;1",
            "05-01-2027;\(ownIban);NL00TEST0000000002;B;;;;EUR;974,50;EUR;1.234,56;;;;;2;;y;1",
            "06-01-2027;\(ownIban);NL00TEST0000000002;C;;;;EUR;2209.06;EUR;-12.5;;;;;3;;z;1",
            "07-01-2027;\(ownIban);NL00TEST0000000002;D;;;;EUR;2196.56;EUR;+7;;;;;4;;z;1",
        ]
        let preview = try importer.preview(data: csv(lines), fileName: "nl.csv", accountId: account)
        #expect(preview.dialect.delimiter == ";")
        #expect(preview.rows.map(\.amount.cents) == [-2550, 123456, -1250, 700])
        #expect(preview.chainOK == true)
        #expect(preview.closingBalance == Money(cents: 220356))
    }

    @Test func newestFirstChain() throws {
        let (importer, account) = try makeDatabase()
        let preview = try importer.preview(data: csv(oldestFirst.reversed()), fileName: "a.csv", accountId: account)
        #expect(preview.chainOK == true)
        #expect(preview.openingBalance == Money(euros: 1000))
        #expect(preview.closingBalance == Money(cents: 106450))
        #expect(preview.rows.map(\.sequence) == ["103", "102", "101"])
        #expect(preview.rowsChronological.map(\.sequence) == ["101", "102", "103"])
    }

    @Test func sameDayOrderedBySequence() throws {
        let (importer, account) = try makeDatabase()
        // Dagen aflopend, maar binnen de dag oplopend op volgnummer.
        let lines = [
            asn("05-01-2027", "970.00", "-20.00", seq: "3"),
            asn("05-01-2027", "950.00", "50.00", seq: "4"),
            asn("04-01-2027", "1000.00", "-10.00", seq: "1"),
            asn("04-01-2027", "990.00", "-20.00", seq: "2"),
        ]
        let preview = try importer.preview(data: csv(lines), fileName: "a.csv", accountId: account)
        #expect(preview.chainOK == true)
        #expect(preview.rowsChronological.map(\.sequence) == ["1", "2", "3", "4"])
        #expect(preview.openingBalance == Money(euros: 1000))
        #expect(preview.closingBalance == Money(euros: 1000))
    }

    @Test func brokenChainDetected() throws {
        let (importer, account) = try makeDatabase()
        var lines = oldestFirst
        lines[2] = asn("06-01-2027", "1070.00", "-10.00", seq: "103")
        let preview = try importer.preview(data: csv(lines), fileName: "a.csv", accountId: account)
        #expect(preview.chainOK == false)
        #expect(preview.chainBreaks == [ChainBreak(lineNumber: 3, previousLineNumber: 2,
                                                   expected: Money(cents: 107450), found: Money(euros: 1070))])
        #expect(preview.warnings.map(\.kind) == [.chainBroken])
        #expect(preview.chainBreaks[0].message.contains("Regel 3"))
        // Een gebroken keten houdt het importeren niet tegen, maar wordt wel bewaard.
        let result = try importer.commit(preview)
        #expect(result.batch.chainOK == false)
    }

    @Test func ibanMismatchWarns() throws {
        let (importer, account) = try makeDatabase(iban: "NL00 TEST 0000 0000 09")
        let preview = try importer.preview(data: csv(oldestFirst), fileName: "a.csv", accountId: account)
        #expect(preview.warnings.map(\.kind) == [.ibanMismatch])
        #expect(preview.warnings[0].message.contains(ownIban))
    }

    @Test func windows1252File() throws {
        let (importer, account) = try makeDatabase()
        let line = asn("04-01-2027", "1000.00", "-4.50", seq: "1", name: "Café Tést", text: "Koffie € 4,50")
        let data = try #require((line + "\r\n").data(using: .windowsCP1252))
        #expect(String(data: data, encoding: .utf8) == nil)
        let preview = try importer.preview(data: data, fileName: "cp.csv", accountId: account)
        #expect(preview.encodingName == "Windows-1252")
        #expect(preview.rows[0].counterpartyName == "Café Tést")
        #expect(preview.rows[0].descriptionText == "Koffie € 4,50")
    }

    @Test func genericProfileWithHeaderAndAfBij() throws {
        let (importer, account) = try makeDatabase()
        let text = """
        "Datum";"Naam / Omschrijving";"Rekening";"Tegenrekening";"Code";"Af Bij";"Bedrag (EUR)";"Mededelingen";"Saldo na mutatie"
        "20270105";"Werkgever Test";"\(ownIban)";"NL00TEST0000000003";"GT";"Bij";"100,00";"Salaris; januari";"1.074,50"
        "20270104";"Bakkerij Test";"\(ownIban)";"NL00TEST0000000002";"BA";"Af";"25,50";"Brood";"974,50"
        """
        let preview = try importer.preview(data: Data(text.utf8), fileName: "g.csv", accountId: account)
        #expect(preview.profile.id == "generic")
        #expect(preview.errors.isEmpty)
        #expect(preview.rows.map(\.amount.cents) == [10000, -2550])
        #expect(preview.rows.map(\.lineNumber) == [2, 3])
        #expect(preview.rows[0].descriptionText == "Salaris; januari")
        #expect(preview.rows[1].counterpartyName == "Bakkerij Test")
        #expect(preview.rows[1].counterpartyIban == "NL00TEST0000000002")
        #expect(preview.rows[1].balanceBefore == Money(euros: 1000))
        #expect(preview.chainOK == true)
        #expect(preview.openingBalance == Money(euros: 1000))
        #expect(preview.closingBalance == Money(cents: 107450))
        #expect(preview.warnings.isEmpty)
    }

    @Test func unknownIndicatorIsARowError() throws {
        let (importer, account) = try makeDatabase()
        let text = "Datum;Af Bij;Bedrag\n04-01-2027;Af;1,00\n05-01-2027;??;2,00\n"
        let preview = try importer.preview(data: Data(text.utf8), fileName: "g.csv", accountId: account)
        #expect(preview.rows.count == 1)
        #expect(preview.errors.map(\.lineNumber) == [3])
        #expect(preview.chainOK == nil)
    }

    @Test func customProfileByHeaderName() throws {
        let (importer, account) = try makeDatabase()
        let profile = BankProfile(id: "eigen", name: "Eigen", hasHeader: true, day: .header("Boekdag"),
                                  dateFormats: ["yyyy-MM-dd"], amount: .header("Som"),
                                  debitCredit: DebitCreditIndicator(column: .header("D/C"), debitValues: ["D"], creditValues: ["C"]),
                                  description: [.header("tekst")])
        let text = "Som,D/C,Boekdag,Tekst\n12.00,D,2027-01-04,Test\n"
        let preview = try importer.preview(data: Data(text.utf8), fileName: "e.csv", accountId: account, profile: profile)
        #expect(preview.rows.map(\.amount.cents) == [-1200])
        #expect(preview.rows[0].descriptionText == "Test")

        var wrong = profile
        wrong.amount = .header("Bedrag")
        #expect(throws: ImportError.columnNotFound("Bedrag")) {
            try importer.preview(data: Data(text.utf8), fileName: "e.csv", accountId: account, profile: wrong)
        }
    }

    @Test func fingerprintIsStable() {
        let day = Day(year: 2027, month: 1, day: 4)!
        func make(_ occurrence: Int, amount: Int64 = -100) -> String {
            Fingerprint.make(accountId: 1, day: day, amount: Money(cents: amount), counterpartyIban: "nl00 test 0000000002",
                             sequence: "7", statementNumber: "1", description: "Test", occurrence: occurrence)
        }
        #expect(make(0) == make(0))
        #expect(make(0).count == 64)
        #expect(make(0) != make(1))
        #expect(make(0) != make(0, amount: -101))
        #expect(make(0) == Fingerprint.make(accountId: 1, day: day, amount: Money(cents: -100),
                                            counterpartyIban: "NL00TEST0000000002", sequence: "7",
                                            statementNumber: "1", description: "Test"))
    }
}

@Suite struct CommitTests {
    @Test func commitWritesBatchAndTransactions() throws {
        let (importer, account) = try makeDatabase()
        let result = try importer.importFile(data: csv(oldestFirst.reversed()), fileName: "jan.csv", accountId: account)
        #expect(result.transactions.count == 3 && result.duplicateCount == 0)
        let (batches, transactions) = try importer.database.read { db in
            (try ImportBatch.fetchAll(db), try BankTransaction.order(Column("id")).fetchAll(db))
        }
        #expect(batches.count == 1)
        let batch = batches[0]
        #expect(batch.accountId == account && batch.fileName == "jan.csv")
        #expect(batch.rowCount == 3 && batch.newCount == 3 && batch.duplicateCount == 0)
        #expect(batch.firstDay == Day(year: 2027, month: 1, day: 4) && batch.lastDay == Day(year: 2027, month: 1, day: 6))
        #expect(batch.openingBalance == Money(euros: 1000) && batch.closingBalance == Money(cents: 106450))
        #expect(batch.chainOK)
        // Van oud naar nieuw opgeslagen, ook al stond het bestand andersom.
        #expect(transactions.map(\.sequence) == ["101", "102", "103"])
        #expect(transactions.allSatisfy { $0.status == .nieuw && $0.batchId == batch.id && $0.accountId == account })
        #expect(transactions[1].amount == Money(euros: 100))
        #expect(transactions[1].counterpartyName == "Werkgever Test")
        #expect(transactions[1].balanceBefore == Money(cents: 97450))
        #expect(Set(transactions.map(\.fingerprint)).count == 3)
    }

    @Test func reimportImportsNothing() throws {
        let (importer, account) = try makeDatabase()
        try importer.importFile(data: csv(oldestFirst), fileName: "a.csv", accountId: account)
        // Dezelfde regels, andere volgorde.
        let again = try importer.preview(data: csv(oldestFirst.reversed()), fileName: "a.csv", accountId: account)
        #expect(again.newCount == 0 && again.duplicateCount == 3)
        #expect(again.rows.allSatisfy { $0.isDuplicate })
        let result = try importer.commit(again)
        #expect(result.transactions.isEmpty && result.duplicateCount == 3)
        #expect(result.batch.newCount == 0 && result.batch.duplicateCount == 3)
        #expect(try count(importer, "bankTransaction") == 3)
    }

    @Test func overlappingFileImportsOnlyNewRows() throws {
        let (importer, account) = try makeDatabase()
        try importer.importFile(data: csv(Array(oldestFirst.prefix(2))), fileName: "a.csv", accountId: account)
        let more = oldestFirst.suffix(2) + [asn("07-01-2027", "1064.50", "-4.50", seq: "104")]
        let result = try importer.importFile(data: csv(Array(more)), fileName: "b.csv", accountId: account)
        #expect(result.transactions.map(\.sequence) == ["103", "104"])
        #expect(result.duplicateCount == 1)
        #expect(result.batch.rowCount == 3 && result.batch.newCount == 2)
        #expect(try count(importer, "bankTransaction") == 4)
        #expect(try count(importer, "importBatch") == 2)
    }

    @Test func identicalRowsBothImport() throws {
        let (importer, account) = try makeDatabase()
        // Twee keer precies dezelfde regel op één dag (geen saldo, geen volgnummer).
        let text = "Datum;Naam;Bedrag;Omschrijving\n04-01-2027;Kiosk Test;-2,50;Koffie\n04-01-2027;Kiosk Test;-2,50;Koffie\n"
        let preview = try importer.preview(data: Data(text.utf8), fileName: "a.csv", accountId: account)
        #expect(preview.rows.count == 2)
        #expect(preview.rows[0].fingerprint != preview.rows[1].fingerprint)
        #expect(try importer.commit(preview).transactions.count == 2)
        #expect(try importer.importFile(data: Data(text.utf8), fileName: "a.csv", accountId: account).transactions.isEmpty)
        // Een later bestand met een derde gelijke regel: alleen die ene is nieuw.
        let three = text + "04-01-2027;Kiosk Test;-2,50;Koffie\n"
        #expect(try importer.importFile(data: Data(three.utf8), fileName: "b.csv", accountId: account).transactions.count == 1)
        #expect(try count(importer, "bankTransaction") == 3)
    }

    @Test func sameRowsOnOtherAccountAreNotDuplicates() throws {
        let (importer, account) = try makeDatabase()
        let other = try importer.database.write { db -> Int64 in
            var a = Account(name: "Spaarrekening", iban: nil, kind: .spaar, openingDate: Day(year: 2027, month: 1, day: 1)!)
            try a.insert(db)
            return a.id!
        }
        try importer.importFile(data: csv(oldestFirst), fileName: "a.csv", accountId: account)
        #expect(try importer.preview(data: csv(oldestFirst), fileName: "a.csv", accountId: other).newCount == 3)
    }

    @Test func faultyRowBlocksImport() throws {
        let (importer, account) = try makeDatabase()
        var lines = oldestFirst
        lines.insert("05-01-2027,\(ownIban),NL00TEST0000000004,'Fout Test',,,,EUR,974.50,EUR,abc,,,,,9,,'x',1", at: 1)
        lines.append("geen transactie")
        let preview = try importer.preview(data: csv(lines), fileName: "fout.csv", accountId: account)
        #expect(preview.rows.count == 3)
        #expect(preview.errors.map(\.lineNumber) == [2, 5])
        #expect(preview.errors[0].message == "Ongeldig bedrag \"abc\".")
        #expect(preview.errors[0].description.hasPrefix("Regel 2: "))
        #expect(preview.errors[1].message.contains("1 kolom"))
        #expect(preview.rowCount == 5 && !preview.canCommit)

        #expect(throws: ImportError.rowErrors(2)) { try importer.commit(preview) }
        #expect(try count(importer, "bankTransaction") == 0)
        #expect(try count(importer, "importBatch") == 0)
        #expect(ImportError.rowErrors(2).errorDescription?.contains("2 regels") == true)

        let result = try importer.commit(preview, skipFaultyRows: true)
        #expect(result.transactions.count == 3 && result.skippedErrorCount == 2)
        #expect(result.batch.rowCount == 5 && result.batch.newCount == 3)
    }

    @Test func invalidDateIsReported() throws {
        let (importer, account) = try makeDatabase()
        let lines = oldestFirst + [asn("31-02-2027", "1064.50", "-1.00", seq: "104")]
        let preview = try importer.preview(data: csv(lines), fileName: "a.csv", accountId: account)
        #expect(preview.errors.map(\.lineNumber) == [4])
        #expect(preview.errors[0].message == "Ongeldige datum \"31-02-2027\".")
    }

    @Test func failureDuringCommitRollsBackEverything() throws {
        let (importer, account) = try makeDatabase()
        var preview = try importer.preview(data: csv(oldestFirst), fileName: "a.csv", accountId: account)
        // Forceer een fout halverwege: twee regels met dezelfde vingerafdruk.
        preview.rows[2].fingerprint = preview.rows[0].fingerprint
        #expect(throws: (any Error).self) { try importer.commit(preview) }
        #expect(try count(importer, "bankTransaction") == 0)
        #expect(try count(importer, "importBatch") == 0)
    }

    @Test func emptyAndUnknownFiles() throws {
        let (importer, account) = try makeDatabase()
        #expect(throws: ImportError.emptyFile) {
            try importer.preview(data: Data("\r\n\r\n".utf8), fileName: "leeg.csv", accountId: account)
        }
        #expect(throws: ImportError.noProfile) {
            try importer.preview(data: Data("x;y\n1;2\n".utf8), fileName: "x.csv", accountId: account)
        }
        #expect(throws: ImportError.accountNotFound) {
            try importer.preview(data: csv(oldestFirst), fileName: "a.csv", accountId: 999)
        }
    }
}
