import SwiftUI
import Charts
import AppKit
import HFCore
import HFInsight

/// Opmaak voor de rapporten: alleen weergave, geen rekenregels.
enum ReportsFormat {
    /// Hele euro's voor assen en labels: "€ 1.250" of "-€ 500".
    static func euros(_ value: Double) -> String {
        euros(Money(cents: Int64(value.rounded()) * 100))
    }

    static func euros(_ amount: Money) -> String {
        let rounded = Money(cents: Int64((amount.doubleValue).rounded()) * 100)
        return String(rounded.formatted().dropLast(3))
    }

    static func month(_ month: Int) -> String { Day.monthNamesShort[month - 1] }
    static func monthIndex(_ name: String) -> Int? { Day.monthNamesShort.firstIndex(of: name).map { $0 + 1 } }
    static func monthName(_ month: Int) -> String { Day.monthNames[month - 1] }

    /// "juni 2027" of "heel 2027".
    static func period(year: Int, month: Int?) -> String {
        month.map { "\(monthName($0)) \(year)" } ?? "heel \(year)"
    }

    /// Bedrag voor het klembord: "1234,56" (zonder punten, zodat Excel het als getal leest).
    static func plain(_ amount: Money) -> String {
        amount.formatted(symbol: false).replacingOccurrences(of: ".", with: "")
    }

    static func tsv(_ header: [String], _ rows: [[String]]) -> String {
        ([header] + rows).map { row in
            row.map { $0.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ") }
                .joined(separator: "\t")
        }.joined(separator: "\n")
    }

    /// Aandeel voor weergave, bv. "34%".
    static func share(_ part: Money, of total: Money) -> String {
        guard !total.isZero else { return "–" }
        return "\(Int((part.doubleValue / total.doubleValue * 100).rounded()))%"
    }

    static func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}

/// Kleuren van de rapporten: één accent, grijs voor de tweede reeks, rood alleen voor een overschrijding.
enum ReportsColor {
    static let accent = Theme.accent
    static let neutral = Theme.series[7]
    static let over = Theme.negative
}

/// Of de uitklapbare delen open beginnen (`HF_REPORTS_OPEN`, voor een snapshot).
enum ReportsDebug {
    static var startsOpen: Bool { ProcessInfo.processInfo.environment["HF_REPORTS_OPEN"] != nil }
    /// Toont het samenvoegvenster in plaats van het tabblad (`HF_REPORTS_MERGE`, voor een snapshot).
    static var showsMerge: Bool { ProcessInfo.processInfo.environment["HF_REPORTS_MERGE"] != nil }
}

/// De vraag die een rapport beantwoordt, als gewone zin boven de grafiek.
struct ReportsQuestion: View {
    let text: String
    var detail: String?

    init(_ text: String, detail: String? = nil) { self.text = text; self.detail = detail }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(text).font(.system(.title2, design: .rounded).weight(.semibold))
            if let detail { Text(detail).font(.body).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Groot kerngetal zonder kader.
struct ReportsKeyNumber: View {
    let title: String
    let value: String
    var tint: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.callout).foregroundStyle(.secondary)
            Text(value).font(.system(size: 28, weight: .semibold, design: .rounded)).monospacedDigit()
                .foregroundStyle(tint).lineLimit(1).minimumScaleFactor(0.7)
        }
    }
}

/// Uitklapbaar deel onder een grafiek, bv. "Toon cijfers".
struct ReportsDisclosure<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    @State private var isOpen = ReportsDebug.startsOpen

    init(_ title: String, @ViewBuilder content: () -> Content) { self.title = title; self.content = content() }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { isOpen.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                    Text(isOpen ? title.replacingOccurrences(of: "Toon", with: "Verberg") : title)
                }
                .font(.body.weight(.medium)).foregroundStyle(Theme.accent).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isOpen ? "Klap dit deel weer in" : "Klap uit om de cijfers achter de grafiek te zien")
            if isOpen { content }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Bedrag in gewone tekstkleur; rood alleen als `redIfNegative` en het bedrag negatief is.
struct ReportsAmount: View {
    let amount: Money
    var redIfNegative = false
    var alwaysSign = false
    var symbol = true

    var body: some View {
        Text(amount.formatted(symbol: symbol, alwaysSign: alwaysSign)).monospacedDigit()
            .foregroundStyle(redIfNegative && amount.isNegative ? ReportsColor.over : Color.primary)
    }
}

/// Maandkiezer: "Heel jaar" of één maand, met pijltjes.
struct ReportsMonthPicker: View {
    @Binding var month: Int?
    var allowsWholeYear = true

    var body: some View {
        HStack(spacing: 4) {
            Button { step(-1) } label: { Image(systemName: "chevron.left") }
                .disabled(month == nil || month == 1)
                .help("Vorige maand")
            Picker("Periode", selection: $month) {
                if allowsWholeYear {
                    Text("Heel jaar").tag(Int?.none)
                    Divider()
                }
                ForEach(1...12, id: \.self) { m in
                    Text(ReportsFormat.monthName(m).capitalized).tag(Int?.some(m))
                }
            }
            .labelsHidden()
            .frame(width: 130)
            .help("Kies een maand of het hele jaar")
            Button { step(1) } label: { Image(systemName: "chevron.right") }
                .disabled(month == 12)
                .help("Volgende maand")
        }
        .controlSize(.small)
    }

    private func step(_ delta: Int) {
        guard let current = month else { month = 1; return }
        month = min(12, max(1, current + delta))
    }
}

/// Zwevend kaartje met exacte waarden bij een punt in een grafiek.
struct ReportsTooltip: View {
    struct Line: Identifiable {
        let id = UUID()
        let label: String
        let color: Color?
        let value: String
    }

    let title: String
    let lines: [Line]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.semibold))
            ForEach(lines) { line in
                HStack(spacing: 6) {
                    if let color = line.color {
                        Circle().fill(color).frame(width: 7, height: 7)
                    }
                    Text(line.label).foregroundStyle(.secondary)
                    Spacer(minLength: 12)
                    Text(line.value).monospacedDigit()
                }
                .font(.caption)
            }
        }
        .padding(8)
        .frame(minWidth: 150)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.hairline))
        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
    }
}

/// Legenda-item: bolletje met naam.
struct ReportsLegendItem: View {
    let title: String
    let color: Color
    var dashed = false

    var body: some View {
        HStack(spacing: 5) {
            if dashed {
                Capsule().fill(color).frame(width: 12, height: 2)
            } else {
                RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 9, height: 9)
            }
            Text(title).font(.callout).foregroundStyle(.secondary)
        }
    }
}

/// Lijst met boekingen: datum, omschrijving, tags en bedrag.
struct ReportsEntryList: View {
    let entries: [EntryRow]
    var ranked = false
    var withYear = false
    var showTags = false

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                HStack(spacing: 10) {
                    if ranked {
                        Text("\(index + 1)").font(.caption).monospacedDigit().foregroundStyle(.tertiary)
                            .frame(width: 18, alignment: .trailing)
                    }
                    Text(entry.day.short(withYear: withYear)).font(.callout).monospacedDigit()
                        .foregroundStyle(.secondary).frame(width: withYear ? 84 : 50, alignment: .leading)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(entry.label.isEmpty ? "Zonder omschrijving" : entry.label).lineLimit(1)
                        Text(subtitle(entry)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    if showTags {
                        Text(entry.tags.map(\.name).joined(separator: ", ")).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    }
                    ReportsAmount(amount: entry.amount).frame(width: 110, alignment: .trailing)
                }
                .padding(.vertical, 7)
                if index < entries.count - 1 { Divider() }
            }
        }
    }

    private func subtitle(_ entry: EntryRow) -> String {
        let kind = entry.itemLabel ?? (entry.isDivers ? "Overig" : (entry.potName ?? ""))
        let counterparty = entry.bank?.counterpartyName ?? ""
        return [kind, counterparty.isEmpty ? entry.accountName : counterparty].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

/// Kopregel van een eigen tabel.
struct ReportsColumnTitle: View {
    let title: String
    var help: String?
    var alignment: Alignment = .trailing

    init(_ title: String, help: String? = nil, alignment: Alignment = .trailing) {
        self.title = title; self.help = help; self.alignment = alignment
    }

    var body: some View {
        Text(title).font(.callout).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: alignment)
            .help(help ?? title)
    }
}

extension View {
    /// Y-as in hele euro's.
    func reportsEuroAxis() -> some View {
        chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine().foregroundStyle(Theme.hairline.opacity(0.5))
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text(ReportsFormat.euros(v)).font(.callout).monospacedDigit()
                    }
                }
            }
        }
    }

    /// X-as met categorieën (maanden, jaren): alleen labels, geen lijnen.
    func reportsCategoryAxis() -> some View {
        chartXAxis {
            AxisMarks { _ in AxisValueLabel().font(.callout) }
        }
    }

    /// Volgt de muis boven een grafiek met een categorie-as (maanden, jaren) en meldt klikken.
    func reportsChartHover(_ hover: Binding<String?>, onClick: ((String) -> Void)? = nil) -> some View {
        chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let point):
                            hover.wrappedValue = reportsCategory(at: point, proxy: proxy, geo: geo)
                        case .ended:
                            hover.wrappedValue = nil
                        }
                    }
                    .onTapGesture { point in
                        if let category = reportsCategory(at: point, proxy: proxy, geo: geo) { onClick?(category) }
                    }
            }
        }
    }
}

@MainActor
private func reportsCategory(at point: CGPoint, proxy: ChartProxy, geo: GeometryProxy) -> String? {
    guard let frame = proxy.plotFrame else { return nil }
    let origin = geo[frame].origin
    return proxy.value(atX: point.x - origin.x, as: String.self)
}
