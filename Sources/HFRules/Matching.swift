import Foundation
import GRDB
import HFCore

/// Waarop een regel een transactie herkende. Bepaalt de zekerheid.
public enum MatchBasis: String, Sendable, Equatable {
    /// Tegenpartij (naam of IBAN) en bedrag kloppen → `hoog`.
    case counterpartyAndAmount
    /// Tegenpartij klopt, de regel heeft geen bedrag → `midden`.
    case counterparty
    /// Tegenpartij klopt, het bedrag van de regel wijkt af → `midden`.
    case counterpartyAmountDiffers
    /// Trefwoord in de omschrijving (zonder tegenpartij) → `midden`.
    case keyword
    /// Alleen het bedrag → `laag`.
    case amountOnly

    public var confidence: Confidence {
        switch self {
        case .counterpartyAndAmount: return .hoog
        case .counterparty, .counterpartyAmountDiffers, .keyword: return .midden
        case .amountOnly: return .laag
        }
    }
}

/// Uitkomst van één regel tegen één transactie.
public struct RuleMatch: Equatable, Sendable {
    public var basis: MatchBasis
    /// Aantal voorwaarden van de regel dat klopt (meer = specifieker).
    public var specificity: Int
    public var confidence: Confidence { basis.confidence }
    public var amountDiffers: Bool { basis == .counterpartyAmountDiffers }
}

/// Voorstel voor het boeken van één banktransactie. Dit is alleen een voorstel; boeken doet HFBudget.
public struct Suggestion: Equatable, Sendable {
    public var bankTransactionId: Int64?
    public var confidence: Confidence
    /// De regel die het voorstel deed; nil bij `geen`.
    public var ruleId: Int64?
    public var ruleName: String?
    /// Label van de vaste post volgens de regel; nil = divers.
    public var targetItemLabel: String?
    /// De vaste post met dat label in het jaar van de transactie; nil = divers of niet gevonden (zie `warnings`).
    public var budgetItemId: Int64?
    public var potId: Int64?
    /// Leesbare omschrijving voor de boeking.
    public var label: String
    public var tagIds: [Int64]
    public var reimburse: Bool
    /// De tegenpartij klopt, maar de regel verwacht een ander bedrag (`expectedAmount`).
    public var amountDiffers: Bool
    public var expectedAmount: Money?
    /// Korte uitleg voor de gebruiker, bv. "Regel 'Energie': tegenpartij en bedrag".
    public var reason: String
    /// Meldingen voor de gebruiker, bv. dat het jaar of de post niet bestaat.
    public var warnings: [String]

    public init(bankTransactionId: Int64? = nil, confidence: Confidence = .geen, ruleId: Int64? = nil,
                ruleName: String? = nil, targetItemLabel: String? = nil, budgetItemId: Int64? = nil,
                potId: Int64? = nil, label: String = "", tagIds: [Int64] = [], reimburse: Bool = false,
                amountDiffers: Bool = false, expectedAmount: Money? = nil, reason: String = "",
                warnings: [String] = []) {
        self.bankTransactionId = bankTransactionId; self.confidence = confidence; self.ruleId = ruleId
        self.ruleName = ruleName; self.targetItemLabel = targetItemLabel; self.budgetItemId = budgetItemId
        self.potId = potId; self.label = label; self.tagIds = tagIds; self.reimburse = reimburse
        self.amountDiffers = amountDiffers; self.expectedAmount = expectedAmount
        self.reason = reason; self.warnings = warnings
    }
}

/// Past regels toe op banktransacties. Laadt regels, jaren en posten één keer; daarna is `suggest`
/// puur rekenwerk zonder database.
public struct RuleMatcher: Sendable {
    /// Alle regels (ook uitgeschakelde; die matchen nooit), op `priority` en id.
    public let rules: [Rule]
    private let years: Set<Int>
    /// Per jaartal de posten: genormaliseerd label → (id, label).
    private let items: [Int: [String: Int64]]

    /// Laadt regels, jaren en posten uit de database.
    public init(_ db: Database) throws {
        try self.init(rules: Rule.fetchAll(db), budgetYears: BudgetYear.fetchAll(db),
                      budgetItems: BudgetItem.order(Column("sortOrder"), Column("id")).fetchAll(db))
    }

    /// Voor tests en previews: zonder database.
    public init(rules: [Rule], budgetYears: [BudgetYear] = [], budgetItems: [BudgetItem] = []) {
        self.rules = rules.sorted { ($0.priority, $0.id ?? .max) < ($1.priority, $1.id ?? .max) }
        var yearById: [Int64: Int] = [:]
        for y in budgetYears { if let id = y.id { yearById[id] = y.year } }
        self.years = Set(budgetYears.map(\.year))
        var items: [Int: [String: Int64]] = [:]
        for item in budgetItems {
            guard let id = item.id, let year = yearById[item.yearId] else { continue }
            let key = TextNormalizer.normalize(item.label)
            // Bij dubbele labels wint de eerste (laagste sortOrder).
            if items[year]?[key] == nil { items[year, default: [:]][key] = id }
        }
        self.items = items
    }

    // MARK: Eén regel

    /// Herkent deze regel de transactie? nil = nee. Uitgeschakelde regels en regels zonder voorwaarden
    /// matchen nooit (`ignoreEnabled` negeert alleen het uitgeschakeld zijn, voor een voorbeeld in de editor).
    public static func match(_ rule: Rule, _ tx: BankTransaction, ignoreEnabled: Bool = false) -> RuleMatch? {
        guard ignoreEnabled || rule.enabled else { return nil }
        if let account = rule.accountId, account != tx.accountId { return nil }

        let party = filled(rule.counterpartyContains).map(TextNormalizer.normalize)
        let iban = filled(rule.counterpartyIban).map(TextNormalizer.normalizeIban)
        let keyword = filled(rule.descriptionContains).map(TextNormalizer.normalize)
        guard party != nil || iban != nil || keyword != nil || rule.amount != nil else { return nil }

        if let party, !TextNormalizer.normalize(tx.counterpartyName).contains(party) { return nil }
        if let iban, TextNormalizer.normalizeIban(tx.counterpartyIban) != iban { return nil }
        if let keyword, !TextNormalizer.normalize(tx.descriptionText).contains(keyword) { return nil }

        let hasParty = party != nil || iban != nil
        var specificity = [party, iban, keyword].compactMap { $0 }.count + (rule.accountId == nil ? 0 : 1)
        guard let amount = rule.amount else {
            return RuleMatch(basis: hasParty ? .counterparty : .keyword, specificity: specificity)
        }
        if amount == tx.amount {
            specificity += 1
            let basis: MatchBasis = hasParty ? .counterpartyAndAmount : (keyword != nil ? .keyword : .amountOnly)
            return RuleMatch(basis: basis, specificity: specificity)
        }
        // Tegenpartij klopt, bedrag wijkt af: toch voorstellen, met zekerheid midden.
        return hasParty ? RuleMatch(basis: .counterpartyAmountDiffers, specificity: specificity) : nil
    }

    // MARK: Beste regel

    /// De winnende regel: hoogste zekerheid, dan laagste `priority`, dan een volledige match vóór
    /// "bedrag wijkt af", dan de meeste kloppende voorwaarden, dan het laagste id.
    public func bestRule(for tx: BankTransaction) -> (rule: Rule, match: RuleMatch)? {
        var best: (rule: Rule, match: RuleMatch)?
        for rule in rules {
            guard let match = Self.match(rule, tx) else { continue }
            if let current = best, !Self.isBetter((rule, match), than: current) { continue }
            best = (rule, match)
        }
        return best
    }

    private static func rank(_ c: Confidence) -> Int {
        switch c { case .hoog: return 0; case .midden: return 1; case .laag: return 2; case .geen: return 3 }
    }

    private static func isBetter(_ a: (rule: Rule, match: RuleMatch), than b: (rule: Rule, match: RuleMatch)) -> Bool {
        let ka = (rank(a.match.confidence), a.rule.priority, a.match.amountDiffers ? 1 : 0,
                  -a.match.specificity, a.rule.id ?? .max)
        let kb = (rank(b.match.confidence), b.rule.priority, b.match.amountDiffers ? 1 : 0,
                  -b.match.specificity, b.rule.id ?? .max)
        return ka < kb
    }

    // MARK: Voorstel

    /// Voorstel voor deze transactie. Zonder passende regel: zekerheid `geen` met alleen een opgeschoond label.
    public func suggest(for tx: BankTransaction) -> Suggestion {
        let cleaned = LabelCleaner.cleanLabel(counterparty: tx.counterpartyName, description: tx.descriptionText)
        let fallbackLabel = cleaned.isEmpty ? "Onbekend" : cleaned
        guard let (rule, match) = bestRule(for: tx) else {
            return Suggestion(bankTransactionId: tx.id, label: fallbackLabel, reason: "Geen regel gevonden")
        }

        var s = Suggestion(bankTransactionId: tx.id, confidence: match.confidence, ruleId: rule.id,
                           ruleName: rule.name)
        s.targetItemLabel = Self.filled(rule.targetItemLabel)
        s.potId = rule.targetPotId
        s.label = Self.filled(rule.entryLabel) ?? fallbackLabel
        s.tagIds = rule.tagIdList
        s.reimburse = rule.reimburse
        s.amountDiffers = match.amountDiffers
        s.expectedAmount = match.amountDiffers ? rule.amount : nil

        let what: String
        switch match.basis {
        case .counterpartyAndAmount: what = "tegenpartij en bedrag"
        case .counterparty: what = "tegenpartij"
        case .counterpartyAmountDiffers:
            what = "tegenpartij klopt, bedrag wijkt af (verwacht \(rule.amount?.formatted() ?? "?"))"
        case .keyword: what = "trefwoord in omschrijving"
        case .amountOnly: what = "alleen bedrag"
        }
        s.reason = "Regel '\(rule.name)': \(what)"

        // Verrekenen met spaar (en de pot daarvan) alleen in de richting waarin de gebruiker het koos.
        if !rule.reimburseApplies(to: tx.amount) {
            s.reimburse = false
            s.potId = nil
            s.confidence = .laag
            let chosen = rule.reimburseDirection == .incoming ? "bij geld erin" : "bij geld eruit"
            let now = tx.amount.cents > 0 ? "binnenkomt" : "eruit gaat"
            s.warnings.append("Regel '\(rule.name)' verrekent met spaar alleen \(chosen); hier gaat het om geld dat "
                              + "\(now), dus zonder verrekenen en zonder pot voorgesteld. Kijk na of dat klopt.")
        }

        if let label = s.targetItemLabel {
            let year = tx.day.year
            if !years.contains(year) {
                s.warnings.append("Het jaar \(year) bestaat nog niet; de post '\(label)' kan niet gekoppeld worden.")
            } else if let id = items[year]?[TextNormalizer.normalize(label)] {
                s.budgetItemId = id
            } else {
                s.warnings.append("De post '\(label)' bestaat niet in \(year).")
            }
        }
        return s
    }

    /// Niet-lege, getrimde tekst; anders nil.
    static func filled(_ text: String?) -> String? {
        guard let t = text.map(TextNormalizer.collapse), !t.isEmpty else { return nil }
        return t
    }
}
