import Testing
@testable import HFRules

@Suite struct LabelCleanerTests {
    @Test(arguments: [
        ("  bakkerij   de korenaar ", "Bakkerij de Korenaar"),
        ("BAKKERIJ DE KORENAAR", "Bakkerij de Korenaar"),
        ("STROOMHUIS B.V.", "Stroomhuis"),
        ("Stroomhuis BV", "Stroomhuis"),
        ("Voorbeeld Holding N.V.", "Voorbeeld Holding"),
        ("FIETSENMAKER VOORBEELD VOF", "Fietsenmaker Voorbeeld"),
        ("Voorbeeld Software GmbH", "Voorbeeld Software"),
        ("Installatiebedrijf Voorbeeld, B.V.", "Installatiebedrijf Voorbeeld"),
        // Gemengde hoofdletters blijven staan.
        ("iDrogist Voorbeeld", "iDrogist Voorbeeld"),
        ("Gemeente Utrecht", "Gemeente Utrecht"),
        ("GEMEENTE UTRECHT", "Gemeente Utrecht"),
        // Afkortingen zonder klinker en voorletters.
        ("ZORGKAS VOORBEELD", "Zorgkas Voorbeeld"),
        ("TVZ ZORG", "TVZ Zorg"),
        ("J.P. VOORBEELD", "J.P. Voorbeeld"),
        ("VAN DER VOORBEELD-JANSEN", "Van der Voorbeeld-Jansen"),
        // Pinautomaat-ruis.
        ("BEA, Betaalpas BAKKERIJ DE KORENAAR,PAS123 NR:1A2B3C, 12.11.27/14:03 UTRECHT", "Bakkerij de Korenaar"),
        ("SUPERMARKT VOORBEELD 1234 UTRECHT NLD", "Supermarkt Voorbeeld"),
        ("CCV*TUINCENTRUM VOORBEELD ZWOLLE NLD", "Tuincentrum Voorbeeld"),
        ("SumUp *Koffiebar Voorbeeld", "Koffiebar Voorbeeld"),
        ("Webwinkel Voorbeeld, NL", "Webwinkel Voorbeeld"),
        ("BEA, Apple Pay Boekhandel Voorbeeld Den Haag,PAS012", "Boekhandel Voorbeeld"),
        // Pinnamen met plaats en datum na ">" (6j).
        ("Winkel Voorbeeld >Dorpstad13.11.2026", "Winkel Voorbeeld"),
        ("Winkel Voorbeeld>Dorpstad13.11.2026", "Winkel Voorbeeld"),
        ("WINKEL VOORBEELD > DORPSTAD 13.11.2026", "Winkel Voorbeeld"),
        ("857 A POINT SEAT S>AMSTERDAM11.11.2026", "A Point Seat"),
        ("042 BAKKERIJ VOORBEELD >ZWOLLE02.03.2027", "Bakkerij Voorbeeld"),
        ("Snackbar Voorbeeld >Dorpstad", "Snackbar Voorbeeld"),
        ("857 >AMSTERDAM11.11.2026", "Amsterdam"),
        ("857>11.11.2026", "857"),
        // Zonder ">" blijft een naam zoals hij was, ook met een nummer vooraan.
        ("Winkel Voorbeeld", "Winkel Voorbeeld"),
        ("123 Inkt Voorbeeld", "123 Inkt Voorbeeld"),
        ("1234", "1234"),
        ("Pijl > Boog Voorbeeld", "Pijl > Boog Voorbeeld"),
        // Niets weghalen als er dan niets overblijft.
        ("BV", "BV"),
        ("", ""),
        ("   ", ""),
    ])
    func cleans(raw: String, expected: String) {
        #expect(LabelCleaner.cleanLabel(raw) == expected)
    }

    @Test func counterpartyWinsOverDescription() {
        #expect(LabelCleaner.cleanLabel(counterparty: "STROOMHUIS BV", description: "Termijn maart") == "Stroomhuis")
    }

    @Test func derivesFromDescriptionWhenCounterpartyIsEmpty() {
        #expect(LabelCleaner.cleanLabel(counterparty: " ",
            description: "BEA, Betaalpas SLAGERIJ VOORBEELD,PAS123 NR:9Z8Y7X, 03.03.27/09:15 ZWOLLE") == "Slagerij Voorbeeld")
        #expect(LabelCleaner.cleanLabel(counterparty: "",
            description: "/TRTP/SEPA Incasso/NAME/Sportvereniging Voorbeeld/REMI/Contributie") == "Sportvereniging Voorbeeld")
        #expect(LabelCleaner.cleanLabel(counterparty: "",
            description: "Naam: Tandarts Voorbeeld B.V. Omschrijving: Factuur 12 IBAN: NL00TEST0000000009") == "Tandarts Voorbeeld")
        #expect(LabelCleaner.cleanLabel(counterparty: "", description: "Bedankt voor het lenen") == "Bedankt voor het lenen")
        #expect(LabelCleaner.cleanLabel(counterparty: "", description: "") == "")
    }

    @Test func longDescriptionsAreCutAtAWord() {
        let label = LabelCleaner.cleanLabel(counterparty: "",
            description: "Terugbetaling van het weekendje weg met de hele groep vorige maand")
        #expect(label == "Terugbetaling van het weekendje weg met")
        #expect(label.count <= 40)
    }

    @Test func structuredFlagOnlyForRecognisableDescriptions() {
        #expect(LabelCleaner.derive(fromDescription: "Bedankt voor het lenen").structured == false)
        #expect(LabelCleaner.derive(fromDescription: "BEA, Betaalpas SLAGERIJ VOORBEELD,PAS123").structured)
        // 6j: een pinnaam met ">" is herkenbaar; het trefwoord bevat geen plaats of datum.
        let pin = LabelCleaner.derive(fromDescription: "Winkel Voorbeeld >Dorpstad13.11.2026")
        #expect(pin.structured && pin.text == "Winkel Voorbeeld")
    }

    @Test func normalizer() {
        #expect(TextNormalizer.normalize("  CAFÉ   de  Brúg ") == "cafe de brug")
        #expect(TextNormalizer.normalizeIban(" nl00 test 0000 0000 01 ") == "NL00TEST0000000001")
    }
}
