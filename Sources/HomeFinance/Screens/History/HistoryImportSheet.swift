import SwiftUI
import HFCore

/// Venster om de Excel-historie te importeren (Administratie › Excel-historie importeren…).
struct HistoryImportSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 16) {
            EmptyState(title: "Excel-historie importeren", message: "Dit wordt nog gebouwd.", icon: "hammer")
            Button("Sluiten") { dismiss() }
        }
        .padding(24).frame(width: 520, height: 360)
    }
}
