import Foundation
import GRDB
import HFCore
import Testing
@testable import HFInsight

/// UX-feedback punt 5: zonder de knop "Het is binnen…" tagt de gebruiker de terugbetaling gewoon met de tag.
/// Volgens de bestaande rekenregel (openstaand = startbedrag zolang niet verrekend − som van de boekingen met
/// de tag zonder verrekening op een betaalrekening) wordt het openstaande bedrag dan € 0,00, ook met een
/// startbedrag en naast een bestaande verrekening.
///
///   startbedrag Tanken € 20,00 (open)
///   15-01-2027  Tanken −60 → bestaande verrekening van 1-2-2027 met storting +60 (zonder tag)
///   20-02-2027  Tanken −55   open
///   05-03-2027  Retour tankpas +10 (tag)  open
///   14-03-2027  Tanken −45   open
///   openstaand = 20 − (−55 + 10 − 45) = € 110,00
@Suite struct RepaymentByTagTests {
    let f: Fixture
    let today = Fixture.today
    /// Eigen tag "Werkreizen", zodat de boekingen van de fixture niet meetellen.
    let tag: Int64

    init() throws {
        f = try Fixture()
        tag = try f.db.write { db in
            var t = Tag(name: "Werkreizen", color: "#445566", sortOrder: 9, settles: true)
            try t.insert(db)
            return t.id!
        }
        try f.db.write { [f, tag] db in
            try db.execute(sql: """
                UPDATE tag SET countsInSpendable = 1, startAmount = ?, startDay = ? WHERE id = ?
                """, arguments: [eur(20), d("2027-01-01"), tag])
            let first = try Self.entry(db, f.betaal, "2027-01-15", -60, "Tanken", tag: tag)
            let deposit = try Self.entry(db, f.betaal, "2027-02-01", 60, "Storting tanken")
            var s = Settlement(tagId: tag, day: d("2027-02-01"), amount: eur(60), depositEntryId: deposit)
            try s.insert(db)
            try db.execute(sql: "UPDATE entry SET settlementId = ? WHERE id = ?", arguments: [s.id!, first])
            _ = try Self.entry(db, f.betaal, "2027-02-20", -55, "Tanken", tag: tag)
            _ = try Self.entry(db, f.betaal, "2027-03-05", 10, "Retour tankpas", tag: tag)
            _ = try Self.entry(db, f.betaal, "2027-03-14", -45, "Tanken", tag: tag)
        }
    }

    @discardableResult
    static func entry(_ db: Database, _ account: Int64, _ day: String, _ amount: Int64, _ label: String,
                      tag: Int64? = nil) throws -> Int64 {
        var e = Entry(accountId: account, day: d(day), amount: eur(amount), label: label)
        try e.insert(db)
        if let tag { try EntryTag(entryId: e.id!, tagId: tag).insert(db) }
        return e.id!
    }

    private func outstanding() throws -> Money {
        try f.db.read { try Insight.settlementOverview($0, today: today) }.first { $0.id == tag }!.outstanding
    }

    @Test func taggedRepaymentBringsOutstandingToZero() throws {
        #expect(try outstanding() == eur(110))
        let before = try f.db.read { try Insight.spendable($0, year: 2027, today: today) }
        #expect(before.returningTags.first { $0.id == tag }?.amount == eur(110))

        // De terugbetaling komt binnen zonder tag: nog steeds € 110,00 open (en het geld telt dubbel mee).
        let repayment = try f.db.write { db in try Self.entry(db, f.betaal, "2027-03-15", 110, "Terugbetaling werkgever") }
        #expect(try outstanding() == eur(110))

        // De gebruiker tagt haar met Tanken: openstaand € 0,00.
        try f.db.write { db in try EntryTag(entryId: repayment, tagId: tag).insert(db) }
        #expect(try outstanding() == .zero)
        let after = try f.db.read { try Insight.spendable($0, year: 2027, today: today) }
        #expect(after.returningTags.first { $0.id == tag } == nil)
        // Nog te besteden: het geld staat nu op de rekening en telt niet meer als "komt nog terug".
        #expect(after.spendableEndOfMonth == before.spendableEndOfMonth)
        // Geen aandachtspunt meer voor deze tag.
        let dash = try f.db.read { try Insight.dashboard($0, today: today) }
        #expect(!dash.attention.contains { if case .openSettlement(let id, _, _, _) = $0 { return id == tag }; return false })
    }

    @Test func partialRepaymentLowersTheOutstandingAmount() throws {
        try f.db.write { db in try Self.entry(db, f.betaal, "2027-03-15", 50, "Deel terug", tag: tag) }
        #expect(try outstanding() == eur(60))
    }

    @Test func settledStartAmountNoLongerCounts() throws {
        // Is het startbedrag al in een verrekening meegenomen, dan telt het niet meer; € 90,00 terug is genoeg.
        try f.db.write { db in
            let s = try Int64.fetchOne(db, sql: "SELECT id FROM settlement WHERE tagId = ?", arguments: [tag])!
            try db.execute(sql: "UPDATE tag SET startSettlementId = ? WHERE id = ?", arguments: [s, tag])
            try Self.entry(db, f.betaal, "2027-03-15", 90, "Terugbetaling", tag: tag)
        }
        #expect(try outstanding() == .zero)
    }
}
