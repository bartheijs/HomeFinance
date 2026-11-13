# HFHistory — Excel-historie importeren

Eenmalige import van de twee Excel-werkmappen: de begroting (één blad per jaar) en de spaarpotten (blad `RES`).
Hangt alleen af van `HFCore` en GRDB. Leest `.xlsx` zonder code van derden.

## Zo werkt het

1. **Lezen** (`HistoryWorkbook`): maakt van een werkmap gewone Swift-waarden. Schrijft niets.
2. **Controleren**: elk jaar draagt zijn eigen verschillen met de totalen in het blad (`differences`).
   `HistoryImporter.check…` zegt daarnaast wat een import in déze database zou doen.
3. **Importeren** (`HistoryImporter`): één transactie per aanroep, alles of niets.

```swift
import HFHistory

let budget = try HistoryWorkbook.readBudget(url)             // nieuwste jaar eerst
let years = budget.years.filter(\.totalsMatch)

let check = try db.read { try HistoryImporter.checkBudget($0, years: years, accountId: betaalId) }
// check.refused, check.replaced, check.openingChange …

let result = try HistoryImporter.importBudget(years: years, into: db, accountId: betaalId,
                                              confirmOpeningChange: gebruikerIsAkkoord)
```

Lezen en controleren hebben geen database en geen UI nodig. Voor een proefrun op een bestand:

```swift
let budget = try HistoryWorkbook.readBudget(url)
print(budget.summary(today: .today()))                 // per jaar: aantallen, totalen, verschillen, maandsaldi
print(try HistoryWorkbook.readSavings(url2).summary)
```

De samenvattingen bevatten alleen aantallen, bedragen, rijnummers en vaste soortnamen (`HistoryNote.code`,
`HistoryDifference.kind`): geen labels, omschrijvingen, bladnamen of potnamen.

Fouten zijn `XLSXError`, `HistoryReadError` en `HistoryError` (`LocalizedError`, `Equatable`);
`localizedDescription` is een Nederlandse melding.

## XLSXWorkbook — de lezer

`XLSXWorkbook.read(url)` pakt het bestand uit in een tijdelijke map (`/usr/bin/ditto -x -k`), leest
`xl/workbook.xml`, de verwijzingen, `sharedStrings.xml`, `styles.xml` en de bladen met `XMLParser`, en ruimt
de map op. Het bestand zelf wordt niet gewijzigd.

- `sheets: [XLSXSheet]`; `sheet[rij, kolom]` (beide vanaf 1) geeft een `XLSXCell`.
- `XLSXCell.value`: `.empty`, `.text`, `.number`, `.date(Day, serial:)`. `hasFormula` zegt of er een formule
  staat; de waarde is dan de uitkomst die Excel bewaard heeft.
- Datum = een getal met opmaak `numFmtId` 14–22 of een eigen opmaak met `d`, `y` of `mmm`.
  Werkmappen met de 1904-telling worden herkend.
- `Money(excel:)` rondt af op centen en vangt zwevendekommaresten op (-120,10000000000001 → -120,10).

## HistoryWorkbook — lezen

| Functie | Geeft |
|---|---|
| `readBudget(url) -> HistoryBudget` | `years` (nieuwste eerst) en `unread` (bladen die niet gelezen zijn, met reden). |
| `readSavings(url) -> HistorySavings` | De potten uit het blad `RES` met hun mutaties. Fout als het blad ontbreekt. |
| `budget(from:)` / `savings(from:)` | Hetzelfde voor een al gelezen `XLSXWorkbook`. |

### Jaarblad (alles op label, nooit op rijnummer)

- **Bladnaam**: `2019` of `2018 <woord>`. Twee bladen van hetzelfde jaar worden samengevoegd. Jaren vóór
  `firstRegularYear` (2009) en bladen zonder jaartal: niet ingelezen.
- **Rij 1**: twaalf opeenvolgende maandcellen (datums of `jan … dec`) bepalen de maandkolommen. Links daarvan
  is de cel `plan` (of anders `nu`) de plankolom; ontbreekt die, dan is elk plan € 0,00 (waarschuwing).
  Cellen met tekst rechts van de maanden zijn volgkolommen.
- **Hoofdgrid** = rij 2 tot de rij `Totaal`. `IN …`, `UIT …`, `RES …` worden posten (label zonder voorvoegsel).
  `RESERVERINGEN` is de UIT-post met `isReserveTotal`. Van RES-regels alleen label en plan. Andere labels zijn
  hulprijen: overgeslagen en gemeld.
- **Losse regels**: van `IN Various` tot `UIT Various`, en van `UIT Various` tot de eerste rij die begint met
  `Op de rekening`. Eén boeking per gevulde maandcel. Rij zonder omschrijving met bedragen = totaalrij,
  overgeslagen. Dag = de datum in kolom B als die in het jaar valt, anders de 15e (`dayIsKnown = false`).
- **Tags**: een waarde in een volgkolom die (zonder teken) gelijk is aan het bedrag van de rij.
  Een andere waarde wordt genegeerd (bij UIT Various met een waarschuwing).
- **Saldoblok** (na `UIT Various`): `Op de rekening op …` = beginsaldo, `IN`, `UIT`, `Op de rekening` =
  eindsaldo; bedrag in kolom B.

### Controle per jaar

`HistoryYear.differences` is leeg als alles klopt (`totalsMatch`):

- berekende inkomsten (alle positieve bedragen) = `IN` van het blad, berekende uitgaven = `UIT`.
  Klopt dat niet maar klopt het wél per blok (IN-rijen + IN Various, UIT-rijen + UIT Various), dan telt het
  als kloppend, met een waarschuwing;
- beginsaldo + alle bedragen = `Op de rekening`.

### Grens en saldo per maandeinde

| Op `HistoryYear` | Geeft |
|---|---|
| `balanceThrough(month:)` | Beginsaldo + alles t/m die maand (0 = beginsaldo). Het saldo waarop de bank moet aansluiten. |
| `monthEndBalances` | De twaalf maandeindsaldi, of nil zonder beginsaldo. |
| `amounts(through:)`, `entryCount(through:)`, `excludedCount(through:)` | Wat een import t/m die maand meeneemt en wat erbuiten blijft. |
| `amountsAfter(month:)` | Aantal bedragen na die maand en de maanden waarin ze staan. |
| `suggestedThroughMonth(today:)` | nil (hele blad), behalve als het jaar van vandaag bedragen bevat ná de maand van vandaag: dan die maand. |
| `summary(throughMonth:today:)` | De printbare samenvatting van het jaar. |

Een losse regel valt buiten de grens als zijn maandkolom (`month`) óf zijn datum na de grens ligt
(`lastMonth`). De controle tegen de totalen van het blad gaat altijd over het hele jaar.

`chainDifference` = beginsaldo − eindsaldo van het vorige jaar (waarschuwing, blokkeert niet).
Er wordt nooit iets rechtgezet: het teken in het blad blijft staan, afwijkingen komen in `warnings`.

### Blad RES

Rij 1 = potnamen vanaf kolom B. Vanaf rij 2: datum in A (zonder datum: de laatste datum erboven) en per pot
een mutatie. Het lezen stopt bij de eerste rij met formules in meer dan de helft van de potkolommen
(`stoppedAtRow`); de waarden in die rij zijn `statedBalance` per pot. Verschilt de som van de mutaties
daarvan, dan staat dat in `differences`.

## HistoryImporter — schrijven

| Functie | Doet |
|---|---|
| `checkBudget(db, years:, accountId:, throughMonth:) -> HistoryBudgetCheck` | Niets wijzigen; geeft `refused` (jaar → reden), `replaced`, `existingItems`, `openingChange`, `openingProblem`. |
| `importBudget(years:, into:, accountId:, forcedYears:, throughMonth:, confirmOpeningChange:, today:) -> HistoryImportResult` | Importeert de jaren op een betaalrekening. |
| `checkSavings(db, savings:, accountId:) -> HistorySavingsCheck` | `refusal`, `newPots`, `replaces`, `openingChange`. |
| `importSavings(_, into:, accountId:, allowDifferences:, opening:) -> HistoryImportResult` | Importeert de potmutaties op een spaarrekening. |

Beide importfuncties bestaan ook met een `Database` als eerste parameter, voor gebruik binnen een bestaande
transactie.

**Begroting, per jaar:**

- `BudgetYear` wordt gemaakt als hij er niet is; bestaande buffers blijven staan. `closed = true`, behalve
  het jaar van `today`.
- Posten in bladvolgorde (`sortOrder`), frequentie `maand`. Plan van RESERVERINGEN = som van de RES-plannen
  (zijn er geen RES-regels, dan het plan uit het blad).
- Eén handmatige boeking per gevulde maandcel (de 15e, label = post) en één per losse regel (zonder post):
  `reviewed = true`, `note = "Excel-historie"` (`HistoryImporter.note`). Tags worden op naam gezocht
  (hoofdletterongevoelig) en zo nodig aangemaakt.
- **Grens** (`throughMonth: [jaar: maand]`, 0–12): alleen de boekingen t/m die maand gaan mee; posten en plan
  komen altijd mee. Standaard geen grens, ook niet voor het lopende jaar. De grens telt ook mee in
  `openingChange`. Een andere waarde geeft `invalidThroughMonth`.
- **Opnieuw importeren** (ook met een andere grens) verwijdert eerst de historie-boekingen van dat jaar en alle posten van dat jaar.
- **Geweigerd** (`yearHasOtherEntries`): het jaar heeft boekingen op een betaalrekening, of op een post van
  dat jaar, die niet uit de historie komen.
- **Totalen kloppen niet**: geweigerd (`totalsDiffer`) tenzij het jaar in `forcedYears` staat.

**Begindatum van de rekening.** Boekingen mogen niet vóór `openingDate` liggen. Ligt 1 januari van het
vroegste jaar daarvoor, dan wordt `openingDate` die dag en `openingBalance` het beginsaldo van dat jaar.
`HistoryOpeningChange` laat het gevolg zien: `oldBalance` (saldo op de oude begindatum nu),
`balanceAtOldDate` (na de import) en `difference`. Is het verschil niet nul, dan is
`confirmOpeningChange: true` nodig; anders volgt `openingBalanceChanges`.

**Spaarrekening:**

- Potten worden op naam gezocht (hoofdletterongevoelig); ontbrekende potten worden `reservering`.
- Eén handmatige boeking per mutatie met `potId` en `note = "Excel-historie"`. Opnieuw importeren vervangt
  alle historie-boekingen van de rekening.
- **Geweigerd** (`savingsHasOtherEntries`): er staan andere boekingen op of vóór de laatste datum uit het blad
  (bijvoorbeeld "Beginsaldo …" per pot); de hele historie importeren zou dubbel tellen.
- Begindatum: verschuift naar de eerste mutatiedatum. `opening:` bepaalt wat er bij een verschil gebeurt:
  `.stopIfDifferent` (fout), `.acceptNewBalance` (beginsaldo € 0,00; het saldo op de oude begindatum wordt de
  som van de historie) of `.keepOldBalance` (het saldo op de oude begindatum blijft; het verschil wordt het
  beginsaldo en staat niet in een pot).

## Aannames

- De rijen `IN Various` en `UIT Various` zelf bevatten geen boekingen (kopregels). Staan die labels in het
  hoofdgrid, dan worden ze daar overgeslagen.
- Een rij in de losse regels waarvan de omschrijving met "Totaal" begint is een totaalrij.
- Een plan met het verkeerde teken voor zijn richting (bv. positief bij UIT) wordt omgedraaid, met een
  waarschuwing; de app eist IN ≥ 0 en UIT/RES ≤ 0.
- Twee bladen van één jaar: sluit het eindsaldo van het eerste aan op het beginsaldo van het tweede, dan loopt
  het saldo door; anders worden begin- en eindsaldi opgeteld. Dezelfde post in beide bladen wordt één post.
- Bij het opnieuw importeren van een jaar gaan zelf ingestelde eigenschappen van posten (pot, frequentie,
  verwachte dag) verloren; `checkBudget` meldt bestaande posten in `existingItems`.
- In het blad RES is een kolom met de kop Totaal, Som of Saldo geen pot.
- Getest met zelfgemaakte werkmappen met verzonnen inhoud, niet met de echte bestanden. Een developer
  reviewt deze module vóór gebruik met echte gegevens.
