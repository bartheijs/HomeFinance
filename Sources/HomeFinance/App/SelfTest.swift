import SwiftUI
import AppKit
import HFCore

/// Zelftest van de echte app: `HomeFinance --database <kopie> --zelftest <logbestand>` (of met `--voorbeeld`).
///
/// Opent het gewone venster (de echte `NavigationSplitView`, niet de nagetekende zijbalk van de snapshots), loopt
/// alle schermen uit `Screen.allCases` langs via `model.selection` en controleert:
/// - de zijbalk verscheen, met een regel voor elk scherm (SwiftUI) en evenveel zichtbare rijen in AppKit;
/// - elk scherm verscheen binnen `screenTimeout`;
/// - `model.errorMessage` bleef leeg;
/// - er waren geen fouten in `model.read` of `model.perform` (`AppModel.failures`).
///
/// Schrijft per controle een regel "OK …" of "FOUT …" naar het logbestand en eindigt met exitcode 0 (alles OK) of
/// 1. Een bewaker op een eigen thread stopt het proces na `hardLimit` seconden met exitcode 1, ook als de
/// hoofdthread vastzit. Er worden geen bedragen, namen of IBAN's gelogd.
@MainActor
enum SelfTest {
    static let screenTimeout: Duration = .seconds(5)
    static let hardLimit: TimeInterval = 90

    static var isOn: Bool { LaunchOptions.selfTestLogURL != nil }
    nonisolated static var isOnNonisolated: Bool { LaunchOptions.selfTestLogURL != nil }

    // MARK: Waarnemingen uit de views (doen niets buiten de zelftest)

    private static var screenAppearances: [Screen: Int] = [:]
    private static var sidebarRows: Set<Screen> = []

    static func screenAppeared(_ screen: Screen) {
        guard isOn else { return }
        screenAppearances[screen, default: 0] += 1
    }

    static func sidebarRowAppeared(_ screen: Screen) {
        guard isOn else { return }
        sidebarRows.insert(screen)
    }

    /// Laatst gemeten plek (in venstercoördinaten, oorsprong linksboven) van views met `.selfTestProbe(_:)`.
    private static var probeFrames: [String: CGRect] = [:]

    static func probe(_ name: String, frame: CGRect) {
        guard isOn else { return }
        probeFrames[name] = frame
    }

    // MARK: Logbestand

    private nonisolated(unsafe) static var handle: FileHandle?
    private static var failed = 0
    private static var passed = 0

    private nonisolated static func write(_ line: String) {
        let stamp = Date().formatted(.iso8601.time(includingFractionalSeconds: true))
        handle?.write(Data("\(stamp) \(line)\n".utf8))
    }

    private static func check(_ ok: Bool, _ text: String) {
        if ok { passed += 1 } else { failed += 1 }
        write("\(ok ? "OK  " : "FOUT") \(text)")
    }

    // MARK: Verloop

    /// Start de zelftest. Aangeroepen bij het opstarten van de app, vóór het venster er is.
    static func start(model: @escaping @MainActor () -> AppModel?) {
        guard let url = LaunchOptions.selfTestLogURL else { return }
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try? FileHandle(forWritingTo: url)
        write("zelftest gestart (harde tijdslimiet \(Int(hardLimit)) s)")
        write("versie (zoals bij Instellingen › Over): \(BuildInfo.current.displayText)")

        // Bewaker: werkt ook als de hoofdthread vastloopt.
        Thread.detachNewThread {
            Thread.sleep(forTimeInterval: hardLimit)
            write("FOUT tijdslimiet van \(Int(hardLimit)) s overschreden; de app reageerde niet op tijd")
            write("UITSLAG: NIET GESLAAGD")
            try? handle?.synchronize()
            exit(1)
        }

        Task { @MainActor in
            await run(model: model)
            finish()
        }
    }

    private static func run(model: @MainActor () -> AppModel?) async {
        // 1. Het venster en het model.
        let windowUp = await wait(.seconds(15)) { model() != nil && mainWindow() != nil }
        check(windowUp, "venster geopend" + (windowUp ? "" : " (model \(model() == nil ? "ontbreekt" : "er"), "
              + "vensters: \(NSApp.windows.map { "\($0.className) zichtbaar=\($0.isVisible)" })"))
        guard windowUp, let model = model() else { return }
        check(model.isTestDatabase, "app draait op het testbestand, niet op de eigen administratie")
        check(model.hasData, "administratie heeft gegevens (anders verschijnt het welkomstscherm)")

        // 2. De zijbalk.
        let expected = Set(Screen.allCases)
        let rowsUp = await wait(.seconds(5)) { sidebarRows == expected }
        check(rowsUp, "zijbalk verscheen met \(expected.count) regels (gezien: \(sidebarRows.count))")
        let appKitRows = await waitValue(.seconds(3)) { visibleSidebarRowCount() } until: { $0 >= expected.count }
        check(appKitRows >= expected.count,
              "zijbalk toont in het venster minstens \(expected.count) rijen met inhoud (gevonden: \(appKitRows))")

        // 3. Elk scherm.
        for screen in Screen.allCases {
            let before = screenAppearances[screen, default: 0]
            let alreadyShown = model.selection == screen
            if !alreadyShown { model.selection = screen }
            let appeared = await wait(screenTimeout) {
                screenAppearances[screen, default: 0] > (alreadyShown ? 0 : before)
            }
            check(appeared, "scherm \(screen.rawValue) (\(screen.title)) verscheen")
            // Even laten tekenen en laden, dan pas naar fouten kijken.
            try? await Task.sleep(for: .milliseconds(400))
            check(model.errorMessage == nil, "geen foutmelding in beeld op \(screen.rawValue)"
                  + (model.errorMessage.map { ": \($0)" } ?? ""))
            model.errorMessage = nil
        }

        // 3b. Transacties: de kop blijft zichtbaar en het downloadblok (6a) staat eronder, ook in het kleinste venster.
        await checkTransactionsHeader(model: model)

        // 4. De zijbalk staat er na de ronde nog (een zijbalk die later leeg wordt, valt hier op).
        let rowsAfter = visibleSidebarRowCount()
        check(rowsAfter >= expected.count,
              "zijbalk toont na de ronde nog minstens \(expected.count) rijen met inhoud (gevonden: \(rowsAfter))")

        // 5. Fouten in read/perform over de hele ronde.
        check(model.failures.isEmpty, "geen fouten in model.read/perform (\(model.failures.count))")
        for f in model.failures.prefix(20) { write("     \(f)") }
    }

    private static func checkTransactionsHeader(model: AppModel) async {
        model.selection = .transactions
        guard let window = mainWindow() else { return }
        let original = window.frame
        // Gewone maat, daarna de kleinste maat die het venster toelaat (1100 × 700 inhoud).
        let sizes: [(String, NSSize?)] = [("huidige venstermaat", nil), ("kleinste venstermaat", NSSize(width: 1100, height: 700))]
        for (label, size) in sizes {
            probeFrames = [:]  // alleen metingen na deze maatwijziging tellen
            if let size { window.setContentSize(size) }
            try? await Task.sleep(for: .milliseconds(600))
            let height = window.contentView?.bounds.height ?? 0
            // Onder de werkbalk: een kop die eronder of erboven wegvalt, telt als niet zichtbaar.
            let top = max(0, height - window.contentLayoutRect.maxY)
            let inWindow: (CGRect) -> Bool = { $0.width > 0 && $0.height > 0 && $0.minY >= top - 0.5 && $0.maxY <= height + 0.5 }
            let header = await waitValue(.seconds(3)) { probeFrames["transacties-kop"] } until: { $0.map(inWindow) ?? false }
            check(header.map(inWindow) ?? false, "Transacties: kop zichtbaar in het venster (\(label))"
                  + (header.map { " y \(Int($0.minY))–\(Int($0.maxY)), zichtbaar gebied \(Int(top))–\(Int(height))" } ?? ", niet gezien"))
            let block = await waitValue(.seconds(3)) { probeFrames["transacties-downloadblok"] } until: { $0.map(inWindow) ?? false }
            check(block.map(inWindow) ?? false, "Transacties: downloadblok verscheen in het venster (\(label))"
                  + (block.map { " y \(Int($0.minY))–\(Int($0.maxY))" } ?? ", niet gezien"))
            if let header, let block {
                check(block.minY >= header.maxY - 0.5, "Transacties: downloadblok staat onder de kop (\(label))")
            }
        }
        window.setFrame(original, display: true)
        try? await Task.sleep(for: .milliseconds(300))
    }

    private static func finish() {
        let ok = failed == 0
        write("\(passed) OK, \(failed) FOUT")
        write("UITSLAG: \(ok ? "GESLAAGD" : "NIET GESLAAGD")")
        try? handle?.synchronize()
        // Direct stoppen, zonder de gewone afsluitroute (geen back-up, geen telefoondashboard).
        exit(ok ? 0 : 1)
    }

    // MARK: Hulpjes

    private static func wait(_ limit: Duration, _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + limit
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    private static func waitValue<T>(_ limit: Duration, _ value: () -> T, until: (T) -> Bool) async -> T {
        let deadline = ContinuousClock.now + limit
        while ContinuousClock.now < deadline {
            let v = value()
            if until(v) { return v }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return value()
    }

    private static func mainWindow() -> NSWindow? {
        NSApp.windows.first { $0.isVisible && $0.contentView != nil && $0.title == "HomeFinance" }
            ?? NSApp.windows.first { $0.isVisible && $0.contentView != nil }
    }

    /// Het aantal rijen met een zichtbare, niet-lege rijweergave in de tabel van de zijbalk (AppKit). Dit ziet
    /// een zijbalk die wel in SwiftUI bestaat maar leeg getekend wordt.
    private static func visibleSidebarRowCount() -> Int {
        guard let content = mainWindow()?.contentView else { return 0 }
        let tables = allSubviews(of: content).compactMap { $0 as? NSTableView }
        // De zijbalk is de meest linkse tabel.
        guard let table = tables.min(by: { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX })
        else { return 0 }
        var count = 0
        for row in 0..<table.numberOfRows {
            guard let view = table.rowView(atRow: row, makeIfNecessary: false), !view.isHidden,
                  view.frame.height > 0, view.frame.width > 0, !table.visibleRect.intersection(view.frame).isEmpty,
                  // Een rij zonder getekende inhoud telt niet.
                  allSubviews(of: view).contains(where: { !$0.isHidden && $0.frame.width > 0 && $0.frame.height > 0 })
            else { continue }
            count += 1
        }
        return count
    }

    private static func allSubviews(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { allSubviews(of: $0) }
    }
}

// MARK: - Meetpunt voor de zelftest

extension View {
    /// Meldt in de zelftest waar deze view in het venster staat. Buiten de zelftest verandert er niets.
    @ViewBuilder func selfTestProbe(_ name: String) -> some View {
        if SelfTest.isOn {
            onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { SelfTest.probe(name, frame: $0) }
        } else {
            self
        }
    }
}
