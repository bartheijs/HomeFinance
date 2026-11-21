import SwiftUI

/// Posten: de begroting van het jaar (buffers en vaste posten), met jaar aanmaken en afsluiten. Stond tot UX-stap
/// C1 bij Instellingen › Jaar en posten; de inhoud is dezelfde (`SettingsYearTab`).
struct BudgetScreen: View {
    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader("Posten", subtitle: "Buffers en vaste posten van het begrotingsjaar.")
            Divider()
            SettingsYearTab()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
