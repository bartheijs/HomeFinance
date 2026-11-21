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

@Suite struct MoneyExpressionTests {
    @Test func evaluatesSimpleSums() {
        #expect(Money(evaluating: "249*4")?.cents == 99600)
        #expect(Money(evaluating: "2695 - 269,50")?.cents == 242550)
        #expect(Money(evaluating: "4 x 19,80")?.cents == 7920)
        #expect(Money(evaluating: "=157*2")?.cents == 31400)
        #expect(Money(evaluating: "254*4-40")?.cents == 97600)
        #expect(Money(evaluating: "818,42/3")?.cents == 27281)
        #expect(Money(evaluating: "-5000+876,59")?.cents == -412341)
        #expect(Money(evaluating: "10 * 39,5")?.cents == 39500)
        #expect(Money(evaluating: "12,50")?.cents == 1250)
        #expect(Money(evaluating: "-45,50")?.cents == -4550)
    }

    @Test func rejectsNonsense() {
        #expect(Money(evaluating: "abc") == nil)
        #expect(Money(evaluating: "12*") == nil)
        #expect(Money(evaluating: "*12") == nil)
        #expect(Money(evaluating: "10/0") == nil)
        #expect(Money(evaluating: "") == nil)
    }
}

@Suite struct BuildInfoTests {
    @Test func showsVersionDateAndCommit() {
        let info = BuildInfo(infoDictionary: ["CFBundleShortVersionString": "1.0", "CFBundleVersion": "42",
                                              "HFBuildCommit": "abc1234", "HFBuildDate": "2026-11-21 14:50"])
        #expect(info.displayText == "1.0 · gebouwd 21-11-2026 14:50 · abc1234")
        #expect(info.isComplete)
    }

    @Test func marksUncommittedChanges() {
        let info = BuildInfo(version: "1.0", commit: "abc1234+", builtAt: "2026-01-05 09:03")
        #expect(info.displayText == "1.0 · gebouwd 05-01-2026 09:03 · abc1234+")
    }

    @Test func missingInformationIsDevelopmentVersion() {
        #expect(BuildInfo(infoDictionary: nil).displayText == "ontwikkelversie")
        #expect(BuildInfo(infoDictionary: ["CFBundleShortVersionString": "1.0", "CFBundleVersion": "1"])
            .displayText == "ontwikkelversie")
        #expect(BuildInfo(version: "1.0", commit: "abc1234", builtAt: "21-11-2026").displayText == "ontwikkelversie")
        #expect(BuildInfo(version: "1.0", commit: " ", builtAt: "2026-11-21 14:50").displayText == "ontwikkelversie")
        #expect(!BuildInfo(infoDictionary: nil).isComplete)
    }
}

// MARK: - 6f: richting van verrekenen met spaar per regel

@Suite struct ReimburseDirectionMigrationTests {
    /// Bestaande regels krijgen bij migratie v9 een richting: die van hun laatste boeking met verrekenen,
    /// anders "erin" (alleen bijschrijving). Regels zonder verrekenen krijgen "beide". Verzonnen data.
    @Test func existingRulesGetDirectionFromLastUse() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v8-scenario-goalparts-project")
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO account (id, name, iban, kind, openingDate) VALUES (1, 'Betaal', 'NL00TEST0000000001', 'betaal', '2027-01-01');
                INSERT INTO rule (id, name, origin, counterpartyIban, reimburse) VALUES
                    (1, 'Kind A', 'geleerd', 'NL00TEST0000000011', 1),
                    (2, 'Apotheek', 'geleerd', 'NL00TEST0000000012', 1),
                    (3, 'Nooit gebruikt', 'handmatig', 'NL00TEST0000000013', 1),
                    (4, 'Zonder verrekenen', 'geleerd', 'NL00TEST0000000014', 0),
                    (5, 'Wisselend', 'geleerd', 'NL00TEST0000000015', 1);
                INSERT INTO entry (accountId, day, amount, reimburse, ruleId, createdAt) VALUES
                    (1, '2027-02-01', 2500, 1, 1, '2027-02-01 10:00:00'),
                    (1, '2027-02-03', -1999, 1, 2, '2027-02-03 10:00:00'),
                    (1, '2027-02-05', -500, 0, 3, '2027-02-05 10:00:00'),
                    (1, '2027-02-07', -700, 0, 4, '2027-02-07 10:00:00'),
                    (1, '2027-01-10', -1500, 1, 5, '2027-01-10 10:00:00'),
                    (1, '2027-03-10', 4000, 1, 5, '2027-03-10 10:00:00');
                """)
        }
        try AppDatabase.migrator.migrate(queue)
        let directions = try queue.read { db in
            try Dictionary(uniqueKeysWithValues: Rule.fetchAll(db).map { ($0.id!, $0.reimburseDirection) })
        }
        #expect(directions[1] == .incoming)   // laatst gebruikt bij geld erin
        #expect(directions[2] == .outgoing)   // laatst gebruikt bij geld eruit
        #expect(directions[3] == .incoming)   // geen boeking met verrekenen: veilige keuze
        #expect(directions[4] == .both)       // geen verrekenen: richting telt niet
        #expect(directions[5] == .incoming)   // de laatste boeking telt
    }

    @Test func directionApplies() {
        #expect(ReimburseDirection.incoming.applies(to: Money(cents: 100)))
        #expect(!ReimburseDirection.incoming.applies(to: Money(cents: -100)))
        #expect(ReimburseDirection.outgoing.applies(to: Money(cents: -100)))
        #expect(ReimburseDirection.both.applies(to: Money(cents: -100)))
        let withoutReimburse = Rule(name: "Spaar", targetPotId: 1, reimburseDirection: .incoming)
        #expect(withoutReimburse.reimburseApplies(to: Money(cents: -100)))
    }
}
