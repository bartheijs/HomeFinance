import SwiftUI
import GRDB
import HFCore
import HFImport
import HFRules
import HFBudget
import HFInsight

// Toestand en acties van het scherm "Importeren en nakijken".
// Rekenwerk zit in de modules: voorstellen (HFRules), boeken (HFBudget), wachtrij (HFInsight), import (HFImport).

/// Waar een (deel van een) transactie naartoe gaat. `none` = divers (betaal) of niet toegewezen (spaar).
enum ReviewTarget: Hashable, Sendable {
    case none
    case item(Int64)
    case pot(Int64)
}

/// Eén regel in de splitsing van een transactie.
struct ReviewSplitLine: Identifiable, Equatable {
    var id = UUID()
    var amount: Money?
    var label = ""
    var target: ReviewTarget = .none
    /// Het verschil tussen het gestorte bedrag en de vaste storting; de gebruiker kiest waar het heen gaat.
    var isDifference = false
    /// Verrekenen met spaar voor deze regel (alleen betaalrekening): de pot, of nil voor "Nee".
    var settlePotId: Int64?

    static func == (l: Self, r: Self) -> Bool {
        l.amount == r.amount && l.label == r.label && l.target == r.target && l.isDifference == r.isDifference
            && l.settlePotId == r.settlePotId
    }
}

/// Het voorstel zoals de gebruiker het kan aanpassen voordat hij boekt.
struct ReviewDraft: Equatable {
    var target: ReviewTarget = .none
    var label = ""
    var tagIds: Set<Int64> = []
    var reimburse = false
    var reimbursePotId: Int64?
    var note = ""
    /// Geld dat even van spaar is gehaald (of de terugboeking daarvan); telt niet mee als besteedbaar.
    var temporaryLoan = false
    /// "yyyy-MM": de maand waarin de boeking meetelt; nil = de maand van de datum.
    var period: String?
    var isSplit = false
    var lines: [ReviewSplitLine] = []
}

/// Groepen in de wachtrij: twijfelgevallen eerst.
enum ReviewGroup: Int, CaseIterable, Identifiable {
    case doubt, probable, certain
    var id: Int { rawValue }

    var title: String {
        switch self {
        case .doubt: "Twijfelgevallen"
        case .probable: "Waarschijnlijk goed"
        case .certain: "Zeker"
        }
    }
    var help: String {
        switch self {
        case .doubt: "Geen regel gevonden, alleen een gok, of het bedrag wijkt af. Kijk deze eerst na."
        case .probable: "Een regel herkent de tegenpartij of de omschrijving, maar niet het bedrag."
        case .certain: "Tegenpartij en bedrag kloppen met een regel. Deze kun je in één keer boeken."
        }
    }
    var icon: String {
        switch self {
        case .doubt: "questionmark.circle.fill"
        case .probable: "circle.lefthalf.filled"
        case .certain: "checkmark.circle.fill"
        }
    }
    var color: Color {
        switch self {
        case .doubt: Theme.warning
        case .probable: Theme.info
        case .certain: Theme.positive
        }
    }
}

/// Eén transactie in de wachtrij met alles wat de modules erover zeggen.
struct ReviewRow: Identifiable, Equatable {
    let item: ReviewItem
    let suggestion: Suggestion
    let cleanLabel: String
    let group: ReviewGroup
    /// Herkend als (een kant van) een vaste storting; gaat vóór de regels.
    let match: DistributionMatch?
    /// De bankregel van een verrekening met spaar; gaat vóór vaste stortingen en regels.
    let settlement: SavingsTransferMatch?
    /// Deze transactie is één kant van een overboeking tussen eigen rekeningen.
    let pair: TransferPair?
    /// Doelkant van een herkende storting: de gebruiker boekt het als de vaste storting (verdeling over de
    /// potten) of juist als één pot. Standaard de verdeling, behalve als het een losse overboeking lijkt.
    var usesDistribution = true
    /// Waarschuwing als bij deze transactie verrekenen met spaar wordt gekozen (overboeking met eigen spaar).
    var ownSavingsWarning: String?

    var id: Int64 { item.id }
    /// De vaste storting zoals die meetelt voor het voorstel: nil als de gebruiker één pot kiest.
    var activeMatch: DistributionMatch? { usesDistribution ? match : nil }
    /// Aan de doelkant kan de gebruiker wisselen tussen de vaste storting en één pot.
    var canSwitchDistribution: Bool { match?.side == .destination && match?.distribution != nil }
    var tx: BankTransaction { item.transaction }
}

/// "Onthoud als regel" of "Regel bijwerken met deze keuze?" in het detail, met de samenvatting uit HFRules.
struct ReviewRuleOption: Equatable {
    /// Het concept werkt de regel bij die het voorstel deed (anders: een nieuwe regel).
    var isUpdate: Bool
    var isOn: Bool
    /// De regel zoals hij bewaard wordt als het vinkje aan staat.
    var rule: Rule
    /// "Voortaan bij …: post …" (uit `RuleEngine.summary`).
    var summary: String
    var title: String { isUpdate ? "Regel bijwerken met deze keuze" : "Onthoud als regel" }
}

/// Melding onder de wachtrij, met de mogelijkheid om de laatste actie terug te draaien.
struct ReviewNotice: Identifiable {
    let id = UUID()
    var text: String
    var undo: (@MainActor (AppModel) -> Void)?
}

/// Eén rekening binnen een import: het voorbeeld van één bestand.
struct ReviewImportPart: Identifiable {
    var id: String { fileName }
    var fileName: String
    var accountName: String
    var preview: ImportPreview
    /// De rekening heeft Excel-historie; anders start hij met alleen een beginsaldo.
    var hasHistory = false
    /// Eerste import van de rekening: positie (in tijdsvolgorde) van de eerste regel die volgens het
    /// eerste voorstel meegaat. Daaromheen toont het venster de regels om zelf te kiezen.
    var seamCenter: Int?
    /// Regelnummers die de app zelf buiten de import hield (vóór het beginsaldo of in de Excel-historie),
    /// om ze te onderscheiden van regels die de gebruiker zelf uitzet.
    var autoSkipped: Set<Int> = []

    /// Alles wat niet nieuw is: eerder geïmporteerd of niet meegenomen. Nieuw + al bekend + fout = alle regels.
    var knownCount: Int { preview.duplicateCount + preview.cutoverSkippedCount }

    /// Het label bij een regel die niet wordt geïmporteerd, of nil als hij meegaat.
    func knownLabel(_ row: ImportRow) -> String? {
        if row.isBeforeCutover {
            guard autoSkipped.contains(row.lineNumber) else { return "gaat niet mee" }
            return hasHistory ? "al bekend (in je Excel-historie)" : "al bekend (vóór je beginsaldo)"
        }
        return row.isDuplicate ? "al geïmporteerd" : nil
    }

    /// Uitsplitsing van "Al bekend", bv. "3 van vóór je beginsaldo · 0 eerder geïmporteerd".
    var knownBreakdown: String {
        let before = preview.rows.filter { $0.isBeforeCutover && autoSkipped.contains($0.lineNumber) }.count
        let manual = preview.cutoverSkippedCount - before
        var parts = ["\(before) \(hasHistory ? "uit je Excel-historie" : "van vóór je beginsaldo")",
                     "\(preview.duplicateCount) eerder geïmporteerd"]
        if manual > 0 { parts.append("\(manual) zelf uitgezet") }
        return parts.joined(separator: " · ")
    }
}

/// Een gekozen bestand (zip van de bank of een los afschrift) dat gelezen is en op bevestiging wacht.
struct ReviewPendingImport: Identifiable {
    var id = UUID()
    var fileName: String
    /// De zip zoals HFImport hem las; nil bij een los bestand.
    var archive: ArchivePreview?
    var parts: [ReviewImportPart]
    /// Bestanden uit de zip die niet meegaan, met de reden.
    var skipped: [ArchiveItem] = []
    /// Los bestand: bij welke rekening het hoort en hoe dat bepaald is.
    var recognition: String?
    var recognized = true

    var newCount: Int { parts.map(\.preview.newCount).reduce(0, +) }
    var errorCount: Int { parts.map(\.preview.errorCount).reduce(0, +) }
}

/// Een bestand waarvan de kolomindeling niet herkend is.
struct ReviewRawFile: Identifiable {
    let id = UUID()
    var fileName: String
    var rows: [[String]]
    var columnCount: Int
}

@MainActor @Observable
final class ReviewStore {
    var accounts: [Account] = []
    var accountId: Int64?
    /// Aantal nog te boeken transacties per rekening.
    var openCounts: [Int64: Int] = [:]
    var rows: [ReviewRow] = []
    var selection: Set<Int64> = []
    /// De rij waar de pijltjestoetsen vanaf tellen.
    var cursor: Int64?
    var pots: [Pot] = []
    var tags: [Tag] = []
    var pairs: [TransferPair] = []
    var lastBatch: ImportBatch?
    var check: ImportCheck?
    var notice: ReviewNotice?
    var pendingImport: ReviewPendingImport?
    var rawFile: ReviewRawFile?
    var loaded = false
    /// "Meer opties" in het paneel rechts staat open.
    var showMore = false
    /// Wat er nu uitstaat aan tijdelijk van spaar geleend geld.
    var loanOutstanding: Money = .zero
    /// Bestaande omschrijvingen, om aan te vullen bij het typen.
    var labels: [LabelSuggestion] = []

    private var itemsByYear: [Int: [BudgetItem]] = [:]
    private var itemsById: [Int64: BudgetItem] = [:]
    private var potsById: [Int64: Pot] = [:]
    private var drafts: [Int64: ReviewDraft] = [:]
    private var defaults: [Int64: ReviewDraft] = [:]
    /// De vaste storting die de gebruiker koos toen er meer kandidaten waren.
    private var chosenMatches: [Int64: DistributionMatch] = [:]
    /// Keuze van de gebruiker tussen vaste storting (true) en één pot (false), per transactie.
    private var distributionChoice: [Int64: Bool] = [:]
    /// "Onthoud als regel" / "Regel bijwerken" aangevinkt, per transactie (standaard uit).
    private var rememberRule: Set<Int64> = []
    /// Regelconcept dat de gebruiker in de editor aanpaste, met de keuze waarbij dat gebeurde.
    private var customRules: [Int64: (correction: Correction, rule: Rule)] = [:]
    /// Voorkomt dat het scherm bij elke tekening de regels opnieuw uit de database haalt.
    @ObservationIgnored private var proposalCache: [Int64: (correction: Correction, proposal: RuleProposal)] = [:]
    @ObservationIgnored private var summaryCache: [Int64: (rule: Rule, text: String)] = [:]

    // MARK: Afgeleid

    var account: Account? { accounts.first { $0.id == accountId } }
    var kind: AccountKind { account?.kind ?? .betaal }
    var checkingAccount: Account? { accounts.first { $0.kind == .betaal } }

    var selectedRows: [ReviewRow] { rows.filter { selection.contains($0.id) } }
    var singleRow: ReviewRow? { selection.count == 1 ? rows.first { selection.contains($0.id) } : nil }

    func rows(in group: ReviewGroup) -> [ReviewRow] { rows.filter { $0.group == group } }

    /// Transacties die zonder kijken geboekt kunnen worden: zekerheid hoog en het bedrag klopt.
    var certainRows: [ReviewRow] {
        rows.filter { $0.group == .certain && problem(for: $0) == nil }
    }
    /// Alles wat je zelf even moet bekijken.
    var toCheckRows: [ReviewRow] { rows.filter { $0.group != .certain } }

    func items(year: Int, direction: Direction) -> [BudgetItem] {
        (itemsByYear[year] ?? []).filter { $0.direction == direction }
    }
    func yearExists(_ year: Int) -> Bool { itemsByYear[year] != nil }
    func pots(kind: PotKind, accountId: Int64? = nil) -> [Pot] {
        pots.filter { $0.kind == kind && (accountId == nil || $0.accountId == accountId) }
    }
    func accountName(_ id: Int64) -> String { accounts.first { $0.id == id }?.name ?? "andere rekening" }

    func potName(_ id: Int64?) -> String? { id.flatMap { potsById[$0]?.name } }

    func title(of target: ReviewTarget, kind: AccountKind) -> String {
        switch target {
        case .none: kind == .betaal ? "Divers" : "Geen pot (divers)"
        case .item(let id): itemsById[id]?.label ?? "Onbekende post"
        case .pot(let id): potsById[id]?.name ?? "Onbekende pot"
        }
    }

    // MARK: Laden

    /// Bankregels van al afgevinkte verrekeningen met spaar worden aan hun boekingen gehangen en verdwijnen
    /// uit de wachtrij. Schrijft alleen als er echt iets te doen is.
    private func attachSettlements(_ model: AppModel) {
        let accountIds: [Int64] = model.read([]) { db in
            try Int64.fetchAll(db, sql: "SELECT id FROM account WHERE archived = 0").filter { id in
                try SavingsTransferService.recognizeAll(db, accountId: id).values.contains { $0.transfer?.done == true }
            }
        }
        guard !accountIds.isEmpty else { return }
        var attached = 0
        model.perform {
            try model.db.write { db in
                for id in accountIds { attached += try SavingsTransferService.attachAll(db, accountId: id) }
            }
        }
        guard attached > 0 else { return }
        let text = attached == 1 ? "1 verrekening herkend en afgehandeld" : "\(attached) verrekeningen herkend en afgehandeld"
        notice = ReviewNotice(text: text)
    }

    func load(_ model: AppModel) {
        let jump = model.reviewJump
        if let jump { accountId = jump.accountId }
        attachSettlements(model)
        model.read(()) { db in
            accounts = try Account.fetchAll(db, sql: "SELECT * FROM account WHERE archived = 0 ORDER BY sortOrder, id")
            if accountId == nil || !accounts.contains(where: { $0.id == accountId }) { accountId = accounts.first?.id }
            tags = try Tag.fetchAll(db, sql: "SELECT * FROM tag ORDER BY sortOrder, id")
            pots = Insight.pickerOrder(try Pot.fetchAll(db, sql: "SELECT * FROM pot WHERE archived = 0 ORDER BY sortOrder, id"))
            potsById = Dictionary(uniqueKeysWithValues: pots.compactMap { p in p.id.map { ($0, p) } })

            let years = try BudgetYear.fetchAll(db)
            let yearById = Dictionary(uniqueKeysWithValues: years.compactMap { y in y.id.map { ($0, y.year) } })
            // RES-regels krijgen geen boekingen; de regel RESERVERINGEN (UIT) wel.
            let items = try BudgetItem.fetchAll(db, sql: "SELECT * FROM budgetItem WHERE direction <> 'RES' ORDER BY sortOrder, id")
            itemsById = Dictionary(uniqueKeysWithValues: items.compactMap { i in i.id.map { ($0, i) } })
            var byYear: [Int: [BudgetItem]] = Dictionary(uniqueKeysWithValues: years.map { ($0.year, []) })
            // Per richting op alfabet voor de post-kiezer (Insight.itemPickerOrder, 6n).
            for item in Insight.itemPickerOrder(items) { if let year = yearById[item.yearId] { byYear[year, default: []].append(item) } }
            itemsByYear = byYear

            loanOutstanding = try Insight.temporaryLoanOutstanding(db, on: model.today)
            let queue = try Insight.reviewQueue(db)
            openCounts = Dictionary(grouping: queue, by: \.transaction.accountId).mapValues(\.count)
            guard let accountId, let account else {
                rows = []; pairs = []; lastBatch = nil; check = nil
                return
            }
            let suggestions = try RuleEngine.suggestAll(db, accountId: accountId)
            // Volgorde van herkennen: verrekeningen met spaar, dan vaste stortingen, dan regels.
            let settlements = try SavingsTransferService.recognizeAll(db, accountId: accountId)
            let matches = try DistributionService.recognizeAll(db, accountId: accountId)
            labels = try Insight.allLabels(db, accountKind: account.kind)
            // Wat als verrekening of vaste storting herkend is, telt niet mee als losse overboeking.
            pairs = try TransferService.findTransferPairs(db).filter { pair in
                guard pair.from.accountId == accountId || pair.to.accountId == accountId,
                      pair.from.status == .nieuw || pair.to.status == .nieuw else { return false }
                for side in [pair.from, pair.to] where side.status == .nieuw {
                    if try SavingsTransferService.recognize(db, bankTransaction: side) != nil { return false }
                    if try DistributionService.recognize(db, bankTransaction: side) != nil { return false }
                }
                return true
            }
            rows = try queue.filter { $0.transaction.accountId == accountId }.map { item in
                let tx = item.transaction
                let suggestion = suggestions[item.id] ?? Suggestion(bankTransactionId: item.id)
                let settlement = settlements[item.id]
                let match = settlement == nil ? chosenMatches[item.id] ?? matches[item.id] : nil
                let pair = pairs.first { $0.from.id == tx.id || $0.to.id == tx.id }
                let uses = match.map { m in
                    m.side == .destination && m.distribution != nil ? distributionChoice[item.id] ?? !m.looksSeparate : true
                } ?? true
                let ownSavings = account.kind == .betaal
                    ? try SavingsTransferService.ownSavingsWarning(db, bankTransaction: tx, reimburse: true) : nil
                return ReviewRow(
                    item: item, suggestion: suggestion,
                    cleanLabel: LabelCleaner.cleanLabel(counterparty: tx.counterpartyName, description: tx.descriptionText),
                    group: settlement != nil ? .doubt
                        : match.map { $0.distribution != nil && $0.exactAmount && uses ? .certain : .doubt }
                        ?? Self.group(suggestion, hasProposal: pair != nil),
                    match: match, settlement: settlement, pair: pair,
                    usesDistribution: uses, ownSavingsWarning: ownSavings)
            }
            .sorted { ($0.group.rawValue, $0.tx.day, $0.id) < ($1.group.rawValue, $1.tx.day, $1.id) }

            lastBatch = try ImportBatch.fetchOne(db, sql: """
                SELECT * FROM importBatch WHERE accountId = ? ORDER BY importedAt DESC, id DESC LIMIT 1
                """, arguments: [accountId])
            check = try lastBatch?.id.map { try BalanceService.importCheck(db, batchId: $0) }
        }
        loaded = true

        let ids = Set(rows.map(\.id))
        drafts = drafts.filter { ids.contains($0.key) }
        chosenMatches = chosenMatches.filter { ids.contains($0.key) }
        distributionChoice = distributionChoice.filter { ids.contains($0.key) }
        rememberRule = rememberRule.intersection(ids)
        customRules = customRules.filter { ids.contains($0.key) }
        proposalCache = [:]
        summaryCache = [:]
        defaults = defaults.filter { ids.contains($0.key) }
        for row in rows {
            let fresh = makeDefault(row)
            if defaults[row.id] != fresh { defaults[row.id] = fresh }
        }
        if let jump, jump.accountId == accountId {
            model.reviewJump = nil
            if ids.contains(jump.transactionId) { selection = [jump.transactionId]; cursor = jump.transactionId }
        }
        selection = selection.intersection(ids)
        if selection.isEmpty, let first = rows.first { selection = [first.id] }
        if cursor == nil || !selection.contains(cursor!) { cursor = rows.first { selection.contains($0.id) }?.id }
        SelfTest.potPickerLoaded(.review, kinds: pots.map(\.kind), names: pots.map(\.name))
    }

    private static func group(_ s: Suggestion, hasProposal: Bool) -> ReviewGroup {
        if s.amountDiffers || !s.warnings.isEmpty { return .doubt }
        switch s.confidence {
        case .hoog: return .certain
        case .midden: return .probable
        case .laag, .geen: return hasProposal ? .probable : .doubt
        }
    }

    // MARK: Voorstel en concept

    private func makeDefault(_ row: ReviewRow) -> ReviewDraft {
        let s = row.suggestion
        var draft = ReviewDraft(label: s.label.isEmpty || s.label == "Onbekend" ? row.cleanLabel : s.label,
                                tagIds: kind == .betaal ? Set(s.tagIds) : [])   // tags alleen op de betaalrekening
        if draft.label.isEmpty { draft.label = "Onbekend" }
        // Een vaste storting gaat vóór de regels.
        if let match = row.activeMatch, match.distribution != nil, !match.allocations.isEmpty {
            draft.tagIds = []
            if match.side == .source, let only = match.allocations.first {
                draft.label = only.label
                draft.target = only.budgetItemId.flatMap { itemsById[$0] != nil ? .item($0) : nil } ?? .none
                draft.temporaryLoan = false
            } else {
                draft.isSplit = true
                draft.lines = match.allocations.map { a in
                    ReviewSplitLine(amount: a.amount, label: a.label, target: a.potId.map { .pot($0) } ?? .none)
                }
                if !match.difference.isZero {
                    draft.lines.append(ReviewSplitLine(amount: match.difference,
                                                       label: "\(match.distribution?.name ?? "Storting"): verschil",
                                                       target: .none, isDifference: true))
                }
            }
            return draft
        }
        switch kind {
        case .betaal:
            if let id = s.budgetItemId, itemsById[id] != nil { draft.target = .item(id) }
            draft.reimburse = s.reimburse
            draft.reimbursePotId = draft.reimburse ? s.potId : nil
            draft.temporaryLoan = looksLikeLoanReturn(row)
        case .spaar:
            if let id = s.potId, potsById[id]?.accountId == row.tx.accountId { draft.target = .pot(id) }
        }
        return draft
    }

    /// De betaalkant van een overboeking naar een eigen rekening, terwijl er nog geleend geld uitstaat:
    /// dit lijkt de terugboeking van wat tijdelijk van spaar is gehaald.
    func looksLikeLoanReturn(_ row: ReviewRow) -> Bool {
        kind == .betaal && row.pair != nil && row.tx.amount.isNegative && loanOutstanding > .zero
    }

    /// Er passen meer vaste stortingen: de gebruiker kiest er één, daarna volgt het voorstel van die storting.
    func chooseDistribution(_ distribution: Distribution, for row: ReviewRow, _ model: AppModel) {
        guard let id = distribution.id else { return }
        let ok = model.perform {
            chosenMatches[row.id] = try model.db.read {
                try DistributionService.proposal($0, distributionId: id, for: row.tx)
            }
        }
        if ok { drafts[row.id] = nil; load(model) }
    }

    /// Doelkant van een herkende vaste storting: boeken als de storting (verdeling over de potten) of als één pot.
    /// Kiest de gebruiker de storting terwijl er nog geen verdeling is (het leek een losse overboeking), dan
    /// wordt het voorstel van die storting opgehaald.
    func setUsesDistribution(_ on: Bool, for row: ReviewRow, _ model: AppModel) {
        guard row.canSwitchDistribution, let id = row.match?.distribution?.id else { return }
        if on, row.match?.allocations.isEmpty == true {
            let ok = model.perform {
                chosenMatches[row.id] = try model.db.read {
                    try DistributionService.proposal($0, distributionId: id, for: row.tx)
                }
            }
            guard ok else { return }
        }
        distributionChoice[row.id] = on
        drafts[row.id] = nil
        load(model)
    }

    /// De waarschuwing bij verrekenen met spaar op een overboeking met de eigen spaarrekening, als die in het
    /// concept gekozen is (ook in een regel van een splitsing). Nil als er niets te waarschuwen is.
    func ownSavingsWarning(for row: ReviewRow) -> String? {
        guard let text = row.ownSavingsWarning else { return nil }
        let draft = draft(for: row)
        let settles = draft.isSplit ? draft.lines.contains { $0.settlePotId != nil } : draft.reimburse
        return settles ? text : nil
    }

    /// Maakt een tag (en zet verrekenen aan vanaf de begindatum van de rekening) en zet hem op deze transactie.
    /// Geeft een Nederlandse foutmelding terug, of nil als het gelukt is.
    func createTag(name: String, color: String, settles: Bool, for row: ReviewRow, _ model: AppModel) -> String? {
        let from = account?.openingDate ?? row.tx.day
        var created: Tag?
        do {
            try model.db.write { db in
                let tag = try TagService.create(db, name: name, color: color)
                if settles, let id = tag.id { try SettlementService.enable(db, tagId: id, from: from) }
                created = tag
            }
        } catch {
            return error.localizedDescription
        }
        guard let id = created?.id else { return nil }
        model.read(()) { db in tags = try Tag.fetchAll(db, sql: "SELECT * FROM tag ORDER BY sortOrder, id") }
        var d = draft(for: row)
        d.tagIds.insert(id)   // gaat zo ook mee in het regelconcept (Onthoud als regel)
        setDraft(d, for: row)
        model.toast = settles ? "Tag \"\(name)\" gemaakt met verrekenen" : "Tag \"\(name)\" gemaakt"
        return nil
    }

    /// De drie maanden rond de datum van de transactie, als (periode, naam); nil = de maand van de datum zelf.
    func periodChoices(for row: ReviewRow) -> [(period: String?, title: String)] {
        (-1...1).map { offset in
            var year = row.tx.day.year, month = row.tx.day.month + offset
            if month < 1 { month = 12; year -= 1 } else if month > 12 { month = 1; year += 1 }
            return (offset == 0 ? nil : String(format: "%04d-%02d", year, month),
                    "\(Day.monthNames[month - 1]) \(year)")
        }
    }

    func draft(for row: ReviewRow) -> ReviewDraft { drafts[row.id] ?? defaults[row.id] ?? makeDefault(row) }
    func isEdited(_ row: ReviewRow) -> Bool { drafts[row.id] != nil }

    func setDraft(_ draft: ReviewDraft, for row: ReviewRow) {
        if draft == defaults[row.id] { drafts[row.id] = nil } else { drafts[row.id] = draft }
    }
    func resetDraft(for row: ReviewRow) { drafts[row.id] = nil }

    // MARK: Regels alleen met toestemming

    /// Wat de regels met de huidige keuze zouden doen (uit HFRules; schrijft niets).
    private func ruleProposal(for row: ReviewRow, _ model: AppModel) -> RuleProposal? {
        let draft = draft(for: row)
        // Een gesplitste boeking, een vaste storting of een verrekening wordt niet als regel onthouden.
        guard !draft.isSplit, row.match == nil, row.settlement == nil else { return nil }
        let correction = correction(for: row)
        if let cached = proposalCache[row.id], cached.correction == correction { return cached.proposal }
        let proposal: RuleProposal? = model.read(nil) { try RuleEngine.ruleProposal(for: correction, $0) }
        if let proposal { proposalCache[row.id] = (correction, proposal) }
        return proposal
    }

    /// De regel die bewaard wordt als het vinkje aan staat: het concept, of de versie uit de editor. Is de keuze
    /// daarna nog veranderd, dan neemt die versie de nieuwe keuze over (de voorwaarden blijven).
    private func shownRule(for row: ReviewRow, _ proposal: RuleProposal) -> Rule? {
        if let custom = customRules[row.id] {
            let correction = correction(for: row)
            return custom.correction == correction ? custom.rule : RuleEngine.applyChoice(correction, to: custom.rule)
        }
        return proposal.draft
    }

    /// De optie onder "Waar hoort dit bij?", of nil als er niets aan te bieden is (bijvoorbeeld als de keuze
    /// gelijk is aan het voorstel van een regel).
    func ruleOption(for row: ReviewRow, _ model: AppModel) -> ReviewRuleOption? {
        guard let proposal = ruleProposal(for: row, model), proposal.offersChoice,
              let rule = shownRule(for: row, proposal) else { return nil }
        let summary: String
        if let cached = summaryCache[row.id], cached.rule == rule {
            summary = cached.text
        } else {
            summary = model.read("") { try RuleEngine.summary(of: rule, $0) }
            summaryCache[row.id] = (rule, summary)
        }
        return ReviewRuleOption(isUpdate: proposal.isUpdate, isOn: rememberRule.contains(row.id), rule: rule,
                                summary: summary)
    }

    func setRemember(_ on: Bool, for row: ReviewRow) {
        if on { rememberRule.insert(row.id) } else { rememberRule.remove(row.id); customRules[row.id] = nil }
    }

    /// De gebruiker paste het concept aan in de editor. Geeft een foutmelding, of nil als het goed is.
    func setCustomRule(_ rule: Rule, for row: ReviewRow) -> String? {
        do { try RuleEngine.validate(rule) } catch { return error.localizedDescription }
        customRules[row.id] = (correction(for: row), rule)
        rememberRule.insert(row.id)
        return nil
    }

    /// De regel die het voorstel deed, om hem vanuit Nakijken aan te passen.
    func proposingRule(for row: ReviewRow, _ model: AppModel) -> Rule? {
        guard let id = row.suggestion.ruleId else { return nil }
        return model.read(nil) { try RuleEngine.rule(id: id, $0) }
    }

    /// Bewaart een aangepaste bestaande regel en haalt de voorstellen opnieuw op.
    /// Geeft een foutmelding, of nil als het gelukt is.
    func saveRule(_ rule: Rule, _ model: AppModel) -> String? {
        var rule = rule
        do { try model.db.write { try RuleEngine.save(&rule, $0) } } catch { return error.localizedDescription }
        model.toast = "Regel ‘\(rule.name)’ bewaard"
        load(model)
        return nil
    }

    /// Wat er nog niet verdeeld is in een splitsing.
    func remaining(_ draft: ReviewDraft, for row: ReviewRow) -> Money {
        row.tx.amount - draft.lines.compactMap(\.amount).sum()
    }

    /// Waarom er nog niet geboekt kan worden, of nil als het kan.
    func problem(for row: ReviewRow) -> String? {
        let draft = draft(for: row)
        guard draft.isSplit else { return nil }
        if draft.lines.isEmpty { return "Voeg minstens één regel toe." }
        if draft.lines.contains(where: { $0.amount == nil }) { return "Vul bij elke regel een geldig bedrag in." }
        let rest = remaining(draft, for: row)
        return rest.isZero ? nil : "Nog te verdelen: \(rest.formatted())."
    }

    private func allocations(for row: ReviewRow, reviewed: Bool) -> [Allocation] {
        let draft = draft(for: row)
        let s = row.suggestion
        let note = draft.note.trimmingCharacters(in: .whitespacesAndNewlines)
        // Tags alleen op de betaalrekening (in Nakijken staan alleen nieuwe transacties: geen tags van vroeger).
        let tagIds = kind == .betaal ? draft.tagIds.sorted() : []
        func ids(_ target: ReviewTarget) -> (item: Int64?, pot: Int64?) {
            switch target {
            case .none: (nil, nil)
            case .item(let id): (id, nil)
            case .pot(let id): (nil, id)
            }
        }
        if draft.isSplit {
            return draft.lines.map { line in
                let t = ids(line.target)
                let label = line.label.trimmingCharacters(in: .whitespaces)
                let settle = kind == .betaal ? line.settlePotId : nil
                return Allocation(amount: line.amount ?? .zero, label: label.isEmpty ? draft.label : label,
                                  budgetItemId: t.item, potId: settle ?? t.pot, reimburse: settle != nil,
                                  tagIds: tagIds, note: note, reviewed: reviewed, period: draft.period)
            }
        }
        let t = ids(draft.target)
        let reimburse = kind == .betaal && draft.reimburse
        let sameTarget = s.ruleId != nil && draft.target == defaults[row.id]?.target
        let label = draft.label.trimmingCharacters(in: .whitespaces)
        return [Allocation(amount: row.tx.amount, label: label.isEmpty ? row.cleanLabel : label,
                           budgetItemId: t.item, potId: kind == .betaal ? (reimburse ? draft.reimbursePotId : nil) : t.pot,
                           reimburse: reimburse, tagIds: tagIds, note: note,
                           ruleId: sameTarget ? s.ruleId : nil, confidence: sameTarget ? s.confidence : nil,
                           reviewed: reviewed, temporaryLoan: kind == .betaal && draft.temporaryLoan,
                           period: draft.period)]
    }

    private func correction(for row: ReviewRow) -> Correction {
        let draft = draft(for: row)
        var itemLabel: String?
        var potId: Int64?
        switch draft.target {
        case .none: break
        case .item(let id): itemLabel = itemsById[id]?.label
        case .pot(let id): potId = id
        }
        let reimburse = kind == .betaal && draft.reimburse
        if reimburse { potId = draft.reimbursePotId }
        let label = draft.label.trimmingCharacters(in: .whitespaces)
        return Correction(bankTransaction: row.tx, itemLabel: itemLabel, potId: potId,
                          entryLabel: label.isEmpty || label == row.suggestion.label ? nil : label,
                          tagIds: kind == .betaal ? draft.tagIds.sorted() : [], reimburse: reimburse)
    }

    // MARK: Selectie

    func select(_ id: Int64, command: Bool = false, shift: Bool = false) {
        if shift, let from = cursor, let a = rows.firstIndex(where: { $0.id == from }),
           let b = rows.firstIndex(where: { $0.id == id }) {
            selection = Set(rows[min(a, b)...max(a, b)].map(\.id))
        } else if command {
            if selection.contains(id) { if selection.count > 1 { selection.remove(id) } } else { selection.insert(id) }
            cursor = id
        } else {
            selection = [id]
            cursor = id
        }
    }

    /// Pijltjestoetsen: één rij omhoog of omlaag; met shift groeit de selectie.
    func move(_ delta: Int, extend: Bool) {
        guard !rows.isEmpty else { return }
        let current = rows.firstIndex { $0.id == cursor } ?? (delta > 0 ? -1 : rows.count)
        let next = rows[min(max(current + delta, 0), rows.count - 1)].id
        if extend { selection.insert(next) } else { selection = [next] }
        cursor = next
    }

    func selectAll() { selection = Set(rows.map(\.id)) }

    /// De rij die na het boeken van `ids` geselecteerd wordt, zodat ⏎ blijft doorwerken.
    private func successor(of ids: Set<Int64>) -> Int64? {
        guard let last = rows.lastIndex(where: { ids.contains($0.id) }) else { return nil }
        return rows[(last + 1)...].first { !ids.contains($0.id) }?.id
            ?? rows[..<last].last { !ids.contains($0.id) }?.id
    }

    private func finish(_ model: AppModel, handled ids: Set<Int64>) {
        let next = successor(of: ids)
        for id in ids { drafts[id] = nil }
        selection = next.map { [$0] } ?? []
        cursor = next
        load(model)
        model.autoReconcile()
    }

    // MARK: Boeken en overslaan

    /// Boekt de geselecteerde transactie met de keuze zoals die er staat. Een regel wordt alleen bewaard of
    /// bijgewerkt als "Onthoud als regel" of "Regel bijwerken met deze keuze" aan staat.
    func bookCurrent(_ model: AppModel) {
        guard let row = singleRow else { return }
        if let settlement = row.settlement {
            if let transfer = settlement.transfer { attachSettlement(transfer, to: row, model) }
            else { model.errorMessage = "Er passen meer verrekeningen bij deze overboeking. Kies rechts welke het is." }
            return
        }
        if let problem = problem(for: row) { model.errorMessage = problem; return }
        let draft = draft(for: row)
        let allocations = allocations(for: row, reviewed: true)
        // Alleen een regel bewaren als de gebruiker dat aanvinkte (6i); anders telt hoogstens het gebruik.
        let learnable = !draft.isSplit && row.match == nil
        let remember: Rule? = learnable && rememberRule.contains(row.id)
            ? ruleProposal(for: row, model).flatMap { $0.offersChoice ? shownRule(for: row, $0) : nil } : nil
        let correction = correction(for: row)
        var learned: LearnResult?
        let ok = model.perform {
            try model.db.write { db in
                _ = try BookingService.book(db, bankTransactionId: row.id, allocations: allocations)
                if learnable { learned = try RuleEngine.afterBooking(correction, remember: remember, db) }
            }
        }
        guard ok else { return }
        var text = "Geboekt: \(allocations.count == 1 ? allocations[0].label : "\(row.cleanLabel) in \(allocations.count) regels")"
        let changedRules = learned.flatMap { $0.outcome == .unchanged ? nil : $0 }
        if let changedRules { text += " · \(changedRules.message)" }
        if allocations.contains(where: \.reimburse) { text += " · \(settlementBalanceText(model))" }
        announce(model, text, unbook: [row.id], learned: changedRules)
        finish(model, handled: [row.id])
    }

    /// Boekt alle zekere transacties in één keer. Ze blijven "na te kijken" in Transacties.
    func bookAllCertain(_ model: AppModel) {
        book(certainRows, model, reviewedIfEdited: false)
    }

    /// Boekt de selectie met het voorstel per transactie.
    func bookSelection(_ model: AppModel) {
        let chosen = selectedRows
        let blocked = chosen.filter { problem(for: $0) != nil }
        guard blocked.isEmpty else {
            model.errorMessage = blocked.count == 1
                ? "\"\(blocked[0].cleanLabel)\" is gesplitst maar de regels tellen niet op tot het bankbedrag."
                : "\(blocked.count) gesplitste transacties tellen niet op tot het bankbedrag."
            return
        }
        book(chosen, model, reviewedIfEdited: true)
    }

    private func book(_ chosen: [ReviewRow], _ model: AppModel, reviewedIfEdited: Bool) {
        guard !chosen.isEmpty else { return }
        guard !chosen.contains(where: { $0.settlement != nil }) else {
            model.errorMessage = "In de selectie zit de overboeking van een verrekening met spaar. Die boek je niet opnieuw: hang hem apart aan."
            return
        }
        let requests = chosen.map { row in
            BookingRequest(bankTransactionId: row.id,
                           allocations: allocations(for: row, reviewed: reviewedIfEdited && isEdited(row)))
        }
        let ruleIds = requests.compactMap { $0.allocations.count == 1 ? $0.allocations[0].ruleId : nil }
        let ok = model.perform {
            try model.db.write { db in
                _ = try BookingService.bookAll(db, requests)
                for ruleId in ruleIds { try RuleEngine.recordUse(ruleId: ruleId, db) }
            }
        }
        guard ok else { return }
        let ids = Set(chosen.map(\.id))
        var text = ids.count == 1 ? "1 transactie geboekt" : "\(ids.count) transacties geboekt"
        if !reviewedIfEdited { text += " · nog na te kijken in Transacties" }
        if requests.contains(where: { $0.allocations.contains(where: \.reimburse) }) { text += " · \(settlementBalanceText(model))" }
        announce(model, text, unbook: Array(ids), learned: nil)
        finish(model, handled: ids)
    }

    /// "Te verrekenen met spaar: nu € 310,00 van spaar naar betaal", na een boeking met Verrekenen met spaar.
    private func settlementBalanceText(_ model: AppModel) -> String {
        model.read("Te verrekenen met spaar") { db in
            let open = try Insight.openReimbursements(db)
            switch open.direction {
            case .fromSavings: return "Te verrekenen met spaar: nu \(open.transferAmount.formatted()) van spaar naar betaal"
            case .toSavings: return "Te verrekenen met spaar: nu \(open.transferAmount.formatted()) van betaal naar spaar"
            case .none: return "Te verrekenen met spaar: per saldo niets over te maken"
            }
        }
    }

    /// De bankregel van een verrekening: zo nodig eerst afvinken (dan wordt de verrekening geboekt op de dag van
    /// de bankregel), daarna de bankregel aan die boekingen hangen. Er komt geen boeking bij.
    func attachSettlement(_ transfer: SavingsTransfer, to row: ReviewRow, _ model: AppModel) {
        guard let id = transfer.id else { return }
        let ok = model.perform {
            try model.db.write { db in
                if !transfer.done { _ = try SavingsTransferService.markDone(db, savingsTransferId: id, on: row.tx.day) }
                try SavingsTransferService.attach(db, savingsTransferId: id, bankTransactionId: row.id)
            }
        }
        guard ok else { return }
        let text = transfer.done ? "Bankregel aan de verrekening gehangen" : "Verrekening afgevinkt en bankregel aangehangen"
        model.toast = text
        notice = ReviewNotice(text: text)
        finish(model, handled: [row.id])
    }

    /// "Verrekening van 12 jun (€ 310,00)".
    func title(of transfer: SavingsTransfer) -> String {
        "Verrekening van \(transfer.day.short()) (\(transfer.amount.magnitude.formatted()))"
    }

    func skipSelection(_ model: AppModel) {
        let ids = selection
        guard !ids.isEmpty else { return }
        let ok = model.perform {
            try model.db.write { db in
                for id in ids { try BookingService.skip(db, bankTransactionId: id) }
            }
        }
        guard ok else { return }
        let text = ids.count == 1 ? "1 transactie overgeslagen" : "\(ids.count) transacties overgeslagen"
        model.toast = text
        notice = ReviewNotice(text: text) { [weak self] model in
            let done = model.perform("Terug in de wachtrij") {
                try model.db.write { db in
                    for id in ids { try BookingService.unskip(db, bankTransactionId: id) }
                }
            }
            if done { self?.selection = ids; self?.cursor = ids.first; self?.load(model) }
        }
        finish(model, handled: ids)
    }

    private func announce(_ model: AppModel, _ text: String, unbook ids: [Int64], learned: LearnResult?) {
        model.toast = text
        notice = ReviewNotice(text: text) { [weak self] model in
            let done = model.perform("Ongedaan gemaakt") {
                try model.db.write { db in
                    for id in ids { try BookingService.unbook(db, bankTransactionId: id) }
                    if let learned { try RuleEngine.undoLearning(learned, db) }
                }
            }
            if done { self?.selection = Set(ids); self?.cursor = ids.first; self?.load(model) }
        }
    }

    func undo(_ model: AppModel) {
        guard let undo = notice?.undo else { return }
        notice = nil
        undo(model)
    }

    // MARK: Overboekingen tussen eigen rekeningen

    /// Koppelt de gevonden paren. Een kant die nog niet geboekt is, krijgt eerst het voorstel van de regels
    /// (of de verdeling van een vaste storting met exact bedrag), zodat de post of pot niet verloren gaat.
    func linkPairs(_ model: AppModel, only pair: TransferPair? = nil) {
        let chosen = pair.map { [$0] } ?? pairs
        guard !chosen.isEmpty else { return }
        let kinds = Dictionary(uniqueKeysWithValues: accounts.compactMap { a in a.id.map { ($0, a.kind) } })
        let ok = model.perform {
            try model.db.write { db in
                for pair in chosen {
                    for side in [pair.from, pair.to] where side.status == .nieuw {
                        guard let id = side.id, let kind = kinds[side.accountId] else { continue }
                        if let match = try DistributionService.recognize(db, bankTransaction: side),
                           match.distribution != nil, match.exactAmount, !match.allocations.isEmpty {
                            _ = try BookingService.book(db, bankTransactionId: id, allocations: match.allocations)
                            continue
                        }
                        let s = try RuleEngine.suggest(for: side, db)
                        guard let ruleId = s.ruleId, !s.amountDiffers, s.warnings.isEmpty else { continue }
                        let reimburse = kind == .betaal && s.reimburse
                        let allocation = Allocation(
                            amount: side.amount, label: s.label,
                            budgetItemId: kind == .betaal ? s.budgetItemId : nil,
                            potId: kind == .spaar || reimburse ? s.potId : nil,
                            reimburse: reimburse, tagIds: s.tagIds, ruleId: ruleId, confidence: s.confidence)
                        _ = try BookingService.book(db, bankTransactionId: id, allocations: [allocation])
                        try RuleEngine.recordUse(ruleId: ruleId, db)
                    }
                    try TransferService.linkTransfer(db, fromBankTransactionId: pair.from.id!,
                                                     toBankTransactionId: pair.to.id!)
                }
            }
        }
        guard ok else { return }
        model.toast = chosen.count == 1 ? "Overboeking gekoppeld" : "\(chosen.count) overboekingen gekoppeld"
        notice = nil
        let ids = Set(chosen.flatMap { [$0.from.id, $0.to.id].compactMap { $0 } })
        finish(model, handled: ids.intersection(rows.map(\.id)))
    }

    // MARK: Importeren

    /// Leest een bestand en toont het voorbeeld. Schrijft nog niets.
    /// Een zip van de bank geeft één blok per rekening; bij een los bestand bepaalt het IBAN de rekening.
    func open(_ url: URL, _ model: AppModel) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let fileName = url.lastPathComponent
        let data: Data
        do { data = try Data(contentsOf: url) } catch {
            model.errorMessage = "Het bestand \"\(fileName)\" kan niet worden geopend."
            return
        }
        do {
            pendingImport = try makePending(data: data, fileName: fileName, model)
        } catch ImportError.noProfile {
            if let file = try? CSVFile(data: data) {
                rawFile = ReviewRawFile(fileName: fileName, rows: file.rawRows(limit: 12), columnCount: file.columnCount)
            } else {
                model.errorMessage = ImportError.noProfile.localizedDescription
            }
        } catch {
            model.errorMessage = error.localizedDescription
        }
    }

    /// Leest het bestand. Bij de eerste bankimport van een rekening (`needsSeam`) zoekt HFImport op saldo
    /// waar het bestand aansluit op de administratie (beginsaldo of Excel-historie), met een dag als terugval.
    private func makePending(data: Data, fileName: String, _ model: AppModel) throws -> ReviewPendingImport? {
        let importer = BankImporter(database: model.db)
        if fileName.lowercased().hasSuffix(".zip") || data.starts(with: [0x50, 0x4B, 0x03, 0x04]) {
            var cutovers: [Int64: Day] = [:]
            var balances: [Int64: Money] = [:]
            for id in try model.db.read({ try Int64.fetchAll($0, sql: "SELECT id FROM account") })
            where try importer.needsSeam(accountId: id) {
                cutovers[id] = try importer.defaultSkipThrough(accountId: id)
                balances[id] = try importer.resumeBalance(accountId: id)
            }
            let archive = try importer.previewArchive(data: data, fileName: fileName, skipThroughByAccount: cutovers,
                                                      resumeFromBalance: balances)
            let parts = try archive.importableItems.compactMap { item in
                try item.preview.map {
                    ReviewImportPart(fileName: item.fileName, accountName: item.account?.name ?? "Onbekende rekening",
                                     preview: $0, hasHistory: try importer.historyCutover(accountId: $0.accountId) != nil,
                                     seamCenter: Self.seamCenter($0), autoSkipped: Self.autoSkipped($0))
                }
            }
            return ReviewPendingImport(fileName: fileName, archive: archive, parts: parts, skipped: archive.skippedItems)
        }
        let match = try? importer.matchAccount(data: data, fileName: fileName)
        guard let target = match?.account?.id ?? accountId else { return nil }
        let name = match?.account?.name ?? accountName(target)
        let needsSeam = try importer.needsSeam(accountId: target)
        let preview = try importer.preview(
            data: data, fileName: fileName, accountId: target,
            skipThrough: needsSeam ? try importer.defaultSkipThrough(accountId: target) : nil,
            resumeFromBalance: needsSeam ? try importer.resumeBalance(accountId: target) : nil)
        return ReviewPendingImport(
            fileName: fileName,
            parts: [ReviewImportPart(fileName: fileName, accountName: name, preview: preview,
                                     hasHistory: try importer.historyCutover(accountId: target) != nil,
                                     seamCenter: Self.seamCenter(preview), autoSkipped: Self.autoSkipped(preview))],
            recognition: match?.account != nil
                ? "Herkend als: \(name)"
                : "\(match?.message ?? "De rekening is niet herkend.") Het bestand gaat naar de gekozen rekening: \(name).",
            recognized: match?.account != nil)
    }

    private static func autoSkipped(_ preview: ImportPreview) -> Set<Int> {
        Set(preview.rows.filter(\.isBeforeCutover).map(\.lineNumber))
    }

    private static func seamCenter(_ preview: ImportPreview) -> Int? {
        guard preview.seam != nil else { return nil }
        let rows = preview.rowsChronological
        return rows.firstIndex { !$0.isBeforeCutover } ?? rows.count
    }

    /// De gebruiker zet zelf een regel aan of uit bij de aansluiting op de Excel-historie.
    func setIncluded(_ included: Bool, line: Int, in partId: String) {
        guard var pending = pendingImport, let index = pending.parts.firstIndex(where: { $0.id == partId }) else { return }
        let changed = pending.parts[index].preview.overriding(includeLineNumbers: included ? [line] : [],
                                                              excludeLineNumbers: included ? [] : [line])
        pending.parts[index].preview = changed
        if let item = pending.archive?.items.firstIndex(where: { $0.fileName == partId }) {
            pending.archive?.items[item].preview = changed
        }
        pendingImport = pending
    }

    /// Wat er bij de huidige keuze nog niet klopt: eindsaldo van het bestand min (saldo van de administratie
    /// plus de regels die meegaan). Moet € 0,00 zijn. nil als het bestand geen saldo levert.
    func seamDifference(_ preview: ImportPreview) -> Money? {
        guard let seam = preview.seam, let sought = seam.soughtBalance, let closing = seam.fileClosingBalance else { return nil }
        return closing - sought - preview.rows.filter { !$0.isBeforeCutover }.map(\.amount).sum()
    }

    func openSample(_ model: AppModel) {
        model.perform {
            let url = try DemoSupport.writeSampleArchive(today: model.today)
            open(url, model)
        }
    }

    func commit(_ pending: ReviewPendingImport, skipFaultyRows: Bool, _ model: AppModel) {
        // Per rekening: naam, id en wat er geïmporteerd is.
        var results: [(name: String, accountId: Int64, result: ImportResult)] = []
        let ok = model.perform {
            let importer = BankImporter(database: model.db)
            if let archive = pending.archive {
                results = try importer.commitArchive(archive, skipFaultyRows: skipFaultyRows).compactMap { r in
                    r.account.id.map { (r.account.name, $0, r.result) }
                }
            } else if let part = pending.parts.first {
                let result = try importer.commit(part.preview, skipFaultyRows: skipFaultyRows)
                results = [(part.accountName, part.preview.accountId, result)]
            }
        }
        guard ok, !results.isEmpty else { return }
        if results.count == 1, let only = results.first {
            let n = only.result.transactions.count
            var parts = [n == 1 ? "1 transactie geïmporteerd" : "\(n) transacties geïmporteerd"]
            let known = only.result.duplicateCount + only.result.cutoverSkippedCount
            if known > 0 { parts.append("\(known) al bekend") }
            if only.result.skippedErrorCount > 0 { parts.append("\(only.result.skippedErrorCount) fout overgeslagen") }
            model.toast = parts.joined(separator: " · ")
        } else {
            model.toast = "Geïmporteerd · " + results.map { r in
                let known = r.result.duplicateCount + r.result.cutoverSkippedCount
                return "\(r.name): \(r.result.transactions.count) nieuw" + (known > 0 ? ", \(known) al bekend" : "")
            }.joined(separator: " · ")
        }
        pendingImport = nil
        notice = nil
        // Blijf op de rekening met de meeste nieuwe transacties.
        if let busiest = results.max(by: { $0.result.transactions.count < $1.result.transactions.count }) {
            accountId = busiest.accountId
        }
        selection = []
        load(model)
    }
}
