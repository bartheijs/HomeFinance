import Foundation
import HFCore

/// Tekst vergelijkbaar maken: hoofdletters, accenten en dubbele spaties tellen niet mee.
public enum TextNormalizer {
    /// Kleine letters, zonder accenten, witruimte samengevoegd tot één spatie en getrimd.
    public static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    /// IBAN zonder spaties, in hoofdletters.
    public static func normalizeIban(_ iban: String) -> String {
        String(iban.filter { !$0.isWhitespace }).uppercased()
    }

    /// Witruimte samenvoegen en trimmen, zonder de letters te veranderen.
    static func collapse(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

/// Maakt van ruwe banktekst een leesbare naam voor een boeking.
/// Bewust voorzichtig: bij twijfel blijft de tekst staan.
public enum LabelCleaner {
    /// Langste naam die uit een omschrijving wordt afgeleid.
    static let maxDerivedLength = 40

    /// Schoont één ruwe naam op: spaties, pinautomaat-ruis, land/plaats achteraan (alleen bij
    /// pinbetalingen), rechtsvormen (B.V., N.V., VOF …) en hoofdletters (niet ALLES IN KAPITALEN).
    public static func cleanLabel(_ raw: String) -> String {
        analyze(raw).text
    }

    /// Naam voor een boeking: de opgeschoonde tegenpartij, of — als die leeg is — een naam die uit de
    /// omschrijving is afgeleid. Geeft "" als er niets bruikbaars is.
    public static func cleanLabel(counterparty: String, description: String) -> String {
        let name = cleanLabel(counterparty)
        if !name.isEmpty { return name }
        return derive(fromDescription: description).text
    }

    /// Voorgestelde omschrijving voor een nieuwe boeking (6b). Bij een overboeking met een korte, eigen tekst
    /// (bijvoorbeeld "Zakgeld") is dat die tekst; in alle andere gevallen hetzelfde als
    /// `cleanLabel(counterparty:description:)`. Een omschrijving uit een regel (`Rule.entryLabel`) gaat hier
    /// altijd voor; dat regelt `RuleMatcher.suggest`.
    public static func suggestedLabel(counterparty: String, description: String, transactionCode: String = "") -> String {
        let name = cleanLabel(counterparty)
        if !name.isEmpty, let own = personalNote(description, transactionCode: transactionCode, counterparty: name) {
            return own
        }
        return cleanLabel(counterparty: counterparty, description: description)
    }

    /// `suggestedLabel(counterparty:description:transactionCode:)` voor een banktransactie.
    public static func suggestedLabel(for tx: BankTransaction) -> String {
        suggestedLabel(counterparty: tx.counterpartyName, description: tx.descriptionText,
                       transactionCode: tx.transactionCode)
    }

    /// Langste eigen tekst die als omschrijving wordt voorgesteld.
    static let maxPersonalLength = 30
    /// Meeste woorden in een eigen tekst.
    static let maxPersonalWords = 4

    /// Transactiecodes van betalingen die nooit een eigen tekst hebben (pin, geldautomaat, incasso, iDEAL,
    /// acceptgiro, kosten, rente). Codes van overboekingen (bv. OVB, IOB, POV) of een onbekende code laten
    /// de keuze aan de tekst zelf.
    static let nonPersonalCodes: Set<String> = [
        "BEA", "GEA", "PIN", "INC", "ACC", "IDB", "IMB", "KST", "KTN", "RNT", "PRV", "PRM", "STO", "COR", "EFF",
        "BA", "BC", "GA", "GB", "EI", "ID", "MA", "KH", "IC", "GM",
    ]

    /// Woorden die op een zakelijke betaling wijzen; dan is de tegenpartij duidelijker dan de tekst.
    private static let businessWords: Set<String> = [
        "factuur", "factuurnummer", "fact", "nota", "termijn", "klantnummer", "klantnr", "debiteurnummer",
        "contract", "contractnummer", "polis", "polisnummer", "order", "ordernummer", "bestelling", "kenmerk",
        "referentie", "ref", "betalingskenmerk", "betaling", "abonnement", "incasso", "machtiging", "contributie",
        "premie", "dossier", "dossiernummer", "aanslag", "vordering", "transactie", "nr", "no",
    ]

    /// De omschrijving zelf, als het een korte, menselijke tekst is; anders nil.
    static func personalNote(_ description: String, transactionCode: String, counterparty: String) -> String? {
        let code = transactionCode.trimmingCharacters(in: .whitespaces).uppercased()
        if nonPersonalCodes.contains(code) { return nil }
        let text = TextNormalizer.collapse(description).trimmingCharacters(in: CharacterSet(charactersIn: " ,;.-"))
        guard !text.isEmpty, text.count <= maxPersonalLength else { return nil }
        let words = text.split(separator: " ")
        guard words.count <= maxPersonalWords else { return nil }
        // Gestructureerde tekst: velden, scheidingstekens, links.
        if text.range(of: #"[/:*#@=|\\]|https?|www\."#, options: [.regularExpression, .caseInsensitive]) != nil {
            return nil
        }
        // Kenmerken: vijf of meer cijfers achter elkaar, of meer cijfers dan letters.
        if text.range(of: #"\d{5,}"#, options: .regularExpression) != nil { return nil }
        let letters = text.filter(\.isLetter).count, digits = text.filter(\.isNumber).count
        guard letters >= 3, digits <= letters / 2 else { return nil }
        // Voorvoegsels van de bank of de betaalverwerker (pin, iDEAL, SEPA).
        if text.range(of: #"^(IDEAL|SEPA|EUROPESE INCASSO|INCASSO|BETAALAUTOMAAT|GELDAUTOMAAT|BEA|GEA)\b"#,
                      options: [.regularExpression, .caseInsensitive]) != nil { return nil }
        let normalized = TextNormalizer.normalize(text)
        if normalized.split(separator: " ").contains(where: { businessWords.contains(String($0).filter(\.isLetter)) }) {
            return nil
        }
        // Zelfde als de tegenpartij (of een deel daarvan): dan liever de opgeschoonde naam.
        let party = TextNormalizer.normalize(counterparty)
        if party.contains(normalized) || normalized.contains(party) { return nil }
        let result = analyze(text)
        guard !result.terminal, !result.text.isEmpty else { return nil }
        return result.text
    }

    // MARK: Intern

    /// Naam uit een omschrijving. `structured` is true als de naam uit een herkenbaar veld kwam
    /// (pinbetaling, "/NAME/…/", "Naam: …"); alleen dan is hij bruikbaar als trefwoord voor een regel.
    static func derive(fromDescription description: String) -> (text: String, structured: Bool) {
        let d = TextNormalizer.collapse(description)
        guard !d.isEmpty else { return ("", false) }
        var source = d
        var structured = false
        if let r = d.range(of: #"(?<=/NAME/)[^/]+"#, options: [.regularExpression, .caseInsensitive]) {
            source = String(d[r]); structured = true
        } else if let r = d.range(
            of: #"(?<=\bNaam:)\s*.+?(?=\s+(Omschrijving|IBAN|Kenmerk|Machtiging|Incassant|BIC)\s*:|$)"#,
            options: [.regularExpression, .caseInsensitive]) {
            source = String(d[r]); structured = true
        }
        let result = analyze(source)
        return (truncate(result.text), structured || result.terminal)
    }

    private static let cities = [
        "amsterdam", "rotterdam", "den haag", "'s-gravenhage", "s-gravenhage", "utrecht", "eindhoven",
        "groningen", "tilburg", "almere", "breda", "nijmegen", "apeldoorn", "haarlem", "arnhem", "enschede",
        "amersfoort", "zaandam", "zwolle", "leiden", "maastricht", "dordrecht", "zoetermeer", "deventer",
        "delft", "alkmaar", "leeuwarden", "hilversum", "amstelveen", "venlo", "den bosch", "'s-hertogenbosch",
        "s-hertogenbosch", "emmen", "ede", "gouda", "assen", "lelystad", "roermond", "middelburg",
    ]

    private static let smallWords: Set<String> = [
        "de", "het", "een", "van", "der", "den", "en", "voor", "op", "in", "'t", "te", "ter", "ten", "aan", "bij",
    ]

    static func analyze(_ raw: String) -> (text: String, terminal: Bool) {
        var s = TextNormalizer.collapse(raw)
        guard !s.isEmpty else { return ("", false) }
        var terminal = false
        let ci: String.CompareOptions = [.regularExpression, .caseInsensitive]

        // 1. Voorvoegsels van de bank of de betaalverwerker.
        var changed = true
        while changed {
            changed = false
            if let r = s.range(of: #"^(BEA|GEA|BETAALAUTOMAAT|GELDAUTOMAAT|PINBETALING|BETAALPAS|APPLE PAY|GOOGLE PAY|CONTACTLOOS)\b\s*[,:]?\s*"#, options: ci) {
                s.removeSubrange(r); terminal = true; changed = true
            } else if let r = s.range(of: #"^(CCV|SUMUP|ZETTLE|IZ|SQ)\s*\*\s*"#, options: ci) {
                s.removeSubrange(r); terminal = true; changed = true
            } else if let r = s.range(of: #"^(IDEAL|SEPA INCASSO( ALGEMEEN DOORLOPEND)?|SEPA OVERBOEKING)\b\s*[,:]?\s*"#, options: ci),
                      r.upperBound < s.endIndex {
                s.removeSubrange(r); changed = true
            }
        }

        // 1b. Pinnaam met plaats en datum na ">" (6j): "Winkel Plaats >Plaats13.11.2026",
        // "857 A POINT SEAT S>AMSTERDAM11.11.2026". Alleen als na ">" niets anders staat dan een plaats en/of
        // een datum, en de plaats direct aan ">" vastzit of er een datum staat ("Pijl > Boog" blijft staan).
        // Het deel ervoor is vaak afgekapt; een losse letter achteraan ("S") is dan een restje.
        if let r = s.range(of: #"\s*>\s*([\p{L}'.\- ]*?)\s*(\d{1,2}[.\-/]\d{1,2}[.\-/]\d{2,4})?\s*$"#,
                           options: .regularExpression),
           r.lowerBound > s.startIndex,
           case let tail = String(s[r]).drop(while: { $0 != ">" }).dropFirst(),
           tail.contains(where: \.isNumber) || tail.first.map({ !$0.isWhitespace }) == true {
            let place = TextNormalizer.collapse(String(tail.prefix(while: { !$0.isNumber })))
            var name = trimPunctuation(String(s[..<r.lowerBound]))
            if let l = name.range(of: #"\s+\p{L}$"#, options: .regularExpression),
               name[..<l.lowerBound].split(separator: " ").count >= 2 {
                name.removeSubrange(l)
            }
            // Alleen een nummer vóór ">": dan is de plaats de zinnigste naam.
            if !name.contains(where: \.isLetter), !place.isEmpty { name = place }
            if !name.isEmpty { s = name; terminal = true }
        }

        // 2. Alles vanaf het eerste automaatkenmerk (pasnummer, terminal, datum met tijd) vervalt.
        let marker = #"[,\s]*(\bPAS\s?\d{3}\b|\bNR:\s*\S+|\bTERM(INAL)?:|\bTRANSACTIE:|\bPASVOLGNR|\bKAART:|\b\d{2}[.\-]\d{2}[.\-]\d{2,4}[/ ]\d{2}[:.]\d{2}).*$"#
        if let r = s.range(of: marker, options: ci), r.lowerBound > s.startIndex {
            s.removeSubrange(r); terminal = true
        }

        // 3. Landcode achteraan (alleen in hoofdletters; twee letters alleen na een komma).
        if let r = s.range(of: #"\s*,?\s+(NLD|BEL|DEU|FRA|GBR|ESP|ITA|LUX|USA)$"#, options: .regularExpression),
           r.lowerBound > s.startIndex {
            s.removeSubrange(r); terminal = true
        } else if let r = s.range(of: #"\s*,\s*(NL|BE|DE|FR|GB|LU)$"#, options: .regularExpression),
                  r.lowerBound > s.startIndex {
            s.removeSubrange(r)
        }
        s = trimPunctuation(s)

        // 4. Alleen bij pinbetalingen: plaatsnaam en filiaalnummer achteraan.
        if terminal {
            let lower = s.lowercased()
            for city in cities where lower.hasSuffix(city) {
                let cut = s.index(s.endIndex, offsetBy: -city.count)
                guard cut > s.startIndex, " ,".contains(s[s.index(before: cut)]) else { continue }
                let rest = trimPunctuation(String(s[..<cut]))
                if !rest.isEmpty { s = rest }
                break
            }
            if let r = s.range(of: #"\s+\d{3,}$"#, options: .regularExpression), r.lowerBound > s.startIndex {
                s.removeSubrange(r)
            }
            // Los filiaalnummer vooraan (6j), alleen als er daarna nog letters staan.
            if let r = s.range(of: #"^\d{2,}\s+"#, options: .regularExpression),
               s[r.upperBound...].contains(where: \.isLetter) {
                s.removeSubrange(r)
            }
        }

        // 5. Rechtsvormen achteraan.
        while let r = s.range(of: #"[,\s]+(B\.?V\.?|N\.?V\.?|V\.?O\.?F\.?|C\.?V\.?|GMBH|LTD\.?|INC\.?|LLC)$"#, options: ci),
              r.lowerBound > s.startIndex {
            s.removeSubrange(r)
        }
        s = trimPunctuation(s)

        // 6. Hoofdletters.
        return (capitalize(s), terminal)
    }

    private static func trimPunctuation(_ s: String) -> String {
        s.trimmingCharacters(in: CharacterSet(charactersIn: " ,;:-*/"))
    }

    /// Alleen tekst die helemaal in hoofdletters of helemaal in kleine letters staat wordt aangepast.
    private static func capitalize(_ s: String) -> String {
        let letters = s.filter(\.isLetter)
        guard !letters.isEmpty else { return s }
        let allUpper = letters.allSatisfy(\.isUppercase)
        let allLower = letters.allSatisfy(\.isLowercase)
        guard allUpper || allLower else { return s }
        let words = s.split(separator: " ").map(String.init)
        return words.enumerated().map { index, word in
            word.split(separator: "-", omittingEmptySubsequences: false)
                .map { capitalizeWord(String($0), first: index == 0, wasUpper: allUpper) }
                .joined(separator: "-")
        }.joined(separator: " ")
    }

    private static func capitalizeWord(_ word: String, first: Bool, wasUpper: Bool) -> String {
        if word.contains(where: \.isNumber) { return word }
        let lower = word.lowercased()
        if !first && smallWords.contains(lower) { return lower }
        // Voorletters ("J.P.") blijven hoofdletters.
        if word.contains("."), word.split(separator: ".").allSatisfy({ $0.count <= 2 }) { return word.uppercased() }
        // Afkortingen zonder klinker ("KPN") blijven staan zoals ze waren.
        let folded = lower.folding(options: .diacriticInsensitive, locale: nil)
        let wordLetters = folded.filter(\.isLetter)
        if wasUpper, (2...5).contains(wordLetters.count), !wordLetters.contains(where: { "aeiouy".contains($0) }) {
            return word
        }
        guard let i = lower.firstIndex(where: \.isLetter) else { return word }
        return lower[..<i] + lower[i...].prefix(1).uppercased() + lower[lower.index(after: i)...]
    }

    private static func truncate(_ s: String) -> String {
        guard s.count > maxDerivedLength else { return s }
        var words: [Substring] = []
        var length = 0
        for w in s.split(separator: " ") {
            if length + w.count + (words.isEmpty ? 0 : 1) > maxDerivedLength { break }
            length += w.count + (words.isEmpty ? 0 : 1)
            words.append(w)
        }
        return words.isEmpty ? String(s.prefix(maxDerivedLength)) : words.joined(separator: " ")
    }
}
