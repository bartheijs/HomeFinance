import Foundation
import GRDB
import HFCore
import Testing
@testable import HFBudget

/// Verrekenen met spaar in twee richtingen: afvinken boekt, bankregels worden daarna alleen aangehangen.
@Suite struct SavingsNettingTests {
    /// Handmatige boeking op de betaalrekening die met spaar verrekend wordt.
    @discardableResult
    private func mark(_ db: Database, _ fx: Fixture, _ cents: Int64, _ label: String, pot: Pot? = nil,
                      day: String = "2027-04-01") throws -> Entry {
        try EntryService.create(db, EntryDraft(accountId: fx.betaal.id!, day: d(day), amount: c(cents), label: label,
                                               potId: pot?.id, reimburse: true))
    }
    private func moves(_ list: [PotMovement]) -> [String] {
        list.map { "\($0.pot?.name ?? "-"):\($0.amount.cents)" }
    }
    private func lines(_ entries: [Entry]) -> [String] {
        entries.map { "\($0.potId.map(String.init) ?? "-"):\($0.amount.cents)" }
    }
    private func balance(_ db: Database, _ account: Account, _ day: String = "2027-12-31") throws -> Money {
        try BalanceService.balance(db, accountId: account.id!, on: d(day))
    }
    private func count(_ db: Database) throws -> Int { try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM entry") ?? -1 }

    @Test func alleenUitgaven() throws {
        let fx = try Fixture()
        try fx.app.write { db in
            let a = try mark(db, fx, -12_000, "Tandarts", pot: fx.potVerzekering)
            let b = try mark(db, fx, -3_050, "Schoolreis")
            let open = try SavingsTransferService.openReimbursements(db)
            // 120,00 + 30,50 uit spaar, niets erheen: netto 150,50 van spaar naar betaal.
            #expect(open.fromSavings == c(15_050) && open.toSavings == .zero && open.net == c(15_050))
            #expect(open.total == c(15_050))
            #expect(moves(open.perPot) == ["Verzekering:12000", "-:3050"])
            #expect(try SavingsTransferService.openWithoutPot(db).map(\.id) == [b.id])

            let transfer = try SavingsTransferService.createSavingsTransfer(db, entryIds: [a.id!, b.id!], day: d("2027-04-05"))
            #expect(transfer.amount == c(15_050) && !transfer.done)
            let summary = try SavingsTransferService.summary(db, savingsTransferId: transfer.id!)
            #expect(summary.needsBankTransfer && summary.bookedEntries.isEmpty && summary.net == c(15_050))
            #expect(summary.checkingAccountId == fx.betaal.id && summary.savingsAccountId == fx.spaar.id)
            #expect(try SavingsTransferService.openReimbursements(db).net == .zero)
            #expect(try SavingsTransferService.openWithoutPot(db).isEmpty)
            // Vastleggen boekt nog niets: betaal 1.000,00 − 150,50, spaar ongewijzigd.
            #expect(try balance(db, fx.betaal) == c(84_950) && (try balance(db, fx.spaar) == c(500_000)))
        }
    }

    @Test func alleenBijschrijvingenAfvinkenBoektBeideRekeningen() throws {
        let fx = try Fixture()
        try fx.app.write { db in
            let a = try mark(db, fx, 20_000, "Spaargeld kind", pot: fx.potSpaar)
            let b = try mark(db, fx, 5_000, "Verjaardagsgeld", pot: fx.potSpaar)
            let open = try SavingsTransferService.openReimbursements(db)
            // 200,00 + 50,00 doorstorten: netto −250,00 (van betaal naar spaar), de pot krijgt 250,00.
            #expect(open.fromSavings == .zero && open.toSavings == c(25_000) && open.net == c(-25_000))
            #expect(moves(open.perPot) == ["Spaarpot kind:-25000"])
            let transfer = try SavingsTransferService.createSavingsTransfer(db, entryIds: [a.id!, b.id!], day: d("2027-04-05"))
            #expect(transfer.amount == c(-25_000))
            #expect(try balance(db, fx.betaal) == c(125_000))

            let done = try SavingsTransferService.markDone(db, savingsTransferId: transfer.id!, on: d("2027-04-06"))
            #expect(done.done && done.doneAt != nil)
            let booked = try SavingsTransferService.summary(db, savingsTransferId: transfer.id!).bookedEntries
            let spaar = try #require(booked.first { $0.accountId == fx.spaar.id })
            let betaal = try #require(booked.first { $0.accountId == fx.betaal.id })
            #expect(booked.count == 2 && booked.allSatisfy { $0.day == d("2027-04-06") && $0.bankTransactionId == nil })
            #expect(spaar.amount == c(25_000) && spaar.potId == fx.potSpaar.id)
            #expect(betaal.amount == c(-25_000) && betaal.label == "Verrekening spaar" && !betaal.reimburse)
            #expect(betaal.budgetItemId == nil && betaal.note == "Verrekening #\(transfer.id!)")
            #expect(spaar.counterEntryId == betaal.id && betaal.counterEntryId == spaar.id)
            // Betaal: 1.000 + 250 − 250 = 1.000,00. Spaar: 5.000 + 250 = 5.250,00. Pot: 250,00.
            #expect(try balance(db, fx.betaal) == c(100_000) && (try balance(db, fx.spaar) == c(525_000)))
            #expect(try PotService.balance(db, potId: fx.potSpaar.id!) == c(25_000))

            // Nog eens afvinken boekt niet opnieuw.
            let before = try count(db)
            try SavingsTransferService.markDone(db, savingsTransferId: transfer.id!, on: d("2027-04-07"))
            #expect(try count(db) == before)
        }
    }

    @Test func gemengdMetNettoNulPositiefEnNegatief() throws {
        let fx = try Fixture()
        try fx.app.write { db in
            let tandarts = try mark(db, fx, -12_000, "Tandarts", pot: fx.potVerzekering)
            let spaargeld = try mark(db, fx, 20_000, "Spaargeld kind", pot: fx.potSpaar)
            let cadeau = try mark(db, fx, -3_000, "Cadeau uit spaarpot", pot: fx.potSpaar)
            let huisje = try mark(db, fx, -5_000, "Huisje", pot: fx.potVakantie)
            let all = [tandarts, spaargeld, cadeau, huisje].map { $0.id! }

            // Uit spaar: 120 + 30 + 50 = 200,00. Naar spaar: 200,00. Netto nul.
            // Per pot: Verzekering 120 eruit, Vakantie 50 eruit, Spaarpot 200 erin − 30 eruit = 170 erin.
            let open = try SavingsTransferService.openReimbursements(db)
            #expect(open.fromSavings == c(20_000) && open.toSavings == c(20_000) && open.net == .zero)
            #expect(moves(open.perPot) == ["Verzekering:12000", "Vakantie:5000", "Spaarpot kind:-17000"])

            let nul = try SavingsTransferService.createSavingsTransfer(db, entryIds: all, day: d("2027-04-05"))
            #expect(nul.amount == .zero)
            #expect(try SavingsTransferService.summary(db, savingsTransferId: nul.id!).needsBankTransfer == false)

            // Afvinken bij netto nul: alleen de potmutaties, samen nul, en niets op de betaalrekening.
            try SavingsTransferService.markDone(db, savingsTransferId: nul.id!, on: d("2027-04-05"))
            let summary = try SavingsTransferService.summary(db, savingsTransferId: nul.id!)
            #expect(lines(summary.bookedEntries) == ["\(fx.potVerzekering.id!):-12000", "\(fx.potVakantie.id!):-5000",
                                                     "\(fx.potSpaar.id!):17000"])
            #expect(summary.bookedEntries.allSatisfy { $0.accountId == fx.spaar.id && $0.counterEntryId == nil })
            #expect(summary.isConfirmed)
            #expect(try PotService.balance(db, potId: fx.potSpaar.id!) == c(17_000))
            #expect(try balance(db, fx.spaar) == c(500_000) && (try balance(db, fx.betaal) == c(100_000)))
            #expect(try SavingsTransferService.unconfirmed(db, today: d("2027-12-31")).isEmpty)

            // Heropenen haalt de boekingen weg; verwijderen maakt alles weer open.
            let reopened = try SavingsTransferService.reopen(db, savingsTransferId: nul.id!)
            #expect(!reopened.done)
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM entry WHERE accountId = ?", arguments: [fx.spaar.id]) == 0)
            #expect(try PotService.balance(db, potId: fx.potSpaar.id!) == .zero)
            try SavingsTransferService.delete(db, savingsTransferId: nul.id!)
            #expect(try SavingsTransferService.openReimbursements(db).entries.count == 4)

            // Tandarts + spaargeld: 120 uit, 200 erheen → netto −80,00 (naar spaar).
            let negatief = try SavingsTransferService.createSavingsTransfer(db, entryIds: [tandarts.id!, spaargeld.id!],
                                                                           day: d("2027-04-05"))
            #expect(negatief.amount == c(-8_000))
            // Cadeau + huisje: 30 + 50 uit → netto +80,00 (naar betaal).
            let positief = try SavingsTransferService.createSavingsTransfer(db, entryIds: [cadeau.id!, huisje.id!],
                                                                           day: d("2027-04-05"))
            #expect(positief.amount == c(8_000))
            #expect(moves(try SavingsTransferService.summary(db, savingsTransferId: negatief.id!).perPot)
                    == ["Verzekering:12000", "Spaarpot kind:-20000"])
            // +80,00 op de spaarrekening hoort bij de negatieve; die is nog niet afgevinkt.
            let bij = try fx.tx(db, fx.spaar, "2027-04-07", 8_000, iban: Fixture.betaalIban)
            let match = try #require(try SavingsTransferService.recognize(db, bankTransaction: bij))
            #expect(match.transfer?.id == negatief.id && match.needsMarkDone && match.side == .savings)
        }
    }

    @Test func afvinkenEnBankregelsAanhangen() throws {
        let fx = try Fixture()
        try fx.app.write { db in
            let ids = [try mark(db, fx, -12_000, "Tandarts", pot: fx.potVerzekering),
                       try mark(db, fx, -3_050, "Schoolreis"),
                       try mark(db, fx, 2_000, "Borg terug", pot: fx.potVakantie)].map { $0.id! }
            // 120,00 + 30,50 − 20,00 = 130,50 van spaar naar betaal.
            let transfer = try SavingsTransferService.createSavingsTransfer(db, entryIds: ids, day: d("2027-04-05"))
            #expect(transfer.amount == c(13_050))
            try SavingsTransferService.markDone(db, savingsTransferId: transfer.id!, on: d("2027-04-05"))
            var summary = try SavingsTransferService.summary(db, savingsTransferId: transfer.id!)
            // Spaar: Verzekering 120 eruit, Vakantie 20 erin, 30,50 zonder pot eruit = −130,50. Betaal: +130,50.
            #expect(lines(summary.bookedEntries) == ["\(fx.potVerzekering.id!):-12000", "\(fx.potVakantie.id!):2000",
                                                     "-:-3050", "-:13050"])
            // Betaal: 1.000 − 120 − 30,50 + 20 + 130,50 = 1.000,00. Spaar: 5.000 − 130,50 = 4.869,50.
            #expect(try balance(db, fx.betaal) == c(100_000) && (try balance(db, fx.spaar) == c(486_950)))
            #expect(try PotService.balance(db, potId: fx.potVerzekering.id!) == c(-12_000))
            #expect(try PotService.balance(db, potId: fx.potVakantie.id!) == c(2_000))
            #expect(!summary.isConfirmed)

            var batch = ImportBatch(accountId: fx.betaal.id!, fileName: "test.csv", lastDay: d("2027-04-07"),
                                    closingBalance: c(100_000))
            try batch.insert(db)
            let bij = try fx.tx(db, fx.betaal, "2027-04-07", 13_050, iban: "nl00 test 0000 0000 02", batchId: batch.id)
            let af = try fx.tx(db, fx.spaar, "2027-04-06", -13_050, iban: Fixture.betaalIban)
            let vreemd = try fx.tx(db, fx.betaal, "2027-04-08", 13_050, iban: "NL00TEST0000000099")
            let anderBedrag = try fx.tx(db, fx.betaal, "2027-04-08", 13_000, iban: Fixture.spaarIban)
            let zonderIban = try fx.tx(db, fx.betaal, "2027-04-12", 13_050)
            let teLaat = try fx.tx(db, fx.betaal, "2027-04-13", 13_050, iban: Fixture.spaarIban)
            let verkeerdeKant = try fx.tx(db, fx.spaar, "2027-04-06", 13_050, iban: Fixture.betaalIban)

            let betaal = try #require(try SavingsTransferService.recognize(db, bankTransaction: bij))
            #expect(betaal.side == .checking && betaal.transfer?.id == transfer.id && !betaal.needsMarkDone)
            #expect(try SavingsTransferService.recognize(db, bankTransaction: af)?.side == .savings)
            // Zonder tegenrekening telt het bedrag; 7 dagen na het afvinken mag nog, 8 niet.
            #expect(try SavingsTransferService.recognize(db, bankTransaction: zonderIban)?.transfer?.id == transfer.id)
            for t in [vreemd, anderBedrag, teLaat, verkeerdeKant] {
                #expect(try SavingsTransferService.recognize(db, bankTransaction: t) == nil)
            }
            #expect(Set(try SavingsTransferService.recognizeAll(db, accountId: fx.betaal.id!).keys) == [bij.id!, zonderIban.id!])
            #expect(try BalanceService.importCheck(db, batchId: batch.id!).balanceMatches == nil)

            // Aanhangen: geen nieuwe boekingen, geen ander saldo; de boeking krijgt de bankregel en haar dag.
            let before = try count(db)
            summary = try SavingsTransferService.attach(db, savingsTransferId: transfer.id!, bankTransactionId: bij.id!)
            #expect(try count(db) == before)
            #expect(summary.checkingTransactionId == bij.id && summary.savingsTransactionId == nil && !summary.isConfirmed)
            #expect(try fx.status(db, bij.id!) == .verwerkt)
            let attached = try fx.entries(db, tx: bij.id!)
            #expect(attached.count == 1 && attached[0].amount == c(13_050) && attached[0].day == d("2027-04-07"))
            #expect(try balance(db, fx.betaal) == c(100_000) && (try balance(db, fx.spaar) == c(486_950)))
            // De dag is verschoven van 5 naar 7 april: op 6 april staat de 130,50 er nog niet.
            #expect(try balance(db, fx.betaal, "2027-04-06") == c(86_950))
            let check = try BalanceService.importCheck(db, batchId: batch.id!)
            #expect(check.allHandled && check.balanceMatches == true)
            #expect(throws: BudgetError.alreadyBooked) {
                try SavingsTransferService.attach(db, savingsTransferId: transfer.id!, bankTransactionId: bij.id!)
            }
            #expect(throws: BudgetError.self) {
                try SavingsTransferService.attach(db, savingsTransferId: transfer.id!, bankTransactionId: zonderIban.id!)
            }
            #expect(try SavingsTransferService.recognize(db, bankTransaction: zonderIban) == nil)

            // De spaarkant: drie boekingen aan één bankregel, samen −130,50.
            #expect(try SavingsTransferService.attachAll(db, accountId: fx.spaar.id!) == 1)
            summary = try SavingsTransferService.summary(db, savingsTransferId: transfer.id!)
            #expect(summary.isConfirmed && summary.savingsTransactionId == af.id)
            let spaarEntries = try fx.entries(db, tx: af.id!)
            #expect(spaarEntries.count == 3 && spaarEntries.allSatisfy { $0.day == d("2027-04-06") })
            #expect(spaarEntries.map(\.amount).sum() == c(-13_050))
            #expect(try count(db) == before)
            #expect(try balance(db, fx.spaar) == c(486_950))

            // De rest van de module blijft van deze boekingen af.
            #expect(throws: BudgetError.savingsTransferBooking) { try BookingService.unbook(db, bankTransactionId: bij.id!) }
            #expect(throws: BudgetError.savingsTransferBooking) {
                try BookingService.book(db, bankTransactionId: af.id!, allocations: [Allocation(amount: c(-13_050), label: "x")])
            }
            #expect(throws: BudgetError.savingsTransferBooking) { try EntryService.delete(db, entryId: spaarEntries[0].id!) }
            #expect(BudgetError.savingsTransferBooking.localizedDescription.contains("Spaaroverboekingen"))
            #expect(throws: BudgetError.self) { try SavingsTransferService.reopen(db, savingsTransferId: transfer.id!) }
            #expect(throws: BudgetError.self) { try SavingsTransferService.delete(db, savingsTransferId: transfer.id!) }
            // Label en notitie wijzigen mag wel.
            var draft = try EntryService.draft(db, entryId: attached[0].id!)
            draft.label = "Terug van spaar"
            #expect(try EntryService.update(db, entryId: attached[0].id!, draft).label == "Terug van spaar")

            // Loskoppelen zet de bankregels terug op nieuw; daarna kan heropenen en verwijderen.
            try SavingsTransferService.detach(db, bankTransactionId: bij.id!)
            try SavingsTransferService.detach(db, bankTransactionId: af.id!)
            #expect(try fx.status(db, bij.id!) == .nieuw && (try fx.status(db, af.id!) == .nieuw))
            #expect(try count(db) == before && (try balance(db, fx.betaal) == c(100_000)))
            #expect(throws: BudgetError.self) { try SavingsTransferService.detach(db, bankTransactionId: vreemd.id!) }
            try SavingsTransferService.reopen(db, savingsTransferId: transfer.id!)
            summary = try SavingsTransferService.summary(db, savingsTransferId: transfer.id!)
            #expect(summary.bookedEntries.isEmpty && !summary.transfer.done)
            #expect(try balance(db, fx.betaal) == c(86_950) && (try balance(db, fx.spaar) == c(500_000)))
            #expect(try PotService.balance(db, potId: fx.potVerzekering.id!) == .zero)
            try SavingsTransferService.delete(db, savingsTransferId: transfer.id!)
            #expect(try SavingsTransferService.openReimbursements(db).net == c(13_050))
        }
    }

    @Test func tweeKandidatenMetHetzelfdeBedrag() throws {
        let fx = try Fixture()
        try fx.app.write { db in
            let a = try mark(db, fx, -5_000, "Tandarts", pot: fx.potVerzekering)
            let b = try mark(db, fx, -5_000, "Huisje", pot: fx.potVakantie)
            let eerste = try SavingsTransferService.createSavingsTransfer(db, entryIds: [a.id!], day: d("2027-04-05"))
            let tweede = try SavingsTransferService.createSavingsTransfer(db, entryIds: [b.id!], day: d("2027-04-05"))
            try SavingsTransferService.markDone(db, savingsTransferId: eerste.id!, on: d("2027-04-05"))
            try SavingsTransferService.markDone(db, savingsTransferId: tweede.id!, on: d("2027-04-05"))

            let bij1 = try fx.tx(db, fx.betaal, "2027-04-07", 5_000, iban: Fixture.spaarIban)
            let twijfel = try #require(try SavingsTransferService.recognize(db, bankTransaction: bij1))
            #expect(twijfel.isAmbiguous && twijfel.transfer == nil && !twijfel.needsMarkDone)
            #expect(twijfel.transfers.map(\.id) == [eerste.id, tweede.id])
            #expect(try SavingsTransferService.attachAll(db, accountId: fx.betaal.id!) == 0)
            #expect(try fx.status(db, bij1.id!) == .nieuw)

            // De gebruiker kiest de tweede; de volgende bankregel kan dan alleen nog de eerste zijn.
            try SavingsTransferService.attach(db, savingsTransferId: tweede.id!, bankTransactionId: bij1.id!)
            let bij2 = try fx.tx(db, fx.betaal, "2027-04-08", 5_000, iban: Fixture.spaarIban)
            #expect(try SavingsTransferService.recognize(db, bankTransaction: bij2)?.transfer?.id == eerste.id)
            #expect(try SavingsTransferService.attachAll(db, accountId: fx.betaal.id!) == 1)
            #expect(try fx.entries(db, tx: bij2.id!).map(\.note) == ["Verrekening #\(eerste.id!)"])

            // Twee bankregels op de spaarrekening in één ronde: de eerste is een twijfelgeval, dus niets.
            try fx.tx(db, fx.spaar, "2027-04-07", -5_000, iban: Fixture.betaalIban)
            try fx.tx(db, fx.spaar, "2027-04-08", -5_000, iban: Fixture.betaalIban)
            #expect(try SavingsTransferService.attachAll(db, accountId: fx.spaar.id!) == 0)
            #expect(try SavingsTransferService.recognizeAll(db, accountId: fx.spaar.id!).values.allSatisfy(\.isAmbiguous))
        }
    }

    @Test func nietAfgevinktMaarWelEenBankregel() throws {
        let fx = try Fixture()
        try fx.app.write { db in
            let a = try mark(db, fx, -4_000, "Huisje", pot: fx.potVakantie, day: "2027-05-01")
            let transfer = try SavingsTransferService.createSavingsTransfer(db, entryIds: [a.id!], day: d("2027-05-05"))
            let af = try fx.tx(db, fx.spaar, "2027-05-07", -4_000, iban: Fixture.betaalIban)
            let match = try #require(try SavingsTransferService.recognize(db, bankTransaction: af))
            #expect(match.transfer?.id == transfer.id && match.needsMarkDone)
            // Aanhangen kan pas na afvinken; de automatische ronde slaat hem over.
            #expect(throws: BudgetError.self) {
                try SavingsTransferService.attach(db, savingsTransferId: transfer.id!, bankTransactionId: af.id!)
            }
            #expect(try SavingsTransferService.attachAll(db, accountId: fx.spaar.id!) == 0)
            #expect(try fx.status(db, af.id!) == .nieuw)

            // "Afvinken en aanhangen": afvinken op de dag van de bankregel, daarna aanhangen.
            try SavingsTransferService.markDone(db, savingsTransferId: transfer.id!, on: af.day)
            let summary = try SavingsTransferService.attach(db, savingsTransferId: transfer.id!, bankTransactionId: af.id!)
            #expect(summary.savingsTransactionId == af.id && summary.transfer.done)
            #expect(try fx.entries(db, tx: af.id!).map(\.day) == [d("2027-05-07")])
            #expect(try PotService.balance(db, potId: fx.potVakantie.id!) == c(-4_000))
            // Betaal: 1.000 − 40 + 40 = 1.000,00. Spaar: 5.000 − 40 = 4.960,00.
            #expect(try balance(db, fx.betaal) == c(100_000) && (try balance(db, fx.spaar) == c(496_000)))
        }
    }

    @Test func onbevestigdNaVijfDagen() throws {
        let fx = try Fixture()
        try fx.app.write { db in
            let a = try mark(db, fx, -4_000, "Huisje", pot: fx.potVakantie)
            let b = try mark(db, fx, -1_000, "Nog open", pot: fx.potVakantie)
            let transfer = try SavingsTransferService.createSavingsTransfer(db, entryIds: [a.id!], day: d("2027-04-05"))
            let nietAfgevinkt = try SavingsTransferService.createSavingsTransfer(db, entryIds: [b.id!], day: d("2027-04-01"))
            #expect(try SavingsTransferService.unconfirmed(db, today: d("2027-06-01")).isEmpty)
            try SavingsTransferService.markDone(db, savingsTransferId: transfer.id!, on: d("2027-04-05"))
            // 5 april + 5 dagen = 10 april.
            #expect(try SavingsTransferService.unconfirmed(db, today: d("2027-04-09")).isEmpty)
            #expect(try SavingsTransferService.unconfirmed(db, today: d("2027-04-10")).map(\.id) == [transfer.id])

            let bij = try fx.tx(db, fx.betaal, "2027-04-06", 4_000, iban: Fixture.spaarIban)
            let af = try fx.tx(db, fx.spaar, "2027-04-06", -4_000, iban: Fixture.betaalIban)
            try SavingsTransferService.attach(db, savingsTransferId: transfer.id!, bankTransactionId: bij.id!)
            #expect(try SavingsTransferService.unconfirmed(db, today: d("2027-04-20")).map(\.id) == [transfer.id])
            try SavingsTransferService.attach(db, savingsTransferId: transfer.id!, bankTransactionId: af.id!)
            #expect(try SavingsTransferService.unconfirmed(db, today: d("2027-04-20")).isEmpty)
            #expect(!nietAfgevinkt.done)
        }
    }

    @Test func verschillendeRekeningenWordenGeweigerd() throws {
        let fx = try Fixture()
        try fx.app.write { db in
            let spaar2 = try AccountService.create(db, Account(name: "Testspaar 2", iban: "NL00TEST0000000003",
                                                               kind: .spaar, openingDate: d("2027-01-01")))
            let betaal2 = try AccountService.create(db, Account(name: "Testbetaal 2", iban: "NL00TEST0000000004",
                                                                kind: .betaal, openingDate: d("2027-01-01")))
            let ander = try PotService.create(db, Pot(accountId: spaar2.id!, name: "Andere pot", kind: .spaar))
            let a = try mark(db, fx, -1_000, "A", pot: fx.potVakantie)
            let b = try mark(db, fx, -2_000, "B", pot: ander)
            let opBetaal2 = try EntryService.create(db, EntryDraft(accountId: betaal2.id!, day: d("2027-04-01"),
                                                                   amount: c(-500), label: "C", potId: fx.potVakantie.id,
                                                                   reimburse: true))
            #expect(throws: BudgetError.self) {
                try SavingsTransferService.createSavingsTransfer(db, entryIds: [a.id!, b.id!], day: d("2027-04-05"))
            }
            #expect(throws: BudgetError.self) {
                try SavingsTransferService.createSavingsTransfer(db, entryIds: [a.id!, opBetaal2.id!], day: d("2027-04-05"))
            }
            // Een verrekening met de andere spaarrekening wordt alleen daar herkend en geboekt.
            let transfer = try SavingsTransferService.createSavingsTransfer(db, entryIds: [b.id!], day: d("2027-04-05"))
            let fout = try fx.tx(db, fx.spaar, "2027-04-06", -2_000, iban: Fixture.betaalIban)
            let goed = try fx.tx(db, spaar2, "2027-04-06", -2_000, iban: Fixture.betaalIban)
            let bijFout = try fx.tx(db, fx.betaal, "2027-04-06", 2_000, iban: Fixture.spaarIban)
            let bijGoed = try fx.tx(db, fx.betaal, "2027-04-06", 2_000, iban: "NL00TEST0000000003")
            #expect(try SavingsTransferService.recognize(db, bankTransaction: fout) == nil)
            #expect(try SavingsTransferService.recognize(db, bankTransaction: bijFout) == nil)
            #expect(try SavingsTransferService.recognize(db, bankTransaction: goed)?.transfer?.id == transfer.id)
            #expect(try SavingsTransferService.recognize(db, bankTransaction: bijGoed)?.transfer?.id == transfer.id)
            try SavingsTransferService.markDone(db, savingsTransferId: transfer.id!, on: d("2027-04-06"))
            #expect(try balance(db, spaar2) == c(-2_000) && (try balance(db, fx.spaar) == c(500_000)))
            #expect(BudgetError.potRequiresReimburse.localizedDescription.contains("verrekenen met spaar"))
        }
    }
}
