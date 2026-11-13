import SwiftUI
import GRDB
import HFCore
import HFRules

/// Alles wat het regelscherm uit de database nodig heeft.
struct RulesData: Equatable {
    var rules: [Rule] = []
    var accounts: [Account] = []
    var pots: [Pot] = []
    var tags: [Tag] = []
    /// Labels van de posten van het gekozen jaar waarop geboekt kan worden (geen RES-regels).
    var itemLabels: [String] = []
    var transactionCount = 0

    static func load(_ db: Database, year: Int) throws -> RulesData {
        var d = RulesData()
        d.rules = try RuleEngine.rules(db)
        d.accounts = try Account.order(Column("sortOrder"), Column("id")).fetchAll(db)
        d.pots = try Pot.order(Column("accountId"), Column("sortOrder"), Column("id")).fetchAll(db)
        d.tags = try Tag.order(Column("sortOrder"), Column("id")).fetchAll(db)
        if let y = try BudgetYear.filter(Column("year") == year).fetchOne(db), let yearId = y.id {
            d.itemLabels = try BudgetItem
                .filter(Column("yearId") == yearId && Column("direction") != Direction.RES.rawValue)
                .order(Column("sortOrder"), Column("id"))
                .fetchAll(db).map(\.label)
        }
        d.transactionCount = try BankTransaction.fetchCount(db)
        return d
    }

    func accountName(_ id: Int64?) -> String? { accounts.first { $0.id == id }?.name }
    func potName(_ id: Int64?) -> String? { pots.first { $0.id == id }?.name }
    func tags(of rule: Rule) -> [Tag] {
        let ids = Set(rule.tagIdList)
        return tags.filter { $0.id.map(ids.contains) ?? false }
    }
}

enum RulesOriginFilter: String, CaseIterable, Identifiable {
    case alle, handmatig, geleerd
    var id: String { rawValue }
    var title: String {
        switch self { case .alle: "Alle"; case .handmatig: "Handmatig"; case .geleerd: "Geleerd" }
    }
}

/// Leesbare teksten bij een regel. Geen rekenwerk: de zekerheid komt uit `RuleMatcher`.
enum RulesText {
    static func filled(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespaces), !t.isEmpty else { return nil }
        return t
    }

    static func amount(_ m: Money) -> String {
        m.formatted(symbol: false).replacingOccurrences(of: "-", with: "−")
    }

    /// "tegenpartij bevat ‘energie’ en bedrag = −120,00"
    static func conditions(_ r: Rule) -> String {
        var parts: [String] = []
        if let v = filled(r.counterpartyContains) { parts.append("tegenpartij bevat ‘\(v)’") }
        if let v = filled(r.counterpartyIban) { parts.append("IBAN is \(v)") }
        if let v = filled(r.descriptionContains) { parts.append("omschrijving bevat ‘\(v)’") }
        if let a = r.amount { parts.append("bedrag = \(amount(a))") }
        return parts.isEmpty ? "nog geen voorwaarden" : parts.joined(separator: " en ")
    }

    static func hasConditions(_ r: Rule) -> Bool {
        filled(r.counterpartyContains) != nil || filled(r.counterpartyIban) != nil
            || filled(r.descriptionContains) != nil || r.amount != nil
    }

    /// Waarop deze regel zou herkennen als alles klopt. Vraagt het aan de module met een transactie
    /// die precies aan de voorwaarden voldoet.
    static func expectedBasis(_ rule: Rule) -> MatchBasis? {
        guard let day = Day(iso: "2000-01-01") else { return nil }
        let tx = BankTransaction(accountId: rule.accountId ?? 0, day: day, amount: rule.amount ?? .zero,
                                 counterpartyName: rule.counterpartyContains ?? "",
                                 counterpartyIban: rule.counterpartyIban ?? "",
                                 descriptionText: rule.descriptionContains ?? "", fingerprint: "")
        return RuleMatcher.match(rule, tx, ignoreEnabled: true)?.basis
    }

    static func basisExplanation(_ basis: MatchBasis?) -> String {
        switch basis {
        case .counterpartyAndAmount:
            "Tegenpartij en bedrag kloppen. Wijkt het bedrag een keer af, dan wordt het ‘Waarschijnlijk’."
        case .counterparty, .counterpartyAmountDiffers:
            "Alleen de tegenpartij klopt; er is geen bedrag om mee te vergelijken."
        case .keyword:
            "Herkend aan een trefwoord in de omschrijving."
        case .amountOnly:
            "Alleen het bedrag klopt. Dat kan toeval zijn, dus kijk dit altijd na."
        case nil:
            "Vul minstens één voorwaarde in."
        }
    }

    static func lastUsed(_ date: Date?) -> String {
        guard let date else { return "nooit" }
        return Day(date: date).short(withYear: true)
    }
}

/// Uitleg van de zekerheidsniveaus (uit de spec, in gewone taal).
struct RulesConfidenceHelp: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Hoe zeker is een voorstel?").font(.headline)
            row(.hoog, "De tegenpartij (naam of IBAN) én het bedrag kloppen. Dit kun je meestal in één keer boeken.")
            row(.midden, "De tegenpartij klopt maar het bedrag is anders of onbekend, of er staat een trefwoord in de omschrijving.")
            row(.laag, "Alleen het bedrag klopt. Altijd even nakijken.")
            row(.geen, "Geen regel past. Je kiest zelf; van je keuze wordt een regel geleerd.")
            Divider()
            Text("Passen er meer regels, dan wint de zekerste. Bij gelijke zekerheid wint de regel met de laagste prioriteit, daarna de regel met de meeste voorwaarden.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 380)
    }

    private func row(_ c: Confidence, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Pill(c.title, color: c.color).frame(width: 118, alignment: .leading)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Zet onderdelen naast elkaar en breekt af naar een volgende regel.
struct RulesFlow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(width: bounds.width, subviews: subviews)
        for (index, point) in result.points.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), proposal: .unspecified)
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (size: CGSize, points: [CGPoint]) {
        var points: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for view in subviews {
            let s = view.sizeThatFits(.unspecified)
            if x > 0, x + s.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            points.append(CGPoint(x: x, y: y))
            x += s.width + spacing
            rowHeight = max(rowHeight, s.height)
            maxX = max(maxX, x - spacing)
        }
        return (CGSize(width: maxX, height: y + rowHeight), points)
    }
}

extension Binding where Value == String? {
    /// Tekstveld op een optionele tekst: leeg = nil.
    var rulesText: Binding<String> {
        Binding<String>(get: { wrappedValue ?? "" }, set: { wrappedValue = $0.isEmpty ? nil : $0 })
    }
}
