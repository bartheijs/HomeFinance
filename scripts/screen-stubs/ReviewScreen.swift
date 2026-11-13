import SwiftUI
import HFCore

struct ReviewScreen: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        EmptyState(title: "Review", message: "Dit scherm wordt nog gebouwd.", icon: "hammer")
    }
}
