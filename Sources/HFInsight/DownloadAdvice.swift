import Foundation
import GRDB
import HFCore

// MARK: - Downloadadvies

/// Eén rekening in het downloadadvies.
public struct DownloadAccount: Identifiable, Equatable, Sendable {
    public let id: Int64
    public let name: String
    public let iban: String?
    /// Datum van de laatste banktransactie in de app, of nil als er nog niets geïmporteerd is.
    public let lastBankDay: Day?
    /// Vanaf deze dag moet deze rekening opnieuw: de laatste banktransactiedatum, of de startdatum.
    public let fromDay: Day
}

/// Welke bankbestanden de gebruiker moet downloaden om de app bij te werken.
public struct DownloadAdvice: Equatable, Sendable {
    /// De rekeningen (niet gearchiveerd), in de volgorde van de app.
    public let accounts: [DownloadAccount]
    /// Begin van de periode: de vroegste `fromDay` over alle rekeningen. Die dag zelf zit er bewust in
    /// (overlap); dubbele regels slaat de import over.
    public let from: Day
    /// Einde van de periode: vandaag.
    public let through: Day
    /// True als er voor minstens één rekening al banktransacties in de app staan.
    public let hasEarlierImport: Bool
}

extension Insight {
    /// Downloadadvies voor het scherm Transacties: per rekening de laatste banktransactiedatum, en de periode
    /// vanaf de vroegste daarvan (met die dag als overlap) tot en met `today`. Een rekening zonder
    /// banktransacties telt vanaf haar startdatum (de datum van het beginsaldo). Geeft nil zonder rekeningen.
    public static func downloadAdvice(_ db: Database, today: Day) throws -> DownloadAdvice? {
        let accounts = try Account.filter(Column("archived") == false)
            .order(Column("sortOrder"), Column("id")).fetchAll(db)
        guard !accounts.isEmpty else { return nil }
        var lastDays: [Int64: Day] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT accountId, MAX(day) AS last FROM bankTransaction GROUP BY accountId") {
            if let id: Int64 = row["accountId"], let last: Day = row["last"] { lastDays[id] = last }
        }
        let list = accounts.compactMap { a -> DownloadAccount? in
            guard let id = a.id else { return nil }
            let last = lastDays[id]
            return DownloadAccount(id: id, name: a.name, iban: a.iban, lastBankDay: last,
                                   fromDay: min(last ?? a.openingDate, today))
        }
        guard let from = list.map(\.fromDay).min() else { return nil }
        return DownloadAdvice(accounts: list, from: from, through: today,
                              hasEarlierImport: list.contains { $0.lastBankDay != nil })
    }
}

// MARK: - Volgorde in keuzelijsten

extension Insight {
    /// Volgorde van potten in een keuzelijst: eerst de reserveringspotten, dan de spaarpotten, binnen elke
    /// groep alfabetisch (hoofdletterongevoelig, Nederlandse sortering, "Pot 2" vóór "Pot 10").
    /// Eén plek voor alle pot-kiezers; "Nee", "Geen pot" en dergelijke zet de kiezer zelf bovenaan.
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

    /// Alfabetische vergelijking van twee namen zoals in een Nederlandse lijst.
    public static func compareNames(_ a: String, _ b: String) -> ComparisonResult {
        a.compare(b, options: [.caseInsensitive, .diacriticInsensitive, .numeric, .widthInsensitive],
                  range: nil, locale: Locale(identifier: "nl_NL"))
    }

    private static func kindRank(_ kind: PotKind) -> Int {
        switch kind { case .reservering: return 0; case .spaar: return 1 }
    }
}
