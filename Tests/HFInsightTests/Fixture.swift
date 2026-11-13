import Foundation
import GRDB
import HFCore

func eur(_ euros: Int64, _ cents: Int64 = 0) -> Money {
    Money(cents: euros < 0 ? euros * 100 - cents : euros * 100 + cents)
}
func d(_ iso: String) -> Day { Day(iso: iso)! }

/// Verzonnen begroting 2027. Peildag in de tests: 15 maart 2027.
///
/// Betaalrekening (begin 3.000,00):
///   jan  Salaris +3000 · Huur −1200 · Energie −160 · Verzekering −300 · RESERVERINGEN −250 · Lening −200
///        divers: Boodschappen −80 · Tanken −60 · Marktplaats +40 · Cadeau −30 (vergoed uit spaar)
///        → vast 890, IN divers 40, UIT divers −170, resultaat 760
///   feb  Salaris +3000 · Huur −1200 · Verzekering −50 (niet verwacht) · RESERVERINGEN −250 · Lening −100 −100
///        divers: Uit eten −75 (vergoeden, pot Vakantie) · Tanken −55
///        → vast 1300, UIT divers −130, resultaat 1170
///   mrt  Huur −1200
///        divers: Boodschappen −90 (nog nakijken) · Tandarts −120 (vergoeden) · Terugbetaling +20
///        → vast −1200, IN divers 20, UIT divers −210, resultaat −1390
///   saldo op 15-3: 3000 + 760 + 1170 − 1390 = 3.540,00
///
/// Spaarrekening (begin 5.000,00):
///   Auto +100 +100 = 200 · Vakantie +150 +150 −200 = 100 · Kind A +25 · rente +10 zonder pot
///   saldo 5.335,00 · potten 325,00 · niet toegewezen 5.010,00
struct Fixture {
    let db: AppDatabase
    var betaal: Int64 = 0, spaar: Int64 = 0
    var potAuto: Int64 = 0, potVakantie: Int64 = 0, potKind: Int64 = 0
    var salaris: Int64 = 0, huur: Int64 = 0, energie: Int64 = 0, verzekering: Int64 = 0, reserveringen: Int64 = 0
    var resAuto: Int64 = 0, resVakantie: Int64 = 0, lening: Int64 = 0, wegenbelasting: Int64 = 0
    var tagBoodschappen: Int64 = 0, tagTanken: Int64 = 0, tagUitEten: Int64 = 0
    var transfer: Int64 = 0

    static let today = d("2027-03-15")

    init() throws {
        db = try AppDatabase.inMemory()
        try db.write { db in
            var a1 = Account(name: "Betaalrekening", iban: "NL00TEST0000000001", kind: .betaal,
                             openingBalance: eur(3000), openingDate: d("2027-01-01"), sortOrder: 1)
            try a1.insert(db); betaal = a1.id!
            var a2 = Account(name: "Spaarrekening", iban: "NL00TEST0000000002", kind: .spaar,
                             openingBalance: eur(5000), openingDate: d("2027-01-01"), sortOrder: 2)
            try a2.insert(db); spaar = a2.id!

            var year = BudgetYear(year: 2027, antiRood: eur(500), tijdelijkAntiRood: eur(100), reserveBase: eur(2000))
            try year.insert(db)
            let y = year.id!

            func pot(_ name: String, _ kind: PotKind, _ monthly: Int64, target: Int64? = nil, owner: String? = nil,
                     order: Int) throws -> Int64 {
                var p = Pot(accountId: spaar, name: name, kind: kind, owner: owner, monthlyAmount: eur(monthly),
                            targetAmount: target.map { eur($0) }, sortOrder: order)
                try p.insert(db); return p.id!
            }
            potAuto = try pot("Auto", .reservering, 100, target: 2400, order: 1)
            potVakantie = try pot("Vakantie", .reservering, 150, order: 2)
            potKind = try pot("Spaarpot Kind A", .spaar, 25, target: 1000, owner: "Kind A", order: 3)

            var order = 0
            func item(_ label: String, _ dir: Direction, _ plan: Int64, freq: Frequency = .maand, months: String = "",
                      day: Int? = nil, total: Bool = false, reduces: Bool = false, pot: Int64? = nil) throws -> Int64 {
                order += 1
                var i = BudgetItem(yearId: y, label: label, direction: dir, planAmount: eur(plan), frequency: freq,
                                   expectedMonths: months, expectedDay: day, isReserveTotal: total,
                                   reducesReserve: reduces, potId: pot, sortOrder: order)
                try i.insert(db); return i.id!
            }
            salaris = try item("Salaris", .IN, 3000, day: 25)
            huur = try item("Huur", .UIT, -1200, day: 1)
            energie = try item("Energie", .UIT, -150, day: 20)
            verzekering = try item("Verzekering", .UIT, -300, freq: .kwartaal, months: "1,4,7,10", day: 10)
            reserveringen = try item("RESERVERINGEN", .UIT, 0, day: 5, total: true)
            resAuto = try item("Auto", .RES, -100, pot: potAuto)
            resVakantie = try item("Vakantie", .RES, -150, pot: potVakantie)
            lening = try item("Lening", .UIT, -200, day: 28, reduces: true)
            wegenbelasting = try item("Wegenbelasting", .UIT, -90, freq: .jaar, months: "6", day: 15)

            func tag(_ name: String, _ order: Int) throws -> Int64 {
                var t = Tag(name: name, color: "#112233", sortOrder: order)
                try t.insert(db); return t.id!
            }
            tagBoodschappen = try tag("boodschappen", 1)
            tagTanken = try tag("tanken", 2)
            tagUitEten = try tag("uit eten", 3)

            var st = SavingsTransfer(day: d("2027-01-31"), amount: eur(30), done: true, note: "januari")
            try st.insert(db); transfer = st.id!

            var batch = ImportBatch(accountId: betaal, fileName: "test-maart.csv",
                                    importedAt: Date(timeIntervalSince1970: 1_800_000_000), rowCount: 3, newCount: 3,
                                    lastDay: d("2027-03-14"), closingBalance: eur(3482, 50))
            try batch.insert(db)
            func bank(_ day: String, _ amount: Money, _ name: String, _ text: String, _ status: BankTransactionStatus) throws -> Int64 {
                var b = BankTransaction(accountId: betaal, batchId: batch.id, day: d(day), amount: amount,
                                        counterpartyName: name, counterpartyIban: "NL00TEST0000000099",
                                        descriptionText: text, fingerprint: "fp-\(day)-\(amount.cents)", status: status)
                try b.insert(db); return b.id!
            }
            let bankBoodschappen = try bank("2027-03-03", eur(-90), "Supermarkt Testmarkt", "Pinbetaling 03-03", .verwerkt)
            _ = try bank("2027-03-13", eur(-45), "Bakker Test", "Pinbetaling 13-03", .nieuw)
            _ = try bank("2027-03-14", eur(-12, 50), "Kiosk Test", "Pinbetaling 14-03", .nieuw)

            @discardableResult
            func entry(_ account: Int64, _ day: String, _ amount: Int64, _ label: String, item: Int64? = nil,
                       pot: Int64? = nil, tags: [Int64] = [], reimburse: Bool = false, transfer: Int64? = nil,
                       reviewed: Bool = true, bank: Int64? = nil, note: String = "") throws -> Int64 {
                var e = Entry(accountId: account, bankTransactionId: bank, day: d(day), amount: eur(amount), label: label,
                              budgetItemId: item, potId: pot, reimburse: reimburse, savingsTransferId: transfer,
                              reviewed: reviewed, note: note)
                try e.insert(db)
                for t in tags { try EntryTag(entryId: e.id!, tagId: t).insert(db) }
                return e.id!
            }
            // Januari
            try entry(betaal, "2027-01-25", 3000, "Salaris", item: salaris)
            try entry(betaal, "2027-01-02", -1200, "Huur", item: huur)
            try entry(betaal, "2027-01-20", -160, "Energie", item: energie)
            try entry(betaal, "2027-01-10", -300, "Verzekering", item: verzekering)
            try entry(betaal, "2027-01-05", -250, "Reserveringen", item: reserveringen)
            try entry(betaal, "2027-01-28", -200, "Lening", item: lening)
            try entry(betaal, "2027-01-12", -80, "Boodschappen", tags: [tagBoodschappen])
            try entry(betaal, "2027-01-15", -60, "Tanken", tags: [tagTanken])
            try entry(betaal, "2027-01-18", 40, "Marktplaats")
            try entry(betaal, "2027-01-22", -30, "Cadeau", pot: potKind, reimburse: true, transfer: transfer)
            // Februari
            try entry(betaal, "2027-02-25", 3000, "Salaris", item: salaris)
            try entry(betaal, "2027-02-01", -1200, "Huur", item: huur)
            try entry(betaal, "2027-02-11", -50, "Verzekering naheffing", item: verzekering)
            try entry(betaal, "2027-02-05", -250, "Reserveringen", item: reserveringen)
            try entry(betaal, "2027-02-27", -100, "Lening deel 1", item: lening)
            try entry(betaal, "2027-02-27", -100, "Lening deel 2", item: lening)
            try entry(betaal, "2027-02-14", -75, "Uit eten", pot: potVakantie, tags: [tagUitEten], reimburse: true)
            try entry(betaal, "2027-02-20", -55, "Tanken", tags: [tagTanken], note: "lange rit")
            // Maart
            try entry(betaal, "2027-03-01", -1200, "Huur", item: huur)
            try entry(betaal, "2027-03-03", -90, "Boodschappen", tags: [tagBoodschappen], reviewed: false, bank: bankBoodschappen)
            try entry(betaal, "2027-03-10", -120, "Tandarts", reimburse: true)
            try entry(betaal, "2027-03-12", 20, "Terugbetaling")
            // Spaarrekening
            try entry(spaar, "2027-01-05", 100, "Storting Auto", pot: potAuto)
            try entry(spaar, "2027-01-05", 150, "Storting Vakantie", pot: potVakantie)
            try entry(spaar, "2027-01-10", 25, "Zakgeld sparen", pot: potKind)
            try entry(spaar, "2027-02-05", 100, "Storting Auto", pot: potAuto)
            try entry(spaar, "2027-02-05", 150, "Storting Vakantie", pot: potVakantie)
            try entry(spaar, "2027-02-15", -200, "Opname vakantie", pot: potVakantie)
            try entry(spaar, "2027-03-02", 10, "Rente")

            // Afstemmingen: betaal klopt (28-2), spaar heeft € 5 verschil en is 43 dagen oud (31-1).
            var r1 = Reconciliation(accountId: betaal, day: d("2027-02-28"), actualBalance: eur(4930), calculatedBalance: eur(4930))
            try r1.insert(db)
            var r2 = Reconciliation(accountId: spaar, day: d("2027-01-31"), actualBalance: eur(5270), calculatedBalance: eur(5275))
            try r2.insert(db)
        }
    }
}
