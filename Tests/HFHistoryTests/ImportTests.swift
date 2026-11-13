import Foundation
import Testing
import GRDB
import HFCore
@testable import HFHistory

@Suite struct BudgetImportTests {
    let today = day(2026, 11, 13)

    func makeDatabase(openingDate: Day = day(2009, 1, 1), openingBalance: Money = .zero) throws -> (AppDatabase, Int64, Int64) {
        let db = try AppDatabase.inMemory()
        return try db.write { d in
            var betaal = Account(name: "Betaal", iban: "NL00TEST0000000001", kind: .betaal,
                                 openingBalance: openingBalance, openingDate: openingDate)
            try betaal.insert(d)
            var spaar = Account(name: "Spaar", iban: "NL00TEST0000000002", kind: .spaar, openingDate: openingDate)
            try spaar.insert(d)
            return (db, betaal.id!, spaar.id!)
        }
    }

    func richYear(_ year: Int = 2020, opening: Double = 1000) throws -> HistoryYear {
        try #require(try TestWorkbook.budget([RichYear(year: year, datedVarious: true, opening: opening).sheet()]).year(year))
    }

    @Test func maaktJaarPostenBoekingenEnTags() throws {
        let (db, betaal, _) = try makeDatabase()
        let result = try HistoryImporter.importBudget(years: [try richYear()], into: db, accountId: betaal, today: today)
        #expect(result.years == [2020])
        #expect(result.itemCount == 6)
        #expect(result.entryCount == 12)
        #expect(result.newTagCount == 2)
        #expect(result.openingChange == nil)

        try db.read { d in
            let year = try #require(try BudgetYear.filter(Column("year") == 2020).fetchOne(d))
            #expect(year.closed)

            let items = try BudgetItem.filter(Column("yearId") == year.id!).order(Column("sortOrder")).fetchAll(d)
            #expect(items.map(\.label) == ["Salaris", "Huur", "RESERVERINGEN", "Auto", "Vakantie", "Energie"])
            #expect(items.map(\.direction) == [.IN, .UIT, .UIT, .RES, .RES, .UIT])
            #expect(items.map(\.sortOrder) == [0, 1, 2, 3, 4, 5])
            #expect(items.allSatisfy { $0.frequency == .maand && $0.expectedMonths.isEmpty })
            #expect(items.filter(\.isReserveTotal).map(\.label) == ["RESERVERINGEN"])
            // Plan van RESERVERINGEN = som van de RES-regels.
            #expect(items[2].planAmount == eur(-300))
            #expect(items[0].planAmount == eur(2500))

            let entries = try Entry.order(Column("day"), Column("id")).fetchAll(d)
            #expect(entries.count == 12)
            #expect(entries.allSatisfy { $0.note == "Excel-historie" && $0.reviewed && $0.bankTransactionId == nil && $0.accountId == betaal })
            #expect(entries.map(\.amount).sum() == eur(5550 - 2385.60))

            // Gridboekingen: de 15e, label van de post. RES-regels hebben geen boekingen.
            let grid = entries.filter { $0.budgetItemId != nil }
            #expect(grid.count == 6)
            #expect(grid.allSatisfy { $0.day.day == 15 })
            let energy = try #require(grid.first { $0.budgetItemId == items[5].id })
            #expect(energy.day == day(2020, 3, 15))
            #expect(energy.amount == eur(-120.10))
            #expect(energy.label == "Energie")
            #expect(!grid.contains { $0.budgetItemId == items[3].id || $0.budgetItemId == items[4].id })

            // Losse regels: zonder post, met de datum uit kolom B als die er is.
            let fuel = try #require(entries.first { $0.label == "Tankbeurt" })
            #expect(fuel.budgetItemId == nil)
            #expect(fuel.day == day(2020, 3, 7))
            let tags = try Tag.order(Column("sortOrder")).fetchAll(d)
            #expect(Set(tags.map(\.name)) == ["Tanken", "Uit eten"])
            let fuelTags = try String.fetchAll(d, sql: "SELECT t.name FROM entryTag e JOIN tag t ON t.id = e.tagId WHERE e.entryId = ?", arguments: [fuel.id])
            #expect(fuelTags == ["Tanken"])
            try #expect(try EntryTag.fetchCount(d) == 2)
        }
    }

    @Test func hetJaarVanVandaagBlijftOpen() throws {
        let (db, betaal, _) = try makeDatabase()
        let years = try TestWorkbook.budget([RichYear(year: 2026, opening: 4164.40).sheet(), RichYear(year: 2025).sheet()]).years
        try HistoryImporter.importBudget(years: years, into: db, accountId: betaal, today: today)
        try db.read { d in
            try #expect(try BudgetYear.filter(Column("year") == 2026).fetchOne(d)?.closed == false)
            try #expect(try BudgetYear.filter(Column("year") == 2025).fetchOne(d)?.closed == true)
        }
    }

    @Test func bestaandeTagWordtHergebruikt() throws {
        let (db, betaal, _) = try makeDatabase()
        try db.write { d in
            var tag = Tag(name: "tanken", color: "#112233", sortOrder: 0)
            try tag.insert(d)
        }
        let result = try HistoryImporter.importBudget(years: [try richYear()], into: db, accountId: betaal, today: today)
        #expect(result.newTagCount == 1)
        try db.read { d in try #expect(try Tag.fetchCount(d) == 2) }
    }

    @Test func opnieuwImporterenVervangt() throws {
        let (db, betaal, _) = try makeDatabase()
        try HistoryImporter.importBudget(years: [try richYear()], into: db, accountId: betaal, today: today)
        try db.write { d in
            try d.execute(sql: "UPDATE budgetYear SET antiRood = 50000 WHERE year = 2020")
        }
        // Tweede keer met een gewijzigd blad: een post minder.
        var changed = try richYear()
        changed.items.removeAll { $0.label == "Energie" }
        let check = try db.read { try HistoryImporter.checkBudget($0, years: [changed], accountId: betaal) }
        #expect(check.replaced == [2020])
        #expect(check.refused.isEmpty)

        let result = try HistoryImporter.importBudget(years: [changed], into: db, accountId: betaal, forcedYears: [2020], today: today)
        #expect(result.entryCount == 11)
        try db.read { d in
            try #expect(try Entry.fetchCount(d) == 11)
            try #expect(try BudgetItem.fetchCount(d) == 5)
            try #expect(try BudgetYear.fetchCount(d) == 1)
            try #expect(try EntryTag.fetchCount(d) == 2)
            try #expect(try Tag.fetchCount(d) == 2)
            // Instellingen van het jaar blijven staan.
            try #expect(try BudgetYear.fetchOne(d)?.antiRood == Money(cents: 50000))
        }
    }

    @Test func weigertEenJaarMetEigenBoekingen() throws {
        let (db, betaal, _) = try makeDatabase()
        try db.write { d in
            var own = Entry(accountId: betaal, day: day(2020, 6, 1), amount: eur(-10), label: "Zelf ingevoerd")
            try own.insert(d)
        }
        let years = try TestWorkbook.budget([RichYear(year: 2020).sheet(), RichYear(year: 2019).sheet()]).years
        let check = try db.read { try HistoryImporter.checkBudget($0, years: years, accountId: betaal) }
        #expect(Array(check.refused.keys) == [2020])
        #expect(check.refused[2020]?.contains("1 boeking") == true)

        #expect(throws: HistoryError.yearHasOtherEntries(year: 2020, count: 1)) {
            try HistoryImporter.importBudget(years: years, into: db, accountId: betaal, today: today)
        }
        // Alles of niets: ook 2019 is niet geïmporteerd.
        try db.read { d in
            try #expect(try Entry.fetchCount(d) == 1)
            try #expect(try BudgetYear.fetchCount(d) == 0)
        }
        // Zonder het geweigerde jaar lukt het wel.
        try HistoryImporter.importBudget(years: years.filter { $0.year == 2019 }, into: db, accountId: betaal, today: today)
        try db.read { d in try #expect(try Entry.fetchCount(d) == 13) }
    }

    @Test func weigertTotalenDieNietKloppenTenzijGeforceerd() throws {
        let (db, betaal, _) = try makeDatabase()
        let year = try #require(try TestWorkbook.budget([RichYear(statedIncome: 5560).sheet()]).year(2020))
        #expect(throws: HistoryError.totalsDiffer(year: 2020)) {
            try HistoryImporter.importBudget(years: [year], into: db, accountId: betaal, today: today)
        }
        try db.read { d in try #expect(try Entry.fetchCount(d) == 0) }
        let result = try HistoryImporter.importBudget(years: [year], into: db, accountId: betaal, forcedYears: [2020], today: today)
        #expect(result.entryCount == 12)
    }

    @Test func weigertEenSpaarrekeningEnEenLegeKeuze() throws {
        let (db, betaal, spaar) = try makeDatabase()
        #expect(throws: HistoryError.notACheckingAccount("Spaar")) {
            try HistoryImporter.importBudget(years: [try richYear()], into: db, accountId: spaar, today: today)
        }
        #expect(throws: HistoryError.nothingToImport) {
            try HistoryImporter.importBudget(years: [], into: db, accountId: betaal, today: today)
        }
    }

    @Test func begindatumSchuiftZonderVerschil() throws {
        // De rekening begint op 1-1-2021 met precies het eindsaldo van 2020.
        let (db, betaal, _) = try makeDatabase(openingDate: day(2021, 1, 1), openingBalance: eur(4164.40))
        let year = try richYear()
        let check = try db.read { try HistoryImporter.checkBudget($0, years: [year], accountId: betaal) }
        let change = try #require(check.openingChange)
        #expect(change.oldDate == day(2021, 1, 1))
        #expect(change.newDate == day(2020, 1, 1))
        #expect(change.newBalance == eur(1000))
        #expect(change.balanceAtOldDate == eur(4164.40))
        #expect(change.difference == .zero)

        let result = try HistoryImporter.importBudget(years: [year], into: db, accountId: betaal, today: today)
        #expect(result.openingChange == change)
        try db.read { d in
            let account = try #require(try Account.fetchOne(d, key: betaal))
            #expect(account.openingDate == day(2020, 1, 1))
            #expect(account.openingBalance == eur(1000))
            // Saldo aan het begin van de oude begindatum is ongewijzigd.
            let before = try Money.fetchOne(d, sql: "SELECT COALESCE(SUM(amount), 0) FROM entry WHERE accountId = ? AND day < ?",
                                            arguments: [betaal, day(2021, 1, 1)]) ?? .zero
            #expect(account.openingBalance + before == eur(4164.40))
        }
    }

    @Test func begindatumMetVerschilVraagtBevestiging() throws {
        // Rekening begint midden in 2020 met een saldo dat € 25 afwijkt van wat de historie oplevert.
        // Historie vóór 1-7-2020: 1000 + 5550 − 2385,60 − (juli −25) − (augustus −35) = 4224,40.
        let (db, betaal, _) = try makeDatabase(openingDate: day(2020, 7, 1), openingBalance: eur(4199.40))
        let year = try richYear()
        let check = try db.read { try HistoryImporter.checkBudget($0, years: [year], accountId: betaal) }
        let change = try #require(check.openingChange)
        #expect(change.balanceAtOldDate == eur(4224.40))
        #expect(change.oldBalance == eur(4199.40))
        #expect(change.difference == eur(25))

        #expect(throws: HistoryError.openingBalanceChanges(change)) {
            try HistoryImporter.importBudget(years: [year], into: db, accountId: betaal, today: today)
        }
        try db.read { d in
            try #expect(try Account.fetchOne(d, key: betaal)?.openingDate == day(2020, 7, 1))
            try #expect(try Entry.fetchCount(d) == 0)
        }

        try HistoryImporter.importBudget(years: [year], into: db, accountId: betaal, confirmOpeningChange: true, today: today)
        try db.read { d in
            let account = try #require(try Account.fetchOne(d, key: betaal))
            #expect(account.openingDate == day(2020, 1, 1))
            #expect(account.openingBalance == eur(1000))
            try #expect(try Entry.fetchCount(d) == 12)
        }
    }

    @Test func begindatumBlijftAlsDeHistorieErNietVoorLigt() throws {
        let (db, betaal, _) = try makeDatabase(openingDate: day(2015, 1, 1), openingBalance: eur(77))
        let check = try db.read { try HistoryImporter.checkBudget($0, years: [try richYear()], accountId: betaal) }
        #expect(check.openingChange == nil)
        try HistoryImporter.importBudget(years: [try richYear()], into: db, accountId: betaal, today: today)
        try db.read { d in
            try #expect(try Account.fetchOne(d, key: betaal)?.openingDate == day(2015, 1, 1))
            try #expect(try Account.fetchOne(d, key: betaal)?.openingBalance == eur(77))
        }
    }

    @Test func zonderBeginsaldoKanDeBegindatumNietSchuiven() throws {
        let (db, betaal, _) = try makeDatabase(openingDate: day(2021, 1, 1))
        var year = try richYear()
        year.openingBalance = nil
        let check = try db.read { try HistoryImporter.checkBudget($0, years: [year], accountId: betaal) }
        #expect(check.openingProblem != nil)
        #expect(throws: HistoryError.openingBalanceUnknown(year: 2020)) {
            try HistoryImporter.importBudget(years: [year], into: db, accountId: betaal, forcedYears: [2020], today: today)
        }
    }

    @Test func meerdereJarenSluitenOpElkaarAan() throws {
        let (db, betaal, _) = try makeDatabase(openingDate: day(2022, 1, 1), openingBalance: eur(1000 + 2 * 3164.40))
        let years = try TestWorkbook.budget([RichYear(year: 2021, opening: 4164.40).sheet(), RichYear(year: 2020).sheet()]).years
        #expect(years.allSatisfy { $0.chainDifference == nil })
        let result = try HistoryImporter.importBudget(years: years, into: db, accountId: betaal, today: today)
        #expect(result.years == [2020, 2021])
        #expect(result.openingChange?.difference == .zero)
        #expect(result.entryCount == 24)
    }
}

@Suite struct SavingsImportTests {
    func makeDatabase(openingDate: Day = day(2019, 1, 1), openingBalance: Money = .zero) throws -> (AppDatabase, Int64, Int64) {
        let db = try AppDatabase.inMemory()
        return try db.write { d in
            var betaal = Account(name: "Betaal", iban: "NL00TEST0000000001", kind: .betaal, openingDate: openingDate)
            try betaal.insert(d)
            var spaar = Account(name: "Spaar", iban: "NL00TEST0000000002", kind: .spaar,
                                openingBalance: openingBalance, openingDate: openingDate)
            try spaar.insert(d)
            var pot = Pot(accountId: spaar.id!, name: "AUTO", kind: .spaar, sortOrder: 0)
            try pot.insert(d)
            return (db, betaal.id!, spaar.id!)
        }
    }

    func savings() throws -> HistorySavings { try TestWorkbook.savings([SavingsReadTests.sheet()]) }

    @Test func importeertMutatiesPerPot() throws {
        let (db, _, spaar) = try makeDatabase()
        let check = try db.read { try HistoryImporter.checkSavings($0, savings: try savings(), accountId: spaar) }
        #expect(check.refusal == nil)
        #expect(check.newPots == ["Vakantie", "Kleding"])
        #expect(!check.replaces)
        #expect(check.openingChange == nil)

        let result = try HistoryImporter.importSavings(try savings(), into: db, accountId: spaar)
        #expect(result.entryCount == 8)
        #expect(result.newPotCount == 2)
        try db.read { d in
            let pots = try Pot.order(Column("sortOrder")).fetchAll(d)
            // Bestaande pot op naam gevonden (hoofdletters maken niet uit) en niet gewijzigd.
            #expect(pots.map(\.name) == ["AUTO", "Vakantie", "Kleding"])
            #expect(pots.map(\.kind) == [.spaar, .reservering, .reservering])
            func balance(_ pot: Pot) throws -> Money {
                try Money.fetchOne(d, sql: "SELECT COALESCE(SUM(amount), 0) FROM entry WHERE potId = ?", arguments: [pot.id]) ?? .zero
            }
            try #expect(try pots.map(balance) == [eur(250), eur(169.70), eur(75)])
            let entries = try Entry.fetchAll(d)
            #expect(entries.allSatisfy { $0.accountId == spaar && $0.note == "Excel-historie" && $0.reviewed && $0.budgetItemId == nil })
            #expect(entries.filter { $0.day == day(2019, 1, 25) }.count == 4)
        }

        // Opnieuw importeren vervangt.
        let again = try db.read { try HistoryImporter.checkSavings($0, savings: try savings(), accountId: spaar) }
        #expect(again.replaces)
        #expect(again.newPots.isEmpty)
        try HistoryImporter.importSavings(try savings(), into: db, accountId: spaar)
        try db.read { d in
            try #expect(try Entry.fetchCount(d) == 8)
            try #expect(try Pot.fetchCount(d) == 3)
        }
    }

    @Test func weigertBijBestaandeBeginsaldi() throws {
        let (db, _, spaar) = try makeDatabase()
        try db.write { d in
            var opening = Entry(accountId: spaar, day: day(2019, 2, 1), amount: eur(250), label: "Beginsaldo Auto", potId: 1)
            try opening.insert(d)
        }
        let check = try db.read { try HistoryImporter.checkSavings($0, savings: try savings(), accountId: spaar) }
        #expect(check.refusal?.contains("dubbel") == true)
        #expect(throws: HistoryError.savingsHasOtherEntries(count: 1, lastDay: day(2019, 3, 3))) {
            try HistoryImporter.importSavings(try savings(), into: db, accountId: spaar)
        }
        try db.read { d in try #expect(try Entry.fetchCount(d) == 1) }
    }

    @Test func eigenBoekingenNaDeLaatsteDatumZijnGeenBezwaar() throws {
        let (db, _, spaar) = try makeDatabase()
        try db.write { d in
            var later = Entry(accountId: spaar, day: day(2019, 3, 4), amount: eur(10), label: "Later", potId: 1)
            try later.insert(d)
        }
        try HistoryImporter.importSavings(try savings(), into: db, accountId: spaar)
        try db.read { d in try #expect(try Entry.fetchCount(d) == 9) }
    }

    @Test func weigertVerschillenInPotsaldiTenzijToegestaan() throws {
        let (db, _, spaar) = try makeDatabase()
        let wrong = try TestWorkbook.savings([SavingsReadTests.sheet(statedAuto: 300)])
        #expect(throws: HistoryError.savingsTotalsDiffer(count: 1)) {
            try HistoryImporter.importSavings(wrong, into: db, accountId: spaar)
        }
        try HistoryImporter.importSavings(wrong, into: db, accountId: spaar, allowDifferences: true)
        try db.read { d in try #expect(try Entry.fetchCount(d) == 8) }
    }

    @Test func begindatumVanDeSpaarrekening() throws {
        // Rekening begint op 1-3-2019 met € 900. De historie vóór die dag telt op tot 644,70.
        let (db, betaal, spaar) = try makeDatabase(openingDate: day(2019, 3, 1), openingBalance: eur(900))
        let check = try db.read { try HistoryImporter.checkSavings($0, savings: try savings(), accountId: spaar) }
        let change = try #require(check.openingChange)
        #expect(change.newDate == day(2019, 1, 25))
        #expect(change.balanceAtOldDate == eur(644.70))
        #expect(change.difference == eur(-255.30))

        #expect(throws: HistoryError.openingBalanceChanges(change)) {
            try HistoryImporter.importSavings(try savings(), into: db, accountId: spaar)
        }
        #expect(throws: HistoryError.notASavingsAccount("Betaal")) {
            try HistoryImporter.importSavings(try savings(), into: db, accountId: betaal)
        }

        // Het saldo op de oude begindatum houden: het verschil wordt het beginsaldo op de eerste datum.
        let kept = try HistoryImporter.importSavings(try savings(), into: db, accountId: spaar, opening: .keepOldBalance)
        #expect(kept.openingChange?.difference == .zero)
        try db.read { d in
            let account = try #require(try Account.fetchOne(d, key: spaar))
            #expect(account.openingDate == day(2019, 1, 25))
            #expect(account.openingBalance == eur(255.30))
        }
    }

    @Test func begindatumMetNieuwSaldo() throws {
        let (db, _, spaar) = try makeDatabase(openingDate: day(2019, 3, 1), openingBalance: eur(900))
        try HistoryImporter.importSavings(try savings(), into: db, accountId: spaar, opening: .acceptNewBalance)
        try db.read { d in
            let account = try #require(try Account.fetchOne(d, key: spaar))
            #expect(account.openingDate == day(2019, 1, 25))
            #expect(account.openingBalance == .zero)
        }
    }
}
