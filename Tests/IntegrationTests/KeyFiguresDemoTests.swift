import Testing
import Foundation
import GRDB
import HFCore
import HFInsight
import HFBackup

/// Kerncijfers op de voorbeelddata: dezelfde gegevens geven exact hetzelfde JSON, en de getallen komen overeen
/// met wat de schermen tonen.
@Suite struct KeyFiguresDemoTests {
    let today = Day(iso: "2027-06-18")!

    private func seeded() throws -> AppDatabase {
        let db = try AppDatabase.inMemory()
        _ = try DemoData.seed(into: db, today: today)
        return db
    }

    @Test func sameDataGivesSameJSON() throws {
        let a = try seeded().read { try Insight.keyFigures($0, today: today).json() }
        let b = try seeded().read { try Insight.keyFigures($0, today: today).json() }
        #expect(a == b)
    }

    @Test func figuresMatchTheScreens() throws {
        let db = try seeded()
        let v = try db.read { try Insight.keyFigures($0, today: today).values }
        let (accounts, pots, entries, newCount) = try db.read { db in
            (try Insight.accountOverview(db, today: today),
             try Insight.potOverview(db, today: today).accounts.flatMap(\.pots),
             try Entry.fetchCount(db),
             try BankTransaction.filter(Column("status") == "nieuw").fetchCount(db))
        }
        #expect(!accounts.isEmpty)
        #expect(!pots.isEmpty)
        #expect(v.keys.filter { $0.hasPrefix("rekening.") && $0.hasSuffix(".saldo") }.count == accounts.count)
        #expect(v.keys.filter { $0.hasPrefix("pot.") && $0.hasSuffix(".saldo") }.count == pots.count)
        #expect(v["boekingen.aantal"] == String(entries))
        #expect(v["banktransacties.nieuw"] == String(newCount))
        #expect(v["besteedbaarNu"]?.first?.isNumber == true || v["besteedbaarNu"]?.first == "-")
        #expect(v["nogTeBestedenDezeMaand"] != "geen begrotingsjaar")
    }
}
