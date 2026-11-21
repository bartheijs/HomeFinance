import Foundation
import GRDB
import HFCore
import Testing
@testable import HFInsight

/// De opbouw van RESERVERINGEN uit de gekoppelde vaste storting (UX-stap B1). Alleen weergave: het plan in het
/// maandgrid blijft de som van de RES-regels.
@Suite struct ReserveBuildupTests {
    let f: Fixture
    init() throws { f = try Fixture() }

    /// Een vaste storting Auto 100 + Vakantie 150 (gelijk aan de RES-regels van de fixture), optioneel gekoppeld.
    @discardableResult
    private func addDistribution(auto: Int64 = 100, vakantie: Int64 = 150, link: Bool = true) throws -> Int64 {
        try f.db.write { db in
            var d = Distribution(name: "Maandelijkse storting", accountId: f.spaar, sortOrder: 1, sourceAccountId: f.betaal)
            try d.insert(db)
            var l1 = DistributionLine(distributionId: d.id!, potId: f.potAuto, amount: eur(auto), sortOrder: 1)
            try l1.insert(db)
            var l2 = DistributionLine(distributionId: d.id!, potId: f.potVakantie, amount: eur(vakantie), sortOrder: 2)
            try l2.insert(db)
            if link {
                try db.execute(sql: "UPDATE budgetItem SET distributionId = ? WHERE id = ?", arguments: [d.id, f.reserveringen])
            }
            return d.id!
        }
    }

    private func buildup() throws -> ReserveBuildup {
        try #require(try f.db.read { try Insight.reserveBuildup($0, year: 2027) })
    }

    @Test func withoutDistributionTheBuildupComesFromTheReserveLines() throws {
        let b = try buildup()
        #expect(b.distribution == nil)
        #expect(b.lines.isEmpty)
        #expect(b.reserveLineTotal == eur(250))
        #expect(b.reserveLineCount == 2)
        #expect(!b.isOutOfStep)
        #expect(b.warning == nil)
        #expect(b.reserveLinesNote == nil)
        #expect(b.sentence == "RESERVERINGEN is nog niet aan een vaste overboeking gekoppeld. De opbouw komt uit de RES-regels hieronder.")
    }

    @Test func linkedDistributionIsTheBuildup() throws {
        try addDistribution()
        let b = try buildup()
        #expect(b.distribution?.name == "Maandelijkse storting")
        #expect(b.lines.map(\.potName) == ["Auto", "Vakantie"])
        #expect(b.distributionTotal == eur(250))
        #expect(!b.isOutOfStep)
        #expect(b.warning == nil)
        #expect(b.sentence == "De opbouw komt uit Automatisch sparen: Maandelijkse storting (2 potjes, € 250,00 per maand). Je wijzigt de verdeling bij Automatisch sparen.")
        #expect(b.reserveLinesNote != nil)
        // Rijen voor het maandgrid: informatief, met negatieve id's.
        #expect(b.gridRows.map(\.label) == ["Auto", "Vakantie"])
        #expect(b.gridRows.allSatisfy { $0.id < 0 && $0.kind == .reserveLine && $0.isInformational })
        #expect(b.gridRows.map(\.plan) == [eur(-100), eur(-150)])
    }

    @Test func reserveLinesAndDistributionOutOfStepGiveAWarning() throws {
        try addDistribution(vakantie: 192)
        let b = try buildup()
        #expect(b.isOutOfStep)
        #expect(b.warning == "Let op: de RES-regels tellen op tot € 250,00 per maand, Automatisch sparen: Maandelijkse storting tot € 292,00. Het maandgrid en \"nog te besteden deze maand\" rekenen RESERVERINGEN nog met de RES-regels. Maak de RES-regels gelijk aan de overboeking om het verschil weg te werken.")
    }

    /// De bevinding van B1, vastgelegd: het plan van RESERVERINGEN in het maandgrid is de som van de RES-regels,
    /// ook als er een vaste storting met een ander totaal aan gekoppeld is. Deze stap verandert dat niet.
    @Test func gridPlanStillFollowsTheReserveLines() throws {
        try addDistribution(vakantie: 192)
        let grid = try f.db.read { try Insight.monthGrid($0, year: 2027, today: Fixture.today) }
        let total = try #require(grid.rows.first { $0.kind == .reserveTotal })
        #expect(total.plan == eur(-250))
    }

    @Test func noReserveTotalGivesNoBuildup() throws {
        try f.db.write { try $0.execute(sql: "DELETE FROM budgetItem WHERE isReserveTotal = 1") }
        #expect(try f.db.read { try Insight.reserveBuildup($0, year: 2027) } == nil)
        #expect(try f.db.read { try Insight.reserveBuildup($0, year: 2030) } == nil)
    }
}
