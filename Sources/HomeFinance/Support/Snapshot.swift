import SwiftUI
import AppKit
import HFCore
import HFInsight
import HFPublish

/// Schrijft elk scherm met voorbeelddata weg als PNG, zonder dat iemand de app bedient.
/// Schrijft ook `telefoon.html`: de pagina voor de telefoon met dezelfde voorbeelddata (`--only telefoon` voor
/// alleen die pagina).
/// Gebruik: HomeFinance --snapshot <map> [--only <scherm>] [--dark]
@MainActor
enum Snapshot {
    nonisolated static func run(outputDirectory: URL, only: String?) {
        MainActor.assumeIsolated {
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            do {
                try render(outputDirectory: outputDirectory, only: only)
            } catch {
                FileHandle.standardError.write(Data("Snapshot mislukt: \(error)\n".utf8))
                exit(1)
            }
            exit(0)
        }
    }

    private static func render(outputDirectory: URL, only: String?) throws {
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let today = Day(iso: "2027-06-18")!
        let db = try AppDatabase.inMemory()
        try DemoSupport.seed(db, today: today)
        let dark = CommandLine.arguments.contains("--dark")
        let size = NSSize(width: 1440, height: 900)

        for screen in Screen.allCases where only == nil || only == screen.rawValue {
            let model = AppModel(db: db, isDemo: true, today: today)
            model.selection = screen
            model.isSnapshot = true
            let host = NSHostingView(rootView: RootView().environment(model).frame(width: size.width, height: size.height))
            let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -20000, y: -20000), size: size),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.contentView = host
            window.orderFrontRegardless()
            // Geef SwiftUI tijd om gegevens te laden en te tekenen.
            RunLoop.main.run(until: Date().addingTimeInterval(1.5))
            host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
            host.cacheDisplay(in: host.bounds, to: rep)
            let url = outputDirectory.appendingPathComponent("\(screen.rawValue)\(dark ? "-dark" : "").png")
            try rep.representation(using: .png, properties: [:])?.write(to: url)
            print("geschreven: \(url.path)")
            window.orderOut(nil)
        }
        if only == nil || only == "telefoon" { try writePhonePage(db: db, today: today, to: outputDirectory) }
    }

    /// De telefoonpagina met voorbeelddata, met alle onderdelen aan: de potjes van de kinderen uit het voorbeeld
    /// en als gezamenlijke spaarpot de eerste spaarpot zonder eigenaar.
    private static func writePhonePage(db: AppDatabase, today: Day, to outputDirectory: URL) throws {
        let html = try db.read { database in
            let overview = try Insight.potOverview(database, today: today)
            var options = PublishOptions()
            options.childOwners = overview.byOwner.compactMap(\.owner).filter { $0.hasPrefix("Kind") }
            options.sharedPotId = overview.byKind.flatMap(\.pots)
                .first { $0.kind == .spaar && $0.owner == nil && !$0.archived }?.id
            // "Bijgewerkt op" past bij de peildag van de voorbeelddata (12:00 op die dag).
            let snapshot = try PhoneDashboard.make(database, today: today, now: today.date.addingTimeInterval(12 * 3600),
                                                   options: options)
            return PhoneDashboard.html(snapshot, options: options)
        }
        let url = outputDirectory.appendingPathComponent("telefoon.html")
        try Data(html.utf8).write(to: url)
        print("geschreven: \(url.path)")
    }
}
