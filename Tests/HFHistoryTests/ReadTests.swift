import Foundation
import Testing
import HFCore
@testable import HFHistory

@Suite struct XLSXReaderTests {
    @Test func leestTekstGetalDatumEnFormule() throws {
        var s = TSheet("Blad één")
        s.set(1, 1, .text("  gedeelde tekst "))
        s.set(1, 2, .inline("in de cel & meer"))
        s.set(2, 1, .num(12.5))
        s.set(2, 2, .date(day(2021, 3, 9)))
        s.set(2, 3, .monthDate(day(2021, 4, 1)))
        s.set(2, 4, .rawDate(day(2021, 4, 1)))
        s.set(3, 28, .formula("A2*2", 25))
        let url = try TestWorkbook.write([s, TSheet("Leeg")])
        defer { TestWorkbook.cleanUp(url) }

        let workbook = try XLSXWorkbook.read(url)
        #expect(workbook.sheets.map(\.name) == ["Blad één", "Leeg"])
        let sheet = workbook.sheets[0]
        #expect(sheet[1, 1].text == "gedeelde tekst")
        #expect(sheet[1, 2].text == "in de cel & meer")
        #expect(sheet[2, 1].value == .number(12.5))
        #expect(sheet[2, 2].day == day(2021, 3, 9))
        #expect(sheet[2, 3].day == day(2021, 4, 1))
        #expect(sheet[2, 4].day == nil)
        #expect(sheet[2, 4].number == XLSXWorkbook.serial(for: day(2021, 4, 1)))
        #expect(sheet[3, 28].number == 25)
        #expect(sheet[3, 28].hasFormula)
        #expect(!sheet[2, 1].hasFormula)
        #expect(sheet[9, 9].isEmpty)
        #expect(sheet.maxRow == 3)
        #expect(sheet.maxColumn == 28)
        #expect(workbook.sheets[1].maxRow == 0)
    }

    @Test func ruimtDeTijdelijkeMapOp() throws {
        let fm = FileManager.default
        let url = try TestWorkbook.write([TSheet("A")])
        defer { TestWorkbook.cleanUp(url) }
        // Een eigen, lege map voor de tijdelijke kopie: na het lezen moet die weer leeg zijn.
        let root = url.deletingLastPathComponent().appendingPathComponent("tmp", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        _ = try XLSXWorkbook.read(url, temporaryRoot: root)
        #expect(try fm.contentsOfDirectory(atPath: root.path).isEmpty)
        // Ook als het lezen mislukt.
        let broken = root.deletingLastPathComponent().appendingPathComponent("kapot.xlsx")
        try Data("geen zip".utf8).write(to: broken)
        #expect(throws: XLSXError.self) { try XLSXWorkbook.read(broken, temporaryRoot: root) }
        #expect(try fm.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test func weigertEenBestandDatGeenXlsxIs() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hfhistory-test-\(UUID().uuidString).xlsx")
        try Data("geen zip".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: XLSXError.notAnXLSX(url.lastPathComponent)) { try XLSXWorkbook.read(url) }
        #expect(throws: XLSXError.fileMissing("bestaat-niet.xlsx")) {
            try XLSXWorkbook.read(URL(fileURLWithPath: "/nonexistent/bestaat-niet.xlsx"))
        }
    }

    @Test func herkentDatumopmaak() {
        #expect(XLSXWorkbook.isDateFormat("d-m-yy"))
        #expect(XLSXWorkbook.isDateFormat("[$-413]d\\ mmmm\\ yyyy;@"))
        #expect(XLSXWorkbook.isDateFormat("mmm"))
        #expect(!XLSXWorkbook.isDateFormat("0.00 \"dagen\""))
        #expect(!XLSXWorkbook.isDateFormat("[Red]#,##0.00"))
        #expect(!XLSXWorkbook.isDateFormat("_ € * #,##0.00_ ;_ € * \\-#,##0.00_ "))
        #expect(!XLSXWorkbook.isDateFormat("General"))
    }

    @Test func rekentDatumgetallenOm() {
        #expect(XLSXWorkbook.day(fromSerial: 1, date1904: false) == day(1900, 1, 1))
        #expect(XLSXWorkbook.day(fromSerial: 61, date1904: false) == day(1900, 3, 1))
        #expect(XLSXWorkbook.day(fromSerial: 43831, date1904: false) == day(2020, 1, 1))
        #expect(XLSXWorkbook.day(fromSerial: 43831.75, date1904: false) == day(2020, 1, 1))
        #expect(XLSXWorkbook.day(fromSerial: 42369, date1904: true) == day(2020, 1, 1))
        #expect(XLSXWorkbook.serial(for: day(2020, 1, 1)) == 43831)
    }

    @Test func rondtAfOpCenten() {
        #expect(Money(excel: -120.10000000000001) == eur(-120.10))
        #expect(Money(excel: 0.1 + 0.2) == eur(0.30))
        #expect(Money(excel: 1.005) == eur(1.01))      // binair 1,00499999…; Excel toont 1,01
        #expect(Money(excel: -1.005) == eur(-1.01))
        #expect(Money(excel: 19.999999999999996) == eur(20))
        #expect(!Money.hasSubCents(-120.10000000000001))
        #expect(Money.hasSubCents(33.3333))
    }
}

@Suite struct BudgetReadTests {
    @Test func leestHetGridMetDatumsInDeKop() throws {
        let budget = try TestWorkbook.budget([RichYear().sheet()])
        #expect(budget.unread.isEmpty)
        let year = try #require(budget.year(2020))

        #expect(year.items.map(\.label) == ["Salaris", "Huur", "RESERVERINGEN", "Auto", "Vakantie", "Energie"])
        #expect(year.items.map(\.direction) == [.IN, .UIT, .UIT, .RES, .RES, .UIT])
        #expect(year.items.map(\.plan) == [eur(2500), eur(-900), eur(-300), eur(-200), eur(-100), eur(-120)])
        #expect(year.items.map(\.isReserveTotal) == [false, false, true, false, false, false])

        // Formule met bewaarde waarde in februari.
        #expect(year.items[0].monthAmounts[0] == eur(2500))
        #expect(year.items[0].monthAmounts[1] == eur(2500))
        #expect(year.items[0].monthAmounts[2] == nil)
        // RES-regels: wel label en plan, nooit de maandcellen.
        #expect(year.items[3].monthAmounts.allSatisfy { $0 == nil })
        // Zwevendekommarest afgerond op centen, zonder waarschuwing.
        #expect(year.items[5].monthAmounts[2] == eur(-120.10))
        #expect(!year.warnings.contains { $0.message.contains("decimalen") })

        // Hulprij en totaalrijen zijn overgeslagen en gemeld.
        #expect(year.skippedRows.contains { $0.row == 4 && $0.message.contains("Hulpregel") })
        #expect(year.skippedRows.contains { $0.row == 15 })
        #expect(year.skippedRows.contains { $0.row == 20 })
        #expect(year.skippedRows.count == 3)

        #expect(year.entryCount == 12)
        #expect(year.openingBalance == eur(1000))
        #expect(year.statedIncome == eur(5550))
        #expect(year.statedExpenses == eur(-2385.60))
        #expect(year.statedClosing == eur(4164.40))
        #expect(year.computedIncome == eur(5550))
        #expect(year.computedExpenses == eur(-2385.60))
        #expect(year.computedClosing == eur(4164.40))
        #expect(year.totalsMatch)
        #expect(year.chainDifference == nil)
    }

    @Test func leestMaandnamenAlsTekstVanafKolomDMetNu() throws {
        let budget = try TestWorkbook.budget([RichYear(year: 2012, firstMonthColumn: 4, monthsAsDates: false, planHeader: "nu").sheet()])
        let year = try #require(budget.year(2012))
        #expect(year.items.count == 6)
        #expect(year.items[1].plan == eur(-900))
        #expect(year.items[1].monthAmounts[0] == eur(-900))
        #expect(year.items[5].monthAmounts[2] == eur(-120.10))
        #expect(year.various.count == 6)
        #expect(year.totalsMatch)
    }

    @Test func leestVanafKolomFZonderPlankolom() throws {
        let budget = try TestWorkbook.budget([RichYear(year: 2011, firstMonthColumn: 6, planHeader: nil).sheet()])
        let year = try #require(budget.year(2011))
        // De scenariokolommen C–E tellen niet mee.
        #expect(year.items[0].monthAmounts[0] == eur(2500))
        #expect(year.items.allSatisfy { $0.plan == .zero })
        #expect(year.warnings.contains { $0.message.contains("plan") })
        #expect(year.computedIncome == eur(5550))
        #expect(year.totalsMatch)
    }

    @Test func losseRegelsZonderDatumKomenOpDe15e() throws {
        let year = try #require(try TestWorkbook.budget([RichYear().sheet()]).year(2020))
        #expect(year.various.map(\.label) == ["Verkoop fiets", "Belastingteruggave", "Tankbeurt", "Restaurant", "Cadeau", "Cadeau"])
        #expect(year.various.map(\.section) == [.IN, .IN, .UIT, .UIT, .UIT, .UIT])
        #expect(year.various.map(\.amount) == [eur(150), eur(400), eur(-60), eur(-45.50), eur(-25), eur(-35)])
        #expect(year.various.map(\.day) == [day(2020, 5, 15), day(2020, 6, 15), day(2020, 3, 15), day(2020, 4, 15),
                                             day(2020, 7, 15), day(2020, 8, 15)])
        #expect(year.various.allSatisfy { !$0.dayIsKnown })
        #expect(year.unknownDayCount == 6)
    }

    @Test func losseRegelsMetDatumInKolomB() throws {
        let year = try #require(try TestWorkbook.budget([RichYear(datedVarious: true).sheet()]).year(2020))
        #expect(year.various[0].day == day(2020, 5, 20))
        #expect(year.various[0].dayIsKnown)
        #expect(year.various[2].day == day(2020, 3, 7))
        // Een datum buiten het jaar wordt niet gebruikt en gemeld.
        #expect(year.various[3].day == day(2020, 4, 15))
        #expect(!year.various[3].dayIsKnown)
        #expect(year.warnings.contains { $0.row == 18 && $0.message.contains("buiten 2020") })
        #expect(year.unknownDayCount == 4)
        #expect(year.totalsMatch)
    }

    @Test func volgkolomGelijkAanBedragWordtTag() throws {
        let year = try #require(try TestWorkbook.budget([RichYear().sheet()]).year(2020))
        #expect(year.various[2].tags == ["Tanken"])       // -60 en -60
        #expect(year.various[3].tags == ["Uit eten"])     // -45,50 en +45,50
        #expect(year.various[4].tags.isEmpty)             // 12 is geen van de bedragen
        #expect(year.various[5].tags.isEmpty)
        #expect(year.warnings.contains { $0.row == 19 && $0.message.contains("Tanken") })
        // In het blok IN Various is een afwijkende waarde een losse berekening: stil genegeerd.
        #expect(year.various[1].tags.isEmpty)
        #expect(!year.warnings.contains { $0.row == 14 })
        // Het bedrag in de volgkolom is geen tweede uitgave.
        #expect(year.computedExpenses == eur(-2385.60))
    }

    @Test func totalenDieNietKloppenWordenGemeld() throws {
        let budget = try TestWorkbook.budget([RichYear(statedIncome: 5560, closing: 4000).sheet()])
        let year = try #require(budget.year(2020))
        #expect(!year.totalsMatch)
        #expect(year.differences.map(\.title) == ["Inkomsten", "Eindsaldo"])
        #expect(year.differences[0].computed == eur(5550))
        #expect(year.differences[0].stated == eur(5560))
        #expect(year.differences[0].difference == eur(-10))
        #expect(year.differences[1].difference == eur(164.40))
        #expect(year.differences[0].text.contains("-€ 10,00"))
        // Er is niets rechtgezet.
        #expect(year.computedIncome == eur(5550))
    }

    @Test func positiefBedragBijUitGeeftWaarschuwing() throws {
        // Excel telt hier per blok: de terugbetaling van 30 zit in UIT.
        let sheet = SimpleYear(name: "2016", opening: 100,
                               items: [("IN Loon", 1000, [1: 1000]), ("UIT Verzekering", -50, [1: -50, 2: 30])],
                               incomeVarious: [("Correctie", 3, -5)],
                               statedIncome: 995, statedExpenses: -20).sheet()
        let year = try #require(try TestWorkbook.budget([sheet]).year(2016))
        #expect(year.items[1].monthAmounts[1] == eur(30))
        #expect(year.various[0].amount == eur(-5))
        #expect(year.warnings.contains { $0.message.contains("positief bedrag") })
        #expect(year.warnings.contains { $0.message.contains("negatief bedrag") })
        #expect(year.warnings.contains { $0.message.contains("per blok") })
        #expect(year.totalsMatch)
        // Op teken geteld (zoals de app divers indeelt).
        #expect(year.computedIncome == eur(1030))
        #expect(year.computedExpenses == eur(-55))
    }

    @Test func eindsaldoOngelijkAanVolgendBeginsaldo() throws {
        let a = SimpleYear(name: "2014", opening: 100, items: [("IN Loon", 1000, [1: 1000])]).sheet()   // eind 1100
        let b = SimpleYear(name: "2015", opening: 1100, items: [("UIT Huur", -400, [1: -400])]).sheet() // eind 700
        let c = SimpleYear(name: "2016", opening: 650, items: [("IN Loon", 1000, [1: 1000])]).sheet()
        let budget = try TestWorkbook.budget([c, b, a])
        #expect(budget.years.map(\.year) == [2016, 2015, 2014])
        #expect(budget.year(2015)?.chainDifference == nil)
        #expect(budget.year(2016)?.chainDifference == eur(-50))
        #expect(budget.year(2016)?.warnings.contains { $0.message.contains("eindsaldo van 2015") } == true)
        // Een verschil in de keten is een waarschuwing; de totalen van het jaar zelf kloppen.
        #expect(budget.year(2016)?.totalsMatch == true)
    }

    @Test func oudeEnAfwijkendeBladenWordenNietIngelezen() throws {
        var old = TSheet("2007")
        old.row(1, [.text("Maand"), .text("Bedrag")])
        old.row(2, [.text("januari"), .num(12)])
        var notes = TSheet("Notities")
        notes.set(1, 1, .text("Los lijstje"))
        var broken = RichYear(year: 2015).sheet()
        broken.set(9, 1, .text("Som"))   // geen rij Totaal
        var noMonths = TSheet("2013")
        noMonths.row(1, [nil, .text("plan"), .text("jan"), .text("feb")])

        let budget = try TestWorkbook.budget([RichYear(year: 2019).sheet(), broken, noMonths, old, notes])
        #expect(budget.years.map(\.year) == [2019])
        #expect(budget.unread.count == 4)
        func reason(_ name: String) -> String? { budget.unread.first { $0.name == name }?.reason }
        #expect(reason("2007") == "niet ingelezen: afwijkende indeling")
        #expect(reason("Notities") == "niet ingelezen: geen jaarblad")
        #expect(reason("2015") == "niet ingelezen: geen rij ‘Totaal’ gevonden")
        #expect(reason("2013") == "niet ingelezen: geen twaalf maandkolommen in rij 1")
        #expect(budget.unread.first { $0.name == "2007" }?.year == 2007)
    }

    @Test func tweeBladenVanHetzelfdeJaarWordenSamengevoegd() throws {
        // Tweede helft staat als eerste tabblad; het blad met de vroegste bedragen komt toch eerst.
        let second = SimpleYear(name: "2018 Nieuw", opening: 0,
                                items: [("IN Loon", 1000, [7: 1000, 8: 1000]), ("UIT Huur", -450, [7: -450]),
                                        ("UIT Sport", -20, [9: -20])],
                                incomeVarious: [("Van oude bank", 7, 1300)]).sheet()            // eind 2830
        let first = SimpleYear(name: "2018 Oud", opening: 500,
                               items: [("IN Loon", 1000, [1: 1000, 2: 1000]), ("UIT Huur", -400, [1: -400, 2: -400]),
                                       ("RESERVERINGEN", -100, [1: -100]), ("RES Auto", -100, [:])],
                               expenseVarious: [("Naar nieuwe bank", 6, -1300), ("Fiets", 3, -300)]).sheet()   // eind 0
        let budget = try TestWorkbook.budget([second, first, SimpleYear(name: "2017", opening: 0, closing: 0).sheet()])
        #expect(budget.years.map(\.year) == [2018, 2017])
        let year = try #require(budget.year(2018))
        #expect(year.sheetNames == ["2018 Oud", "2018 Nieuw"])
        #expect(year.items.map(\.label) == ["Loon", "Huur", "RESERVERINGEN", "Auto", "Sport"])
        #expect(year.items[0].monthAmounts.compactMap { $0 }.count == 4)
        #expect(year.items[0].monthAmounts[6] == eur(1000))
        // Verschillend plan: dat van het latere blad, met een melding.
        #expect(year.items[1].plan == eur(-450))
        #expect(year.warnings.contains { $0.message.contains("verschillend plan") })
        #expect(year.various.count == 3)
        #expect(year.openingBalance == eur(500))
        #expect(year.statedIncome == eur(5300))
        #expect(year.statedExpenses == eur(-2970))
        #expect(year.statedClosing == eur(2830))
        #expect(year.computedClosing == eur(2830))
        #expect(year.totalsMatch)
    }

    @Test func tweeBladenDieOpElkaarAansluiten() throws {
        // Het tweede blad begint met het eindsaldo van het eerste: het saldo loopt door, niet optellen.
        let first = SimpleYear(name: "2018 A", opening: 500, items: [("IN Loon", 1000, [1: 1000])]).sheet()       // eind 1500
        let second = SimpleYear(name: "2018 B", opening: 1500, items: [("UIT Huur", -400, [8: -400])],
                                statedIncome: 0).sheet()                                                        // eind 1100
        let year = try #require(try TestWorkbook.budget([first, second]).year(2018))
        #expect(year.openingBalance == eur(500))
        #expect(year.statedClosing == eur(1100))
        #expect(year.computedClosing == eur(1100))
        #expect(year.totalsMatch)
        #expect(year.warnings.contains { $0.message.contains("loopt door") })
    }

    @Test func eenMislukteHelftMaaktHetHeleJaarOnleesbaar() throws {
        var broken = TSheet("2018 B")
        broken.set(1, 1, .text("iets anders"))
        let good = SimpleYear(name: "2018 A", opening: 500, items: [("IN Loon", 1000, [1: 1000])]).sheet()
        let budget = try TestWorkbook.budget([good, broken])
        #expect(budget.years.isEmpty)
        #expect(budget.unread.map(\.name).sorted() == ["2018 A", "2018 B"])
    }

    @Test func jaarUitBladnaam() {
        #expect(HistoryWorkbook.year(fromSheetName: "2019") == 2019)
        #expect(HistoryWorkbook.year(fromSheetName: " 2018 Bank ") == 2018)
        #expect(HistoryWorkbook.year(fromSheetName: "2018b") == nil)
        #expect(HistoryWorkbook.year(fromSheetName: "Notities 2019") == nil)
        #expect(HistoryWorkbook.year(fromSheetName: "20190") == nil)
    }
}

@Suite struct SavingsReadTests {
    static func sheet(statedAuto: Double = 250) -> TSheet {
        var s = TSheet("RES")
        s.row(1, [nil, .text("Auto"), .text("Vakantie"), .text("Kleding")])
        s.row(2, [.date(day(2019, 1, 25)), .num(200), .num(100), nil])
        s.row(3, [nil, nil, .num(-30.300000000000004), .num(50)])                 // zonder datum: hoort bij 25-1
        s.row(4, [.date(day(2019, 2, 25)), .num(200), .num(100), .formula("20+5", 25)])   // één formule: gewone mutatie
        s.row(5, [.date(day(2019, 3, 3)), .num(-150), nil, .num(0)])
        s.row(6, [nil, .formula("SUM(B2:B5)", statedAuto), .formula("SUM(C2:C5)", 169.7), .formula("SUM(D2:D5)", 75)])
        s.row(7, [.text("Controle"), .num(999), .num(999), .num(999)])            // hulprij ná de totalen
        return s
    }

    @Test func leestHetBladRES() throws {
        var other = TSheet("Overzicht")
        other.set(1, 1, .text("iets"))
        let savings = try TestWorkbook.savings([other, Self.sheet()])
        #expect(savings.pots.map(\.name) == ["Auto", "Vakantie", "Kleding"])
        #expect(savings.pots[0].movements == [HistoryMovement(day: day(2019, 1, 25), amount: eur(200), row: 2),
                                              HistoryMovement(day: day(2019, 2, 25), amount: eur(200), row: 4),
                                              HistoryMovement(day: day(2019, 3, 3), amount: eur(-150), row: 5)])
        // Rij zonder datum hoort bij de laatste datum erboven; zwevendekommarest afgerond.
        #expect(savings.pots[1].movements[1] == HistoryMovement(day: day(2019, 1, 25), amount: eur(-30.30), row: 3))
        #expect(savings.pots[2].movements.map(\.amount) == [eur(50), eur(25)])
        // Gestopt bij de rij met formules; de hulprij erna telt niet mee.
        #expect(savings.stoppedAtRow == 6)
        #expect(savings.movementCount == 8)
        #expect(savings.pots.map(\.statedBalance) == [eur(250), eur(169.70), eur(75)])
        #expect(savings.pots.map(\.balance) == [eur(250), eur(169.70), eur(75)])
        #expect(savings.totalsMatch)
        #expect(savings.firstDay == day(2019, 1, 25))
        #expect(savings.lastDay == day(2019, 3, 3))
        #expect(savings.unread.map(\.name) == ["Overzicht"])
    }

    @Test func saldoDatNietKloptWordtGemeld() throws {
        let savings = try TestWorkbook.savings([Self.sheet(statedAuto: 300)])
        #expect(!savings.totalsMatch)
        #expect(savings.differences.count == 1)
        #expect(savings.differences[0].title == "Pot Auto")
        #expect(savings.differences[0].difference == eur(-50))
    }

    @Test func mutatiesBovenDeEersteDatumWordenOvergeslagen() throws {
        var s = TSheet("RES")
        s.row(1, [nil, .text("Auto"), .text("Totaal")])
        s.row(2, [nil, .num(40), .num(40)])
        s.row(3, [.rawDate(day(2019, 1, 25)), .num(10), .num(10)])
        let savings = try TestWorkbook.savings([s])
        #expect(savings.pots.map(\.name) == ["Auto"])            // de kolom Totaal is geen pot
        #expect(savings.pots[0].movements == [HistoryMovement(day: day(2019, 1, 25), amount: eur(10), row: 3)])
        #expect(savings.skippedRows.count == 1)
        #expect(savings.stoppedAtRow == nil)
        #expect(savings.warnings.contains { $0.message.contains("Geen totaalrij") })
    }

    @Test func werkmapZonderBladRES() throws {
        #expect(throws: HistoryReadError.noSavingsSheet) { try TestWorkbook.savings([TSheet("Sparen")]) }
    }
}
