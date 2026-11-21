import SwiftUI
import HFCore
import HFInsight

/// De wachtrij: per transactie alleen datum, naam, voorstel en bedrag. Wat je moet bekijken staat bovenaan.
struct ReviewQueueView: View {
    @Environment(AppModel.self) private var model
    @Environment(ReviewStore.self) private var store
    @FocusState private var focused: Bool

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    section("Na te kijken", store.toCheckRows,
                            help: "Geen regel gevonden, of de regel is niet zeker van de post of het bedrag. Kijk deze zelf na.")
                    section("Zeker", store.rows.filter { $0.group == .certain },
                            help: "Tegenpartij en bedrag kloppen met een regel of een vaste storting. Deze kun je in één keer boeken.")
                }
                .padding(8)
            }
            .onChange(of: store.cursor) { _, id in
                if let id { withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(id) } }
            }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(.upArrow) { store.move(-1, extend: NSEvent.modifierFlags.contains(.shift)); return .handled }
        .onKeyPress(.downArrow) { store.move(1, extend: NSEvent.modifierFlags.contains(.shift)); return .handled }
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .onAppear { focused = true }
    }

    @ViewBuilder private func section(_ title: String, _ rows: [ReviewRow], help: String) -> some View {
        if !rows.isEmpty {
            HStack(spacing: 6) {
                Text(title).fontWeight(.semibold)
                Text("\(rows.count)").monospacedDigit().foregroundStyle(.secondary)
            }
            .font(.subheadline)
            .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 4)
            .help(help)
            ForEach(rows) { row in
                ReviewQueueRow(row: row)
                    .id(row.id)
                    .onTapGesture {
                        let flags = NSEvent.modifierFlags
                        store.select(row.id, command: flags.contains(.command), shift: flags.contains(.shift))
                        focused = true
                    }
                    .contextMenu { menu(for: row) }
            }
        }
    }

    @ViewBuilder private func menu(for row: ReviewRow) -> some View {
        let inSelection = store.selection.contains(row.id) && store.selection.count > 1
        Button(inSelection ? "Boek selectie (\(store.selection.count))" : "Boek") {
            if inSelection { store.bookSelection(model) } else { store.select(row.id); store.bookCurrent(model) }
        }
        Button(inSelection ? "Sla selectie over" : "Sla over") {
            if !inSelection { store.select(row.id) }
            store.skipSelection(model)
        }
        if let pair = row.pair {
            Divider()
            Button("Koppel als overboeking") { store.linkPairs(model, only: pair) }
        }
        if store.isEdited(row) {
            Divider()
            Button("Terug naar het voorstel") { store.resetDraft(for: row) }
        }
        Divider()
        Button("Alles selecteren") { store.selectAll() }
    }
}

/// Eén regel in de wachtrij: datum, leesbare naam, het voorstel als één label, bedrag.
struct ReviewQueueRow: View {
    @Environment(ReviewStore.self) private var store
    let row: ReviewRow

    var body: some View {
        let selected = store.selection.contains(row.id)
        let draft = store.draft(for: row)
        HStack(spacing: 12) {
            Text(row.tx.day.short()).monospacedDigit().foregroundStyle(.secondary)
                .frame(width: 54, alignment: .leading)
            Text(draft.isSplit ? row.cleanLabel : draft.label).fontWeight(.medium).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            proposal(draft).lineLimit(1).layoutPriority(1)
            Text(row.tx.amount.formatted(symbol: false)).monospacedDigit()
                .foregroundStyle(row.tx.amount.isNegative ? Color.primary : Theme.positive)
                .frame(width: 90, alignment: .trailing)
        }
        .font(.system(size: 14))
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(selected ? AnyShapeStyle(Theme.accent.opacity(0.14)) : AnyShapeStyle(.clear),
                    in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
    }

    /// Het voorstel als één label; oranje alleen als je zelf nog moet kiezen of het bedrag afwijkt.
    @ViewBuilder private func proposal(_ draft: ReviewDraft) -> some View {
        let s = row.suggestion
        if let settlement = row.settlement {
            label(settlement.transfer.map { store.title(of: $0) } ?? "Kies verrekening", attention: true)
                .help("De overboeking van een verrekening met spaar. Deze boek je niet opnieuw; je hangt hem aan de verrekening.")
        } else if let match = row.match, match.looksSeparate, !row.usesDistribution, !store.isEdited(row),
                  draft.target == .none {
            label("Losse overboeking? Kies pot", attention: true)
                .help("Het bedrag is heel anders dan de vaste storting. Kies één pot, of kies toch de vaste storting.")
        } else if let match = row.match, row.usesDistribution, !store.isEdited(row) {
            if let distribution = match.distribution {
                label(match.exactAmount ? distribution.name : "\(distribution.name) · ander bedrag", attention: !match.exactAmount)
                    .help(match.exactAmount ? "Herkend als vaste storting."
                                            : "Herkend als vaste storting, maar het bedrag wijkt \(match.difference.formatted(alwaysSign: true)) af.")
            } else {
                label("Kies vaste storting", attention: true)
                    .help("Er passen meer vaste stortingen bij deze overboeking.")
            }
        } else if draft.isSplit {
            label("Gesplitst in \(draft.lines.count)")
        } else if draft.target == .none, row.pair != nil {
            label("Overboeking")
        } else if s.amountDiffers, !store.isEdited(row) {
            label((["\(store.title(of: draft.target, kind: store.kind)) · ander bedrag"] + linkLabels(draft)).joined(separator: " · "), attention: true)
                .help(s.expectedAmount.map { "De regel verwacht \($0.formatted())." } ?? "Het bedrag wijkt af van de regel.")
        } else if s.ruleId == nil, !store.isEdited(row) {
            label("Nog kiezen", attention: true)
                .help("Geen regel herkent deze transactie. Zonder keuze wordt hij geboekt als \(store.title(of: .none, kind: store.kind).lowercased()).")
        } else {
            let text = ([store.title(of: draft.target, kind: store.kind)] + linkLabels(draft)).joined(separator: " · ")
            label(text).help(text)
        }
    }

    /// "uit potje X" bij verrekenen met spaar, "voorgeschoten (Tanken)" bij een tag die verrekend wordt.
    private func linkLabels(_ draft: ReviewDraft) -> [String] {
        guard store.kind == .betaal else { return [] }
        let settling = store.tags.filter { $0.settles && draft.tagIds.contains($0.id ?? -1) }.map(\.name)
        return Insight.linkLabels(amount: row.tx.amount, reimburse: draft.reimburse,
                                  potName: store.potName(draft.reimbursePotId), settlingTagNames: settling)
    }

    private func label(_ text: String, attention: Bool = false) -> some View {
        Text(text)
            .truncationMode(.middle)
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 9).padding(.vertical, 3)
            .foregroundStyle(attention ? Theme.warning : Color.secondary)
            .background(attention ? AnyShapeStyle(Theme.warning.opacity(0.14)) : AnyShapeStyle(.quaternary.opacity(0.6)), in: Capsule())
    }
}
