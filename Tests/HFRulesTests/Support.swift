import Foundation
import GRDB
import Testing
import HFCore
@testable import HFRules

// Alle testdata is verzonnen.

struct Fixture {
    let db: AppDatabase
    var accountId: Int64 = 0
    var savingsId: Int64 = 0
    var potId: Int64 = 0
    var energieId: Int64 = 0
    var sportId: Int64 = 0
    private static var counter = 0

    init() throws {
        db = try AppDatabase.inMemory()
        var f = (acc: Int64(0), sav: Int64(0), pot: Int64(0), energie: Int64(0), sport: Int64(0))
        try db.write { d in
            var acc = Account(name: "Betaal", iban: "NL00TEST0000000001", kind: .betaal, openingDate: Day(iso: "2027-01-01")!)
            try acc.insert(d)
            var sav = Account(name: "Spaar", iban: "NL00TEST0000000002", kind: .spaar, openingDate: Day(iso: "2027-01-01")!)
            try sav.insert(d)
            var pot = Pot(accountId: sav.id!, name: "Vakantie", kind: .spaar)
            try pot.insert(d)
            var year = BudgetYear(year: 2027)
            try year.insert(d)
            var energie = BudgetItem(yearId: year.id!, label: "Energie", direction: .UIT, planAmount: Money(euros: -150))
            try energie.insert(d)
            var sport = BudgetItem(yearId: year.id!, label: "Sportclub", direction: .UIT, planAmount: Money(euros: -30), sortOrder: 1)
            try sport.insert(d)
            f = (acc.id!, sav.id!, pot.id!, energie.id!, sport.id!)
        }
        accountId = f.acc; savingsId = f.sav; potId = f.pot; energieId = f.energie; sportId = f.sport
    }

    /// Voegt een verzonnen banktransactie toe.
    @discardableResult
    func tx(_ d: Database, name: String = "", iban: String = "", description: String = "", cents: Int64 = -1000,
            day: String = "2027-03-05", account: Int64? = nil, status: BankTransactionStatus = .nieuw,
            code: String = "") throws -> BankTransaction {
        var t = BankTransaction(accountId: account ?? accountId, day: Day(iso: day)!, amount: Money(cents: cents),
                                counterpartyName: name, counterpartyIban: iban, descriptionText: description,
                                transactionCode: code, fingerprint: UUID().uuidString, status: status)
        try t.insert(d)
        return t
    }

    @discardableResult
    func rule(_ d: Database, _ rule: Rule) throws -> Rule {
        var r = rule
        try r.insert(d)
        return r
    }
}
