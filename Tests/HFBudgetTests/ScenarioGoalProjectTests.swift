import Foundation
import GRDB
import HFCore
import Testing
@testable import HFBudget

@Suite struct ScenarioTests {
    private func item(_ db: Database, _ item: BudgetItem) throws -> BudgetItem {
        try BudgetItem.fetchOne(db, key: item.id!)!
    }

    @Test func watAlsZettenEnWissen() throws {
        let fx = try Fixture()
        try fx.app.write { db in
            #expect(try YearService.setScenario(db, itemId: fx.boodschappen.id!, amount: c(-50_000)).scenarioAmount == c(-50_000))
            #expect(try item(db, fx.boodschappen).planAmount == c(-60_000))
            try YearService.setScenario(db, itemId: fx.salaris.id!, amount: c(320_000))
            // Zelfde tekenregels als het plan; nul mag; niet voor RES-regels.
            #expect(throws: BudgetError.signMismatch(direction: .UIT)) {
                try YearService.setScenario(db, itemId: fx.boodschappen.id!, amount: c(1))
            }
            #expect(throws: BudgetError.signMismatch(direction: .IN)) {
                try YearService.setScenario(db, itemId: fx.salaris.id!, amount: c(-1))
            }
            #expect(throws: BudgetError.self) { try YearService.setScenario(db, itemId: fx.resVakantie.id!, amount: c(-100)) }
            #expect(try item(db, fx.boodschappen).scenarioAmount == c(-50_000))
            #expect(try YearService.setScenario(db, itemId: fx.boodschappen.id!, amount: .zero).scenarioAmount == .zero)

            // Een gewone wijziging van de post laat het wat-als-bedrag staan; een andere richting wist het.
            var edit = try item(db, fx.salaris)
            edit.label = "Loon"; edit.scenarioAmount = nil
            #expect(try YearService.updateItem(db, edit).scenarioAmount == c(320_000))
            edit.direction = .UIT; edit.planAmount = c(-100)
            #expect(try YearService.updateItem(db, edit).scenarioAmount == nil)

            // Een nieuw jaar begint zonder wat-als-bedragen; een nieuwe post ook.
            let y2028 = try YearService.createYear(db, year: 2028, copyingFrom: 2027)
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM budgetItem WHERE yearId = ? AND scenarioAmount IS NOT NULL",
                                     arguments: [y2028.id]) == 0)
            #expect(try YearService.createItem(db, BudgetItem(yearId: fx.year.id!, label: "Nieuw", direction: .UIT,
                                                              planAmount: c(-100), scenarioAmount: c(-50))).scenarioAmount == nil)

            #expect(try YearService.setScenario(db, itemId: fx.boodschappen.id!, amount: nil).scenarioAmount == nil)
            try YearService.setScenario(db, itemId: fx.boodschappen.id!, amount: c(-1))
            #expect(try YearService.clearScenario(db, yearId: fx.year.id!) == 1)
            #expect(try YearService.clearScenario(db, yearId: fx.year.id!) == 0)

            try YearService.closeYear(db, year: 2027)
            #expect(throws: BudgetError.yearClosed(2027)) {
                try YearService.setScenario(db, itemId: fx.boodschappen.id!, amount: c(-1))
            }
            #expect(throws: BudgetError.yearClosed(2027)) { try YearService.clearScenario(db, yearId: fx.year.id!) }
            #expect(throws: BudgetError.yearClosed(2027)) { try YearService.applyScenario(db, yearId: fx.year.id!) }
        }
    }

    @Test func watAlsToepassen() throws {
        let fx = try Fixture()
        try fx.app.write { db in
            let vast = try DistributionService.create(db, name: "Vast sparen", accountId: fx.spaar.id!)
            try DistributionService.setLines(db, distributionId: vast.id!, [(fx.potVakantie.id!, c(15_000))])
            let sparen = try YearService.createItem(db, BudgetItem(yearId: fx.year.id!, label: "Sparen", direction: .UIT,
                                                                   planAmount: .zero, distributionId: vast.id))
            #expect(sparen.planAmount == c(-15_000))

            try YearService.setScenario(db, itemId: fx.salaris.id!, amount: c(320_000))
            try YearService.setScenario(db, itemId: fx.boodschappen.id!, amount: c(-55_000))
            // Een gekoppelde post en de regel RESERVERINGEN mogen een wat-als-bedrag hebben, maar hun plan is berekend.
            #expect(try YearService.setScenario(db, itemId: sparen.id!, amount: c(-20_000)).planAmount == c(-15_000))
            try YearService.setScenario(db, itemId: fx.reserveringen.id!, amount: c(-30_000))

            let result = try YearService.applyScenario(db, yearId: fx.year.id!)
            #expect(result.appliedCount == 2)
            #expect(result.skipped.map(\.id) == [fx.reserveringen.id, sparen.id])
            #expect(result.skipped.map(\.scenarioAmount) == [c(-30_000), c(-20_000)])
            #expect(try item(db, fx.salaris).planAmount == c(320_000))
            #expect(try item(db, fx.boodschappen).planAmount == c(-55_000))
            #expect(try item(db, sparen).planAmount == c(-15_000))
            #expect(try item(db, fx.reserveringen).planAmount == c(-25_000))
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM budgetItem WHERE scenarioAmount IS NOT NULL") == 0)

            // Niets ingevuld: niets te doen.
            #expect(try YearService.applyScenario(db, yearId: fx.year.id!) == ScenarioApplyResult(appliedCount: 0, skipped: []))
        }
    }
}

@Suite struct GoalPartTests {
    @Test func spaardoelUitOnderdelen() throws {
        let fx = try Fixture()
        try fx.app.write { db in
            let potId = fx.potSpaar.id!
            func target() throws -> Money? { try Pot.fetchOne(db, key: potId)!.targetAmount }
            // Eén los bedrag invullen kan gewoon.
            var pot = fx.potSpaar
            pot.targetAmount = c(100_000)
            try PotService.update(db, pot)
            #expect(try PotService.goalParts(db, potId: potId).isEmpty)

            // 40 × 65,00 + 1 × 120,00 + 2 × 0,00 = 2.720,00
            let parts = try PotService.setGoalParts(db, potId: potId, [
                GoalPart(potId: 0, label: " Lessen ", quantity: 40, unitAmount: c(6_500)),
                GoalPart(potId: 0, label: "", unitAmount: c(12_000)),
                GoalPart(potId: 0, label: "Gratis", quantity: 2, unitAmount: .zero),
            ])
            #expect(parts.map(\.label) == ["Lessen", "", "Gratis"])
            #expect(parts.map(\.amount) == [c(260_000), c(12_000), .zero])
            #expect(parts.allSatisfy { $0.potId == potId } && parts.map(\.sortOrder) == [0, 1, 2])
            #expect(try target() == c(272_000))

            #expect(throws: BudgetError.self) {
                try PotService.setGoalParts(db, potId: potId, [GoalPart(potId: potId, label: "x", quantity: 0, unitAmount: c(1))])
            }
            #expect(throws: BudgetError.self) {
                try PotService.setGoalParts(db, potId: potId, [GoalPart(potId: potId, label: "x", unitAmount: c(-1))])
            }
            #expect(try PotService.goalParts(db, potId: potId).count == 3)

            // Met onderdelen wordt een zelf ingevuld doel overschreven; de rest van de wijziging gaat door.
            pot.targetAmount = c(5); pot.name = "Rijbewijs"; pot.targetDate = d("2028-06-01")
            let saved = try PotService.update(db, pot)
            #expect(saved.targetAmount == c(272_000) && saved.name == "Rijbewijs" && saved.targetDate == d("2028-06-01"))

            // Vervangen: 10 × 65,00 = 650,00. Leegmaken laat het doel staan en maakt het weer vrij.
            try PotService.setGoalParts(db, potId: potId, [GoalPart(potId: potId, label: "Lessen", quantity: 10, unitAmount: c(6_500))])
            #expect(try target() == c(65_000))
            #expect(try PotService.setGoalParts(db, potId: potId, []).isEmpty)
            #expect(try target() == c(65_000))
            pot.targetAmount = nil
            #expect(try PotService.update(db, pot).targetAmount == nil)
            #expect(throws: BudgetError.notFound(what: "Potje", id: 999)) { try PotService.setGoalParts(db, potId: 999, []) }
        }
    }
}

@Suite struct ForecastProjectTests {
    @Test func projectBijEenVerwachting() throws {
        let fx = try Fixture()
        try fx.app.write { db in
            let potId = fx.potSpaar.id!
            let a = try ForecastService.create(db, potId: potId, day: d("2027-07-01"), amount: c(-80_000),
                                               label: "Huisje", project: "  Zomer 2027 ")
            let b = try ForecastService.create(db, potId: potId, day: d("2027-07-10"), amount: c(-20_000),
                                               label: "Reis", project: "Zomer 2027")
            let cc = try ForecastService.create(db, potId: potId, day: d("2027-12-01"), amount: c(-10_000), project: "winter")
            let los = try ForecastService.create(db, potId: potId, day: d("2027-05-01"), amount: c(50_000), label: "Gift")
            try ForecastService.create(db, potId: fx.potVerzekering.id!, day: d("2027-07-01"), amount: c(-1_000),
                                       project: "Zomer 2027")
            #expect(a.project == "Zomer 2027" && los.project == "")
            try ForecastService.markRealized(db, forecastItemId: b.id!)
            #expect(try ForecastService.projects(db, potId: potId) == ["winter", "Zomer 2027"])

            var edit = cc
            edit.project = " Winter 2027 "
            #expect(try ForecastService.update(db, edit).project == "Winter 2027")
            edit.project = "   "
            #expect(try ForecastService.update(db, edit).project == "")
            #expect(try ForecastService.projects(db, potId: potId) == ["Zomer 2027"])

            // Hernoemen raakt alleen deze pot, ook de uitgekomen verwachting.
            #expect(try ForecastService.renameProject(db, potId: potId, from: " Zomer 2027", to: "Vakantie ") == 2)
            #expect(try ForecastService.renameProject(db, potId: potId, from: "Zomer 2027", to: "Vakantie") == 0)
            #expect(try ForecastService.renameProject(db, potId: potId, from: "Vakantie", to: "Vakantie") == 0)
            #expect(try ForecastService.projects(db, potId: potId) == ["Vakantie"])
            #expect(try ForecastService.projects(db, potId: fx.potVerzekering.id!) == ["Zomer 2027"])
            #expect(try ForecastItem.fetchOne(db, key: b.id!)!.project == "Vakantie")
            #expect(throws: BudgetError.self) { try ForecastService.renameProject(db, potId: potId, from: " ", to: "x") }
            // Een lege doelnaam haalt de verwachtingen uit het project.
            #expect(try ForecastService.renameProject(db, potId: potId, from: "Vakantie", to: "") == 2)
            #expect(try ForecastService.projects(db, potId: potId).isEmpty)
        }
    }
}
