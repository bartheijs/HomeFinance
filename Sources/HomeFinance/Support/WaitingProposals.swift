import Foundation
import GRDB
import HFCore
import HFBudget
import HFRules
import HFInsight

// Eén bron voor de voorstellen bij wachtende banktransacties (UX-stap D1). Nakijken en Transacties lezen allebei
// hieruit, zodat ze dezelfde voorstellen en dezelfde aantallen "zeker / na te kijken" tonen. Dit is alleen lijm:
// herkennen doen HFBudget (overboeking met spaar, automatisch sparen, eigen overboekingen) en HFRules (regels),
// de indeling doet HFInsight (`Insight.waitingGroup`).

/// Alles wat de herkenning zegt over één wachtende banktransactie.
struct WaitingProposal: Equatable {
    let item: ReviewItem
    /// Het voorstel van de regels.
    let suggestion: Suggestion
    /// Opgeschoonde naam van de tegenpartij of omschrijving.
    let cleanLabel: String
    /// De banktransactie van een vastgelegde overboeking met spaar (gaat vóór alles).
    let settlement: SavingsTransferMatch?
    /// Herkend als automatisch sparen (gaat vóór de regels), ook als het een losse overboeking lijkt.
    let match: DistributionMatch?
    /// Eén kant van een overboeking tussen eigen rekeningen.
    let pair: TransferPair?
    /// De betaalkant van een overboeking naar een eigen rekening terwijl er nog tijdelijk geleend geld uitstaat:
    /// dit lijkt de terugboeking.
    let looksLikeLoanReturn: Bool
    /// Voorgeschoten tags waarvan deze bijschrijving de terugbetaling lijkt (exact eerst), D2.
    var depositCandidates: [SettlementService.DepositCandidate] = []
    /// De andere helft van een overboeking tussen eigen rekeningen (betaal ↔ spaar), ook als die als automatisch
    /// sparen herkend is of al geboekt is, D2.
    var otherHalf: WaitingOtherHalf?

    var id: Int64 { item.id }
    var transaction: BankTransaction { item.transaction }

    /// De omschrijving die wordt voorgesteld: die van de regel, anders de opgeschoonde naam.
    var proposedLabel: String {
        let s = suggestion.label
        if !s.isEmpty && s != "Onbekend" { return s }
        return cleanLabel.isEmpty ? "Onbekend" : cleanLabel
    }

    /// Standaard volgt een herkende storting de verdeling, behalve als het een losse overboeking lijkt.
    var followsDistributionByDefault: Bool { !(match?.looksSeparate ?? false) }

    /// De groep, met de keuze van de gebruiker tussen de vaste overboeking en één potje (nil = standaard), en
    /// eventueel een storting die de gebruiker koos uit meer kandidaten.
    func group(followsDistribution: Bool? = nil, chosenMatch: DistributionMatch? = nil) -> WaitingGroup {
        let m = settlement == nil ? (chosenMatch ?? match) : nil
        let follows: Bool = m.map { m in
            m.side == .destination && m.distribution != nil ? followsDistribution ?? !m.looksSeparate : true
        } ?? true
        return Insight.waitingGroup(WaitingSignals(
            isSavingsTransfer: settlement != nil,
            distribution: m.map { .init(isSingle: $0.distribution != nil, exactAmount: $0.exactAmount, followsDistribution: follows) },
            confidence: suggestion.confidence, amountDiffers: suggestion.amountDiffers,
            hasWarnings: !suggestion.warnings.isEmpty, isOwnTransfer: pair != nil))
    }
}

/// De andere helft van een eigen overboeking, om in het paneel te tonen.
struct WaitingOtherHalf: Equatable {
    let transaction: BankTransaction
    let accountName: String
    /// Die helft wacht nog (status nieuw); anders is hij al geboekt.
    var isWaiting: Bool { transaction.status == .nieuw }

    /// "De andere helft: + € 250,00 op Spaarrekening, 11 jun · wacht nog op een plek".
    var text: String {
        "De andere helft: \(transaction.amount.formatted(alwaysSign: true)) op \(accountName), \(transaction.day.short())"
            + (isWaiting ? " · wacht nog op een plek" : " · al geboekt")
    }
}

enum WaitingProposals {
    /// De wachtende banktransacties van één rekening met hun voorstel, in de volgorde van de wachtrij (datum, id).
    /// `pairs`: de eigen overboekingen waarvan een kant wacht, zonder die al als overboeking met spaar of
    /// automatisch sparen herkend zijn.
    static func load(_ db: Database, accountId: Int64, today: Day) throws
        -> (proposals: [WaitingProposal], pairs: [TransferPair]) {
        guard let account = try Account.fetchOne(db, key: accountId) else { return ([], []) }
        let queue = try Insight.reviewQueue(db, accountId: accountId)
        let suggestions = try RuleEngine.suggestAll(db, accountId: accountId)
        // Volgorde van herkennen: overboekingen met spaar, dan automatisch sparen, dan regels.
        let settlements = try SavingsTransferService.recognizeAll(db, accountId: accountId)
        let matches = try DistributionService.recognizeAll(db, accountId: accountId)
        let pairs = try TransferService.findTransferPairs(db).filter { pair in
            guard pair.from.accountId == accountId || pair.to.accountId == accountId,
                  pair.from.status == .nieuw || pair.to.status == .nieuw else { return false }
            for side in [pair.from, pair.to] where side.status == .nieuw {
                if try SavingsTransferService.recognize(db, bankTransaction: side) != nil { return false }
                if try DistributionService.recognize(db, bankTransaction: side) != nil { return false }
            }
            return true
        }
        let loanOutstanding = try Insight.temporaryLoanOutstanding(db, on: today)
        // Alle paren, ook die als automatisch sparen of overboeking met spaar herkend zijn: voor "de andere helft".
        let allPairs = try TransferService.findTransferPairs(db)
        let names = Dictionary(uniqueKeysWithValues: try Account.fetchAll(db).compactMap { a in a.id.map { ($0, a.name) } })
        let proposals = try queue.map { item in
            let tx = item.transaction
            let pair = pairs.first { $0.from.id == tx.id || $0.to.id == tx.id }
            let settlement = settlements[item.id]
            let other = allPairs.first { $0.from.id == tx.id || $0.to.id == tx.id }
                .map { $0.from.id == tx.id ? $0.to : $0.from }
            return WaitingProposal(
                item: item,
                suggestion: try suggestions[item.id] ?? RuleEngine.suggest(for: tx, db),
                cleanLabel: LabelCleaner.cleanLabel(counterparty: tx.counterpartyName, description: tx.descriptionText),
                settlement: settlement,
                match: settlement == nil ? matches[item.id] : nil,
                pair: pair,
                looksLikeLoanReturn: account.kind == .betaal && pair != nil && tx.amount.isNegative && loanOutstanding > .zero,
                depositCandidates: settlement == nil ? try SettlementService.depositCandidates(db, bankTransaction: tx) : [],
                otherHalf: other.map { WaitingOtherHalf(transaction: $0, accountName: names[$0.accountId] ?? "andere rekening") })
        }
        return (proposals, pairs)
    }
}
