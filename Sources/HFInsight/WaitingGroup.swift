import Foundation
import HFCore

// MARK: - Zeker, waarschijnlijk of twijfel bij een wachtende banktransactie

/// Hoe zeker het voorstel bij een wachtende banktransactie is. Nakijken en Transacties gebruiken allebei deze
/// indeling, zodat ze dezelfde aantallen "zeker" en "na te kijken" tonen (UX-stap D1).
public enum WaitingGroup: Int, CaseIterable, Sendable, Comparable {
    /// Geen regel, alleen een gok, een afwijkend bedrag of een melding: eerst zelf bekijken.
    case doubt
    /// Een regel herkent de tegenpartij of de omschrijving, maar niet het bedrag.
    case probable
    /// Tegenpartij en bedrag kloppen met een regel, of het bedrag is precies een vaste overboeking.
    case certain

    public static func < (l: Self, r: Self) -> Bool { l.rawValue < r.rawValue }
}

/// Wat de herkenning over een wachtende banktransactie zegt, in gewone waarden. De app vult dit uit HFRules
/// (voorstel van de regels) en HFBudget (overboeking met spaar, automatisch sparen, eigen overboeking).
public struct WaitingSignals: Equatable, Sendable {
    /// Dit is de banktransactie van een vastgelegde overboeking met spaar (wordt gekoppeld, niet geboekt).
    public var isSavingsTransfer = false
    /// Herkend als automatisch sparen (vaste overboeking); nil als dat niet zo is.
    public var distribution: Distribution?

    /// Automatisch sparen zoals het meetelt voor het voorstel.
    public struct Distribution: Equatable, Sendable {
        /// Precies één vaste overboeking past (anders kiest de gebruiker).
        public var isSingle: Bool
        /// Het bedrag is precies het totaal van de vaste overboeking.
        public var exactAmount: Bool
        /// Het voorstel volgt de vaste overboeking (false: de gebruiker kiest één potje, of het lijkt een losse
        /// overboeking).
        public var followsDistribution: Bool
        public init(isSingle: Bool, exactAmount: Bool, followsDistribution: Bool) {
            self.isSingle = isSingle; self.exactAmount = exactAmount; self.followsDistribution = followsDistribution
        }
    }

    /// Zekerheid van het voorstel van de regels.
    public var confidence: Confidence = .geen
    /// De regel kent de tegenpartij, maar verwacht een ander bedrag.
    public var amountDiffers = false
    /// De regels gaven een melding (bv. de post bestaat niet in dit jaar).
    public var hasWarnings = false
    /// Deze transactie is één kant van een overboeking tussen eigen rekeningen.
    public var isOwnTransfer = false

    public init(isSavingsTransfer: Bool = false, distribution: Distribution? = nil, confidence: Confidence = .geen,
                amountDiffers: Bool = false, hasWarnings: Bool = false, isOwnTransfer: Bool = false) {
        self.isSavingsTransfer = isSavingsTransfer; self.distribution = distribution; self.confidence = confidence
        self.amountDiffers = amountDiffers; self.hasWarnings = hasWarnings; self.isOwnTransfer = isOwnTransfer
    }
}

extension Insight {
    /// De groep van een wachtende banktransactie. Volgorde: overboeking met spaar (altijd twijfel: koppelen doe
    /// je bewust), automatisch sparen (zeker alleen bij één storting, precies het bedrag en de verdeling gevolgd),
    /// dan de regels (een afwijkend bedrag of een melding is twijfel; een gok of niets is "waarschijnlijk" als het
    /// een eigen overboeking is, anders twijfel).
    public static func waitingGroup(_ s: WaitingSignals) -> WaitingGroup {
        if s.isSavingsTransfer { return .doubt }
        if let d = s.distribution {
            return d.isSingle && d.exactAmount && d.followsDistribution ? .certain : .doubt
        }
        if s.amountDiffers || s.hasWarnings { return .doubt }
        switch s.confidence {
        case .hoog: return .certain
        case .midden: return .probable
        case .laag, .geen: return s.isOwnTransfer ? .probable : .doubt
        }
    }

    /// De regel met de aantallen, overal dezelfde: "Nog 3 na te kijken · 4 zeker".
    public static func waitingCountsLine(toCheck: Int, certain: Int) -> String {
        switch (toCheck, certain) {
        case (0, 0): "Niets te boeken"
        case (0, let c): "\(c) zeker · niets na te kijken"
        case (let t, 0): "Nog \(t) na te kijken"
        case (let t, let c): "Nog \(t) na te kijken · \(c) zeker"
        }
    }
}
