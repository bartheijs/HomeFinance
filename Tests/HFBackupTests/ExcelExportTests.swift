import Foundation
import GRDB
import HFCore
import Testing
@testable import HFBackup

// MARK: - Eenvoudige xlsx-lezer voor de tests

/// Eén teruggelezen cel.
struct ReadCell: Equatable {
    var type: String?
    var style = 0
    var raw: String?
    var formula: String?
    /// Tekst (via de gedeelde teksten) voor tekstcellen.
    var text: String?
    /// Getal in centen voor getalcellen (bedragen hebben hoogstens twee decimalen).
    var cents: Int64? { raw.flatMap { Money(parsing: $0)?.cents } }
}

/// Uitgepakt en ingelezen xlsx-bestand: per tabblad de cellen op verwijzing ("C5").
struct ReadWorkbook {
    var entries: [String] = []
    var sheetNames: [String] = []
    var sheets: [String: [String: ReadCell]] = [:]
    var sheetXML: [String: String] = [:]

    init(_ url: URL) throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("HFBackupTests-xlsx-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(try Self.run("/usr/bin/unzip", ["-t", "-qq", url.path]).status == 0, "geen geldige zip")
        entries = try Self.run("/usr/bin/unzip", ["-Z1", url.path]).output.split(separator: "\n").map(String.init)
        #expect(try Self.run("/usr/bin/unzip", ["-o", "-qq", url.path, "-d", folder.path]).status == 0)

        func parse(_ path: String) throws -> XMLCollector {
            let collector = XMLCollector()
            let parser = XMLParser(data: try Data(contentsOf: folder.appendingPathComponent(path)))
            parser.delegate = collector
            #expect(parser.parse(), "\(path) is geen geldige XML: \(String(describing: parser.parserError))")
            return collector
        }
        // Elk onderdeel moet geldige XML zijn.
        for entry in entries { _ = try parse(entry) }

        let strings = try parse("xl/sharedStrings.xml").strings
        let workbook = try parse("xl/workbook.xml")
        sheetNames = workbook.sheetNames
        for (index, name) in sheetNames.enumerated() {
            let path = "xl/worksheets/sheet\(index + 1).xml"
            var cells = try parse(path).cells
            for (ref, cell) in cells where cell.type == "s" {
                cells[ref]?.text = cell.raw.flatMap(Int.init).map { strings[$0] }
            }
            sheets[name] = cells
            sheetXML[name] = try String(contentsOf: folder.appendingPathComponent(path), encoding: .utf8)
        }
    }

    func cell(_ sheet: String, _ ref: String) -> ReadCell? { sheets[sheet]?[ref] }
    func text(_ sheet: String, _ ref: String) -> String? { cell(sheet, ref)?.text }
    func cents(_ sheet: String, _ ref: String) -> Int64? { cell(sheet, ref)?.cents }
    func formula(_ sheet: String, _ ref: String) -> String? { cell(sheet, ref)?.formula }

    /// Rijnummer van de eerste rij met deze tekst in kolom A.
    func row(_ sheet: String, labelled label: String) -> Int? {
        sheets[sheet]?.filter { $0.key.hasPrefix("A") && $0.value.text == label }
            .compactMap { Int($0.key.dropFirst()) }.min()
    }

    static func run(_ tool: String, _ arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

final class XMLCollector: NSObject, XMLParserDelegate {
    var strings: [String] = []
    var sheetNames: [String] = []
    var cells: [String: ReadCell] = [:]
    private var text = ""
    private var currentRef: String?
    private var current = ReadCell()

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        text = ""
        switch name {
        case "sheet": sheetNames.append(attributes["name"] ?? "")
        case "c":
            currentRef = attributes["r"]
            current = ReadCell(type: attributes["t"], style: Int(attributes["s"] ?? "0") ?? 0)
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        switch name {
        case "si": strings.append(text)
        case "v": current.raw = text
        case "f": current.formula = text
        case "c": if let currentRef { cells[currentRef] = current }
        default: break
        }
    }
}

// MARK: - Kleine verzonnen administratie

func day(_ iso: String) -> Day { Day(iso: iso)! }

/// Het lastige label: tekens die in XML een betekenis hebben.
let trickyLabel = "Bakker <Jansen> & \"zoon\" 'vers'"
let trickyAccount = "Betaal & <test> \"rekening\""

/// Jaar 2027 met twee rekeningen, zes posten, een paar boekingen, twee potten en één vaste storting.
/// De verwachte cijfers staan uitgeschreven bij de tests.
func exportDatabase() throws -> AppDatabase {
    let db = try AppDatabase.inMemory()
    try db.write { d in
        var betaal = Account(name: trickyAccount, iban: "NL00TEST0000000001", kind: .betaal,
                             openingBalance: Money(euros: 1_000), openingDate: day("2027-01-01"), sortOrder: 1)
        try betaal.insert(d)
        var spaar = Account(name: "Spaar", iban: "NL00TEST0000000002", kind: .spaar, openingDate: day("2027-01-01"), sortOrder: 2)
        try spaar.insert(d)
        var year = BudgetYear(year: 2027, antiRood: Money(euros: 500))
        try year.insert(d)

        var auto = Pot(accountId: spaar.id!, name: "Auto", kind: .reservering, monthlyAmount: Money(euros: 100),
                       targetAmount: Money(euros: 1_000), sortOrder: 1, targetDate: day("2027-12-01"))
        try auto.insert(d)
        var vakantie = Pot(accountId: spaar.id!, name: "Vakantie", kind: .spaar, owner: "Ouder 1", sortOrder: 2)
        try vakantie.insert(d)
        var oud = Pot(accountId: spaar.id!, name: "Oude pot", kind: .spaar, sortOrder: 3, archived: true)
        try oud.insert(d)

        func item(_ label: String, _ direction: Direction, _ euros: Int64, _ order: Int, total: Bool = false,
                  pot: Int64? = nil) throws -> Int64 {
            var item = BudgetItem(yearId: year.id!, label: label, direction: direction, planAmount: Money(euros: euros),
                                  isReserveTotal: total, potId: pot, sortOrder: order)
            try item.insert(d)
            return item.id!
        }
        let loon = try item("Loon", .IN, 2_000, 1)
        let huur = try item("Huur", .UIT, -700, 2)
        let verzekering = try item("Verzekering", .UIT, -50, 3)
        _ = try item("RESERVERINGEN", .UIT, 0, 4, total: true)
        _ = try item("Auto", .RES, -100, 5, pot: auto.id)
        _ = try item("Vakantie", .RES, -50, 6, pot: vakantie.id)
        var check = ItemCheck(budgetItemId: verzekering, month: 2)
        try check.insert(d)

        var uitEten = Tag(name: "Uit eten", sortOrder: 1)
        try uitEten.insert(d)
        var cadeau = Tag(name: "Cadeau", sortOrder: 2)
        try cadeau.insert(d)

        @discardableResult
        func entry(_ account: Int64, _ iso: String, _ cents: Int64, _ label: String, item: Int64? = nil, pot: Int64? = nil,
                   loan: Bool = false, period: String? = nil, bank: Bool = false, note: String = "") throws -> Int64 {
            var bankId: Int64?
            if bank {
                var tx = BankTransaction(accountId: account, day: day(iso), amount: Money(cents: cents),
                                         counterpartyName: "Bakkerij Voorbeeld", descriptionText: "Pas 001 <kassa>",
                                         fingerprint: "test-\(iso)-\(cents)", status: .verwerkt)
                try tx.insert(d)
                bankId = tx.id
            }
            var entry = Entry(accountId: account, bankTransactionId: bankId, day: day(iso), amount: Money(cents: cents),
                              label: label, budgetItemId: item, potId: pot, note: note, temporaryLoan: loan, period: period)
            try entry.insert(d)
            return entry.id!
        }
        // Betaalrekening
        try entry(betaal.id!, "2026-12-30", -50_00, "Verzekering januari", item: verzekering, period: "2027-01")
        try entry(betaal.id!, "2027-01-01", -700_00, "Huur", item: huur)
        let bakker = try entry(betaal.id!, "2027-01-10", -45_50, trickyLabel, bank: true, note: "5 > 3 & 2 < 4")
        try entry(betaal.id!, "2027-01-15", 300_00, "Geleend van spaar", loan: true)
        try entry(betaal.id!, "2027-01-25", 2_000_00, "Loon", item: loon)
        try entry(betaal.id!, "2027-02-01", -700_00, "Huur", item: huur)
        try entry(betaal.id!, "2027-02-05", 20_00, "Teruggekregen")
        try entry(betaal.id!, "2027-02-26", -700_00, "Huur maart", item: huur, period: "2027-03")
        try EntryTag(entryId: bakker, tagId: cadeau.id!).insert(d)
        try EntryTag(entryId: bakker, tagId: uitEten.id!).insert(d)
        // Spaarrekening
        try entry(spaar.id!, "2026-12-15", 250_00, "Vakantiegeld", pot: vakantie.id)
        try entry(spaar.id!, "2027-01-01", 400_00, "Beginsaldo Auto", pot: auto.id)
        try entry(spaar.id!, "2027-02-02", 10_00, "Rente")
        try entry(spaar.id!, "2027-03-03", -120_00, "Garage", pot: auto.id)

        var distribution = Distribution(name: "Maandelijkse reservering", accountId: spaar.id!, sourceAccountId: betaal.id)
        try distribution.insert(d)
        var line1 = DistributionLine(distributionId: distribution.id!, potId: auto.id!, amount: Money(euros: 100), sortOrder: 1)
        try line1.insert(d)
        var line2 = DistributionLine(distributionId: distribution.id!, potId: vakantie.id!, amount: Money(euros: 50), sortOrder: 2)
        try line2.insert(d)
    }
    return db
}

let exportMoment = date("2027-06-18 12:00:00")

// MARK: - Tests

@Suite struct ExcelExportTests {
    @Test func fileIsAValidZipWithTheExpectedParts() throws {
        let temp = try TempFolder()
        let url = try Backup.exportYearAsExcel(try exportDatabase(), year: 2027, to: temp.sub("export"), now: exportMoment)

        #expect(url.lastPathComponent == "HomeFinance 2027.xlsx")
        #expect(Backup.excelFileName(year: 2027) == "HomeFinance 2027.xlsx")
        // Een zip begint met "PK".
        #expect(Array(try Data(contentsOf: url).prefix(2)) == [0x50, 0x4B])
        let book = try ReadWorkbook(url)
        #expect(book.entries == [
            "[Content_Types].xml", "_rels/.rels", "xl/workbook.xml", "xl/_rels/workbook.xml.rels", "xl/styles.xml",
            "xl/sharedStrings.xml", "xl/worksheets/sheet1.xml", "xl/worksheets/sheet2.xml", "xl/worksheets/sheet3.xml",
            "xl/worksheets/sheet4.xml", "xl/worksheets/sheet5.xml",
        ])
        #expect(book.sheetNames == ["Maandgrid", "Transacties", "Potten", "Vaste stortingen", "Toelichting"])
        // Nog een keer exporteren vervangt het bestand.
        let again = try Backup.exportYearAsExcel(try exportDatabase(), year: 2027, to: temp.sub("export"), now: exportMoment)
        #expect(again == url)
        #expect(try FileManager.default.contentsOfDirectory(atPath: temp.sub("export").path) == ["HomeFinance 2027.xlsx"])
    }

    @Test func monthGridMatchesHandCalculation() throws {
        let temp = try TempFolder()
        let book = try ReadWorkbook(try Backup.exportYearAsExcel(try exportDatabase(), year: 2027, to: temp.url, now: exportMoment))
        let s = "Maandgrid"

        // Kop: Post | Plan | jan … dec | Jaar, vet.
        #expect(book.text(s, "A1") == "Post" && book.text(s, "B1") == "Plan" && book.text(s, "C1") == "jan")
        #expect(book.text(s, "N1") == "dec" && book.text(s, "O1") == "Jaar")
        #expect(book.cell(s, "A1")?.style == Xlsx.styleBold)

        // Rijen: 2 Inkomsten, 3 Loon, 4 Uitgaven, 5 Huur, 6 Verzekering, 7 RESERVERINGEN, 8 Auto, 9 Vakantie.
        #expect((2...9).map { book.text(s, "A\($0)") }
                == ["Inkomsten", "Loon", "Uitgaven", "Huur", "Verzekering", "RESERVERINGEN", "Auto", "Vakantie"])
        #expect(book.cell(s, "A2")?.style == Xlsx.styleBold)
        #expect(book.cell(s, "A8")?.style == Xlsx.styleIndent)

        // Een maandcel: loon in januari, als echt getal met bedragopmaak.
        let loon = try #require(book.cell(s, "C3"))
        #expect(loon.cents == 2_000_00 && loon.type == nil && loon.style == Xlsx.styleMoney && loon.formula == nil)
        #expect(loon.raw == "2000.00")
        #expect(book.cell(s, "D3") == nil)                       // geen boeking: lege cel
        #expect(book.cents(s, "B5") == -700_00)                  // plan
        // De huur van eind februari telt mee in maart (afwijkende periode).
        #expect(book.cents(s, "C5") == -700_00 && book.cents(s, "D5") == -700_00 && book.cents(s, "E5") == -700_00)
        #expect(book.cell(s, "F5") == nil)
        // De verzekering van 30-12-2026 telt mee in januari 2027; februari is met de hand afgevinkt.
        #expect(book.cents(s, "C6") == -50_00)
        #expect(book.text(s, "D6") == "afgevinkt")
        // RESERVERINGEN: plan = som van de RES-regels; RES-regels tonen alleen hun plan.
        #expect(book.cents(s, "B7") == -150_00 && book.cents(s, "B8") == -100_00)
        #expect(book.cell(s, "C8") == nil && book.cell(s, "O8") == nil)

        // Jaarkolom: SUM over de maanden, met bewaarde uitkomst.
        #expect(book.formula(s, "O3") == "SUM(C3:N3)" && book.cents(s, "O3") == 2_000_00)
        #expect(book.formula(s, "O5") == "SUM(C5:N5)" && book.cents(s, "O5") == -2_100_00)

        // Totaalrijen: 11 Vaste posten, 12 IN divers, 13 UIT divers, 14 Netto divers, 15 Resultaat.
        #expect((11...15).map { book.text(s, "A\($0)") }
                == ["Vaste posten", "IN divers", "UIT divers", "Netto divers", "Resultaat"])
        #expect(book.formula(s, "C11") == "SUM(C3:C9)" && book.cents(s, "C11") == 1_250_00)   // 2000 − 700 − 50
        #expect(book.cents(s, "D11") == -700_00 && book.cents(s, "E11") == -700_00 && book.cents(s, "F11") == 0)
        #expect(book.formula(s, "O11") == "SUM(C11:N11)" && book.cents(s, "O11") == -150_00)
        #expect(book.cents(s, "C12") == 300_00 && book.cents(s, "D12") == 20_00 && book.cents(s, "O12") == 320_00)
        #expect(book.cents(s, "C13") == -45_50 && book.cents(s, "O13") == -45_50)
        #expect(book.formula(s, "C14") == "SUM(C12:C13)" && book.cents(s, "C14") == 254_50)
        #expect(book.formula(s, "C15") == "SUM(C11,C14)" && book.cents(s, "C15") == 1_504_50)
        #expect(book.cents(s, "O15") == 124_50)                  // −150 + 274,50
        #expect(book.cell(s, "C15")?.style == Xlsx.styleMoneyBold)

        // Jaaroverzicht op de exportdag.
        #expect(book.text(s, "A17") == "Jaaroverzicht per")
        #expect(book.cell(s, "B17")?.raw == String(Xlsx.serial(day("2027-06-18"))))
        #expect(book.text(s, "A18") == "Op de rekening op 1-1" && book.cents(s, "B18") == 950_00)   // 1000 − 50
        #expect(book.text(s, "A19") == "IN" && book.cents(s, "B19") == 2_320_00)
        #expect(book.text(s, "A20") == "UIT" && book.cents(s, "B20") == -2_195_50)
        #expect(book.text(s, "A21") == "Op de rekening" && book.cents(s, "B21") == 1_124_50)
        #expect(book.text(s, "A22") == "Anti-rood" && book.cents(s, "B22") == 500_00)
        #expect(book.text(s, "A23") == "Tijdelijk geleend" && book.cents(s, "B23") == 300_00)
        #expect(book.text(s, "A24") == "Besteedbaar" && book.cents(s, "B24") == 324_50)
        #expect(book.formula(s, "B24") == "B21-B22-B23")

        // Eerste rij en eerste kolom bevroren; kolombreedtes gezet.
        let xml = try #require(book.sheetXML[s])
        #expect(xml.contains("<pane xSplit=\"1\" ySplit=\"1\" topLeftCell=\"B2\" activePane=\"bottomRight\" state=\"frozen\"/>"))
        #expect(xml.contains("<col min=\"1\" max=\"1\" width=\"34.0\" customWidth=\"1\"/>"))
    }

    @Test func transactionsListEveryEntryOfTheBudgetYear() throws {
        let temp = try TempFolder()
        let book = try ReadWorkbook(try Backup.exportYearAsExcel(try exportDatabase(), year: 2027, to: temp.url, now: exportMoment))
        let s = "Transacties"

        #expect((0..<14).map { book.text(s, "\(Xlsx.column($0))1") } == [
            "Datum", "Telt mee in", "Rekening", "Omschrijving", "Post of pot", "Divers", "Tags", "Bedrag",
            "Vergoeden uit spaar", "Tijdelijk geleend", "Nagekeken", "Notitie", "Tegenpartij", "Bankomschrijving",
        ])
        // 8 boekingen op de betaalrekening en 3 op de spaarrekening tellen mee in 2027 (die van 15-12-2026 niet).
        let dataRows = Set(try #require(book.sheets[s]).keys.compactMap { Int($0.drop { $0.isLetter }) }).filter { $0 > 1 }
        #expect(dataRows.sorted() == Array(2...12))
        #expect(try #require(book.sheetXML[s]).contains("<autoFilter ref=\"A1:N12\"/>"))

        // Rij 2: op 30-12-2026 betaald, telt mee in januari 2027. De datum is een echte datumcel.
        let first = try #require(book.cell(s, "A2"))
        #expect(first.raw == String(Xlsx.serial(day("2026-12-30"))) && first.style == Xlsx.styleDate && first.type == nil)
        #expect(Xlsx.serial(day("2026-12-30")) == 46_386)
        #expect(book.text(s, "B2") == "2027-01" && book.text(s, "E2") == "Verzekering" && book.text(s, "F2") == "nee")

        // De boeking met lastige tekens blijft heel, met tags, notitie en bankgegevens.
        let bakker = try #require((2...12).first { book.text(s, "D\($0)") == trickyLabel })
        #expect(book.text(s, "C\(bakker)") == trickyAccount)
        #expect(book.text(s, "F\(bakker)") == "ja")
        #expect(book.text(s, "G\(bakker)") == "Uit eten, Cadeau")
        let amount = try #require(book.cell(s, "H\(bakker)"))
        #expect(amount.cents == -45_50 && amount.raw == "-45.50" && amount.style == Xlsx.styleMoney)
        #expect(book.text(s, "L\(bakker)") == "5 > 3 & 2 < 4")
        #expect(book.text(s, "M\(bakker)") == "Bakkerij Voorbeeld" && book.text(s, "N\(bakker)") == "Pas 001 <kassa>")

        // Afwijkende periode: datum 26-02, telt mee in maart.
        let shifted = try #require((2...12).first { book.text(s, "D\($0)") == "Huur maart" })
        #expect(book.cell(s, "A\(shifted)")?.raw == String(Xlsx.serial(day("2027-02-26"))))
        #expect(book.text(s, "B\(shifted)") == "2027-03")
        // Tijdelijk geleend en een boeking op de spaarrekening (pot, geen "divers").
        let loan = try #require((2...12).first { book.text(s, "D\($0)") == "Geleend van spaar" })
        #expect(book.text(s, "J\(loan)") == "ja" && book.text(s, "I\(loan)") == "nee" && book.text(s, "K\(loan)") == "ja")
        let garage = try #require((2...12).first { book.text(s, "D\($0)") == "Garage" })
        #expect(book.text(s, "C\(garage)") == "Spaar" && book.text(s, "E\(garage)") == "Auto" && book.cell(s, "F\(garage)") == nil)
        #expect((2...12).allSatisfy { book.text(s, "D\($0)") != "Vakantiegeld" })
    }

    @Test func potsAndDistributionsMatchHandCalculation() throws {
        let temp = try TempFolder()
        let book = try ReadWorkbook(try Backup.exportYearAsExcel(try exportDatabase(), year: 2027, to: temp.url, now: exportMoment))

        // Potten: 2 rekening, 3 Auto, 4 Vakantie, 5 Totaal potten, 6 Niet toegewezen, 7 Saldo.
        // De gearchiveerde pot zonder saldo staat er niet in.
        let p = "Potten"
        #expect(book.text(p, "D1") == "Saldo op 18-06-2027" && book.text(p, "E1") == "Gestort in 2027")
        #expect((2...7).map { book.text(p, "A\($0)") }
                == ["Spaar", "Auto", "Vakantie", "Totaal potten", "Niet toegewezen", "Saldo Spaar"])
        #expect(book.text(p, "B3") == "reservering" && book.text(p, "C4") == "Ouder 1" && book.cell(p, "C3") == nil)
        #expect(book.cents(p, "D3") == 280_00 && book.cents(p, "E3") == 400_00 && book.cents(p, "F3") == -120_00)
        #expect(book.cents(p, "G3") == 1_000_00)
        #expect(book.cell(p, "H3")?.raw == String(Xlsx.serial(day("2027-12-01"))) && book.cell(p, "H3")?.style == Xlsx.styleDate)
        // Vakantie: € 250 gestort in 2026, dus saldo 250 en niets in 2027.
        #expect(book.cents(p, "D4") == 250_00 && book.cents(p, "E4") == 0 && book.cents(p, "F4") == 0)
        #expect(book.cell(p, "G4") == nil)
        #expect(book.formula(p, "D5") == "SUM(D3:D4)" && book.cents(p, "D5") == 530_00)
        #expect(book.formula(p, "E5") == "SUM(E3:E4)" && book.cents(p, "E5") == 400_00)
        #expect(book.cents(p, "D6") == 10_00)                    // de rente zonder pot
        #expect(book.formula(p, "D7") == "SUM(D5:D6)" && book.cents(p, "D7") == 540_00)

        // Vaste stortingen: 2 naam, 3 en 4 de regels, 5 het totaal.
        let v = "Vaste stortingen"
        #expect(book.text(v, "A2") == "Maandelijkse reservering" && book.text(v, "B2") == "naar Spaar")
        #expect(book.text(v, "B3") == "Auto" && book.cents(v, "C3") == 100_00)
        #expect(book.text(v, "B4") == "Vakantie" && book.cents(v, "C4") == 50_00)
        #expect(book.text(v, "A5") == "Totaal Maandelijkse reservering")
        #expect(book.formula(v, "C5") == "SUM(C3:C4)" && book.cents(v, "C5") == 150_00)

        // Toelichting: datum, jaar en de twee zinnen.
        let t = "Toelichting"
        #expect(book.text(t, "A1") == "HomeFinance 2027")
        #expect(book.cell(t, "B2")?.raw == String(Xlsx.serial(day("2027-06-18"))))
        #expect(book.cell(t, "B3")?.raw == "2027")
        #expect(book.text(t, "A5")?.contains("leesbare kopie") == true && book.text(t, "A5")?.contains("geen back-up") == true)
        #expect(book.text(t, "A6")?.contains("databasebestand") == true)
    }

    @Test func pastYearUsesTheLastDayOfThatYear() throws {
        let temp = try TempFolder()
        let book = try ReadWorkbook(try Backup.exportYearAsExcel(try exportDatabase(), year: 2027, to: temp.url,
                                                                 now: date("2028-02-10 12:00:00")))
        #expect(book.text("Potten", "D1") == "Saldo op 31-12-2027")
        #expect(book.cell("Maandgrid", "B17")?.raw == String(Xlsx.serial(day("2027-12-31"))))
        #expect(book.cell("Toelichting", "B2")?.raw == String(Xlsx.serial(day("2028-02-10"))))
        #expect(book.cents("Potten", "D3") == 280_00)
    }

    @Test func emptyYearGivesHeadersOnly() throws {
        let temp = try TempFolder()
        let db = try AppDatabase.inMemory()
        try db.write { d in
            var year = BudgetYear(year: 2030)
            try year.insert(d)
        }
        let book = try ReadWorkbook(try Backup.exportYearAsExcel(db, year: 2030, to: temp.url, now: exportMoment))

        #expect(book.sheetNames.count == 5)
        // Alleen de kopregel op de lijsten.
        for sheet in ["Transacties", "Potten", "Vaste stortingen"] {
            let rows = Set(try #require(book.sheets[sheet]).keys.compactMap { Int($0.drop { $0.isLetter }) })
            #expect(rows == [1], "\(sheet) heeft meer dan de kopregel")
        }
        // Het maandgrid heeft geen posten; de totaalrijen staan op nul, zonder formule over een leeg bereik.
        let s = "Maandgrid"
        #expect(book.text(s, "A1") == "Post")
        let fixed = try #require(book.row(s, labelled: "Vaste posten"))
        #expect(fixed == 3)
        #expect(book.cents(s, "C\(fixed)") == 0 && book.formula(s, "C\(fixed)") == nil)
        let spendable = try #require(book.row(s, labelled: "Besteedbaar"))
        #expect(book.cents(s, "B\(spendable)") == 0)
    }

    @Test func unknownYearGivesADutchError() throws {
        let temp = try TempFolder()
        let db = try exportDatabase()
        #expect(throws: ExportError.yearNotFound(2031)) {
            try Backup.exportYearAsExcel(db, year: 2031, to: temp.url, now: exportMoment)
        }
        #expect(ExportError.yearNotFound(2031).localizedDescription
                == "Er is geen begroting voor het jaar 2031. Kies een jaar dat in HomeFinance bestaat.")
        #expect(ExportError.writeFailed("x").localizedDescription.contains("kon niet worden geschreven"))
        // Er is niets geschreven.
        #expect(try FileManager.default.contentsOfDirectory(atPath: temp.url.path).isEmpty)
    }

    @Test func demoDataExportsAndTiesToTheDatabase() throws {
        let temp = try TempFolder()
        let (db, summary) = try seeded(testToday)
        let book = try ReadWorkbook(try Backup.exportYearAsExcel(db, year: 2027, to: temp.url, now: exportMoment))

        // "Op de rekening" is het saldo van de betaalrekening; Resultaat over het jaar is wat er bij kwam.
        let s = "Maandgrid"
        let balanceRow = try #require(book.row(s, labelled: "Op de rekening"))
        #expect(book.cents(s, "B\(balanceRow)") == summary.checkingBalance.cents)
        let resultRow = try #require(book.row(s, labelled: "Resultaat"))
        #expect(book.cents(s, "O\(resultRow)") == (summary.checkingBalance - DemoPlan.checkingOpening).cents)
        // De maandtotalen tellen op tot de jaarkolom.
        #expect((2...13).compactMap { book.cents(s, "\(Xlsx.column($0))\(resultRow)") }.reduce(0, +)
                == book.cents(s, "O\(resultRow)"))
        // Eén regel per boeking van het jaar.
        let entries = try db.read { try Entry.fetchCount($0) }
        let rows = Set(try #require(book.sheets["Transacties"]).keys.compactMap { Int($0.drop { $0.isLetter }) })
        #expect(rows.count == entries + 1)
        // Niet toegewezen op de spaarrekening is de rentebijschrijving.
        let unassigned = try #require(book.row("Potten", labelled: "Niet toegewezen"))
        #expect(book.cents("Potten", "D\(unassigned)") == DemoPlan.savingsInterest.cents)
    }

    @Test func writerHelpers() {
        #expect(Xlsx.column(0) == "A" && Xlsx.column(25) == "Z" && Xlsx.column(26) == "AA" && Xlsx.column(701) == "ZZ")
        #expect(Xlsx.ref(2, 5) == "C5")
        #expect(Xlsx.escape("a<b>&\"c\"'\u{01}\n") == "a&lt;b&gt;&amp;&quot;c&quot;&apos;\n")
        #expect(Xlsx.number(Money(cents: -5)) == "-0.05" && Xlsx.number(Money(cents: 123_456)) == "1234.56")
        #expect(Xlsx.serial(Day(year: 1970, month: 1, day: 1)!) == 25_569)
        #expect(Xlsx.serial(Day(year: 2027, month: 1, day: 1)!) == 46_388)
        #expect(Xlsx.sheetName("Naam: met/tekens [en] een hele lange staart erachteraan").count == 31)
        #expect(!Xlsx.sheetName("a/b").contains("/"))
    }
}
