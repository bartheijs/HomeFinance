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
    /// Versie van de voorbeelddata. Hoog dit op bij elke wijziging in `DemoPlan` of `seed`: de app vult een
    /// bestaande voorbeelddatabase dan opnieuw (`openDemo`). 3 = alles om te demonstreren: voorbeeldzip met
    /// betaal- en spaarrekening, potten per kind, groep Kids, vaste stortingen, Tanken verrekenen met startbedrag,
    /// regels zoals "Onthoud als regel" ze maakt (november 2026).
    public static let version = 3

    /// Instelling met de versie van de voorbeelddata in een voorbeelddatabase.
    public static let versionKey = "voorbeeld.versie"

    /// Naam van de gezamenlijke spaarpot met een vooruitblik (voor het telefoondashboard).
    public static let sharedPotName = DemoPlan.sharedPot.name
    /// De eigenaren (kinderen) van wie de potjes op het telefoondashboard staan.
    public static let childOwners = DemoPlan.childOwners

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

    /// Opent de voorbeelddatabase op `url` met voorbeelddata van deze `version`. Bij het eerste gebruik wordt hij
    /// gevuld en daarna `afterSeed` aangeroepen (bv. om het telefoondashboard in te stellen); staat er
    /// voorbeelddata van een andere versie in, dan wordt dit bestand leeggemaakt en opnieuw gevuld. Weigert de
    /// eigen administratie (`AppDatabase.defaultURL`), ook via een symbolische of harde koppeling. (Het
    /// voorbeeldbestand van de app staat in dezelfde map, `voorbeeld.sqlite`; dat mag wel.)
    public static func openDemo(at url: URL, today: Day, leaveRecentForImport: Bool = true,
                                afterSeed: (AppDatabase) throws -> Void = { _ in }) throws -> AppDatabase {
        guard !isRealAdministration(url) else { throw CocoaError(.fileWriteNoPermission) }
        var db = try AppDatabase.open(at: url)
        let (accounts, stored) = try db.read { (try Account.fetchCount($0), try Setting.get($0, versionKey)) }
        if accounts > 0, stored != String(version) {
            try db.writer.erase()
            db = try AppDatabase(db.writer)
        }
        if try db.read({ try Account.fetchCount($0) }) == 0 {
            _ = try seed(into: db, today: today, leaveRecentForImport: leaveRecentForImport)
            try db.write { try Setting.set($0, versionKey, String(version)) }
            try afterSeed(db)
        }
        return db
    }

    /// Is `url` de eigen administratie (zelfde pad na het volgen van koppelingen, of hetzelfde bestand op schijf)?
    static func isRealAdministration(_ url: URL) -> Bool {
        let real = AppDatabase.defaultURL.resolvingSymlinksInPath().standardizedFileURL
        let given = url.resolvingSymlinksInPath().standardizedFileURL
        if given.path == real.path { return true }
        let fm = FileManager.default
        if let a = try? fm.attributesOfItem(atPath: given.path), let b = try? fm.attributesOfItem(atPath: real.path),
           let na = a[.systemFileNumber] as? Int, let nb = b[.systemFileNumber] as? Int,
           let da = a[.systemNumber] as? Int, let db = b[.systemNumber] as? Int, na == nb, da == db {
            return true
        }
        return false
    }

    /// Bestandsnaam voor de voorbeeld-CSV, bv. `voorbeeld-betaalrekening-2027-06-18.csv`.
    public static func sampleCSVFileName(today: Day) -> String { "voorbeeld-betaalrekening-\(today.iso).csv" }

    /// Bestandsnaam voor de voorbeeldzip, bv. `voorbeeld-bank-2027-06-18.zip`.
    public static func sampleArchiveFileName(today: Day) -> String { "voorbeeld-bank-\(today.iso).zip" }

    /// De tekst van een bank-CSV voor de betaalrekening met de transacties van de laatste 10 dagen t/m `today`.
    ///
    /// Formaat: 19 kolommen, geen kopregel, komma als scheidingsteken, bedragen met een punt (`-12.50`).
    /// Kolommen: 0 datum dd-mm-jjjj, 1 eigen IBAN, 2 IBAN tegenpartij, 3 naam tegenpartij, 4 adres, 5 postcode,
    /// 6 plaats, 7 valuta rekening, 8 saldo vóór mutatie, 9 valuta mutatie, 10 bedrag met teken, 11 journaaldatum,
    /// 12 valutadatum, 13 interne code, 14 globale code, 15 volgnummer, 16 betalingskenmerk, 17 omschrijving,
    /// 18 afschriftnummer. Sluit aan op het saldo van een database die met `leaveRecentForImport: true` is gevuld.
    public static func sampleCSV(today: Day) -> String {
        let plan = DemoPlan(today: today)
        return csv(plan.checking.filter(plan.isRecent), ownIban: DemoPlan.checkingIban)
    }

    /// Als `sampleCSV(today:)`, maar voor de spaarrekening. Leeg als daar de laatste 10 dagen niets gebeurde.
    public static func sampleSavingsCSV(today: Day) -> String {
        let plan = DemoPlan(today: today)
        return csv(plan.savings.filter(plan.isRecent), ownIban: DemoPlan.savingsIban)
    }

    /// Schrijft de voorbeeldzip naar `folder`, zoals de bank hem levert: per rekening een CSV met de transacties van
    /// de laatste 10 dagen t/m `today` (`<IBAN>-<dd-mm-jjjj>.csv`; een rekening zonder transacties ontbreekt).
    /// Hoort bij een database die met `leaveRecentForImport: true` is gevuld: importeren sluit dan aan op het
    /// saldo van beide rekeningen. Een bestaand bestand met dezelfde naam wordt vervangen.
    @discardableResult
    public static func writeSampleArchive(today: Day, to folder: URL) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let work = fm.temporaryDirectory.appendingPathComponent("HomeFinance-voorbeeldzip-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        var names: [String] = []
        for (iban, text) in [(DemoPlan.checkingIban, sampleCSV(today: today)), (DemoPlan.savingsIban, sampleSavingsCSV(today: today))]
        where !text.isEmpty {
            let name = "\(iban)-\(today.dutch).csv"
            try Data(text.utf8).write(to: work.appendingPathComponent(name))
            names.append(name)
        }
        let archive = work.appendingPathComponent("uit.zip")
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = work
        zip.arguments = ["-X", "-D", "-q", archive.path] + names
        zip.standardOutput = Pipe()
        zip.standardError = Pipe()
        try zip.run()
        zip.waitUntilExit()
        guard zip.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
        let url = folder.appendingPathComponent(sampleArchiveFileName(today: today))
        if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
        try fm.moveItem(at: archive, to: url)
        return url
    }

    static func csv(_ rows: [DemoTx], ownIban: String) -> String {
        guard !rows.isEmpty else { return "" }
        let internalCodes = ["PIN": "101", "INC": "202", "OVB": "303"]
        return rows.map { tx -> String in
            let fields: [String] = [
                tx.day.dutch, ownIban, tx.iban, tx.name, "", "", "", "EUR",
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
            let isGoal = def.name == DemoPlan.goalPot.name
            var pot = Pot(accountId: savingsId, name: def.name, kind: def.kind, owner: def.owner,
                          monthlyAmount: Money(cents: def.monthly), targetAmount: def.target.map(Money.init(cents:)),
                          sortOrder: index + 1, targetDate: isGoal ? DemoPlan.goalDate(year: year) : nil)
            try pot.insert(db)
            potIds[def.name] = pot.id
        }
        // Het spaardoel uit onderdelen; het doelbedrag van de pot is de som ervan.
        for (index, part) in DemoPlan.goalParts.enumerated() {
            var record = GoalPart(potId: potIds[DemoPlan.goalPot.name]!, label: part.label, quantity: part.quantity,
                                  unitAmount: Money(cents: part.unit), sortOrder: index + 1)
            try record.insert(db)
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
        for def in DemoPlan.reserveLines {
            sortOrder += 1
            var item = BudgetItem(yearId: budgetYear.id!, label: def.name, direction: .RES,
                                  planAmount: Money(cents: -def.monthly), potId: potIds[def.name], sortOrder: sortOrder)
            try item.insert(db)
        }

        // Vaste stortingen van de betaal- naar de spaarrekening, gekoppeld aan hun post: RESERVERINGEN (verdeeld
        // over alle potten met een RES-regel) en elke spaarpost apart. Zo tonen spaardoelen en de vooruitblik wat
        // er per maand bij komt.
        var distributionOrder = 0
        func insertDistribution(_ name: String, itemLabel: String, lines: [DemoPot]) throws {
            distributionOrder += 1
            var distribution = Distribution(name: name, accountId: savingsId, sortOrder: distributionOrder,
                                            sourceAccountId: checkingId)
            try distribution.insert(db)
            for (index, def) in lines.enumerated() {
                var line = DistributionLine(distributionId: distribution.id!, potId: potIds[def.name]!,
                                            amount: Money(cents: def.monthly), sortOrder: index + 1)
                try line.insert(db)
            }
            try db.execute(sql: "UPDATE budgetItem SET distributionId = ? WHERE id = ?",
                           arguments: [distribution.id, itemIds[itemLabel]])
        }
        try insertDistribution(DemoPlan.reserveDistributionName, itemLabel: DemoPlan.reserveLabel, lines: DemoPlan.reserveLines)
        for def in DemoPlan.items {
            guard case .saving(let potName) = def.kind,
                  let pot = DemoPlan.pots.first(where: { $0.name == potName }) else { continue }
            try insertDistribution(def.label, itemLabel: def.label, lines: [pot])
        }

        // Vooruitblik voor de rentepot: de rente van de komende maanden gaat eraf, de schenking van volgend jaar
        // komt erbij. Zo zie je of de reservering het jaar rondkomt.
        if let loan = DemoPlan.items.first(where: { $0.label == DemoPlan.loanLabel }) {
            let potId = potIds[DemoPlan.loanPot.name]!
            var month = plan.today.month + (plan.today.day >= loan.day ? 1 : 0)
            while month <= 12 {
                var expected = ForecastItem(potId: potId, day: Day(year: year, month: month, day: loan.day)!,
                                            amount: Money(cents: loan.cents),
                                            label: "Rente \(Day.monthNames[month - 1])", createdAt: stamp)
                try expected.insert(db)
                month += 1
            }
            var gift = ForecastItem(potId: potId, day: Day(year: year + 1, month: 1, day: 5)!,
                                    amount: Money(cents: -loan.cents * 12), label: "Schenking \(year + 1)", createdAt: stamp)
            try gift.insert(db)
        }
        // En voor de gezamenlijke spaarpot: een verwachte grote uitgave.
        var expense = ForecastItem(potId: potIds[DemoPlan.sharedPot.name]!,
                                   day: plan.today.adding(days: DemoPlan.sharedExpenseDays),
                                   amount: Money(cents: DemoPlan.sharedExpense.cents),
                                   label: DemoPlan.sharedExpense.label, createdAt: stamp)
        try expense.insert(db)

        // Tags. Tanken wordt verrekend (6g): met een startbedrag en meetellend in "nog te besteden".
        var tagIds: [String: Int64] = [:]
        for (index, def) in DemoPlan.tags.enumerated() {
            var tag = Tag(name: def.name, color: def.color, sortOrder: index + 1)
            if def.name == DemoPlan.fuelTag {
                tag.settles = true
                tag.startAmount = DemoPlan.fuelStartAmount
                tag.startDay = plan.yearStart
                tag.countsInSpendable = true
            }
            try tag.insert(db)
            tagIds[def.name] = tag.id
        }
        let fuelTagId = tagIds[DemoPlan.fuelTag]!
        // Zoals `SettlementService.enable` vanaf 1 januari: een beginstand zonder boekingen.
        var opening = Settlement(tagId: fuelTagId, day: plan.yearStart, amount: .zero, isOpening: true,
                                 note: "Beginstand", createdAt: stamp)
        try opening.insert(db)

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
                    rule.reimburseDirection = .outgoing
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
        // Zakgeld: zoals "Onthoud als regel" hem maakt (6i): op de rekening van het kind, verrekenen met de
        // zakgeldpot alleen bij geld eruit (6f), geen vaste omschrijving (de eigen tekst blijft, 6b).
        for (child, iban, _) in DemoPlan.children {
            rules.append(Rule(name: "\(child) Voorbeeld", priority: 20, origin: .geleerd, accountId: checkingId,
                              counterpartyIban: iban, targetPotId: potIds["Zakgeld \(child)"], reimburse: true,
                              reimburseDirection: .outgoing))
            // Rijles: de rijschool is dezelfde, het kind staat in de omschrijving.
            rules.append(Rule(name: "Rijles \(child)", priority: 40, accountId: checkingId,
                              counterpartyContains: DemoPlan.drivingSchool.name, descriptionContains: child,
                              targetPotId: potIds[DemoPlan.goalPot.name], entryLabel: "Rijles \(child)",
                              tagIds: String(tagIds["Rijbewijs \(child)"]!), reimburse: true,
                              reimburseDirection: .outgoing))
        }
        rules.append(Rule(name: DemoPlan.fuelRefundParty.name, priority: 30, origin: .geleerd, accountId: checkingId,
                          counterpartyIban: DemoPlan.fuelRefundParty.iban, entryLabel: DemoPlan.fuelRefundLabel))
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

        // Verrekeningen met spaar t/m vandaag. Die van vóór de laatste 10 dagen zijn afgevinkt en hebben hun
        // bankregels; een recentere is vastgelegd maar nog niet afgevinkt: de import herkent haar overboeking.
        var transferIds: [Int: Int64] = [:]
        for (index, def) in plan.transfers.enumerated() where def.day <= plan.today {
            let done = def.day <= plan.cutoff
            var transfer = SavingsTransfer(day: def.day, amount: def.amount, done: done, doneAt: done ? def.day.date : nil,
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
        /// Boekingen met de tag Tanken (id, maand) en de terugstortingen (boeking, dag, bedrag, voor welke maand).
        var fuelEntries: [(id: Int64, month: Int)] = []
        var fuelRefunds: [(entryId: Int64, day: Day, amount: Money, month: Int)] = []

        func insertAccount(_ list: [DemoTx], accountId: Int64, isChecking: Bool) throws {
            let booked = list.filter { !plan.isRecent($0) }
            // De laatste geboekte boekingen op de betaalrekening staan nog op "nakijken".
            let unreviewedFrom = isChecking ? max(booked.count - 6, 0) : booked.count
            let kept = leaveRecentForImport ? booked : list

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
                    if line.tags.contains(DemoPlan.fuelTag) { fuelEntries.append((entry.id!, tx.day.month)) }
                    if let month = tx.fuelRefundFor { fuelRefunds.append((entry.id!, tx.day, tx.amount, month)) }
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
        // Tanken verrekenen: elke geboekte terugstorting verrekent de tankbeurten van de maand ervoor (in januari
        // het startbedrag), zoals `SettlementService.settle` met de storting gekoppeld.
        for refund in fuelRefunds {
            var settlement = Settlement(tagId: fuelTagId, day: refund.day, amount: refund.amount,
                                        depositEntryId: refund.entryId, createdAt: refund.day.date)
            try settlement.insert(db)
            let ids = fuelEntries.filter { $0.month == refund.month }.map(\.id)
            for id in ids {
                try db.execute(sql: "UPDATE entry SET settlementId = ? WHERE id = ?", arguments: [settlement.id, id])
            }
            if refund.month == 0 {
                try db.execute(sql: "UPDATE tag SET startSettlementId = ? WHERE id = ?", arguments: [settlement.id, fuelTagId])
            }
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
