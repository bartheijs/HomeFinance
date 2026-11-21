import Foundation
import GRDB
import Testing
import HFCore
@testable import HFInsight

// 6h: "n boekingen" bij Instellingen › Tags opent Transacties op de betaalrekening met het filter op de tag.
// Verzonnen testgegevens.
@Suite struct TagUsageTests {
    private struct Setup {
        let app: AppDatabase
        var betaal1: Int64 = 0, betaal2: Int64 = 0, spaar: Int64 = 0, tagA: Int64 = 0, tagB: Int64 = 0
    }

    private func setup() throws -> Setup {
        var s = Setup(app: try AppDatabase.inMemory())
        try s.app.write { db in
            var spaar = Account(name: "Spaar", iban: "NL00TEST0000000002", kind: .spaar, openingDate: d("2027-01-01"),
                                sortOrder: 0)
            try spaar.insert(db)
            var b1 = Account(name: "Betaal 1", iban: "NL00TEST0000000001", kind: .betaal, openingDate: d("2027-01-01"),
                             sortOrder: 1)
            try b1.insert(db)
            var b2 = Account(name: "Betaal 2", iban: "NL00TEST0000000003", kind: .betaal, openingDate: d("2027-01-01"),
                             sortOrder: 2)
            try b2.insert(db)
            var a = Tag(name: "A"); try a.insert(db)
            var b = Tag(name: "B"); try b.insert(db)
            s.betaal1 = b1.id!; s.betaal2 = b2.id!; s.spaar = spaar.id!; s.tagA = a.id!; s.tagB = b.id!
        }
        return s
    }

    private func entry(_ db: Database, _ account: Int64, tag: Int64?) throws {
        var e = Entry(accountId: account, day: d("2027-03-01"), amount: Money(cents: -1_000), label: "Test")
        try e.insert(db)
        if let tag { try EntryTag(entryId: e.id!, tagId: tag).insert(db) }
    }

    @Test func gebruikTeltBetaalEnSpaarApart() throws {
        let s = try setup()
        try s.app.write { db in
            try entry(db, s.betaal1, tag: s.tagA)
            try entry(db, s.betaal2, tag: s.tagA)
            try entry(db, s.spaar, tag: s.tagA)
        }
        let usage = try s.app.read { try Insight.tagUsage($0) }
        #expect(usage[s.tagA] == TagUsage(tagId: s.tagA, onPayment: 2, onSavings: 1))
        #expect(usage[s.tagA]?.total == 3)
        #expect(usage[s.tagB] == nil)
    }

    @Test func filterKiestBetaalrekeningMetDeMeesteBoekingen() throws {
        let s = try setup()
        try s.app.write { db in
            try entry(db, s.betaal2, tag: s.tagA)
            try entry(db, s.betaal2, tag: s.tagA)
            try entry(db, s.betaal1, tag: s.tagA)
            // Ook al staan er meer op spaar: nooit de spaarrekening.
            for _ in 0..<5 { try entry(db, s.spaar, tag: s.tagA) }
        }
        let target = try s.app.read { try Insight.tagFilterTarget($0, tagId: s.tagA) }
        #expect(target == TagFilterTarget(accountId: s.betaal2, tagId: s.tagA))
    }

    @Test func zonderBoekingenOpBetaalDeEersteBetaalrekening() throws {
        let s = try setup()
        try s.app.write { db in try entry(db, s.spaar, tag: s.tagB) }
        let target = try s.app.read { try Insight.tagFilterTarget($0, tagId: s.tagB) }
        #expect(target == TagFilterTarget(accountId: s.betaal1, tagId: s.tagB))
    }

    @Test func zonderBetaalrekeningGeenFilter() throws {
        let app = try AppDatabase.inMemory()
        let tagId = try app.write { db -> Int64 in
            var spaar = Account(name: "Spaar", kind: .spaar, openingDate: d("2027-01-01"))
            try spaar.insert(db)
            var t = Tag(name: "A"); try t.insert(db)
            return t.id!
        }
        #expect(try app.read { try Insight.tagFilterTarget($0, tagId: tagId) } == nil)
    }
}
