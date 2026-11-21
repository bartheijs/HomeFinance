import SwiftUI
import HFCore
import HFBudget

/// Wat de app extra herkent bij een wachtende banktransactie (UX-stap D2), in Nakijken en Transacties hetzelfde:
/// de terugbetaling van voorgeschoten geld ("Is dit je € … van Tanken terug?") en de andere helft van een eigen
/// overboeking. Alleen weergave; boeken doen de stores met `SettlementService.bookAsDeposit`.
struct WaitingExtras: View {
    let proposal: WaitingProposal
    /// Boek als overig met deze tag (één klik): daarmee staat er voor de tag niets meer open.
    let onDeposit: (SettlementService.DepositCandidate) -> Void
    /// Ga naar de andere helft (alleen als die nog wacht).
    let onShowOther: (() -> Void)?

    var body: some View {
        if !proposal.depositCandidates.isEmpty || proposal.otherHalf != nil {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(proposal.depositCandidates, id: \.tagId) { candidate in
                    depositCard(candidate)
                }
                if let other = proposal.otherHalf { otherHalfRow(other) }
            }
        }
    }

    private func depositCard(_ c: SettlementService.DepositCandidate) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Is dit je \(c.outstanding.formatted()) van \(c.tagName) terug?", systemImage: "arrow.uturn.backward.circle")
                .fontWeight(.medium)
            if !c.exact {
                Text("\((proposal.transaction.amount - c.outstanding).formatted(alwaysSign: true)) verschil")
                    .font(.callout)
            }
            Button("Tag \(c.tagName)") { onDeposit(c) }
                .help("Boekt deze bijschrijving als overig met de tag \(c.tagName). Daarna staat er voor \(c.tagName) niets meer open.")
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.info.opacity(0.09), in: RoundedRectangle(cornerRadius: 9))
    }

    private func otherHalfRow(_ other: WaitingOtherHalf) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "arrow.left.arrow.right").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(other.text).fixedSize(horizontal: false, vertical: true)
                Text("Dit is één overboeking tussen je eigen rekeningen; beide helften horen bij elkaar.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if other.isWaiting, let onShowOther {
                Button("Bekijk") { onShowOther() }
                    .buttonStyle(.link)
                    .help("Ga naar de andere helft op \(other.accountName), om daar het potje of de post te kiezen.")
            }
        }
        .font(.callout)
    }
}

/// "Losse overboeking? Kies een potje" bij een overboeking naar spaar met een ander bedrag dan automatisch
/// sparen, ook als het verschil klein is (de grens voor het automatische voorstel blijft, dit is alleen het
/// aanbod; D2).
struct LooseTransferOffer: View {
    let distributionName: String
    let difference: Money
    let choosePot: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Ander bedrag dan Automatisch sparen: \(distributionName) (\(difference.formatted(alwaysSign: true))).")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Losse overboeking? Kies een potje") { choosePot() }
                .buttonStyle(.link)
                .help("Is dit een losse overboeking naar spaar, en niet je vaste overboeking? Dan gaat het hele bedrag naar één potje dat je zelf kiest.")
        }
    }
}
