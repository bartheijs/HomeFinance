import SwiftUI
import AppKit
import HFCore
import HFInsight

/// Zelftest van de echte app: `HomeFinance --database <kopie> --zelftest <logbestand>` (of met `--voorbeeld`).
///
/// Opent het gewone venster (de echte `NavigationSplitView`, niet de nagetekende zijbalk van de snapshots), loopt
/// alle schermen uit `Screen.allCases` langs via `model.selection` en controleert:
/// - de zijbalk verscheen, met een regel voor elk scherm (SwiftUI) en evenveel zichtbare rijen in AppKit;
/// - per groep van de zijbalk (`SidebarGroup.all`) de verwachte rijen, in SwiftUI en zoals getekend in AppKit,
///   in de gewone en de kleinste venstermaat (UX-stap C1);
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
    /// Per scherm de groep waarin de rij van de zijbalk verscheen.
    private static var sidebarRowGroups: [Screen: String] = [:]

    static func screenAppeared(_ screen: Screen) {
        guard isOn else { return }
        screenAppearances[screen, default: 0] += 1
    }

    static func sidebarRowAppeared(_ screen: Screen, group: String) {
        guard isOn else { return }
        sidebarRows.insert(screen)
        sidebarRowGroups[screen] = group
    }

    /// Laatst geladen pot-kiezer per scherm: aantal potten en of ze in kiezervolgorde staan (6c). Geen namen.
    private static var potPickers: [Screen: (count: Int, ordered: Bool)] = [:]

    /// Een scherm meldt de potten van zijn pot-kiezers na het laden. Controleert zelf, los van `pickerOrder`, dat
    /// eerst de reserveringspotten en dan de spaarpotten komen, elk op alfabet.
    static func potPickerLoaded(_ screen: Screen, kinds: [PotKind], names: [String]) {
        guard isOn else { return }
        var ordered = kinds.count == names.count
        for i in names.indices.dropFirst() where ordered {
            if kinds[i - 1] == kinds[i] {
                ordered = Insight.compareNames(names[i - 1], names[i]) != .orderedDescending
            } else {
                ordered = kinds[i - 1] == .reservering && kinds[i] == .spaar
            }
        }
        potPickers[screen] = (names.count, ordered)
    }

    /// Laatst getoonde aantallen wachtende banktransacties per scherm (D1): rekening, totaal en zeker. Geen namen.
    private static var waitingCounts: [Screen: (accountId: Int64, total: Int, certain: Int)] = [:]

    /// Nakijken en Transacties melden na het laden hoeveel banktransacties er wachten en hoeveel zeker zijn.
    static func waitingCountsLoaded(_ screen: Screen, accountId: Int64?, total: Int, certain: Int) {
        guard isOn, let accountId else { return }
        waitingCounts[screen] = (accountId, total, certain)
    }

    /// Hoeveel wachtende banktransacties een terugbetaling van voorgeschoten geld of een andere helft tonen (D2).
    private static var waitingExtras: [Screen: (deposits: Int, otherHalves: Int)] = [:]

    static func waitingExtrasLoaded(_ screen: Screen, _ proposals: [WaitingProposal]) {
        guard isOn else { return }
        waitingExtras[screen] = (proposals.filter { !$0.depositCandidates.isEmpty }.count,
                                 proposals.filter { $0.otherHalf != nil }.count)
    }

    /// Te doen meldde na het laden zijn kaartjes: hoeveel er getekend worden (minstens 1: "Er is niets te doen.")
    /// en hoeveel er openstaan.
    private static var settleUp: (blocks: Int, open: Int)?

    static func settleUpLoaded(blocks: Int, open: Int) {
        guard isOn else { return }
        settleUp = (blocks, open)
    }

    /// Laatst gemeten plek (in venstercoördinaten, oorsprong linksboven) van views met `.selfTestProbe(_:)`.
    private static var probeFrames: [String: CGRect] = [:]

    static func probe(_ name: String, frame: CGRect) {
        guard isOn else { return }
        probeFrames[name] = frame
    }

    /// Een gemeten view verdween (zie `selfTestProbe(_:removeOnDisappear:)`).
    static func probeGone(_ name: String) {
        guard isOn else { return }
        probeFrames[name] = nil
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
        let expected = Set(SidebarGroup.sidebarScreens)
        let rowsUp = await wait(.seconds(5)) { sidebarRows == expected }
        check(rowsUp, "zijbalk verscheen met \(expected.count) regels (gezien: \(sidebarRows.count))")
        let appKitRows = await waitValue(.seconds(3)) { visibleSidebarRowCount() } until: { $0 >= expected.count }
        check(appKitRows >= expected.count,
              "zijbalk toont in het venster minstens \(expected.count) rijen met inhoud (gevonden: \(appKitRows))")
        for group in SidebarGroup.all {
            let seen = group.screens.filter { sidebarRowGroups[$0] == group.title }
            check(seen == group.screens, "zijbalk, groep \(groupName(group)): \(group.screens.map(\.title).joined(separator: ", "))"
                  + (seen == group.screens ? "" : " (gezien: \(seen.map(\.title).joined(separator: ", ")))"))
        }
        await checkSidebarGroups(label: "huidige venstermaat")

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

        // 3a. Pot-kiezers op Transacties en Nakijken staan per soort op alfabet (6c).
        for screen in [Screen.transactions, .review] {
            let picker = potPickers[screen]
            write("     pot-kiezer \(screen.rawValue): \(picker.map { "\($0.count) potten, volgorde \($0.ordered ? "OK" : "FOUT")" } ?? "niet geladen")")
            check(picker.map { $0.count > 0 && $0.ordered } ?? false,
                  "pot-kiezer \(screen.rawValue) verscheen met potten per soort op alfabet")
        }

        // 3a2. Nakijken en Transacties tonen dezelfde aantallen zeker / na te kijken (één bron, D1).
        let review = waitingCounts[.review], transactions = waitingCounts[.transactions]
        write("     wachtend nakijken: \(review.map { "\($0.total) totaal, \($0.certain) zeker" } ?? "niet geladen")"
              + " · transacties: \(transactions.map { "\($0.total) totaal, \($0.certain) zeker" } ?? "niet geladen")")
        if let review, let transactions, review.accountId == transactions.accountId {
            check(review.total == transactions.total && review.certain == transactions.certain,
                  "Nakijken en Transacties tonen dezelfde aantallen wachtend en zeker (D1)")
        } else {
            check(false, "Nakijken en Transacties tonen dezelfde aantallen (niet te vergelijken: \(review == nil || transactions == nil ? "niet geladen" : "andere rekening"))")
        }

        // 3a3. Dezelfde extra herkenning op beide plekken (D2). Hoeveel er zijn hangt van de datum en de gegevens af.
        let rx = waitingExtras[.review], tx = waitingExtras[.transactions]
        write("     extra herkenning nakijken: \(rx.map { "\($0.deposits) terugbetaling, \($0.otherHalves) andere helft" } ?? "niet geladen")"
              + " · transacties: \(tx.map { "\($0.deposits) terugbetaling, \($0.otherHalves) andere helft" } ?? "niet geladen")")
        check(rx != nil && rx?.deposits == tx?.deposits && rx?.otherHalves == tx?.otherHalves,
              "Nakijken en Transacties tonen dezelfde terugbetalingen en andere helften (D2)")

        // 3a4. Te doen toont alleen kaartjes met inhoud (of "Er is niets te doen."); de teller in de zijbalk is het
        // aantal kaartjes.
        let expectedCards = model.read(SettleUpData()) { try SettleUpData.read($0, today: model.today) }.cards
        write("     te doen: \(settleUp.map { "\($0.blocks) getekend, \($0.open) kaartjes" } ?? "niet geladen")"
              + " (verwacht: \(expectedCards.isEmpty ? "niets te doen" : expectedCards.joined(separator: ", ")))")
        check(settleUp?.blocks == max(expectedCards.count, 1) && settleUp?.open == expectedCards.count,
              "Te doen toont alleen de kaartjes met inhoud")
        check(settleUp.map { SidebarBadges.count(for: .settleUp, model: model) == $0.open } ?? false,
              "teller van Te doen in de zijbalk = aantal kaartjes")

        // 3b. Transacties: de kop blijft zichtbaar en het downloadblok (6a) staat eronder, ook in het kleinste venster.
        await checkTransactionsHeader(model: model)

        // 3c. Elk scherm (en elk tabblad van Rapporten en Instellingen) in de gewone en de kleinste venstermaat:
        // kop zichtbaar, niets horizontaal buiten beeld, zijbalk zichtbaar (6k-3).
        await checkLayout(model: model, expectedRows: expected.count)

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
            // Alleen metingen na deze maatwijziging tellen; de zijbalk meldt zich alleen bij een verschuiving opnieuw.
            probeFrames = probeFrames.filter { $0.key.hasPrefix("zijbalk-") }
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

    /// Eén halte van de ronde langs de schermen: een scherm, of een tabblad van een scherm met tabbladen.
    private struct Stop {
        let screen: Screen
        /// Tabblad van Rapporten (`ReportsTab`) of Instellingen (`SettingsTab`), anders nil.
        let tab: String?
        let title: String
    }

    private static var stops: [Stop] {
        Screen.allCases.flatMap { screen -> [Stop] in
            switch screen {
            case .reports: ReportsTab.allCases.map { Stop(screen: screen, tab: $0.rawValue, title: "\(screen.title) › \($0.title)") }
            case .settings: SettingsTab.allCases.map { Stop(screen: screen, tab: $0.rawValue, title: "\(screen.title) › \($0.title)") }
            default: [Stop(screen: screen, tab: nil, title: screen.title)]
            }
        }
    }

    /// Vraagt een scherm met `.selfTestTabRequests(_:)` om een ander tabblad (object: de rawValue).
    static let tabRequest = Notification.Name("HomeFinanceSelfTestTabRequest")

    private static func checkLayout(model: AppModel, expectedRows: Int) async {
        guard let window = mainWindow() else { return }
        let original = window.frame
        let originalSettingsTab = model.settingsTab
        let sizes: [(String, NSSize?)] = [("gewone venstermaat", nil), ("kleinste venstermaat", NSSize(width: 1100, height: 700))]
        for (label, size) in sizes {
            if let size {
                window.setContentSize(size)
                try? await Task.sleep(for: .milliseconds(500))
                let width = window.contentView?.bounds.width ?? 0
                check(abs(width - size.width) <= 1, "venster blijft op de \(label) (\(Int(width)) breed, gevraagd \(Int(size.width)))")
            }
            await checkSidebarGroups(label: label)
            // Begin elke maat op een ander scherm dan het eerste, zodat het eerste scherm vers verschijnt.
            model.selection = stops.first?.screen == .dashboard ? .reports : .dashboard
            try? await Task.sleep(for: .milliseconds(300))
            var current: Screen? = nil
            for stop in stops {
                if stop.screen == .settings, let tab = stop.tab { model.settingsTab = tab }
                if current != stop.screen {
                    // Alleen de kop hoort bij het scherm; "scherm" en "scherm-ruimte" zitten om alle schermen heen
                    // en melden zich pas opnieuw als hun plek verandert.
                    probeFrames["scherm-kop"] = nil; probeFrames["scherm-titel"] = nil
                    probeFrames = probeFrames.filter { !$0.key.hasPrefix("rechtzetten-blok-") }
                    let before = screenAppearances[stop.screen, default: 0]
                    if model.selection != stop.screen {
                        model.selection = stop.screen
                        _ = await wait(screenTimeout) { screenAppearances[stop.screen, default: 0] > before }
                    }
                    current = stop.screen
                }
                if stop.screen == .reports, let tab = stop.tab {
                    NotificationCenter.default.post(name: tabRequest, object: tab)
                }
                try? await Task.sleep(for: .milliseconds(450))
                checkStop(stop, label: label, window: window, expectedRows: expectedRows)
            }
        }
        model.settingsTab = originalSettingsTab
        window.setFrame(original, display: true)
        try? await Task.sleep(for: .milliseconds(300))
    }

    private static func checkStop(_ stop: Stop, label: String, window: NSWindow, expectedRows: Int) {
        let where_ = "\(stop.title) (\(label))"
        let height = window.contentView?.bounds.height ?? 0
        let width = window.contentView?.bounds.width ?? 0
        let top = max(0, height - window.contentLayoutRect.maxY)
        let sidebar = sidebarFrame()
        let sidebarRight = sidebar?.maxX ?? 0
        let area = probeFrames["scherm-ruimte"]
        let left = max(sidebarRight, area?.minX ?? sidebarRight)
        let right = min(width, area?.maxX ?? width)
        let fmt: (CGRect) -> String = { "x \(Int($0.minX))–\(Int($0.maxX)), y \(Int($0.minY))–\(Int($0.maxY))" }

        // Kop: binnen het venster, onder de werkbalk, tussen zijbalk en rechterrand, titel op één regel.
        let header = probeFrames["scherm-kop"], title = probeFrames["scherm-titel"]
        let titleFont = NSFont.systemFont(ofSize: NSFont.preferredFont(forTextStyle: .title1).pointSize, weight: .bold)
        let lineHeight = titleFont.ascender - titleFont.descender + titleFont.leading
        let headerOK = header.map { $0.width > 0 && $0.height > 0 && $0.minY >= top - 0.5 && $0.maxY <= height + 0.5
            && $0.minX >= left - 1 && $0.maxX <= right + 1 } ?? false
        let titleOK = title.map { $0.width > 0 && $0.height < lineHeight * 1.5 } ?? false
        check(headerOK && titleOK, "kop zichtbaar: \(where_)"
              + (header.map { " kop \(fmt($0))" } ?? ", kop niet gezien")
              + (title.map { titleOK ? "" : ", titel over meer regels (hoogte \(Int($0.height)))" } ?? ", titel niet gezien")
              + (headerOK ? "" : ", ruimte x \(Int(left))–\(Int(right)) y \(Int(top))–\(Int(height))"))

        // Niet horizontaal buiten beeld: het scherm past in de ruimte naast de zijbalk.
        let screen = probeFrames["scherm"]
        let fits = screen.map { $0.width > 0 && $0.minX >= left - 1 && $0.maxX <= right + 1 } ?? false
        check(fits, "schuift niet buiten beeld: \(where_)"
              + (screen.map { fits ? "" : " scherm \(fmt($0)), ruimte x \(Int(left))–\(Int(right))" } ?? ", scherm niet gemeten"))

        // Zijbalk: links in beeld, breed genoeg, met alle rijen.
        let rows = visibleSidebarRowCount()
        let sidebarOK = (sidebar.map { $0.minX >= -0.5 && $0.width >= 150 } ?? false) && rows >= expectedRows
        // Te doen: de kaartjes (of "Er is niets te doen.") staan in beeld, binnen de ruimte naast de zijbalk.
        if stop.screen == .settleUp {
            let expected = settleUp?.blocks ?? -1
            let blocks = probeFrames.filter { $0.key.hasPrefix("rechtzetten-blok-") }.map(\.value)
            let inside = blocks.allSatisfy { $0.width > 0 && $0.minX >= left - 1 && $0.maxX <= right + 1 }
            check(blocks.count == expected && inside,
                  "Te doen: \(expected) kaartje(s) binnen beeld (\(label), gezien: \(blocks.count))")
        }

        check(sidebarOK, "zijbalk zichtbaar: \(where_)"
              + (sidebarOK ? "" : " (\(sidebar.map { "x \(Int($0.minX))–\(Int($0.maxX))" } ?? "niet gevonden"), \(rows) rijen)"))
    }

    private static func groupName(_ group: SidebarGroup) -> String {
        group.title.isEmpty ? "onderaan" : group.title
    }

    /// De zijbalk zoals AppKit hem tekent, als reeks: "#Groep" voor een groepskop, anders de titel van het scherm.
    /// Een groep zonder kop (Instellingen) staat er zonder "#"-regel.
    private static var expectedSidebarSequence: [String] {
        SidebarGroup.all.flatMap { ($0.title.isEmpty ? [] : ["#\($0.title)"]) + $0.screens.map(\.title) }
    }

    /// Controleert per groep de getekende rijen van de zijbalk: welke schermen onder welke kop staan, in volgorde.
    private static func checkSidebarGroups(label: String) async {
        let expected = expectedSidebarSequence
        let seen = await waitValue(.seconds(3)) { sidebarSequence() } until: { $0 == expected }
        let groupTitles = Set(SidebarGroup.all.map(\.title).filter { !$0.isEmpty })
        for group in SidebarGroup.all {
            // De schermen die AppKit onder de kop van deze groep tekent (tot de volgende kop).
            var rows: [String] = []
            if group.title.isEmpty {
                rows = seen.filter { title in group.screens.contains { $0.title == title } }
            } else if let start = seen.firstIndex(of: "#\(group.title)") {
                for item in seen[(start + 1)...] {
                    if item.hasPrefix("#") { break }
                    rows.append(item)
                }
                // Instellingen staat zonder kop onder de laatste groep; die hoort er niet bij.
                rows.removeAll { title in SidebarGroup.all.contains { $0.title.isEmpty && $0.screens.contains { $0.title == title } } }
            }
            let want = group.screens.map(\.title)
            check(rows == want, "zijbalk getekend, groep \(groupName(group)) (\(label)): \(want.joined(separator: ", "))"
                  + (rows == want ? "" : " (gezien: \(rows.isEmpty ? "niets" : rows.joined(separator: ", ")))"))
        }
        let unknown = seen.filter { $0.hasPrefix("#") && !groupTitles.contains(String($0.dropFirst())) }
        check(unknown.isEmpty && seen == expected, "zijbalk getekend in de juiste volgorde, zonder andere groepen (\(label))"
              + (seen == expected ? "" : " (gezien: \(seen.joined(separator: " | ")))"))
    }

    /// De zijbalk zoals hij getekend is, als reeks zoals `expectedSidebarSequence`. Elke rij en elke groepskop
    /// meldt in SwiftUI zijn plek (`zijbalk-rij-…`, `zijbalk-kop-…`); alleen een plek die in de zijbalk valt en waar
    /// AppKit een zichtbare rij met inhoud tekent, telt mee. Volgorde: van boven naar beneden.
    private static func sidebarSequence() -> [String] {
        guard let window = mainWindow(), let content = window.contentView else { return [] }
        let tables = allSubviews(of: content).compactMap { $0 as? NSTableView }
        guard let table = tables.min(by: { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX }),
              let sidebar = sidebarFrame()
        else { return [] }
        let height = content.bounds.height
        // Getekende rijen in de coördinaten van de metingen (oorsprong linksboven).
        var drawn: [CGRect] = []
        for row in 0..<table.numberOfRows {
            guard let view = table.rowView(atRow: row, makeIfNecessary: false), !view.isHidden,
                  view.frame.height > 0, view.frame.width > 0, !table.visibleRect.intersection(view.frame).isEmpty,
                  allSubviews(of: view).contains(where: { !$0.isHidden && $0.frame.width > 0 && $0.frame.height > 0 })
            else { continue }
            let r = view.convert(view.bounds, to: nil)
            drawn.append(CGRect(x: r.minX, y: height - r.maxY, width: r.width, height: r.height))
        }
        var items: [(y: CGFloat, text: String)] = []
        for (name, frame) in probeFrames where frame.width > 0 && frame.height > 0 {
            let text: String
            if name.hasPrefix("zijbalk-rij-"), let screen = Screen(rawValue: String(name.dropFirst("zijbalk-rij-".count))) {
                text = screen.title
            } else if name.hasPrefix("zijbalk-kop-") {
                text = "#" + name.dropFirst("zijbalk-kop-".count)
            } else { continue }
            let mid = CGPoint(x: frame.midX, y: frame.midY)
            guard frame.minX >= sidebar.minX - 1, frame.maxX <= sidebar.maxX + 1,
                  drawn.contains(where: { $0.contains(mid) }) else { continue }
            items.append((frame.midY, text))
        }
        return items.sorted { $0.y < $1.y }.map(\.text)
    }

    /// Plek van de zijbalk (de scrollweergave om de meest linkse tabel) in venstercoördinaten.
    private static func sidebarFrame() -> CGRect? {
        guard let content = mainWindow()?.contentView else { return nil }
        let tables = allSubviews(of: content).compactMap { $0 as? NSTableView }
        guard let table = tables.min(by: { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX }),
              let scroll = table.enclosingScrollView, !scroll.isHiddenOrHasHiddenAncestor
        else { return nil }
        return scroll.convert(scroll.bounds, to: nil)
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
    /// Laat de zelftest het tabblad van dit scherm kiezen (`SelfTest.tabRequest`). Buiten de zelftest verandert er
    /// niets.
    @ViewBuilder func selfTestTabRequests<T: RawRepresentable>(_ tab: Binding<T>) -> some View where T.RawValue == String {
        if SelfTest.isOn {
            onReceive(NotificationCenter.default.publisher(for: SelfTest.tabRequest)) { note in
                if let raw = note.object as? String, let value = T(rawValue: raw) { tab.wrappedValue = value }
            }
        } else {
            self
        }
    }

    /// Meldt in de zelftest waar deze view in het venster staat. Buiten de zelftest verandert er niets.
    @ViewBuilder func selfTestProbe(_ name: String, removeOnDisappear: Bool = false) -> some View {
        if SelfTest.isOn {
            onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { SelfTest.probe(name, frame: $0) }
                .onDisappear { if removeOnDisappear { SelfTest.probeGone(name) } }
        } else {
            self
        }
    }
}
