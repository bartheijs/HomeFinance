import SwiftUI
import AppKit
import HFCore
import HFBackup

/// Over: waar de gegevens staan, hoeveel het er zijn, en wisselen tussen voorbeeld en eigen administratie.
struct SettingsAboutTab: View {
    @Environment(AppModel.self) private var model
    @State private var counts = BackupCounts()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.spacing) {
                HStack(spacing: Theme.spacing) {
                    StatTile(title: "Rekeningen", value: "\(counts.accounts)", icon: "creditcard")
                    StatTile(title: "Jaren", value: "\(counts.years)", icon: "calendar")
                    StatTile(title: "Boekingen", value: "\(counts.entries)", icon: "list.bullet.rectangle")
                    StatTile(title: "Banktransacties", value: "\(counts.bankTransactions)", icon: "tray.and.arrow.down")
                }
                Card("Je gegevens", icon: "internaldrive") {
                    VStack(alignment: .leading, spacing: 12) {
                        SettingsRow(model.isDemo ? "Voorbeelddatabase" : "Database",
                                    text: "Alles staat in één bestand op deze Mac. Er gaat niets naar een server; alleen back-ups kun je zelf in een cloudmap zetten.") {
                            Button("Toon in Finder") { NSWorkspace.shared.activateFileViewerSelecting([databaseURL]) }
                        }
                        Text(databaseURL.path).font(.callout.monospaced()).foregroundStyle(.secondary)
                            .textSelection(.enabled).lineLimit(2).truncationMode(.middle)
                    }
                }
                Card("Welke gegevens bekijk je?", icon: "arrow.left.arrow.right") {
                    SettingsRow(model.isDemo ? "Je bekijkt voorbeelddata" : "Je bekijkt je eigen administratie",
                                text: model.isDemo
                                    ? "Een verzonnen gezin om alles uit te proberen. Je eigen administratie blijft onaangeroerd."
                                    : "De voorbeelddata staan in een aparte database. Wisselen verandert niets aan je eigen gegevens.") {
                        if model.isDemo {
                            Button("Naar mijn eigen administratie") { model.switchToOwnData() }.buttonStyle(.borderedProminent)
                        } else {
                            Button("Bekijk voorbeelddata") { model.switchToDemo() }
                        }
                    }
                }
                Card("HomeFinance", icon: "info.circle") {
                    VStack(alignment: .leading, spacing: 6) {
                        LabeledContent("Versie", value: version)
                        LabeledContent("Gegevens", value: "lokaal op deze Mac, zonder account of login")
                        LabeledContent("Bedragen", value: "in hele centen, nooit afgerond")
                    }
                    .frame(maxWidth: 520, alignment: .leading)
                }
            }
            .frame(maxWidth: 780, alignment: .leading)
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: SettingsReloadKey(revision: model.revision, year: model.year)) {
            counts = model.read(BackupCounts()) { try Backup.counts($0) }
        }
    }

    private var databaseURL: URL { model.isDemo ? AppModel.demoURL : AppDatabase.defaultURL }

    private var version: String {
        let info = Bundle.main.infoDictionary
        guard let short = info?["CFBundleShortVersionString"] as? String else { return "ontwikkelversie" }
        let build = info?["CFBundleVersion"] as? String
        return build.map { "\(short) (\($0))" } ?? short
    }
}
