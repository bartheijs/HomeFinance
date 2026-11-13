import Foundation
import GRDB
import HFCore
import Testing
@testable import HFBudget

@Suite struct BookingTests {
    @Test func boekenZetStatusEnMaaktBoeking() throws {
        let fx = try Fixture()
        try fx.app.write { db in
            let t = try fx.tx(db, fx.betaal, "2027-01-25", 300_000)
            let entries = try BookingService.book(db, bankTransactionId: t.id!, allocations: [
                Allocation(amount: c(300_000), label: "Salaris januari", budgetItemId: fx.salaris.id),
            ])
            #expect(entries.count == 1)
            #expect(entries[0].reviewed == false)
            #expect(entries[0].day == d("2027-01-25"))
            #expect(entries[0].accountId == fx.betaal.id)
            #expect(try fx.status(db, t.id!) == .verwerkt)
        }
    }

    @Test func splitsingMoetOptellenTotBankbedrag() throws {
        let fx = try Fixture()
        try fx.app.write { db in
            let t = try fx.tx(db, fx.betaal, "2027-01-10", -8_000)
            #expect(throws: BudgetError.allocationSumMismatch(expected: c(-8_000), actual: c(-7_500))) {
                try BookingService.book(db, bankTransactionId: t.id!, allocations: [
                    Allocation(amount: c(-5_000), label: "Boodschappen", budgetItemId: fx.boodschappen.id),
                    Allocation(amount: c(-2_500), label: "Cadeau"),
                ])
            }
            #expect(try fx.entries(db, tx: t.id!).isEmpty)
            #expect(try fx.status(db, t.id!) == .nieuw)
            #expect(throws: BudgetError.allocationsEmpty) {
                try BookingService.book(db, bankTransactionId: t.id!, allocations: [])
            }
            try BookingService.book(db, bankTransactionId: t.id!, allocations: [
                Allocation(amount: c(-5_000), label: "Boodschappen", budgetItemId: fx.boodschappen.id),
                Allocation(amount: c(-3_000), label: "Cadeau"),
            ])
            #expect(try fx.entries(db, tx: t.id!).map(\.amount) == [c(-5_000), c(-3_000)])
        }
    }

    @Test func opnieuwBoekenVervangtBestaandeBoekingenEnTags() throws {
        let fx = try Fixture()
        try fx.app.write { db in
            let tag = try TagService.create(db, name: "tanken")
            let t = try fx.tx(db, fx.betaal, "2027-02-03", -6_000)
            try BookingService.book(db, bankTransactionId: t.id!, allocations: [
                Allocation(amount: c(-6_000), label: "Eerste poging"),
            ])
            let entries = try BookingService.book(db, bankTransactionId: t.id!, allocations: [
                Allocation(amount: c(-4_000), label: "Tanken", tagIds: [tag.id!], note: "notitie", confidence: .midden),
                Allocation(amount: c(-2_000), label: "Winkel"),
            ])
            #expect(try fx.entries(db, tx: t.id!).map(\.label) == ["Tanken", "Winkel"])
            #expect(try EntryService.tagIds(db, entryId: entries[0].id!) == [tag.id!])
            #expect(entries[0].confidence == .midden)
        }
    }

    @Test func afgeslotenJaarWeigertBoeken() throws {
        let fx = try Fixture()
        try fx.app.write { db in
            let t = try fx.tx(db, fx.betaal, "2027-03-01", -1_000)
            let booked = try fx.tx(db, fx.betaal, "2027-03-02", -2_000)
            try BookingService.book(db, bankTransactionId: booked.id!, allocations: [Allocation(amount: c(-2_000), label: "x")])
            try YearService.closeYear(db, year: 2027)
            #expect(throws: BudgetError.yearClosed(2027)) {
                try BookingService.book(db, bankTransactionId: t.id!, allocations: [Allocation(amount: c(-1_000), label: "x")])
            }
            #expect(throws: BudgetError.yearClosed(2027)) { try BookingService.unbook(db, bankTransactionId: booked.id!) }
            #expect(throws: BudgetError.yearClosed(2027)) {
                try EntryService.create(db, EntryDraft(accountId: fx.betaal.id!, day: d("2027-06-01"), amount: c(-100), label: "x"))
            }
            let entry = try fx.entries(db, tx: booked.id!)[0]
            #expect(throws: BudgetError.yearClosed(2027)) { try EntryService.setReviewed(db, entryIds: [entry.id!], true) }
            #expect(throws: BudgetError.yearClosed(2027)) {
                try YearService.createItem(db, BudgetItem(yearId: fx.year.id!, label: "Nieuw", direction: .UIT, planAmount: c(-100)))
            }
            #expect(throws: BudgetError.yearClosed(2027)) { try YearService.deleteItem(db, itemId: fx.boodschappen.id!) }
            #expect(BudgetError.yearClosed(2027).errorDescription?.contains("afgesloten") == true)
            try YearService.reopenYear(db, year: 2027)
            try BookingService.book(db, bankTransactionId: t.id!, allocations: [Allocation(amount: c(-1_000), label: "x")])
        }
    }

    @Test func betaalrekeningValidatie() throws {
        let fx = try Fixture()
        try fx.app.write { db in
            let y2028 = try YearService.createYear(db, year: 2028)
            let item2028 = try YearService.createItem(db, BudgetItem(yearId: y2028.id!, label: "Boodschappen",
                                                                     direction: .UIT, planAmount: c(-100)))
            let t = try fx.tx(db, fx.betaal, "2027-01-10", -5_000)
            func book(_ a: Allocation) throws { try BookingService.book(db, bankTransactionId: t.id!, allocations: [a]) }

            #expect(throws: BudgetError.itemWrongYear(item: "Boodschappen", day: d("2027-01-10"))) {
                try book(Allocation(amount: c(-5_000), label: "x", budgetItemId: item2028.id))
            }
            #expect(throws: BudgetError.resItemNoEntries(item: "Verzekering")) {
                try book(Allocation(amount: c(-5_000), label: "x", budgetItemId: fx.resVerzekering.id))
            }
            #expect(throws: BudgetError.potRequiresReimburse) {
                try book(Allocation(amount: c(-5_000), label: "x", potId: fx.potVakantie.id))
            }
            // Pot mag wel samen met vergoeden; de regel RESERVERINGEN mag boekingen krijgen.
            try book(Allocation(amount: c(-5_000), label: "Vakantiehuis", potId: fx.potVakantie.id, reimburse: true))
            try book(Allocation(amount: c(-5_000), label: "Reserveringen", budgetItemId: fx.reserveringen.id))

            let plus = try fx.tx(db, fx.betaal, "2027-01-11", 5_000)
            #expect(throws: BudgetError.reimburseNotExpense) {
                try BookingService.book(db, bankTransactionId: plus.id!, allocations: [
                    Allocation(amount: c(5_000), label: "x", reimburse: true)])
            }
        }
    }

    @Test func spaarrekeningValidatie() throws {
        let fx = try Fixture()
        try fx.app.write { db in
            let spaar2 = try AccountService.create(db, Account(name: "Testspaar 2", iban: "NL00TEST0000000003",
                                                               kind: .spaar, openingDate: d("2027-01-01")))
            let vreemdePot = try PotService.create(db, Pot(accountId: spaar2.id!, name: "Andere pot", kind: .spaar))
            let t = try fx.tx(db, fx.spaar, "2027-01-28", 25_000)
            func book(_ a: Allocation) throws { try BookingService.book(db, bankTransactionId: t.id!, allocations: [a]) }

            #expect(throws: BudgetError.budgetItemOnSavings) {
                try book(Allocation(amount: c(25_000), label: "x", budgetItemId: fx.salaris.id))
            }
            #expect(throws: BudgetError.potWrongAccount(pot: "Andere pot")) {
                try book(Allocation(amount: c(25_000), label: "x", potId: vreemdePot.id))
            }
            #expect(throws: BudgetError.reimburseOnSavings) {
                try book(Allocation(amount: c(-25_000 + 50_000), label: "x", reimburse: true))
            }
            try book(Allocation(amount: c(25_000), label: "Storting", potId: fx.potSpaar.id))
            #expect(try PotService.balance(db, potId: fx.potSpaar.id!) == c(25_000))
        }
    }

    @Test func boekingVoorBegindatumWordtGeweigerd() throws {
        let fx = try Fixture()
        try fx.app.write { db in
            let t = try fx.tx(db, fx.betaal, "2026-12-31", -1_000)
            #expect(throws: BudgetError.beforeOpeningDate(account: "Testbetaal", openingDate: d("2027-01-01"))) {
                try BookingService.book(db, bankTransactionId: t.id!, allocations: [Allocation(amount: c(-1_000), label: "x")])
            }
        }
    }

    @Test func ongedaanMakenOverslaanEnTerugzetten() throws {
        let fx = try Fixture()
        try fx.app.write { db in
            let t = try fx.tx(db, fx.betaal, "2027-01-10", -5_000)
            try BookingService.book(db, bankTransactionId: t.id!, allocations: [Allocation(amount: c(-5_000), label: "x")])
            #expect(throws: BudgetError.alreadyBooked) { try BookingService.skip(db, bankTransactionId: t.id!) }
            try BookingService.unbook(db, bankTransactionId: t.id!)
            #expect(try fx.entries(db, tx: t.id!).isEmpty)
            #expect(try fx.status(db, t.id!) == .nieuw)
            #expect(throws: BudgetError.notSkipped) { try BookingService.unskip(db, bankTransactionId: t.id!) }
            try BookingService.skip(db, bankTransactionId: t.id!)
            #expect(try fx.status(db, t.id!) == .overgeslagen)
            try BookingService.unskip(db, bankTransactionId: t.id!)
            #expect(try fx.status(db, t.id!) == .nieuw)
            #expect(throws: BudgetError.notFound(what: "Banktransactie", id: 9_999)) {
                try BookingService.unbook(db, bankTransactionId: 9_999)
            }
        }
    }

    @Test func bulkBoekenIsAllesOfNiets() throws {
        let fx = try Fixture()
        try fx.app.write { db in
            let a = try fx.tx(db, fx.betaal, "2027-01-10", -1_000)
            let b = try fx.tx(db, fx.betaal, "2027-01-11", -2_000)
            #expect(throws: BudgetError.self) {
                try BookingService.bookAll(db, [
                    BookingRequest(bankTransactionId: a.id!, allocations: [Allocation(amount: c(-1_000), label: "a")]),
                    BookingRequest(bankTransactionId: b.id!, allocations: [Allocation(amount: c(-1_999), label: "b")]),
                ])
            }
            #expect(try fx.status(db, a.id!) == .nieuw)
            #expect(try fx.entries(db, tx: a.id!).isEmpty)
            let entries = try BookingService.bookAll(db, [
                BookingRequest(bankTransactionId: a.id!, allocations: [Allocation(amount: c(-1_000), label: "a")]),
                BookingRequest(bankTransactionId: b.id!, allocations: [Allocation(amount: c(-2_000), label: "b")]),
            ])
            #expect(entries.count == 2)
            #expect(try fx.status(db, b.id!) == .verwerkt)
        }
    }
}

@Suite struct EntryTests {
    @Test func handmatigeBoekingMakenWijzigenVerwijderen() throws {
        let fx = try Fixture()
        try fx.app.write { db in
            let tag = try TagService.create(db, name: "uit eten")
            let entry = try EntryService.create(db, EntryDraft(accountId: fx.betaal.id!, day: d("2027-02-01"),
                                                               amount: c(-4_500), label: "Contant", tagIds: [tag.id!]))
            #expect(entry.reviewed)
            #expect(entry.bankTransactionId == nil)
            var draft = try EntryService.draft(db, entryId: entry.id!)
            #expect(draft.tagIds == [tag.id!])
            draft.amount = c(-5_000); draft.day = d("2027-02-02"); draft.budgetItemId = fx.boodschappen.id
            draft.tagIds = []
            let updated = try EntryService.update(db, entryId: entry.id!, draft)
            #expect(updated.amount == c(-5_000))
            #expect(updated.budgetItemId == fx.boodschappen.id)
            #expect(try EntryService.tagIds(db, entryId: entry.id!).isEmpty)
            #expect(throws: BudgetError.resItemNoEntries(item: "Vakantie")) {
                draft.budgetItemId = fx.resVakantie.id
                try EntryService.update(db, entryId: entry.id!, draft)
            }
            try EntryService.delete(db, entryId: entry.id!)
            #expect(try Entry.fetchOne(db, key: entry.id!) == nil)
        }
    }

    @Test func boekingUitBankHoudtBedragEnDag() throws {
        let fx = try Fixture()
        try fx.app.write { db in
            let t = try fx.tx(db, fx.betaal, "2027-01-10", -5_000)
            let entry = try BookingService.book(db, bankTransactionId: t.id!,
                                                allocations: [Allocation(amount: c(-5_000), label: "x")])[0]
            var draft = try EntryService.draft(db, entryId: entry.id!)
            draft.label = "Supermarkt"; draft.budgetItemId = fx.boodschappen.id; draft.note = "week 2"
            let updated = try EntryService.update(db, entryId: entry.id!, draft)
            #expect(updated.label == "Supermarkt")
            #expect(updated.budgetItemId == fx.boodschappen.id)
            draft.amount = c(-4_000)
            #expect(throws: BudgetError.bankEntryImmutable) { try EntryService.update(db, entryId: entry.id!, draft) }
            draft.amount = c(-5_000); draft.day = d("2027-01-11")
            #expect(throws: BudgetError.bankEntryImmutable) { try EntryService.update(db, entryId: entry.id!, draft) }
            #expect(throws: BudgetError.bankEntryDelete) { try EntryService.delete(db, entryId: entry.id!) }
        }
    }

    @Test func nagekekenEnTags() throws {
        let fx = try Fixture()
        try fx.app.write { db in
            let a = try fx.tx(db, fx.betaal, "2027-01-10", -1_000)
            let b = try fx.tx(db, fx.betaal, "2027-01-11", -2_000)
            let s = try fx.tx(db, fx.spaar, "2027-01-11", 2_000)
            let all = try BookingService.bookAll(db, [a, b, s].map {
                BookingRequest(bankTransactionId: $0.id!, allocations: [Allocation(amount: $0.amount, label: "x")])
            })
            try EntryService.setReviewed(db, entryIds: [all[0].id!], true)
            #expect(try Entry.fetchOne(db, key: all[0].id!)!.reviewed)
            try EntryService.setReviewed(db, entryIds: [all[0].id!], false)
            #expect(try EntryService.markAllReviewed(db, accountId: fx.betaal.id!) == 2)
            #expect(try Entry.fetchOne(db, key: all[1].id!)!.reviewed)
            #expect(try Entry.fetchOne(db, key: all[2].id!)!.reviewed == false)

            let t1 = try TagService.create(db, name: "tanken")
            let t2 = try TagService.create(db, name: "uit eten")
            try EntryService.setTags(db, entryId: all[0].id!, tagIds: [t2.id!, t1.id!, t2.id!])
            #expect(try EntryService.tagIds(db, entryId: all[0].id!) == [t1.id!, t2.id!])
            #expect(throws: BudgetError.notFound(what: "Tag", id: 777)) {
                try EntryService.setTags(db, entryId: all[0].id!, tagIds: [777])
            }
            #expect(try EntryService.tagIds(db, entryId: all[0].id!).count == 2)
        }
    }
}
