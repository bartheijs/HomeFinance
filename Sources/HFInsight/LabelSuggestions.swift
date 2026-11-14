import Foundation
import GRDB
import HFCore

// MARK: - Typen

/// Een bestaande omschrijving, om bij het typen voor te stellen.
public struct LabelSuggestion: Identifiable, Equatable, Sendable {
    /// De genormaliseerde omschrijving (kleine letters, enkele spaties); gelijk aan `LabelTotal.id`.
    public let id: String
    /// De meest gebruikte schrijfwijze.
    public let label: String
    /// Aantal boekingen met deze omschrijving (0 als hij alleen in een regel voorkomt).
    public let count: Int
    /// Dag van de laatste boeking, of nil als hij alleen in een regel voorkomt.
    public let lastUsed: Day?
    /// Label van de vaste post die bij meer dan de helft van de boekingen hoort, of nil (meestal divers).
    /// Posten bestaan per jaar; het label koppelt ze over jaren.
    public let itemLabel: String?
    /// De tags die bij meer dan de helft van de boekingen staan.
    public let tags: [TagRef]

    public init(id: String, label: String, count: Int, lastUsed: Day?, itemLabel: String?, tags: [TagRef]) {
        self.id = id; self.label = label; self.count = count; self.lastUsed = lastUsed
        self.itemLabel = itemLabel; self.tags = tags
    }

    /// Suggestie voor een losse tekst (handig in tests en previews).
    public init(label: String, count: Int = 1, lastUsed: Day? = nil) {
        self.init(id: Insight.normalizedLabel(label), label: Insight.cleanLabel(label), count: count,
                  lastUsed: lastUsed, itemLabel: nil, tags: [])
    }
}

/// Zoeken en vergelijken van omschrijvingen, zonder database. Werkt op een lijst uit `Insight.allLabels`,
/// die de aanroeper kan bewaren zolang er niets geboekt wordt.
public enum LabelMatcher {
    /// Omschrijvingen die met de tekst beginnen (eerst) of hem bevatten, hoofdletter- en accentongevoelig;
    /// daarbinnen op aantal keer gebruikt en dan op laatst gebruikt. Lege tekst: de meest gebruikte.
    public static func suggest(_ text: String, from labels: [LabelSuggestion], limit: Int = 8) -> [LabelSuggestion] {
        let needle = fold(text)
        let ranked: [(Int, LabelSuggestion)] = labels.compactMap { s in
            if needle.isEmpty { return (0, s) }
            let hay = fold(s.label)
            if hay.hasPrefix(needle) { return (0, s) }
            return hay.contains(needle) ? (1, s) : nil
        }
        return ranked.sorted { a, b in
            if a.0 != b.0 { return a.0 < b.0 }
            if a.1.count != b.1.count { return a.1.count > b.1.count }
            if a.1.lastUsed != b.1.lastUsed {
                guard let x = a.1.lastUsed else { return false }
                guard let y = b.1.lastUsed else { return true }
                return x > y
            }
            return a.1.label < b.1.label
        }.prefix(max(0, limit)).map(\.1)
    }

    /// Een bestaande omschrijving die bijna gelijk is aan de getypte tekst ("Bedoel je ‘Zakgeld’?"), of nil.
    /// Geeft nil als de tekst zelf al bestaat. Bij meer kandidaten wint de meest gebruikte.
    public static func similar(_ text: String, in labels: [LabelSuggestion]) -> LabelSuggestion? {
        let key = Insight.normalizedLabel(text)
        guard !key.isEmpty, !labels.contains(where: { $0.id == key }) else { return nil }
        let typed = Prepared(text)
        return labels.filter { isNearDuplicate(typed, Prepared($0.label)) }
            .max { ($0.count, $1.label) < ($1.count, $0.label) }
    }

    /// Twee omschrijvingen zijn bijna gelijk (maar niet gelijk na normalisatie) als:
    /// - ze alleen verschillen in spaties, leestekens of accenten; of
    /// - ze evenveel woorden hebben en precies één woord verschilt, en dat woord is enkelvoud/meervoud
    ///   (-s, -en) of een tikfout: bewerkingsafstand 1 bij woorden t/m 6 letters, 2 bij langere.
    /// Een verschil in een cijfer, in een heel woord of in een woord korter dan 4 letters telt als anders.
    public static func isNearDuplicate(_ a: String, _ b: String) -> Bool {
        isNearDuplicate(Prepared(a), Prepared(b))
    }

    // MARK: Intern

    /// Kleine letters, zonder accenten, enkele spaties.
    static func fold(_ text: String) -> String {
        Insight.cleanLabel(text).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    struct Prepared {
        let key: String
        let words: [[Character]]
        let squashed: String

        init(_ text: String) {
            key = Insight.normalizedLabel(text)
            words = LabelMatcher.fold(text).split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(Array.init)
            squashed = String(words.joined())
        }
    }

    static func isNearDuplicate(_ a: Prepared, _ b: Prepared) -> Bool {
        if a.key == b.key || a.squashed.isEmpty || b.squashed.isEmpty { return false }
        if a.squashed == b.squashed { return true }
        guard a.words.count == b.words.count else { return false }
        var differing: ([Character], [Character])?
        for (x, y) in zip(a.words, b.words) where x != y {
            if differing != nil { return false }
            differing = (x, y)
        }
        guard let (x, y) = differing else { return false }
        return nearWords(x, y)
    }

    static func nearWords(_ x: [Character], _ y: [Character]) -> Bool {
        if x.contains(where: \.isNumber) || y.contains(where: \.isNumber) { return false }
        let (short, long) = x.count <= y.count ? (x, y) : (y, x)
        if short.count >= 2, long == short + ["s"] || long == short + ["e", "n"] { return true }
        guard short.count >= 4 else { return false }
        let allowed = long.count <= 6 ? 1 : 2
        guard long.count - short.count <= allowed else { return false }
        return editDistance(x, y) <= allowed
    }

    /// Bewerkingsafstand waarbij twee verwisselde buurletters als één bewerking tellen.
    static func editDistance(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var d = [[Int]](repeating: [Int](repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in 0...a.count { d[i][0] = i }
        for j in 0...b.count { d[0][j] = j }
        for i in 1...a.count {
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                d[i][j] = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + cost)
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] {
                    d[i][j] = min(d[i][j], d[i - 2][j - 2] + 1)
                }
            }
        }
        return d[a.count][b.count]
    }
}

// MARK: - Functies

extension Insight {
    /// Alle bestaande omschrijvingen van boekingen, plus de `entryLabel` van regels, elk één keer
    /// (hoofdletters en extra spaties maken geen verschil), meest gebruikte eerst.
    /// - `accountKind`: alleen boekingen op dat soort rekening (regels zonder rekening tellen altijd mee).
    /// - `since`: alleen boekingen vanaf die dag (regels tellen dan niet mee).
    /// Twee GROUP BY-queries; de lijst is te bewaren en te doorzoeken met `LabelMatcher`.
    public static func allLabels(_ db: Database, accountKind: AccountKind? = nil, since: Day? = nil) throws -> [LabelSuggestion] {
        var clause = "trim(e.label) <> ''"
        var args: [(any DatabaseValueConvertible)?] = []
        if let accountKind { clause += " AND a.kind = ?"; args.append(accountKind) }
        if let since { clause += " AND e.day >= ?"; args.append(since) }

        struct Group {
            var spellings: [String: Int] = [:]
            var count = 0
            var lastUsed: Day?
            var items: [String: Int] = [:]
            var tags: [Int64: Int] = [:]
            var ruleItem: String?
            var ruleTags: [Int64] = []
        }
        var groups: [String: Group] = [:]
        for r in try Row.fetchAll(db, sql: """
            SELECT e.label, i.label AS itemLabel, COUNT(*) AS c, MAX(e.day) AS last
            FROM entry e JOIN account a ON a.id = e.accountId LEFT JOIN budgetItem i ON i.id = e.budgetItemId
            WHERE \(clause) GROUP BY e.label, i.label
            """, arguments: StatementArguments(args)) {
            let clean = cleanLabel(r["label"]), n: Int = r["c"], last: Day? = r["last"]
            var g = groups[clean.lowercased()] ?? Group()
            g.spellings[clean, default: 0] += n
            g.count += n
            if let last, g.lastUsed.map({ last > $0 }) ?? true { g.lastUsed = last }
            if let item: String = r["itemLabel"] { g.items[item, default: 0] += n }
            groups[clean.lowercased()] = g
        }
        for r in try Row.fetchAll(db, sql: """
            SELECT e.label, et.tagId, COUNT(*) AS c
            FROM entry e JOIN account a ON a.id = e.accountId JOIN entryTag et ON et.entryId = e.id
            WHERE \(clause) GROUP BY e.label, et.tagId
            """, arguments: StatementArguments(args)) {
            groups[normalizedLabel(r["label"])]?.tags[r["tagId"], default: 0] += r["c"] as Int
        }
        if since == nil {
            var ruleSQL = "SELECT r.entryLabel, r.targetItemLabel, r.tagIds FROM rule r WHERE trim(COALESCE(r.entryLabel, '')) <> ''"
            var ruleArgs: [(any DatabaseValueConvertible)?] = []
            if let accountKind {
                ruleSQL += " AND (r.accountId IS NULL OR r.accountId IN (SELECT id FROM account WHERE kind = ?))"
                ruleArgs.append(accountKind)
            }
            for r in try Row.fetchAll(db, sql: ruleSQL, arguments: StatementArguments(ruleArgs)) {
                let clean = cleanLabel(r["entryLabel"]), key = clean.lowercased()
                guard groups[key] == nil else { continue }
                var g = Group()
                g.spellings[clean] = 0
                g.ruleItem = r["targetItemLabel"]
                g.ruleTags = (r["tagIds"] as String).split(separator: ",").compactMap { Int64($0) }
                groups[key] = g
            }
        }
        let tags = Dictionary(uniqueKeysWithValues: try Row.fetchAll(db, sql: "SELECT id, name, color, sortOrder FROM tag ORDER BY sortOrder, name")
            .enumerated().map { ($1["id"] as Int64, ($0, TagRef(id: $1["id"], name: $1["name"], color: $1["color"]))) })

        return groups.map { key, g -> LabelSuggestion in
            let label = g.spellings.sorted { ($1.value, $0.key) < ($0.value, $1.key) }.first?.key ?? key
            let item = g.count == 0 ? g.ruleItem : g.items.first { $0.value * 2 > g.count }?.key
            let tagIds = g.count == 0 ? g.ruleTags : g.tags.filter { $0.value * 2 > g.count }.map(\.key)
            return LabelSuggestion(id: key, label: label, count: g.count, lastUsed: g.lastUsed, itemLabel: item,
                                   tags: tagIds.compactMap { tags[$0] }.sorted { $0.0 < $1.0 }.map(\.1))
        }
        .sorted { a, b in
            if a.count != b.count { return a.count > b.count }
            if a.lastUsed != b.lastUsed {
                guard let x = a.lastUsed else { return false }
                guard let y = b.lastUsed else { return true }
                return x > y
            }
            return a.label < b.label
        }
    }

    /// Suggesties bij het typen van een omschrijving: begint-met vóór bevat, dan op aantal keer gebruikt, dan op
    /// laatst gebruikt. Lege tekst geeft de meest gebruikte omschrijvingen van de laatste 12 maanden vóór `today`.
    public static func labelSuggestions(_ db: Database, matching text: String, accountKind: AccountKind? = nil,
                                        limit: Int = 8, today: Day) throws -> [LabelSuggestion] {
        if LabelMatcher.fold(text).isEmpty {
            let since = Day(year: today.year - 1, month: today.month, day: min(today.day, 28)) ?? today.adding(days: -365)
            return Array(try allLabels(db, accountKind: accountKind, since: since).prefix(max(0, limit)))
        }
        return LabelMatcher.suggest(text, from: try allLabels(db, accountKind: accountKind), limit: limit)
    }

    /// Groepen bestaande omschrijvingen die bijna gelijk zijn (zie `LabelMatcher.isNearDuplicate`), voor het
    /// scherm "Omschrijvingen samenvoegen". Grootste groep (meeste boekingen) eerst; binnen een groep de meest
    /// gebruikte schrijfwijze eerst.
    public static func similarLabelGroups(_ db: Database, accountKind: AccountKind? = nil) throws -> [[LabelSuggestion]] {
        let labels = try allLabels(db, accountKind: accountKind)
        let prepared = labels.map { LabelMatcher.Prepared($0.label) }
        var parent = Array(labels.indices)
        func root(_ i: Int) -> Int {
            var i = i
            while parent[i] != i { parent[i] = parent[parent[i]]; i = parent[i] }
            return i
        }
        // Alleen paren met evenveel woorden of dezelfde tekst zonder spaties en leestekens kunnen bijna gelijk zijn.
        var bySquash: [String: [Int]] = [:], byWordCount: [Int: [Int]] = [:]
        for i in labels.indices {
            bySquash[prepared[i].squashed, default: []].append(i)
            byWordCount[prepared[i].words.count, default: []].append(i)
        }
        for bucket in Array(bySquash.values) + Array(byWordCount.values) where bucket.count > 1 {
            for x in 0..<bucket.count {
                for y in (x + 1)..<bucket.count where LabelMatcher.isNearDuplicate(prepared[bucket[x]], prepared[bucket[y]]) {
                    let (a, b) = (root(bucket[x]), root(bucket[y]))
                    if a != b { parent[max(a, b)] = min(a, b) }
                }
            }
        }
        // `labels` staat al op meest gebruikt, dus elke groep ook.
        let groups = Dictionary(grouping: labels.indices, by: root).values.filter { $0.count > 1 }
            .map { $0.sorted().map { labels[$0] } }
        return groups.sorted { a, b in
            let (x, y) = (a.map(\.count).reduce(0, +), b.map(\.count).reduce(0, +))
            return x != y ? x > y : a[0].label < b[0].label
        }
    }
}
