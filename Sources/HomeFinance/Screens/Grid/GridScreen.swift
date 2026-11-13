import SwiftUI
import HFCore

struct GridScreen: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        EmptyState(title: "Grid", message: "Dit scherm wordt nog gebouwd.", icon: "hammer")
    }
}
