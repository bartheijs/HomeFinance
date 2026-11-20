# Voortgang en openstaand werk

*Bijgewerkt op 20 november 2026. Dit bestand is het overdrachtspunt voor de volgende werksessie.*

## Stand op 20 november 2026

- De gebruiker draait sinds 8 november parallel met Excel. Bij de volgende import werkt hij
  `docs/checklist-volgende-import.md` af. De tijdlijn van de bouw staat in `docs/tijdlijn.html`.
- Alles wat in de tabel hieronder "klaar" heet, is gebouwd en gepusht t/m commit `20dcbfd`. Het werk van vandaag
  (hieronder) is nog niet gecommit.
- 464 tests in 82 suites, allemaal groen. De app staat in de map Apps.

**Vandaag gedaan**

- Alle schermen nagelopen op schermafbeeldingen: licht, donker en in het kleinste venster (1100 × 700). Hersteld:
  - Rapporten: bij "Budget tegen werkelijk" en "Diverse uitgaven" liep de rij tabbladen buiten het venster en
    schoof het hele scherm opzij. De knoppen van zo'n rapport staan nu onder de tabbladen. In een smal venster
    worden de tabbladen een keuzemenu.
  - Instellingen: in een smal venster brak de titel af ("Instellin-gen"). De tabbladen komen dan onder de titel.
  - De oude naam "Spaaroverboekingen" stond nog op tien plekken (knoppen, uitleg, twee foutmeldingen). Het is
    overal "Verrekenen met spaar".
  - Engels "Trackingcategorieën" vervangen door Nederlandse uitleg (Instellingen › Tags).
  - Te lichte grijze bijschriften leesbaarder gemaakt (Potten, Rapporten › Per omschrijving, Maandgrid, Tags).
- Voorbeelddata uitgebreid (versie 2):
  - per kind spaargeld, kleedgeld en zakgeld als potten;
  - het spaardoel "Studie en rijbewijs", opgebouwd uit onderdelen, met een tag per kind voor de rijlessen;
  - vaste stortingen, zodat spaardoelen en de vooruitblik echte maandbedragen tonen;
  - een vooruitblik voor de rentepot "Rente privélening".

  Een voorbeelddatabase van een oudere versie vult de app vanzelf opnieuw. Dat geldt alleen voor het
  voorbeeldbestand, nooit voor de eigen administratie.
- Telefoondashboard nagekeken met voorbeelddata, op 375 punten breed, licht en donker. Het hoofdgetal is nu
  "Nog te besteden deze maand", net als op het Dashboard van de Mac, met "Besteedbaar nu" eronder. Geen
  horizontaal schuiven. De tweede back-upmap is goed aangesloten: hij wordt gebruikt bij afsluiten (als
  "Back-up maken bij afsluiten" aan staat) en bij "Maak nu back-up".
- Hulpje voor het nalopen: `HomeFinance --snapshot <map>` schrijft ook `telefoon.html`. Met `--size 1100x700` teken
  je op een andere venstergrootte.

**Openstaand:** zie "Nog te doen, in volgorde" en "Grotere schermpunten" hieronder.

## Stand per onderdeel

| Onderdeel | Stand |
|---|---|
| Importeren met naad op saldo (`HFImport`) en importvenster | Klaar, 71 tests. In gebruik: de eerste import van de gebruiker (14 november) sloot aan op het beginsaldo. |
| Nakijken, boeken, regels die bijleren (`HFRules`, `HFBudget`) | Klaar en in gebruik. Tags direct zichtbaar en aan te maken bij nakijken (16 november). |
| Vaste storting met verdeling en herkenning | Klaar, met scherm (Potten › Vaste stortingen). |
| Potten: beginbedrag, in de min, spaardoel (ook uit onderdelen), vooruitblik met projecten | Klaar, met schermen. |
| Verrekenen met spaar (twee richtingen, boekt bij afvinken, bankregel hangt er later aan) | Klaar, met scherm. Open verrekeningen tellen mee in "nog te besteden". Na een sluitende import stemt de app vanzelf af. |
| Verrekenen per tag (Tanken) | Klaar: schakelaar "Verrekenen" bij Instellingen › Tags, acties bij Transacties en Nakijken. |
| Totalen per omschrijving, aanvullen bij typen, bijna-dubbelen, samenvoegen | Klaar: Rapporten › Per omschrijving (met samenvoegen) en aanvullen in de omschrijvingsvelden van Transacties en Nakijken. |
| Begrotingsmaand ("telt mee in"), post afvinken, maandbalans met wat-als, export naar Excel, rekenen in bedragvelden | Klaar. |
| Dashboard met "Nog te besteden deze maand" als hoofdgetal | Klaar (16 november). Meldingen over verrekeningen zonder bankregel staan in één regel. |
| Telefoondashboard (`HFPublish`, tabblad Telefoon, tweede back-upmap) | Klaar, 17 tests. Nagekeken op 20 november met voorbeelddata (375 punten, licht en donker). Nog niet op een echte iPhone geopend. |
| Voorbeelddata (`HFBackup`) | Versie 2 (20 november): potten per kind, spaardoel uit onderdelen met tags per kind, vaste stortingen, vooruitblik rentepot. 42 tests in de module. |
| Regels leren uit Excel-historie en bankexport (`HistoryRuleSeeder`) | Module klaar, 63 tests in `HFRules`. De knop in het scherm Regels ontbreekt nog; die hangt aan de historie-import. |
| Excel-historie importeren (`HFHistory`) | In de wacht (besluit 14 november). Gebouwd, 50 tests op nagebootste bestanden. **De proefdraai op de echte Excels is mislukt; er is niets geïmporteerd.** De oplossing staat hieronder; de code is nog niet aangepast. |
| Tijdlijn van de bouw als HTML-pagina | Klaar: `docs/tijdlijn.html`. |
| Checklist voor de volgende import | Klaar: `docs/checklist-volgende-import.md`. |

## Nog te doen, in volgorde

1. **De volgende import** met de checklist (gebruiker). De afwijkingen terugmelden; daarna herstellen wat niet
   klopt.
2. **Beslissen** wat er vanaf december gebeurt met de kindgerelateerde posten (kindgebonden budget, zang- en
   dansles): aanpassen of laten vervallen (gebruiker, uit de checklist).
3. **Nagaan** of de 6 reserveringsregels die op 14 november nog niet aan een pot gekoppeld waren, inmiddels
   gekoppeld zijn (gebruiker; niet in de code te zien).
4. **Telefoondashboard aanzetten** bij Instellingen › Telefoon (map kiezen) en de pagina op de iPhone openen
   (gebruiker).
5. **Met de hand testen** wat op schermafbeeldingen niet te zien is: klikken, vensters en slepen. Bijvoorbeeld
   de popover en het dubbelklikken in het maandgrid, het detailpaneel van een pot met de vooruitblik, de vensters
   Vaste stortingen, Nieuwe pot en Splitsen.
6. **Grotere schermpunten** hieronder oppakken, als de gebruiker dat wil.
7. **Excel-historie** (in de wacht): `HFHistory` aanpassen volgens de oplossing hieronder, proefdraaien, pas
   importeren als de jaren kloppen. Daarna de knop "Leer regels uit bankhistorie" in het scherm Regels.
8. **Code-review** door een developer voordat de app de enige administratie wordt (zie de spec).
9. Het werk van 20 november committen (de gebruiker beslist).

## Grotere schermpunten (nalopen van 20 november)

Niet hersteld omdat het een keuze in de vormgeving is of meer werk dan een kleine reparatie:

- **Maandgrid:** de bedragen van toekomstige maanden en de nog open bedragen staan in licht, cursief grijs. Dat
  is bewust, maar ze zijn slecht leesbaar, in donker nog iets meer dan in licht. Overwegen ze iets donkerder te
  maken.
- **Rapporten, grafieken:** het bedrag boven een staaf valt soms op de stippellijn van het gemiddelde (bv.
  "€ 134" en "€ 115" bij Tanken).
- **Rapporten › Per omschrijving:** lange namen worden in de lijst afgekapt ("Restaurant De Verzonnen…"). De
  volledige naam staat rechts boven het detail en verschijnt bij aanwijzen.
- **Smal venster (1100 punten):** in Importeren en nakijken worden namen in de lijst afgekapt ("Tuincentru…"); het
  detail rechts toont de volledige naam.
- **Twee namen voor hetzelfde:** het rapport heet "Categorieën", de instelling "Tags". Kies één woord.
- **Telefoon:** de spaarpotten staan niet per persoon gegroepeerd zoals op de Mac, en met veel potten wordt de
  pagina lang. Het onderdeel "Potten" kan bij Instellingen › Telefoon uit.
- **Voorbeeldmodus:** uitgeschakelde knoppen (Telefoon, Back-up) zijn nauwelijks leesbaar. Dat is de stijl van
  macOS; met de eigen administratie zijn ze gewoon aan.
- **Schakelaars** (Regels, "Wat als…") tonen op de schermafbeeldingen geen accentkleur, aan of uit zie je alleen
  aan het knopje. Waarschijnlijk komt dat doordat het venster bij de opname niet actief was. Live controleren.

## Proefdraai Excel-historie: wat er misging en hoe het moet

De lezer stemt voor 17 van de 18 jaren niet overeen met de totalen in de bladen. Oorzaken, vastgesteld op de
echte bestanden (alleen structuur en sommen bekeken):

1. **Rijen zonder omschrijving zijn echte boekingen.** De lezer slaat een rij zonder tekst in kolom A over als
   "totaalrij". In 2026 zijn dat twee gewone regels; samen precies het verschil in het eindsaldo.
   Een totaalrij herken je aan formules in de maandcellen, niet aan een leeg label.
2. **De bladen tellen per blok, niet op teken.** `IN` en `UIT` in het saldoblok zijn `SUM`-formules over vaste
   bereiken. Een positief bedrag in het UIT-blok telt bij UIT, een negatief bedrag in het IN-blok bij IN.
3. **In oudere jaren tellen ook RES-regels en hulprijen mee.** Tot en met ongeveer 2023 staan er maandbedragen
   in RES-regels en in rijen zonder IN/UIT/RES-voorvoegsel, en die zitten in het UIT-bereik van het blad.
4. **2010 heeft geen formules** in het saldoblok, alleen waarden.

**De oplossing:** laat de formules van het blad bepalen wat meetelt. Lees de `SUM`-bereiken uit de cellen `IN`
en `UIT` van het saldoblok. Elke cel met een getal (geen formule) binnen die bereiken is een boeking: binnen het
IN-bereik hoort hij bij inkomsten, binnen het UIT-bereik bij uitgaven. Of het een vaste post of een losse regel
is volgt uit de plek (boven `Totaal` of in een Various-sectie). Voor alle jaren met formules (2009, 2011–2026)
is gecontroleerd dat de som van die bereiken exact gelijk is aan de waarde in het blad. Cellen buiten de
bereiken (totaalrijen, herhaalde maandkoppen) tellen niet mee. Voor 2010 blijft de huidige werkwijze de
terugvaloptie.

Daarna: proefdraai opnieuw. Pas importeren als de jaren kloppen. Proefdraai-hulpje: een los pakketje dat
`HomeFinanceKit` gebruikt en `HistoryWorkbook.readBudget(url).summary(today:)` afdrukt (buiten de repo).

## Bekende beperkingen

- De schermen zijn op schermafbeeldingen nagelopen (licht, donker, kleinste venster). Klikken, vensters en
  slepen zijn nog niet met de hand getest.
- Datum en maandkolom: de app leidt de maand af uit de datum. Een paar Excel-regels staan bewust in een
  naastgelegen maandkolom en vallen in de app dus in een andere maand. Met "telt mee in" kan een boeking in een
  andere maand meetellen.

## Eerder

### 16 november 2026

- Dashboard: "Nog te besteden deze maand" (besteedbaar eind van de maand) is het hoofdgetal; "Besteedbaar nu" staat eronder.
- Administratie van de gebruiker hersteld (met kopie `homefinance-voor-herstel-november.sqlite`): 11 posten voor
  november afgevinkt die vóór de start op 8 november betaald waren, 3 posten afgevinkt als "vervalt in november"
  (kindgebonden budget, schoonmaak, zang- en dansles), kinderbijslag op € 283,33 per maand (€ 850 / 3) op zijn
  verzoek: telt zo in het maandoverzicht en in de forecast.
- Vergelijking met de Excel van de gebruiker: saldi en alle 35 potten gelijk aan zijn Excel (2). "Nog te besteden" in
  november wijkt € 448,25 af van zijn Excel-forecast: + € 283,33 kinderbijslag per maand, + € 187,50 rente-reservering
  die in de Excel apart op de betaalrekening staat (in de app hoort die in een pot op spaar; nog niet overgemaakt),
  − € 22,58 werkelijke tegen geplande bedragen.
- De open punten van die dag zijn klaar (commit `9cba8b0`): open verrekeningen met spaar tellen mee in "nog te
  besteden", de voorbeelddata heeft bankregels bij de verrekeningen en de meldingen staan in één regel.

### 14 november 2026, einde van de dag

- De gebruiker is gestart: 2 rekeningen, 31 posten, 35 potten met beginbedrag en een vaste storting staan in zijn
  administratie; de eerste bankimport sloot aan op het beginsaldo (betaal: 13 nieuw; spaar: 4 nieuw).
- Gebouwd en getest (435 tests): vaste storting met herkenning, pot met beginbedrag, spaardoel (ook uit
  onderdelen), vooruitblik met projecten, potten in de min, afvinken, begrotingsmaand, verrekenen per tag,
  verrekenen met spaar (twee richtingen, boekt bij afvinken), totalen per omschrijving met aanvullen en
  samenvoegen, maandbalans met wat-als, export naar Excel, rekenen in bedragvelden, telefoondashboard.
- Wat die dag nog openstond: de tijdlijn (klaar), voorbeelddata met de nieuwe onderdelen (klaar op 20
  november) en de schermen nalopen (op schermafbeeldingen klaar op 20 november; met de hand nog niet). De
  reserveringsregels zonder pot, de historie-import en de knop "Leer regels uit bankhistorie" staan hierboven
  bij "Nog te doen".

### Koerswijziging 14 november 2026

- **Start met alleen beginstanden**, geen historie. De gebruiker richt zelf in (posten, potten met beginbedrag)
  om de app te leren kennen. De historie-import staat in de wacht; de oorzaak van de mislukte proefdraai en de
  oplossing staan hierboven en blijven geldig voor later.
- **Vaste storting met verdeling** wordt een eigen instelling (naam, potten met bedrag, totaal); er kunnen er
  meer zijn. Vervangt het maandbedrag per pot en de RES-regels als bron van de verdeling.
- **Een post voor een maand met de hand afvinken** als voldaan.
- **Een boeking kan in een andere maand meetellen** dan zijn datum (`Entry.period`); het saldo volgt de datum.
- Uitgevoerd: schema v4 tot en met v8, de logica in `HFBudget` en `HFInsight` en de schermen.

### Besluiten van 13 november 2026

- Overgang van Excel naar de app per **8 november 2026** (laatste boeking in de Excel). Daarna schaduwdraaien.
- De Excel bevat alleen echte bedragen; vooruit ingevulde verwachtingen haalt de gebruiker altijd weer weg.
- De naad tussen Excel-historie en bank wordt op **saldo** gezocht, niet op datum.
- "Gereserveerd" op de betaalrekening is vervallen; dat geld gaat naar een pot op de spaarrekening.
- "Tijdelijk anti-rood" volgt uit boekingen met de markering *tijdelijk geleend van spaar*.
- Back-up naar iCloud Drive; dashboard voor de telefoon als bestand in een cloudmap (geen hosting).
