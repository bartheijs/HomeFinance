import Foundation
import GRDB
import HFCore

// MARK: - Downloadadvies

/// Eén rekening in het downloadadvies.
public struct DownloadAccount: Identifiable, Equatable, Sendable {
    public let id: Int64
    public let name: String
    /// Datum van de laatste banktransactie in de app, of nil als er nog niets geïmporteerd is.
    public let lastBankDay: Day?
    /// Vanaf deze dag moet deze rekening opnieuw: de laatste banktransactiedatum, of zonder banktransacties de
    /// startdatum van het beginsaldo. Nooit later dan vandaag.
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

    /// Hoofdzin van het blok: wat je downloadt, van welke rekeningen en welke periode.
    public var instruction: String {
        let names = accounts.map(\.name)
        let list = names.count <= 1 ? (names.first ?? "")
            : names.dropLast().joined(separator: ", ") + " en " + (names.last ?? "")
        let period = from == through
            ? "van vandaag (\(from.dutch))"
            : "van \(from.dutch) tot en met \(through.dutch)"
        return "Bijwerken: download bij de bank de CSV-export (zip, één bestand per rekening) van \(list), \(period)."
    }

    /// Uitleg onder de hoofdzin: waar de begindag vandaan komt en dat overlap geen kwaad kan.
    public var note: String {
        let reason = hasEarlierImport
            ? "De begindag is de vroegste laatste banktransactie in de app; die dag zit er bewust nog een keer in."
            : "Er is nog niets geïmporteerd, dus de periode begint bij de startdatum van het beginsaldo."
        return reason + " Overlap kan geen kwaad: regels die er al zijn, worden overgeslagen."
    }

    /// Per rekening de laatste banktransactie (of de startdatum), één regel per rekening.
    public var perAccount: String {
        accounts.map { a in
            "\(a.name): " + (a.lastBankDay.map { "laatste banktransactie \($0.dutch)" }
                             ?? "nog niets geïmporteerd, vanaf de startdatum \(a.fromDay.dutch)")
        }.joined(separator: "\n")
    }
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
            return DownloadAccount(id: id, name: a.name, lastBankDay: last, fromDay: min(last ?? a.openingDate, today))
        }
        guard let from = list.map(\.fromDay).min() else { return nil }
        return DownloadAdvice(accounts: list, from: from, through: today,
                              hasEarlierImport: list.contains { $0.lastBankDay != nil })
    }
}
