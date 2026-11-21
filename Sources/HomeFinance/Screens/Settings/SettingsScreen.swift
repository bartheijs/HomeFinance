import SwiftUI
import HFCore

/// Instellingen: vijf tabbladen, gekozen via `model.settingsTab`.
struct SettingsScreen: View {
    @Environment(AppModel.self) private var model
    /// De breedte die het scherm van het venster krijgt; bepaalt of de tabbladen naast de titel passen.
    @State private var width: CGFloat = 0

    /// Vanaf deze schermbreedte passen de tabbladen (ongeveer 685 punten) naast de titel en de langste ondertitel.
    /// Daaronder staan ze onder de titel; anders breekt de titel af als "Instellin-gen".
    static let tabsBesideTitleMinWidth: CGFloat = 1150

    /// Alleen voor snapshots: een ander tabblad tekenen dan het eerste (HF_SNAPSHOT_SETTINGS_TAB=rekeningen).
    private var snapshotTab: SettingsTab? {
        guard model.isSnapshot else { return nil }
        return ProcessInfo.processInfo.environment["HF_SNAPSHOT_SETTINGS_TAB"].flatMap(SettingsTab.init(rawValue:))
    }

    var body: some View {
        let tab = snapshotTab ?? SettingsTab(rawValue: model.settingsTab) ?? .rekeningen
        VStack(spacing: 0) {
            if width >= Self.tabsBesideTitleMinWidth {
                ScreenHeader("Instellingen", subtitle: tab.subtitle) { tabPicker(tab) }
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ScreenHeader("Instellingen", subtitle: tab.subtitle)
                    tabPicker(tab).padding(.horizontal, 24).padding(.bottom, 12)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            Group {
                switch tab {
                case .rekeningen: SettingsAccountsTab()
                case .regels: RulesScreen(embedded: true)
                case .backup: SettingsBackupTab()
                case .telefoon: SettingsPhoneTab()
                case .over: SettingsAboutTab()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // Meet de breedte die het venster geeft (minWidth 0: niet wat de inhoud zou willen).
        .frame(minWidth: 0, maxWidth: .infinity)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }

    private func tabPicker(_ tab: SettingsTab) -> some View {
        Picker("Onderdeel", selection: Binding(get: { tab }, set: { model.settingsTab = $0.rawValue })) {
            ForEach(SettingsTab.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented).labelsHidden().fixedSize()
    }
}
