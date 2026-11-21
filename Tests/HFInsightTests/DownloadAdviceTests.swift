import Testing
import GRDB
import HFCore
@testable import HFInsight

@Suite struct DownloadAdviceTests {
    private func bank(_ accountId: Int64, _ day: String, _ amount: Int64, _ seq: String) -> BankTransaction {
        BankTransaction(accountId: accountId, day: d(day), amount: eur(amount), counterpartyName: "Winkel Voorbeeld",
                        counterpartyIban: "NL00TEST0000000099", sequence: seq, fingerprint: "fp-\(accountId)-\(seq)")
    }

    @Test func withoutImportStartsAtTheOpeningDate() throws {
        let db = try AppDatabase.inMemory()
        let advice = try db.write { db -> DownloadAdvice? in
            var a = Account(name: "Betaal", iban: "NL00TEST0000000001", kind: .betaal, openingDate: d("2027-01-01"))
            try a.insert(db)
            return try Insight.downloadAdvice(db, today: d("2027-03-15"))
        }
        let result = try #require(advice)
        #expect(result.from == d("2027-01-01"))
        #expect(result.through == d("2027-03-15"))
        #expect(result.hasEarlierImport == false)
        #expect(result.accounts.map(\.name) == ["Betaal"])
        #expect(result.accounts[0].lastBankDay == nil)
    }

    @Test func startsAtTheEarliestLastBankDayWithThatDayAsOverlap() throws {
        let db = try AppDatabase.inMemory()
        let advice = try db.write { db -> DownloadAdvice? in
            var betaal = Account(name: "Betaal", iban: "NL00TEST0000000001", kind: .betaal,
                                 openingDate: d("2027-01-01"), sortOrder: 1)
            try betaal.insert(db)
            var spaar = Account(name: "Spaar", iban: "NL00TEST0000000002", kind: .spaar,
                                openingDate: d("2027-01-01"), sortOrder: 2)
            try spaar.insert(db)
            var oud = Account(name: "Oud", kind: .betaal, openingDate: d("2026-01-01"), sortOrder: 3, archived: true)
            try oud.insert(db)
            var t1 = bank(betaal.id!, "2027-03-10", -20, "1"); try t1.insert(db)
            var t2 = bank(betaal.id!, "2027-03-12", -30, "2"); try t2.insert(db)
            var t3 = bank(spaar.id!, "2027-03-05", 50, "3"); try t3.insert(db)
            return try Insight.downloadAdvice(db, today: d("2027-03-15"))
        }
        let result = try #require(advice)
        #expect(result.accounts.map(\.name) == ["Betaal", "Spaar"])
        #expect(result.accounts.map(\.lastBankDay) == [d("2027-03-12"), d("2027-03-05")])
        #expect(result.from == d("2027-03-05"))
        #expect(result.hasEarlierImport)
    }

    @Test func accountWithoutTransactionsCountsFromItsOpeningDate() throws {
        let db = try AppDatabase.inMemory()
        let advice = try db.write { db -> DownloadAdvice? in
            var betaal = Account(name: "Betaal", kind: .betaal, openingDate: d("2027-01-01"), sortOrder: 1)
            try betaal.insert(db)
            var nieuw = Account(name: "Nieuw", kind: .spaar, openingDate: d("2027-02-01"), sortOrder: 2)
            try nieuw.insert(db)
            var t = bank(betaal.id!, "2027-03-10", -20, "1"); try t.insert(db)
            return try Insight.downloadAdvice(db, today: d("2027-03-15"))
        }
        #expect(try #require(advice).from == d("2027-02-01"))
    }

    @Test func noAccountsGivesNoAdvice() throws {
        let db = try AppDatabase.inMemory()
        #expect(try db.read { try Insight.downloadAdvice($0, today: d("2027-03-15")) } == nil)
    }

    @Test func potsAreSortedAlphabeticallyWithinTheirGroup() {
        let pots = [
            Pot(id: 1, accountId: 1, name: "Zorg", kind: .reservering),
            Pot(id: 2, accountId: 1, name: "spaargeld kind", kind: .spaar),
            Pot(id: 3, accountId: 1, name: "auto", kind: .reservering),
            Pot(id: 4, accountId: 1, name: "Buffer", kind: .spaar),
            Pot(id: 5, accountId: 1, name: "Énergie", kind: .reservering),
            Pot(id: 6, accountId: 1, name: "Pot 10", kind: .spaar),
            Pot(id: 7, accountId: 1, name: "Pot 2", kind: .spaar),
        ]
        #expect(Insight.pickerOrder(pots).map(\.name)
                == ["auto", "Énergie", "Zorg", "Buffer", "Pot 2", "Pot 10", "spaargeld kind"])
    }
}
