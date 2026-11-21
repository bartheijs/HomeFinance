import SwiftUI
import GRDB
import HFCore
import HFInsight
import HFBudget
import HFRules

// MARK: - Feed

/// Een regel in de feed is een boeking of een banktransactie die nog geboekt moet worden.
enum TransactionsItemID: Hashable {
    case entry(Int64)
    case bank(Int64)
}

/// Een nieuwe banktransactie met het voorstel van de regels.
struct TransactionsPending: Equatable {
    let transaction: BankTransaction
    let suggestion: Suggestion
    /// De vaste storting waar deze transactie bij past, als die herkend is (gaat vóór de regels).
    var match: DistributionMatch? = nil
    /// De verrekening met spaar waarvan dit de bankregel is (gaat vóór alles). Zo'n transactie wordt niet
    /// geboekt maar aan de verrekening gehangen.
    var transferMatch: SavingsTransferMatch? = nil

    var id: Int64 { transaction.id ?? 0 }
    /// Herkende vaste storting waarvan de regels precies het bankbedrag zijn: zo te boeken.
    var bookableMatch: DistributionMatch? {
        guard let match, match.distribution != nil, !match.allocations.isEmpty,
              match.allocations.map(\.amount).sum() == transaction.amount else { return nil }
        return match
    }
    /// Het voorstel is bruikbaar zonder verder te kiezen.
    var hasSuggestion: Bool {
        if transferMatch != nil { return false }
        return match == nil ? suggestion.confidence != .geen && suggestion.warnings.isEmpty : bookableMatch != nil
    }
    var isCertain: Bool {
        if transferMatch != nil { return false }
        return match == nil ? suggestion.confidence == .hoog && suggestion.warnings.isEmpty : bookableMatch != nil
    }
    /// De regels om mee te boeken volgens het voorstel (nagekeken, want de gebruiker klikt zelf).
    func suggestedAllocations(kind: AccountKind) -> [Allocation] {
        if let bookableMatch {
            return bookableMatch.allocations.map { var a = $0; a.reviewed = true; return a }
        }
        return [TransactionsDraft(pending: self, kind: kind).allocation(
            amount: transaction.amount, kind: kind, ruleId: suggestion.ruleId, confidence: suggestion.confidence)]
    }
}

struct TransactionsFeedItem: Identifiable, Equatable {
    enum Content: Equatable {
        case entry(EntryRow)
        case pending(TransactionsPending)
    }
    let content: Content

    var id: TransactionsItemID {
        switch content {
        case .entry(let row): .entry(row.id)
        case .pending(let p): .bank(p.id)
        }
    }
    var entry: EntryRow? { if case .entry(let row) = content { row } else { nil } }
    var pending: TransactionsPending? { if case .pending(let p) = content { p } else { nil } }

    var day: Day { entry?.day ?? pending?.transaction.day ?? Day.today() }
    var amount: Money { entry?.amount ?? pending?.transaction.amount ?? .zero }
    var title: String {
        if entry?.isSettlementBooking == true || pending?.transferMatch != nil { return "Verrekening spaar" }
        let text = entry?.label ?? pending?.match?.distribution?.name ?? pending?.suggestion.label ?? ""
        return text.isEmpty ? "Zonder omschrijving" : text
    }
    var bankTransactionId: Int64? { entry?.bankTransactionId ?? pending?.id }
}

struct TransactionsDayGroup: Identifiable, Equatable {
    let day: Day
    var items: [TransactionsFeedItem]
    var id: Day { day }
}

// MARK: - Filters

enum TransactionsStatusFilter: String, CaseIterable, Identifiable {
    case all, newOnly, unreviewed
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: "Alles"
        case .newOnly: "Alleen nieuw"
        case .unreviewed: "Na te kijken"
        }
    }
}

/// Wat de gebruiker zoekt en filtert. De rekening staat los hiervan (de kaarten bovenaan).
struct TransactionsCriteria: Equatable {
    var text = ""
    var month: Int?
    var itemId: Int64?
    var potId: Int64?
    var tagId: Int64?
    var status = TransactionsStatusFilter.all
    var diversOnly = false
    var reimburseOnly = false
    /// Alleen boekingen die als tijdelijk geleend van spaar gemarkeerd zijn.
    var loanOnly = false

    var trimmedText: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Aantal actieve filters achter de knop Filters.
    var filterCount: Int {
        [month != nil, itemId != nil, potId != nil, tagId != nil, status != .all, diversOnly, reimburseOnly, loanOnly]
            .filter { $0 }.count
    }
    var hasFilters: Bool { filterCount > 0 || !trimmedText.isEmpty }
    var hasSubject: Bool { itemId != nil || potId != nil || tagId != nil }

    mutating func clear() { self = TransactionsCriteria() }

    func entryFilter(accountId: Int64, year: Int, limit: Int?, offset: Int = 0) -> EntryFilter {
        EntryFilter(accountId: accountId, year: month == nil ? nil : year, month: month,
                    text: trimmedText.isEmpty ? nil : trimmedText,
                    budgetItemId: itemId, potId: potId, tagId: tagId,
                    diversOnly: diversOnly, unreviewedOnly: status == .unreviewed, reimburseOnly: reimburseOnly,
                    sort: .dayDescending, limit: limit, offset: offset)
    }

    /// Past een nieuwe transactie bij de filters? (Nieuwe transacties hebben alleen een voorstel.)
    func matches(_ p: TransactionsPending, year: Int) -> Bool {
        let t = p.transaction
        if loanOnly { return false }
        if let month, t.day.year != year || t.day.month != month { return false }
        if let itemId, p.suggestion.budgetItemId != itemId { return false }
        if let potId, p.suggestion.potId != potId { return false }
        if let tagId, !p.suggestion.tagIds.contains(tagId) { return false }
        if diversOnly, p.suggestion.budgetItemId != nil { return false }
        if reimburseOnly, !p.suggestion.reimburse { return false }
        let needle = trimmedText.lowercased()
        if !needle.isEmpty {
            let haystack = [t.counterpartyName, t.descriptionText, p.suggestion.label].joined(separator: "\n").lowercased()
            if !haystack.contains(needle) { return false }
        }
        return true
    }
}

// MARK: - Keuzelijsten

struct TransactionsLookups: Equatable {
    var accounts: [AccountOverview] = []
    /// Vaste posten waarop je kunt boeken (zonder RES-regels), per jaar.
    var itemsByYear: [Int: [BudgetItem]] = [:]
    var closedYears: Set<Int> = []
    var pots: [Pot] = []
    var tags: [HFCore.Tag] = []
    /// Verrekeningen met spaar die al zijn afgevinkt (en dus geboekt).
    var doneTransferIds: Set<Int64> = []

    func account(_ id: Int64?) -> AccountOverview? { accounts.first { $0.id == id } }
    func items(year: Int) -> [BudgetItem] { itemsByYear[year] ?? [] }
    func item(_ id: Int64?) -> BudgetItem? {
        guard let id else { return nil }
        for items in itemsByYear.values { if let found = items.first(where: { $0.id == id }) { return found } }
        return nil
    }
    func item(label: String, year: Int) -> BudgetItem? {
        items(year: year).first { $0.label.caseInsensitiveCompare(label) == .orderedSame }
    }
    func pot(_ id: Int64?) -> Pot? { pots.first { $0.id == id } }
    func tag(_ id: Int64?) -> HFCore.Tag? { tags.first { $0.id == id } }

    /// Potten van één spaarrekening (nil = alle); een gearchiveerde pot alleen als hij al gekozen is.
    func pots(accountId: Int64?, keeping current: Int64? = nil) -> [Pot] {
        pots.filter { (accountId == nil || $0.accountId == accountId) && (!$0.archived || $0.id == current) }
    }

    static func fetch(_ db: Database, today: Day) throws -> TransactionsLookups {
        var l = TransactionsLookups()
        l.accounts = try Insight.accountOverview(db, today: today).filter { !$0.archived }
        let years = try BudgetYear.fetchAll(db)
        l.closedYears = Set(years.filter(\.closed).map(\.year))
        var yearById: [Int64: Int] = [:]
        for y in years { if let id = y.id { yearById[id] = y.year } }
        let items = try BudgetItem.filter(Column("direction") != Direction.RES.rawValue)
            .order(Column("sortOrder")).fetchAll(db)
        // Per richting op alfabet, voor alle post-kiezers op dit scherm (Insight.itemPickerOrder, 6n).
        for item in Insight.itemPickerOrder(items) {
            if let year = yearById[item.yearId] { l.itemsByYear[year, default: []].append(item) }
        }
        // Per soort op alfabet, voor alle pot-kiezers op dit scherm (Insight.pickerOrder, 6c).
        l.pots = Insight.pickerOrder(try Pot.order(Column("accountId"), Column("sortOrder"), Column("name")).fetchAll(db))
        l.tags = try HFCore.Tag.order(Column("sortOrder"), Column("name")).fetchAll(db)
        l.doneTransferIds = Set(try SavingsTransfer.filter(Column("done") == true).fetchAll(db).compactMap(\.id))
        return l
    }
}

// MARK: - Concept

/// De keuzes bij één transactie: voor een nieuwe transactie vóór het boeken, voor een boeking de tekstvelden.
struct TransactionsDraft: Equatable {
    var label = ""
    var day = Day.today()
    var isIncome = false
    /// Bedrag zonder teken; nil zolang de invoer niet klopt.
    var magnitude: Money? = nil
    var itemId: Int64?
    /// Spaarrekening: de pot. Betaalrekening: de pot waarmee verrekend wordt (uitgave: eruit, bijschrijving: erin).
    var potId: Int64?
    var reimburse = false
    var tagIds: Set<Int64> = []
    var note = ""
    /// Tijdelijk geleend van spaar (alleen betaalrekening).
    var temporaryLoan = false
    /// "yyyy-MM": de maand waarin de boeking meetelt; nil = de maand van de datum.
    var period: String?

    init() {}

    /// Neemt een bestaande omschrijving over, met de post en tags die er meestal bij horen
    /// als die hier nog niet gekozen zijn.
    mutating func adopt(_ suggestion: LabelSuggestion, lookups: TransactionsLookups, kind: AccountKind) {
        label = suggestion.label
        if kind == .betaal, itemId == nil, let itemLabel = suggestion.itemLabel,
           let item = lookups.item(label: itemLabel, year: day.year) {
            itemId = item.id
        }
        // Tags alleen op de betaalrekening.
        if kind == .betaal, tagIds.isEmpty { tagIds = Set(suggestion.tags.map(\.id)) }
    }

    init(row: EntryRow) {
        label = row.label; day = row.day
        isIncome = !row.amount.isNegative; magnitude = row.amount.magnitude
        itemId = row.budgetItemId; potId = row.potId; reimburse = row.reimburse
        tagIds = Set(row.tags.map(\.id)); note = row.note
        temporaryLoan = row.temporaryLoan
        period = row.period
    }

    init(pending p: TransactionsPending, kind: AccountKind) {
        let s = p.suggestion, t = p.transaction
        label = s.label; day = t.day
        isIncome = !t.amount.isNegative; magnitude = t.amount.magnitude
        tagIds = kind == .betaal ? Set(s.tagIds) : []   // tags alleen op de betaalrekening
        switch kind {
        case .betaal:
            itemId = s.budgetItemId
            reimburse = s.reimburse && !t.amount.isZero
            potId = reimburse ? s.potId : nil
        case .spaar:
            potId = s.potId
        }
    }

    /// Bedrag met teken: uitgaven negatief.
    var amount: Money? {
        guard let m = magnitude?.magnitude else { return nil }
        return isIncome ? m : -m
    }

    var isValid: Bool {
        guard let amount else { return false }
        return !amount.isZero && !label.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// De boekingsregel voor een banktransactie met deze keuzes.
    func allocation(amount: Money, kind: AccountKind, ruleId: Int64? = nil, confidence: Confidence? = nil) -> Allocation {
        let wantsReimburse = kind == .betaal && reimburse && !amount.isZero
        return Allocation(amount: amount, label: label.trimmingCharacters(in: .whitespaces),
                          budgetItemId: kind == .betaal ? itemId : nil,
                          potId: kind == .spaar ? potId : (wantsReimburse ? potId : nil),
                          reimburse: wantsReimburse, tagIds: tagIds.sorted(), note: note,
                          ruleId: ruleId, confidence: confidence, reviewed: true,
                          temporaryLoan: kind == .betaal && temporaryLoan, period: period)
    }
}

/// Extra gegevens bij de gekozen boeking: de andere delen van een splitsing en de tegenboeking.
struct TransactionsExtra: Equatable {
    var parts: [Entry] = []
    var counter: Entry?
    var counterAccountName: String?
    var savingsTransfer: SavingsTransfer?
    /// Nog over te boeken met spaar, of nog terug te krijgen bij een voorgeschoten tag (HFInsight).
    var progress: EntryProgress?

    static func fetch(_ db: Database, row: EntryRow, today: Day) throws -> TransactionsExtra {
        var d = TransactionsExtra()
        d.progress = try Insight.entryProgress(db, entryId: row.id, today: today)
        if let bankId = row.bankTransactionId {
            let parts = try Entry.filter(Column("bankTransactionId") == bankId).order(Column("id")).fetchAll(db)
            if parts.count > 1 { d.parts = parts }
        }
        if let counterId = row.counterEntryId, let counter = try Entry.fetchOne(db, key: counterId) {
            d.counter = counter
            d.counterAccountName = try Account.fetchOne(db, key: counter.accountId)?.name
        }
        if let transferId = row.savingsTransferId {
            d.savingsTransfer = try SavingsTransfer.fetchOne(db, key: transferId)
        }
        return d
    }
}

/// Eén regel in de sheet Splitsen.
struct TransactionsSplitPart: Identifiable, Equatable {
    let id = UUID()
    var draft = TransactionsDraft()
}

/// De banktransactie die gesplitst wordt, met de regels om mee te beginnen.
struct TransactionsSplitTarget: Identifiable {
    let transaction: BankTransaction
    let kind: AccountKind
    var parts: [TransactionsSplitPart]
    var id: Int64 { transaction.id ?? 0 }
}

/// Waarvoor de sheet Nieuwe tag opent (vanuit een menu): de tag komt op deze regels.
struct TransactionsNewTagTarget: Identifiable {
    let ids: [TransactionsItemID]
    let id = UUID()
}

/// Waarvoor de sheet Verrekenen opent: een tag, optioneel met een bijschrijving als terugstorting.
struct TransactionsSettleTarget: Identifiable {
    let tagId: Int64
    let tagName: String
    var deposit: EntryRow?
    var id: Int64 { tagId }
}

struct TransactionsSummary: Equatable {
    var count: Int
    var sum: Money
    var average: Money?
    var months: Int?
}

// MARK: - Store

/// Toestand van het startscherm: de gekozen rekening, de feed, de selectie en het concept in het detailpaneel.
@MainActor @Observable
final class TransactionsStore {
    static let pageSize = 100

    var accountId: Int64?
    var criteria = TransactionsCriteria()
    private(set) var lookups = TransactionsLookups()
    private(set) var groups: [TransactionsDayGroup] = []
    private(set) var items: [TransactionsFeedItem] = []
    private(set) var pendingAll: [TransactionsPending] = []
    private(set) var totalEntryCount = 0
    private(set) var hasLoaded = false
    /// Samenvatting bij een filter op tag, post of pot (over het begrotingsjaar).
    private(set) var summary: TransactionsSummary?
    /// Wat er nu tijdelijk van spaar geleend is en nog niet is teruggeboekt.
    private(set) var loanOutstanding = Money.zero
    /// Som van alle gevonden boekingen (bij zoeken of filteren).
    private(set) var foundSum = Money.zero
    /// Bestaande omschrijvingen, om aan te vullen tijdens het typen.
    private(set) var labels: [LabelSuggestion] = []
    /// Tags die verrekend worden en waar nog iets van openstaat.
    private(set) var settlements: [TagSettlementSummary] = []
    var settleTarget: TransactionsSettleTarget?
    var newTagTarget: TransactionsNewTagTarget?
    /// Gemarkeerde boekingen die nog met spaar verrekend moeten worden, gesaldeerd.
    private(set) var openReimbursements: HFInsight.OpenReimbursements?
    /// Welke bankbestanden de gebruiker moet downloaden om bij te werken (6a).
    private(set) var downloadAdvice: DownloadAdvice?

    var selection = Set<TransactionsItemID>()
    var showDetail = false
    var showMore = false
    var showTagPicker = false
    var splitTarget: TransactionsSplitTarget?
    var noteTarget: EntryRow?

    // Detailpaneel
    private(set) var extra = TransactionsExtra()
    var draft = TransactionsDraft()
    private(set) var original = TransactionsDraft()
    private(set) var draftFor: TransactionsItemID?
    private(set) var draftVersion = 0
    /// Vaste storting bij de gekozen nieuwe transactie (nil = zelf kiezen), en waar een verschil heen gaat.
    var matchChoice: DistributionMatch?
    var differencePotId: Int64?
    /// Een open verwachting die bij de gekozen boeking past.
    private(set) var forecast: ForecastItem?

    /// Laatst gekozen posten (op label, want posten bestaan per jaar) en potten, voor bovenaan de keuzelijst.
    private(set) var recentItemLabels: [String] = []
    private(set) var recentPotIds: [Int64] = []

    @ObservationIgnored private var entries: [EntryRow] = []
    @ObservationIgnored private var loadedKey: String?
    @ObservationIgnored private var reselectBankId: Int64?

    var account: AccountOverview? { lookups.account(accountId) }
    var kind: AccountKind { account?.kind ?? .betaal }
    var hasMore: Bool { criteria.status != .newOnly && !criteria.loanOnly && entries.count < totalEntryCount }
    var selectedItems: [TransactionsFeedItem] { items.filter { selection.contains($0.id) } }
    var single: TransactionsFeedItem? { selection.count == 1 ? items.first { selection.contains($0.id) } : nil }
    var certainPending: [TransactionsPending] { pendingAll.filter(\.isCertain) }
    var isTextDirty: Bool { single?.entry != nil && draft != original }

    func isLocked(_ item: TransactionsFeedItem) -> Bool { lookups.closedYears.contains(item.day.year) }

    // MARK: Laden

    func reload(_ model: AppModel) {
        lookups = model.read(lookups) { try TransactionsLookups.fetch($0, today: model.today) }
        SelfTest.potPickerLoaded(.transactions, kinds: lookups.pots.map(\.kind), names: lookups.pots.map(\.name))
        if lookups.account(accountId) == nil {
            accountId = (lookups.accounts.first { $0.kind == .betaal } ?? lookups.accounts.first)?.id
        }
        guard let accountId else {
            entries = []; pendingAll = []; totalEntryCount = 0; rebuild(model); hasLoaded = true
            return
        }
        let key = "\(accountId)|\(criteria)|\(model.year)"
        let limit = key == loadedKey ? max(Self.pageSize, entries.count) : Self.pageSize
        loadedKey = key

        attachSettlements(model, accountId: accountId)
        pendingAll = model.read([]) { db in
            // Volgorde van herkennen: verrekeningen met spaar, vaste stortingen, regels.
            let transfers = try SavingsTransferService.recognizeAll(db, accountId: accountId)
            let suggestions = try RuleEngine.suggestAll(db, accountId: accountId)
            // Vaste stortingen worden vóór de regels herkend.
            let matches = try DistributionService.recognizeAll(db, accountId: accountId)
            var list: [TransactionsPending] = []
            for item in try Insight.reviewQueue(db, accountId: accountId) {
                guard let id = item.transaction.id else { continue }
                let suggestion = try suggestions[id] ?? RuleEngine.suggest(for: item.transaction, db)
                let transfer = transfers[id]
                list.append(TransactionsPending(transaction: item.transaction, suggestion: suggestion,
                                                match: transfer == nil ? matches[id].flatMap { $0.looksSeparate ? nil : $0 } : nil,
                                                transferMatch: transfer))
            }
            return list
        }
        loanOutstanding = model.read(Money.zero) { try Insight.temporaryLoanOutstanding($0, on: model.today) }
        openReimbursements = model.read(nil as HFInsight.OpenReimbursements?) { try Insight.openReimbursements($0) }
        downloadAdvice = model.read(nil as DownloadAdvice?) { try Insight.downloadAdvice($0, today: model.today) }
        let kind = kind
        labels = model.read(labels) { try Insight.allLabels($0, accountKind: kind) }
        settlements = model.read([]) {
            try Insight.settlementOverview($0, today: model.today).filter { $0.openCount > 0 && $0.outstanding > .zero }
        }
        if criteria.loanOnly {
            // EntryFilter kent dit filter niet; HFInsight levert de gemarkeerde boekingen in één keer.
            entries = model.read([]) { try Insight.temporaryLoanEntries($0).filter { $0.accountId == accountId } }
            totalEntryCount = entries.count
            foundSum = entries.map(\.amount).sum()
        } else if criteria.status == .newOnly {
            entries = []; totalEntryCount = 0; foundSum = .zero
        } else {
            let filter = criteria.entryFilter(accountId: accountId, year: model.year, limit: limit)
            if let result = model.read(nil as EntrySearchResult?, { try Insight.searchEntries($0, filter: filter) }) {
                entries = result.rows
                totalEntryCount = result.totalCount
                foundSum = result.totalSum
            }
        }
        loadSummary(model, accountId: accountId)
        rebuild(model)
        hasLoaded = true
    }

    /// Hangt bankregels van al afgevinkte verrekeningen met spaar automatisch aan (alleen eenduidige).
    /// Eerst alleen lezen; er wordt pas geschreven als er echt iets aan te hangen is.
    private func attachSettlements(_ model: AppModel, accountId: Int64) {
        let needed = model.read(false) { db in
            try SavingsTransferService.recognizeAll(db, accountId: accountId).values
                .contains { $0.transfer != nil && !$0.needsMarkDone }
        }
        guard needed else { return }
        var count = 0
        let ok = model.perform { try model.db.write { count = try SavingsTransferService.attachAll($0, accountId: accountId) } }
        if ok, count > 0 {
            model.toast = count == 1 ? "1 bankregel aan een verrekening met spaar gehangen"
                                     : "\(count) bankregels aan verrekeningen met spaar gehangen"
        }
    }

    func loadMore(_ model: AppModel) {
        guard hasMore, let accountId else { return }
        let filter = criteria.entryFilter(accountId: accountId, year: model.year, limit: Self.pageSize, offset: entries.count)
        guard let result = model.read(nil as EntrySearchResult?, { try Insight.searchEntries($0, filter: filter) }) else { return }
        let known = Set(entries.map(\.id))
        entries.append(contentsOf: result.rows.filter { !known.contains($0.id) })
        totalEntryCount = result.totalCount
        rebuild(model)
    }

    /// Voegt boekingen en nieuwe transacties samen tot één feed, nieuwste boven, gegroepeerd per dag.
    private func rebuild(_ model: AppModel) {
        var pending = criteria.status == .unreviewed ? [] : pendingAll.filter { criteria.matches($0, year: model.year) }
        // Zolang niet alle boekingen geladen zijn, tonen we nieuwe transacties tot de oudste geladen dag.
        if hasMore, let oldest = entries.last?.day { pending = pending.filter { $0.transaction.day >= oldest } }

        var byDay: [Day: [TransactionsFeedItem]] = [:]
        for p in pending.sorted(by: { $0.id > $1.id }) {
            byDay[p.transaction.day, default: []].append(TransactionsFeedItem(content: .pending(p)))
        }
        for row in entries { byDay[row.day, default: []].append(TransactionsFeedItem(content: .entry(row))) }
        groups = byDay.keys.sorted(by: >).map { TransactionsDayGroup(day: $0, items: byDay[$0] ?? []) }
        items = groups.flatMap(\.items)

        // Selectie bijhouden: een zojuist geboekte transactie blijft gekozen (nu als boeking).
        if let bankId = reselectBankId {
            reselectBankId = nil
            if let booked = items.first(where: { $0.entry?.bankTransactionId == bankId }) { selection = [booked.id] }
        }
        let present = Set(items.map(\.id))
        if !selection.isSubset(of: present) { selection.formIntersection(present) }
        if selection.isEmpty { showDetail = false }
        syncDetail(model)
    }

    private func loadSummary(_ model: AppModel, accountId: Int64) {
        guard criteria.hasSubject, criteria.status != .newOnly, !criteria.loanOnly else { summary = nil; return }
        var filter = criteria.entryFilter(accountId: accountId, year: model.year, limit: 0)
        filter.year = model.year
        guard let result = model.read(nil as EntrySearchResult?, { try Insight.searchEntries($0, filter: filter) }) else {
            summary = nil; return
        }
        // Gemiddelde per maand: HFInsight levert dit alleen voor tags per jaar (`tagYear`); voor een post, pot
        // of combinatie delen we hier de som door de verstreken maanden van het begrotingsjaar.
        var months: Int?
        if criteria.month == nil {
            if model.year < model.today.year { months = 12 } else if model.year == model.today.year { months = model.today.month }
        }
        var average: Money?
        if let months, months > 0, result.totalCount > 0 { average = Money(cents: result.totalSum.cents / Int64(months)) }
        summary = TransactionsSummary(count: result.totalCount, sum: result.totalSum, average: average, months: months)
    }

    func selectAccount(_ id: Int64) {
        guard id != accountId else { return }
        accountId = id
        selection = []
        // Post en pot horen bij de soort rekening.
        criteria.itemId = nil; criteria.potId = nil; criteria.diversOnly = false; criteria.reimburseOnly = false
        criteria.loanOnly = false
    }

    // MARK: Detailpaneel

    func selectionChanged(_ model: AppModel) {
        saveTextIfNeeded(model)
        if !selection.isEmpty { showDetail = true }
        syncDetail(model)
    }

    private func syncDetail(_ model: AppModel) {
        let item = single
        if item?.id != draftFor {
            draftFor = item?.id
            resetDraft()
        } else if let row = item?.entry {
            // Keuzes (post, tags, verrekenen) zijn al bewaard; alleen getypte tekst blijft als concept staan.
            let fresh = TransactionsDraft(row: row)
            if draft == original {
                if fresh != original { draft = fresh; original = fresh; draftVersion += 1 }
            } else {
                var kept = fresh
                kept.label = draft.label; kept.note = draft.note
                kept.day = draft.day; kept.isIncome = draft.isIncome; kept.magnitude = draft.magnitude
                original = fresh
                draft = kept
            }
        }
        if let row = item?.entry {
            extra = model.read(TransactionsExtra()) { try TransactionsExtra.fetch($0, row: row, today: model.today) }
            forecast = row.accountKind == .spaar && row.potId != nil
                ? model.read(nil as ForecastItem?) { try ForecastService.suggestRealization($0, entryId: row.id).first }
                : nil
        } else {
            extra = TransactionsExtra()
            forecast = nil
        }
    }

    func resetDraft() {
        var fresh = TransactionsDraft()
        if let row = single?.entry { fresh = TransactionsDraft(row: row) }
        if let pending = single?.pending { fresh = TransactionsDraft(pending: pending, kind: kind) }
        draft = fresh
        original = fresh
        draftVersion += 1
        matchChoice = single?.pending?.match
        differencePotId = nil
    }

    func closeDetail() {
        selection = []
        showDetail = false
    }

    // MARK: Hulpjes voor acties

    private func entries(in ids: [TransactionsItemID]) -> [EntryRow] {
        items.filter { ids.contains($0.id) }.compactMap(\.entry)
    }
    private func pendings(in ids: [TransactionsItemID]) -> [TransactionsPending] {
        items.filter { ids.contains($0.id) }.compactMap(\.pending)
    }

    /// Voert een schrijfactie uit, ververst de feed meteen (zonder sprong) en toont de bevestiging.
    @discardableResult
    private func run(_ model: AppModel, _ message: () -> String, _ action: (Database) throws -> Void) -> Bool {
        let ok = model.perform { try model.db.write { try action($0) } }
        if ok {
            reload(model)
            model.toast = message()
            model.autoReconcile(accountIds: accountId.map { [$0] })
        }
        return ok
    }

    private func remember(itemLabel: String?) {
        guard let itemLabel else { return }
        recentItemLabels.removeAll { $0 == itemLabel }
        recentItemLabels.insert(itemLabel, at: 0)
        recentItemLabels = Array(recentItemLabels.prefix(3))
    }
    private func remember(potId: Int64?) {
        guard let potId else { return }
        recentPotIds.removeAll { $0 == potId }
        recentPotIds.insert(potId, at: 0)
        recentPotIds = Array(recentPotIds.prefix(3))
    }

    private func targetName(_ draft: TransactionsDraft) -> String {
        switch kind {
        case .betaal: lookups.item(draft.itemId)?.label ?? "Divers"
        case .spaar: lookups.pot(draft.potId)?.name ?? "geen pot"
        }
    }

    private func correction(_ transaction: BankTransaction, _ draft: TransactionsDraft, suggestedLabel: String?) -> Correction {
        Correction(bankTransaction: transaction,
                   itemLabel: kind == .betaal ? lookups.item(draft.itemId)?.label : nil,
                   potId: kind == .spaar || draft.reimburse ? draft.potId : nil,
                   entryLabel: draft.label == suggestedLabel ? nil : draft.label,
                   tagIds: draft.tagIds.sorted(), reimburse: kind == .betaal && draft.reimburse)
    }

    // MARK: Nieuwe transacties boeken

    /// Boekt nieuwe transacties precies volgens het voorstel van de regels.
    func bookSuggested(_ model: AppModel, _ list: [TransactionsPending]) {
        let usable = list.filter(\.hasSuggestion)
        guard !usable.isEmpty else {
            if !list.isEmpty { model.toast = "Geen voorstel: kies eerst waar dit bij hoort" }
            return
        }
        let kind = kind
        let requests = usable.map { BookingRequest(bankTransactionId: $0.id, allocations: $0.suggestedAllocations(kind: kind)) }
        if usable.count == 1, selection.contains(.bank(usable[0].id)) { reselectBankId = usable[0].id }
        let name = usable[0].bookableMatch?.distribution?.name ?? targetName(TransactionsDraft(pending: usable[0], kind: kind))
        run(model, { usable.count == 1 ? "Geboekt op ‘\(name)’" : "\(TransactionsFormat.number(usable.count)) transacties geboekt" }) { db in
            try BookingService.bookAll(db, requests)
            for ruleId in usable.filter({ $0.match == nil }).compactMap(\.suggestion.ruleId) { try RuleEngine.recordUse(ruleId: ruleId, db) }
        }
    }

    func bookSuggested(_ model: AppModel, ids: [TransactionsItemID]) {
        bookSuggested(model, pendings(in: ids))
    }

    func bookAllCertain(_ model: AppModel) { bookSuggested(model, certainPending) }

    /// Boekt één nieuwe transactie met de eigen keuzes. Er wordt geen regel gemaakt of gewijzigd (6i); deed een
    /// regel precies dit voorstel, dan telt die als gebruikt.
    func book(_ model: AppModel, _ p: TransactionsPending, with draft: TransactionsDraft) {
        let kind = kind
        let unchanged = draft == TransactionsDraft(pending: p, kind: kind)
        let allocation = draft.allocation(amount: p.transaction.amount, kind: kind,
                                          ruleId: unchanged ? p.suggestion.ruleId : nil,
                                          confidence: p.suggestion.confidence)
        let correction = correction(p.transaction, draft, suggestedLabel: p.suggestion.label)
        remember(itemLabel: correction.itemLabel)
        if kind == .spaar { remember(potId: draft.potId) }
        if selection.contains(.bank(p.id)) { reselectBankId = p.id }
        let name = targetName(draft)
        let loan = allocation.temporaryLoan
        run(model, {
            if loan { return "Geboekt en gemarkeerd als tijdelijk geleend. Uitstaand: \(self.loanOutstanding.formatted())" }
            return "Geboekt op ‘\(name)’"
        }) { db in
            try BookingService.book(db, bankTransactionId: p.id, allocations: [allocation])
            _ = try RuleEngine.afterBooking(correction, remember: nil, db)
        }
    }

    func skip(_ model: AppModel, ids: [TransactionsItemID]) {
        let list = pendings(in: ids)
        guard !list.isEmpty else { return }
        run(model, { list.count == 1 ? "Overgeslagen" : "\(TransactionsFormat.number(list.count)) transacties overgeslagen" }) { db in
            for p in list { try BookingService.skip(db, bankTransactionId: p.id) }
        }
    }

    // MARK: Toewijzen

    /// Wijst toe aan een vaste post (op label; nil = divers). Nieuwe transacties worden daarmee geboekt.
    func assign(_ model: AppModel, ids: [TransactionsItemID], itemLabel: String?) {
        guard kind == .betaal else { return }
        let rows = entries(in: ids), news = pendings(in: ids)
        guard !rows.isEmpty || !news.isEmpty else { return }
        // Posten bestaan per jaar: zoek per regel de post met dit label in het jaar van de transactie.
        func resolve(_ day: Day) -> (found: Bool, id: Int64?) {
            guard let itemLabel else { return (true, nil) }
            guard let item = lookups.item(label: itemLabel, year: day.year) else { return (false, nil) }
            return (true, item.id)
        }
        let missing = (rows.map(\.day) + news.map(\.transaction.day)).filter { !resolve($0).found }.count
        let total = rows.count + news.count
        let isSingle = total == 1
        if isSingle, let p = news.first, selection.contains(.bank(p.id)) { reselectBankId = p.id }
        remember(itemLabel: itemLabel)
        let name = itemLabel ?? "Divers"
        run(model, {
            if missing > 0 {
                return "\(TransactionsFormat.number(total - missing)) op ‘\(name)’ gezet; \(missing) niet (de post bestaat niet in dat jaar)"
            }
            return isSingle ? "Toegewezen aan ‘\(name)’" : "\(TransactionsFormat.number(total)) toegewezen aan ‘\(name)’"
        }) { db in
            for row in rows {
                let target = resolve(row.day)
                guard target.found else { continue }
                var e = try EntryService.draft(db, entryId: row.id)
                e.budgetItemId = target.id
                try EntryService.update(db, entryId: row.id, e)
                // Geen regel leren (6i): een regel ontstaat alleen met toestemming in Nakijken of bij Regels.
            }
            for p in news {
                let target = resolve(p.transaction.day)
                guard target.found else { continue }
                var d = TransactionsDraft(pending: p, kind: .betaal); d.itemId = target.id
                try BookingService.book(db, bankTransactionId: p.id, allocations: [
                    d.allocation(amount: p.transaction.amount, kind: .betaal, confidence: p.suggestion.confidence)])
                _ = try RuleEngine.afterBooking(self.correction(p.transaction, d, suggestedLabel: p.suggestion.label),
                                                remember: nil, db)
            }
        }
    }

    /// Wijst toe aan een pot op de spaarrekening (nil = niet toegewezen).
    func assign(_ model: AppModel, ids: [TransactionsItemID], potId: Int64?) {
        guard kind == .spaar else { return }
        let rows = entries(in: ids), news = pendings(in: ids)
        guard !rows.isEmpty || !news.isEmpty else { return }
        if rows.isEmpty, news.count == 1, selection.contains(.bank(news[0].id)) { reselectBankId = news[0].id }
        remember(potId: potId)
        let name = lookups.pot(potId)?.name
        let count = rows.count + news.count
        run(model, {
            guard let name else { return "Niet meer aan een pot toegewezen" }
            return count == 1 ? "Toegewezen aan pot ‘\(name)’" : "\(TransactionsFormat.number(count)) toegewezen aan pot ‘\(name)’"
        }) { db in
            for row in rows {
                var e = try EntryService.draft(db, entryId: row.id)
                e.potId = potId
                try EntryService.update(db, entryId: row.id, e)
            }
            for p in news {
                var d = TransactionsDraft(pending: p, kind: .spaar); d.potId = potId
                try BookingService.book(db, bankTransactionId: p.id, allocations: [
                    d.allocation(amount: p.transaction.amount, kind: .spaar, confidence: p.suggestion.confidence)])
                _ = try RuleEngine.afterBooking(self.correction(p.transaction, d, suggestedLabel: p.suggestion.label),
                                                remember: nil, db)
            }
        }
    }

    // MARK: Acties op boekingen

    /// Zet een tag aan; hebben alle gekozen boekingen hem al, dan gaat hij uit.
    func toggleTag(_ model: AppModel, ids: [TransactionsItemID], tagId: Int64) {
        let rows = entries(in: ids)
        guard !rows.isEmpty, let name = lookups.tag(tagId)?.name else {
            if !pendings(in: ids).isEmpty { model.toast = "Boek de transactie eerst; daarna kun je een tag zetten" }
            return
        }
        let add = !rows.allSatisfy { $0.tags.contains { $0.id == tagId } }
        run(model, { add ? "Tag ‘\(name)’ gezet" : "Tag ‘\(name)’ weggehaald" }) { db in
            for row in rows {
                var tags = row.tags.map(\.id)
                if add, !tags.contains(tagId) { tags.append(tagId) }
                if !add { tags.removeAll { $0 == tagId } }
                try EntryService.setTags(db, entryId: row.id, tagIds: tags)
            }
        }
    }

    /// Maakt een nieuwe tag (met op verzoek verrekenen aan vanaf de begindatum van de rekening) en zet hem
    /// meteen op de geboekte regels in `ids`. Geeft het id van de tag terug, of nil bij een fout
    /// (de melding staat dan in beeld).
    @discardableResult
    func createTag(_ model: AppModel, name: String, color: String, settles: Bool, ids: [TransactionsItemID]) -> Int64? {
        let rows = entries(in: ids)
        let accountId = accountId
        var created: Int64?
        let ok = run(model, {
            var text = "Tag ‘\(name)’ aangemaakt"
            if !rows.isEmpty { text += rows.count == 1 ? " en gezet" : " en gezet op \(TransactionsFormat.entries(rows.count))" }
            if settles { text += "; verrekenen staat aan" }
            return text
        }) { db in
            let tag = try TagService.create(db, name: name, color: color)
            created = tag.id
            guard let tagId = tag.id else { return }
            if settles {
                let from = try accountId.flatMap { try Account.fetchOne(db, key: $0)?.openingDate } ?? Day.today()
                try SettlementService.enable(db, tagId: tagId, from: from)
            }
            for row in rows {
                try EntryService.setTags(db, entryId: row.id, tagIds: row.tags.map(\.id) + [tagId])
            }
        }
        return ok ? created : nil
    }

    /// Haalt een tag weg van de gekozen boekingen die hem hebben (ook op een spaarrekening, waar tags niet
    /// meer kunnen maar van vroeger nog kunnen staan).
    func removeTag(_ model: AppModel, ids: [TransactionsItemID], tagId: Int64) {
        let rows = entries(in: ids).filter { $0.tags.contains { $0.id == tagId } }
        guard !rows.isEmpty else { return }
        let name = lookups.tag(tagId)?.name ?? "tag"
        run(model, { "Tag ‘\(name)’ weggehaald" }) { db in
            for row in rows {
                try EntryService.setTags(db, entryId: row.id, tagIds: row.tags.map(\.id).filter { $0 != tagId })
            }
        }
    }

    /// Kunnen de gekozen boekingen een tag krijgen? Alleen op de betaalrekening.
    var tagsAllowed: Bool { kind == .betaal }

    /// Tags die op minstens één van de gekozen boekingen staan (op spaar: alleen nog om weg te halen).
    func tagsPresent(in ids: [TransactionsItemID]) -> [HFCore.Tag] {
        let present = Set(entries(in: ids).flatMap { $0.tags.map(\.id) })
        return lookups.tags.filter { present.contains($0.id ?? -1) }
    }

    func setTags(_ model: AppModel, row: EntryRow, _ tagIds: Set<Int64>) {
        run(model, { "Tags bijgewerkt" }) { try EntryService.setTags($0, entryId: row.id, tagIds: tagIds.sorted()) }
    }

    /// Verrekenen met spaar aan of uit (uit als het bij alle gekozen boekingen al aan staat).
    /// Een uitgave komt uit de pot, een bijschrijving gaat naar de pot.
    func toggleReimburse(_ model: AppModel, ids: [TransactionsItemID]) {
        let rows = entries(in: ids).filter { $0.accountKind == .betaal && !$0.amount.isZero && !$0.isSettlementBooking }
        guard !rows.isEmpty else {
            model.toast = pendings(in: ids).isEmpty ? "Verrekenen met spaar kan alleen bij een boeking op de betaalrekening"
                                                    : "Open de transactie en zet ‘Verrekenen met spaar’ aan; het gaat mee bij het boeken"
            return
        }
        let on = !rows.allSatisfy(\.reimburse)
        run(model, { on ? "Verrekenen met spaar aangezet. Kies nog de pot." : "Verrekenen met spaar uitgezet" }) { db in
            for row in rows { try EntryService.setReimburse(db, entryId: row.id, on, potId: on ? row.potId : nil) }
        }
    }

    /// Zet verrekenen met spaar aan met deze pot (nil = pot later kiezen).
    func setReimbursePot(_ model: AppModel, ids: [TransactionsItemID], potId: Int64?) {
        let rows = entries(in: ids).filter { $0.accountKind == .betaal && !$0.amount.isZero && !$0.isSettlementBooking }
        guard !rows.isEmpty else { return }
        let name = lookups.pot(potId)?.name
        let allOut = rows.allSatisfy { $0.amount.isNegative }, allIn = rows.allSatisfy { !$0.amount.isNegative }
        run(model, {
            guard let name else { return "Verrekenen met spaar aangezet; pot nog niet gekozen" }
            if allOut { return "Komt uit pot ‘\(name)’" }
            if allIn { return "Gaat naar pot ‘\(name)’" }
            return "Verrekenen met pot ‘\(name)’"
        }) { db in
            for row in rows { try EntryService.setReimburse(db, entryId: row.id, true, potId: potId) }
        }
    }

    /// Hangt de bankregel aan een verrekening met spaar; een nog niet afgevinkte verrekening wordt eerst
    /// afgevinkt op de dag van de bankregel.
    func attachTransfer(_ model: AppModel, _ p: TransactionsPending, transfer: SavingsTransfer) {
        guard let transferId = transfer.id else { return }
        run(model, { transfer.done ? "Bankregel aan de verrekening gehangen" : "Verrekening afgevinkt en bankregel aangehangen" }) { db in
            if !transfer.done { try SavingsTransferService.markDone(db, savingsTransferId: transferId, on: p.transaction.day) }
            try SavingsTransferService.attach(db, savingsTransferId: transferId, bankTransactionId: p.id)
        }
    }

    /// Tijdelijk geleend van spaar aan of uit (uit als het bij alle gekozen boekingen al aan staat).
    func toggleTemporaryLoan(_ model: AppModel, ids: [TransactionsItemID]) {
        let rows = entries(in: ids).filter { $0.accountKind == .betaal }
        guard !rows.isEmpty else {
            model.toast = pendings(in: ids).isEmpty ? "Tijdelijk geleend kan alleen bij een boeking op de betaalrekening"
                                                    : "Open de transactie en zet ‘Tijdelijk geleend van spaar’ aan onder Meer; het gaat mee bij het boeken"
            return
        }
        let on = !rows.allSatisfy(\.temporaryLoan)
        run(model, {
            (on ? "Gemarkeerd als tijdelijk geleend." : "Markering tijdelijk geleend weggehaald.")
                + " Uitstaand: \(self.loanOutstanding.formatted())"
        }) { db in
            for row in rows { try EntryService.setTemporaryLoan(db, entryId: row.id, on) }
        }
    }

    func setReviewed(_ model: AppModel, ids: [TransactionsItemID], _ reviewed: Bool) {
        let rows = entries(in: ids)
        guard !rows.isEmpty else { return }
        run(model, {
            guard reviewed else { return "Teruggezet op nakijken" }
            return rows.count == 1 ? "Nagekeken" : "\(TransactionsFormat.number(rows.count)) boekingen nagekeken"
        }) { db in
            try EntryService.setReviewed(db, entryIds: rows.map(\.id), reviewed)
        }
    }

    func setNote(_ model: AppModel, row: EntryRow, _ note: String) {
        if draftFor == .entry(row.id) { draft.note = note; original.note = note }
        run(model, { note.isEmpty ? "Notitie weggehaald" : "Notitie bewaard" }) { db in
            var e = try EntryService.draft(db, entryId: row.id)
            e.note = note
            try EntryService.update(db, entryId: row.id, e)
        }
    }

    private func writeText(_ db: Database, row: EntryRow, _ d: TransactionsDraft) throws {
        var e = try EntryService.draft(db, entryId: row.id)
        e.label = d.label.trimmingCharacters(in: .whitespaces)
        e.note = d.note
        if row.bankTransactionId == nil, let amount = d.amount {
            e.day = d.day
            e.amount = amount
            if amount.isZero, row.accountKind == .betaal { e.reimburse = false; e.potId = nil }
        }
        try EntryService.update(db, entryId: row.id, e)
    }

    /// Bewaart de getypte velden van de gekozen boeking (omschrijving, notitie; bij handinvoer ook datum en bedrag).
    @discardableResult
    func saveText(_ model: AppModel) -> Bool {
        guard let item = single, let row = item.entry, isTextDirty, draft.isValid, !isLocked(item) else { return true }
        let d = draft
        original = draft
        return run(model, { "Bewaard" }) { try self.writeText($0, row: row, d) }
    }

    /// Getypte tekst gaat niet verloren als je een andere regel kiest.
    private func saveTextIfNeeded(_ model: AppModel) {
        guard draft != original, case .entry(let id)? = draftFor, let row = entries.first(where: { $0.id == id }),
              draft.isValid, !lookups.closedYears.contains(row.day.year) else { return }
        let d = draft
        original = draft
        model.perform("Bewaard") { try model.db.write { try self.writeText($0, row: row, d) } }
    }

    func unbook(_ model: AppModel, row: EntryRow) {
        guard let bankId = row.bankTransactionId else { return }
        original = draft
        let ok = run(model, { "Boeking ongedaan gemaakt; de transactie staat weer als nieuw in de lijst" }) {
            try BookingService.unbook($0, bankTransactionId: bankId)
        }
        if ok, items.contains(where: { $0.id == .bank(bankId) }) { selection = [.bank(bankId)] }
    }

    func delete(_ model: AppModel, row: EntryRow) {
        original = draft
        run(model, { "Boeking verwijderd" }) { try EntryService.delete($0, entryId: row.id) }
    }

    @discardableResult
    func create(_ model: AppModel, accountId: Int64, kind: AccountKind, draft d: TransactionsDraft) -> Bool {
        guard let amount = d.amount else { return false }
        let reimburse = kind == .betaal && d.reimburse && !amount.isZero
        let entryDraft = EntryDraft(
            accountId: accountId, day: d.day, amount: amount,
            label: d.label.trimmingCharacters(in: .whitespaces),
            budgetItemId: kind == .betaal ? d.itemId : nil,
            potId: kind == .spaar ? d.potId : (reimburse ? d.potId : nil),
            reimburse: reimburse, tagIds: kind == .betaal ? d.tagIds.sorted() : [], note: d.note,
            temporaryLoan: kind == .betaal && d.temporaryLoan)
        var created: Int64?
        let ok = run(model, { "Boeking toegevoegd" }) { created = try EntryService.create($0, entryDraft).id }
        if ok, let created, items.contains(where: { $0.id == .entry(created) }) { selection = [.entry(created)] }
        return ok
    }

    // MARK: Begrotingsmaand

    /// Laat boekingen in een andere maand meetellen ("yyyy-MM"; nil = de maand van de datum).
    func setPeriod(_ model: AppModel, ids: [TransactionsItemID], period: String?) {
        let rows = entries(in: ids)
        guard !rows.isEmpty else { return }
        let parts = period?.split(separator: "-").compactMap { Int($0) } ?? []
        let year = parts.count == 2 ? parts[0] : nil, month = parts.count == 2 ? parts[1] : nil
        run(model, {
            guard let month else { return "Telt weer mee in de maand van de datum" }
            return "Telt nu mee in \(Day.monthNames[month - 1]). Het saldo van de rekening verandert niet."
        }) { db in
            for row in rows { try EntryService.setPeriod(db, entryId: row.id, year: year, month: month) }
        }
    }

    // MARK: Omschrijving overnemen

    /// Zet een bestaande omschrijving op een boeking, met de post en tags die er meestal bij horen
    /// als de boeking die nog niet heeft.
    func applyLabel(_ model: AppModel, row: EntryRow, _ suggestion: LabelSuggestion) {
        var d = TransactionsDraft(row: row)
        d.adopt(suggestion, lookups: lookups, kind: row.accountKind)
        if draftFor == .entry(row.id) { draft.label = d.label; original.label = d.label }
        run(model, { "Omschrijving ‘\(d.label)’ overgenomen" }) { db in
            var e = try EntryService.draft(db, entryId: row.id)
            e.label = d.label
            if row.accountKind == .betaal { e.budgetItemId = d.itemId }
            e.tagIds = d.tagIds.sorted()
            try EntryService.update(db, entryId: row.id, e)
        }
    }

    // MARK: Vaste storting

    /// Kiest één van meer passende vaste stortingen voor de gekozen nieuwe transactie.
    func chooseDistribution(_ model: AppModel, _ p: TransactionsPending, distributionId: Int64) {
        matchChoice = model.read(matchChoice) {
            try DistributionService.proposal($0, distributionId: distributionId, for: p.transaction)
        }
        differencePotId = nil
    }

    /// Wat er na de vaste verdeling overblijft van het bankbedrag (nul als het precies past).
    func distributionRest(_ p: TransactionsPending) -> Money {
        guard let match = matchChoice else { return .zero }
        return p.transaction.amount - match.allocations.map(\.amount).sum()
    }

    /// Boekt volgens de vaste storting; een verschil gaat naar de gekozen pot of blijft niet toegewezen.
    func bookDistribution(_ model: AppModel, _ p: TransactionsPending) {
        guard let match = matchChoice, let distribution = match.distribution, !match.allocations.isEmpty else { return }
        var allocations = match.allocations.map { a -> Allocation in var a = a; a.reviewed = true; return a }
        let rest = distributionRest(p)
        if !rest.isZero {
            allocations.append(Allocation(amount: rest, label: "\(distribution.name): verschil",
                                          potId: match.side == .destination ? differencePotId : nil, reviewed: true))
        }
        let count = allocations.count
        if selection.contains(.bank(p.id)) { reselectBankId = nil }
        run(model, { count == 1 ? "Geboekt op ‘\(distribution.name)’" : "‘\(distribution.name)’ geboekt, verdeeld over \(count) regels" }) { db in
            try BookingService.book(db, bankTransactionId: p.id, allocations: allocations)
        }
    }

    // MARK: Verwachting

    func realizeForecast(_ model: AppModel, _ item: ForecastItem, row: EntryRow) {
        guard let id = item.id else { return }
        run(model, { "Verwachting afgevinkt" }) { try ForecastService.markRealized($0, forecastItemId: id, entryId: row.id) }
    }

    // MARK: Verrekenen

    @discardableResult
    func settle(_ model: AppModel, tagId: Int64, entryIds: [Int64], includeStart: Bool = false, day: Day,
                depositEntryId: Int64?) -> Bool {
        var result: SettlementResult?
        return run(model, {
            guard let result else { return "Verrekend" }
            var text = "\(result.settlement.amount.formatted()) verrekend"
            if let difference = result.difference, !difference.isZero {
                text += difference > .zero ? "; \(difference.formatted()) te veel teruggestort" : "; \(difference.magnitude.formatted()) te weinig teruggestort"
            } else if result.deposit == nil {
                text += "; de terugstorting koppel je later"
            }
            return text
        }) { db in
            result = try SettlementService.settle(db, tagId: tagId, entryIds: entryIds, includeStart: includeStart,
                                                  day: day, depositEntryId: depositEntryId)
        }
    }

    func linkDeposit(_ model: AppModel, settlementId: Int64, depositEntryId: Int64) {
        run(model, { "Terugstorting gekoppeld aan de verrekening" }) {
            try SettlementService.linkDeposit($0, settlementId: settlementId, depositEntryId: depositEntryId)
        }
    }

    /// Opent de sheet Verrekenen voor een tag, optioneel met een bijschrijving als terugstorting.
    func startSettle(tagId: Int64, deposit: EntryRow? = nil) {
        guard let tag = lookups.tag(tagId) else { return }
        settleTarget = TransactionsSettleTarget(tagId: tagId, tagName: tag.name, deposit: deposit)
    }

    func deleteSettlement(_ model: AppModel, settlementId: Int64) {
        run(model, { "Verrekening ongedaan gemaakt; de boekingen staan weer open" }) {
            try SettlementService.delete($0, settlementId: settlementId)
        }
    }

    // MARK: Splitsen en notitie

    func startSplit(_ model: AppModel, _ item: TransactionsFeedItem) {
        guard let bankId = item.bankTransactionId else {
            model.toast = "Splitsen kan alleen bij een transactie van de bank"
            return
        }
        let kind = kind
        splitTarget = model.read(nil as TransactionsSplitTarget?) { db in
            guard let transaction = try BankTransaction.fetchOne(db, key: bankId) else { return nil }
            var parts: [TransactionsSplitPart] = []
            if let p = item.pending {
                parts = [TransactionsSplitPart(draft: TransactionsDraft(pending: p, kind: kind))]
            } else {
                for entry in try Entry.filter(Column("bankTransactionId") == bankId).order(Column("id")).fetchAll(db) {
                    var d = TransactionsDraft()
                    d.label = entry.label; d.day = entry.day
                    d.isIncome = !entry.amount.isNegative; d.magnitude = entry.amount.magnitude
                    d.itemId = entry.budgetItemId; d.potId = entry.potId; d.reimburse = entry.reimburse
                    d.note = entry.note; d.temporaryLoan = entry.temporaryLoan; d.period = entry.period
                    d.tagIds = Set(try EntryService.tagIds(db, entryId: entry.id ?? 0))
                    parts.append(TransactionsSplitPart(draft: d))
                }
            }
            if parts.count < 2 {
                var second = TransactionsDraft()
                second.day = transaction.day; second.isIncome = !transaction.amount.isNegative
                parts.append(TransactionsSplitPart(draft: second))
            }
            return TransactionsSplitTarget(transaction: transaction, kind: kind, parts: parts)
        }
    }

    @discardableResult
    func split(_ model: AppModel, _ target: TransactionsSplitTarget, parts: [TransactionsSplitPart]) -> Bool {
        let negative = target.transaction.amount.isNegative
        var allocations: [Allocation] = []
        for part in parts {
            guard let magnitude = part.draft.magnitude?.magnitude, !magnitude.isZero else { continue }
            allocations.append(part.draft.allocation(amount: negative ? -magnitude : magnitude, kind: target.kind))
        }
        let count = allocations.count
        return run(model, { count == 1 ? "Geboekt als één regel" : "Gesplitst in \(count) delen" }) { db in
            try BookingService.book(db, bankTransactionId: target.id, allocations: allocations)
        }
    }

    func startNote(_ model: AppModel, ids: [TransactionsItemID]) {
        guard ids.count == 1, let row = entries(in: ids).first else {
            model.toast = pendings(in: ids).isEmpty ? "Kies één boeking voor een notitie"
                                                    : "Boek de transactie eerst; daarna kun je een notitie maken"
            return
        }
        noteTarget = row
    }
}

enum TransactionsFormat {
    private static let dutch = Locale(identifier: "nl_NL")
    private static let weekdays = ["zondag", "maandag", "dinsdag", "woensdag", "donderdag", "vrijdag", "zaterdag"]

    static let loanHelp = "Geld dat je even van spaar haalt en later terugboekt. Het telt niet mee als besteedbaar zolang het uitstaat. Markeer ook de terugboeking."

    static let settleHelp = "Bij een uitgave komt het bedrag uit de pot op de spaarrekening, bij een bijschrijving gaat het naar de pot. Het saldo maak je later in één keer over bij Verrekenen met spaar."
    static let periodHelp = "Voor iets dat eind van de maand is betaald maar bij de volgende maand hoort. Het saldo van je rekening verandert er niet door."

    /// "yyyy-MM" voor de maand vóór (−1), van (0) of na (+1) de datum; nil voor de maand van de datum zelf.
    static func period(_ day: Day, offset: Int) -> (key: String?, month: Int, year: Int) {
        var month = day.month + offset, year = day.year
        if month < 1 { month += 12; year -= 1 }
        if month > 12 { month -= 12; year += 1 }
        return (offset == 0 ? nil : String(format: "%04d-%02d", year, month), month, year)
    }

    /// Maandnummer uit "yyyy-MM".
    static func month(of period: String?) -> Int? {
        guard let parts = period?.split(separator: "-"), parts.count == 2, let m = Int(parts[1]), (1...12).contains(m) else { return nil }
        return m
    }

    static func number(_ n: Int) -> String { n.formatted(.number.locale(dutch)) }

    /// "1 boeking", "1.204 boekingen"
    static func entries(_ n: Int) -> String { "\(number(n)) \(n == 1 ? "boeking" : "boekingen")" }

    /// "Vandaag", "Gisteren", "dinsdag 15 juni" (met jaar als het een ander jaar is).
    static func dayTitle(_ day: Day, today: Day) -> String {
        if day == today { return "Vandaag" }
        if day == today.adding(days: -1) { return "Gisteren" }
        if day == today.adding(days: 1) { return "Morgen" }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let weekday = weekdays[(calendar.component(.weekday, from: day.date) - 1) % 7]
        return "\(weekday) \(day.day) \(Day.monthNames[day.month - 1])" + (day.year == today.year ? "" : " \(day.year)")
    }
}
