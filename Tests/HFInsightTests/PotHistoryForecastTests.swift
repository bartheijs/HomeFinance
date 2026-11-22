import Foundation
import GRDB
import HFCore
import Testing
@testable import HFInsight

/// Vooruitblik met eerdere uitgaven (wens gebruiker 22-11-2026). Potje "Tandarts" op de spaarrekening, peildag
/// 15 maart 2027:
///   10-12-2026  +1000 (start)
///   10-01-2027  −120
///   10-02-2027  −60
///   20-02-2027  −300  eenmalig (telt niet mee in het gemiddelde)
///   05-03-2027  −40   lopende maand (telt niet mee)
/// Gemiddelde over dec–feb (3 maanden): −180 / 3 = −60 per maand. Saldo nu 480.
@Suite struct PotHistoryForecastTests {
    let f: Fixture
    let pot: Int64
    let today = d("2027-03-15")

    init() throws {
        f = try Fixture()
        pot = try f.db.write { [f] db in
            var p = Pot(accountId: f.spaar, name: "Tandarts", kind: .reservering, monthlyAmount: .zero, sortOrder: 9)
            try p.insert(db)
            for (day, amount, oneOff) in [("2026-12-10", 1000, false), ("2027-01-10", -120, false),
                                          ("2027-02-10", -60, false), ("2027-02-20", -300, true),
                                          ("2027-03-05", -40, false)] {
                var e = Entry(accountId: f.spaar, day: d(day), amount: eur(Int64(amount)), label: "Tandarts", potId: p.id)
                e.forecastOneOff = oneOff
                try e.insert(db)
            }
            return p.id!
        }
    }

    private func forecast() throws -> PotForecast {
        try f.db.read { try Insight.potForecast($0, potId: pot, today: today, until: d("2027-12-31")) }
    }

    private func flag(_ on: Bool) throws {
        try f.db.write { try $0.execute(sql: "UPDATE pot SET forecastFromHistory = ? WHERE id = ?", arguments: [on, pot]) }
    }

    @Test func offByDefaultButShowsTheAverage() throws {
        let fc = try forecast()
        #expect(!fc.usesHistory)
        #expect(fc.historyAverage == PotHistoryAverage(perMonth: eur(-60), months: 3))
        #expect(!fc.events.contains { $0.kind == .historyAverage })
        #expect(fc.endBalance == eur(480))
    }

    @Test func onAddsTheAverageEveryMonth() throws {
        try flag(true)
        let fc = try forecast()
        let averages = fc.events.filter { $0.kind == .historyAverage }
        // April t/m december: 9 keer −60 op de 15e.
        #expect(averages.count == 9)
        #expect(averages.first?.day == d("2027-04-15"))
        #expect(averages.allSatisfy { $0.amount == eur(-60) })
        #expect(fc.endBalance == eur(480 - 540))
        // Binnen een jaar onder nul: melding op het dashboard.
        let dash = try f.db.read { try Insight.dashboard($0, today: today) }
        #expect(dash.attention.contains(.potsRunningOut(names: ["Tandarts"])))
    }

    @Test func realizedExpectationsDoNotCountTwice() throws {
        // De −60 van februari is een uitgekomen verwachting (bv. het abonnement): die staat al als verwachting.
        try f.db.write { db in
            let entry = try Int64.fetchOne(db, sql: "SELECT id FROM entry WHERE potId = ? AND day = '2027-02-10'", arguments: [pot])!
            var item = ForecastItem(potId: pot, day: d("2027-02-10"), amount: eur(-60), label: "Abonnement")
            item.realizedEntryId = entry
            item.realizedAt = Date()
            try item.insert(db)
        }
        #expect(try forecast().historyAverage == PotHistoryAverage(perMonth: eur(-40), months: 3))
    }
}
