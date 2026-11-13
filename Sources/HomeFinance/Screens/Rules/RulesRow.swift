import SwiftUI
import HFCore
import HFRules

/// Vaste kolombreedtes van de regeltabel.
enum RulesColumns {
    static let toggle: CGFloat = 44
    static let result: CGFloat = 190
    static let hits: CGFloat = 62
    static let lastUsed: CGFloat = 88
    static let move: CGFloat = 46
}

struct RulesTableHeader: View {
    var body: some View {
        HStack(spacing: 10) {
            Text("Aan").frame(width: RulesColumns.toggle, alignment: .leading)
            Text("Regel en voorwaarden").frame(maxWidth: .infinity, alignment: .leading)
            Text("Resultaat").frame(width: RulesColumns.result, alignment: .leading)
            Text("Gebruikt").frame(width: RulesColumns.hits, alignment: .trailing)
                .help("Hoe vaak een boeking met het voorstel van deze regel is gemaakt")
            Text("Laatst").frame(width: RulesColumns.lastUsed, alignment: .trailing)
            Text("Volgorde").frame(width: RulesColumns.move, alignment: .trailing)
                .help("Bij gelijke zekerheid wint de bovenste regel")
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14).padding(.vertical, 8)
    }
}

struct RulesRow: View {
    let rule: Rule
    let data: RulesData
    let isSelected: Bool
    let canMove: Bool
    let isFirst: Bool
    let isLast: Bool
    var onToggle: (Bool) -> Void
    var onMove: (Int) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Toggle("Regel aan", isOn: Binding(get: { rule.enabled }, set: onToggle))
                .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                .frame(width: RulesColumns.toggle, alignment: .leading)
                .help(rule.enabled ? "Deze regel doet mee. Zet uit om hem te bewaren zonder dat hij voorstellen doet."
                                   : "Deze regel staat uit en doet geen voorstellen.")
            nameColumn
            resultColumn.frame(width: RulesColumns.result, alignment: .leading)
            Text(rule.hitCount == 0 ? "–" : "\(rule.hitCount)×")
                .monospacedDigit()
                .foregroundStyle(rule.hitCount == 0 ? .tertiary : .primary)
                .frame(width: RulesColumns.hits, alignment: .trailing)
            Text(RulesText.lastUsed(rule.lastUsed))
                .font(.callout).monospacedDigit()
                .foregroundStyle(rule.lastUsed == nil ? .tertiary : .secondary)
                .frame(width: RulesColumns.lastUsed, alignment: .trailing)
            moveButtons.frame(width: RulesColumns.move, alignment: .trailing)
        }
        .padding(.horizontal, 14).padding(.vertical, 7)
        .background(isSelected ? Theme.accent.opacity(0.14) : Color.clear)
        .overlay(alignment: .leading) {
            if isSelected { Rectangle().fill(Theme.accent).frame(width: 3) }
        }
        .contentShape(Rectangle())
        .opacity(rule.enabled ? 1 : 0.55)
    }

    private var nameColumn: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(rule.name).fontWeight(.medium).lineLimit(1)
                if rule.origin == .geleerd {
                    Pill("geleerd", color: Theme.info, icon: "sparkles")
                        .help("Deze regel is vanzelf ontstaan uit een correctie in Nakijken en past zich aan als je weer corrigeert.")
                } else {
                    Pill("handmatig", color: .secondary)
                        .help("Deze regel is met de hand gemaakt en wordt nooit automatisch aangepast.")
                }
            }
            Text(conditionLine)
                .font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                .help(conditionLine)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var conditionLine: String {
        var text = RulesText.conditions(rule)
        if let account = data.accountName(rule.accountId) { text += " · alleen \(account)" }
        return text
    }

    private var resultColumn: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Image(systemName: targetIcon).foregroundStyle(Theme.accent).font(.caption)
                Text(targetText).lineLimit(1)
            }
            let tags = data.tags(of: rule)
            if !tags.isEmpty || rule.reimburse {
                HStack(spacing: 6) {
                    ForEach(tags) { tag in
                        HStack(spacing: 3) {
                            Circle().fill(Color(hex: tag.color)).frame(width: 7, height: 7)
                            Text(tag.name)
                        }
                    }
                    if rule.reimburse {
                        Label("vergoeden", systemImage: "arrow.uturn.backward")
                            .foregroundStyle(Theme.warning)
                            .help("De uitgave wordt gemarkeerd om uit de spaarrekening te vergoeden.")
                    }
                }
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    private var targetText: String {
        if let label = RulesText.filled(rule.targetItemLabel) { return label }
        if let pot = data.potName(rule.targetPotId) { return rule.reimburse ? "Divers, uit pot \(pot)" : "Pot \(pot)" }
        return "Divers"
    }

    private var targetIcon: String {
        if RulesText.filled(rule.targetItemLabel) != nil { return "list.bullet.rectangle" }
        if rule.targetPotId != nil && !rule.reimburse { return "tray.full" }
        return "ellipsis.circle"
    }

    private var moveButtons: some View {
        HStack(spacing: 2) {
            Button { onMove(-1) } label: { Image(systemName: "chevron.up") }
                .disabled(!canMove || isFirst)
                .help(canMove ? "Eerder proberen" : "Wis de filters om de volgorde te wijzigen")
            Button { onMove(1) } label: { Image(systemName: "chevron.down") }
                .disabled(!canMove || isLast)
                .help(canMove ? "Later proberen" : "Wis de filters om de volgorde te wijzigen")
        }
        .buttonStyle(.borderless).controlSize(.small)
    }
}
