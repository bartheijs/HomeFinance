import SwiftUI
import AppKit
import HFCore

/// De tabbladen van Instellingen. De id's zijn de waarden van `AppModel.settingsTab`.
enum SettingsTab: String, CaseIterable, Identifiable {
    case rekeningen, regels, tags, backup, telefoon, over
    var id: String { rawValue }

    var title: String {
        switch self {
        case .rekeningen: "Rekeningen"
        case .regels: "Regels"
        case .tags: "Tags"
        case .backup: "Back-up"
        case .telefoon: "Telefoon"
        case .over: "Over"
        }
    }

    var subtitle: String {
        switch self {
        case .rekeningen: "Je betaal- en spaarrekeningen, en de controle met het banksaldo."
        case .regels: "Een regel ontstaat als je in Nakijken ‘Voortaan zo indelen’ aanvinkt, of als je hem hier maakt."
        case .tags: "Kenmerken om uitgaven te volgen, zoals tanken of uit eten."
        case .backup: "Reservekopieën van je administratie."
        case .telefoon: "Je belangrijkste cijfers als pagina op je telefoon."
        case .over: "Waar je gegevens staan en welke je bekijkt."
        }
    }
}

struct SettingsReloadKey: Equatable {
    var revision: Int
    var year: Int
}

enum SettingsFormat {
    private static let dateTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "nl_NL")
        f.dateFormat = "d MMM yyyy 'om' HH:mm"
        return f
    }()

    /// "12 jun 2027 om 14:03"
    static func dateTime(_ date: Date) -> String { dateTimeFormatter.string(from: date) }

    static func bytes(_ count: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f.string(fromByteCount: count)
    }

    /// Een `Day` als datum in de eigen tijdzone, voor een `DatePicker`.
    static func date(_ day: Day) -> Date {
        Calendar.current.date(from: DateComponents(year: day.year, month: day.month, day: day.day)) ?? day.date
    }

    /// "#RRGGBB" van een gekozen kleur.
    static func hex(_ color: Color) -> String {
        guard let c = NSColor(color).usingColorSpace(.sRGB) else { return "#888888" }
        func part(_ v: CGFloat) -> Int { min(255, max(0, Int((v * 255).rounded()))) }
        return String(format: "#%02X%02X%02X", part(c.redComponent), part(c.greenComponent), part(c.blueComponent))
    }

    static func count(_ n: Int, _ one: String, _ many: String) -> String { "\(n) \(n == 1 ? one : many)" }

    /// Kleuren voor nieuwe tags, in vaste volgorde.
    static let tagPalette = ["#1F7A5C", "#2D6CDF", "#D98E04", "#B0447F", "#6B5BD2", "#3C9AA8", "#C0562B", "#7A8590"]
}

/// Melding boven in een tabblad.
struct SettingsBanner: View {
    let icon: String
    let text: String
    var color: Color = Theme.info

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: icon).foregroundStyle(color)
            Text(.init(text)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .font(.callout)
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(color.opacity(0.25)))
    }
}

/// Rustige achtergrond voor een veld dat je in een tabelrij direct kunt bewerken.
struct SettingsInlineField: ViewModifier {
    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .padding(.horizontal, 6).padding(.vertical, 4)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 5))
    }
}

extension View {
    func settingsInlineField() -> some View { modifier(SettingsInlineField()) }
}

/// Regel met een titel, een toelichting eronder en rechts een bedieningselement.
struct SettingsRow<Control: View>: View {
    let title: String
    var text: String?
    @ViewBuilder var control: Control

    init(_ title: String, text: String? = nil, @ViewBuilder control: () -> Control) {
        self.title = title; self.text = text; self.control = control()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let text {
                    Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            control
        }
    }
}
