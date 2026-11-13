import SwiftUI
import HFCore

struct TransactionsScreen: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        EmptyState(title: "Transactions", message: "Dit scherm wordt nog gebouwd.", icon: "hammer")
    }
}
