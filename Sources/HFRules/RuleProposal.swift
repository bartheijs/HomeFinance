import Foundation
import GRDB
import HFCore

// Regels alleen met toestemming (6i): de app leert niet meer stil van een boeking. Nakijken toont een concept
// ("Onthoud als regel" of "Regel bijwerken met deze keuze?") en bewaart het pas als de gebruiker dat aanvinkt.

/// Wat de regels met een keuze zouden doen. Schrijft niets.
public struct RuleProposal: Equatable, Sendable {
    /// De regel die het voorstel deed; nil als geen regel deze transactie herkende.
    public var proposingRule: Rule?
    /// De keuze is gelijk aan wat die regel voor deze transactie voorstelt.
    public var matchesProposal: Bool
    /// Het concept: bij een voorstellende regel die regel met deze keuze (zelfde id), anders een nieuwe regel
    /// (id nil). Nil als er geen regel te maken valt (geen tegenpartij en geen bruikbaar trefwoord).
    public var draft: Rule?

    /// Het concept werkt een bestaande regel bij (in plaats van een nieuwe te maken).
    public var isUpdate: Bool { draft?.id != nil }
    /// Moet Nakijken de keuze aanbieden? Niet als de keuze gelijk is aan het voorstel of als er niets te maken valt.
    public var offersChoice: Bool { draft != nil && !(proposingRule != nil && matchesProposal) }
}

extension RuleEngine {

    /// Het regelconcept bij een keuze. Kiest de gebruiker iets anders dan de voorstellende regel, dan is het
    /// concept die regel met de nieuwe keuze (voorwaarden blijven). Zonder voorstellende regel is het een nieuwe
    /// regel voor de tegenpartij (IBAN, anders naam, anders een trefwoord uit een herkenbare omschrijving),
    /// met een bedrag als voorwaarde als het doel een vaste post is en tegenpartij en bedrag al eerder voorkwamen.
    public static func ruleProposal(for correction: Correction, _ db: Database) throws -> RuleProposal {
        let tx = correction.bankTransaction
        let matcher = try RuleMatcher(db)
        let suggestion = matcher.suggest(for: tx)
        if let winner = matcher.bestRule(for: tx)?.rule {
            let same = Self.matches(correction, winner, suggestedLabel: suggestion.label)
            return RuleProposal(proposingRule: winner, matchesProposal: same,
                                draft: same ? winner : applyChoice(correction, to: winner))
        }
        guard let party = Party(tx) else { return RuleProposal(proposingRule: nil, matchesProposal: false, draft: nil) }

        let itemLabel = RuleMatcher.filled(correction.itemLabel)
        var amount: Money?
        if itemLabel != nil, party.isCounterparty {
            let sameAmount = try BankTransaction.filter(Column("amount") == tx.amount).fetchAll(db)
            let others = sameAmount.filter { $0.id == nil || $0.id != tx.id }.filter(party.matches).count
            if others + 1 >= 2 { amount = tx.amount }
        }
        let defaultLabel = LabelCleaner.cleanLabel(counterparty: tx.counterpartyName, description: tx.descriptionText)
        var rule = party.newRule(name: defaultLabel.isEmpty ? "Nieuwe regel" : defaultLabel)
        rule.amount = amount
        rule.priority = ((matcher.rules.map(\.priority).max() ?? 0) / 10 + 1) * 10
        rule = applyChoice(correction, to: rule)
        return RuleProposal(proposingRule: nil, matchesProposal: false, draft: rule)
    }

    /// Zet de keuze (post, pot, verrekenen en de richting daarvan, omschrijving, tags) in een regel.
    /// De voorwaarden, naam en volgorde blijven. `correction.entryLabel == nil` betekent "de voorgestelde
    /// omschrijving": de omschrijving van de regel blijft dan zoals hij was. Puur rekenwerk.
    public static func applyChoice(_ correction: Correction, to rule: Rule) -> Rule {
        var r = rule
        r.targetItemLabel = RuleMatcher.filled(correction.itemLabel)
        // Omschrijving (6b): geen gekozen omschrijving = het voorstel overgenomen, dus wat de regel al had blijft.
        // Een gekozen omschrijving gelijk aan wat de app zonder regel voorstelt (de eigen tekst van een
        // overboeking, anders de tegenpartij) wordt niet vastgelegd, zodat elke transactie haar eigen tekst
        // houdt. Al het andere (ook bewust de naam van de tegenpartij bij een overboeking) wel.
        if let chosen = RuleMatcher.filled(correction.entryLabel) {
            let own = LabelCleaner.suggestedLabel(for: correction.bankTransaction)
            r.entryLabel = TextNormalizer.normalize(chosen) == TextNormalizer.normalize(own) ? nil : chosen
        }
        r.tagIdList = correction.tagIds
        learnReimburse(into: &r, from: correction)
        return r
    }

    /// Is de keuze gelijk aan wat deze regel voor déze transactie voorstelt (in de andere richting dan waarin
    /// verrekenen gekozen is: zonder verrekenen en zonder pot)?
    static func matches(_ correction: Correction, _ winner: Rule, suggestedLabel: String) -> Bool {
        var rule = winner
        let tx = correction.bankTransaction
        if !rule.reimburseApplies(to: tx.amount) { rule.reimburse = false; rule.targetPotId = nil }
        let chosenLabel = RuleMatcher.filled(correction.entryLabel)
        return TextNormalizer.normalize(rule.targetItemLabel ?? "")
                == TextNormalizer.normalize(RuleMatcher.filled(correction.itemLabel) ?? "")
            && rule.targetPotId == correction.potId
            && Set(rule.tagIdList) == Set(correction.tagIds)
            && rule.reimburse == correction.reimburse
            && (chosenLabel == nil || TextNormalizer.normalize(chosenLabel!) == TextNormalizer.normalize(suggestedLabel))
    }

    /// Na het boeken. Zonder `remember` verandert er inhoudelijk niets: een regel die precies deze keuze
    /// voorstelde telt als gebruikt (`hitCount`, `lastUsed`); een afwijkende keuze is een uitzondering.
    /// Met `remember` (het concept, eventueel aangepast in de editor) wordt die regel bewaard zoals hij is:
    /// nieuw (`created`) of bijgewerkt (`updated`, met de oude regel in `previousRule` voor ongedaan maken).
    public static func afterBooking(_ correction: Correction, remember: Rule?, _ db: Database,
                                    now: Date = Date()) throws -> LearnResult {
        if var rule = remember {
            let previous = try rule.id.flatMap { try Rule.fetchOne(db, key: $0) }
            try save(&rule, db)
            let summary = try Self.summary(of: rule, db)
            return LearnResult(outcome: previous == nil ? .created : .updated, rule: rule, previousRule: previous,
                               usedRuleId: nil,
                               message: (previous == nil ? "Regel bewaard: " : "Regel bijgewerkt: ") + summary)
        }
        let matcher = try RuleMatcher(db)
        let tx = correction.bankTransaction
        guard let winner = matcher.bestRule(for: tx)?.rule, let id = winner.id else {
            return LearnResult(outcome: .unchanged, rule: nil, previousRule: nil, usedRuleId: nil,
                               message: "Geen regel gemaakt.")
        }
        guard matches(correction, winner, suggestedLabel: matcher.suggest(for: tx).label) else {
            return LearnResult(outcome: .unchanged, rule: winner, previousRule: nil, usedRuleId: nil,
                               message: "Regel '\(winner.name)' blijft ongewijzigd; deze boeking is een uitzondering.")
        }
        try recordUse(ruleId: id, db, at: now)
        return LearnResult(outcome: .unchanged, rule: try Rule.fetchOne(db, key: id) ?? winner, previousRule: nil,
                           usedRuleId: id, message: "Volgens regel '\(winner.name)'.")
    }

    /// Eén zin over wat een regel doet, voor Nakijken, bv.
    /// "Voortaan bij Stichting Voorbeeld: post Divers, verrekenen met pot Vakantie bij geld eruit, omschrijving 'Gift'".
    public static func summary(of rule: Rule, _ db: Database) throws -> String {
        let potName = try rule.targetPotId.flatMap {
            try String.fetchOne(db, sql: "SELECT name FROM pot WHERE id = ?", arguments: [$0])
        }
        let tagNames = try rule.tagIdList.compactMap {
            try String.fetchOne(db, sql: "SELECT name FROM tag WHERE id = ?", arguments: [$0])
        }
        return summary(of: rule, potName: potName, tagNames: tagNames)
    }

    /// Zoals `summary(of:_:)`, met de namen van pot en tags al opgezocht. Puur rekenwerk.
    public static func summary(of rule: Rule, potName: String?, tagNames: [String]) -> String {
        let name = RuleMatcher.filled(rule.counterpartyContains)
        let iban = RuleMatcher.filled(rule.counterpartyIban).map(TextNormalizer.normalizeIban)
        let keyword = RuleMatcher.filled(rule.descriptionContains)

        var who: [String] = []
        if let name { who.append(name) }
        if let iban { who.append(name == nil ? "\(TextNormalizer.collapse(rule.name)) (\(iban))" : "(\(iban))") }
        if let keyword { who.append(who.isEmpty ? "omschrijving met '\(keyword)'" : "met '\(keyword)' in de omschrijving") }
        if let amount = rule.amount { who.append(who.isEmpty ? "bedrag \(amount.formatted())" : "bij \(amount.formatted())") }
        let subject = who.isEmpty ? "deze regel" : who.joined(separator: " ")

        var parts: [String] = []
        let pot = potName ?? rule.targetPotId.map { "pot \($0)" }
        if let item = RuleMatcher.filled(rule.targetItemLabel) {
            parts.append("post \(item)")
        } else if !rule.reimburse, let pot {
            parts.append("pot \(pot)")
        } else {
            parts.append("post Divers")
        }
        if rule.reimburse {
            let direction: String = switch rule.reimburseDirection {
            case .incoming: " bij geld erin"
            case .outgoing: " bij geld eruit"
            case .both: ""
            }
            parts.append("verrekenen met " + (pot.map { "pot \($0)" } ?? "spaar") + direction)
        }
        if let label = RuleMatcher.filled(rule.entryLabel) { parts.append("omschrijving '\(label)'") }
        if !tagNames.isEmpty {
            parts.append((tagNames.count == 1 ? "tag " : "tags ") + tagNames.joined(separator: ", "))
        }
        return "Voortaan bij \(subject): " + parts.joined(separator: ", ")
    }
}
