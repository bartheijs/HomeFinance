import SwiftUI
import GRDB
import HFCore
import HFInsight
import HFBudget

/// Wat de gebruiker in de filterbalk heeft gekozen. Het jaar komt uit `AppModel.year`.
struct TransactionsCriteria: Equatable {
    var text = ""
    var accountId: Int64?
    var month: Int?
    var itemId: Int64?
    var potId: Int64?
    var tagId: Int64?
    var unreviewedOnly = false
    var diversOnly = false
    var reimburseOnly = false
    var sort: EntrySort = .dayDescending

    var trimmedText: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var hasFilters: Bool {
        !trimmedText.isEmpty || accountId != nil || month != nil || itemId != nil || potId != nil || tagId != nil
            || unreviewedOnly || diversOnly || reimburseOnly
    }

    /// Een filter op tag, post of pot: dan tonen we de samenvatting.
    var hasSubject: Bool { itemId != nil || potId != nil || tagId != nil }

    mutating func clearFilters() {
        let keep = sort
        self = TransactionsCriteria()
        sort = keep
    }

    func filter(year: Int, limit: Int?, offset: Int = 0) -> EntryFilter {
        EntryFilter(accountId: accountId, year: year, month: month,
                    text: trimmedText.isEmpty ? nil : trimmedText,
                    budgetItemId: itemId, potId: potId, tagId: tagId,
                    diversOnly: diversOnly, unreviewedOnly: unreviewedOnly, reimburseOnly: reimburseOnly,
                    sort: sort, limit: limit, offset: offset)
    }
}

/// Keuzelijsten voor filters, inspector en de sheet.
struct TransactionsLookups: Equatable {
    var accounts: [Account] = []
    /// Vaste posten van het getoonde jaar waarop je kunt boeken (zonder RES-regels).
    var items: [BudgetItem] = []
    var pots: [Pot] = []
    var tags: [Tag] = []
    var yearClosed = false
    var hasAnyEntries = true
    /// Nog na te kijken in het getoonde jaar (zonder andere filters).
    var unreviewedCount = 0

    var incomeItems: [BudgetItem] { items.filter { $0.direction == .IN } }
    var expenseItems: [BudgetItem] { items.filter { $0.direction == .UIT } }
    var activeAccounts: [Account] { accounts.filter { !$0.archived } }

    func account(_ id: Int64?) -> Account? { accounts.first { $0.id == id } }
    func item(_ id: Int64?) -> BudgetItem? { items.first { $0.id == id } }
    func pot(_ id: Int64?) -> Pot? { pots.first { $0.id == id } }
    func tag(_ id: Int64?) -> Tag? { tags.first { $0.id == id } }

    /// Potten van één spaarrekening; een gearchiveerde pot alleen als hij al gekozen is.
    func pots(accountId: Int64?, keeping current: Int64? = nil) -> [Pot] {
        pots.filter { (accountId == nil || $0.accountId == accountId) && (!$0.archived || $0.id == current) }
    }

    static func fetch(_ db: Database, year: Int) throws -> TransactionsLookups {
        var l = TransactionsLookups()
        l.accounts = try Account.order(Column("sortOrder"), Column("name")).fetchAll(db)
        let budgetYear = try BudgetYear.filter(Column("year") == year).fetchOne(db)
        l.yearClosed = budgetYear?.closed ?? false
        l.items = try TransactionsLookups.items(db, year: year)
        l.pots = try Pot.order(Column("accountId"), Column("sortOrder"), Column("name")).fetchAll(db)
        l.tags = try Tag.order(Column("sortOrder"), Column("name")).fetchAll(db)
        l.hasAnyEntries = try Entry.fetchCount(db) > 0
        l.unreviewedCount = try Insight.searchEntries(
            db, filter: EntryFilter(year: year, unreviewedOnly: true, limit: 0)).totalCount
        return l
    }

    /// Posten van een jaar waarop geboekt mag worden.
    static func items(_ db: Database, year: Int) throws -> [BudgetItem] {
        guard let y = try BudgetYear.filter(Column("year") == year).fetchOne(db), let id = y.id else { return [] }
        return try BudgetItem.filter(Column("yearId") == id && Column("direction") != Direction.RES.rawValue)
            .order(Column("sortOrder")).fetchAll(db)
    }
}

/// De bewerkbare velden van één boeking in de inspector (en in de sheet voor een nieuwe boeking).
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
        label = row.label
        day = row.day
        isIncome = !row.amount.isNegative
        magnitude = row.amount.magnitude
        itemId = row.budgetItemId
        potId = row.potId
        reimburse = row.reimburse
        tagIds = Set(row.tags.map(\.id))
        note = row.note
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
}

/// Extra gegevens bij de gekozen boeking: de andere delen van een splitsing en de tegenboeking.
struct TransactionsDetail: Equatable {
    var parts: [Entry] = []
    var counter: Entry?
    var counterAccountName: String?
    var savingsTransfer: SavingsTransfer?

    static func fetch(_ db: Database, row: EntryRow) throws -> TransactionsDetail {
        var d = TransactionsDetail()
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

/// Toestand van het scherm Transacties: filters, de geladen pagina's, de selectie en het concept in de inspector.
@MainActor @Observable
final class TransactionsStore {
    static let pageSize = 200

    var criteria = TransactionsCriteria()
    private(set) var rows: [EntryRow] = []
    private(set) var totalCount = 0
    private(set) var totalSum = Money.zero
    private(set) var lookups = TransactionsLookups()
    private(set) var hasLoaded = false
    var selection = Set<Int64>()
    var showInspector = true

    // Inspector
    private(set) var editingRow: EntryRow?
    private(set) var detail = TransactionsDetail()
    var draft = TransactionsDraft()
    private(set) var original = TransactionsDraft()
    /// Loopt op als het concept van buitenaf vervangen wordt (velden opnieuw opbouwen).
    private(set) var draftVersion = 0
    /// Selectie die wacht tot de gebruiker heeft gekozen wat er met niet-bewaarde wijzigingen gebeurt.
    var pendingSelection: Set<Int64>?
    var showUnsavedDialog = false

    @ObservationIgnored private var loadedYear: Int?
    @ObservationIgnored private var loadedCriteria: TransactionsCriteria?

    var isDirty: Bool { editingRow != nil && draft != original }
    var hasMore: Bool { rows.count < totalCount }
    var selectedRows: [EntryRow] { rows.filter { selection.contains($0.id) } }

    // MARK: Laden

    func reload(_ model: AppModel) {
        let year = model.year
        if let previous = loadedYear, previous != year { carryFiltersOver(model, to: year) }
        loadedYear = year

        lookups = model.read(lookups) { try TransactionsLookups.fetch($0, year: year) }
        let sameView = loadedCriteria == criteria
        let limit = sameView ? max(Self.pageSize, rows.count) : Self.pageSize
        let filter = criteria.filter(year: year, limit: limit)
        guard let result = model.read(nil as EntrySearchResult?, { try Insight.searchEntries($0, filter: filter) }) else {
            hasLoaded = true
            return
        }
        let anchor = rows.firstIndex { selection.contains($0.id) }
        rows = result.rows
        totalCount = result.totalCount
        totalSum = result.totalSum
        loadedCriteria = criteria
        hasLoaded = true

        // Selectie bijhouden. Verdwijnt de gekozen boeking door een actie (bv. nagekeken onder het filter
        // "Na te kijken"), dan schuift de selectie door naar de volgende regel: zo kijk je snel een rij na.
        let present = Set(rows.map(\.id))
        let kept = selection.intersection(present)
        if isDirty, let id = editingRow?.id, !present.contains(id) {
            // Niet-bewaarde wijzigingen niet stil weggooien.
        } else if kept.isEmpty, !selection.isEmpty, sameView, let anchor, !rows.isEmpty {
            selection = [rows[min(anchor, rows.count - 1)].id]
        } else if kept != selection {
            selection = kept
        }
        if model.isSnapshot, selection.isEmpty, let first = rows.first(where: { !$0.reviewed }) ?? rows.first {
            selection = [first.id]
        }
        syncEditor(model)
    }

    func loadMore(_ model: AppModel) {
        guard hasMore, loadedCriteria == criteria else { return }
        let filter = criteria.filter(year: model.year, limit: Self.pageSize, offset: rows.count)
        guard let result = model.read(nil as EntrySearchResult?, { try Insight.searchEntries($0, filter: filter) }) else { return }
        let known = Set(rows.map(\.id))
        rows.append(contentsOf: result.rows.filter { !known.contains($0.id) })
        totalCount = result.totalCount
        totalSum = result.totalSum
    }

    /// Een postfilter hoort bij één jaar; bij een ander jaar zoeken we de post met hetzelfde label.
    private func carryFiltersOver(_ model: AppModel, to year: Int) {
        guard let label = lookups.item(criteria.itemId)?.label else { return }
        let items = model.read([]) { try TransactionsLookups.items($0, year: year) }
        criteria.itemId = items.first { $0.label == label }?.id
    }

    // MARK: Inspector

    /// Aangeroepen als de selectie in de tabel verandert.
    func selectionChanged(_ model: AppModel) {
        let single = selection.count == 1 ? selection.first : nil
        if single == editingRow?.id, single != nil || editingRow == nil { return }
        if isDirty, let editing = editingRow {
            pendingSelection = selection
            selection = [editing.id]
            showUnsavedDialog = true
            return
        }
        syncEditor(model)
    }

    private func syncEditor(_ model: AppModel) {
        let single = selection.count == 1 ? selection.first : nil
        let row = rows.first { $0.id == single }
        if row?.id != editingRow?.id {
            if isDirty, editingRow != nil, row == nil, single != nil { return }
            editingRow = row
            resetDraft()
        } else if let row {
            let wasDirty = isDirty
            editingRow = row
            if wasDirty {
                original = TransactionsDraft(row: row)
            } else if TransactionsDraft(row: row) != original {
                resetDraft()
            }
        }
        if let row = editingRow {
            detail = model.read(TransactionsDetail()) { try TransactionsDetail.fetch($0, row: row) }
        } else {
            detail = TransactionsDetail()
        }
    }

    func resetDraft() {
        let fresh = editingRow.map(TransactionsDraft.init(row:)) ?? TransactionsDraft()
        draft = fresh
        original = fresh
        draftVersion += 1
    }

    /// Posten van het jaar van een boeking (meestal het getoonde jaar).
    func items(_ model: AppModel, year: Int) -> [BudgetItem] {
        year == model.year ? lookups.items : model.read([]) { try TransactionsLookups.items($0, year: year) }
    }

    @discardableResult
    func save(_ model: AppModel) -> Bool {
        guard let row = editingRow, isDirty else { return true }
        let d = draft
        let ok = model.perform("Boeking bewaard") {
            try model.db.write { db in
                var e = try EntryService.draft(db, entryId: row.id)
                e.label = d.label.trimmingCharacters(in: .whitespaces)
                if row.bankTransactionId == nil, let amount = d.amount {
                    e.day = d.day
                    e.amount = amount
                }
                switch row.accountKind {
                case .betaal:
                    e.budgetItemId = d.itemId
                    e.reimburse = d.reimburse && e.amount.isNegative
                    e.potId = e.reimburse ? d.potId : nil
                case .spaar:
                    e.potId = d.potId
                }
                e.tagIds = d.tagIds.sorted()
                e.note = d.note
                try EntryService.update(db, entryId: row.id, e)
            }
        }
        if ok { original = draft }
        return ok
    }

    func resolveUnsaved(_ model: AppModel, save shouldSave: Bool) {
        if shouldSave {
            guard save(model) else { pendingSelection = nil; return }
        } else {
            original = draft
        }
        if let pending = pendingSelection { selection = pending }
        pendingSelection = nil
        syncEditor(model)
    }

    // MARK: Acties

    private func countText(_ n: Int) -> String { TransactionsFormat.entries(n) }

    func setReviewed(_ model: AppModel, ids: [Int64], _ reviewed: Bool) {
        guard !ids.isEmpty else { return }
        model.perform(reviewed ? "\(countText(ids.count)) nagekeken" : "\(countText(ids.count)) weer op nakijken gezet") {
            try model.db.write { try EntryService.setReviewed($0, entryIds: ids, reviewed) }
        }
    }

    /// Markeert alles wat het huidige filter vindt als nagekeken (ook wat nog niet geladen is).
    func markAllFilteredReviewed(_ model: AppModel) {
        var filter = criteria.filter(year: model.year, limit: nil)
        filter.unreviewedOnly = true
        let onlyAccount = criteria.accountId
        let isWholeAccountAndYear = !criteria.hasSubject && criteria.month == nil && criteria.trimmedText.isEmpty
            && !criteria.diversOnly && !criteria.reimburseOnly
        _ = isWholeAccountAndYear; _ = onlyAccount
        // `EntryService.markAllReviewed` gaat over alle jaren van een rekening; dit scherm toont één jaar,
        // dus markeren we precies de gevonden boekingen.
        let ids = model.read([Int64]()) { try Insight.searchEntries($0, filter: filter).rows.map(\.id) }
        setReviewed(model, ids: ids, true)
    }

    func changeTag(_ model: AppModel, ids: [Int64], tagId: Int64, add: Bool) {
        guard !ids.isEmpty, let name = lookups.tag(tagId)?.name else { return }
        model.perform(add ? "Tag ‘\(name)’ gezet op \(countText(ids.count))" : "Tag ‘\(name)’ weggehaald bij \(countText(ids.count))") {
            try model.db.write { db in
                for id in ids {
                    var tags = try EntryService.tagIds(db, entryId: id)
                    if add, !tags.contains(tagId) { tags.append(tagId) }
                    if !add { tags.removeAll { $0 == tagId } }
                    try EntryService.setTags(db, entryId: id, tagIds: tags)
                }
            }
        }
    }

    /// Zet de vaste post (nil = divers). Alleen boekingen op een betaalrekening doen mee.
    func setItem(_ model: AppModel, ids: [Int64], itemId: Int64?) {
        let targets = rows.filter { ids.contains($0.id) && $0.accountKind == .betaal }.map(\.id)
        guard !targets.isEmpty else {
            model.toast = "Een post kan alleen op boekingen van een betaalrekening"
            return
        }
        let name = lookups.item(itemId)?.label ?? "Divers"
        model.perform("\(countText(targets.count)) op ‘\(name)’ gezet") {
            try model.db.write { db in
                for id in targets {
                    var e = try EntryService.draft(db, entryId: id)
                    e.budgetItemId = itemId
                    try EntryService.update(db, entryId: id, e)
                }
            }
        }
    }

    func unbook(_ model: AppModel, row: EntryRow) {
        guard let bankId = row.bankTransactionId else { return }
        original = draft
        let ok = model.perform("Teruggezet naar Importeren en nakijken") {
            try model.db.write { try BookingService.unbook($0, bankTransactionId: bankId) }
        }
        if ok { selection = [] }
    }

    func delete(_ model: AppModel, row: EntryRow) {
        original = draft
        let ok = model.perform("Boeking verwijderd") {
            try model.db.write { try EntryService.delete($0, entryId: row.id) }
        }
        if ok { selection = [] }
    }

    @discardableResult
    func create(_ model: AppModel, accountId: Int64, kind: AccountKind, draft d: TransactionsDraft) -> Bool {
        guard let amount = d.amount else { return false }
        var created: Int64?
        let reimburse = kind == .betaal && d.reimburse && amount.isNegative
        let entryDraft = EntryDraft(
            accountId: accountId, day: d.day, amount: amount,
            label: d.label.trimmingCharacters(in: .whitespaces),
            budgetItemId: kind == .betaal ? d.itemId : nil,
            potId: kind == .spaar ? d.potId : (reimburse ? d.potId : nil),
            reimburse: reimburse, tagIds: d.tagIds.sorted(), note: d.note)
        let ok = model.perform("Boeking toegevoegd") {
            try model.db.write { created = try EntryService.create($0, entryDraft).id }
        }
        if ok, let created, !isDirty {
            reload(model)
            if rows.contains(where: { $0.id == created }) { selection = [created] }
        }
        return ok
    }

    // MARK: Samenvatting

    /// Aantal maanden waarover het gemiddelde loopt: de verstreken maanden van het getoonde jaar.
    /// nil als er één maand gekozen is of het jaar nog moet beginnen.
    func averageMonths(year: Int, today: Day) -> Int? {
        guard criteria.month == nil else { return nil }
        if year < today.year { return 12 }
        if year == today.year { return today.month }
        return nil
    }

    /// Gemiddelde per maand van het hele zoekresultaat. HFInsight levert dit alleen voor tags per jaar
    /// (`tagYear`); voor een post, pot of combinatie van filters delen we hier de som door het aantal maanden.
    func averagePerMonth(year: Int, today: Day) -> Money? {
        guard let months = averageMonths(year: year, today: today), months > 0, totalCount > 0 else { return nil }
        return Money(cents: totalSum.cents / Int64(months))
    }
}

enum TransactionsFormat {
    private static let dutch = Locale(identifier: "nl_NL")

    static func number(_ n: Int) -> String { n.formatted(.number.locale(dutch)) }

    /// "1 boeking", "1.204 boekingen"
    static func entries(_ n: Int) -> String { "\(number(n)) \(n == 1 ? "boeking" : "boekingen")" }
}
