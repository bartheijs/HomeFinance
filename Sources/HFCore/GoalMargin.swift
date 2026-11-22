import Foundation
import GRDB

/// De marge op een spaardoel: hoeveel het verwachte saldo op de doeldatum onder het doel mag blijven en dan toch
/// als "op koers" geldt (bv. 4 cent per maand te weinig hoeft geen actie). In basispunten van het doelbedrag
/// (50 = 0,5 %), voor alle potjes. Bewaard in de tabel `setting`; zonder waarde geldt `defaultBasisPoints`.
public enum GoalMargin {
    public static let key = "spaardoel.margeBasispunten"
    public static let defaultBasisPoints = 50
    /// De keuzes in de interface: 0 %, 0,5 %, 1 % en 2 %.
    public static let choices = [0, 50, 100, 200]

    public static func basisPoints(_ db: Database) throws -> Int {
        guard let text = try Setting.get(db, key), let value = Int(text), value >= 0 else { return defaultBasisPoints }
        return value
    }

    public static func setBasisPoints(_ db: Database, _ value: Int) throws {
        try Setting.set(db, key, String(max(0, value)))
    }

    /// De marge in geld voor een doelbedrag (naar beneden afgerond op centen).
    public static func amount(of target: Money, basisPoints: Int) -> Money {
        Money(cents: target.cents * Int64(basisPoints) / 10_000)
    }

    /// "0,5 %".
    public static func text(_ basisPoints: Int) -> String {
        let whole = basisPoints / 100, rest = basisPoints % 100
        if rest == 0 { return "\(whole) %" }
        return "\(whole),\(rest % 10 == 0 ? String(rest / 10) : String(format: "%02d", rest)) %"
    }
}
