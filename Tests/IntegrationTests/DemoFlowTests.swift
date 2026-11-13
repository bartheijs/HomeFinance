import Testing
import Foundation
import GRDB
import HFCore
import HFImport
import HFRules
import HFBudget
import HFInsight
import HFBackup

/// De hele keten zoals een gebruiker hem doorloopt, op voorbeelddata:
/// voorbeeldbestand importeren → voorstellen → boeken → saldo sluit op het eindsaldo van het bestand.
@Suite struct DemoFlowTests {
    let today = Day(iso: "2027-06-18")!

    @Test func importSuggestBookAndReconcile() throws {
        let db = try AppDatabase.inMemory()
        let summary = try DemoData.seed(into: db, today: today, leaveRecentForImport: true)
        let csv = Data(DemoData.sampleCSV(today: today).utf8)
        let importer = BankImporter(database: db)

        // 1. Voorbeeld: herkend, foutloos, keten sluit en sluit aan op het saldo in de app.
        let preview = try importer.preview(data: csv, fileName: "voorbeeld.csv", accountId: summary.checkingAccountId)
        #expect(preview.profile.id == "asn")
        #expect(preview.errorCount == 0)
        #expect(preview.chainOK == true)
        #expect(preview.newCount > 0)
        #expect(preview.duplicateCount == 0)
        #expect(preview.warnings.isEmpty)
        let balanceBefore = try db.read { try Insight.balance($0, accountId: summary.checkingAccountId, on: today) }
        #expect(preview.openingBalance == balanceBefore)

        // 2. Importeren; nog een keer importeren doet niets.
        let result = try importer.commit(preview)
        #expect(result.transactions.count == preview.newCount)
        let again = try importer.preview(data: csv, fileName: "voorbeeld.csv", accountId: summary.checkingAccountId)
        #expect(again.newCount == 0)

        // 3. Voorstellen: de regels uit de voorbeelddata herkennen het grootste deel.
        let suggestions = try db.read { try RuleEngine.suggestAll($0, accountId: summary.checkingAccountId) }
        #expect(suggestions.count == result.transactions.count)
        let known = suggestions.values.filter { $0.confidence != .geen }.count
        #expect(known * 2 >= suggestions.count, "minstens de helft krijgt een voorstel (\(known)/\(suggestions.count))")

        // 4. Alles boeken volgens het voorstel (zonder voorstel: divers).
        try db.write { d in
            let requests = result.transactions.map { t -> BookingRequest in
                let s = suggestions[t.id!]!
                // Vergoeden kan alleen bij een uitgave; een pot op de betaalrekening alleen samen met vergoeden.
                let reimburse = s.reimburse && t.amount.isNegative
                return BookingRequest(bankTransactionId: t.id!, allocations: [
                    Allocation(amount: t.amount, label: s.label, budgetItemId: s.budgetItemId,
                               potId: reimburse ? s.potId : nil, reimburse: reimburse, tagIds: s.tagIds,
                               ruleId: s.ruleId, confidence: s.confidence, reviewed: false),
                ])
            }
            _ = try BookingService.bookAll(d, requests)
        }

        // 5. Controle na import: niets meer open, berekend saldo = eindsaldo van het bestand.
        let check = try db.read { try BalanceService.importCheck($0, batchId: result.batch.id!) }
        #expect(check.newCount == 0)
        #expect(check.balanceMatches == true, "\(check.summary)")
        let balanceAfter = try db.read { try Insight.balance($0, accountId: summary.checkingAccountId, on: today) }
        #expect(balanceAfter == preview.closingBalance)

        // 6. De schermcijfers zijn te berekenen.
        try db.read { d in
            let dash = try Insight.dashboard(d, today: today)
            #expect(dash.spendable != nil)
            let grid = try Insight.monthGrid(d, year: today.year, today: today)
            #expect(!grid.rows.isEmpty)
            let pots = try Insight.potOverview(d, accountId: nil, today: today)
            #expect(!pots.accounts.isEmpty)
        }
    }

    @Test func backupAndRestoreKeepEverything() throws {
        let db = try AppDatabase.inMemory()
        _ = try DemoData.seed(into: db, today: today)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("hf-it-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let info = try Backup.createBackup(from: db, to: folder)
        #expect(info.isVerified)
        let before = try db.read { try Entry.fetchCount($0) }
        try db.write { try $0.execute(sql: "DELETE FROM entry WHERE bankTransactionId IS NULL") ; try $0.execute(sql: "UPDATE entry SET label = 'kapot'") }
        _ = try Backup.restore(from: info.url, into: db, safetyFolder: folder.appendingPathComponent("veilig"))
        #expect(try db.read { try Entry.fetchCount($0) } == before)
        #expect(try db.read { try Entry.filter(Column("label") == "kapot").fetchCount($0) } == 0)
    }
}
