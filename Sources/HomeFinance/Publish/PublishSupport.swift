import Foundation
import AppKit
import GRDB
import HFCore
import HFBackup
import HFPublish

/// Schrijft het dashboard voor de telefoon als bestand naar een cloudmap.
/// De app roept `schedule` aan na elke wijziging in de database en `publishNow` bij afsluiten.
///
/// Twee bestanden met dezelfde pagina: HTML (voor de app Bestanden) en PDF (voor apps die geen HTML tonen).
/// Fouten komen nooit als melding in beeld; de laatste fout staat bij Instellingen › Telefoon.
@MainActor
enum PublishSupport {
    nonisolated static let folderName = "HomeFinance vandaag"
    nonisolated static let htmlFileName = "HomeFinance vandaag.html"
    nonisolated static let pdfFileName = "HomeFinance vandaag.pdf"
    /// Zo lang wacht de app na de laatste wijziging voordat hij schrijft.
    static let quietSeconds = 10.0

    enum Outcome: Equatable {
        case written(Date)
        /// De cijfers zijn dezelfde als in de bestanden die er al staan.
        case unchanged
        /// Staat uit, of de app toont voorbeelddata.
        case skipped
        case failed(String)
    }

    private struct Prepared: Sendable {
        let settings: PublishSettings
        let snapshot: PhoneSnapshot
        let html: String
    }

    private struct Written {
        let snapshot: PhoneSnapshot
        let options: PublishOptions
        let folder: URL
    }

    private static var pending: Task<Void, Never>?
    /// Wat er voor het laatst geschreven is; daarmee slaan we een nieuwe versie zonder nieuwe cijfers over.
    /// Dit stopt ook de kring "schrijven → resultaat opslaan → databasewijziging → opnieuw schrijven".
    private static var lastWritten: Written?

    // MARK: Aanroepen vanuit de app

    /// Plant een nieuwe versie in: tien seconden na de laatste wijziging, buiten de hoofdthread.
    static func schedule(_ model: AppModel) {
        guard !model.isDemo, !model.isSnapshot else { return }
        pending?.cancel()
        pending = Task { [weak model] in
            try? await Task.sleep(for: .seconds(quietSeconds))
            guard !Task.isCancelled, let model else { return }
            await publish(model, force: false)
        }
    }

    /// Schrijft direct een nieuwe versie, als de gebruiker dit aan heeft staan. Voor bij afsluiten: wacht tot
    /// het klaar is (de PDF hooguit een paar seconden).
    static func publishNow(_ model: AppModel) {
        guard !model.isDemo, !model.isSnapshot else { return }
        pending?.cancel()
        pending = nil
        let db = model.db
        guard let prepared = try? prepare(db, today: model.today), prepared.settings.enabled,
              let folder = prepared.settings.folderURL, !isUpToDate(prepared, in: folder) else { return }
        let pdf = PhonePDFRenderer.pdfBlocking(html: prepared.html)
        do {
            try write(html: prepared.html, pdf: pdf, to: folder)
            try? db.write { try PublishSettings.recordSuccess($0, at: prepared.snapshot.generatedAt) }
        } catch {
            try? db.write { try PublishSettings.recordFailure($0, message: message(for: error, folder: folder)) }
        }
    }

    /// Schrijft de bestanden. Met `force` ook als het automatisch bijwerken uit staat of er niets veranderd is
    /// (de knop "Nu bijwerken").
    @discardableResult
    static func publish(_ model: AppModel, force: Bool) async -> Outcome {
        guard !model.isDemo, !model.isSnapshot else { return .skipped }
        let db = model.db, today = model.today
        let prepared: Prepared
        do {
            prepared = try await Task.detached(priority: .utility) { try prepare(db, today: today) }.value
        } catch {
            return .failed(error.localizedDescription)
        }
        guard force || prepared.settings.enabled else { return .skipped }
        guard let folder = prepared.settings.folderURL else { return .failed("Er is nog geen map gekozen.") }
        if !force, isUpToDate(prepared, in: folder) { return .unchanged }

        let pdf = try? await PhonePDFRenderer.pdf(html: prepared.html)
        do {
            try await Task.detached(priority: .utility) {
                try write(html: prepared.html, pdf: pdf, to: folder)
                try db.write { database in
                    try PublishSettings.recordSuccess(database, at: prepared.snapshot.generatedAt)
                    if pdf == nil {
                        try PublishSettings.recordFailure(
                            database, message: "Het HTML-bestand is bijgewerkt, maar de PDF kon niet gemaakt worden.")
                    }
                }
            }.value
            lastWritten = Written(snapshot: prepared.snapshot, options: prepared.settings.options, folder: folder)
            return .written(prepared.snapshot.generatedAt)
        } catch {
            let text = message(for: error, folder: folder)
            _ = try? await Task.detached { try db.write { try PublishSettings.recordFailure($0, message: text) } }.value
            return .failed(text)
        }
    }

    /// Schrijft de pagina naar een tijdelijke map en opent hem in de browser. Werkt ook met voorbeelddata en
    /// als het bijwerken uit staat; de gekozen map wordt niet aangeraakt.
    static func preview(_ model: AppModel) async -> Outcome {
        let db = model.db, today = model.today
        do {
            let prepared = try await Task.detached { try prepare(db, today: today) }.value
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("HomeFinance voorbeeld", isDirectory: true)
            let pdf = try? await PhonePDFRenderer.pdf(html: prepared.html)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try write(html: prepared.html, pdf: pdf, to: folder)
            NSWorkspace.shared.open(folder.appendingPathComponent(htmlFileName))
            return .written(prepared.snapshot.generatedAt)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    // MARK: Mappen

    /// iCloud Drive op deze Mac, of nil als die niet aan staat.
    nonisolated static var iCloudDrive: URL? {
        let drive = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        return FileManager.default.fileExists(atPath: drive.path) ? drive : nil
    }

    /// De map ‘HomeFinance vandaag’ in iCloud Drive.
    nonisolated static var iCloudSuggestion: URL? {
        iCloudDrive?.appendingPathComponent(folderName, isDirectory: true)
    }

    /// Voorstel voor de map: naast de back-upmap als die er is, anders in iCloud Drive.
    nonisolated static func defaultFolder(backupFolder: URL?) -> URL? {
        if let backupFolder {
            return backupFolder.deletingLastPathComponent().appendingPathComponent(folderName, isDirectory: true)
        }
        return iCloudSuggestion
    }

    // MARK: Lezen en schrijven

    nonisolated private static func prepare(_ db: AppDatabase, today: Day) throws -> Prepared {
        let (settings, snapshot) = try db.read { database in
            (try PublishSettings.load(database), try PhoneDashboard.make(database, today: today))
        }
        return Prepared(settings: settings, snapshot: snapshot,
                        html: PhoneDashboard.html(snapshot, options: settings.options))
    }

    private static func isUpToDate(_ prepared: Prepared, in folder: URL) -> Bool {
        guard let last = lastWritten, last.folder == folder, last.options == prepared.settings.options,
              last.snapshot.hasSameNumbers(as: prepared.snapshot) else { return false }
        return FileManager.default.fileExists(atPath: folder.appendingPathComponent(htmlFileName).path)
    }

    /// Schrijft beide bestanden. Elk bestand komt eerst onder een tijdelijke naam in dezelfde map en vervangt dan
    /// in één stap het oude, zodat de telefoon nooit een half bestand ziet.
    nonisolated static func write(html: String, pdf: Data?, to folder: URL) throws {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        if !fm.fileExists(atPath: folder.path, isDirectory: &isDirectory) {
            // Alleen de map zelf aanmaken. Ontbreekt ook de map erboven, dan is de cloudmap er niet.
            try fm.createDirectory(at: folder, withIntermediateDirectories: false)
        } else if !isDirectory.boolValue {
            throw CocoaError(.fileWriteUnknown)
        }
        try replace(Data(html.utf8), at: folder.appendingPathComponent(htmlFileName))
        if let pdf { try replace(pdf, at: folder.appendingPathComponent(pdfFileName)) }
    }

    nonisolated private static func replace(_ data: Data, at url: URL) throws {
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString.prefix(8)).tmp")
        do {
            try data.write(to: temporary)
            guard rename(temporary.path, url.path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    nonisolated private static func message(for error: Error, folder: URL) -> String {
        let fm = FileManager.default
        if !fm.fileExists(atPath: folder.deletingLastPathComponent().path) {
            return "De map is niet bereikbaar: \(folder.path). Staat de cloudschijf aan?"
        }
        if fm.fileExists(atPath: folder.path), !fm.isWritableFile(atPath: folder.path) {
            return "HomeFinance mag niet schrijven in \(folder.path)."
        }
        return "Schrijven in \(folder.path) is mislukt: \(error.localizedDescription)"
    }
}

/// Tweede back-upmap (bijvoorbeeld in Google Drive), naast de map van `BackupSettings`.
/// Het pad staat in een eigen instelling; aantal en "bij afsluiten" volgen de gewone back-upinstellingen.
enum SecondBackupSupport {
    static let folderKey = "backup.secondFolderPath"

    static func folderURL(_ db: Database) throws -> URL? {
        try Setting.get(db, folderKey).flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
    }

    static func setFolder(_ db: Database, _ url: URL?) throws {
        try Setting.set(db, folderKey, url?.path)
    }

    /// Maakt een back-up in de tweede map en ruimt daar op. Geeft nil als er geen tweede map is.
    @discardableResult
    static func backup(db: AppDatabase, now: Date = Date()) throws -> BackupInfo? {
        let (folder, keep) = try db.read { (try folderURL($0), try BackupSettings.load($0).keepCount) }
        guard let folder else { return nil }
        // Bestaat de map erboven niet, dan staat de cloudschijf uit: niets aanmaken op een verkeerde plek.
        guard FileManager.default.fileExists(atPath: folder.deletingLastPathComponent().path) else {
            throw BackupError.folderUnavailable(folder.path)
        }
        let info = try Backup.createBackup(from: db, to: folder, now: now)
        _ = try? Backup.prune(in: folder, keep: keep)
        return info
    }

    /// Voor bij afsluiten: alleen als "back-up maken bij afsluiten" aan staat; fouten worden genegeerd.
    static func backupOnQuitIfWanted(db: AppDatabase) {
        guard let settings = try? db.read({ try BackupSettings.load($0) }), settings.autoBackupOnQuit else { return }
        _ = try? backup(db: db)
    }
}
