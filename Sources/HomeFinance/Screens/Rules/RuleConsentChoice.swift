import SwiftUI
import HFCore
import HFRules

/// "Voortaan zo indelen" (of "Regel bijwerken met deze keuze") onder de keuze bij een wachtende banktransactie.
/// Standaard uit; aan = de samenvatting van de regel en "Aanpassen…". Nakijken en Transacties tonen dit blok op
/// dezelfde manier (UX-stap D1); de regel wordt pas bij het boeken bewaard, en alleen als het vinkje aan staat.
struct RuleConsentChoice: View {
    let option: ReviewRuleOption
    let setOn: (Bool) -> Void
    let edit: (Rule) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(option.title, isOn: Binding(get: { option.isOn }, set: setOn))
                .toggleStyle(.checkbox)
                .help(option.isUpdate
                      ? "Aan: de regel die dit voorstelde krijgt voortaan deze keuze. Uit: alleen deze boeking wijkt af; de regel blijft zoals hij is."
                      : "Aan: bij het boeken wordt een regel bewaard, zodat dit de volgende keer wordt voorgesteld. Uit: alleen boeken.")
            if !option.isUpdate {
                Text("Boekingen van deze tegenpartij krijgen voortaan deze post of dit potje voorgesteld.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 20)
            }
            if option.isOn {
                Text(option.summary)
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 20)
                Button("Aanpassen…") { edit(option.rule) }
                    .buttonStyle(.link).font(.callout).padding(.leading, 20)
                    .help("Open de regel in de regeleditor: voorwaarden en wat hij doet. Hij wordt bewaard als je boekt.")
            }
        }
    }
}
