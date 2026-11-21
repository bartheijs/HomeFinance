import Foundation
import HFCore
import Testing
@testable import HFInsight

/// Eén indeling "zeker / waarschijnlijk / twijfel" voor Nakijken en Transacties (UX-stap D1).
@Suite struct WaitingGroupTests {
    typealias D = WaitingSignals.Distribution

    @Test func savingsTransferIsAlwaysDoubt() {
        #expect(Insight.waitingGroup(WaitingSignals(isSavingsTransfer: true, confidence: .hoog)) == .doubt)
    }

    @Test func distributionIsCertainOnlyWhenSingleExactAndFollowed() {
        let ok = D(isSingle: true, exactAmount: true, followsDistribution: true)
        #expect(Insight.waitingGroup(WaitingSignals(distribution: ok)) == .certain)
        #expect(Insight.waitingGroup(WaitingSignals(distribution: D(isSingle: false, exactAmount: true, followsDistribution: true))) == .doubt)
        #expect(Insight.waitingGroup(WaitingSignals(distribution: D(isSingle: true, exactAmount: false, followsDistribution: true))) == .doubt)
        // Lijkt een losse overboeking (of de gebruiker kiest één potje): twijfel, ook als een regel zeker is.
        #expect(Insight.waitingGroup(WaitingSignals(distribution: D(isSingle: true, exactAmount: false, followsDistribution: false),
                                                    confidence: .hoog)) == .doubt)
    }

    @Test func rulesDecideWithoutDistribution() {
        #expect(Insight.waitingGroup(WaitingSignals(confidence: .hoog)) == .certain)
        #expect(Insight.waitingGroup(WaitingSignals(confidence: .hoog, amountDiffers: true)) == .doubt)
        #expect(Insight.waitingGroup(WaitingSignals(confidence: .hoog, hasWarnings: true)) == .doubt)
        #expect(Insight.waitingGroup(WaitingSignals(confidence: .midden)) == .probable)
        #expect(Insight.waitingGroup(WaitingSignals(confidence: .laag)) == .doubt)
        #expect(Insight.waitingGroup(WaitingSignals(confidence: .geen, isOwnTransfer: true)) == .probable)
    }

    @Test func countsLine() {
        #expect(Insight.waitingCountsLine(toCheck: 3, certain: 4) == "Nog 3 na te kijken · 4 zeker")
        #expect(Insight.waitingCountsLine(toCheck: 0, certain: 2) == "2 zeker · niets na te kijken")
        #expect(Insight.waitingCountsLine(toCheck: 1, certain: 0) == "Nog 1 na te kijken")
    }
}
