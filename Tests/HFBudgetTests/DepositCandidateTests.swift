import Foundation
import GRDB
import HFCore
import Testing
@testable import HFBudget

/// "Is dit je geld van Tanken terug?" bij een wachtende bijschrijving (UX-stap D2).
@Suite struct DepositCandidateTests {
    private func setup(_ db: Database, _ fx: Fixture) throws -> HFCore.Tag {
        let tag = try TagService.create(db, name: "Tanken")
        _ = try SettlementService.enable(db, tagId: tag.id!, from: d("2027-01-01"))
        for (day, cents) in [("2027-02-03", Int64(-6_000)), ("2027-02-17", -4_442)] {
            try EntryService.create(db, EntryDraft(accountId: fx.betaal.id!, day: d(day), amount: c(cents),
                                                   label: "Tank", tagIds: [tag.id!]))
        }
        return tag
    }

    @Test func exactAndNearAmountsAreCandidates() throws {
        let fx = try Fixture()
        try fx.app.write { db in
            let tag = try setup(db, fx)
            let exact = try fx.tx(db, fx.betaal, "2027-03-01", 10_442)
            let near = try fx.tx(db, fx.betaal, "2027-03-01", 10_400)
            let far = try fx.tx(db, fx.betaal, "2027-03-01", 10_000)
            let expense = try fx.tx(db, fx.betaal, "2027-03-01", -10_442)
            let savings = try fx.tx(db, fx.spaar, "2027-03-01", 10_442)
            let found = try SettlementService.depositCandidates(db, bankTransaction: exact)
            #expect(found == [.init(tagId: tag.id!, tagName: "Tanken", outstanding: c(10_442), exact: true)])
            #expect(try SettlementService.depositCandidates(db, bankTransaction: near).first?.exact == false)
            #expect(try SettlementService.depositCandidates(db, bankTransaction: far).isEmpty)
            #expect(try SettlementService.depositCandidates(db, bankTransaction: expense).isEmpty)
            #expect(try SettlementService.depositCandidates(db, bankTransaction: savings).isEmpty)
        }
    }

    @Test func bookAsDepositBooksAndSettlesInOneGo() throws {
        let fx = try Fixture()
        try fx.app.write { db in
            let tag = try setup(db, fx)
            let deposit = try fx.tx(db, fx.betaal, "2027-03-01", 10_442)
            let result = try SettlementService.bookAsDeposit(db, bankTransactionId: deposit.id!, tagId: tag.id!,
                                                             label: "Declaratie")
            #expect(result.settlement.amount == c(10_442))
            #expect(result.difference == .zero)
            let booked = try fx.entries(db, tx: deposit.id!)
            #expect(booked.count == 1 && booked[0].budgetItemId == nil && booked[0].label == "Declaratie")
            #expect(result.deposit?.id == booked[0].id)
            #expect(try fx.status(db, deposit.id!) == .verwerkt)
            #expect(try SettlementService.open(db, tagId: tag.id!).amount == .zero)
            // Niets meer open: geen kandidaat en een tweede keer kan niet.
            let again = try fx.tx(db, fx.betaal, "2027-03-02", 10_442)
            #expect(try SettlementService.depositCandidates(db, bankTransaction: again).isEmpty)
            #expect(throws: BudgetError.self) {
                try SettlementService.bookAsDeposit(db, bankTransactionId: again.id!, tagId: tag.id!, label: "x")
            }
            #expect(try fx.status(db, again.id!) == .nieuw)
        }
    }
}
