import Foundation
import Testing
import GRDB
import HFCore
@testable import HFHistory

/// Importeren tot en met een maand, saldo per maandeinde en de samenvatting zonder labels.
@Suite struct LimitTests {
    let today = day(2020, 6, 10)

    func richYear(dated: Bool = false) throws -> HistoryYear {
        try #require(try TestWorkbook.budget([RichYear(datedVarious: dated).sheet()]).year(2020))
    }

    func makeDatabase() throws -> (AppDatabase, Int64) {
        let db = try AppDatabase.inMemory()
        return try db.write { d in
            var betaal = Account(name: "Betaal", iban: "NL00TEST0000000001", kind: .betaal, openingDate: day(2009, 1, 1))
            try betaal.insert(d)
            return (db, betaal.id!)
        }
    }

    @Test func saldoPerMaandeindeKloptMetHandberekening() throws {
        let year = try richYear()
        // jan: 2500 − 900 − 300 = +1300 · feb: 2500 − 900 = +1600 · mrt: −120,10 − 60 · apr: −45,50
        // mei: +150 · jun: +400 · jul: −25 · aug: −35
        #expect(year.balanceThrough(month: 0) == eur(1000))
        #expect(year.balanceThrough(month: 1) == eur(2300))
        #expect(year.balanceThrough(month: 2) == eur(3900))
        #expect(year.balanceThrough(month: 3) == eur(3719.90))
        #expect(year.balanceThrough(month: 4) == eur(3674.40))
        #expect(year.balanceThrough(month: 6) == eur(4224.40))
        #expect(year.balanceThrough(month: 12) == eur(4164.40))
        #expect(year.monthEndBalances?.count == 12)
        #expect(year.monthEndBalances?[7] == eur(4164.40))
        #expect(year.balanceThrough(month: 12) == year.computedClosing)

        #expect(year.entryCount(through: 4) == 8)
        #expect(year.excludedCount(through: 4) == 4)
        #expect(year.entryCount(through: nil) == 12)
        #expect(year.excludedCount(through: nil) == 0)
        // De controle tegen het blad gaat altijd over het hele jaar.
        #expect(year.totalsMatch)
        #expect(year.computedIncome == eur(5550))
    }

    @Test func grensLaatLatereMaandenWeg() throws {
        let (db, betaal) = try makeDatabase()
        let year = try richYear()
        let result = try HistoryImporter.importBudget(years: [year], into: db, accountId: betaal,
                                                      throughMonth: [2020: 4], today: today)
        #expect(result.entryCount == 8)
        #expect(result.itemCount == 6)      // posten en plan komen gewoon mee
        try db.read { d in
            let entries = try Entry.fetchAll(d)
            #expect(entries.count == 8)
            #expect(entries.allSatisfy { $0.day.month <= 4 })
            #expect(!entries.contains { $0.label == "Verkoop fiets" || $0.label == "Cadeau" })
            #expect(entries.map(\.amount).sum() + eur(1000) == year.balanceThrough(month: 4))
            #expect(try BudgetItem.fetchCount(d) == 6)
            #expect(try BudgetYear.fetchOne(d)?.closed == false)   // het jaar van vandaag blijft open
        }
    }

    @Test func andereGrensVervangtDeVorigeImport() throws {
        let (db, betaal) = try makeDatabase()
        let year = try richYear()
        try HistoryImporter.importBudget(years: [year], into: db, accountId: betaal, throughMonth: [2020: 4], today: today)
        try HistoryImporter.importBudget(years: [year], into: db, accountId: betaal, throughMonth: [2020: 7], today: today)
        try db.read { d in try #expect(try Entry.fetchCount(d) == 11) }
        try HistoryImporter.importBudget(years: [year], into: db, accountId: betaal, throughMonth: [2020: 0], today: today)
        try db.read { d in
            try #expect(try Entry.fetchCount(d) == 0)
            try #expect(try BudgetItem.fetchCount(d) == 6)
        }
        try HistoryImporter.importBudget(years: [year], into: db, accountId: betaal, today: today)
        try db.read { d in try #expect(try Entry.fetchCount(d) == 12) }
        #expect(throws: HistoryError.invalidThroughMonth(year: 2020, month: 13)) {
            try HistoryImporter.importBudget(years: [year], into: db, accountId: betaal, throughMonth: [2020: 13], today: today)
        }
    }

    @Test func losseRegelMetDatumNaDeGrensBlijftBuiten() throws {
        // Het bedrag staat in de kolom maart, de datum in kolom B is 2 mei.
        var sheet = RichYear().sheet()
        sheet.set(17, 2, .date(day(2020, 5, 2)))
        let year = try #require(try TestWorkbook.budget([sheet]).year(2020))
        let fuel = try #require(year.various.first { $0.label == "Tankbeurt" })
        #expect(fuel.month == 3)
        #expect(fuel.day == day(2020, 5, 2))
        #expect(fuel.lastMonth == 5)
        #expect(year.entryCount(through: 4) == 7)
        #expect(year.balanceThrough(month: 4) == eur(3734.40))   // 3674,40 zonder de −60

        let (db, betaal) = try makeDatabase()
        try HistoryImporter.importBudget(years: [year], into: db, accountId: betaal, throughMonth: [2020: 4], today: today)
        try db.read { d in
            try #expect(try Entry.filter(Column("label") == "Tankbeurt").fetchCount(d) == 0)
            try #expect(try Entry.fetchCount(d) == 7)
        }
    }

    @Test func standaardIsHetHeleBladOokVoorHetLopendeJaar() throws {
        let year = try richYear()
        // Vandaag in augustus of later: er staat niets na de maand van vandaag → geen grens.
        #expect(year.suggestedThroughMonth(today: day(2020, 8, 3)) == nil)
        #expect(year.suggestedThroughMonth(today: day(2020, 12, 31)) == nil)
        // Een ander jaar krijgt nooit een grens.
        #expect(year.suggestedThroughMonth(today: day(2021, 2, 1)) == nil)
        #expect(year.suggestedThroughMonth(today: day(2019, 2, 1)) == nil)
    }

    @Test func bedragenNaVandaagWordenGemeldEnStaanStandaardUit() throws {
        let year = try richYear()
        // Vandaag is 10 juni: juli (−25) en augustus (−35) liggen in de toekomst.
        let later = year.amountsAfter(month: today.month)
        #expect(later.count == 2)
        #expect(later.months == [7, 8])
        #expect(year.suggestedThroughMonth(today: today) == 6)
        #expect(year.balanceThrough(month: 6) == eur(4224.40))
        #expect(year.amountsAfter(month: 8).count == 0)
    }

    @Test func grensTeltMeeBijHetVerschuivenVanDeBegindatum() throws {
        let db = try AppDatabase.inMemory()
        let betaal = try db.write { d -> Int64 in
            var account = Account(name: "Betaal", kind: .betaal, openingBalance: eur(3674.40), openingDate: day(2020, 11, 1))
            try account.insert(d)
            return account.id!
        }
        let year = try richYear()
        let limited = try db.read { try HistoryImporter.checkBudget($0, years: [year], accountId: betaal, throughMonth: [2020: 4]) }
        #expect(limited.openingChange?.balanceAtOldDate == eur(3674.40))
        #expect(limited.openingChange?.difference == .zero)
        let whole = try db.read { try HistoryImporter.checkBudget($0, years: [year], accountId: betaal) }
        #expect(whole.openingChange?.balanceAtOldDate == eur(4164.40))
    }

    @Test func samenvattingBevatGeenLabels() throws {
        let budget = try TestWorkbook.budget([RichYear(statedIncome: 5560).sheet(),
                                              SimpleYear(name: "2019 Geheimebank", opening: 5).sheet(),
                                              SimpleYear(name: "2019 Anderebank", opening: 7).sheet(),
                                              TSheet("Privénotities")])
        let text = budget.summary(today: today)
        for secret in ["Salaris", "Huur", "Hulpregel", "Tankbeurt", "Cadeau", "Tanken", "Uit eten", "Energie",
                       "Geheimebank", "Anderebank", "Privénotities", "Verkoop"] {
            #expect(!text.contains(secret), "samenvatting bevat ‘\(secret)’")
        }
        #expect(text.contains("2020 — 1 blad — totalen KLOPPEN NIET"))
        #expect(text.contains("posten: 4 vast + 2 RES; regels: 6 grid + 6 los = 12 (6 los zonder datum)"))
        #expect(text.contains("IN:   blad € 5.560,00, berekend € 5.550,00"))
        #expect(text.contains("VERSCHIL inkomsten: berekend € 5.550,00, blad € 5.560,00, verschil -€ 10,00"))
        #expect(text.contains("jan 2.300,00 | feb 3.900,00"))
        #expect(text.contains("hulprij: 1 (rij 4)"))
        #expect(text.contains("totaalrij: 2 (rij 15, rij 20)"))
        #expect(text.contains("volgkolom-ongelijk: 1 (rij 19)"))
        #expect(text.contains("NA VANDAAG: 2 bedragen in maand 7, 8"))
        #expect(text.contains("grens t/m maand 6: 10 regels mee, 2 buiten de import; saldo na import € 4.224,40"))
        #expect(text.contains("2019 — 2 bladen"))
        #expect(text.contains("blad zonder jaartal: niet ingelezen: geen jaarblad"))

        let savings = try TestWorkbook.savings([SavingsReadTests.sheet(statedAuto: 300), TSheet("Geheim blad")])
        let savingsText = savings.summary
        for secret in ["Auto", "Vakantie", "Kleding", "Geheim"] { #expect(!savingsText.contains(secret)) }
        #expect(savingsText.contains("pot 1: 3 mutaties, som € 250,00, blad € 300,00 — VERSCHIL -€ 50,00"))
        #expect(savingsText.contains("pot 2: 3 mutaties, som € 169,70, blad € 169,70 — klopt"))
        #expect(savingsText.contains("gestopt bij rij: 6"))
    }
}
