import Foundation
import HFCore

// Het plan achter de voorbeelddata: alle verzonnen banktransacties van het jaar, zonder database.
// `DemoData.seed` zet het plan in de database; `DemoData.sampleCSV` maakt er een bank-CSV van.
// Alles is verzonnen en hangt alleen af van `today`.

/// Eigen pseudo-toevalsgenerator (SplitMix64), zodat dezelfde `today` altijd dezelfde data geeft.
struct SeededGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func int(_ range: ClosedRange<Int>) -> Int {
        range.lowerBound + Int(next() % UInt64(range.count))
    }

    mutating func pick<T>(_ items: [T]) -> T { items[int(0...(items.count - 1))] }
}

/// Eén boeking die bij een voorbeeldtransactie hoort.
struct DemoLine {
    var amount: Money
    var label: String
    var itemLabel: String? = nil
    var potName: String? = nil
    var tags: [String] = []
    var reimburse = false
    /// Index in `DemoPlan.transfers` van de spaaroverboeking die deze uitgave vergoedt.
    var transferIndex: Int? = nil
    var ruleName: String? = nil
    var confidence: Confidence? = nil
}

/// Eén verzonnen banktransactie met de boekingen die erbij horen.
struct DemoTx {
    var onSavings = false
    var day: Day
    var amount: Money
    var name: String
    var iban: String = ""
    var description: String
    var code: String = "PIN"
    var lines: [DemoLine]
    /// Overboeking tussen de eigen rekeningen: beide kanten hebben hetzelfde nummer.
    var link: Int? = nil
    /// Volgnummer binnen de rekening en saldo vóór de mutatie; ingevuld door `DemoPlan`.
    var sequence = 0
    var balanceBefore = Money.zero
}

struct DemoItem {
    enum Kind { case normal, reserveTotal, saving(pot: String) }
    var label: String
    var direction: Direction
    var cents: Int64
    var frequency: Frequency = .maand
    var months: [Int] = Array(1...12)
    var day: Int
    var party: String
    var iban: String
    var code: String = "INC"
    var reducesReserve = false
    var kind: Kind = .normal
}

struct DemoPot {
    var name: String
    var kind: PotKind
    var owner: String? = nil
    var monthly: Int64
    var target: Int64? = nil
    /// Deel van het beginsaldo van de spaarrekening dat op 1 januari in deze pot zit.
    var initial: Int64
}

struct DemoPlan {
    static let checkingIban = "NL00TEST0000000001"
    static let savingsIban = "NL00TEST0000000002"
    static let checkingOpening = Money(euros: 6_850)
    /// Deel van het beginsaldo van de spaarrekening dat niet over potten verdeeld is.
    static let savingsUnassigned = Money(euros: 350)
    static let tags: [(name: String, color: String)] = [
        ("Tanken", "#E67E22"), ("Uit eten", "#C0392B"), ("Cadeau", "#8E44AD"), ("Vakantie", "#2980B9"),
    ]

    // MARK: Potten

    static let reservePots: [DemoPot] = [
        DemoPot(name: "Wegenbelasting", kind: .reservering, monthly: 42_00, initial: 320_00),
        DemoPot(name: "Auto-onderhoud", kind: .reservering, monthly: 60_00, initial: 900_00),
        DemoPot(name: "Vervanging auto", kind: .reservering, monthly: 100_00, initial: 2_400_00),
        DemoPot(name: "Gemeentebelastingen", kind: .reservering, monthly: 78_00, initial: 900_00),
        DemoPot(name: "Waterschapsbelasting", kind: .reservering, monthly: 31_00, initial: 380_00),
        DemoPot(name: "Onderhoud huis", kind: .reservering, monthly: 120_00, initial: 1_200_00),
        DemoPot(name: "Tuin", kind: .reservering, monthly: 20_00, initial: 160_00),
        DemoPot(name: "Vakantie", kind: .reservering, monthly: 200_00, initial: 1_600_00),
        DemoPot(name: "Kleding", kind: .reservering, monthly: 90_00, initial: 720_00),
        DemoPot(name: "Cadeaus", kind: .reservering, monthly: 45_00, initial: 360_00),
        DemoPot(name: "Sinterklaas en kerst", kind: .reservering, monthly: 35_00, initial: 280_00),
        DemoPot(name: "Verjaardagen", kind: .reservering, monthly: 30_00, initial: 240_00),
        DemoPot(name: "School en opvang", kind: .reservering, monthly: 55_00, initial: 440_00),
        DemoPot(name: "Sport en hobby", kind: .reservering, monthly: 40_00, initial: 400_00),
        DemoPot(name: "Abonnementen (jaarlijks)", kind: .reservering, monthly: 18_00, initial: 144_00),
        DemoPot(name: "Tandarts", kind: .reservering, monthly: 25_00, initial: 450_00),
        DemoPot(name: "Brillen en lenzen", kind: .reservering, monthly: 20_00, initial: 160_00),
        DemoPot(name: "Huisdier", kind: .reservering, monthly: 30_00, initial: 400_00),
        DemoPot(name: "Apparaten en inventaris", kind: .reservering, monthly: 50_00, initial: 400_00),
        DemoPot(name: "Fietsen", kind: .reservering, monthly: 25_00, initial: 350_00),
    ]

    static let savingsPots: [DemoPot] = [
        DemoPot(name: "Spaarpot Kind 1", kind: .spaar, owner: "Kind 1", monthly: 25_00, target: 2_500_00, initial: 1_240_00),
        DemoPot(name: "Spaarpot Kind 2", kind: .spaar, owner: "Kind 2", monthly: 20_00, target: 2_500_00, initial: 980_00),
        DemoPot(name: "Studie Ouder 1", kind: .spaar, owner: "Ouder 1", monthly: 0, target: 3_000_00, initial: 1_500_00),
        DemoPot(name: "Nieuwe fiets Ouder 2", kind: .spaar, owner: "Ouder 2", monthly: 0, target: 1_800_00, initial: 650_00),
        DemoPot(name: "Buffer gezin", kind: .spaar, monthly: 150_00, target: 10_000_00, initial: 4_000_00),
    ]

    static var pots: [DemoPot] { reservePots + savingsPots }
    static var reserveTotal: Money { Money(cents: reservePots.map(\.monthly).reduce(0, +)) }
    static var savingsOpening: Money { Money(cents: pots.map(\.initial).reduce(0, +)) + savingsUnassigned }

    // MARK: Vaste posten

    static let reserveLabel = "RESERVERINGEN"

    static let items: [DemoItem] = [
        DemoItem(label: "Salaris Ouder 1", direction: .IN, cents: 3_150_00, day: 24,
                 party: "Werkgever Voorbeeld BV", iban: "NL00TEST0000000101", code: "OVB"),
        DemoItem(label: "Salaris Ouder 2", direction: .IN, cents: 2_280_00, day: 25,
                 party: "Stichting Fictief Onderwijs", iban: "NL00TEST0000000102", code: "OVB"),
        DemoItem(label: "Kinderbijslag", direction: .IN, cents: 560_00, frequency: .kwartaal, months: [1, 4, 7, 10],
                 day: 2, party: "Kinderbijslagkantoor Demo", iban: "NL00TEST0000000103", code: "OVB"),
        DemoItem(label: "Hypotheek", direction: .UIT, cents: -1_185_00, day: 1,
                 party: "Demo Hypotheekbank", iban: "NL00TEST0000000104"),
        DemoItem(label: "Boodschappen", direction: .UIT, cents: -850_00, day: 1,
                 party: "Huishoudrekening Ouder 1 en Ouder 2", iban: "NL00TEST0000000105", code: "OVB"),
        DemoItem(label: "Zorgverzekering", direction: .UIT, cents: -312_50, day: 27,
                 party: "Zorgverzekeraar Voorbeeld", iban: "NL00TEST0000000106"),
        DemoItem(label: "Woonverzekeringen", direction: .UIT, cents: -48_75, day: 3,
                 party: "Verzekeraar Fictief NV", iban: "NL00TEST0000000107"),
        DemoItem(label: "Autoverzekering", direction: .UIT, cents: -62_40, day: 5,
                 party: "Autoverzekeraar Demo", iban: "NL00TEST0000000108"),
        DemoItem(label: "Energie", direction: .UIT, cents: -185_00, day: 15,
                 party: "Energie Demo BV", iban: "NL00TEST0000000109"),
        DemoItem(label: "Water", direction: .UIT, cents: -22_50, day: 10,
                 party: "Waterbedrijf Voorbeeld", iban: "NL00TEST0000000110"),
        DemoItem(label: "Internet en tv", direction: .UIT, cents: -57_50, day: 12,
                 party: "Glasvezel Fictief", iban: "NL00TEST0000000111"),
        DemoItem(label: "Mobiel", direction: .UIT, cents: -38_00, day: 18,
                 party: "Telecom Demo", iban: "NL00TEST0000000112"),
        DemoItem(label: "Streaming film", direction: .UIT, cents: -13_99, day: 8,
                 party: "Kijkdoos Streaming", iban: "NL00TEST0000000113"),
        DemoItem(label: "Streaming muziek", direction: .UIT, cents: -10_99, day: 20,
                 party: "Luisterlijn Muziek", iban: "NL00TEST0000000114"),
        DemoItem(label: "Sportvereniging", direction: .UIT, cents: -135_00, frequency: .kwartaal, months: [1, 4, 7, 10],
                 day: 6, party: "Sportclub Voorbeeld", iban: "NL00TEST0000000115"),
        DemoItem(label: "Privélening", direction: .UIT, cents: -250_00, day: 28,
                 party: "Lening Familie Voorbeeld", iban: "NL00TEST0000000116", code: "OVB", reducesReserve: true),
        DemoItem(label: reserveLabel, direction: .UIT, cents: -reserveTotal.cents, day: 26,
                 party: "Spaarrekening gezin", iban: savingsIban, code: "OVB", kind: .reserveTotal),
        DemoItem(label: "Sparen Kind 1", direction: .UIT, cents: -25_00, day: 26,
                 party: "Spaarrekening gezin", iban: savingsIban, code: "OVB", kind: .saving(pot: "Spaarpot Kind 1")),
        DemoItem(label: "Sparen Kind 2", direction: .UIT, cents: -20_00, day: 26,
                 party: "Spaarrekening gezin", iban: savingsIban, code: "OVB", kind: .saving(pot: "Spaarpot Kind 2")),
        DemoItem(label: "Sparen buffer", direction: .UIT, cents: -150_00, day: 26,
                 party: "Spaarrekening gezin", iban: savingsIban, code: "OVB", kind: .saving(pot: "Buffer gezin")),
    ]

    /// Afwijkingen van het plan: (post, maand) → bedrag en toelichting.
    static let deviations: [String: (cents: Int64, note: String)] = [
        "Energie-3": (-192_40, "Termijn na jaarafrekening"),
        "Mobiel-2": (-41_50, "Abonnement plus buiten bundel"),
        "Salaris Ouder 1-5": (5_040_00, "Salaris inclusief vakantiegeld"),
        "Zorgverzekering-8": (-318_10, "Premie en eigen bijdrage"),
    ]

    /// De post waarvan één betaling ontbreekt, zodat het maandgrid een "te laat" laat zien.
    static let missingLabel = "Water"

    static let fuelStations = [("Tankstation Demo Noord", "NL00TEST0000000201"), ("Tankstation Demo Zuid", "NL00TEST0000000202")]
    static let restaurants = [("Restaurant De Verzonnen Lepel", "NL00TEST0000000211"),
                              ("Pizzeria Voorbeeld", "NL00TEST0000000212"), ("Eetcafe Fictief", "NL00TEST0000000213")]
    static let shops = [("Bouwmarkt Demo", "NL00TEST0000000221"), ("Drogisterij Voorbeeld", "NL00TEST0000000222"),
                        ("Boekhandel Fictief", "NL00TEST0000000223"), ("Warenhuis Demo", "NL00TEST0000000224"),
                        ("Bakkerij Voorbeeld", "NL00TEST0000000225"), ("Tuincentrum Fictief", "NL00TEST0000000226")]
    static let children = [("Kind 1", "NL00TEST0000000021", Int64(-7_50)), ("Kind 2", "NL00TEST0000000022", Int64(-5_00))]

    /// Uitgaven op de betaalrekening die uit een pot vergoed worden: (winkel, IBAN, pot, laagste, hoogste bedrag in centen, tag).
    static let reimbursables: [(String, String, String, Int, Int, String?)] = [
        ("Garage Demo", "NL00TEST0000000231", "Auto-onderhoud", 120_00, 290_00, nil),
        ("Tandartspraktijk Voorbeeld", "NL00TEST0000000232", "Tandarts", 45_00, 95_00, nil),
        ("Kledingwinkel Fictief", "NL00TEST0000000233", "Kleding", 60_00, 160_00, nil),
        ("Dierenarts Demo", "NL00TEST0000000234", "Huisdier", 40_00, 90_00, nil),
        ("Fietsenwinkel Voorbeeld", "NL00TEST0000000235", "Fietsen", 30_00, 80_00, nil),
        ("Basisschool Fictief", "NL00TEST0000000236", "School en opvang", 25_00, 70_00, nil),
        ("Cadeauwinkel Demo", "NL00TEST0000000237", "Cadeaus", 20_00, 55_00, "Cadeau"),
        ("Hobbywinkel Voorbeeld", "NL00TEST0000000238", "Sport en hobby", 30_00, 75_00, nil),
    ]

    /// Jaarrekeningen die rechtstreeks van de spaarrekening betaald worden: (maand, dag, partij, IBAN, pot, bedrag).
    static let annualBills: [(Int, Int, String, String, String, Int64)] = [
        (1, 20, "Wegenbelastingkantoor Demo", "NL00TEST0000000241", "Wegenbelasting", -126_00),
        (4, 20, "Wegenbelastingkantoor Demo", "NL00TEST0000000241", "Wegenbelasting", -126_00),
        (7, 20, "Wegenbelastingkantoor Demo", "NL00TEST0000000241", "Wegenbelasting", -126_00),
        (10, 20, "Wegenbelastingkantoor Demo", "NL00TEST0000000241", "Wegenbelasting", -126_00),
        (2, 27, "Gemeente Voorbeeldstad", "NL00TEST0000000242", "Gemeentebelastingen", -864_00),
        (3, 30, "Waterschap Fictief", "NL00TEST0000000243", "Waterschapsbelasting", -352_00),
        (7, 8, "Reisbureau Fictief", "NL00TEST0000000244", "Vakantie", -1_485_00),
        (9, 12, "Schildersbedrijf Voorbeeld", "NL00TEST0000000245", "Onderhoud huis", -640_00),
        (11, 28, "Speelgoedwinkel Demo", "NL00TEST0000000246", "Sinterklaas en kerst", -210_00),
    ]

    // MARK: Plan

    let today: Day
    /// Laatste dag waarvan de banktransacties geboekt zijn; alles daarna blijft `nieuw`.
    let cutoff: Day
    let yearStart: Day
    /// Banktransacties per rekening t/m `today`, op volgorde, met volgnummer en saldo vóór de mutatie.
    private(set) var checking: [DemoTx] = []
    private(set) var savings: [DemoTx] = []
    /// Spaaroverboekingen (spaar → betaal) die uitgaven vergoeden.
    private(set) var transfers: [(day: Day, amount: Money)] = []

    func isRecent(_ tx: DemoTx) -> Bool { tx.day > cutoff }

    init(today: Day) {
        self.today = today
        self.cutoff = today.adding(days: -10)
        let year = today.year
        self.yearStart = Day(year: year, month: 1, day: 1)!
        let yearEnd = Day(year: year, month: 12, day: 31)!
        var all: [DemoTx] = []
        var nextLink = 0

        func day(_ month: Int, _ wanted: Int) -> Day {
            var d = wanted
            while true {
                if let result = Day(year: year, month: month, day: d) { return result }
                d -= 1
            }
        }
        func generator(_ stream: UInt64) -> SeededGenerator {
            SeededGenerator(seed: UInt64(year) &* 0x9E37_79B9_7F4A_7C15 &+ stream)
        }

        // 1. Vaste posten, elke verwachte maand.
        for item in Self.items {
            for month in item.months {
                let date = day(month, item.day)
                let deviation = Self.deviations["\(item.label)-\(month)"]
                let amount = Money(cents: deviation?.cents ?? item.cents)
                let confidence: Confidence = deviation == nil ? .hoog : .midden
                let monthName = Day.monthNames[month - 1]
                let description = deviation?.note ?? "\(item.label) \(monthName) \(year)"
                let line = DemoLine(amount: amount, label: item.label, itemLabel: item.label,
                                    ruleName: item.label, confidence: confidence)
                var tx = DemoTx(day: date, amount: amount, name: item.party, iban: item.iban,
                                description: description, code: item.code, lines: [line])
                switch item.kind {
                case .normal:
                    all.append(tx)
                case .reserveTotal:
                    tx.link = nextLink
                    all.append(tx)
                    let lines = Self.reservePots.map {
                        DemoLine(amount: Money(cents: $0.monthly), label: "Reservering \($0.name)", potName: $0.name)
                    }
                    all.append(DemoTx(onSavings: true, day: date, amount: -amount, name: "Ouder 1 en Ouder 2",
                                      iban: Self.checkingIban, description: description, code: "OVB",
                                      lines: lines, link: nextLink))
                    nextLink += 1
                case .saving(let pot):
                    tx.link = nextLink
                    all.append(tx)
                    let line = DemoLine(amount: -amount, label: item.label, potName: pot,
                                        ruleName: "\(item.label) (spaarrekening)", confidence: .hoog)
                    all.append(DemoTx(onSavings: true, day: date, amount: -amount, name: "Ouder 1 en Ouder 2",
                                      iban: Self.checkingIban, description: description, code: "OVB",
                                      lines: [line], link: nextLink))
                    nextLink += 1
                }
            }
        }

        // 2. Wekelijks zakgeld.
        var pocketDay = yearStart.adding(days: 2)
        while pocketDay <= yearEnd {
            for (child, iban, cents) in Self.children {
                let line = DemoLine(amount: Money(cents: cents), label: "Zakgeld \(child)",
                                    ruleName: "Zakgeld \(child)", confidence: .hoog)
                all.append(DemoTx(day: pocketDay, amount: Money(cents: cents), name: "\(child) Voorbeeld", iban: iban,
                                  description: "Zakgeld \(child)", code: "OVB", lines: [line]))
            }
            pocketDay = pocketDay.adding(days: 7)
        }

        // 3. Tanken, uit eten en losse winkels, met tussenpozen uit de generator.
        func stream(_ id: UInt64, first: ClosedRange<Int>, step: ClosedRange<Int>, _ make: (inout SeededGenerator, Day) -> DemoTx) {
            var rng = generator(id)
            var date = yearStart.adding(days: rng.int(first))
            while date <= yearEnd {
                all.append(make(&rng, date))
                date = date.adding(days: rng.int(step))
            }
        }
        stream(1, first: 2...9, step: 11...17) { rng, date in
            let (name, iban) = rng.pick(Self.fuelStations)
            let amount = Money(cents: -Int64(rng.int(48_00...84_00)))
            return DemoTx(day: date, amount: amount, name: name, iban: iban, description: "Betaalautomaat \(name)",
                          lines: [DemoLine(amount: amount, label: "Tanken", tags: ["Tanken"],
                                           ruleName: "Tankstation Demo", confidence: .midden)])
        }
        stream(2, first: 4...12, step: 13...24) { rng, date in
            let (name, iban) = rng.pick(Self.restaurants)
            let amount = Money(cents: -Int64(rng.int(28_00...95_00)))
            return DemoTx(day: date, amount: amount, name: name, iban: iban, description: "Betaalautomaat \(name)",
                          lines: [DemoLine(amount: amount, label: name, tags: ["Uit eten"],
                                           ruleName: name, confidence: .midden)])
        }
        stream(3, first: 1...5, step: 4...9) { rng, date in
            let (name, iban) = rng.pick(Self.shops)
            let amount = Money(cents: -Int64(rng.int(6_50...78_00)))
            return DemoTx(day: date, amount: amount, name: name, iban: iban, description: "Betaalautomaat \(name)",
                          lines: [DemoLine(amount: amount, label: name)])
        }

        // 4. Eenmalige inkomsten en een vakantie-uitgave.
        func oneOff(_ month: Int, _ d: Int, _ cents: Int64, _ name: String, _ iban: String, _ description: String,
                    _ label: String, tags: [String] = []) {
            let amount = Money(cents: cents)
            all.append(DemoTx(day: day(month, d), amount: amount, name: name, iban: iban, description: description,
                              code: "OVB", lines: [DemoLine(amount: amount, label: label, tags: tags)]))
        }
        oneOff(2, 14, 39_95, "Webwinkel Voorbeeld", "NL00TEST0000000251", "Terugbetaling retour bestelling", "Terugbetaling retour")
        oneOff(4, 22, 412_00, "Belastingkantoor Demo", "NL00TEST0000000252", "Teruggaaf inkomstenbelasting", "Teruggaaf belasting")
        oneOff(5, 5, 100_00, "Opa en Oma Voorbeeld", "NL00TEST0000000253", "Cadeau voor de verjaardag", "Cadeau verjaardag", tags: ["Cadeau"])
        oneOff(7, 14, -186_00, "Camping Fictief", "NL00TEST0000000254", "Aanbetaling kampeerplaats", "Camping", tags: ["Vakantie"])
        oneOff(10, 9, 75_00, "Ouder 2 Voorbeeld", "NL00TEST0000000255", "Terugbetaling voorgeschoten bedrag", "Terugbetaling voorschot")

        // 5. Uitgaven die uit een pot vergoed worden.
        var reimbursements: [DemoTx] = []
        var rng = generator(4)
        var date = yearStart.adding(days: rng.int(8...20))
        while date <= yearEnd {
            let (name, iban, pot, low, high, tag) = rng.pick(Self.reimbursables)
            let amount = Money(cents: -Int64(rng.int(low...high)))
            let line = DemoLine(amount: amount, label: name, potName: pot, tags: tag.map { [$0] } ?? [],
                                reimburse: true, ruleName: name, confidence: .midden)
            reimbursements.append(DemoTx(day: date, amount: amount, name: name, iban: iban,
                                         description: "Betaalautomaat \(name)", lines: [line]))
            date = date.adding(days: rng.int(16...30))
        }

        // 6. Elke twee maanden één overboeking van spaar naar betaal voor de uitgaven tot dan toe.
        for month in [3, 5, 7, 9, 11] {
            let transferDay = day(month, 2)
            var perPot: [(pot: String, amount: Money)] = []
            var total = Money.zero
            for index in reimbursements.indices
            where reimbursements[index].day < transferDay && reimbursements[index].lines[0].transferIndex == nil {
                reimbursements[index].lines[0].transferIndex = transfers.count
                let line = reimbursements[index].lines[0]
                total += line.amount.magnitude
                if let i = perPot.firstIndex(where: { $0.pot == line.potName }) {
                    perPot[i].amount += line.amount.magnitude
                } else {
                    perPot.append((line.potName ?? "", line.amount.magnitude))
                }
            }
            guard !total.isZero else { continue }
            transfers.append((transferDay, total))
            let description = "Vergoeding uitgaven uit potten"
            all.append(DemoTx(day: transferDay, amount: total, name: "Spaarrekening gezin", iban: Self.savingsIban,
                              description: description, code: "OVB",
                              lines: [DemoLine(amount: total, label: "Vergoeding uit spaar")], link: nextLink))
            all.append(DemoTx(onSavings: true, day: transferDay, amount: -total, name: "Ouder 1 en Ouder 2",
                              iban: Self.checkingIban, description: description, code: "OVB",
                              lines: perPot.map { DemoLine(amount: -$0.amount, label: "Vergoeding \($0.pot)", potName: $0.pot) },
                              link: nextLink))
            nextLink += 1
        }
        all += reimbursements

        // 7. Jaarrekeningen rechtstreeks van de spaarrekening.
        for (month, d, name, iban, pot, cents) in Self.annualBills {
            let amount = Money(cents: cents)
            let line = DemoLine(amount: amount, label: "\(pot) \(year)", potName: pot, ruleName: name, confidence: .midden)
            all.append(DemoTx(onSavings: true, day: day(month, d), amount: amount, name: name, iban: iban,
                              description: "\(pot) \(year)", code: "INC", lines: [line]))
        }

        // Alleen t/m vandaag, op dag gesorteerd (bij gelijke dag de volgorde van aanmaken).
        var kept = all.enumerated()
            .filter { $0.element.day <= today }
            .sorted { ($0.element.day, $0.offset) < ($1.element.day, $1.offset) }
            .map(\.element)

        // Eén betaling ontbreekt: de laatste van de post die al geboekt had moeten zijn.
        if let missing = kept.lastIndex(where: {
            !$0.onSavings && $0.lines.first?.itemLabel == Self.missingLabel && $0.day < cutoff
        }) {
            kept.remove(at: missing)
        }

        func chain(_ list: [DemoTx], opening: Money) -> [DemoTx] {
            var balance = opening
            return list.enumerated().map { index, tx in
                var tx = tx
                tx.sequence = index + 1
                tx.balanceBefore = balance
                balance += tx.amount
                return tx
            }
        }
        checking = chain(kept.filter { !$0.onSavings }, opening: Self.checkingOpening)
        savings = chain(kept.filter(\.onSavings), opening: Self.savingsOpening)
    }
}
