import Foundation
import GRDB
import HFCore
import Testing
@testable import HFBudget

/// 6g: startbedrag op een verrekentag en "telt mee in nog te besteden". Verzonnen data.
@Suite struct SettlementStartTests {
    @discardableResult
    private func entry(_ db: Database, _ fx: Fixture, _ day: String, _ cents: Int64, _ label: String,
                       tags: [Int64] = []) throws -> Entry {
        try EntryService.create(db, EntryDraft(accountId: fx.betaal.id!, day: d(day), amount: c(cents),
                                               label: label, tagIds: tags))
    }

    @Test func startbedragTeltMeeInOpenstaand() throws {
        let fx = try Fixture()
        try fx.app.write { db in
            let tag = try TagService.create(db, name: "Tanken")
            // Alleen op een tag met verrekenen.
            #expect(throws: BudgetError.tagNotSettling(tag: "Tanken")) {
                try SettlementService.setStart(db, tagId: tag.id!, amount: c(12_345), day: d("2027-01-01"))
            }
            try SettlementService.enable(db, tagId: tag.id!, from: d("2027-01-01"))
            try entry(db, fx, "2027-01-10", -5_000, "Tank A", tags: [tag.id!])
            #expect(throws: BudgetError.self) {
                try SettlementService.setStart(db, tagId: tag.id!, amount: c(-100), day: d("2027-01-01"))
            }

            let saved = try SettlementService.setStart(db, tagId: tag.id!, amount: c(12_345), day: d("2027-01-01"))
            #expect(saved.startAmount == c(12_345) && saved.startDay == d("2027-01-01") && saved.startIsOpen)
            let open = try SettlementService.open(db, tagId: tag.id!)
            #expect(open.start == c(12_345))
            #expect(open.amount == c(17_345))
            #expect(open.entries.count == 1)

            // Naam wijzigen laat startbedrag en "telt mee" staan.
            try TagService.setCountsInSpendable(db, tagId: tag.id!, true)
            var renamed = try Tag.fetchOne(db, key: tag.id!)!
            renamed.name = "Brandstof"
            renamed.startAmount = .zero
            renamed.countsInSpendable = false
            let updated = try TagService.update(db, renamed)
            #expect(updated.startAmount == c(12_345) && updated.countsInSpendable)

            // Verrekenen uit en weer aan: het startbedrag blijft.
            try SettlementService.disable(db, tagId: tag.id!)
            try SettlementService.enable(db, tagId: tag.id!, from: d("2027-01-05"))
            #expect(try SettlementService.open(db, tagId: tag.id!).amount == c(17_345))

            // € 0,00 haalt het startbedrag weg.
            let removed = try SettlementService.setStart(db, tagId: tag.id!, amount: .zero, day: d("2027-01-01"))
            #expect(removed.startAmount == .zero && removed.startDay == nil)
            #expect(try SettlementService.open(db, tagId: tag.id!).amount == c(5_000))
        }
    }

    @Test func verrekenenMetStartbedrag() throws {
        let fx = try Fixture()
        try fx.app.write { db in
            let tag = try TagService.create(db, name: "Tanken")
            try SettlementService.enable(db, tagId: tag.id!, from: d("2027-01-01"))
            try SettlementService.setStart(db, tagId: tag.id!, amount: c(8_000), day: d("2027-01-01"))
            let a = try entry(db, fx, "2027-02-03", -4_000, "Tank A", tags: [tag.id!])
            let b = try entry(db, fx, "2027-02-17", -3_000, "Tank B", tags: [tag.id!])
            let storting = try entry(db, fx, "2027-02-25", 12_000, "Terugstorting")

            // De voorgestelde storting gaat uit van het openstaande bedrag mét startbedrag (150,00): 120,00 valt buiten.
            #expect(try SettlementService.suggestDeposit(db, tagId: tag.id!, asOf: d("2027-02-26")).isEmpty)

            let result = try SettlementService.settle(db, tagId: tag.id!, entryIds: [a.id!], includeStart: true,
                                                      day: d("2027-02-25"), depositEntryId: storting.id)
            #expect(result.settlement.amount == c(12_000))
            #expect(result.difference == .zero)
            let tagNa = try Tag.fetchOne(db, key: tag.id!)!
            #expect(tagNa.startSettlementId == result.settlement.id && !tagNa.startIsOpen)
            var open = try SettlementService.open(db, tagId: tag.id!)
            #expect(open.start == .zero && open.entries.map(\.id) == [b.id] && open.amount == c(3_000))

            // Niet twee keer, en niet meer te wijzigen zolang het verrekend is.
            #expect(throws: BudgetError.self) {
                try SettlementService.settle(db, tagId: tag.id!, entryIds: [b.id!], includeStart: true, day: d("2027-03-01"))
            }
            #expect(throws: BudgetError.self) {
                try SettlementService.setStart(db, tagId: tag.id!, amount: c(1_000), day: d("2027-01-01"))
            }
            // De tag heeft nu een echte verrekening: verwijderen wordt geweigerd.
            #expect(throws: BudgetError.self) { try TagService.delete(db, tagId: tag.id!) }

            // Ongedaan maken: het startbedrag staat weer open.
            try SettlementService.delete(db, settlementId: result.settlement.id!)
            open = try SettlementService.open(db, tagId: tag.id!)
            #expect(open.start == c(8_000) && open.amount == c(15_000))
            #expect(try Tag.fetchOne(db, key: tag.id!)!.startSettlementId == nil)

            // Alleen het startbedrag verrekenen, zonder boekingen.
            let alleenStart = try SettlementService.settle(db, tagId: tag.id!, entryIds: [], includeStart: true,
                                                           day: d("2027-03-01"))
            #expect(alleenStart.settlement.amount == c(8_000))
            #expect(try SettlementService.open(db, tagId: tag.id!).amount == c(7_000))
            // Zonder boekingen en zonder startbedrag is er niets te verrekenen.
            #expect(throws: BudgetError.self) {
                try SettlementService.settle(db, tagId: tag.id!, entryIds: [], day: d("2027-03-02"))
            }
        }
    }

    @Test func teltMeeInNogTeBestedenAanEnUit() throws {
        let fx = try Fixture()
        try fx.app.write { db in
            let tag = try TagService.create(db, name: "Tanken")
            #expect(!tag.countsInSpendable)
            #expect(try TagService.setCountsInSpendable(db, tagId: tag.id!, true).countsInSpendable)
            #expect(try !TagService.setCountsInSpendable(db, tagId: tag.id!, false).countsInSpendable)
        }
    }
}
