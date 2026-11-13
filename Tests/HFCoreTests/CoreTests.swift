import Testing
import Foundation
import GRDB
@testable import HFCore

@Suite struct MoneyTests {
    @Test func parsesDutchNotation() {
        #expect(Money(parsing: "-1.234,56")?.cents == -123456)
        #expect(Money(parsing: "45,5")?.cents == 4550)
        #expect(Money(parsing: "€ 12")?.cents == 1200)
        #expect(Money(parsing: "-45.50")?.cents == -4550)
        #expect(Money(parsing: "1.234")?.cents == 123400)
        #expect(Money(parsing: "0,07")?.cents == 7)
        #expect(Money(parsing: "+3,00")?.cents == 300)
        #expect(Money(parsing: "12,50-")?.cents == -1250)
    }

    @Test func rejectsNonsense() {
        #expect(Money(parsing: "") == nil)
        #expect(Money(parsing: "abc") == nil)
        #expect(Money(parsing: "1,234,5") == nil)
        #expect(Money(parsing: "1,999") == nil)
        #expect(Money(parsing: "12.3456") == nil)
    }

    @Test func formats() {
        #expect(Money(cents: -123456).formatted() == "-€ 1.234,56")
        #expect(Money(cents: 7).formatted(symbol: false) == "0,07")
        #expect(Money(cents: 100000000).formatted(symbol: false) == "1.000.000,00")
        #expect(Money(cents: 500).formatted(alwaysSign: true) == "+€ 5,00")
    }

    @Test func sums() {
        #expect([Money(cents: 10), Money(cents: -3)].sum() == Money(cents: 7))
    }
}

@Suite struct DayTests {
    @Test func parsesAndValidates() {
        #expect(Day(dutch: "31-01-2027")?.iso == "2027-01-31")
        #expect(Day(iso: "2027-02-29") == nil)
        #expect(Day(iso: "2028-02-29") != nil)
        #expect(Day(dutch: "1/3/2027")?.dutch == "01-03-2027")
    }

    @Test func comparesAndAdds() {
        let a = Day(iso: "2026-12-31")!
        #expect(a.adding(days: 1) == Day(iso: "2027-01-01")!)
        #expect(a < a.adding(days: 1))
    }
}

@Suite struct SchemaTests {
    @Test func roundTripsRecords() throws {
        let db = try AppDatabase.inMemory()
        try db.write { d in
            var acc = Account(name: "Betaal", iban: "NL00TEST0000000001", kind: .betaal,
                              openingBalance: Money(cents: 100000), openingDate: Day(iso: "2027-01-01")!)
            try acc.insert(d)
            var year = BudgetYear(year: 2027, antiRood: Money(euros: 4500))
            try year.insert(d)
            var item = BudgetItem(yearId: year.id!, label: "UIT boodschappen", direction: .UIT,
                                  planAmount: Money(euros: -450))
            try item.insert(d)
            var e = Entry(accountId: acc.id!, day: Day(iso: "2027-01-05")!, amount: Money(cents: -4321),
                          label: "supermarkt", budgetItemId: item.id)
            try e.insert(d)
            let back = try Entry.fetchOne(d, key: e.id)
            #expect(back?.amount == Money(cents: -4321))
            #expect(back?.day == Day(iso: "2027-01-05"))
            #expect(try Account.fetchOne(d, key: acc.id)?.kind == .betaal)
            try Setting.set(d, "x", "1")
            #expect(try Setting.get(d, "x") == "1")
        }
    }

    @Test func fingerprintIsUnique() throws {
        let db = try AppDatabase.inMemory()
        try db.write { d in
            var acc = Account(name: "Betaal", kind: .betaal, openingDate: Day(iso: "2027-01-01")!)
            try acc.insert(d)
            var t1 = BankTransaction(accountId: acc.id!, day: Day(iso: "2027-01-02")!, amount: Money(cents: -1), fingerprint: "a")
            try t1.insert(d)
            var t2 = t1; t2.id = nil
            #expect(throws: (any Error).self) { try t2.insert(d) }
        }
    }
}
