import SwiftUI
import AppKit
import HFCore

/// Schrijft elk scherm met voorbeelddata weg als PNG, zonder dat iemand de app bedient.
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
                                  styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
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
}
