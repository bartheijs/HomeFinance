import Foundation
import GRDB
import HFCore

// MARK: - Hulpje "Nieuw jaarbedrag" (UX-stap B3)

/// Wat de gebruiker in het hulpje "Nieuw jaarbedrag" kiest: een jaarlijkse rekening (bv. Wegenbelasting) waarvoor
/// elke maand 1/12 naar een potje gaat, via een vaste storting, met de post in de begroting die meeloopt.
/// Het hulpje doet niets wat niet ook met de hand kan; het zet de bestaande stappen in de goede volgorde.
public struct AnnualAmountRequest: Equatable, Sendable {
    public enum PotChoice: Equatable, Sendable {
        case existing(Int64)
        /// Nieuwe reserveringspot met deze naam, op de spaarrekening van de vaste storting.
        case new(name: String)
    }
    public enum DistributionChoice: Equatable, Sendable {
        case existing(Int64)
        /// Nieuwe vaste storting naar deze spaarrekening, van de eerste betaalrekening.
        case new(name: String, accountId: Int64)
    }
    public enum ItemChoice: Equatable, Sendable {
        /// Een bestaande UIT-post van het jaar die nog niet aan een storting hangt.
        case existing(Int64)
        /// Een nieuwe UIT-post met dit label.
        case new(label: String)
    }

    /// Naam van de rekening; wordt het label van de verwachting.
    public var name: String
    /// Het bedrag per jaar, positief.
    public var yearlyAmount: Money
    public var pot: PotChoice
    public var distribution: DistributionChoice
    /// Alleen nodig als de storting in `year` nog geen post heeft; nil = de begroting rekent er (nog) niet mee.
    public var item: ItemChoice?
    /// Het begrotingsjaar waarin de post meeloopt.
    public var year: Int
    /// Maand (1–12) waarin de rekening komt: dan komt er een verwachting in het potje. nil = geen verwachting.
    public var forecastMonth: Int?
    /// Vandaag; bepaalt het jaar van de verwachting (deze maand of later dit jaar, anders volgend jaar).
    public var today: Day

    public init(name: String, yearlyAmount: Money, pot: PotChoice, distribution: DistributionChoice,
                item: ItemChoice? = nil, year: Int, forecastMonth: Int? = nil, today: Day) {
        self.name = name; self.yearlyAmount = yearlyAmount; self.pot = pot; self.distribution = distribution
        self.item = item; self.year = year; self.forecastMonth = forecastMonth; self.today = today
    }
}

/// Wat het hulpje gaat doen, vóór het opslaan.
public struct AnnualAmountPreview: Equatable, Sendable {
    /// Jaarbedrag ÷ 12, op centen afgerond.
    public let monthly: Money
    public let potName: String
    public let potIsNew: Bool
    public let distributionName: String
    public let distributionIsNew: Bool
    /// Wat er nu al in de storting naar dit potje gaat (0 als het er nog niet in staat).
    public let potLineBefore: Money
    /// Totaal van de storting vóór en na.
    public let totalBefore: Money
    public let totalAfter: Money
    /// De post die het totaal volgt, of nil als de begroting er niet mee rekent.
    public let itemLabel: String?
    public let itemIsNew: Bool
    /// De post is RESERVERINGEN en het jaar heeft RES-regels: het hulpje zet er een RES-regel bij (of verhoogt
    /// die van dit potje), zodat het maandgrid en "nog te besteden" meerekenen.
    public let addsReserveLine: Bool
    /// De dag van de verwachting, of nil.
    public let forecastDay: Day?
    /// Waarom de begroting er niet mee rekent (bv. het jaar is afgesloten), of nil.
    public let itemNote: String?

    /// "Er gaat elke maand € 42,00 naar potje X via vaste storting Y; je begroting rekent met € … op post Z.
    /// Let op: verhoog je overboeking bij de bank naar € …."
    public var summary: String {
        var text = "Er gaat elke maand \(monthly.formatted()) naar potje \(potName) via vaste storting \(distributionName)"
        if let itemLabel {
            text += "; je begroting rekent met \(totalAfter.formatted()) op post \(itemLabel)."
        } else {
            text += "; je begroting rekent er nog niet mee" + (itemNote.map { " (\($0))" } ?? "") + "."
        }
        if distributionIsNew {
            text += " Let op: maak bij de bank een maandelijkse overboeking van \(totalAfter.formatted()) van je betaalrekening naar je spaarrekening."
        } else {
            text += " Let op: verhoog je overboeking bij de bank naar \(totalAfter.formatted())."
        }
        return text
    }

    /// De losse stappen, in de volgorde waarin ze gebeuren.
    public var steps: [String] {
        var list: [String] = []
        list.append(potIsNew ? "Potje \(potName) wordt gemaakt (reservering)." : "Potje \(potName) bestaat al.")
        if distributionIsNew {
            list.append("Vaste storting \(distributionName) wordt gemaakt met \(monthly.formatted()) voor \(potName).")
        } else if potLineBefore.isZero {
            list.append("\(monthly.formatted()) per maand erbij in vaste storting \(distributionName) (totaal \(totalBefore.formatted()) → \(totalAfter.formatted())).")
        } else {
            list.append("\(potName) krijgt in vaste storting \(distributionName) \(monthly.formatted()) per maand extra: \((potLineBefore + monthly).formatted()) (totaal \(totalBefore.formatted()) → \(totalAfter.formatted())).")
        }
        if let itemLabel {
            list.append(itemIsNew ? "Post \(itemLabel) wordt gemaakt; het plan volgt de storting." : "Het plan van post \(itemLabel) volgt de storting: \(totalAfter.formatted()).")
        }
        if addsReserveLine { list.append("De RES-regel van \(potName) gaat \(monthly.formatted()) omhoog (of komt erbij), zodat het maandgrid meerekent.") }
        if let forecastDay {
            list.append("Verwachting in het potje: −\(Money(cents: monthly.cents * 12).formatted()) in \(Day.monthNames[forecastDay.month - 1]) \(String(forecastDay.year)).")
        }
        return list
    }

    /// Eén zin voor na afloop.
    public var afterwards: String {
        "Komt de rekening, kies dan bij het nakijken ‘uit pot \(potName)’ en laat het onthouden."
    }
}

/// Wat er gemaakt of gewijzigd is.
public struct AnnualAmountResult: Equatable, Sendable {
    public let potId: Int64
    public let distributionId: Int64
    public let itemId: Int64?
    public let forecastItemId: Int64?
}

public enum AnnualAmountService {
    /// Jaarbedrag ÷ 12, half naar boven afgerond op centen (€ 100 → € 8,33; € 504 → € 42,00).
    public static func monthly(for yearly: Money) -> Money {
        Money(cents: (yearly.cents * 2 + 12) / 24)
    }

    /// De dag van de verwachting: de 1e van `month`, dit jaar als die maand nog komt (of nu is), anders volgend jaar.
    public static func forecastDay(month: Int, today: Day) -> Day? {
        Day(year: month >= today.month ? today.year : today.year + 1, month: month, day: 1)
    }

    /// Wat het hulpje zou doen; schrijft niets. Gooit bij ongeldige keuzes (bv. een potje op een andere rekening).
    public static func preview(_ db: Database, _ request: AnnualAmountRequest) throws -> AnnualAmountPreview {
        try plan(db, request).preview
    }

    /// Voert alles in één keer uit (alles of niets).
    @discardableResult
    public static func apply(_ db: Database, _ request: AnnualAmountRequest) throws -> AnnualAmountResult {
        try atomic(db) {
            let p = try plan(db, request)
            // 1. Potje.
            let potId: Int64
            switch request.pot {
            case .existing(let id): potId = id
            case .new(let name):
                potId = try PotService.create(db, Pot(accountId: p.accountId, name: name, kind: .reservering)).id!
            }
            // 2. Vaste storting.
            let distributionId: Int64
            switch request.distribution {
            case .existing(let id): distributionId = id
            case .new(let name, let accountId):
                let source = try Int64.fetchOne(db, sql: """
                    SELECT id FROM account WHERE kind = ? AND archived = 0 ORDER BY sortOrder, id LIMIT 1
                    """, arguments: [AccountKind.betaal])
                distributionId = try DistributionService.create(db, name: name, accountId: accountId,
                                                                sourceAccountId: source).id!
            }
            try DistributionService.setLine(db, distributionId: distributionId, potId: potId,
                                            amount: p.preview.potLineBefore + p.preview.monthly)
            // 3. Post.
            var itemId = p.followingItemId
            if itemId == nil, let yearId = p.openYearId, let choice = request.item {
                switch choice {
                case .existing(let id):
                    itemId = try DistributionService.link(db, distributionId: distributionId, budgetItemId: id).id
                case .new(let label):
                    itemId = try YearService.createItem(db, BudgetItem(yearId: yearId, label: label, direction: .UIT,
                                                                       planAmount: .zero, distributionId: distributionId)).id
                }
            }
            // 4. RES-regel bij RESERVERINGEN, zodat het plan in het maandgrid meegaat.
            if p.preview.addsReserveLine, let yearId = p.openYearId {
                if var line = try BudgetItem.fetchOne(db, sql: """
                    SELECT * FROM budgetItem WHERE yearId = ? AND direction = ? AND isReserveTotal = 0 AND potId = ?
                    ORDER BY sortOrder, id LIMIT 1
                    """, arguments: [yearId, Direction.RES, potId]) {
                    line.planAmount -= p.preview.monthly
                    try YearService.updateItem(db, line)
                } else {
                    try YearService.createItem(db, BudgetItem(yearId: yearId, label: p.preview.potName, direction: .RES,
                                                              planAmount: -p.preview.monthly, potId: potId))
                }
            }
            // 5. Verwachting.
            var forecastId: Int64?
            if let day = p.preview.forecastDay {
                let label = request.name.trimmingCharacters(in: .whitespacesAndNewlines)
                forecastId = try ForecastService.create(db, potId: potId, day: day,
                                                        amount: -Money(cents: p.preview.monthly.cents * 12),
                                                        label: label.isEmpty ? p.preview.potName : label).id
            }
            return AnnualAmountResult(potId: potId, distributionId: distributionId, itemId: itemId, forecastItemId: forecastId)
        }
    }

    // MARK: Intern

    private struct Plan {
        let preview: AnnualAmountPreview
        let accountId: Int64
        let openYearId: Int64?
        let followingItemId: Int64?
    }

    private static func plan(_ db: Database, _ r: AnnualAmountRequest) throws -> Plan {
        guard r.yearlyAmount > .zero else { throw BudgetError.validation("Vul een bedrag per jaar in.") }
        let monthly = monthly(for: r.yearlyAmount)
        guard monthly > .zero else { throw BudgetError.validation("Het bedrag per jaar is te klein.") }
        if let month = r.forecastMonth, !(1...12).contains(month) {
            throw BudgetError.validation("Kies een maand van 1 t/m 12 voor de rekening.")
        }

        // Storting en spaarrekening.
        let accountId: Int64, distributionName: String, distributionId: Int64?
        switch r.distribution {
        case .existing(let id):
            let d = try DistributionService.fetch(db, id)
            guard !d.archived else { throw BudgetError.validation("De vaste storting \(d.name) is gearchiveerd.") }
            accountId = d.accountId; distributionName = d.name; distributionId = id
        case .new(let name, let account):
            distributionName = try Check.nonEmpty(name, "De naam van de vaste storting")
            guard try Check.account(db, account).kind == .spaar else {
                throw BudgetError.validation("Een vaste storting hoort bij een spaarrekening.")
            }
            accountId = account; distributionId = nil
        }

        // Potje.
        let potName: String, potId: Int64?
        switch r.pot {
        case .existing(let id):
            let pot = try Check.pot(db, id)
            guard !pot.archived else { throw BudgetError.validation("Het potje \(pot.name) is gearchiveerd.") }
            guard pot.accountId == accountId else { throw BudgetError.potWrongAccount(pot: pot.name) }
            potName = pot.name; potId = id
        case .new(let name):
            potName = try Check.nonEmpty(name, "De naam van het potje")
            let exists = try Bool.fetchOne(db, sql: """
                SELECT EXISTS(SELECT 1 FROM pot WHERE accountId = ? AND lower(name) = lower(?))
                """, arguments: [accountId, potName]) ?? false
            guard !exists else {
                throw BudgetError.validation("Er is al een potje \(potName); kies het bij ‘bestaand potje’.")
            }
            potId = nil
        }

        let lines = try distributionId.map { try DistributionService.lines(db, distributionId: $0) } ?? []
        let totalBefore = lines.map(\.amount).sum()
        let potLineBefore = lines.first { $0.potId == potId }?.amount ?? .zero

        // Post in het begrotingsjaar.
        var itemLabel: String?, itemIsNew = false, itemNote: String?, openYearId: Int64?, followingItemId: Int64?
        var followsReserveTotal = false
        let year = try BudgetYear.filter(Column("year") == r.year).fetchOne(db)
        if let year, !year.closed {
            openYearId = year.id
            let linked = try distributionId.map {
                try BudgetItem.fetchOne(db, sql: """
                    SELECT * FROM budgetItem WHERE yearId = ? AND distributionId = ? ORDER BY sortOrder, id LIMIT 1
                    """, arguments: [year.id, $0])
            } ?? nil
            if let linked {
                itemLabel = linked.label; followingItemId = linked.id; followsReserveTotal = linked.isReserveTotal
            } else if let choice = r.item {
                switch choice {
                case .existing(let id):
                    let item = try Check.item(db, id)
                    guard item.yearId == year.id, item.direction == .UIT else {
                        throw BudgetError.validation("Kies een uitgavenpost van \(String(r.year)).")
                    }
                    if let other = item.distributionId, other != distributionId {
                        let name = try DistributionService.fetch(db, other).name
                        throw BudgetError.validation("Post \(item.label) hoort al bij vaste storting \(name).")
                    }
                    itemLabel = item.label; followsReserveTotal = item.isReserveTotal
                case .new(let label):
                    itemLabel = try Check.nonEmpty(label, "Het label van de post"); itemIsNew = true
                }
            } else {
                itemNote = "er is geen post gekozen"
            }
        } else {
            itemNote = year == nil ? "het jaar \(String(r.year)) bestaat nog niet" : "\(String(r.year)) is afgesloten"
        }
        var addsReserveLine = false
        if followsReserveTotal, let yearId = openYearId {
            let count = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM budgetItem WHERE yearId = ? AND direction = ? AND isReserveTotal = 0
                """, arguments: [yearId, Direction.RES]) ?? 0
            addsReserveLine = count > 0
        }

        let preview = AnnualAmountPreview(
            monthly: monthly, potName: potName, potIsNew: potId == nil, distributionName: distributionName,
            distributionIsNew: distributionId == nil, potLineBefore: potLineBefore, totalBefore: totalBefore,
            totalAfter: totalBefore + monthly, itemLabel: itemLabel, itemIsNew: itemIsNew,
            addsReserveLine: addsReserveLine, forecastDay: r.forecastMonth.flatMap { forecastDay(month: $0, today: r.today) },
            itemNote: itemNote)
        return Plan(preview: preview, accountId: accountId, openYearId: openYearId, followingItemId: followingItemId)
    }
}
