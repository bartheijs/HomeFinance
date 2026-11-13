import Foundation
import GRDB
import HFCore
import HFBackup

// Dunne lijm tussen de app en de modules, zodat schermen niet hoeven te weten
// hoe voorbeelddata en back-ups precies worden aangeroepen.

enum DemoSupport {
    /// Opent de voorbeelddatabase en vult hem bij het eerste gebruik.
    static func openDemo(at url: URL) throws -> AppDatabase {
        let db = try AppDatabase.open(at: url)
        if try db.read({ try Account.fetchCount($0) }) == 0 {
            // De laatste dagen blijven buiten de database: die importeer je zelf met het voorbeeldbestand.
            _ = try DemoData.seed(into: db, today: Day.today(), leaveRecentForImport: true)
        }
        return db
    }

    /// Volledige voorbeelddata, met transacties die nog nagekeken moeten worden (voor snapshots).
    static func seed(_ db: AppDatabase, today: Day) throws {
        _ = try DemoData.seed(into: db, today: today)
    }

    /// Schrijft het voorbeeld-CSV-bestand naar een tijdelijke map en geeft de plek terug.
    static func writeSampleCSV(today: Day) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(DemoData.sampleCSVFileName(today: today))
        try DemoData.sampleCSV(today: today).write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}

enum BackupSupport {
    static func backupOnQuitIfWanted(db: AppDatabase) {
        _ = try? Backup.backupUsingSettings(db)
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
