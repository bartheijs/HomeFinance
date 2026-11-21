import Foundation
import GRDB
import HFCore
import Testing
@testable import HFInsight

/// De extra aandachtspunten op het dashboard (UX-feedback): buffer niet gehaald, spaardoel niet op koers,
/// saldo na import sluit niet aan, grote uitgave op komst; en de kaartjes.
@Suite struct DashboardAttentionTests {
    let f: Fixture
    init() throws { f = try Fixture() }

    private func dashboard(_ day: String = "2027-03-15") throws -> Dashboard {
        try f.db.read { try Insight.dashboard($0, today: d(day)) }
    }

    @Test func bufferNotReachedWhenSpendableIsNegative() throws {
        try f.db.write { try $0.execute(sql: "UPDATE budgetYear SET antiRood = ?", arguments: [eur(10_000)]) }
        let dash = try dashboard()
        let end = try #require(dash.spendable).spendableEndOfMonth
        #expect(end.isNegative)
        #expect(dash.attention.contains(.bufferNotReached(shortfall: end.magnitude)))
        #expect(AttentionItem.bufferNotReached(shortfall: eur(12)).message
                == "Het minimum op je betaalrekening haal je deze maand niet: € 12,00 tekort.")
    }

    @Test func potGoalBehind() throws {
        try f.db.write {
            try $0.execute(sql: "UPDATE pot SET targetAmount = ?, targetDate = ? WHERE id = ?",
                           arguments: [eur(100_000), d("2027-04-30"), f.potAuto])
        }
        #expect(try dashboard().attention.contains(.potGoalsBehind(names: ["Auto"])))
        #expect(AttentionItem.potGoalsBehind(names: ["Auto"]).message == "Spaardoel niet op koers: Auto.")
    }

    @Test func importBalanceDiffersOnlyWhenNothingWaits() throws {
        // Met wachtende banktransacties geen melding: die is dan nog niet compleet.
        #expect(!(try dashboard()).attention.contains { if case .importBalanceDiffers = $0 { return true }; return false })
        try f.db.write { try $0.execute(sql: "UPDATE bankTransaction SET status = 'overgeslagen' WHERE status = 'nieuw'") }
        let found = try dashboard().attention.first { if case .importBalanceDiffers = $0 { return true }; return false }
        guard case .importBalanceDiffers(let id, _, let bank, let app, let day)? = found else {
            Issue.record("geen melding over het saldo na de import"); return
        }
        #expect(id == f.betaal)
        #expect(bank == eur(3482, 50))
        #expect(day == d("2027-03-14"))
        #expect(app != bank)
    }

    @Test func largeExpenseComingForNonMonthlyItem() throws {
        // Verzekering: per kwartaal, −300, rond de 10e; op 5 april nog niet geboekt.
        let dash = try dashboard("2027-04-05")
        #expect(dash.attention.contains(.largeExpenseComing(itemId: f.verzekering, label: "Verzekering",
                                                            amount: eur(300), expectedDay: 10)))
        // Huur (−1200) komt elke maand: geen melding.
        #expect(!dash.attention.contains { if case .largeExpenseComing(let id, _, _, _) = $0 { return id == f.huur }; return false })
        #expect(AttentionItem.largeExpenseComing(itemId: 1, label: "Verzekering", amount: eur(300), expectedDay: 10).message
                == "Grote uitgave op komst: Verzekering € 300,00, rond de 10e.")
    }

    @Test func cardsFigures() throws {
        let dash = try dashboard()
        #expect(dash.checkingTotal + dash.savingsTotal == dash.accountsTotal)
        #expect(dash.checkingTotal == eur(3540))
        let fixed = try #require(dash.fixedItems)
        #expect(fixed.incomeExpected + fixed.expensesExpected == fixed.expectedNet)
        #expect(fixed.expectedNet == fixed.outstandingTotal)
        let incidental = dash.incidental
        #expect(incidental.net == incidental.income + incidental.expenses)
        #expect(incidental.largestExpenses.count <= 3)
        #expect(incidental.largestExpenses.allSatisfy { $0.isDivers && $0.amount < .zero })
    }
}
