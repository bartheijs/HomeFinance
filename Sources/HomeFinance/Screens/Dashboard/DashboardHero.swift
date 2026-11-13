import SwiftUI
import HFCore
import HFInsight

/// Het grote getal: besteedbaar nu, met één regel uitleg. De opbouw zit achter een uitklapper.
struct DashboardHero: View {
    let spendable: Spendable
    @State private var showBreakdown = false

    private static let spendableHelp = """
        Besteedbaar is wat je vrij kunt uitgeven: het saldo van de betaalrekening, min het geld dat daar \
        nog voor reserveringen op staat, min de buffers die je nooit wilt aanspreken (anti-rood).
        """

    private var tint: Color { spendable.spendable.isNegative ? Theme.negative : Theme.accent }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Besteedbaar").font(.title3.weight(.medium)).foregroundStyle(.secondary)
            Text(spendable.spendable.formatted())
                .font(.system(size: 76, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .help(Self.spendableHelp)
            Text(spendable.spendable.isNegative
                 ? "Je zit onder je buffers."
                 : "Vrij uit te geven, na reserveringen en buffers.")
                .font(.title3).foregroundStyle(.secondary)
                .padding(.top, 2)
            (Text("Eind van de maand: ").foregroundStyle(.secondary)
                + Text(spendable.spendableEndOfMonth.formatted()).fontWeight(.semibold)
                    .foregroundColor(spendable.spendableEndOfMonth.isNegative ? Theme.negative : .primary))
                .font(.body).monospacedDigit()
                .padding(.top, 14)
                .help("Een vooruitblik: besteedbaar van nu, plus de vaste posten die deze maand nog verwacht worden en nog niet geboekt zijn.")
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { showBreakdown.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(showBreakdown ? 90 : 0))
                    Text("Hoe is dit opgebouwd?")
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.accent)
            .padding(.top, 18)
            if showBreakdown {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 32) {
                        breakdown.frame(width: 280)
                        expected.frame(width: 260)
                    }
                    VStack(alignment: .leading, spacing: 20) {
                        breakdown.frame(maxWidth: 320)
                        expected.frame(maxWidth: 320)
                    }
                }
                .padding(.top, 14)
            }
        }
    }

    // MARK: De opbouw

    private var breakdown: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Nu").font(.subheadline).foregroundStyle(.secondary)
            line("Saldo betaalrekening", spendable.balance, sign: " ",
                 help: "Wat er vandaag op de betaalrekening(en) staat volgens de boekingen.")
            line("Gereserveerd", spendable.reserved, sign: "−",
                 help: "Geld op de betaalrekening dat al een bestemming heeft, zoals de jaarlijkse posten waarvoor je spaart.")
            line("Anti-rood", spendable.antiRood, sign: "−",
                 help: "Vaste buffer die altijd op de rekening blijft staan, zodat je niet rood komt te staan.")
            if !spendable.tijdelijkAntiRood.isZero {
                line("Tijdelijk anti-rood", spendable.tijdelijkAntiRood, sign: "−",
                     help: "Extra buffer die je tijdelijk aanhoudt, bijvoorbeeld voor een grote uitgave die eraan komt.")
            }
            Divider()
            total("Besteedbaar", spendable.spendable)
        }
        .font(.callout)
    }

    private var expected: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Nog verwacht deze maand").font(.subheadline).foregroundStyle(.secondary)
            if spendable.expectedItems.isEmpty {
                Text("Alle vaste posten van deze maand zijn geboekt.").foregroundStyle(.secondary)
            } else {
                ForEach(spendable.expectedItems) { item in
                    HStack(spacing: 6) {
                        Text(item.label).lineLimit(1)
                        if item.isLate {
                            Image(systemName: "clock").font(.caption).foregroundStyle(Theme.negative)
                                .help("De verwachte dag is al voorbij.")
                        }
                        Spacer(minLength: 4)
                        Text(item.plan.formatted(alwaysSign: true)).monospacedDigit()
                    }
                }
                Divider()
                total("Eind van de maand", spendable.spendableEndOfMonth)
            }
        }
        .font(.callout)
    }

    private func line(_ title: String, _ amount: Money, sign: String, help: String) -> some View {
        HStack(spacing: 6) {
            Text(sign).frame(width: 12).foregroundStyle(.secondary)
            Text(title).lineLimit(1)
            Spacer(minLength: 4)
            Text(amount.formatted()).monospacedDigit()
        }
        .help(help)
    }

    private func total(_ title: String, _ amount: Money) -> some View {
        HStack(spacing: 6) {
            Text("=").frame(width: 12).foregroundStyle(.secondary)
            Text(title).fontWeight(.semibold)
            Spacer(minLength: 4)
            Text(amount.formatted()).monospacedDigit().fontWeight(.semibold)
                .foregroundStyle(amount.isNegative ? Theme.negative : Color.primary)
        }
    }
}

/// Staat op de plek van het grote getal zolang het jaar van vandaag nog geen begroting heeft.
struct DashboardYearMissingCard: View {
    @Environment(AppModel.self) private var model
    let year: Int

    var body: some View {
        HStack(alignment: .center, spacing: 20) {
            Image(systemName: "calendar.badge.plus")
                .font(.system(size: 44)).foregroundStyle(Theme.accent)
                .frame(width: 72)
            VStack(alignment: .leading, spacing: 6) {
                Text("Nog geen begroting voor \(String(year))")
                    .font(.system(.title2, design: .rounded).weight(.bold))
                Text("Besteedbaar en de vaste posten kunnen pas getoond worden als het jaar \(String(year)) bestaat. Maak het jaar aan in Instellingen; je kunt de posten van vorig jaar overnemen.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    model.settingsTab = "jaar"
                    model.selection = .settings
                } label: {
                    Label("Jaar \(String(year)) aanmaken", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.top, 6)
            }
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.accent.opacity(0.5)))
    }
}
