import Foundation
import GRDB
import HFCore
import Testing
@testable import HFBudget

@Suite struct TransferTests {
    @Test func paarWordtGevondenGekoppeldEnNietOpnieuwGevonden() throws {
        let fx = try Fixture()
        try fx.app.write { db in
            let out = try fx.tx(db, fx.betaal, "2027-01-27", -25_000, iban: "nl00 test 0000 0000 02")
            let into = try fx.tx(db, fx.spaar, "2027-01-28", 25_000, iban: Fixture.betaalIban)
            // Ruis: zelfde bedrag maar vreemde tegenrekening, en een te late bijschrijving.
            try fx.tx(db, fx.spaar, "2027-01-28", 25_000, iban: "NL00TEST0000000099")
            try fx.tx(db, fx.betaal, "2027-02-01", -9_000, iban: Fixture.spaarIban)
            try fx.tx(db, fx.spaar, "2027-02-05", 9_000, iban: Fixture.betaalIban)

            let pairs = try TransferService.findTransferPairs(db)
            #expect(pairs.count == 1)
            #expect(pairs[0].from.id == out.id)
            #expect(pairs[0].to.id == into.id)

            try TransferService.linkTransfer(db, fromBankTransactionId: out.id!, toBankTransactionId: into.id!)
            let a = try fx.entries(db, tx: out.id!), b = try fx.entries(db, tx: into.id!)
            #expect(a.count == 1 && b.count == 1)
            #expect(a[0].counterEntryId == b[0].id)
            #expect(b[0].counterEntryId == a[0].id)
            #expect(a[0].label == "Overboeking naar Testspaar")
            #expect(b[0].label == "Overboeking van Testbetaal")
            #expect(try fx.status(db, out.id!) == .verwerkt)
            #expect(try fx.status(db, into.id!) == .verwerkt)
            #expect(try TransferService.findTransferPairs(db).isEmpty)
            #expect(throws: BudgetError.alreadyLinked) {
                try TransferService.linkTransfer(db, fromBankTransactionId: out.id!, toBankTransactionId: into.id!)
            }

            try TransferService.unlinkTransfer(db, bankTransactionId: into.id!)
            #expect(try fx.entries(db, tx: out.id!)[0].counterEntryId == nil)
            #expect(try fx.entries(db, tx: into.id!)[0].counterEntryId == nil)
            #expect(try TransferService.findTransferPairs(db).count == 1)
            #expect(throws: BudgetError.notLinked) { try TransferService.unlinkTransfer(db, bankTransactionId: into.id!) }
        }
    }

    @Test func elkeTransactieZitInHoogstensEenPaar() throws {
        let fx = try Fixture()
        try fx.app.write { db in
            let out1 = try fx.tx(db, fx.betaal, "2027-03-01", -5_000, iban: Fixture.spaarIban)
            let out2 = try fx.tx(db, fx.betaal, "2027-03-02", -5_000, iban: Fixture.spaarIban)
            let in1 = try fx.tx(db, fx.spaar, "2027-03-01", 5_000, iban: Fixture.betaalIban)
            let in2 = try fx.tx(db, fx.spaar, "2027-03-03", 5_000, iban: Fixture.betaalIban)
            let pairs = try TransferService.findTransferPairs(db)
            #expect(pairs.map { [$0.from.id!, $0.to.id!] } == [[out1.id!, in1.id!], [out2.id!, in2.id!]])
        }
    }

    @Test func koppelenMetGesplitsteKantEnOngeldigeParen() throws {
        let fx = try Fixture()
        try fx.app.write { db in
            let out = try fx.tx(db, fx.betaal, "2027-01-27", -25_000, iban: Fixture.spaarIban)
            let into = try fx.tx(db, fx.spaar, "2027-01-27", 25_000, iban: Fixture.betaalIban)
            try BookingService.book(db, bankTransactionId: out.id!, allocations: [
                Allocation(amount: c(-25_000), label: "Reserveringen", budgetItemId: fx.reserveringen.id)])
            let split = try #require(try PotService.distribution(db, for: c(25_000), accountId: fx.spaar.id!))
            try BookingService.book(db, bankTransactionId: into.id!, allocations: split)
            try TransferService.linkTransfer(db, fromBankTransactionId: out.id!, toBankTransactionId: into.id!)
            let a = try fx.entries(db, tx: out.id!), b = try fx.entries(db, tx: into.id!)
            #expect(a[0].counterEntryId == b[0].id)
            #expect(b.allSatisfy { $0.counterEntryId == a[0].id })
            #expect(a[0].budgetItemId == fx.reserveringen.id)

            let other = try fx.tx(db, fx.betaal, "2027-02-01", -100)
            let same = try fx.tx(db, fx.betaal, "2027-02-01", 100)
            let wrong = try fx.tx(db, fx.spaar, "2027-02-01", 99)
            #expect(throws: BudgetError.self) {
                try TransferService.linkTransfer(db, fromBankTransactionId: other.id!, toBankTransactionId: same.id!)
            }
            #expect(throws: BudgetError.self) {
                try TransferService.linkTransfer(db, fromBankTransactionId: other.id!, toBankTransactionId: wrong.id!)
            }
            #expect(try fx.status(db, other.id!) == .nieuw)
        }
    }
}

@Suite struct PotTests {
    @Test func verdelenOverReserveringspotten() throws {
        let fx = try Fixture()
        try fx.app.write { db in
            let split = try #require(try PotService.distribution(db, for: c(25_000), accountId: fx.spaar.id!))
            #expect(split.map(\.amount) == [c(10_000), c(15_000)])
            #expect(split.map(\.potId) == [fx.potVerzekering.id, fx.potVakantie.id])
            #expect(split.map(\.label) == ["Verzekering", "Vakantie"])
            #expect(try PotService.distribution(db, for: c(24_999), accountId: fx.spaar.id!) == nil)
            #expect(try PotService.distribution(db, for: c(27_500), accountId: fx.spaar.id!) == nil)
            #expect(try PotService.distribution(db, for: c(25_000), accountId: fx.betaal.id!) == nil)

            let t = try fx.tx(db, fx.spaar, "2027-01-28", 25_000)
            try BookingService.book(db, bankTransactionId: t.id!, allocations: split)
            #expect(try PotService.balance(db, potId: fx.potVerzekering.id!) == c(10_000))
            #expect(try PotService.balance(db, potId: fx.potVakantie.id!) == c(15_000))
        }
    }

    @Test func verplaatsenTussenPottenTeltOpTotNul() throws {
        let fx = try Fixture()
        try fx.app.write { db in
            let before = try BalanceService.balance(db, accountId: fx.spaar.id!, on: d("2027-12-31"))
            let move = try PotService.moveBetweenPots(db, from: fx.potVakantie.id!, to: fx.potSpaar.id!,
                                                      amount: c(4_000), day: d("2027-02-01"), label: "Schuiven")
            #expect(move.from.amount + move.to.amount == .zero)
            #expect(move.from.accountId == move.to.accountId)
            #expect(try PotService.balance(db, potId: fx.potVakantie.id!) == c(-4_000))
            #expect(try PotService.balance(db, potId: fx.potSpaar.id!) == c(4_000))
            #expect(try BalanceService.balance(db, accountId: fx.spaar.id!, on: d("2027-12-31")) == before)
            #expect(throws: BudgetError.self) {
                try PotService.moveBetweenPots(db, from: fx.potVakantie.id!, to: fx.potVakantie.id!,
                                               amount: c(1), day: d("2027-02-01"), label: "x")
            }
            #expect(throws: BudgetError.self) {
                try PotService.moveBetweenPots(db, from: fx.potVakantie.id!, to: fx.potSpaar.id!,
                                               amount: c(-1), day: d("2027-02-01"), label: "x")
            }
        }
    }

    /// Potje opheffen: het hele saldo gaat naar een ander potje en het potje wordt gearchiveerd, in één keer.
    @Test func potjeOpheffenNaarAnderPotje() throws {
        let fx = try Fixture()
        try fx.app.write { db in
            try PotService.moveBetweenPots(db, from: fx.potVakantie.id!, to: fx.potSpaar.id!,
                                           amount: c(4_000), day: d("2027-02-01"), label: "Schuiven")
            let verzekering = try PotService.balance(db, potId: fx.potVerzekering.id!)
            let rekening = try BalanceService.balance(db, accountId: fx.spaar.id!, on: d("2027-12-31"))
            // Saldo positief zonder bestemming: kan niet.
            #expect(throws: BudgetError.self) {
                try PotService.close(db, potId: fx.potSpaar.id!, toPotId: nil, day: d("2027-03-01"))
            }
            try PotService.close(db, potId: fx.potSpaar.id!, toPotId: fx.potVerzekering.id!, day: d("2027-03-01"))
            #expect(try PotService.balance(db, potId: fx.potSpaar.id!) == .zero)
            #expect(try PotService.balance(db, potId: fx.potVerzekering.id!) == verzekering + c(4_000))
            #expect(try Pot.fetchOne(db, key: fx.potSpaar.id!)?.archived == true)
            #expect(try BalanceService.balance(db, accountId: fx.spaar.id!, on: d("2027-12-31")) == rekening)
            // Een potje in de min moet eerst worden aangevuld.
            #expect(throws: BudgetError.self) {
                try PotService.close(db, potId: fx.potVakantie.id!, toPotId: fx.potVerzekering.id!, day: d("2027-03-01"))
            }
            #expect(try Pot.fetchOne(db, key: fx.potVakantie.id!)?.archived == false)
        }
    }

    /// De schakelaar "Reken met eerdere uitgaven" blijft staan als je het potje wijzigt; eenmalig per boeking.
    @Test func vooruitblikMetEerdereUitgaven() throws {
        let fx = try Fixture()
        try fx.app.write { db in
            try PotService.setForecastFromHistory(db, potId: fx.potVakantie.id!, true)
            var pot = try Pot.fetchOne(db, key: fx.potVakantie.id!)!
            #expect(pot.forecastFromHistory)
            pot.forecastFromHistory = false
            pot.name = "Vakantie zomer"
            try PotService.update(db, pot)
            #expect(try Pot.fetchOne(db, key: fx.potVakantie.id!)?.forecastFromHistory == true)
            let move = try PotService.moveBetweenPots(db, from: fx.potVakantie.id!, to: fx.potSpaar.id!,
                                                      amount: c(1_000), day: d("2027-02-01"), label: "x")
            try PotService.setForecastOneOff(db, entryId: move.from.id!, true)
            #expect(try Entry.fetchOne(db, key: move.from.id!)?.forecastOneOff == true)
        }
    }

    @Test func potBeherenArchiverenEnVolgorde() throws {
        let fx = try Fixture()
        try fx.app.write { db in
            #expect(throws: BudgetError.self) {
                try PotService.create(db, Pot(accountId: fx.betaal.id!, name: "Fout", kind: .spaar))
            }
            #expect(throws: BudgetError.self) {
                try PotService.create(db, Pot(accountId: fx.spaar.id!, name: "  ", kind: .spaar))
            }
            var pot = fx.potSpaar
            pot.name = "Spaarpot kind B"; pot.targetAmount = c(100_000)
            #expect(try PotService.update(db, pot).name == "Spaarpot kind B")

            try EntryService.create(db, EntryDraft(accountId: fx.spaar.id!, day: d("2027-02-01"), amount: c(1_000),
                                                   label: "Storting", potId: pot.id))
            #expect(throws: BudgetError.potNotEmpty(pot: "Spaarpot kind B", balance: c(1_000))) {
                try PotService.archive(db, potId: pot.id!)
            }
            #expect(throws: BudgetError.potHasEntries(pot: "Spaarpot kind B")) { try PotService.delete(db, potId: pot.id!) }
            try EntryService.create(db, EntryDraft(accountId: fx.spaar.id!, day: d("2027-02-02"), amount: c(-1_000),
                                                   label: "Opname", potId: pot.id))
            try PotService.archive(db, potId: pot.id!)
            #expect(try Pot.fetchOne(db, key: pot.id!)!.archived)
            try PotService.unarchive(db, potId: pot.id!)

            let ids = [fx.potSpaar.id!, fx.potVerzekering.id!, fx.potVakantie.id!]
            try PotService.reorder(db, accountId: fx.spaar.id!, orderedIds: ids)
            let ordered = try Int64.fetchAll(db, sql: "SELECT id FROM pot WHERE accountId = ? ORDER BY sortOrder",
                                             arguments: [fx.spaar.id])
            #expect(ordered == ids)
            #expect(throws: BudgetError.self) {
                try PotService.reorder(db, accountId: fx.spaar.id!, orderedIds: [fx.potSpaar.id!])
            }
            try PotService.delete(db, potId: try PotService.create(db, Pot(accountId: fx.spaar.id!, name: "Leeg", kind: .spaar)).id!)
        }
    }
}

@Suite struct SavingsTransferTests {
    @Test func levenscyclusVanVergoeding() throws {
        let fx = try Fixture()
        try fx.app.write { db in
            let t1 = try fx.tx(db, fx.betaal, "2027-04-01", -12_000)
            let t2 = try fx.tx(db, fx.betaal, "2027-04-03", -3_050)
            let t3 = try fx.tx(db, fx.betaal, "2027-04-04", -700)
            let e1 = try BookingService.book(db, bankTransactionId: t1.id!, allocations: [
                Allocation(amount: c(-12_000), label: "Tandarts", potId: fx.potVerzekering.id, reimburse: true)])[0]
            let e2 = try BookingService.book(db, bankTransactionId: t2.id!, allocations: [
                Allocation(amount: c(-3_050), label: "Schoolreis", reimburse: true)])[0]
            let e3 = try BookingService.book(db, bankTransactionId: t3.id!, allocations: [
                Allocation(amount: c(-700), label: "Gewoon")])[0]

            let open = try SavingsTransferService.openReimbursements(db)
            #expect(open.entries.map(\.id) == [e1.id, e2.id])
            #expect(open.total == c(15_050))

            #expect(throws: BudgetError.notReimbursable(entry: "Gewoon")) {
                try SavingsTransferService.createSavingsTransfer(db, entryIds: [e1.id!, e3.id!], day: d("2027-04-05"))
            }
            let transfer = try SavingsTransferService.createSavingsTransfer(db, entryIds: [e1.id!, e2.id!], day: d("2027-04-05"))
            #expect(transfer.amount == c(15_050))
            #expect(transfer.done == false)
            #expect(try SavingsTransferService.entries(db, savingsTransferId: transfer.id!).count == 2)
            #expect(try SavingsTransferService.openReimbursements(db).total == .zero)
            #expect(throws: BudgetError.notReimbursable(entry: "Tandarts")) {
                try SavingsTransferService.createSavingsTransfer(db, entryIds: [e1.id!], day: d("2027-04-06"))
            }

            // Vergoeden uitzetten, opnieuw boeken of ongedaan maken wordt geweigerd zolang de overboeking bestaat.
            #expect(throws: BudgetError.inSavingsTransfer) { try EntryService.setReimburse(db, entryId: e1.id!, false) }
            #expect(throws: BudgetError.inSavingsTransfer) { try BookingService.unbook(db, bankTransactionId: t1.id!) }
            #expect(throws: BudgetError.inSavingsTransfer) {
                try BookingService.book(db, bankTransactionId: t1.id!, allocations: [Allocation(amount: c(-12_000), label: "x")])
            }

            let done = try SavingsTransferService.markDone(db, savingsTransferId: transfer.id!, on: d("2027-04-05"))
            #expect(done.done && done.doneAt != nil)
            let reopened = try SavingsTransferService.reopen(db, savingsTransferId: transfer.id!)
            #expect(!reopened.done && reopened.doneAt == nil)

            try SavingsTransferService.delete(db, savingsTransferId: transfer.id!)
            #expect(try SavingsTransferService.openReimbursements(db).total == c(15_050))
            try EntryService.setReimburse(db, entryId: e1.id!, false)
            #expect(try Entry.fetchOne(db, key: e1.id!)!.potId == nil)
            #expect(try SavingsTransferService.openReimbursements(db).total == c(3_050))
            try EntryService.setReimburse(db, entryId: e3.id!, true, potId: fx.potVakantie.id)
            #expect(try SavingsTransferService.openReimbursements(db).total == c(3_750))
        }
    }
}
