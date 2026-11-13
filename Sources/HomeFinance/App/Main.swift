import SwiftUI
import AppKit

/// Startpunt. Normaal start de SwiftUI-app; met `--snapshot <map>` worden alle schermen
/// met voorbeelddata als PNG weggeschreven (voor controle zonder de app te bedienen).
@main
enum Main {
    static func main() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            Snapshot.run(outputDirectory: URL(fileURLWithPath: args[i + 1]),
                         only: args.firstIndex(of: "--only").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil })
        } else {
            HomeFinanceApp.main()
        }
    }
}

struct HomeFinanceApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel.launch()

    var body: some Scene {
        WindowGroup("HomeFinance") {
            RootView()
                .environment(model)
                .frame(minWidth: 1100, minHeight: 700)
                .onAppear { delegate.model = model }
        }
        .defaultSize(width: 1440, height: 900)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Administratie") {
                Button("Importeren en nakijken") { model.selection = .review }
                    .keyboardShortcut("i", modifiers: .command)
                Button("Maandgrid") { model.selection = .grid }
                    .keyboardShortcut("g", modifiers: .command)
                Button("Dashboard") { model.selection = .dashboard }
                    .keyboardShortcut("d", modifiers: .command)
                Divider()
                Button("Back-up maken…") { model.selection = .settings; model.settingsTab = "backup" }
                    .keyboardShortcut("b", modifiers: [.command, .shift])
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Zonder app-bundel (swift run) is dit nodig om een gewoon venster met menubalk te krijgen.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { model?.onQuit() }
    }
}
