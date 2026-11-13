import Foundation
import GRDB
import HFCore

func eur(_ euros: Int64, _ cents: Int64 = 0) -> Money {
    Money(cents: euros < 0 ? euros * 100 - cents : euros * 100 + cents)
}
func d(_ iso: String) -> Day { Day(iso: iso)! }

/// Verzonnen begroting 2027. Peildag in de tests: 15 maart 2027. Anti-rood 500,00.
///
/// Betaalrekening (begin 3.000,00):
///   jan  Salaris +3000 · Huur −1200 · Water −40 · Energie −150 · Boodschappen −200      → 4.410,00
///   feb  Salaris +3000 · Huur −1200 · Water −40 · Energie −150 · Fiets −300             → 5.720,00
///   mrt  Huur −1200 · Boodschappen −90 · Tandarts −120 (vergoeden uit spaar)
///        · Geleend van spaar +250 (tijdelijk geleend)                                   → 4.560,00
///   besteedbaar op 15-3: 4560 − 500 − 250 = 3.810,00
///   nog verwacht in maart: Salaris +3000 (open) · Energie −150 (open) · Water −40 (te laat, dag 5)
///   besteedbaar eind maart: 3810 + 3000 − 150 − 40 = 6.620,00
///   uitgaven maart: −1.410,00 · plan uitgaven maart: −1.390,00 → 101%
///
/// Spaarrekening (begin 1.000,00):
///   pot Auto (reservering) +100 +100 = 200 · pot met rare tekens (spaar) +25
///   rente +10 en uitgeleend −250, beide zonder pot → niet toegewezen 760,00
struct Fixture {
    let db: AppDatabase
    static let today = d("2027-03-15")
    /// Naam met tekens die in HTML een betekenis hebben.
    static let trickyPot = "Kind \"A\" & <b>co</b>'s pot"
    static let trickyItem = "Water <script>alert(1)</script> & Co"
    static let trickyAccount = "Betaal <img alt=x> & 'meer'"

    init(withYear: Bool = true) throws {
        db = try AppDatabase.inMemory()
        try db.write { db in
            var a1 = Account(name: Self.trickyAccount, iban: "NL00TEST0000000001", kind: .betaal,
                             openingBalance: eur(3000), openingDate: d("2027-01-01"), sortOrder: 1)
            try a1.insert(db)
            var a2 = Account(name: "Spaarrekening", iban: "NL00TEST0000000002", kind: .spaar,
                             openingBalance: eur(1000), openingDate: d("2027-01-01"), sortOrder: 2)
            try a2.insert(db)
            let betaal = a1.id!, spaar = a2.id!

            var p1 = Pot(accountId: spaar, name: "Auto", kind: .reservering, monthlyAmount: eur(100), sortOrder: 1)
            try p1.insert(db)
            var p2 = Pot(accountId: spaar, name: Self.trickyPot, kind: .spaar, monthlyAmount: eur(25), sortOrder: 2)
            try p2.insert(db)

            var salaris: Int64?, huur: Int64?, water: Int64?, energie: Int64?
            if withYear {
                var year = BudgetYear(year: 2027, antiRood: eur(500))
                try year.insert(db)
                var order = 0
                func item(_ label: String, _ dir: Direction, _ plan: Int64, day: Int) throws -> Int64 {
                    order += 1
                    var i = BudgetItem(yearId: year.id!, label: label, direction: dir, planAmount: eur(plan),
                                       frequency: .maand, expectedMonths: "", expectedDay: day, sortOrder: order)
                    try i.insert(db); return i.id!
                }
                salaris = try item("Salaris", .IN, 3000, day: 25)
                huur = try item("Huur", .UIT, -1200, day: 1)
                water = try item(Self.trickyItem, .UIT, -40, day: 5)
                energie = try item("Energie", .UIT, -150, day: 20)
            }

            func entry(_ account: Int64, _ day: String, _ amount: Int64, _ label: String, item: Int64? = nil,
                       pot: Int64? = nil, reimburse: Bool = false, loan: Bool = false) throws {
                var e = Entry(accountId: account, day: d(day), amount: eur(amount), label: label,
                              budgetItemId: item, potId: pot, reimburse: reimburse, temporaryLoan: loan)
                try e.insert(db)
            }
            for month in ["01", "02"] {
                try entry(betaal, "2027-\(month)-25", 3000, "Salaris", item: salaris)
                try entry(betaal, "2027-\(month)-01", -1200, "Huur", item: huur)
                try entry(betaal, "2027-\(month)-05", -40, "Water", item: water)
                try entry(betaal, "2027-\(month)-20", -150, "Energie", item: energie)
            }
            try entry(betaal, "2027-01-12", -200, "Boodschappen")
            try entry(betaal, "2027-02-14", -300, "Fiets")
            try entry(betaal, "2027-03-01", -1200, "Huur", item: huur)
            try entry(betaal, "2027-03-03", -90, "Boodschappen")
            try entry(betaal, "2027-03-10", -120, "Tandarts", reimburse: true)
            try entry(betaal, "2027-03-11", 250, "Geleend van spaar", loan: true)

            try entry(spaar, "2027-01-05", 100, "Storting Auto", pot: p1.id)
            try entry(spaar, "2027-02-05", 100, "Storting Auto", pot: p1.id)
            try entry(spaar, "2027-01-10", 25, "Zakgeld", pot: p2.id)
            try entry(spaar, "2027-03-02", 10, "Rente")
            try entry(spaar, "2027-03-11", -250, "Uitgeleend aan betaal")
        }
    }
}
