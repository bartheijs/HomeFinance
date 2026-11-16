import Foundation
import GRDB
import HFCore

// MARK: - Typen

/// Eén pot met saldo en voortgang.
public struct PotSummary: Identifiable, Equatable, Sendable {
    public let id: Int64
    public let accountId: Int64
    public let name: String
    public let kind: PotKind
    public let owner: String?
    public let archived: Bool
    /// Som van de boekingen op de spaarrekening met deze pot, t/m de peildag.
    public let balance: Money
    public let monthlyAmount: Money
    /// Som van de regels van deze pot in alle niet-gearchiveerde vaste stortingen.
    public let distributionAmount: Money
    public let targetAmount: Money?
    /// Doeldatum van het spaardoel, of nil.
    public let targetDate: Day?
    /// Het spaardoel uitgewerkt (status, nodig per maand, tekort), of nil zonder doelbedrag.
    public let goal: PotGoal?
    /// Saldo ÷ doel (0…1 en hoger), of nil zonder doel. Alleen voor weergave.
    public let progress: Double?
    /// Nog te sparen tot het doel (nooit negatief), of nil zonder doel.
    public let remainingToTarget: Money?
    /// Stortingen dit jaar (positief).
    public let depositsThisYear: Money
    /// Opnames dit jaar (negatief).
    public let withdrawalsThisYear: Money
    public let lastMovement: Day?
    /// Aantal losse verwachtingen (`ForecastItem`) die nog niet zijn uitgekomen.
    public let openForecastCount: Int
    /// Voor een pot die in de min staat: hoe en wanneer hij weer op nul komt. nil als het saldo niet negatief is.
    public let recovery: PotRecovery?
    /// Nog te verrekenen met de betaalrekening volgens de open gemarkeerde boekingen: positief = gaat nog uit de
    /// pot, negatief = komt er nog bij. € 0,00 als er niets openstaat.
    public let pendingSettlement: Money
}

/// Of en wanneer een pot die in de min staat weer wordt aangevuld.
public enum PotRecoveryStatus: String, Sendable, CaseIterable {
    /// De vooruitblik komt op of boven nul; zie `recoveryDate`.
    case herstelt
    /// Er is geen vaste storting en geen verwachting die het tekort oplost.
    case wordtNietAangevuld
    /// Er komt wel geld bij, maar binnen 10 jaar niet genoeg.
    case duurtLangerDan10Jaar
}

/// Een pot met een negatief saldo: het geld is geleend van de andere potten op dezelfde spaarrekening.
public struct PotRecovery: Equatable, Sendable {
    /// Het bedrag onder nul (positief).
    public let shortfall: Money
    /// Wat er per maand bij komt via niet-gearchiveerde vaste stortingen.
    public let perMonth: Money
    /// De eerste dag waarop de vooruitblik (vaste stortingen en open losse verwachtingen) op of boven nul komt,
    /// tot 10 jaar vooruit; nil als dat niet gebeurt.
    public let recoveryDate: Day?
    public let status: PotRecoveryStatus
}

/// Een spaarrekening met zijn potten.
public struct SavingsAccountPots: Identifiable, Equatable, Sendable {
    public let id: Int64
    public let name: String
    public let archived: Bool
    /// Saldo van de rekening = beginsaldo + boekingen.
    public let balance: Money
    /// Som van alle potten.
    public let potTotal: Money
    /// Niet toegewezen = saldo − som van de potten.
    public let unallocated: Money
    /// Som van de negatieve potsaldi als positief bedrag: geleend van de andere potten op deze rekening.
    public let borrowedFromOtherPots: Money
    /// Aantal potten met een negatief saldo.
    public let negativePotCount: Int
    public let pots: [PotSummary]
}

/// Potten van één soort.
public struct PotKindGroup: Identifiable, Equatable, Sendable {
    public var id: PotKind { kind }
    public let kind: PotKind
    public let total: Money
    public let monthlyTotal: Money
    public let pots: [PotSummary]
}

/// Potten van één eigenaar (`owner` nil = zonder eigenaar).
public struct PotOwnerGroup: Identifiable, Equatable, Sendable {
    public var id: String { owner ?? "" }
    public let owner: String?
    public let total: Money
    public let monthlyTotal: Money
    public let pots: [PotSummary]
}

/// Overzicht van potten en spaarrekeningen.
public struct PotOverview: Equatable, Sendable {
    public let accounts: [SavingsAccountPots]
    public let byKind: [PotKindGroup]
    public let byOwner: [PotOwnerGroup]
    public let totalBalance: Money
    public let totalPots: Money
    public let totalUnallocated: Money
    /// Som van alle negatieve potsaldi als positief bedrag.
    public let borrowedFromOtherPots: Money
    public let negativePotCount: Int
}

/// Twee boekingen zonder pot op dezelfde spaarrekening met exact tegengestelde bedragen: ze heffen elkaar op.
public struct CancelledPair: Identifiable, Equatable, Sendable {
    public var id: String { "\(first.id)-\(second.id)" }
    /// De oudste van de twee (bij gelijke dag de eerst geboekte).
    public let first: EntryRow
    public let second: EntryRow
    /// Het bedrag zonder teken.
    public var amount: Money { first.amount.magnitude }
}

/// Boekingen op spaarrekeningen zonder pot, zonder de paren die elkaar opheffen. Het saldo "niet toegewezen" van
/// een rekening (`SavingsAccountPots.unallocated`) verandert hier niet door: opgeheven boekingen tellen daar
/// gewoon mee en zijn samen € 0,00.
public struct UnallocatedSavings: Equatable, Sendable {
    /// De boekingen zonder pot die niet zijn opgeheven, nieuwste eerst.
    public let entries: [EntryRow]
    /// De paren die elkaar opheffen, nieuwste paar eerst.
    public let cancelledPairs: [CancelledPair]
    /// Som van `entries`.
    public let remainingTotal: Money
    /// Aantal opgeheven boekingen (2 × het aantal paren).
    public let cancelledCount: Int
}

/// Boeking van een pot met het saldo van de pot ná die boeking.
public struct PotHistoryRow: Identifiable, Equatable, Sendable {
    public var id: Int64 { entry.id }
    public let entry: EntryRow
    public let runningBalance: Money
}

/// Richting van een overboeking tussen spaar- en betaalrekening.
public enum SavingsTransferDirection: String, Sendable, CaseIterable {
    /// Van spaar naar betaal (netto meer uitgaven dan bijschrijvingen).
    case fromSavings
    /// Van betaal naar spaar (netto meer bijschrijvingen dan uitgaven).
    case toSavings
    /// Netto niets over te maken; er kan nog wel tussen potten verrekend worden.
    case none

    init(net: Money) { self = net > .zero ? .fromSavings : (net < .zero ? .toSavings : .none) }
}

/// Te verrekenen bedrag per pot (`potId` nil = geen pot gekozen).
public struct ReimbursementPotTotal: Identifiable, Equatable, Sendable {
    public var id: Int64 { potId ?? 0 }
    public let potId: Int64?
    public let potName: String?
    /// Som van de boekingen met hun teken (uitgaven negatief, bijschrijvingen positief).
    public let total: Money
    /// Wat de pot uit gaat (positief) of in komt (negatief) = −`total`.
    public let amount: Money
    public let count: Int
    /// Het potsaldo na het verrekenen (huidig saldo − `amount`); nil zonder pot en in de historie.
    public let balanceAfter: Money?
}

/// Gemarkeerde boekingen op betaalrekeningen die nog met spaar verrekend moeten worden: uitgaven die uit een
/// pot komen en bijschrijvingen die naar een pot gaan, gesaldeerd tot één overboeking.
public struct OpenReimbursements: Equatable, Sendable {
    public let entries: [EntryRow]
    /// Som van de boekingen met hun teken = −`net`.
    public let total: Money
    /// Som van de uitgaven (positief): komt uit spaar.
    public let fromSavings: Money
    /// Som van de bijschrijvingen (positief): gaat naar spaar.
    public let toSavings: Money
    /// `fromSavings` − `toSavings`: positief = van spaar naar betaal, negatief = van betaal naar spaar.
    public let net: Money
    /// Het over te maken bedrag zonder teken = |`net`|.
    public let transferAmount: Money
    public let direction: SavingsTransferDirection
    public let perPot: [ReimbursementPotTotal]
    /// Aantal boekingen waarbij nog geen pot is gekozen.
    public let withoutPotCount: Int
}

/// Een overboeking tussen spaar en betaal met de boekingen die erin verrekend zijn.
public struct SavingsTransferDetail: Identifiable, Equatable, Sendable {
    public let id: Int64
    public let day: Day
    /// Netto bedrag met teken: positief = van spaar naar betaal, negatief = van betaal naar spaar.
    public let amount: Money
    /// Het overgemaakte bedrag zonder teken.
    public let transferAmount: Money
    public let direction: SavingsTransferDirection
    /// Afgevinkt: de overboeking bij de bank is gedaan.
    public let done: Bool
    public let doneAt: Date?
    public let note: String
    /// De verrekende boekingen op de betaalrekening, oudste eerst.
    public let entries: [EntryRow]
    /// Som van die boekingen met hun teken; hoort −`amount` te zijn.
    public let entriesTotal: Money
    public let perPot: [ReimbursementPotTotal]
    /// De potmutaties op de spaarrekening die bij deze overboeking geboekt zijn.
    public let potEntries: [EntryRow]
    /// De potmutaties zijn al geboekt (er zijn verrekeningsboekingen op een spaarrekening).
    public let potMutationsBooked: Bool
    /// Alle boekingen die de verrekening zelf heeft gemaakt: de potmutaties op de spaarrekening en de tegenboeking
    /// op de betaalrekening.
    public let bookings: [EntryRow]
    /// Aan de boeking op de betaalrekening hangt een bankregel.
    public let checkingBankConfirmed: Bool
    /// Aan de boekingen op de spaarrekening hangt een bankregel.
    public let savingsBankConfirmed: Bool
    /// De oudste dag van een verrekeningsboeking waar nog geen bankregel aan hangt, of nil als alles bevestigd is
    /// of de verrekening nog niet is afgevinkt. Een bankregel verschuift de boeking naar de dag van de bank.
    public let unconfirmedSince: Day?

    /// Afgevinkt (zelfde als `done`).
    public var isDone: Bool { done }
    /// De overboeking is aan beide kanten in een bankbestand gezien. Bij netto nul is er geen overboeking en is
    /// dit altijd waar.
    public var bankConfirmed: Bool { amount.isZero || (checkingBankConfirmed && savingsBankConfirmed) }
}

/// Hoe `HFBudget` de boekingen van een verrekening met spaar markeert (`SavingsTransferService.markDone`): de
/// instelling `savingsTransfer.<id>.entries` bevat de id's van de boekingen die het afvinken heeft gemaakt (de
/// potmutaties op de spaarrekening en de boeking op de betaalrekening). De notitie "Verrekening #<id>" is alleen
/// voor de gebruiker; de koppeling hangt er niet van af. Een bankregel aan een kant is een `bankTransactionId` op
/// de boekingen van die kant (`attach`).
struct TransferMarkers {
    /// Boeking-id → id van de verrekening.
    var entryTransfer: [Int64: Int64] = [:]

    init(_ db: Database) throws {
        for r in try Row.fetchAll(db, sql: "SELECT key, value FROM setting WHERE key LIKE 'savingsTransfer.%.entries'") {
            let parts = (r["key"] as String).split(separator: ".")
            guard parts.count == 3, let transferId = Int64(parts[1]) else { continue }
            for id in (r["value"] as String).split(separator: ",").compactMap({ Int64($0.trimmingCharacters(in: .whitespaces)) }) {
                entryTransfer[id] = transferId
            }
        }
    }

    func transferId(of row: EntryRow) -> Int64? { entryTransfer[row.id] }

    /// SQL-voorwaarde die alle verrekeningsboekingen selecteert.
    var clause: String {
        entryTransfer.isEmpty ? "0" : "e.id IN (\(entryTransfer.keys.map(String.init).joined(separator: ",")))"
    }
}

// MARK: - Functies

extension Insight {
    /// Potten per spaarrekening, per soort en per eigenaar. `accountId` nil = alle spaarrekeningen.
    /// Saldi tellen boekingen t/m `today`; "dit jaar" is het jaar van `today`.
    public static func potOverview(_ db: Database, accountId: Int64? = nil, today: Day) throws -> PotOverview {
        var accountSQL = """
            SELECT a.id, a.name, a.archived,
                   a.openingBalance + COALESCE((SELECT SUM(e.amount) FROM entry e
                                                WHERE e.accountId = a.id AND e.day <= ?), 0) AS balance
            FROM account a WHERE a.kind = 'spaar'
            """
        var args: [(any DatabaseValueConvertible)?] = [today]
        if let accountId { accountSQL += " AND a.id = ?"; args.append(accountId) }
        accountSQL += " ORDER BY a.sortOrder, a.id"
        let accountRows = try Row.fetchAll(db, sql: accountSQL, arguments: StatementArguments(args))

        let yearStart = Q.yearStart(today.year)
        let potRows = try Row.fetchAll(db, sql: """
            SELECT p.*, COALESCE(SUM(e.amount), 0) AS bal,
                   COALESCE(SUM(CASE WHEN e.amount > 0 AND e.day >= ? THEN e.amount ELSE 0 END), 0) AS dep,
                   COALESCE(SUM(CASE WHEN e.amount < 0 AND e.day >= ? THEN e.amount ELSE 0 END), 0) AS wd,
                   MAX(e.day) AS lastDay,
                   (SELECT COALESCE(SUM(l.amount), 0) FROM distributionLine l
                    JOIN distribution d ON d.id = l.distributionId
                    WHERE l.potId = p.id AND d.archived = 0) AS distributed,
                   (SELECT COUNT(*) FROM forecastItem f WHERE f.potId = p.id AND f.realizedAt IS NULL) AS openForecasts
            FROM pot p
            LEFT JOIN entry e ON e.potId = p.id AND e.accountId = p.accountId AND e.day <= ?
            GROUP BY p.id ORDER BY p.sortOrder, p.id
            """, arguments: [yearStart, yearStart, today])
        let accountIds = Set(accountRows.map { $0["id"] as Int64 })
        // Eén keer laden voor alle potten; het spaardoel per pot rekent daarna zonder verdere queries.
        let forecast = try ForecastContext(db, today: today)
        let pending = try pendingSettlements(db)
        let pots = try potRows.compactMap { r -> PotSummary? in
            let pot = try Pot(row: r)
            guard accountIds.contains(pot.accountId) else { return nil }
            let balance: Money = r["bal"]
            let target = pot.targetAmount.flatMap { $0 > .zero ? $0 : nil }
            return PotSummary(id: pot.id!, accountId: pot.accountId, name: pot.name, kind: pot.kind, owner: pot.owner,
                              archived: pot.archived, balance: balance, monthlyAmount: pot.monthlyAmount,
                              distributionAmount: r["distributed"], targetAmount: pot.targetAmount,
                              targetDate: pot.targetDate, goal: forecast.goal(pot: pot, balance: balance),
                              progress: target.map { max(0, balance.doubleValue / $0.doubleValue) },
                              remainingToTarget: target.map { max(.zero, $0 - balance) },
                              depositsThisYear: r["dep"], withdrawalsThisYear: r["wd"], lastMovement: r["lastDay"],
                              openForecastCount: r["openForecasts"],
                              recovery: forecast.recovery(potId: pot.id!, balance: balance),
                              pendingSettlement: pending[pot.id!] ?? .zero)
        }

        let accounts = accountRows.map { r -> SavingsAccountPots in
            let id: Int64 = r["id"]
            let own = pots.filter { $0.accountId == id }
            let balance: Money = r["balance"]
            let potTotal = own.map(\.balance).sum()
            return SavingsAccountPots(id: id, name: r["name"], archived: r["archived"], balance: balance,
                                      potTotal: potTotal, unallocated: balance - potTotal,
                                      borrowedFromOtherPots: -own.map(\.balance).filter { $0 < .zero }.sum(),
                                      negativePotCount: own.filter { $0.balance < .zero }.count, pots: own)
        }
        let byKind = PotKind.allCases.compactMap { kind -> PotKindGroup? in
            let group = pots.filter { $0.kind == kind }
            guard !group.isEmpty else { return nil }
            return PotKindGroup(kind: kind, total: group.map(\.balance).sum(),
                                monthlyTotal: group.map(\.monthlyAmount).sum(), pots: group)
        }
        let owners = Set(pots.map(\.owner)).sorted { a, b in
            switch (a, b) {
            case let (x?, y?): return x.localizedCaseInsensitiveCompare(y) == .orderedAscending
            case (nil, _): return false
            case (_, nil): return true
            }
        }
        let byOwner = owners.map { owner -> PotOwnerGroup in
            let group = pots.filter { $0.owner == owner }
            return PotOwnerGroup(owner: owner, total: group.map(\.balance).sum(),
                                 monthlyTotal: group.map(\.monthlyAmount).sum(), pots: group)
        }
        return PotOverview(accounts: accounts, byKind: byKind, byOwner: byOwner,
                           totalBalance: accounts.map(\.balance).sum(), totalPots: accounts.map(\.potTotal).sum(),
                           totalUnallocated: accounts.map(\.unallocated).sum(),
                           borrowedFromOtherPots: accounts.map(\.borrowedFromOtherPots).sum(),
                           negativePotCount: accounts.map(\.negativePotCount).reduce(0, +))
    }

    /// Alle boekingen van een pot op zijn spaarrekening, oudste eerst, met het oplopende saldo.
    public static func potHistory(_ db: Database, potId: Int64) throws -> [PotHistoryRow] {
        guard let accountId = try Int64.fetchOne(db, sql: "SELECT accountId FROM pot WHERE id = ?", arguments: [potId]) else {
            throw InsightError.potNotFound(potId)
        }
        var running = Money.zero
        return try entryRows(db, where: "e.potId = ? AND e.accountId = ?", arguments: [potId, accountId],
                             order: "e.day ASC, e.id ASC").map {
            running += $0.amount
            return PotHistoryRow(entry: $0, runningBalance: running)
        }
    }

    /// Boekingen op spaarrekeningen zonder pot die elkaar niet opheffen (nieuwste eerst), dus de `entries` van
    /// `unallocatedSavingsOverview`. `accountId` nil = alle spaarrekeningen.
    public static func unallocatedSavingsEntries(_ db: Database, accountId: Int64? = nil) throws -> [EntryRow] {
        try unallocatedSavingsOverview(db, accountId: accountId).entries
    }

    /// Boekingen op spaarrekeningen zonder pot, met de paren die elkaar opheffen apart gehouden. Twee boekingen
    /// zonder pot op dezelfde spaarrekening heffen elkaar op als hun bedragen exact tegengesteld zijn en hun dagen
    /// hooguit 45 dagen uit elkaar liggen. Per bedrag wordt greedy gekoppeld aan de dichtstbijzijnde dag
    /// (bij gelijke afstand de oudste eerst); elke boeking zit in hoogstens één paar.
    /// `accountId` nil = alle spaarrekeningen; paren worden nooit over rekeningen heen gekoppeld.
    public static func unallocatedSavingsOverview(_ db: Database, accountId: Int64? = nil) throws -> UnallocatedSavings {
        var clause = "a.kind = 'spaar' AND e.potId IS NULL"
        var args: [(any DatabaseValueConvertible)?] = []
        if let accountId { clause += " AND e.accountId = ?"; args.append(accountId) }
        let all = try entryRows(db, where: clause, arguments: args)

        // Kandidaten: positieve en negatieve boeking met hetzelfde bedrag op dezelfde rekening.
        struct Key: Hashable { let account: Int64; let cents: Int64 }
        var positives: [Key: [EntryRow]] = [:], negatives: [Key: [EntryRow]] = [:]
        for e in all where !e.amount.isZero {
            let key = Key(account: e.accountId, cents: abs(e.amount.cents))
            if e.amount > .zero { positives[key, default: []].append(e) } else { negatives[key, default: []].append(e) }
        }
        var candidates: [(distance: Int, plus: EntryRow, minus: EntryRow)] = []
        for (key, plus) in positives {
            for p in plus {
                for m in negatives[key] ?? [] {
                    let distance = abs(Q.daysBetween(p.day, m.day))
                    if distance <= cancellationWindowDays { candidates.append((distance, p, m)) }
                }
            }
        }
        candidates.sort { ($0.distance, min($0.plus.day, $0.minus.day), $0.plus.id, $0.minus.id)
            < ($1.distance, min($1.plus.day, $1.minus.day), $1.plus.id, $1.minus.id) }
        var used = Set<Int64>()
        var pairs: [CancelledPair] = []
        for c in candidates where !used.contains(c.plus.id) && !used.contains(c.minus.id) {
            used.insert(c.plus.id); used.insert(c.minus.id)
            let (first, second) = (c.plus.day, c.plus.id) <= (c.minus.day, c.minus.id) ? (c.plus, c.minus) : (c.minus, c.plus)
            pairs.append(CancelledPair(first: first, second: second))
        }
        pairs.sort { ($0.first.day, $0.first.id) > ($1.first.day, $1.first.id) }
        let remaining = all.filter { !used.contains($0.id) }
        return UnallocatedSavings(entries: remaining, cancelledPairs: pairs, remainingTotal: remaining.map(\.amount).sum(),
                                  cancelledCount: used.count)
    }

    /// Hoeveel dagen twee tegengestelde boekingen zonder pot hooguit uit elkaar mogen liggen om als opgeheven te gelden.
    public static let cancellationWindowDays = 45

    /// Groepeert gemarkeerde boekingen per pot, in volgorde van eerste voorkomen.
    static func reimbursementPots(_ entries: [EntryRow], balances: [Int64: Money]?) -> [ReimbursementPotTotal] {
        var order: [Int64?] = []
        var groups: [Int64?: (String?, Money, Int)] = [:]
        for e in entries {
            if groups[e.potId] == nil { order.append(e.potId) }
            let g = groups[e.potId] ?? (e.potName, .zero, 0)
            groups[e.potId] = (g.0, g.1 + e.amount, g.2 + 1)
        }
        return order.map { potId in
            let g = groups[potId]!
            let balance = potId.flatMap { id in balances.map { $0[id] ?? .zero } }
            return ReimbursementPotTotal(potId: potId, potName: g.0, total: g.1, amount: -g.1, count: g.2,
                                         balanceAfter: balance.map { $0 + g.1 })
        }
    }

    /// Wat er nog uit elke pot gaat (positief) of erin komt (negatief): de gemarkeerde boekingen die nog niet in
    /// een afgevinkte verrekening zitten (open, of in een verrekening die nog niet is afgevinkt).
    static func pendingSettlements(_ db: Database) throws -> [Int64: Money] {
        var result: [Int64: Money] = [:]
        for r in try Row.fetchAll(db, sql: """
            SELECT e.potId, SUM(e.amount) AS s FROM entry e
            LEFT JOIN savingsTransfer t ON t.id = e.savingsTransferId
            WHERE e.reimburse = 1 AND (e.savingsTransferId IS NULL OR t.done = 0)
              AND e.potId IS NOT NULL AND e.accountId IN \(Q.betaal)
            GROUP BY e.potId
            """) {
            result[r["potId"]] = -(r["s"] as Money)
        }
        return result
    }

    /// Netto bedrag van alle open verrekeningen met spaar: gemarkeerde boekingen op betaalrekeningen die nog niet in
    /// een afgevinkte verrekening zitten (`fromSavings` − `toSavings`, dus positief = van spaar naar betaal).
    static func pendingSettlementNet(_ db: Database) throws -> Money {
        let sum = try Money.fetchOne(db, sql: """
            SELECT COALESCE(SUM(e.amount), 0) FROM entry e
            LEFT JOIN savingsTransfer t ON t.id = e.savingsTransferId
            WHERE e.reimburse = 1 AND (e.savingsTransferId IS NULL OR t.done = 0) AND e.accountId IN \(Q.betaal)
            """) ?? .zero
        return -sum
    }

    /// Gemarkeerde boekingen op betaalrekeningen die nog niet in een overboeking zitten: uitgaven (uit een pot) en
    /// bijschrijvingen (naar een pot), gesaldeerd, met het bedrag per pot en het potsaldo erna.
    public static func openReimbursements(_ db: Database) throws -> OpenReimbursements {
        let entries = try entryRows(db, where: "e.reimburse = 1 AND e.savingsTransferId IS NULL AND a.kind = 'betaal'",
                                    order: "e.day ASC, e.id ASC")
        var balances: [Int64: Money] = [:]
        if entries.contains(where: { $0.potId != nil }) {
            for r in try Row.fetchAll(db, sql: """
                SELECT p.id, COALESCE(SUM(e.amount), 0) AS s FROM pot p
                LEFT JOIN entry e ON e.potId = p.id AND e.accountId = p.accountId GROUP BY p.id
                """) {
                balances[r["id"]] = r["s"]
            }
        }
        let fromSavings = -entries.map(\.amount).filter { $0 < .zero }.sum()
        let toSavings = entries.map(\.amount).filter { $0 > .zero }.sum()
        let net = fromSavings - toSavings
        return OpenReimbursements(entries: entries, total: -net, fromSavings: fromSavings, toSavings: toSavings,
                                  net: net, transferAmount: net.magnitude, direction: SavingsTransferDirection(net: net),
                                  perPot: reimbursementPots(entries, balances: balances),
                                  withoutPotCount: entries.filter { $0.potId == nil }.count)
    }

    /// Alle overboekingen tussen spaar en betaal (nieuwste eerst) met de verrekende boekingen, het bedrag per pot
    /// en of de potmutaties al geboekt zijn.
    public static func savingsTransfers(_ db: Database) throws -> [SavingsTransferDetail] {
        let transfers = try SavingsTransfer.order(Column("day").desc, Column("id").desc).fetchAll(db)
        guard !transfers.isEmpty else { return [] }
        let markers = try TransferMarkers(db)
        let entries = try entryRows(db, where: "e.savingsTransferId IS NOT NULL AND a.kind = 'betaal'",
                                    order: "e.day ASC, e.id ASC").filter { !$0.isSettlementBooking }
        let grouped = Dictionary(grouping: entries, by: { $0.savingsTransferId! })
        let bookings = Dictionary(grouping: try entryRows(db, where: markers.clause, order: "e.day ASC, e.id ASC")
            .filter(\.isSettlementBooking), by: { $0.settlementTransferId! })
        return transfers.map { t in
            let own = grouped[t.id!] ?? []
            let made = bookings[t.id!] ?? []
            let potEntries = made.filter { $0.accountKind == .spaar }
            return SavingsTransferDetail(id: t.id!, day: t.day, amount: t.amount, transferAmount: t.amount.magnitude,
                                         direction: SavingsTransferDirection(net: t.amount), done: t.done,
                                         doneAt: t.doneAt, note: t.note, entries: own,
                                         entriesTotal: own.map(\.amount).sum(),
                                         perPot: reimbursementPots(own, balances: nil), potEntries: potEntries,
                                         potMutationsBooked: !potEntries.isEmpty, bookings: made,
                                         checkingBankConfirmed: made.contains { $0.accountKind == .betaal && $0.bankTransactionId != nil },
                                         savingsBankConfirmed: made.contains { $0.accountKind == .spaar && $0.bankTransactionId != nil },
                                         unconfirmedSince: t.done ? made.filter { $0.bankTransactionId == nil }.map(\.day).min() : nil)
        }
    }
}
