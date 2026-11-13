import SwiftUI
import AppKit
import HFCore
import HFBackup

/// Back-ups: map kiezen, nu een back-up maken, terugzetten en alles exporteren als CSV.
struct SettingsBackupTab: View {
    @Environment(AppModel.self) private var model

    @State private var settings = BackupSettings()
    @State private var isDue = false
    @State private var backups: [BackupInfo] = []
    @State private var listing = false
    @State private var restoreTarget: BackupInfo?
    @State private var showList = false

    /// Naam van de map met kopieën die vlak vóór een herstel gemaakt worden.
    static let safetyFolderName = "Veiligheidskopieën"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.spacing) {
                if model.isDemo {
                    SettingsBanner(icon: "theatermasks.fill",
                                   text: "Je bekijkt **voorbeelddata**. Back-ups zijn bedoeld voor je eigen administratie; terugzetten staat hier uit.",
                                   color: Theme.warning)
                } else if isDue {
                    SettingsBanner(icon: "exclamationmark.triangle.fill",
                                   text: settings.lastBackupAt == nil
                                       ? "**Er is nog geen back-up gemaakt.** Kies een map en maak er nu een."
                                       : "**De laatste back-up is een week of langer geleden.** Maak er nu een.",
                                   color: Theme.warning)
                }
                Text("Een back-up is één los bestand met je hele administratie. Zet de map in iCloud Drive, dan staat er altijd een kopie buiten deze Mac.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                folderCard
                automaticCard
                listCard
                exportCard
            }
            .frame(maxWidth: 780, alignment: .leading)
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: SettingsReloadKey(revision: model.revision, year: model.year)) { load() }
        .confirmationDialog(restoreTitle, isPresented: Binding(
            get: { restoreTarget != nil }, set: { if !$0 { restoreTarget = nil } }), presenting: restoreTarget) { info in
            Button("Zet deze back-up terug", role: .destructive) { restore(info) }
            Button("Annuleer", role: .cancel) {}
        } message: { info in
            Text("Je hele huidige administratie wordt vervangen door de inhoud van deze back-up (\(countsText(info.counts))). Alles wat je daarna hebt ingevoerd is dan weg.\n\nEerst wordt een veiligheidskopie van je huidige gegevens gemaakt in de map ‘\(Self.safetyFolderName)’. Daarmee kun je deze stap ongedaan maken.")
        }
    }

    private var restoreTitle: String {
        "Back-up van \(restoreTarget.map { SettingsFormat.dateTime($0.date) } ?? "") terugzetten?"
    }

    // MARK: Kaarten

    private var folderCard: some View {
        Card("Back-upmap", icon: "folder") {
            VStack(alignment: .leading, spacing: 10) {
                if let folder = settings.folderURL {
                    HStack(spacing: 8) {
                        Image(systemName: "folder.fill").foregroundStyle(Theme.info)
                        Text(folder.path).font(.callout.monospaced()).lineLimit(2).truncationMode(.middle)
                            .textSelection(.enabled).help(folder.path)
                    }
                } else {
                    Label("Nog geen map gekozen. Zonder map wordt er geen back-up gemaakt.", systemImage: "folder.badge.questionmark")
                        .foregroundStyle(Theme.warning)
                }
                HStack {
                    Button("Kies map…") { chooseFolder() }
                    if settings.folderURL == nil, let suggestion = Self.iCloudSuggestion {
                        Button("Gebruik iCloud Drive") { setFolder(suggestion) }
                            .help("Gebruikt de map ‘HomeFinance back-ups’ in iCloud Drive")
                    }
                    if let folder = settings.folderURL {
                        Button("Toon in Finder") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
                    }
                }
            }
        }
    }

    private var automaticCard: some View {
        Card("Automatisch", icon: "clock.arrow.circlepath") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Back-up maken bij afsluiten", isOn: Binding(
                    get: { settings.autoBackupOnQuit }, set: { settings.autoBackupOnQuit = $0; saveSettings() }))
                    .help("Elke keer dat je HomeFinance sluit, komt er een back-up in de map.")
                Stepper(value: Binding(get: { settings.keepCount }, set: { settings.keepCount = $0; saveSettings() }), in: 1...365) {
                    Text("Bewaar de laatste **\(settings.keepCount)** back-ups")
                }
                .help("Oudere back-ups worden opgeruimd. Veiligheidskopieën blijven altijd staan.")
                Divider()
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Laatste back-up").font(.caption).foregroundStyle(.secondary)
                        Text(settings.lastBackupAt.map(SettingsFormat.dateTime) ?? "nog nooit")
                            .monospacedDigit()
                            .foregroundStyle(isDue && !model.isDemo ? Theme.warning : Color.primary)
                    }
                    Spacer()
                    Button { backupNow() } label: { Label("Maak nu back-up", systemImage: "externaldrive.badge.plus") }
                        .buttonStyle(.borderedProminent)
                        .disabled(settings.folderURL == nil)
                        .help(settings.folderURL == nil ? "Kies eerst een map" : "Schrijft nu een gecontroleerde kopie naar de map")
                }
            }
        }
    }

    private var listCard: some View {
        Card(padding: 0) {
            VStack(spacing: 0) {
                Button { showList.toggle() } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "chevron.right").font(.callout.weight(.semibold)).foregroundStyle(.secondary)
                            .rotationEffect(.degrees(showList ? 90 : 0))
                        Text("Eerdere back-ups").font(.headline)
                        if listing { ProgressView().controlSize(.small) }
                        Spacer()
                        Text(SettingsFormat.count(backups.count, "bestand", "bestanden")).font(.callout).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 13)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Klik om de back-ups te zien en er een terug te zetten")
                if showList { backupRows }
            }
        }
    }

    @ViewBuilder private var backupRows: some View {
        Divider()
        if backups.isEmpty {
            Text(settings.folderURL == nil ? "Kies een map om back-ups te maken en te zien."
                                           : (listing ? "Back-ups worden gecontroleerd…" : "Nog geen back-ups in deze map."))
                .font(.callout).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading).padding(16)
        }
        ForEach(backups) { info in
            SettingsBackupRow(info: info, countsText: countsText(info.counts), canRestore: !model.isDemo,
                              onRestore: { restoreTarget = info })
            Divider().padding(.leading, 16)
        }
    }

    private var exportCard: some View {
        Card("Exporteren", icon: "tablecells") {
            SettingsRow("Alles als CSV",
                        text: "Eén bestand per tabel, direct te openen in Excel. Handig als extra zekerheid of om zelf mee te rekenen.") {
                Button("Exporteer alles als CSV…") { exportCSV() }
            }
        }
    }

    // MARK: Lezen

    private func load() {
        settings = model.read(BackupSettings()) { try BackupSettings.load($0) }
        isDue = (try? Backup.isBackupDue(model.db, now: SettingsFormat.date(model.today))) ?? false
        refreshList()
    }

    private func refreshList() {
        guard let folder = settings.folderURL else { backups = []; return }
        let safety = folder.appendingPathComponent(Self.safetyFolderName, isDirectory: true)
        listing = true
        Task {
            // Elk bestand wordt gecontroleerd; dat hoeft het scherm niet op te houden.
            let found = await Task.detached(priority: .userInitiated) {
                (Backup.listBackups(in: folder) + Backup.listBackups(in: safety)).sorted { $0.date > $1.date }
            }.value
            backups = found
            listing = false
        }
    }

    private func countsText(_ c: BackupCounts) -> String {
        [SettingsFormat.count(c.years, "jaar", "jaren"),
         SettingsFormat.count(c.entries, "boeking", "boekingen")].joined(separator: " · ")
    }

    private static var iCloudSuggestion: URL? {
        let drive = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        guard FileManager.default.fileExists(atPath: drive.path) else { return nil }
        return drive.appendingPathComponent("HomeFinance back-ups", isDirectory: true)
    }

    // MARK: Schrijven

    private func saveSettings() {
        let current = settings
        model.perform { try model.db.write { db in try current.save(db) } }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Kies de map voor back-ups"
        panel.prompt = "Kies map"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = settings.folderURL ?? Self.iCloudSuggestion?.deletingLastPathComponent()
        if panel.runModal() == .OK, let url = panel.url { setFolder(url) }
    }

    private func setFolder(_ url: URL) {
        settings.setFolder(url)
        saveSettings()
        refreshList()
    }

    private func backupNow() {
        model.perform("Back-up gemaakt") {
            guard try Backup.backupUsingSettings(model.db) != nil else { throw BackupError.folderUnavailable(settings.folderPath ?? "") }
        }
        load()
    }

    private func restore(_ info: BackupInfo) {
        guard !model.isDemo, let folder = settings.folderURL else { return }
        let safety = folder.appendingPathComponent(Self.safetyFolderName, isDirectory: true)
        model.perform("Back-up van \(SettingsFormat.dateTime(info.date)) teruggezet") {
            _ = try Backup.restore(from: info.url, into: model.db, safetyFolder: safety)
        }
        load()
    }

    private func exportCSV() {
        let panel = NSOpenPanel()
        panel.title = "Kies de map voor de CSV-bestanden"
        panel.prompt = "Exporteer hier"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        var written = 0
        let ok = model.perform {
            written = try Backup.exportAllAsCSV(model.db, to: folder).count
        }
        if ok {
            model.toast = "\(written) CSV-bestanden geschreven"
            NSWorkspace.shared.activateFileViewerSelecting([folder])
        }
    }
}

struct SettingsBackupRow: View {
    let info: BackupInfo
    let countsText: String
    let canRestore: Bool
    var onRestore: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: info.kind == .safety ? "lifepreserver" : "externaldrive.fill")
                .foregroundStyle(info.kind == .safety ? Theme.info : Theme.accent).frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(SettingsFormat.dateTime(info.date)).fontWeight(.medium).monospacedDigit()
                    if info.kind == .safety {
                        Pill("veiligheidskopie", color: Theme.info)
                            .help("Automatisch gemaakt vlak voordat een back-up werd teruggezet")
                    }
                    if info.isVerified {
                        Pill("gecontroleerd", color: Theme.positive, icon: "checkmark.seal.fill")
                            .help("Het bestand is geopend en volledig nagekeken; het is een bruikbare back-up.")
                    } else {
                        Pill("onbruikbaar", color: Theme.negative, icon: "xmark.octagon.fill")
                            .help(info.problem ?? "")
                    }
                }
                Text(info.isVerified ? "\(countsText)\(period) · \(SettingsFormat.bytes(info.size))"
                                     : (info.problem ?? "Dit bestand kan niet gelezen worden."))
                    .font(.callout).foregroundStyle(info.isVerified ? Color.secondary : Theme.negative).lineLimit(1)
            }
            Spacer(minLength: 8)
            Button("Herstel…", action: onRestore)
                .disabled(!canRestore || !info.isVerified)
                .help(canRestore ? "Vervang de huidige administratie door deze back-up"
                                 : "Terugzetten kan alleen in je eigen administratie")
            Button { NSWorkspace.shared.activateFileViewerSelecting([info.url]) } label: { Image(systemName: "magnifyingglass") }
                .help("Toon in Finder")
        }
        .controlSize(.small)
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    private var period: String {
        guard let last = info.lastEntryDay else { return "" }
        return " · t/m \(last.short(withYear: true))"
    }
}
