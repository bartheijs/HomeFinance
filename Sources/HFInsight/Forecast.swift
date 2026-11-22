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
    /// De gemiddelde uitgaven per maand uit het verleden (`Pot.forecastFromHistory`), één keer per maand.
    case historyAverage
}

/// Gemiddelde uitgaven per maand van een pot uit het verleden, voor de vooruitblik (`Pot.forecastFromHistory`).
/// Over de afgelopen `historyMonths` hele maanden (of korter als de pot jonger is), zonder boekingen die als
/// eenmalig gemarkeerd zijn (`Entry.forecastOneOff`) en zonder boekingen waarmee een losse verwachting is
/// uitgekomen (die staan al als verwachting in de vooruitblik).
public struct PotHistoryAverage: Equatable, Sendable {
    /// Gemiddeld per maand (negatief of nul).
    public let perMonth: Money
    /// Over hoeveel maanden.
    public let months: Int
}

/// Eén verwachte mutatie van een pot.
public struct ForecastEvent: Identifiable, Equatable, Sendable {
    public let id: String
    public let day: Day
    /// Met teken: positief = erbij, negatief = eraf.
    public let amount: Money
    public let label: String
    public let kind: ForecastEventKind
    /// Het project van een losse verwachting (`ForecastItem.project`), of nil.
    public let project: String?
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
    /// De pot rekent met eerdere uitgaven (`Pot.forecastFromHistory`).
    public var usesHistory: Bool = false
    /// Het gemiddelde waarmee gerekend wordt (ook als de schakelaar uit staat, om te tonen wat het zou zijn); nil
    /// als er nog geen hele maand met boekingen is.
    public var historyAverage: PotHistoryAverage? = nil

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
    /// De onderdelen waaruit het doelbedrag is opgebouwd (`GoalPart`), of leeg.
    public let parts: [GoalPartRow]
    /// Som van de onderdelen (€ 0,00 zonder onderdelen).
    public let partsTotal: Money
    /// De marge op het doel (`GoalMargin`): zoveel mag het verwachte saldo op de doeldatum onder het doel blijven.
    public var margin: Money = .zero
    /// Op koers dankzij de marge: het verwachte saldo op de doeldatum blijft (iets) onder het doel.
    public var isWithinMargin: Bool {
        status == .opKoers && (projectedOnTargetDate ?? balance) < targetAmount
    }
}

/// Eén onderdeel van een spaardoel: aantal × bedrag per stuk.
public struct GoalPartRow: Identifiable, Equatable, Sendable {
    public let id: Int64
    public let label: String
    public let quantity: Int
    public let unitAmount: Money
    /// `quantity` × `unitAmount`.
    public let amount: Money
}

/// Eén regel van een project, met wat er werkelijk betaald is als de regel is afgevinkt.
public struct ForecastProjectItem: Identifiable, Equatable, Sendable {
    public var id: Int64 { item.id ?? 0 }
    public let item: ForecastItem
    /// Afgevinkt: het bedrag van de gekoppelde echte boeking, of anders het verwachte bedrag. Open: nil.
    public let realizedAmount: Money?
}

/// De verwachtingen van één project (bv. een vakantie) als begroting: gepland, betaald, nog te komen.
public struct ForecastProject: Identifiable, Equatable, Sendable {
    public var id: String { name }
    public let name: String
    /// De regels, oudste dag eerst.
    public let items: [ForecastProjectItem]
    /// Som van alle regels (verwachte bedragen, met teken).
    public let planned: Money
    /// Som van de afgevinkte regels (werkelijk bedrag waar bekend).
    public let realized: Money
    /// Som van de nog open regels.
    public let remaining: Money
    public let count: Int
    public let openCount: Int
    /// Open regels met een dag op of vóór de peildag.
    public let overdueCount: Int
    public let firstDay: Day
    public let lastDay: Day
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
    typealias RawEvent = (day: Day, amount: Money, label: String, kind: ForecastEventKind, id: String, project: String?)

    let today: Day
    /// Marge op een spaardoel in basispunten (`GoalMargin`).
    var marginBasisPoints = GoalMargin.defaultBasisPoints
    /// Open losse verwachtingen per pot, op dag.
    var items: [Int64: [ForecastItem]] = [:]
    /// Regels van niet-gearchiveerde vaste stortingen per pot, op volgorde van de stortingen.
    var lines: [Int64: [Line]] = [:]
    /// Onderdelen van het spaardoel per pot.
    var parts: [Int64: [GoalPartRow]] = [:]
    /// Gemiddelde uitgaven per maand voor potten met `forecastFromHistory` (alleen die tellen in `events`).
    var averages: [Int64: PotHistoryAverage] = [:]

    init(_ db: Database, today: Day, potId: Int64? = nil) throws {
        self.today = today
        marginBasisPoints = try GoalMargin.basisPoints(db)
        var request = ForecastItem.filter(Column("realizedAt") == nil)
        if let potId { request = request.filter(Column("potId") == potId) }
        for item in try request.order(Column("day"), Column("id")).fetchAll(db) {
            items[item.potId, default: []].append(item)
        }
        var partRequest = GoalPart.order(Column("sortOrder"), Column("id"))
        if let potId { partRequest = partRequest.filter(Column("potId") == potId) }
        for part in try partRequest.fetchAll(db) {
            parts[part.potId, default: []].append(GoalPartRow(id: part.id!, label: part.label, quantity: part.quantity,
                                                              unitAmount: part.unitAmount, amount: part.amount))
        }
        var flagged = Pot.filter(Column("forecastFromHistory") == true)
        if let potId { flagged = flagged.filter(Column("id") == potId) }
        for pot in try flagged.fetchAll(db) {
            if let average = try Self.historyAverage(db, pot: pot, today: today) { averages[pot.id!] = average }
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

    /// Aantal hele maanden waarover het gemiddelde loopt.
    static let historyMonths = 12

    /// Het gemiddelde van de uitgaven per maand over de hele maanden vóór de lopende maand (hoogstens
    /// `historyMonths`, vanaf de maand van de eerste boeking op de pot). Nil als er nog geen hele maand is.
    static func historyAverage(_ db: Database, pot: Pot, today: Day) throws -> PotHistoryAverage? {
        guard let potId = pot.id,
              let first = try Day.fetchOne(db, sql: "SELECT MIN(day) FROM entry WHERE potId = ? AND accountId = ?",
                                           arguments: [potId, pot.accountId]) else { return nil }
        let monthsSinceFirst = (today.year - first.year) * 12 + (today.month - first.month)
        let months = min(historyMonths, monthsSinceFirst)
        guard months > 0 else { return nil }
        let index = today.year * 12 + (today.month - 1) - months
        let start = Day(year: index / 12, month: index % 12 + 1, day: 1)!
        let end = Day(year: today.year, month: today.month, day: 1)!.adding(days: -1)
        let total = try Money.fetchOne(db, sql: """
            SELECT COALESCE(SUM(e.amount), 0) FROM entry e
            WHERE e.potId = ? AND e.accountId = ? AND e.amount < 0 AND e.day >= ? AND e.day <= ?
              AND e.forecastOneOff = 0
              AND NOT EXISTS (SELECT 1 FROM forecastItem f WHERE f.realizedEntryId = e.id)
            """, arguments: [potId, pot.accountId, start, end]) ?? .zero
        return PotHistoryAverage(perMonth: Money(cents: total.cents / Int64(months)), months: months)
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
            .map { item -> RawEvent in
                let project = item.project.trimmingCharacters(in: .whitespaces)
                return (item.day, item.amount, item.label, .oneOff(forecastItemId: item.id!), "los-\(item.id!)",
                        project.isEmpty ? nil : project)
            }
        for line in lines[potId] ?? [] {
            for day in depositDays(lastDeposit: line.lastDeposit, until: until) {
                raw.append((day, line.amount, line.name, .recurring(distributionId: line.distributionId),
                            "vast-\(line.distributionId)-\(Q.periodKey(day.year, day.month))", nil))
            }
        }
        if let average = averages[potId], average.perMonth < .zero {
            // Vanaf de maand na vandaag, halverwege de maand: de uitgaven van deze maand zitten al (deels) in het saldo.
            var (y, m) = today.month == 12 ? (today.year + 1, 1) : (today.year, today.month + 1)
            while let day = Day(year: y, month: m, day: 15), day <= until {
                raw.append((day, average.perMonth, "Gemiddelde uitgaven", .historyAverage,
                            "gem-\(Q.periodKey(y, m))", nil))
                (y, m) = m == 12 ? (y + 1, 1) : (y, m + 1)
            }
        }
        return raw.sorted { ($0.day, $1.amount, $0.id) < ($1.day, $0.amount, $1.id) }
    }

    /// De dag 10 jaar na vandaag: zo ver kijkt de vooruitblik voor doel en herstel.
    var horizon: Day { Day(year: today.year + 10, month: today.month, day: min(today.day, 28))! }

    /// Voor een pot met een negatief saldo: wanneer de vooruitblik weer op of boven nul komt.
    func recovery(potId: Int64, balance: Money) -> PotRecovery? {
        guard balance < .zero else { return nil }
        let perMonth = (lines[potId] ?? []).map(\.amount).sum()
        var running = balance
        var date: Day?
        for e in events(potId: potId, until: horizon) {
            running += e.amount
            if running >= .zero { date = e.day; break }
        }
        let status: PotRecoveryStatus = date != nil ? .herstelt
            : (perMonth > .zero ? .duurtLangerDan10Jaar : .wordtNietAangevuld)
        return PotRecovery(shortfall: -balance, perMonth: perMonth, recoveryDate: date, status: status)
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
        // Binnen de marge onder het doel telt als op koers (UX-feedback: 4 cent per maand te weinig is geen actie).
        let margin = GoalMargin.amount(of: target, basisPoints: marginBasisPoints)
        let status: PotGoalStatus
        if reached { status = .bereikt }
        else if let date = pot.targetDate {
            if date < today { status = .verlopen }
            else { status = (projected ?? balance) >= target - margin ? .opKoers : .tekort }
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
                       status: status, projectedReachDate: reachDate,
                       parts: parts[potId] ?? [], partsTotal: (parts[potId] ?? []).map(\.amount).sum(),
                       margin: margin)
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
            return ForecastEvent(id: e.id, day: e.day, amount: e.amount, label: e.label, kind: e.kind,
                                 project: e.project, balanceAfter: running)
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

        var forecast = PotForecast(potId: potId, potName: pot.name, today: today, until: until,
                                   targetAmount: pot.targetAmount, targetDate: pot.targetDate, startBalance: startBalance,
                                   events: events, overdue: (context.items[potId] ?? []).filter { $0.day <= today },
                                   points: points, lowestPoint: lowest)
        forecast.usesHistory = pot.forecastFromHistory
        forecast.historyAverage = try ForecastContext.historyAverage(db, pot: pot, today: today)
        return forecast
    }

    /// Het spaardoel van een pot op de peildag, of nil als de pot geen doelbedrag heeft.
    public static func potGoal(_ db: Database, potId: Int64, today: Day) throws -> PotGoal? {
        guard let pot = try Pot.fetchOne(db, key: potId) else { throw InsightError.potNotFound(potId) }
        let balance = try Money.fetchOne(db, sql: """
            SELECT COALESCE(SUM(amount), 0) FROM entry WHERE potId = ? AND accountId = ? AND day <= ?
            """, arguments: [potId, pot.accountId, today]) ?? .zero
        return try ForecastContext(db, today: today, potId: potId).goal(pot: pot, balance: balance)
    }

    /// De projecten van een pot: per niet-lege `ForecastItem.project` de regels met wat gepland, betaald en nog
    /// te komen is. Het project met de laatste dag het verst in de toekomst staat eerst.
    public static func forecastProjects(_ db: Database, potId: Int64, today: Day) throws -> [ForecastProject] {
        var groups: [String: [ForecastProjectItem]] = [:]
        for r in try Row.fetchAll(db, sql: """
            SELECT f.*, e.amount AS entryAmount FROM forecastItem f LEFT JOIN entry e ON e.id = f.realizedEntryId
            WHERE f.potId = ? AND trim(f.project) <> '' ORDER BY f.day, f.id
            """, arguments: [potId]) {
            let item = try ForecastItem(row: r)
            let actual: Money? = r["entryAmount"]
            groups[item.project.trimmingCharacters(in: .whitespaces), default: []].append(
                ForecastProjectItem(item: item, realizedAmount: item.isRealized ? (actual ?? item.amount) : nil))
        }
        return groups.map { name, items in
            let open = items.filter { !$0.item.isRealized }
            return ForecastProject(name: name, items: items, planned: items.map(\.item.amount).sum(),
                                   realized: items.compactMap(\.realizedAmount).sum(),
                                   remaining: open.map(\.item.amount).sum(), count: items.count, openCount: open.count,
                                   overdueCount: open.filter { $0.item.day <= today }.count,
                                   firstDay: items.first!.item.day, lastDay: items.last!.item.day)
        }
        .sorted { ($0.lastDay, $1.name) > ($1.lastDay, $0.name) }
    }

    /// Alle losse verwachtingen van een pot: eerst de open (oudste dag eerst), dan de uitgekomen (nieuwste eerst).
    public static func forecastItems(_ db: Database, potId: Int64) throws -> [ForecastItem] {
        let all = try ForecastItem.filter(Column("potId") == potId).order(Column("day"), Column("id")).fetchAll(db)
        return all.filter { !$0.isRealized } + all.filter(\.isRealized).reversed()
    }
}
