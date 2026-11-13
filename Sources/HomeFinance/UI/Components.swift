import SwiftUI
import HFCore

/// Een geldbedrag, rechts uitgelijnd te gebruiken, met vaste cijferbreedte.
struct MoneyText: View {
    let amount: Money
    /// Groen voor positief, rood voor negatief.
    var colored = false
    var alwaysSign = false
    var symbol = true

    init(_ amount: Money, colored: Bool = false, alwaysSign: Bool = false, symbol: Bool = true) {
        self.amount = amount; self.colored = colored; self.alwaysSign = alwaysSign; self.symbol = symbol
    }

    var body: some View {
        Text(amount.formatted(symbol: symbol, alwaysSign: alwaysSign))
            .monospacedDigit()
            .foregroundStyle(colored ? (amount.isNegative ? Theme.negative : (amount.isZero ? Color.secondary : Theme.positive)) : Color.primary)
    }
}

/// Wit vlak met afgeronde hoeken, de basis van elk blok op een scherm.
struct Card<Content: View>: View {
    var title: String?
    var icon: String?
    var padding: CGFloat = 16
    @ViewBuilder var content: Content

    init(_ title: String? = nil, icon: String? = nil, padding: CGFloat = 16, @ViewBuilder content: () -> Content) {
        self.title = title; self.icon = icon; self.padding = padding; self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                Label {
                    Text(title).font(.headline)
                } icon: {
                    if let icon { Image(systemName: icon).foregroundStyle(Theme.accent) }
                }
            }
            content
        }
        .padding(padding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.hairline.opacity(0.6)))
    }
}

/// Kerngetal met titel en toelichting.
struct StatTile: View {
    let title: String
    let value: String
    var subtitle: String?
    var icon: String?
    var tint: Color = Theme.accent

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if let icon { Image(systemName: icon).foregroundStyle(tint) }
                Text(title).font(.subheadline).foregroundStyle(.secondary)
            }
            Text(value).font(.system(.title2, design: .rounded).weight(.semibold)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.7)
            if let subtitle {
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.hairline.opacity(0.6)))
    }
}

/// Klein gekleurd label (status, tag, zekerheid).
struct Pill: View {
    let text: String
    var color: Color = .secondary
    var icon: String?

    init(_ text: String, color: Color = .secondary, icon: String? = nil) {
        self.text = text; self.color = color; self.icon = icon
    }

    var body: some View {
        HStack(spacing: 4) {
            if let icon { Image(systemName: icon) }
            Text(text)
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 8).padding(.vertical, 3)
        .foregroundStyle(color)
        .background(color.opacity(0.14), in: Capsule())
    }
}

/// Kop van een scherm: titel, toelichting en knoppen rechts.
struct ScreenHeader<Trailing: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var trailing: Trailing

    init(_ title: String, subtitle: String? = nil, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.title = title; self.subtitle = subtitle; self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(.title, design: .rounded).weight(.bold))
                if let subtitle { Text(subtitle).font(.callout).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 12)
    }
}

/// Uitleg bij een leeg scherm, met optioneel een knop.
struct EmptyState: View {
    let title: String
    let message: String
    var icon: String = "tray"
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: icon)
        } description: {
            Text(message)
        } actions: {
            if let actionTitle, let action {
                Button(actionTitle, action: action).buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Tekstveld voor een bedrag in Nederlandse notatie. `value` is nil zolang de invoer ongeldig of leeg is.
struct MoneyField: View {
    let title: String
    @Binding var value: Money?
    @State private var text = ""
    @FocusState private var focused: Bool

    init(_ title: String, value: Binding<Money?>) { self.title = title; self._value = value }

    var body: some View {
        TextField(title, text: $text)
            .multilineTextAlignment(.trailing)
            .monospacedDigit()
            .focused($focused)
            .onAppear { text = value?.formatted(symbol: false) ?? "" }
            .onChange(of: text) { _, new in value = Money(parsing: new) }
            .onChange(of: focused) { _, isFocused in
                if !isFocused, let v = value { text = v.formatted(symbol: false) }
            }
            .overlay(alignment: .leading) {
                if !text.isEmpty && value == nil {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
                        .help("Dit is geen geldig bedrag. Gebruik bijvoorbeeld 12,50")
                        .padding(.leading, 4)
                }
            }
    }
}

extension Day {
    /// "5 jan" of met jaar "5 jan 2027".
    func short(withYear: Bool = false) -> String {
        "\(day) \(Day.monthNamesShort[month - 1])" + (withYear ? " \(year)" : "")
    }
}

extension Confidence {
    var title: String {
        switch self { case .hoog: "Zeker"; case .midden: "Waarschijnlijk"; case .laag: "Gok"; case .geen: "Onbekend" }
    }
    var color: Color {
        switch self { case .hoog: Theme.positive; case .midden: Theme.info; case .laag: Theme.warning; case .geen: .secondary }
    }
}
