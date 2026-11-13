import SwiftUI
import GRDB
import HFCore
import HFHistory

/// Toestand van het venster Excel-historie importeren. Rekent niets zelf uit; alles komt uit `HFHistory`.
@MainActor @Observable
final class HistoryImportState {
    enum Step: Int, CaseIterable {
        case choose, review, account, done

        var title: String {
            switch self {
            case .choose: "Bestanden"
            case .review: "Nakijken"
            case .account: "Rekening"
            case .done: "Klaar"
            }
        }
    }

    enum FileKind { case budget, savings }

    var step: Step = .choose
    /// Foutmelding voor de alert in het venster zelf. Een alert van het hoofdvenster zou achter dit venster
    /// blijven wachten, daarom toont het venster zijn eigen meldingen.
    var problem: String?

    /// Als `AppModel.perform`, maar met de melding in dit venster.
    @discardableResult
    func perform(_ action: () throws -> Void) -> Bool {
        do { try action(); return true } catch {
            problem = error.localizedDescription
            return false
        }
    }

    // Stap 1
    var budgetFile: URL?
    var savingsFile: URL?
    var isReading = false

    // Stap 2
    var budget: HistoryBudget?
    var savings: HistorySavings?
    /// Aangevinkte jaren. Jaren waarvan de totalen niet kloppen staan er alleen in na "toch importeren".
    var selected: Set<Int> = []
    /// Grens per jaar (importeren t/m die maand); een jaar zonder grens gaat helemaal mee.
    var throughMonth: [Int: Int] = [:]
    var includeSavings = true
    var allowSavingsDifferences = false

    // Stap 3
    var checkingAccounts: [Account] = []
    var savingsAccounts: [Account] = []
    var accountId: Int64?
    var savingsAccountId: Int64?
    var budgetCheck: HistoryBudgetCheck?
    var savingsCheck: HistorySavingsCheck?
    var confirmOpening = false
    var savingsOpening: HistoryOpeningDecision = .stopIfDifferent

    // Stap 4
    var budgetResult: HistoryImportResult?
    var savingsResult: HistoryImportResult?

    // MARK: Stap 1 → 2

    var canRead: Bool { (budgetFile != nil || savingsFile != nil) && !isReading }

    func setFile(_ url: URL, kind: FileKind) {
        switch kind {
        case .budget: budgetFile = url
        case .savings: savingsFile = url
        }
    }

    /// Leest de gekozen werkmappen buiten de hoofdthread. Er wordt nog niets opgeslagen.
    func read(today: Day) async {
        isReading = true
        defer { isReading = false }
        let budgetURL = budgetFile, savingsURL = savingsFile
        let outcome = await Task.detached(priority: .userInitiated) { () -> Result<(HistoryBudget?, HistorySavings?), Error> in
            Result {
                let budget = try budgetURL.map { url in try Self.withAccess(url) { try HistoryWorkbook.readBudget(url) } }
                let savings = try savingsURL.map { url in try Self.withAccess(url) { try HistoryWorkbook.readSavings(url) } }
                return (budget, savings)
            }
        }.value
        perform {
            let (budget, savings) = try outcome.get()
            self.budget = budget
            self.savings = savings
            selected = Set((budget?.years ?? []).filter(\.totalsMatch).map(\.year))
            // Standaard gaat het hele blad mee. Alleen bedragen in het lopende jaar ná de maand van vandaag
            // (waarschijnlijk vergeten verwachtingen) staan standaard uit.
            throughMonth = [:]
            for year in budget?.years ?? [] {
                if let month = year.suggestedThroughMonth(today: today) { throughMonth[year.year] = month }
            }
            includeSavings = savings != nil
            allowSavingsDifferences = false
            step = .review
        }
    }

    nonisolated private static func withAccess<T>(_ url: URL, _ body: () throws -> T) rethrows -> T {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return try body()
    }

    // MARK: Stap 2 → 3

    var wantsSavings: Bool {
        guard let savings, includeSavings, savings.movementCount > 0 else { return false }
        return savings.totalsMatch || allowSavingsDifferences
    }

    var canContinueFromReview: Bool { !selected.isEmpty || wantsSavings }

    func toggle(_ year: Int) {
        if selected.contains(year) { selected.remove(year) } else { selected.insert(year) }
    }

    /// De aangevinkte jaren die de controle niet geweigerd heeft.
    var yearsToImport: [HistoryYear] {
        (budget?.years ?? []).filter { selected.contains($0.year) && budgetCheck?.refused[$0.year] == nil }
    }

    func prepareAccounts(_ model: AppModel) {
        var accounts: [Account] = []
        perform {
            accounts = try model.db.read {
                try Account.filter(Column("archived") == false).order(Column("sortOrder"), Column("id")).fetchAll($0)
            }
        }
        checkingAccounts = accounts.filter { $0.kind == .betaal }
        savingsAccounts = accounts.filter { $0.kind == .spaar }
        if accountId == nil || !checkingAccounts.contains(where: { $0.id == accountId }) { accountId = checkingAccounts.first?.id }
        if savingsAccountId == nil || !savingsAccounts.contains(where: { $0.id == savingsAccountId }) { savingsAccountId = savingsAccounts.first?.id }
        refreshChecks(model)
        step = .account
    }

    /// Vraagt `HFHistory` wat de import op de gekozen rekeningen zou doen. Wijzigt niets.
    func refreshChecks(_ model: AppModel) {
        confirmOpening = false
        savingsOpening = .stopIfDifferent
        budgetCheck = nil
        savingsCheck = nil
        let chosen = (budget?.years ?? []).filter { selected.contains($0.year) }
        let limits = throughMonth
        if !chosen.isEmpty, let accountId {
            perform { budgetCheck = try model.db.read { try HistoryImporter.checkBudget($0, years: chosen, accountId: accountId, throughMonth: limits) } }
        }
        if wantsSavings, let savings, let savingsAccountId {
            perform { savingsCheck = try model.db.read { try HistoryImporter.checkSavings($0, savings: savings, accountId: savingsAccountId) } }
        }
    }

    // MARK: Stap 3 → 4

    var budgetReady: Bool {
        guard !yearsToImport.isEmpty, accountId != nil, let check = budgetCheck, check.openingProblem == nil else { return false }
        if let change = check.openingChange, !change.difference.isZero { return confirmOpening }
        return true
    }

    var savingsReady: Bool {
        guard wantsSavings, savingsAccountId != nil, let check = savingsCheck, check.refusal == nil else { return false }
        if let change = check.openingChange, !change.difference.isZero { return savingsOpening != .stopIfDifferent }
        return true
    }

    /// Er is iets om te importeren en niets wacht nog op een keuze.
    var canImport: Bool {
        let budgetPending = !yearsToImport.isEmpty
        let savingsPending = wantsSavings && savingsCheck?.refusal == nil
        guard budgetPending || savingsPending else { return false }
        return (!budgetPending || budgetReady) && (!savingsPending || savingsReady)
    }

    var importTitle: String {
        let n = yearsToImport.count
        if n == 0 { return "Importeer spaarhistorie" }
        return n == 1 ? "Importeer 1 jaar" : "Importeer \(n) jaren"
    }

    /// Schrijft alles in één transactie: lukt de spaarhistorie niet, dan komt ook de begroting er niet in.
    func runImport(_ model: AppModel) {
        let years = yearsToImport
        let forced = Set(years.filter { !$0.totalsMatch }.map(\.year))
        let importSavings = wantsSavings && savingsCheck?.refusal == nil
        let today = model.today
        let limits = throughMonth
        let done = perform {
            try model.db.write { db in
                if !years.isEmpty, let accountId {
                    budgetResult = try HistoryImporter.importBudget(db, years: years, accountId: accountId, forcedYears: forced, throughMonth: limits,
                                                                    confirmOpeningChange: confirmOpening, today: today)
                }
                if importSavings, let savings, let savingsAccountId {
                    savingsResult = try HistoryImporter.importSavings(db, savings: savings, accountId: savingsAccountId,
                                                                      allowDifferences: allowSavingsDifferences,
                                                                      opening: savingsOpening)
                }
            }
            step = .done
        }
        if !done { budgetResult = nil; savingsResult = nil }
    }
}
