import SwiftUI
import AppKit
import HFCore
import HFPublish

/// Schrijft elk scherm met voorbeelddata weg als PNG, zonder dat iemand de app bedient, en het dashboard voor de
/// telefoon als `telefoon.html` (`--only telefoon` voor alleen die pagina).
/// Gebruik: HomeFinance --snapshot <map> [--only <scherm>] [--dark] [--size 1100x700]
/// Met `--size` teken je op een andere venstergrootte, bv. de kleinste die de app toestaat (1100×700).
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
        let size = requestedSize ?? NSSize(width: 1440, height: 900)

        if only == nil || only == "telefoon" {
            let phone = try db.read { try PhoneDashboard.make($0, today: today) }
            let url = outputDirectory.appendingPathComponent("telefoon.html")
            try PhoneDashboard.html(phone).write(to: url, atomically: true, encoding: .utf8)
            print("geschreven: \(url.path)")
        }

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
    }

    /// `--size BxH`, bv. `--size 1100x700`; nil als het ontbreekt of niet te lezen is.
    private static var requestedSize: NSSize? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--size"), i + 1 < args.count else { return nil }
        let parts = args[i + 1].lowercased().split(separator: "x").compactMap { Double($0) }
        guard parts.count == 2, parts[0] >= 400, parts[1] >= 300 else { return nil }
        return NSSize(width: parts[0], height: parts[1])
    }
}
