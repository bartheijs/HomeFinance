import Foundation
import HFCore

// MARK: - Volgorde van potten in keuzelijsten

extension Insight {
    /// Volgorde van potten in een keuzelijst: eerst de reserveringspotten, dan de spaarpotten, binnen elke groep
    /// alfabetisch (hoofdletterongevoelig, Nederlandse sortering, "Pot 2" vóór "Pot 10", "Één" bij de E).
    /// Eén plek voor alle pot-kiezers; "Nee", "Geen pot" en dergelijke zet de kiezer zelf bovenaan.
    /// Het overzicht Potten en sparen (per persoon) gebruikt dit niet.
    public static func pickerOrder<T>(_ items: [T], kind: (T) -> PotKind, name: (T) -> String) -> [T] {
        items.enumerated().sorted { a, b in
            let ka = kindRank(kind(a.element)), kb = kindRank(kind(b.element))
            if ka != kb { return ka < kb }
            switch compareNames(name(a.element), name(b.element)) {
            case .orderedAscending: return true
            case .orderedDescending: return false
            case .orderedSame: return a.offset < b.offset
            }
        }.map(\.element)
    }

    /// `pickerOrder` voor potten uit de database.
    public static func pickerOrder(_ pots: [Pot]) -> [Pot] {
        pickerOrder(pots, kind: \.kind, name: \.name)
    }

    /// `pickerOrder` voor potten uit het potoverzicht.
    public static func pickerOrder(_ pots: [PotSummary]) -> [PotSummary] {
        pickerOrder(pots, kind: \.kind, name: \.name)
    }

    /// Alfabetische vergelijking van twee namen zoals in een Nederlandse lijst: eerst zonder op hoofdletters en
    /// accenten te letten; zijn ze dan gelijk, dan beslist de gewone Nederlandse volgorde ("ex" vóór "éx").
    public static func compareNames(_ a: String, _ b: String) -> ComparisonResult {
        let dutch = Locale(identifier: "nl_NL")
        let loose = a.compare(b, options: [.caseInsensitive, .diacriticInsensitive, .numeric, .widthInsensitive],
                              range: nil, locale: dutch)
        if loose != .orderedSame { return loose }
        return a.compare(b, options: [.numeric], range: nil, locale: dutch)
    }

    private static func kindRank(_ kind: PotKind) -> Int {
        switch kind { case .reservering: return 0; case .spaar: return 1 }
    }
}
