import Foundation
import GRDB
import HFCore
@testable import HFBudget

// Verzonnen testgegevens: geen echte namen, IBAN's of bedragen.

func d(_ iso: String) -> Day { Day(iso: iso)! }
func c(_ cents: Int64) -> Money { Money(cents: cents) }

struct Fixture {
    let app: AppDatabase
    var betaal: Account
    var spaar: Account
    var year: BudgetYear
    var salaris: BudgetItem
    var boodschappen: BudgetItem
    var reserveringen: BudgetItem
    var resVerzekering: BudgetItem
    var resVakantie: BudgetItem
    var potVerzekering: Pot
    var potVakantie: Pot
    var potSpaar: Pot

    static let betaalIban = "NL00TEST0000000001"
    static let spaarIban = "NL00TEST0000000002"

    init() throws {
        let app = try AppDatabase.inMemory()
        self.app = app
        (betaal, spaar, year, salaris, boodschappen, reserveringen, resVerzekering, resVakantie,
         potVerzekering, potVakantie, potSpaar) = try app.write { db in
            let betaal = try AccountService.create(db, Account(name: "Testbetaal", iban: Fixture.betaalIban, kind: .betaal,
                                                               openingBalance: c(100_000), openingDate: d("2027-01-01")))
            let spaar = try AccountService.create(db, Account(name: "Testspaar", iban: Fixture.spaarIban, kind: .spaar,
                                                              openingBalance: c(500_000), openingDate: d("2027-01-01")))
            let year = try YearService.createYear(db, year: 2027, antiRood: c(50_000), reserveBase: c(20_000))
            let potVerzekering = try PotService.create(db, Pot(accountId: spaar.id!, name: "Verzekering", kind: .reservering,
                                                               monthlyAmount: c(10_000)))
            let potVakantie = try PotService.create(db, Pot(accountId: spaar.id!, name: "Vakantie", kind: .reservering,
                                                            monthlyAmount: c(15_000)))
            let potSpaar = try PotService.create(db, Pot(accountId: spaar.id!, name: "Spaarpot kind", kind: .spaar,
                                                         owner: "Kind A", monthlyAmount: c(2_500)))
            let salaris = try YearService.createItem(db, BudgetItem(yearId: year.id!, label: "Salaris", direction: .IN,
                                                                    planAmount: c(300_000), expectedDay: 25))
            let boodschappen = try YearService.createItem(db, BudgetItem(yearId: year.id!, label: "Boodschappen",
                                                                         direction: .UIT, planAmount: c(-60_000)))
            let reserveringen = try YearService.createItem(db, BudgetItem(yearId: year.id!, label: "RESERVERINGEN",
                                                                          direction: .UIT, planAmount: .zero,
                                                                          isReserveTotal: true))
            let resVerzekering = try YearService.createItem(db, BudgetItem(yearId: year.id!, label: "Verzekering",
                                                                           direction: .RES, planAmount: c(-10_000),
                                                                           potId: potVerzekering.id))
            let resVakantie = try YearService.createItem(db, BudgetItem(yearId: year.id!, label: "Vakantie",
                                                                        direction: .RES, planAmount: c(-15_000),
                                                                        potId: potVakantie.id))
            return (betaal, spaar, year, salaris, boodschappen, reserveringen, resVerzekering, resVakantie,
                    potVerzekering, potVakantie, potSpaar)
        }
    }

    private static let counter = Counter()

    /// Voegt een verzonnen banktransactie toe.
    @discardableResult
    func tx(_ db: Database, _ account: Account, _ day: String, _ cents: Int64, iban: String = "",
            batchId: Int64? = nil, name: String = "Testwinkel") throws -> BankTransaction {
        var t = BankTransaction(accountId: account.id!, batchId: batchId, day: d(day), amount: c(cents),
                                counterpartyName: name, counterpartyIban: iban, descriptionText: "test",
                                fingerprint: "fp-\(Fixture.counter.next())")
        try t.insert(db)
        return t
    }

    func entries(_ db: Database, tx id: Int64) throws -> [Entry] {
        try Entry.fetchAll(db, sql: "SELECT * FROM entry WHERE bankTransactionId = ? ORDER BY id", arguments: [id])
    }

    func status(_ db: Database, _ id: Int64) throws -> BankTransactionStatus {
        try BankTransaction.fetchOne(db, key: id)!.status
    }
}

final class Counter: @unchecked Sendable {
    private var value = 0
    private let lock = NSLock()
    func next() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
}
