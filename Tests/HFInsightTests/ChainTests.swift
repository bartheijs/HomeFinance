import Foundation
import GRDB
import HFCore
import Testing
@testable import HFInsight

/// De keten post ↔ vaste storting ↔ potje (UX-stap B2): de zinnen bij een potje, een storting en een post.
@Suite struct ChainTests {
    let f: Fixture
    init() throws { f = try Fixture() }

    @discardableResult
    private func distribution(_ name: String, order: Int, lines: [(Int64, Int64)], item: Int64? = nil,
                              archived: Bool = false) throws -> Int64 {
        try f.db.write { db in
            var d = Distribution(name: name, accountId: f.spaar, sortOrder: order, archived: archived, sourceAccountId: f.betaal)
            try d.insert(db)
            for (index, line) in lines.enumerated() {
                var l = DistributionLine(distributionId: d.id!, potId: line.0, amount: eur(line.1), sortOrder: index + 1)
                try l.insert(db)
            }
            if let item {
                try db.execute(sql: "UPDATE budgetItem SET distributionId = ? WHERE id = ?", arguments: [d.id, item])
            }
            return d.id!
        }
    }

    private func chain() throws -> ChainOverview { try f.db.read { try Insight.chain($0, year: 2027) } }

    @Test func oneDistributionWithItem() throws {
        let id = try distribution("Maandelijkse reserveringen", order: 1,
                                  lines: [(f.potAuto, 100), (f.potVakantie, 150)], item: f.reserveringen)
        let c = try chain()
        #expect(c.pot(f.potAuto).sentence == "Krijgt € 100,00 per maand via Automatisch sparen: Maandelijkse reserveringen (post RESERVERINGEN).")
        #expect(c.pot(f.potAuto).monthly == eur(100))
        #expect(c.item(f.reserveringen).sentence == "Gaat via Automatisch sparen: Maandelijkse reserveringen naar 2 potjes.")
        #expect(c.item(f.reserveringen).distribution?.id == id)
        #expect(c.distribution(id)?.sentence == "Telt in je begroting als: post RESERVERINGEN.")
    }

    @Test func distributionWithoutItemAndPotWithoutDistribution() throws {
        let id = try distribution("Extra spaar", order: 1, lines: [(f.potKind, 25)])
        let c = try chain()
        #expect(c.pot(f.potKind).sentence == "Krijgt € 25,00 per maand via Automatisch sparen: Extra spaar (nog niet gekoppeld aan een post).")
        #expect(c.distribution(id)?.sentence == "Telt nog niet in je begroting van 2027: kies hieronder een post.")
        #expect(c.pot(f.potAuto).sentence == "Krijgt geen geld via een vaste overboeking.")
        #expect(c.item(f.huur).sentence == nil)
    }

    @Test func singlePotNamesThePot() throws {
        try distribution("Extra spaar", order: 1, lines: [(f.potKind, 25)], item: f.lening)
        #expect(try chain().item(f.lening).sentence == "Gaat via Automatisch sparen: Extra spaar naar 1 potje (Spaarpot Kind A).")
    }

    @Test func potInTwoDistributionsGivesAList() throws {
        try distribution("Maandelijkse reserveringen", order: 1, lines: [(f.potAuto, 100)], item: f.reserveringen)
        try distribution("Extra", order: 2, lines: [(f.potAuto, 20)])
        try distribution("Oud", order: 3, lines: [(f.potAuto, 999)], archived: true)
        let pot = try chain().pot(f.potAuto)
        #expect(pot.lines.count == 2)
        #expect(pot.sentence == "Krijgt € 120,00 per maand via 2 vaste overboekingen:")
        #expect(pot.lines.map(\.line) == ["€ 100,00 via Maandelijkse reserveringen (post RESERVERINGEN)",
                                          "€ 20,00 via Extra (nog niet gekoppeld aan een post)"])
    }

    @Test func distributionLinkedToTwoItems() throws {
        let id = try distribution("Extra spaar", order: 1, lines: [(f.potKind, 25)], item: f.lening)
        try f.db.write { try $0.execute(sql: "UPDATE budgetItem SET distributionId = ? WHERE id = ?", arguments: [id, f.energie]) }
        #expect(try chain().distribution(id)?.sentence == "Telt in je begroting als: post Energie en post Lening.")
    }

    @Test func otherYearHasNoItems() throws {
        let id = try distribution("Maandelijkse reserveringen", order: 1, lines: [(f.potAuto, 100)], item: f.reserveringen)
        let c = try f.db.read { try Insight.chain($0, year: 2028) }
        #expect(c.distribution(id)?.distribution.items.isEmpty == true)
        #expect(c.pot(f.potAuto).sentence == "Krijgt € 100,00 per maand via Automatisch sparen: Maandelijkse reserveringen (nog niet gekoppeld aan een post).")
    }
}
