import Foundation
import HFCore

/// De naad tussen wat al in de administratie staat (Excel-historie) en wat uit het bankbestand komt.
public struct ImportSeam: Equatable, Sendable {
    public enum Method: Equatable, Sendable {
        /// Een regel gevonden waarvan het saldo vóór mutatie gelijk is aan het gezochte saldo.
        case foundByBalance
        /// Het gezochte saldo is het saldo ná de laatste regel: alles in het bestand is al verwerkt.
        case alreadyProcessed
        /// Op datum (`skipThrough`): omdat er geen saldo is gezocht, of omdat het niet gevonden is.
        case byDate
        /// Het saldo is niet gevonden en er is geen datum meegegeven: alle regels gaan mee.
        case notFound
        /// De gebruiker heeft zelf regels aan- of uitgezet (`overriding`).
        case manual
    }

    /// Hoe de regels die meegaan zijn bepaald.
    public var method: Method
    /// Het saldo van de administratie waarop gezocht is (`resumeFromBalance`), of nil.
    public var soughtBalance: Money?
    /// De eerste regel die meegaat: regelnummer en dag. nil als er niets meegaat.
    public var lineNumber: Int?
    public var day: Day?
    /// Het saldo vóór die eerste regel; bij `foundByBalance` gelijk aan `soughtBalance`.
    public var balance: Money?
    /// Aantal regels dat niet meegaat.
    public var skippedCount: Int
    /// Regelnummers van alle regels waarvan het saldo vóór mutatie gelijk is aan het gezochte saldo.
    /// Meer dan één: er was twijfel; de vroegste met een sluitende keten erna is gekozen.
    public var seamCandidates: [Int]
    /// Het gezochte saldo is (ook) het saldo ná de laatste regel van het bestand.
    public var closingBalanceMatches: Bool
    /// Saldo vóór de eerste en ná de laatste regel van het bestand.
    public var fileOpeningBalance: Money?
    public var fileClosingBalance: Money?

    /// Er is op saldo gezocht, maar geen aansluitende regel gevonden.
    public var balanceNotFound: Bool {
        soughtBalance != nil && method != .foundByBalance && method != .alreadyProcessed && seamCandidates.isEmpty
            && !closingBalanceMatches
    }
    /// Er waren meer plekken waar het saldo aansluit.
    public var isAmbiguous: Bool { seamCandidates.count + (closingBalanceMatches ? 1 : 0) > 1 }
}

extension ImportPreview {
    /// Bepaalt welke regels al in de administratie staan. Volgorde: eerst op saldo (`resumeFromBalance`),
    /// lukt dat niet dan op datum (`skipThrough`), anders gaat alles mee.
    mutating func applySeam(resumeFromBalance: Money?, skipThrough: Day?) {
        self.skipThrough = skipThrough
        fileOpeningBalance = openingBalance
        guard resumeFromBalance != nil || skipThrough != nil else { return }

        var seam = ImportSeam(method: .notFound, soughtBalance: resumeFromBalance, lineNumber: nil, day: nil,
                              balance: nil, skippedCount: 0, seamCandidates: [], closingBalanceMatches: false,
                              fileOpeningBalance: openingBalance, fileClosingBalance: closingBalance)
        var decided = false

        if let sought = resumeFromBalance {
            let order = chronologicalIndices
            let hasBalances = !rows.isEmpty && rows.allSatisfy { $0.balanceBefore != nil }
            if hasBalances {
                let candidates = order.indices.filter { rows[order[$0]].balanceBefore == sought }
                seam.seamCandidates = candidates.map { rows[order[$0]].lineNumber }
                seam.closingBalanceMatches = closingBalance == sought
                // Een kandidaat telt pas echt als de keten erna nergens breekt.
                let breakLines = Set(chainBreaks.map(\.lineNumber))
                let lastBreak = order.indices.last { breakLines.contains(rows[order[$0]].lineNumber) } ?? -1
                let start: Int? = candidates.first { $0 >= lastBreak }
                    ?? (seam.closingBalanceMatches ? order.count : candidates.first)

                if let start {
                    for position in order.indices { rows[order[position]].isBeforeCutover = position < start }
                    seam.method = start == order.count ? .alreadyProcessed : .foundByBalance
                    decided = true
                    if start == order.count {
                        warnings.append(ImportWarning(kind: .alreadyProcessed, message:
                            "Het saldo \(sought.formatted()) van je administratie is gelijk aan het eindsaldo van dit "
                            + "bestand: alles in dit bestand is al verwerkt."))
                    } else if start > 0 {
                        let first = rows[order[start]]
                        warnings.append(ImportWarning(kind: .beforeCutover, message:
                            "\(start) \(start == 1 ? "regel" : "regels") vóór regel \(first.lineNumber) (\(first.day.dutch)) "
                            + "\(start == 1 ? "is" : "zijn") overgeslagen: het saldo \(sought.formatted()) van je "
                            + "administratie sluit daar aan."))
                    }
                    if seam.isAmbiguous {
                        let n = seam.seamCandidates.count + (seam.closingBalanceMatches ? 1 : 0)
                        warnings.append(ImportWarning(kind: .seamAmbiguous, message:
                            "Het saldo \(sought.formatted()) komt op \(n) plekken in dit bestand voor; de vroegste is "
                            + "gekozen. Controleer of de overgang klopt."))
                    }
                } else {
                    warnings.append(ImportWarning(kind: .seamNotFound, message:
                        "Geen regel in dit bestand sluit aan op het saldo \(sought.formatted()) van je administratie. "
                        + "Het bestand begint met \((openingBalance ?? .zero).formatted()) en eindigt met "
                        + "\((closingBalance ?? .zero).formatted())."))
                }
            } else {
                warnings.append(ImportWarning(kind: .seamNotFound, message:
                    "Dit bestand levert geen saldo per regel; de aansluiting op het saldo \(sought.formatted()) van je "
                    + "administratie kan niet worden gezocht."))
            }
        }

        if !decided, let day = skipThrough {
            for i in rows.indices { rows[i].isBeforeCutover = rows[i].day <= day }
            seam.method = .byDate
            let skipped = cutoverSkippedCount
            if skipped > 0 {
                warnings.append(ImportWarning(kind: .beforeCutover, message:
                    "\(skipped) \(skipped == 1 ? "regel" : "regels") van \(day.dutch) of eerder "
                    + "\(skipped == 1 ? "is" : "zijn") overgeslagen: die periode staat al in je Excel-historie."))
            }
        }

        recomputeAfterSkips()
        fillSeam(&seam)
        self.seam = seam
    }

    /// Geeft een nieuw voorbeeld waarin de gebruiker zelf regels heeft aangezet (`includeLineNumbers`) of
    /// uitgezet (`excludeLineNumbers`). `commit` volgt die keuze. Een regel die al in de database staat
    /// (`isDuplicate`) wordt ook na aanzetten niet opnieuw geïmporteerd.
    public func overriding(includeLineNumbers: Set<Int> = [], excludeLineNumbers: Set<Int> = []) -> ImportPreview {
        var copy = self
        for i in copy.rows.indices {
            let line = copy.rows[i].lineNumber
            if excludeLineNumbers.contains(line) { copy.rows[i].isBeforeCutover = true }
            else if includeLineNumbers.contains(line) { copy.rows[i].isBeforeCutover = false }
        }
        copy.warnings.removeAll { [.beforeCutover, .alreadyProcessed, .manualSelection].contains($0.kind) }
        copy.recomputeAfterSkips()
        var seam = copy.seam ?? ImportSeam(
            method: .manual, soughtBalance: nil, lineNumber: nil, day: nil, balance: nil, skippedCount: 0,
            seamCandidates: [], closingBalanceMatches: false,
            fileOpeningBalance: copy.fileOpeningBalance, fileClosingBalance: copy.closingBalance)
        seam.method = .manual
        copy.fillSeam(&seam)
        copy.seam = seam
        let skipped = copy.cutoverSkippedCount
        if skipped > 0 {
            copy.warnings.append(ImportWarning(kind: .manualSelection, message:
                "\(skipped) \(skipped == 1 ? "regel gaat" : "regels gaan") op jouw keuze niet mee."))
        }
        return copy
    }

    /// Beginsaldo en periode gaan over de regels die meegaan; de keten blijft over het hele bestand gecontroleerd.
    mutating func recomputeAfterSkips() {
        let kept = rowsChronological.filter { !$0.isBeforeCutover }
        guard cutoverSkippedCount > 0 else {
            firstDay = rows.map(\.day).min()
            lastDay = rows.map(\.day).max()
            openingBalance = fileOpeningBalance
            return
        }
        firstDay = kept.map(\.day).min()
        lastDay = kept.map(\.day).max()
        if fileOpeningBalance != nil {
            // Gaat er niets mee, dan is er ook geen verschil tussen begin en eind.
            openingBalance = kept.isEmpty ? closingBalance : kept.first?.balanceBefore
        }
    }

    private func fillSeam(_ seam: inout ImportSeam) {
        let first = rowsChronological.first { !$0.isBeforeCutover }
        seam.lineNumber = first?.lineNumber
        seam.day = first?.day
        seam.balance = first?.balanceBefore ?? (first == nil ? closingBalance : nil)
        seam.skippedCount = cutoverSkippedCount
    }
}
