import SwiftUI
import GRDB
import HFCore

/// Eerste start: kiezen tussen rondkijken met voorbeelddata of de eigen administratie beginnen.
struct WelcomeScreen: View {
    @Environment(AppModel.self) private var model
    @State private var showSetup = false

    var body: some View {
        ZStack {
            LinearGradient(colors: [Theme.accent.opacity(0.22), Theme.background, Theme.info.opacity(0.12)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()
            VStack(spacing: 28) {
                Image(systemName: "eurosign.bank.building.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(Theme.accent)
                    .symbolRenderingMode(.hierarchical)
                VStack(spacing: 8) {
                    Text("Welkom bij HomeFinance")
                        .font(.system(size: 38, weight: .bold, design: .rounded))
                    Text("Je gezinsbegroting zonder typewerk: importeer je bankafschrift, kijk het na,\nen zie direct wat er te besteden is.")
                        .font(.title3).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                HStack(spacing: 18) {
                    choice(icon: "theatermasks.fill", title: "Eerst rondkijken",
                           text: "Open een verzonnen gezin met een half jaar aan gegevens. Je kunt alles uitproberen zonder iets te breken.",
                           button: "Bekijk voorbeelddata", prominent: false) { model.switchToDemo() }
                    choice(icon: "house.fill", title: "Mijn administratie beginnen",
                           text: "Voer je rekeningen en beginsaldi in. Daarna stel je je posten in en importeer je je eerste afschrift.",
                           button: "Begin", prominent: true) { showSetup = true }
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 760)
                if model.isDemo {
                    Button("Terug naar mijn eigen administratie") { model.switchToOwnData() }.buttonStyle(.link)
                }
            }
            .padding(40)
        }
        .sheet(isPresented: $showSetup) { SetupSheet() }
    }

    private func choice(icon: String, title: String, text: String, button: String, prominent: Bool,
                        action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: icon).font(.title).foregroundStyle(Theme.accent)
            Text(title).font(.title3.weight(.semibold))
            Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            if prominent {
                Button(button, action: action).buttonStyle(.borderedProminent).controlSize(.large)
            } else {
                Button(button, action: action).buttonStyle(.bordered).controlSize(.large)
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, minHeight: 210, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Theme.hairline.opacity(0.6)))
    }
}

/// Minimale inrichting: rekeningen, beginsaldi en het eerste jaar.
private struct SetupSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var year = max(Day.today().year, 2027)
    @State private var betaalName = "Betaalrekening"
    @State private var betaalIban = ""
    @State private var betaalBalance: Money? = .zero
    @State private var hasSavings = true
    @State private var spaarName = "Spaarrekening"
    @State private var spaarIban = ""
    @State private var spaarBalance: Money? = .zero
    @State private var antiRood: Money? = .zero

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Mijn administratie beginnen").font(.title2.weight(.bold))
                Text("Je kunt alles later aanpassen bij Instellingen.").foregroundStyle(.secondary)
            }
            .padding(20)
            Form {
                Section("Startjaar") {
                    Stepper("Begrotingsjaar: \(String(year))", value: $year, in: 2020...2100)
                    Text("Beginsaldi gelden op 1 januari \(String(year)).").font(.caption).foregroundStyle(.secondary)
                }
                Section("Betaalrekening") {
                    TextField("Naam", text: $betaalName)
                    TextField("IBAN", text: $betaalIban, prompt: Text("NL00BANK0123456789"))
                    LabeledContent("Saldo op 1 januari") { MoneyField("0,00", value: $betaalBalance).frame(width: 140) }
                }
                Section("Spaarrekening") {
                    Toggle("Ik houd ook een spaarrekening met potjes bij", isOn: $hasSavings)
                    if hasSavings {
                        TextField("Naam", text: $spaarName)
                        TextField("IBAN", text: $spaarIban, prompt: Text("NL00BANK0123456789"))
                        LabeledContent("Saldo op 1 januari") { MoneyField("0,00", value: $spaarBalance).frame(width: 140) }
                    }
                }
                Section("Buffer") {
                    LabeledContent("Minimaal op je betaalrekening aan het eind van de maand") { MoneyField("0,00", value: $antiRood).frame(width: 140) }
                    Text("Bedrag dat altijd op de betaalrekening moet blijven staan. Het telt niet mee in vrij te besteden.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Annuleren") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Aanmaken") { create() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(betaalName.trimmingCharacters(in: .whitespaces).isEmpty || betaalBalance == nil
                              || (hasSavings && spaarBalance == nil) || antiRood == nil)
            }
            .padding(16)
        }
        .frame(width: 560, height: 640)
    }

    private func create() {
        let start = Day(year: year, month: 1, day: 1)!
        func iban(_ s: String) -> String? {
            let v = s.replacingOccurrences(of: " ", with: "").uppercased()
            return v.isEmpty ? nil : v
        }
        let ok = model.perform("Administratie aangemaakt") {
            try model.db.write { db in
                var betaal = Account(name: betaalName, iban: iban(betaalIban), kind: .betaal,
                                     openingBalance: betaalBalance ?? .zero, openingDate: start, sortOrder: 0)
                try betaal.insert(db)
                if hasSavings {
                    var spaar = Account(name: spaarName, iban: iban(spaarIban), kind: .spaar,
                                        openingBalance: spaarBalance ?? .zero, openingDate: start, sortOrder: 1)
                    try spaar.insert(db)
                }
                var y = BudgetYear(year: year, antiRood: antiRood ?? .zero)
                try y.insert(db)
            }
        }
        if ok {
            model.year = year
            model.selection = .settings
            dismiss()
        }
    }
}
