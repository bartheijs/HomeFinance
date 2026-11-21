import SwiftUI
import AppKit
import HFCore
import HFBackup
import HFInsight
import HFPublish

/// Dashboard voor de telefoon: een pagina met de belangrijkste cijfers in een map die synchroniseert.
struct SettingsPhoneTab: View {
    @Environment(AppModel.self) private var model

    @State private var settings = PublishSettings()
    @State private var backupFolder: URL?
    @State private var busy = false
    /// Eigenaren die bij een pot zijn ingevuld, op alfabet.
    @State private var owners: [String] = []
    /// Potten om uit te kiezen voor de gezamenlijke spaarpot (niet gearchiveerd, behalve de gekozen), op alfabet.
    @State private var pots: [PotSummary] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.spacing) {
                if model.isDemo {
                    SettingsBanner(icon: "theatermasks.fill",
                                   text: "Je bekijkt **voorbeelddata**. Automatisch bijwerken werkt alleen met je eigen administratie. Een voorbeeld bekijken kan wel.",
                                   color: Theme.warning)
                }
                Text("De app zet een pagina met je belangrijkste cijfers in een map die met je telefoon synchroniseert. Op je telefoon open je hem met de app Bestanden of Drive.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                mainCard
                folderCard
                familyCard
                sectionsCard
            }
            .frame(maxWidth: 780, alignment: .leading)
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: SettingsReloadKey(revision: model.revision, year: model.year)) { load() }
    }

    // MARK: Kaarten

    private var mainCard: some View {
        Card("Bijwerken", icon: "iphone") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Dashboard voor de telefoon bijwerken", isOn: Binding(
                    get: { settings.enabled && !model.isDemo }, set: { setEnabled($0) }))
                    .disabled(model.isDemo)
                    .help("Na elke wijziging schrijft de app een nieuwe versie, en ook bij afsluiten.")
                if settings.enabled, !model.isDemo, settings.folderURL == nil {
                    Label("Kies eerst een map. Zonder map wordt er niets geschreven.", systemImage: "folder.badge.questionmark")
                        .font(.callout).foregroundStyle(Theme.warning)
                }
                Divider()
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Laatst bijgewerkt").font(.caption).foregroundStyle(.secondary)
                        Text(settings.lastPublishedAt.map(SettingsFormat.dateTime) ?? "nog nooit").monospacedDigit()
                    }
                    Spacer()
                    if busy { ProgressView().controlSize(.small) }
                    Button("Bekijk voorbeeld") { preview() }
                        .disabled(busy)
                        .help("Opent de pagina in je browser. Er wordt niets in de gekozen map gezet.")
                    Button { publishNow() } label: { Label("Nu bijwerken", systemImage: "arrow.triangle.2.circlepath") }
                        .buttonStyle(.borderedProminent)
                        .disabled(busy || model.isDemo || settings.folderURL == nil)
                        .help(model.isDemo ? "Kan alleen met je eigen administratie"
                              : (settings.folderURL == nil ? "Kies eerst een map" : "Schrijft nu een nieuwe versie naar de map"))
                }
                if let error = settings.lastError, !model.isDemo {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout).foregroundStyle(Theme.negative)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
            }
        }
    }

    private var folderCard: some View {
        Card("Map", icon: "folder") {
            VStack(alignment: .leading, spacing: 10) {
                if let folder = settings.folderURL {
                    HStack(spacing: 8) {
                        Image(systemName: "folder.fill").foregroundStyle(Theme.info)
                        Text(folder.path).font(.callout.monospaced()).lineLimit(2).truncationMode(.middle)
                            .textSelection(.enabled).help(folder.path)
                    }
                } else {
                    Label("Nog geen map gekozen.", systemImage: "folder.badge.questionmark")
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Button("Kies map…") { chooseFolder() }
                    if let suggestion = PublishSupport.iCloudSuggestion, settings.folderURL != suggestion {
                        Button("Gebruik iCloud Drive") { setFolder(suggestion) }
                            .help("Gebruikt de map ‘\(PublishSupport.folderName)’ in iCloud Drive")
                    }
                    if let folder = settings.folderURL {
                        Button("Toon in Finder") { showInFinder(folder) }
                    }
                }
                .disabled(model.isDemo)
                Text("Iedereen die bij deze map kan, kan deze cijfers zien. Kies een map in je eigen iCloud of Google Drive.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text("In de map komen twee bestanden met dezelfde pagina: ‘\(PublishSupport.htmlFileName)’ en ‘\(PublishSupport.pdfFileName)’. Werkt het HTML-bestand niet op je telefoon, open dan de PDF.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var sectionsCard: some View {
        Card("Wat staat erop", icon: "list.bullet.rectangle") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Nog te besteden deze maand, besteedbaar nu en de uitgaven van deze maand staan er altijd op.")
                    .font(.callout).foregroundStyle(.secondary)
                optionToggle("Vaste posten van deze maand", \.showFixedItems)
                optionToggle("Verloop van besteedbaar per maand", \.showTrend)
                optionToggle("Saldo per rekening", \.showAccounts)
                optionToggle("Potten", \.showPots)
            }
        }
    }

    private var familyCard: some View {
        Card("Voor het gezin", icon: "person.2") {
            VStack(alignment: .leading, spacing: 10) {
                optionToggle("Potjes van de kinderen", \.showChildPots)
                if settings.options.showChildPots {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Kies wiens potjes erop komen. Dit is de eigenaar die je bij een pot invult (Potten en sparen › pot bewerken).")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        if ownerChoices.isEmpty {
                            Text("Er zijn nog geen potten met een eigenaar.").font(.callout).foregroundStyle(.secondary)
                        }
                        ForEach(ownerChoices, id: \.self) { owner in
                            Toggle(owner, isOn: ownerBinding(owner)).toggleStyle(.checkbox)
                        }
                    }
                    .padding(.leading, 20)
                }
                Divider()
                optionToggle("Gezamenlijke spaarpot met vooruitblik", \.showSharedPot)
                if settings.options.showSharedPot {
                    VStack(alignment: .leading, spacing: 6) {
                        Picker("Pot", selection: Binding(
                            get: { settings.options.sharedPotId },
                            set: { settings.options.sharedPotId = $0; save() })) {
                            Text("Kies een pot").tag(Int64?.none)
                            ForEach(pots) { pot in
                                // Potten van verschillende kinderen heten vaak hetzelfde; de eigenaar maakt ze uniek.
                                Text(pot.owner.map { "\(pot.name) (\($0))" } ?? pot.name).tag(Int64?.some(pot.id))
                            }
                        }
                        .frame(maxWidth: 360)
                        Text("Met het saldo nu en de verwachte stand over 3, 6 en 12 maanden, berekend zoals de vooruitblik bij de pot.")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, 20)
                }
            }
        }
    }

    /// De eigenaren om uit te kiezen, plus eerder gekozen eigenaren die niet meer bestaan (om ze uit te zetten).
    private var ownerChoices: [String] {
        let gone = settings.options.childOwners.filter { !owners.contains($0) }
        return owners + gone.sorted { Insight.compareNames($0, $1) == .orderedAscending }
    }

    private func ownerBinding(_ owner: String) -> Binding<Bool> {
        Binding(get: { settings.options.childOwners.contains(owner) },
                set: { on in
                    settings.options.childOwners.removeAll { $0 == owner }
                    if on { settings.options.childOwners.append(owner) }
                    save()
                })
    }

    private func optionToggle(_ title: String, _ keyPath: WritableKeyPath<PublishOptions, Bool>) -> some View {
        Toggle(title, isOn: Binding(
            get: { settings.options[keyPath: keyPath] },
            set: { settings.options[keyPath: keyPath] = $0; save() }))
    }

    // MARK: Lezen

    private func load() {
        settings = model.read(PublishSettings()) { try PublishSettings.load($0) }
        backupFolder = model.read(nil) { try BackupSettings.load($0).folderURL }
        let today = model.today, chosen = settings.options.sharedPotId
        let overview = model.read(PotOverview?.none) { try Insight.potOverview($0, today: today) }
        let all = overview?.byKind.flatMap(\.pots) ?? []
        owners = (overview?.byOwner ?? []).compactMap(\.owner)
        pots = Insight.pickerOrder(all.filter { !$0.archived || $0.id == chosen })
    }

    // MARK: Schrijven

    /// Bewaart de keuzes. De app plant daarna zelf een nieuwe versie in (elke wijziging in de database doet dat).
    private func save() {
        let current = settings
        model.perform { try model.db.write { db in try current.save(db) } }
    }

    private func setEnabled(_ on: Bool) {
        guard !model.isDemo else { return }
        settings.enabled = on
        if on, settings.folderURL == nil, let suggestion = PublishSupport.defaultFolder(backupFolder: backupFolder) {
            settings.folderPath = suggestion.path
        }
        save()
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Kies de map voor het dashboard op je telefoon"
        panel.prompt = "Kies map"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = settings.folderURL ?? PublishSupport.defaultFolder(backupFolder: backupFolder)?.deletingLastPathComponent()
        if panel.runModal() == .OK, let url = panel.url { setFolder(url) }
    }

    private func setFolder(_ url: URL) {
        settings.folderPath = url.path
        save()
    }

    private func showInFinder(_ folder: URL) {
        let file = folder.appendingPathComponent(PublishSupport.htmlFileName)
        let target = FileManager.default.fileExists(atPath: file.path) ? file : folder
        NSWorkspace.shared.activateFileViewerSelecting([target])
    }

    private func publishNow() {
        busy = true
        Task {
            let outcome = await PublishSupport.publish(model, force: true)
            busy = false
            switch outcome {
            case .written: model.toast = "Dashboard voor de telefoon bijgewerkt"
            case .failed(let text): model.errorMessage = text
            case .unchanged, .skipped: break
            }
            load()
        }
    }

    private func preview() {
        busy = true
        Task {
            let outcome = await PublishSupport.preview(model)
            busy = false
            if case .failed(let text) = outcome { model.errorMessage = text }
        }
    }
}
