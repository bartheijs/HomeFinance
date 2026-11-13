import SwiftUI
import HFCore

/// Instellingen: vijf tabbladen, gekozen via `model.settingsTab`.
struct SettingsScreen: View {
    @Environment(AppModel.self) private var model

    /// Alleen voor snapshots: een ander tabblad tekenen dan het eerste (HF_SNAPSHOT_SETTINGS_TAB=rekeningen).
    private var snapshotTab: SettingsTab? {
        guard model.isSnapshot else { return nil }
        return ProcessInfo.processInfo.environment["HF_SNAPSHOT_SETTINGS_TAB"].flatMap(SettingsTab.init(rawValue:))
    }

    var body: some View {
        let tab = snapshotTab ?? SettingsTab(rawValue: model.settingsTab) ?? .jaar
        VStack(spacing: 0) {
            ScreenHeader("Instellingen", subtitle: tab.subtitle) {
                Picker("Onderdeel", selection: Binding(get: { tab }, set: { model.settingsTab = $0.rawValue })) {
                    ForEach(SettingsTab.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            Divider()
            Group {
                switch tab {
                case .jaar: SettingsYearTab()
                case .rekeningen: SettingsAccountsTab()
                case .tags: SettingsTagsTab()
                case .backup: SettingsBackupTab()
                case .over: SettingsAboutTab()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
