import Testing
import Foundation
import GRDB
import HFCore
import HFImport
import HFRules
import HFBudget
import HFInsight
import HFBackup
import HFPublish

/// De voorbeeldzip (6m) zoals de gebruiker hem in de voorbeeldmodus importeert: beide rekeningen, foutloos, de
/// voorstellen laten 6b, 6e, 6f, 6j en de herkende verrekening zien, en na het boeken sluit alles.
@Suite struct DemoArchiveTests {
    let today = Day(iso: "2027-06-18")!

    @Test func sampleArchiveImportsAndCloses() throws {
        let db = try AppDatabase.inMemory()
        let summary = try DemoData.seed(into: db, today: today, leaveRecentForImport: true)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("hf-demozip-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = try DemoData.writeSampleArchive(today: today, to: folder)
        let importer = BankImporter(database: db)

        // 1. Voorbeeld: twee bestanden, elk bij zijn rekening, foutloos, keten sluit op het saldo in de app.
        let archive = try importer.previewArchive(url: url)
        #expect(archive.items.count == 2 && archive.skippedItems.isEmpty)
        #expect(archive.canCommit && archive.errorCount == 0 && archive.duplicateCount == 0)
        for item in archive.importableItems {
            let preview = try #require(item.preview)
            #expect(preview.chainOK == true && preview.warnings.isEmpty, "\(item.fileName)")
            let accountId = try #require(item.account?.id)
            let balance = try db.read { try Insight.balance($0, accountId: accountId, on: today) }
            #expect(preview.openingBalance == balance, "\(item.fileName)")
        }
        #expect(Set(archive.importableItems.compactMap(\.account?.id)) == [summary.checkingAccountId, summary.savingsAccountId])

        // 2. Importeren; dezelfde zip nog eens geeft niets nieuws.
        let results = try importer.commitArchive(archive)
        #expect(results.count == 2)
        #expect(try importer.previewArchive(url: url).newCount == 0)
        let transactions = results.flatMap(\.result.transactions)
        let checking = transactions.filter { $0.accountId == summary.checkingAccountId }
        let savings = transactions.filter { $0.accountId == summary.savingsAccountId }

        try db.read { d in
            let suggestions = try RuleEngine.suggestAll(d)
            // 6f: zakgeld naar een kind wordt verrekend met zijn zakgeldpot; geld van datzelfde kind erin niet.
            let pocketPot = try #require(try Pot.filter(Column("name") == "Zakgeld Kind 1").fetchOne(d)?.id)
            let pocket = try #require(checking.first { $0.counterpartyIban == "NL00TEST0000000021" && $0.amount.isNegative })
            #expect(suggestions[pocket.id!]?.reimburse == true && suggestions[pocket.id!]?.potId == pocketPot)
            let refund = try #require(checking.first { $0.counterpartyIban == "NL00TEST0000000021" && $0.amount > .zero })
            #expect(suggestions[refund.id!]?.reimburse == false && suggestions[refund.id!]?.potId == nil)
            #expect(suggestions[refund.id!]?.confidence == .laag)
            // 6b: de eigen tekst van een overboeking; 6j: een nette naam bij een rommelige pinbetaling.
            let babysitter = try #require(checking.first { $0.descriptionText == "Oppas zaterdag" })
            #expect(LabelCleaner.suggestedLabel(for: babysitter) == "Oppas zaterdag")
            let snack = try #require(checking.first { $0.counterpartyName.contains("FRIETKRAAM") })
            #expect(LabelCleaner.suggestedLabel(for: snack) == "Frietkraam Demo")
            // Tanken krijgt de tag via de regel (alleen op de betaalrekening).
            let fuelTag = try #require(try Tag.filter(Column("name") == "Tanken").fetchOne(d)?.id)
            for tx in checking where tx.counterpartyName.hasPrefix("Tankstation Demo") {
                #expect(suggestions[tx.id!]?.tagIds == [fuelTag])
            }
            #expect(savings.allSatisfy { suggestions[$0.id!]?.tagIds.isEmpty ?? true })

            // 6e: de losse overboeking naar spaar is niet de vaste storting.
            let extra = try #require(savings.first { $0.amount == Money(euros: 250) })
            let match = try DistributionService.recognize(d, bankTransaction: extra)
            #expect(match == nil || match?.looksSeparate == true)
        }

        // 3. De verrekening met spaar wordt aan beide kanten herkend: afvinken en aanhangen.
        let open = try #require(try db.read { try SavingsTransfer.filter(Column("done") == false).fetchOne($0) })
        let transferRows = try db.write { d -> [BankTransaction] in
            var rows: [BankTransaction] = []
            for tx in transactions {
                guard let match = try SavingsTransferService.recognize(d, bankTransaction: tx) else { continue }
                #expect(match.transfer?.id == open.id && match.needsMarkDone)
                rows.append(tx)
            }
            #expect(rows.count == 2)
            _ = try SavingsTransferService.markDone(d, savingsTransferId: open.id!, on: rows[0].day)
            for tx in rows { _ = try SavingsTransferService.attach(d, savingsTransferId: open.id!, bankTransactionId: tx.id!) }
            return rows
        }

        // 4. De rest boeken volgens het voorstel; de losse overboeking aan de spaarkant in de pot Vakantie.
        try db.write { d in
            let suggestions = try RuleEngine.suggestAll(d)
            let vacation = try Pot.filter(Column("name") == "Vakantie").fetchOne(d)!.id!
            let handled = Set(transferRows.compactMap(\.id))
            let requests = transactions.filter { !handled.contains($0.id!) }.map { t -> BookingRequest in
                let s = suggestions[t.id!]!
                let onSavings = t.accountId == summary.savingsAccountId
                let reimburse = !onSavings && s.reimburse && t.amount.isNegative
                return BookingRequest(bankTransactionId: t.id!, allocations: [
                    Allocation(amount: t.amount, label: s.label.isEmpty ? LabelCleaner.suggestedLabel(for: t) : s.label,
                               budgetItemId: s.amountDiffers ? nil : s.budgetItemId,
                               potId: onSavings ? vacation : (reimburse ? s.potId : nil), reimburse: reimburse,
                               tagIds: onSavings ? [] : s.tagIds, ruleId: s.ruleId, confidence: s.confidence,
                               reviewed: false),
                ])
            }
            _ = try BookingService.bookAll(d, requests)
        }

        // 5. Controle na de import: niets meer open en het saldo sluit op het eindsaldo van elk bestand.
        for result in results {
            let check = try db.read { try BalanceService.importCheck($0, batchId: result.result.batch.id!) }
            #expect(check.newCount == 0, "\(result.fileName)")
            #expect(check.balanceMatches == true, "\(result.fileName): \(check.summary)")
        }
        let transfer = try db.read { try SavingsTransfer.fetchOne($0, key: open.id) }
        #expect(transfer?.done == true)
    }
}

/// Het telefoondashboard (6l) met de voorbeelddata en de instelling die de app er bij het vullen bij zet
/// (`DemoSupport.configurePhone`): potjes per kind, de gezamenlijke spaarpot met een vooruitblik die niet vlak is,
/// en Tanken als "komt nog terug".
@Suite struct DemoPhoneTests {
    @Test func phoneShowsChildrenSharedPotAndFuel() throws {
        let today = Day(iso: "2027-06-18")!
        let db = try AppDatabase.inMemory()
        _ = try DemoData.seed(into: db, today: today)
        let phone = try db.read { d -> PhoneSnapshot in
            let shared = try Int64.fetchOne(d, sql: "SELECT id FROM pot WHERE name = ?", arguments: [DemoData.sharedPotName])
            let options = PublishOptions(childOwners: DemoData.childOwners, sharedPotId: shared)
            return try PhoneDashboard.make(d, today: today, options: options)
        }
        #expect(phone.childPots.map(\.owner) == ["Kind 1", "Kind 2"])
        #expect(phone.childPots.allSatisfy { $0.pots.count == 3 })
        let shared = try #require(phone.sharedPot)
        #expect(shared.name == "Buffer gezin")
        #expect(shared.ahead.map(\.months) == [3, 6, 12])
        #expect(Set(shared.ahead.map(\.balance)).count == 3 && shared.ahead.allSatisfy { $0.balance != shared.balance })
        #expect(phone.budget?.returning.map(\.name) == ["Tanken"])
    }
}
