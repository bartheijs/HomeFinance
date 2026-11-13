import SwiftUI
import HFCore

struct PotsScreen: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        EmptyState(title: "Pots", message: "Dit scherm wordt nog gebouwd.", icon: "hammer")
    }
}
