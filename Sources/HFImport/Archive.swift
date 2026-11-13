import Foundation
import GRDB
import HFCore

/// Bij welke rekening een bestand hoort, volgens het IBAN in het bestand of in de bestandsnaam.
public struct AccountMatch: Equatable, Sendable {
    /// Het gevonden IBAN zonder spaties; leeg als er geen is gevonden.
    public var iban: String
    /// De rekening met dat IBAN, of nil als die niet bestaat.
    public var account: Account?
    /// Nederlandse melding als er geen rekening is, anders nil.
    public var message: String? {
        guard account == nil else { return nil }
        return iban.isEmpty
            ? "In het bestand en de bestandsnaam staat geen IBAN; kies zelf de rekening."
            : "Geen rekening met IBAN \(iban) gevonden."
    }
}

/// Eén bestand uit een zip van de bank.
public struct ArchiveItem: Identifiable, Equatable, Sendable {
    /// Pad van het bestand binnen de zip.
    public var fileName: String
    /// Het IBAN uit de regels van het bestand, anders uit de bestandsnaam; leeg als er geen is.
    public var iban: String
    public var account: Account?
    /// Het voorbeeld, als het bestand gelezen kon worden en bij een rekening hoort.
    public var preview: ImportPreview?
    /// Nederlandse melding waarom dit bestand niet geïmporteerd wordt; nil als het meegaat.
    public var message: String?

    public var id: String { fileName }
    /// Dit bestand gaat mee bij `commitArchive`.
    public var isImportable: Bool { preview.map { !$0.rows.isEmpty } ?? false }
}

/// De inhoud van een zip van de bank: per bestand een onderdeel. Niets valt stil weg.
public struct ArchivePreview: Equatable, Sendable {
    public var fileName: String
    public var items: [ArchiveItem]

    /// De onderdelen die geïmporteerd worden.
    public var importableItems: [ArchiveItem] { items.filter(\.isImportable) }
    /// De onderdelen die niet meegaan, elk met een melding.
    public var skippedItems: [ArchiveItem] { items.filter { !$0.isImportable } }
    public var newCount: Int { importableItems.compactMap(\.preview?.newCount).reduce(0, +) }
    public var duplicateCount: Int { importableItems.compactMap(\.preview?.duplicateCount).reduce(0, +) }
    public var errorCount: Int { importableItems.compactMap(\.preview?.errorCount).reduce(0, +) }
    /// Regels van op of vóór de overgangsdag, over alle bestanden.
    public var cutoverSkippedCount: Int { importableItems.compactMap(\.preview?.cutoverSkippedCount).reduce(0, +) }
    /// Importeren kan zonder de keuze om foute regels over te slaan.
    public var canCommit: Bool { !importableItems.isEmpty && errorCount == 0 }
}

/// Wat er voor één bestand uit de zip is geïmporteerd.
public struct ArchiveImportResult: Equatable, Sendable {
    public var fileName: String
    public var account: Account
    public var result: ImportResult
}

public extension BankImporter {
    // MARK: Rekening bij een bestand

    /// Zoekt de rekening bij een bestand: het eigen IBAN uit de gelezen regels, anders het IBAN waarmee de
    /// bestandsnaam begint (bv. "NL00TEST0000000001-13-11-2026T13_33_15.csv").
    func matchAccount(forFileNamed fileName: String, rows: [ImportRow] = []) throws -> AccountMatch {
        try database.read { try Self.match($0, fileName: fileName, rows: rows) }
    }

    /// Als hierboven, maar leest het bestand eerst zelf (CSV of PDF); handig vóór de gebruiker een rekening kiest.
    func matchAccount(data: Data, fileName: String) throws -> AccountMatch {
        let iban = Self.ownIban(data: data, fileName: fileName)
        return try database.read { try Self.match($0, iban: iban) }
    }

    // MARK: Zip

    /// Pakt een zip van de bank uit en maakt per bestand een onderdeel met de bijbehorende rekening en het
    /// voorbeeld. Schrijft niets in de database; de tijdelijke map wordt weer opgeruimd.
    ///
    /// `skipThrough` is de overgangsdag voor alle rekeningen; `skipThroughByAccount` (rekening-id → dag) gaat
    /// voor als de rekeningen een eigen overgangsdag hebben (zie `historyCutover`).
    /// `resumeFromBalance` (rekening-id → saldo van de administratie) zoekt per rekening eerst op saldo waar het
    /// bestand aansluit; geef alleen rekeningen mee waarvoor `needsSeam` true is.
    func previewArchive(url: URL, skipThrough: Day? = nil, skipThroughByAccount: [Int64: Day] = [:],
                        resumeFromBalance: [Int64: Money] = [:]) throws -> ArchivePreview {
        let files = try ZipArchive.extract(url: url)
        return try previewArchive(files: files, fileName: url.lastPathComponent, skipThrough: skipThrough,
                                  skipThroughByAccount: skipThroughByAccount, resumeFromBalance: resumeFromBalance)
    }

    /// Als hierboven, voor een zip in het geheugen.
    func previewArchive(data: Data, fileName: String, skipThrough: Day? = nil,
                        skipThroughByAccount: [Int64: Day] = [:],
                        resumeFromBalance: [Int64: Money] = [:]) throws -> ArchivePreview {
        let files = try ZipArchive.extract(data: data)
        return try previewArchive(files: files, fileName: fileName, skipThrough: skipThrough,
                                  skipThroughByAccount: skipThroughByAccount, resumeFromBalance: resumeFromBalance)
    }

    /// Importeert alle onderdelen met een rekening in één databasetransactie: alles of niets.
    /// Hebben de voorbeelden foute regels, dan volgt `ImportError.rowErrors`, tenzij `skipFaultyRows` true is.
    /// Zonder enig importeerbaar onderdeel volgt `ImportError.nothingToImport`.
    @discardableResult
    func commitArchive(_ archive: ArchivePreview, skipFaultyRows: Bool = false) throws -> [ArchiveImportResult] {
        let items = archive.importableItems
        guard !items.isEmpty else { throw ImportError.nothingToImport }
        if archive.errorCount > 0, !skipFaultyRows { throw ImportError.rowErrors(archive.errorCount) }
        return try database.write { db in
            try items.map { item in
                ArchiveImportResult(fileName: item.fileName, account: item.account!,
                                    result: try Self.insert(db, item.preview!))
            }
        }
    }

    internal func previewArchive(files: [ZipArchive.File], fileName: String, skipThrough: Day?,
                                 skipThroughByAccount: [Int64: Day],
                                 resumeFromBalance: [Int64: Money] = [:]) throws -> ArchivePreview {
        var items: [ArchiveItem] = []
        for file in files.sorted(by: { $0.name < $1.name }) {
            var item = ArchiveItem(fileName: file.name, iban: "", account: nil, preview: nil, message: nil)
            defer { items.append(item) }

            guard let data = file.data else {
                item.message = file.problem ?? "Het bestand kan niet worden gelezen."
                continue
            }
            let ext = (file.name as NSString).pathExtension.lowercased()
            let isPDF = PDFStatement.isPDF(data: data, fileName: file.name)
            guard isPDF || ["csv", "txt"].contains(ext) else {
                item.message = "Dit bestandstype wordt niet ondersteund (alleen CSV en PDF)."
                continue
            }
            if data.isEmpty || (!isPDF && ((try? CSVFile(data: data))?.records.isEmpty ?? false)) {
                item.message = "Het bestand is leeg."
                continue
            }
            let match = try matchAccount(data: data, fileName: file.name)
            item.iban = match.iban
            item.account = match.account
            guard let accountId = match.account?.id else {
                item.message = match.message
                continue
            }
            do {
                let preview = try self.preview(data: data, fileName: file.name, accountId: accountId,
                                               skipThrough: skipThroughByAccount[accountId] ?? skipThrough,
                                               resumeFromBalance: resumeFromBalance[accountId])
                item.preview = preview
                if preview.rows.isEmpty {
                    item.message = preview.errors.isEmpty
                        ? "Het bestand bevat geen transacties."
                        : "Geen enkele regel van het bestand kon worden gelezen."
                }
            } catch {
                item.message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
        return ArchivePreview(fileName: fileName, items: items)
    }

    // MARK: Intern

    internal static func match(_ db: Database, fileName: String, rows: [ImportRow]) throws -> AccountMatch {
        try match(db, iban: mostCommonOwnIban(rows) ?? ibanInFileName(fileName))
    }

    internal static func match(_ db: Database, iban: String) throws -> AccountMatch {
        guard !iban.isEmpty else { return AccountMatch(iban: "", account: nil) }
        let account = try Account.fetchAll(db).first { $0.iban.map(normalizeIban) == iban }
        return AccountMatch(iban: iban, account: account)
    }

    internal static func mostCommonOwnIban(_ rows: [ImportRow]) -> String? {
        var counts: [String: Int] = [:]
        for row in rows where !row.ownIban.isEmpty { counts[row.ownIban, default: 0] += 1 }
        return counts.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key
    }

    internal static func ibanInFileName(_ fileName: String) -> String {
        let base = ((fileName as NSString).lastPathComponent as NSString).deletingPathExtension.uppercased()
        guard let m = base.firstMatch(of: #/[A-Z]{2}\d{2}[A-Z0-9]{11,30}/#) else { return "" }
        return String(m.0)
    }

    /// Het eigen IBAN volgens de inhoud van het bestand, anders volgens de bestandsnaam.
    internal static func ownIban(data: Data, fileName: String) -> String {
        if PDFStatement.isPDF(data: data, fileName: fileName) {
            if let pages = try? PDFStatement.pages(of: data), let statement = try? StatementParser.parse(pages: pages),
               !statement.ownIban.isEmpty {
                return statement.ownIban
            }
        } else if let file = try? CSVFile(data: data), let profile = BankProfile.detect(for: file) {
            let placeholder = Account(id: 0, name: "", kind: .betaal, openingDate: .today())
            if let preview = try? ImportPreview.build(file: file, fileName: fileName, account: placeholder, profile: profile),
               let iban = mostCommonOwnIban(preview.rows) {
                return iban
            }
        }
        return ibanInFileName(fileName)
    }
}

/// Pakt een zip uit naar een tijdelijke map, leest de bestanden en ruimt de map weer op.
enum ZipArchive {
    struct File {
        /// Pad binnen de zip.
        var name: String
        var data: Data?
        /// Waarom het bestand niet gelezen is.
        var problem: String?
    }

    static func extract(data: Data) throws -> [File] {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let zip = directory.appendingPathComponent("archief.zip")
        try data.write(to: zip)
        return try extract(zip: zip, workDirectory: directory)
    }

    static func extract(url: URL) throws -> [File] {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        return try extract(zip: url, workDirectory: directory)
    }

    private static func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HomeFinance-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        return directory
    }

    private static func extract(zip: URL, workDirectory: URL) throws -> [File] {
        // Eerst de namen bekijken: een pad dat buiten de map uitkomt, weigert het hele archief.
        let listing = try run("/usr/bin/unzip", ["-Z1", zip.path])
        guard listing.status == 0 else { throw ImportError.archiveUnreadable }
        let names = listing.output.split(separator: "\n").map(String.init)
        for name in names {
            let parts = name.split(separator: "/", omittingEmptySubsequences: false)
            if name.hasPrefix("/") || name.hasPrefix("~") || parts.contains("..") || name.contains("\\") {
                throw ImportError.archiveUnsafePath(name)
            }
        }

        let target = workDirectory.appendingPathComponent("inhoud", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let unpack = try run("/usr/bin/unzip", ["-qq", "-o", zip.path, "-d", target.path])
        guard unpack.status == 0 else { throw ImportError.archiveUnreadable }

        let root = target.resolvingSymlinksInPath().path + "/"
        var files: [File] = []
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey]
        guard let walker = FileManager.default.enumerator(at: target, includingPropertiesForKeys: keys) else {
            throw ImportError.archiveUnreadable
        }
        for case let url as URL in walker {
            let values = try url.resourceValues(forKeys: Set(keys))
            if values.isDirectory == true && values.isSymbolicLink != true { continue }
            let path = url.standardizedFileURL.path
            let resolved = url.resolvingSymlinksInPath().path
            let prefix = target.standardizedFileURL.path + "/"
            let name = path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : url.lastPathComponent
            // Ruis van macOS zelf telt niet als bestand.
            if name.hasPrefix("__MACOSX/") || url.lastPathComponent == ".DS_Store" { continue }
            if values.isSymbolicLink == true || !resolved.hasPrefix(root) || values.isRegularFile != true {
                files.append(File(name: name, data: nil, problem: "Snelkoppelingen in een zip worden niet gelezen."))
                continue
            }
            files.append(File(name: name, data: try? Data(contentsOf: url), problem: nil))
        }
        return files
    }

    private static func run(_ tool: String, _ arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { throw ImportError.archiveUnreadable }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
