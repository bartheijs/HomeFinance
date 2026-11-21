import Foundation
import GRDB
import HFCore

/// Kerncijfers van een administratie: een vaste, platte lijst getallen om twee versies van de app op dezelfde
/// gegevens met elkaar te vergelijken (testronde). Rekent niet zelf: alle bedragen komen uit de bestaande
/// leesfuncties (`accountOverview`, `balance`, `potOverview`, `spendable`, `openReimbursements`); alleen
/// aantallen worden hier geteld.
public struct KeyFigures: Equatable, Sendable {
    /// De peildag.
    public let day: Day
    /// Sleutel → waarde. Bedragen als "-1234.56" (euro's, punt als scheidingsteken), aantallen als "12".
    public let values: [String: String]

    /// Stabiel JSON: sleutels op alfabet, één per regel.
    public func json() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(values)
    }
}

extension Insight {
    /// Versie van de opbouw van de kerncijfers. Ophogen als er sleutels bijkomen of veranderen.
    public static let keyFiguresVersion = 1

    /// De kerncijfers op de peildag `today`.
    ///
    /// Sleutels (`<id>` is vier cijfers, zodat de volgorde vast is):
    /// - `rekening.<id>.naam`, `.soort`, `.gearchiveerd`, `.saldo` (op de peildag),
    ///   `.laatsteImport.dag`, `.laatsteImport.eindsaldo` en `.laatsteImport.saldoVolgensApp` (saldo op die dag);
    /// - `pot.<id>.naam`, `.rekening`, `.gearchiveerd`, `.saldo`;
    /// - `besteedbaarNu`, `nogTeBestedenDezeMaand` (of "geen begrotingsjaar");
    /// - `boekingen.aantal`, `banktransacties.<status>`, `verrekeningen.openNetto`, `verrekeningen.openAantal`;
    /// - `afgevinkt.<jjjj-mm>`: aantal afgevinkte posten per begrotingsmaand.
    public static func keyFigures(_ db: Database, today: Day) throws -> KeyFigures {
        var v: [String: String] = [:]
        v["kerncijfers.versie"] = String(keyFiguresVersion)
        v["peildag"] = today.iso

        for a in try accountOverview(db, today: today) {
            let k = "rekening.\(pad(a.id))"
            v["\(k).naam"] = a.name
            v["\(k).soort"] = a.kind.rawValue
            v["\(k).gearchiveerd"] = a.archived ? "ja" : "nee"
            v["\(k).saldo"] = amount(a.balance)
            if let last = a.lastImport {
                v["\(k).laatsteImport.dag"] = last.lastDay?.iso ?? "onbekend"
                v["\(k).laatsteImport.eindsaldo"] = last.closingBalance.map(amount) ?? "geen"
                if let day = last.lastDay {
                    v["\(k).laatsteImport.saldoVolgensApp"] = amount(try balance(db, accountId: a.id, on: day))
                }
            } else {
                v["\(k).laatsteImport.dag"] = "geen"
            }
        }

        for pot in try potOverview(db, today: today).accounts.flatMap(\.pots) {
            let k = "pot.\(pad(pot.id))"
            v["\(k).naam"] = pot.name
            v["\(k).rekening"] = pad(pot.accountId)
            v["\(k).gearchiveerd"] = pot.archived ? "ja" : "nee"
            v["\(k).saldo"] = amount(pot.balance)
        }

        do {
            let s = try spendable(db, year: today.year, today: today)
            v["besteedbaarNu"] = amount(s.spendable)
            v["nogTeBestedenDezeMaand"] = amount(s.spendableEndOfMonth)
        } catch InsightError.yearNotFound {
            v["besteedbaarNu"] = "geen begrotingsjaar"
            v["nogTeBestedenDezeMaand"] = "geen begrotingsjaar"
        }

        v["boekingen.aantal"] = String(try Entry.fetchCount(db))
        for status in BankTransactionStatus.allCases {
            v["banktransacties.\(status.rawValue)"] = String(
                try BankTransaction.filter(Column("status") == status.rawValue).fetchCount(db))
        }

        let open = try openReimbursements(db)
        v["verrekeningen.openNetto"] = amount(open.net)
        v["verrekeningen.openAantal"] = String(open.entries.count)

        let checks = try Row.fetchAll(db, sql: """
            SELECT y.year, c.month, COUNT(*) AS n FROM itemCheck c
            JOIN budgetItem i ON i.id = c.budgetItemId
            JOIN budgetYear y ON y.id = i.yearId
            GROUP BY y.year, c.month
            """)
        for r in checks {
            let year: Int = r["year"], month: Int = r["month"], n: Int = r["n"]
            v[String(format: "afgevinkt.%04d-%02d", year, month)] = String(n)
        }

        return KeyFigures(day: today, values: v)
    }

    private static func pad(_ id: Int64) -> String { String(format: "%04lld", id) }

    /// "-1234.56": vast formaat, los van de taal van de Mac.
    private static func amount(_ m: Money) -> String {
        let c = m.cents.magnitude
        return "\(m.cents < 0 ? "-" : "")\(c / 100).\(String(format: "%02llu", c % 100))"
    }
}
