import Foundation
import GRDB
import HFCore

/// Eén voorbeeld bij een voorstel: een bankregel en de historieboeking waaraan hij gekoppeld is.
public struct SeedExample: Equatable, Sendable {
    public var day: Day
    public var amount: Money
    public var historyLabel: String
}

/// Voorstel voor één regel, afgeleid uit bankregels die aan de Excel-historie gekoppeld zijn.
public struct SeedProposal: Equatable, Sendable, Identifiable {
    /// Stabiele sleutel van de tegenpartij (IBAN, naam of trefwoord).
    public var id: String
    /// Conceptregel (`origin = .geleerd`, nog niet opgeslagen). De app mag hem aanpassen vóór `apply`.
    public var rule: Rule
    /// Tegenpartij zoals de bank hem levert (voor weergave en voor de controle op bestaande regels).
    public var counterpartyName: String
    public var counterpartyIban: String
    /// Aantal koppelingen dat dit voorstel steunt.
    public var matchCount: Int
    /// Twee of drie voorbeelden.
    public var examples: [SeedExample]
    /// Korte toelichting, bv. "5 keer gekoppeld aan post Energie".
    public var explanation: String
}

/// Vermelding van een tegenpartij waarvoor geen voorstel is gedaan.
public struct SeedNote: Equatable, Sendable {
    /// Opgeschoonde naam van de tegenpartij.
    public var counterparty: String
    /// Aantal gekoppelde bankregels van deze tegenpartij.
    public var matchCount: Int
    /// Uitleg voor de gebruiker.
    public var detail: String
}

/// Uitkomst van `HistoryRuleSeeder.propose`.
public struct SeedResult: Equatable, Sendable {
    /// Voorstellen, meeste koppelingen eerst.
    public var proposals: [SeedProposal] = []
    /// Tegenpartijen waarvan de koppelingen over meer doelen verdeeld zijn zonder duidelijke meerderheid.
    public var mixed: [SeedNote] = []
    /// Tegenpartijen waarvoor al een regel bestaat.
    public var alreadyCovered: [SeedNote] = []
    /// Bankregels die aan precies één historieboeking gekoppeld zijn.
    public var matchedCount = 0
    /// Bankregels met meer mogelijke historieboekingen, zonder duidelijke keuze.
    public var ambiguousCount = 0
    /// Bankregels zonder historieboeking met hetzelfde bedrag in de buurt.
    public var noCandidateCount = 0
    /// Bankregels zonder tegenpartij en zonder bruikbaar trefwoord (overgeslagen).
    public var skippedCount = 0
    /// Tegenpartijen met te weinig koppelingen voor een voorstel (één koppeling, niet gelijk aan een plan).
    public var insufficientCount = 0
    public var mixedCount: Int { mixed.count }
    public var alreadyCoveredCount: Int { alreadyCovered.count }
}

/// Stelt regels voor door een bankexport naast de geïmporteerde Excel-historie te leggen.
/// De bankregels worden niet opgeslagen en er wordt niets geboekt; alleen `apply` schrijft, en dan alleen regels.
public enum HistoryRuleSeeder {
    /// Kenmerk van de boekingen uit de Excel-historie (`Entry.note`).
    public static let historyNote = "Excel-historie"

    // MARK: Voorstellen

    /// Koppelt elke bankregel aan hoogstens één historieboeking van `accountId` met hetzelfde bedrag en
    /// groepeert de koppelingen per tegenpartij tot regelvoorstellen. Schrijft niets.
    public static func propose(_ db: Database, candidates: [BankTransaction], accountId: Int64) throws -> SeedResult {
        var result = SeedResult()
        let items = Dictionary(uniqueKeysWithValues: try BudgetItem.fetchAll(db).compactMap { i in i.id.map { ($0, i) } })
        let history = try loadHistory(db, accountId: accountId)
        let existingRules = try Rule.fetchAll(db)

        // 1. Tegenpartij per bankregel; zonder tegenpartij of trefwoord doet de regel niet mee.
        let parties: [Party?] = candidates.map(Party.init)
        result.skippedCount = parties.filter { $0 == nil }.count

        // 2. Koppelen, sterkste aanwijzing eerst: exacte dag, dan 2 dagen / zelfde maand, dan naastgelegen maand.
        var byAmount: [Int64: [Int]] = [:]
        for (i, h) in history.enumerated() { byAmount[h.entry.amount.cents, default: []].append(i) }
        var used = Set<Int>()
        var link: [Int: Int] = [:]          // index bankregel → index historieboeking
        var settled = Set<Int>()            // gekoppeld of dubbelzinnig

        func run(_ tier: (BankTransaction, History) -> Bool, last: Bool) {
            for (t, tx) in candidates.enumerated() where parties[t] != nil && !settled.contains(t) {
                let pool = (byAmount[tx.amount.cents] ?? []).filter { !used.contains($0) && tier(tx, history[$0]) }
                if pool.isEmpty {
                    if last { result.noCandidateCount += 1 }
                    continue
                }
                settled.insert(t)
                if let chosen = choose(pool, history, tx) {
                    used.insert(chosen); link[t] = chosen; result.matchedCount += 1
                } else {
                    result.ambiguousCount += 1
                }
            }
        }
        run({ tx, h in h.realDate && h.entry.day == tx.day }, last: false)
        run({ tx, h in
            h.realDate ? abs(daysBetween(h.entry.day, tx.day)) <= 2 : monthIndex(h.entry.day) == monthIndex(tx.day)
        }, last: false)
        run({ tx, h in !h.realDate && abs(monthIndex(h.entry.day) - monthIndex(tx.day)) == 1 }, last: true)

        // 3. Groeperen per tegenpartij, in volgorde van eerste voorkomen.
        var order: [String] = []
        var groups: [String: [(tx: BankTransaction, hist: History)]] = [:]
        var groupParty: [String: Party] = [:]
        for (t, tx) in candidates.enumerated() {
            guard let party = parties[t], let h = link[t] else { continue }
            if groups[party.key] == nil { order.append(party.key); groupParty[party.key] = party }
            groups[party.key, default: []].append((tx, history[h]))
        }

        for key in order {
            guard let links = groups[key], let party = groupParty[key], let first = links.first else { continue }
            let cleaned = LabelCleaner.cleanLabel(counterparty: first.tx.counterpartyName,
                                                  description: first.tx.descriptionText)
            let name = cleaned.isEmpty ? "Onbekend" : cleaned

            if let rule = links.lazy.compactMap({ coveringRule(existingRules, for: $0.tx) }).first {
                result.alreadyCovered.append(SeedNote(counterparty: name, matchCount: links.count,
                                                      detail: "Er bestaat al een regel: '\(rule.name)'."))
                continue
            }

            // Doel: de post waar de meeste koppelingen naartoe gaan (label over de jaren heen), of divers.
            var targetOrder: [String] = []
            var byTarget: [String: [(tx: BankTransaction, hist: History)]] = [:]
            for l in links {
                let label = l.hist.entry.budgetItemId.flatMap { items[$0]?.label }
                let k = label.map { "post:" + TextNormalizer.normalize($0) } ?? "divers"
                if byTarget[k] == nil { targetOrder.append(k) }
                byTarget[k, default: []].append(l)
            }
            let topKey = targetOrder.max { (byTarget[$0]?.count ?? 0) < (byTarget[$1]?.count ?? 0) } ?? "divers"
            let majority = byTarget[topKey] ?? []
            if majority.count * 3 < links.count * 2 {
                let parts = targetOrder.map { k -> String in
                    let label = byTarget[k]?.first?.hist.entry.budgetItemId.flatMap { items[$0]?.label }
                    return "\(byTarget[k]?.count ?? 0) × \(label.map { "post \($0)" } ?? "overig")"
                }
                result.mixed.append(SeedNote(counterparty: name, matchCount: links.count,
                                             detail: "Verdeeld over meer doelen: " + parts.joined(separator: ", ") + "."))
                continue
            }

            let item = majority.first?.hist.entry.budgetItemId.flatMap { items[$0] }
            let equalsPlan = majority.count == 1 && item != nil
                && majority.allSatisfy { l in l.hist.entry.budgetItemId.flatMap { items[$0]?.planAmount } == l.tx.amount }
            guard majority.count >= 2 || equalsPlan else {
                result.insufficientCount += 1
                continue
            }

            var rule = party.newRule(name: name)
            rule.targetItemLabel = item?.label
            if let item {
                rule.entryLabel = item.label
                let amounts = Set(majority.map(\.tx.amount))
                if majority.count >= 2, amounts.count == 1 { rule.amount = amounts.first }
            } else {
                // Divers: alleen een omschrijving als de historielabels (bijna) gelijk zijn.
                var labelCount: [String: Int] = [:]
                for l in majority { labelCount[l.hist.labelNorm, default: 0] += 1 }
                if let (norm, count) = labelCount.max(by: { $0.value < $1.value }), !norm.isEmpty,
                   count * 3 >= majority.count * 2 {
                    rule.entryLabel = majority.first { $0.hist.labelNorm == norm }
                        .map { TextNormalizer.collapse($0.hist.entry.label) }
                }
            }
            var tagCount: [Int64: Int] = [:]
            for l in majority { for tag in l.hist.tags { tagCount[tag, default: 0] += 1 } }
            rule.tagIdList = tagCount.filter { $0.value * 3 >= majority.count * 2 }.keys.sorted()

            let target = item.map { "post \($0.label)" } ?? "overig"
            var explanation = "\(majority.count) keer gekoppeld aan \(target)"
            if equalsPlan { explanation += " (bedrag gelijk aan het plan)" }
            if majority.count < links.count { explanation += "; \(links.count - majority.count) keer aan iets anders" }
            result.proposals.append(SeedProposal(
                id: key, rule: rule,
                counterpartyName: TextNormalizer.collapse(first.tx.counterpartyName),
                counterpartyIban: TextNormalizer.normalizeIban(first.tx.counterpartyIban),
                matchCount: majority.count,
                examples: majority.prefix(3).map {
                    SeedExample(day: $0.tx.day, amount: $0.tx.amount, historyLabel: $0.hist.entry.label)
                },
                explanation: explanation))
        }
        // Stabiel: meeste koppelingen eerst, verder de volgorde van het bankbestand.
        result.proposals = result.proposals.enumerated()
            .sorted { ($1.element.matchCount, $0.offset) < ($0.element.matchCount, $1.offset) }
            .map(\.element)
        return result
    }

    // MARK: Opslaan

    /// Slaat de gekozen voorstellen op als geleerde regels (alles of niets). Een voorstel waarvoor intussen
    /// al een regel voor die tegenpartij bestaat wordt overgeslagen. Geeft de gemaakte regels terug.
    @discardableResult
    public static func apply(_ db: Database, proposals: [SeedProposal]) throws -> [Rule] {
        var created: [Rule] = []
        try db.inSavepoint {
            var rules = try Rule.fetchAll(db)
            for proposal in proposals {
                let probe = BankTransaction(
                    accountId: proposal.rule.accountId ?? 0, day: Day(year: 2000, month: 1, day: 1)!, amount: .zero,
                    counterpartyName: proposal.rule.counterpartyContains ?? proposal.counterpartyName,
                    counterpartyIban: proposal.rule.counterpartyIban ?? proposal.counterpartyIban,
                    descriptionText: proposal.rule.descriptionContains ?? "", fingerprint: "")
                guard coveringRule(rules, for: probe) == nil else { continue }
                var rule = proposal.rule
                rule.id = nil
                rule.origin = .geleerd
                rule.reimburse = false
                rule.hitCount = 0
                rule.lastUsed = nil
                try RuleEngine.save(&rule, db)
                created.append(rule)
                rules.append(rule)
            }
            return .commit
        }
        return created
    }

    // MARK: Intern

    struct History {
        let entry: Entry
        /// Diverse boeking met een echte datum (niet de 15e).
        let realDate: Bool
        let labelNorm: String
        let words: [String]
        let tags: Set<Int64>
    }

    private static let stopWords: Set<String> = ["van", "het", "een", "voor", "der", "den", "met", "aan", "bij"]

    private static func loadHistory(_ db: Database, accountId: Int64) throws -> [History] {
        let entries = try Entry
            .filter(Column("accountId") == accountId && Column("bankTransactionId") == nil && Column("note") == historyNote)
            .order(Column("day"), Column("id"))
            .fetchAll(db)
        var tags: [Int64: Set<Int64>] = [:]
        let rows = try Row.fetchAll(db, sql: """
            SELECT et.entryId, et.tagId FROM entryTag et JOIN entry e ON e.id = et.entryId
            WHERE e.accountId = ? AND e.note = ?
            """, arguments: [accountId, historyNote])
        for row in rows { tags[row[0], default: []].insert(row[1]) }
        return entries.map { e in
            let norm = TextNormalizer.normalize(e.label)
            let words = norm.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
                .filter { $0.count >= 3 && !stopWords.contains($0) }
            return History(entry: e, realDate: e.budgetItemId == nil && e.day.day != 15, labelNorm: norm,
                           words: words, tags: e.id.flatMap { tags[$0] } ?? [])
        }
    }

    /// Kiest uit meer kandidaten: één kandidaat, onderling gelijke kandidaten, of precies één waarvan alle
    /// woorden van het historielabel in de banktekst staan. Anders nil (dubbelzinnig).
    private static func choose(_ pool: [Int], _ history: [History], _ tx: BankTransaction) -> Int? {
        if pool.count == 1 { return pool[0] }
        let first = history[pool[0]]
        if pool.allSatisfy({
            history[$0].entry.budgetItemId == first.entry.budgetItemId && history[$0].labelNorm == first.labelNorm
                && history[$0].tags == first.tags
        }) { return pool[0] }
        let text = TextNormalizer.normalize(tx.counterpartyName + " " + tx.descriptionText)
        let helped = pool.filter { i in
            !history[i].words.isEmpty && history[i].words.allSatisfy { text.contains($0) }
        }
        return helped.count == 1 ? helped[0] : nil
    }

    /// Een bestaande regel (handmatig of geleerd, aan of uit) die deze tegenpartij al herkent.
    /// Het bedrag en de rekening van de regel tellen daarbij niet mee.
    private static func coveringRule(_ rules: [Rule], for tx: BankTransaction) -> Rule? {
        let hasCounterparty = !tx.counterpartyName.allSatisfy(\.isWhitespace)
            || !tx.counterpartyIban.allSatisfy(\.isWhitespace)
        return rules.first { rule in
            var probe = rule
            probe.amount = nil
            probe.accountId = nil
            guard let match = RuleMatcher.match(probe, tx, ignoreEnabled: true) else { return false }
            if match.basis == .counterparty { return true }
            // Een trefwoordregel dekt alleen een tegenpartij die zelf op een trefwoord gegroepeerd is.
            return !hasCounterparty && match.basis == .keyword
        }
    }

    private static func monthIndex(_ day: Day) -> Int { day.year * 12 + day.month }

    private static func daysBetween(_ a: Day, _ b: Day) -> Int {
        Int((b.date.timeIntervalSince(a.date) / 86_400).rounded())
    }
}

extension Party {
    /// Sleutel om bankregels van dezelfde tegenpartij te groeperen.
    var key: String {
        switch self {
        case .iban(let iban, _): return "iban:" + iban
        case .name(_, let normalized): return "naam:" + normalized
        case .keyword(_, let normalized): return "trefwoord:" + normalized
        }
    }
}
