import Foundation
import GRDB
import HFCore

/// Wat de gebruiker uiteindelijk koos voor een banktransactie.
public struct Correction: Equatable, Sendable {
    public var bankTransaction: BankTransaction
    /// Label van de gekozen vaste post; nil = divers.
    public var itemLabel: String?
    public var potId: Int64?
    /// De omschrijving die de gebruiker aan de boeking gaf; nil = het voorgestelde label.
    public var entryLabel: String?
    public var tagIds: [Int64]
    public var reimburse: Bool

    public init(bankTransaction: BankTransaction, itemLabel: String? = nil, potId: Int64? = nil,
                entryLabel: String? = nil, tagIds: [Int64] = [], reimburse: Bool = false) {
        self.bankTransaction = bankTransaction; self.itemLabel = itemLabel; self.potId = potId
        self.entryLabel = entryLabel; self.tagIds = tagIds; self.reimburse = reimburse
    }
}

public enum LearnOutcome: String, Sendable, Equatable {
    /// Er is een nieuwe geleerde regel gemaakt.
    case created
    /// De bestaande geleerde regel voor deze tegenpartij is aangepast.
    case updated
    /// Er is niets aan de regels veranderd (zie `message`).
    case unchanged
}

/// Wat `learn` deed, zodat het scherm "Regel geleerd: …" met ongedaan maken kan tonen.
public struct LearnResult: Equatable, Sendable {
    public var outcome: LearnOutcome
    /// De gemaakte, aangepaste of gebruikte regel; nil als er geen regel bij betrokken was.
    public var rule: Rule?
    /// De regel zoals hij was vóór de aanpassing (alleen bij `updated`); nodig voor ongedaan maken.
    public var previousRule: Rule?
    /// De regel waarvan het gebruik is geteld (alleen als de keuze gelijk was aan het voorstel).
    public var usedRuleId: Int64?
    /// Melding voor de gebruiker.
    public var message: String
}

extension RuleEngine {

    /// Leert van een correctie. Maakt een geleerde regel voor de tegenpartij (IBAN, anders naam, anders een
    /// trefwoord uit een herkenbare omschrijving) of past de bestaande geleerde regel aan.
    /// Handmatige regels worden nooit aangepast; een regel met alleen een bedrag wordt nooit geleerd.
    public static func learn(from correction: Correction, _ db: Database, now: Date = Date()) throws -> LearnResult {
        let tx = correction.bankTransaction
        let matcher = try RuleMatcher(db)
        let best = matcher.bestRule(for: tx)
        let suggestion = matcher.suggest(for: tx)

        let itemLabel = RuleMatcher.filled(correction.itemLabel)
        let chosenLabel = RuleMatcher.filled(correction.entryLabel)
        let sameAsProposal: Bool = {
            guard let rule = best?.rule else { return false }
            return TextNormalizer.normalize(rule.targetItemLabel ?? "") == TextNormalizer.normalize(itemLabel ?? "")
                && rule.targetPotId == correction.potId
                && Set(rule.tagIdList) == Set(correction.tagIds)
                && rule.reimburse == correction.reimburse
                && (chosenLabel == nil
                    || TextNormalizer.normalize(chosenLabel!) == TextNormalizer.normalize(suggestion.label))
        }()

        func onlyRecordUse(_ rule: Rule) throws -> LearnResult {
            var used = rule
            if let id = rule.id {
                try recordUse(ruleId: id, db, at: now)
                used = try Rule.fetchOne(db, key: id) ?? rule
            }
            return LearnResult(outcome: .unchanged, rule: used, previousRule: nil, usedRuleId: rule.id,
                               message: "De keuze is gelijk aan het voorstel van regel '\(rule.name)'; er is niets gewijzigd.")
        }

        // Voor wie leren we?
        guard let party = Party(tx) else {
            if sameAsProposal, let rule = best?.rule { return try onlyRecordUse(rule) }
            return LearnResult(outcome: .unchanged, rule: nil, previousRule: nil, usedRuleId: nil,
                               message: "Niets geleerd: de transactie heeft geen tegenpartij en geen bruikbaar trefwoord in de omschrijving.")
        }

        let learned = try Rule.filter(Column("origin") == RuleOrigin.geleerd).order(Column("id")).fetchAll(db)
        let existing = learned.first { party.owns($0) }

        // Bedrag als voorwaarde: alleen bij een vaste post en als tegenpartij + bedrag minstens twee keer gezien is.
        var desiredAmount: Money?
        if itemLabel != nil, party.isCounterparty {
            let sameAmount = try BankTransaction.filter(Column("amount") == tx.amount).fetchAll(db)
            let others = sameAmount.filter { $0.id == nil || $0.id != tx.id }.filter(party.matches).count
            if others + 1 >= 2 { desiredAmount = tx.amount }
        }

        if sameAsProposal, let rule = best?.rule {
            let amountWouldChange = rule.id == existing?.id && rule.amount != desiredAmount
            if !amountWouldChange { return try onlyRecordUse(rule) }
        }

        if let existing, !existing.enabled {
            return LearnResult(outcome: .unchanged, rule: existing, previousRule: nil, usedRuleId: nil,
                               message: "De geleerde regel '\(existing.name)' staat uit; er is niets gewijzigd.")
        }

        let defaultLabel = LabelCleaner.cleanLabel(counterparty: tx.counterpartyName, description: tx.descriptionText)
        var rule = existing ?? party.newRule(name: defaultLabel.isEmpty ? "Geleerde regel" : defaultLabel)
        rule.targetItemLabel = itemLabel
        rule.targetPotId = correction.potId
        rule.entryLabel = chosenLabel.flatMap {
            TextNormalizer.normalize($0) == TextNormalizer.normalize(defaultLabel) ? nil : $0
        }
        rule.tagIdList = correction.tagIds
        rule.reimburse = correction.reimburse
        rule.amount = desiredAmount
        // Een andere regel won tot nu toe: zet de geleerde regel ervoor, anders heeft leren geen effect.
        if let winner = best?.rule, winner.id != rule.id, winner.priority <= rule.priority {
            rule.priority = winner.priority - 1
        }

        if let existing, existing == rule {
            return LearnResult(outcome: .unchanged, rule: existing, previousRule: nil, usedRuleId: nil,
                               message: "De geleerde regel '\(existing.name)' had deze keuze al.")
        }
        try rule.save(db)

        var target = "divers"
        if let itemLabel {
            target = "post '\(itemLabel)'"
        } else if let potId = correction.potId {
            let name = try String.fetchOne(db, sql: "SELECT name FROM pot WHERE id = ?", arguments: [potId])
            target = "pot '\(name ?? String(potId))'"
        }
        let amountText = rule.amount.map { " (bedrag \($0.formatted()))" } ?? ""
        let verb = existing == nil ? "Regel geleerd" : "Regel bijgewerkt"
        return LearnResult(outcome: existing == nil ? .created : .updated, rule: rule, previousRule: existing,
                           usedRuleId: nil, message: "\(verb): '\(rule.name)' → \(target)\(amountText)")
    }

    /// Maakt het leren ongedaan: een gemaakte regel wordt verwijderd, een aangepaste regel teruggezet.
    /// Bij `unchanged` gebeurt er niets.
    public static func undoLearning(_ result: LearnResult, _ db: Database) throws {
        switch result.outcome {
        case .created:
            if let id = result.rule?.id { try Rule.deleteOne(db, key: id) }
        case .updated:
            if let previous = result.previousRule { try previous.update(db) }
        case .unchanged:
            break
        }
    }
}

/// De tegenpartij waarvoor een regel geleerd wordt.
enum Party {
    case iban(String, name: String)
    case name(String, normalized: String)
    /// Geen naam en geen IBAN: een trefwoord uit een herkenbare omschrijving (bv. een pinbetaling).
    case keyword(String, normalized: String)

    init?(_ tx: BankTransaction) {
        let iban = TextNormalizer.normalizeIban(tx.counterpartyIban)
        let name = TextNormalizer.collapse(tx.counterpartyName)
        if !iban.isEmpty {
            self = .iban(iban, name: name)
        } else if !name.isEmpty {
            self = .name(name, normalized: TextNormalizer.normalize(name))
        } else {
            let derived = LabelCleaner.derive(fromDescription: tx.descriptionText)
            let normalized = TextNormalizer.normalize(derived.text)
            // Onderscheidend: uit een herkenbaar veld, met minstens één woord van vier letters of meer.
            guard derived.structured,
                  normalized.split(separator: " ").contains(where: { $0.filter(\.isLetter).count >= 4 })
            else { return nil }
            self = .keyword(derived.text, normalized: normalized)
        }
    }

    var isCounterparty: Bool {
        if case .keyword = self { return false }
        return true
    }

    /// Is dit de geleerde regel voor deze tegenpartij?
    func owns(_ rule: Rule) -> Bool {
        let ruleIban = RuleMatcher.filled(rule.counterpartyIban).map(TextNormalizer.normalizeIban)
        let ruleName = RuleMatcher.filled(rule.counterpartyContains).map(TextNormalizer.normalize)
        let ruleKeyword = RuleMatcher.filled(rule.descriptionContains).map(TextNormalizer.normalize)
        switch self {
        case .iban(let iban, _): return ruleIban == iban
        case .name(_, let normalized): return ruleIban == nil && ruleName == normalized
        case .keyword(_, let normalized): return ruleIban == nil && ruleName == nil && ruleKeyword == normalized
        }
    }

    /// Is deze transactie van dezelfde tegenpartij?
    func matches(_ tx: BankTransaction) -> Bool {
        switch self {
        case .iban(let iban, _): return TextNormalizer.normalizeIban(tx.counterpartyIban) == iban
        case .name(_, let normalized):
            return tx.counterpartyIban.allSatisfy(\.isWhitespace)
                && TextNormalizer.normalize(tx.counterpartyName) == normalized
        case .keyword(_, let normalized): return TextNormalizer.normalize(tx.descriptionText).contains(normalized)
        }
    }

    func newRule(name: String) -> Rule {
        var rule = Rule(name: name, origin: .geleerd)
        switch self {
        case .iban(let iban, _): rule.counterpartyIban = iban
        case .name(let raw, _): rule.counterpartyContains = raw
        case .keyword(let text, _): rule.descriptionContains = text
        }
        return rule
    }
}
