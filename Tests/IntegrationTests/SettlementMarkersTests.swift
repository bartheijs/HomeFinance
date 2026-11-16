import Testing
import Foundation
import GRDB
import HFCore
import HFBudget
import HFInsight

/// HFInsight moet verrekeningen met spaar herkennen zoals HFBudget ze schrijft. Deze test gebruikt de ECHTE weg
/// (`createSavingsTransfer`, `markDone`, `attach`) en leest daarna met HFInsight, zodat de twee niet uit elkaar
/// kunnen lopen.
///
/// Verzonnen situatie: Tandarts −120 en Bril −45 zijn van de betaalrekening betaald uit pot Gezondheid (200).
/// Eén verrekening van 165 van spaar naar betaal, afgevinkt op 3 maart 2027.
@Suite struct SettlementMarkersTests {
    let transferDay = Day(iso: "2027-03-03")!
    let bankDay = Day(iso: "2027-03-04")!

    private struct Setup {
        let db: AppDatabase
        let checking: Int64, savings: Int64, pot: Int64
        let transferId: Int64
    }

    /// Rekeningen, een pot, twee gemarkeerde uitgaven en een afgevinkte verrekening.
    private func setUp() throws -> Setup {
        let db = try AppDatabase.inMemory()
        return try db.write { d in
            var year = BudgetYear(year: 2027); try year.insert(d)
            var checking = Account(name: "Betaalrekening", iban: "NL00TEST0000000001", kind: .betaal,
                                   openingBalance: Money(cents: 300_000), openingDate: Day(iso: "2027-01-01")!)
            try checking.insert(d)
            var savings = Account(name: "Spaarrekening", iban: "NL00TEST0000000002", kind: .spaar,
                                  openingBalance: Money(cents: 100_000), openingDate: Day(iso: "2027-01-01")!)
            try savings.insert(d)
            var pot = Pot(accountId: savings.id!, name: "Gezondheid", kind: .reservering)
            try pot.insert(d)
            var opening = Entry(accountId: savings.id!, day: Day(iso: "2027-01-01")!, amount: Money(cents: 20_000),
                                label: "Beginsaldo Gezondheid", potId: pot.id, note: "Beginsaldo")
            try opening.insert(d)
            var ids: [Int64] = []
            for (amount, label, day) in [(-12_000, "Tandarts", "2027-02-26"), (-4_500, "Bril", "2027-03-01")] {
                var e = Entry(accountId: checking.id!, day: Day(iso: day)!, amount: Money(cents: Int64(amount)), label: label,
                              potId: pot.id, reimburse: true)
                try e.insert(d); ids.append(e.id!)
            }
            let transfer = try SavingsTransferService.createSavingsTransfer(d, entryIds: ids, day: transferDay)
            try SavingsTransferService.markDone(d, savingsTransferId: transfer.id!, on: transferDay)
            return Setup(db: db, checking: checking.id!, savings: savings.id!, pot: pot.id!, transferId: transfer.id!)
        }
    }

    private func bankTransaction(_ s: Setup, account: Int64, cents: Int64, fingerprint: String) throws -> Int64 {
        try s.db.write { d in
            var b = BankTransaction(accountId: account, day: bankDay, amount: Money(cents: cents),
                                    counterpartyName: "Eigen rekening Test", fingerprint: fingerprint)
            try b.insert(d)
            return b.id!
        }
    }

    private func detail(_ s: Setup) throws -> SavingsTransferDetail {
        try #require(try s.db.read { try Insight.savingsTransfers($0) }.first { $0.id == s.transferId })
    }
    private func unconfirmed(_ s: Setup, today: Day) throws -> [AttentionItem] {
        try s.db.read { try Insight.dashboard($0, today: today) }.attention.filter {
            switch $0 { case .unconfirmedSettlement, .unconfirmedSettlements: return true; default: return false }
        }
    }

    @Test func attachedBankLinesConfirmBothSides() throws {
        let s = try setUp()
        // Direct na het afvinken: afgevinkt, geboekt, nog zonder bankregels.
        var t = try detail(s)
        #expect(t.isDone)
        #expect(t.amount == Money(cents: 16_500))               // netto van spaar naar betaal
        #expect(t.direction == .fromSavings)
        #expect(t.potMutationsBooked)
        #expect(t.bookings.count == 2)                          // potmutatie op spaar + boeking op betaal
        #expect(t.bookings.allSatisfy { $0.isSettlementBooking && $0.settlementTransferId == s.transferId })
        #expect(t.potEntries.map(\.amount) == [Money(cents: -16_500)])
        #expect(t.entries.map(\.label) == ["Tandarts", "Bril"])  // de gemarkeerde boekingen zijn geen verrekeningsboekingen
        #expect(t.entries.allSatisfy { !$0.isSettlementBooking })
        #expect(!t.checkingBankConfirmed && !t.savingsBankConfirmed && !t.bankConfirmed)
        #expect(t.unconfirmedSince == transferDay)

        // De bankregels komen binnen en worden aangehangen.
        let onChecking = try bankTransaction(s, account: s.checking, cents: 16_500, fingerprint: "fp-betaal")
        let onSavings = try bankTransaction(s, account: s.savings, cents: -16_500, fingerprint: "fp-spaar")
        try s.db.write { d in
            try SavingsTransferService.attach(d, savingsTransferId: s.transferId, bankTransactionId: onChecking)
            try SavingsTransferService.attach(d, savingsTransferId: s.transferId, bankTransactionId: onSavings)
        }
        t = try detail(s)
        #expect(t.isDone)
        #expect(t.checkingBankConfirmed)
        #expect(t.savingsBankConfirmed)
        #expect(t.bankConfirmed)
        #expect(t.unconfirmedSince == nil)
        #expect(t.bookings.allSatisfy { $0.bankTransactionId != nil && $0.isSettlementBooking })
        // Ook ruim na de bevestigingstermijn geen melding.
        #expect(try unconfirmed(s, today: Day(iso: "2027-03-20")!).isEmpty)
        // HFBudget en HFInsight zijn het eens.
        #expect(try s.db.read { try SavingsTransferService.unconfirmed($0, today: Day(iso: "2027-03-20")!) }.isEmpty)
    }

    @Test func withoutAttachTheWarningComesAfterTheConfirmationPeriod() throws {
        let s = try setUp()
        let days = SavingsTransferService.confirmationDays
        #expect(Insight.settlementConfirmationDays == days)
        // Voor de termijn geen melding; erop of erna wel (6 dagen na het boeken zeker).
        let early = transferDay.adding(days: days - 1)
        #expect(try unconfirmed(s, today: early).isEmpty)
        #expect(try s.db.read { try SavingsTransferService.unconfirmed($0, today: early) }.isEmpty)
        let late = transferDay.adding(days: 6)
        let items = try unconfirmed(s, today: late)
        #expect(items == [.unconfirmedSettlement(amount: Money(cents: 16_500), day: transferDay)])
        #expect(try s.db.read { try SavingsTransferService.unconfirmed($0, today: late) }.map(\.id) == [s.transferId])
        #expect(try !detail(s).bankConfirmed)
    }

    @Test func oneSideAttachedKeepsTheWarningForTheOtherSide() throws {
        let s = try setUp()
        let onChecking = try bankTransaction(s, account: s.checking, cents: 16_500, fingerprint: "fp-betaal")
        try s.db.write { d in
            try SavingsTransferService.attach(d, savingsTransferId: s.transferId, bankTransactionId: onChecking)
        }
        let t = try detail(s)
        #expect(t.checkingBankConfirmed)
        #expect(!t.savingsBankConfirmed)
        #expect(!t.bankConfirmed)
        // De boeking op de betaalrekening is naar de bankdag geschoven; de spaarkant staat nog op de dag van afvinken.
        #expect(t.unconfirmedSince == transferDay)
        let late = transferDay.adding(days: 6)
        #expect(try unconfirmed(s, today: late).count == 1)
        #expect(try s.db.read { try SavingsTransferService.unconfirmed($0, today: late) }.count == 1)
    }

    @Test func reopenedTransferHasNoBookingsLeft() throws {
        let s = try setUp()
        try s.db.write { d in try SavingsTransferService.reopen(d, savingsTransferId: s.transferId) }
        let t = try detail(s)
        #expect(!t.isDone)
        #expect(t.bookings.isEmpty)
        #expect(!t.potMutationsBooked)
        #expect(t.unconfirmedSince == nil)
        #expect(try unconfirmed(s, today: transferDay.adding(days: 30)).isEmpty)
    }
}
