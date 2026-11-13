import Foundation
import GRDB
import HFCore
import Testing
@testable import HFBudget

@Suite struct BalanceTests {
    @Test func saldoEnAfstemming() throws {
        let fx = try Fixture()
        try fx.app.write { db in
            let t1 = try fx.tx(db, fx.betaal, "2027-01-10", -5_000)
            let t2 = try fx.tx(db, fx.betaal, "2027-01-25", 300_000)
            try BookingService.book(db, bankTransactionId: t1.id!, allocations: [Allocation(amount: c(-5_000), label: "x")])
            try BookingService.book(db, bankTransactionId: t2.id!, allocations: [
                Allocation(amount: c(300_000), label: "Salaris", budgetItemId: fx.salaris.id)])
            try EntryService.create(db, EntryDraft(accountId: fx.betaal.id!, day: d("2027-01-15"), amount: c(-2_000), label: "Contant"))

            #expect(try BalanceService.balance(db, accountId: fx.betaal.id!, on: d("2027-01-09")) == c(100_000))
            #expect(try BalanceService.balance(db, accountId: fx.betaal.id!, on: d("2027-01-10")) == c(95_000))
            #expect(try BalanceService.balance(db, accountId: fx.betaal.id!, on: d("2027-01-24")) == c(93_000))
            #expect(try BalanceService.balance(db, accountId: fx.betaal.id!, on: d("2027-01-31")) == c(393_000))
            #expect(try BalanceService.balance(db, accountId: fx.spaar.id!, on: d("2027-01-31")) == c(500_000))

            let ok = try BalanceService.reconcile(db, accountId: fx.betaal.id!, day: d("2027-01-31"), actualBalance: c(393_000))
            #expect(ok.difference == .zero)
            #expect(ok.calculatedBalance == c(393_000))
            let off = try BalanceService.reconcile(db, accountId: fx.betaal.id!, day: d("2027-01-24"), actualBalance: c(93_250))
            #expect(off.difference == c(-250))
            let history = try BalanceService.history(db, accountId: fx.betaal.id!)
            #expect(history.map(\.day) == [d("2027-01-31"), d("2027-01-24")])
            #expect(try BalanceService.history(db, accountId: fx.spaar.id!).isEmpty)
        }
    }

    @Test func importcontrole() throws {
        let fx = try Fixture()
        try fx.app.write { db in
            var batch = ImportBatch(accountId: fx.betaal.id!, fileName: "test.csv", rowCount: 3, newCount: 3,
                                    firstDay: d("2027-01-05"), lastDay: d("2027-01-20"),
                                    openingBalance: c(100_000), closingBalance: c(92_500))
            try batch.insert(db)
            let t1 = try fx.tx(db, fx.betaal, "2027-01-05", -5_000, batchId: batch.id)
            let t2 = try fx.tx(db, fx.betaal, "2027-01-12", -2_000, batchId: batch.id)
            let t3 = try fx.tx(db, fx.betaal, "2027-01-20", -500, batchId: batch.id)

            var check = try BalanceService.importCheck(db, batchId: batch.id!)
            #expect(check.transactionCount == 3 && check.newCount == 3)
            #expect(!check.allHandled && !check.balanceIsMeaningful && check.balanceMatches == nil)
            #expect(check.summary.contains("niet geboekt"))

            for t in [t1, t2] {
                try BookingService.book(db, bankTransactionId: t.id!, allocations: [Allocation(amount: t.amount, label: "x")])
            }
            check = try BalanceService.importCheck(db, batchId: batch.id!)
            #expect(check.newCount == 1 && check.processedCount == 2)
            #expect(check.balanceMatches == nil)

            try BookingService.book(db, bankTransactionId: t3.id!, allocations: [Allocation(amount: t3.amount, label: "x")])
            check = try BalanceService.importCheck(db, batchId: batch.id!)
            #expect(check.allHandled)
            #expect(check.calculatedBalance == c(92_500))
            #expect(check.difference == .zero && check.balanceMatches == true)

            // Overslaan haalt de regel uit het saldo: de controle meldt het verschil en de overgeslagen regel.
            try BookingService.unbook(db, bankTransactionId: t3.id!)
            try BookingService.skip(db, bankTransactionId: t3.id!)
            check = try BalanceService.importCheck(db, batchId: batch.id!)
            #expect(check.allHandled && check.skippedCount == 1 && check.skippedUpToLastDay == 1)
            #expect(check.balanceMatches == false && check.difference == c(500))
            #expect(check.summary.contains("overgeslagen"))

            // Een oudere, nog niet geboekte transactie van dezelfde rekening maakt de vergelijking zinloos.
            try fx.tx(db, fx.betaal, "2027-01-02", -100)
            check = try BalanceService.importCheck(db, batchId: batch.id!)
            #expect(check.allHandled && check.openUpToLastDay == 1 && check.balanceMatches == nil)

            var zonderSaldo = ImportBatch(accountId: fx.spaar.id!, fileName: "leeg.csv")
            try zonderSaldo.insert(db)
            let leeg = try BalanceService.importCheck(db, batchId: zonderSaldo.id!)
            #expect(leeg.difference == nil && leeg.balanceMatches == nil && leeg.lastDay == nil)
        }
    }
}

@Suite struct YearTests {
    @Test func planVanReserveringenBlijftGelijkAanSomVanResRegels() throws {
        let fx = try Fixture()
        try fx.app.write { db in
            func total() throws -> Money { try BudgetItem.fetchOne(db, key: fx.reserveringen.id!)!.planAmount }
            #expect(try total() == c(-25_000))
            let extra = try YearService.createItem(db, BudgetItem(yearId: fx.year.id!, label: "Auto", direction: .RES,
                                                                  planAmount: c(-5_000)))
            #expect(try total() == c(-30_000))
            var changed = fx.resVakantie
            changed.planAmount = c(-20_000)
            try YearService.updateItem(db, changed)
            #expect(try total() == c(-35_000))
            try YearService.deleteItem(db, itemId: extra.id!)
            #expect(try total() == c(-30_000))
            // Een plan dat de aanroeper zelf op de totaalregel zet, wordt overschreven.
            var manual = try BudgetItem.fetchOne(db, key: fx.reserveringen.id!)!
            manual.planAmount = c(-1)
            #expect(try YearService.updateItem(db, manual).planAmount == c(-30_000))

            #expect(throws: BudgetError.reserveTotalExists(year: 2027)) {
                try YearService.createItem(db, BudgetItem(yearId: fx.year.id!, label: "Nog een", direction: .UIT,
                                                          planAmount: .zero, isReserveTotal: true))
            }
            #expect(throws: BudgetError.reserveTotalExists(year: 2027)) {
                var second = fx.boodschappen
                second.isReserveTotal = true
                try YearService.updateItem(db, second)
            }
        }
    }

    @Test func tekenEnVeldvalidatieVanPosten() throws {
        let fx = try Fixture()
        try fx.app.write { db in
            func make(_ direction: Direction, _ cents: Int64, frequency: Frequency = .maand, months: String = "") throws -> BudgetItem {
                try YearService.createItem(db, BudgetItem(yearId: fx.year.id!, label: "Test", direction: direction,
                                                          planAmount: c(cents), frequency: frequency, expectedMonths: months))
            }
            #expect(throws: BudgetError.signMismatch(direction: .IN)) { try make(.IN, -1) }
            #expect(throws: BudgetError.signMismatch(direction: .UIT)) { try make(.UIT, 1) }
            #expect(throws: BudgetError.signMismatch(direction: .RES)) { try make(.RES, 1) }
            #expect(throws: BudgetError.self) { try make(.UIT, -100, frequency: .kwartaal) }
            #expect(throws: BudgetError.self) { try make(.UIT, -100, frequency: .jaar, months: "13") }
            let quarterly = try make(.UIT, -100, frequency: .kwartaal, months: "10, 1,4,7")
            #expect(quarterly.expectedMonths == "1,4,7,10")
            #expect(quarterly.months == [1, 4, 7, 10])
            #expect(try make(.UIT, 0).sortOrder > quarterly.sortOrder)
            #expect(throws: BudgetError.yearClosed(2027)) {
                try YearService.closeYear(db, year: 2027)
                defer { try? YearService.reopenYear(db, year: 2027) }
                try YearService.updateBuffers(db, year: 2027, antiRood: .zero, tijdelijkAntiRood: .zero)
            }
        }
    }

    @Test func postMetBoekingenVerwijderen() throws {
        let fx = try Fixture()
        try fx.app.write { db in
            let entry = try EntryService.create(db, EntryDraft(accountId: fx.betaal.id!, day: d("2027-02-01"),
                                                               amount: c(-4_500), label: "Supermarkt",
                                                               budgetItemId: fx.boodschappen.id))
            #expect(throws: BudgetError.itemHasEntries(item: "Boodschappen", count: 1)) {
                try YearService.deleteItem(db, itemId: fx.boodschappen.id!)
            }
            #expect(throws: BudgetError.itemHasEntries(item: "Boodschappen", count: 1)) {
                var res = fx.boodschappen
                res.direction = .RES
                try YearService.updateItem(db, res)
            }
            try YearService.deleteItem(db, itemId: fx.boodschappen.id!, convertEntriesToDivers: true)
            let after = try #require(try Entry.fetchOne(db, key: entry.id!))
            #expect(after.budgetItemId == nil)
            #expect(after.amount == c(-4_500))
            #expect(try BudgetItem.fetchOne(db, key: fx.boodschappen.id!) == nil)
        }
    }

    @Test func jaarKopieren() throws {
        let fx = try Fixture()
        try fx.app.write { db in
            try YearService.updateBuffers(db, year: 2027, antiRood: c(50_000), tijdelijkAntiRood: c(10_000))
            var q = fx.boodschappen
            q.frequency = .kwartaal; q.expectedMonths = "1,4,7,10"; q.expectedDay = 3
            try YearService.updateItem(db, q)
            try YearService.reorderItems(db, yearId: fx.year.id!, orderedIds: [
                fx.reserveringen.id!, fx.salaris.id!, fx.boodschappen.id!, fx.resVakantie.id!, fx.resVerzekering.id!])
            try EntryService.create(db, EntryDraft(accountId: fx.betaal.id!, day: d("2027-02-01"), amount: c(-100),
                                                   label: "x", budgetItemId: fx.boodschappen.id))

            let copy = try YearService.createYear(db, year: 2028, copyingFrom: 2027)
            #expect(copy.antiRood == c(50_000) && copy.tijdelijkAntiRood == c(10_000))
            #expect(copy.closed == false)
            func items(_ yearId: Int64) throws -> [BudgetItem] {
                try BudgetItem.fetchAll(db, sql: "SELECT * FROM budgetItem WHERE yearId = ? ORDER BY sortOrder", arguments: [yearId])
            }
            let source = try items(fx.year.id!), target = try items(copy.id!)
            #expect(target.map(\.label) == ["RESERVERINGEN", "Salaris", "Boodschappen", "Vakantie", "Verzekering"])
            #expect(target.count == source.count)
            for (s, t) in zip(source, target) {
                var expected = s
                expected.id = t.id; expected.yearId = copy.id!
                #expect(t == expected)
            }
            #expect(target[0].planAmount == c(-25_000))
            #expect(target[3].potId == fx.potVakantie.id)
            let copied = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM entry WHERE budgetItemId IN (SELECT id FROM budgetItem WHERE yearId = ?)
                """, arguments: [copy.id]) ?? -1
            #expect(copied == 0)

            #expect(throws: BudgetError.yearExists(2028)) { try YearService.createYear(db, year: 2028, copyingFrom: 2027) }
            #expect(throws: BudgetError.yearExists(2027)) { try YearService.createYear(db, year: 2027) }
            #expect(throws: BudgetError.yearMissing(2030)) { try YearService.createYear(db, year: 2031, copyingFrom: 2030) }
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM budgetYear") == 2)
        }
    }
}

@Suite struct AccountAndTagTests {
    @Test func rekeningenBeheren() throws {
        let fx = try Fixture()
        try fx.app.write { db in
            let created = try AccountService.create(db, Account(name: " Extra ", iban: "nl00 test 0000 0000 07",
                                                                kind: .betaal, openingDate: d("2027-01-01")))
            #expect(created.iban == "NL00TEST0000000007")
            #expect(created.name == "Extra")
            #expect(created.sortOrder == 2)
            #expect(throws: BudgetError.duplicateIban("NL00TEST0000000001")) {
                try AccountService.create(db, Account(name: "Dubbel", iban: "nl00test0000000001", kind: .spaar,
                                                      openingDate: d("2027-01-01")))
            }
            #expect(throws: BudgetError.self) {
                try AccountService.create(db, Account(name: "Fout", iban: "NL00-TEST", kind: .spaar, openingDate: d("2027-01-01")))
            }
            let zonderIban = try AccountService.create(db, Account(name: "Contant", iban: "  ", kind: .betaal,
                                                                   openingDate: d("2027-01-01")))
            #expect(zonderIban.iban == nil)

            var changed = fx.betaal
            changed.name = "Hoofdrekening"; changed.iban = Fixture.betaalIban.lowercased()
            #expect(try AccountService.update(db, changed).name == "Hoofdrekening")
            try EntryService.create(db, EntryDraft(accountId: fx.betaal.id!, day: d("2027-01-05"), amount: c(-1), label: "x"))
            changed.openingDate = d("2027-01-06")
            #expect(throws: BudgetError.self) { try AccountService.update(db, changed) }
            var kind = fx.spaar
            kind.kind = .betaal
            #expect(throws: BudgetError.self) { try AccountService.update(db, kind) }

            #expect(throws: BudgetError.accountInUse(account: "Hoofdrekening")) {
                try AccountService.delete(db, accountId: fx.betaal.id!)
            }
            try AccountService.delete(db, accountId: zonderIban.id!)
            try AccountService.setArchived(db, accountId: created.id!, true)
            #expect(try Account.fetchOne(db, key: created.id!)!.archived)
            try AccountService.reorder(db, orderedIds: [created.id!, fx.spaar.id!, fx.betaal.id!])
            #expect(try Int64.fetchAll(db, sql: "SELECT id FROM account ORDER BY sortOrder")
                    == [created.id!, fx.spaar.id!, fx.betaal.id!])
        }
    }

    @Test func tagsBeheren() throws {
        let fx = try Fixture()
        try fx.app.write { db in
            let a = try TagService.create(db, name: "tanken", color: "#ff8800")
            let b = try TagService.create(db, name: "uit eten")
            #expect(a.color == "#FF8800")
            #expect(throws: BudgetError.duplicateName("Tanken")) { try TagService.create(db, name: "Tanken") }
            #expect(throws: BudgetError.self) { try TagService.create(db, name: "kleur", color: "rood") }
            var renamed = b
            renamed.name = "restaurant"
            #expect(try TagService.update(db, renamed).name == "restaurant")
            try TagService.reorder(db, orderedIds: [b.id!, a.id!])
            #expect(try Int64.fetchAll(db, sql: "SELECT id FROM tag ORDER BY sortOrder") == [b.id!, a.id!])

            let entry = try EntryService.create(db, EntryDraft(accountId: fx.betaal.id!, day: d("2027-01-05"),
                                                               amount: c(-1), label: "x", tagIds: [a.id!, b.id!]))
            try TagService.delete(db, tagId: a.id!)
            #expect(try EntryService.tagIds(db, entryId: entry.id!) == [b.id!])
        }
    }

    @Test func foutmeldingenZijnNederlands() {
        let message = BudgetError.allocationSumMismatch(expected: c(-8_000), actual: c(-7_500)).localizedDescription
        #expect(message.contains("€ 75,00") && message.contains("€ 80,00"))
        #expect(BudgetError.potNotEmpty(pot: "Vakantie", balance: c(1_000)).localizedDescription.contains("€ 10,00"))
    }
}
