import SwiftUI
import HFCore
import HFRules

/// Eén regel als leesbare zin: "Stroomhuis → Energie". Details staan in het paneel.
struct RulesRow: View {
    let rule: Rule
    let data: RulesData
    let isSelected: Bool
    var onToggle: (Bool) -> Void

    var body: some View {
        HStack(spacing: 14) {
            Toggle("Regel aan", isOn: Binding(get: { rule.enabled }, set: onToggle))
                .toggleStyle(.switch).controlSize(.small).labelsHidden()
                .help(rule.enabled ? "Deze regel doet mee. Zet uit om hem te bewaren zonder dat hij voorstellen doet."
                                   : "Deze regel staat uit en doet geen voorstellen.")
            (Text(RulesText.subject(rule)).fontWeight(.medium)
             + Text("  →  ").foregroundStyle(.tertiary)
             + Text(RulesText.target(rule, data)).foregroundStyle(.secondary))
                .font(.title3).lineLimit(1)
            Spacer(minLength: 8)
            Image(systemName: "chevron.right").font(.callout).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 18).padding(.vertical, 11)
        .background(isSelected ? Theme.accent.opacity(0.12) : Color.clear)
        .contentShape(Rectangle())
        .opacity(rule.enabled ? 1 : 0.5)
        .help("Klik voor de voorwaarden, een voorbeeld en de volgorde")
    }
}
