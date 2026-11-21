import Testing
import Foundation
import HFCore
import HFInsight
import HFBackup

/// De rekensom op het dashboard telt ook met de voorbeelddata exact op tot "nog te besteden deze maand",
/// met alle soorten regels (tijdelijk geleend, komt nog terug, open verrekening) waar de voorbeelddata ze heeft.
@Suite struct SpendableBreakdownDemoTests {
    @Test(arguments: ["2027-06-18", "2026-11-21", "2027-01-05"])
    func addsUpWithDemoData(_ iso: String) throws {
        let today = Day(iso: iso)!
        let db = try AppDatabase.inMemory()
        _ = try DemoData.seed(into: db, today: today)
        let dash = try db.read { try Insight.dashboard($0, today: today) }
        let s = try #require(dash.spendable)
        let b = SpendableBreakdown(s)
        #expect(b.addsUp)
        #expect(b.total == s.spendableEndOfMonth)
        #expect(b.lines.last?.kind == .expected)
        #expect(b.lines.last?.amount == b.expectedNet)
    }
}
