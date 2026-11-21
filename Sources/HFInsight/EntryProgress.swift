import Foundation
import GRDB
import HFCore

/// Waar een boeking staat die nog iets tegoed heeft: uit een potje betaald (nog over te boeken met spaar) of
/// voorgeschoten bij een tag die verrekend wordt (nog terug te krijgen). Alleen weergave; rekent zoals het scherm
/// Verrekenen met spaar en de tagverrekening.
public struct EntryProgress: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// Verrekenen met spaar. `inPendingTransfer`: de boeking zit al in een vastgelegde, nog niet afgevinkte
        /// verrekening; het bedrag is dan dat van die verrekening.
        case toTransfer(potName: String?, direction: SavingsTransferDirection, inPendingTransfer: Bool)
        /// Voorgeschoten bij een tag die verrekend wordt.
        case toReceive(tagId: Int64, tagName: String)
    }

    public let kind: Kind
    /// Het openstaande bedrag zonder teken: netto over te boeken met spaar, of nog terug te krijgen voor de tag.
    public let amount: Money

    /// De voortgangsregel, bv. "Nog over te boeken: € 535,12 van spaar naar betaal" of
    /// "Nog terug te krijgen: € 144,42 (Tanken)".
    public var line: String {
        switch kind {
        case .toTransfer(_, let direction, _):
            switch direction {
            case .fromSavings: return "Nog over te boeken: \(amount.formatted()) van spaar naar betaal"
            case .toSavings: return "Nog over te boeken: \(amount.formatted()) van betaal naar spaar"
            case .none: return "Nog over te boeken: niets, alleen tussen potjes"
            }
        case .toReceive(_, let name):
            return "Nog terug te ontvangen: \(amount.formatted()) (\(name))"
        }
    }

    /// Korte uitleg onder de regel.
    public var explanation: String {
        switch kind {
        case .toTransfer(let pot, _, let pending):
            let from = pot.map { "Hoort bij potje \($0). " } ?? "Er is nog geen potje gekozen. "
            return from + (pending
                ? "Zit in een vastgelegde overboeking die nog niet is afgevinkt. Maak het bedrag over en vink hem af."
                : "Dit is het totaal van alle open boekingen: zet het in één overboeking recht en vink hem af.")
        case .toReceive(_, let name):
            return "Dit krijg je terug. Het bedrag is het totaal dat nog openstaat voor \(name)."
        }
    }
}

extension Insight {
    /// De voortgang van een boeking op een betaalrekening; nil als er niets openstaat (geen pot of tag, of al
    /// verrekend). Verrekenen met spaar gaat voor een tag.
    public static func entryProgress(_ db: Database, entryId: Int64, today: Day) throws -> EntryProgress? {
        guard let entry = try Entry.fetchOne(db, key: entryId),
              try Account.fetchOne(db, key: entry.accountId)?.kind == .betaal else { return nil }
        if entry.reimburse, !entry.amount.isZero {
            let potName = try entry.potId.flatMap { try Pot.fetchOne(db, key: $0)?.name }
            if let transferId = entry.savingsTransferId {
                guard let transfer = try savingsTransfers(db).first(where: { $0.id == transferId }), !transfer.done else { return nil }
                return EntryProgress(kind: .toTransfer(potName: potName, direction: transfer.direction, inPendingTransfer: true),
                                     amount: transfer.transferAmount)
            }
            let open = try openReimbursements(db)
            return EntryProgress(kind: .toTransfer(potName: potName, direction: open.direction, inPendingTransfer: false),
                                 amount: open.transferAmount)
        }
        guard entry.settlementId == nil, entry.amount.isNegative else { return nil }
        let tagIds = Set(try Int64.fetchAll(db, sql: "SELECT tagId FROM entryTag WHERE entryId = ?", arguments: [entryId]))
        guard let summary = try settlementOverview(db, today: today).first(where: { tagIds.contains($0.id) }),
              summary.outstanding > .zero else { return nil }
        return EntryProgress(kind: .toReceive(tagId: summary.id, tagName: summary.name), amount: summary.outstanding)
    }

    /// De toevoeging achter de post in een lijst: "uit potje X" / "naar potje X" bij verrekenen met spaar
    /// (`potName` nil = "uit spaar"), en "voorgeschoten (Tanken)" bij een uitgave met een tag die verrekend wordt.
    /// Leeg als er niets bijzonders is. `settlingTagNames`: namen van de tags op de boeking die verrekend worden
    /// en nog niet verrekend zijn.
    public static func linkLabels(amount: Money, reimburse: Bool, potName: String?, settlingTagNames: [String]) -> [String] {
        var parts: [String] = []
        if reimburse, !amount.isZero {
            let pot = potName.map { "potje \($0)" } ?? "spaar"
            parts.append(amount.isNegative ? "uit \(pot)" : "naar \(pot)")
        }
        if amount.isNegative { parts += settlingTagNames.map { "krijg ik terug (\($0))" } }
        return parts
    }
}
