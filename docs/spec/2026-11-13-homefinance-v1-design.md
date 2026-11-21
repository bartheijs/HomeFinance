# HomeFinance voor macOS — ontwerp v1

*13 november 2026, bijgewerkt op 14 november 2026. Bron: `bron/Family_Budget_App_Specification.md` (geanonimiseerd) en het technische vooronderzoek.*

## Doel

Een native macOS-app voor één gebruiker die twee Excel-werkmappen vervangt: de gezinsbegroting op de
betaalrekening (maandoverzicht IN/UIT sinds 2006) en de administratie van de spaarrekening (reserveringspotten
en spaarpotten). De financiële logica van de Excel blijft gelijk; het typewerk verdwijnt.

**Start:** op 8 november 2026 met alleen beginstanden (saldo per rekening, beginbedrag per pot), zonder
historie. De gebruiker richt zelf in en draait schaduw in zijn Excel. De Excel-historie importeren staat in de
wacht (zie `docs/voortgang.md`).

**Klaar is:** een maand bijhouden kost alleen nog een CSV importeren en nakijken; het berekende saldo sluit op
€ 0,00 met de bank; besteedbaar klopt met de Excel-formule; elke pot heeft een saldo.

## Besluiten

| Onderwerp | Besluit |
|---|---|
| Techniek | Swift 6, SwiftUI, SQLite via GRDB 7, Swift Charts. Eén SwiftPM-package, geen `.xcodeproj`. |
| Opslag | `~/Library/Application Support/HomeFinance/homefinance.sqlite`. Nooit in een cloudmap. |
| Geld | `Money` in hele centen. Uitgaven negatief, inkomsten positief. Nooit `Double`. |
| Datums | `Day` (jaar-maand-dag, zonder tijdzone), in de database als `yyyy-MM-dd`. |
| Rekeningen | Meerdere: betaalrekening(en) en spaarrekening(en). Alle potten staan op één spaarrekening. |
| Import | De zip van de bank (één CSV per rekening, 19 kolommen zonder kop; bevestigd met echte bestanden), ook los CSV of PDF. Saldoketen, dubbelen, en bij de eerste import aansluiting op het beginsaldo. |
| Categorisatie | Regels die de gebruiker zelf maakt of bijwerkt, ook vanuit Nakijken ("Onthoud als regel"). Geen AI in v1. |
| Login | Geen. De Mac is de beveiliging. |
| Taal | Interface Nederlands. Code, commentaar in code mag Nederlands; identifiers Engels. |
| Telefoon | Geen hosting: de app schrijft een pagina (HTML zonder scripts en PDF) naar een cloudmap. |
| Back-up | Het databasebestand naar een map naar keuze (iCloud Drive), optioneel een tweede map. Een export naar Excel is een leesbare kopie, geen back-up. |
| Later | Excel-historie 2006–2026 (gebouwd, in de wacht), PDF-rapporten, AI-suggesties. |
| Privacy | Geen echte gegevens in de repo, tests of prompts. Testdata is verzonnen. |

## Modules

| Target | Taak | Hangt af van |
|---|---|---|
| `HFCore` | `Money`, `Day`, records, schema en migraties (`AppDatabase`) | GRDB |
| `HFImport` | CSV lezen per bankprofiel, saldoketen, dubbelen, import naar `bankTransaction` | HFCore |
| `HFRules` | Regels toepassen op banktransacties, voorstellen met zekerheid, regelconcept bij een boeking | HFCore |
| `HFBudget` | Schrijven: boeken, splitsen, potten, overboekingen, afstemming, jaar en posten beheren | HFCore |
| `HFInsight` | Lezen: maandgrid, status vaste posten, saldo, besteedbaar, potsaldi, rapportcijfers, zoeken | HFCore |
| `HFBackup` | Back-up en herstel, voorbeelddata, export als CSV en als Excel-bestand per jaar | HFCore |
| `HFHistory` | Eenmalige import van de Excel-historie (in de wacht) | HFCore |
| `HFPublish` | Het dashboard voor de telefoon als bestand | HFCore, HFInsight |
| `HomeFinance` | De SwiftUI-app. Geen rekenlogica in views. | alles |

Modules kennen elkaar niet onderling (`HFInsight` leest alleen en rekent zelf met SQL); alleen de app verbindt ze. Elke module beschrijft zijn publieke API in
`docs/api/<Module>.md`.

## Datamodel

Zie `Sources/HFCore/Records.swift` (records met uitleg) en `Schema.swift` (tabellen). Kern:

- **Account**: betaal of spaar, met beginsaldo en begindatum.
- **BudgetYear**: jaar, `antiRood`, `closed`.
- **BudgetItem**: vaste post in één jaar (rij in het grid): label, richting IN/UIT/RES, planbedrag met teken,
  frequentie, verwachte maanden en dag. Eén post per jaar is `isReserveTotal` (de regel RESERVERINGEN).
- **Pot**: deel van het saldo van een spaarrekening; soort reservering of spaar; optioneel een spaardoel
  (`targetAmount`, `targetDate`, eventueel opgebouwd uit **GoalPart**-regels). Mag negatief staan.
- **Distribution** + **DistributionLine**: een vaste storting van een betaalrekening naar een spaarrekening,
  met de verdeling over potten.
- **ForecastItem**: een verwacht bedrag voor een pot op een datum, optioneel binnen een project.
- **ItemCheck**: een post die voor een maand met de hand is afgevinkt.
- **Settlement**: een verrekening van een tag (bv. Tanken).
- **BankTransaction**: regel van de bank, onveranderlijk. Status nieuw, verwerkt of overgeslagen.
- **Entry** (boeking): bedrag op een rekening, toegewezen aan post of pot. Eén of meer per banktransactie
  (splitsen); zonder banktransactie = handinvoer. `reviewed = false` betekent "nog nakijken".
  `period` = de maand waarin de boeking meetelt als dat een andere is dan de maand van de datum.
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
- **Besteedbaar** = saldo betaalrekening − `antiRood` − tijdelijk geleend van spaar + wat er nog terugkomt van
  verrekentags met "telt mee in nog te besteden" (zie Verrekenen per tag; alleen in het lopende jaar).
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
- Een pot mag in de min staan: hij leent dan van de andere potten. De app toont wanneer hij met de huidige
  stortingen weer op nul staat, en het totaal dat geleend is uit andere potten.
- **Beginbedrag**: een pot krijgt bij het aanmaken een beginbedrag (standaard € 0,00), geboekt als handmatige
  boeking "Beginsaldo …" op de spaarrekening. Beginsaldo rekening = potten + niet toegewezen.
- **Vaste storting**: naam, herkomstrekening (betaal), doelrekening (spaar) en per pot een bedrag. Het totaal is
  de som van de regels. Een post op de betaalrekening kan aan een vaste storting gekoppeld zijn; zijn plan is
  dan altijd min het totaal. Er kunnen meer vaste stortingen zijn. Dit vervangt het maandbedrag per pot en de
  RES-regels als bron van de verdeling.
- **Herkennen**: een banktransactie tussen de herkomst- en doelrekening van een vaste storting wordt aan beide
  kanten herkend aan de tegenrekening. Op de spaarrekening is het voorstel de verdeling over de potten; op de
  betaalrekening de gekoppelde post. Wijkt het bedrag af, dan toont de app het verschil en kiest de gebruiker.
- **Spaardoel**: doelbedrag en doeldatum. Nodig per maand = (doel − saldo − verwachte losse bedragen) gedeeld
  door het aantal stortmomenten tot de doeldatum. Daarnaast: wat er nu per maand gestort wordt, of het doel
  gehaald wordt, en op welke datum.
- **Vooruitblik**: het verwachte saldo van een pot in de tijd = het echte saldo + de terugkerende stortingen uit
  de vaste stortingen + de losse verwachtingen (`ForecastItem`). De storting van de lopende maand telt alleen
  mee als hij nog niet binnen is. Een losse verwachting wordt afgevinkt als hij is uitgekomen. Verwachtingen
  tellen nergens anders in mee. Verwachtingen met hetzelfde project vormen een begroting: gepland, betaald,
  nog te komen.
- **Overboeking tussen eigen rekeningen**: twee banktransacties met tegengesteld bedrag, waarvan de
  tegenrekening de andere eigen rekening is, binnen 3 dagen. De boekingen worden aan elkaar gekoppeld
  (`counterEntryId`). Ze tellen op elke rekening gewoon mee in het saldo.

### Verrekenen met spaar
- Een boeking op de betaalrekening kan gemarkeerd worden om met een pot verrekend te worden (`reimburse` +
  `potId`): een uitgave "komt uit de pot", een bijschrijving "gaat naar de pot".
- Openstaand = alle gemarkeerde boekingen die nog niet in een verrekening zitten. Het saldo is netto: uit potten
  min naar potten. Positief = over te maken van spaar naar betaal; negatief = van betaal naar spaar; nul = alleen
  verschuiven tussen potten.
- **Afvinken boekt meteen**: per pot een boeking op de spaarrekening en één tegenboeking op de betaalrekening,
  aan elkaar gekoppeld. De administratie klopt dus zodra de gebruiker heeft overgemaakt.
- **Bij een latere import** wordt de bankregel herkend (bedrag, tegenrekening, binnen 7 dagen) en aan de
  bestaande verrekening gehangen. Er komt geen nieuwe boeking bij en het saldo verandert niet.
- Een afgevinkte verrekening die na 5 dagen nog niet in een bankbestand is gezien, wordt gemeld.
- Volgorde van herkennen bij nieuwe banktransacties: verrekeningen, dan vaste stortingen, dan regels.
- **Een regel verrekent alleen in één richting** (`Rule.reimburseDirection`: geld erin, geld eruit of beide).
  In de andere richting stelt dezelfde regel de post, de omschrijving en de tags voor, maar géén verrekenen en
  géén pot, met zekerheid laag en een melding (twijfelgeval in Nakijken). Het regelconcept in Nakijken vult de richting
  met die van de transactie waarbij de gebruiker verrekenen koos. Bestaande regels met verrekenen kregen bij migratie v9 de
  richting van hun laatste boeking met verrekenen, en zonder zo'n boeking "geld erin" (alleen bijschrijving)
  als veilige keuze. Aanleiding: een regel op de rekening van een kind, geleerd van geld dat binnenkwam voor
  haar spaarpot, haalde ook zakgeld dat naar het kind ging van die spaarpot af.

### Verrekenen per tag
- Een tag kan "verrekenen" hebben (bv. Tanken): uitgaven met die tag stort de gebruiker later terug op de
  betaalrekening. Openstaand = − de som van de boekingen met die tag zonder verrekening, vanaf de startdatum.
- Een verrekening legt vast welke boekingen zijn afgerekend en koppelt optioneel de terugstorting.
- **Startbedrag** (6g): wat er bij de start van de app al openstond (voorgeschoten in de Excel-periode), met een
  dag. Het telt mee in het openstaande bedrag en gaat bij het verrekenen mee als een openstaande post. Na het
  verrekenen is het niet meer te wijzigen, tot die verrekening ongedaan is gemaakt.
- **Telt mee in nog te besteden** (6g), per tag, standaard uit: het openstaande bedrag van de tag telt mee als
  verwachte inkomst in "besteedbaar nu" en "nog te besteden deze maand". Het Dashboard toont het als aparte
  regel. Beide instellingen staan bij Instellingen › Tags, onder "Verrekenen" (migratie v10).

### Begrotingsmaand en afvinken
- Een boeking telt voor de begroting in de maand van zijn `period`, of anders in de maand van zijn datum. De
  periode mag hoogstens twee maanden van de datum afliggen. Het saldo van de rekening volgt altijd de datum.
- Een vaste post kan voor een maand met de hand worden afgevinkt. Zonder boeking is de status dan `afgevinkt`:
  hij telt als voldaan, niet als open of te laat, en niet in "nog verwacht deze maand".

### Maandbalans en wat-als
- Maandbalans = geplande inkomsten per maand min geplande uitgaven per maand; kwartaal- en jaarposten naar rato.
- Per post kan een wat-als-bedrag worden ingevuld. De wat-als-balans gebruikt dat bedrag waar het is ingevuld en
  anders het plan. Er verandert niets aan de begroting tot de gebruiker er het nieuwe plan van maakt.

### Omschrijvingen
- De omschrijving van een boeking komt uit de regel of van de gebruiker; de tekst van de bank blijft bewaard.
- Totalen per omschrijving: losse boekingen gegroepeerd op genormaliseerde omschrijving.
- Bij het typen vult de app bestaande omschrijvingen aan en meldt hij een bijna-gelijke schrijfwijze. Dubbele
  schrijfwijzen kunnen worden samengevoegd.

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
8. **Eerste import van een rekening** (nog geen banktransacties): de app zoekt de regel waarvan het saldo vóór
   de mutatie gelijk is aan het saldo in de administratie. Alles ervoor wordt overgeslagen en telt als "al
   bekend". Wordt geen regel gevonden, dan valt de app terug op de begindatum en kiest de gebruiker per regel.
9. Geïmporteerde transacties blijven in de wachtrij staan tot ze geboekt of overgeslagen zijn, ook na het
   sluiten van de app.

### Regels
Zekerheid en volgorde:
1. Tegenpartij (naam of IBAN) **en** bedrag kloppen → `hoog`.
2. Tegenpartij klopt, regel heeft geen bedrag of het bedrag wijkt af → `midden`.
3. Trefwoord in de omschrijving → `midden`.
4. Alleen bedrag → `laag`.
5. Geen regel → `geen`.

Binnen dezelfde zekerheid wint de laagste `priority`, daarna de meest specifieke regel.

**Regels alleen met toestemming** (sinds 21 november, 6i). Boeken maakt of wijzigt nooit vanzelf een regel.
- Geen regel deed een voorstel: in Nakijken staat "Onthoud als regel", standaard uit. Aangevinkt toont het één
  samenvattingszin ("Voortaan bij X: post …, verrekenen met pot … bij geld eruit, omschrijving '…'") en
  "Aanpassen…" (de regeleditor, voorgevuld). Het concept: voorwaarde op de tegenpartij (IBAN, anders naam,
  anders een trefwoord uit een herkenbare omschrijving), een bedrag erbij als het doel een vaste post is en
  tegenpartij en bedrag al eerder voorkwamen, en als acties de keuze (post, pot, verrekenen met richting,
  omschrijving, tags). De regel wordt bewaard bij het boeken, precies zoals getoond.
- Een regel deed een voorstel en de keuze wijkt af: "Regel bijwerken met deze keuze", standaard uit. Aan: die
  regel krijgt de nieuwe acties, zijn voorwaarden blijven. Uit: de boeking is een uitzondering, de regel blijft.
- De keuze is gelijk aan het voorstel: geen vinkje; de regel telt als gebruikt (`hitCount`, `lastUsed`).
- Bij "Waarom dit voorstel?" opent "Regel aanpassen…" de voorstellende regel in de editor.
- Een regel met alleen een bedrag kan zo niet ontstaan (de editor eist een voorwaarde; het concept heeft altijd
  een tegenpartij of trefwoord). Transacties maakt geen regels.

## Schermen

Zijbalk: Transacties (startscherm, als een bank-app) · Importeren en nakijken · Dashboard · Maandgrid · Potten en
sparen · Verrekenen met spaar · Rapporten · Regels · Instellingen (jaar en posten, rekeningen, tags, back-up,
telefoon, over).

Uitgangspunt: de eerste aanblik van elk scherm is rustig; details staan achter een klik. Alleen het maandgrid is
compact. Bedragvelden accepteren ook een som (249*4).

## Testen

Swift Testing, per module een eigen testtarget, met een database in het geheugen (`AppDatabase.inMemory()`).
Rekenregels krijgen tests met uitgewerkte, verzonnen voorbeelden.

## Aannames en beperkingen

- De uitleg van "t.o.v. maandbudget" hierboven.
- De app draait alleen op de eigen Mac, zonder App Store en zonder sandbox.
- De schermen zijn gebouwd en op schermafbeeldingen bekeken, maar niet systematisch met de hand getest.
- Een developer reviewt de code voordat de app de enige administratie wordt; tot dan draait de Excel mee.
