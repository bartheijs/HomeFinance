import SwiftUI
import HFCore
import HFInsight

/// Het grote getal: besteedbaar nu, de opbouw ervan en de verwachting voor het eind van de maand.
struct DashboardHeroCard: View {
    let spendable: Spendable
    @State private var showExpected = false

    private static let spendableHelp = """
        Besteedbaar is wat je vrij kunt uitgeven: het saldo van de betaalrekening, min het geld dat daar \
        nog voor reserveringen op staat, min de buffers die je nooit wilt aanspreken (anti-rood).
        """

    private var tint: Color {
        spendable.spendable.isNegative ? Theme.negative : (spendable.spendable.isZero ? .secondary : Theme.positive)
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 20) {
                headline.frame(minWidth: 230, maxWidth: .infinity, alignment: .leading)
                Divider()
                breakdown.frame(width: 250)
                Divider()
                endOfMonth.frame(width: 215, alignment: .leading)
            }
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 20) {
                    headline.frame(maxWidth: .infinity, alignment: .leading)
                    Divider()
                    breakdown.frame(width: 250)
                }
                Divider()
                endOfMonth
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.hairline.opacity(0.6)))
    }

    // MARK: Het getal

    private var headline: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Besteedbaar").font(.headline)
                Image(systemName: "info.circle").font(.caption).foregroundStyle(.tertiary)
            }
            .help(Self.spendableHelp)
            Text(spendable.spendable.formatted())
                .font(.system(size: 46, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .help(Self.spendableHelp)
            Text(spendable.spendable.isNegative
                 ? "Je zit onder je buffers. Peildatum \(spendable.asOf.short())."
                 : "Vrij uit te geven op \(spendable.asOf.short()), na reserveringen en buffers.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 10)
            DashboardBalanceBar(spendable: spendable)
        }
    }

    // MARK: De opbouw

    private var breakdown: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Zo is het opgebouwd").font(.subheadline).foregroundStyle(.secondary)
            line("Saldo betaalrekening", spendable.balance, sign: " ", dot: nil,
                 help: "Wat er vandaag op de betaalrekening(en) staat volgens de boekingen.")
            line("Gereserveerd", spendable.reserved, sign: "−", dot: Theme.info,
                 help: "Geld op de betaalrekening dat al een bestemming heeft, zoals de jaarlijkse posten waarvoor je spaart.")
            line("Anti-rood", spendable.antiRood, sign: "−", dot: Theme.warning,
                 help: "Vaste buffer die altijd op de rekening blijft staan, zodat je niet rood komt te staan.")
            line("Tijdelijk anti-rood", spendable.tijdelijkAntiRood, sign: "−", dot: Theme.warning.opacity(0.55),
                 help: "Extra buffer die je tijdelijk aanhoudt, bijvoorbeeld voor een grote uitgave die eraan komt.")
            Divider()
            HStack(spacing: 6) {
                Text("=").frame(width: 12).foregroundStyle(.secondary)
                Text("Besteedbaar").fontWeight(.semibold)
                Spacer(minLength: 4)
                Text(spendable.spendable.formatted()).monospacedDigit().fontWeight(.semibold).foregroundStyle(tint)
            }
        }
        .font(.callout)
    }

    private func line(_ title: String, _ amount: Money, sign: String, dot: Color?, help: String) -> some View {
        HStack(spacing: 6) {
            Text(sign).frame(width: 12).foregroundStyle(.secondary)
            Text(title).lineLimit(1)
            if let dot { Circle().fill(dot).frame(width: 7, height: 7) }
            Spacer(minLength: 4)
            Text(amount.formatted()).monospacedDigit()
        }
        .help(help)
    }

    // MARK: Eind van de maand

    private var endOfMonth: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Eind van de maand").font(.subheadline).foregroundStyle(.secondary)
                Image(systemName: "info.circle").font(.caption).foregroundStyle(.tertiary)
            }
            .help("Een vooruitblik: besteedbaar van nu, plus de vaste posten die deze maand nog verwacht worden en nog niet geboekt zijn.")
            MoneyText(spendable.spendableEndOfMonth, colored: true)
                .font(.system(.title, design: .rounded).weight(.semibold))
                .lineLimit(1).minimumScaleFactor(0.7)
            if spendable.expectedItems.isEmpty {
                Label("Alle vaste posten van deze maand zijn geboekt.", systemImage: "checkmark.circle")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                let count = spendable.expectedItems.count
                Text("Na \(count) verwachte \(count == 1 ? "post" : "posten") van samen \(spendable.expectedTotal.formatted(alwaysSign: true)).")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { showExpected.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.right").font(.caption2.weight(.semibold))
                            .rotationEffect(.degrees(showExpected ? 90 : 0))
                        Text(showExpected ? "Verberg posten" : "Toon posten")
                    }
                    .font(.caption.weight(.medium))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accent)
                .padding(.top, 2)
                if showExpected {
                    VStack(spacing: 4) {
                        ForEach(spendable.expectedItems) { item in
                            HStack(spacing: 6) {
                                if item.isLate {
                                    Image(systemName: "clock.badge.exclamationmark").foregroundStyle(Theme.warning)
                                        .help("De verwachte dag is al voorbij.")
                                }
                                Text(item.label).lineLimit(1)
                                Spacer(minLength: 4)
                                MoneyText(item.plan, colored: true)
                            }
                            .font(.caption)
                        }
                    }
                    .padding(.top, 2)
                }
            }
        }
    }
}

/// Balk die laat zien hoe het saldo verdeeld is over gereserveerd, buffers en besteedbaar.
private struct DashboardBalanceBar: View {
    let spendable: Spendable

    private var parts: [(Color, Money, String)] {
        [(Theme.info, spendable.reserved, "Gereserveerd"),
         (Theme.warning, spendable.antiRood, "Anti-rood"),
         (Theme.warning.opacity(0.55), spendable.tijdelijkAntiRood, "Tijdelijk anti-rood"),
         (Theme.positive, spendable.spendable, "Besteedbaar")]
    }

    var body: some View {
        // Alleen zinvol als elk deel een stuk van het saldo is.
        if !spendable.balance.isNegative, !spendable.balance.isZero, parts.allSatisfy({ !$0.1.isNegative }) {
            VStack(alignment: .leading, spacing: 5) {
                GeometryReader { geo in
                    HStack(spacing: 2) {
                        ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                            if !part.1.isZero {
                                Rectangle().fill(part.0)
                                    .frame(width: max(3, (geo.size.width - 6) * DashboardFormat.fraction(part.1, of: spendable.balance)))
                                    .help("\(part.2): \(part.1.formatted())")
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .clipShape(Capsule())
                }
                .frame(height: 8)
                Text("Verdeling van \(spendable.balance.formatted()) op de betaalrekening")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
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
