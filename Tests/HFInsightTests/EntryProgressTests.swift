import Foundation
import GRDB
import HFCore
import Testing
@testable import HFInsight

/// Het potlabel in de lijst en de voortgangsregel bij een boeking (UX-stap A3).
@Suite struct EntryProgressTests {
    let f: Fixture
    init() throws { f = try Fixture() }

    private func entryId(_ label: String) throws -> Int64 {
        try f.db.read { try Int64.fetchOne($0, sql: "SELECT id FROM entry WHERE label = ? ORDER BY id LIMIT 1", arguments: [label])! }
    }

    private func progress(_ label: String) throws -> EntryProgress? {
        let id = try entryId(label)
        return try f.db.read { try Insight.entryProgress($0, entryId: id, today: Fixture.today) }
    }

    @Test func openReimbursementShowsTheNetAmountToTransfer() throws {
        // Uit eten −75 (pot Vakantie) en Tandarts −120 staan open: samen € 195 van spaar naar betaal.
        let p = try #require(try progress("Uit eten"))
        #expect(p.kind == .toTransfer(potName: "Vakantie", direction: .fromSavings, inPendingTransfer: false))
        #expect(p.amount == eur(195))
        #expect(p.line == "Nog over te boeken: € 195,00 van spaar naar betaal")
    }

    @Test func entryWithoutAnythingOpenHasNoProgress() throws {
        #expect(try progress("Huur") == nil)
        #expect(try progress("Storting Auto") == nil)
    }

    @Test func advancedTagShowsWhatIsStillToCome() throws {
        try f.db.write { try $0.execute(sql: "UPDATE tag SET settles = 1 WHERE id = ?", arguments: [f.tagTanken]) }
        let p = try #require(try progress("Tanken"))
        #expect(p.kind == .toReceive(tagId: f.tagTanken, tagName: "tanken"))
        #expect(p.amount == eur(115))
        #expect(p.line == "Nog terug te krijgen: € 115,00 (tanken)")
    }

    @Test func linkLabels() {
        #expect(Insight.linkLabels(amount: eur(-75), reimburse: true, potName: "Vakantie", settlingTagNames: []) == ["uit potje Vakantie"])
        #expect(Insight.linkLabels(amount: eur(20), reimburse: true, potName: nil, settlingTagNames: []) == ["naar spaar"])
        #expect(Insight.linkLabels(amount: eur(-60), reimburse: false, potName: nil, settlingTagNames: ["Tanken"]) == ["voorgeschoten (Tanken)"])
        #expect(Insight.linkLabels(amount: eur(144), reimburse: false, potName: nil, settlingTagNames: ["Tanken"]).isEmpty)
        #expect(Insight.linkLabels(amount: eur(-10), reimburse: false, potName: nil, settlingTagNames: []).isEmpty)
    }
}
