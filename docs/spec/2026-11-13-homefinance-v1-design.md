# HomeFinance voor macOS — ontwerp v1

*13 november 2026. Bron: `bron/Family_Budget_App_Specification.md` (geanonimiseerd) en het technische vooronderzoek.*

## Doel

Een native macOS-app voor één gebruiker die twee Excel-werkmappen vervangt: de gezinsbegroting op de
betaalrekening (maandoverzicht IN/UIT sinds 2006) en de administratie van de spaarrekening (reserveringspotten
en spaarpotten). Start op 1-1-2027. De financiële logica van de Excel blijft gelijk; het typewerk verdwijnt.

**Klaar is:** een maand bijhouden kost alleen nog een CSV importeren en nakijken; het berekende saldo sluit op
€ 0,00 met de bank; besteedbaar klopt met de Excel-formule; elke pot heeft een saldo.

## Besluiten

| Onderwerp | Besluit |
|---|---|
| Techniek | Swift 6, SwiftUI, SQLite via GRDB 7, Swift Charts. Eén SwiftPM-package, geen `.xcodeproj`. |
| Opslag | `~/Library/Application Support/HomeFinance/homefinance.sqlite`. Nooit in een cloudmap. |
| Geld | `Money` in hele centen. Uitgaven negatief, inkomsten positief. Nooit `Double`. |
| Datums | `Day` (jaar-maand-dag, zonder tijdzone), in de database als `yyyy-MM-dd`. |
| Rekeningen | Meerdere: betaalrekening(en) en spaarrekening(en). Elke rekening heeft een eigen CSV-import. |
| Import | Bank-CSV per rekening, met controle van de saldoketen en herkenning van dubbelen. |
| Categorisatie | Regels, die bijleren van elke correctie. Geen AI in v1. |
| Login | Geen. De Mac is de beveiliging. |
| Taal | Interface Nederlands. Code, commentaar in code mag Nederlands; identifiers Engels. |
| Later | Webdashboard (alleen lezen), Excel-historie 2006–2026, export naar Excel/PDF, AI-suggesties. |
| Privacy | Geen echte gegevens in de repo, tests of prompts. Testdata is verzonnen. |

## Modules

| Target | Taak | Hangt af van |
|---|---|---|
| `HFCore` | `Money`, `Day`, records, schema en migraties (`AppDatabase`) | GRDB |
| `HFImport` | CSV lezen per bankprofiel, saldoketen, dubbelen, import naar `bankTransaction` | HFCore |
| `HFRules` | Regels toepassen op banktransacties, voorstellen met zekerheid, leren van correcties | HFCore |
| `HFBudget` | Schrijven: boeken, splitsen, potten, overboekingen, afstemming, jaar en posten beheren | HFCore |
| `HFInsight` | Lezen: maandgrid, status vaste posten, saldo, besteedbaar, potsaldi, rapportcijfers, zoeken | HFCore |
| `HFBackup` | Back-up en herstel van de database, voorbeelddata | HFCore |
| `HomeFinance` | De SwiftUI-app. Geen rekenlogica in views. | alles |

Modules kennen elkaar niet onderling (`HFInsight` leest alleen en rekent zelf met SQL); alleen de app verbindt ze. Elke module beschrijft zijn publieke API in
`docs/api/<Module>.md`.

## Datamodel

Zie `Sources/HFCore/Records.swift` (records met uitleg) en `Schema.swift` (tabellen). Kern:

- **Account**: betaal of spaar, met beginsaldo en begindatum.
- **BudgetYear**: jaar, `antiRood`, `closed`.
- **BudgetItem**: vaste post in één jaar (rij in het grid): label, richting IN/UIT/RES, planbedrag met teken,
  frequentie, verwachte maanden en dag. Eén post per jaar is `isReserveTotal` (de regel RESERVERINGEN).
- **Pot**: deel van het saldo van een spaarrekening; soort reservering of spaar; maandbedrag.
- **BankTransaction**: regel van de bank, onveranderlijk. Status nieuw, verwerkt of overgeslagen.
- **Entry** (boeking): bedrag op een rekening, toegewezen aan post of pot. Eén of meer per banktransactie
  (splitsen); zonder banktransactie = handinvoer. `reviewed = false` betekent "nog nakijken".
- **Tag**: trackingcategorie (tanken, uit eten), n-op-m met Entry.
- **Rule**, **Reconciliation**, **SavingsTransfer**, **ImportBatch**, **Setting**.

## Rekenregels

### Betaalrekening en maandgrid
- Een boeking op een betaalrekening met `budgetItemId` hoort bij die vaste post; zonder is het **divers**:
  IN divers als het bedrag positief is, UIT divers als het negatief is.
- Maand en jaar van een boeking volgen uit `day` (de datum van de transactie, niet van de import).
- **Grid**: rijen = vaste posten van het jaar op `sortOrder`; kolommen = plan, jan–dec. Celwaarde = som van de
  boekingen van die post in die maand. Een cel kan meer boekingen bevatten.
- **Plan van RESERVERINGEN** = som van het plan van alle RES-regels van het jaar. RES-regels zelf krijgen geen
  boekingen op de betaalrekening; ze tonen alleen de opbouw.
- **Totaalrijen per maand**: vaste posten (zonder RES-regels), IN divers, UIT divers, netto divers, resultaat.
- **Ruimte t.o.v. maandbudget** = (som plan van de posten die deze maand verwacht worden, zonder RES-regels)
  + IN divers + UIT divers. Positief: binnen budget. (De spec is hier niet eenduidig; dit is de gekozen uitleg.)
- **Celstatus**: `gelijk` (som = plan), `afwijkend` (≠ plan), `nietVerwacht` (post komt deze maand niet voor of
  de maand ligt in de toekomst), `open` (verwacht, nog niet geboekt, nog niet te laat), `teLaat` (verwacht, niet
  geboekt en de verwachte dag is voorbij of de maand is voorbij).
- Kwartaal- en jaarposten: `planAmount` is het bedrag per keer; `expectedMonths` zegt in welke maanden.

### Saldo en afstemming
- Saldo van een rekening op dag D = beginsaldo + som van de boekingen t/m D.
- Afstemmen: de gebruiker voert het werkelijke banksaldo in; verschil = berekend − werkelijk; moet € 0,00 zijn.
  Elke controle wordt vastgelegd.
- Een banktransactie is `verwerkt` als de som van zijn boekingen gelijk is aan zijn bedrag.

### Besteedbaar
- **Besteedbaar** = saldo betaalrekening − `antiRood` − tijdelijk geleend van spaar.
- **Anti-rood** is een vast bedrag per jaar (Instellingen).
- **Tijdelijk geleend van spaar** (voorheen "tijdelijk anti-rood") is geen instelling maar volgt uit de
  transacties: een boeking op de betaalrekening kan de markering `temporaryLoan` krijgen. Lenen is een
  bijschrijving (+), terugboeken een afschrijving (−); het uitstaande bedrag is de som van alle gemarkeerde
  boekingen t/m de peildag, met nul als ondergrens. Het Dashboard meldt wat er nog uitstaat.
- Op de betaalrekening staat geen geld met een bestemming. Alles wat gereserveerd is, staat in een pot op de
  spaarrekening (besluit 13-11-2026). De Excel hield één reservering op de betaalrekening aan: een jaarlijkse
  schenking waaruit maandelijks rente op een privélening wordt betaald. In de app is dat een pot: de schenking
  gaat één keer per jaar naar die pot, de maandelijkse rentebetaling krijgt via een regel "vergoeden uit spaar"
  uit die pot en loopt mee in de maandelijkse spaaroverboeking.
- De kolommen `budgetYear.reserveBase`, `budgetYear.tijdelijkAntiRood` en `budgetItem.reducesReserve` bestaan
  nog in het schema maar worden niet meer gebruikt.
- **Besteedbaar eind van de maand** (simulatie) = besteedbaar + som van het plan van alle vaste posten die deze
  maand verwacht worden en nog geen boeking hebben (RESERVERINGEN telt mee, RES-regels niet).

### Potten en spaarrekening
- Saldo van een pot = som van de boekingen op de spaarrekening met dat `potId`.
- Saldo spaarrekening = beginsaldo + som boekingen; **niet toegewezen** = saldo − som van alle potten.
- **Verdelen**: een storting die gelijk is aan de som van de maandbedragen van de reserveringspotten wordt
  gesplitst in één boeking per pot (elk zijn `monthlyAmount`).
- **Overboeking tussen eigen rekeningen**: twee banktransacties met tegengesteld bedrag, waarvan de
  tegenrekening de andere eigen rekening is, binnen 3 dagen. De boekingen worden aan elkaar gekoppeld
  (`counterEntryId`). Ze tellen op elke rekening gewoon mee in het saldo.

### Spaaroverboekingen (vergoeden uit spaar)
- Een uitgave op de betaalrekening kan `reimburse` krijgen, met optioneel de pot die betaalt.
- Openstaand = alle `reimburse`-boekingen zonder `savingsTransferId`; het totaal is het over te boeken bedrag.
- "Overboeking maken" legt een `SavingsTransfer` vast met die boekingen; "gedaan" markeert hem.
- Voorschieten en terugkrijgen blijven twee losse boekingen (één UIT, één IN).

### Import (uit de werkwijze van de Excel)
1. Bestand lezen; elke regel wordt een `BankTransaction` of een gemelde fout. Geen regel verdwijnt stil.
2. **Saldoketen**: waar de bank "saldo vóór mutatie" levert, moet saldo-vóór + bedrag gelijk zijn aan het
   saldo-vóór van de volgende regel. Het eindsaldo van het bestand wordt getoond en bewaard.
3. **Dubbelen**: vingerafdruk per regel; een regel die al bestaat wordt overgeslagen en geteld.
4. Alles in één databasetransactie: bij een fout wordt niets geïmporteerd.
5. Regels doen per transactie een voorstel met zekerheid. Twijfelgevallen eerst, daarna boeken.
6. Nieuwe boekingen krijgen `reviewed = false` tot de gebruiker ze heeft nagekeken.
7. Controle achteraf: elke geïmporteerde regel is verwerkt of overgeslagen; het berekende saldo is gelijk aan
   het eindsaldo van het bestand.

### Regels
Zekerheid en volgorde:
1. Tegenpartij (naam of IBAN) **en** bedrag kloppen → `hoog`.
2. Tegenpartij klopt, regel heeft geen bedrag of het bedrag wijkt af → `midden`.
3. Trefwoord in de omschrijving → `midden`.
4. Alleen bedrag → `laag`.
5. Geen regel → `geen`.

Binnen dezelfde zekerheid wint de laagste `priority`, daarna de meest specifieke regel. Een correctie van de
gebruiker maakt een geleerde regel of past de bestaande geleerde regel voor die tegenpartij aan. Een regel met
alleen een bedrag wordt nooit automatisch geleerd.

## Schermen

Zijbalk: Dashboard · Importeren en nakijken · Maandgrid · Transacties · Potten en sparen · Spaaroverboekingen ·
Rapporten · Regels · Instellingen (jaar en posten, rekeningen, tags, back-up).

## Testen

Swift Testing, per module een eigen testtarget, met een database in het geheugen (`AppDatabase.inMemory()`).
Rekenregels krijgen tests met uitgewerkte, verzonnen voorbeelden.

## Aannames (te bevestigen door Bart)

- Het CSV-formaat van de bank is het bekende formaat zonder kopregel met 19 kolommen, waaronder "saldo vóór
  mutatie". Er is nog geen voorbeeldbestand; de kolomindeling is daarom instelbaar.
- De uitleg van "t.o.v. maandbudget" hierboven.
- De app draait alleen op de eigen Mac, zonder App Store en zonder sandbox.
