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

    var id: Int64 { transaction.id ?? 0 }
    /// Het voorstel is bruikbaar zonder verder te kiezen.
    var hasSuggestion: Bool { suggestion.confidence != .geen && suggestion.warnings.isEmpty }
    var isCertain: Bool { suggestion.confidence == .hoog && suggestion.warnings.isEmpty }
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
        let text = entry?.label ?? pending?.suggestion.label ?? ""
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

    var trimmedText: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Aantal actieve filters achter de knop Filters.
    var filterCount: Int {
        [month != nil, itemId != nil, potId != nil, tagId != nil, status != .all, diversOnly, reimburseOnly]
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
        for item in items {
            if let year = yearById[item.yearId] { l.itemsByYear[year, default: []].append(item) }
        }
        l.pots = try Pot.order(Column("accountId"), Column("sortOrder"), Column("name")).fetchAll(db)
        l.tags = try HFCore.Tag.order(Column("sortOrder"), Column("name")).fetchAll(db)
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
    /// Spaarrekening: de pot. Betaalrekening: de pot die vergoedt.
    var potId: Int64?
    var reimburse = false
    var tagIds: Set<Int64> = []
    var note = ""

    init() {}

    init(row: EntryRow) {
        label = row.label; day = row.day
        isIncome = !row.amount.isNegative; magnitude = row.amount.magnitude
        itemId = row.budgetItemId; potId = row.potId; reimburse = row.reimburse
        tagIds = Set(row.tags.map(\.id)); note = row.note
    }

    init(pending p: TransactionsPending, kind: AccountKind) {
        let s = p.suggestion, t = p.transaction
        label = s.label; day = t.day
        isIncome = !t.amount.isNegative; magnitude = t.amount.magnitude
        tagIds = Set(s.tagIds)
        switch kind {
        case .betaal:
            itemId = s.budgetItemId
            reimburse = s.reimburse && t.amount.isNegative
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
        let wantsReimburse = kind == .betaal && reimburse && amount.isNegative
        return Allocation(amount: amount, label: label.trimmingCharacters(in: .whitespaces),
                          budgetItemId: kind == .betaal ? itemId : nil,
                          potId: kind == .spaar ? potId : (wantsReimburse ? potId : nil),
                          reimburse: wantsReimburse, tagIds: tagIds.sorted(), note: note,
                          ruleId: ruleId, confidence: confidence, reviewed: true)
    }
}

/// Extra gegevens bij de gekozen boeking: de andere delen van een splitsing en de tegenboeking.
struct TransactionsExtra: Equatable {
    var parts: [Entry] = []
    var counter: Entry?
    var counterAccountName: String?
    var savingsTransfer: SavingsTransfer?

    static func fetch(_ db: Database, row: EntryRow) throws -> TransactionsExtra {
        var d = TransactionsExtra()
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

    /// Laatst gekozen posten (op label, want posten bestaan per jaar) en potten, voor bovenaan de keuzelijst.
    private(set) var recentItemLabels: [String] = []
    private(set) var recentPotIds: [Int64] = []

    @ObservationIgnored private var entries: [EntryRow] = []
    @ObservationIgnored private var loadedKey: String?
    @ObservationIgnored private var reselectBankId: Int64?

    var account: AccountOverview? { lookups.account(accountId) }
    var kind: AccountKind { account?.kind ?? .betaal }
    var hasMore: Bool { criteria.status != .newOnly && entries.count < totalEntryCount }
    var selectedItems: [TransactionsFeedItem] { items.filter { selection.contains($0.id) } }
    var single: TransactionsFeedItem? { selection.count == 1 ? items.first { selection.contains($0.id) } : nil }
    var certainPending: [TransactionsPending] { pendingAll.filter(\.isCertain) }
    var isTextDirty: Bool { single?.entry != nil && draft != original }

    func isLocked(_ item: TransactionsFeedItem) -> Bool { lookups.closedYears.contains(item.day.year) }

    // MARK: Laden

    func reload(_ model: AppModel) {
        lookups = model.read(lookups) { try TransactionsLookups.fetch($0, today: model.today) }
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

        pendingAll = model.read([]) { db in
            let suggestions = try RuleEngine.suggestAll(db, accountId: accountId)
            var list: [TransactionsPending] = []
            for item in try Insight.reviewQueue(db, accountId: accountId) {
                guard let id = item.transaction.id else { continue }
                let suggestion = try suggestions[id] ?? RuleEngine.suggest(for: item.transaction, db)
                list.append(TransactionsPending(transaction: item.transaction, suggestion: suggestion))
            }
            return list
        }
        if criteria.status == .newOnly {
            entries = []; totalEntryCount = 0
        } else {
            let filter = criteria.entryFilter(accountId: accountId, year: model.year, limit: limit)
            if let result = model.read(nil as EntrySearchResult?, { try Insight.searchEntries($0, filter: filter) }) {
                entries = result.rows
                totalEntryCount = result.totalCount
            }
        }
        loadSummary(model, accountId: accountId)
        rebuild(model)
        hasLoaded = true
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
        guard criteria.hasSubject, criteria.status != .newOnly else { summary = nil; return }
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
            // Keuzes (post, tags, vergoeden) zijn al bewaard; alleen getypte tekst blijft als concept staan.
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
            extra = model.read(TransactionsExtra()) { try TransactionsExtra.fetch($0, row: row) }
        } else {
            extra = TransactionsExtra()
        }
    }

    func resetDraft() {
        var fresh = TransactionsDraft()
        if let row = single?.entry { fresh = TransactionsDraft(row: row) }
        if let pending = single?.pending { fresh = TransactionsDraft(pending: pending, kind: kind) }
        draft = fresh
        original = fresh
        draftVersion += 1
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
        let requests = usable.map { p in
            BookingRequest(bankTransactionId: p.id, allocations: [
                TransactionsDraft(pending: p, kind: kind).allocation(
                    amount: p.transaction.amount, kind: kind, ruleId: p.suggestion.ruleId, confidence: p.suggestion.confidence)])
        }
        if usable.count == 1, selection.contains(.bank(usable[0].id)) { reselectBankId = usable[0].id }
        let name = targetName(TransactionsDraft(pending: usable[0], kind: kind))
        run(model, { usable.count == 1 ? "Geboekt op ‘\(name)’" : "\(TransactionsFormat.number(usable.count)) transacties geboekt" }) { db in
            try BookingService.bookAll(db, requests)
            for ruleId in usable.compactMap(\.suggestion.ruleId) { try RuleEngine.recordUse(ruleId: ruleId, db) }
        }
    }

    func bookSuggested(_ model: AppModel, ids: [TransactionsItemID]) {
        bookSuggested(model, pendings(in: ids))
    }

    func bookAllCertain(_ model: AppModel) { bookSuggested(model, certainPending) }

    /// Boekt één nieuwe transactie met de eigen keuzes en leert ervan.
    func book(_ model: AppModel, _ p: TransactionsPending, with draft: TransactionsDraft) {
        let kind = kind
        let unchanged = draft == TransactionsDraft(pending: p, kind: kind)
        let allocation = draft.allocation(amount: p.transaction.amount, kind: kind,
                                          ruleId: unchanged ? p.suggestion.ruleId : nil,
                                          confidence: p.suggestion.confidence)
        let correction = correction(p.transaction, draft, suggestedLabel: p.suggestion.label)
        var learned: LearnResult?
        remember(itemLabel: correction.itemLabel)
        if kind == .spaar { remember(potId: draft.potId) }
        if selection.contains(.bank(p.id)) { reselectBankId = p.id }
        let name = targetName(draft)
        run(model, { learned.flatMap { $0.outcome == .unchanged ? nil : $0.message } ?? "Geboekt op ‘\(name)’" }) { db in
            try BookingService.book(db, bankTransactionId: p.id, allocations: [allocation])
            learned = try RuleEngine.learn(from: correction, db)
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
        var learned: LearnResult?
        if isSingle, let p = news.first, selection.contains(.bank(p.id)) { reselectBankId = p.id }
        remember(itemLabel: itemLabel)
        let name = itemLabel ?? "Divers"
        run(model, {
            if let learned, learned.outcome != .unchanged { return learned.message }
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
                // Leren van een correctie, behalve bij een deel van een splitsing.
                if isSingle, let bankId = row.bankTransactionId, row.bank?.amount == row.amount,
                   let transaction = try BankTransaction.fetchOne(db, key: bankId) {
                    var d = TransactionsDraft(row: row); d.itemId = target.id
                    learned = try RuleEngine.learn(from: self.correction(transaction, d, suggestedLabel: nil), db)
                }
            }
            for p in news {
                let target = resolve(p.transaction.day)
                guard target.found else { continue }
                var d = TransactionsDraft(pending: p, kind: .betaal); d.itemId = target.id
                try BookingService.book(db, bankTransactionId: p.id, allocations: [
                    d.allocation(amount: p.transaction.amount, kind: .betaal, confidence: p.suggestion.confidence)])
                let result = try RuleEngine.learn(from: self.correction(p.transaction, d, suggestedLabel: p.suggestion.label), db)
                if isSingle { learned = result }
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
                _ = try RuleEngine.learn(from: self.correction(p.transaction, d, suggestedLabel: p.suggestion.label), db)
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

    func setTags(_ model: AppModel, row: EntryRow, _ tagIds: Set<Int64>) {
        run(model, { "Tags bijgewerkt" }) { try EntryService.setTags($0, entryId: row.id, tagIds: tagIds.sorted()) }
    }

    /// Vergoeden uit spaar aan of uit (uit als het bij alle gekozen uitgaven al aan staat).
    func toggleReimburse(_ model: AppModel, ids: [TransactionsItemID]) {
        let rows = entries(in: ids).filter { $0.accountKind == .betaal && $0.amount.isNegative }
        guard !rows.isEmpty else {
            model.toast = pendings(in: ids).isEmpty ? "Vergoeden uit spaar kan alleen bij een uitgave op de betaalrekening"
                                                    : "Boek de transactie eerst; daarna kun je vergoeden aanzetten"
            return
        }
        let on = !rows.allSatisfy(\.reimburse)
        run(model, { on ? "Vergoeden uit spaar aangezet" : "Vergoeden uit spaar uitgezet" }) { db in
            for row in rows { try EntryService.setReimburse(db, entryId: row.id, on, potId: on ? row.potId : nil) }
        }
    }

    func setReimbursePot(_ model: AppModel, ids: [TransactionsItemID], potId: Int64?) {
        let rows = entries(in: ids).filter { $0.accountKind == .betaal && $0.amount.isNegative }
        guard !rows.isEmpty else { return }
        let name = lookups.pot(potId)?.name
        run(model, { name.map { "Vergoeden uit pot ‘\($0)’" } ?? "Vergoeden uit spaar, pot nog niet gekozen" }) { db in
            for row in rows { try EntryService.setReimburse(db, entryId: row.id, true, potId: potId) }
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
            if !amount.isNegative, row.accountKind == .betaal { e.reimburse = false; e.potId = nil }
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
        let reimburse = kind == .betaal && d.reimburse && amount.isNegative
        let entryDraft = EntryDraft(
            accountId: accountId, day: d.day, amount: amount,
            label: d.label.trimmingCharacters(in: .whitespaces),
            budgetItemId: kind == .betaal ? d.itemId : nil,
            potId: kind == .spaar ? d.potId : (reimburse ? d.potId : nil),
            reimburse: reimburse, tagIds: d.tagIds.sorted(), note: d.note)
        var created: Int64?
        let ok = run(model, { "Boeking toegevoegd" }) { created = try EntryService.create($0, entryDraft).id }
        if ok, let created, items.contains(where: { $0.id == .entry(created) }) { selection = [.entry(created)] }
        return ok
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
                    d.note = entry.note
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
