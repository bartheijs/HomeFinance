import SwiftUI
import HFCore
import HFInsight

/// Het grote getal: wat er deze maand nog te besteden is als alle vaste posten zijn geweest.
/// Besteedbaar nu staat klein eronder; de opbouw zit achter een uitklapper.
struct DashboardHero: View {
    @Environment(AppModel.self) private var model
    let spendable: Spendable
    @State private var showBreakdown = false

    private static let mainHelp = "Je saldo nu, plus wat er deze maand nog aan vaste posten binnenkomt en afgaat, min je anti-roodbuffer."
    private static let nowHelp = "Wat er nu vrij op de rekening staat, zonder de posten die deze maand nog komen."

    private var endTint: Color { spendable.spendableEndOfMonth.isNegative ? Theme.negative : Theme.accent }
    private var monthName: String { Day.monthNames[spendable.asOf.month - 1] }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Nog te besteden deze maand").font(.title3.weight(.medium)).foregroundStyle(.secondary)
                .help(Self.mainHelp)
            Text(spendable.spendableEndOfMonth.formatted())
                .font(.system(size: 76, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(endTint)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .help(Self.mainHelp)
            Text("Als alle vaste lasten en inkomsten van \(monthName) zijn binnen, houd je dit over.")
                .font(.title3).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
            (Text("Besteedbaar nu: ").foregroundStyle(.secondary)
                + Text(spendable.spendable.formatted()).fontWeight(.semibold)
                    .foregroundColor(spendable.spendable.isNegative ? Theme.negative : .primary))
                .font(.body).monospacedDigit()
                .padding(.top, 14)
                .help(Self.nowHelp)
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
                breakdown
                    .frame(maxWidth: 420)
                    .padding(.top, 14)
            }
        }
    }

    // MARK: De opbouw

    private var breakdown: some View {
        VStack(alignment: .leading, spacing: 7) {
            line("Saldo betaalrekening nu", spendable.balance, sign: " ",
                 help: "Wat er vandaag op de betaalrekening(en) staat volgens de boekingen.")
            line("Anti-rood", spendable.antiRood, sign: "−",
                 help: "Vaste buffer die altijd op de rekening blijft staan, zodat je niet rood komt te staan.")
            if !spendable.tijdelijkAntiRood.isZero {
                line("Tijdelijk geleend van spaar", spendable.tijdelijkAntiRood, sign: "−",
                     help: "Geld dat je tijdelijk van spaar naar de betaalrekening hebt gehaald en nog moet terugboeken. Het staat op de rekening, maar is niet van jou om uit te geven.")
            }
            Divider()
            total("Besteedbaar nu", spendable.spendable).help(Self.nowHelp)

            Text("Nog verwacht deze maand").font(.subheadline).foregroundStyle(.secondary)
                .padding(.top, 10)
            if spendable.expectedItems.isEmpty {
                Text("Alle vaste posten van \(monthName) zijn al geboekt of afgevinkt.").foregroundStyle(.secondary)
            } else {
                ForEach(spendable.expectedItems) { item in
                    HStack(spacing: 6) {
                        Text(item.label).lineLimit(1)
                        if item.isLate { Pill("te laat", color: Theme.negative) }
                        Spacer(minLength: 4)
                        Text(item.plan.formatted(alwaysSign: true)).monospacedDigit()
                    }
                    .help(item.isLate ? "De verwachte dag is al voorbij en er is nog niets geboekt." : "Wordt later deze maand verwacht.")
                }
                HStack(spacing: 6) {
                    Text("Samen").foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Text(spendable.expectedTotal.formatted(alwaysSign: true)).monospacedDigit().foregroundStyle(.secondary)
                }
                .font(.caption)
            }
            Divider()
            total("Nog te besteden", spendable.spendableEndOfMonth).help(Self.mainHelp)

            HStack(spacing: 0) {
                Text("Is een post al betaald maar staat hij er nog? Vink hem af in het ")
                    .foregroundStyle(.secondary)
                Button("Maandgrid") { model.selection = .grid }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.accent)
                    .help("Open het maandgrid, waar je een post kunt afvinken")
                Text(".").foregroundStyle(.secondary)
            }
            .font(.caption)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 8)
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
