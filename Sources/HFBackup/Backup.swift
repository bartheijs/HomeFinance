import Foundation
import GRDB
import HFCore

// Back-up en herstel van de HomeFinance-database.
//
// Een back-up is een consistente kopie, gemaakt met de online-backup-API van SQLite (via GRDB),
// nooit een gewone bestandskopie van een database die in gebruik is.

/// Fouten van back-up en herstel, met een Nederlandse melding voor de gebruiker.
public enum BackupError: Error, LocalizedError, Equatable, Sendable {
    /// Het bestand bestaat niet (meer).
    case fileNotFound(String)
    /// Het bestand is geen SQLite-database.
    case notADatabase(String)
    /// De database is beschadigd; `detail` is de melding van SQLite.
    case corrupt(file: String, detail: String)
    /// Wel een database, maar niet van HomeFinance.
    case notHomeFinance(String)
    /// Gemaakt met een nieuwere versie van de app (onbekende migraties).
    case newerVersion(file: String, unknownMigrations: [String])
    /// De map bestaat niet of is niet beschrijfbaar.
    case folderUnavailable(String)
    /// Herstellen is mislukt; de database is teruggezet naar de toestand van vóór het herstel.
    case restoreFailed(detail: String)
    /// Herstellen is mislukt en terugzetten ook; de veiligheidskopie staat op `safetyBackup`.
    case restoreFailedNotRolledBack(detail: String, safetyBackup: String)

    public var errorDescription: String? {
        switch self {
        case .fileNotFound(let file):
            return "Het bestand \(file) is niet gevonden."
        case .notADatabase(let file):
            return "\(file) is geen geldige HomeFinance-back-up: het bestand is geen database."
        case .corrupt(let file, let detail):
            return "\(file) is beschadigd en kan niet worden gebruikt (\(detail))."
        case .notHomeFinance(let file):
            return "\(file) is geen geldige HomeFinance-back-up: de tabellen van HomeFinance ontbreken."
        case .newerVersion(let file, _):
            return "\(file) is gemaakt met een nieuwere versie van HomeFinance. Werk de app bij en probeer het opnieuw."
        case .folderUnavailable(let folder):
            return "De map \(folder) bestaat niet of is niet beschrijfbaar."
        case .restoreFailed(let detail):
            return "Herstellen is mislukt (\(detail)). De database is ongewijzigd gebleven."
        case .restoreFailedNotRolledBack(let detail, let safetyBackup):
            return "Herstellen is mislukt (\(detail)) en de oude gegevens konden niet worden teruggezet. "
                + "De veiligheidskopie staat in \(safetyBackup)."
        }
    }
}

/// Aantallen in de hoofdtabellen van een database of back-up.
public struct BackupCounts: Equatable, Sendable {
    public var accounts: Int
    public var years: Int
    public var entries: Int
    public var bankTransactions: Int

    public init(accounts: Int = 0, years: Int = 0, entries: Int = 0, bankTransactions: Int = 0) {
        self.accounts = accounts; self.years = years; self.entries = entries; self.bankTransactions = bankTransactions
    }
}

/// Soort back-upbestand.
public enum BackupKind: String, Equatable, Sendable {
    /// Gewone back-up (`HomeFinance-yyyyMMdd-HHmmss.sqlite`); valt onder het opruimen.
    case regular
    /// Veiligheidskopie van vlak vóór een herstel (`HomeFinance-voor-herstel-…`); wordt nooit opgeruimd.
    case safety
}

/// Beschrijving van één back-upbestand.
public struct BackupInfo: Equatable, Sendable, Identifiable {
    public var url: URL
    /// Moment van de back-up (uit de bestandsnaam; anders de wijzigingsdatum van het bestand).
    public var date: Date
    /// Grootte in bytes.
    public var size: Int64
    public var kind: BackupKind
    public var counts: BackupCounts
    /// Eerste en laatste dag met een boeking, of nil als er geen boekingen zijn.
    public var firstEntryDay: Day?
    public var lastEntryDay: Day?
    /// Migraties die in de back-up zijn toegepast.
    public var appliedMigrations: [String]
    /// nil = gecontroleerd en in orde; anders de Nederlandse reden waarom het bestand niet bruikbaar is.
    public var problem: String?

    public var id: URL { url }
    /// De back-up is gecontroleerd en bruikbaar.
    public var isVerified: Bool { problem == nil }
    public var fileName: String { url.lastPathComponent }
}

/// Resultaat van een herstel.
public struct RestoreResult: Equatable, Sendable {
    /// De back-up die is teruggezet.
    public var restored: BackupInfo
    /// De veiligheidskopie van de database van vóór het herstel.
    public var safetyBackup: BackupInfo
    /// Migraties die na het terugzetten nog zijn uitgevoerd (leeg als de back-up al bij was).
    public var migrationsApplied: [String]
    /// Aantallen in de database na het herstel.
    public var counts: BackupCounts
}

/// Back-up maken, controleren, opruimen en herstellen.
public enum Backup {
    static let regularPrefix = "HomeFinance-"
    static let safetyPrefix = "HomeFinance-voor-herstel-"
    static let fileExtension = "sqlite"

    static let requiredTables = ["account", "budgetYear", "budgetItem", "pot", "importBatch", "bankTransaction",
                                 "entry", "tag", "entryTag", "rule", "reconciliation", "savingsTransfer", "setting"]

    // MARK: Maken

    /// Maakt een consistente back-up van de database in `folder` en controleert die.
    /// Bestandsnaam: `HomeFinance-yyyyMMdd-HHmmss.sqlite`. Legt het moment vast als laatste back-up.
    @discardableResult
    public static func createBackup(from db: AppDatabase, to folder: URL, now: Date = Date()) throws -> BackupInfo {
        let info = try writeBackup(from: db, to: folder, now: now, kind: .regular)
        try db.write { try BackupSettings.setLastBackup($0, now) }
        return info
    }

    static func writeBackup(from db: AppDatabase, to folder: URL, now: Date, kind: BackupKind) throws -> BackupInfo {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            throw BackupError.folderUnavailable(folder.path)
        }
        guard fm.isWritableFile(atPath: folder.path) else { throw BackupError.folderUnavailable(folder.path) }

        let prefix = kind == .safety ? safetyPrefix : regularPrefix
        let stamp = stampFormatter.string(from: now)
        var final = folder.appendingPathComponent("\(prefix)\(stamp).\(fileExtension)")
        var n = 2
        while fm.fileExists(atPath: final.path) {
            final = folder.appendingPathComponent("\(prefix)\(stamp)-\(n).\(fileExtension)")
            n += 1
        }
        // Eerst naar een tijdelijk bestand; pas na controle krijgt het zijn echte naam.
        let temp = folder.appendingPathComponent(".\(final.lastPathComponent).tmp")
        try? fm.removeItem(at: temp)
        do {
            let destination = try DatabaseQueue(path: temp.path)
            try db.writer.backup(to: destination)
            try destination.close()
            // Een bron in WAL-modus levert een kopie in WAL-modus op; maak er één los bestand van.
            // Dat kan pas met een nieuwe verbinding, die de kop van het bestand opnieuw leest.
            let converter = try DatabaseQueue(path: temp.path)
            try converter.writeWithoutTransaction { try $0.execute(sql: "PRAGMA journal_mode = DELETE") }
            try converter.close()
            _ = try inspect(temp)
            removeSidecars(of: temp)
            try fm.moveItem(at: temp, to: final)
        } catch {
            try? fm.removeItem(at: temp)
            removeSidecars(of: temp)
            throw error
        }
        var info = try verify(backupAt: final)
        info.date = now
        return info
    }

    // MARK: Controleren

    /// Controleert een back-upbestand: alleen-lezen openen, `PRAGMA integrity_check`, het schema van
    /// HomeFinance en een bekende migratie. Geeft aantallen en de periode van de boekingen terug.
    /// Gooit een `BackupError` met Nederlandse melding als het geen geldige back-up is.
    public static func verify(backupAt url: URL) throws -> BackupInfo {
        let inspection = try inspect(url)
        return BackupInfo(url: url, date: fileDate(url), size: fileSize(url), kind: kind(of: url),
                          counts: inspection.counts, firstEntryDay: inspection.firstDay,
                          lastEntryDay: inspection.lastDay, appliedMigrations: inspection.migrations, problem: nil)
    }

    struct Inspection {
        var counts: BackupCounts
        var firstDay: Day?
        var lastDay: Day?
        var migrations: [String]
    }

    static func inspect(_ url: URL) throws -> Inspection {
        let name = url.lastPathComponent
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw BackupError.fileNotFound(name)
        }
        var config = Configuration()
        config.readonly = true
        do {
            let queue = try DatabaseQueue(path: url.path, configuration: config)
            defer { try? queue.close() }
            return try queue.read { db in
                let check = try String.fetchAll(db, sql: "PRAGMA integrity_check")
                guard check == ["ok"] else {
                    throw BackupError.corrupt(file: name, detail: check.first ?? "onbekende fout")
                }
                for table in requiredTables + ["grdb_migrations"] {
                    guard try db.tableExists(table) else { throw BackupError.notHomeFinance(name) }
                }
                let applied = try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid")
                guard !applied.isEmpty else { throw BackupError.notHomeFinance(name) }
                let known = Set(AppDatabase.migrator.migrations)
                let unknown = applied.filter { !known.contains($0) }
                guard unknown.isEmpty else { throw BackupError.newerVersion(file: name, unknownMigrations: unknown) }
                let range = try Row.fetchOne(db, sql: "SELECT MIN(day) AS first, MAX(day) AS last FROM entry")
                return Inspection(counts: try counts(db), firstDay: range?["first"], lastDay: range?["last"],
                                  migrations: applied)
            }
        } catch let error as BackupError {
            throw error
        } catch let error as DatabaseError where error.resultCode == .SQLITE_NOTADB {
            throw BackupError.notADatabase(name)
        } catch let error as DatabaseError {
            throw BackupError.corrupt(file: name, detail: error.message ?? "SQLite-fout \(error.resultCode.rawValue)")
        } catch {
            throw BackupError.notADatabase(name)
        }
    }

    /// Aantallen in de hoofdtabellen van een geopende database.
    public static func counts(_ db: Database) throws -> BackupCounts {
        func count(_ table: String) throws -> Int {
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \"\(table)\"") ?? 0
        }
        return BackupCounts(accounts: try count("account"), years: try count("budgetYear"),
                            entries: try count("entry"), bankTransactions: try count("bankTransaction"))
    }

    // MARK: Lijst en opruimen

    /// Alle back-ups in een map, nieuwste eerst. Elk bestand wordt gecontroleerd; een onbruikbaar bestand
    /// staat in de lijst met `problem` gevuld. Een map die niet bestaat geeft een lege lijst.
    public static func listBackups(in folder: URL) -> [BackupInfo] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return urls
            .filter { $0.pathExtension == fileExtension && $0.lastPathComponent.hasPrefix(regularPrefix) }
            .map { url -> BackupInfo in
                do {
                    return try verify(backupAt: url)
                } catch {
                    return BackupInfo(url: url, date: fileDate(url), size: fileSize(url), kind: kind(of: url),
                                      counts: BackupCounts(), firstEntryDay: nil, lastEntryDay: nil,
                                      appliedMigrations: [], problem: error.localizedDescription)
                }
            }
            .sorted { ($0.date, $0.fileName) > ($1.date, $1.fileName) }
    }

    /// Ruimt oude back-ups op: bewaart de nieuwste `keep` gewone back-ups (minstens één) en verwijdert de rest.
    /// De enige gecontroleerde back-up wordt nooit verwijderd; veiligheidskopieën blijven altijd staan.
    /// Geeft de verwijderde bestanden terug.
    @discardableResult
    public static func prune(in folder: URL, keep: Int) throws -> [URL] {
        let regular = listBackups(in: folder).filter { $0.kind == .regular }
        let keepCount = max(keep, 1)
        guard regular.count > keepCount else { return [] }
        let kept = regular.prefix(keepCount)
        var candidates = Array(regular.dropFirst(keepCount))
        if !kept.contains(where: \.isVerified), let rescue = candidates.firstIndex(where: \.isVerified) {
            candidates.remove(at: rescue)
        }
        var removed: [URL] = []
        for backup in candidates {
            try FileManager.default.removeItem(at: backup.url)
            removed.append(backup.url)
        }
        return removed
    }

    // MARK: Herstellen

    /// Zet een back-up terug in de draaiende database, zonder bestanden te wisselen of de app te herstarten.
    ///
    /// Volgorde: back-up controleren, veiligheidskopie van de huidige database in `safetyFolder`, inhoud van de
    /// back-up via de backup-API in de database kopiëren, migraties uitvoeren. De back-upinstellingen van deze
    /// Mac (map, aantal, automatisch, laatste back-up) blijven behouden. Mislukt er iets, dan blijft de database
    /// zoals hij was. Laad na afloop de schermen opnieuw.
    @discardableResult
    public static func restore(from backup: URL, into db: AppDatabase, safetyFolder: URL,
                               now: Date = Date()) throws -> RestoreResult {
        try restore(from: backup, into: db, safetyFolder: safetyFolder, now: now, afterCopy: nil)
    }

    /// Als `restore`, met een haak voor tests om een fout ná het kopiëren na te bootsen.
    static func restore(from backup: URL, into db: AppDatabase, safetyFolder: URL, now: Date,
                        afterCopy: (() throws -> Void)?) throws -> RestoreResult {
        let info = try verify(backupAt: backup)
        let settings = try db.read { try BackupSettings.load($0) }
        let safety = try writeBackup(from: db, to: safetyFolder, now: now, kind: .safety)

        do {
            try copyContents(of: backup, into: db)
            try afterCopy?()
            try AppDatabase.migrator.migrate(db.writer)
            let counts = try db.write { database -> BackupCounts in
                try settings.save(database)
                try database.notifyChanges(in: .fullDatabase)
                return try Backup.counts(database)
            }
            let known = AppDatabase.migrator.migrations
            return RestoreResult(restored: info, safetyBackup: safety,
                                 migrationsApplied: known.filter { !info.appliedMigrations.contains($0) },
                                 counts: counts)
        } catch {
            let detail = error.localizedDescription
            do {
                try copyContents(of: safety.url, into: db)
                try? db.write { try $0.notifyChanges(in: .fullDatabase) }
            } catch {
                throw BackupError.restoreFailedNotRolledBack(detail: detail, safetyBackup: safety.url.path)
            }
            throw BackupError.restoreFailed(detail: detail)
        }
    }

    /// Kopieert de inhoud van een databasebestand in de draaiende database (bron = bestand, doel = de writer).
    private static func copyContents(of file: URL, into db: AppDatabase) throws {
        var config = Configuration()
        config.readonly = true
        let source = try DatabaseQueue(path: file.path, configuration: config)
        defer { try? source.close() }
        try source.backup(to: db.writer)
    }

    // MARK: Automatisch

    /// Is het tijd voor een back-up? Ja als er gegevens zijn en de laatste back-up ontbreekt of 7 dagen of
    /// langer geleden is.
    public static func isBackupDue(_ db: AppDatabase, now: Date = Date()) throws -> Bool {
        try db.read { database in
            guard try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM account") ?? 0 > 0 else { return false }
            guard let last = try BackupSettings.load(database).lastBackupAt else { return true }
            return now.timeIntervalSince(last) >= 7 * 24 * 3600
        }
    }

    /// Maakt een back-up in de ingestelde map en ruimt daarna op volgens het ingestelde aantal.
    /// Geeft nil terug als er geen back-upmap is ingesteld.
    @discardableResult
    public static func backupUsingSettings(_ db: AppDatabase, now: Date = Date()) throws -> BackupInfo? {
        let settings = try db.read { try BackupSettings.load($0) }
        guard let folder = settings.folderURL else { return nil }
        let info = try createBackup(from: db, to: folder, now: now)
        try prune(in: folder, keep: settings.keepCount)
        return info
    }

    // MARK: Hulp

    static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()

    /// Verwijdert eventuele hulpbestanden (-wal, -shm, -journal) van een tijdelijk databasebestand.
    static func removeSidecars(of url: URL) {
        for suffix in ["-wal", "-shm", "-journal"] {
            try? FileManager.default.removeItem(atPath: url.path + suffix)
        }
    }

    static func kind(of url: URL) -> BackupKind {
        url.lastPathComponent.hasPrefix(safetyPrefix) ? .safety : .regular
    }

    static func fileSize(_ url: URL) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }

    /// Moment uit de bestandsnaam, anders de wijzigingsdatum.
    static func fileDate(_ url: URL) -> Date {
        var name = url.deletingPathExtension().lastPathComponent
        for prefix in [safetyPrefix, regularPrefix] where name.hasPrefix(prefix) {
            name.removeFirst(prefix.count)
            break
        }
        if name.count >= 15, let date = stampFormatter.date(from: String(name.prefix(15))) { return date }
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.modificationDate] as? Date) ?? Date(timeIntervalSince1970: 0)
    }
}
