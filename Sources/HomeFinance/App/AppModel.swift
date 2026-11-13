import SwiftUI
import GRDB
import HFCore

/// De schermen in de zijbalk.
enum Screen: String, CaseIterable, Identifiable, Hashable {
    case dashboard, review, grid, transactions, pots, reimbursements, reports, rules, settings
    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard: "Dashboard"
        case .review: "Importeren en nakijken"
        case .grid: "Maandgrid"
        case .transactions: "Transacties"
        case .pots: "Potten en sparen"
        case .reimbursements: "Spaaroverboekingen"
        case .reports: "Rapporten"
        case .rules: "Regels"
        case .settings: "Instellingen"
        }
    }

    var icon: String {
        switch self {
        case .dashboard: "gauge.with.dots.needle.50percent"
        case .review: "tray.and.arrow.down"
        case .grid: "tablecells"
        case .transactions: "list.bullet.rectangle"
        case .pots: "square.grid.3x3.topleft.filled"
        case .reimbursements: "arrow.left.arrow.right.circle"
        case .reports: "chart.bar.xaxis"
        case .rules: "wand.and.stars"
        case .settings: "gearshape"
        }
    }

    static let overview: [Screen] = [.dashboard, .review, .grid, .transactions]
    static let savings: [Screen] = [.pots, .reimbursements]
    static let insight: [Screen] = [.reports, .rules]
}

/// Gedeelde toestand van de app: de database, het gekozen jaar en de navigatie.
/// Schermen laden hun gegevens opnieuw wanneer `revision` verandert (na elke schrijfactie).
@MainActor @Observable
final class AppModel {
    private(set) var db: AppDatabase
    /// De app toont voorbeelddata (aparte database), niet de eigen administratie.
    private(set) var isDemo: Bool
    /// Loopt op na elke wijziging in de database.
    private(set) var revision = 0
    var selection: Screen = .dashboard
    var settingsTab: String = "jaar"
    /// Het begrotingsjaar dat de schermen tonen.
    var year: Int
    /// Vaste "vandaag" voor snapshots en tests; normaal nil (= echte datum).
    var fixedToday: Day?
    /// De app tekent schermen naar PNG (zie Snapshot).
    var isSnapshot = false
    var errorMessage: String?
    /// Korte bevestiging onderin (bv. "12 transacties geboekt").
    var toast: String?

    @ObservationIgnored private var observer: AnyDatabaseCancellable?

    var today: Day { fixedToday ?? Day.today() }

    init(db: AppDatabase, isDemo: Bool, today: Day? = nil) {
        self.db = db
        self.isDemo = isDemo
        self.fixedToday = today
        self.year = (today ?? Day.today()).year
        observe()
    }

    // MARK: Database kiezen

    static var demoURL: URL {
        AppDatabase.defaultURL.deletingLastPathComponent().appendingPathComponent("voorbeeld.sqlite")
    }

    static func launch() -> AppModel {
        let wantsDemo = UserDefaults.standard.bool(forKey: "toonVoorbeelddata")
        do {
            if wantsDemo {
                return AppModel(db: try DemoSupport.openDemo(at: demoURL), isDemo: true)
            }
            return AppModel(db: try AppDatabase.open(at: AppDatabase.defaultURL), isDemo: false)
        } catch {
            // Laatste redmiddel: een lege database in het geheugen, met de fout in beeld.
            let m = AppModel(db: try! AppDatabase.inMemory(), isDemo: false)
            m.errorMessage = "De database kon niet geopend worden: \(error.localizedDescription)"
            return m
        }
    }

    func switchToDemo() {
        perform {
            let demo = try DemoSupport.openDemo(at: Self.demoURL)
            UserDefaults.standard.set(true, forKey: "toonVoorbeelddata")
            replace(db: demo, isDemo: true)
        }
    }

    func switchToOwnData() {
        perform {
            let own = try AppDatabase.open(at: AppDatabase.defaultURL)
            UserDefaults.standard.set(false, forKey: "toonVoorbeelddata")
            replace(db: own, isDemo: false)
        }
    }

    private func replace(db: AppDatabase, isDemo: Bool) {
        observer?.cancel()
        self.db = db
        self.isDemo = isDemo
        self.year = today.year
        self.selection = .dashboard
        observe()
        revision += 1
    }

    private func observe() {
        let observation = DatabaseRegionObservation(tracking: .fullDatabase)
        observer = observation.start(in: db.writer, onError: { _ in }, onChange: { [weak self] _ in
            Task { @MainActor in self?.revision += 1 }
        })
    }

    // MARK: Hulpjes voor schermen

    /// Is er al een administratie (minstens één rekening)?
    var hasData: Bool {
        read(false) { try Account.fetchCount($0) > 0 }
    }

    /// Lezen met een terugvalwaarde; een fout komt in beeld.
    func read<T>(_ fallback: T, _ block: (Database) throws -> T) -> T {
        do { return try db.read(block) } catch {
            errorMessage = error.localizedDescription
            return fallback
        }
    }

    /// Voert een actie uit en toont een eventuele fout. Geeft terug of het gelukt is.
    @discardableResult
    func perform(_ success: String? = nil, _ action: () throws -> Void) -> Bool {
        do {
            try action()
            if let success { toast = success }
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func onQuit() {
        guard !isDemo else { return }
        BackupSupport.backupOnQuitIfWanted(db: db)
    }
}
