// Module HFImport — bank-CSV lezen, voorbeeld tonen en importeren. Zie docs/api/HFImport.md.
import Foundation
import GRDB
import HFCore

/// Wat er bij een import in de database is gezet.
public struct ImportResult: Equatable, Sendable {
    public var batch: ImportBatch
    /// De nieuwe banktransacties (status `nieuw`), van oud naar nieuw.
    public var transactions: [BankTransaction]
    /// Regels die al in de database stonden en zijn overgeslagen.
    public var duplicateCount: Int
    /// Regels van op of vóór de overgangsdag die niet zijn geïmporteerd.
    public var cutoverSkippedCount: Int = 0
    /// Foute regels die op verzoek zijn overgeslagen.
    public var skippedErrorCount: Int
}

/// Leest een bank-CSV voor één rekening en importeert hem als banktransacties.
public struct BankImporter: Sendable {
    public let database: AppDatabase

    public init(database: AppDatabase) { self.database = database }

    /// Leest het bestand en toont wat er geïmporteerd zou worden. Schrijft niets.
    /// Een PDF-rekeningafschrift wordt herkend aan de inhoud of de extensie; `profile` telt dan niet mee.
    /// Zonder `profile` wordt het profiel geraden; lukt dat niet, dan volgt `ImportError.noProfile`.
    /// Met `skipThrough` blijven regels van die dag of eerder buiten de import (zie `defaultSkipThrough`).
    /// Met `resumeFromBalance` (het saldo van de administratie) wordt eerst op saldo gezocht waar het bestand
    /// aansluit; zie `ImportPreview.seam`. Alleen nodig bij de eerste bankimport van een rekening (`needsSeam`).
    public func preview(data: Data, fileName: String, accountId: Int64, profile: BankProfile? = nil,
                        skipThrough: Day? = nil, resumeFromBalance: Money? = nil) throws -> ImportPreview {
        if PDFStatement.isPDF(data: data, fileName: fileName) {
            let statement = try StatementParser.parse(pages: PDFStatement.pages(of: data))
            return try database.read { db in
                guard let account = try Account.fetchOne(db, key: accountId) else { throw ImportError.accountNotFound }
                var preview = ImportPreview.build(statement: statement, fileName: fileName, account: account,
                                                  skipThrough: skipThrough, resumeFromBalance: resumeFromBalance,
                                                  hasExcelHistory: try Self.hasExcelHistory(db, accountId))
                try Self.markDuplicates(db, &preview)
                try Self.addSuggestion(db, &preview)
                return preview
            }
        }
        let file = try CSVFile(data: data)
        guard let profile = profile ?? BankProfile.detect(for: file) else {
            throw file.records.isEmpty ? ImportError.emptyFile : ImportError.noProfile
        }
        return try database.read { db in
            guard let account = try Account.fetchOne(db, key: accountId) else { throw ImportError.accountNotFound }
            var preview = try ImportPreview.build(file: file, fileName: fileName, account: account, profile: profile,
                                                  skipThrough: skipThrough, resumeFromBalance: resumeFromBalance,
                                                  hasExcelHistory: try Self.hasExcelHistory(db, accountId))
            try Self.markDuplicates(db, &preview)
            try Self.addSuggestion(db, &preview)
            return preview
        }
    }

    /// Als hierboven, voor een bestand op schijf.
    public func preview(url: URL, accountId: Int64, profile: BankProfile? = nil,
                        skipThrough: Day? = nil, resumeFromBalance: Money? = nil) throws -> ImportPreview {
        try preview(data: Data(contentsOf: url), fileName: url.lastPathComponent, accountId: accountId,
                    profile: profile, skipThrough: skipThrough, resumeFromBalance: resumeFromBalance)
    }

    /// De naad hoeft alleen gezocht te worden bij de eerste bankimport van een rekening: true zolang de
    /// rekening nog geen enkele banktransactie heeft, met of zonder Excel-historie. Daarna herkent de
    /// vingerafdruk wat al geïmporteerd is.
    public func needsSeam(accountId: Int64) throws -> Bool {
        try database.read { db in
            try Bool.fetchOne(db, sql: "SELECT NOT EXISTS (SELECT 1 FROM bankTransaction WHERE accountId = ?)",
                              arguments: [accountId]) ?? true
        }
    }

    /// Het saldo van de rekening in de app: beginsaldo plus alle boekingen (ook handmatige en Excel-historie).
    /// Geef dit door als `resumeFromBalance`, zodat elke aanroeper hetzelfde bedrag gebruikt.
    public func resumeBalance(accountId: Int64) throws -> Money {
        try database.read { db in
            guard let account = try Account.fetchOne(db, key: accountId) else { throw ImportError.accountNotFound }
            let entries = try Money.fetchOne(db, sql: "SELECT COALESCE(SUM(amount), 0) FROM entry WHERE accountId = ?",
                                             arguments: [accountId]) ?? .zero
            return account.openingBalance + entries
        }
    }

    /// De dag om als `skipThrough` (terugval op datum) te gebruiken: de laatste dag van de Excel-historie als
    /// die er is, anders de dag vóór de begindatum van de rekening (regels van vóór de start horen er niet in).
    public func defaultSkipThrough(accountId: Int64) throws -> Day {
        try database.read { db in
            guard let account = try Account.fetchOne(db, key: accountId) else { throw ImportError.accountNotFound }
            let history = try Day.fetchOne(db, sql: """
                SELECT MAX(day) FROM entry WHERE accountId = ? AND note = 'Excel-historie'
                """, arguments: [accountId])
            return history ?? account.openingDate.adding(days: -1)
        }
    }

    static func hasExcelHistory(_ db: Database, _ accountId: Int64) throws -> Bool {
        try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM entry WHERE accountId = ? AND note = 'Excel-historie')",
                          arguments: [accountId]) ?? false
    }

    /// De overgangsdag van een rekening: de laatste dag met een boeking uit de Excel-historie
    /// (`Entry.note == "Excel-historie"`), of nil als die er niet zijn. Geef hem door als `skipThrough`.
    public func historyCutover(accountId: Int64) throws -> Day? {
        try database.read { db in
            try Day.fetchOne(db, sql: "SELECT MAX(day) FROM entry WHERE accountId = ? AND note = 'Excel-historie'",
                             arguments: [accountId])
        }
    }

    /// Importeert een voorbeeld in één databasetransactie: een `ImportBatch` plus de nieuwe banktransacties
    /// met status `nieuw`. Dubbelen en regels van op of vóór de overgangsdag worden overgeslagen.
    /// Bij een fout wordt niets geïmporteerd.
    /// Bevat het voorbeeld foute regels, dan volgt `ImportError.rowErrors`, tenzij `skipFaultyRows` true is.
    @discardableResult
    public func commit(_ preview: ImportPreview, skipFaultyRows: Bool = false) throws -> ImportResult {
        if !preview.errors.isEmpty, !skipFaultyRows { throw ImportError.rowErrors(preview.errors.count) }
        guard !preview.rows.isEmpty else { throw ImportError.emptyFile }

        return try database.write { db in try Self.insert(db, preview) }
    }

    /// Zet één voorbeeld in de database; de aanroeper zorgt voor de transactie.
    static func insert(_ db: Database, _ preview: ImportPreview) throws -> ImportResult {
        do {
            guard try Account.exists(db, key: preview.accountId) else { throw ImportError.accountNotFound }
            // Opnieuw op dubbelen controleren: de database kan sinds het voorbeeld veranderd zijn.
            var current = preview
            try Self.markDuplicates(db, &current)

            var batch = ImportBatch(
                accountId: current.accountId, fileName: current.fileName, importedAt: Date(),
                rowCount: current.rowCount, newCount: current.newCount, duplicateCount: current.duplicateCount,
                firstDay: current.firstDay, lastDay: current.lastDay,
                openingBalance: current.openingBalance, closingBalance: current.closingBalance,
                chainOK: current.chainOK ?? true)
            try batch.insert(db)

            var inserted: [BankTransaction] = []
            for row in current.rowsChronological where !row.isDuplicate && !row.isBeforeCutover {
                var transaction = BankTransaction(
                    accountId: current.accountId, batchId: batch.id, day: row.day, amount: row.amount,
                    balanceBefore: row.balanceBefore, counterpartyName: row.counterpartyName,
                    counterpartyIban: row.counterpartyIban, descriptionText: row.descriptionText,
                    reference: row.reference, transactionCode: row.transactionCode, sequence: row.sequence,
                    fingerprint: row.fingerprint, status: .nieuw)
                try transaction.insert(db)
                inserted.append(transaction)
            }
            return ImportResult(batch: batch, transactions: inserted, duplicateCount: current.duplicateCount,
                                cutoverSkippedCount: current.cutoverSkippedCount,
                                skippedErrorCount: current.errors.count)
        }
    }

    /// Voorbeeld maken en meteen importeren.
    @discardableResult
    public func importFile(data: Data, fileName: String, accountId: Int64, profile: BankProfile? = nil,
                           skipThrough: Day? = nil, resumeFromBalance: Money? = nil,
                           skipFaultyRows: Bool = false) throws -> ImportResult {
        try commit(preview(data: data, fileName: fileName, accountId: accountId, profile: profile,
                           skipThrough: skipThrough, resumeFromBalance: resumeFromBalance),
                   skipFaultyRows: skipFaultyRows)
    }

    /// Als hierboven, voor een bestand op schijf.
    @discardableResult
    public func importFile(url: URL, accountId: Int64, profile: BankProfile? = nil,
                           skipThrough: Day? = nil, resumeFromBalance: Money? = nil,
                           skipFaultyRows: Bool = false) throws -> ImportResult {
        try commit(preview(url: url, accountId: accountId, profile: profile, skipThrough: skipThrough,
                           resumeFromBalance: resumeFromBalance), skipFaultyRows: skipFaultyRows)
    }

    /// Vult bij de waarschuwing "bestand is van een andere rekening" de rekening in waar het wel bij hoort.
    static func addSuggestion(_ db: Database, _ preview: inout ImportPreview) throws {
        guard let i = preview.warnings.firstIndex(where: { $0.kind == .ibanMismatch }) else { return }
        let match = try Self.match(db, fileName: preview.fileName, rows: preview.rows)
        guard let account = match.account, account.id != preview.accountId else { return }
        preview.warnings[i].suggestedAccount = account
        preview.warnings[i].message += " Het hoort bij rekening \(account.name)."
    }

    static func markDuplicates(_ db: Database, _ preview: inout ImportPreview) throws {
        guard let first = preview.firstDay, let last = preview.lastDay else { return }
        let existing = try Set(String.fetchAll(db, sql: """
            SELECT fingerprint FROM bankTransaction WHERE accountId = ? AND day BETWEEN ? AND ?
            """, arguments: [preview.accountId, first, last]))
        for i in preview.rows.indices {
            preview.rows[i].isDuplicate = existing.contains(preview.rows[i].fingerprint)
        }
    }
}
