import SwiftUI
import HFCore

struct DashboardScreen: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        EmptyState(title: "Dashboard", message: "Dit scherm wordt nog gebouwd.", icon: "hammer")
    }
}
