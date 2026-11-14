# HomeFinance

Gezinsbegroting voor macOS. Vervangt de Excel-werkmappen voor de betaalrekening (maandoverzicht IN/UIT) en de
spaarrekening (reserverings- en spaarpotten). Alles staat lokaal op je Mac.

## De app starten

Je hebt alleen Xcode nodig (staat al op je Mac). Open Terminal in deze map en typ:

```bash
./scripts/run.sh
```

Dat bouwt de app en opent hem vanuit `dist/HomeFinance.app`. Wil je hem in je map Apps (Launchpad, Spotlight)?

```bash
./scripts/run.sh --install
```

Dat zet de nieuwste versie in `/Applications/HomeFinance.app`. Na elke wijziging in de code doe je dat opnieuw.
De eerste keer duurt het bouwen een paar minuten, daarna seconden.

Bij de eerste start kies je tussen **rondkijken met voorbeelddata** (een verzonnen gezin) en **je eigen
administratie beginnen**. Je kunt later altijd wisselen via Instellingen › Over.

## Zo werk je ermee

1. **Download bij je bank** de transacties als CSV. Je krijgt een zip-bestand met één CSV per rekening.
2. **Sleep het zip-bestand** op het scherm *Importeren en nakijken*. De app controleert of het saldo klopt en
   slaat regels over die er al in staan.
3. **Kijk de voorstellen na.** Zekere voorstellen boek je in één keer; bij twijfel kies je zelf de post. De app
   onthoudt je keuze als regel voor de volgende keer.
4. **Maandgrid** toont je vertrouwde jaaroverzicht. **Dashboard** toont wat er te besteden is.
5. **Afstemmen** (Instellingen › Rekeningen): vul het saldo van je bank in; het verschil moet € 0,00 zijn.

## Begrippen

| Begrip | Betekenis |
|---|---|
| Vaste post | Een regel in je begroting die elke maand, elk kwartaal of elk jaar terugkomt. |
| Divers | Alles wat geen vaste post is: losse inkomsten (IN divers) en uitgaven (UIT divers). |
| Reserveringen | Wat je maandelijks opzijzet voor jaarlijkse of onregelmatige kosten. Eén overboeking naar spaar, verdeeld over potten. |
| Pot | Een deel van het saldo op je spaarrekening met een eigen doel. |
| Anti-rood | Buffer die altijd op de betaalrekening moet blijven staan. |
| Besteedbaar | Saldo betaalrekening − anti-rood − wat je tijdelijk van spaar hebt geleend. Geld met een bestemming staat in potten op de spaarrekening. |
| Tijdelijk geleend van spaar | Geld dat je even naar de betaalrekening haalt en later terugboekt. Je markeert beide overboekingen; de app houdt bij wat er uitstaat. |
| Verrekenen met spaar | Een uitgave die uit een pot hoort te komen, of geld dat binnenkomt en naar een pot moet. Je maakt het saldo in één keer over en vinkt het af. |
| Vaste storting | Een bedrag dat regelmatig naar de spaarrekening gaat, met de verdeling over potten. |
| Spaardoel | Doelbedrag en doeldatum bij een pot; de app rekent uit wat er per maand bij moet. |
| Vooruitblik | Wat het saldo van een pot naar verwachting doet, met de bedragen die je nog verwacht. Telt nergens in mee. |
| Telt mee in | De maand waarin een boeking voor de begroting meetelt, als dat een andere is dan de maand van de datum. |
| Tag | Label om uitgaven te volgen (tanken, uit eten). Telt niet als extra uitgave. |

## Waar staan je gegevens?

- Je administratie: `~/Library/Application Support/HomeFinance/homefinance.sqlite`
- De voorbeelddata: `~/Library/Application Support/HomeFinance/voorbeeld.sqlite`
- Back-ups: in de map die je kiest bij Instellingen › Back-up (bijvoorbeeld in iCloud Drive).

In deze map met broncode staan nooit echte gegevens.

## Voor wie aan de code werkt

| Map | Inhoud |
|---|---|
| `docs/spec/` | Het ontwerp en alle rekenregels. Begin hier. |
| `docs/api/` | Wat elke module kan, met voorbeelden. |
| `Sources/HFCore` | Geldbedragen, datums, tabellen en het databaseschema. |
| `Sources/HFImport` | Bankbestanden lezen (zip, CSV, PDF), saldoketen, dubbelen. |
| `Sources/HFRules` | Regels die voorstellen doen en bijleren. |
| `Sources/HFBudget` | Alles wat gegevens wijzigt: boeken, potten, afstemmen, jaarbeheer. |
| `Sources/HFInsight` | Alles wat gegevens leest: maandgrid, besteedbaar, rapporten. |
| `Sources/HFBackup` | Back-up, herstel en voorbeelddata. |
| `Sources/HomeFinance` | De schermen (SwiftUI). |
| `Tests/` | Geautomatiseerde tests per module. |

```bash
swift test                                   # alle tests
swift run HomeFinance --snapshot /tmp/snap   # elk scherm als afbeelding, met voorbeelddata
open Package.swift                           # het project openen in Xcode
```

Techniek: Swift 6, SwiftUI, Swift Charts, SQLite via [GRDB](https://github.com/groue/GRDB.swift).
Werkafspraken voor AI-agents staan in `CLAUDE.md`.
