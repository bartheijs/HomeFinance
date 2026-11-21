import SwiftUI
import HFCore
import HFInsight

/// Het grote getal: wat er deze maand nog te besteden is, met de opbouw als korte rekensom eronder.
/// De regels komen uit `SpendableBreakdown` (HFInsight) en tellen exact op tot het grote getal.
struct DashboardHero: View {
    @Environment(AppModel.self) private var model
    let spendable: Spendable
    /// Banktransacties op de betaalrekening die nog niet geboekt zijn (tellen nog niet mee).
    var unbooked: Int = 0
    @State private var showExpected = false

    private var breakdown: SpendableBreakdown { SpendableBreakdown(spendable) }
    private var endTint: Color { spendable.spendableEndOfMonth.isNegative ? Theme.negative : Theme.accent }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Nog te besteden deze maand").font(.title3.weight(.medium))
            Text(spendable.spendableEndOfMonth.formatted())
                .font(.system(size: 76, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(endTint)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            if unbooked > 0 { unbookedWarning }
            sum
                .frame(maxWidth: 520)
                .padding(.top, 14)
        }
    }

    /// Zolang er banktransacties wachten, klopt het grote getal nog niet.
    private var unbookedWarning: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
            Text(unbooked == 1 ? "1 banktransactie telt nog niet mee." : "\(unbooked) banktransacties tellen nog niet mee.")
            Button("Boeken") { model.selection = .review }
                .controlSize(.small)
                .help("Ga naar Importeren en nakijken om deze banktransacties te boeken.")
        }
        .font(.callout)
        .padding(.top, 10)
    }

    // MARK: De rekensom

    private var sum: some View {
        let b = breakdown
        return VStack(alignment: .leading, spacing: 7) {
            ForEach(b.lines) { line in
                if line.kind == .expected {
                    expectedLine(line)
                    if showExpected { expectedDetail(b).padding(.leading, 18) }
                } else {
                    row(sign: sign(line), title: line.title, amount: line.amount.magnitude)
                }
            }
            Divider()
            HStack(spacing: 6) {
                Text("=").frame(width: 12)
                Text("Nog te besteden deze maand").fontWeight(.semibold)
                Spacer(minLength: 4)
                Text(b.total.formatted()).monospacedDigit().fontWeight(.semibold)
                    .foregroundStyle(b.total.isNegative ? Theme.negative : Color.primary)
            }
        }
        .font(.callout)
    }

    private func sign(_ line: SpendableBreakdown.Line) -> String {
        switch line.kind {
        case .balance: " "
        default: line.amount.isNegative ? "−" : "+"
        }
    }

    private func row(sign: String, title: String, amount: Money) -> some View {
        HStack(spacing: 6) {
            Text(sign).frame(width: 12)
            Text(title).lineLimit(1)
            Spacer(minLength: 4)
            Text(amount.formatted()).monospacedDigit()
        }
    }

    private func expectedLine(_ line: SpendableBreakdown.Line) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { showExpected.toggle() }
        } label: {
            HStack(spacing: 6) {
                Text(sign(line)).frame(width: 12)
                Text(line.title).lineLimit(1)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                    .rotationEffect(.degrees(showExpected ? 90 : 0))
                Spacer(minLength: 4)
                Text(line.amount.magnitude.formatted()).monospacedDigit()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(showExpected ? "Inklappen" : "Toon de verwachte inkomsten en uitgaven per post")
    }

    @ViewBuilder private func expectedDetail(_ b: SpendableBreakdown) -> some View {
        if b.expectedIncome.isEmpty && b.expectedExpenses.isEmpty {
            Text("Niets meer verwacht deze maand.")
        } else {
            VStack(alignment: .leading, spacing: 5) {
                if !b.expectedIncome.isEmpty { group("Inkomsten", b.expectedIncome) }
                if !b.expectedExpenses.isEmpty { group("Uitgaven", b.expectedExpenses) }
            }
        }
    }

    private func group(_ title: String, _ lines: [SpendableBreakdown.ExpectedLine]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.callout.weight(.semibold)).padding(.top, 4)
            ForEach(lines) { line in
                HStack(spacing: 6) {
                    Text(line.title).lineLimit(1)
                    if line.isLate { Pill("te laat", color: Theme.negative) }
                    Spacer(minLength: 4)
                    MoneyText(line.amount, colored: true, alwaysSign: true)
                }
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
                                Button {
                    model.selection = .budget
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
