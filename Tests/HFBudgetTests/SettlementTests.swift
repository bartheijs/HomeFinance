import Foundation
import GRDB
import HFCore
import Testing
@testable import HFBudget

@Suite struct SettlementTests {
    /// Handmatige boeking op de betaalrekening met tags.
    @discardableResult
    private func entry(_ db: Database, _ fx: Fixture, _ day: String, _ cents: Int64, _ label: String,
                       tags: [Int64] = [], account: Account? = nil) throws -> Entry {
        try EntryService.create(db, EntryDraft(accountId: (account ?? fx.betaal).id!, day: d(day), amount: c(cents),
                                               label: label, tagIds: tags))
    }

    @Test func aanzettenMetBeginstand() throws {
        let fx = try Fixture()
        try fx.app.write { db in
            let tag = try TagService.create(db, name: "Tanken")
            let jan1 = try entry(db, fx, "2027-01-10", -5_000, "Tank A", tags: [tag.id!])
            let jan2 = try entry(db, fx, "2027-01-20", -3_000, "Tank B", tags: [tag.id!])
            let feb = try entry(db, fx, "2027-02-05", -4_000, "Tank C", tags: [tag.id!])

            let opening = try SettlementService.enable(db, tagId: tag.id!, from: d("2027-02-01"))
            #expect(opening.isOpening && opening.amount == c(8_000) && opening.day == d("2027-02-01"))
            #expect(try Tag.fetchOne(db, key: tag.id!)!.settles)
            #expect(try SettlementService.entries(db, settlementId: opening.id!).map(\.id) == [jan1.id, jan2.id])
            var open = try SettlementService.open(db, tagId: tag.id!)
            #expect(open.entries.map(\.id) == [feb.id] && open.amount == c(4_000))

            // Een echte verrekening blijft staan als de beginstand een andere datum krijgt.
            let real = try SettlementService.settle(db, tagId: tag.id!, entryIds: [feb.id!], day: d("2027-02-25"))
            let moved = try SettlementService.enable(db, tagId: tag.id!, from: d("2027-01-15"))
            #expect(moved.amount == c(5_000))
            open = try SettlementService.open(db, tagId: tag.id!)
            #expect(open.entries.map(\.id) == [jan2.id] && open.amount == c(3_000))
            #expect(try SettlementService.entries(db, settlementId: real.settlement.id!).map(\.id) == [feb.id])
            let history = try SettlementService.history(db, tagId: tag.id!)
            #expect(history.map(\.id) == [real.settlement.id, moved.id])
            #expect(history.filter(\.isOpening).count == 1)

            #expect(throws: BudgetError.self) { try SettlementService.delete(db, settlementId: moved.id!) }
            try SettlementService.disable(db, tagId: tag.id!)
            #expect(try Tag.fetchOne(db, key: tag.id!)!.settles == false)
            #expect(try SettlementService.history(db, tagId: tag.id!).count == 2)
            #expect(throws: BudgetError.tagNotSettling(tag: "Tanken")) {
                try SettlementService.settle(db, tagId: tag.id!, entryIds: [jan2.id!], day: d("2027-03-01"))
            }

            // Zonder eerdere boekingen is de beginstand € 0,00; naam wijzigen laat `settles` staan.
            let leeg = try TagService.create(db, name: "Parkeren")
            #expect(try SettlementService.enable(db, tagId: leeg.id!, from: d("2027-01-01")).amount == .zero)
            var renamed = leeg
            renamed.name = "Parkeergeld"
            #expect(try TagService.update(db, renamed).settles)
        }
    }

    @Test func openstaandMetRetourEnZonderSpaarrekening() throws {
        let fx = try Fixture()
        try fx.app.write { db in
            let tag = try TagService.create(db, name: "Tanken")
            let other = try TagService.create(db, name: "Uit eten")
            try SettlementService.enable(db, tagId: tag.id!, from: d("2027-01-01"))
            let a = try entry(db, fx, "2027-03-02", -6_000, "Tank A", tags: [tag.id!, other.id!])
            let retour = try entry(db, fx, "2027-03-04", 1_000, "Retour", tags: [tag.id!])
            try entry(db, fx, "2027-03-05", -2_000, "Restaurant", tags: [other.id!])
            try entry(db, fx, "2027-03-06", -9_900, "Zonder tag")
            let spaar = try entry(db, fx, "2027-03-07", -7_000, "Spaarboeking met tag", tags: [tag.id!], account: fx.spaar)

            let open = try SettlementService.open(db, tagId: tag.id!)
            #expect(open.entries.map(\.id) == [a.id, retour.id])
            #expect(open.amount == c(5_000))
            #expect(try SettlementService.open(db, tagId: other.id!).amount == c(8_000))
            #expect(throws: BudgetError.notSettleable(entry: "Spaarboeking met tag", tag: "Tanken")) {
                try SettlementService.settle(db, tagId: tag.id!, entryIds: [spaar.id!], day: d("2027-03-25"))
            }
        }
    }

    @Test func verrekenenVanAllesEnVanEenSelectie() throws {
        let fx = try Fixture()
        try fx.app.write { db in
            let tag = try TagService.create(db, name: "Tanken")
            try SettlementService.enable(db, tagId: tag.id!, from: d("2027-01-01"))
            let a = try entry(db, fx, "2027-03-02", -6_000, "Tank A", tags: [tag.id!])
            let b = try entry(db, fx, "2027-03-09", -4_550, "Tank B", tags: [tag.id!])
            let cc = try entry(db, fx, "2027-03-16", -5_000, "Tank C", tags: [tag.id!])
            let los = try entry(db, fx, "2027-03-17", -100, "Zonder tag")

            #expect(throws: BudgetError.self) {
                try SettlementService.settle(db, tagId: tag.id!, entryIds: [], day: d("2027-03-25"))
            }
            #expect(throws: BudgetError.notSettleable(entry: "Zonder tag", tag: "Tanken")) {
                try SettlementService.settle(db, tagId: tag.id!, entryIds: [a.id!, los.id!], day: d("2027-03-25"))
            }
            #expect(try SettlementService.open(db, tagId: tag.id!).amount == c(15_550))

            let first = try SettlementService.settle(db, tagId: tag.id!, entryIds: [a.id!, b.id!], day: d("2027-03-25"),
                                                     note: "maart")
            #expect(first.settlement.amount == c(10_550))
            #expect(first.settlement.isOpening == false && first.settlement.note == "maart")
            #expect(first.deposit == nil && first.difference == nil)
            #expect(try SettlementService.entries(db, settlementId: first.settlement.id!).map(\.id) == [a.id, b.id])
            #expect(try SettlementService.open(db, tagId: tag.id!).amount == c(5_000))
            #expect(throws: BudgetError.notSettleable(entry: "Tank A", tag: "Tanken")) {
                try SettlementService.settle(db, tagId: tag.id!, entryIds: [a.id!], day: d("2027-03-26"))
            }

            // Alles wat nog openstaat, ook in een afgesloten jaar.
            try YearService.closeYear(db, year: 2027)
            let rest = try SettlementService.open(db, tagId: tag.id!)
            let second = try SettlementService.settle(db, tagId: tag.id!, entryIds: rest.entries.map { $0.id! },
                                                      day: d("2027-04-25"))
            #expect(second.settlement.amount == c(5_000))
            #expect(try Entry.fetchOne(db, key: cc.id!)!.settlementId == second.settlement.id)
            #expect(try SettlementService.open(db, tagId: tag.id!).amount == .zero)
            #expect(try SettlementService.history(db, tagId: tag.id!).first?.id == second.settlement.id)
        }
    }

    @Test func stortingKoppelenMetEnZonderVerschil() throws {
        let fx = try Fixture()
        try fx.app.write { db in
            let tag = try TagService.create(db, name: "Tanken")
            try SettlementService.enable(db, tagId: tag.id!, from: d("2027-01-01"))
            let a = try entry(db, fx, "2027-03-02", -6_000, "Tank A", tags: [tag.id!])
            let b = try entry(db, fx, "2027-04-02", -4_000, "Tank B", tags: [tag.id!])
            let exact = try entry(db, fx, "2027-03-25", 6_000, "Terugstorting maart")
            let rond = try entry(db, fx, "2027-04-25", 4_050, "Terugstorting april")
            let uitgave = try entry(db, fx, "2027-04-26", -4_000, "Geen storting")
            let opSpaar = try entry(db, fx, "2027-04-26", 4_000, "Storting op spaar", account: fx.spaar)
            let metTag = try entry(db, fx, "2027-04-27", 4_000, "Retour met tag", tags: [tag.id!])

            let first = try SettlementService.settle(db, tagId: tag.id!, entryIds: [a.id!], day: d("2027-03-25"),
                                                     depositEntryId: exact.id)
            #expect(first.settlement.depositEntryId == exact.id)
            #expect(first.deposit?.id == exact.id && first.difference == .zero)

            // Een storting hoort bij hoogstens één verrekening; mislukt het koppelen, dan is er niets vastgelegd.
            #expect(throws: BudgetError.self) {
                try SettlementService.settle(db, tagId: tag.id!, entryIds: [b.id!], day: d("2027-04-25"),
                                             depositEntryId: exact.id)
            }
            #expect(try SettlementService.open(db, tagId: tag.id!).entries.map(\.id) == [b.id, metTag.id])

            let second = try SettlementService.settle(db, tagId: tag.id!, entryIds: [b.id!], day: d("2027-04-25"))
            for wrong in [uitgave, opSpaar, metTag, exact] {
                #expect(throws: BudgetError.self) {
                    try SettlementService.linkDeposit(db, settlementId: second.settlement.id!, depositEntryId: wrong.id)
                }
            }
            let linked = try SettlementService.linkDeposit(db, settlementId: second.settlement.id!, depositEntryId: rond.id)
            #expect(linked.difference == c(50))
            #expect(try SettlementService.result(db, settlementId: second.settlement.id!).difference == c(50))
            // Opnieuw dezelfde koppelen mag; ontkoppelen kan met nil.
            try SettlementService.linkDeposit(db, settlementId: second.settlement.id!, depositEntryId: rond.id)
            #expect(throws: BudgetError.depositLinked) { try EntryService.delete(db, entryId: rond.id!) }
            let unlinked = try SettlementService.linkDeposit(db, settlementId: second.settlement.id!, depositEntryId: nil)
            #expect(unlinked.settlement.depositEntryId == nil && unlinked.difference == nil)
            try EntryService.delete(db, entryId: rond.id!)

            let opening = try #require(try SettlementService.history(db, tagId: tag.id!).last)
            #expect(throws: BudgetError.self) {
                try SettlementService.linkDeposit(db, settlementId: opening.id!, depositEntryId: uitgave.id)
            }
        }
    }

    @Test func voorstelVoorDeStorting() throws {
        let fx = try Fixture()
        try fx.app.write { db in
            let tag = try TagService.create(db, name: "Tanken")
            try SettlementService.enable(db, tagId: tag.id!, from: d("2027-01-01"))
            #expect(try SettlementService.suggestDeposit(db, tagId: tag.id!, asOf: d("2027-05-31")).isEmpty)
            try entry(db, fx, "2027-05-03", -12_345, "Tank A", tags: [tag.id!])

            let bijna = try entry(db, fx, "2027-05-28", 12_400, "Bijna, nieuwste")
            let exactOud = try entry(db, fx, "2027-05-20", 12_345, "Exact, ouder")
            let exactNieuw = try entry(db, fx, "2027-05-26", 12_345, "Exact, nieuwer")
            try entry(db, fx, "2027-05-27", 12_446, "Te ver weg")
            try entry(db, fx, "2027-04-10", 12_345, "Te oud")
            try entry(db, fx, "2027-05-27", 12_345, "Op spaar", account: fx.spaar)
            try EntryService.create(db, EntryDraft(accountId: fx.betaal.id!, day: d("2027-05-25"), amount: c(12_345),
                                                   label: "Vaste post", budgetItemId: fx.salaris.id))
            let gekoppeld = try entry(db, fx, "2027-05-29", 12_345, "Al gekoppeld")
            let oud = try entry(db, fx, "2027-01-05", -100, "Oude tank", tags: [tag.id!])
            try SettlementService.settle(db, tagId: tag.id!, entryIds: [oud.id!], day: d("2027-05-29"),
                                         depositEntryId: gekoppeld.id)

            let suggestions = try SettlementService.suggestDeposit(db, tagId: tag.id!, asOf: d("2027-05-31"))
            #expect(suggestions.map(\.label) == ["Exact, nieuwer", "Exact, ouder", "Bijna, nieuwste"])
            #expect(suggestions.map(\.id) == [exactNieuw.id, exactOud.id, bijna.id])
        }
    }

    @Test func verwijderenMaaktWeerOpen() throws {
        let fx = try Fixture()
        try fx.app.write { db in
            let tag = try TagService.create(db, name: "Tanken")
            try SettlementService.enable(db, tagId: tag.id!, from: d("2027-01-01"))
            let a = try entry(db, fx, "2027-03-02", -6_000, "Tank A", tags: [tag.id!])
            let storting = try entry(db, fx, "2027-03-25", 6_000, "Terugstorting")
            let result = try SettlementService.settle(db, tagId: tag.id!, entryIds: [a.id!], day: d("2027-03-25"),
                                                      depositEntryId: storting.id)
            #expect(try SettlementService.open(db, tagId: tag.id!).amount == .zero)
            try SettlementService.delete(db, settlementId: result.settlement.id!)
            #expect(try SettlementService.open(db, tagId: tag.id!).amount == c(6_000))
            #expect(try Entry.fetchOne(db, key: a.id!)!.settlementId == nil)
            #expect(try SettlementService.history(db, tagId: tag.id!).allSatisfy(\.isOpening))
            // De storting is weer vrij en wordt opnieuw voorgesteld.
            #expect(try SettlementService.suggestDeposit(db, tagId: tag.id!, asOf: d("2027-03-31")).map(\.id) == [storting.id])
            #expect(throws: BudgetError.notFound(what: "Verrekening", id: result.settlement.id!)) {
                try SettlementService.delete(db, settlementId: result.settlement.id!)
            }
        }
    }

    @Test func verrekendeBoekingHoudtTagEnBedrag() throws {
        let fx = try Fixture()
        try fx.app.write { db in
            let tag = try TagService.create(db, name: "Tanken")
            let other = try TagService.create(db, name: "Uit eten")
            try SettlementService.enable(db, tagId: tag.id!, from: d("2027-01-01"))
            let manual = try entry(db, fx, "2027-03-02", -6_000, "Tank A", tags: [tag.id!])
            let t = try fx.tx(db, fx.betaal, "2027-03-09", -4_000)
            let booked = try BookingService.book(db, bankTransactionId: t.id!, allocations: [
                Allocation(amount: c(-4_000), label: "Tank B", tagIds: [tag.id!])])[0]
            let stortingTx = try fx.tx(db, fx.betaal, "2027-03-25", 10_000)
            let storting = try BookingService.book(db, bankTransactionId: stortingTx.id!, allocations: [
                Allocation(amount: c(10_000), label: "Terugstorting")])[0]
            let result = try SettlementService.settle(db, tagId: tag.id!, entryIds: [manual.id!, booked.id!],
                                                      day: d("2027-03-25"), depositEntryId: storting.id)
            #expect(result.difference == .zero)

            #expect(throws: BudgetError.inSettlement) { try EntryService.setTags(db, entryId: manual.id!, tagIds: []) }
            #expect(throws: BudgetError.inSettlement) {
                try EntryService.setTags(db, entryId: manual.id!, tagIds: [other.id!])
            }
            var draft = try EntryService.draft(db, entryId: manual.id!)
            draft.amount = c(-6_500)
            #expect(throws: BudgetError.inSettlement) { try EntryService.update(db, entryId: manual.id!, draft) }
            draft.amount = c(-6_000); draft.tagIds = []
            #expect(throws: BudgetError.inSettlement) { try EntryService.update(db, entryId: manual.id!, draft) }
            #expect(throws: BudgetError.inSettlement) { try EntryService.delete(db, entryId: manual.id!) }
            #expect(throws: BudgetError.inSettlement) { try BookingService.unbook(db, bankTransactionId: t.id!) }
            #expect(throws: BudgetError.inSettlement) {
                try BookingService.book(db, bankTransactionId: t.id!, allocations: [Allocation(amount: c(-4_000), label: "x")])
            }
            #expect(throws: BudgetError.depositLinked) { try BookingService.unbook(db, bankTransactionId: stortingTx.id!) }
            #expect(BudgetError.inSettlement.localizedDescription.contains("verrekend"))

            // Wat wel mag: een tag erbij, label en notitie wijzigen.
            try EntryService.setTags(db, entryId: manual.id!, tagIds: [tag.id!, other.id!])
            draft.tagIds = [tag.id!]; draft.label = "Tankstation"; draft.note = "week 9"
            #expect(try EntryService.update(db, entryId: manual.id!, draft).label == "Tankstation")
            #expect(try Entry.fetchOne(db, key: manual.id!)!.settlementId == result.settlement.id)

            // Een tag met verrekeningen kan niet verwijderd worden; de historie blijft staan.
            #expect(throws: BudgetError.tagHasSettlements(tag: "Tanken", count: 1)) {
                try TagService.delete(db, tagId: tag.id!)
            }
            #expect(try SettlementService.history(db, tagId: tag.id!).count == 2)
            #expect(BudgetError.tagHasSettlements(tag: "Tanken", count: 1).localizedDescription.contains("historie"))

            // Na het verwijderen van de verrekening is alles weer vrij, ook de tag (de beginstand is leeg).
            try SettlementService.delete(db, settlementId: result.settlement.id!)
            try EntryService.setTags(db, entryId: manual.id!, tagIds: [])
            try BookingService.unbook(db, bankTransactionId: t.id!)
            try BookingService.unbook(db, bankTransactionId: stortingTx.id!)
            try TagService.delete(db, tagId: tag.id!)
            #expect(try Tag.fetchOne(db, key: tag.id!) == nil)

            // Een beginstand met boekingen houdt het verwijderen ook tegen.
            let parkeren = try TagService.create(db, name: "Parkeren")
            try entry(db, fx, "2027-01-10", -500, "Garage", tags: [parkeren.id!])
            try SettlementService.enable(db, tagId: parkeren.id!, from: d("2027-02-01"))
            #expect(throws: BudgetError.tagHasSettlements(tag: "Parkeren", count: 1)) {
                try TagService.delete(db, tagId: parkeren.id!)
            }
        }
    }
}
