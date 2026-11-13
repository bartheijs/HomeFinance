import SwiftUI
import HFCore

struct ReportsScreen: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        EmptyState(title: "Reports", message: "Dit scherm wordt nog gebouwd.", icon: "hammer")
    }
}
