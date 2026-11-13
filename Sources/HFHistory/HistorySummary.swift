import Foundation
import HFCore

// Compacte, printbare samenvattingen om een proefrun op de echte bestanden te beoordelen.
// Er staan alleen aantallen, bedragen, rijnummers en vaste soortnamen in: geen labels, omschrijvingen,
// bladnamen of potnamen uit de werkmap.

extension HistoryYear {
    /// Samenvatting van het jaar zonder inhoud uit het blad.
    /// - `throughMonth`: toont ook wat een import t/m die maand zou meenemen.
    /// - `today`: meldt bedragen in maanden na de maand van vandaag (alleen voor het jaar van vandaag).
    public func summary(throughMonth: Int? = nil, today: Day? = nil) -> String {
        var lines: [String] = []
        let fixed = items.filter { $0.direction != .RES }.count
        let gridEntries = items.reduce(0) { $0 + $1.monthAmounts.compactMap { $0 }.count }
        func money(_ value: Money?) -> String { value?.formatted() ?? "niet gevonden" }
        func sheetNumber(_ name: String) -> String {
            guard sheetNames.count > 1, let index = sheetNames.firstIndex(of: name) else { return "" }
            return "blad \(index + 1) "
        }

        lines.append("\(year) — \(sheetNames.count == 1 ? "1 blad" : "\(sheetNames.count) bladen") — totalen \(totalsMatch ? "KLOPPEN" : "KLOPPEN NIET")")
        lines.append("  posten: \(fixed) vast + \(items.count - fixed) RES; regels: \(gridEntries) grid + \(various.count) los = \(entryCount) (\(unknownDayCount) los zonder datum)")
        lines.append("  beginsaldo: \(money(openingBalance))")
        lines.append("  IN:   blad \(money(statedIncome)), berekend \(computedIncome.formatted())")
        lines.append("  UIT:  blad \(money(statedExpenses)), berekend \(computedExpenses.formatted())")
        lines.append("  eind: blad \(money(statedClosing)), berekend \(money(computedClosing))")
        for difference in differences {
            let part = difference.part.map { " (blad \($0))" } ?? ""
            let delta = difference.difference.map { $0.formatted(alwaysSign: true) } ?? "n.v.t."
            lines.append("  VERSCHIL \(difference.kind)\(part): berekend \(difference.computed.formatted()), blad \(money(difference.stated)), verschil \(delta)")
        }
        if let chainDifference {
            lines.append("  KETEN: beginsaldo − eindsaldo \(year - 1) = \(chainDifference.formatted(alwaysSign: true))")
        }
        if let balances = monthEndBalances {
            let text = balances.enumerated().map { "\(Day.monthNamesShort[$0.offset]) \($0.element.formatted(symbol: false))" }
            lines.append("  saldo per maandeinde: " + text.joined(separator: " | "))
        }
        if let throughMonth {
            lines.append("  grens t/m maand \(throughMonth): \(entryCount(through: throughMonth)) regels mee, \(excludedCount(through: throughMonth)) buiten de import; saldo na import \(money(balanceThrough(month: throughMonth)))")
        }
        if let today, today.year == year {
            let later = amountsAfter(month: today.month)
            if later.count > 0 {
                lines.append("  NA VANDAAG: \(later.count) bedragen in maand \(later.months.map(String.init).joined(separator: ", ")) (waarschijnlijk verwachtingen)")
            }
        }

        func grouped(_ title: String, _ notes: [HistoryNote]) {
            guard !notes.isEmpty else { return }
            lines.append("  \(title) (\(notes.count)):")
            let codes = Dictionary(grouping: notes, by: \.code)
            for code in codes.keys.sorted() {
                let list = codes[code]!
                let rows = list.compactMap { note in note.row.map { "\(sheetNumber(note.sheet))rij \($0)" } }
                let shown = rows.prefix(12).joined(separator: ", ") + (rows.count > 12 ? ", …" : "")
                lines.append("    \(code): \(list.count)" + (shown.isEmpty ? "" : " (\(shown))"))
            }
        }
        grouped("waarschuwingen", warnings)
        grouped("overgeslagen rijen", skippedRows)
        return lines.joined(separator: "\n")
    }
}

extension HistoryBudget {
    /// Samenvatting van de hele begrotingswerkmap, nieuwste jaar eerst, zonder inhoud uit de bladen.
    public func summary(today: Day? = nil) -> String {
        var parts = years.map { $0.summary(throughMonth: today.flatMap($0.suggestedThroughMonth(today:)), today: today) }
        if !unread.isEmpty {
            var lines = ["niet ingelezen (\(unread.count) bladen):"]
            for sheet in unread {
                lines.append("  \(sheet.year.map(String.init) ?? "blad zonder jaartal"): \(sheet.reason)")
            }
            parts.append(lines.joined(separator: "\n"))
        }
        let matching = years.filter(\.totalsMatch).count
        parts.insert("Begrotingswerkmap: \(years.count) jaren gelezen, \(matching) met kloppende totalen, \(unread.count) bladen niet gelezen", at: 0)
        return parts.joined(separator: "\n\n")
    }
}

extension HistorySavings {
    /// Samenvatting van het blad RES zonder potnamen: de potten staan er op volgnummer (kolomvolgorde) in.
    public var summary: String {
        var lines: [String] = []
        lines.append("Spaarwerkmap, blad RES — saldi \(totalsMatch ? "KLOPPEN" : "KLOPPEN NIET")")
        let period = firstDay.flatMap { first in lastDay.map { "\(first.dutch) t/m \($0.dutch)" } } ?? "geen mutaties"
        lines.append("  potten: \(pots.count); mutaties: \(movementCount); periode: \(period)")
        lines.append("  gestopt bij rij: \(stoppedAtRow.map(String.init) ?? "geen totaalrij gevonden")")
        for (index, pot) in pots.enumerated() {
            let stated = pot.statedBalance?.formatted() ?? "geen"
            let mark = pot.statedBalance.map { $0 == pot.balance ? "klopt" : "VERSCHIL \((pot.balance - $0).formatted(alwaysSign: true))" } ?? "niet gecontroleerd"
            lines.append("  pot \(index + 1): \(pot.movements.count) mutaties, som \(pot.balance.formatted()), blad \(stated) — \(mark)")
        }
        func grouped(_ title: String, _ notes: [HistoryNote]) {
            guard !notes.isEmpty else { return }
            lines.append("  \(title) (\(notes.count)):")
            let codes = Dictionary(grouping: notes, by: \.code)
            for code in codes.keys.sorted() {
                let rows = codes[code]!.compactMap { $0.row.map { "rij \($0)" } }
                let shown = rows.prefix(12).joined(separator: ", ") + (rows.count > 12 ? ", …" : "")
                lines.append("    \(code): \(codes[code]!.count)" + (shown.isEmpty ? "" : " (\(shown))"))
            }
        }
        grouped("waarschuwingen", warnings)
        grouped("overgeslagen rijen", skippedRows)
        lines.append("  andere bladen, niet ingelezen: \(unread.count)")
        return lines.joined(separator: "\n")
    }
}
