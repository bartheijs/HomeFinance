import Foundation
import GRDB
import HFCore
import Testing
@testable import HFInsight

private let today = Fixture.today

/// Verrekenen met spaar in twee richtingen. Open in de fixture:
///   Uit eten −75 (pot Vakantie, saldo 100) · Tandarts −120 (geen pot)   → 195 uit spaar
/// Potsaldi: Auto 200 · Vakantie 100 · Kind A 25.
@Suite struct ReimbursementTests {
    let f: Fixture
    init() throws { f = try Fixture() }

    @discardableResult
    private func mark(_ day: String, _ amount: Int64, _ label: String, pot: Int64?, transfer: Int64? = nil,
                      account: Int64? = nil, reimburse: Bool = true) throws -> Int64 {
        try f.db.write { db in
            var e = Entry(accountId: account ?? f.betaal, day: d(day), amount: eur(amount), label: label, potId: pot,
                          reimburse: reimburse, savingsTransferId: transfer)
            try e.insert(db); return e.id!
        }
    }
    private func open() throws -> OpenReimbursements { try f.db.read { try Insight.openReimbursements($0) } }
    private func attention() throws -> AttentionItem? {
        try f.db.read { try Insight.dashboard($0, today: today) }.attention.first {
            if case .openReimbursements = $0 { return true }; return false
        }
    }

    @Test func expensesOnly() throws {
        let o = try open()
        #expect(o.entries.map(\.label) == ["Uit eten", "Tandarts"])
        #expect(o.fromSavings == eur(195))
        #expect(o.toSavings == .zero)
        #expect(o.net == eur(195))
        #expect(o.transferAmount == eur(195))
        #expect(o.direction == .fromSavings)
        #expect(o.total == eur(-195))                           // oude betekenis: som van de boekingen
        #expect(o.withoutPotCount == 1)
        #expect(o.perPot.map(\.potName) == ["Vakantie", nil])
        #expect(o.perPot.map(\.amount) == [eur(75), eur(120)])  // gaat de pot uit
        #expect(o.perPot.map(\.total) == [eur(-75), eur(-120)])
        #expect(o.perPot.map(\.balanceAfter) == [eur(25), nil]) // Vakantie 100 − 75
        #expect(try attention() == .openReimbursements(amount: eur(195), count: 2, direction: .fromSavings))
        #expect(try attention()?.message == "€ 195,00 over te maken van spaar naar betaal (2 boekingen).")
    }

    @Test func mixedExpensesAndDeposits() throws {
        try mark("2027-03-11", 50, "Verjaardagsgeld", pot: f.potKind)
        let o = try open()
        // Uit spaar 195, naar spaar 50: netto 145 van spaar naar betaal.
        #expect(o.fromSavings == eur(195))
        #expect(o.toSavings == eur(50))
        #expect(o.net == eur(145))
        #expect(o.transferAmount == eur(145))
        #expect(o.direction == .fromSavings)
        #expect(o.perPot.map(\.potName) == ["Vakantie", nil, "Spaarpot Kind A"])
        #expect(o.perPot.map(\.amount) == [eur(75), eur(120), eur(-50)])
        #expect(o.perPot.map(\.balanceAfter) == [eur(25), nil, eur(75)])   // Kind A 25 + 50
        #expect(o.entries.map(\.settlementDirection) == [.fromPot, .fromPot, .toPot])
        #expect(try attention()?.message == "€ 145,00 over te maken van spaar naar betaal (3 boekingen).")
        // Een niet-gemarkeerde boeking heeft geen richting.
        let plain = try #require(try f.db.read { try Insight.searchEntries($0, filter: EntryFilter(text: "Marktplaats")) }.rows.first)
        #expect(plain.settlementDirection == nil)
    }

    @Test func netNegativeGoesToSavings() throws {
        try mark("2027-03-11", 300, "Gift opa", pot: f.potKind)
        let o = try open()
        // 195 − 300 = −105: van betaal naar spaar.
        #expect(o.net == eur(-105))
        #expect(o.transferAmount == eur(105))
        #expect(o.direction == .toSavings)
        #expect(o.total == eur(105))
        #expect(try attention() == .openReimbursements(amount: eur(105), count: 3, direction: .toSavings))
        #expect(try attention()?.message == "€ 105,00 over te maken van betaal naar spaar (3 boekingen).")
    }

    @Test func netZeroStillSettlesBetweenPots() throws {
        try mark("2027-03-11", 195, "Gift opa", pot: f.potKind)
        let o = try open()
        #expect(o.net == .zero)
        #expect(o.transferAmount == .zero)
        #expect(o.direction == .none)
        #expect(o.perPot.map(\.amount) == [eur(75), eur(120), eur(-195)])
        #expect(try attention() == .openReimbursements(amount: .zero, count: 3, direction: .none))
        #expect(try attention()?.message == "3 boekingen over te boeken tussen potjes.")
        #expect(AttentionItem.openReimbursements(amount: .zero, count: 1, direction: .none).message
                == "1 boeking over te boeken tussen potjes.")
    }

    @Test func samePotBothWaysAndPendingPerPot() throws {
        try mark("2027-03-11", 25, "Terug van reisgenoot", pot: f.potVakantie)
        try mark("2027-03-12", 50, "Verjaardagsgeld", pot: f.potKind)
        let o = try open()
        // Vakantie: −75 + 25 → 50 de pot uit, saldo 100 − 50 = 50. Kind A: 50 erbij → 75.
        let vakantie = try #require(o.perPot.first { $0.potId == f.potVakantie })
        #expect(vakantie.amount == eur(50))
        #expect(vakantie.count == 2)
        #expect(vakantie.balanceAfter == eur(50))
        let pots = try f.db.read { try Insight.potOverview($0, today: today) }.accounts[0].pots
        #expect(pots.map(\.pendingSettlement) == [.zero, eur(50), eur(-50)])
        // De potsaldi zelf veranderen pas als de potmutaties geboekt worden.
        #expect(pots.map(\.balance) == [eur(200), eur(100), eur(25)])
    }

    @Test func nothingOpen() throws {
        try f.db.write { db in try db.execute(sql: "UPDATE entry SET reimburse = 0") }
        let o = try open()
        #expect(o.entries.isEmpty)
        #expect(o.direction == .none)
        #expect(o.transferAmount == .zero)
        #expect(o.withoutPotCount == 0)
        #expect(try attention() == nil)
    }

    @Test func transferHistory() throws {
        // Nieuwe overboeking van 5-3: Bril −95 (pot Auto) en Gift +200 (pot Kind A) → netto −105: van betaal naar spaar.
        let t2: Int64 = try f.db.write { db in
            var t = SavingsTransfer(day: d("2027-03-05"), amount: eur(-105), note: "maart")
            try t.insert(db); return t.id!
        }
        try mark("2027-03-04", -95, "Bril", pot: f.potAuto, transfer: t2)
        try mark("2027-03-04", 200, "Gift", pot: f.potKind, transfer: t2)

        var list = try f.db.read { try Insight.savingsTransfers($0) }
        #expect(list.map(\.id) == [t2, f.transfer])             // nieuwste eerst
        let new = list[0]
        #expect(new.amount == eur(-105))
        #expect(new.transferAmount == eur(105))
        #expect(new.direction == .toSavings)
        #expect(!new.done)
        #expect(new.entries.map(\.label) == ["Bril", "Gift"])
        #expect(new.entriesTotal == eur(105))                   // = −amount
        #expect(new.perPot.map(\.potName) == ["Auto", "Spaarpot Kind A"])
        #expect(new.perPot.map(\.amount) == [eur(95), eur(-200)])
        #expect(new.perPot.allSatisfy { $0.balanceAfter == nil })
        #expect(!new.potMutationsBooked)
        #expect(new.potEntries.isEmpty)
        #expect(new.unconfirmedSince == nil)                    // nog niet afgevinkt
        // De oude overboeking uit de fixture: 30 van spaar naar betaal (Cadeau −30 uit Kind A).
        let old = list[1]
        #expect(old.direction == .fromSavings)
        #expect(old.transferAmount == eur(30))
        #expect(old.done)
        #expect(old.perPot.map(\.amount) == [eur(30)])

        // De potmutaties worden geboekt op de spaarrekening en hangen aan de overboeking.
        let pot1 = try mark("2027-03-05", -95, "Verrekening Auto", pot: f.potAuto, account: f.spaar, reimburse: false)
        let pot2 = try mark("2027-03-05", 200, "Verrekening Kind A", pot: f.potKind, account: f.spaar, reimburse: false)
        try f.db.write { db in try Setting.set(db, "savingsTransfer.\(t2).entries", "\(pot1),\(pot2)") }
        list = try f.db.read { try Insight.savingsTransfers($0) }
        #expect(list[0].potMutationsBooked)
        #expect(list[0].potEntries.map(\.amount) == [eur(-95), eur(200)])
        #expect(list[0].entries.map(\.label) == ["Bril", "Gift"])   // de spaarboekingen staan niet tussen de verrekende boekingen
        #expect(list[0].entriesTotal == eur(105))
        // Boekingen in een overboeking staan niet meer open.
        #expect(try open().entries.map(\.label) == ["Uit eten", "Tandarts"])
    }
}

/// Een verrekening wordt volledig geboekt zodra hij is afgevinkt. Verrekening van 5-3-2027:
///   Bril −95 (pot Auto) en Gift +200 (pot Kind A) → netto −105: van betaal naar spaar.
///   Verrekeningsboekingen (instelling `savingsTransfer.<id>.entries`, notitie "Verrekening #<id>"):
///     spaarrekening: Auto −95 · Kind A +200      betaalrekening: −105 (de tegenboeking, een gewone diverse boeking)
@Suite struct SettlementBookingTests {
    let f: Fixture
    var transfer: Int64 = 0
    var checkingBooking: Int64 = 0, potBookings: [Int64] = []

    init() throws {
        f = try Fixture()
        try f.db.write { db in
            var t = SavingsTransfer(day: d("2027-03-05"), amount: eur(-105), note: "maart")
            try t.insert(db); transfer = t.id!
            for (amount, label, pot) in [(Int64(-95), "Bril", f.potAuto), (200, "Gift", f.potKind)] {
                var e = Entry(accountId: f.betaal, day: d("2027-03-04"), amount: eur(amount), label: label, potId: pot,
                              reimburse: true, savingsTransferId: transfer)
                try e.insert(db)
            }
        }
    }

    /// Wat `markDone` doet: afvinken en de boekingen maken.
    private func markDone() throws -> (checking: Int64, pots: [Int64]) {
        try f.db.write { db in
            try db.execute(sql: "UPDATE savingsTransfer SET done = 1 WHERE id = ?", arguments: [transfer])
            // Zoals `SavingsTransferService.markDone`: notitie "Verrekening #<id>" en de id's in de instelling.
            let note = "Verrekening #\(transfer)"
            var ids: [Int64] = []
            for (account, amount, label, pot) in [
                (f.spaar, Int64(-95), "Verrekening spaar: Auto", f.potAuto as Int64?),
                (f.spaar, 200, "Verrekening spaar: Spaarpot Kind A", f.potKind),
                (f.betaal, -105, "Verrekening spaar", nil),
            ] {
                var e = Entry(accountId: account, day: d("2027-03-05"), amount: eur(amount), label: label, potId: pot, note: note)
                try e.insert(db); ids.append(e.id!)
            }
            try Setting.set(db, "savingsTransfer.\(transfer).entries", ids.map(String.init).joined(separator: ","))
            return (ids[2], Array(ids[0...1]))
        }
    }

    private func attachBank(_ entryIds: [Int64], account: Int64, amount: Int64, fingerprint: String) throws {
        try f.db.write { db in
            var b = BankTransaction(accountId: account, day: d("2027-03-06"), amount: eur(amount),
                                    counterpartyName: "Eigen rekening Test", fingerprint: fingerprint, status: .verwerkt)
            try b.insert(db)
            for id in entryIds { try db.execute(sql: "UPDATE entry SET bankTransactionId = ? WHERE id = ?", arguments: [b.id!, id]) }
        }
    }

    private func detail() throws -> SavingsTransferDetail {
        try #require(try f.db.read { try Insight.savingsTransfers($0) }.first { $0.id == transfer })
    }
    private func unconfirmed(today day: Day = Fixture.today) throws -> [AttentionItem] {
        try f.db.read { try Insight.dashboard($0, today: day) }.attention.filter {
            switch $0 { case .unconfirmedSettlement, .unconfirmedSettlements: return true; default: return false }
        }
    }
    private func pending() throws -> [Money] {
        try f.db.read { try Insight.potOverview($0, today: Fixture.today) }.accounts[0].pots.map(\.pendingSettlement)
    }

    @Test func pendingUntilMarkedDone() throws {
        // In een verrekening die nog niet is afgevinkt telt alles nog mee: Auto 95 eruit, Vakantie 75 eruit
        // (open in de fixture), Kind A 200 erbij. Cadeau −30 zit in de afgevinkte verrekening van januari: telt niet.
        #expect(try pending() == [eur(95), eur(75), eur(-200)])
        #expect(try !detail().isDone)
        #expect(try detail().bookings.isEmpty)
        #expect(try unconfirmed().isEmpty)                      // niet afgevinkt: geen melding
        _ = try markDone()
        // Afgevinkt: de potmutaties zijn geboekt, er is niets meer te verrekenen voor Auto en Kind A.
        #expect(try pending() == [.zero, eur(75), .zero])
        let pots = try f.db.read { try Insight.potOverview($0, today: Fixture.today) }.accounts[0].pots
        #expect(pots.map(\.balance) == [eur(105), eur(100), eur(225)])   // Auto 200 − 95 · Kind A 25 + 200
    }

    @Test func doneTransferWithBookings() throws {
        let made = try markDone()
        let t = try detail()
        #expect(t.isDone)
        #expect(t.direction == .toSavings)
        #expect(t.transferAmount == eur(105))
        #expect(t.entries.map(\.label) == ["Bril", "Gift"])             // alleen de gemarkeerde boekingen
        #expect(t.bookings.map(\.id).sorted() == (made.pots + [made.checking]).sorted())
        #expect(t.bookings.allSatisfy { $0.isSettlementBooking && $0.settlementTransferId == transfer })
        #expect(t.potEntries.map(\.amount) == [eur(-95), eur(200)])
        #expect(t.potMutationsBooked)
        #expect(!t.checkingBankConfirmed)
        #expect(!t.savingsBankConfirmed)
        #expect(!t.bankConfirmed)
        // De gemarkeerde boekingen zelf zijn geen verrekeningsboekingen.
        #expect(t.entries.allSatisfy { !$0.isSettlementBooking })
    }

    @Test func counterBookingIsOrdinaryDiversInTheBudget() throws {
        let made = try markDone()
        try f.db.read { db in
            let uit = try Insight.diversEntries(db, year: 2027, month: 3, positive: false)
            let counter = try #require(uit.first { $0.id == made.checking })
            #expect(counter.isSettlementBooking)
            #expect(counter.isDivers)
            // Maart UIT divers: −210 (fixture) − 95 (Bril) − 105 (tegenboeking) = −410; IN divers: 20 + 200 (Gift) = 220.
            let g = try Insight.monthGrid(db, year: 2027, today: Fixture.today)
            #expect(g.monthTotals[2].uitDivers == eur(-410))
            #expect(g.monthTotals[2].inDivers == eur(220))
            // Saldo betaalrekening: 3540 − 95 + 200 − 105 = 3540: de verrekening is per saldo al overgemaakt.
            try #expect(Insight.balance(db, accountId: f.betaal, on: Fixture.today) == eur(3540))
        }
    }

    @Test func unconfirmedAfterFiveDaysUntilBothSidesSeen() throws {
        let made = try markDone()
        // Zoals `SavingsTransferService.unconfirmed`: 5 dagen na het boeken (5 maart) zonder bankregel.
        #expect(try unconfirmed(today: d("2027-03-09")).isEmpty)        // 4 dagen
        let item = AttentionItem.unconfirmedSettlement(amount: eur(105), day: d("2027-03-05"))
        #expect(try unconfirmed(today: d("2027-03-10")) == [item])      // precies 5 dagen
        #expect(try unconfirmed(today: d("2027-03-11")) == [item])
        #expect(try detail().unconfirmedSince == d("2027-03-05"))
        #expect(item.message == "Overboeking met spaar van € 105,00 op 05-03-2027 is nog niet gezien in een bankbestand.")

        // De bankregel op de betaalrekening hangt eraan: nog niet aan beide kanten.
        try attachBank([made.checking], account: f.betaal, amount: -105, fingerprint: "fp-verrekening-betaal")
        #expect(try detail().checkingBankConfirmed)
        #expect(try !detail().savingsBankConfirmed)
        // De bankregel verschuift de boeking naar de dag van de bank; wat nog open staat is de spaarkant.
        #expect(try unconfirmed() == [item])
        // Ook de spaarkant: bevestigd, de melding verdwijnt.
        try attachBank(made.pots, account: f.spaar, amount: 105, fingerprint: "fp-verrekening-spaar")
        #expect(try detail().savingsBankConfirmed)
        #expect(try detail().bankConfirmed)
        #expect(try unconfirmed().isEmpty)
    }

    @Test func netZeroNeedsNoBankConfirmation() throws {
        try f.db.write { db in
            try db.execute(sql: "UPDATE savingsTransfer SET amount = 0, done = 1 WHERE id = ?", arguments: [transfer])
        }
        #expect(try detail().direction == .none)
        #expect(try detail().bankConfirmed)
        #expect(try unconfirmed().isEmpty)
    }

    @Test func bookingsAreRecognisedFromTheEntriesSetting() throws {
        // Alleen de instelling `savingsTransfer.<id>.entries` telt; de notitie is voor de gebruiker.
        try f.db.write { db in
            try db.execute(sql: "UPDATE savingsTransfer SET done = 1 WHERE id = ?", arguments: [transfer])
            var pot = Entry(accountId: f.spaar, day: d("2027-03-05"), amount: eur(200), label: "Naar Kind A", potId: f.potKind)
            try pot.insert(db)
            var b = BankTransaction(accountId: f.betaal, day: d("2027-03-06"), amount: eur(-105),
                                    counterpartyName: "Eigen rekening Test", fingerprint: "fp-instelling", status: .verwerkt)
            try b.insert(db)
            var counter = Entry(accountId: f.betaal, bankTransactionId: b.id, day: d("2027-03-06"), amount: eur(-105),
                                label: "Verrekening spaar")
            try counter.insert(db)
            // Een boeking met de notitie maar zonder markering is geen verrekeningsboeking.
            var loose = Entry(accountId: f.betaal, day: d("2027-03-06"), amount: eur(-1), label: "Los", note: "Verrekening #\(transfer)")
            try loose.insert(db)
            try Setting.set(db, "savingsTransfer.\(transfer).entries", "\(pot.id!),\(counter.id!)")
        }
        let t = try detail()
        #expect(t.bookings.map(\.label) == ["Naar Kind A", "Verrekening spaar"])
        #expect(t.potMutationsBooked)
        #expect(t.checkingBankConfirmed)
        #expect(!t.savingsBankConfirmed)
        #expect(t.unconfirmedSince == d("2027-03-05"))          // de spaarkant heeft nog geen bankregel
        let row = try #require(try f.db.read { try Insight.searchEntries($0, filter: EntryFilter(text: "Verrekening spaar")) }.rows.first)
        #expect(row.isSettlementBooking)
        #expect(row.settlementTransferId == transfer)
        let loose = try #require(try f.db.read { try Insight.searchEntries($0, filter: EntryFilter(text: "Los")) }.rows.first)
        #expect(!loose.isSettlementBooking)
        // Een gewone boeking is geen verrekeningsboeking.
        let plain = try #require(try f.db.read { try Insight.searchEntries($0, filter: EntryFilter(text: "Tandarts")) }.rows.first)
        #expect(!plain.isSettlementBooking)
    }
}

/// "Nog te besteden" gaat uit van een situatie waarin alles verrekend is. Fixture op 15-3-2027:
///   besteedbaar nu 3.040,00 · nog verwacht +2.400,00 · open verrekening Uit eten −75 en Tandarts −120.
@Suite struct PendingSettlementTests {
    let f: Fixture
    init() throws { f = try Fixture() }

    private func spendable(today day: Day = Fixture.today) throws -> Spendable {
        try f.db.read { try Insight.spendable($0, year: 2027, today: day) }
    }
    private func mark(_ day: String, _ amount: Int64, _ label: String, transfer: Int64? = nil) throws {
        try f.db.write { db in
            var e = Entry(accountId: f.betaal, day: d(day), amount: eur(amount), label: label, reimburse: true,
                          savingsTransferId: transfer)
            try e.insert(db)
        }
    }

    @Test func fromSavingsToChecking() throws {
        let s = try spendable()
        #expect(s.pendingSettlement == eur(195))                // er komt nog 195 van spaar naar betaal
        #expect(s.spendable == eur(3040))                       // besteedbaar nu verandert niet
        #expect(s.spendableEndOfMonth == eur(3040) + eur(2400) + eur(195))
    }

    @Test func fromCheckingToSavings() throws {
        try mark("2027-03-11", 300, "Gift opa")                 // moet nog naar een potje: −105 netto
        let s = try spendable()
        // De gift staat al op de betaalrekening: besteedbaar nu 3040 + 300 = 3340.
        #expect(s.spendable == eur(3340))
        #expect(s.pendingSettlement == eur(-105))               // 195 − 300
        // 3340 + 2400 − 105 = 5635: hetzelfde eindbedrag als zonder gift, want na verrekenen is de gift weg.
        #expect(s.spendableEndOfMonth == eur(5635))
    }

    @Test func netZero() throws {
        try mark("2027-03-11", 195, "Gift opa")
        let s = try spendable()
        // Besteedbaar nu 3040 + 195 = 3235; netto niets te verrekenen; de 195 die erbij kwam blijft staan:
        // 3235 + 2400 = 5635.
        #expect(s.spendable == eur(3235))
        #expect(s.pendingSettlement == .zero)
        #expect(s.spendableEndOfMonth == eur(5635))
    }

    @Test func markedDoneTransferNoLongerCounts() throws {
        let transfer: Int64 = try f.db.write { db in
            var t = SavingsTransfer(day: d("2027-03-12"), amount: eur(195), done: false)
            try t.insert(db)
            try db.execute(sql: "UPDATE entry SET savingsTransferId = ? WHERE reimburse = 1 AND savingsTransferId IS NULL",
                           arguments: [t.id!])
            return t.id!
        }
        // In een verrekening die nog niet is afgevinkt telt hij nog mee.
        #expect(try spendable().pendingSettlement == eur(195))
        try f.db.write { db in try db.execute(sql: "UPDATE savingsTransfer SET done = 1 WHERE id = ?", arguments: [transfer]) }
        let s = try spendable()
        #expect(s.pendingSettlement == .zero)
        #expect(s.spendableEndOfMonth == eur(5440))
    }

    @Test func onlyInTheCurrentYear() throws {
        // Voor een voorbij jaar is er geen simulatie, dus ook geen verrekening die meetelt.
        let past = try spendable(today: d("2028-02-01"))
        #expect(past.pendingSettlement == .zero)
        #expect(past.spendableEndOfMonth == past.spendable)
    }
}

/// Meer dan één onbevestigde verrekening wordt één melding. Fixture: de overboeking van 31-1 (30,00, afgevinkt)
/// is nog in geen bankbestand gezien.
@Suite struct UnconfirmedSummaryTests {
    let f: Fixture
    init() throws { f = try Fixture() }

    private func items(today day: Day = Fixture.today) throws -> [AttentionItem] {
        try f.db.read { try Insight.dashboard($0, today: day) }.attention.filter {
            switch $0 { case .unconfirmedSettlement, .unconfirmedSettlements: return true; default: return false }
        }
    }
    /// Een afgevinkte verrekening met de boeking op de betaalrekening, zoals `markDone` hem maakt (zonder bankregel).
    private func addDone(_ day: String, _ amount: Int64) throws {
        try f.db.write { db in
            var t = SavingsTransfer(day: d(day), amount: eur(amount), done: true)
            try t.insert(db)
            var e = Entry(accountId: f.betaal, day: d(day), amount: eur(amount), label: "Verrekening spaar", note: "Verrekening #\(t.id!)")
            try e.insert(db)
            try Setting.set(db, "savingsTransfer.\(t.id!).entries", "\(e.id!)")
        }
    }

    @Test func oneStaysSingle() throws {
        // De overboeking van januari in de fixture is afgevinkt maar zonder boekingen: HFBudget kent hem niet als onbevestigd.
        #expect(try items().isEmpty)
        try addDone("2027-03-01", 45)
        #expect(try items() == [.unconfirmedSettlement(amount: eur(45), day: d("2027-03-01"))])
    }

    @Test func severalBecomeOne() throws {
        try addDone("2027-01-31", 30)
        try addDone("2027-02-20", -80)      // van betaal naar spaar: telt met zijn bedrag zonder teken
        try addDone("2027-03-01", 45)
        let list = try items()
        let summary = AttentionItem.unconfirmedSettlements(count: 3, total: eur(155), oldestDay: d("2027-01-31"))
        #expect(list == [summary])
        #expect(summary.message == "3 overboekingen met spaar (samen € 155,00) zijn nog niet gezien in een bankbestand, de oudste van 31-01-2027.")
    }

    @Test func recentOnesDoNotCount() throws {
        try addDone("2027-03-01", 45)
        try addDone("2027-03-12", 60)       // 3 dagen geleden: nog geen reden tot melden
        #expect(try items() == [.unconfirmedSettlement(amount: eur(45), day: d("2027-03-01"))])
        try addDone("2027-03-08", 60)       // 7 dagen geleden
        #expect(try items() == [.unconfirmedSettlements(count: 2, total: eur(105), oldestDay: d("2027-03-01"))])
    }
}
