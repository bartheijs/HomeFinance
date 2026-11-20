import Foundation
import GRDB
import HFCore
import Testing
@testable import HFBackup

/// Dagen waarop de voorbeelddata moet kloppen: begin, midden en eind van het jaar, ook een schrikkeljaar.
let demoDays: [Day] = [
    Day(year: 2027, month: 1, day: 1)!, Day(year: 2027, month: 1, day: 9)!, Day(year: 2027, month: 3, day: 3)!,
    testToday, Day(year: 2027, month: 11, day: 13)!, Day(year: 2027, month: 12, day: 31)!,
    Day(year: 2028, month: 2, day: 29)!, Day(year: 2026, month: 11, day: 13)!,
]

func seeded(_ today: Day, leaveRecentForImport: Bool = false) throws -> (AppDatabase, DemoSummary) {
    let db = try AppDatabase.inMemory()
    let summary = try DemoData.seed(into: db, today: today, leaveRecentForImport: leaveRecentForImport)
    return (db, summary)
}

@Suite struct DemoDataTests {
    @Test(arguments: demoDays)
    func processedTransactionsAreFullyBooked(today: Day) throws {
        let (db, _) = try seeded(today)
        try db.read { database in
            let wrong = try Int.fetchOne(database, sql: """
                SELECT COUNT(*) FROM bankTransaction t
                WHERE t.status = 'verwerkt'
                  AND t.amount <> (SELECT COALESCE(SUM(e.amount), 0) FROM entry e WHERE e.bankTransactionId = t.id)
                """)
            #expect(wrong == 0)
            // Nieuwe transacties hebben geen boekingen en liggen in de laatste 10 dagen.
            let newWithEntries = try Int.fetchOne(database, sql: """
                SELECT COUNT(*) FROM entry e JOIN bankTransaction t ON t.id = e.bankTransactionId WHERE t.status = 'nieuw'
                """)
            #expect(newWithEntries == 0)
            let cutoff = today.adding(days: -10)
            #expect(try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM bankTransaction WHERE status = 'nieuw' AND day <= ?",
                                     arguments: [cutoff]) == 0)
            #expect(try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM bankTransaction WHERE status <> 'nieuw' AND day > ?",
                                     arguments: [cutoff]) == 0)
            #expect(try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM bankTransaction WHERE day > ? OR day < ?",
                                     arguments: [today, Day(year: today.year, month: 1, day: 1)!]) == 0)
            #expect(try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM bankTransaction WHERE status = 'nieuw'")! > 0)
        }
    }

    @Test(arguments: demoDays)
    func balanceChainIsConsistent(today: Day) throws {
        let (db, _) = try seeded(today)
        try db.read { database in
            for account in try Account.fetchAll(database) {
                let rows = try BankTransaction.fetchAll(database, sql:
                    "SELECT * FROM bankTransaction WHERE accountId = ? ORDER BY id", arguments: [account.id])
                // De keten begint bij het beginsaldo plus de handboekingen van de begindatum (beginsaldi per pot).
                let manual = try Money.fetchOne(database, sql:
                    "SELECT COALESCE(SUM(amount), 0) FROM entry WHERE accountId = ? AND bankTransactionId IS NULL",
                    arguments: [account.id])!
                var expected = account.openingBalance + manual
                var previousDay = account.openingDate
                for row in rows {
                    #expect(row.balanceBefore == expected)
                    #expect(row.day >= previousDay)
                    expected += row.amount
                    previousDay = row.day
                }
            }
        }
    }

    @Test(arguments: demoDays)
    func accountBalanceEqualsOpeningPlusEntries(today: Day) throws {
        let (db, summary) = try seeded(today)
        try db.read { database in
            for account in try Account.fetchAll(database) {
                let entries = try Money.fetchOne(database, sql:
                    "SELECT COALESCE(SUM(amount), 0) FROM entry WHERE accountId = ?", arguments: [account.id])!
                let processed = try Money.fetchOne(database, sql:
                    "SELECT COALESCE(SUM(amount), 0) FROM bankTransaction WHERE accountId = ? AND status = 'verwerkt'",
                    arguments: [account.id])!
                let booked = try Money.fetchOne(database, sql:
                    "SELECT COALESCE(SUM(amount), 0) FROM entry WHERE accountId = ? AND bankTransactionId IS NOT NULL",
                    arguments: [account.id])!
                #expect(booked == processed)
                let firstNew = try BankTransaction.fetchOne(database, sql:
                    "SELECT * FROM bankTransaction WHERE accountId = ? AND status = 'nieuw' ORDER BY id LIMIT 1",
                    arguments: [account.id])
                if let firstNew { #expect(firstNew.balanceBefore == account.openingBalance + entries) }
                if account.id == summary.checkingAccountId {
                    #expect(summary.checkingBalance == account.openingBalance + entries)
                }
            }
            let reconciliation = try Reconciliation.fetchAll(database)
            #expect(reconciliation.count == 1)
            #expect(reconciliation[0].difference == .zero)
            #expect(reconciliation[0].accountId == summary.checkingAccountId)
            #expect(reconciliation[0].calculatedBalance == summary.checkingBalance)
            let through = try Money.fetchOne(database, sql:
                "SELECT COALESCE(SUM(amount), 0) FROM entry WHERE accountId = ? AND day <= ?",
                arguments: [summary.checkingAccountId, reconciliation[0].day])!
            #expect(reconciliation[0].calculatedBalance == DemoPlan.checkingOpening + through)
        }
    }

    @Test(arguments: demoDays)
    func potsFitInTheSavingsBalance(today: Day) throws {
        let (db, summary) = try seeded(today)
        try db.read { database in
            let account = try Account.fetchOne(database, key: summary.savingsAccountId)!
            let balance = account.openingBalance + (try Money.fetchOne(database, sql:
                "SELECT COALESCE(SUM(amount), 0) FROM entry WHERE accountId = ?", arguments: [account.id])!)
            let pots = try Row.fetchAll(database, sql: """
                SELECT p.name, COALESCE(SUM(e.amount), 0) AS balance FROM pot p
                LEFT JOIN entry e ON e.potId = p.id AND e.accountId = p.accountId GROUP BY p.id
                """)
            let potSum = pots.map { $0["balance"] as Money }.sum()
            #expect(potSum <= balance)
            // Niet toegewezen is precies de rentebijschrijving (zodra die geboekt is); verder heeft alles een pot.
            #expect(account.openingBalance == .zero)
            let unassigned = try Entry.fetchAll(database, sql:
                "SELECT * FROM entry WHERE accountId = ? AND potId IS NULL", arguments: [account.id])
            let interestBooked = Day(year: today.year, month: 1, day: DemoPlan.savingsInterestDay)! <= today.adding(days: -10)
            #expect(unassigned.count == (interestBooked ? 1 : 0))
            #expect(unassigned.allSatisfy { $0.amount == DemoPlan.savingsInterest && $0.bankTransactionId != nil })
            #expect(balance - potSum == (interestBooked ? DemoPlan.savingsInterest : .zero))
            // Elke pot heeft één beginsaldo-boeking op 1 januari, zonder banktransactie.
            let openings = try Entry.fetchAll(database, sql:
                "SELECT * FROM entry WHERE accountId = ? AND bankTransactionId IS NULL", arguments: [account.id])
            // (De pot voor de rente op de privélening begint leeg en heeft er dus geen.)
            #expect(openings.count == pots.count - 1)
            #expect(openings.allSatisfy { $0.potId != nil && $0.amount > .zero && $0.day == account.openingDate })
            #expect(Set(openings.compactMap(\.potId)).count == pots.count - 1)
            for pot in pots {
                #expect((pot["balance"] as Money) >= .zero, "pot \(pot["name"] as String) staat negatief")
            }
            // Boekingen met een pot op de spaarrekening horen bij een pot van die rekening.
            #expect(try Int.fetchOne(database, sql: """
                SELECT COUNT(*) FROM entry e JOIN pot p ON p.id = e.potId
                WHERE e.accountId = ? AND p.accountId <> e.accountId
                """, arguments: [account.id]) == 0)
        }
    }

    /// De privélening: jaarlijkse schenking naar een pot, maandelijkse rente vergoed uit die pot.
    @Test(arguments: demoDays)
    func loanInterestIsReimbursedFromItsPot(today: Day) throws {
        let (db, summary) = try seeded(today)
        let cutoff = today.adding(days: -10)
        try db.read { database in
            let pot = try #require(try Pot.filter(Column("name") == "Rente privélening").fetchOne(database))
            #expect(pot.kind == .reservering)
            #expect(pot.monthlyAmount == .zero)
            #expect(pot.accountId == summary.savingsAccountId)
            #expect(try BudgetItem.filter(Column("potId") == pot.id).fetchCount(database) == 0)
            let item = try #require(try BudgetItem.filter(Column("label") == "Privélening").fetchOne(database))
            let gift = Money(cents: -item.planAmount.cents * 12)

            // Schenking: binnen op de betaalrekening (divers), door naar de pot, aan beide kanten gekoppeld.
            let received = try Entry.fetchAll(database, sql:
                "SELECT * FROM entry WHERE accountId = ? AND label = 'Schenking familie'", arguments: [summary.checkingAccountId])
            let inPot = try Entry.fetchAll(database, sql:
                "SELECT * FROM entry WHERE accountId = ? AND potId = ? AND amount > 0", arguments: [summary.savingsAccountId, pot.id])
            let giftBooked = Day(year: today.year, month: 1, day: 6)! <= cutoff
            #expect(received.count == (giftBooked ? 1 : 0))
            #expect(inPot.count == (giftBooked ? 1 : 0))
            if giftBooked {
                #expect(received[0].amount == gift && received[0].budgetItemId == nil)
                #expect(inPot[0].amount == gift)
                let out = try #require(try Entry.fetchOne(database, key: inPot[0].counterEntryId))
                #expect(out.accountId == summary.checkingAccountId && out.amount == -gift && out.budgetItemId == nil)
                #expect(out.counterEntryId == inPot[0].id)
            }

            // Elke rentebetaling is gemarkeerd met de pot; alleen de laatste staat nog open.
            let payments = try Entry.fetchAll(database, sql:
                "SELECT * FROM entry WHERE budgetItemId = ? ORDER BY day", arguments: [item.id])
            #expect(payments.allSatisfy { $0.reimburse && $0.potId == pot.id && $0.accountId == summary.checkingAccountId })
            let open = payments.filter { $0.savingsTransferId == nil }
            #expect(open.map(\.id) == Array(payments.suffix(1)).map(\.id))
            if today == testToday {
                #expect(payments.count == 5)
                #expect(open.map(\.day) == [Day(year: 2027, month: 5, day: 28)!])
            }

            // Saldo van de pot = schenking − vergoede maanden.
            let balance = try Money.fetchOne(database, sql:
                "SELECT COALESCE(SUM(amount), 0) FROM entry WHERE accountId = ? AND potId = ?",
                arguments: [summary.savingsAccountId, pot.id])!
            let reimbursed = payments.filter { $0.savingsTransferId != nil }.map(\.amount).sum()
            #expect(balance == (giftBooked ? gift : .zero) + reimbursed)
            #expect(balance >= .zero)

            // Eén afgeronde spaaroverboeking per maand, elk met de rente van de maand ervoor erin.
            let transfers = try SavingsTransfer.fetchAll(database, sql: "SELECT * FROM savingsTransfer ORDER BY day")
            #expect(Set(transfers.map(\.day.month)).count == transfers.count)
            #expect(transfers.allSatisfy { $0.done && $0.day.day == 27 && $0.day <= cutoff })

            // De regel herkent de tegenpartij en stelt vergoeden uit de pot voor.
            let rule = try #require(try Rule.filter(Column("name") == "Privélening").fetchOne(database))
            #expect(rule.reimburse && rule.targetPotId == pot.id && rule.targetItemLabel == "Privélening")
            #expect(rule.counterpartyContains == "Lening Familie Voorbeeld")
        }
    }

    /// Afgeronde verrekeningen met spaar zoals HFBudget ze maakt (`markDone`) en een latere import ze aanhangt
    /// (`attach`): boekingen "Verrekening #<id>" op beide rekeningen, met de bankregels eraan.
    @Test(arguments: demoDays)
    func settlementsHaveBankTransactionsOnBothSides(today: Day) throws {
        let (db, summary) = try seeded(today)
        try db.read { database in
            let transfers = try SavingsTransfer.fetchAll(database, sql: "SELECT * FROM savingsTransfer ORDER BY day, id")
            for transfer in transfers {
                #expect(transfer.done && transfer.doneAt != nil && transfer.amount > .zero)
                let id = transfer.id!
                let list = try #require(try Setting.get(database, "savingsTransfer.\(id).entries"))
                let ids = list.split(separator: ",").compactMap { Int64($0) }
                let booked = try Entry.fetchAll(database, sql:
                    "SELECT * FROM entry WHERE id IN (\(list)) ORDER BY id")
                #expect(booked.count == ids.count && !booked.isEmpty)
                #expect(booked.allSatisfy { $0.note == "Verrekening #\(id)" && $0.savingsTransferId == nil && $0.reviewed })
                // Er hangt niets anders onder dit nummer.
                #expect(try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM entry WHERE note = ?",
                                         arguments: ["Verrekening #\(id)"]) == booked.count)

                // Betaalkant: één diverse boeking van +netto; spaarkant: per pot een boeking, samen −netto.
                let checking = booked.filter { $0.accountId == summary.checkingAccountId }
                let savings = booked.filter { $0.accountId == summary.savingsAccountId }
                #expect(checking.count == 1 && checking[0].amount == transfer.amount)
                #expect(checking[0].label == "Verrekening spaar" && checking[0].budgetItemId == nil && !checking[0].reimburse)
                #expect(savings.map(\.amount).sum() == -transfer.amount)
                #expect(savings.allSatisfy { $0.potId != nil && $0.amount.isNegative && $0.counterEntryId == checking[0].id })
                #expect(Set(savings.compactMap(\.potId)).count == savings.count)
                #expect(savings.map(\.id).contains(checking[0].counterEntryId))
                // De gemarkeerde uitgaven zijn samen het bedrag van de verrekening.
                let marked = try Money.fetchOne(database, sql:
                    "SELECT COALESCE(SUM(amount), 0) FROM entry WHERE savingsTransferId = ?", arguments: [id])!
                #expect(-marked == transfer.amount)

                // Aan beide kanten een bankregel, met de eigen andere rekening als tegenrekening.
                let checkingTx = try #require(try BankTransaction.fetchOne(database, key: checking[0].bankTransactionId))
                #expect(checkingTx.status == .verwerkt && checkingTx.amount == transfer.amount)
                #expect(checkingTx.counterpartyIban == DemoPlan.savingsIban && checkingTx.day == checking[0].day)
                #expect(checkingTx.day == transfer.day && checkingTx.accountId == summary.checkingAccountId)
                #expect(Set(savings.compactMap(\.bankTransactionId)).count == 1)
                let savingsTx = try #require(try BankTransaction.fetchOne(database, key: savings[0].bankTransactionId))
                #expect(savingsTx.status == .verwerkt && savingsTx.amount == -transfer.amount)
                #expect(savingsTx.counterpartyIban == DemoPlan.checkingIban && savingsTx.accountId == summary.savingsAccountId)
                #expect(savings.allSatisfy { $0.day == savingsTx.day })
            }
            #expect(transfers.count >= (today.month > 3 ? 3 : 0))

            // Zoals `SavingsTransferService.unconfirmed`: niets afgevinkts zonder bankregel na 5 dagen.
            var unconfirmed = 0
            for transfer in transfers {
                let list = try Setting.get(database, "savingsTransfer.\(transfer.id!).entries") ?? ""
                let open = try Entry.fetchAll(database, sql:
                    "SELECT * FROM entry WHERE id IN (\(list)) AND bankTransactionId IS NULL")
                if let bookedOn = open.map(\.day).min(), bookedOn.adding(days: 5) <= today { unconfirmed += 1 }
            }
            #expect(unconfirmed == 0)
            // En zoals het Dashboard het ziet: geen afgevinkte verrekening waarvan een kant geen bankregel heeft.
            #expect(try Int.fetchOne(database, sql: """
                SELECT COUNT(*) FROM savingsTransfer t WHERE t.done = 1 AND (
                    SELECT COUNT(*) FROM entry e WHERE e.note = 'Verrekening #' || t.id AND e.bankTransactionId IS NULL) > 0
                """) == 0)
        }
    }

    @Test func seedingTwiceRefuses() throws {
        let (db, _) = try seeded(testToday)
        let before = try dump(db)
        #expect(throws: DemoDataError.databaseNotEmpty) { try DemoData.seed(into: db, today: testToday) }
        #expect(try dump(db) == before)
        #expect(DemoDataError.databaseNotEmpty.localizedDescription.contains("lege database"))
    }

    @Test func sameTodayGivesIdenticalData() throws {
        let (first, firstSummary) = try seeded(testToday)
        let (second, secondSummary) = try seeded(testToday)
        #expect(firstSummary == secondSummary)
        #expect(try dump(first) == dump(second))
        #expect(DemoData.sampleCSV(today: testToday) == DemoData.sampleCSV(today: testToday))
        // Een latere dag verandert het verleden niet: de oude banktransacties blijven gelijk.
        let (later, _) = try seeded(testToday.adding(days: 30))
        let cutoff = testToday.adding(days: -10)
        func history(_ db: AppDatabase) throws -> [String] {
            try db.read { database in
                try Row.fetchAll(database, sql: """
                    SELECT accountId, day, amount, balanceBefore, counterpartyName, sequence FROM bankTransaction
                    WHERE day <= ? AND NOT (counterpartyName = 'Waterbedrijf Voorbeeld') ORDER BY id
                    """, arguments: [cutoff]).map(\.description)
            }
        }
        #expect(try history(first).count > 100)
        #expect(try history(first).count == history(later).count)
    }

    @Test func contentsMatchTheBrief() throws {
        let (db, summary) = try seeded(testToday)
        try db.read { database in
            let accounts = try Account.fetchAll(database)
            #expect(accounts.map(\.kind) == [.betaal, .spaar])
            #expect(accounts.allSatisfy { $0.iban?.hasPrefix("NL00TEST") == true })
            #expect(accounts.allSatisfy { $0.openingDate == Day(year: 2027, month: 1, day: 1) })

            let year = try BudgetYear.fetchOne(database)!
            #expect(year.year == 2027)
            #expect(year.antiRood == Money(euros: 4_500))
            #expect(year.reserveBase == .zero)

            let items = try BudgetItem.fetchAll(database)
            #expect(items.count == summary.budgetItemCount)
            let res = items.filter { $0.direction == .RES }
            // 20 reserveringspotten, plus kleedgeld en zakgeld per kind en het spaardoel studie en rijbewijs.
            #expect(res.count == 25)
            #expect(res.count == DemoPlan.reserveLines.count)
            #expect(res.allSatisfy { $0.potId != nil && $0.planAmount.isNegative })
            let total = items.filter(\.isReserveTotal)
            #expect(total.count == 1)
            #expect(total[0].planAmount == res.map(\.planAmount).sum())
            #expect(items.filter { $0.direction != .RES }.count >= 15)
            #expect(items.contains { $0.frequency == .kwartaal && $0.expectedMonths == "1,4,7,10" })
            #expect(items.filter { $0.reducesReserve }.isEmpty)
            #expect(items.filter { $0.direction == .IN }.allSatisfy { !$0.planAmount.isNegative })
            #expect(items.filter { $0.direction == .UIT }.allSatisfy { $0.planAmount.isNegative })

            let pots = try Pot.fetchAll(database)
            #expect(pots.filter { $0.kind == .reservering }.count == 21)
            let resPots = Set(res.compactMap(\.potId))
            #expect(pots.filter { resPots.contains($0.id!) }.map(\.monthlyAmount).sum() == -total[0].planAmount)
            #expect(Set(pots.filter { $0.kind == .spaar }.compactMap(\.owner)) == ["Kind 1", "Kind 2", "Ouder 1", "Ouder 2"])
            // Spaardoelen: spaargeld per kind, de doelen per ouder, de buffer en studie en rijbewijs; kleed- en
            // zakgeld hebben geen doel.
            let goals = pots.filter { $0.targetAmount != nil }.map(\.name)
            #expect(goals == ["Spaargeld Kind 1", "Spaargeld Kind 2", "Studie Ouder 1", "Nieuwe fiets Ouder 2",
                              "Buffer gezin", "Studie en rijbewijs"])

            #expect(try Tag.fetchAll(database).map(\.name) == ["Tanken", "Uit eten", "Cadeau", "Vakantie",
                                                                "Rijbewijs Kind 1", "Rijbewijs Kind 2"])
            #expect(try Rule.fetchCount(database) > 30)
            #expect(try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM rule WHERE hitCount > 0")! > 20)

            // Tags op tanken en uit eten.
            for tag in ["Tanken", "Uit eten"] {
                #expect(try Int.fetchOne(database, sql: """
                    SELECT COUNT(*) FROM entryTag et JOIN tag t ON t.id = et.tagId WHERE t.name = ?
                    """, arguments: [tag])! >= 3)
            }
            // Vergoedingen: deels in een afgeronde spaaroverboeking, deels open.
            let transfers = try SavingsTransfer.fetchAll(database)
            #expect(!transfers.isEmpty)
            #expect(transfers.allSatisfy { $0.done })
            for transfer in transfers {
                let covered = try Money.fetchOne(database, sql:
                    "SELECT COALESCE(SUM(amount), 0) FROM entry WHERE savingsTransferId = ?", arguments: [transfer.id])!
                #expect(-covered == transfer.amount)
            }
            #expect(try Int.fetchOne(database, sql:
                "SELECT COUNT(*) FROM entry WHERE reimburse AND savingsTransferId IS NULL")! >= 1)
            #expect(try Int.fetchOne(database, sql:
                "SELECT COUNT(*) FROM entry WHERE reimburse AND (amount >= 0 OR potId IS NULL)") == 0)

            // Maandelijkse reservering: verdeeld over de potten en gekoppeld aan de betaalkant.
            let reserveEntries = try Entry.fetchAll(database, sql:
                "SELECT * FROM entry WHERE budgetItemId = ? ORDER BY day", arguments: [total[0].id])
            #expect(reserveEntries.count == 5)
            for entry in reserveEntries {
                let counter = try Entry.fetchAll(database, sql:
                    "SELECT * FROM entry WHERE counterEntryId = ?", arguments: [entry.id])
                #expect(counter.count == 25)
                #expect(counter.map(\.amount).sum() == -entry.amount)
                #expect(counter.allSatisfy { $0.accountId == summary.savingsAccountId && $0.potId != nil })
                #expect(counter.contains { $0.id == entry.counterEntryId })
            }
            // RES-regels krijgen geen boekingen op de betaalrekening.
            #expect(try Int.fetchOne(database, sql: """
                SELECT COUNT(*) FROM entry e JOIN budgetItem i ON i.id = e.budgetItemId WHERE i.direction = 'RES'
                """) == 0)
            // Tekens kloppen met de richting van de post.
            #expect(try Int.fetchOne(database, sql: """
                SELECT COUNT(*) FROM entry e JOIN budgetItem i ON i.id = e.budgetItemId
                WHERE (i.direction = 'IN' AND e.amount < 0) OR (i.direction = 'UIT' AND e.amount > 0)
                """) == 0)

            // Afwijking van het plan en één ontbrekende betaling ("te laat").
            #expect(try Int.fetchOne(database, sql: """
                SELECT COUNT(*) FROM entry e JOIN budgetItem i ON i.id = e.budgetItemId
                WHERE i.label = 'Energie' AND e.amount <> i.planAmount
                """) == 1)
            let waterMonths = try Int.fetchAll(database, sql: """
                SELECT CAST(substr(e.day, 6, 2) AS INTEGER) FROM entry e JOIN budgetItem i ON i.id = e.budgetItemId
                WHERE i.label = 'Water' ORDER BY e.day
                """)
            #expect(waterMonths == [1, 2, 3, 4])
            #expect(try Int.fetchOne(database, sql:
                "SELECT COUNT(*) FROM bankTransaction WHERE counterpartyName = 'Waterbedrijf Voorbeeld' AND day LIKE '2027-05%'") == 0)

            // Werk voor de review: nieuwe transacties en geboekte boekingen die nog nagekeken moeten worden.
            #expect(summary.newTransactionCount >= 3)
            let unreviewed = try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM entry WHERE NOT reviewed")!
            #expect((3...12).contains(unreviewed))
            #expect(summary.bankTransactionCount == (try BankTransaction.fetchCount(database)))
            #expect(summary.entryCount == (try Entry.fetchCount(database)))
            #expect(summary.bookedThrough == Day(year: 2027, month: 6, day: 8))

            // Elke batch klopt met zijn transacties.
            for batch in try ImportBatch.fetchAll(database) {
                #expect(try BankTransaction.filter(Column("batchId") == batch.id).fetchCount(database) == batch.rowCount)
            }
            #expect(try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM bankTransaction WHERE batchId IS NULL") == 0)
            // Alles verzonnen: alleen test-IBAN's.
            #expect(try Int.fetchOne(database, sql:
                "SELECT COUNT(*) FROM bankTransaction WHERE counterpartyIban NOT LIKE 'NL00TEST%'") == 0)
        }
    }

    @Test(arguments: demoDays)
    func sampleCSVContinuesTheSeededBalance(today: Day) throws {
        let (db, summary) = try seeded(today, leaveRecentForImport: true)
        let csv = DemoData.sampleCSV(today: today)
        let rows = csv.split(separator: "\n").map { $0.split(separator: ",", omittingEmptySubsequences: false).map(String.init) }
        #expect(!rows.isEmpty)
        #expect(csv.hasSuffix("\n"))

        // De betaalrekening heeft geen nieuwe transacties; die komen uit het bestand.
        let pendingOnChecking = try db.read { database in
            try Int.fetchOne(database, sql:
                "SELECT COUNT(*) FROM bankTransaction WHERE accountId = ? AND status = 'nieuw'",
                arguments: [summary.checkingAccountId])
        }
        #expect(pendingOnChecking == 0)
        var balance = summary.checkingBalance
        let cutoff = today.adding(days: -10)
        var sequences = Set<String>()
        for row in rows {
            #expect(row.count == 19)
            let day = try #require(Day(dutch: row[0]))
            #expect(day > cutoff && day <= today)
            #expect(row[1] == DemoData.checkingIban)
            #expect(row[2].hasPrefix("NL00TEST"))
            #expect(!row[3].isEmpty)
            #expect(row[7] == "EUR" && row[9] == "EUR")
            #expect(Money(parsing: row[8]) == balance)
            let amount = try #require(Money(parsing: row[10]))
            #expect(!amount.isZero)
            balance += amount
            #expect(row[11] == row[0] && row[12] == row[0])
            #expect(sequences.insert(row[15]).inserted)
            #expect(!row[17].isEmpty)
        }

        // Zonder de optie staan precies dezelfde regels als `nieuw` in de database.
        let (full, fullSummary) = try seeded(today)
        try full.read { database in
            let pending = try BankTransaction.fetchAll(database, sql:
                "SELECT * FROM bankTransaction WHERE accountId = ? AND status = 'nieuw' ORDER BY id",
                arguments: [fullSummary.checkingAccountId])
            #expect(pending.map(\.sequence) == rows.map { $0[15] })
            #expect(pending.map(\.amount) == rows.map { Money(parsing: $0[10])! })
            #expect(pending.first?.balanceBefore == summary.checkingBalance)
        }
        #expect(fullSummary.checkingBalance == summary.checkingBalance)
    }

    @Test func generatorIsDeterministic() {
        var a = SeededGenerator(seed: 42), b = SeededGenerator(seed: 42), c = SeededGenerator(seed: 43)
        let first = (0..<20).map { _ in a.int(1...1_000) }
        #expect(first == (0..<20).map { _ in b.int(1...1_000) })
        #expect(first != (0..<20).map { _ in c.int(1...1_000) })
        #expect(first.allSatisfy { (1...1_000).contains($0) })
    }
}

/// Wat de gebruiker zelf ook heeft ingericht: potten per kind, een spaardoel uit onderdelen met een tag per kind,
/// vaste stortingen en de pot voor de rente op de privélening met een vooruitblik.
@Suite struct DemoDataPotsTests {
    @Test(arguments: demoDays)
    func everyChildHasSavingsClothingAndPocketMoney(today: Day) throws {
        let (db, summary) = try seeded(today)
        try db.read { database in
            for child in ["Kind 1", "Kind 2"] {
                let pots = try Pot.filter(Column("owner") == child).order(Column("sortOrder")).fetchAll(database)
                #expect(pots.map(\.name) == ["Spaargeld \(child)", "Kleedgeld \(child)", "Zakgeld \(child)"])
                #expect(pots.allSatisfy { $0.kind == .spaar && $0.accountId == summary.savingsAccountId && $0.monthlyAmount > .zero })
                // Zakgeld en kleding van dit kind gaan van de betaalrekening en worden vergoed uit zijn eigen pot.
                for (label, pot) in [("Zakgeld \(child)", pots[2]), ("Kleding \(child)", pots[1])] {
                    let entries = try Entry.filter(Column("label") == label).fetchAll(database)
                    #expect(entries.allSatisfy { $0.accountId == summary.checkingAccountId && $0.reimburse
                                                 && $0.potId == pot.id && $0.amount.isNegative && $0.budgetItemId == nil })
                    if today >= Day(year: today.year, month: 3, day: 15)! { #expect(!entries.isEmpty, "\(label)") }
                }
            }
            // De regel voor het zakgeld stelt vergoeden uit de pot van het kind voor.
            let rule = try #require(try Rule.filter(Column("name") == "Zakgeld Kind 1").fetchOne(database))
            let pot = try #require(try Pot.filter(Column("name") == "Zakgeld Kind 1").fetchOne(database))
            #expect(rule.reimburse && rule.targetPotId == pot.id)
        }
    }

    @Test(arguments: demoDays)
    func goalIsBuiltFromPartsWithATagPerChild(today: Day) throws {
        let (db, summary) = try seeded(today)
        try db.read { database in
            let pot = try #require(try Pot.filter(Column("name") == "Studie en rijbewijs").fetchOne(database))
            let parts = try GoalPart.filter(Column("potId") == pot.id).order(Column("sortOrder")).fetchAll(database)
            #expect(parts.count == 4)
            #expect(parts.map(\.label).contains("Rijlessen Kind 1") && parts.map(\.label).contains("Rijlessen Kind 2"))
            #expect(pot.targetAmount == parts.map(\.amount).sum())
            #expect(pot.targetDate == Day(year: today.year + 1, month: 8, day: 31))
            #expect(pot.owner == nil && pot.kind == .spaar)

            // Rijlessen en examen: van de betaalrekening, vergoed uit deze pot, met de tag van het kind.
            for child in ["Kind 1", "Kind 2"] {
                let tag = try #require(try Tag.filter(Column("name") == "Rijbewijs \(child)").fetchOne(database))
                let tagged = try Entry.fetchAll(database, sql: """
                    SELECT e.* FROM entry e JOIN entryTag et ON et.entryId = e.id WHERE et.tagId = ? ORDER BY e.day
                    """, arguments: [tag.id])
                #expect(tagged.allSatisfy { $0.potId == pot.id && $0.reimburse && $0.accountId == summary.checkingAccountId
                                            && $0.label.hasSuffix(child) })
                let rule = try #require(try Rule.filter(Column("name") == "Rijles \(child)").fetchOne(database))
                #expect(rule.descriptionContains == child && rule.targetPotId == pot.id && rule.reimburse)
                #expect(rule.tagIds == String(tag.id!))
                if today == testToday {
                    // Kind 1 heeft om de twee weken rijles sinds 4 februari en deed theorie-examen; Kind 2 sinds 11 mei.
                    #expect(tagged.count == (child == "Kind 1" ? 10 : 3))
                }
            }
        }
    }

    @Test(arguments: demoDays)
    func fixedDepositsMatchTheirItems(today: Day) throws {
        let (db, summary) = try seeded(today)
        try db.read { database in
            let distributions = try Distribution.order(Column("sortOrder")).fetchAll(database)
            #expect(distributions.map(\.name) == ["Maandelijkse reserveringen", "Sparen Kind 1", "Sparen Kind 2", "Sparen buffer"])
            for distribution in distributions {
                #expect(distribution.accountId == summary.savingsAccountId)
                #expect(distribution.sourceAccountId == summary.checkingAccountId)
                let lines = try DistributionLine.filter(Column("distributionId") == distribution.id).fetchAll(database)
                let item = try #require(try BudgetItem.filter(Column("distributionId") == distribution.id).fetchOne(database))
                #expect(item.planAmount == -lines.map(\.amount).sum())
            }
            // De verdeling van RESERVERINGEN is precies die van de RES-regels.
            let reserve = try #require(try BudgetItem.filter(Column("isReserveTotal") == true).fetchOne(database))
            let lines = try DistributionLine.filter(Column("distributionId") == reserve.distributionId).fetchAll(database)
            let res = try BudgetItem.filter(Column("direction") == Direction.RES.rawValue).fetchAll(database)
            #expect(Dictionary(uniqueKeysWithValues: lines.map { ($0.potId, $0.amount) })
                    == Dictionary(uniqueKeysWithValues: res.map { ($0.potId!, -$0.planAmount) }))
        }
    }

    @Test(arguments: demoDays)
    func interestPotLooksAhead(today: Day) throws {
        let (db, _) = try seeded(today)
        try db.read { database in
            let pot = try #require(try Pot.filter(Column("name") == "Rente privélening").fetchOne(database))
            let expected = try ForecastItem.filter(Column("potId") == pot.id).order(Column("day")).fetchAll(database)
            #expect(expected.allSatisfy { $0.day > today && !$0.isRealized })
            let gift = try #require(expected.last)
            #expect(gift.day == Day(year: today.year + 1, month: 1, day: 5) && gift.amount == Money(euros: 3_000))
            #expect(expected.dropLast().allSatisfy {
                $0.amount == Money(euros: -250) && $0.day.day == 28 && $0.day.year == today.year
            })
            // Op 18 juni: de rente van juni t/m december en de schenking van volgend jaar.
            if today == testToday { #expect(expected.count == 8) }
        }
    }
}

/// De app vult een bestaande voorbeelddatabase opnieuw zodra de voorbeelddata een nieuwe versie heeft.
@Suite struct DemoDatabaseFileTests {
    @Test func oldDemoDataIsReplacedAndCurrentDataKept() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("hf-demo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("voorbeeld.sqlite")

        // Eerste keer: gevuld, met de versie erbij.
        var db: AppDatabase? = try DemoData.openDemo(at: url, today: testToday)
        let pots = try db!.read { try Pot.fetchCount($0) }
        #expect(pots == DemoPlan.pots.count)
        let version = try db!.read { try Setting.get($0, DemoData.versionKey) }
        #expect(version == String(DemoData.version))

        // Zelfde versie: niets opnieuw; wat de gebruiker in het voorbeeld deed blijft staan.
        try db!.write { try $0.execute(sql: "UPDATE pot SET name = 'Uitgeprobeerd' WHERE id = 1") }
        db = nil
        db = try DemoData.openDemo(at: url, today: testToday)
        let kept = try db!.read { try String.fetchOne($0, sql: "SELECT name FROM pot WHERE id = 1") }
        #expect(kept == "Uitgeprobeerd")

        // Oudere versie: het bestand wordt leeggemaakt en opnieuw gevuld.
        try db!.write { try Setting.set($0, DemoData.versionKey, "1") }
        db = nil
        db = try DemoData.openDemo(at: url, today: testToday)
        try db!.read { database throws in
            #expect(try Pot.fetchCount(database) == DemoPlan.pots.count)
            #expect(try Pot.filter(Column("name") == "Uitgeprobeerd").fetchCount(database) == 0)
            #expect(try Account.fetchCount(database) == 2)
            #expect(try Setting.get(database, DemoData.versionKey) == String(DemoData.version))
        }
    }
}
