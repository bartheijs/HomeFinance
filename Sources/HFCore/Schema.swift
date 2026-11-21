import Foundation
import GRDB

/// De database van HomeFinance: één SQLite-bestand, lokaal, met migraties.
public final class AppDatabase: Sendable {
    public let writer: any DatabaseWriter

    /// Opent de database en voert openstaande migraties uit.
    public init(_ writer: any DatabaseWriter) throws {
        self.writer = writer
        try Self.migrator.migrate(writer)
    }

    /// Lege database in het geheugen, voor tests en previews.
    public static func inMemory() throws -> AppDatabase {
        try AppDatabase(DatabaseQueue(configuration: configuration))
    }

    /// Database op schijf. Maakt de map aan als die nog niet bestaat.
    public static func open(at url: URL) throws -> AppDatabase {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return try AppDatabase(DatabasePool(path: url.path, configuration: configuration))
    }

    /// ~/Library/Application Support/HomeFinance/homefinance.sqlite
    public static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("HomeFinance", isDirectory: true)
            .appendingPathComponent("homefinance.sqlite")
    }

    public static var configuration: Configuration {
        var c = Configuration()
        c.foreignKeysEnabled = true
        return c
    }

    public var reader: any DatabaseReader { writer }

    public func read<T>(_ block: (Database) throws -> T) throws -> T { try writer.read(block) }
    public func write<T>(_ block: (Database) throws -> T) throws -> T { try writer.write(block) }

    // MARK: Migraties

    /// Nieuwe schemawijzigingen komen als NIEUWE migratie onderaan; bestaande migraties nooit aanpassen.
    public static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()

        m.registerMigration("v1") { db in
            try db.create(table: "account") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("iban", .text).unique()
                t.column("kind", .text).notNull()
                t.column("openingBalance", .integer).notNull().defaults(to: 0)
                t.column("openingDate", .text).notNull()
                t.column("sortOrder", .integer).notNull().defaults(to: 0)
                t.column("archived", .boolean).notNull().defaults(to: false)
            }

            try db.create(table: "budgetYear") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("year", .integer).notNull().unique()
                t.column("antiRood", .integer).notNull().defaults(to: 0)
                t.column("tijdelijkAntiRood", .integer).notNull().defaults(to: 0)
                t.column("reserveBase", .integer).notNull().defaults(to: 0)
                t.column("closed", .boolean).notNull().defaults(to: false)
            }

            try db.create(table: "pot") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("accountId", .integer).notNull().indexed().references("account", onDelete: .restrict)
                t.column("name", .text).notNull()
                t.column("kind", .text).notNull()
                t.column("owner", .text)
                t.column("monthlyAmount", .integer).notNull().defaults(to: 0)
                t.column("targetAmount", .integer)
                t.column("sortOrder", .integer).notNull().defaults(to: 0)
                t.column("archived", .boolean).notNull().defaults(to: false)
            }

            try db.create(table: "budgetItem") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("yearId", .integer).notNull().indexed().references("budgetYear", onDelete: .cascade)
                t.column("label", .text).notNull()
                t.column("direction", .text).notNull()
                t.column("planAmount", .integer).notNull().defaults(to: 0)
                t.column("frequency", .text).notNull().defaults(to: "maand")
                t.column("expectedMonths", .text).notNull().defaults(to: "")
                t.column("expectedDay", .integer)
                t.column("isReserveTotal", .boolean).notNull().defaults(to: false)
                t.column("reducesReserve", .boolean).notNull().defaults(to: false)
                t.column("potId", .integer).references("pot", onDelete: .setNull)
                t.column("sortOrder", .integer).notNull().defaults(to: 0)
            }

            try db.create(table: "importBatch") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("accountId", .integer).notNull().indexed().references("account", onDelete: .restrict)
                t.column("fileName", .text).notNull()
                t.column("importedAt", .datetime).notNull()
                t.column("rowCount", .integer).notNull().defaults(to: 0)
                t.column("newCount", .integer).notNull().defaults(to: 0)
                t.column("duplicateCount", .integer).notNull().defaults(to: 0)
                t.column("firstDay", .text)
                t.column("lastDay", .text)
                t.column("openingBalance", .integer)
                t.column("closingBalance", .integer)
                t.column("chainOK", .boolean).notNull().defaults(to: true)
            }

            try db.create(table: "bankTransaction") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("accountId", .integer).notNull().indexed().references("account", onDelete: .restrict)
                t.column("batchId", .integer).indexed().references("importBatch", onDelete: .setNull)
                t.column("day", .text).notNull().indexed()
                t.column("amount", .integer).notNull()
                t.column("balanceBefore", .integer)
                t.column("counterpartyName", .text).notNull().defaults(to: "")
                t.column("counterpartyIban", .text).notNull().defaults(to: "")
                t.column("descriptionText", .text).notNull().defaults(to: "")
                t.column("reference", .text).notNull().defaults(to: "")
                t.column("transactionCode", .text).notNull().defaults(to: "")
                t.column("sequence", .text).notNull().defaults(to: "")
                t.column("fingerprint", .text).notNull().unique()
                t.column("status", .text).notNull().defaults(to: "nieuw").indexed()
            }

            try db.create(table: "savingsTransfer") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("day", .text).notNull()
                t.column("amount", .integer).notNull()
                t.column("done", .boolean).notNull().defaults(to: false)
                t.column("doneAt", .datetime)
                t.column("note", .text).notNull().defaults(to: "")
            }

            try db.create(table: "rule") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("priority", .integer).notNull().defaults(to: 100)
                t.column("enabled", .boolean).notNull().defaults(to: true)
                t.column("origin", .text).notNull().defaults(to: "handmatig")
                t.column("accountId", .integer).references("account", onDelete: .cascade)
                t.column("counterpartyContains", .text)
                t.column("counterpartyIban", .text)
                t.column("descriptionContains", .text)
                t.column("amount", .integer)
                t.column("targetItemLabel", .text)
                t.column("targetPotId", .integer).references("pot", onDelete: .setNull)
                t.column("entryLabel", .text)
                t.column("tagIds", .text).notNull().defaults(to: "")
                t.column("reimburse", .boolean).notNull().defaults(to: false)
                t.column("hitCount", .integer).notNull().defaults(to: 0)
                t.column("lastUsed", .datetime)
            }

            try db.create(table: "entry") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("accountId", .integer).notNull().indexed().references("account", onDelete: .restrict)
                t.column("bankTransactionId", .integer).indexed().references("bankTransaction", onDelete: .cascade)
                t.column("day", .text).notNull().indexed()
                t.column("amount", .integer).notNull()
                t.column("label", .text).notNull().defaults(to: "")
                t.column("budgetItemId", .integer).indexed().references("budgetItem", onDelete: .setNull)
                t.column("potId", .integer).indexed().references("pot", onDelete: .setNull)
                t.column("reimburse", .boolean).notNull().defaults(to: false)
                t.column("savingsTransferId", .integer).references("savingsTransfer", onDelete: .setNull)
                t.column("counterEntryId", .integer).references("entry", onDelete: .setNull)
                t.column("reviewed", .boolean).notNull().defaults(to: true)
                t.column("note", .text).notNull().defaults(to: "")
                t.column("ruleId", .integer).references("rule", onDelete: .setNull)
                t.column("confidence", .text)
                t.column("createdAt", .datetime).notNull()
            }

            try db.create(table: "tag") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull().unique()
                t.column("color", .text).notNull().defaults(to: "#888888")
                t.column("sortOrder", .integer).notNull().defaults(to: 0)
            }

            try db.create(table: "entryTag") { t in
                t.column("entryId", .integer).notNull().references("entry", onDelete: .cascade)
                t.column("tagId", .integer).notNull().indexed().references("tag", onDelete: .cascade)
                t.primaryKey(["entryId", "tagId"])
            }

            try db.create(table: "reconciliation") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("accountId", .integer).notNull().indexed().references("account", onDelete: .cascade)
                t.column("day", .text).notNull()
                t.column("actualBalance", .integer).notNull()
                t.column("calculatedBalance", .integer).notNull()
                t.column("createdAt", .datetime).notNull()
            }

            try db.create(table: "setting") { t in
                t.primaryKey("key", .text)
                t.column("value", .text).notNull()
            }
        }

        // Tijdelijk anti-rood wordt afgeleid uit gemarkeerde boekingen in plaats van een instelling per jaar.
        m.registerMigration("v2-temporaryLoan") { db in
            try db.alter(table: "entry") { t in
                t.add(column: "temporaryLoan", .boolean).notNull().defaults(to: false)
            }
        }

        // Verrekenen per tag: uitgaven met een tag (bv. Tanken) die de gebruiker periodiek terugstort.
        m.registerMigration("v3-settlement") { db in
            try db.alter(table: "tag") { t in
                t.add(column: "settles", .boolean).notNull().defaults(to: false)
            }
            try db.create(table: "settlement") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("tagId", .integer).notNull().indexed().references("tag", onDelete: .cascade)
                t.column("day", .text).notNull()
                t.column("amount", .integer).notNull()
                t.column("depositEntryId", .integer).references("entry", onDelete: .setNull)
                t.column("isOpening", .boolean).notNull().defaults(to: false)
                t.column("note", .text).notNull().defaults(to: "")
                t.column("createdAt", .datetime).notNull()
            }
            try db.alter(table: "entry") { t in
                t.add(column: "settlementId", .integer).references("settlement", onDelete: .setNull)
            }
        }

        // Zelf inrichten en bijsturen: vaste stortingen met een verdeling over potten, een post voor een maand
        // met de hand op 'voldaan' zetten, en een boeking laten meetellen in een andere maand dan zijn datum.
        m.registerMigration("v4-distribution-check-period") { db in
            try db.create(table: "distribution") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("accountId", .integer).notNull().indexed().references("account", onDelete: .restrict)
                t.column("sortOrder", .integer).notNull().defaults(to: 0)
                t.column("archived", .boolean).notNull().defaults(to: false)
            }
            try db.create(table: "distributionLine") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("distributionId", .integer).notNull().indexed().references("distribution", onDelete: .cascade)
                t.column("potId", .integer).notNull().references("pot", onDelete: .cascade)
                t.column("amount", .integer).notNull()
                t.column("sortOrder", .integer).notNull().defaults(to: 0)
                t.uniqueKey(["distributionId", "potId"])
            }
            try db.alter(table: "budgetItem") { t in
                t.add(column: "distributionId", .integer).references("distribution", onDelete: .setNull)
            }
            try db.create(table: "itemCheck") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("budgetItemId", .integer).notNull().references("budgetItem", onDelete: .cascade)
                t.column("month", .integer).notNull()
                t.column("note", .text).notNull().defaults(to: "")
                t.column("createdAt", .datetime).notNull()
                t.uniqueKey(["budgetItemId", "month"])
            }
            try db.alter(table: "entry") { t in
                t.add(column: "period", .text)
            }
        }

        // De vaste storting kent ook de rekening waar het geld vandaan komt, zodat beide kanten herkend worden.
        m.registerMigration("v5-distribution-source") { db in
            try db.alter(table: "distribution") { t in
                t.add(column: "sourceAccountId", .integer).references("account", onDelete: .setNull)
            }
        }

        // Vooruitblik per pot: verwachte bedragen op een datum. Telt nergens in mee, alleen in de vooruitblik.
        m.registerMigration("v6-forecast") { db in
            try db.create(table: "forecastItem") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("potId", .integer).notNull().indexed().references("pot", onDelete: .cascade)
                t.column("day", .text).notNull()
                t.column("amount", .integer).notNull()
                t.column("label", .text).notNull().defaults(to: "")
                t.column("realizedEntryId", .integer).references("entry", onDelete: .setNull)
                t.column("realizedAt", .datetime)
                t.column("createdAt", .datetime).notNull()
            }
        }

        // Spaardoel per pot: naast het doelbedrag ook de datum waarop het er moet zijn.
        m.registerMigration("v7-pot-target-date") { db in
            try db.alter(table: "pot") { t in
                t.add(column: "targetDate", .text)
            }
        }

        // Wat-als-bedrag per post, een spaardoel opgebouwd uit onderdelen, en verwachtingen gegroepeerd per project.
        m.registerMigration("v8-scenario-goalparts-project") { db in
            try db.alter(table: "budgetItem") { t in
                t.add(column: "scenarioAmount", .integer)
            }
            try db.create(table: "goalPart") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("potId", .integer).notNull().indexed().references("pot", onDelete: .cascade)
                t.column("label", .text).notNull().defaults(to: "")
                t.column("quantity", .integer).notNull().defaults(to: 1)
                t.column("unitAmount", .integer).notNull().defaults(to: 0)
                t.column("sortOrder", .integer).notNull().defaults(to: 0)
            }
            try db.alter(table: "forecastItem") { t in
                t.add(column: "project", .text).notNull().defaults(to: "")
            }
        }

        // Richting van "verrekenen met spaar" per regel (6f). Bestaande regels met verrekenen krijgen de richting
        // van hun laatste boeking met verrekenen; zonder zo'n boeking "erin" (alleen bijschrijving), de veilige
        // keuze. Regels zonder verrekenen krijgen "beide"; de richting telt pas als verrekenen aan gaat.
        m.registerMigration("v9-rule-reimburse-direction") { db in
            try db.alter(table: "rule") { t in
                t.add(column: "reimburseDirection", .text).notNull().defaults(to: "beide")
            }
            try db.execute(sql: """
                UPDATE rule SET reimburseDirection = COALESCE(
                    (SELECT CASE WHEN e.amount > 0 THEN 'erin' ELSE 'eruit' END
                     FROM entry e
                     WHERE e.ruleId = rule.id AND e.reimburse = 1 AND e.amount <> 0
                     ORDER BY e.day DESC, e.id DESC LIMIT 1),
                    'erin')
                WHERE reimburse = 1
                """)
        }

        return m
    }
}
