# Voortgang en openstaand werk

*Bijgewerkt op 21 november 2026. Dit bestand is het overdrachtspunt voor de volgende werksessie.*

## Terug naar de code van 16 november (21 november 2026)

- **Testvangnet (ronde 1)**: `scripts/testronde.sh`. De orchestrator draait het na elke wens op een kopie van de
  echte administratie. De basis met kerncijfers staat buiten de repo, bij de gebruiker lokaal in
  `~/Library/Application Support/HomeFinance/testronde/` (eerste basis: `basis-ronde1-5a8410b.json`; vanaf 6g: `basis-ronde11-6g.json`, met de tagvelden erbij).

- Na installatie van `16b21a1` werkte de app niet goed bij de gebruiker (lege zijbalk, startpagina zonder kop).
  Oorzaak niet gevonden. Op verzoek van de gebruiker is de **code teruggezet naar `9cba8b0`** (16 november),
  de versie waarin hij al zijn werk deed. De documentatie (deze voortgang, checklist, tijdlijn) blijft.
- Wat daarmee uit de code is gegaan en **opnieuw, één voor één** gebouwd wordt, elk met een testronde bij de
  gebruiker (echte app starten, niet alleen tests en snapshots):
  - uit `70cab3b` (20 november): schermfixes (smal venster, "Verrekenen met spaar" overal, leesbaarheid),
    voorbeelddata versie 2, telefoondashboard met "Nog te besteden deze maand", snapshot `--size`;
  - uit `16b21a1`: 6a, 6b, 6c (zie hieronder).
- Bewaard: de oude commits in de geschiedenis, en het onderbroken diagnosewerk op branch
  `wip/diagnose-zijbalk` (startoptie `--database`, logging).
- Let op: de gebruiker meldde dat ook de versie van 16 november soms dezelfde lege zijbalk toont. Na elke
  bouwronde dit expliciet laten controleren.

## Testvangnet, ronde 1 (21 november 2026, nog niet gecommit)

Twee gaten gedicht: de echte app werd nooit gestart, en niemand controleerde of een nieuwe versie met de echte
gegevens hetzelfde rekent. Uitleg voor de gebruiker staat in de README ("Een testronde na elke wijziging").

- **`scripts/testronde.sh --uit <map>`**: bouwt, draait `swift test`, start de echte app met voorbeelddata voor de
  zelftest en schrijft de kerncijfers. Eindigt met TOTAAL: GESLAAGD of NIET GESLAAGD.
- **Op een kopie** (alleen de orchestrator draait dit, nooit een bouwsessie):
  `scripts/testronde.sh --uit <nieuwe map> --database <kopie.sqlite> --basis <vorige map>/kerncijfers-kopie.json`.
  Het script werkt op eigen kopieën in de uitvoermap; het opgegeven bestand verandert niet. Verschillen met de
  basis staan per veld als `oud → nieuw` in `verschillen.txt`. De eerste keer zonder `--basis`: die ronde levert
  de basis.
- **Zelftest** (`--zelftest <log>`, `App/SelfTest.swift`): opent de echte `NavigationSplitView` (niet de
  snapshot-zijbalk), kiest elk scherm via `model.selection` en logt per controle OK/FOUT: zijbalk met 9 regels
  (in SwiftUI én als getekende rijen in AppKit, ook nog na de ronde), elk scherm binnen 5 s, geen
  `errorMessage`, geen fouten in `model.read`/`perform`. Harde limiet 90 s op een eigen thread.
  Aangetoond: met het Regels-scherm tijdelijk weggehaald faalt hij (exitcode 1, "FOUT scherm rules").
- **Kerncijfers** (`--kerncijfers <json> [--dag]`, `Insight.keyFigures`): platte, gesorteerde lijst met saldo per
  rekening (en saldo volgens de app tegen het eindsaldo van de laatste import), saldo per pot, besteedbaar nu,
  nog te besteden deze maand, aantallen boekingen en banktransacties per status, open verrekeningen netto en
  afgevinkte posten per maand. 8 tests.
- **Gevonden bij het bouwen:** met een bestandspad op de opdrachtregel (zoals `--database <pad>`) opende de app
  géén venster: AppKit zag het pad als document om te openen. Bij testruns staat dat nu uit
  (`NSTreatUnknownArgumentsAsOpen`). Waarschijnlijk niet de oorzaak van de lege zijbalk bij de gebruiker (die start
  zonder opties), maar wel een verklaring voor vreemd gedrag bij eerder diagnosewerk met `--database`.
- Overgenomen van `wip/diagnose-zijbalk`: alleen het idee van `--database`/`--voorbeeld` (opnieuw geschreven,
  met weigering van de echte map). De `--log`/hartslag-diagnose is niet overgenomen.

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

**21 november (nog niet gecommit)**

- **6a, downloadinstructie op Transacties.** Onder de rekeningen staat een rustig blok: download de CSV-export
  (zip, één bestand per rekening) van welke rekeningen, en van welke dag tot en met vandaag. De begindag is de
  vroegste laatste banktransactie over alle rekeningen; die dag zit er bewust nog in, overlap kan geen kwaad.
  Zonder eerdere import: vanaf de startdatum van het beginsaldo. Aanwijzen toont per rekening de laatste
  banktransactie. Berekening: `Insight.downloadAdvice` (5 tests).
- **6b, voorgestelde omschrijving slim kiezen.** Bij een overboeking met een korte eigen tekst ("Zakgeld") stelt
  de app die tekst voor; bij pin, incasso, iDEAL, gestructureerde, zakelijke of lange teksten de tegenpartij.
  Een omschrijving uit een regel gaat altijd voor. Regels matchen precies als eerst; een geleerde regel legt de
  eigen tekst niet vast, zodat elke overboeking haar eigen tekst houdt. `LabelCleaner.suggestedLabel` (26 testgevallen).
- **6c, potten op alfabet in alle pot-kiezers** (Nakijken, Transacties, verrekenen, Regels, Vaste stortingen,
  Instellingen › Jaar, Potten, Verrekenen met spaar): per groep op alfabet, Nederlandse sortering. Eén functie:
  `Insight.pickerOrder`.
- 477 tests in 84 suites, allemaal groen. Schermen nagekeken met `--snapshot` (voorbeelddata). De open
  keuzelijsten zelf zijn op schermafbeeldingen niet te zien; de volgorde is met een test gedekt.

**Openstaand:** zie "Nog te doen, in volgorde" en "Grotere schermpunten" hieronder.

## Stand per onderdeel

| Onderdeel | Stand |
|---|---|
| Importeren met naad op saldo (`HFImport`) en importvenster | Klaar, 71 tests. In gebruik: de eerste import van de gebruiker (14 november) sloot aan op het beginsaldo. |
| Nakijken, boeken, regels (`HFRules`, `HFBudget`) | Klaar en in gebruik. Tags direct zichtbaar en aan te maken bij nakijken (16 november). Regels alleen met toestemming ("Onthoud als regel", 6i, 21 november). |
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
6a, 6b en 6c (wensen van 21 november) zijn gebouwd op 21 november; zie "21 november" hierboven. **Maar zie
   "Let op" bovenaan: die versie werkte niet bij de gebruiker en is teruggedraaid.**
6a. **Downloadinstructie op Transacties** — opnieuw gebouwd, klaar (21 november), nog niet geïnstalleerd.
   Onder de rekeningkaarten staat één rustig blok: "Bijwerken: download bij de bank de CSV-export (zip, één
   bestand per rekening) van … , van … tot en met …", met daaronder waar de begindag vandaan komt en dat overlap
   geen kwaad kan (dubbele regels worden overgeslagen). Begindag: de vroegste laatste banktransactie over alle
   niet-gearchiveerde rekeningen (die dag bewust als overlap); zonder eerdere import de startdatum van het
   beginsaldo. Aanwijzen toont per rekening de laatste banktransactie.
   Verschil met de versie uit `16b21a1`: rekenwerk én teksten zitten in `HFInsight/DownloadAdvice.swift`
   (6 tests in `DownloadAdviceTests`); de view is gewone tekst die over meer regels afbreekt, zonder
   `.fixedSize` (die kon in een laag venster de kop van het scherm boven uit beeld duwen; niet bewezen als
   oorzaak van de eerdere storing). De zelftest controleert nu op Transacties, op de huidige én de kleinste
   venstermaat (1100 × 700), dat de kop onder de werkbalk zichtbaar is, dat het downloadblok in beeld staat
   en dat het onder de kop staat (meetpunt `.selfTestProbe`, doet buiten de zelftest niets).
   Testronde met voorbeelddata: GESLAAGD (498 tests, zelftest 31 OK). Nog: testronde op een kopie, installeren,
   en de gebruiker laten kijken naar de kop van Transacties en de zijbalk.
6b. **Voorgestelde omschrijving slim kiezen** — opnieuw gebouwd, klaar (21 november), nog niet geïnstalleerd.
   Bij een overboeking met een korte, eigen tekst ("Zakgeld") stelt Nakijken (en Transacties) die tekst voor; bij
   pin, geldautomaat, incasso, iDEAL (transactiecodes als BEA, GEA, INC, IDB), gestructureerde tekst (`/…/`,
   "Naam:", kenmerken, factuurnummers, lange rijen cijfers), zakelijke woorden of een lange tekst de tegenpartij.
   Een omschrijving uit een regel gaat altijd voor. Regels matchen precies als eerst.
   Ingepast in 6i ("Onthoud als regel"):
   - Laat de gebruiker de eigen tekst staan, dan legt het regelconcept géén vaste omschrijving vast; elke
     volgende overboeking houdt haar eigen tekst. De samenvattingszin noemt dan geen omschrijving.
   - Kiest de gebruiker bewust iets anders (ook de naam van de tegenpartij bij een overboeking), dan komt dat
     in de regel en in de zin ("omschrijving 'J. Voorbeeld'").
   - Wijzigt de gebruiker bij een bestaande regel alleen de post, dan blijft de omschrijving van die regel staan
     (`applyChoice` met lege omschrijving = voorstel overgenomen). Vervangt hij de omschrijving van de regel
     door de eigen tekst, dan legt de bijgewerkte regel geen omschrijving meer vast.
   - Regeleditor: het lege veld Omschrijving toont "eigen tekst of tegenpartij", met uitleg in de hulptekst.
   - Het kopje rechts in Nakijken blijft de tegenpartij tonen (wat is het); het veld Omschrijving de eigen tekst.
   `LabelCleaner.suggestedLabel` (logica als in `16b21a1`), 31 testgevallen in `SuggestedLabelTests`. Het oude
   `learn` is niet aangepast (de app gebruikt het niet meer).
   Testronde met voorbeelddata: GESLAAGD (508 tests, zelftest 31 OK). Nog: testronde op een kopie, installeren,
   en de gebruiker laten kijken bij een overboeking met een eigen tekst en bij "Onthoud als regel".
6c. **Potten op alfabet in alle pot-kiezers** — opnieuw gebouwd, klaar (21 november), nog niet geïnstalleerd.
   In elke keuzelijst met potten staan binnen de groepen (Reserveringspotten, Spaarpotten) de potten op
   alfabet, hoofdletterongevoelig en op Nederlandse sortering; "Nee", "Geen pot" en "Kies een pot" blijven
   bovenaan. Eén functie: `Insight.pickerOrder` (`HFInsight/PickerOrder.swift`, 6 tests in `PickerOrderTests`).
   De schermen sorteren bij het laden van hun gegevens, niet in de views: Transacties (`TransactionsLookups`,
   dus ook filter, detail, nieuwe boeking, splitsen, verrekenen en het menu "Pot"), Nakijken (`ReviewStore`),
   Regels en de regeleditor (`RulesData`), Instellingen › Jaar (`SettingsYearData`), Vaste stortingen
   (`PotsDistData`), Verrekenen met spaar (`ReimbData.potChoices`) en bij Potten het menu bij boekingen zonder
   pot en "Verplaats naar andere pot" (`PotsData.pickerPots`). Het overzicht Potten en sparen (per persoon)
   en de lijst per pot bij Verrekenen met spaar zijn niet veranderd.
   Verschil met `16b21a1`: de databasequery's zijn ongewijzigd (ook op het startscherm Transacties); er wordt
   alleen achteraf in het geheugen gesorteerd. De zelftest controleert zelf (los van `pickerOrder`) dat de
   pot-kiezers van Transacties en Nakijken laden met per soort alfabetische potten en logt alleen het aantal en
   "volgorde OK/FOUT". Aangetoond: zonder de sortering op Transacties faalt de zelftest.
   Testronde met voorbeelddata: GESLAAGD (514 tests, zelftest 33 OK). Nog: testronde op een kopie, installeren,
   en de gebruiker een paar pot-kiezers laten openen (Transacties, Nakijken, Regels).
6e. **Vaste storting niet herkennen bij een heel ander bedrag** — klaar (21 november), nog niet geïnstalleerd.
   Wat er gebouwd is: `DistributionService.recognize` stelt aan de spaarkant geen verdeling meer voor als het
   bedrag minder dan de helft of meer dan anderhalf keer het totaal van de storting is (`isFarFromTotal`); het
   wordt een twijfelgeval "lijkt een losse overboeking" (`looksSeparate`). Bij een kleiner verschil blijft de
   verdeling met "verschil naar". In Nakijken kan de gebruiker bij een herkende storting aan de spaarkant altijd
   wisselen: "Niet de vaste storting: één pot kiezen" en "Toch de vaste storting …". Aan de betaalkant staat er
   één zin uitleg zodra bij een overboeking met de eigen spaarrekening verrekenen of een pot wordt gekozen
   (`SavingsTransferService.ownSavingsWarning`); boeken blijft mogelijk. Bij Transacties wordt een vermoedelijk
   losse overboeking niet als storting getoond. Tests in `LosseOverboekingTests`.
   Oorspronkelijke melding: Een losse overboeking van
   betaal naar spaar werd aan de spaarkant herkend als de maandelijkse vaste storting (zelfde tegenrekening),
   ook al scheelde het bedrag sterk; het verschil kwam in één pot en alle reserveringspotten kregen hun
   maandbedrag dubbel. `DistributionService.recognize` (doelkant): bij een groot verschil geen verdeling
   voorstellen maar twijfel. En: een pot aan de betaalkant van een overboeking naar spaar niet stilzwijgend
   als "verrekenen met spaar" behandelen (waarschuwen). Data van de gebruiker is met de hand hersteld.
   Ook: de gebruiker vindt het onderscheid niet vanzelfsprekend tussen "verrekenen" (bij de aanleiding: geld
   voor een pot staat op betaal) en de overboeking zelf (geen verrekenen). Waarschuw als bij een overboeking
   naar of van de eigen spaarrekening "Verrekenen met spaar" wordt gekozen, met één zin uitleg.
6f. **Regels met "verrekenen met spaar" kijken naar de richting** — klaar (21 november, nog niet geïnstalleerd).
   Aanleiding: een regel op de rekening van een kind met verrekenen gold ook voor zakgeld dat naar dat kind ging.
   Nu heeft elke regel `reimburseDirection` (geld erin / geld eruit / beide, nieuwe migratie v9). In de andere
   richting stelt de regel post, omschrijving en tags voor, zonder verrekenen en zonder pot, met zekerheid laag
   en een melding: een twijfelgeval in Nakijken. Leren legt de richting vast; zakgeld zonder verrekenen boeken
   laat het verrekenen van de regel voor geld erin staan. Bestaande regels met verrekenen: richting van hun
   laatste boeking met verrekenen, anders "geld erin". Regels waar verrekenen al met de hand uit staat (drie bij
   de gebruiker) veranderen niet. Bij Regels staat in de lijst "verrekenen met spaar bij geld erin", en in de
   editor onder "Verrekenen met spaar" een keuze "Verrekenen bij: geld erin / geld eruit / beide". Details in
   `docs/api/HFRules.md` en de spec (Verrekenen met spaar).
6g. **Startbedrag op een verrekentag, en meetellen in "nog te besteden"** — klaar (21 november), nog niet
   geïnstalleerd of gecommit.
   - Migratie `v10-tag-start-spendable`: op `tag` de kolommen `startAmount` (standaard 0), `startDay`,
     `startSettlementId` en `countsInSpendable` (standaard uit). Bestaande tags: geen startbedrag, telt niet mee.
   - `HFBudget`: `SettlementService.setStart(db, tagId:, amount:, day:)`; `open` geeft ook `start`;
     `settle(..., includeStart:)` neemt het startbedrag mee als openstaande post; `delete` zet het weer open.
     `TagService.setCountsInSpendable`; `update` laat de nieuwe velden staan.
   - `HFInsight`: `TagSettlementSummary` met `openStart` en `countsInSpendable` (startbedrag zit in `outstanding`,
     telt als 1 in `openCount`); `settlementStart`; `SettlementDetail.startAmount`. `Spendable.returningTags` /
     `returningTotal` tellen mee in "besteedbaar nu" en dus ook in "nog te besteden deze maand" (alleen lopend
     jaar). Kerncijfers versie 2: `besteedbaarNu.terugTeKrijgen` en `tag.<id>.openstaand|startbedrag|teltMee`.
   - Schermen: Instellingen › Tags onder "Verrekenen": regel "Startbedrag" (Voeg toe… / Wijzig…, dag voorgesteld
     op de beginstand) en schakelaar "Telt mee in nog te besteden". Verrekenen-sheet toont het startbedrag als
     aan te vinken post; de historie noemt het. Dashboard: regel "+ Komt nog terug: <tag>" met één zin uitleg.
   - De telefoonpagina rekent het mee via `spendable`, maar toont (nog) geen aparte regel; dat kan bij 6l.
     De trendgrafiek (`spendableSeries`) rekent het niet mee.
   - Tests: `SettlementStartTests` (HFBudget, 3), `SettlementStartInsightTests` (HFInsight, 4),
     `TagStartMigrationTests` (HFCore, 1). testronde.sh met voorbeelddata: GESLAAGD (534 tests, zelftest 33 OK).
     De voorbeelddata heeft geen verrekentag; de nieuwe schermdelen zijn niet door de zelftest gedekt en niet met
     de hand in de app geprobeerd.
   - Testronde met een kopie: verwacht als verschillen alleen de nieuwe sleutels (`(ontbreekt) → …`); zolang
     niemand een startbedrag of "telt mee" instelt, blijven `besteedbaarNu` en `nogTeBestedenDezeMaand` gelijk.
6h. **Tags alleen op de betaalrekening, en filteren op tag** — klaar (21 november), nog niet geïnstalleerd of
   gecommit. (Aanleiding: een tag met één boeking op spaar was in Transacties onvindbaar omdat daar de
   betaalrekening geselecteerd stond.)
   - `HFBudget` weigert een tag op een boeking van een spaarrekening met `BudgetError.tagOnSavings` (boeken,
     handmatige boeking, bewerken, `setTags`, verplaatsen naar spaar). Tags die er al stonden blijven staan,
     mogen bij bewerken en opnieuw boeken mee en mogen weg; er komt niets bij. Geen migratie, geen data
     aangeraakt. Nieuw: `EntryService.tagsAllowed(db, accountId:)`.
   - Regels stellen op een spaarrekening geen tag meer voor (`RuleMatcher`).
   - Schermen: bij een spaarrekening is de tagkeuze weg in Nakijken, Transacties (detail, menu's, toets T,
     rechtsklik) en Nieuwe boeking, met de zin "Tags kunnen alleen op boekingen van de betaalrekening." Staat
     er nog een tag van vroeger op een spaarboeking, dan staat die er met "Tag verwijderen" (detail) of
     "Tag ‘…’ verwijderen" (menu's). Splitsen had geen tagkeuze.
   - Instellingen › Tags: "n boekingen" is een link. Die opent Transacties op de betaalrekening (die met de
     meeste boekingen met die tag) met alleen het filter op die tag, alle maanden. Staan er ook boekingen op
     spaar, dan staat eronder "waarvan m op spaar". Logica: `Insight.tagUsage`, `Insight.tagFilterTarget`.
   - Tests: 6 in `TagOnSavingsTests` (HFBudget), 4 in `TagUsageTests` (HFInsight), 1 in `MatchingTests`;
     één bestaande verrekentest zet zijn spaar-tag nu rechtstreeks in de database. Testronde met
     voorbeelddata geslaagd (526 tests, zelftest 33 OK).
   - Nog te doen door de orchestrator: testronde op een kopie, installeren; de gebruiker de link bij
     Instellingen › Tags laten proberen en kijken hoeveel tags er nog op spaar staan.
6i. **Regels alleen met toestemming en aan te passen vanuit Nakijken** — klaar (21 november, nog niet
   geïnstalleerd). De app leert niet meer stil: boeken in Nakijken en in Transacties (boeken, toewijzen aan een
   post of pot) maakt of wijzigt geen regel meer.
   - Nakijken: onder "Waar hoort dit bij?" staat het vinkje "Onthoud als regel", **standaard uit**. Aan: één
     samenvattingszin uit `RuleEngine.summary` ("Voortaan bij Stichting X: post Divers, verrekenen met pot Y bij
     geld eruit, omschrijving 'Z'") en "Aanpassen…", dat de regeleditor als sheet opent, voorgevuld met
     voorwaarden en acties. De regel wordt bewaard bij het boeken, zoals hij er staat.
   - Deed een regel het voorstel en kiest de gebruiker iets anders: "Regel bijwerken met deze keuze" (standaard
     uit), met dezelfde zin en "Aanpassen…". Zonder vinkje blijft de regel ongewijzigd: een uitzondering.
     Neemt de gebruiker het voorstel ongewijzigd over, dan staat er geen vinkje en telt de regel als gebruikt.
   - Bij "Waarom dit voorstel?" (Meer opties): "Regel aanpassen…" opent die regel in de editor; bewaren geldt meteen.
   - Niet bij een splitsing, een vaste storting of een verrekening (daar leerde de app ook niet van).
   - Ongedaan maken na het boeken draait ook een bewaarde of bijgewerkte regel terug.
   - Logica in `HFRules/RuleProposal.swift` (`ruleProposal`, `applyChoice`, `afterBooking`, `summary`), 9 tests.
     Het oude `learn` roept de app niet meer aan.
   - Nog te doen door de orchestrator: de 15 bestaande, automatisch geleerde regels wissen (eerst een kopie);
     de gebruiker maakt ze bij volgende imports met aandacht opnieuw.
   - Mogelijke vervolgstap: ook in Transacties "Onthoud als regel" bij het boeken van een nieuwe transactie.
6j. **Namen van pinbetalingen opschonen** — klaar (21 november), nog niet geïnstalleerd of gecommit. De bank
   levert pinnamen als "Winkel Plaats >Plaats13.11.2026" of "857 A POINT SEAT S>AMSTERDAM11.11.2026".
   `LabelCleaner` haalt nu het deel vanaf ">" weg (plaats en datum, ook aan elkaar vast), een losse letter die
   van het afkappen overblijft ("S") en een los voorloopnummer van twee of meer cijfers: "Winkel Plaats",
   "A Point Seat". Staat er vóór ">" alleen een nummer, dan wordt de plaats de naam. Een ">" met een spatie
   erna en zonder datum ("Pijl > Boog") blijft staan; zonder ">" verandert er niets (ook "123 Inkt" niet).
   - Alleen nieuwe voorstellen veranderen (voorgestelde omschrijving, naam van een nieuwe regel). Bestaande
     boekingen en regels houden hun tekst.
   - Regels matchen niet op de opgeschoonde naam maar op de ruwe tegenpartij (genormaliseerd, "bevat"); dat is
     ongewijzigd. Een regel met "Winkel Plaats" als tegenpartij matcht dus nog steeds. Wel een bestaande
     beperking (niet door 6j): een **geleerde** regel voor zo'n pinnaam krijgt de hele ruwe naam mét datum als
     voorwaarde en past daardoor niet op een volgend bezoek. Zie de vervolgsuggestie hieronder.
   - Tests: `LabelCleanerTests` (met/zonder spatie, datum vast aan de plaats, voorloopnummer, zonder ">", alleen
     een nummer) en `MatchingTests.pinNameWithPlaceAndDateStillMatches`.
6k. **Geleerde regels voor pinnamen zonder plaats en datum** (voorstel, nog niet gepland). Bij leren uit een
   pinbetaling met ">" de voorwaarde "tegenpartij bevat" vullen met het deel vóór ">" in plaats van de hele
   ruwe naam, zodat de regel ook op een volgend bezoek past.
6k. **Schermfixes van 20 november opnieuw, in vier aparte stappen** (afspraak 21 november; na 6g). Elk met
   een eigen testronde en test door de gebruiker; bij problemen alleen die stap terugdraaien. Uit `70cab3b`
   als voorbeeld (`git show 70cab3b`), niet blind overnemen. Die commit lag onder de misgelopen release.
   1. Alleen teksten: overal "Verrekenen met spaar"; de Engelse tekst bij Tags in het Nederlands.
   2. Leesbaarheid: te lichte grijze bijschriften iets donkerder.
   3. Rapporten in een smal venster. Eerst de zelftest uitbreiden: elk scherm in gewone én kleinste
      venstermaat, zijbalk na elke stap zichtbaar.
   4. Instellingen in een smal venster.
   Volgorde van de rondes: 6c (test), 6j, 6h, 6g, 6k-1 t/m 6k-4. Daarna nog te vragen: telefoondashboard
   met "Nog te besteden deze maand", voorbeelddata versie 2.
6l. **Telefoondashboard voor het gezin** — klaar (21 november), nog niet geïnstalleerd of gecommit. Op de
   telefoonpagina (`HFPublish`), in deze volgorde:
   1. hoofdgetal "Nog te besteden deze maand" (zoals het Dashboard op de Mac) met "Besteedbaar nu" eronder. Een
      verrekentag met "telt mee in nog te besteden" (6g) staat eronder als "Komt nog terug: <tag>";
   2. per gekozen eigenaar (kind) een kaart met het totaal en de potjes met saldo. Alleen de eigenaren die de
      gebruiker aanvinkt; een groep als "Kids" komt er dus niet op, tenzij die wordt aangevinkt;
   3. één gekozen spaarpot met het saldo nu en de verwachte stand over 3, 6 en 12 maanden, met
      `Insight.potForecast` (dezelfde vooruitblik als bij de pot). Geen naam in de code.
   - Instellen bij Instellingen › Telefoon, kaart "Voor het gezin": schakelaar plus vinkjes per eigenaar, en
     schakelaar plus keuzelijst met potten. Zolang er niets gekozen is, staan de onderdelen er niet op.
     Opgeslagen in `publish.options` (nieuwe sleutels; oudere instellingen worden gewoon gelezen). Geen migratie.
   - `PhoneDashboard.make` krijgt de opties mee; nieuwe velden `budget.returning`, `childPots`, `sharedPot`.
   - `--snapshot` schrijft nu ook `telefoon.html` met voorbeelddata (`--only telefoon`).
   - Bekeken op 375 px breed, licht en donker: geen horizontaal schuiven. De voorbeelddata heeft geen vaste
     stortingen, dus daar is de vooruitblik vlak (bij 6m een pot met stortingen meenemen).
   - Tests: 15 in `PhoneFamilyTests` (HFPublish), 2 bestaande aangepast aan het nieuwe hoofdgetal. Testronde met
     voorbeelddata GESLAAGD (549 tests, zelftest 33 OK). De kaart "Voor het gezin" in Instellingen is niet door de
     zelftest gedekt en niet met de hand geprobeerd.
   - Testronde met een kopie: geen nieuwe kerncijfers; verwacht geen verschillen.
   Na de installatie zet de orchestrator het telefoondashboard samen met de gebruiker aan en laat het op een
   echte iPhone bekijken.
6m. **Voorbeelddata versie 3, om te demonstreren** — klaar (21 november), nog niet geïnstalleerd of gecommit.
   Een verzonnen gezin waarmee alles van 6a–6l te laten zien is; de demo-route staat in de README
   ("Demonstreren"), de inhoud in `docs/api/HFBackup.md`.
   - `DemoData.version` = 3. `DemoData.openDemo` (uit `70cab3b`) vult een voorbeeldbestand van een andere of
     onbekende versie opnieuw; weigert de eigen administratie vóór er iets geopend wordt (ook via koppeling).
   - Voorbeeldmodus: de laatste 10 dagen van **beide** rekeningen ontbreken; Nakijken heeft de knop
     "Voorbeeldbestand importeren" (was: "Gebruik het voorbeeldbestand", alleen betaal-CSV). Die schrijft een zip
     zoals de bank hem levert (`DemoData.writeSampleArchive`) en opent hem met het gewone zip-importeren. Daarin:
     zakgeld (verrekenen bij geld eruit, 6f), geld terug van een kind (twijfel, 6f), "Oppas zaterdag" (eigen
     tekst, 6b), een rommelige pinnaam (6j), een losse overboeking naar spaar (6e) en de overboeking van een
     vastgelegde, nog niet afgevinkte verrekening met spaar ("Afvinken en aanhangen").
   - Uit versie 2 overgenomen: potten per kind (spaargeld, kleedgeld, zakgeld), "Studie en rijbewijs" met
     onderdelen (nu met eigenaar **Kids**), rijlessen met tag per kind, kleding uit kleedgeld, vooruitblik voor de
     rentepot. Nieuw: "Buffer gezin" met vooruitblik (verwachte wasmachine), Tanken verrekent met startbedrag en
     "telt mee in nog te besteden" en maandelijkse terugstorting (6g), regels zoals "Onthoud als regel" ze maakt
     (6i, 6f), pinnamen zoals de bank ze levert (6j), tags alleen op betaal (6h).
   - Vaste stortingen: bewust **één** ("Maandelijkse reserveringen", 28 potten). Versie 2 had er vier vanaf de
     betaalrekening; dan vraagt Nakijken bij een losse overboeking naar spaar eerst "Kies welke vaste storting"
     in plaats van "lijkt een losse overboeking" (6e kijkt pas naar het bedrag als er één kandidaat is). Zie 6n.
   - Telefoon (6l): na het vullen zet de app bij "Voor het gezin" Kind 1, Kind 2 en Buffer gezin aan
     (`DemoSupport.configurePhone`, ook bij `--voorbeeld` en `--snapshot`). Het dashboard zelf blijft uit.
   - Tests: `DemoDataTests` bijgewerkt, nieuw `DemoDataPotsTests`, `DemoDataVersion3Tests`,
     `DemoDatabaseFileTests` (HFBackup), `DemoArchiveTests` en `DemoPhoneTests` (IntegrationTests; die hangt nu
     ook af van HFPublish): de zip importeert foutloos, sluit aan op beide saldi en na boeken sluit elke import.
     Testronde met voorbeelddata GESLAAGD (563 tests, zelftest 33 OK, 152 kerncijfers).
   - Niet met de hand geprobeerd: de knop in de echte app en het vernieuwen van een bestaand voorbeeldbestand
     (de zelftest gebruikt `--voorbeeld`, niet de voorbeeldmodus). Geen migratie, geen invloed op de eigen
     administratie; op een kopie verwacht ik geen verschillen (niet gedraaid).
6n. **Losse overboeking bij meer vaste stortingen** (voorstel, nog niet gepland). `DistributionService.recognize`
   (spaarkant): passen er meer vaste stortingen op tegenrekening en geen enkele op bedrag, dan nu "kies welke";
   beter: als het bedrag ver van álle totalen ligt, meteen "lijkt een losse overboeking".
6d. **Versie zichtbaar in Instellingen › Over** — klaar (21 november). `scripts/run.sh` zet bij elke build de
   korte commit-hash (met een `+` als er niet-gecommitte wijzigingen waren) en de bouwdatum in `Info.plist`
   (`HFBuildCommit`, `HFBuildDate`; `CFBundleVersion` is het aantal commits). Over toont bv. "Versie 1.0 ·
   gebouwd 21-11-2026 14:50 · 7931616"; zonder die gegevens (`swift run`, `swift build`) "ontwikkelversie". De
   tekst komt uit `BuildInfo` in HFCore (met tests). De zelftest zet dezelfde tekst als tweede regel in zijn log.
7. **Excel-historie** (in de wacht): `HFHistory` aanpassen volgens de oplossing hieronder, proefdraaien, pas
   importeren als de jaren kloppen. Daarna de knop "Leer regels uit bankhistorie" in het scherm Regels.
8. **Code-review** door een developer voordat de app de enige administratie wordt (zie de spec).

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
