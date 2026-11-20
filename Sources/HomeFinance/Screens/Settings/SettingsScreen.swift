import SwiftUI
import HFCore

/// Instellingen: zes tabbladen, gekozen via `model.settingsTab`.
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
            // Past de rij tabbladen niet naast de titel (smal venster), dan komt hij eronder;
            // anders breekt de titel af als "Instellin-gen".
            ViewThatFits(in: .horizontal) {
                ScreenHeader("Instellingen", subtitle: tab.subtitle) { tabPicker(tab) }
                VStack(alignment: .leading, spacing: 0) {
                    ScreenHeader("Instellingen", subtitle: tab.subtitle)
                    tabPicker(tab).padding(.horizontal, 24).padding(.bottom, 12)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            Group {
                switch tab {
                case .jaar: SettingsYearTab()
                case .rekeningen: SettingsAccountsTab()
                case .tags: SettingsTagsTab()
                case .backup: SettingsBackupTab()
                case .telefoon: SettingsPhoneTab()
                case .over: SettingsAboutTab()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func tabPicker(_ tab: SettingsTab) -> some View {
        Picker("Onderdeel", selection: Binding(get: { tab }, set: { model.settingsTab = $0.rawValue })) {
            ForEach(SettingsTab.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented).labelsHidden().fixedSize()
    }
}
