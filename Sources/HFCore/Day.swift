import Foundation
import GRDB

/// Een kalenderdag zonder tijd of tijdzone. In de database als "yyyy-MM-dd".
public struct Day: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let year: Int
    public let month: Int
    public let day: Int

    private static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    public init?(year: Int, month: Int, day: Int) {
        var comps = DateComponents()
        comps.year = year; comps.month = month; comps.day = day
        guard (1...12).contains(month), (1...31).contains(day), (1900...2200).contains(year),
              let date = Self.calendar.date(from: comps),
              Self.calendar.component(.day, from: date) == day,
              Self.calendar.component(.month, from: date) == month else { return nil }
        self.year = year; self.month = month; self.day = day
    }

    /// "2027-01-31"
    public init?(iso: String) {
        let p = iso.split(separator: "-")
        guard p.count == 3, p[0].count == 4, let y = Int(p[0]), let m = Int(p[1]), let d = Int(p[2]) else { return nil }
        self.init(year: y, month: m, day: d)
    }

    /// "31-01-2027" (ook "31/01/2027" en "31.01.2027")
    public init?(dutch: String) {
        let p = dutch.trimmingCharacters(in: .whitespaces)
            .split(whereSeparator: { "-/.".contains($0) })
        guard p.count == 3, let d = Int(p[0]), let m = Int(p[1]), let y = Int(p[2]), p[2].count == 4 else { return nil }
        self.init(year: y, month: m, day: d)
    }

    public init(date: Date, calendar: Calendar = .current) {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        self.year = c.year!; self.month = c.month!; self.day = c.day!
    }

    public static func today() -> Day { Day(date: Date()) }

    public var iso: String { String(format: "%04d-%02d-%02d", year, month, day) }
    public var dutch: String { String(format: "%02d-%02d-%04d", day, month, year) }
    public var description: String { iso }

    /// Middernacht UTC van deze dag; alleen voor weergave en rekenen met dagen.
    public var date: Date {
        Self.calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    public func adding(days: Int) -> Day {
        Day(date: Self.calendar.date(byAdding: .day, value: days, to: date)!, calendar: Self.calendar)
    }

    public static func < (l: Day, r: Day) -> Bool {
        (l.year, l.month, l.day) < (r.year, r.month, r.day)
    }

    public static let monthNamesShort = ["jan", "feb", "mrt", "apr", "mei", "jun", "jul", "aug", "sep", "okt", "nov", "dec"]
    public static let monthNames = ["januari", "februari", "maart", "april", "mei", "juni", "juli", "augustus",
                                    "september", "oktober", "november", "december"]
}

extension Day: Codable {
    public init(from decoder: Decoder) throws {
        let s = try decoder.singleValueContainer().decode(String.self)
        guard let d = Day(iso: s) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Ongeldige dag: \(s)"))
        }
        self = d
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(iso)
    }
}

extension Day: DatabaseValueConvertible {
    public var databaseValue: DatabaseValue { iso.databaseValue }
    public static func fromDatabaseValue(_ dbValue: DatabaseValue) -> Day? {
        String.fromDatabaseValue(dbValue).flatMap(Day.init(iso:))
    }
}
