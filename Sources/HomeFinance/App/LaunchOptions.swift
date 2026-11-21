import Foundation
import HFCore

/// Startopties voor de testronde. Normaal staat er niets op de opdrachtregel en doen deze niets.
///
/// - `--database <pad>`: open dat bestand in plaats van de eigen administratie (bijvoorbeeld een kopie).
///   Geweigerd als het pad in de map van de echte administratie ligt. Back-ups bij afsluiten en het
///   telefoondashboard staan dan uit.
/// - `--voorbeeld`: voorbeelddata. Zonder `--database` in een nieuw tijdelijk bestand; met `--database` alleen
///   als dat bestand nog leeg is. Ook dan draait de app als testdatabase (geen back-up, geen telefoondashboard).
/// - `--zelftest <logbestand>`: opent het echte venster, loopt alle schermen langs en sluit af (zie `SelfTest`).
/// - `--kerncijfers <uitvoer.json>`: schrijft de kerncijfers zonder venster (zie `KeyFiguresCommand`).
/// - `--dag <jjjj-mm-dd>`: peildag voor de kerncijfers en de voorbeelddata; standaard vandaag.
enum LaunchOptions {
    static let arguments = CommandLine.arguments

    static func value(after flag: String) -> String? {
        guard let i = arguments.firstIndex(of: flag), i + 1 < arguments.count else { return nil }
        return arguments[i + 1]
    }

    static func fileURL(after flag: String) -> URL? {
        value(after: flag).map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
    }

    /// Het bestand van `--database`, of nil.
    static let databaseURL: URL? = fileURL(after: "--database")
    static let useDemo = arguments.contains("--voorbeeld")
    static let selfTestLogURL: URL? = fileURL(after: "--zelftest")
    static let keyFiguresURL: URL? = fileURL(after: "--kerncijfers")
    static let dayText: String? = value(after: "--dag")

    /// Een test- of voorbeeldbestand in plaats van de eigen administratie.
    static var isTestRun: Bool { databaseURL != nil || useDemo }

    /// De peildag van `--dag`, of vandaag. Een onleesbare datum is een fout.
    static func day() throws -> Day {
        guard let text = dayText else { return Day.today() }
        guard let day = Day(iso: text) else { throw TestDatabaseError.badDay(text) }
        return day
    }

    /// Opent het testbestand: `--database` (geweigerd in de map van de echte administratie) of, met alleen
    /// `--voorbeeld`, een nieuw tijdelijk bestand. Met `--voorbeeld` komt er voorbeelddata in als het bestand leeg is.
    static func openTestDatabase() throws -> AppDatabase {
        let url: URL
        if let given = databaseURL {
            try refuseRealAdministration(given)
            url = given
        } else {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("HomeFinance-voorbeeld-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            url = dir.appendingPathComponent("voorbeeld.sqlite")
        }
        let db = try AppDatabase.open(at: url)
        if useDemo, try db.read({ try Account.fetchCount($0) }) == 0 {
            try DemoSupport.seed(db, today: try day())
        }
        return db
    }

    /// Weigert elk pad in de map van de echte administratie (`~/Library/Application Support/HomeFinance/`), ook
    /// via een symbolische of harde koppeling naar het echte bestand.
    static func refuseRealAdministration(_ url: URL) throws {
        let realFile = AppDatabase.defaultURL.resolvingSymlinksInPath().standardizedFileURL
        let realDir = realFile.deletingLastPathComponent().path + "/"
        let given = url.resolvingSymlinksInPath().standardizedFileURL
        let givenDir = given.deletingLastPathComponent().resolvingSymlinksInPath().path + "/"
        if given.path == realFile.path || given.path.hasPrefix(realDir) || givenDir.hasPrefix(realDir) {
            throw TestDatabaseError.realAdministration(url.path)
        }
        // Harde koppeling: zelfde bestand op schijf onder een andere naam.
        let fm = FileManager.default
        if let a = try? fm.attributesOfItem(atPath: given.path), let b = try? fm.attributesOfItem(atPath: realFile.path),
           let na = a[.systemFileNumber] as? Int, let nb = b[.systemFileNumber] as? Int,
           let da = a[.systemNumber] as? Int, let dbn = b[.systemNumber] as? Int, na == nb, da == dbn {
            throw TestDatabaseError.realAdministration(url.path)
        }
    }
}

enum TestDatabaseError: Error, LocalizedError {
    case realAdministration(String)
    case badDay(String)

    var errorDescription: String? {
        switch self {
        case .realAdministration(let path):
            "Geweigerd: \(path) is (of staat bij) de echte administratie. Gebruik een kopie op een andere plek."
        case .badDay(let text):
            "Onleesbare datum bij --dag: \(text) (verwacht jjjj-mm-dd)."
        }
    }
}
