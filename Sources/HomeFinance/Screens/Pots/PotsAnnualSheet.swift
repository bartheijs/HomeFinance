import SwiftUI
import GRDB
import HFCore
import HFInsight
import HFBudget

// MARK: - Hulpje "Nieuw jaarbedrag" (UX-stap B3)

/// Wat het venster nodig heeft om te kiezen: spaarrekeningen, potjes, vaste stortingen met hun post, en de
/// uitgavenposten van het jaar die nog vrij zijn.
private struct PotsAnnualData: Equatable {
    var savings: [Account] = []
    var pots: [Pot] = []
    var distributions: [Distribution] = []
    /// Per storting de post van het jaar die het totaal volgt.
    var linkedItem: [Int64: String] = [:]
    /// UIT-posten van het jaar zonder vaste storting.
    var freeItems: [BudgetItem] = []
    var yearExists = false

    @MainActor
    static func load(model: AppModel, year: Int) -> PotsAnnualData {
        model.read(PotsAnnualData()) { db in
            var data = PotsAnnualData()
            data.savings = try Account.filter(Column("kind") == AccountKind.spaar.rawValue && Column("archived") == false)
                .order(Column("sortOrder"), Column("id")).fetchAll(db)
            data.pots = Insight.pickerOrder(try Pot.filter(Column("archived") == false)
                .order(Column("sortOrder"), Column("id")).fetchAll(db))
            data.distributions = try DistributionService.all(db)
            for distribution in try Insight.chain(db, year: year).distributions {
                if let first = distribution.items.first { data.linkedItem[distribution.id] = first.label }
            }
            if let budgetYear = try BudgetYear.filter(Column("year") == year).fetchOne(db), !budgetYear.closed {
                data.yearExists = true
                data.freeItems = Insight.itemPickerOrder(try BudgetItem.fetchAll(db, sql: """
                    SELECT * FROM budgetItem WHERE yearId = ? AND direction = 'UIT' AND distributionId IS NULL
                    ORDER BY sortOrder, id
                    """, arguments: [budgetYear.id]))
            }
            return data
        }
    }
}

/// Eén venster dat een jaarlijkse rekening in één keer goed zet: een potje, 1/12 per maand in een vaste storting,
/// de post in de begroting die meeloopt, en eventueel een verwachting voor de rekening zelf.
struct PotsAnnualSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    private enum PotMode: Hashable { case new, existing }
    /// Keuze van de post: nil = geen, -1 = nieuwe post, anders een bestaande post.
    private static let newItemTag: Int64 = -1

    @State private var data = PotsAnnualData()
    @State private var name = ""
    @State private var yearly: Money?
    @State private var potMode: PotMode = .new
    @State private var existingPotId: Int64?
    /// nil = nieuwe vaste storting.
    @State private var distributionId: Int64?
    @State private var newDistributionName = "Jaarlijkse rekeningen"
    @State private var newDistributionAccountId: Int64?
    @State private var itemTag: Int64? = PotsAnnualSheet.newItemTag
    @State private var newItemLabel = ""
    @State private var withForecast = false
    @State private var forecastMonth = 1
    @State private var done: AnnualAmountPreview?

    private var year: Int { model.today.year }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Nieuw jaarbedrag").font(.title2.weight(.semibold))
                Text("Voor een rekening die één keer per jaar komt, zoals wegenbelasting. Je spaart er elke maand een twaalfde voor in een potje; dit venster zet potje, vaste overboeking en post in één keer goed.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
            Divider()
            if let done {
                finished(done)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        amountSection
                        potSection
                        distributionSection
                        itemSection
                        forecastSection
                        summarySection
                    }
                    .padding(20)
                }
                Divider()
                HStack {
                    Spacer()
                    Button("Annuleer") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("Zet klaar") { save() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(previewResult.preview == nil)
                }
                .padding(16)
            }
        }
        .frame(width: 620, height: 680)
        .task {
            data = PotsAnnualData.load(model: model, year: year)
            newDistributionAccountId = data.savings.first?.id
            distributionId = data.distributions.first(where: { $0.id.flatMap { data.linkedItem[$0] } != nil })?.id ?? data.distributions.first?.id
            if !data.yearExists { itemTag = nil }
            forecastMonth = model.today.month
        }
    }

    // MARK: Onderdelen

    private var amountSection: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 10) {
            GridRow {
                Text("Waarvoor").foregroundStyle(.secondary)
                TextField("Waarvoor", text: $name, prompt: Text("bijv. Wegenbelasting")).textFieldStyle(.roundedBorder)
            }
            GridRow {
                Text("Per jaar").foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    MoneyField("0,00", value: $yearly).textFieldStyle(.roundedBorder).frame(width: 130)
                    if let yearly, yearly > .zero {
                        Text("dat is \(AnnualAmountService.monthly(for: yearly).formatted()) per maand")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var potSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Potje").font(.headline)
            Picker("Potje", selection: $potMode) {
                Text("Nieuw potje").tag(PotMode.new)
                Text("Bestaand potje").tag(PotMode.existing)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            if potMode == .new {
                Text(name.trimmed.isEmpty ? "Het potje krijgt de naam die je hierboven invult." : "Er komt een reserveringspotje \(name.trimmed).")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                Picker("Bestaand potje", selection: $existingPotId) {
                    Text("Kies een potje").tag(Int64?.none)
                    ForEach(potsOnTargetAccount, id: \.id) { Text($0.name).tag($0.id) }
                }
                .labelsHidden().fixedSize()
            }
        }
    }

    private var distributionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Automatisch sparen").font(.headline)
            Picker("Automatisch sparen", selection: $distributionId) {
                ForEach(data.distributions, id: \.id) { d in
                    Text(data.linkedItem[d.id!].map { "\(d.name) (post \($0))" } ?? d.name).tag(d.id)
                }
                if !data.distributions.isEmpty { Divider() }
                Text("Nieuwe vaste overboeking").tag(Int64?.none)
            }
            .labelsHidden().fixedSize()
            .onChange(of: distributionId) { _, _ in existingPotId = nil }
            if distributionId == nil {
                HStack(spacing: 10) {
                    TextField("Naam", text: $newDistributionName).textFieldStyle(.roundedBorder).frame(width: 240)
                    if data.savings.count > 1 {
                        Picker("Naar", selection: $newDistributionAccountId) {
                            ForEach(data.savings, id: \.id) { Text($0.name).tag($0.id) }
                        }
                        .fixedSize()
                    }
                }
                Text("Een nieuwe overboeking betekent ook een nieuwe overboeking bij de bank.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var itemSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Post in je begroting \(String(year))").font(.headline)
            if let distributionId, let label = data.linkedItem[distributionId] {
                Text("Post \(label) volgt het totaal van deze overboeking vanzelf.").font(.callout).foregroundStyle(.secondary)
            } else if !data.yearExists {
                Text("Er is geen open begrotingsjaar \(String(year)). De begroting rekent er pas mee als je de overboeking later aan een post koppelt.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                Picker("Post", selection: $itemTag) {
                    Text("Nieuwe post").tag(Optional(Self.newItemTag))
                    if !data.freeItems.isEmpty {
                        Divider()
                        ForEach(data.freeItems, id: \.id) { Text($0.label).tag($0.id) }
                    }
                    Divider()
                    Text("Geen post (nu niet)").tag(Int64?.none)
                }
                .labelsHidden().fixedSize()
                if itemTag == Self.newItemTag {
                    TextField("Naam van de post", text: $newItemLabel,
                              prompt: Text(distributionId == nil ? newDistributionName : "Naam van de post"))
                        .textFieldStyle(.roundedBorder).frame(width: 240)
                }
                Text("Het plan van de post wordt min het totaal van de overboeking: zo telt de overboeking als uitgave op je betaalrekening.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var forecastSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Toggle("Zet de rekening als verwachting in het potje, in", isOn: $withForecast).toggleStyle(.checkbox)
                Picker("Maand", selection: $forecastMonth) {
                    ForEach(1...12, id: \.self) { Text(Day.monthNames[$0 - 1]).tag($0) }
                }
                .labelsHidden().fixedSize().disabled(!withForecast)
            }
            Text("Dan toont de vooruitblik van het potje de dip als de rekening komt. Verwachtingen tellen nergens anders in mee.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var summarySection: some View {
        let result = previewResult
        VStack(alignment: .leading, spacing: 8) {
            Text("Wat er gebeurt").font(.headline)
            if let preview = result.preview {
                ChainBox {
                    Text(preview.summary).font(.callout).fixedSize(horizontal: false, vertical: true)
                }
                ForEach(Array(preview.steps.enumerated()), id: \.offset) { _, step in
                    Text("• \(step)").font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text(result.message ?? "Vul in waarvoor het is en het bedrag per jaar.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func finished(_ preview: AnnualAmountPreview) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Klaargezet", systemImage: "checkmark.circle.fill").font(.title3.weight(.semibold)).foregroundStyle(Theme.positive)
            ChainBox { Text(preview.summary).font(.callout).fixedSize(horizontal: false, vertical: true) }
            Text(preview.afterwards).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer()
            HStack {
                Spacer()
                Button("Klaar") { dismiss() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
    }

    // MARK: Logica (in HFBudget)

    private var targetAccountId: Int64? {
        if let distributionId { return data.distributions.first { $0.id == distributionId }?.accountId }
        return newDistributionAccountId
    }

    private var potsOnTargetAccount: [Pot] { data.pots.filter { $0.accountId == targetAccountId } }

    /// De keuzes als verzoek aan `AnnualAmountService`, of nil als er nog iets ontbreekt.
    private var request: AnnualAmountRequest? {
        guard let yearly, yearly > .zero, !name.trimmed.isEmpty else { return nil }
        let pot: AnnualAmountRequest.PotChoice
        switch potMode {
        case .new: pot = .new(name: name.trimmed)
        case .existing:
            guard let existingPotId else { return nil }
            pot = .existing(existingPotId)
        }
        let distribution: AnnualAmountRequest.DistributionChoice
        if let distributionId {
            distribution = .existing(distributionId)
        } else {
            guard let account = newDistributionAccountId else { return nil }
            distribution = .new(name: newDistributionName.trimmed, accountId: account)
        }
        var item: AnnualAmountRequest.ItemChoice?
        if let itemTag {
            if itemTag == Self.newItemTag {
                let label = newItemLabel.trimmed
                item = .new(label: label.isEmpty ? (distributionId == nil ? newDistributionName.trimmed : name.trimmed) : label)
            } else {
                item = .existing(itemTag)
            }
        }
        return AnnualAmountRequest(name: name.trimmed, yearlyAmount: yearly, pot: pot, distribution: distribution,
                                   item: item, year: year, forecastMonth: withForecast ? forecastMonth : nil,
                                   today: model.today)
    }

    private var previewResult: (preview: AnnualAmountPreview?, message: String?) {
        guard let request else { return (nil, nil) }
        do {
            return (try model.db.read { try AnnualAmountService.preview($0, request) }, nil)
        } catch {
            return (nil, error.localizedDescription)
        }
    }

    private func save() {
        guard let request, let preview = previewResult.preview else { return }
        let ok = model.perform("\(preview.potName): \(preview.monthly.formatted()) per maand klaargezet") {
            _ = try model.db.write { try AnnualAmountService.apply($0, request) }
        }
        if ok { done = preview }
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
