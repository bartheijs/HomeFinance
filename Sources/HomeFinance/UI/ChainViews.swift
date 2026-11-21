import SwiftUI
import HFCore
import HFInsight

// De keten post ↔ vaste storting ↔ potje (UX-stap B2). De zinnen komen uit HFInsight (`Insight.chain`); deze
// views tonen ze alleen, met knoppen naar de andere kant.

/// Een kader met het ketenicoon, voor alle plekken gelijk.
struct ChainBox<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "arrow.triangle.branch").foregroundStyle(Theme.accent).font(.callout)
            VStack(alignment: .leading, spacing: 5) { content }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// Een knop als link, bv. "Vaste storting Maandelijkse reserveringen".
struct ChainLinkButton: View {
    let title: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(title, action: action)
            .buttonStyle(.link)
            .font(.callout)
            .lineLimit(1)
            .help(help)
    }
}

/// Bij een potje: "Krijgt € 42,00 per maand via vaste storting X (post Y)." Bij meer stortingen een lijstje.
struct PotChainView: View {
    @Environment(AppModel.self) private var model
    let chain: PotChain

    var body: some View {
        ChainBox {
            Text(chain.sentence).font(.callout).fixedSize(horizontal: false, vertical: true)
            if chain.lines.count > 1 {
                ForEach(chain.lines) { line in
                    Text("• \(line.line)").font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            links
        }
    }

    @ViewBuilder private var links: some View {
        let items = chain.lines.flatMap(\.distribution.items)
        if !chain.lines.isEmpty {
            HStack(spacing: 12) {
                ForEach(chain.lines) { line in
                    ChainLinkButton(title: "Vaste storting \(line.distribution.name)",
                                    help: "Open de vaste storting \(line.distribution.name) bij Vaste stortingen.") {
                        model.jump(.distribution(line.distribution.id))
                    }
                }
                ForEach(items.reduce(into: [ChainItemRef]()) { list, item in
                    if !list.contains(item) { list.append(item) }
                }) { item in
                    ChainLinkButton(title: "Post \(item.label)", help: "Open de post \(item.label) in je begroting.") {
                        model.jump(.item(item.id, year: model.year))
                    }
                }
            }
        }
    }
}

/// Bij een post: "Gaat via vaste storting X naar 28 potjes." met een knop naar de storting.
struct ItemChainView: View {
    @Environment(AppModel.self) private var model
    let chain: ItemChain

    var body: some View {
        if let sentence = chain.sentence, let distribution = chain.distribution {
            ChainBox {
                Text(sentence).font(.callout).fixedSize(horizontal: false, vertical: true)
                ChainLinkButton(title: "Open vaste storting \(distribution.name)",
                                help: "Bekijk of wijzig de verdeling over de potjes bij Vaste stortingen.") {
                    model.jump(.distribution(distribution.id))
                }
            }
        }
    }
}
