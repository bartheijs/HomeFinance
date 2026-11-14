import Foundation
import GRDB
import HFCore

// MARK: - Typen

/// Waar een verwachte mutatie vandaan komt.
public enum ForecastEventKind: Equatable, Sendable {
    /// Een losse verwachting (`ForecastItem`).
    case oneOff(forecastItemId: Int64)
    /// De maandelijkse bijschrijving uit een vaste storting (`Distribution`).
    case recurring(distributionId: Int64)
}

/// Eén verwachte mutatie van een pot.
public struct ForecastEvent: Identifiable, Equatable, Sendable {
    public let id: String
    public let day: Day
    /// Met teken: positief = erbij, negatief = eraf.
    public let amount: Money
    public let label: String
    public let kind: ForecastEventKind
    /// Het verwachte potsaldo na deze mutatie.
    public let balanceAfter: Money
}

/// Punt in de grafiek van een pot: echt saldo (`isForecast == false`) of verwacht saldo.
public struct ForecastPoint: Identifiable, Equatable, Sendable {
    public var id: String { "\(day.iso)-\(isForecast ? "v" : "w")" }
    public let day: Day
    public let balance: Money
    public let isForecast: Bool
}

/// De vooruitblik van één pot. Staat los van de werkelijkheid: raakt geen enkel ander cijfer.
public struct PotForecast: Equatable, Sendable {
    public let potId: Int64
    public let potName: String
    public let today: Day
    public let until: Day
    /// Het spaardoel van de pot (bedrag en datum), om als lijn in de grafiek te tekenen; nil zonder doel.
    public let targetAmount: Money?
    public let targetDate: Day?
    /// Het echte potsaldo op `today`.
    public let startBalance: Money
    /// Verwachte mutaties van morgen t/m `until`, oplopend op dag (op één dag eerst wat erbij komt).
    public let events: [ForecastEvent]
    /// Losse verwachtingen die niet zijn uitgekomen en waarvan de dag vandaag of eerder is ("over tijd").
    /// Ze tellen niet mee in de lijn.
    public let overdue: [ForecastItem]
    /// Voor de grafiek: echt saldo per maandeinde van de afgelopen 12 maanden (of vanaf de eerste boeking) t/m
    /// vandaag, daarna het verwachte saldo per dag met een mutatie en op `until`.
    public let points: [ForecastPoint]
    /// Het laagste verwachte saldo van vandaag t/m `until` (de vroegste dag bij gelijke stand).
    public let lowestPoint: ForecastPoint
    /// Het verwachte saldo op `until`.
    public var endBalance: Money { events.last?.balanceAfter ?? startBalance }

    /// Het verwachte saldo aan het eind van een dag, of nil buiten `today` … `until`.
    public func balance(on day: Day) -> Money? {
        guard day >= today, day <= until else { return nil }
        return events.last { $0.day <= day }?.balanceAfter ?? startBalance
    }
}

/// Stand van een spaardoel.
public enum PotGoalStatus: String, Sendable, CaseIterable {
    /// Het saldo is het doel of meer.
    case bereikt
    /// Het verwachte saldo op de doeldatum haalt het doel.
    case opKoers
    /// Het verwachte saldo op de doeldatum blijft onder het doel.
    case tekort
    /// De doeldatum is voorbij en het doel is niet gehaald.
    case verlopen
    /// Er is een doelbedrag maar geen doeldatum.
    case zonderDatum
}

/// Het spaardoel van een pot: wat er nog nodig is en wat er per maand gespaard moet worden.
public struct PotGoal: Equatable, Sendable {
    public let potId: Int64
    public let targetAmount: Money
    public let targetDate: Day?
    /// Het echte potsaldo op de peildag.
    public let balance: Money
    /// Doel − saldo, minimaal € 0,00.
    public let remaining: Money
    /// Som van de open losse verwachtingen van morgen t/m de doeldatum (uitgaven negatief); € 0,00 zonder datum.
    public let expectedOneOffs: Money
    /// Aantal stortmomenten van morgen t/m de doeldatum; 0 zonder datum of als de datum voorbij is.
    public let monthsLeft: Int
    /// (`remaining` − `expectedOneOffs`) ÷ `monthsLeft`, naar boven afgerond op centen, minimaal € 0,00;
    /// nil zonder doeldatum of als er geen stortmoment meer is.
    public let requiredPerMonth: Money?
    /// Wat er nu per maand naar de pot gaat: de regels in niet-gearchiveerde vaste stortingen.
    public let currentPerMonth: Money
    /// `requiredPerMonth` − `currentPerMonth`: positief = per maand te weinig, negatief = ruimte over.
    public let shortfallPerMonth: Money?
    /// Het verwachte saldo op de doeldatum volgens de vooruitblik; nil zonder doeldatum.
    public let projectedOnTargetDate: Money?
    public let status: PotGoalStatus
    /// De eerste dag waarop de vooruitblik het doel haalt (vandaag als het al bereikt is); nil als dat met de
    /// huidige stortingen en verwachtingen binnen 10 jaar niet gebeurt.
    public let projectedReachDate: Day?
}

// MARK: - Functies

/// Gedeelde gegevens voor vooruitblik en spaardoel: in drie queries voor één pot of voor alle potten.
struct ForecastContext {
    struct Line {
        let distributionId: Int64
        let name: String
        let amount: Money
        /// Dag van de laatste echte bijschrijving van dit bedrag op de pot (bij voorkeur gesplitst uit een
        /// banktransactie met het totaal van de storting), of nil.
        let lastDeposit: Day?
    }
    typealias RawEvent = (day: Day, amount: Money, label: String, kind: ForecastEventKind, id: String)

    let today: Day
    /// Open losse verwachtingen per pot, op dag.
    var items: [Int64: [ForecastItem]] = [:]
    /// Regels van niet-gearchiveerde vaste stortingen per pot, op volgorde van de stortingen.
    var lines: [Int64: [Line]] = [:]

    init(_ db: Database, today: Day, potId: Int64? = nil) throws {
        self.today = today
        var request = ForecastItem.filter(Column("realizedAt") == nil)
        if let potId { request = request.filter(Column("potId") == potId) }
        for item in try request.order(Column("day"), Column("id")).fetchAll(db) {
            items[item.potId, default: []].append(item)
        }
        let deposit = "e.potId = l.potId AND e.accountId = p.accountId AND e.amount = l.amount AND e.day <= ?"
        var sql = """
            SELECT l.potId, d.id, d.name, l.amount,
                   (SELECT MAX(e.day) FROM entry e WHERE \(deposit)) AS anyDay,
                   (SELECT MAX(e.day) FROM entry e JOIN bankTransaction b ON b.id = e.bankTransactionId
                    WHERE \(deposit) AND b.amount = (SELECT SUM(x.amount) FROM distributionLine x
                                                    WHERE x.distributionId = d.id)) AS wholeDay
            FROM distributionLine l
            JOIN distribution d ON d.id = l.distributionId
            JOIN pot p ON p.id = l.potId
            WHERE d.archived = 0
            """
        var args: [(any DatabaseValueConvertible)?] = [today, today]
        if let potId { sql += " AND l.potId = ?"; args.append(potId) }
        sql += " ORDER BY d.sortOrder, d.id"
        for r in try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args)) {
            let whole: Day? = r["wholeDay"], any: Day? = r["anyDay"]
            lines[r["potId"], default: []].append(
                Line(distributionId: r["id"], name: r["name"], amount: r["amount"], lastDeposit: whole ?? any))
        }
    }

    /// De dagen na vandaag t/m `until` waarop een maandelijkse storting verwacht wordt. `lastDeposit` nil = de 25e.
    /// De lopende maand telt alleen als de storting nog niet binnen is; is de gewone dag al voorbij, dan morgen.
    func depositDays(lastDeposit: Day?, until: Day) -> [Day] {
        let dayOfMonth = lastDeposit?.day ?? Insight.defaultDistributionDay
        let received = lastDeposit.map { $0.year == today.year && $0.month == today.month } ?? false
        let tomorrow = today.adding(days: 1)
        var days: [Day] = []
        var (y, m) = (today.year, today.month)
        while (y, m) <= (until.year, until.month) {
            var day = Day(year: y, month: m, day: min(dayOfMonth, Q.lastDay(y, m).day))!
            let isCurrent = (y, m) == (today.year, today.month)
            if isCurrent, day <= today { day = tomorrow }
            let skip = isCurrent && (received || tomorrow.month != today.month)
            if !skip, day > today, day <= until { days.append(day) }
            m += 1
            if m > 12 { m = 1; y += 1 }
        }
        return days
    }

    /// Alle verwachte mutaties van een pot van morgen t/m `until`, op dag (op één dag eerst wat erbij komt).
    func events(potId: Int64, until: Day) -> [RawEvent] {
        var raw: [RawEvent] = (items[potId] ?? []).filter { $0.day > today && $0.day <= until }
            .map { ($0.day, $0.amount, $0.label, .oneOff(forecastItemId: $0.id!), "los-\($0.id!)") }
        for line in lines[potId] ?? [] {
            for day in depositDays(lastDeposit: line.lastDeposit, until: until) {
                raw.append((day, line.amount, line.name, .recurring(distributionId: line.distributionId),
                            "vast-\(line.distributionId)-\(Q.periodKey(day.year, day.month))"))
            }
        }
        return raw.sorted { ($0.day, $1.amount, $0.id) < ($1.day, $0.amount, $1.id) }
    }

    /// Het spaardoel van een pot, of nil zonder doelbedrag.
    func goal(pot: Pot, balance: Money) -> PotGoal? {
        guard let target = pot.targetAmount, target > .zero, let potId = pot.id else { return nil }
        let remaining = max(.zero, target - balance)
        let current = (lines[potId] ?? []).map(\.amount).sum()
        let reached = balance >= target

        var oneOffs = Money.zero, monthsLeft = 0
        var required: Money?, projected: Money?
        if let date = pot.targetDate {
            let upcoming = events(potId: potId, until: date)
            projected = balance + upcoming.map(\.amount).sum()
            oneOffs = upcoming.filter { if case .oneOff = $0.kind { return true }; return false }.map(\.amount).sum()
            // Stortmomenten: het ritme van de eerste vaste storting, of de 25e als er geen is.
            monthsLeft = depositDays(lastDeposit: lines[potId]?.first?.lastDeposit, until: date).count
            if monthsLeft > 0 {
                let needed = max(0, (remaining - oneOffs).cents), n = Int64(monthsLeft)
                required = Money(cents: (needed + n - 1) / n)
            }
        }
        let status: PotGoalStatus
        if reached { status = .bereikt }
        else if let date = pot.targetDate {
            if date < today { status = .verlopen }
            else { status = (projected ?? balance) >= target ? .opKoers : .tekort }
        } else { status = .zonderDatum }

        var reachDate: Day? = reached ? today : nil
        if !reached, let horizon = Day(year: today.year + 10, month: today.month, day: min(today.day, 28)) {
            var running = balance
            for e in events(potId: potId, until: horizon) {
                running += e.amount
                if running >= target { reachDate = e.day; break }
            }
        }
        return PotGoal(potId: potId, targetAmount: target, targetDate: pot.targetDate, balance: balance,
                       remaining: remaining, expectedOneOffs: oneOffs, monthsLeft: monthsLeft,
                       requiredPerMonth: required, currentPerMonth: current,
                       shortfallPerMonth: required.map { $0 - current }, projectedOnTargetDate: projected,
                       status: status, projectedReachDate: reachDate)
    }
}

extension Insight {
    /// Dag van de maand voor een vaste storting waarvan nog geen echte bijschrijving bekend is.
    public static let defaultDistributionDay = 25

    /// De vooruitblik van een pot van `today` t/m `until`: het echte saldo nu, de verwachte mutaties (losse
    /// verwachtingen en maandelijkse vaste stortingen) met het doorlopende saldo, wat over tijd is en een
    /// reeks voor de grafiek.
    public static func potForecast(_ db: Database, potId: Int64, today: Day, until: Day) throws -> PotForecast {
        guard let pot = try Pot.fetchOne(db, key: potId) else { throw InsightError.potNotFound(potId) }
        let history = try Row.fetchAll(db, sql: """
            SELECT day, SUM(amount) AS s FROM entry WHERE potId = ? AND accountId = ? AND day <= ? GROUP BY day ORDER BY day
            """, arguments: [potId, pot.accountId, today]).map { ($0["day"] as Day, $0["s"] as Money) }
        let startBalance = history.map(\.1).sum()
        let context = try ForecastContext(db, today: today, potId: potId)

        var running = startBalance
        let events = context.events(potId: potId, until: until).map { e -> ForecastEvent in
            running += e.amount
            return ForecastEvent(id: e.id, day: e.day, amount: e.amount, label: e.label, kind: e.kind, balanceAfter: running)
        }

        // Grafiek: echt saldo per maandeinde, dan het verwachte saldo.
        var points: [ForecastPoint] = []
        if let first = history.first?.0 {
            let earliest = Day(year: today.year - 1, month: today.month, day: 1)!
            var days = seriesDays(from: max(first, earliest), to: today, step: .monthEnd)
            if days.last != today { days.append(today) }
            points = zip(days, Q.cumulative(history, at: days)).map { ForecastPoint(day: $0, balance: $1, isForecast: false) }
        } else {
            points = [ForecastPoint(day: today, balance: startBalance, isForecast: false)]
        }
        var lowest = ForecastPoint(day: today, balance: startBalance, isForecast: false)
        for (i, e) in events.enumerated() where i == events.count - 1 || events[i + 1].day != e.day {
            let point = ForecastPoint(day: e.day, balance: e.balanceAfter, isForecast: true)
            points.append(point)
            if point.balance < lowest.balance { lowest = point }
        }
        if until > today, points.last?.day != until {
            points.append(ForecastPoint(day: until, balance: running, isForecast: true))
        }

        return PotForecast(potId: potId, potName: pot.name, today: today, until: until,
                           targetAmount: pot.targetAmount, targetDate: pot.targetDate, startBalance: startBalance,
                           events: events, overdue: (context.items[potId] ?? []).filter { $0.day <= today },
                           points: points, lowestPoint: lowest)
    }

    /// Het spaardoel van een pot op de peildag, of nil als de pot geen doelbedrag heeft.
    public static func potGoal(_ db: Database, potId: Int64, today: Day) throws -> PotGoal? {
        guard let pot = try Pot.fetchOne(db, key: potId) else { throw InsightError.potNotFound(potId) }
        let balance = try Money.fetchOne(db, sql: """
            SELECT COALESCE(SUM(amount), 0) FROM entry WHERE potId = ? AND accountId = ? AND day <= ?
            """, arguments: [potId, pot.accountId, today]) ?? .zero
        return try ForecastContext(db, today: today, potId: potId).goal(pot: pot, balance: balance)
    }

    /// Alle losse verwachtingen van een pot: eerst de open (oudste dag eerst), dan de uitgekomen (nieuwste eerst).
    public static func forecastItems(_ db: Database, potId: Int64) throws -> [ForecastItem] {
        let all = try ForecastItem.filter(Column("potId") == potId).order(Column("day"), Column("id")).fetchAll(db)
        return all.filter { !$0.isRealized } + all.filter(\.isRealized).reversed()
    }
}
