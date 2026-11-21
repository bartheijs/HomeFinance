import Foundation
import GRDB
import HFCore
import Testing
@testable import HFBudget

@Suite struct RecognitionTests {
    /// Vaste storting 100,00 + 150,00 = 250,00 van Testbetaal naar Testspaar.
    private func vast(_ db: Database, _ fx: Fixture, source: Bool = true) throws -> Distribution {
        let vast = try DistributionService.create(db, name: "Vast sparen", accountId: fx.spaar.id!,
                                                  sourceAccountId: source ? fx.betaal.id : nil)
        try DistributionService.setLines(db, distributionId: vast.id!, [
            (fx.potVerzekering.id!, c(10_000)), (fx.potVakantie.id!, c(15_000))])
        return vast
    }

    @Test func herkomstrekeningValidatie() throws {
        let fx = try Fixture()
        try fx.app.write { db in
            #expect(throws: BudgetError.self) {
                try DistributionService.create(db, name: "Fout", accountId: fx.spaar.id!, sourceAccountId: fx.spaar.id)
            }
            let spaar2 = try AccountService.create(db, Account(name: "Testspaar 2", iban: "NL00TEST0000000003",
                                                               kind: .spaar, openingDate: d("2027-01-01")))
            let vast = try vast(db, fx, source: false)
            #expect(vast.sourceAccountId == nil)
            #expect(throws: BudgetError.self) {
                try DistributionService.setSource(db, distributionId: vast.id!, sourceAccountId: spaar2.id)
            }
            #expect(try DistributionService.setSource(db, distributionId: vast.id!, sourceAccountId: fx.betaal.id)
                .sourceAccountId == fx.betaal.id)
            #expect(try DistributionService.setSource(db, distributionId: vast.id!, sourceAccountId: nil)
                .sourceAccountId == nil)
        }
    }

    @Test func beideKantenMetIban() throws {
        let fx = try Fixture()
        try fx.app.write { db in
            let vast = try vast(db, fx)
            try DistributionService.link(db, distributionId: vast.id!, budgetItemId: fx.reserveringen.id!)
            // IBAN's worden vergeleken zonder spaties en hoofdletters.
            let bij = try fx.tx(db, fx.spaar, "2027-01-28", 25_000, iban: "nl00 test 0000 0000 01")
            let af = try fx.tx(db, fx.betaal, "2027-01-27", -25_000, iban: "nl00test0000000002")

            let doel = try #require(try DistributionService.recognize(db, bankTransaction: bij))
            #expect(doel.side == .destination && doel.distribution?.id == vast.id && !doel.isAmbiguous)
            #expect(doel.exactAmount && doel.difference == .zero && doel.warning == nil)
            #expect(doel.allocations.map(\.amount) == [c(10_000), c(15_000)])
            #expect(doel.allocations.map(\.potId) == [fx.potVerzekering.id, fx.potVakantie.id])

            let herkomst = try #require(try DistributionService.recognize(db, bankTransaction: af))
            #expect(herkomst.side == .source && herkomst.distribution?.id == vast.id)
            #expect(herkomst.exactAmount && herkomst.difference == .zero && herkomst.warning == nil)
            #expect(herkomst.allocations == [Allocation(amount: c(-25_000), label: "Vast sparen",
                                                        budgetItemId: fx.reserveringen.id)])

            // De voorstellen zijn direct te boeken.
            try BookingService.book(db, bankTransactionId: bij.id!, allocations: doel.allocations)
            try BookingService.book(db, bankTransactionId: af.id!, allocations: herkomst.allocations)
            #expect(try PotService.balance(db, potId: fx.potVakantie.id!) == c(15_000))

            // Andere richting of een vreemde tegenrekening is geen storting.
            let terug = try fx.tx(db, fx.spaar, "2027-02-01", -25_000, iban: Fixture.betaalIban)
            let vreemd = try fx.tx(db, fx.betaal, "2027-02-01", -25_000, iban: "NL00TEST0000000099")
            let zonder = try fx.tx(db, fx.betaal, "2027-02-01", -25_000)
            for t in [terug, vreemd, zonder] {
                #expect(try DistributionService.recognize(db, bankTransaction: t) == nil)
            }
            try DistributionService.setArchived(db, distributionId: vast.id!, true)
            #expect(try DistributionService.recognize(db, bankTransaction: bij) == nil)
        }
    }

    @Test func afwijkendBedragMetEnZonderHerkomst() throws {
        let fx = try Fixture()
        try fx.app.write { db in
            let vast = try vast(db, fx)
            let meer = try fx.tx(db, fx.spaar, "2027-01-28", 26_000, iban: Fixture.betaalIban)
            let meerZonderIban = try fx.tx(db, fx.spaar, "2027-01-28", 26_000)
            let exactZonderIban = try fx.tx(db, fx.spaar, "2027-01-28", 25_000)
            let exactVreemd = try fx.tx(db, fx.spaar, "2027-01-28", 25_000, iban: "NL00TEST0000000099")
            let afMeer = try fx.tx(db, fx.betaal, "2027-01-27", -24_000, iban: Fixture.spaarIban)

            // Met herkomst: de tegenrekening beslist, ook bij 260,00 in plaats van 250,00.
            let match = try #require(try DistributionService.recognize(db, bankTransaction: meer))
            #expect(!match.exactAmount && match.difference == c(1_000) && match.warning != nil)
            #expect(match.allocations.map(\.amount) == [c(10_000), c(15_000)])
            #expect(try DistributionService.recognize(db, bankTransaction: meerZonderIban) == nil)
            #expect(try DistributionService.recognize(db, bankTransaction: exactZonderIban)?.exactAmount == true)
            #expect(try DistributionService.recognize(db, bankTransaction: exactVreemd) == nil)
            // Herkomstkant met 240,00: verschil −10,00, één regel met het bankbedrag.
            let af = try #require(try DistributionService.recognize(db, bankTransaction: afMeer))
            #expect(!af.exactAmount && af.difference == c(-1_000) && af.allocations.map(\.amount) == [c(-24_000)])

            // Zonder herkomst: alleen het exacte bedrag, en de herkomstkant wordt niet herkend.
            try DistributionService.setSource(db, distributionId: vast.id!, sourceAccountId: nil)
            #expect(try DistributionService.recognize(db, bankTransaction: meer) == nil)
            #expect(try DistributionService.recognize(db, bankTransaction: exactVreemd)?.distribution?.id == vast.id)
            #expect(try DistributionService.recognize(db, bankTransaction: afMeer) == nil)
        }
    }

    @Test func tweeStortingenTussenDezelfdeRekeningen() throws {
        let fx = try Fixture()
        try fx.app.write { db in
            let vast = try vast(db, fx)
            let kind = try DistributionService.create(db, name: "Kind", accountId: fx.spaar.id!, sourceAccountId: fx.betaal.id)
            try DistributionService.setLines(db, distributionId: kind.id!, [(fx.potSpaar.id!, c(2_500))])

            // Het totaal beslist: 25,00 is de storting "Kind".
            let klein = try fx.tx(db, fx.spaar, "2027-01-28", 2_500, iban: Fixture.betaalIban)
            #expect(try DistributionService.recognize(db, bankTransaction: klein)?.distribution?.id == kind.id)
            let afKlein = try fx.tx(db, fx.betaal, "2027-01-27", -2_500, iban: Fixture.spaarIban)
            #expect(try DistributionService.recognize(db, bankTransaction: afKlein)?.distribution?.id == kind.id)

            // Geen van beide totalen past: beide kandidaten, de gebruiker kiest.
            let anders = try fx.tx(db, fx.spaar, "2027-01-28", 9_999, iban: Fixture.betaalIban)
            let twijfel = try #require(try DistributionService.recognize(db, bankTransaction: anders))
            #expect(twijfel.isAmbiguous && twijfel.distribution == nil && twijfel.allocations.isEmpty)
            #expect(twijfel.distributions.map(\.id) == [vast.id, kind.id])
            #expect(!twijfel.exactAmount && twijfel.warning != nil)
            let gekozen = try DistributionService.proposal(db, distributionId: kind.id!, for: anders)
            #expect(gekozen.side == .destination && gekozen.difference == c(7_499))
            #expect(gekozen.allocations.map(\.amount) == [c(2_500)])

            // Twee stortingen met hetzelfde totaal: ook dan alle kandidaten.
            let ook = try DistributionService.create(db, name: "Ook 25", accountId: fx.spaar.id!, sourceAccountId: fx.betaal.id)
            try DistributionService.setLines(db, distributionId: ook.id!, [(fx.potVakantie.id!, c(2_500))])
            #expect(try DistributionService.recognize(db, bankTransaction: klein)?.distributions.count == 3)

            // Alle nieuwe transacties van een rekening in één keer; geboekte doen niet mee.
            let los = try fx.tx(db, fx.spaar, "2027-01-29", 123)
            try BookingService.book(db, bankTransactionId: anders.id!, allocations: [Allocation(amount: c(9_999), label: "x")])
            let all = try DistributionService.recognizeAll(db, accountId: fx.spaar.id!)
            #expect(Set(all.keys) == [klein.id!])
            #expect(all[los.id!] == nil)
            #expect(try DistributionService.recognizeAll(db, accountId: fx.betaal.id!).keys.sorted() == [afKlein.id!])
        }
    }

    @Test func herkomstkantZonderGekoppeldePost() throws {
        let fx = try Fixture()
        try fx.app.write { db in
            let vast = try vast(db, fx)
            let af = try fx.tx(db, fx.betaal, "2027-01-27", -25_000, iban: Fixture.spaarIban)
            let match = try #require(try DistributionService.recognize(db, bankTransaction: af))
            #expect(match.exactAmount && match.allocations == [Allocation(amount: c(-25_000), label: "Vast sparen")])
            #expect(match.warning?.contains("overig") == true)

            // De post telt alleen in het jaar van de transactie.
            try DistributionService.link(db, distributionId: vast.id!, budgetItemId: fx.boodschappen.id!)
            #expect(try DistributionService.recognize(db, bankTransaction: af)?.allocations.first?.budgetItemId
                    == fx.boodschappen.id)
            let later = try fx.tx(db, fx.betaal, "2028-01-27", -25_000, iban: Fixture.spaarIban)
            let match2028 = try #require(try DistributionService.recognize(db, bankTransaction: later))
            #expect(match2028.allocations.first?.budgetItemId == nil && match2028.warning?.contains("2028") == true)
        }
    }
}

@Suite struct ForecastTests {
    @Test func verwachtingBeheren() throws {
        let fx = try Fixture()
        try fx.app.write { db in
            let gift = try ForecastService.create(db, potId: fx.potSpaar.id!, day: d("2027-05-15"), amount: c(50_000),
                                                  label: "  Gift  ")
            let uitgave = try ForecastService.create(db, potId: fx.potSpaar.id!, day: d("2026-12-01"), amount: c(-20_000))
            #expect(gift.label == "Gift" && uitgave.label == "" && !gift.isRealized)
            #expect(throws: BudgetError.self) {
                try ForecastService.create(db, potId: fx.potSpaar.id!, day: d("2027-05-15"), amount: .zero)
            }
            #expect(throws: BudgetError.notFound(what: "Potje", id: 999)) {
                try ForecastService.create(db, potId: 999, day: d("2027-05-15"), amount: c(1))
            }
            try PotService.archive(db, potId: fx.potVakantie.id!)
            #expect(throws: BudgetError.self) {
                try ForecastService.create(db, potId: fx.potVakantie.id!, day: d("2027-05-15"), amount: c(1))
            }

            var changed = gift
            changed.amount = c(60_000); changed.day = d("2027-06-01"); changed.realizedAt = Date()
            let saved = try ForecastService.update(db, changed)
            #expect(saved.amount == c(60_000) && saved.day == d("2027-06-01") && saved.realizedAt == nil)
            changed.amount = .zero
            #expect(throws: BudgetError.self) { try ForecastService.update(db, changed) }
            #expect(try ForecastService.items(db, potId: fx.potSpaar.id!).map(\.id) == [uitgave.id, gift.id])

            // De verwachting telt nergens in mee: saldo van pot en rekening blijven gelijk.
            #expect(try PotService.balance(db, potId: fx.potSpaar.id!) == .zero)
            #expect(try BalanceService.balance(db, accountId: fx.spaar.id!, on: d("2027-12-31")) == c(500_000))

            try ForecastService.delete(db, forecastItemId: uitgave.id!)
            #expect(try ForecastService.items(db, potId: fx.potSpaar.id!).count == 1)
            #expect(throws: BudgetError.notFound(what: "Verwachting", id: uitgave.id!)) {
                try ForecastService.delete(db, forecastItemId: uitgave.id!)
            }
        }
    }

    @Test func uitgekomenEnWeerOpen() throws {
        let fx = try Fixture()
        try fx.app.write { db in
            func entry(_ cents: Int64, _ account: Account, pot: Int64? = nil) throws -> Entry {
                try EntryService.create(db, EntryDraft(accountId: account.id!, day: d("2027-05-20"), amount: c(cents),
                                                       label: "Boeking", potId: pot))
            }
            let gift = try ForecastService.create(db, potId: fx.potSpaar.id!, day: d("2027-05-15"), amount: c(50_000))
            let tweede = try ForecastService.create(db, potId: fx.potSpaar.id!, day: d("2027-05-16"), amount: c(50_000))
            let bij = try entry(48_000, fx.spaar, pot: fx.potSpaar.id)
            let af = try entry(-48_000, fx.spaar, pot: fx.potSpaar.id)
            let opBetaal = try entry(50_000, fx.betaal)

            #expect(throws: BudgetError.self) { try ForecastService.markRealized(db, forecastItemId: gift.id!, entryId: af.id) }
            #expect(throws: BudgetError.self) {
                try ForecastService.markRealized(db, forecastItemId: gift.id!, entryId: opBetaal.id)
            }
            // Het bedrag mag afwijken (480,00 in plaats van 500,00).
            let done = try ForecastService.markRealized(db, forecastItemId: gift.id!, entryId: bij.id)
            #expect(done.isRealized && done.realizedEntryId == bij.id)
            #expect(throws: BudgetError.self) {
                try ForecastService.markRealized(db, forecastItemId: tweede.id!, entryId: bij.id)
            }
            // Zonder boeking afvinken kan ook.
            #expect(try ForecastService.markRealized(db, forecastItemId: tweede.id!).realizedEntryId == nil)
            #expect(try ForecastService.items(db, potId: fx.potSpaar.id!).isEmpty)
            #expect(try ForecastService.items(db, potId: fx.potSpaar.id!, includeRealized: true).count == 2)

            let open = try ForecastService.reopen(db, forecastItemId: gift.id!)
            #expect(!open.isRealized && open.realizedEntryId == nil)
            #expect(try ForecastService.items(db, potId: fx.potSpaar.id!).map(\.id) == [gift.id])
        }
    }

    @Test func voorstelBijEenBoeking() throws {
        let fx = try Fixture()
        try fx.app.write { db in
            @discardableResult
            func forecast(_ day: String, _ cents: Int64, _ label: String, pot: Pot? = nil) throws -> ForecastItem {
                try ForecastService.create(db, potId: (pot ?? fx.potSpaar).id!, day: d(day), amount: c(cents), label: label)
            }
            // Boeking van 500,00 op 20 mei. 5 % van 520,00 = 26,00 → verschil 20,00 past; 5 % van 530,00 = 26,50 → 30,00 niet.
            let bijna = try forecast("2027-05-10", 52_000, "Binnen 5 %")
            let exactVer = try forecast("2027-06-30", 50_000, "Exact, 41 dagen")
            let exactDicht = try forecast("2027-05-18", 50_000, "Exact, 2 dagen")
            try forecast("2027-05-20", 53_000, "Te ver in bedrag")
            try forecast("2027-07-10", 50_000, "Te ver in tijd")
            try forecast("2027-05-20", -50_000, "Ander teken")
            try forecast("2027-05-20", 50_000, "Andere pot", pot: fx.potVakantie)
            let gedaan = try forecast("2027-05-20", 50_000, "Al uitgekomen")
            try ForecastService.markRealized(db, forecastItemId: gedaan.id!)

            let entry = try EntryService.create(db, EntryDraft(accountId: fx.spaar.id!, day: d("2027-05-20"),
                                                               amount: c(50_000), label: "Bijschrijving",
                                                               potId: fx.potSpaar.id))
            #expect(try ForecastService.suggestRealization(db, entryId: entry.id!).map(\.id)
                    == [exactDicht.id, exactVer.id, bijna.id])
            let zonderPot = try EntryService.create(db, EntryDraft(accountId: fx.spaar.id!, day: d("2027-05-20"),
                                                                   amount: c(50_000), label: "Niet toegewezen"))
            #expect(try ForecastService.suggestRealization(db, entryId: zonderPot.id!).isEmpty)
        }
    }
}

/// 6e: een losse overboeking naar spaar niet aanzien voor de vaste storting, en waarschuwen bij verrekenen op
/// een overboeking met de eigen spaarrekening.
@Suite struct LosseOverboekingTests {
    /// Vaste storting 100,00 + 150,00 = 250,00 van Testbetaal naar Testspaar.
    private func vast(_ db: Database, _ fx: Fixture) throws -> Distribution {
        let vast = try DistributionService.create(db, name: "Vast sparen", accountId: fx.spaar.id!,
                                                  sourceAccountId: fx.betaal.id)
        try DistributionService.setLines(db, distributionId: vast.id!, [
            (fx.potVerzekering.id!, c(10_000)), (fx.potVakantie.id!, c(15_000))])
        return vast
    }

    @Test func grens() {
        let totaal = c(25_000)
        #expect(!DistributionService.isFarFromTotal(c(12_500), total: totaal))   // precies de helft
        #expect(DistributionService.isFarFromTotal(c(12_499), total: totaal))
        #expect(!DistributionService.isFarFromTotal(c(37_500), total: totaal))   // precies anderhalf keer
        #expect(DistributionService.isFarFromTotal(c(37_501), total: totaal))
        #expect(!DistributionService.isFarFromTotal(c(25_000), total: totaal))
        #expect(!DistributionService.isFarFromTotal(c(100), total: .zero))
    }

    @Test func grootVerschilGeenVerdeling() throws {
        let fx = try Fixture()
        try fx.app.write { db in
            let vast = try vast(db, fx)
            // 18,95 en 500,00 naar spaar: te ver van 250,00 af.
            for cents: Int64 in [1_895, 50_000] {
                let los = try fx.tx(db, fx.spaar, "2027-01-28", cents, iban: Fixture.betaalIban)
                let match = try #require(try DistributionService.recognize(db, bankTransaction: los))
                #expect(match.looksSeparate && match.side == .destination && match.distribution?.id == vast.id)
                #expect(match.allocations.isEmpty && !match.exactAmount)
                #expect(match.difference == c(cents) - c(25_000))
                #expect(match.warning?.contains("losse overboeking") == true)
                // Toch de vaste storting kiezen kan: dan wel de verdeling.
                let toch = try DistributionService.proposal(db, distributionId: vast.id!, for: los)
                #expect(!toch.looksSeparate && toch.allocations.map(\.amount) == [c(10_000), c(15_000)])
            }
            // In recognizeAll net zo.
            #expect(try DistributionService.recognizeAll(db, accountId: fx.spaar.id!).values.allSatisfy(\.looksSeparate))
        }
    }

    @Test func kleinVerschilWelVerdeling() throws {
        let fx = try Fixture()
        try fx.app.write { db in
            _ = try vast(db, fx)
            // 240,00 en 300,00: binnen de grens, verdeling met verschil zoals altijd.
            for (cents, verschil): (Int64, Int64) in [(24_000, -1_000), (30_000, 5_000)] {
                let t = try fx.tx(db, fx.spaar, "2027-01-28", cents, iban: Fixture.betaalIban)
                let match = try #require(try DistributionService.recognize(db, bankTransaction: t))
                #expect(!match.looksSeparate && match.difference == c(verschil))
                #expect(match.allocations.map(\.amount) == [c(10_000), c(15_000)])
            }
            let exact = try fx.tx(db, fx.spaar, "2027-01-29", 25_000, iban: Fixture.betaalIban)
            let match = try #require(try DistributionService.recognize(db, bankTransaction: exact))
            #expect(!match.looksSeparate && match.exactAmount && match.warning == nil)
        }
    }

    @Test func herkomstkantBlijftGelijk() throws {
        let fx = try Fixture()
        try fx.app.write { db in
            let vast = try vast(db, fx)
            try DistributionService.link(db, distributionId: vast.id!, budgetItemId: fx.reserveringen.id!)
            let af = try fx.tx(db, fx.betaal, "2027-01-27", -1_895, iban: Fixture.spaarIban)
            let match = try #require(try DistributionService.recognize(db, bankTransaction: af))
            #expect(match.side == .source && !match.looksSeparate)
            #expect(match.allocations.map(\.amount) == [c(-1_895)])
        }
    }

    @Test func waarschuwingVerrekenenBijEigenSpaar() throws {
        let fx = try Fixture()
        try fx.app.write { db in
            let naarSpaar = try fx.tx(db, fx.betaal, "2027-01-27", -1_895, iban: "nl00 test 0000 0000 02")
            let vanSpaar = try fx.tx(db, fx.betaal, "2027-01-27", 5_000, iban: Fixture.spaarIban)
            let winkel = try fx.tx(db, fx.betaal, "2027-01-27", -1_895, iban: "NL00TEST0000000099")
            let zonder = try fx.tx(db, fx.betaal, "2027-01-27", -1_895)
            let spaarkant = try fx.tx(db, fx.spaar, "2027-01-27", 1_895, iban: Fixture.betaalIban)

            let naar = try #require(try SavingsTransferService.ownSavingsWarning(db, bankTransaction: naarSpaar, reimburse: true))
            #expect(naar.contains("naar je eigen spaarrekening") && naar.contains("spaarkant"))
            let van = try #require(try SavingsTransferService.ownSavingsWarning(db, bankTransaction: vanSpaar, reimburse: true))
            #expect(van.contains("van je eigen spaarrekening"))
            // Zonder verrekenen, bij een vreemde of geen tegenrekening, en aan de spaarkant: niets.
            #expect(try SavingsTransferService.ownSavingsWarning(db, bankTransaction: naarSpaar, reimburse: false) == nil)
            for t in [winkel, zonder, spaarkant] {
                #expect(try SavingsTransferService.ownSavingsWarning(db, bankTransaction: t, reimburse: true) == nil)
            }
            // Alleen waarschuwen: boeken met verrekenen blijft mogelijk.
            try BookingService.book(db, bankTransactionId: naarSpaar.id!, allocations: [
                Allocation(amount: c(-1_895), label: "Naar spaar", potId: fx.potVakantie.id, reimburse: true)])
        }
    }
}
