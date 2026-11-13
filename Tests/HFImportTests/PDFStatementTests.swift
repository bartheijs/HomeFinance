import Foundation
import CoreGraphics
import CoreText
import Testing
import GRDB
import HFCore
@testable import HFImport

// Alle gegevens hieronder zijn verzonnen.

private let savingsIban = "NL00TEST0000000002"

private func header(opening: String = "€ 1.200,00", closing: String = "€ 1.200,98", page: String = "1 van 1") -> [String] {
    [
        "Rekeningafschrift",
        "1-11-2026 t/m 13-11-2026 \(page)",
        "Blad",
        "Spaarrekening naam",
        "NL00 TEST 0000 0000 02",
        "Kredietlimiet € 0,00",
        "Rekeninghouder",
        "A. Voorbeeld",
        "VOORBEELDSTRAAT 1",
        "1234 AB PLAATS",
        "Beginsaldo op 01-11-2026",
        opening,
        "Eindsaldo op 13-11-2026",
        closing,
        "Datum Bij/Af Bedrag (€) Omschrijving",
    ]
}

private let interest = "05-11-2026 Bij 0,98 Rente over positief saldo tot 01-11-26"

private func page(_ lines: [String]) -> String { lines.joined(separator: "\n") }

/// Tekent regels tekst in een PDF, één pagina per lijst.
func makePDF(_ pages: [[String]]) -> Data {
    let data = NSMutableData()
    var box = CGRect(x: 0, y: 0, width: 595, height: 842)
    let context = CGContext(consumer: CGDataConsumer(data: data as CFMutableData)!, mediaBox: &box, nil)!
    let font = CTFontCreateWithName("Helvetica" as CFString, 10, nil)
    for lines in pages {
        context.beginPDFPage(nil)
        var y: CGFloat = 800
        for line in lines {
            let text = NSAttributedString(string: line, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
            context.textPosition = CGPoint(x: 50, y: y)
            CTLineDraw(CTLineCreateWithAttributedString(text), context)
            y -= 16
        }
        context.endPDFPage()
    }
    context.closePDF()
    return data as Data
}

private func makeDatabase(iban: String? = savingsIban) throws -> (BankImporter, Int64) {
    let db = try AppDatabase.inMemory()
    let id = try db.write { db -> Int64 in
        var account = Account(name: "Spaarrekening", iban: iban, kind: .spaar,
                              openingDate: Day(year: 2026, month: 11, day: 1)!)
        try account.insert(db)
        return account.id!
    }
    return (BankImporter(database: db), id)
}

private func account(iban: String? = savingsIban) -> Account {
    Account(id: 1, name: "Spaarrekening", iban: iban, kind: .spaar, openingDate: Day(year: 2026, month: 11, day: 1)!)
}

@Suite struct StatementTextTests {
    @Test func exampleStatement() throws {
        let statement = try StatementParser.parse(pages: [page(header() + [interest])])
        #expect(statement.ownIban == savingsIban)
        #expect(statement.openingBalance == Money(euros: 1200))
        #expect(statement.openingDay == Day(year: 2026, month: 11, day: 1))
        #expect(statement.closingBalance == Money(cents: 120098))
        #expect(statement.closingDay == Day(year: 2026, month: 11, day: 13))
        #expect(statement.errors.isEmpty)
        #expect(statement.lines == [BankStatement.Line(
            lineNumber: 16, day: Day(year: 2026, month: 11, day: 5)!, amount: Money(cents: 98),
            description: ["Rente over positief saldo tot 01-11-26"])])

        let preview = ImportPreview.build(statement: statement, fileName: "a.pdf", account: account())
        #expect(preview.rows.count == 1 && preview.errors.isEmpty)
        #expect(preview.rows[0].balanceBefore == Money(euros: 1200))
        #expect(preview.rows[0].descriptionText == "Rente over positief saldo tot 01-11-26")
        #expect(preview.rows[0].counterpartyIban == "" && preview.rows[0].counterpartyName == "")
        #expect(preview.chainOK == true)
        #expect(preview.openingBalance == Money(euros: 1200) && preview.closingBalance == Money(cents: 120098))
        #expect(preview.warnings.isEmpty)
        #expect(preview.profile.id == "pdf" && preview.encodingName == "PDF")
    }

    @Test func debitLineAndMultilineDescription() throws {
        let lines = header(closing: "€ 1.050,98") + [
            interest,
            "07-11-2026 Af 250,00 Overboeking naar betaalrekening",
            "NL00TEST0000000001 A. Voorbeeld",
            "Kenmerk vakantie 2027",
            "10-11-2026 Bij 1.100,00 Storting",
            "Naam: B. Test",
            "12-11-2026 Af 1.000,00",
        ]
        let statement = try StatementParser.parse(pages: [page(lines)])
        #expect(statement.lines.map(\.amount.cents) == [98, -25000, 110000, -100000])
        #expect(statement.lines[1].description == ["Overboeking naar betaalrekening", "NL00TEST0000000001 A. Voorbeeld",
                                                   "Kenmerk vakantie 2027"])
        #expect(statement.lines[3].description.isEmpty)

        let preview = ImportPreview.build(statement: statement, fileName: "a.pdf", account: account())
        #expect(preview.rows[1].descriptionText
                == "Overboeking naar betaalrekening NL00TEST0000000001 A. Voorbeeld Kenmerk vakantie 2027")
        #expect(preview.rows[1].counterpartyIban == "NL00TEST0000000001")
        #expect(preview.rows[1].counterpartyName == "A. Voorbeeld")
        #expect(preview.rows[2].counterpartyName == "B. Test" && preview.rows[2].counterpartyIban == "")
        #expect(preview.rows.map(\.balanceBefore?.cents) == [120000, 120098, 95098, 205098])
        #expect(preview.chainOK == true)
    }

    @Test func twoPagesSkipHeadersAndFooters() throws {
        let first = header(closing: "€ 1.300,98", page: "1 van 2") + [
            interest,
            "06-11-2026 Bij 50,00 Storting een",
            "vervolg op pagina een",
            "Blad 1 van 2",
        ]
        let second = header(closing: "€ 1.300,98", page: "2 van 2") + [
            "vervolg op pagina twee",
            "08-11-2026 Bij 50,00 Storting twee",
        ]
        let statement = try StatementParser.parse(pages: [page(first), page(second)])
        #expect(statement.lines.count == 3 && statement.errors.isEmpty)
        // De omschrijving loopt door over de paginagrens; de kop van pagina 2 hoort er niet bij.
        #expect(statement.lines[1].description == ["Storting een", "vervolg op pagina een", "vervolg op pagina twee"])
        #expect(statement.lines[2].lineNumber == first.count + header().count + 2)
        let preview = ImportPreview.build(statement: statement, fileName: "a.pdf", account: account())
        #expect(preview.chainOK == true && preview.closingBalance == Money(cents: 130098))
    }

    @Test func closingBalanceMismatch() throws {
        let statement = try StatementParser.parse(pages: [page(header(closing: "€ 1.250,00") + [interest])])
        let preview = ImportPreview.build(statement: statement, fileName: "a.pdf", account: account())
        #expect(preview.chainOK == false)
        #expect(preview.warnings.map(\.kind) == [.chainBroken])
        #expect(preview.warnings[0].message.contains("€ 1.250,00"))
        #expect(preview.warnings[0].message.contains("€ 1.200,98"))
        #expect(preview.closingBalance == Money(euros: 1250))
    }

    @Test func shuffledHeaderLines() throws {
        let lines = [
            "26",
            "Rekeningafschrift",
            "Blad",
            "1-11-2026 t/m 13-11-20 1 van 1",
            "Rekeninghouder",
            "A. Voorbeeld",
            "Beginsaldo op 01-11-2026",
            "Eindsaldo op 13-11-2026",
            "€ 1.200,00",
            "€ 1.150,98",
            "Kredietlimiet € 0,00",
            "VOORBEELDSTRAAT 1",
            "Spaarrekening naam",
            "NL00 TEST 0000 0000 02",
            "Datum Bij/Af Bedrag (€) Omschrijving",
            "07-11-2026 Af 50,00 Opname",
            interest,
        ]
        let statement = try StatementParser.parse(pages: [page(lines)])
        #expect(statement.ownIban == savingsIban)
        #expect(statement.openingBalance == Money(euros: 1200))
        #expect(statement.closingBalance == Money(cents: 115098))
        // Aflopend bestand: de nieuwste regel staat bovenaan.
        let preview = ImportPreview.build(statement: statement, fileName: "a.pdf", account: account())
        #expect(preview.chainOK == true)
        #expect(preview.rowsChronological.map(\.amount.cents) == [98, -5000])
        #expect(preview.rows.map(\.balanceBefore?.cents) == [120098, 120000])
    }

    @Test func unreadableTransactionLinesBecomeErrors() throws {
        let lines = header() + [
            interest,
            "06-11-2026 Bij abc Kapot bedrag",
            "hoort bij de kapotte regel",
            "07-11-2026 Misschien 5,00 Onbekende aanduiding",
            "31-02-2026 Bij 5,00 Bestaat niet",
            "08-11-2026",
        ]
        let statement = try StatementParser.parse(pages: [page(lines)])
        #expect(statement.lines.count == 1)
        #expect(statement.lines[0].description == ["Rente over positief saldo tot 01-11-26"])
        #expect(statement.errors.map(\.lineNumber) == [17, 19, 20, 21])
        #expect(statement.errors[0].message == "Ongeldig bedrag \"abc\".")
        #expect(statement.errors[1].message.contains("af/bij"))
        #expect(statement.errors[2].message.contains("Ongeldige datum"))
        #expect(statement.errors[3].message.contains("geen leesbare transactie"))
    }

    @Test func missingBalancesAndWrongAccount() throws {
        let lines = ["Rekeningafschrift", "NL00 TEST 0000 0000 02", "Datum Bij/Af Bedrag (€) Omschrijving", interest]
        let statement = try StatementParser.parse(pages: [page(lines)])
        let preview = ImportPreview.build(statement: statement, fileName: "a.pdf", account: account(iban: "NL00TEST0000000009"))
        #expect(preview.chainOK == nil && preview.rows[0].balanceBefore == nil)
        #expect(preview.warnings.map(\.kind) == [.ibanMismatch, .chainNotChecked])
    }

    @Test func textWithoutStatementThrows() {
        #expect(throws: ImportError.noTransactionTable) {
            try StatementParser.parse(pages: ["Beste klant,\nHierbij uw jaaroverzicht.\n"])
        }
    }
}

@Suite struct PDFImportTests {
    @Test func readsGeneratedPDF() throws {
        let (importer, account) = try makeDatabase()
        let pdf = makePDF([header() + [interest]])
        #expect(PDFStatement.isPDF(data: pdf, fileName: "zonder-extensie"))
        // Herkend aan de inhoud, ook zonder .pdf in de naam.
        let preview = try importer.preview(data: pdf, fileName: "afschrift", accountId: account)
        #expect(preview.rows.count == 1 && preview.errors.isEmpty)
        #expect(preview.rows[0].day == Day(year: 2026, month: 11, day: 5))
        #expect(preview.rows[0].amount == Money(cents: 98))
        #expect(preview.rows[0].descriptionText == "Rente over positief saldo tot 01-11-26")
        #expect(preview.rows[0].ownIban == savingsIban)
        #expect(preview.openingBalance == Money(euros: 1200) && preview.closingBalance == Money(cents: 120098))
        #expect(preview.chainOK == true && preview.warnings.isEmpty)

        let result = try importer.commit(preview)
        #expect(result.transactions.count == 1)
        #expect(result.transactions[0].status == .nieuw)
        #expect(result.transactions[0].balanceBefore == Money(euros: 1200))
        #expect(result.batch.openingBalance == Money(euros: 1200) && result.batch.closingBalance == Money(cents: 120098))
        #expect(result.batch.chainOK)
    }

    @Test func twoPagePDFAndReimport() throws {
        let (importer, account) = try makeDatabase()
        let first = header(closing: "€ 1.050,98", page: "1 van 2") + [
            interest,
            "07-11-2026 Af 250,00 Overboeking naar betaalrekening",
            "NL00TEST0000000001 A. Voorbeeld",
        ]
        let second = header(closing: "€ 1.050,98", page: "2 van 2") + [
            "10-11-2026 Bij 50,00 Storting",
            "10-11-2026 Bij 50,00 Storting",
        ]
        let pdf = makePDF([first, second])
        let result = try importer.importFile(data: pdf, fileName: "nov.pdf", accountId: account)
        #expect(result.transactions.map(\.amount.cents) == [98, -25000, 5000, 5000])
        #expect(result.transactions[1].counterpartyIban == "NL00TEST0000000001")
        #expect(result.transactions[1].counterpartyName == "A. Voorbeeld")
        #expect(result.batch.chainOK)

        // Hetzelfde afschrift opnieuw: niets nieuw.
        let again = try importer.importFile(data: pdf, fileName: "nov.pdf", accountId: account)
        #expect(again.transactions.isEmpty && again.duplicateCount == 4)

        // Een overlappend afschrift met één nieuwe regel.
        let later = header(opening: "€ 1.200,98", closing: "€ 1.060,98") + [
            "07-11-2026 Af 250,00 Overboeking naar betaalrekening",
            "NL00TEST0000000001 A. Voorbeeld",
            "10-11-2026 Bij 50,00 Storting",
            "10-11-2026 Bij 50,00 Storting",
            "14-11-2026 Bij 10,00 Storting",
        ]
        let overlap = try importer.importFile(data: makePDF([later]), fileName: "nov2.pdf", accountId: account)
        #expect(overlap.transactions.map(\.amount.cents) == [1000] && overlap.duplicateCount == 3)
        let total = try importer.database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM bankTransaction")! }
        #expect(total == 5)
    }

    @Test func pdfWithoutTextOrTable() throws {
        let (importer, account) = try makeDatabase()
        #expect(throws: ImportError.pdfWithoutText) {
            try importer.preview(data: makePDF([[]]), fileName: "scan.pdf", accountId: account)
        }
        #expect(throws: ImportError.noTransactionTable) {
            try importer.preview(data: makePDF([["Beste klant", "Hierbij uw jaaroverzicht"]]), fileName: "brief.pdf", accountId: account)
        }
        #expect(throws: ImportError.pdfUnreadable) {
            try importer.preview(data: Data("geen pdf".utf8), fileName: "kapot.pdf", accountId: account)
        }
        #expect(ImportError.pdfWithoutText.errorDescription?.contains("geen leesbare tekst") == true)
    }
}
