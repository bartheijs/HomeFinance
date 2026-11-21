import SwiftUI
import HFCore
import HFRules

/// De regeleditor als sheet, vanuit Nakijken: het concept van "Onthoud als regel" of de regel die het voorstel
/// deed. Bewaren gaat via `onSave`, dat een foutmelding teruggeeft of nil als het gelukt is.
struct RuleEditorSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let original: Rule
    let isNew: Bool
    let year: Int
    let intro: String
    let saveTitle: String
    let onSave: (Rule) -> String?

    @State private var draft: Rule
    @State private var data = RulesData()
    @State private var hits: [RuleTestHit] = []
    @State private var error: String?

    init(rule: Rule, isNew: Bool, year: Int, intro: String, saveTitle: String, onSave: @escaping (Rule) -> String?) {
        original = rule; self.isNew = isNew; self.year = year
        self.intro = intro; self.saveTitle = saveTitle; self.onSave = onSave
        _draft = State(initialValue: rule)
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(intro)
                .font(.callout).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20).padding(.top, 12)
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(Theme.negative)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20).padding(.top, 6)
            }
            RulesEditor(draft: $draft, data: data, hits: hits, year: year, isNew: isNew,
                        isDirty: draft != original, position: nil, canMove: false,
                        onSave: save, onRevert: { dismiss() }, onDuplicate: {}, onDelete: {}, onMove: { _ in },
                        onClose: { dismiss() },
                        showsManageButtons: false, saveTitle: saveTitle, cancelTitle: "Annuleer")
        }
        .frame(width: 480, height: 680)
        .task {
            data = model.read(RulesData()) { try RulesData.load($0, year: year) }
            refreshHits()
        }
        .onChange(of: draft) { _, _ in refreshHits() }
    }

    private func refreshHits() {
        guard RulesText.hasConditions(draft) else { hits = []; return }
        hits = model.read([]) { try RuleEngine.testRule(draft, against: $0) }
    }

    private func save() {
        if let message = onSave(draft) { error = message } else { dismiss() }
    }
}
