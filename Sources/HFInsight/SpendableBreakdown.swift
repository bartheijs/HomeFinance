import Foundation
import HFCore

/// De opbouw van "nog te besteden deze maand" als korte rekensom, voor onder het grote getal op het dashboard.
/// Rekent niets nieuws: alleen een andere indeling van de onderdelen van `Spendable`, zodat de regels samen
/// precies `Spendable.spendableEndOfMonth` zijn.
///
/// ```
///   Huidig saldo betaalrekening                      € …
/// − Minimaal op de rekening aan het eind van de maand € …
/// − Tijdelijk geleend van spaar                       € …   (alleen als er iets uitstaat)
/// + Komt nog terug                                    € …   (alleen als er iets meetelt)
/// + Nog verwacht deze maand                           € …   (netto; uit te klappen per post)
/// = Nog te besteden deze maand                        € …
/// ```
public struct SpendableBreakdown: Equatable, Sendable {
    public enum LineKind: String, Sendable {
        case balance, buffer, temporaryLoan, returning, expected
    }

    /// Eén regel van de som. `amount` is de bijdrage aan de uitkomst, met teken (de buffer is dus negatief).
    public struct Line: Identifiable, Equatable, Sendable {
        public var id: LineKind { kind }
        public let kind: LineKind
        public let title: String
        public let amount: Money
    }

    /// Eén verwachte post of verrekening onder "Nog verwacht deze maand" (uitgeklapt), met teken.
    public struct ExpectedLine: Identifiable, Equatable, Sendable {
        public let id: String
        public let title: String
        public let amount: Money
        public let isLate: Bool
    }

    /// De regels van de som, in volgorde; de laatste is altijd `expected`.
    public let lines: [Line]
    /// Verwachte inkomsten per post (positief).
    public let expectedIncome: [ExpectedLine]
    /// Verwachte uitgaven per post (negatief), plus een open verrekening met spaar (met teken).
    public let expectedExpenses: [ExpectedLine]
    /// Uitkomst; gelijk aan `Spendable.spendableEndOfMonth`.
    public let total: Money

    /// Netto van "Nog verwacht deze maand": de verwachte posten plus een open verrekening met spaar.
    public var expectedNet: Money { (expectedIncome + expectedExpenses).map(\.amount).sum() }

    public init(_ s: Spendable) {
        var lines = [
            Line(kind: .balance, title: "Huidig saldo betaalrekening", amount: s.balance),
            Line(kind: .buffer, title: "Minimaal op de rekening aan het eind van de maand", amount: -s.antiRood),
        ]
        if !s.tijdelijkAntiRood.isZero {
            lines.append(Line(kind: .temporaryLoan, title: "Tijdelijk geleend van spaar", amount: -s.tijdelijkAntiRood))
        }
        if !s.returningTotal.isZero {
            lines.append(Line(kind: .returning, title: "Komt nog terug", amount: s.returningTotal))
        }
        var income: [ExpectedLine] = []
        var expenses: [ExpectedLine] = []
        for item in s.expectedItems {
            let line = ExpectedLine(id: "post-\(item.id)", title: item.label, amount: item.plan, isLate: item.isLate)
            if item.plan > .zero { income.append(line) } else if item.plan < .zero { expenses.append(line) }
        }
        if !s.pendingSettlement.isZero {
            let line = ExpectedLine(id: "spaar", title: "Nog over te boeken met spaar", amount: s.pendingSettlement, isLate: false)
            if s.pendingSettlement > .zero { income.append(line) } else { expenses.append(line) }
        }
        expectedIncome = income
        expectedExpenses = expenses
        lines.append(Line(kind: .expected, title: "Nog verwacht deze maand",
                          amount: (income + expenses).map(\.amount).sum()))
        self.lines = lines
        total = s.spendableEndOfMonth
    }

    /// Klopt de som: de regels samen zijn de uitkomst.
    public var addsUp: Bool { lines.map(\.amount).sum() == total }
}

extension Dashboard {
    /// Banktransacties op de betaalrekening(en) die nog niet geboekt zijn. Zolang dit meer dan nul is, telt het
    /// grote getal ze nog niet mee.
    public var unbookedCheckingTransactions: Int {
        accounts.filter { $0.kind == .betaal }.map(\.newBankTransactionCount).reduce(0, +)
    }
}
