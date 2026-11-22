import SwiftUI
import GRDB
import HFCore
import HFBudget
import os

/// De schermen in de zijbalk, in de volgorde van de zijbalk (zie `SidebarGroup.all`).
enum Screen: String, CaseIterable, Identifiable, Hashable {
    case dashboard, settleUp, review, transactions, tags, grid, budget, pots, distributions, reimbursements, reports, settings
    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard: "Dashboard"
        case .settleUp: "Te doen"
        case .review: "Importeren en nakijken"
        case .transactions: "Transacties"
        case .tags: "Tags"
        case .grid: "Maandgrid"
        case .budget: "Posten"
        case .pots: "Potjes"
        case .distributions: "Automatisch sparen"
        case .reimbursements: "Nog overboeken"
        case .reports: "Rapporten"
        case .settings: "Instellingen"
        }
    }

    var icon: String {
        switch self {
        case .dashboard: "gauge.with.dots.needle.50percent"
        case .settleUp: "checklist"
        case .review: "tray.and.arrow.down"
        case .transactions: "list.bullet.rectangle"
        case .tags: "tag"
        case .grid: "tablecells"
        case .budget: "list.bullet.clipboard"
        case .pots: "square.grid.3x3.topleft.filled"
        case .distributions: "arrow.triangle.branch"
        case .reimbursements: "arrow.left.arrow.right.circle"
        case .reports: "chart.bar.xaxis"
        case .settings: "gearshape"
        }
    }
}

/// Een groep in de zijbalk: ingedeeld naar wat je komt doen (UX-stap C1). De laatste groep heeft geen kop.
struct SidebarGroup: Identifiable {
    let title: String
    let screens: [Screen]
    var id: String { title }

    static let all: [SidebarGroup] = [
        // Te doen vervangt in de zijbalk het losse scherm Nog overboeken (UX-stap D4); dat scherm blijft
        // bestaan en is bereikbaar vanuit Te doen en de andere links. Maandgrid staat onder Inzicht (UX-feedback).
        SidebarGroup(title: "Vandaag", screens: [.dashboard, .settleUp]),
        SidebarGroup(title: "Bijwerken", screens: [.review, .transactions, .tags]),
        SidebarGroup(title: "Begroting", screens: [.budget]),
        SidebarGroup(title: "Sparen", screens: [.pots, .distributions]),
        SidebarGroup(title: "Inzicht", screens: [.grid]),   // Rapporten tijdelijk uit de zijbalk (wens gebruiker 22-11-2026)
        SidebarGroup(title: "", screens: [.settings]),
    ]

    /// De schermen die een regel in de zijbalk hebben (niet elk scherm: Nog overboeken zit in Te doen).
    static var sidebarScreens: [Screen] { all.flatMap(\.screens) }
}

/// Transacties openen op een rekening met het filter op een tag.
/// Vraag aan Importeren en nakijken om deze banktransactie te selecteren (bv. vanuit het maandgrid).
struct ReviewJump: Equatable {
    var accountId: Int64
    var transactionId: Int64
}

/// Sprong in de keten post ↔ vaste storting ↔ potje (UX-stap B2). Het doelscherm neemt hem over en zet hem
/// terug op nil.
enum ChainJump: Equatable {
    /// Vaste stortingen, met deze storting geselecteerd.
    case distribution(Int64)
    /// Posten, met deze post van dit jaar opengeklapt.
    case item(Int64, year: Int)
}

struct TransactionsJump: Equatable {
    var accountId: Int64
    var tagId: Int64?
    /// Alleen de boekingen die als tijdelijk geleend van spaar gemarkeerd zijn (vanuit Te doen).
    var loanOnly = false
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
    /// De app opent op de transacties, net als een bank-app; met voorbeelddata op het Dashboard, waar je meteen
    /// ziet wat er te besteden is.
    var selection: Screen = .transactions
    var settingsTab: String = "rekeningen"
    /// Vraag aan Transacties om te openen op deze rekening met dit filter (bv. vanuit Instellingen › Tags).
    /// Transacties neemt het over en zet het terug op nil.
    var transactionsJump: TransactionsJump?
    /// Vraag aan Importeren en nakijken om op deze banktransactie te openen. Nakijken neemt het over en zet het
    /// terug op nil.
    var reviewJump: ReviewJump?
    /// Vraag om naar de andere kant van de keten te gaan (zie `ChainJump`).
    var chainJump: ChainJump?
    /// Het begrotingsjaar dat de schermen tonen.
    var year: Int
    /// Vaste "vandaag" voor snapshots en tests; normaal nil (= echte datum).
    var fixedToday: Day?
    /// De app tekent schermen naar PNG (zie Snapshot).
    var isSnapshot = false
    /// Toont het venster om de Excel-historie te importeren.
    var showHistoryImport = false
    var errorMessage: String?
    /// Korte bevestiging onderin (bv. "12 transacties geboekt").
    var toast: String?

    @ObservationIgnored private var observer: AnyDatabaseCancellable?

    var today: Day { fixedToday ?? Day.today() }

    /// Gaat naar de andere kant van de keten: de vaste storting (Vaste stortingen) of de post (Posten).
    func jump(_ target: ChainJump) {
        chainJump = target
        switch target {
        case .distribution: selection = .distributions
        case .item(_, let year):
            self.year = year
            selection = .budget
        }
    }

    init(db: AppDatabase, isDemo: Bool, today: Day? = nil) {
        self.db = db
        self.isDemo = isDemo
        self.fixedToday = today
        self.year = (today ?? Day.today()).year
        self.selection = isDemo ? .dashboard : .transactions
        observe()
        autoReconcile(announce: false)
    }

    // MARK: Database kiezen

    static var demoURL: URL {
        AppDatabase.defaultURL.deletingLastPathComponent().appendingPathComponent("voorbeeld.sqlite")
    }

    /// Gestart met `--database` of `--voorbeeld`: een testbestand, niet de eigen administratie. Geen back-up bij
    /// afsluiten, geen telefoondashboard en niet wisselen naar de eigen administratie of de voorbeelddata.
    private(set) var isTestDatabase = false
    /// Fouten uit `read` en `perform` (en bij het openen), voor de zelftest. Leeg als alles goed ging.
    @ObservationIgnored private(set) var failures: [String] = []

    static func launch() -> AppModel {
        if LaunchOptions.isTestRun {
            // Nooit terugvallen op de eigen administratie: bij een fout een lege database met de fout in beeld.
            do {
                let m = AppModel(db: try LaunchOptions.openTestDatabase(), isDemo: false)
                m.isTestDatabase = true
                return m
            } catch {
                let m = AppModel(db: try! AppDatabase.inMemory(), isDemo: false)
                m.isTestDatabase = true
                m.failures.append("openen: \(error.localizedDescription)")
                m.errorMessage = "De testdatabase kon niet geopend worden: \(error.localizedDescription)"
                return m
            }
        }
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
        guard !isTestDatabase else { return }
        perform {
            let demo = try DemoSupport.openDemo(at: Self.demoURL)
            UserDefaults.standard.set(true, forKey: "toonVoorbeelddata")
            replace(db: demo, isDemo: true)
        }
    }

    func switchToOwnData() {
        guard !isTestDatabase else { return }
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
        self.selection = isDemo ? .dashboard : .transactions
        observe()
        autoReconcile(announce: false)
        revision += 1
    }

    // MARK: Automatisch afstemmen

    @ObservationIgnored private static let log = Logger(subsystem: "HomeFinance", category: "afstemmen")

    /// Legt stil een afstemming vast voor elke volledig geboekte import die exact aansluit op het eindsaldo van
    /// de bank (`BalanceService.autoReconcileAll`). Zonder `accountIds` voor alle rekeningen. Fouten komen niet
    /// in beeld maar in het log. Met `announce` komt er een toast bij een nieuwe afstemming, achter een
    /// eventuele melding die er al staat.
    func autoReconcile(accountIds: [Int64]? = nil, announce: Bool = true) {
        do {
            let created: [Reconciliation] = try db.write { db in
                let ids = try accountIds ?? Int64.fetchAll(db, sql: "SELECT id FROM account WHERE archived = 0")
                return try ids.flatMap { try BalanceService.autoReconcileAll(db, accountId: $0) }
            }
            guard announce, let newest = created.max(by: { $0.day < $1.day }) else { return }
            let text = "Afgestemd met de bank: \(newest.actualBalance.formatted()) op \(newest.day.dutch)"
            toast = toast.map { "\($0) · \(text)" } ?? text
        } catch {
            Self.log.error("Automatisch afstemmen mislukt: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func observe() {
        let observation = DatabaseRegionObservation(tracking: .fullDatabase)
        observer = observation.start(in: db.writer, onError: { _ in }, onChange: { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.revision += 1
                if !self.isTestDatabase { PublishSupport.schedule(self) }
            }
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
            failures.append("read (\(T.self)): \(error.localizedDescription)")
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
            failures.append("perform: \(error.localizedDescription)")
            errorMessage = error.localizedDescription
            return false
        }
    }

    func onQuit() {
        guard !isDemo, !isTestDatabase else { return }
        BackupSupport.backupOnQuitIfWanted(db: db)
        PublishSupport.publishNow(self)
    }
}
