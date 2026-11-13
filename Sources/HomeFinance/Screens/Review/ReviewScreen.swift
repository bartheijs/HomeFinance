import SwiftUI
import UniformTypeIdentifiers
import HFCore
import HFBudget

/// Importeren en nakijken: de export van de bank inlezen en de nieuwe transacties stap voor stap boeken.
struct ReviewScreen: View {
    @Environment(AppModel.self) private var model
    @State private var store = ReviewStore()
    @State private var showImporter = false
    @State private var dropTargeted = false

    private struct ReloadKey: Hashable { var revision: Int; var year: Int }

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader("Importeren en nakijken", subtitle: store.loaded ? store.account?.name : nil) { headerControls }
            Group {
                if !store.loaded {
                    Color.clear
                } else if store.accounts.isEmpty {
                    EmptyState(title: "Nog geen rekening",
                               message: "Maak eerst een betaal- of spaarrekening aan. Daarna kun je hier de export van je bank importeren.",
                               icon: "building.columns", actionTitle: "Naar Instellingen") {
                        model.settingsTab = "rekeningen"
                        model.selection = .settings
                    }
                } else if store.rows.isEmpty {
                    ReviewEmptyView(chooseFile: { showImporter = true })
                } else {
                    content
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if store.loaded, !store.rows.isEmpty { ReviewCheckLine() }
        }
        .background(Theme.background)
        .environment(store)
        .task(id: ReloadKey(revision: model.revision, year: model.year)) { store.load(model) }
        .onChange(of: store.accountId) { store.load(model) }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.zip, .commaSeparatedText, .pdf, .plainText, .data]) { result in
            if case .success(let url) = result { store.open(url, model) }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: \.isFileURL) else { return false }
            store.open(url, model)
            return true
        } isTargeted: { dropTargeted = $0 }
        .overlay { if dropTargeted { dropOverlay } }
        .sheet(item: $store.pendingImport) { pending in
            ReviewImportSheet(pending: pending).environment(store).environment(model)
        }
        .sheet(item: $store.rawFile) { file in
            ReviewRawFileSheet(file: file)
        }
    }

    @ViewBuilder private var headerControls: some View {
        if store.accounts.count > 1 {
            Picker("Rekening", selection: $store.accountId) {
                ForEach(store.accounts) { account in
                    let open = store.openCounts[account.id ?? 0] ?? 0
                    Text(open > 0 ? "\(account.name)  \(open)" : account.name).tag(account.id)
                }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            .help("De wachtrij hieronder is van de gekozen rekening. Het getal is het aantal transacties dat nog geboekt moet worden.")
        }
        if !store.rows.isEmpty {
            Button("Importeren…") { showImporter = true }
                .keyboardShortcut("o", modifiers: .command)
                .help("Kies het zip-bestand van je bank, of een los CSV- of PDF-afschrift (⌘O). Slepen naar dit scherm kan ook.")
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 18) {
            ReviewProgressLine()
            ReviewBanner()
            HStack(alignment: .top, spacing: 20) {
                ReviewQueueView()
                    .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
                ReviewInspector()
                    .frame(minWidth: 330, idealWidth: 390, maxWidth: 390, maxHeight: .infinity)
            }
        }
        .padding(.horizontal, 24).padding(.top, 6).padding(.bottom, 16)
    }

    private var dropOverlay: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            VStack(spacing: 10) {
                Image(systemName: "tray.and.arrow.down.fill").font(.system(size: 44)).foregroundStyle(Theme.accent)
                Text("Laat los om te importeren").font(.title2.weight(.semibold))
                Text("De rekening wordt herkend aan het IBAN").foregroundStyle(.secondary)
            }
            .padding(40)
            .background(RoundedRectangle(cornerRadius: 20).strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 2, dash: [8, 6])))
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Voortgang

/// Eén regel bovenaan: hoeveel je zelf moet bekijken, hoeveel zeker is, en de hoofdknop.
struct ReviewProgressLine: View {
    @Environment(AppModel.self) private var model
    @Environment(ReviewStore.self) private var store

    var body: some View {
        let certain = store.certainRows.count
        let toCheck = store.rows.count - certain
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title(toCheck: toCheck, certain: certain))
                    .font(.system(.title2, design: .rounded).weight(.semibold))
                Text(certain > 0
                     ? "Zeker betekent: tegenpartij en bedrag kloppen met een regel. Die boek je in één keer; daarna blijven alleen de twijfelgevallen over."
                     : "Loop ze één voor één langs: kies waar het bij hoort en druk op ⏎.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            if certain > 0 {
                Button { store.bookAllCertain(model) } label: {
                    Text(certain == 1 ? "Boek de zekere" : "Boek de \(certain) zekere").padding(.horizontal, 6)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .keyboardShortcut(.return, modifiers: [.command, .shift])
                .help("Boekt alle zekere transacties in één keer (⇧⌘⏎). In Transacties blijven ze gemarkeerd als 'nog na te kijken'.")
            }
        }
    }

    private func title(toCheck: Int, certain: Int) -> String {
        switch (toCheck, certain) {
        case (0, let c): "\(c) zeker · niets na te kijken"
        case (let t, 0): "Nog \(t) na te kijken"
        case (let t, let c): "Nog \(t) na te kijken · \(c) zeker"
        }
    }
}

/// Hoogstens één melding tegelijk: de laatste actie (met ongedaan maken) of gevonden overboekingen.
struct ReviewBanner: View {
    @Environment(AppModel.self) private var model
    @Environment(ReviewStore.self) private var store

    var body: some View {
        if let notice = store.notice {
            row(icon: "checkmark.circle", text: notice.text) {
                if notice.undo != nil {
                    Button("Maak ongedaan") { store.undo(model) }
                        .help("Draait de laatste actie terug, ook een geleerde regel.")
                }
                Button { store.notice = nil } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless).help("Sluit deze melding")
            }
            .task(id: notice.id) {
                try? await Task.sleep(for: .seconds(20))
                if store.notice?.id == notice.id { store.notice = nil }
            }
        } else if !store.pairs.isEmpty {
            let n = store.pairs.count
            row(icon: "arrow.left.arrow.right",
                text: n == 1 ? "1 overboeking tussen je eigen rekeningen gevonden"
                             : "\(n) overboekingen tussen je eigen rekeningen gevonden") {
                Button(n == 1 ? "Koppel" : "Koppel alle \(n)") { store.linkPairs(model) }
                    .help("Boekt beide kanten met het voorstel en koppelt ze aan elkaar, zodat je ziet dat het geld bij jezelf blijft. Een storting die gelijk is aan de maandbedragen wordt over de reserveringspotten verdeeld.")
            }
        }
    }

    private func row<Trailing: View>(icon: String, text: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(.secondary)
            Text(text).lineLimit(1)
            Spacer(minLength: 8)
            trailing()
        }
        .font(.callout).controlSize(.small)
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// De importcontrole als één regel onderaan (spec Import stap 7).
struct ReviewCheckLine: View {
    @Environment(ReviewStore.self) private var store

    var body: some View {
        if let batch = store.lastBatch, let check = store.check {
            HStack(spacing: 8) {
                Image(systemName: Self.icon(check)).foregroundStyle(Self.color(check))
                Text(Self.line(batch, check)).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .font(.callout).foregroundStyle(.secondary)
            .padding(.horizontal, 24).padding(.vertical, 10)
            .help(check.summary + " (Bestand: \(batch.fileName))")
        }
    }

    static func icon(_ check: ImportCheck) -> String {
        switch check.balanceMatches {
        case true?: "checkmark.circle.fill"
        case false?: "exclamationmark.triangle.fill"
        case nil: "clock"
        }
    }
    static func color(_ check: ImportCheck) -> Color {
        switch check.balanceMatches {
        case true?: Theme.positive
        case false?: Theme.negative
        case nil: .secondary
        }
    }

    /// Korte vorm van `ImportCheck.summary`; de volledige tekst staat in de tooltip.
    static func line(_ batch: ImportBatch, _ check: ImportCheck) -> String {
        let when = "Laatste import \(Day(date: batch.importedAt).short())"
        let open = check.allHandled ? "alles geboekt" : "nog \(check.newCount) van \(check.transactionCount) te boeken"
        let balance: String
        switch check.balanceMatches {
        case true?: balance = "saldo klopt met het bestand (\(check.closingBalance?.formatted() ?? ""))"
        case false?: balance = "saldo wijkt \(check.difference?.formatted(alwaysSign: true) ?? "") af van het bestand"
        case nil: balance = check.closingBalance == nil ? "het bestand heeft geen eindsaldo"
                                                        : "saldo controleren kan zodra alles geboekt is"
        }
        return "\(when) · \(open) · \(balance)"
    }
}

// MARK: - Lege toestand

/// De wachtrij is leeg: importeren staat centraal, groot en uitnodigend.
struct ReviewEmptyView: View {
    @Environment(AppModel.self) private var model
    @Environment(ReviewStore.self) private var store
    var chooseFile: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                VStack(spacing: 14) {
                    Image(systemName: "tray.and.arrow.down").font(.system(size: 44, weight: .light)).foregroundStyle(Theme.accent)
                    Text("Sleep het zip-bestand van je bank hierheen").font(.system(.title2, design: .rounded).weight(.semibold))
                    Text("(of een los CSV- of PDF-afschrift)").font(.title3).foregroundStyle(.secondary)
                    HStack(spacing: 10) {
                        Button("Kies bestand…", action: chooseFile).buttonStyle(.borderedProminent)
                            .keyboardShortcut("o", modifiers: .command)
                        if model.isDemo {
                            Button("Gebruik het voorbeeldbestand") { store.openSample(model) }
                                .help("Een verzonnen afschrift van de betaalrekening met de transacties van de laatste dagen.")
                        }
                    }
                    .controlSize(.large).padding(.top, 8)
                    Text("De app herkent de rekening aan het IBAN, slaat dubbelen over en doet per transactie een voorstel.")
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
                }
                .padding(.vertical, 54).frame(maxWidth: 640)
                .background(RoundedRectangle(cornerRadius: 20)
                    .strokeBorder(Theme.accent.opacity(0.45), style: StrokeStyle(lineWidth: 1.5, dash: [8, 6])))

                if !store.pairs.isEmpty { ReviewBanner().frame(maxWidth: 640) }

                if let batch = store.lastBatch, let check = store.check {
                    VStack(spacing: 4) {
                        Label("Alles is geboekt", systemImage: "checkmark.circle.fill")
                            .font(.headline).foregroundStyle(check.balanceMatches == false ? Color.primary : Theme.positive)
                        Text("\(batch.fileName) · \(batch.newCount) nieuw\(batch.duplicateCount > 0 ? ", \(batch.duplicateCount) al bekend" : "")")
                            .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        Text(ReviewCheckLine.line(batch, check))
                            .foregroundStyle(check.balanceMatches == false ? Theme.negative : Color.secondary)
                    }
                    .font(.callout).frame(maxWidth: 640)
                    .help(check.summary)
                } else {
                    Text("Er is voor \(store.account?.name ?? "deze rekening") nog niets geïmporteerd.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24).padding(.top, 40).padding(.bottom, 24)
        }
    }
}
