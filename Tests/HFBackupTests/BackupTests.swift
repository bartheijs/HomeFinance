import Foundation
import GRDB
import HFCore
import Testing
@testable import HFBackup

/// Tijdelijke map die na de test weer verdwijnt.
final class TempFolder {
    let url: URL
    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("HFBackupTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: url) }
    func sub(_ name: String) -> URL { url.appendingPathComponent(name, isDirectory: true) }
}

let testToday = Day(year: 2027, month: 6, day: 18)!

func date(_ iso: String) -> Date {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = .current
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return f.date(from: iso)!
}

/// Kleine verzonnen database: één rekening met een paar boekingen.
func smallDatabase(_ db: AppDatabase, accountName: String = "Testrekening", entries: Int = 3) throws {
    try db.write { database in
        var account = Account(name: accountName, iban: "NL00TEST0000000001", kind: .betaal,
                              openingBalance: Money(euros: 100), openingDate: Day(year: 2027, month: 1, day: 1)!)
        try account.insert(database)
        var year = BudgetYear(year: 2027)
        try year.insert(database)
        for i in 0..<entries {
            var entry = Entry(accountId: account.id!, day: Day(year: 2027, month: 1, day: 10 + i)!,
                              amount: Money(cents: -1_250), label: "Boeking \(i)")
            try entry.insert(database)
        }
    }
}

func accountNames(_ db: AppDatabase) throws -> [String] {
    try db.read { try String.fetchAll($0, sql: "SELECT name FROM account ORDER BY id") }
}

/// Alle rijen van alle tabellen als tekst, om twee databases te vergelijken.
func dump(_ db: AppDatabase) throws -> [String] {
    try db.read { database in
        let tables = try String.fetchAll(database, sql:
            "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name")
        return try tables.flatMap { table in
            try Row.fetchAll(database, sql: "SELECT * FROM \"\(table)\" ORDER BY rowid").map { "\(table): \($0)" }
        }
    }
}

@Suite struct BackupTests {
    @Test func createBackupWritesVerifiedFileWithTimestampName() throws {
        let temp = try TempFolder()
        let db = try AppDatabase.inMemory()
        try smallDatabase(db)
        let now = date("2027-03-04 15:16:17")

        let info = try Backup.createBackup(from: db, to: temp.sub("backups"), now: now)

        #expect(info.fileName == "HomeFinance-20270304-151617.sqlite")
        #expect(FileManager.default.fileExists(atPath: info.url.path))
        #expect(info.isVerified)
        #expect(info.kind == .regular)
        #expect(info.date == now)
        #expect(info.size > 0)
        #expect(info.counts == BackupCounts(accounts: 1, years: 1, entries: 3, bankTransactions: 0))
        #expect(info.firstEntryDay == Day(year: 2027, month: 1, day: 10))
        #expect(info.lastEntryDay == Day(year: 2027, month: 1, day: 12))
        #expect(info.appliedMigrations == AppDatabase.migrator.migrations)
        #expect(try db.read { try BackupSettings.load($0).lastBackupAt } == now)
        // Geen tijdelijke bestanden achtergebleven.
        let names = try FileManager.default.contentsOfDirectory(atPath: temp.sub("backups").path)
        #expect(names == [info.fileName])
    }

    @Test func twoBackupsInTheSameSecondGetDifferentNames() throws {
        let temp = try TempFolder()
        let db = try AppDatabase.inMemory()
        try smallDatabase(db)
        let now = date("2027-03-04 15:16:17")
        let first = try Backup.createBackup(from: db, to: temp.url, now: now)
        let second = try Backup.createBackup(from: db, to: temp.url, now: now)
        #expect(first.url != second.url)
        #expect(second.fileName == "HomeFinance-20270304-151617-2.sqlite")
        #expect(Backup.listBackups(in: temp.url).count == 2)
    }

    @Test func backupOfDatabaseOnDiskIsOneSelfContainedFile() throws {
        let temp = try TempFolder()
        let db = try AppDatabase.open(at: temp.sub("live").appendingPathComponent("homefinance.sqlite"))
        try smallDatabase(db, entries: 5)

        let info = try Backup.createBackup(from: db, to: temp.sub("backups"), now: date("2027-03-04 10:00:00"))

        #expect(info.counts.entries == 5)
        let names = try FileManager.default.contentsOfDirectory(atPath: temp.sub("backups").path)
        #expect(names == [info.fileName])
        #expect(try Backup.verify(backupAt: info.url).counts == info.counts)
        // De bron staat in WAL-modus, de back-up niet: hij heeft geen hulpbestanden nodig.
        #expect(try db.read { try String.fetchOne($0, sql: "PRAGMA journal_mode") } == "wal")
        let copy = try DatabaseQueue(path: info.url.path)
        #expect(try copy.read { try String.fetchOne($0, sql: "PRAGMA journal_mode") } == "delete")
        try copy.close()
        #expect(try FileManager.default.contentsOfDirectory(atPath: temp.sub("backups").path) == [info.fileName])
    }

    @Test func verifyRejectsFilesThatAreNotAHomeFinanceBackup() throws {
        let temp = try TempFolder()

        let missing = temp.url.appendingPathComponent("HomeFinance-20270101-000000.sqlite")
        #expect(throws: BackupError.fileNotFound(missing.lastPathComponent)) { try Backup.verify(backupAt: missing) }

        let text = temp.url.appendingPathComponent("tekst.sqlite")
        try Data(String(repeating: "Dit is geen database. ", count: 100).utf8).write(to: text)
        #expect(throws: BackupError.notADatabase("tekst.sqlite")) { try Backup.verify(backupAt: text) }

        let other = temp.url.appendingPathComponent("anders.sqlite")
        let queue = try DatabaseQueue(path: other.path)
        try queue.write { try $0.execute(sql: "CREATE TABLE iets (id INTEGER PRIMARY KEY)") }
        try queue.close()
        #expect(throws: BackupError.notHomeFinance("anders.sqlite")) { try Backup.verify(backupAt: other) }

        // Een back-up van een nieuwere versie van de app.
        let db = try AppDatabase.inMemory()
        try smallDatabase(db)
        let backup = try Backup.createBackup(from: db, to: temp.url, now: date("2027-03-04 10:00:00"))
        let newer = try DatabaseQueue(path: backup.url.path)
        try newer.write { try $0.execute(sql: "INSERT INTO grdb_migrations (identifier) VALUES ('v999')") }
        try newer.close()
        #expect(throws: BackupError.newerVersion(file: backup.fileName, unknownMigrations: ["v999"])) {
            try Backup.verify(backupAt: backup.url)
        }
    }

    @Test func errorsHaveDutchMessages() {
        let errors: [BackupError] = [
            .fileNotFound("a.sqlite"), .notADatabase("a.sqlite"), .corrupt(file: "a.sqlite", detail: "x"),
            .notHomeFinance("a.sqlite"), .newerVersion(file: "a.sqlite", unknownMigrations: ["v9"]),
            .folderUnavailable("/map"), .restoreFailed(detail: "x"),
            .restoreFailedNotRolledBack(detail: "x", safetyBackup: "/map/a.sqlite"),
        ]
        for error in errors {
            #expect(error.localizedDescription.contains("a.sqlite") || error.localizedDescription.contains("map")
                    || error.localizedDescription.contains("Herstellen"))
        }
        #expect(BackupError.notHomeFinance("a.sqlite").localizedDescription
                == "a.sqlite is geen geldige HomeFinance-back-up: de tabellen van HomeFinance ontbreken.")
    }

    @Test func listBackupsIsNewestFirstAndFlagsBrokenFiles() throws {
        let temp = try TempFolder()
        let db = try AppDatabase.inMemory()
        try smallDatabase(db)
        try Backup.createBackup(from: db, to: temp.url, now: date("2027-03-01 10:00:00"))
        try Backup.createBackup(from: db, to: temp.url, now: date("2027-03-03 10:00:00"))
        try Backup.createBackup(from: db, to: temp.url, now: date("2027-03-02 10:00:00"))
        try Data("kapot".utf8).write(to: temp.url.appendingPathComponent("HomeFinance-20270304-100000.sqlite"))
        try Data("x".utf8).write(to: temp.url.appendingPathComponent("notities.txt"))

        let list = Backup.listBackups(in: temp.url)

        #expect(list.map(\.fileName) == [
            "HomeFinance-20270304-100000.sqlite", "HomeFinance-20270303-100000.sqlite",
            "HomeFinance-20270302-100000.sqlite", "HomeFinance-20270301-100000.sqlite",
        ])
        #expect(list.map(\.isVerified) == [false, true, true, true])
        #expect(list[0].problem?.contains("geen geldige HomeFinance-back-up") == true)
        #expect(list[1].date == date("2027-03-03 10:00:00"))
        #expect(Backup.listBackups(in: temp.sub("bestaat-niet")).isEmpty)
    }

    @Test func pruneKeepsTheNewest() throws {
        let temp = try TempFolder()
        let db = try AppDatabase.inMemory()
        try smallDatabase(db)
        for day in 1...5 {
            try Backup.createBackup(from: db, to: temp.url, now: date("2027-03-0\(day) 10:00:00"))
        }
        let removed = try Backup.prune(in: temp.url, keep: 2)
        #expect(removed.count == 3)
        #expect(Backup.listBackups(in: temp.url).map(\.fileName)
                == ["HomeFinance-20270305-100000.sqlite", "HomeFinance-20270304-100000.sqlite"])
        #expect(try Backup.prune(in: temp.url, keep: 2).isEmpty)
        // keep 0 bewaart er toch één.
        try Backup.prune(in: temp.url, keep: 0)
        #expect(Backup.listBackups(in: temp.url).count == 1)
    }

    @Test func pruneNeverDeletesTheOnlyVerifiedBackupOrSafetyCopies() throws {
        let temp = try TempFolder()
        let db = try AppDatabase.inMemory()
        try smallDatabase(db)
        let good = try Backup.createBackup(from: db, to: temp.url, now: date("2027-03-01 10:00:00"))
        let older = try Backup.createBackup(from: db, to: temp.url, now: date("2027-02-01 10:00:00"))
        let safety = try Backup.writeBackup(from: db, to: temp.url, now: date("2027-01-01 10:00:00"), kind: .safety)
        for day in 2...4 {
            try Data("kapot".utf8).write(to: temp.url.appendingPathComponent("HomeFinance-2027030\(day)-100000.sqlite"))
        }

        let removed = try Backup.prune(in: temp.url, keep: 2)

        // De twee nieuwste zijn kapot; de nieuwste goede blijft daarom staan.
        #expect(Set(removed.map(\.lastPathComponent)) == ["HomeFinance-20270302-100000.sqlite", older.fileName])
        let left = Backup.listBackups(in: temp.url)
        #expect(left.contains { $0.fileName == good.fileName && $0.isVerified })
        #expect(left.contains { $0.fileName == safety.fileName && $0.kind == .safety })
        #expect(left.count == 4)
    }

    @Test func restoreBringsBackTheBackupAndWritesASafetyCopy() throws {
        let temp = try TempFolder()
        let db = try AppDatabase.open(at: temp.sub("live").appendingPathComponent("homefinance.sqlite"))
        try smallDatabase(db, accountName: "Voor de back-up")
        let backup = try Backup.createBackup(from: db, to: temp.sub("backups"), now: date("2027-03-01 10:00:00"))

        // Na de back-up verandert er van alles, ook de back-upinstellingen.
        try db.write { database in
            try database.execute(sql: "UPDATE account SET name = 'Na de back-up'")
            try database.execute(sql: "DELETE FROM entry")
            var settings = try BackupSettings.load(database)
            settings.folderPath = "/verzonnen/map"
            settings.keepCount = 12
            settings.lastBackupAt = date("2027-03-05 09:00:00")
            try settings.save(database)
        }

        let result = try Backup.restore(from: backup.url, into: db, safetyFolder: temp.sub("veiligheid"),
                                        now: date("2027-03-06 12:00:00"))

        #expect(try accountNames(db) == ["Voor de back-up"])
        #expect(result.counts == BackupCounts(accounts: 1, years: 1, entries: 3, bankTransactions: 0))
        #expect(result.restored.url == backup.url)
        #expect(result.migrationsApplied.isEmpty)
        // De veiligheidskopie bevat de toestand van vlak voor het herstel.
        #expect(result.safetyBackup.fileName == "HomeFinance-voor-herstel-20270306-120000.sqlite")
        #expect(result.safetyBackup.kind == .safety)
        #expect(result.safetyBackup.counts.entries == 0)
        let safety = try DatabaseQueue(path: result.safetyBackup.url.path)
        #expect(try safety.read { try String.fetchOne($0, sql: "SELECT name FROM account") } == "Na de back-up")
        // De back-upinstellingen van deze Mac blijven staan.
        let settings = try db.read { try BackupSettings.load($0) }
        #expect(settings.folderPath == "/verzonnen/map")
        #expect(settings.keepCount == 12)
        #expect(settings.lastBackupAt == date("2027-03-05 09:00:00"))
        // De database werkt gewoon door.
        try db.write { try $0.execute(sql: "UPDATE account SET name = 'Daarna'") }
        #expect(try accountNames(db) == ["Daarna"])
        #expect(try db.read { try Backup.counts($0) }.entries == 3)
    }

    @Test func restoreIntoInMemoryDatabase() throws {
        let temp = try TempFolder()
        let source = try AppDatabase.inMemory()
        try DemoData.seed(into: source, today: testToday)
        let backup = try Backup.createBackup(from: source, to: temp.url, now: date("2027-06-18 10:00:00"))

        let target = try AppDatabase.inMemory()
        let result = try Backup.restore(from: backup.url, into: target, safetyFolder: temp.sub("veiligheid"))

        #expect(result.counts == backup.counts)
        #expect(try dump(target).filter { !$0.hasPrefix("setting:") } == dump(source).filter { !$0.hasPrefix("setting:") })
    }

    @Test func restoreOfInvalidBackupLeavesLiveDatabaseUntouched() throws {
        let temp = try TempFolder()
        let db = try AppDatabase.inMemory()
        try smallDatabase(db, accountName: "Blijft staan")
        let before = try dump(db)
        let bad = temp.url.appendingPathComponent("HomeFinance-20270301-100000.sqlite")
        try Data("geen database".utf8).write(to: bad)

        #expect(throws: BackupError.notADatabase(bad.lastPathComponent)) {
            try Backup.restore(from: bad, into: db, safetyFolder: temp.sub("veiligheid"))
        }
        #expect(try dump(db) == before)
        // Er is niets begonnen, dus ook geen veiligheidskopie.
        #expect(!FileManager.default.fileExists(atPath: temp.sub("veiligheid").path))
    }

    @Test func restoreThatFailsHalfwayPutsTheOldDataBack() throws {
        struct Boom: Error, LocalizedError { var errorDescription: String? { "nagebootste fout" } }
        let temp = try TempFolder()
        let old = try AppDatabase.inMemory()
        try smallDatabase(old, accountName: "Uit de back-up", entries: 1)
        let backup = try Backup.createBackup(from: old, to: temp.sub("backups"), now: date("2027-03-01 10:00:00"))

        for onDisk in [false, true] {
            let db = onDisk
                ? try AppDatabase.open(at: temp.sub("live").appendingPathComponent("homefinance.sqlite"))
                : try AppDatabase.inMemory()
            try smallDatabase(db, accountName: "Huidige gegevens", entries: 7)
            let before = try dump(db)
            var sawBackupContents = false

            #expect(throws: BackupError.restoreFailed(detail: "nagebootste fout")) {
                try Backup.restore(from: backup.url, into: db, safetyFolder: temp.sub("veiligheid-\(onDisk)"),
                                   now: date("2027-03-06 12:00:00"), afterCopy: {
                    sawBackupContents = try accountNames(db) == ["Uit de back-up"]
                    throw Boom()
                })
            }
            #expect(sawBackupContents)
            #expect(try dump(db) == before)
            #expect(Backup.listBackups(in: temp.sub("veiligheid-\(onDisk)")).count == 1)
        }
    }

    @Test func settingsHaveDefaultsAndRoundTrip() throws {
        let db = try AppDatabase.inMemory()
        let defaults = try db.read { try BackupSettings.load($0) }
        #expect(defaults == BackupSettings(folderPath: nil, folderBookmark: nil, keepCount: 30,
                                           autoBackupOnQuit: true, lastBackupAt: nil))
        #expect(defaults.folderURL == nil)

        var settings = defaults
        settings.folderPath = "/verzonnen/back-upmap"
        settings.keepCount = 5
        settings.autoBackupOnQuit = false
        settings.lastBackupAt = date("2027-03-01 10:00:00")
        try db.write { try settings.save($0) }
        let loaded = try db.read { try BackupSettings.load($0) }
        #expect(loaded == settings)
        #expect(loaded.folderURL?.path == "/verzonnen/back-upmap")

        // Een bestaande map krijgt ook een bookmark.
        let temp = try TempFolder()
        settings.setFolder(temp.url)
        #expect(settings.folderBookmark != nil)
        try db.write { try settings.save($0) }
        let withBookmark = try db.read { try BackupSettings.load($0) }
        #expect(withBookmark.folderURL?.standardizedFileURL.resolvingSymlinksInPath().path
                == temp.url.standardizedFileURL.resolvingSymlinksInPath().path)
    }

    @Test func backupIsDueAfterSevenDays() throws {
        let db = try AppDatabase.inMemory()
        let now = date("2027-03-10 12:00:00")
        // Lege database: niets om te bewaren.
        #expect(try Backup.isBackupDue(db, now: now) == false)
        try smallDatabase(db)
        #expect(try Backup.isBackupDue(db, now: now) == true)
        try db.write { try BackupSettings.setLastBackup($0, date("2027-03-03 12:00:01")) }
        #expect(try Backup.isBackupDue(db, now: now) == false)
        try db.write { try BackupSettings.setLastBackup($0, date("2027-03-03 12:00:00")) }
        #expect(try Backup.isBackupDue(db, now: now) == true)
    }

    @Test func backupUsingSettingsWritesAndPrunes() throws {
        let temp = try TempFolder()
        let db = try AppDatabase.inMemory()
        try smallDatabase(db)
        #expect(try Backup.backupUsingSettings(db, now: date("2027-03-01 10:00:00")) == nil)

        try db.write { database in
            var settings = try BackupSettings.load(database)
            settings.folderPath = temp.url.path
            settings.keepCount = 2
            try settings.save(database)
        }
        for day in 1...4 {
            #expect(try Backup.backupUsingSettings(db, now: date("2027-03-0\(day) 10:00:00")) != nil)
        }
        #expect(Backup.listBackups(in: temp.url).map(\.fileName)
                == ["HomeFinance-20270304-100000.sqlite", "HomeFinance-20270303-100000.sqlite"])
        #expect(try Backup.isBackupDue(db, now: date("2027-03-05 10:00:00")) == false)
    }

    @Test func exportWritesOneDutchCSVPerTable() throws {
        let temp = try TempFolder()
        let db = try AppDatabase.inMemory()
        try db.write { database in
            var account = Account(name: "Rekening; met \"leestekens\"", iban: "NL00TEST0000000001", kind: .betaal,
                                  openingBalance: Money(cents: 123_456), openingDate: Day(year: 2027, month: 1, day: 1)!)
            try account.insert(database)
            var entry = Entry(accountId: account.id!, day: Day(year: 2027, month: 2, day: 3)!,
                              amount: Money(cents: -5), label: "Kleine uitgave")
            try entry.insert(database)
            var pot = Pot(accountId: account.id!, name: "Pot", kind: .spaar)
            try pot.insert(database)
        }

        let files = try Backup.exportAllAsCSV(db, to: temp.sub("export"))

        #expect(Set(files.map(\.table)) == Set(Backup.requiredTables))
        #expect(files.first { $0.table == "entry" }?.rowCount == 1)
        #expect(files.first { $0.table == "tag" }?.rowCount == 0)

        func lines(_ table: String) throws -> [String] {
            let data = try Data(contentsOf: temp.sub("export").appendingPathComponent("\(table).csv"))
            #expect(Array(data.prefix(3)) == [0xEF, 0xBB, 0xBF])
            let text = String(decoding: data.dropFirst(3), as: UTF8.self)
            return text.components(separatedBy: "\r\n").filter { !$0.isEmpty }
        }
        let account = try lines("account")
        #expect(account[0] == "id;name;iban;kind;openingBalance;openingDate;sortOrder;archived")
        #expect(account[1] == "1;\"Rekening; met \"\"leestekens\"\"\";NL00TEST0000000001;betaal;1234,56;2027-01-01;0;0")
        let entry = try lines("entry")
        #expect(entry[0].hasPrefix("id;accountId;bankTransactionId;day;amount;label;"))
        #expect(entry[1].hasPrefix("1;1;;2027-02-03;-0,05;Kleine uitgave;;;0;"))
        // Lege tabel: alleen de kopregel. Lege optionele bedragen blijven leeg.
        #expect(try lines("tag") == ["id;name;color;sortOrder"])
        #expect(try lines("pot")[1] == "1;1;Pot;spaar;;0,00;;0;0")
    }

    @Test func moneyAndFieldFormatting() {
        #expect(Backup.csvMoney(123_456) == "1234,56")
        #expect(Backup.csvMoney(-1_000_000_01) == "-1000000,01")
        #expect(Backup.csvMoney(0) == "0,00")
        #expect(Backup.csvField("gewoon") == "gewoon")
        #expect(Backup.csvField("regel\neinde") == "\"regel\neinde\"")
    }
}
