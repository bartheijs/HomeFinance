import Foundation
import GRDB
import HFCore

// De keten post ↔ vaste storting ↔ potje (UX-stap B). Alleen weergave: de zinnen en lijstjes die de schermen tonen
// bij een post, een vaste storting en een potje. Er wordt niets anders gerekend dan in de rest van HFInsight.

// MARK: - Typen

/// Eén vaste storting zoals die in de keten verschijnt.
public struct ChainDistribution: Identifiable, Equatable, Sendable {
    /// Id van de storting.
    public let id: Int64
    public let name: String
    public let archived: Bool
    /// Som van de regels (positief).
    public let total: Money
    /// De potjes in de storting, op volgorde van de regels.
    public let potNames: [String]
    /// De posten van het gevraagde jaar die aan deze storting gekoppeld zijn (meestal één).
    public let items: [ChainItemRef]

    /// "Maandelijkse reserveringen (post RESERVERINGEN)" of "… (nog niet gekoppeld aan een post)".
    public var nameWithItem: String {
        "\(name) (\(items.isEmpty ? "nog niet gekoppeld aan een post" : Insight.chainItemList(items)))"
    }
}

/// Een post in de keten.
public struct ChainItemRef: Identifiable, Equatable, Sendable {
    public let id: Int64
    public let label: String
}

/// Wat er via één vaste storting naar een potje gaat.
public struct ChainPotLine: Identifiable, Equatable, Sendable {
    public var id: Int64 { distribution.id }
    public let distribution: ChainDistribution
    /// Het bedrag dat in deze storting naar het potje gaat (positief).
    public let amount: Money
    /// "€ 42,00 via Maandelijkse reserveringen (post RESERVERINGEN)".
    public var line: String { "\(amount.formatted()) via \(distribution.nameWithItem)" }
}

/// De keten vanuit een potje: via welke vaste stortingen het geld krijgt, en bij welke post die horen.
public struct PotChain: Equatable, Sendable {
    public let potId: Int64
    /// Alleen niet-gearchiveerde stortingen.
    public let lines: [ChainPotLine]
    /// Totaal per maand over alle stortingen.
    public var monthly: Money { lines.map(\.amount).sum() }

    /// "Krijgt € 42,00 per maand via vaste storting X (post Y)." Bij meer stortingen staat het lijstje in `lines`.
    public var sentence: String {
        switch lines.count {
        case 0: return "Krijgt geen geld via een vaste overboeking."
        case 1:
            let line = lines[0]
            return "Krijgt \(line.amount.formatted()) per maand via Automatisch sparen: \(line.distribution.nameWithItem)."
        default:
            return "Krijgt \(monthly.formatted()) per maand via \(lines.count) vaste overboekingen:"
        }
    }
}

/// De keten vanuit een post: via welke vaste storting hij naar welke potjes gaat.
public struct ItemChain: Equatable, Sendable {
    public let itemId: Int64
    /// De gekoppelde storting, of nil.
    public let distribution: ChainDistribution?

    /// "Gaat via vaste storting X naar 28 potjes." (bij één potje met de naam erbij), of nil zonder koppeling.
    public var sentence: String? {
        guard let distribution else { return nil }
        let count = distribution.potNames.count
        let target: String
        switch count {
        case 0: target = "nog geen potjes"
        case 1: target = "1 potje (\(distribution.potNames[0]))"
        default: target = "\(count) potjes"
        }
        return "Gaat via Automatisch sparen: \(distribution.name) naar \(target)."
    }
}

/// De keten vanuit een vaste storting: als welke post hij in de begroting telt.
public struct DistributionChain: Equatable, Sendable {
    public let distribution: ChainDistribution
    public let year: Int

    /// "Telt in je begroting als: post RESERVERINGEN." of een zin dat er nog geen post is.
    public var sentence: String {
        distribution.items.isEmpty
            ? "Telt nog niet in je begroting van \(String(year)): kies hieronder een post."
            : "Telt in je begroting als: \(Insight.chainItemList(distribution.items))."
    }
}

/// De keten van één begrotingsjaar, voor alle posten, stortingen en potjes tegelijk.
public struct ChainOverview: Equatable, Sendable {
    public let year: Int
    public let distributions: [ChainDistribution]
    /// Per pot-id: de stortingen waar het potje in staat (zonder gearchiveerde).
    let potLines: [Int64: [ChainPotLine]]

    public func pot(_ potId: Int64) -> PotChain { PotChain(potId: potId, lines: potLines[potId] ?? []) }

    public func item(_ itemId: Int64) -> ItemChain {
        ItemChain(itemId: itemId, distribution: distributions.first { $0.items.contains { $0.id == itemId } })
    }

    public func distribution(_ distributionId: Int64) -> DistributionChain? {
        distributions.first { $0.id == distributionId }.map { DistributionChain(distribution: $0, year: year) }
    }
}

// MARK: - Opbouw van RESERVERINGEN

/// De opbouw van de post RESERVERINGEN: de regels van de gekoppelde vaste storting, met daarnaast de oude
/// RES-regels. Het maandgrid en "nog te besteden" rekenen het plan van RESERVERINGEN nog als de som van de
/// RES-regels; daarom blijft die som zichtbaar en waarschuwt de app als de twee uit elkaar lopen.
public struct ReserveBuildup: Equatable, Sendable {
    /// Id van de post RESERVERINGEN.
    public let itemId: Int64
    public let itemLabel: String
    /// De gekoppelde vaste storting, of nil.
    public let distribution: ChainDistribution?
    /// De regels van die storting (leeg zonder koppeling).
    public let lines: [ChainBuildupLine]
    /// Som van de RES-regels van het jaar (positief) en hun aantal.
    public let reserveLineTotal: Money
    public let reserveLineCount: Int

    /// Som van de stortingsregels (positief).
    public var distributionTotal: Money { lines.map(\.amount).sum() }

    /// Waar de opbouw vandaan komt, in één zin.
    public var sentence: String {
        if let distribution {
            let count = lines.count == 1 ? "1 potje" : "\(lines.count) potjes"
            return "De opbouw komt uit Automatisch sparen: \(distribution.name) (\(count), \(distributionTotal.formatted()) per maand). Je wijzigt de verdeling bij Automatisch sparen."
        }
        if reserveLineCount > 0 {
            return "\(itemLabel) is nog niet aan een vaste overboeking gekoppeld. De opbouw komt uit de RES-regels hieronder."
        }
        return "\(itemLabel) is nog niet aan een vaste overboeking gekoppeld en heeft geen opbouw."
    }

    /// De RES-regels en de vaste storting tellen niet op tot hetzelfde bedrag. Alleen bij een koppeling met RES-regels.
    public var isOutOfStep: Bool {
        distribution != nil && reserveLineCount > 0 && reserveLineTotal != distributionTotal
    }

    /// Waarschuwing als de RES-regels en de storting uit elkaar lopen, anders nil.
    public var warning: String? {
        guard isOutOfStep, let distribution else { return nil }
        return "Let op: de RES-regels tellen op tot \(reserveLineTotal.formatted()) per maand, Automatisch sparen: \(distribution.name) tot \(distributionTotal.formatted()). Het maandgrid en \"nog over deze maand\" rekenen \(itemLabel) nog met de RES-regels. Maak de RES-regels gelijk aan de overboeking om het verschil weg te werken."
    }

    /// Uitleg bij de groep RES-regels in de begroting, als er een storting gekoppeld is.
    public var reserveLinesNote: String? {
        guard distribution != nil, reserveLineCount > 0 else { return nil }
        return "De verdeling over potjes staat bij Automatisch sparen. Deze RES-regels zijn de oude opbouw: het maandgrid rekent het plan van \(itemLabel) er nog mee, dus houd hun som gelijk aan de overboeking."
    }

    /// De stortingsregels als informatieve rijen voor het maandgrid (onder RESERVERINGEN, telt nergens mee).
    /// De id's zijn negatief, zodat ze nooit met een post botsen.
    public var gridRows: [GridRow] {
        let empty = (1...12).map {
            GridCell(month: $0, sum: .zero, entryCount: 0, status: .nietVerwacht, expected: nil, difference: .zero,
                     isChecked: false)
        }
        return lines.map { line in
            GridRow(id: -line.id, label: line.potName, direction: .RES, kind: .reserveLine, plan: -line.amount,
                    frequency: .maand, expectedMonths: [], expectedDay: nil, potId: line.potId, cells: empty,
                    yearTotal: .zero, planYearTotal: .zero)
        }
    }
}

/// Eén regel van de opbouw: dit bedrag gaat elke maand naar dit potje.
public struct ChainBuildupLine: Identifiable, Equatable, Sendable {
    /// Id van de stortingsregel.
    public let id: Int64
    public let potId: Int64
    public let potName: String
    /// Positief.
    public let amount: Money
}

// MARK: - Functies

extension Insight {
    /// "post A" of "post A en post B".
    static func chainItemList(_ items: [ChainItemRef]) -> String {
        let names = items.map { "post \($0.label)" }
        guard names.count > 1 else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " en " + names.last!
    }

    /// De keten post ↔ vaste storting ↔ potje voor het begrotingsjaar `year`: alle stortingen (ook gearchiveerde)
    /// met hun potjes en de gekoppelde posten van dat jaar.
    public static func chain(_ db: Database, year: Int) throws -> ChainOverview {
        var potNames: [Int64: [String]] = [:]
        var totals: [Int64: Money] = [:]
        var linesByPot: [(distributionId: Int64, potId: Int64, amount: Money)] = []
        for r in try Row.fetchAll(db, sql: """
            SELECT l.distributionId, l.potId, l.amount, p.name AS potName
            FROM distributionLine l JOIN pot p ON p.id = l.potId ORDER BY l.sortOrder, l.id
            """) {
            let distributionId: Int64 = r["distributionId"]
            potNames[distributionId, default: []].append(r["potName"])
            totals[distributionId, default: .zero] += r["amount"] as Money
            linesByPot.append((distributionId, r["potId"], r["amount"]))
        }
        var items: [Int64: [ChainItemRef]] = [:]
        for r in try Row.fetchAll(db, sql: """
            SELECT i.id, i.label, i.distributionId FROM budgetItem i JOIN budgetYear y ON y.id = i.yearId
            WHERE y.year = ? AND i.distributionId IS NOT NULL ORDER BY i.sortOrder, i.id
            """, arguments: [year]) {
            items[r["distributionId"], default: []].append(ChainItemRef(id: r["id"], label: r["label"]))
        }
        let distributions = try Row.fetchAll(db, sql: "SELECT id, name, archived FROM distribution ORDER BY sortOrder, id")
            .map { r -> ChainDistribution in
                let id: Int64 = r["id"]
                return ChainDistribution(id: id, name: r["name"], archived: r["archived"], total: totals[id] ?? .zero,
                                         potNames: potNames[id] ?? [], items: items[id] ?? [])
            }
        let byId = Dictionary(uniqueKeysWithValues: distributions.map { ($0.id, $0) })
        var potLines: [Int64: [ChainPotLine]] = [:]
        // Op volgorde van de stortingen, niet van de regels.
        for distribution in distributions where !distribution.archived {
            for line in linesByPot where line.distributionId == distribution.id {
                potLines[line.potId, default: []].append(ChainPotLine(distribution: byId[distribution.id]!, amount: line.amount))
            }
        }
        return ChainOverview(year: year, distributions: distributions, potLines: potLines)
    }

    /// De opbouw van de post RESERVERINGEN van `year`, of nil als dat jaar of die post niet bestaat.
    public static func reserveBuildup(_ db: Database, year: Int) throws -> ReserveBuildup? {
        guard let budgetYear = try BudgetYear.filter(Column("year") == year).fetchOne(db) else { return nil }
        let items = try Q.items(db, yearId: budgetYear.id!)
        guard let total = items.first(where: \.isReserveTotal) else { return nil }
        let reserveLines = items.filter(\.isReserveLine)
        var distribution: ChainDistribution?
        var lines: [ChainBuildupLine] = []
        if let distributionId = total.distributionId {
            distribution = try chain(db, year: year).distributions.first { $0.id == distributionId }
            lines = try Row.fetchAll(db, sql: """
                SELECT l.id, l.potId, p.name AS potName, l.amount FROM distributionLine l JOIN pot p ON p.id = l.potId
                WHERE l.distributionId = ? ORDER BY l.sortOrder, l.id
                """, arguments: [distributionId]).map {
                ChainBuildupLine(id: $0["id"], potId: $0["potId"], potName: $0["potName"], amount: $0["amount"])
            }
        }
        return ReserveBuildup(itemId: total.id!, itemLabel: total.label, distribution: distribution, lines: lines,
                              reserveLineTotal: reserveLines.map(\.planAmount).sum().magnitude,
                              reserveLineCount: reserveLines.count)
    }
}
