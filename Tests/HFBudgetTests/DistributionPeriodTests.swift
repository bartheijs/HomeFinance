import Foundation
import GRDB
import HFCore
import Testing
@testable import HFBudget

private func plan(_ db: Database, _ item: BudgetItem) throws -> Money {
    try BudgetItem.fetchOne(db, key: item.id!)!.planAmount
}

@Suite struct DistributionTests {
    @Test func stortingEnRegelsBeheren() throws {
        let fx = try Fixture()
        try fx.app.write { db in
            #expect(throws: BudgetError.self) { try DistributionService.create(db, name: "Fout", accountId: fx.betaal.id!) }
            #expect(throws: BudgetError.self) { try DistributionService.create(db, name: "  ", accountId: fx.spaar.id!) }
            let vast = try DistributionService.create(db, name: " Vast sparen ", accountId: fx.spaar.id!)
            let extra = try DistributionService.create(db, name: "Extra", accountId: fx.spaar.id!)
            #expect(vast.name == "Vast sparen" && vast.sortOrder == 0 && extra.sortOrder == 1)
            #expect(try DistributionService.total(db, distributionId: vast.id!) == .zero)

            let spaar2 = try AccountService.create(db, Account(name: "Testspaar 2", iban: "NL00TEST0000000003",
                                                               kind: .spaar, openingDate: d("2027-01-01")))
            let vreemd = try PotService.create(db, Pot(accountId: spaar2.id!, name: "Andere pot", kind: .spaar))
            #expect(throws: BudgetError.potWrongAccount(pot: "Andere pot")) {
                try DistributionService.setLines(db, distributionId: vast.id!, [(vreemd.id!, c(100))])
            }
            #expect(throws: BudgetError.self) {
                try DistributionService.setLines(db, distributionId: vast.id!, [(fx.potVakantie.id!, .zero)])
            }
            #expect(throws: BudgetError.self) {
                try DistributionService.setLines(db, distributionId: vast.id!,
                                                 [(fx.potVakantie.id!, c(100)), (fx.potVakantie.id!, c(200))])
            }
            #expect(try DistributionService.lines(db, distributionId: vast.id!).isEmpty)

            // 100,00 + 150,00 + 25,00 = 275,00
            let lines = try DistributionService.setLines(db, distributionId: vast.id!, [
                (fx.potVakantie.id!, c(15_000)), (fx.potVerzekering.id!, c(10_000)), (fx.potSpaar.id!, c(2_500))])
            #expect(lines.map(\.potId) == [fx.potVakantie.id!, fx.potVerzekering.id!, fx.potSpaar.id!])
            #expect(try DistributionService.total(db, distributionId: vast.id!) == c(27_500))
            // Eén regel wijzigen, één toevoegen is hetzelfde als wijzigen; één weghalen: 150 + 120 = 270,00
            try DistributionService.setLine(db, distributionId: vast.id!, potId: fx.potVerzekering.id!, amount: c(12_000))
            #expect(try DistributionService.removeLine(db, distributionId: vast.id!, potId: fx.potSpaar.id!).count == 2)
            #expect(try DistributionService.total(db, distributionId: vast.id!) == c(27_000))

            #expect(try DistributionService.rename(db, distributionId: extra.id!, name: "Extra sparen").name == "Extra sparen")
            try DistributionService.reorder(db, orderedIds: [extra.id!, vast.id!])
            #expect(try DistributionService.all(db).map(\.id) == [extra.id, vast.id])
            try DistributionService.setArchived(db, distributionId: extra.id!, true)
            #expect(try DistributionService.all(db).map(\.id) == [vast.id])
            #expect(try DistributionService.all(db, includeArchived: true).count == 2)
            try DistributionService.delete(db, distributionId: extra.id!)
            #expect(try DistributionService.all(db, includeArchived: true).count == 1)
        }
    }

    @Test func gekoppeldePostVolgtHetTotaal() throws {
        let fx = try Fixture()
        try fx.app.write { db in
            let vast = try DistributionService.create(db, name: "Vast sparen", accountId: fx.spaar.id!)
            try DistributionService.setLines(db, distributionId: vast.id!, [
                (fx.potVerzekering.id!, c(10_000)), (fx.potVakantie.id!, c(15_000))])
            #expect(throws: BudgetError.self) {
                try DistributionService.link(db, distributionId: vast.id!, budgetItemId: fx.salaris.id!)
            }
            let linked = try DistributionService.link(db, distributionId: vast.id!, budgetItemId: fx.boodschappen.id!)
            #expect(linked.distributionId == vast.id && linked.planAmount == c(-25_000))

            try DistributionService.setLine(db, distributionId: vast.id!, potId: fx.potVerzekering.id!, amount: c(12_000))
            #expect(try plan(db, fx.boodschappen) == c(-27_000))

            // Een zelf ingevuld plan wordt niet geweigerd maar overschreven.
            var manual = try BudgetItem.fetchOne(db, key: fx.boodschappen.id!)!
            manual.planAmount = c(-1); manual.label = "Sparen"
            let saved = try YearService.updateItem(db, manual)
            #expect(saved.planAmount == c(-27_000) && saved.label == "Sparen")
            manual.direction = .IN
            #expect(throws: BudgetError.self) { try YearService.updateItem(db, manual) }

            // De koppeling gaat mee naar een gekopieerd jaar; een afgesloten jaar verandert niet meer.
            let y2028 = try YearService.createYear(db, year: 2028, copyingFrom: 2027)
            let copy = try #require(try BudgetItem.fetchOne(db, sql: "SELECT * FROM budgetItem WHERE yearId = ? AND label = 'Sparen'",
                                                            arguments: [y2028.id]))
            #expect(copy.distributionId == vast.id && copy.planAmount == c(-27_000))
            try YearService.closeYear(db, year: 2027)
            try DistributionService.setLines(db, distributionId: vast.id!, [(fx.potVakantie.id!, c(20_000))])
            #expect(try plan(db, fx.boodschappen) == c(-27_000))
            #expect(try plan(db, copy) == c(-20_000))
            #expect(try DistributionService.linkedItems(db, distributionId: vast.id!).map(\.id) == [copy.id, fx.boodschappen.id])

            // Een pot verwijderen haalt hem uit de verdeling; het plan volgt.
            let tijdelijk = try PotService.create(db, Pot(accountId: fx.spaar.id!, name: "Tijdelijk", kind: .spaar))
            try DistributionService.setLine(db, distributionId: vast.id!, potId: tijdelijk.id!, amount: c(3_000))
            #expect(try plan(db, copy) == c(-23_000))
            try PotService.delete(db, potId: tijdelijk.id!)
            #expect(try plan(db, copy) == c(-20_000))

            // Ontkoppelen laat het plan staan en maakt het weer vrij; de storting verwijderen ontkoppelt ook.
            let unlinked = try DistributionService.unlink(db, budgetItemId: copy.id!)
            #expect(unlinked.distributionId == nil && unlinked.planAmount == c(-20_000))
            var free = unlinked
            free.planAmount = c(-5_000)
            #expect(try YearService.updateItem(db, free).planAmount == c(-5_000))
            try DistributionService.delete(db, distributionId: vast.id!)
            #expect(try BudgetItem.fetchOne(db, key: fx.boodschappen.id!)!.distributionId == nil)
        }
    }

    @Test func voorstelExactEnMetVerschil() throws {
        let fx = try Fixture()
        try fx.app.write { db in
            let vast = try DistributionService.create(db, name: "Vast sparen", accountId: fx.spaar.id!)
            try DistributionService.setLines(db, distributionId: vast.id!, [
                (fx.potVerzekering.id!, c(10_000)), (fx.potVakantie.id!, c(15_000))])
            let klein = try DistributionService.create(db, name: "Kind", accountId: fx.spaar.id!)
            try DistributionService.setLines(db, distributionId: klein.id!, [(fx.potSpaar.id!, c(2_500))])
            let dubbel = try DistributionService.create(db, name: "Ook 25", accountId: fx.spaar.id!)
            try DistributionService.setLines(db, distributionId: dubbel.id!, [(fx.potSpaar.id!, c(2_500))])
            let leeg = try DistributionService.create(db, name: "Leeg", accountId: fx.spaar.id!)

            let exact = try DistributionService.allocations(db, distributionId: vast.id!, for: c(25_000))
            #expect(exact.isExact && exact.total == c(25_000) && exact.difference == .zero)
            #expect(exact.allocations.map(\.label) == ["Vast sparen: Verzekering", "Vast sparen: Vakantie"])
            #expect(exact.allocations.map(\.amount) == [c(10_000), c(15_000)])
            #expect(exact.allocations.map(\.potId) == [fx.potVerzekering.id, fx.potVakantie.id])
            let t = try fx.tx(db, fx.spaar, "2027-01-28", 25_000)
            try BookingService.book(db, bankTransactionId: t.id!, allocations: exact.allocations)
            #expect(try PotService.balance(db, potId: fx.potVakantie.id!) == c(15_000))

            // 260,00 gestort: de verdeling blijft 100 + 150 en het verschil van 10,00 is aan de gebruiker.
            let meer = try DistributionService.allocations(db, distributionId: vast.id!, for: c(26_000))
            #expect(!meer.isExact && meer.difference == c(1_000))
            #expect(meer.allocations.map(\.amount) == [c(10_000), c(15_000)])
            #expect(try DistributionService.allocations(db, distributionId: vast.id!, for: c(24_000)).difference == c(-1_000))
            #expect(try DistributionService.allocations(db, distributionId: leeg.id!, for: c(500)).allocations.isEmpty)

            #expect(try DistributionService.match(db, accountId: fx.spaar.id!, amount: c(25_000)).map(\.id) == [vast.id])
            #expect(try DistributionService.match(db, accountId: fx.spaar.id!, amount: c(2_500)).map(\.id) == [klein.id, dubbel.id])
            #expect(try DistributionService.match(db, accountId: fx.spaar.id!, amount: c(26_000)).isEmpty)
            #expect(try DistributionService.match(db, accountId: fx.spaar.id!, amount: .zero).isEmpty)
            #expect(try DistributionService.match(db, accountId: fx.betaal.id!, amount: c(25_000)).isEmpty)
            try DistributionService.setArchived(db, distributionId: klein.id!, true)
            #expect(try DistributionService.match(db, accountId: fx.spaar.id!, amount: c(2_500)).map(\.id) == [dubbel.id])

            // De oude weg op basis van maandbedragen blijft werken.
            #expect(try PotService.distribution(db, for: c(25_000), accountId: fx.spaar.id!)?.count == 2)
        }
    }

    @Test func stortingUitBestaandePotten() throws {
        let fx = try Fixture()
        try fx.app.write { db in
            #expect(throws: BudgetError.self) {
                try DistributionService.createFromPots(db, accountId: fx.betaal.id!, name: "x", year: 2027)
            }
            let vast = try DistributionService.createFromPots(db, accountId: fx.spaar.id!, name: "Reserveringen", year: 2027)
            let lines = try DistributionService.lines(db, distributionId: vast.id!)
            // Alleen de reserveringspotten met een maandbedrag: 100,00 en 150,00; de spaarpot doet niet mee.
            #expect(lines.map(\.potId) == [fx.potVerzekering.id!, fx.potVakantie.id!])
            #expect(lines.map(\.amount) == [c(10_000), c(15_000)])
            let reserve = try BudgetItem.fetchOne(db, key: fx.reserveringen.id!)!
            #expect(reserve.distributionId == vast.id && reserve.planAmount == c(-25_000))

            // De storting gaat voor op de som van de RES-regels.
            var res = fx.resVakantie
            res.planAmount = c(-20_000)
            try YearService.updateItem(db, res)
            #expect(try plan(db, fx.reserveringen) == c(-25_000))
            try DistributionService.setLine(db, distributionId: vast.id!, potId: fx.potVakantie.id!, amount: c(17_500))
            #expect(try plan(db, fx.reserveringen) == c(-27_500))
            // Na ontkoppelen volgt de regel weer de RES-regels: 100 + 200 = 300,00.
            #expect(try DistributionService.unlink(db, budgetItemId: fx.reserveringen.id!).planAmount == c(-30_000))

            // Zonder regel RESERVERINGEN in dat jaar wordt er alleen een storting gemaakt.
            let los = try DistributionService.createFromPots(db, accountId: fx.spaar.id!, name: "Los", year: 2030)
            #expect(try DistributionService.linkedItems(db, distributionId: los.id!).isEmpty)
        }
    }
}

@Suite struct PotOpeningTests {
    @Test func potMetBeginbedrag() throws {
        let fx = try Fixture()
        try fx.app.write { db in
            let pot = try PotService.create(db, Pot(accountId: fx.spaar.id!, name: "Auto", kind: .reservering),
                                            openingBalance: c(30_000))
            let opening = try #require(try Entry.fetchOne(db, sql: "SELECT * FROM entry WHERE potId = ?", arguments: [pot.id]))
            #expect(opening.label == "Beginsaldo Auto" && opening.note == PotService.openingNote)
            #expect(opening.day == d("2027-01-01") && opening.amount == c(30_000) && opening.bankTransactionId == nil)
            #expect(try PotService.balance(db, potId: pot.id!) == c(30_000))

            // De beginboeking telt mee in het rekeningsaldo: 5.000,00 + 300,00.
            #expect(try BalanceService.balance(db, accountId: fx.spaar.id!, on: d("2027-01-01")) == c(530_000))
            var summary = try PotService.openingSummary(db, accountId: fx.spaar.id!)
            #expect(summary.accountOpening == c(500_000) && summary.potTotal == c(30_000) && summary.total == c(530_000))
            #expect(summary.potOpenings.map(\.amount) == [.zero, .zero, .zero, c(30_000)])

            // Het beginsaldo bij de bank was 5.000,00: niet toegewezen wordt 4.700,00 en het saldo klopt weer.
            let account = try AccountService.setOpeningFromPots(db, accountId: fx.spaar.id!, totalOpening: c(500_000))
            #expect(account.openingBalance == c(470_000))
            #expect(try BalanceService.balance(db, accountId: fx.spaar.id!, on: d("2027-01-01")) == c(500_000))

            // Aanpassen wijzigt dezelfde boeking; een tweede pot krijgt er later een.
            let changed = try #require(try PotService.setOpeningBalance(db, potId: pot.id!, amount: c(45_000), on: d("2027-01-02")))
            #expect(changed.id == opening.id && changed.amount == c(45_000) && changed.day == d("2027-01-02"))
            let second = try #require(try PotService.setOpeningBalance(db, potId: fx.potVakantie.id!, amount: c(20_000)))
            #expect(second.label == "Beginsaldo Vakantie" && second.day == d("2027-01-01"))
            summary = try PotService.openingSummary(db, accountId: fx.spaar.id!)
            #expect(summary.potTotal == c(65_000) && summary.total == c(535_000))
            #expect(summary.potOpenings.first { $0.pot.id == fx.potVakantie.id }?.amount == c(20_000))

            // Nul verwijdert de beginboeking; een gewone boeking op de pot blijft staan.
            try EntryService.create(db, EntryDraft(accountId: fx.spaar.id!, day: d("2027-02-01"), amount: c(1_000),
                                                   label: "Storting", potId: pot.id))
            #expect(try PotService.setOpeningBalance(db, potId: pot.id!, amount: .zero) == nil)
            #expect(try PotService.balance(db, potId: pot.id!) == c(1_000))
            #expect(try PotService.openingSummary(db, accountId: fx.spaar.id!).potTotal == c(20_000))

            // Zonder beginbedrag komt er geen boeking.
            let leeg = try PotService.create(db, Pot(accountId: fx.spaar.id!, name: "Leeg", kind: .spaar))
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM entry WHERE potId = ?", arguments: [leeg.id]) == 0)
        }
    }
}

@Suite struct ItemCheckTests {
    @Test func postAfvinken() throws {
        let fx = try Fixture()
        try fx.app.write { db in
            try ItemCheckService.setChecked(db, budgetItemId: fx.boodschappen.id!, month: 3, true, note: "contant betaald")
            try ItemCheckService.setChecked(db, budgetItemId: fx.salaris.id!, month: 2, true)
            try ItemCheckService.setChecked(db, budgetItemId: fx.salaris.id!, month: 1, true)
            var checks = try ItemCheckService.checks(db, yearId: fx.year.id!)
            #expect(checks.map(\.budgetItemId) == [fx.salaris.id!, fx.salaris.id!, fx.boodschappen.id!])
            #expect(checks.map(\.month) == [1, 2, 3])
            #expect(checks[2].note == "contant betaald")

            try ItemCheckService.setChecked(db, budgetItemId: fx.boodschappen.id!, month: 3, true, note: "aangepast")
            try ItemCheckService.setChecked(db, budgetItemId: fx.salaris.id!, month: 2, false)
            try ItemCheckService.setChecked(db, budgetItemId: fx.salaris.id!, month: 7, false)
            checks = try ItemCheckService.checks(db, yearId: fx.year.id!)
            #expect(checks.count == 2 && checks[1].note == "aangepast")

            #expect(throws: BudgetError.self) {
                try ItemCheckService.setChecked(db, budgetItemId: fx.resVakantie.id!, month: 3, true)
            }
            #expect(throws: BudgetError.self) {
                try ItemCheckService.setChecked(db, budgetItemId: fx.salaris.id!, month: 13, true)
            }
            try ItemCheckService.setChecked(db, budgetItemId: fx.reserveringen.id!, month: 1, true)
            try YearService.closeYear(db, year: 2027)
            #expect(throws: BudgetError.yearClosed(2027)) {
                try ItemCheckService.setChecked(db, budgetItemId: fx.salaris.id!, month: 4, true)
            }
            #expect(throws: BudgetError.yearClosed(2027)) {
                try ItemCheckService.setChecked(db, budgetItemId: fx.salaris.id!, month: 1, false)
            }
            #expect(try ItemCheckService.checks(db, yearId: fx.year.id!).count == 3)
        }
    }
}

@Suite struct PeriodTests {
    @Test func boekingTeltMeeInAndereMaand() throws {
        let fx = try Fixture()
        try fx.app.write { db in
            func draft(_ day: String, _ period: String?) -> EntryDraft {
                EntryDraft(accountId: fx.betaal.id!, day: d(day), amount: c(-4_000), label: "Supermarkt",
                           budgetItemId: fx.boodschappen.id, period: period)
            }
            let entry = try EntryService.create(db, draft("2027-10-29", "2027-11"))
            #expect(entry.period == "2027-11" && entry.budgetItemId == fx.boodschappen.id)
            #expect(try EntryService.draft(db, entryId: entry.id!).period == "2027-11")
            // De maand van de datum zelf wordt als nil bewaard; twee maanden terug mag nog.
            #expect(try EntryService.create(db, draft("2027-10-29", "2027-10")).period == nil)
            #expect(try EntryService.create(db, draft("2027-10-29", "2027-08")).period == "2027-08")
            #expect(try EntryService.create(db, draft("2027-10-29", "2027-12")).period == "2027-12")

            #expect(throws: BudgetError.periodTooFar(period: "2027-07", day: d("2027-10-29"))) {
                try EntryService.create(db, draft("2027-10-29", "2027-07"))
            }
            for wrong in ["2027-13", "2027-1", "27-11", "november", ""] {
                #expect(throws: BudgetError.periodInvalid(wrong)) { try EntryService.create(db, draft("2027-10-29", wrong)) }
            }
            #expect(BudgetError.periodTooFar(period: "2027-07", day: d("2027-10-29")).localizedDescription.contains("2 maanden"))

            // Het rekeningsaldo volgt de datum: 1.000,00 − 4 × 40,00 = 840,00 op 31 oktober, wat de periode ook is.
            #expect(try BalanceService.balance(db, accountId: fx.betaal.id!, on: d("2027-10-31")) == c(84_000))

            let moved = try EntryService.setPeriod(db, entryId: entry.id!, year: 2027, month: 9)
            #expect(moved.period == "2027-09")
            #expect(try EntryService.setPeriod(db, entryId: entry.id!, year: nil, month: nil).period == nil)
            #expect(throws: BudgetError.self) { try EntryService.setPeriod(db, entryId: entry.id!, year: 2027, month: nil) }
            #expect(throws: BudgetError.periodInvalid("2027-00")) {
                try EntryService.setPeriod(db, entryId: entry.id!, year: 2027, month: 0)
            }

            // Ook bij het boeken van een banktransactie.
            let t = try fx.tx(db, fx.betaal, "2027-11-29", -60_000)
            let booked = try BookingService.book(db, bankTransactionId: t.id!, allocations: [
                Allocation(amount: c(-60_000), label: "Boodschappen december", budgetItemId: fx.boodschappen.id,
                           period: "2027-12")])
            #expect(booked[0].period == "2027-12" && booked[0].day == d("2027-11-29"))
        }
    }

    @Test func periodeInAnderJaarZoektDePostVanDatJaar() throws {
        let fx = try Fixture()
        try fx.app.write { db in
            let draft = EntryDraft(accountId: fx.betaal.id!, day: d("2027-12-28"), amount: c(-4_000), label: "Supermarkt",
                                   budgetItemId: fx.boodschappen.id, period: "2028-01")
            #expect(throws: BudgetError.itemMissingInYear(item: "Boodschappen", year: 2028)) {
                try EntryService.create(db, draft)
            }
            // Zonder vaste post (divers) is er geen post nodig in dat jaar.
            var divers = draft
            divers.budgetItemId = nil
            #expect(try EntryService.create(db, divers).period == "2028-01")

            let y2028 = try YearService.createYear(db, year: 2028, copyingFrom: 2027)
            let item2028 = try #require(try BudgetItem.fetchOne(db, sql: """
                SELECT * FROM budgetItem WHERE yearId = ? AND label = 'Boodschappen'
                """, arguments: [y2028.id]))
            let entry = try EntryService.create(db, draft)
            #expect(entry.budgetItemId == item2028.id && entry.period == "2028-01")
            // Terug naar de maand van de datum: de boeking verhuist terug naar de post van 2027.
            let back = try EntryService.setPeriod(db, entryId: entry.id!, year: nil, month: nil)
            #expect(back.budgetItemId == fx.boodschappen.id && back.period == nil)
            // En andersom: januari 2028 die bij december 2027 hoort.
            let januari = try EntryService.create(db, EntryDraft(accountId: fx.betaal.id!, day: d("2028-01-03"),
                                                                 amount: c(-2_000), label: "Supermarkt",
                                                                 budgetItemId: item2028.id, period: "2027-12"))
            #expect(januari.budgetItemId == fx.boodschappen.id)
            // Zonder periode blijft een post uit een ander jaar geweigerd.
            #expect(throws: BudgetError.itemWrongYear(item: "Boodschappen", day: d("2027-12-28"))) {
                try EntryService.create(db, EntryDraft(accountId: fx.betaal.id!, day: d("2027-12-28"), amount: c(-1),
                                                       label: "x", budgetItemId: item2028.id))
            }

            // Beide jaren moeten open zijn.
            try YearService.closeYear(db, year: 2028)
            #expect(throws: BudgetError.yearClosed(2028)) {
                try EntryService.setPeriod(db, entryId: entry.id!, year: 2028, month: 1)
            }
            #expect(throws: BudgetError.yearClosed(2028)) { try EntryService.create(db, draft) }
            try YearService.reopenYear(db, year: 2028)
            try EntryService.setPeriod(db, entryId: entry.id!, year: 2028, month: 1)
            try YearService.closeYear(db, year: 2028)
            #expect(throws: BudgetError.yearClosed(2028)) {
                try EntryService.setPeriod(db, entryId: entry.id!, year: nil, month: nil)
            }
        }
    }
}

@Suite struct LabelTests {
    private func entry(_ db: Database, _ fx: Fixture, _ label: String, _ day: String = "2027-02-01") throws {
        try EntryService.create(db, EntryDraft(accountId: fx.betaal.id!, day: d(day), amount: c(-500), label: label))
    }
    private func labels(_ db: Database) throws -> [String] {
        try String.fetchAll(db, sql: "SELECT label FROM entry ORDER BY id")
    }

    @Test func hernoemenMetHoofdlettersEnSpaties() throws {
        let fx = try Fixture()
        try fx.app.write { db in
            for label in ["Zakgelt", "  ZAKGELT ", "Zakgeld", "zak  gelt", "Boodschappen"] { try entry(db, fx, label) }
            var rule = Rule(name: "Zakgeld kind", entryLabel: "zakgelt")
            try rule.insert(db)
            var other = Rule(name: "Winkel", entryLabel: "Boodschappen")
            try other.insert(db)

            let result = try LabelService.renameLabel(db, from: " zakGELT", to: "  Zakgeld ")
            #expect(result == LabelRenameResult(entryCount: 2, ruleCount: 1))
            #expect(try labels(db) == ["Zakgeld", "Zakgeld", "Zakgeld", "zak  gelt", "Boodschappen"])
            #expect(try Rule.fetchOne(db, key: rule.id!)!.entryLabel == "Zakgeld")
            #expect(try Rule.fetchOne(db, key: other.id!)!.entryLabel == "Boodschappen")

            // Niets te doen geeft 0; alleen de schrijfwijze gelijktrekken telt wel.
            #expect(try LabelService.renameLabel(db, from: "Zakgelt", to: "Zakgeld") == LabelRenameResult())
            #expect(try LabelService.renameLabel(db, from: "bestaat niet", to: "Iets") == LabelRenameResult())
            #expect(try LabelService.renameLabel(db, from: "zak gelt", to: "Zak gelt").entryCount == 1)
            #expect(throws: BudgetError.self) { try LabelService.renameLabel(db, from: "Zakgeld", to: "   ") }
            #expect(try labels(db).filter { $0 == "Zakgeld" }.count == 3)
        }
    }

    @Test func samenvoegenOokInAfgeslotenJaar() throws {
        let fx = try Fixture()
        try fx.app.write { db in
            for label in ["Zakgelt", "Zak geld", "zakgeld", "Zakgeld", "Sport"] { try entry(db, fx, label) }
            var rule = Rule(name: "r", entryLabel: "Zak  Geld")
            try rule.insert(db)
            #expect(try LabelService.spellingVariants(db) == [["Zakgeld", "zakgeld"]])
            try YearService.closeYear(db, year: 2027)

            let result = try LabelService.mergeLabels(db, ["Zakgelt", "zak geld", "ZAKGELD"], into: "Zakgeld")
            // Zakgelt, Zak geld en zakgeld wijzigen; de bestaande "Zakgeld" stond al goed.
            #expect(result == LabelRenameResult(entryCount: 3, ruleCount: 1))
            #expect(try labels(db) == ["Zakgeld", "Zakgeld", "Zakgeld", "Zakgeld", "Sport"])
            #expect(try LabelService.spellingVariants(db).isEmpty)
            #expect(throws: BudgetError.self) { try LabelService.mergeLabels(db, ["Sport"], into: "") }
            #expect(try LabelService.mergeLabels(db, [], into: "Zakgeld") == LabelRenameResult())
            #expect(LabelService.normalize("  Zak   GELD ") == "zak geld")
        }
    }
}
