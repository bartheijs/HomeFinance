import Foundation
import GRDB
import HFCore
import HFInsight
import HFBackup
import HFPublish

// Dunne lijm tussen de app en de modules, zodat schermen niet hoeven te weten
// hoe voorbeelddata en back-ups precies worden aangeroepen.

enum DemoSupport {
    /// Opent de voorbeelddatabase en vult hem bij het eerste gebruik. Staat er voorbeelddata van een oudere versie
    /// in, dan wordt dit voorbeeldbestand opnieuw gevuld (nooit de eigen administratie). De laatste dagen blijven
    /// buiten de database: die importeer je zelf met de voorbeeldzip.
    static func openDemo(at url: URL) throws -> AppDatabase {
        try DemoData.openDemo(at: url, today: Day.today(), leaveRecentForImport: true, afterSeed: configurePhone)
    }

    /// Volledige voorbeelddata, met transacties die nog nagekeken moeten worden (voor snapshots en de zelftest).
    static func seed(_ db: AppDatabase, today: Day) throws {
        _ = try DemoData.seed(into: db, today: today)
        try configurePhone(db)
    }

    /// Zet op het telefoondashboard van de voorbeelddata de potjes van de kinderen en de gezamenlijke spaarpot aan.
    /// Het dashboard zelf blijft uit (geen map): dat zet de gebruiker bij Instellingen › Telefoon aan.
    static func configurePhone(_ db: AppDatabase) throws {
        try db.write { database in
            var settings = try PublishSettings.load(database)
            settings.options.childOwners = DemoData.childOwners
            settings.options.sharedPotId = try Int64.fetchOne(database, sql: "SELECT id FROM pot WHERE name = ?",
                                                              arguments: [DemoData.sharedPotName])
            try settings.save(database)
        }
    }

    /// Schrijft de voorbeeldzip (betaal- en spaarrekening, laatste 10 dagen) naar een tijdelijke map en geeft de
    /// plek terug.
    static func writeSampleArchive(today: Day) throws -> URL {
        try DemoData.writeSampleArchive(today: today, to: FileManager.default.temporaryDirectory
            .appendingPathComponent("HomeFinance-voorbeeld", isDirectory: true))
    }
}

enum BackupSupport {
    static func backupOnQuitIfWanted(db: AppDatabase) {
        // Alleen als de gebruiker automatische back-up bij afsluiten aan heeft staan.
        guard let settings = try? db.read({ try BackupSettings.load($0) }), settings.autoBackupOnQuit else { return }
        _ = try? Backup.backupUsingSettings(db)
        // Ook naar de tweede back-upmap, als die is ingesteld.
        SecondBackupSupport.backupOnQuitIfWanted(db: db)
    }
}

@MainActor
enum SidebarBadges {
    static func count(for screen: Screen, model: AppModel) -> Int {
        _ = model.revision
        switch screen {
        case .review:
            return model.read(0) { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM bankTransaction WHERE status = 'nieuw'") ?? 0 }
        case .transactions:
            return model.read(0) { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM entry WHERE reviewed = 0") ?? 0 }
        case .settleUp:
            // Het aantal blokken van Nog rechtzetten waar iets openstaat (D4).
            return model.read(0) { try SettleUpData.read($0, today: model.today).openBlockCount }
        case .advances:
            // Tags waarvan je nog voorgeschoten geld terugkrijgt (D3).
            return model.read(0) { try Insight.settlementOverview($0, today: model.today).filter { $0.outstanding > .zero }.count }
        case .reimbursements:
            return model.read(0) {
                try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM entry WHERE reimburse = 1 AND savingsTransferId IS NULL") ?? 0
            }
        default:
            return 0
        }
    }

    static func years(model: AppModel) -> [Int] {
        _ = model.revision
        return model.read([]) { try Int.fetchAll($0, sql: "SELECT year FROM budgetYear ORDER BY year") }
    }
}
