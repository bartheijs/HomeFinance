import Foundation
import GRDB
import HFCore
import Testing
@testable import HFBudget

// 6h: tags alleen op boekingen van de betaalrekening. Verzonnen testgegevens.
@Suite struct TagOnSavingsTests {
    private func tag(_ db: Database, _ name: String = "Testtag") throws -> Int64 {
        try TagService.create(db, name: name, color: "#3366CC").id!
    }

    @Test func boekenOpSpaarMetTagWordtGeweigerd() throws {
        let fx = try Fixture()
        try fx.app.write { db in
            let tagId = try tag(db)
            let t = try fx.tx(db, fx.spaar, "2027-02-01", 5_000)
            #expect(throws: BudgetError.tagOnSavings) {
                try BookingService.book(db, bankTransactionId: t.id!, allocations: [
                    Allocation(amount: c(5_000), label: "Storting", potId: fx.potVakantie.id, tagIds: [tagId]),
                ])
            }
            #expect(try fx.status(db, t.id!) != .verwerkt)
        }
    }

    @Test func boekenOpBetaalMetTagMag() throws {
        let fx = try Fixture()
        try fx.app.write { db in
            let tagId = try tag(db)
            let t = try fx.tx(db, fx.betaal, "2027-02-01", -4_000)
            let entries = try BookingService.book(db, bankTransactionId: t.id!, allocations: [
                Allocation(amount: c(-4_000), label: "Tanken", tagIds: [tagId]),
            ])
            #expect(try EntryService.tagIds(db, entryId: entries[0].id!) == [tagId])
            #expect(try EntryService.tagsAllowed(db, accountId: fx.betaal.id!))
            #expect(try !EntryService.tagsAllowed(db, accountId: fx.spaar.id!))
        }
    }

    @Test func handmatigeBoekingOpSpaarMetTagWordtGeweigerd() throws {
        let fx = try Fixture()
        try fx.app.write { db in
            let tagId = try tag(db)
            #expect(throws: BudgetError.tagOnSavings) {
                try EntryService.create(db, EntryDraft(accountId: fx.spaar.id!, day: d("2027-02-02"), amount: c(1_000),
                                                       label: "Extra", potId: fx.potVakantie.id, tagIds: [tagId]))
            }
            let ok = try EntryService.create(db, EntryDraft(accountId: fx.betaal.id!, day: d("2027-02-02"),
                                                            amount: c(-1_000), label: "Extra", tagIds: [tagId]))
            #expect(try EntryService.tagIds(db, entryId: ok.id!) == [tagId])
        }
    }

    @Test func setTagsOpSpaarWeigertNieuweTag() throws {
        let fx = try Fixture()
        try fx.app.write { db in
            let tagId = try tag(db)
            let entry = try EntryService.create(db, EntryDraft(accountId: fx.spaar.id!, day: d("2027-02-02"),
                                                               amount: c(1_000), label: "Extra", potId: fx.potVakantie.id))
            #expect(throws: BudgetError.tagOnSavings) {
                try EntryService.setTags(db, entryId: entry.id!, tagIds: [tagId])
            }
            #expect(try EntryService.tagIds(db, entryId: entry.id!).isEmpty)
        }
    }

    @Test func verplaatsenNaarSpaarMetTagWordtGeweigerd() throws {
        let fx = try Fixture()
        try fx.app.write { db in
            let tagId = try tag(db)
            let entry = try EntryService.create(db, EntryDraft(accountId: fx.betaal.id!, day: d("2027-02-02"),
                                                               amount: c(-1_000), label: "Extra", tagIds: [tagId]))
            var draft = try EntryService.draft(db, entryId: entry.id!)
            draft.accountId = fx.spaar.id!
            draft.potId = fx.potVakantie.id
            #expect(throws: BudgetError.tagOnSavings) { try EntryService.update(db, entryId: entry.id!, draft) }
        }
    }

    /// Een tag die al op een spaarboeking stond (van vóór deze regel) blijft staan, mag weg, en blokkeert
    /// het bewerken of opnieuw boeken niet.
    @Test func bestaandeTagOpSpaarBlijftEnMagWeg() throws {
        let fx = try Fixture()
        try fx.app.write { db in
            let oud = try tag(db, "Oud")
            let nieuw = try tag(db, "Nieuw")
            let t = try fx.tx(db, fx.spaar, "2027-02-03", 2_000)
            let entry = try BookingService.book(db, bankTransactionId: t.id!, allocations: [
                Allocation(amount: c(2_000), label: "Storting", potId: fx.potVakantie.id),
            ])[0]
            try EntryTag(entryId: entry.id!, tagId: oud).insert(db)   // zoals in een oudere administratie

            // Label wijzigen met de oude tag erbij mag.
            var draft = try EntryService.draft(db, entryId: entry.id!)
            draft.label = "Storting vakantie"
            try EntryService.update(db, entryId: entry.id!, draft)
            #expect(try EntryService.tagIds(db, entryId: entry.id!) == [oud])

            // Opnieuw boeken met dezelfde tag mag, een andere tag niet.
            #expect(throws: BudgetError.tagOnSavings) {
                try BookingService.book(db, bankTransactionId: t.id!, allocations: [
                    Allocation(amount: c(2_000), label: "Storting", potId: fx.potVakantie.id, tagIds: [oud, nieuw]),
                ])
            }
            let rebooked = try BookingService.book(db, bankTransactionId: t.id!, allocations: [
                Allocation(amount: c(2_000), label: "Storting", potId: fx.potVakantie.id, tagIds: [oud]),
            ])[0]
            #expect(try EntryService.tagIds(db, entryId: rebooked.id!) == [oud])

            // Tag verwijderen mag.
            try EntryService.setTags(db, entryId: rebooked.id!, tagIds: [])
            #expect(try EntryService.tagIds(db, entryId: rebooked.id!).isEmpty)
        }
    }
}
