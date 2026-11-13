import SwiftUI
import HFCore

struct SettingsScreen: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        EmptyState(title: "Settings", message: "Dit scherm wordt nog gebouwd.", icon: "hammer")
    }
}
