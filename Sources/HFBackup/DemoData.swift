import Foundation
import GRDB
import HFCore

/// Fouten bij het plaatsen van voorbeelddata.
public enum DemoDataError: Error, LocalizedError, Equatable, Sendable {
    /// De database bevat al rekeningen of een begrotingsjaar.
    case databaseNotEmpty

    public var errorDescription: String? {
        switch self {
        case .databaseNotEmpty:
            return "De database bevat al gegevens. Voorbeelddata kan alleen in een lege database worden gezet."
        }
    }
}

/// Wat `DemoData.seed` heeft aangemaakt.
public struct DemoSummary: Equatable, Sendable {
    public var checkingAccountId: Int64
    public var savingsAccountId: Int64
    public var budgetItemCount: Int
    public var potCount: Int
    public var bankTransactionCount: Int
    /// Banktransacties met status `nieuw` (nog te boeken in de review).
    public var newTransactionCount: Int
    public var entryCount: Int
    /// Saldo van de betaalrekening volgens de boekingen (beginsaldo + boekingen).
    public var checkingBalance: Money
    /// Laatste dag waarvan de banktransacties geboekt zijn.
    public var bookedThrough: Day
}

/// Verzonnen voorbeelddata: het gezin "Ouder 1", "Ouder 2", "Kind 1" en "Kind 2", met verzonnen bedrijven en
/// IBAN's (`NL00TEST…`). Dezelfde `today` geeft altijd precies dezelfde data.
public enum DemoData {
    /// IBAN van de betaalrekening in de voorbeelddata.
    public static let checkingIban = DemoPlan.checkingIban
    /// IBAN van de spaarrekening in de voorbeelddata.
    public static let savingsIban = DemoPlan.savingsIban

    /// Vult een lege database met voorbeelddata van 1 januari van het jaar van `today` t/m `today`.
    ///
    /// De banktransacties van de laatste 10 dagen blijven `nieuw`, zodat de review werk heeft. Met
    /// `leaveRecentForImport: true` worden die van de betaalrekening níet geplaatst; ze komen dan binnen door
    /// `sampleCSV(today:)` te importeren. Weigert (`DemoDataError.databaseNotEmpty`) als er al rekeningen zijn.
    @discardableResult
    public static func seed(into db: AppDatabase, today: Day, leaveRecentForImport: Bool = false) throws -> DemoSummary {
        let plan = DemoPlan(today: today)
        return try db.write { database in
            guard try Account.fetchCount(database) == 0, try BudgetYear.fetchCount(database) == 0 else {
                throw DemoDataError.databaseNotEmpty
            }
            return try insert(plan, into: database, leaveRecentForImport: leaveRecentForImport)
        }
    }

    /// Bestandsnaam voor de voorbeeld-CSV, bv. `voorbeeld-betaalrekening-2027-06-18.csv`.
    public static func sampleCSVFileName(today: Day) -> String { "voorbeeld-betaalrekening-\(today.iso).csv" }

    /// De tekst van een bank-CSV voor de betaalrekening met de transacties van de laatste 10 dagen t/m `today`.
    ///
    /// Formaat: 19 kolommen, geen kopregel, komma als scheidingsteken, bedragen met een punt (`-12.50`).
    /// Kolommen: 0 datum dd-mm-jjjj, 1 eigen IBAN, 2 IBAN tegenpartij, 3 naam tegenpartij, 4 adres, 5 postcode,
    /// 6 plaats, 7 valuta rekening, 8 saldo vóór mutatie, 9 valuta mutatie, 10 bedrag met teken, 11 journaaldatum,
    /// 12 valutadatum, 13 interne code, 14 globale code, 15 volgnummer, 16 betalingskenmerk, 17 omschrijving,
    /// 18 afschriftnummer. Sluit aan op het saldo van een database die met `leaveRecentForImport: true` is gevuld.
    public static func sampleCSV(today: Day) -> String {
        let plan = DemoPlan(today: today)
        let internalCodes = ["PIN": "101", "INC": "202", "OVB": "303"]
        return plan.checking.filter(plan.isRecent).map { tx -> String in
            let fields: [String] = [
                tx.day.dutch, DemoPlan.checkingIban, tx.iban, tx.name, "", "", "", "EUR",
                plain(tx.balanceBefore), "EUR", plain(tx.amount), tx.day.dutch, tx.day.dutch,
                internalCodes[tx.code] ?? "", tx.code, String(tx.sequence), reference(tx), tx.description,
                String(tx.day.month),
            ]
            return fields.map { $0.replacingOccurrences(of: ",", with: " ") }.joined(separator: ",")
        }.joined(separator: "\n") + "\n"
    }

    // MARK: Intern

    /// "-1234.56"
    static func plain(_ money: Money) -> String {
        let a = money.cents.magnitude
        return (money.cents < 0 ? "-" : "") + "\(a / 100)." + String(format: "%02d", Int(a % 100))
    }

    static func reference(_ tx: DemoTx) -> String {
        "DEMO\(tx.day.year)\(tx.onSavings ? "S" : "B")" + String(format: "%05d", tx.sequence)
    }

    private static func insert(_ plan: DemoPlan, into db: Database, leaveRecentForImport: Bool) throws -> DemoSummary {
        let year = plan.today.year
        let stamp = plan.yearStart.date

        // Rekeningen
        var checking = Account(name: "Betaalrekening gezin", iban: DemoPlan.checkingIban, kind: .betaal,
                               openingBalance: DemoPlan.checkingOpening, openingDate: plan.yearStart, sortOrder: 1)
        try checking.insert(db)
        var savings = Account(name: "Spaarrekening gezin", iban: DemoPlan.savingsIban, kind: .spaar,
                              openingBalance: DemoPlan.savingsOpening, openingDate: plan.yearStart, sortOrder: 2)
        try savings.insert(db)
        let checkingId = checking.id!, savingsId = savings.id!

        // Jaar
        var budgetYear = BudgetYear(year: year, antiRood: Money(euros: 4_500))
        try budgetYear.insert(db)

        // Potten
        var potIds: [String: Int64] = [:]
        for (index, def) in DemoPlan.pots.enumerated() {
            var pot = Pot(accountId: savingsId, name: def.name, kind: def.kind, owner: def.owner,
                          monthlyAmount: Money(cents: def.monthly), targetAmount: def.target.map(Money.init(cents:)),
                          sortOrder: index + 1)
            try pot.insert(db)
            potIds[def.name] = pot.id
        }

        // Vaste posten: eerst IN en UIT, daarna de RES-regels onder RESERVERINGEN.
        var itemIds: [String: Int64] = [:]
        var sortOrder = 0
        for def in DemoPlan.items {
            sortOrder += 1
            var isTotal = false
            if case .reserveTotal = def.kind { isTotal = true }
            var item = BudgetItem(yearId: budgetYear.id!, label: def.label, direction: def.direction,
                                  planAmount: Money(cents: def.cents), frequency: def.frequency,
                                  expectedMonths: def.frequency == .maand ? "" : def.months.map(String.init).joined(separator: ","),
                                  expectedDay: def.day, isReserveTotal: isTotal,
                                  sortOrder: sortOrder)
            try item.insert(db)
            itemIds[def.label] = item.id
        }
        for def in DemoPlan.reservePots {
            sortOrder += 1
            var item = BudgetItem(yearId: budgetYear.id!, label: def.name, direction: .RES,
                                  planAmount: Money(cents: -def.monthly), potId: potIds[def.name], sortOrder: sortOrder)
            try item.insert(db)
        }

        // Tags
        var tagIds: [String: Int64] = [:]
        for (index, def) in DemoPlan.tags.enumerated() {
            var tag = Tag(name: def.name, color: def.color, sortOrder: index + 1)
            try tag.insert(db)
            tagIds[def.name] = tag.id
        }

        // Regels voor de terugkerende tegenpartijen
        var rules: [Rule] = []
        for def in DemoPlan.items {
            var rule = Rule(name: def.label, priority: 10, accountId: checkingId, amount: Money(cents: def.cents),
                            targetItemLabel: def.label, entryLabel: def.label)
            switch def.kind {
            case .normal:
                rule.counterpartyContains = def.party
                if def.label == DemoPlan.loanLabel {
                    // De rente op de privélening wordt uit de pot vergoed.
                    rule.targetPotId = potIds[DemoPlan.loanPot.name]
                    rule.reimburse = true
                }
            case .reserveTotal: rule.counterpartyIban = def.iban
            case .saving:
                rule.counterpartyIban = def.iban
                rules.append(Rule(name: "\(def.label) (spaarrekening)", priority: 10, accountId: savingsId,
                                  counterpartyIban: DemoPlan.checkingIban, amount: Money(cents: -def.cents),
                                  targetPotId: { if case .saving(let pot) = def.kind { return potIds[pot] }; return nil }(),
                                  entryLabel: def.label))
            }
            rules.append(rule)
        }
        for (child, iban, cents) in DemoPlan.children {
            rules.append(Rule(name: "Zakgeld \(child)", priority: 20, accountId: checkingId, counterpartyIban: iban,
                              amount: Money(cents: cents), entryLabel: "Zakgeld \(child)"))
        }
        rules.append(Rule(name: "Tankstation Demo", priority: 50, accountId: checkingId,
                          counterpartyContains: "Tankstation Demo", entryLabel: "Tanken",
                          tagIds: String(tagIds["Tanken"]!)))
        for (name, _) in DemoPlan.restaurants {
            rules.append(Rule(name: name, priority: 50, origin: .geleerd, accountId: checkingId,
                              counterpartyContains: name, tagIds: String(tagIds["Uit eten"]!)))
        }
        for (name, _, pot, _, _, tag) in DemoPlan.reimbursables {
            rules.append(Rule(name: name, priority: 50, origin: .geleerd, accountId: checkingId,
                              counterpartyContains: name, targetPotId: potIds[pot],
                              tagIds: tag.flatMap { tagIds[$0] }.map { String($0) } ?? "", reimburse: true,
                              reimburseDirection: .outgoing))
        }
        var seenBills = Set<String>()
        for (_, _, name, _, pot, _) in DemoPlan.annualBills where seenBills.insert(name).inserted {
            rules.append(Rule(name: name, priority: 50, accountId: savingsId, counterpartyContains: name,
                              targetPotId: potIds[pot]))
        }
        var ruleIds: [String: Int64] = [:]
        for index in rules.indices {
            try rules[index].insert(db)
            ruleIds[rules[index].name] = rules[index].id
        }

        // Wat er op 1 januari op de spaarrekening staat: één handboeking per pot. Het beginsaldo van de
        // rekening zelf is nul, zodat er geen bedrag zonder pot overblijft.
        var entryCount = 0
        for def in DemoPlan.pots where def.initial != 0 {
            var entry = Entry(accountId: savingsId, day: plan.yearStart, amount: Money(cents: def.initial),
                              label: "Beginsaldo \(def.name)", potId: potIds[def.name], createdAt: stamp)
            try entry.insert(db)
            entryCount += 1
        }

        // Afgeronde spaaroverboekingen (alleen die al geboekt zijn)
        var transferIds: [Int: Int64] = [:]
        for (index, def) in plan.transfers.enumerated() where def.day <= plan.cutoff {
            var transfer = SavingsTransfer(day: def.day, amount: def.amount, done: true, doneAt: def.day.date,
                                           note: "Vergoeding uitgaven uit potten")
            try transfer.insert(db)
            transferIds[index] = transfer.id
        }

        // Banktransacties en boekingen
        var transactionCount = 0, newCount = 0
        var ruleUse: [Int64: (count: Int, last: Day)] = [:]
        var linked: [Int: (checking: Int64?, savings: [Int64])] = [:]
        /// De boekingen van het afvinken per verrekening, zoals HFBudget ze bijhoudt in `Setting`.
        var bookedByTransfer: [Int64: [Int64]] = [:]
        var checkingBalance = DemoPlan.checkingOpening

        func insertAccount(_ list: [DemoTx], accountId: Int64, isChecking: Bool) throws {
            let booked = list.filter { !plan.isRecent($0) }
            // De laatste geboekte boekingen op de betaalrekening staan nog op "nakijken".
            let unreviewedFrom = isChecking ? max(booked.count - 6, 0) : booked.count
            let kept = isChecking && leaveRecentForImport ? booked : list

            // Eén importbatch per maand.
            var batchIds: [Int: Int64] = [:]
            for (month, rows) in Dictionary(grouping: kept, by: \.day.month).sorted(by: { $0.key < $1.key }) {
                let first = rows.first!, last = rows.last!
                var batch = ImportBatch(
                    accountId: accountId,
                    fileName: "voorbeeld-\(isChecking ? "betaal" : "spaar")-\(year)-" + String(format: "%02d", month) + ".csv",
                    importedAt: last.day.date, rowCount: rows.count, newCount: rows.count, duplicateCount: 0,
                    firstDay: first.day, lastDay: last.day, openingBalance: first.balanceBefore,
                    closingBalance: last.balanceBefore + last.amount, chainOK: true)
                try batch.insert(db)
                batchIds[month] = batch.id
            }

            for (index, tx) in kept.enumerated() {
                let recent = plan.isRecent(tx)
                var record = BankTransaction(
                    accountId: accountId, batchId: batchIds[tx.day.month], day: tx.day, amount: tx.amount,
                    balanceBefore: tx.balanceBefore, counterpartyName: tx.name, counterpartyIban: tx.iban,
                    descriptionText: tx.description, reference: reference(tx), transactionCode: tx.code,
                    sequence: String(tx.sequence), fingerprint: "voorbeeld|\(reference(tx))",
                    status: recent ? .nieuw : .verwerkt)
                try record.insert(db)
                transactionCount += 1
                if recent { newCount += 1; continue }
                if isChecking { checkingBalance += tx.amount }

                // Bankregel van een afgevinkte verrekening: de boekingen zijn die van het afvinken.
                let transferId = tx.transferIndex.flatMap { transferIds[$0] }
                for line in tx.lines {
                    let ruleId = line.ruleName.flatMap { ruleIds[$0] }
                    var entry = Entry(
                        accountId: accountId, bankTransactionId: record.id, day: tx.day, amount: line.amount,
                        label: line.label, budgetItemId: line.itemLabel.flatMap { itemIds[$0] },
                        potId: line.potName.flatMap { potIds[$0] }, reimburse: line.reimburse,
                        savingsTransferId: line.transferIndex.flatMap { transferIds[$0] },
                        reviewed: index < unreviewedFrom, note: transferId.map { "Verrekening #\($0)" } ?? "", ruleId: ruleId,
                        confidence: ruleId == nil ? nil : line.confidence, createdAt: tx.day.date)
                    try entry.insert(db)
                    entryCount += 1
                    if let transferId { bookedByTransfer[transferId, default: []].append(entry.id!) }
                    for tag in line.tags {
                        try EntryTag(entryId: entry.id!, tagId: tagIds[tag]!).insert(db)
                    }
                    if let ruleId {
                        ruleUse[ruleId] = ((ruleUse[ruleId]?.count ?? 0) + 1, tx.day)
                    }
                    if let link = tx.link {
                        var pair = linked[link] ?? (nil, [])
                        if isChecking { pair.checking = entry.id } else { pair.savings.append(entry.id!) }
                        linked[link] = pair
                    }
                }
            }
        }
        try insertAccount(plan.checking, accountId: checkingId, isChecking: true)
        try insertAccount(plan.savings, accountId: savingsId, isChecking: false)

        // Overboekingen tussen de eigen rekeningen aan elkaar koppelen.
        for (_, pair) in linked {
            guard let checkingEntry = pair.checking, let firstSavings = pair.savings.first else { continue }
            try db.execute(sql: "UPDATE entry SET counterEntryId = ? WHERE id = ?", arguments: [firstSavings, checkingEntry])
            for savingsEntry in pair.savings {
                try db.execute(sql: "UPDATE entry SET counterEntryId = ? WHERE id = ?", arguments: [checkingEntry, savingsEntry])
            }
        }
        for (transferId, ids) in bookedByTransfer.sorted(by: { $0.key < $1.key }) {
            try Setting.set(db, "savingsTransfer.\(transferId).entries", ids.sorted().map(String.init).joined(separator: ","))
        }
        for (ruleId, use) in ruleUse {
            try db.execute(sql: "UPDATE rule SET hitCount = ?, lastUsed = ? WHERE id = ?",
                           arguments: [use.count, use.last.date, ruleId])
        }

        // Eén afstemming die sluit.
        let bookedThrough = max(plan.cutoff, plan.yearStart)
        var reconciliation = Reconciliation(accountId: checkingId, day: bookedThrough, actualBalance: checkingBalance,
                                            calculatedBalance: checkingBalance, createdAt: bookedThrough.date)
        try reconciliation.insert(db)

        return DemoSummary(checkingAccountId: checkingId, savingsAccountId: savingsId,
                           budgetItemCount: sortOrder, potCount: DemoPlan.pots.count,
                           bankTransactionCount: transactionCount, newTransactionCount: newCount,
                           entryCount: entryCount, checkingBalance: checkingBalance, bookedThrough: bookedThrough)
    }
}
