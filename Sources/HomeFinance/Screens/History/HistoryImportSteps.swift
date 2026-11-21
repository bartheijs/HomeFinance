import SwiftUI
import HFCore
import HFHistory

// MARK: - Stap 2: nakijken wat er gelezen is

struct HistoryReviewStep: View {
    @Environment(AppModel.self) private var model
    @Bindable var state: HistoryImportState

    var body: some View {
        if let budget = state.budget {
            VStack(alignment: .leading, spacing: 10) {
                Text("Jaren in de begrotingswerkmap").font(.headline)
                if budget.years.isEmpty {
                    Label("Er is geen jaarblad gevonden dat ingelezen kan worden.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Theme.warning)
                } else {
                    Text("Aangevinkte jaren worden geïmporteerd. Een jaar waarvan de totalen niet kloppen met Excel staat uit; je kunt het na het zien van het verschil toch meenemen.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                ForEach(budget.years) { year in
                    HistoryYearRow(year: year, selected: state.selected.contains(year.year), today: model.today,
                                   throughMonth: Binding(get: { state.throughMonth[year.year] },
                                                         set: { state.throughMonth[year.year] = $0 })) { state.toggle(year.year) }
                }
                ForEach(Array(budget.unread.enumerated()), id: \.offset) { _, sheet in
                    HStack(spacing: 10) {
                        Image(systemName: "minus.circle").foregroundStyle(.secondary)
                        Text("Blad \(sheet.name)").fontWeight(.medium)
                        Text(sheet.reason).foregroundStyle(.secondary)
                        Spacer()
                    }
                    .font(.callout).opacity(0.7)
                    .padding(.horizontal, 16).padding(.vertical, 4)
                }
            }
        }
        if let savings = state.savings {
            HistorySavingsCard(savings: savings, include: $state.includeSavings, allowDifferences: $state.allowSavingsDifferences)
        }
    }
}

/// Eén jaar: kerncijfers, of de totalen kloppen, en de meldingen.
private struct HistoryYearRow: View {
    let year: HistoryYear
    let selected: Bool
    let today: Day
    @Binding var throughMonth: Int?
    var toggle: () -> Void
    @State private var expanded = false
    @State private var limitExpanded = false

    private var isCurrent: Bool { year.year == today.year }
    private var later: (count: Int, months: [Int]) { year.amountsAfter(month: today.month) }
    private var regularItems: Int { year.items.filter { $0.direction != .RES }.count }
    private var noteCount: Int { year.warnings.count + year.skippedRows.count }

    var body: some View {
        Card(padding: 14) {
            HStack(alignment: .top, spacing: 12) {
                Toggle(year.totalsMatch ? "Importeren" : "Toch importeren",
                       isOn: Binding(get: { selected }, set: { _ in toggle() }))
                    .toggleStyle(.checkbox).labelsHidden()
                    .help(year.totalsMatch ? "Dit jaar importeren" : "Toch importeren, met het verschil dat hier staat")
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(String(year.year)).font(.system(.title3, design: .rounded).weight(.semibold)).monospacedDigit()
                        if year.sheetNames.count > 1 {
                            Text("uit \(year.sheetNames.count) bladen").font(.callout).foregroundStyle(.secondary)
                                .help(year.sheetNames.joined(separator: ", "))
                        }
                        Text("\(regularItems) posten · \(year.entryCount(through: throughMonth)) boekingen").font(.callout).foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        balance("Begin", year.openingBalance)
                        balance("Eind", year.statedClosing)
                    }
                    if year.totalsMatch {
                        Label("Totalen kloppen met Excel", systemImage: "checkmark.circle.fill")
                            .font(.callout).foregroundStyle(Theme.positive)
                    } else {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(year.differences.enumerated()), id: \.offset) { _, difference in
                                Label(difference.text, systemImage: "xmark.circle.fill")
                                    .font(.callout).foregroundStyle(Theme.negative)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            if !selected {
                                Text("Niet aangevinkt. Zet het vinkje om dit jaar toch te importeren.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if let gap = year.chainDifference {
                        Label("Beginsaldo wijkt \(gap.formatted(alwaysSign: true)) af van het eindsaldo van \(String(year.year - 1)).",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.callout).foregroundStyle(Theme.warning)
                    }
                    if isCurrent { currentYear }
                    if year.unknownDayCount > 0 {
                        Text("\(year.unknownDayCount) losse \(year.unknownDayCount == 1 ? "regel" : "regels"): datum onbekend, 15e van de maand.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if noteCount > 0 {
                        DisclosureGroup(isExpanded: $expanded) {
                            HistoryNoteList(warnings: year.warnings, skipped: year.skippedRows)
                        } label: {
                            Text(noteLabel).font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    /// Het lopende jaar: uitleg, bedragen na vandaag, het saldo na de import en de optionele grens.
    @ViewBuilder private var currentYear: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Dit jaar is nog bezig en blijft open. Alles wat nu in het blad staat wordt geïmporteerd. Daarna ga je verder met de bank; de app controleert bij de eerste bankimport of het saldo aansluit.")
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            if later.count > 0 {
                Label("Er \(later.count == 1 ? "staat 1 bedrag" : "staan \(later.count) bedragen") in \(monthList(later.months)), na de maand van vandaag. Dat zijn waarschijnlijk verwachte bedragen.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(Theme.warning).fixedSize(horizontal: false, vertical: true)
                Toggle("Niet importeren: \(later.count == 1 ? "dit bedrag" : "deze \(later.count) bedragen") na \(Day.monthNames[today.month - 1])",
                       isOn: Binding(get: { throughMonth == today.month },
                                     set: { throughMonth = $0 ? today.month : nil }))
                    .toggleStyle(.checkbox)
            }
            HStack(spacing: 6) {
                Text(throughMonth.map { $0 == 0 ? "Saldo na import (geen boekingen):" : "Saldo na import (eind \(Day.monthNames[$0 - 1])):" } ?? "Saldo na import:")
                    .foregroundStyle(.secondary)
                Text((throughMonth.map { year.balanceThrough(month: $0) } ?? year.computedClosing)?.formatted() ?? "onbekend")
                    .fontWeight(.semibold).monospacedDigit()
            }
            .font(.callout)
            .help("Het saldo waarop de eerste bankimport moet aansluiten.")
            if let throughMonth, year.excludedCount(through: throughMonth) > 0 {
                let n = year.excludedCount(through: throughMonth)
                Text("\(n) \(n == 1 ? "bedrag blijft" : "bedragen blijven") buiten de import.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            DisclosureGroup(isExpanded: $limitExpanded) {
                VStack(alignment: .leading, spacing: 4) {
                    Picker("Importeer tot en met", selection: $throughMonth) {
                        Text("het hele blad").tag(Int?.none)
                        ForEach(1...12, id: \.self) { month in Text(Day.monthNames[month - 1]).tag(Int?.some(month)) }
                    }
                    .frame(maxWidth: 300)
                    Text("Gebruik dit als je blad voor latere maanden verwachte bedragen bevat.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.top, 4)
            } label: {
                Text("Importeer tot en met maand …").font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.info.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    private func monthList(_ months: [Int]) -> String {
        months.map { Day.monthNames[$0 - 1] }.joined(separator: ", ")
    }

    private var noteLabel: String {
        var parts: [String] = []
        if !year.warnings.isEmpty { parts.append(year.warnings.count == 1 ? "1 waarschuwing" : "\(year.warnings.count) waarschuwingen") }
        if !year.skippedRows.isEmpty { parts.append(year.skippedRows.count == 1 ? "1 rij overgeslagen" : "\(year.skippedRows.count) rijen overgeslagen") }
        return parts.joined(separator: " · ")
    }

    private func balance(_ title: String, _ amount: Money?) -> some View {
        HStack(spacing: 4) {
            Text(title).foregroundStyle(.secondary)
            Text(amount?.formatted() ?? "onbekend").monospacedDigit()
        }
        .font(.callout)
    }
}

/// Waarschuwingen en overgeslagen rijen, uitgeklapt.
private struct HistoryNoteList: View {
    let warnings: [HistoryNote]
    let skipped: [HistoryNote]

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(warnings.enumerated()), id: \.offset) { _, note in
                Label(note.text, systemImage: "exclamationmark.triangle").foregroundStyle(.primary)
            }
            ForEach(Array(skipped.enumerated()), id: \.offset) { _, note in
                Label(note.text, systemImage: "arrow.uturn.right").foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 4)
    }
}

/// Wat er in het blad RES van de spaarwerkmap staat.
private struct HistorySavingsCard: View {
    let savings: HistorySavings
    @Binding var include: Bool
    @Binding var allowDifferences: Bool
    @State private var expanded = false

    private var filledPots: [HistoryPot] { savings.pots.filter { !$0.movements.isEmpty } }

    var body: some View {
        Card("Spaarwerkmap, blad RES", icon: "square.grid.3x3.topleft.filled") {
            if savings.movementCount == 0 {
                Label("Er zijn geen mutaties gevonden in het blad RES.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.warning)
            } else {
                Toggle("Spaarhistorie importeren", isOn: $include).toggleStyle(.checkbox)
                Text(summary).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if savings.totalsMatch {
                    if savings.stoppedAtRow != nil {
                        Label("Saldi per potje kloppen met Excel", systemImage: "checkmark.circle.fill")
                            .font(.callout).foregroundStyle(Theme.positive)
                    }
                } else {
                    ForEach(Array(savings.differences.enumerated()), id: \.offset) { _, difference in
                        Label(difference.text, systemImage: "xmark.circle.fill")
                            .font(.callout).foregroundStyle(Theme.negative).fixedSize(horizontal: false, vertical: true)
                    }
                    Toggle("Toch importeren", isOn: $allowDifferences).toggleStyle(.checkbox).disabled(!include)
                }
                DisclosureGroup(isExpanded: $expanded) {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(filledPots.enumerated()), id: \.offset) { _, pot in
                            HStack {
                                Text(pot.name)
                                Text("\(pot.movements.count) mutaties").foregroundStyle(.secondary)
                                Spacer()
                                MoneyText(pot.balance)
                            }
                        }
                        HistoryNoteList(warnings: savings.warnings, skipped: savings.skippedRows)
                        ForEach(Array(savings.unread.enumerated()), id: \.offset) { _, sheet in
                            Text("Blad \(sheet.name): \(sheet.reason)").foregroundStyle(.secondary)
                        }
                    }
                    .font(.caption).padding(.top, 4)
                } label: {
                    Text("Potjes en meldingen").font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var summary: String {
        var text = "\(filledPots.count) potjes · \(savings.movementCount) mutaties"
        if let first = savings.firstDay, let last = savings.lastDay {
            text += " · \(first.short(withYear: true)) t/m \(last.short(withYear: true))"
        }
        if let row = savings.stoppedAtRow { text += " · gelezen tot rij \(row) (de totalen)" }
        return text
    }
}

// MARK: - Stap 3: rekening kiezen en gevolgen bekijken

struct HistoryAccountStep: View {
    @Environment(AppModel.self) private var model
    @Bindable var state: HistoryImportState

    private var chosenYears: [HistoryYear] { (state.budget?.years ?? []).filter { state.selected.contains($0.year) } }

    var body: some View {
        if !chosenYears.isEmpty { budgetCard }
        if state.wantsSavings { savingsCard }
    }

    private var budgetCard: some View {
        Card("Begroting", icon: "tablecells") {
            if state.checkingAccounts.isEmpty {
                Label("Er is nog geen betaalrekening. Maak er eerst een aan bij Instellingen › Rekeningen.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.warning)
            } else {
                Picker("Betaalrekening", selection: $state.accountId) {
                    ForEach(state.checkingAccounts) { account in Text(account.name).tag(account.id) }
                }
                .frame(maxWidth: 360)
                .onChange(of: state.accountId) { _, _ in state.refreshChecks(model) }
            }
            if let check = state.budgetCheck {
                ForEach(check.refused.keys.sorted(by: >), id: \.self) { year in
                    Label(check.refused[year] ?? "", systemImage: "xmark.circle.fill")
                        .font(.callout).foregroundStyle(Theme.negative).fixedSize(horizontal: false, vertical: true)
                }
                if !check.replaced.isEmpty {
                    Label("Al eerder geïmporteerd en wordt vervangen: \(list(check.replaced)).", systemImage: "arrow.triangle.2.circlepath")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if !check.existingItems.isEmpty {
                    Label("De posten die je zelf hebt ingesteld in \(list(Array(check.existingItems.keys))) worden vervangen door die uit Excel.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.callout).foregroundStyle(Theme.warning).fixedSize(horizontal: false, vertical: true)
                }
                if let problem = check.openingProblem {
                    Label(problem, systemImage: "xmark.circle.fill")
                        .font(.callout).foregroundStyle(Theme.negative).fixedSize(horizontal: false, vertical: true)
                }
                if let change = check.openingChange {
                    HistoryOpeningView(change: change)
                    if !change.difference.isZero {
                        Toggle("Akkoord: het saldo op \(change.oldDate.dutch) wordt \(change.balanceAtOldDate.formatted()) in plaats van \(change.oldBalance.formatted())",
                               isOn: $state.confirmOpening)
                            .toggleStyle(.checkbox)
                    }
                }
                let years = state.yearsToImport
                if !years.isEmpty {
                    Text("Te importeren: \(list(years.map(\.year))). Afgesloten na de import, behalve \(String(model.today.year)).")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    ForEach(years.filter { state.throughMonth[$0.year] != nil }) { year in
                        let month = state.throughMonth[year.year] ?? 12
                        Text("\(String(year.year)): alleen t/m \(month == 0 ? "geen enkele maand" : Day.monthNames[month - 1]); \(year.excludedCount(through: month)) bedragen blijven buiten de import. Saldo na import: \(year.balanceThrough(month: month)?.formatted() ?? "onbekend").")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private var savingsCard: some View {
        Card("Spaarhistorie", icon: "square.grid.3x3.topleft.filled") {
            if state.savingsAccounts.isEmpty {
                Label("Er is nog geen spaarrekening. Maak er eerst een aan bij Instellingen › Rekeningen.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.warning)
            } else {
                Picker("Spaarrekening", selection: $state.savingsAccountId) {
                    ForEach(state.savingsAccounts) { account in Text(account.name).tag(account.id) }
                }
                .frame(maxWidth: 360)
                .onChange(of: state.savingsAccountId) { _, _ in state.refreshChecks(model) }
            }
            if let check = state.savingsCheck {
                if let refusal = check.refusal {
                    Label(refusal, systemImage: "xmark.circle.fill")
                        .font(.callout).foregroundStyle(Theme.negative).fixedSize(horizontal: false, vertical: true)
                } else {
                    if check.replaces {
                        Label("De eerder geïmporteerde spaarhistorie wordt vervangen.", systemImage: "arrow.triangle.2.circlepath")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    if !check.newPots.isEmpty {
                        Text("Nieuwe potjes (als reservering): \(check.newPots.joined(separator: ", ")).")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    if let change = check.openingChange {
                        HistoryOpeningView(change: change)
                        if !change.difference.isZero {
                            Picker("Wat wil je met het saldo?", selection: $state.savingsOpening) {
                                Text("Kies…").tag(HistoryOpeningDecision.stopIfDifferent)
                                Text("Saldo op \(change.oldDate.dutch) blijft \(change.oldBalance.formatted()); de rest (\((-change.difference).formatted())) staat vanaf \(change.newDate.dutch) niet in een potje")
                                    .tag(HistoryOpeningDecision.keepOldBalance)
                                Text("Het saldo op \(change.oldDate.dutch) wordt \(change.balanceAtOldDate.formatted()) in plaats van \(change.oldBalance.formatted())")
                                    .tag(HistoryOpeningDecision.acceptNewBalance)
                            }
                            .pickerStyle(.radioGroup)
                        }
                    }
                }
            }
        }
    }

    private func list(_ years: [Int]) -> String {
        years.sorted().map(String.init).joined(separator: ", ")
    }
}

/// Wat het verschuiven van de begindatum betekent: oud saldo, nieuw berekend saldo en het verschil.
private struct HistoryOpeningView: View {
    let change: HistoryOpeningChange

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("De historie begint vóór de begindatum van deze rekening. De begindatum gaat van \(change.oldDate.dutch) naar \(change.newDate.dutch).")
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 3) {
                row("Saldo op \(change.oldDate.dutch) nu", change.oldBalance)
                row("Saldo op \(change.oldDate.dutch) volgens de historie", change.balanceAtOldDate)
                GridRow {
                    Text("Verschil").fontWeight(.medium)
                    MoneyText(change.difference, colored: !change.difference.isZero, alwaysSign: true).gridColumnAlignment(.trailing)
                }
            }
            .font(.callout)
            if change.difference.isZero {
                Label("De historie sluit precies aan; het saldo verandert niet.", systemImage: "checkmark.circle.fill")
                    .font(.callout).foregroundStyle(Theme.positive)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background((change.difference.isZero ? Theme.positive : Theme.warning).opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
    }

    private func row(_ title: String, _ amount: Money) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            MoneyText(amount).gridColumnAlignment(.trailing)
        }
    }
}

// MARK: - Stap 4: klaar

struct HistoryDoneStep: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let state: HistoryImportState

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("De historie staat erin", systemImage: "checkmark.circle.fill")
                .font(.title2.weight(.semibold)).foregroundStyle(Theme.positive)
            if let result = state.budgetResult {
                Card("Begroting", icon: "tablecells") {
                    Text(yearsText(result.years))
                    Text("\(result.itemCount) posten · \(result.entryCount) boekingen" + (result.newTagCount > 0 ? " · \(result.newTagCount) nieuwe tags" : ""))
                        .foregroundStyle(.secondary)
                    if let change = result.openingChange {
                        Text("De rekening begint nu op \(change.newDate.dutch) met \(change.newBalance.formatted()).").foregroundStyle(.secondary)
                    }
                }
            }
            if let result = state.savingsResult {
                Card("Spaarhistorie", icon: "square.grid.3x3.topleft.filled") {
                    Text("\(result.entryCount) mutaties" + (result.newPotCount > 0 ? " · \(result.newPotCount) nieuwe potjes" : ""))
                    if let change = result.openingChange {
                        Text("De rekening begint nu op \(change.newDate.dutch) met \(change.newBalance.formatted()).").foregroundStyle(.secondary)
                    }
                }
            }
            Text("Boekingen uit Excel herken je aan de notitie ‘\(HistoryImporter.note)’. Je kunt de import later opnieuw doen; de eerdere historie wordt dan vervangen.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button {
                model.selection = .reports
                dismiss()
            } label: {
                Label("Open Rapporten › Jaar op jaar", systemImage: "chart.bar.xaxis")
            }
            .buttonStyle(.borderedProminent)
            .help("Opent Rapporten. Kies daar het tabblad Jaar op jaar.")
        }
    }

    private func yearsText(_ years: [Int]) -> String {
        guard let first = years.min(), let last = years.max() else { return "Geen jaren geïmporteerd" }
        if years.count == 1 { return "1 jaar geïmporteerd: \(first)" }
        return "\(years.count) jaren geïmporteerd: \(first) t/m \(last)"
    }
}
