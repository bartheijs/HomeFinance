import SwiftUI
import UniformTypeIdentifiers
import HFCore
import HFHistory

/// Venster om de Excel-historie te importeren (Administratie › Excel-historie importeren…).
/// Vier rustige stappen: bestanden kiezen, nakijken, rekening kiezen, klaar.
struct HistoryImportSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var state = HistoryImportState()
    @State private var picking: HistoryImportState.FileKind?

    private static let xlsx = UTType("org.openxmlformats.spreadsheetml.sheet") ?? .data

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.isDemo {
                EmptyState(title: "Niet in de voorbeelddata",
                           message: "Je kijkt nu naar een verzonnen gezin. Stap over op je eigen administratie (Instellingen › Over) om je Excel-historie te importeren.",
                           icon: "theatermasks")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        switch state.step {
                        case .choose: chooseStep
                        case .review: HistoryReviewStep(state: state)
                        case .account: HistoryAccountStep(state: state)
                        case .done: HistoryDoneStep(state: state)
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Divider()
            footer
        }
        .frame(width: 760, height: 660)
        .alert("Dat ging niet goed", isPresented: Binding(
            get: { state.problem != nil }, set: { if !$0 { state.problem = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(state.problem ?? "")
        }
        .fileImporter(isPresented: Binding(get: { picking != nil }, set: { if !$0 { picking = nil } }),
                      allowedContentTypes: [Self.xlsx]) { result in
            let kind = picking
            picking = nil
            state.perform {
                let url = try result.get()
                if let kind { state.setFile(url, kind: kind) }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "clock.arrow.circlepath").font(.title).foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("Excel-historie importeren").font(.title3.weight(.semibold))
                Text("Eenmalig je oude jaren uit Excel overnemen").font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if !model.isDemo {
                HStack(spacing: 6) {
                    ForEach(HistoryImportState.Step.allCases, id: \.self) { step in
                        Pill("\(step.rawValue + 1) \(step.title)", color: step == state.step ? Theme.accent : .secondary)
                            .opacity(step.rawValue <= state.step.rawValue ? 1 : 0.55)
                    }
                }
            }
        }
        .padding(20)
    }

    // MARK: Stap 1

    private var chooseStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("De app leest je Excel-werkmappen en zet elk jaar in de administratie: de vaste posten, wat er per maand betaald en ontvangen is en de losse inkomsten en uitgaven. De bestanden blijven op deze Mac en worden niet gewijzigd; je ziet eerst wat er gevonden is voordat er iets wordt opgeslagen.")
                .fixedSize(horizontal: false, vertical: true)

            HistoryFileRow(title: "Begrotingswerkmap", detail: "Het bestand met één blad per jaar (.xlsx).",
                           icon: "tablecells", file: state.budgetFile,
                           choose: { picking = .budget }, clear: { state.budgetFile = nil })
            HistoryFileRow(title: "Spaarwerkmap (als je wilt)", detail: "Het bestand met het blad RES: de mutaties per pot (.xlsx).",
                           icon: "square.grid.3x3.topleft.filled", file: state.savingsFile,
                           choose: { picking = .savings }, clear: { state.savingsFile = nil })

            if state.isReading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Bezig met lezen…").foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Knoppen onderaan

    private var footer: some View {
        HStack {
            if model.isDemo || state.step == .done {
                Spacer()
                Button("Sluiten") { dismiss() }.keyboardShortcut(.defaultAction)
            } else {
                Button("Annuleren") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                switch state.step {
                case .choose:
                    Button("Verder") { Task { await state.read(today: model.today) } }
                        .buttonStyle(.borderedProminent).disabled(!state.canRead)
                        .help("Leest de bestanden en laat zien wat er gevonden is. Er wordt nog niets opgeslagen.")
                case .review:
                    Button("Terug") { state.step = .choose }
                    Button("Verder") { state.prepareAccounts(model) }
                        .buttonStyle(.borderedProminent).disabled(!state.canContinueFromReview)
                case .account:
                    Button("Terug") { state.step = .review }
                    Button(state.importTitle) { state.runImport(model) }
                        .buttonStyle(.borderedProminent).disabled(!state.canImport)
                case .done:
                    EmptyView()
                }
            }
        }
        .padding(16)
    }
}

/// Eén bestand kiezen in stap 1.
private struct HistoryFileRow: View {
    let title: String
    let detail: String
    let icon: String
    let file: URL?
    var choose: () -> Void
    var clear: () -> Void

    var body: some View {
        Card {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.title2).foregroundStyle(Theme.accent).frame(width: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    if let file {
                        Label(file.lastPathComponent, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(Theme.positive).lineLimit(1).truncationMode(.middle)
                    } else {
                        Text(detail).font(.callout).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                if file != nil {
                    Button("Wissen", action: clear).buttonStyle(.plain).foregroundStyle(.secondary)
                }
                Button(file == nil ? "Kies bestand…" : "Ander bestand…", action: choose)
            }
        }
    }
}
