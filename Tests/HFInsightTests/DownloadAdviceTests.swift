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
        #expect(result.instruction == "Bijwerken: download bij de bank de CSV-export (zip, één bestand per rekening) "
                + "van Betaal, van 01-01-2027 tot en met 15-03-2027.")
        #expect(result.note.contains("startdatum van het beginsaldo"))
        #expect(result.note.contains("Overlap kan geen kwaad"))
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
            var t4 = bank(oud.id!, "2026-02-01", 10, "4"); try t4.insert(db)
            return try Insight.downloadAdvice(db, today: d("2027-03-15"))
        }
        let result = try #require(advice)
        #expect(result.accounts.map(\.name) == ["Betaal", "Spaar"])
        #expect(result.accounts.map(\.lastBankDay) == [d("2027-03-12"), d("2027-03-05")])
        #expect(result.from == d("2027-03-05"))
        #expect(result.hasEarlierImport)
        #expect(result.instruction.hasSuffix("van Betaal en Spaar, van 05-03-2027 tot en met 15-03-2027."))
        #expect(result.note.contains("bewust nog een keer"))
        #expect(result.perAccount == "Betaal: laatste banktransactie 12-03-2027\nSpaar: laatste banktransactie 05-03-2027")
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
        let result = try #require(advice)
        #expect(result.from == d("2027-02-01"))
        #expect(result.hasEarlierImport)
    }

    @Test func neverLaterThanToday() throws {
        let db = try AppDatabase.inMemory()
        let advice = try db.write { db -> DownloadAdvice? in
            var a = Account(name: "Betaal", kind: .betaal, openingDate: d("2027-06-01"))
            try a.insert(db)
            return try Insight.downloadAdvice(db, today: d("2027-03-15"))
        }
        let result = try #require(advice)
        #expect(result.from == d("2027-03-15"))
        #expect(result.instruction.hasSuffix("van Betaal, van vandaag (15-03-2027)."))
    }

    @Test func threeAccountsAreListedWithCommasAndEn() throws {
        let db = try AppDatabase.inMemory()
        let advice = try db.write { db -> DownloadAdvice? in
            for (i, name) in ["Betaal", "Spaar", "Kind"].enumerated() {
                var a = Account(name: name, kind: .betaal, openingDate: d("2027-01-01"), sortOrder: i)
                try a.insert(db)
            }
            return try Insight.downloadAdvice(db, today: d("2027-03-15"))
        }
        #expect(try #require(advice).instruction.contains("van Betaal, Spaar en Kind, van 01-01-2027"))
    }

    @Test func noAccountsGivesNoAdvice() throws {
        let db = try AppDatabase.inMemory()
        #expect(try db.read { try Insight.downloadAdvice($0, today: d("2027-03-15")) } == nil)
    }
}
