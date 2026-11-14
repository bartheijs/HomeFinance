import Foundation
import GRDB
import HFCore
import Testing
@testable import HFInsight

private let today = Fixture.today   // 15 maart 2027

/// Potsaldi in de fixture op 15-3-2027: Auto 200 (+100 op 5-1 en 5-2), Vakantie 100 (+150, +150, −200),
/// Spaarpot Kind A 25 (+25 op 10-1).
@Suite struct ForecastTests {
    let f: Fixture
    init() throws { f = try Fixture() }

    private func item(_ pot: Int64, _ day: String, _ amount: Int64, _ label: String, realized: Bool = false) throws -> Int64 {
        try f.db.write { db in
            var i = ForecastItem(potId: pot, day: d(day), amount: eur(amount), label: label,
                                 realizedAt: realized ? Date(timeIntervalSince1970: 1_800_000_000) : nil)
            try i.insert(db); return i.id!
        }
    }

    private func distribution(_ name: String, _ lines: [(Int64, Int64)], archived: Bool = false) throws -> Int64 {
        try f.db.write { db in
            var dist = Distribution(name: name, accountId: f.spaar, archived: archived)
            try dist.insert(db)
            for (pot, amount) in lines {
                var l = DistributionLine(distributionId: dist.id!, potId: pot, amount: eur(amount))
                try l.insert(db)
            }
            return dist.id!
        }
    }

    private func deposit(_ pot: Int64, _ day: String, _ amount: Int64, bank: Int64? = nil) throws {
        try f.db.write { db in
            var e = Entry(accountId: f.spaar, bankTransactionId: bank, day: d(day), amount: eur(amount), label: "Storting", potId: pot)
            try e.insert(db)
        }
    }

    private func forecast(_ pot: Int64, until: String, today day: Day = today) throws -> PotForecast {
        try f.db.read { try Insight.potForecast($0, potId: pot, today: day, until: d(until)) }
    }

    @Test func oneOffItemsOnly() throws {
        let verjaardag = try item(f.potKind, "2027-04-10", 50, "Verjaardag")
        let fiets = try item(f.potKind, "2027-06-01", -60, "Fiets")
        _ = try item(f.potKind, "2027-05-01", 999, "Al ontvangen", realized: true)   // uitgekomen: telt niet
        _ = try item(f.potKind, "2027-12-01", 10, "Na het bereik")                   // na `until`: telt niet
        let p = try forecast(f.potKind, until: "2027-08-31")
        // 25 → +50 = 75 (10-4) → −60 = 15 (1-6)
        #expect(p.startBalance == eur(25))
        #expect(p.events.map(\.day) == [d("2027-04-10"), d("2027-06-01")])
        #expect(p.events.map(\.amount) == [eur(50), eur(-60)])
        #expect(p.events.map(\.label) == ["Verjaardag", "Fiets"])
        #expect(p.events.map(\.kind) == [.oneOff(forecastItemId: verjaardag), .oneOff(forecastItemId: fiets)])
        #expect(p.events.map(\.balanceAfter) == [eur(75), eur(15)])
        #expect(p.endBalance == eur(15))
        #expect(p.overdue.isEmpty)
        #expect(p.balance(on: today) == eur(25))
        #expect(p.balance(on: d("2027-04-09")) == eur(25))
        #expect(p.balance(on: d("2027-04-10")) == eur(75))
        #expect(p.balance(on: d("2027-05-01")) == eur(75))
        #expect(p.balance(on: d("2027-08-31")) == eur(15))
        #expect(p.balance(on: d("2027-09-01")) == nil)
        #expect(p.balance(on: d("2027-03-14")) == nil)
        #expect(p.lowestPoint == ForecastPoint(day: d("2027-06-01"), balance: eur(15), isForecast: true))
        // Grafiek: echt saldo per maandeinde vanaf de eerste boeking (10-1) t/m vandaag, daarna de verwachting.
        #expect(p.points == [
            ForecastPoint(day: d("2027-01-31"), balance: eur(25), isForecast: false),
            ForecastPoint(day: d("2027-02-28"), balance: eur(25), isForecast: false),
            ForecastPoint(day: today, balance: eur(25), isForecast: false),
            ForecastPoint(day: d("2027-04-10"), balance: eur(75), isForecast: true),
            ForecastPoint(day: d("2027-06-01"), balance: eur(15), isForecast: true),
            ForecastPoint(day: d("2027-08-31"), balance: eur(15), isForecast: true),
        ])
    }

    @Test func recurringOnlyCurrentMonthNotYetReceived() throws {
        let dist = try distribution("Maandstorting", [(f.potAuto, 100), (f.potVakantie, 150)])
        _ = try distribution("Oud", [(f.potAuto, 500)], archived: true)          // gearchiveerd: telt niet
        let p = try forecast(f.potAuto, until: "2027-05-31")
        // Laatste echte storting van 100 was op 5-2: dag 5. Maart is nog niet binnen en de 5e is voorbij: morgen.
        // 200 → 300 (16-3) → 400 (5-4) → 500 (5-5)
        #expect(p.startBalance == eur(200))
        #expect(p.events.map(\.day) == [d("2027-03-16"), d("2027-04-05"), d("2027-05-05")])
        #expect(p.events.allSatisfy { $0.amount == eur(100) && $0.label == "Maandstorting" && $0.kind == .recurring(distributionId: dist) })
        #expect(p.events.map(\.balanceAfter) == [eur(300), eur(400), eur(500)])
        #expect(p.lowestPoint == ForecastPoint(day: today, balance: eur(200), isForecast: false))
        #expect(Set(p.events.map(\.id)).count == 3)
    }

    @Test func recurringCurrentMonthAlreadyReceived() throws {
        _ = try distribution("Maandstorting", [(f.potAuto, 100), (f.potVakantie, 150)])
        try deposit(f.potAuto, "2027-03-05", 100)
        let p = try forecast(f.potAuto, until: "2027-05-31")
        // Maart is al binnen (saldo 300) en telt dus niet nog een keer.
        #expect(p.startBalance == eur(300))
        #expect(p.events.map(\.day) == [d("2027-04-05"), d("2027-05-05")])
        #expect(p.events.map(\.balanceAfter) == [eur(400), eur(500)])
    }

    @Test func recurringPrefersSplitBankTransaction() throws {
        _ = try distribution("Maandstorting", [(f.potAuto, 100), (f.potVakantie, 150)])
        // Op 7-3 komt de storting van 250 binnen als één banktransactie, gesplitst over Auto en Vakantie.
        let bank: Int64 = try f.db.write { db in
            var b = BankTransaction(accountId: f.spaar, day: d("2027-03-07"), amount: eur(250),
                                    counterpartyName: "Eigen rekening Test", fingerprint: "fp-storting-maart", status: .verwerkt)
            try b.insert(db); return b.id!
        }
        try deposit(f.potAuto, "2027-03-07", 100, bank: bank)
        try deposit(f.potVakantie, "2027-03-07", 150, bank: bank)
        // De gesplitste storting bepaalt de dag (7), niet de losse boekingen op de 5e.
        let p = try forecast(f.potAuto, until: "2027-05-31")
        #expect(p.startBalance == eur(300))
        #expect(p.events.map(\.day) == [d("2027-04-07"), d("2027-05-07")])
        // Peildag 20 april: de gesplitste storting van april is er nog niet → morgen (21-4), daarna 7-5.
        let april = try forecast(f.potAuto, until: "2027-05-31", today: d("2027-04-20"))
        #expect(april.events.map(\.day) == [d("2027-04-21"), d("2027-05-07")])
    }

    @Test func recurringWithoutAnyDepositUsesDay25AndClipsToMonthLength() throws {
        let nieuw: Int64 = try f.db.write { db in
            var p = Pot(accountId: f.spaar, name: "Nieuwe pot", kind: .spaar, sortOrder: 9)
            try p.insert(db); return p.id!
        }
        _ = try distribution("Nieuw sparen", [(nieuw, 40)])
        let p = try forecast(nieuw, until: "2027-04-30")
        #expect(p.startBalance == .zero)
        #expect(p.events.map(\.day) == [d("2027-03-25"), d("2027-04-25")])      // nog geen storting: de 25e
        #expect(p.events.map(\.balanceAfter) == [eur(40), eur(80)])
        #expect(p.points.first == ForecastPoint(day: today, balance: .zero, isForecast: false))

        // Laatste storting op de 31e: in kortere maanden de laatste dag.
        try deposit(nieuw, "2027-01-31", 40)
        let feb = try forecast(nieuw, until: "2027-04-30", today: d("2027-02-10"))
        #expect(feb.startBalance == eur(40))
        #expect(feb.events.map(\.day) == [d("2027-02-28"), d("2027-03-31"), d("2027-04-30")])
        #expect(feb.endBalance == eur(160))
    }

    @Test func overdueItemsAreNotInTheLine() throws {
        let oud = try item(f.potKind, "2027-03-01", 20, "Oma zou nog storten")
        let vandaag = try item(f.potKind, "2027-03-15", 5, "Vandaag verwacht")
        _ = try item(f.potKind, "2027-03-16", 10, "Morgen")
        let p = try forecast(f.potKind, until: "2027-03-31")
        #expect(p.overdue.map(\.id) == [oud, vandaag])
        #expect(p.events.map(\.label) == ["Morgen"])
        #expect(p.endBalance == eur(35))                    // 25 + 10; de 20 en 5 tellen niet mee
    }

    @Test func expenseTakesBalanceBelowZero() throws {
        _ = try distribution("Maandstorting", [(f.potAuto, 100), (f.potVakantie, 150)])
        _ = try item(f.potVakantie, "2027-03-20", -400, "Aanbetaling huisje")
        _ = try item(f.potVakantie, "2027-04-05", -50, "Borg")
        let p = try forecast(f.potVakantie, until: "2027-04-30")
        // 100 → +150 = 250 (16-3) → −400 = −150 (20-3) → +150 = 0 (5-4) → −50 = −50 (5-4, na de storting)
        #expect(p.startBalance == eur(100))
        #expect(p.events.map(\.day) == [d("2027-03-16"), d("2027-03-20"), d("2027-04-05"), d("2027-04-05")])
        #expect(p.events.map(\.amount) == [eur(150), eur(-400), eur(150), eur(-50)])
        #expect(p.events.map(\.balanceAfter) == [eur(250), eur(-150), .zero, eur(-50)])
        #expect(p.lowestPoint == ForecastPoint(day: d("2027-03-20"), balance: eur(-150), isForecast: true))
        #expect(p.balance(on: d("2027-04-05")) == eur(-50))
        // Eén punt per dag in de grafiek: 5-4 staat er één keer in, met het saldo aan het eind van de dag.
        #expect(p.points.filter(\.isForecast).map(\.day) == [d("2027-03-16"), d("2027-03-20"), d("2027-04-05"), d("2027-04-30")])
        #expect(p.points.filter(\.isForecast).map(\.balance) == [eur(250), eur(-150), eur(-50), eur(-50)])
        // Echt saldo per maandeinde: 150 (31-1), 100 (28-2), 100 (vandaag).
        #expect(p.points.filter { !$0.isForecast }.map(\.balance) == [eur(150), eur(100), eur(100)])
    }

    @Test func potWithoutAnything() throws {
        let leeg: Int64 = try f.db.write { db in
            var p = Pot(accountId: f.spaar, name: "Lege pot", kind: .spaar)
            try p.insert(db); return p.id!
        }
        let p = try forecast(leeg, until: "2027-12-31")
        #expect(p.potName == "Lege pot")
        #expect(p.startBalance == .zero)
        #expect(p.events.isEmpty)
        #expect(p.overdue.isEmpty)
        #expect(p.endBalance == .zero)
        #expect(p.lowestPoint == ForecastPoint(day: today, balance: .zero, isForecast: false))
        #expect(p.points == [ForecastPoint(day: today, balance: .zero, isForecast: false),
                             ForecastPoint(day: d("2027-12-31"), balance: .zero, isForecast: true)])
        #expect(throws: InsightError.potNotFound(999)) {
            try f.db.read { try Insight.potForecast($0, potId: 999, today: today, until: d("2027-12-31")) }
        }
    }

    @Test func chartStartsAtMostTwelveMonthsBack() throws {
        // Peildag 10-6-2028: de reeks begint bij het maandeinde van juni 2027 (12 maanden terug), saldo Auto 200.
        let p = try forecast(f.potAuto, until: "2028-06-30", today: d("2028-06-10"))
        let actual = p.points.filter { !$0.isForecast }
        #expect(actual.first?.day == d("2027-06-30"))
        #expect(actual.count == 13)                         // 12 maandeinden + vandaag
        #expect(actual.last?.day == d("2028-06-10"))
        #expect(actual.allSatisfy { $0.balance == eur(200) })
    }

    @Test func forecastDoesNotTouchRealFigures() throws {
        _ = try distribution("Maandstorting", [(f.potAuto, 100), (f.potVakantie, 150)])
        _ = try item(f.potVakantie, "2027-03-20", -400, "Aanbetaling huisje")
        let o = try f.db.read { try Insight.potOverview($0, today: today) }
        #expect(o.accounts[0].pots.map(\.balance) == [eur(200), eur(100), eur(25)])
        #expect(o.accounts[0].unallocated == eur(5010))
    }

    @Test func itemsListAndOpenCount() throws {
        let later = try item(f.potVakantie, "2027-07-01", -900, "Huisje")
        let eerder = try item(f.potVakantie, "2027-04-01", 100, "Vakantiegeld")
        let klaarOud = try item(f.potVakantie, "2027-01-10", 30, "Teruggave", realized: true)
        let klaarNieuw = try item(f.potVakantie, "2027-02-10", 40, "Bonus", realized: true)
        let list = try f.db.read { try Insight.forecastItems($0, potId: f.potVakantie) }
        #expect(list.map(\.id) == [eerder, later, klaarNieuw, klaarOud])   // open eerst (oudste dag), dan uitgekomen (nieuwste)
        let pots = try f.db.read { try Insight.potOverview($0, today: today) }.accounts[0].pots
        #expect(pots.map(\.openForecastCount) == [0, 2, 0])
    }
}
