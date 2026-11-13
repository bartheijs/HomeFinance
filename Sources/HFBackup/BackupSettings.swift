import Foundation
import GRDB
import HFCore

/// Instellingen voor back-ups, opgeslagen in de tabel `setting`.
public struct BackupSettings: Equatable, Sendable {
    /// Pad van de back-upmap, of nil als er nog geen map is gekozen.
    public var folderPath: String?
    /// Bookmark van de back-upmap (vindt de map terug als hij verplaatst of hernoemd is).
    public var folderBookmark: Data?
    /// Aantal back-ups dat bewaard blijft. Standaard 30.
    public var keepCount: Int
    /// Automatisch een back-up maken bij afsluiten. Standaard aan.
    public var autoBackupOnQuit: Bool
    /// Moment van de laatste geslaagde back-up.
    public var lastBackupAt: Date?

    public static let defaultKeepCount = 30

    public init(folderPath: String? = nil, folderBookmark: Data? = nil, keepCount: Int = BackupSettings.defaultKeepCount,
                autoBackupOnQuit: Bool = true, lastBackupAt: Date? = nil) {
        self.folderPath = folderPath; self.folderBookmark = folderBookmark; self.keepCount = keepCount
        self.autoBackupOnQuit = autoBackupOnQuit; self.lastBackupAt = lastBackupAt
    }

    enum Key {
        static let folderPath = "backup.folderPath"
        static let folderBookmark = "backup.folderBookmark"
        static let keepCount = "backup.keepCount"
        static let autoOnQuit = "backup.autoOnQuit"
        static let lastBackupAt = "backup.lastBackupAt"
    }

    /// Leest de instellingen; ontbrekende waarden krijgen de standaard.
    public static func load(_ db: Database) throws -> BackupSettings {
        var s = BackupSettings()
        s.folderPath = try Setting.get(db, Key.folderPath)
        s.folderBookmark = try Setting.get(db, Key.folderBookmark).flatMap { Data(base64Encoded: $0) }
        if let keep = try Setting.get(db, Key.keepCount).flatMap(Int.init), keep >= 1 { s.keepCount = keep }
        if let auto = try Setting.get(db, Key.autoOnQuit) { s.autoBackupOnQuit = auto == "1" }
        s.lastBackupAt = try Setting.get(db, Key.lastBackupAt).flatMap(Double.init)
            .map { Date(timeIntervalSince1970: $0) }
        return s
    }

    /// Slaat alle instellingen op.
    public func save(_ db: Database) throws {
        try Setting.set(db, Key.folderPath, folderPath)
        try Setting.set(db, Key.folderBookmark, folderBookmark?.base64EncodedString())
        try Setting.set(db, Key.keepCount, String(max(keepCount, 1)))
        try Setting.set(db, Key.autoOnQuit, autoBackupOnQuit ? "1" : "0")
        try Self.setLastBackup(db, lastBackupAt)
    }

    /// Legt alleen het moment van de laatste back-up vast.
    public static func setLastBackup(_ db: Database, _ date: Date?) throws {
        try Setting.set(db, Key.lastBackupAt, date.map { String($0.timeIntervalSince1970) })
    }

    /// Kiest de back-upmap: bewaart het pad en, als dat lukt, een bookmark.
    public mutating func setFolder(_ url: URL?) {
        folderPath = url?.path
        folderBookmark = url.flatMap { try? $0.bookmarkData() }
    }

    /// De back-upmap: via de bookmark als die nog klopt, anders via het pad.
    public var folderURL: URL? {
        if let folderBookmark {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: folderBookmark, bookmarkDataIsStale: &stale) { return url }
        }
        return folderPath.map { URL(fileURLWithPath: $0, isDirectory: true) }
    }
}
