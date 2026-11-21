import Foundation
import GRDB
import HFCore
import Testing
@testable import HFBudget

/// Hulpje "Nieuw jaarbedrag" (UX-stap B3): potje, regel in de vaste storting, post en verwachting in één keer.
@Suite struct AnnualAmountTests {
    let f: Fixture
    init() throws { f = try Fixture() }

    private let today = d("2027-03-15")

    /// Vaste storting Verzekering 100 + Vakantie 150, gekoppeld aan RESERVERINGEN (gelijk aan de RES-regels).
    private func reserveDistribution() throws -> Int64 {
        try f.app.write { db in
            let d = try DistributionService.create(db, name: "Maandelijkse reserveringen", accountId: f.spaar.id!,
                                                   sourceAccountId: f.betaal.id!)
            try DistributionService.setLines(db, distributionId: d.id!, [(f.potVerzekering.id!, c(10_000)),
                                                                         (f.potVakantie.id!, c(15_000))])
            try DistributionService.link(db, distributionId: d.id!, budgetItemId: f.reserveringen.id!)
            return d.id!
        }
    }

    private func reserveLineSum(_ db: Database) throws -> Money {
        try Money.fetchOne(db, sql: "SELECT SUM(planAmount) FROM budgetItem WHERE direction = 'RES'") ?? .zero
    }

    @Test func monthlyIsATwelfthRoundedToCents() {
        #expect(AnnualAmountService.monthly(for: c(50_400)) == c(4_200))
        #expect(AnnualAmountService.monthly(for: c(10_000)) == c(833))
        #expect(AnnualAmountService.monthly(for: c(10_006)) == c(834))
        #expect(AnnualAmountService.forecastDay(month: 3, today: today) == d("2027-03-01"))
        #expect(AnnualAmountService.forecastDay(month: 2, today: today) == d("2028-02-01"))
    }

    @Test func newPotInExistingReserveDistribution() throws {
        let distributionId = try reserveDistribution()
        let request = AnnualAmountRequest(name: "Wegenbelasting", yearlyAmount: c(50_400), pot: .new(name: "Wegenbelasting"),
                                          distribution: .existing(distributionId), year: 2027, forecastMonth: 5, today: today)
        let preview = try f.app.read { try AnnualAmountService.preview($0, request) }
        #expect(preview.summary == "Er gaat elke maand € 42,00 naar potje Wegenbelasting via vaste storting Maandelijkse reserveringen; je begroting rekent met € 292,00 op post RESERVERINGEN. Let op: verhoog je overboeking bij de bank naar € 292,00.")
        #expect(preview.potIsNew && !preview.distributionIsNew && !preview.itemIsNew)
        #expect(preview.addsReserveLine)
        #expect(preview.steps.count == 5)
        // Een voorvertoning schrijft niets.
        #expect(try f.app.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM pot WHERE name = 'Wegenbelasting'") } == 0)

        let result = try f.app.write { try AnnualAmountService.apply($0, request) }
        try f.app.read { db in
            let pot = try Pot.fetchOne(db, key: result.potId)!
            #expect(pot.name == "Wegenbelasting" && pot.kind == .reservering && pot.accountId == f.spaar.id)
            #expect(try DistributionService.total(db, distributionId: distributionId) == c(29_200))
            #expect(try BudgetItem.fetchOne(db, key: f.reserveringen.id!)!.planAmount == c(-29_200))
            #expect(result.itemId == f.reserveringen.id)
            // De RES-regels lopen mee, zodat het maandgrid het nieuwe bedrag ook ziet.
            #expect(try reserveLineSum(db) == c(-29_200))
            let forecast = try ForecastItem.fetchOne(db, key: result.forecastItemId!)!
            #expect(forecast.potId == result.potId && forecast.day == d("2027-05-01"))
            #expect(forecast.amount == c(-50_400) && forecast.label == "Wegenbelasting")
        }
    }

    @Test func existingPotGetsExtraOnItsLineAndRESLine() throws {
        let distributionId = try reserveDistribution()
        let request = AnnualAmountRequest(name: "Reisverzekering", yearlyAmount: c(12_000), pot: .existing(f.potVerzekering.id!),
                                          distribution: .existing(distributionId), year: 2027, today: today)
        let preview = try f.app.read { try AnnualAmountService.preview($0, request) }
        #expect(preview.potLineBefore == c(10_000))
        #expect(preview.forecastDay == nil)
        let result = try f.app.write { try AnnualAmountService.apply($0, request) }
        try f.app.read { db in
            let lines = try DistributionService.lines(db, distributionId: distributionId)
            #expect(lines.first { $0.potId == f.potVerzekering.id }?.amount == c(11_000))
            #expect(try BudgetItem.fetchOne(db, key: f.resVerzekering.id!)!.planAmount == c(-11_000))
            #expect(try reserveLineSum(db) == c(-26_000))
            #expect(result.forecastItemId == nil)
        }
    }

    @Test func createsDistributionAndItemWhenNothingExists() throws {
        let request = AnnualAmountRequest(name: "Contributie", yearlyAmount: c(24_000), pot: .new(name: "Contributie"),
                                          distribution: .new(name: "Jaarrekeningen", accountId: f.spaar.id!),
                                          item: .new(label: "Jaarrekeningen"), year: 2027, today: today)
        let preview = try f.app.read { try AnnualAmountService.preview($0, request) }
        #expect(preview.summary == "Er gaat elke maand € 20,00 naar potje Contributie via vaste storting Jaarrekeningen; je begroting rekent met € 20,00 op post Jaarrekeningen. Let op: maak bij de bank een maandelijkse overboeking van € 20,00 van je betaalrekening naar je spaarrekening.")
        #expect(!preview.addsReserveLine)
        let result = try f.app.write { try AnnualAmountService.apply($0, request) }
        try f.app.read { db in
            let distribution = try Distribution.fetchOne(db, key: result.distributionId)!
            #expect(distribution.sourceAccountId == f.betaal.id && distribution.accountId == f.spaar.id)
            let item = try BudgetItem.fetchOne(db, key: result.itemId!)!
            #expect(item.label == "Jaarrekeningen" && item.direction == .UIT)
            #expect(item.distributionId == result.distributionId && item.planAmount == c(-2_000))
            #expect(try reserveLineSum(db) == c(-25_000))   // RES-regels ongemoeid
        }
    }

    @Test func linksAnExistingItem() throws {
        let request = AnnualAmountRequest(name: "Contributie", yearlyAmount: c(24_000), pot: .new(name: "Contributie"),
                                          distribution: .new(name: "Jaarrekeningen", accountId: f.spaar.id!),
                                          item: .existing(f.boodschappen.id!), year: 2027, today: today)
        let result = try f.app.write { try AnnualAmountService.apply($0, request) }
        #expect(result.itemId == f.boodschappen.id)
        #expect(try f.app.read { try BudgetItem.fetchOne($0, key: f.boodschappen.id!)! }.distributionId == result.distributionId)
    }

    @Test func withoutItemOrOpenYearTheBudgetDoesNotCount() throws {
        var request = AnnualAmountRequest(name: "Contributie", yearlyAmount: c(24_000), pot: .new(name: "Contributie"),
                                          distribution: .new(name: "Jaarrekeningen", accountId: f.spaar.id!),
                                          year: 2027, today: today)
        var preview = try f.app.read { try AnnualAmountService.preview($0, request) }
        #expect(preview.itemLabel == nil)
        #expect(preview.summary.contains("je begroting rekent er nog niet mee (er is geen post gekozen)."))
        request.year = 2031
        request.item = .new(label: "Jaarrekeningen")
        preview = try f.app.read { try AnnualAmountService.preview($0, request) }
        #expect(preview.itemNote == "het jaar 2031 bestaat nog niet")
        let result = try f.app.write { try AnnualAmountService.apply($0, request) }
        #expect(result.itemId == nil)
    }

    @Test func refusesWrongChoices() throws {
        let distributionId = try reserveDistribution()
        func preview(_ r: AnnualAmountRequest) throws -> AnnualAmountPreview { try f.app.read { try AnnualAmountService.preview($0, r) } }
        // Een potje dat al bestaat, als nieuw.
        #expect(throws: BudgetError.self) {
            try preview(AnnualAmountRequest(name: "x", yearlyAmount: c(1_200), pot: .new(name: "vakantie"),
                                            distribution: .existing(distributionId), year: 2027, today: today))
        }
        // Geen bedrag.
        #expect(throws: BudgetError.self) {
            try preview(AnnualAmountRequest(name: "x", yearlyAmount: .zero, pot: .new(name: "Nieuw"),
                                            distribution: .existing(distributionId), year: 2027, today: today))
        }
        // Een post die al bij een andere storting hoort.
        let other = try f.app.write { db in
            try DistributionService.create(db, name: "Ander", accountId: f.spaar.id!).id!
        }
        #expect(throws: BudgetError.self) {
            try preview(AnnualAmountRequest(name: "x", yearlyAmount: c(1_200), pot: .new(name: "Nieuw"),
                                            distribution: .existing(other), item: .existing(f.reserveringen.id!),
                                            year: 2027, today: today))
        }
        // Mislukt het, dan blijft alles zoals het was.
        let before = try f.app.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM pot") }
        #expect(throws: BudgetError.self) {
            try f.app.write { try AnnualAmountService.apply($0, AnnualAmountRequest(
                name: "x", yearlyAmount: c(1_200), pot: .new(name: "Nieuw"), distribution: .existing(other),
                item: .existing(f.reserveringen.id!), year: 2027, today: today)) }
        }
        #expect(try f.app.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM pot") } == before)
    }
}
