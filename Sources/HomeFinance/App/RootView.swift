import SwiftUI
import HFCore

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Group {
            if model.hasData && model.isSnapshot {
                // Voor snapshots: de echte zijbalk (met doorschijnend materiaal) laat zich niet buiten beeld tekenen.
                HStack(spacing: 0) {
                    SnapshotSidebar().frame(width: 230)
                    Divider()
                    VStack(spacing: 0) {
                        if model.isDemo { DemoBanner() }
                        detail.frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.background)
                    }
                }
            } else if model.hasData {
                NavigationSplitView {
                    Sidebar()
                        .navigationSplitViewColumnWidth(min: 210, ideal: 230, max: 280)
                } detail: {
                    VStack(spacing: 0) {
                        if model.isDemo { DemoBanner() }
                        detail
                            .selfTestProbe("scherm")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .selfTestProbe("scherm-ruimte")
                            .background(Theme.background)
                    }
                }
            } else {
                WelcomeScreen()
            }
        }
        .id(model.isDemo)
        .alert("Dat ging niet goed", isPresented: Binding(
            get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
        .sheet(isPresented: $model.showHistoryImport) { HistoryImportSheet().environment(model) }
        .overlay(alignment: .bottom) { ToastView() }
        .tint(Theme.accent)
    }

    @ViewBuilder private var detail: some View {
        switch model.selection {
        case .dashboard: DashboardScreen().onAppear { SelfTest.screenAppeared(.dashboard) }
        case .review: ReviewScreen().onAppear { SelfTest.screenAppeared(.review) }
        case .grid: GridScreen().onAppear { SelfTest.screenAppeared(.grid) }
        case .transactions: TransactionsScreen().onAppear { SelfTest.screenAppeared(.transactions) }
        case .pots: PotsScreen().onAppear { SelfTest.screenAppeared(.pots) }
        case .reimbursements: ReimbursementsScreen().onAppear { SelfTest.screenAppeared(.reimbursements) }
        case .reports: ReportsScreen().onAppear { SelfTest.screenAppeared(.reports) }
        case .rules: RulesScreen().onAppear { SelfTest.screenAppeared(.rules) }
        case .settings: SettingsScreen().onAppear { SelfTest.screenAppeared(.settings) }
        }
    }
}

private struct Sidebar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(selection: Binding(get: { Optional(model.selection) }, set: { if let s = $0 { model.selection = s } })) {
            Section("Overzicht") { rows(Screen.overview) }
            Section("Spaarrekening") { rows(Screen.savings) }
            Section("Inzicht") { rows(Screen.insight) }
            Section { rows([.settings]) }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            YearPicker()
                .padding(12)
        }
        .navigationTitle("HomeFinance")
    }

    @ViewBuilder private func rows(_ screens: [Screen]) -> some View {
        ForEach(screens) { s in
            Label(s.title, systemImage: s.icon)
                .badge(SidebarBadges.count(for: s, model: model))
                .tag(s)
                .onAppear { SelfTest.sidebarRowAppeared(s) }
        }
    }
}

/// Nagetekende zijbalk voor snapshots.
private struct SnapshotSidebar: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("HomeFinance").font(.headline).padding(.horizontal, 10).padding(.bottom, 8)
            group("Overzicht", Screen.overview)
            group("Spaarrekening", Screen.savings)
            group("Inzicht", Screen.insight)
            group("", [.settings])
            Spacer()
            YearPicker()
        }
        .padding(12)
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    @ViewBuilder private func group(_ title: String, _ screens: [Screen]) -> some View {
        Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            .padding(.horizontal, 10).padding(.top, 10)
        ForEach(screens) { s in
            HStack {
                Label(s.title, systemImage: s.icon)
                Spacer()
                let n = SidebarBadges.count(for: s, model: model)
                if n > 0 { Text("\(n)").font(.caption).foregroundStyle(.secondary) }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(model.selection == s ? Theme.accent.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 7))
        }
    }
}

/// Jaarkeuze onder in de zijbalk.
private struct YearPicker: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let years = SidebarBadges.years(model: model)
        HStack {
            Button { model.year -= 1 } label: { Image(systemName: "chevron.left") }
                .disabled(!(years.contains(model.year - 1)))
            Spacer()
            VStack(spacing: 0) {
                Text("Begrotingsjaar").font(.caption2).foregroundStyle(.secondary)
                Text(String(model.year)).font(.title3.weight(.semibold)).monospacedDigit()
            }
            Spacer()
            Button { model.year += 1 } label: { Image(systemName: "chevron.right") }
                .disabled(!(years.contains(model.year + 1)))
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct DemoBanner: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "theatermasks.fill")
            Text("Je bekijkt **voorbeelddata**. Alles hier is verzonnen; probeer gerust alles uit.")
            Spacer()
            Button("Naar mijn eigen administratie") { model.switchToOwnData() }
                .controlSize(.small)
        }
        .font(.callout)
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(Theme.warning.opacity(0.14), ignoresSafeAreaEdges: [])
        .background(Theme.background, ignoresSafeAreaEdges: [])
        .overlay(alignment: .bottom) { Divider() }
    }
}

private struct ToastView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        if let text = model.toast {
            Label(text, systemImage: "checkmark.circle.fill")
                .font(.callout.weight(.medium))
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.quaternary))
                .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
                .padding(.bottom, 24)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .task(id: text) {
                    try? await Task.sleep(for: .seconds(3))
                    withAnimation { model.toast = nil }
                }
        }
    }
}
