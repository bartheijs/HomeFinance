import SwiftUI
import HFCore

/// Teksten bij de regel "tags alleen op de betaalrekening" (6h). De regel zelf zit in `HFBudget`.
enum TagRuleText {
    static let savings = "Tags kunnen alleen op boekingen van de betaalrekening."
    static let legacy = "Deze tag staat er nog van vroeger. Hij mag blijven; je kunt hem ook weghalen."
}

/// In plaats van de tagkeuze bij een boeking op een spaarrekening: de uitleg, en bij een tag van vroeger
/// de knop "Tag verwijderen".
struct TransactionsSavingsTags: View {
    let tags: [HFCore.Tag]
    var onRemove: (Int64) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(TagRuleText.savings).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !tags.isEmpty {
                Text(TagRuleText.legacy).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(tags) { tag in
                    HStack(spacing: 8) {
                        Circle().fill(Color(hex: tag.color)).frame(width: 9, height: 9)
                        Text(tag.name)
                        Spacer(minLength: 8)
                        Button("Tag verwijderen", systemImage: "xmark.circle") { onRemove(tag.id ?? 0) }
                            .controlSize(.small)
                            .help("Haalt ‘\(tag.name)’ weg van deze boeking. De boeking zelf blijft.")
                    }
                }
            }
        }
    }
}

/// Menu-items bij een spaarrekening: uitleg en "Tag ‘…’ verwijderen" per tag die er nog staat.
struct TransactionsSavingsTagMenuItems: View {
    @Environment(AppModel.self) private var model
    let store: TransactionsStore
    let ids: [TransactionsItemID]

    var body: some View {
        Text(TagRuleText.savings)
        ForEach(store.tagsPresent(in: ids)) { tag in
            Button("Tag ‘\(tag.name)’ verwijderen", systemImage: "xmark.circle") {
                store.removeTag(model, ids: ids, tagId: tag.id ?? 0)
            }
        }
    }
}
