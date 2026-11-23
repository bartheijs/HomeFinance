# HomeFinance voor macOS — ontwerp v1

*13 november 2026, bijgewerkt op 23 november 2026 (stand van `main` na de UX-ronde, de kwartaalinkomsten en de
vooruitblik met eerdere uitgaven). Bron: `bron/Family_Budget_App_Specification.md` (geanonimiseerd) en het
technische vooronderzoek. Wat per ronde gebouwd is en wat nog openstaat: `docs/voortgang.md`.*

## Doel

Een native macOS-app voor één gebruiker die twee Excel-werkmappen vervangt: de gezinsbegroting op de
betaalrekening (maandoverzicht IN/UIT sinds 2006) en de administratie van de spaarrekening (reserveringspotten
en spaarpotten, in de app **potjes**). De financiële logica van de Excel blijft gelijk; het typewerk verdwijnt.

**Start:** op 8 november 2026 met alleen beginstanden (saldo per rekening, beginbedrag per potje), zonder
historie. De gebruiker richt zelf in en draait schaduw in zijn Excel. De Excel-historie importeren staat in de
wacht (zie `docs/voortgang.md`).

**Klaar is:** een maand bijhouden kost alleen nog een CSV importeren en nakijken; het berekende saldo sluit op
€ 0,00 met de bank; "nog te besteden deze maand" klopt met de Excel-formule; elk potje heeft een saldo.

## Besluiten

| Onderwerp | Besluit |
|---|---|
| Techniek | Swift 6, SwiftUI, SQLite via GRDB 7, Swift Charts. Eén SwiftPM-package, geen `.xcodeproj`. |
| Opslag | `~/Library/Application Support/HomeFinance/homefinance.sqlite`. Nooit in een cloudmap. |
| Geld | `Money` in hele centen. Uitgaven negatief, inkomsten positief. Nooit `Double`. |
| Datums | `Day` (jaar-maand-dag, zonder tijdzone), in de database als `yyyy-MM-dd`. |
| Rekeningen | Meerdere: betaalrekening(en) en spaarrekening(en). Alle potjes staan op één spaarrekening. |
| Import | De zip van de bank (één CSV per rekening, 19 kolommen zonder kop; bevestigd met echte bestanden), ook los CSV of PDF. Saldoketen, dubbelen, en bij de eerste import aansluiting op het beginsaldo. |
| Categorisatie | Regels die de gebruiker zelf maakt of bijwerkt, ook vanuit Nakijken en Transacties ("Voortaan zo indelen"). Geen AI in v1. |
| Login | Geen. De Mac is de beveiliging. |
| Taal | Interface Nederlands. Code, commentaar in code mag Nederlands; identifiers Engels. Identifiers, databasekolommen en de sleutels van de kerncijfers houden hun oude naam (zie Begrippen). |
| Telefoon | Geen hosting: de app schrijft een pagina (HTML en PDF) naar een cloudmap. De HTML heeft alleen een klein ingebouwd script voor de peildatum van de spaarpot (6o); zonder script werkt de pagina ook. |
| Back-up | Het databasebestand naar een map naar keuze (iCloud Drive), optioneel een tweede map. Een export naar Excel is een leesbare kopie, geen back-up. |
| Later | Excel-historie 2006–2026 (gebouwd, in de wacht), PDF-rapporten, AI-suggesties. |
| Privacy | Geen echte gegevens in de repo, tests of prompts. Testdata en voorbeelddata zijn verzonnen. |

## Begrippen

Sinds de UX-ronde (21–22 november 2026) heten een aantal begrippen in de interface anders. De oude naam staat
tussen haakjes; in de code, de database en de kerncijfers staat vaak nog de oude naam (`antiRood`,
`tijdelijkAntiRood`, `Distribution`, `Tag.settles`, `countsInSpendable`, `besteedbaarNu`, `verrekeningen.*`).
De volledige lijst oud → nieuw: `docs/ux/begrippen-voorstel.md`, secties "Doorgevoerd".

| Begrip | Uitleg |
|---|---|
| Post (vaste post) | Een regel in de begroting van één jaar met het bedrag dat je per maand, kwartaal of jaar verwacht. |
| Overig (was: divers) | Boekingen op de betaalrekening die bij geen enkele post horen: IN overig en UIT overig. |
| RESERVERINGEN | De ene post per jaar met het maandbedrag dat naar de potjes op spaar gaat. |
| RES-regels (oude opbouw) | Regels onder RESERVERINGEN uit de Excel; ze bepalen nog het plan van RESERVERINGEN in de berekeningen (zie Rekenregels). |
| Potje (was: pot) | Een deel van het saldo van de spaarrekening met een eigen bestemming; soort reservering of spaar. |
| Automatisch sparen (was: vaste storting) | Een vaste overboeking per maand van betaal naar spaar, verdeeld over potjes; één losse heet "vaste overboeking". |
| Telt in je begroting als (was: hoort bij post) | De post op de betaalrekening waarop de overboeking van Automatisch sparen als uitgave telt. |
| Minimaal op je betaalrekening aan het eind van de maand (was: anti-rood) | Een vast bedrag per jaar dat je altijd laat staan, zodat je niet rood komt; in de rekensom "de buffer". |
| Tijdelijk geleend van spaar (was: tijdelijk anti-rood) | Geld dat je even van spaar haalt en later terugzet; de app telt wat er nog uitstaat. |
| Vrij te besteden (was: besteedbaar nu) | Saldo betaalrekening min de buffer, min tijdelijk geleend, plus wat er nog terugkomt. Alleen nog op de telefoonpagina, in Rapporten en in de kerncijfers. |
| Nog te besteden deze maand | Het hoofdgetal: vrij te besteden plus wat er deze maand nog verwacht wordt (zie de rekensom). |
| Nog verwacht | Status van een post die deze maand nog komt en nog niet te laat is (was: open). |
| Nog overboeken (was: Verrekenen met spaar, Spaaroverboeking) | Iets dat je vanaf betaal betaalde maar bij een potje hoort (of andersom); je zet het later in één overboeking met spaar recht. |
| Tag | Kenmerk om uitgaven te volgen (tanken, uit eten), alleen op de betaalrekening. Telt niet als extra uitgave. |
| Krijg ik terug (was: verrekenen bij een tag, voorgeschoten) | Schakelaar bij een tag: uitgaven met deze tag krijg je terug; de app toont "Nog terug te ontvangen: € …". |
| Tel mee bij ‘nog te besteden’ (was: telt mee in nog te besteden) | Schakelaar bij een tag: het bedrag dat nog terugkomt telt mee in het hoofdgetal als "Komt nog terug". |
| Banktransactie (was: bankregel) | Een regel uit het bankbestand; onveranderlijk. |
| Gecontroleerd / nog niet gecontroleerd (was: nagekeken) | Of je een (automatisch) geboekte boeking achteraf hebt bekeken (`Entry.reviewed`). |
| Voortaan zo indelen (was: onthoud als regel) | Vinkje bij het boeken: van je keuze wordt een regel gemaakt of een regel bijgewerkt. |
| Indelen bij (was: toewijzen aan) | Een boeking bij een post of potje zetten. |
| Hoort bij maand (was: telt mee in) | De begrotingsmaand van een boeking als die anders is dan de maand van de datum. |
| Klopt / Wijkt af / Nog verwacht / Te laat / Afgevinkt | De status van een post in een maand (maandgrid, Vaste posten). |
| Spaardoel | Doelbedrag en doeldatum bij een potje, met een kleine marge. |
| Vooruitblik | Het verwachte saldo van een potje in de tijd. Telt nergens anders in mee. |
| In de min, gedekt door andere potjes (was: geleend uit andere potten) | Het totaal van potjes die negatief staan; geen "tijdelijk geleend". |
| Periodieke transacties / Incidentele transacties | De boekingen op vaste posten tegenover de boekingen op overig (kaartjes op het Dashboard). |
| Te doen (was: Nog rechtzetten) | Het scherm met alles wat nog open staat: nog over te maken, terug te ontvangen, tijdelijk geleend. |

## Modules

| Target | Taak | Hangt af van |
|---|---|---|
| `HFCore` | `Money`, `Day`, records, schema en migraties (`AppDatabase`), `GoalMargin` | GRDB |
| `HFImport` | CSV lezen per bankprofiel, saldoketen, dubbelen, import naar `bankTransaction` | HFCore |
| `HFRules` | Regels toepassen op banktransacties, voorstellen met zekerheid, regelconcept bij een boeking | HFCore |
| `HFBudget` | Schrijven: boeken, splitsen, potjes, overboekingen, Nog overboeken, terugbetalingen, afstemming, jaar en posten beheren, hulpje "Nieuw jaarbedrag" (`AnnualAmountService`) | HFCore |
| `HFInsight` | Lezen: maandgrid, status vaste posten, saldo, vrij en nog te besteden met rekensom, Dashboard en Aandacht, potsaldi, spaardoel, vooruitblik, keten, rapportcijfers, kerncijfers, zoeken | HFCore |
| `HFBackup` | Back-up en herstel, voorbeelddata, export als CSV en als Excel-bestand per jaar | HFCore |
| `HFHistory` | Eenmalige import van de Excel-historie (in de wacht) | HFCore |
| `HFPublish` | Het dashboard voor de telefoon als bestand | HFCore, HFInsight |
| `HomeFinance` | De SwiftUI-app. Geen rekenlogica in views. | alles |

Modules kennen elkaar niet onderling (`HFInsight` leest alleen en rekent zelf met SQL); alleen de app verbindt
ze (bijvoorbeeld `WaitingProposals`: de gedeelde voorstellen voor Nakijken en Transacties). Elke module
beschrijft zijn publieke API in `docs/api/<Module>.md`.

## Datamodel

Zie `Sources/HFCore/Records.swift` (records met uitleg) en `Schema.swift` (tabellen). Kern:

- **Account**: betaal of spaar, met beginsaldo en begindatum.
- **BudgetYear**: jaar, `antiRood` (in de interface: minimaal aan het eind van de maand), `closed`.
- **BudgetItem**: vaste post in één jaar (rij in het grid): label, richting IN/UIT/RES, planbedrag met teken,
  frequentie (maand, kwartaal, jaar), verwachte maanden en dag. Eén post per jaar is `isReserveTotal` (de post
  RESERVERINGEN); de RES-regels zijn `isReserveLine`.
- **Pot** (potje): deel van het saldo van een spaarrekening; soort reservering of spaar; optioneel een eigenaar
  (bv. een kind of een groep), een spaardoel (`targetAmount`, `targetDate`, eventueel opgebouwd uit
  **GoalPart**-regels) en `forecastFromHistory` (vooruitblik met eerdere uitgaven). Mag negatief staan.
  Opheffen = archiveren (`archived`).
- **Distribution** + **DistributionLine** (Automatisch sparen): een vaste overboeking van een betaalrekening
  naar een spaarrekening, met de verdeling over potjes en optioneel de post waarop hij in de begroting telt.
- **ForecastItem**: een verwacht bedrag voor een potje op een datum, optioneel binnen een project; wordt
  afgevinkt met de boeking waarmee hij uitkwam (`realizedEntryId`).
- **ItemCheck**: een post die voor een maand met de hand is afgevinkt.
- **Settlement**: een terugbetaling bij een tag met "Krijg ik terug" (bv. Tanken).
- **BankTransaction**: regel van de bank, onveranderlijk. Status nieuw, verwerkt of overgeslagen.
- **Entry** (boeking): bedrag op een rekening, ingedeeld bij post of potje. Eén of meer per banktransactie
  (splitsen); zonder banktransactie = handinvoer. `reviewed = false` betekent "nog niet gecontroleerd".
  `period` = de maand waarin de boeking meetelt als dat een andere is dan de maand van de datum ("Hoort bij
  maand"). Markeringen: `temporaryLoan`, `reimburse` (+ `potId`, Nog overboeken), `forecastOneOff` (eenmalige
  uitgave, telt niet in het gemiddelde van de vooruitblik).
- **Tag**: n-op-m met Entry; met `settles` (Krijg ik terug), startbedrag en startdag, en `countsInSpendable`
  (Tel mee bij ‘nog te besteden’).
- **Rule**, **Reconciliation**, **SavingsTransfer** (een overboeking met spaar uit Nog overboeken),
  **ImportBatch**, **Setting** (o.a. de marge van spaardoelen en de instellingen van de telefoonpagina).

### Migraties

Bestaande migraties worden nooit aangepast; een wijziging is een nieuwe migratie in `HFCore/Schema.swift`.

| Migratie | Wat |
|---|---|
| `v1` | Alle tabellen van de eerste versie. |
| `v2-temporaryLoan` | Markering tijdelijk geleend van spaar op een boeking. |
| `v3-settlement` | Verrekenen per tag (nu: Krijg ik terug) en de terugbetalingen. |
| `v4-distribution-check-period` | Vaste storting (nu: Automatisch sparen) met verdeling en koppeling aan een post, post afvinken, begrotingsmaand (`period`). |
| `v5-distribution-source` | Herkomstrekening van een vaste storting (Automatisch sparen). |
| `v6-forecast` | Losse verwachtingen voor de vooruitblik. |
| `v7-pot-target-date` | Doeldatum van een spaardoel. |
| `v8-scenario-goalparts-project` | Wat-als-bedragen, onderdelen van een spaardoel, project bij een verwachting. |
| `v9-rule-reimburse-direction` | Richting van verrekenen in een regel (zie Regels en Nog overboeken). |
| `v10-tag-start-spendable` | Startbedrag van een tag en "telt mee in nog te besteden" (6g). |
| `v11-forecast-history` | `pot.forecastFromHistory` en `entry.forecastOneOff`: vooruitblik met eerdere uitgaven (22 november). |

De UX-ronde (stap A t/m D, herstelronde 1) had geen migratie. De marge van spaardoelen en de keuzes voor de
telefoonpagina staan in de tabel `setting`, zonder migratie.

## Rekenregels

### Betaalrekening en maandgrid
- Een boeking op een betaalrekening met `budgetItemId` hoort bij die vaste post; zonder is het **overig** (was:
  divers): IN overig als het bedrag positief is, UIT overig als het negatief is.
- Maand en jaar van een boeking volgen uit `day` (de datum van de transactie, niet van de import), tenzij
  "Hoort bij maand" is ingevuld (zie Begrotingsmaand).
- **Grid**: rijen = vaste posten van het jaar op `sortOrder`; kolommen = plan, jan–dec. Celwaarde = som van de
  boekingen van die post in die maand. Een cel kan meer boekingen bevatten.
- **Plan van RESERVERINGEN** in alle berekeningen (grid, status, ruimte, nog te besteden, rapport plan/werkelijk,
  maandbalans) = som van het plan van alle RES-regels van het jaar (`PlanSet`). RES-regels zelf krijgen geen
  boekingen op de betaalrekening.
- **Totaalrijen per maand**: vaste posten (zonder RES-regels), IN overig, UIT overig, netto overig, resultaat.
- **Ruimte t.o.v. maandbudget** = (som plan van de posten die deze maand verwacht worden, zonder RES-regels)
  + IN overig + UIT overig. Positief: binnen budget. (De spec is hier niet eenduidig; dit is de gekozen uitleg.)
- **Celstatus**: `gelijk` (Klopt: som = plan), `afwijkend` (Wijkt af ± € X), `nietVerwacht` (post komt deze
  maand niet voor of de maand ligt in de toekomst), `open` (Nog verwacht: verwacht, nog niet geboekt, nog niet te
  laat), `teLaat` (Te laat: verwacht, niet geboekt en de verwachte dag of de maand is voorbij), `afgevinkt`.
  Een post met een afwijkend bedrag geldt als voldaan, niet als te laat; het plan verandert niet.
- Kwartaal- en jaarposten: `planAmount` is het bedrag per keer; `expectedMonths` zegt in welke maanden.

### Automatisch sparen tegenover de RES-regels
- De verdeling over de potjes komt uit **Automatisch sparen** (de regels van de vaste overboeking), niet uit de
  RES-regels. Spaardoelen, de vooruitblik, potbedragen per maand en de CSV-export gebruiken Automatisch sparen.
- Hangt RESERVERINGEN aan een Automatisch sparen, dan volgt het **opgeslagen** plan van die post het totaal van
  de overboeking (min het totaal). In de **berekeningen** blijft het plan van RESERVERINGEN de som van de
  RES-regels (zie hierboven). Dat is een bewuste stand (UX-stap B1); één bron ook in het rekenen is een
  rekenregelwijziging en vraagt een eigen besluit.
- Lopen de RES-regels en de overboeking uit elkaar, dan waarschuwt de app in het maandgrid, bij Posten en bij
  Automatisch sparen ("Let op: de RES-regels tellen op tot € …, Automatisch sparen: … tot € …").
- Weergave: de uitgeklapte opbouw van RESERVERINGEN in het maandgrid en bij Posten toont de regels van
  Automatisch sparen (potje en bedrag), alleen-lezen; de RES-regels staan apart als "RES-regels (oude opbouw)".
- Excel-export: plan van RESERVERINGEN = som van de RES-regels; de RES-regels staan als ingesprongen rijen.
  Jaar kopiëren neemt de RES-regels mee.

### Saldo en afstemming
- Saldo van een rekening op dag D = beginsaldo + som van de boekingen t/m D.
- Afstemmen: de gebruiker voert het werkelijke banksaldo in; verschil = berekend − werkelijk; moet € 0,00 zijn.
  Elke controle wordt vastgelegd. Na een import die sluit op het eindsaldo stemt de app vanzelf af.
- Een banktransactie is `verwerkt` als de som van zijn boekingen gelijk is aan zijn bedrag.

### Vrij te besteden (was: besteedbaar nu)
- **Vrij te besteden** = saldo van alle betaalrekeningen − minimaal aan het eind van de maand − tijdelijk geleend
  van spaar + komt nog terug.
- **Peildag**: vandaag, of 31-12 voor een voorbij jaar. "Komt nog terug", "nog verwacht" en open overboekingen
  met spaar tellen alleen in het lopende jaar.
- **Minimaal op je betaalrekening aan het eind van de maand** (was: anti-rood, `budgetYear.antiRood`): een vast
  bedrag per jaar, in te stellen bij Posten en bij de eerste start.
- **Tijdelijk geleend van spaar** (voorheen "tijdelijk anti-rood") is geen instelling maar volgt uit de
  transacties: een boeking op de betaalrekening kan de markering `temporaryLoan` krijgen. Lenen is een
  bijschrijving (+), terugboeken een afschrijving (−); het uitstaande bedrag is de som van alle gemarkeerde
  boekingen t/m de peildag, met nul als ondergrens.
- **Komt nog terug**: per tag met "Krijg ik terug" én "Tel mee bij ‘nog te besteden’" het openstaande bedrag
  (zie Tags), alleen als dat positief is.
- Op de betaalrekening staat geen geld met een bestemming. Alles wat gereserveerd is, staat in een potje op de
  spaarrekening (besluit 13-11-2026). De Excel hield één reservering op de betaalrekening aan: een jaarlijkse
  schenking waaruit maandelijks rente op een privélening wordt betaald. In de app is dat een potje: de schenking
  gaat één keer per jaar naar dat potje, de maandelijkse rentebetaling krijgt via een regel "Nog overboeken" uit
  dat potje en loopt mee in de maandelijkse overboeking met spaar.
- De kolommen `budgetYear.reserveBase`, `budgetYear.tijdelijkAntiRood` en `budgetItem.reducesReserve` bestaan
  nog in het schema maar worden niet meer gebruikt.
- De trendgrafiek (vrij te besteden per maandeinde, Dashboard › Verloop van het jaar en telefoon) rekent met
  saldo − minimaal − tijdelijk geleend, zonder "komt nog terug".

### Nog te besteden deze maand (de rekensom)
Het hoofdgetal van het Dashboard en de telefoon (`Insight.spendable` → `spendableEndOfMonth`). Het Dashboard
toont het als rekensom (`SpendableBreakdown`); de regels tellen exact op tot het hoofdgetal:

```
  Huidig saldo betaalrekening                         saldo van alle betaalrekeningen op de peildag
− Minimaal op de rekening aan het eind van de maand   de buffer van het jaar (altijd getoond)
− Tijdelijk geleend van spaar                         alleen als er iets uitstaat
+ Komt nog terug                                      alleen als een tag meetelt
+ Nog verwacht deze maand                             netto, uit te klappen in inkomsten en uitgaven
= Nog te besteden deze maand
```

**Nog verwacht deze maand** (alleen in het lopende jaar) is de som van:
1. het plan van elke post die deze maand verwacht wordt, waarop in deze begrotingsmaand t/m vandaag nog geen
   boeking op een betaalrekening staat en die niet is afgevinkt. RESERVERINGEN telt mee (met de som van de
   RES-regels), de RES-regels zelf niet. Uitgeklapt per post, met "te laat" als de verwachte dag voorbij is;
2. de **delen van kwartaal- en jaarinkomsten** (sinds 22 november, `f8738a5`): een inkomst (IN) met frequentie
   kwartaal of jaar telt in een maand tussen twee uitbetalingen voor een deel mee. In maand *k* na de vorige
   uitbetaling, met *g* maanden tussen twee uitbetalingen, telt *k/g* van het bedrag (naar beneden afgerond op
   centen). Het deel is cumulatief, omdat nog te besteden uitgaat van het saldo: het geld van de vorige
   uitbetaling is dan al deels uitgegeven. Voorbeeld: kinderbijslag in jan, apr, jul en okt; in november telt
   1/3, in december 2/3, in januari het hele bedrag (als gewone verwachte post). In de rekensom: "Kinderbijslag
   (1 van 3 delen, komt in jan)". Alleen inkomsten; alleen in een maand waarin de post niet verwacht wordt en
   waarin er niets op geboekt is. Vrij te besteden verandert niet;
3. het netto bedrag van alle **open regels van Nog overboeken** (gemarkeerde boekingen die nog niet in een
   afgevinkte overboeking met spaar zitten), met teken vanuit de betaalrekening, als regel "Nog over te boeken
   met spaar".

Zolang er banktransacties op een betaalrekening wachten, waarschuwt het Dashboard dat het getal die nog niet
meetelt (knop Boeken).

### Potjes en spaarrekening
- Saldo van een potje = som van de boekingen op de spaarrekening met dat `potId`.
- Saldo spaarrekening = beginsaldo + som boekingen; **niet toegewezen** = saldo − som van alle potjes.
- Een potje mag in de min staan: het wordt dan gedekt door de andere potjes ("In de min, gedekt door andere
  potjes"). De app toont wanneer het met de huidige stortingen weer op nul staat.
- **Beginbedrag**: een potje krijgt bij het aanmaken een beginbedrag (standaard € 0,00), geboekt als handmatige
  boeking "Beginsaldo …" op de spaarrekening. Beginsaldo rekening = potjes + niet toegewezen.
- **Automatisch sparen** (was: vaste storting): naam, herkomstrekening (betaal), doelrekening (spaar) en per
  potje een bedrag. Het totaal is de som van de regels. Een post op de betaalrekening kan eraan gekoppeld zijn
  ("Telt in je begroting als"); zijn opgeslagen plan is dan altijd min het totaal. Er kunnen meer vaste
  overboekingen zijn. Dit vervangt het maandbedrag per potje en de RES-regels als bron van de verdeling.
- **Herkennen**: een banktransactie tussen de herkomst- en doelrekening van een vaste overboeking wordt aan beide
  kanten herkend aan de tegenrekening. Op de spaarrekening is het voorstel de verdeling over de potjes; op de
  betaalrekening de gekoppelde post. Wijkt het bedrag af, dan toont de app het verschil en kiest de gebruiker;
  bij een (klein) verschil staat er ook "Losse overboeking? Kies een potje". Bij meer vaste overboekingen vanaf
  dezelfde rekening vraagt de app eerst welke (zie `docs/voortgang.md`, 6n).
- **Spaardoel**: doelbedrag en doeldatum. Nodig per maand = (doel − saldo − verwachte losse bedragen) gedeeld
  door het aantal stortmomenten tot de doeldatum. Daarnaast: wat er nu per maand gestort wordt, of het doel
  gehaald wordt, en op welke datum. Status: bereikt, op koers, tekort, verlopen of zonder datum.
  **Marge** (22 november, `0cba322`): blijft het verwachte saldo op de doeldatum minder dan de marge onder het
  doel, dan is het "op koers (binnen de marge)" en komt er geen melding bij Aandacht. De marge is een percentage
  van het doel, standaard 0,5 %, te kiezen bij het spaardoel (0 / 0,5 / 1 / 2 %) en geldt voor alle potjes
  (`GoalMargin`, tabel `setting`). Alleen de status verandert.
- **Vooruitblik**: het verwachte saldo van een potje in de tijd = het echte saldo + de terugkerende stortingen
  uit Automatisch sparen + de losse verwachtingen (`ForecastItem`) + eventueel de gemiddelde eerdere uitgaven
  (hieronder). De storting van de lopende maand telt alleen mee als hij nog niet binnen is. Een losse
  verwachting wordt afgevinkt als hij is uitgekomen. Verwachtingen tellen nergens anders in mee. Verwachtingen
  met hetzelfde project vormen een begroting: gepland, betaald, nog te komen.
- **Verwachting "Elke maand"** (22 november, `b44242d`): bij het toevoegen van een verwachting kan "Elke maand"
  met "Tot en met" (bv. een treinabonnement t/m juli). De app maakt één losse verwachting per maand; samen staan
  ze in één blokje (zonder project wordt de omschrijving het project).
- **Vooruitblik met eerdere uitgaven** (22 november, `52593b2`, migratie v11): schakelaar "Reken met eerdere
  uitgaven" per potje (`Pot.forecastFromHistory`, standaard uit). Aan: vanaf de maand na vandaag gaat er elke
  maand (op de 15e) het gemiddelde van de uitgaven eraf. Het gemiddelde = som van de negatieve boekingen op het
  potje over de afgelopen 12 hele maanden vóór de lopende maand, gedeeld door het aantal maanden (korter bij een
  jong potje, vanaf de maand van de eerste boeking; zonder hele maand geen gemiddelde). Telt niet mee: boekingen
  die als eenmalig zijn gemarkeerd (rechtsklik bij Mutaties, `Entry.forecastOneOff`) en boekingen waarmee een
  losse verwachting is uitgekomen (die staan al als verwachting in de vooruitblik). Het gemiddelde staat ook bij
  de schakelaar als die uit staat. Aandacht: "Potje … komt binnen een jaar onder nul" als een potje met de
  schakelaar aan nu niet negatief staat en in de vooruitblik binnen een jaar onder nul komt.
- **Potje opheffen** (was: archiveren; 22 november, `efbe10d`): zonder saldo meteen. Met saldo kies je waar het
  geld heen gaat: een ander potje (de app verplaatst het saldo en heft op) of de betaalrekening (drie stappen:
  overmaken, de afschrijving op het potje boeken, opheffen).
- **Overboeking tussen eigen rekeningen**: twee banktransacties met tegengesteld bedrag, waarvan de
  tegenrekening de andere eigen rekening is, binnen 3 dagen. De boekingen worden aan elkaar gekoppeld
  (`counterEntryId`). Ze tellen op elke rekening gewoon mee in het saldo. Nakijken en Transacties tonen bij de
  ene helft de andere ("+ € … op Spaarrekening, … · wacht nog op een plek") met "Bekijk".

### Nog overboeken (was: Verrekenen met spaar)
- Een boeking op de betaalrekening kan gemarkeerd worden om met een potje recht te zetten (`reimburse` +
  `potId`; schakelaar "Nog overboeken met spaar"): een uitgave "komt uit het potje", een bijschrijving "gaat naar
  het potje".
- Openstaand = alle gemarkeerde boekingen die nog niet in een overboeking met spaar zitten. Het saldo is netto:
  uit potjes min naar potjes. Positief = over te maken van spaar naar betaal; negatief = van betaal naar spaar;
  nul = alleen verschuiven tussen potjes.
- **Afvinken boekt meteen**: per potje een boeking op de spaarrekening en één tegenboeking op de betaalrekening,
  aan elkaar gekoppeld. De administratie klopt dus zodra de gebruiker heeft overgemaakt. De opgeslagen
  omschrijving "Verrekening spaar" en de notitie "Verrekening #id" zijn bewust niet hernoemd.
- **Bij een latere import** wordt de banktransactie herkend (bedrag, tegenrekening, binnen 7 dagen) en aan de
  bestaande overboeking gehangen ("Afvinken en koppelen"). Er komt geen nieuwe boeking bij en het saldo
  verandert niet.
- Een afgevinkte overboeking die na 5 dagen nog niet in een bankbestand is gezien, wordt gemeld bij Aandacht
  (opent Te doen).
- Volgorde van herkennen bij nieuwe banktransacties: overboekingen met spaar, dan Automatisch sparen, dan regels.
- **Een regel zet alleen in één richting om naar Nog overboeken** (`Rule.reimburseDirection`: geld erin, geld
  eruit of beide). In de andere richting stelt dezelfde regel de post, de omschrijving en de tags voor, maar géén
  Nog overboeken en géén potje, met zekerheid laag en een melding (twijfelgeval in Nakijken). Het regelconcept
  vult de richting met die van de transactie waarbij de gebruiker Nog overboeken koos. Bestaande regels met
  verrekenen kregen bij migratie v9 de richting van hun laatste boeking met verrekenen, en zonder zo'n boeking
  "geld erin" (alleen bijschrijving) als veilige keuze. Aanleiding: een regel op de rekening van een kind,
  geleerd van geld dat binnenkwam voor haar spaarpotje, haalde ook zakgeld dat naar het kind ging van dat potje
  af.

### Tags: Krijg ik terug en Tel mee (was: Verrekenen per tag, Voorgeschoten)
- Tags staan alleen op boekingen van een betaalrekening; HFBudget weigert een tag op spaar (6h).
- **Krijg ik terug** (`Tag.settles`, vanaf een startdag): uitgaven met die tag krijgt de gebruiker later terug
  (bv. Tanken). **Openstaand** ("Nog terug te ontvangen: € …") = het startbedrag zolang dat niet in een
  terugbetaling zit − de som van de boekingen op een betaalrekening met die tag, vanaf de startdag, die nog niet
  in een terugbetaling (`Settlement`) zitten.
- **De terugbetaling taggen** (herstelronde 1, `67b4a18`): de gebruiker geeft de bijschrijving van het geld dat
  terugkomt dezelfde tag. Die bijschrijving telt in de som hierboven af, dus het openstaande bedrag daalt (een
  deel terug verlaagt het, alles terug maakt het € 0,00) en "Komt nog terug" valt weg; nog te besteden blijft
  gelijk, want het geld staat nu op de rekening. Er is geen knop "Het is binnen…" meer. Bij een bijschrijving
  die (bijna, binnen € 1,00) het openstaande bedrag is, vragen Nakijken en Transacties "Is dit je € … van Tanken
  terug?" met de knop "Tag Tanken" (boekt als overig met de tag). Gevolgen: de getagde terugbetaling blijft als
  open boeking bij de tag staan (netto € 0,00), er komt geen regel bij in de geschiedenis van terugbetalingen, en
  een tag-rapport telt de bijschrijving mee in het netto bedrag. Oude terugbetalingen en hun "Maak ongedaan"
  blijven bestaan.
- **Startbedrag** (6g): wat er bij de start van de app al openstond (uit de Excel-periode), met een dag. Het telt
  mee in het openstaande bedrag. Is het in een terugbetaling opgenomen, dan is het niet meer te wijzigen, tot
  die terugbetaling ongedaan is gemaakt.
- **Tel mee bij ‘nog te besteden’** (`countsInSpendable`, 6g), per tag, standaard uit: het openstaande bedrag
  telt mee als "Komt nog terug" in vrij te besteden en nog te besteden (alleen in het lopende jaar, alleen als
  het positief is). Op de telefoon staat het als "Komt nog terug: <tag>".

### Begrotingsmaand en afvinken
- Een boeking telt voor de begroting in de maand van zijn `period` ("Hoort bij maand"), of anders in de maand van
  zijn datum. De periode mag hoogstens twee maanden van de datum afliggen. Het saldo van de rekening volgt altijd
  de datum.
- Een vaste post kan voor een maand met de hand worden afgevinkt. Zonder boeking is de status dan `afgevinkt`:
  hij telt als voldaan, niet als open of te laat, en niet in "nog verwacht deze maand".

### Maandbalans en wat-als
- Maandbalans = geplande inkomsten per maand min geplande uitgaven per maand; kwartaal- en jaarposten naar rato.
- Per post kan een wat-als-bedrag worden ingevuld. De wat-als-balans gebruikt dat bedrag waar het is ingevuld en
  anders het plan. Er verandert niets aan de begroting tot de gebruiker er het nieuwe plan van maakt.

### Omschrijvingen
- De omschrijving van een boeking komt uit de regel of van de gebruiker; de tekst van de bank blijft bewaard.
- Voorgestelde omschrijving zonder regel (6b): bij een overboeking met een korte eigen tekst die tekst, bij pin,
  incasso, iDEAL, gestructureerde, zakelijke of lange teksten de tegenpartij; pinnamen worden opgeschoond (6j).
- Totalen per omschrijving: losse boekingen gegroepeerd op genormaliseerde omschrijving.
- Bij het typen vult de app bestaande omschrijvingen aan en meldt hij een bijna-gelijke schrijfwijze. Dubbele
  schrijfwijzen kunnen worden samengevoegd.

### Volgorde in keuzelijsten
- Potjes (6c) en posten (6n, ronde 14) staan in alle kiezers per groep op alfabet, hoofdletter- en
  accentongevoelig, met Nederlandse sortering ("Pot 2" vóór "Pot 10"); `Insight.pickerOrder` en
  `Insight.itemPickerOrder`. "Overig (geen vaste post)" en "Geen" blijven bovenaan. Het maandgrid en het jaarplan
  houden hun eigen volgorde.

### Import (uit de werkwijze van de Excel)
1. Bestand lezen; elke regel wordt een `BankTransaction` of een gemelde fout. Geen regel verdwijnt stil.
2. **Saldoketen**: waar de bank "saldo vóór mutatie" levert, moet saldo-vóór + bedrag gelijk zijn aan het
   saldo-vóór van de volgende regel. Het eindsaldo van het bestand wordt getoond en bewaard.
3. **Dubbelen**: vingerafdruk per regel; een regel die al bestaat wordt overgeslagen en geteld.
4. Alles in één databasetransactie: bij een fout wordt niets geïmporteerd.
5. Regels doen per transactie een voorstel met zekerheid. Twijfelgevallen eerst, daarna boeken.
6. Nieuwe boekingen krijgen `reviewed = false` ("nog niet gecontroleerd") tot de gebruiker ze heeft bekeken.
7. Controle achteraf: elke geïmporteerde regel is verwerkt of overgeslagen; het berekende saldo is gelijk aan
   het eindsaldo van het bestand. Sluit het niet (en wacht er niets meer), dan meldt Aandacht het.
8. **Eerste import van een rekening** (nog geen banktransacties): de app zoekt de regel waarvan het saldo vóór
   de mutatie gelijk is aan het saldo in de administratie. Alles ervoor wordt overgeslagen en telt als "al
   bekend". Wordt geen regel gevonden, dan valt de app terug op de begindatum en kiest de gebruiker per regel.
9. Geïmporteerde transacties blijven in de wachtrij staan tot ze geboekt of overgeslagen zijn, ook na het
   sluiten van de app.
10. **Downloadadvies** (6a): Transacties zegt van welke rekeningen en vanaf welke dag (de vroegste laatste
    banktransactie over alle rekeningen) tot en met vandaag de CSV-export te downloaden.

### Regels
Zekerheid en volgorde:
1. Tegenpartij (naam of IBAN) **en** bedrag kloppen → `hoog`.
2. Tegenpartij klopt, regel heeft geen bedrag of het bedrag wijkt af → `midden`.
3. Trefwoord in de omschrijving → `midden`.
4. Alleen bedrag → `laag`.
5. Geen regel → `geen`.

Binnen dezelfde zekerheid wint de laagste `priority`, daarna de meest specifieke regel. "Zeker" (in de tellers
van Nakijken en Transacties) betekent alleen nog: ook het bedrag klopt.

**Regels alleen met toestemming** (sinds 21 november, 6i). Boeken maakt of wijzigt nooit vanzelf een regel.
Nakijken en Transacties gebruiken hetzelfde vinkje (`RuleConsentChoice`) en dezelfde voorstellen
(`WaitingProposals`).
- Geen regel deed een voorstel: "Voortaan zo indelen" (was: Onthoud als regel), standaard uit. Aangevinkt toont
  het één samenvattingszin ("Voortaan bij X: post …, nog overboeken met potje … bij geld eruit, omschrijving
  '…'") en "Aanpassen…" (de regeleditor, voorgevuld). Het concept: voorwaarde op de tegenpartij (IBAN, anders
  naam, anders een trefwoord uit een herkenbare omschrijving), een bedrag erbij als het doel een vaste post is
  en tegenpartij en bedrag al eerder voorkwamen, en als acties de keuze (post, potje, Nog overboeken met
  richting, omschrijving, tags). De regel wordt bewaard bij het boeken, precies zoals getoond.
- Een regel deed een voorstel en de keuze wijkt af: "Regel bijwerken met deze keuze", standaard uit. Aan: die
  regel krijgt de nieuwe acties, zijn voorwaarden blijven. Uit: de boeking is een uitzondering, de regel blijft.
- De keuze is gelijk aan het voorstel: geen vinkje; de regel telt als gebruikt (`hitCount`, `lastUsed`).
- Bij "Waarom dit voorstel?" opent "Regel aanpassen…" de voorstellende regel in de editor.
- Een regel met alleen een bedrag kan zo niet ontstaan (de editor eist een voorwaarde; het concept heeft altijd
  een tegenpartij of trefwoord). De knop Boek in Transacties bewaart alleen een regel als het vinkje aan staat.

## Schermen

Uitgangspunt: de eerste aanblik van elk scherm is rustig, met zo min mogelijk tekst (wens uit de test van de
UX-ronde); details staan achter een klik. Alleen het maandgrid is compact. Bedragvelden accepteren ook een som
(249*4). Met voorbeelddata start de app op het Dashboard.

### Zijbalk
Ingedeeld naar wat je komt doen (`SidebarGroup.all`, één lijst die de echte zijbalk en de snapshot-zijbalk
allebei lezen):

| Groep | Schermen |
|---|---|
| Vandaag | Dashboard · Te doen (met teller) |
| Bijwerken | Importeren en nakijken · Transacties · Tags |
| Begroting | Posten |
| Sparen | Potjes · Automatisch sparen |
| Inzicht | Maandgrid |
| *(onderaan, zonder kop)* | Instellingen: Rekeningen, Regels, Back-up, Telefoon, Over |

- **Rapporten** staat tijdelijk niet in de zijbalk (wens van de gebruiker, 22 november, `44b2f9d`); het scherm
  bestaat nog (tabbladen Overzicht, Vrij te besteden, Tags, Per omschrijving, Budget tegen werkelijk, Overige
  uitgaven, Jaar op jaar).
- Tellers in de zijbalk: Importeren en nakijken (wachtende banktransacties), Transacties (nog niet
  gecontroleerd), Te doen (kaartjes met inhoud), Tags (tags met iets terug te ontvangen).
- **Nog overboeken** heeft geen regel in de zijbalk; je komt er via Te doen, de balk op Transacties en het
  Dashboard. Staat de app daar, dan is er in de zijbalk niets gemarkeerd.
- Vervallen: de oude zijbalk (Transacties · Importeren en nakijken · Dashboard · Maandgrid · Potten en sparen ·
  Verrekenen met spaar · Rapporten · Regels · Instellingen met Jaar en posten en Tags), de schermen Nog
  rechtzetten en Voorgeschoten (stap D), en de tabbladen Jaar en posten en Tags van Instellingen.

### Dashboard
- Kop "Dashboard" met de datumregel ("zaterdag 21 november 2026") en de knop Importeren.
- **Nog te besteden deze maand** als groot getal, met de rekensom eronder (zie Rekenregels); "Nog verwacht deze
  maand" klapt uit in inkomsten en uitgaven per post. Geen grijze uitlegtekst en geen "Vrij te besteden".
  Bestaat het jaar nog niet, dan een kaart "Er is nog geen begroting voor …".
- **Aandacht** (rechts naast het getal, of eronder in een smal venster), alleen met wat er is: minimum niet
  gehaald (nog te besteden negatief), vaste posten later dan normaal, nog te boeken banktransacties, nog niet
  gecontroleerde boekingen, open Nog overboeken, overboekingen met spaar die na 5 dagen nog niet in een
  bankbestand zijn gezien, tijdelijk geleend van spaar, per tag nog terug te ontvangen, grote uitgave op komst
  (een verwachte, nog niet geboekte uitgave van € 250 of meer die niet maandelijks is), spaardoelen niet op koers
  (buiten de marge), potjes die binnen een jaar onder nul komen, saldo na import sluit niet aan (alleen als er op
  die rekening niets meer wacht), laatste bankbestand ouder dan 14 dagen, afstemming met verschil of ouder dan
  35 dagen, geen begroting voor het jaar.
- **Drie kaartjes**:
  - *Periodieke transacties* (vaste posten deze maand): "x van y voldaan", Te laat (ook bij 0), Nog verwacht, en
    in en uit zoals al geboekt. Klik → pagina **Vaste posten**.
  - *Incidentele transacties* (overig deze maand): in, uit en de drie grootste uitgaven. Klik → pagina
    **Incidentele transacties**.
  - *Huidig saldo*: betaal, spaar en totaal; niet aanklikbaar.
- Link **Verloop van het jaar**: grafieken vrij te besteden per maand en in en uit per maand.
- Vervallen: de knop Maandgrid, de opbouwzin uit stap A, "Vrij te besteden" en de grijze uitlegzin.

### Vaste posten (achter Periodieke transacties)
Bovenaan nog binnen te komen, nog af te gaan en het saldo daarvan. Daaronder inkomsten en uitgaven apart, elk in
"Nog te komen" en "Verwerkt". Nergens € 0,00: plan, werkelijk bedrag, of plan met "afgevinkt". Filter Alles /
In / Uit. Geen link naar het maandgrid en geen info-icoon (uitleg als tooltip op de titel).

### Incidentele transacties (achter Incidentele transacties)
Drie kaartjes naast elkaar: totalen (in, uit, saldo), uitgaven per tag, de 5 grootste uitgaven. Daaronder alle
transacties zonder vaste post van de maand, te sorteren op datum en bedrag (op- en aflopend) en te filteren op
Alles / In / Uit. Geen links naar andere pagina's.

### Te doen (was: Nog rechtzetten)
Alleen kaartjes met inhoud; is alles leeg, dan "Er is niets te doen.". De teller in de zijbalk is het aantal
kaartjes.
- **Nog overboeken**: per regel "Nog overmaken: € …" met Afvinken…, of grijs "Afgevinkt, wacht op de bank" tot de
  import waarin de overboeking gezien is.
- **Terug te ontvangen**: per tag met Krijg ik terug wat er nog openstaat.
- **Tijdelijk geleend van spaar**: wat er nog uitstaat, met een link naar de boekingen in Transacties.

### Importeren en nakijken, Transacties
- Nakijken en Transacties tonen bij wachtende banktransacties dezelfde voorstellen, dezelfde regel "Nog … na te
  kijken · … zeker", hetzelfde vinkje "Voortaan zo indelen" en dezelfde extra herkenning (terugbetaling van een
  tag, de andere helft van een eigen overboeking, losse overboeking naar een potje).
- Achter de post staat "uit potje X" bij Nog overboeken. In het detail van een boeking in Transacties één regel
  "Nog over te boeken: € …" of "Nog terug te ontvangen: € …" met een knop naar de plek waar je het rechtzet.
- Transacties is een lijst als in een bank-app, met het downloadadvies, filters (ook op tag en op "nog niet
  gecontroleerd") en een balk naar Nog overboeken. "Boek de zekere" zet in Transacties op gecontroleerd, in
  Nakijken op nog niet gecontroleerd (bewust verschillend, keuze van de gebruiker).
- In de voorbeeldmodus heeft Nakijken de knop "Voorbeeldbestand importeren" (zie Voorbeelddata).

### Tags (was: Voorgeschoten, en Instellingen › Tags)
Eén scherm per tag: uitgaven deze maand en dit jaar, "Nog terug te ontvangen: € …" en het beheer (aanmaken,
kleur, schakelaars "Krijg ik terug" en "Tel mee bij ‘nog te besteden’", startbedrag). Rapporten › Tags (was:
Categorieën). Het woord "voorgeschoten" staat nergens meer in de interface.

### Posten (was: Instellingen › Jaar en posten)
Het jaarplan met de posten, jaar aanmaken, kopiëren en afsluiten, "Minimaal op je betaalrekening aan het eind
van de maand", de maandbalans met wat-als, en per post de ketenstrook. De opengeklapte post RESERVERINGEN toont
de opbouw uit Automatisch sparen alleen-lezen met "Verdeling wijzigen bij Automatisch sparen"; de RES-regels
staan in de groep "RES-regels (oude opbouw)" met hun som per maand.

### Maandgrid (onder Inzicht)
Het jaaroverzicht zoals de Excel. Vaste legenda van één regel (Klopt / Wijkt af (± € X) / Nog verwacht / Te laat
/ Afgevinkt) en boven het grid "Juni: 5 van 15 voldaan · 3 te laat". Het celvenster zegt de status in die
woorden; bij "Te laat" een hint als een wachtende banktransactie lijkt te passen, met een knop naar Nakijken.
"Toon opbouw van RESERVERINGEN" klapt de regels van Automatisch sparen uit.

### Potjes en Automatisch sparen
- **Potjes**: per groep (reservering, spaar), met saldo, niet toegewezen en "In de min, gedekt door andere
  potjes". Per potje: mutaties (rechtsklik: "Eenmalig (niet in het gemiddelde)"), spaardoel met marge,
  vooruitblik met verwachtingen ("Elke maand" t/m), projecten, de schakelaar "Reken met eerdere uitgaven" en
  Opheffen….
- **Automatisch sparen** (eigen scherm, was een knop op Potten): per vaste overboeking de verdeling over potjes
  en "Telt in je begroting als".
- **Ketenstrook** post ↔ Automatisch sparen ↔ potje (`Insight.chain`), met een klik naar de andere kant: bij een
  potje "Krijgt € … per maand via Automatisch sparen: X (post Y)" (bij meer overboekingen een lijstje), bij een
  vaste overboeking "Telt in je begroting als: post Y", bij een post (Posten en het celvenster van het maandgrid)
  "Gaat via Automatisch sparen: X naar n potjes".
- **Hulpje "Nieuw jaarbedrag…"** (Potjes, `AnnualAmountService`): naam, bedrag per jaar ("dat is € … per
  maand"), nieuw of bestaand potje, vaste overboeking (of een nieuwe, met de eerste betaalrekening als herkomst),
  de post (volgt vanzelf, of kiezen) en optioneel de rekening als verwachting in het potje. Vóór het opslaan de
  samenvatting "Er gaat elke maand € … naar potje X via Automatisch sparen: Y; je begroting rekent met € … op
  post Z. Let op: verhoog je overboeking bij de bank naar € …". Rekent met het lopende jaar. Is de post
  RESERVERINGEN en zijn er RES-regels, dan verhoogt het hulpje de RES-regel van het potje mee, zodat het grid
  meegaat.

### Instellingen
Rekeningen (met afstemmen), Regels (was een eigen scherm), Back-up, Telefoon, Over (wisselen tussen eigen
administratie en voorbeelddata). In een smal venster komen de tabbladen onder de titel.

### Venstermaten
Elk scherm werkt in de gewone en de kleinste venstermaat (1100 × 700): de titel blijft op één regel, niets
schuift horizontaal buiten beeld, de zijbalk blijft zichtbaar (rondes 15–18, 6k). Grijze bijschriften zijn
`.secondary`, niet lichter.

## Telefoondashboard (`HFPublish`)

Eén pagina (HTML en PDF) in een gekozen cloudmap, alleen lezen, licht en donker, ontworpen voor 375 punten breed
zonder horizontaal schuiven. In deze volgorde:
1. **Nog te besteden deze maand** als hoofdgetal (zelfde getal als het Dashboard), met "Vrij te besteden"
   eronder en per meetellende tag "Komt nog terug: <tag>". Zonder begroting: "Er is nog geen begroting voor …".
2. **Voor het gezin** (6l): per gekozen eigenaar (bv. een kind) een kaart met het totaal en de potjes met saldo.
   Alleen de eigenaren die de gebruiker aanvinkt.
3. **Gezamenlijke spaarpot** (6l, 6o): één gekozen potje met het saldo nu en de verwachte stand over 3, 6 en 12
   maanden (`Insight.potForecast`, dezelfde vooruitblik als bij het potje). Daaronder een datumveld "Stand op
   een eigen datum" en een inklapbare lijst "Stand per maand". De Mac zet de verwachte stand in de pagina tot een
   instelbaar aantal maanden vooruit (standaard 36, 12 … 120): per maand voor de lijst en per dag waarop de stand
   verandert voor het datumveld. Een klein ingebouwd script toont de stand op de gekozen dag; geen internet of
   externe bestanden. Vóór vandaag of na het einde: een korte melding. Zonder scripts (voorvertoning, PDF) is het
   datumveld verborgen en staat alleen de stand per maand er.
4. Uitgaven deze maand; optioneel vaste posten, de trend "Vrij te besteden per maand", rekeningen en potjes.

Instellen bij Instellingen › Telefoon (kaart "Voor het gezin": vinkjes per eigenaar, keuzelijst met potjes, het
aantal maanden vooruit). Zolang er niets gekozen is, staan de onderdelen er niet op. Opgeslagen in
`publish.options` (tabel `setting`); oudere instellingen worden gewoon gelezen. Nog niet op een echte iPhone
gecontroleerd.

## Voorbeelddata (`HFBackup`, versie 3)

Een verzonnen gezin (Ouder 1, Ouder 2, Kind 1, Kind 2) met verzonnen bedrijven en rekeningnummers, om de app te
demonstreren zonder eigen gegevens (6m). De demo-route staat in de README ("Demonstreren"), de inhoud in
`docs/api/HFBackup.md`.
- `DemoData.version` = 3. Een voorbeeldbestand van een andere of onbekende versie wordt vanzelf opnieuw gevuld;
  de eigen administratie wordt geweigerd vóór er iets geopend wordt.
- In de voorbeeldmodus ontbreken de laatste 10 dagen van beide rekeningen. Nakijken › "Voorbeeldbestand
  importeren" schrijft een zip zoals de bank hem levert en importeert die met het gewone zip-importeren; daarin
  o.a. zakgeld met Nog overboeken, geld terug van een kind (twijfel), een eigen overboekingstekst, een rommelige
  pinnaam, een losse overboeking naar spaar en de overboeking van een vastgelegde, nog niet afgevinkte
  overboeking met spaar.
- Inhoud: potjes per kind (spaargeld, kleedgeld, zakgeld), het spaardoel "Studie en rijbewijs" uit onderdelen
  (eigenaar Kids), "Buffer gezin" met vooruitblik, een rentepotje met vooruitblik, Tanken met startbedrag, Krijg
  ik terug en Tel mee, één Automatisch sparen ("Maandelijkse reserveringen"), regels zoals "Voortaan zo indelen"
  ze maakt.
- Telefoon: na het vullen zijn bij "Voor het gezin" Kind 1, Kind 2 en Buffer gezin gekozen; het
  telefoondashboard zelf blijft uit.

## Testen

Swift Testing, per module een eigen testtarget, met een database in het geheugen (`AppDatabase.inMemory()`).
Rekenregels krijgen tests met uitgewerkte, verzonnen voorbeelden. Daarnaast `scripts/testronde.sh`: bouwen,
`swift test`, de echte app starten met voorbeelddata voor de zelftest (elk scherm, beide venstermaten, de
zijbalk zoals AppKit hem tekent) en de kerncijfers (`Insight.keyFigures`) vergelijken met een basis. Zie
`docs/voortgang.md` en de README.

## Aannames en beperkingen

- De uitleg van "t.o.v. maandbudget" hierboven.
- Het plan van RESERVERINGEN in de berekeningen is nog de som van de RES-regels, ook als de post aan Automatisch
  sparen hangt (zie Rekenregels). De app waarschuwt als die twee uit elkaar lopen.
- De grenzen van Aandacht zijn constanten in HFInsight: 14 dagen voor de laatste import, € 250 voor een grote
  uitgave, 5 dagen voor een overboeking met spaar, 35 dagen voor een afstemming.
- De app draait alleen op de eigen Mac, zonder App Store en zonder sandbox.
- De schermen van de UX-ronde zijn gebouwd en met voorbeelddata, de zelftest en schermafbeeldingen gecontroleerd;
  niet alles is met de hand doorgeklikt (zie `docs/voortgang.md`).
- Een developer reviewt de code voordat de app de enige administratie wordt; tot dan draait de Excel mee.
