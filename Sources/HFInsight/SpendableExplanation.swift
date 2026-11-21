import Foundation
import HFCore

/// De opbouw van "nog te besteden deze maand" in één zin, voor onder het grote getal op het dashboard.
/// Rekent niets nieuws: alleen een andere indeling van de onderdelen van `Spendable`, zodat
/// `balance + incoming − outgoing − keptAside == spendableEndOfMonth`.
public struct SpendableExplanation: Equatable, Sendable {
    /// Saldo van de betaalrekening(en) nu.
    public let balance: Money
    /// Wat er deze maand nog binnenkomt (positief): verwachte inkomsten, voorgeschoten geld dat meetelt en een open
    /// verrekening met spaar in het voordeel van de betaalrekening.
    public let incoming: Money
    /// Wat er deze maand nog afgaat (positief): verwachte uitgaven en een open verrekening naar spaar.
    public let outgoing: Money
    /// Wat je laat staan (positief): anti-rood plus wat tijdelijk van spaar geleend is.
    public let keptAside: Money
    /// De grootste verwachte inkomst (bv. het loon), om in de zin te noemen; nil als er geen verwachte inkomst is.
    public let mainIncomeLabel: String?
    /// De verwachte dag van die inkomst, als die bekend is.
    public let mainIncomeDay: Day?
    /// Uitkomst; gelijk aan `Spendable.spendableEndOfMonth`.
    public let total: Money

    public init(_ s: Spendable) {
        let expectedIn = s.expectedItems.filter { $0.plan > .zero }
        let expectedOut = s.expectedItems.filter { $0.plan < .zero }
        balance = s.balance
        incoming = expectedIn.map(\.plan).sum() + s.returningTotal + (s.pendingSettlement > .zero ? s.pendingSettlement : .zero)
        outgoing = expectedOut.map(\.plan).sum().magnitude + (s.pendingSettlement < .zero ? s.pendingSettlement.magnitude : .zero)
        keptAside = s.antiRood + s.tijdelijkAntiRood
        // Bij gelijke bedragen de eerste in de begrotingsvolgorde.
        let main = expectedIn.reduce(nil as ExpectedItem?) { best, item in
            guard let best else { return item }
            return item.plan > best.plan ? item : best
        }
        mainIncomeLabel = main?.label
        mainIncomeDay = main?.expectedDay.flatMap { Day(year: s.asOf.year, month: s.asOf.month, day: $0) }
        total = s.spendableEndOfMonth
    }

    /// Bijvoorbeeld: "Nu staat er € 3.540,00 op je betaalrekening; er komt nog € 3.195,00 binnen (o.a. Salaris,
    /// verwacht 25 mrt) en gaat nog € 600,00 af. € 500,00 laat je staan als buffer."
    public var sentence: String {
        var text = "Nu staat er \(balance.formatted()) op je betaalrekening; "
        if incoming.isZero {
            text += "er komt deze maand niets meer binnen"
        } else {
            text += "er komt nog \(incoming.formatted()) binnen"
            if let label = mainIncomeLabel {
                var detail = "o.a. \(label)"
                if let day = mainIncomeDay { detail += ", verwacht \(day.day) \(Day.monthNamesShort[day.month - 1])" }
                text += " (\(detail))"
            }
        }
        text += outgoing.isZero ? " en gaat er niets meer af." : " en gaat nog \(outgoing.formatted()) af."
        if !keptAside.isZero { text += " \(keptAside.formatted()) laat je staan als buffer." }
        return text
    }
}

extension Dashboard {
    /// Banktransacties op de betaalrekening(en) die nog niet geboekt zijn. Zolang dit meer dan nul is, telt het
    /// grote getal ze nog niet mee.
    public var unbookedCheckingTransactions: Int {
        accounts.filter { $0.kind == .betaal }.map(\.newBankTransactionCount).reduce(0, +)
    }
}
