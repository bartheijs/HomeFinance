import Foundation
import GRDB

/// Een geldbedrag in hele eurocenten. Nooit Double gebruiken voor geld.
/// Uitgaven zijn negatief, inkomsten positief.
public struct Money: Hashable, Comparable, Sendable, AdditiveArithmetic, CustomStringConvertible {
    public var cents: Int64

    public init(cents: Int64) { self.cents = cents }
    public init(euros: Int64, cents: Int64 = 0) { self.cents = euros * 100 + cents }

    public static let zero = Money(cents: 0)

    public static func + (l: Money, r: Money) -> Money { Money(cents: l.cents + r.cents) }
    public static func - (l: Money, r: Money) -> Money { Money(cents: l.cents - r.cents) }
    public static prefix func - (m: Money) -> Money { Money(cents: -m.cents) }
    public static func < (l: Money, r: Money) -> Bool { l.cents < r.cents }

    public var isNegative: Bool { cents < 0 }
    public var isZero: Bool { cents == 0 }
    public var magnitude: Money { Money(cents: abs(cents)) }

    /// Leest een bedrag in Nederlandse of Engelse notatie:
    /// "-1.234,56", "45,5", "€ 12", "-45.50", "1,234.56" is niet toegestaan.
    public init?(parsing text: String) {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.replacingOccurrences(of: "€", with: "")
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\u{00A0}", with: "")
        guard !s.isEmpty else { return nil }
        var negative = false
        if s.hasPrefix("-") { negative = true; s.removeFirst() }
        else if s.hasPrefix("+") { s.removeFirst() }
        else if s.hasSuffix("-") { negative = true; s.removeLast() }

        var whole = s
        var fraction = ""
        if let comma = s.lastIndex(of: ",") {
            guard s.filter({ $0 == "," }).count == 1 else { return nil }
            whole = String(s[..<comma]).replacingOccurrences(of: ".", with: "")
            fraction = String(s[s.index(after: comma)...])
        } else if let dot = s.lastIndex(of: ".") {
            let after = s[s.index(after: dot)...]
            let dots = s.filter { $0 == "." }.count
            if dots == 1 && (1...2).contains(after.count) {
                whole = String(s[..<dot])
                fraction = String(after)
            } else {
                // Punten als duizendtalscheiding: elke groep na de eerste heeft 3 cijfers.
                let groups = s.split(separator: ".", omittingEmptySubsequences: false)
                guard groups.dropFirst().allSatisfy({ $0.count == 3 }) else { return nil }
                whole = groups.joined()
            }
        }
        if whole.isEmpty { whole = "0" }
        guard fraction.count <= 2,
              whole.allSatisfy(\.isASCIIDigit), fraction.allSatisfy(\.isASCIIDigit),
              let w = Int64(whole) else { return nil }
        let f = Int64(fraction.padding(toLength: 2, withPad: "0", startingAt: 0)) ?? 0
        let value = w * 100 + f
        self.cents = negative ? -value : value
    }

    /// "€ 1.234,56" of "-€ 45,50". Met `symbol: false`: "1.234,56".
    public func formatted(symbol: Bool = true, alwaysSign: Bool = false) -> String {
        let a = abs(cents)
        var whole = String(a / 100)
        var grouped = ""
        while whole.count > 3 {
            grouped = "." + whole.suffix(3) + grouped
            whole.removeLast(3)
        }
        let digits = whole + grouped + "," + String(format: "%02d", a % 100)
        let sign = cents < 0 ? "-" : (alwaysSign && cents > 0 ? "+" : "")
        return sign + (symbol ? "€ " : "") + digits
    }

    public var description: String { formatted() }

    /// Voor grafieken en percentages; niet om mee te rekenen.
    public var doubleValue: Double { Double(cents) / 100 }
}

extension Money: Codable {
    public init(from decoder: Decoder) throws {
        cents = try decoder.singleValueContainer().decode(Int64.self)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(cents)
    }
}

extension Money: DatabaseValueConvertible {
    public var databaseValue: DatabaseValue { cents.databaseValue }
    public static func fromDatabaseValue(_ dbValue: DatabaseValue) -> Money? {
        Int64.fromDatabaseValue(dbValue).map(Money.init(cents:))
    }
}

public extension Sequence where Element == Money {
    func sum() -> Money { reduce(.zero, +) }
}

private extension Character {
    var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}
