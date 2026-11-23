# Bouwpakket HomeFinance

*Een zelfstandige opdracht om een gezinsbegroting te bouwen. Dit ene bestand is de enige bron: je hebt geen
repository, geen andere documenten en geen voorbeeldbestanden nodig. Alle namen, bedragen en rekeningnummers in dit
document zijn verzonnen.*

**Voor de AI-agent die dit leest.** Je bouwt een app die bestaat en dagelijks gebruikt wordt (de
referentie-implementatie, een native macOS-app). Bouw dezelfde app op jouw platform (bijvoorbeeld Windows, web of
Linux). "Dezelfde app" betekent: dezelfde begrippen, hetzelfde datamodel, exact dezelfde rekenregels en dezelfde
schermen met dezelfde opbouw. De techniek mag je zelf kiezen. Waar dit document "moet" zegt, is het een eis; waar het
"in de referentie" zegt, is het een voorbeeld.

Inhoud:

1. Opdracht en doel
2. Triage: twee vragen vooraf
3. Spelregels voor de agent
4. Begrippen
5. Architectuur
6. Datamodel
7. Rekenregels
8. Import
9. Schermen
10. Telefoondashboard, back-up en export, voorbeelddata
11. Werkwijze en testvangnet
12. Volgorde van bouwen
13. Acceptatietests

---

## 1. Opdracht en doel

### Wat het is

Een gezinsbegroting voor één huishouden die twee Excel-werkmappen vervangt:

- **het maandoverzicht IN/UIT van de betaalrekening**: een jaarblad met per regel een vaste post (salaris, huur,
  energie, verzekeringen) en per kolom een maand, met het plan en wat er echt is binnengekomen en afgegaan;
- **de administratie van de spaarrekening met potjes**: het saldo van één spaarrekening is verdeeld over potjes
  met een bestemming (reserveringen voor jaarlijkse kosten, spaargeld per persoon, spaardoelen). Elke maand gaat er
  een vaste overboeking naar spaar die over de potjes wordt verdeeld.

De financiële logica van de Excel blijft gelijk; het typewerk verdwijnt. In plaats van bedragen over te typen
importeert de gebruiker het bankbestand, kijkt de voorstellen na en boekt.

### Voor wie

- Eén gebruiker die de financiën van het gezin bijhoudt en de Excel-manier van denken kent (posten, plan tegen
  werkelijk, reserveren in potjes). Geen boekhouder: de interface spreekt gewone taal.
- Daarnaast gezinsleden die alleen kijken: via een telefoonpagina (een statisch bestand) zien zij het hoofdgetal,
  hun eigen potjes en een gezamenlijke spaarpot.

### Uitgangspunten

- **Lokaal.** Alle gegevens staan in één databasebestand op de eigen computer. Geen server, geen account, geen
  login, geen hosting. De computer is de beveiliging.
- **Nooit in een cloudmap.** De database staat in de gewone programmagegevens van de gebruiker. Alleen back-ups en
  de telefoonpagina gaan naar een (gesynchroniseerde) map naar keuze.
- **Start met beginstanden.** Een nieuwe administratie begint met een saldo per rekening en een beginbedrag per
  potje op een begindatum. Historie importeren is geen eis.
- **Geen AI in de app.** Indelen gebeurt met regels die de gebruiker zelf maakt of goedkeurt.

### Wanneer is het klaar

- Een maand bijhouden kost alleen nog: het bankbestand importeren en de voorstellen nakijken.
- Het berekende saldo van elke rekening sluit op € 0,00 met de bank.
- "Nog te besteden deze maand" klopt met de Excel-formule (de rekensom in hoofdstuk 7).
- Elk potje heeft een saldo, en de potjes plus "niet toegewezen" zijn samen het saldo van de spaarrekening.

---

## 2. Triage: twee vragen vooraf

Houd dit kort. Stel de collega vóór het bouwen **alleen deze twee vragen**, leg per keuze in één of twee zinnen de
gevolgen uit, en schrijf de antwoorden op in je eigen projectdocumentatie (bijvoorbeeld een bestand `keuzes.md`).
Begin daarna met ronde 0.

1. **Platform en techniek.** Op welk systeem moet de app draaien (Windows, macOS, Linux, web of mobiel), en met welke
   taal, welk interface-framework en welke database?
   *Gevolgen:* bepaalt hoe de testronde de echte app start en de schermen controleert (hoofdstuk 11), hoe een
   back-up gemaakt wordt (hoofdstuk 10) en welke venstermaten je controleert. Een webversie draait ook lokaal,
   zonder server op internet en zonder account. Zonder voorkeur: een lokale desktopapp met SQLite.
2. **Bank en exportformaat.** Bij welke bank of banken staan de rekeningen, en in welk formaat kan de collega de
   transacties downloaden (CSV, CAMT.053, MT940, PDF)? Vraag om een **voorbeeldbestand met verzonnen of
   geanonimiseerde regels** (zelfde kolommen of structuur, verzonnen namen, IBAN's en bedragen).
   *Gevolgen:* bepaalt de inleesmodule (hoofdstuk 8.6). Levert de bank geen saldo per regel, dan vervallen de
   saldoketen en de naad op saldo en blijft alleen de naad op datum over. Zonder voorbeeldbestand bouw je het
   algemene profiel met kolommen kiezen en het voorbeeldformaat van hoofdstuk 8.5, en pas je het aan zodra er een
   bestand is.

### Standaardkeuzes (niet vragen)

Deze keuzes liggen vast. Leg ze **niet** voor; ze kunnen later worden bijgesteld als de collega daarom vraagt.

- **Taal en begrippen**: Nederlands, met de begrippenlijst van hoofdstuk 4. Stel de namen pas bij na een eerste
  testronde met de gebruiker (les uit de referentie: namen pas na een test vastleggen).
- **Startsituatie**: beginnen met **beginstanden**, zonder historie: per rekening het saldo op een startdatum, per
  potje een beginbedrag, en eventueel een startbedrag bij een tag met "Krijg ik terug". Historie importeren (uit
  Excel of een andere app) is alleen een **latere optie** en hoort niet in de rondes van hoofdstuk 12: het vraagt om
  volledige en consistente oude gegevens per maand en per post, en in de referentie bleek een historie-import uit
  Excel te ingewikkeld en staat die in de wacht.
- **Onderdelen**: eerst de kern (begroting, import, boeken, potjes), daarna de rest in de volgorde van de roadmap.
  De gebruiker kan onderweg een onderdeel overslaan.
- **Huishouden**: de app ondersteunt meerdere inkomens, kwartaal- en jaarinkomsten, en potjes per persoon. Dat
  stelt de gebruiker in de app in, niet vooraf.
- **Opslag en privacy**: alleen lokaal, met een back-up naar een map naar keuze. Echte gegevens komen nooit in
  code, tests of voorbeelden.
- **Werkwijze**: kleine rondes met een testronde zoals in hoofdstuk 11, aangepast aan het gekozen platform.

---

## 3. Spelregels voor de agent

Deze regels zijn hard. Ze komen uit de bouw van de referentie, waar elke overtreding een echte fout opleverde.

1. **Geld in hele centen, nooit als drijvende komma.** Elk bedrag is een geheel getal in centen (64 bits). Rekenen,
   opslaan, vergelijken en optellen gebeurt in centen. Alleen bij tonen wordt het "€ 1.234,56". Waar gedeeld wordt,
   staat in dit document hoe er wordt afgerond.
2. **Uitgaven negatief, inkomsten positief.** Overal: in banktransacties, boekingen, plannen van posten (UIT
   negatief, IN positief), regels en verwachtingen.
3. **Datums zonder tijd en zonder tijdzone.** Een dag is jaar-maand-dag, in de database als tekst `yyyy-MM-dd`.
   "Vandaag" is altijd een parameter van elke berekening, nooit de systeemklok diep in de code; zo zijn tests
   reproduceerbaar.
4. **Geen rekenlogica in de schermen.** Schermen tonen wat de modules uitrekenen. Een getal dat op twee plekken
   staat (Dashboard en telefoon) komt uit één functie.
5. **Een databasewijziging is altijd een nieuwe migratie.** Bestaande migraties pas je nooit aan, ook niet als ze
   nog maar een dag oud zijn. Kolommen die niet meer gebruikt worden blijven staan.
6. **Testdata is verzonnen.** Geen echte namen, IBAN's of bedragen in code, tests, voorbeelddata of commits.
   IBAN's in tests en voorbeelden hebben de vorm `NL00TEST0000000001`. Bedrijven heten "Bakkerij Voorbeeld",
   "Energie Test BV". Personen heten "Ouder 1", "Kind 1".
7. **Interface in het Nederlands.** Alle teksten, foutmeldingen en exportkoppen zijn Nederlands, met de namen uit
   hoofdstuk 4. Identifiers in de code mogen Engels zijn.
8. **Geen regel verdwijnt stil.** Bij import wordt elke regel van het bankbestand een banktransactie of een gemelde
   fout. Bij een fout in één bestand wordt niets geïmporteerd.
9. **Alles of niets.** Elke schrijfactie (boeken, afvinken, importeren, een hulpje dat drie dingen tegelijk zet)
   draait in één databasetransactie.
10. **Banktransacties zijn onveranderlijk.** De gegevens van de bank worden nooit gewijzigd; de gebruiker wijzigt
    alleen boekingen.
11. **Modules kennen elkaar niet** (zie hoofdstuk 5).
12. **Nooit de echte administratie aanraken.** Tests en zelftests werken op een database in het geheugen, op
    voorbeelddata of op een kopie. Weiger in testopties een pad naar de echte gegevensmap.
13. **Een developer reviewt** de code voordat de app de enige administratie van een gezin wordt. Tot dan draait de
    Excel mee (schaduwdraaien).

---

## 4. Begrippen

Gebruik deze namen in de interface, letterlijk. Ze zijn na een test met de gebruiker vastgelegd. De
identifiers in de referentiecode hebben soms een oudere naam; die staat in de laatste kolom, zodat je het
datamodel in hoofdstuk 6 kunt lezen.

| Begrip in de interface | Uitleg van één zin | Naam in datamodel en code |
|---|---|---|
| Post (vaste post) | Een regel in de begroting van één jaar met het bedrag dat je per maand, kwartaal of jaar verwacht. | `budgetItem` |
| IN / UIT | De richting van een post: inkomsten of uitgaven. | `direction` IN, UIT |
| Overig (IN overig, UIT overig) | Boekingen op de betaalrekening die bij geen enkele post horen. | "divers": boeking zonder `budgetItemId` |
| RESERVERINGEN | De ene post per jaar met het maandbedrag dat naar de potjes op spaar gaat. | `budgetItem.isReserveTotal` |
| RES-regels (oude opbouw) | Regels onder RESERVERINGEN die uit de Excel komen; ze bepalen het plan van RESERVERINGEN in de berekeningen. | `budgetItem` met `direction` RES |
| Potje | Een deel van het saldo van de spaarrekening met een eigen bestemming. | `pot` |
| Reserveringspotje / spaarpotje | De twee soorten potjes: geld voor iets dat zeker komt maar niet elke maand, of geld voor een persoon of wens. | `pot.kind` reservering, spaar |
| Niet toegewezen | Het deel van de spaarrekening dat in geen enkel potje zit. | saldo − som potjes |
| Automatisch sparen | Een vaste overboeking per maand van betaal naar spaar, verdeeld over potjes; één losse heet "vaste overboeking". | `distribution`, `distributionLine` |
| Telt in je begroting als | De post op de betaalrekening waarop de overboeking van Automatisch sparen als uitgave telt. | `budgetItem.distributionId` |
| Minimaal op je betaalrekening aan het eind van de maand | Een vast bedrag per jaar dat je altijd laat staan, zodat je niet rood komt; in de rekensom "Minimaal op de rekening aan het eind van de maand". | `budgetYear.antiRood` |
| Tijdelijk geleend van spaar | Geld dat je even van spaar haalt en later terugzet; de app telt wat er nog uitstaat. | `entry.temporaryLoan` |
| Vrij te besteden | Saldo betaalrekening min het minimum, min tijdelijk geleend, plus wat er nog terugkomt. | "besteedbaar nu" |
| Nog te besteden deze maand | Het hoofdgetal: vrij te besteden plus wat er deze maand nog verwacht wordt. | "spendableEndOfMonth" |
| Nog verwacht | Status van een post die deze maand nog komt en nog niet te laat is. | celstatus `open` |
| Klopt / Wijkt af (± € X) / Nog verwacht / Te laat / Afgevinkt | De status van een post in een maand. | `gelijk`, `afwijkend`, `open`, `teLaat`, `afgevinkt` |
| Afvinken (een post) | Een post voor een maand als voldaan markeren, ook zonder boeking. | `itemCheck` |
| Hoort bij maand | De begrotingsmaand van een boeking als die anders is dan de maand van de datum. | `entry.period` |
| Nog overboeken | Iets dat je vanaf betaal betaalde maar bij een potje hoort (of andersom); je zet het later in één overboeking met spaar recht. | `entry.reimburse` + `entry.potId`; "verrekenen met spaar" |
| Overboeking met spaar | Eén vastgelegde overboeking die de open regels van Nog overboeken rechtzet; afgerond heet "overgeboekt". | `savingsTransfer` |
| Tag | Kenmerk om uitgaven te volgen (tanken, uit eten), alleen op de betaalrekening; telt niet als extra uitgave. | `tag`, `entryTag` |
| Krijg ik terug | Schakelaar bij een tag: uitgaven met deze tag krijg je terug; de app toont "Nog terug te ontvangen: € …". | `tag.settles` |
| Tel mee bij ‘nog te besteden’ | Schakelaar bij een tag: wat nog terugkomt telt mee in het hoofdgetal als "Komt nog terug". | `tag.countsInSpendable` |
| Startbedrag (bij een tag) | Wat er bij de start van de app al openstond en nog terug moet komen. | `tag.startAmount`, `startDay` |
| Terugbetaling | Een vastgelegde terugbetaling bij een tag (oude werkwijze; nieuw: de bijschrijving dezelfde tag geven). | `settlement` |
| Banktransactie | Een regel uit het bankbestand; onveranderlijk. | `bankTransaction` |
| Boeking | Een bedrag op een rekening, ingedeeld bij een post, een potje of overig. | `entry` |
| Indelen bij | Een boeking bij een post of potje zetten. | — |
| Gecontroleerd / nog niet gecontroleerd | Of je een (automatisch) geboekte boeking achteraf hebt bekeken. | `entry.reviewed` |
| Regel | Een voorschrift dat bij een banktransactie een post, potje, omschrijving en tags voorstelt. | `rule` |
| Voortaan zo indelen | Vinkje bij het boeken: van je keuze wordt een regel gemaakt of een regel bijgewerkt. | — |
| Zeker | Een voorstel waarbij tegenpartij én bedrag van de regel kloppen. | zekerheid `hoog` |
| Spaardoel | Doelbedrag en doeldatum bij een potje, met een kleine marge. | `pot.targetAmount`, `targetDate` |
| Spaardoel uit onderdelen | Een doelbedrag opgebouwd uit regels "aantal × bedrag". | `goalPart` |
| Verwachting | Een verwacht bedrag voor een potje op een datum (een gift, een rekening); telt alleen in de vooruitblik. | `forecastItem` |
| Project | Een groep verwachtingen bij een potje die samen een begroting vormen (gepland, betaald, nog te komen). | `forecastItem.project` |
| Vooruitblik | Het verwachte saldo van een potje in de tijd; telt nergens anders in mee. | — |
| Reken met eerdere uitgaven | Schakelaar per potje: de vooruitblik trekt elke maand het gemiddelde van de eerdere uitgaven af. | `pot.forecastFromHistory` |
| Eenmalig (niet in het gemiddelde) | Markering op een boeking van een potje: telt niet mee in dat gemiddelde. | `entry.forecastOneOff` |
| In de min, gedekt door andere potjes | Het totaal van potjes die negatief staan; dat geld is in feite van de andere potjes. | — |
| Periodieke transacties / Incidentele transacties | De boekingen op vaste posten tegenover de boekingen op overig (kaartjes op het Dashboard). | — |
| Te doen | Het scherm met alles wat nog open staat: nog over te maken, terug te ontvangen, tijdelijk geleend. | — |
| Aandacht | Het blok op het Dashboard met meldingen die een handeling vragen. | — |
| Afstemmen | Het saldo van de bank invoeren en vergelijken met het berekende saldo; het verschil moet € 0,00 zijn. | `reconciliation` |
| Wat-als | Een proefbedrag per post naast het plan, voor de maandbalans; verandert de begroting niet. | `budgetItem.scenarioAmount` |

**Woorden die je niet gebruikt** (ze zijn na de test vervallen of botsten): "divers", "pot" (zeg "potje"),
"vaste storting", "anti-rood", "besteedbaar nu", "verrekenen" (voor beide betekenissen), "voorgeschoten",
"bankregel", "onthoud als regel", "toewijzen", "nakijken" in de betekenis van achteraf controleren,
"categorie" (botst met post).

---

## 5. Architectuur

### Modules

De app bestaat uit losse modules met elk één taak. Ze hangen alleen af van de kern, **niet van elkaar**. Alleen de
app (de schermen) verbindt ze. Zo kan een module apart getest en vervangen worden, en kan een fout in de ene de
andere niet stil beïnvloeden.

| Module | Taak | Hangt af van |
|---|---|---|
| **Kern** | Geld (centen), dag, de records, het schema en de migraties, gedeelde instellingen (zoals de marge van spaardoelen). | — (database-bibliotheek) |
| **Import** | Bankbestanden lezen (zip, CSV, eventueel PDF), saldoketen, dubbelen, naad met het beginsaldo, importeren als banktransacties. Doet geen voorstellen. | kern |
| **Regels** | Regels toepassen op banktransacties: voorstel met zekerheid, regelconcept bij een keuze, namen opschonen. Schrijft alleen regels, nooit boekingen. | kern |
| **Schrijven (begroting)** | Alles wat gegevens wijzigt: boeken, splitsen, potjes, Automatisch sparen, Nog overboeken, terugbetalingen, afvinken, afstemmen, jaar en posten, hulpje "Nieuw jaarbedrag". | kern |
| **Lezen (inzicht)** | Alles wat gegevens leest en uitrekent: maandgrid, status van posten, saldi, vrij en nog te besteden met de rekensom, Dashboard en Aandacht, potsaldi, spaardoel, vooruitblik, ketenstrook, rapporten, kerncijfers, zoeken. Schrijft nooit. | kern |
| **Back-up en export** | Back-up en herstel, CSV-export, Excel-export per jaar, voorbeelddata. | kern |
| **Telefoondashboard** | De telefoonpagina als statisch bestand. | kern, lezen |
| **App** | De schermen. Geen rekenlogica. Verbindt modules, bijvoorbeeld de gedeelde voorstellen voor Nakijken en Transacties (regels + Automatisch sparen + Nog overboeken). | alles |

Afspraken:

- De lees-module rekent zelf met SQL op de tabellen. Ze roept de schrijfmodule niet aan, ook niet voor iets dat
  daar al bestaat. Waar beide dezelfde regel nodig hebben (bijvoorbeeld "welke boekingen zijn door het afvinken van
  een overboeking met spaar gemaakt"), lezen ze dezelfde opgeslagen markering (zie `setting` in hoofdstuk 6) en is
  er een integratietest die de echte schrijfweg gebruikt.
- Alle schrijffuncties weigeren met een Nederlandse foutmelding die het scherm direct kan tonen.
- Elke module beschrijft zijn publieke functies in een eigen document (in de referentie één Markdown-bestand per
  module).
- Een afgesloten jaar weigert elke wijziging van zijn boekingen en posten.

### De referentie-implementatie (voorbeeld, geen eis)

| Onderdeel | In de referentie | Jouw keuze |
|---|---|---|
| Taal en interface | Swift 6, SwiftUI, Swift Charts, native macOS | vrij (bv. C#/.NET, TypeScript + web, Rust, Kotlin) |
| Database | SQLite via een bibliotheek (GRDB), één bestand | SQLite wordt aangeraden: één bestand, transacties, online-backup-API |
| Pakket | één package met per module een eigen target en testtarget | vrij, maar houd de modulegrenzen |
| Tests | per module een testtarget, database in het geheugen | vrij; een database in het geheugen per test |
| Venster | gewone en kleinste venstermaat 1100 × 700 | kies vergelijkbare maten voor jouw platform |

Live bijwerken: in de referentie observeren schermen hun query's en verversen ze vanzelf na elke schrijfactie.
Hoe jij dat doet is vrij, zolang een scherm na een wijziging elders nooit een verouderd getal toont.

---

## 6. Datamodel

Platformneutraal eindschema. Typen: `int` (64 bits), `geld` (int in centen, met teken), `tekst`, `dag` (tekst
`yyyy-MM-dd`), `maand` (tekst `yyyy-MM`), `bool`, `tijdstip` (datum en tijd, voor "aangemaakt op"). Elke tabel met
`id` heeft een automatisch oplopende primaire sleutel. "→ tabel" is een verwijzing (vreemde sleutel) met het
gedrag bij verwijderen. Tabelnamen en kolomnamen mag je zo overnemen.

Kolommen gemarkeerd met *(niet meer gebruikt)* bestaan in de referentie nog, maar worden door geen rekenregel
gelezen. Je hoeft ze niet te bouwen.

### account — rekening

| Kolom | Type | Regel |
|---|---|---|
| id | int | |
| name | tekst | verplicht |
| iban | tekst | uniek; opgeslagen zonder spaties, in hoofdletters |
| kind | tekst | `betaal` of `spaar` |
| openingBalance | geld | beginsaldo; bij een spaarrekening met potjes het **niet toegewezen** deel (zie potjes) |
| openingDate | dag | begindatum; boekingen vóór deze dag worden geweigerd |
| sortOrder | int | volgorde in lijsten |
| archived | bool | gearchiveerd |

Meerdere betaal- en spaarrekeningen mogen. Alle potjes van één gezin staan in de praktijk op één spaarrekening,
maar het model staat potjes per spaarrekening toe. Verwijderen alleen als de rekening nergens gebruikt wordt.

### budgetYear — begrotingsjaar

| Kolom | Type | Regel |
|---|---|---|
| id | int | |
| year | int | uniek |
| antiRood | geld | "Minimaal op je betaalrekening aan het eind van de maand", ≥ 0 |
| closed | bool | afgesloten: geen wijzigingen aan boekingen en posten van dit kalenderjaar |
| tijdelijkAntiRood | geld | *(niet meer gebruikt; tijdelijk geleend volgt uit boekingen)* |
| reserveBase | geld | *(niet meer gebruikt)* |

### budgetItem — post

| Kolom | Type | Regel |
|---|---|---|
| id | int | |
| yearId | → budgetYear | verwijderen: mee verwijderd |
| label | tekst | naam van de post, bv. "Energie" |
| direction | tekst | `IN`, `UIT` of `RES` |
| planAmount | geld | bedrag **per keer**; IN ≥ 0, UIT en RES ≤ 0 |
| frequency | tekst | `maand`, `kwartaal` of `jaar` |
| expectedMonths | tekst | bij kwartaal/jaar de maanden, bv. `1,4,7,10`; leeg bij maand |
| expectedDay | int? | dag van de maand waarop de post meestal komt (voor "te laat") |
| isReserveTotal | bool | dit is RESERVERINGEN; hoogstens één per jaar, richting UIT |
| potId | → pot? | alleen bij RES-regels: het potje dat de regel vult; bij verwijderen leeg |
| sortOrder | int | volgorde in het maandgrid |
| distributionId | → distribution? | "Telt in je begroting als": de gekoppelde Automatisch sparen; bij verwijderen leeg |
| scenarioAmount | geld? | wat-als-bedrag, zelfde tekenregels als het plan; leeg = geen |
| reducesReserve | bool | *(niet meer gebruikt)* |

Een post met `direction` RES heet een RES-regel. Hij krijgt nooit boekingen.

### pot — potje

| Kolom | Type | Regel |
|---|---|---|
| id | int | |
| accountId | → account | een spaarrekening; verwijderen van de rekening geweigerd |
| name | tekst | |
| kind | tekst | `reservering` of `spaar` |
| owner | tekst? | eigenaar, vrije tekst (een persoon of een groep); gebruikt om te groeperen en voor de telefoon |
| targetAmount | geld? | doelbedrag van het spaardoel |
| targetDate | dag? | doeldatum |
| forecastFromHistory | bool | "Reken met eerdere uitgaven", standaard uit |
| sortOrder | int | |
| archived | bool | opgeheven; kan alleen bij saldo € 0,00 |
| monthlyAmount | geld | *(niet meer bewerkt; de verdeling komt uit Automatisch sparen)* |

### goalPart — onderdeel van een spaardoel

| Kolom | Type | Regel |
|---|---|---|
| id | int | |
| potId | → pot | mee verwijderd |
| label | tekst | mag leeg |
| quantity | int | ≥ 1 |
| unitAmount | geld | ≥ 0, bedrag per stuk |
| sortOrder | int | |

Met onderdelen is `pot.targetAmount` altijd de som van `quantity × unitAmount`; het doelveld is dan alleen-lezen.

### distribution — Automatisch sparen (één vaste overboeking)

| Kolom | Type | Regel |
|---|---|---|
| id | int | |
| name | tekst | verplicht, bv. "Maandelijkse reserveringen" |
| accountId | → account | de **doelrekening** (spaar) |
| sourceAccountId | → account? | de **herkomstrekening** (betaal), niet gelijk aan het doel |
| sortOrder | int | |
| archived | bool | gearchiveerd telt nergens mee |

### distributionLine — verdeling over potjes

| Kolom | Type | Regel |
|---|---|---|
| id | int | |
| distributionId | → distribution | mee verwijderd |
| potId | → pot | potje van de doelrekening; mee verwijderd |
| amount | geld | > 0, per maand |
| sortOrder | int | |

Uniek: (distributionId, potId). Het totaal van een Automatisch sparen is de som van zijn regels.

### forecastItem — verwachting bij een potje

| Kolom | Type | Regel |
|---|---|---|
| id | int | |
| potId | → pot | mee verwijderd |
| day | dag | mag in het verleden liggen |
| amount | geld | met teken, niet nul |
| label | tekst | mag leeg |
| project | tekst | leeg = geen project; getrimd |
| realizedEntryId | → entry? | de boeking waarmee de verwachting uitkwam |
| realizedAt | tijdstip? | gezet = uitgekomen (afgevinkt) |
| createdAt | tijdstip | |

### importBatch — één importpoging per bestand

| Kolom | Type | Regel |
|---|---|---|
| id | int | |
| accountId | → account | |
| fileName | tekst | |
| importedAt | tijdstip | |
| rowCount | int | alle regels van het bestand, goede en foute |
| newCount | int | geïmporteerd |
| duplicateCount | int | al bekend |
| firstDay, lastDay | dag? | van de regels die meegingen |
| openingBalance, closingBalance | geld? | saldo vóór de eerste meegaande regel en na de laatste regel; leeg zonder saldo in het bestand |
| chainOK | bool | saldoketen sluit (true ook als het bestand geen saldo heeft) |

Ook als alles dubbel is, komt er een batch (met `newCount` 0), zodat de poging en het eindsaldo vastliggen.

### bankTransaction — banktransactie

| Kolom | Type | Regel |
|---|---|---|
| id | int | |
| accountId | → account | |
| batchId | → importBatch? | |
| day | dag | boekingsdatum van de bank |
| amount | geld | met teken |
| balanceBefore | geld? | saldo vóór de mutatie, als de bank het levert |
| counterpartyName | tekst | ruwe naam van de tegenpartij |
| counterpartyIban | tekst | |
| descriptionText | tekst | ruwe omschrijving |
| reference | tekst | betalingskenmerk |
| transactionCode | tekst | code van de bank (pin, incasso, overboeking …) |
| sequence | tekst | volgnummer van de bank |
| fingerprint | tekst | uniek; zie Import |
| status | tekst | `nieuw`, `verwerkt` of `overgeslagen` |

`verwerkt` = de som van de boekingen is gelijk aan het bedrag. `overgeslagen` telt niet mee in het saldo.

### entry — boeking

| Kolom | Type | Regel |
|---|---|---|
| id | int | |
| accountId | → account | |
| bankTransactionId | → bankTransaction? | leeg = handmatige boeking; één banktransactie kan meer boekingen hebben (splitsen) |
| day | dag | volgt de banktransactie; bepaalt het saldo |
| amount | geld | met teken |
| label | tekst | omschrijving (uit regel of van de gebruiker); de banktekst blijft in de banktransactie |
| budgetItemId | → budgetItem? | alleen op betaal; leeg = overig |
| potId | → pot? | op spaar: het potje; op betaal: alleen samen met `reimburse` |
| reimburse | bool | Nog overboeken (alleen op betaal, niet bij bedrag nul) |
| savingsTransferId | → savingsTransfer? | de overboeking met spaar waarin deze gemarkeerde boeking zit; leeg = staat nog open |
| counterEntryId | → entry? | de andere helft van een overboeking tussen eigen rekeningen of van het afvinken |
| reviewed | bool | gecontroleerd; nieuwe boekingen uit een import beginnen op false |
| note | tekst | |
| ruleId | → rule? | de regel die het voorstel deed |
| confidence | tekst? | `hoog`, `midden`, `laag`, `geen` |
| temporaryLoan | bool | tijdelijk geleend van spaar (alleen op betaal) |
| settlementId | → settlement? | zit in een vastgelegde terugbetaling bij een tag |
| period | maand? | "Hoort bij maand"; leeg = de maand van `day` |
| forecastOneOff | bool | eenmalig, niet in het gemiddelde van de vooruitblik |
| createdAt | tijdstip | |

Verwijderen van de banktransactie verwijdert haar boekingen. Een boeking op een spaarrekening heeft nooit een
post, nooit `reimburse` en nooit een tag.

### tag en entryTag

| Kolom (tag) | Type | Regel |
|---|---|---|
| id | int | |
| name | tekst | uniek, hoofdletterongevoelig |
| color | tekst | `#RRGGBB` |
| sortOrder | int | |
| settles | bool | Krijg ik terug |
| startAmount | geld | startbedrag, ≥ 0 (0 = geen) |
| startDay | dag? | dag van het startbedrag |
| startSettlementId | → settlement? | de terugbetaling waarin het startbedrag is opgenomen |
| countsInSpendable | bool | Tel mee bij ‘nog te besteden’ |

`entryTag`: (`entryId` → entry, `tagId` → tag), samen de primaire sleutel; beide mee verwijderd. Een boeking kan
meer tags hebben (n-op-m).

### settlement — terugbetaling bij een tag

| Kolom | Type | Regel |
|---|---|---|
| id | int | |
| tagId | → tag | |
| day | dag | |
| amount | geld | startbedrag (indien meegenomen) − som van de boekingen |
| depositEntryId | → entry? | de bijschrijving waarmee het geld terugkwam |
| isOpening | bool | beginstand: sluit boekingen van vóór het aanzetten van "Krijg ik terug" af |
| note | tekst | |
| createdAt | tijdstip | |

### savingsTransfer — overboeking met spaar (uit Nog overboeken)

| Kolom | Type | Regel |
|---|---|---|
| id | int | |
| day | dag | dag van vastleggen |
| amount | geld | netto met teken: positief = van spaar naar betaal, negatief = van betaal naar spaar, nul = alleen tussen potjes |
| done | bool | afgevinkt (en dus geboekt) |
| doneAt | tijdstip? | |
| note | tekst | |

Welke gemarkeerde boekingen erin zitten, staat in `entry.savingsTransferId`; welke boekingen het afvinken maakte, in `setting` (zie onder).

### itemCheck — post afgevinkt voor een maand

| Kolom | Type | Regel |
|---|---|---|
| id | int | |
| budgetItemId | → budgetItem | mee verwijderd |
| month | int | 1–12, in het jaar van de post |
| note | tekst | |
| createdAt | tijdstip | |

Uniek: (budgetItemId, month). Niet voor RES-regels; wel voor RESERVERINGEN.

### rule — regel

| Kolom | Type | Regel |
|---|---|---|
| id | int | |
| name | tekst | verplicht |
| priority | int | lager = eerder; nieuwe regels achteraan (hoogste + 10, afgerond op tientallen) |
| enabled | bool | |
| origin | tekst | `handmatig` of `geleerd` (via "Voortaan zo indelen") |
| accountId | → account? | alleen voor deze rekening (telt niet als voorwaarde) |
| counterpartyContains | tekst? | voorwaarde: komt voor in de naam van de tegenpartij |
| counterpartyIban | tekst? | voorwaarde: IBAN van de tegenpartij (zonder spaties, hoofdletters) |
| descriptionContains | tekst? | voorwaarde: trefwoord in de omschrijving |
| amount | geld? | voorwaarde: exact bedrag met teken |
| targetItemLabel | tekst? | actie: naam van de post (per jaar opgezocht); leeg = overig |
| targetPotId | → pot? | actie: potje |
| entryLabel | tekst? | actie: omschrijving; leeg = de voorgestelde omschrijving |
| tagIds | tekst | actie: tag-id's, komma-gescheiden |
| reimburse | bool | actie: Nog overboeken |
| reimburseDirection | tekst | `erin`, `eruit` of `beide`: alleen in die richting Nog overboeken (standaard `beide`) |
| hitCount | int | hoe vaak gebruikt |
| lastUsed | tijdstip? | |

Een regel zonder enige voorwaarde (alleen `accountId` telt niet) is ongeldig.

### reconciliation — afstemming

| Kolom | Type | Regel |
|---|---|---|
| id | int | |
| accountId | → account | |
| day | dag | |
| actualBalance | geld | saldo volgens de bank |
| calculatedBalance | geld | saldo volgens de app |
| createdAt | tijdstip | |

Verschil = berekend − werkelijk.

### setting — sleutel en waarde

`key` (tekst, primaire sleutel), `value` (tekst). Gebruikte sleutels:

| Sleutel | Inhoud |
|---|---|
| `savingsTransfer.<id>.entries` | komma-gescheiden id's van de boekingen die het **afvinken** van die overboeking met spaar maakte (potmutaties en tegenboeking). Alleen deze lijst bepaalt of een boeking "een boeking van het afvinken" is; schrijven en lezen gebruiken dezelfde bron |
| `spaardoel.margeBasispunten` | marge van spaardoelen in basispunten van het doel (standaard 50 = 0,5 %) |
| `publish.options` | keuzes voor de telefoonpagina (JSON) |
| `backup.*` | map, aantal te bewaren, back-up bij afsluiten, laatste back-up |
| `voorbeeld.versie` | versie van de voorbeelddata in het voorbeeldbestand |
| eigen bankprofielen | (optioneel) zelf gekozen kolomindeling per bank, als JSON |

### Wat er niet in de database staat

- Geen saldo-kolommen: elk saldo wordt uitgerekend.
- Geen "nog te besteden" of andere afgeleide getallen.
- Geen migratiegeschiedenis in dit document: bouw het eindschema als je eerste migratie, en doe elke latere
  wijziging als nieuwe migratie.

---

## 7. Rekenregels

Alle regels hieronder zijn exact. De voorbeelden gebruiken verzonnen bedragen. Hoofdstuk 13 bevat ze nog eens als
acceptatietests met de verwachte uitkomst.

### 8.1 Basis

- **Saldo van een rekening op dag D** = `openingBalance` + som van alle boekingen op die rekening met `day ≤ D`.
  Boekingen met een datum ná de peildag tellen niet mee in saldi, vrij te besteden en potsaldi (het maandgrid
  toont wel alle boekingen van het jaar).
- **Betaal: post of overig.** Een boeking op een betaalrekening met `budgetItemId` hoort bij die post; zonder
  post is het overig: **IN overig** als het bedrag positief is, **UIT overig** als het negatief is.
- **Alleen boekingen op betaalrekeningen** tellen mee in het maandgrid, de status van posten, overig en de
  rapporten over de begroting. De spaarrekening is de wereld van de potjes.
- **Peildag**: vandaag in het lopende jaar, 31-12 voor een voorbij jaar. "Komt nog terug", "Nog verwacht" en open
  regels van Nog overboeken tellen alleen in het lopende jaar.
- **Bedragvelden** accepteren een som (`249*4`, `504/12`, `100+25,50`); eerst × en ÷, dan + en −, afgerond op
  centen (half naar boven). Notaties: `-1.234,56`, `45,5`, `€ 12`, `-45.50`; een punt met precies één of twee
  cijfers erachter is een decimaalteken, anders een duizendtalscheiding.
- **Tonen**: `€ 1.234,56` en `-€ 45,50`.

### 8.2 Begrotingsmaand: "Hoort bij maand"

- Een boeking telt voor de begroting in de maand van `period` als die gezet is, anders in de maand van `day`.
- `period` ligt hoogstens **twee maanden** vóór of na de maand van de datum. De maand van de datum zelf wordt als
  leeg opgeslagen.
- Valt de periode in een ander jaar dan de datum (december ↔ januari), dan hoort de boeking bij de post met
  **hetzelfde label** in het jaar van de periode; bestaat die post daar niet, dan wordt het geweigerd. Terugzetten
  verhuist de boeking terug. Beide jaren moeten open zijn.
- Het **saldo volgt altijd `day`**. De begrotingsmaand geldt voor: maandgrid, celboekingen, overig, status van
  posten, "nog verwacht", maandresultaten, plan tegen werkelijk, tags per maand, totalen per omschrijving,
  incidentele transacties en de maandcijfers op het Dashboard.
- Jaaroverzicht: IN en UIT volgen het begrotingsjaar, saldi volgen de datum. Er geldt altijd
  `op de rekening op 1-1 + IN + UIT − verschoven over de jaargrens = op de rekening`.

Voorbeeld: het salaris van € 3.000,00 komt op 28 februari binnen en is bedoeld voor maart. Met "Hoort bij maand:
maart" staat het in de maartkolom van het grid; het saldo van 28 februari bevat het wel.

### 8.3 Posten, plan en het maandgrid

- **Plan per keer.** `planAmount` is het bedrag per keer dat de post voorkomt. Een maandpost komt in alle 12
  maanden; een kwartaal- of jaarpost alleen in `expectedMonths`.
- **Plan van RESERVERINGEN** is in álle berekeningen (grid, status, ruimte, nog te besteden, plan tegen
  werkelijk, maandbalans) de **som van het plan van de RES-regels** van dat jaar. RES-regels zelf krijgen geen
  boekingen en tellen in totalen niet mee (ze zijn informatief).
- **Opgeslagen plan bij Automatisch sparen.** Is een post gekoppeld aan een Automatisch sparen
  (`distributionId`), dan wordt zijn opgeslagen `planAmount` na elke wijziging van de verdeling op **− het
  totaal** van die overboeking gezet (voor posten in niet-afgesloten jaren). Een zelf ingevuld plan wordt dan
  overschreven. Na ontkoppelen blijft het plan staan en is het weer vrij. Voor RESERVERINGEN geldt in de
  berekeningen toch de som van de RES-regels (bewuste stand); lopen die twee uit elkaar, dan waarschuwt de app in
  het maandgrid, bij Posten en bij Automatisch sparen: "Let op: de RES-regels tellen op tot € …, Automatisch
  sparen: … tot € …". Gebruiken alle jaren Automatisch sparen zonder RES-regels, dan is RESERVERINGEN gewoon een
  post met het totaal als plan.
- **Grid**: rijen = posten van het jaar op `sortOrder`; kolommen = plan, januari t/m december, jaar. Cel = som van
  de boekingen van die post in die begrotingsmaand (een cel kan meer boekingen bevatten). Een RES-regel toont
  alleen zijn plan.
- **Totaalrijen per maand**: vaste posten (zonder RES-regels), IN overig, UIT overig, netto overig, resultaat
  (alles). **Ruimte t.o.v. maandbudget** = (som van het plan van de posten die deze maand verwacht worden, zonder
  RES-regels, met RESERVERINGEN) + IN overig + UIT overig. Positief = binnen budget.
- **Jaarplan per post** = plan × aantal verwachte maanden.

**Celstatus** (per post per maand):

| Situatie | Status | In de interface |
|---|---|---|
| Afgevinkt en geen boeking | `afgevinkt` | Afgevinkt |
| Boeking(en), som gelijk aan het plan van die maand | `gelijk` | Klopt |
| Boeking(en), som wijkt af, of boeking in een maand waarin de post niet verwacht wordt | `afwijkend` | Wijkt af (± € verschil) |
| Geen boeking, post niet verwacht in die maand, of plan € 0,00 | `nietVerwacht` | (leeg) |
| Geen boeking, verwacht, maand ligt in de toekomst | `nietVerwacht` | (toekomst, nog geen status) |
| Geen boeking, verwacht, maand is voorbij | `teLaat` | Te laat |
| Geen boeking, verwacht, lopende maand, `expectedDay` is gezet en vandaag > `expectedDay` | `teLaat` | Te laat |
| Geen boeking, verwacht, lopende maand, anders | `open` | Nog verwacht |

- Een post met een afwijkend bedrag geldt als **voldaan**, niet als te laat; het plan verandert niet.
- Afgevinkt mét boeking houdt de gewone status (Klopt of Wijkt af).
- Voor het overzicht van de maand ("Juni: 5 van 15 voldaan · 3 te laat") en het kaartje Periodieke transacties
  telt elke post die deze maand verwacht wordt: **voldaan** (Klopt, Wijkt af of Afgevinkt), **te laat** of **nog
  verwacht**. Een verwachte post met plan € 0,00 en zonder boeking telt niet mee.
- **Afvinken** kan per post per maand, niet voor RES-regels, wel voor RESERVERINGEN, niet in een afgesloten jaar.
  Een afgevinkte post zonder boeking telt als voldaan, niet als open of te laat en niet in "nog verwacht".

### 8.4 Vrij te besteden

```
Vrij te besteden = saldo van alle betaalrekeningen op de peildag
                 − minimaal op de rekening aan het eind van de maand   (budgetYear.antiRood)
                 − tijdelijk geleend van spaar
                 + komt nog terug
```

- **Tijdelijk geleend van spaar** volgt uit boekingen, niet uit een instelling: een boeking op een betaalrekening
  kan de markering `temporaryLoan` krijgen, bij het lenen (een bijschrijving, +) én bij het terugboeken (een
  afschrijving, −). Uitstaand = som van alle gemarkeerde boekingen op betaalrekeningen t/m de peildag, **met nul
  als ondergrens**.
- **Komt nog terug** = per tag met "Krijg ik terug" én "Tel mee bij ‘nog te besteden’" het openstaande bedrag
  (7.8), alleen als het **positief** is en alleen in het lopende jaar.
- Op de betaalrekening staat geen geld met een bestemming: alles wat gereserveerd is, staat in een potje op spaar.
- **Trendgrafiek** (vrij te besteden per maandeinde, op het Dashboard › Verloop van het jaar en op de telefoon):
  per maandeinde t/m de peildag `saldo − minimaal − tijdelijk geleend`, **zonder** "komt nog terug". (In de
  referentie is dit een bekende kleine afwijking die later gelijkgetrokken wordt met het hoofdgetal; bouw het zo,
  maar houd de berekening op één plek zodat dat makkelijk kan.)

### 8.5 Nog te besteden deze maand: de rekensom

Het hoofdgetal van het Dashboard en de telefoon. Het Dashboard toont het als rekensom waarvan de regels **exact**
optellen tot het hoofdgetal:

```
  Huidig saldo betaalrekening                          saldo van alle betaalrekeningen op de peildag
− Minimaal op de rekening aan het eind van de maand    altijd getoond
− Tijdelijk geleend van spaar                          alleen als er iets uitstaat
+ Komt nog terug                                       alleen als er een tag meetelt (één regel per tag mag)
+ Nog verwacht deze maand                              netto; uit te klappen in inkomsten en uitgaven per post
= Nog te besteden deze maand
```

Dus: **nog te besteden = vrij te besteden + nog verwacht deze maand.**

**Nog verwacht deze maand** is alleen gevuld in het lopende jaar en is de som van drie delen:

1. **Posten die deze maand nog komen.** Het plan van elke post die deze maand verwacht wordt, met plan ≠ 0, waarop
   in deze begrotingsmaand t/m vandaag **nog geen boeking op een betaalrekening** staat en die **niet is
   afgevinkt**. RESERVERINGEN telt mee met de som van de RES-regels; RES-regels zelf niet. Per post met "te laat"
   als `expectedDay` gezet is en vandaag > `expectedDay`. Eén boeking op de post, ook een afwijkend bedrag, en de
   post telt niet meer mee.
2. **Delen van kwartaal- en jaarinkomsten.** Een post met richting IN, frequentie kwartaal of jaar, plan > 0, die
   deze maand **niet** verwacht wordt en waarop deze maand niets geboekt is, telt voor een deel mee:
   - neem de maanden van de post gesorteerd; *vorige* = de laatste verwachte maand vóór deze maand (anders de
     laatste maand van de lijst − 12); *volgende* = de eerste verwachte maand ná deze maand (anders de eerste
     maand + 12);
   - *g* = volgende − vorige, *k* = deze maand − vorige;
   - alleen als g > 1 en 0 < k < g: deel = plan × k ÷ g, **naar beneden afgerond op centen** (gehele deling).
   - In de rekensom: "<post> (k van g delen, komt in <maand>)".
   - Het deel is cumulatief, omdat nog te besteden uitgaat van het saldo: het geld van de vorige uitbetaling is
     dan al deels uitgegeven. In de maand van uitbetaling telt het hele bedrag (als gewone verwachte post, deel 1)
     zolang het er niet is. Uitgaven worden niet verdeeld. Vrij te besteden verandert niet.
3. **Open regels van Nog overboeken**: het netto bedrag van alle gemarkeerde boekingen (`reimburse`) op
   betaalrekeningen die nog niet in een **afgevinkte** overboeking met spaar zitten, met teken vanuit de
   betaalrekening: uitgaven uit een potje geven +, bijschrijvingen naar een potje geven −. In de rekensom als
   regel "Nog over te boeken met spaar".

Zolang er banktransacties op een betaalrekening wachten (status `nieuw`), toont het Dashboard bij het getal een
waarschuwing dat die nog niet meetellen, met een knop Boeken. Bestaat het jaar nog niet: een kaart "Er is nog geen
begroting voor <jaar>." in plaats van het getal.

**Rekenvoorbeeld** (vandaag 10 maart 2027):

| Regel | Bedrag |
|---|---|
| Huidig saldo betaalrekening | € 1.850,00 |
| − Minimaal op de rekening aan het eind van de maand | − € 500,00 |
| + Komt nog terug (Tanken, 60,00 open, tel mee aan) | + € 60,00 |
| + Nog verwacht deze maand | + € 2.215,00 |
| **= Nog te besteden deze maand** | **€ 3.625,00** |

Waarbij "Nog verwacht" uitgeklapt is: Salaris + € 3.000,00 (dag 25, nog niet binnen) · Energie − € 150,00 (dag 5:
te laat) · Verzekering − € 480,00 (jaarpost in maart) · RESERVERINGEN − € 400,00 (som van de RES-regels) ·
Kwartaaluitkering + € 200,00 (2 van 3 delen van € 300,00, komt in apr) · Nog over te boeken met spaar + € 45,00.
Huur (− € 1.200,00) is al geboekt en telt dus niet. Vrij te besteden is € 1.410,00.

### 8.6 Potjes en de spaarrekening

- **Saldo van een potje** = som van de boekingen op de spaarrekening met dat `potId`. Een gemarkeerde uitgave op
  de betaalrekening met een `potId` (Nog overboeken) telt **niet** in het potsaldo; pas de boeking van het
  afvinken doet dat.
- **Niet toegewezen** = saldo spaarrekening − som van alle potjes van die rekening.
- **Beginbedrag**: een potje krijgt bij het aanmaken een beginbedrag (standaard € 0,00), geboekt als handmatige
  boeking "Beginsaldo <naam>" met notitie "Beginsaldo" op de begindatum van de rekening. Daarom is
  `account.openingBalance` van een spaarrekening het **niet toegewezen** deel: beginsaldo bij de bank =
  openingBalance + som van de beginboekingen. Bij het inrichten vult de gebruiker het werkelijke beginsaldo in en
  rekent de app `openingBalance` = werkelijk beginsaldo − som beginbedragen uit.
- **In de min**: een potje mag negatief staan (iets vooruit betaald). Het wordt dan gedekt door de andere
  potjes. "In de min, gedekt door andere potjes" = som van de negatieve potsaldi als positief bedrag, met het
  aantal potjes. Bij zo'n potje toont de app wanneer het weer op nul staat: de eerste dag waarop de vooruitblik
  (Automatisch sparen + open verwachtingen) ≥ 0 komt, tot 10 jaar vooruit; anders "wordt niet aangevuld" (geen
  storting en geen verwachting) of "duurt langer dan 10 jaar".
- **Verplaatsen tussen potjes**: twee handmatige boekingen op dezelfde spaarrekening die samen nul zijn.
- **Potje opheffen**: zonder saldo meteen (archiveren). Met saldo kiest de gebruiker waar het geld heen gaat:
  een ander potje (de app verplaatst het hele saldo en heft op, in één keer) of de betaalrekening (drie stappen:
  overmaken bij de bank, de afschrijving op het potje boeken, opheffen). Een negatief saldo eerst aanvullen.
  Verwijderen kan alleen zonder boekingen.
- **Volgorde in keuzelijsten**: potjes per groep (eerst reservering, dan spaar), binnen de groep op alfabet,
  hoofdletter- en accentongevoelig, met natuurlijke sortering ("Potje 2" vóór "Potje 10"). Posten in keuzelijsten:
  eerst UIT, dan IN, RES laatst, binnen de groep zo op alfabet. "Overig (geen vaste post)" en "Geen" staan bovenaan.
  Het maandgrid en het jaarplan houden hun eigen volgorde (`sortOrder`).

### 8.7 Automatisch sparen en de koppeling met een post

- Een **Automatisch sparen** heeft een naam, een herkomstrekening (betaal), een doelrekening (spaar) en per
  potje een bedrag per maand (> 0, een potje hoogstens één keer, het potje hoort bij de doelrekening). Het
  **totaal** is de som van de regels. Er kunnen er meer zijn; gearchiveerde tellen nergens mee.
- De verdeling over de potjes komt **uit Automatisch sparen**, niet uit de RES-regels. Spaardoelen, de
  vooruitblik, potbedragen per maand en de exports gebruiken Automatisch sparen.
- **Telt in je begroting als**: een UIT-post op de betaalrekening kan eraan gekoppeld zijn; zijn opgeslagen plan
  is dan altijd − het totaal (zie 7.3). Bij een nieuw jaar (kopiëren) gaat de koppeling mee.
- **Ketenstrook** (alleen weergave), overal met dezelfde zinnen:
  - bij een potje: "Krijgt € 37,50 per maand via Automatisch sparen: <naam> (post <post>)." Bij meer
    overboekingen: "… via 2 vaste overboekingen:" met een lijstje;
  - bij een Automatisch sparen: "Telt in je begroting als: post <post>.";
  - bij een post: "Gaat via Automatisch sparen: <naam> naar <n> potjes."
  Met een klik naar de andere kant.
- **Opbouw van RESERVERINGEN** (uitgeklapt in het maandgrid en bij Posten): de regels van de gekoppelde
  Automatisch sparen (potje en bedrag), alleen-lezen, met "Verdeling wijzigen bij Automatisch sparen"; de RES-regels
  apart als groep "RES-regels (oude opbouw)" met hun som per maand.
- **Bij het boeken**: aan de spaarkant wordt een herkende overboeking geboekt als één boeking per regel van de
  verdeling, met label "<naam>: <potje>".

### 8.8 Herkenning van overboekingen: Automatisch sparen tegenover een losse overboeking

Bij elke nieuwe banktransactie wordt in deze **volgorde** gezocht: eerst overboekingen met spaar (7.9), dan
Automatisch sparen, dan regels (7.13). IBAN's worden altijd vergeleken zonder spaties en hoofdletterongevoelig.

**Doelkant** (bijschrijving op de spaarrekening van een Automatisch sparen):

- Past als de tegenrekening het IBAN van de herkomstrekening is, **ook als het bedrag afwijkt** van het totaal.
- Is er geen herkomst ingesteld, heeft de herkomst geen IBAN of heeft de transactie geen tegenrekening: alleen bij
  een bedrag dat **exact het totaal** is. Een bekende, andere tegenrekening past nooit, ook niet bij het exacte bedrag.
- Exact het totaal: voorstel = de verdeling, zeker (als er maar één Automatisch sparen past).
- Klein verschil: voorstel = de vaste verdeling plus "verschil € …"; de regels tellen dan **niet** op tot het
  bankbedrag en de gebruiker kiest waar het verschil heen gaat (twijfelgeval). Er staat ook "Losse overboeking?
  Kies een potje".
- **Groot verschil** (`bedrag < totaal ÷ 2` of `bedrag > totaal × 1,5`; precies de helft of anderhalf keer valt er
  nog binnen; bij een totaal ≤ 0 nooit): **geen verdeling**. Het is een twijfelgeval "Dit lijkt een losse
  overboeking …"; het scherm stelt één potje voor. Kiest de gebruiker toch "de vaste overboeking", dan komt de
  verdeling alsnog.

**Herkomstkant** (afschrijving op de herkomstrekening): past als de tegenrekening het IBAN van de doelrekening
is. Voorstel = één boeking met het bankbedrag op de post die in het jaar van de transactie aan die Automatisch
sparen gekoppeld is; zonder gekoppelde post overig met een melding. De grens voor "los" geldt hier niet.
Zonder herkomstrekening wordt deze kant niet herkend.

**Meer kandidaten**: passen er meer Automatisch sparen (vanaf dezelfde rekening), dan wint de ene waarvan het
totaal gelijk is aan het bedrag; is die er niet precies één keer, dan vraagt de app eerst welke.

**Overboeking op de eigen spaarrekening is geen Nog overboeken.** Kiest de gebruiker bij een banktransactie op
betaal waarvan de tegenrekening een eigen spaarrekening is "Nog overboeken met spaar" of een potje, dan toont de
app: "Dit is een overboeking naar (of: van) je eigen spaarrekening. Kies het potje aan de spaarkant; ‘Nog
overboeken met spaar’ is voor geld dat nog moet verhuizen." Alleen een waarschuwing; boeken blijft mogelijk.

**Overboeking tussen eigen rekeningen** (ook zonder Automatisch sparen): twee banktransacties met tegengesteld
bedrag, waarvan de tegenrekening de andere eigen rekening is, hoogstens 3 dagen uit elkaar, elk in hoogstens één
paar. De boekingen worden aan elkaar gekoppeld (`counterEntryId`, bij een gesplitste kant naar de eerste regel van
de andere kant) en tellen op elke rekening gewoon mee in het saldo. Nakijken en Transacties tonen bij de ene helft
de andere: "+ € 250,00 op Spaarrekening, 4 mrt · wacht nog op een plek" met "Bekijk". Met de hand koppelen mag ook
(alleen verschillende rekeningen en tegengestelde bedragen vereist).

### 8.9 Nog overboeken (met spaar)

- Een boeking op een betaalrekening kan gemarkeerd worden met `reimburse` + `potId` (schakelaar "Nog overboeken
  met spaar"): een **uitgave** "komt uit het potje", een **bijschrijving** "gaat naar het potje". Niet bij bedrag
  nul, niet op spaar.
- **Openstaand** = alle gemarkeerde boekingen zonder `savingsTransferId`. Gesaldeerd:
  - `uit potjes` = som van de gemarkeerde uitgaven (als positief bedrag);
  - `naar potjes` = som van de gemarkeerde bijschrijvingen;
  - **netto = uit potjes − naar potjes**. Positief = over te maken van spaar naar betaal; negatief = van betaal
    naar spaar; nul = alleen verschuiven tussen potjes.
  - Per potje: positief = het potje uit, negatief = het potje in.
- **Vastleggen**: de gekozen open boekingen vormen één overboeking met spaar (`amount` = netto met teken). Ze
  moeten op één betaalrekening staan en hun potjes op één spaarrekening; anders per rekeningpaar apart.
- **Afvinken boekt meteen**, in één transactie, als handmatige boekingen op de dag van afvinken:
  - spaarrekening: per potje één boeking (uit het potje negatief, erin positief), plus één regel zonder potje
    voor gemarkeerde boekingen zonder potje; samen − netto;
  - betaalrekening: één **overige** boeking "Verrekening spaar" van + netto, zonder markering (in het grid dus IN
    of UIT overig, zoals in de Excel);
  - bij netto nul: niets op de betaalrekening;
  - de betaal- en spaarkant verwijzen naar elkaar (`counterEntryId`); alle krijgen de notitie "Verrekening #<id>";
    hun id's gaan in `setting` `savingsTransfer.<id>.entries`.
  De administratie klopt dus zodra de gebruiker bij de bank heeft overgemaakt. Nog eens afvinken boekt niet
  opnieuw. Heropenen of verwijderen haalt de boekingen van het afvinken weg (geweigerd zolang er een banktransactie
  aan hangt).
- **Bij een latere import** wordt de banktransactie van die overboeking herkend: bedrag + netto op betaal of
  − netto op spaar, de tegenrekening is de andere rekening (of ontbreekt), binnen **7 dagen** van het afvinken. De
  banktransactie wordt aan de bestaande boeking gehangen: geen nieuwe boeking, de boeking neemt de dag van de bank
  over, de banktransactie wordt `verwerkt`, het eindsaldo verandert niet. Een nog niet afgevinkte overboeking die
  zo herkend wordt: "Afvinken en koppelen" (afvinken op de dag van de bank, dan koppelen). Meer kandidaten: de
  gebruiker kiest. Draai dit **vóór** regels en eigen-overboeking-koppeling, anders staat het bedrag er twee keer.
- **Bescherming**: boekingen van het afvinken en gemarkeerde boekingen in een overboeking kunnen niet van bedrag,
  rekening, dag of potje veranderen en niet los verwijderd of opnieuw geboekt worden (label, notitie en tags wel).
- **Aandacht**: een afgevinkte overboeking (netto ≠ 0) waarvan na **5 dagen** (oudste boeking van het afvinken
  zonder banktransactie + 5 ≤ vandaag) nog niet aan beide kanten een banktransactie hangt: "Overboeking met spaar
  van € … op <dag> is nog niet gezien in een bankbestand." Bij meer dan één: "N overboekingen (samen € …) zijn nog
  niet gezien in een bankbestand, de oudste van <dag>."

### 8.10 Tags, Krijg ik terug en Tel mee

- **Tags staan alleen op boekingen van een betaalrekening.** Een tag op spaar wordt geweigerd. Een tag telt niet
  als extra uitgave; een boeking met twee tags telt bij beide tags mee.
- **Krijg ik terug** (`tag.settles`): uitgaven met die tag krijgt de gebruiker later terug.
- **Openstaand** ("Nog terug te ontvangen: € …"):

  ```
  openstaand = startbedrag (als het nog niet in een terugbetaling zit)
             − som van alle boekingen op betaalrekeningen met deze tag zonder settlementId
  ```

  Uitgaven zijn negatief, dus ze verhogen het openstaande bedrag. Boekingen op spaar tellen niet mee.
- **De terugbetaling taggen** (de huidige werkwijze): de gebruiker geeft de bijschrijving van het geld dat
  terugkomt **dezelfde tag**. Die bijschrijving telt in de som hierboven af: een deel terug verlaagt het
  openstaande bedrag, alles terug maakt het € 0,00. "Komt nog terug" valt dan weg en nog te besteden blijft gelijk,
  want het geld staat nu op de rekening. Er is geen knop "Het is binnen…".
- **Herkennen**: is een nog niet geboekte bijschrijving op betaal (bijna) gelijk aan het openstaande bedrag van
  een tag (exact, of binnen € 1,00), dan vragen Nakijken en Transacties "Is dit je € … van <tag> terug?" met de
  knop "Tag <tag>": boekt als overig met die tag. Exact eerst, dan op naam.
- **Startbedrag**: wat er bij de start al openstond (bijvoorbeeld uit de Excel-periode), met een dag. Alleen bij
  Krijg ik terug, niet negatief, € 0,00 haalt het weg. Zit het in een vastgelegde terugbetaling, dan is het niet
  meer te wijzigen tot die ongedaan is gemaakt.
- **Beginstand bij aanzetten**: zet de gebruiker Krijg ik terug aan vanaf een dag, dan worden alle boekingen met
  de tag van vóór die dag in één beginstand-terugbetaling (`isOpening`, bedrag mag 0) gezet: die staan niet open.
- **Vastgelegde terugbetalingen** (oude werkwijze, blijft werken en blijft zichtbaar in de geschiedenis met
  "Maak ongedaan"): een terugbetaling legt een selectie open boekingen (en eventueel het startbedrag) vast;
  bedrag = startbedrag − som van de boekingen; selectie met negatief totaal wordt geweigerd. De boekingen krijgen
  `settlementId` en staan niet meer open.
- **Tel mee bij ‘nog te besteden’** (`countsInSpendable`, standaard uit): het openstaande bedrag telt als "Komt
  nog terug: <tag>" mee in vrij te besteden en nog te besteden, alleen als het positief is en in het lopende jaar.

### 8.11 Minimaal op de rekening en de melding

- "Minimaal op je betaalrekening aan het eind van de maand" is één bedrag per jaar, in te stellen bij Posten en
  bij de eerste start.
- Het zit al in de rekensom (7.5). Is **nog te besteden negatief**, dan meldt Aandacht dat het minimum aan het
  eind van de maand niet gehaald wordt, met het tekort (= − nog te besteden).

### 8.12 Spaardoel, vooruitblik en verwachtingen

**Verwachtingen** (`forecastItem`): een bedrag met teken bij een potje op een dag. Ze tellen **nergens** anders
in mee dan in de vooruitblik en het spaardoel. Een verwachting wordt "uitgekomen" (afgevinkt) met de echte
boeking; voorstel bij een boeking: open verwachtingen van dat potje met hetzelfde teken, bedrag exact of binnen 5 %,
dag binnen 45 dagen, exact eerst. Een boeking hoort bij hoogstens één verwachting.
"**Elke maand**" met "Tot en met": één verwachting per maand op dezelfde dag (in een kortere maand de laatste
dag), hoogstens 60; zonder project wordt de omschrijving het project. Verwachtingen met hetzelfde project vormen
een begroting: gepland (alle), betaald (uitgekomen: het bedrag van de echte boeking, anders het verwachte),
nog te komen (open).

**Vooruitblik** van een potje (van morgen t/m een einddatum):

- startsaldo = het echte potsaldo vandaag;
- **los**: open verwachtingen met een dag ná vandaag. Open verwachtingen op of vóór vandaag zijn "over tijd" en
  tellen niet mee (ze staan apart in beeld);
- **terugkerend**: per niet-gearchiveerde Automatisch sparen met een regel voor dit potje één bijschrijving per
  maand. De dag van de maand = de dag van de laatste echte bijschrijving van precies dat bedrag op het potje;
  zonder zo'n bijschrijving de **25e**; in een kortere maand de laatste dag. De lopende maand telt alleen mee als
  de storting deze maand nog niet binnen is; is de gewone dag al voorbij, dan staat hij op morgen (en niet als
  morgen al in de volgende maand valt);
- **eerdere uitgaven** (alleen met "Reken met eerdere uitgaven" aan): vanaf de maand na vandaag elke maand op de
  **15e** het gemiddelde van de uitgaven. Gemiddelde = som van de **negatieve** boekingen op het potje over de
  afgelopen hele maanden vóór de lopende maand, hoogstens 12, gedeeld door dat aantal maanden (gehele deling,
  afgerond richting nul). Bij een jong potje: het aantal maanden vanaf de maand van de eerste boeking t/m de vorige
  maand; zonder hele maand geen gemiddelde. Telt niet mee: boekingen gemarkeerd als eenmalig, en boekingen waarmee
  een verwachting is uitgekomen. Het gemiddelde staat ook bij de schakelaar als die uit staat.
- Op één dag eerst wat erbij komt, dan wat eraf gaat. Per gebeurtenis het saldo erna; het laagste punt vanaf
  vandaag (onder nul = tekort). De grafiek toont het echte saldo per maandeinde over de afgelopen 12 maanden en
  daarna de verwachte punten.
- **Aandacht**: "Potje … komt binnen een jaar onder nul" als een potje met "Reken met eerdere uitgaven" aan nu
  niet negatief staat en in de vooruitblik binnen een jaar onder nul komt.

**Spaardoel** (doelbedrag > 0, optioneel een doeldatum):

- `nog nodig` = max(0, doel − saldo).
- `verwachte losse bedragen` = som van de open verwachtingen van morgen t/m de doeldatum (uitgaven negatief).
- `stortmomenten` = het aantal dagen van morgen t/m de doeldatum waarop een maandstorting komt (zelfde ritme als
  de vooruitblik, van de eerste Automatisch sparen van het potje; zonder: de 25e).
- **Nodig per maand** = (nog nodig − verwachte losse bedragen) ÷ stortmomenten, **naar boven afgerond** op centen,
  minimaal € 0,00; leeg zonder datum of zonder stortmoment.
- **Nu per maand** = som van de regels van het potje in niet-gearchiveerde Automatisch sparen.
- **Tekort per maand** = nodig − nu (positief = te weinig).
- **Verwacht op de doeldatum** = saldo + alle gebeurtenissen van de vooruitblik t/m de doeldatum.
- **Status**: `bereikt` (saldo ≥ doel) · anders zonder datum `zonder datum` · datum voorbij: `verlopen` · anders
  `op koers` als verwacht op de doeldatum ≥ doel − marge, anders `tekort`.
- **Marge** = doel × basispunten ÷ 10.000, naar beneden afgerond op centen; standaard 50 basispunten (0,5 %), te
  kiezen 0 / 0,5 / 1 / 2 %, één instelling voor alle potjes. Op koers maar onder het doel: "op koers (binnen de
  marge)". Alleen de status verandert, niet "nodig per maand".
- **Doel gehaald op**: de eerste dag waarop de vooruitblik het doel haalt, tot 10 jaar vooruit (vandaag als het al
  bereikt is).
- **Uit onderdelen**: het doelbedrag is de som van aantal × bedrag per stuk van de onderdelen, getoond onder het
  doel.
- **Aandacht**: spaardoelen met status `tekort` of `verlopen` (dus buiten de marge).

### 8.13 Regels en "Voortaan zo indelen"

**Voorwaarden** (alle ingevulde moeten kloppen): tegenpartij-naam bevat; tegenpartij-IBAN gelijk; omschrijving
bevat trefwoord; bedrag exact (met teken); optioneel alleen voor een rekening. Tekst hoofdletter- en
accentongevoelig, dubbele spaties tellen niet. Uitgeschakelde regels en regels zonder voorwaarde matchen nooit.

**Zekerheid**:

| Situatie | Zekerheid |
|---|---|
| Tegenpartij (naam of IBAN) én bedrag kloppen | hoog ("zeker") |
| Tegenpartij klopt, regel heeft geen bedrag | midden |
| Tegenpartij klopt, bedrag van de regel wijkt af | midden, met "bedrag wijkt af (verwacht € …)" |
| Trefwoord in de omschrijving, zonder tegenpartij-voorwaarde (ook met kloppend bedrag) | midden |
| Alleen bedrag | laag |
| Geen regel | geen |

**Winnaar**: hoogste zekerheid → laagste `priority` → volledige match vóór "bedrag wijkt af" → meeste kloppende
voorwaarden (`accountId` telt mee) → laagste id.

**Voorstel**: de post wordt per jaar op label gezocht (hoofdletterongevoelig) in het jaar van de **datum van de
transactie**; bestaat het jaar of de post niet, dan geen post en een melding ("De post 'X' bestaat niet in 2028.").
Omschrijving: die van de regel, anders de voorgestelde omschrijving (8.4), anders "Onbekend". Tags: die van de
regel, maar leeg op een spaarrekening.

**Richting bij Nog overboeken** (`reimburseDirection`): een regel zet alleen in zijn richting om naar Nog
overboeken (`erin` = bedrag positief, `eruit` = negatief, `beide`). In de andere richting stelt dezelfde regel de
post, de omschrijving en de tags voor, maar **géén** Nog overboeken en **géén** potje, met zekerheid **laag** en een
melding ("Regel 'X' zet alleen bij geld eruit om naar Nog overboeken; …"). Zo'n voorstel is een twijfelgeval en
wordt nooit automatisch geboekt. Zonder Nog overboeken geldt het potje van de regel altijd (bijvoorbeeld op spaar).
Aanleiding: een regel voor de rekening van een kind, gemaakt bij geld dat binnenkwam voor het spaarpotje van dat
kind, haalde ook het zakgeld dat naar het kind ging van dat potje af.

**Regels alleen met toestemming.** Boeken maakt of wijzigt nooit vanzelf een regel. Nakijken en Transacties
gebruiken hetzelfde vinkje en dezelfde voorstellen:

- **Geen regel deed een voorstel** → vinkje "Voortaan zo indelen", standaard uit. Aangevinkt toont het één
  samenvattingszin, bijvoorbeeld "Voortaan bij Energie Test BV (NL00TEST0000000050): post Energie" of "Voortaan bij
  Kind 1 Voorbeeld: overig, nog overboeken met potje Zakgeld Kind 1 bij geld eruit", plus "Aanpassen…" (de
  regeleditor, voorgevuld). Het concept:
  - voorwaarde op de tegenpartij: het IBAN, anders de naam, anders een trefwoord uit een herkenbare omschrijving
    (pinbetaling of naamveld); lukt dat niet, dan geen vinkje;
  - een bedrag als voorwaarde alleen als het doel een vaste post is én tegenpartij + bedrag minstens twee keer
    gezien zijn (deze transactie meegeteld);
  - acties: de keuze (post, potje, Nog overboeken met de richting van deze transactie, omschrijving, tags);
  - omschrijving: alleen vastleggen als de gebruiker iets anders koos dan de voorgestelde omschrijving; anders
    houdt elke volgende overboeking haar eigen tekst;
  - `origin` geleerd, `priority` achteraan.
  De regel wordt bij het boeken bewaard, precies zoals getoond.
- **Een regel deed een voorstel en de keuze wijkt af** → vinkje "Regel bijwerken met deze keuze", standaard uit.
  Aan: die regel krijgt de nieuwe acties, zijn voorwaarden blijven. Uit: de boeking is een uitzondering.
  Nog overboeken: gekozen in de andere richting dan de regel al deed → richting wordt `beide`; uitgezet in de
  richting van de regel → uit; uitgezet bij `beide` → alleen nog de andere richting.
- **Keuze gelijk aan het voorstel** → geen vinkje; de regel telt als gebruikt (`hitCount` + 1, `lastUsed`).
- "Waarom dit voorstel?" toont de reden ("Regel 'Energie': tegenpartij en bedrag") met "Regel aanpassen…".
- Na bewaren: "Regel bewaard: Voortaan bij …" met "Maak ongedaan" (verwijdert een nieuwe regel of zet een
  bijgewerkte terug).

**Indeling in Nakijken en Transacties** (zeker / waarschijnlijk / twijfel), gedeeld:

| Bron van het voorstel | Groep |
|---|---|
| Overboeking met spaar herkend | twijfel (de gebruiker bevestigt) |
| Automatisch sparen: één kandidaat, exact het bedrag, verdeling gevolgd | zeker |
| Automatisch sparen: anders (verschil, los, meer kandidaten) | twijfel |
| Regel met afwijkend bedrag of met een melding | twijfel |
| Regel `hoog` | zeker |
| Regel `midden` | waarschijnlijk |
| `laag` of `geen`, maar een eigen overboeking (andere helft gevonden) | waarschijnlijk |
| `laag` of `geen`, anders | twijfel |

Tellers overal dezelfde regel: "Nog 3 na te kijken · 4 zeker". Twijfelgevallen eerst.

### 8.14 Maandbalans en wat-als

- **Maandbalans** = geplande inkomsten per maand − geplande uitgaven per maand. Per post: plan per maand = plan ×
  aantal keer per jaar ÷ 12, afgerond op centen. RES-regels doen niet mee; RESERVERINGEN en posten bij een
  Automatisch sparen wel. Per jaar: plan × aantal keer, zonder afronding per maand.
- **Wat-als**: per post een proefbedrag (zelfde tekenregels als het plan, niet voor RES-regels). De wat-als-balans
  gebruikt dat bedrag waar het is ingevuld en anders het plan. Er verandert niets tot de gebruiker "Maak hier het
  plan van" kiest; dan wordt elk wat-als-bedrag het plan en worden alle wat-als-bedragen gewist. Posten met een
  berekend plan (RESERVERINGEN, posten bij Automatisch sparen) worden overgeslagen en gemeld.

### 8.15 Hulpje "Nieuw jaarbedrag"

Zet een jaarlijkse kost in één keer goed: potje + regel in Automatisch sparen + post + optioneel een verwachting.

- Invoer: naam, bedrag per jaar (> 0), nieuw of bestaand potje (reservering), welke Automatisch sparen (of een
  nieuwe, met de eerste betaalrekening als herkomst), de post (volgt vanzelf als de overboeking al aan een post
  hangt, anders kiezen of nieuw), en optioneel de maand van de rekening (als verwachting).
- **Per maand** = jaarbedrag ÷ 12, **half naar boven** afgerond op centen (€ 100,00 → € 8,33; € 500,00 → € 41,67).
- Vóór opslaan de samenvatting: "Er gaat elke maand € … naar potje X via Automatisch sparen: Y; je begroting rekent
  met € … op post Z. Let op: verhoog je overboeking bij de bank naar € …".
- Opslaan (alles of niets): het potje maken of kiezen; in de overboeking het bedrag van dat potje verhogen met het
  maandbedrag; de post koppelen als dat nog niet zo was; eventueel een verwachting van − het jaarbedrag op de 1e
  van de gekozen maand (dit jaar als de maand nog komt of nu is, anders volgend jaar). Rekent met het lopende jaar.
- Is de post RESERVERINGEN en heeft het jaar RES-regels, dan verhoogt het hulpje ook de RES-regel van dat potje
  (of maakt er een), zodat het grid meegaat.

### 8.16 Saldo controleren en afstemmen

- **Afstemmen**: de gebruiker voert het banksaldo op een dag in; verschil = berekend − werkelijk; moet € 0,00 zijn.
  Elke controle wordt vastgelegd.
- **Automatisch afstemmen**: is een import helemaal verwerkt (geen transactie van die rekening t/m de laatste dag
  meer `nieuw`) en is het berekende saldo op de laatste dag gelijk aan het eindsaldo van het bestand, dan legt de
  app stil een afstemming vast (één per rekening per dag). Dit gebeurt bij het openen en na elke boek-, oversla- of
  koppelactie.
- **Controle na import**: elke geïmporteerde regel is verwerkt of overgeslagen; het berekende saldo is gelijk aan
  het eindsaldo van het bestand. Overgeslagen transacties tellen niet in het saldo en geven dus een verschil,
  tenzij er een handmatige boeking tegenover staat.

### 8.17 Omschrijvingen

- De omschrijving van een boeking komt uit de regel of van de gebruiker; de tekst van de bank blijft bewaard.
- **Totalen per omschrijving**: overige boekingen op betaal gegroepeerd op genormaliseerde omschrijving (spaties
  weg vooraan en achteraan, meervoudige spaties samen, hoofdletterongevoelig); getoond met de meest gebruikte
  schrijfwijze.
- **Aanvullen bij typen**: begint-met vóór bevat, dan vaakst gebruikt, dan laatst gebruikt.
- **Bijna gelijk** ("Bedoel je ‘Zakgeld’?"): alleen verschil in spaties, leestekens of accenten; of evenveel
  woorden waarvan precies één verschilt als enkelvoud/meervoud (-s, -en) of als tikfout (bewerkingsafstand 1 bij
  woorden t/m 6 letters, 2 bij langere; twee verwisselde letters tellen als 1). Een verschil in een cijfer, een heel
  woord of een woord korter dan 4 letters telt als anders ("Zakgeld Kind 1" en "Zakgeld Kind 2" zijn verschillend).
- **Samenvoegen**: alle boekingen én regels met de ene schrijfwijze krijgen de andere, ook in afgesloten jaren.

### 8.18 Grenzen in Aandacht (constanten)

| Grens | Waarde |
|---|---|
| Laatste bankbestand te oud | 14 dagen |
| Grote uitgave op komst | € 250,00 of meer, verwachte en nog niet geboekte uitgave van een post die niet elke maand komt |
| Overboeking met spaar niet gezien | 5 dagen na afvinken |
| Afstemming te oud | 35 dagen (of nooit afgestemd sinds de begindatum) |
| Herkenning overboeking met spaar | 7 dagen |
| Eigen overboeking koppelen | 3 dagen |
| Terugbetaling van een tag herkennen | exact of binnen € 1,00 |
| Losse overboeking | < helft of > anderhalf keer het totaal |

---

## 8. Import

### 9.1 De stappen

1. **Lezen.** Elke regel van het bestand wordt een banktransactie of een gemelde fout ("Regel 12: ongeldig
   bedrag"). Geen regel verdwijnt stil. Meldingen: ongeldige datum, ongeldig bedrag, ongeldig saldo, onbekende
   af/bij-aanduiding, te weinig kolommen, aanhalingsteken niet afgesloten.
2. **Voorvertoning** (schrijft niets): aantal nieuw, aantal al bekend, foute regels, de saldoketen (sluit / sluit
   niet / niet te controleren), begin- en eindsaldo, en waarschuwingen (zie onder).
3. **Importeren** in één databasetransactie. Met foute regels weigert de import, tenzij de gebruiker bewust "foute
   regels overslaan" kiest. Bij een fout in één bestand van een zip wordt niets van de hele zip geïmporteerd.
4. **Voorstellen**: de regels, Automatisch sparen en Nog overboeken doen per nieuwe transactie een voorstel met
   zekerheid (hoofdstuk 7). Twijfelgevallen eerst, daarna boeken.
5. **Nieuwe boekingen** uit een import krijgen `reviewed = false` ("nog niet gecontroleerd") tot de gebruiker ze
   heeft bekeken.
6. **Wachtrij**: geïmporteerde transacties blijven `nieuw` tot ze geboekt of overgeslagen zijn, ook na het
   sluiten van de app.
7. **Controle achteraf**: zie 6.16. Sluit het saldo na een import niet aan terwijl er op die rekening niets meer
   wacht, dan meldt Aandacht: "Het saldo van <rekening> sluit niet aan: bank € …, app € … op <dag>."

### 9.2 Saldoketen

- Alleen als **elke** gelezen regel een saldo heeft (anders: "niet te controleren").
- Saldo vóór mutatie + bedrag = saldo vóór mutatie van de volgende regel (in tijdsvolgorde). Levert de bank het
  saldo ná de mutatie, dan reken je om.
- De regels worden op dag gesorteerd; binnen een dag kiest de lezer de volgorde (volgnummer van de bank,
  bestandsvolgorde of omgekeerd) die de minste breuken geeft. Zo maakt het niet uit of het bestand oud→nieuw of
  nieuw→oud staat.
- Een breuk is een **waarschuwing** (met regelnummers, verwacht en gevonden saldo) en houdt importeren niet tegen;
  `importBatch.chainOK` wordt false.
- Beginsaldo = saldo vóór de eerste meegaande regel; eindsaldo = saldo na de laatste regel. Beide worden getoond en
  bewaard.

### 9.3 Dubbelen

- **Vingerafdruk** per regel = SHA-256 over: rekening-id, dag, bedrag, IBAN van de tegenpartij, volgnummer van de
  bank, afschriftnummer, omschrijving, en een **volgnummer voor verder gelijke regels binnen hetzelfde bestand**
  (0, 1, 2 …). Naam van de tegenpartij en saldo tellen niet mee.
- Een regel waarvan de vingerafdruk al bestaat, wordt overgeslagen en geteld als "al bekend". Hetzelfde of een
  overlappend bestand opnieuw importeren voegt dus niets dubbel toe, terwijl twee écht gelijke regels op één dag
  allebei binnenkomen.
- De vingerafdruk wordt binnen de importtransactie opnieuw gecontroleerd.

### 9.4 Eerste import: aansluiten op het beginsaldo (de naad)

Alleen bij de eerste import van een rekening (nog geen enkele banktransactie). Het bestand begint meestal vóór
de begindatum; de vingerafdruk kent die regels niet. Volgorde: **eerst op saldo, dan op datum, dan met de hand.**

1. **Op saldo.** Het gezochte saldo is het saldo van de rekening in de app (beginsaldo + alle boekingen, ook
   handmatige). Zoek in tijdsvolgorde de regel waarvan het **saldo vóór de mutatie** gelijk is aan dat saldo. Alle
   regels daarvóór gaan niet mee ("N regels vóór regel X (<dag>) zijn overgeslagen: het saldo € … sluit daar
   aan."). Dit werkt ook midden op een dag.
   - **Meer kandidaten**: de vroegste waarna de keten nergens breekt wint, met een waarschuwing en de lijst
     kandidaten. Breekt de keten na elke kandidaat: de kandidaat waarbij het eindsaldo aansluit, anders de vroegste.
   - **Alles al verwerkt**: het gezochte saldo is gelijk aan het saldo ná de laatste regel → niets nieuw, met een
     melding.
   - **Niet gevonden**: "Geen regel in dit bestand sluit aan op het saldo € … van je administratie. Het bestand
     begint met € … en eindigt met € …." Dan stap 2.
2. **Op datum** (terugval): regels met een dag vóór de begindatum van de rekening gaan niet mee ("… die vallen vóór
   je beginsaldo."); regels óp de begindatum gaan mee.
3. **Met de hand**: de gebruiker zet per regel aan of uit (uitzetten wint); tellingen en beginsaldo worden opnieuw
   bepaald. Een regel die al in de database staat, gaat ook na aanzetten niet mee.

Regels die niet meegaan blijven grijs zichtbaar in de voorvertoning, tellen niet als nieuw of dubbel, en de
saldoketen wordt over het hele bestand gecontroleerd. Na de eerste import doet de vingerafdruk het werk.

### 9.5 Het voorbeeldformaat van de referentiebank

De referentiebank levert bij "download transacties" **één zip met één CSV per rekening**. De bestandsnaam begint
met het IBAN van de rekening, bijvoorbeeld `NL00TEST0000000001-13-03-2027T13_33_15.csv`.

Per CSV: **geen kopregel**, 19 kolommen, komma als scheidingsteken, bedragen met een punt als decimaalteken en een
min-teken (`-12.50`). Kolommen (vanaf 0):

| Kolom | Inhoud | Gebruikt als |
|---|---|---|
| 0 | boekingsdatum `dd-mm-jjjj` | `day` (verplicht) |
| 1 | eigen IBAN | controle: hoort het bestand bij deze rekening? |
| 2 | IBAN tegenpartij | `counterpartyIban` |
| 3 | naam tegenpartij | `counterpartyName` |
| 4 | adres tegenpartij | niet gebruikt |
| 5 | postcode tegenpartij | niet gebruikt |
| 6 | plaats tegenpartij | niet gebruikt |
| 7 | valuta rekening | niet gebruikt |
| 8 | saldo vóór mutatie | `balanceBefore` (saldoketen, naad) |
| 9 | valuta mutatie | niet gebruikt |
| 10 | bedrag met teken | `amount` (verplicht) |
| 11 | journaaldatum | niet gebruikt |
| 12 | valutadatum | niet gebruikt |
| 13 | interne transactiecode | niet gebruikt |
| 14 | globale transactiecode (bv. `PIN`, `INC`, `OVB`, `BEA`, `GEA`, `IDB`) | `transactionCode` |
| 15 | volgnummer | `sequence` |
| 16 | betalingskenmerk | `reference` |
| 17 | omschrijving | `descriptionText` |
| 18 | afschriftnummer | alleen in de vingerafdruk |

Alleen datum en bedrag zijn verplicht; ontbrekende kolommen daarna geven een lege waarde.

**Zip-regels**: uitpakken in een eigen tijdelijke map; een pad dat buiten die map uitkomt (`..`, absoluut pad)
weigert het hele archief. Per bestand: CSV (`.csv`, `.txt`) en eventueel PDF worden gelezen; een ander type, een
leeg bestand, een bestand zonder IBAN of met een onbekend IBAN gaat niet mee, met een melding ("Geen rekening met
IBAN … gevonden."). Systeembestanden van het besturingssysteem worden zonder melding genegeerd. De rekening is het
meest voorkomende eigen IBAN in de regels, anders het IBAN in de bestandsnaam. Twee bestanden voor dezelfde
rekening in één zip mogen overlappen. Per bestand een eigen importbatch.

**Los bestand**: de app stelt de rekening voor op basis van het IBAN; past het IBAN in het bestand niet bij de
gekozen rekening, dan een waarschuwing met de rekening waar het wel bij hoort.

**CSV lezen in het algemeen**: codering UTF-8 (met of zonder BOM), dan Windows-1252, dan ISO-8859-1.
Scheidingsteken (`,` `;` tab) en aanhalingsteken (`"` `'`) raden uit de eerste 100 regels. Velden tussen
aanhalingstekens mogen het scheidingsteken, regeleinden en een verdubbeld aanhalingsteken bevatten. Lege regels
tellen niet mee. Regelnummers wijzen naar de regel in het bestand.

**PDF-rekeningafschrift** (optioneel, terugvaloptie): dezelfde voorvertoning; saldo per regel uitgerekend vanaf
het beginsaldo van het afschrift; de keten sluit als beginsaldo + som = eindsaldo. Gebruik per rekening óf CSV óf
PDF, anders komen regels dubbel binnen (andere omschrijving, andere vingerafdruk).

### 9.6 Een andere bank: een eigen inleesmodule

Het formaat hierboven is een **voorbeeld**. Een andere bank krijgt een **eigen inleesprofiel** binnen de
importmodule (een kolomindeling, of een eigen lezer voor een ander bestandstype). De rest van de app merkt daar
niets van. Bouw daarnaast:

- een **algemeen profiel** dat een CSV met kopregel herkent aan gangbare Nederlandse en Engelse kolomnamen (datum
  / date, bedrag / amount, naam / name, tegenrekening / iban, omschrijving / mededelingen / description, saldo na /
  voor mutatie, af bij, volgnr …); zonder datum- en bedragkolom: geen profiel;
- **kolommen met de hand kiezen** als geen profiel past, te bewaren als eigen profiel;
- een **af/bij-kolom** voor banken die bedragen zonder teken leveren (af: `af`, `d`, `debet`, `debit`, `db`,
  `dr`; bij: `bij`, `c`, `credit`, `cr`; een onbekende waarde is een fout op de regel);
- meer **datumnotaties** (`dd-MM-yyyy`, `yyyy-MM-dd`, `MM/dd/yyyy`, `dd-MM-yy`, `yyyyMMdd`), in volgorde
  geprobeerd; het scheidingsteken mag afwijken en er mag een tijd achter staan.

**Wat een inleesmodule minimaal moet leveren**, per regel:

| Veld | Verplicht | Waarom |
|---|---|---|
| boekingsdatum | ja | saldo, maand, vingerafdruk |
| bedrag met teken (of bedrag + af/bij) | ja | alles |
| eigen IBAN (per regel, in de kop of in de bestandsnaam) | sterk aanbevolen | de juiste rekening kiezen, zip verdelen |
| IBAN tegenpartij | sterk aanbevolen | regels, eigen overboekingen, Automatisch sparen, Nog overboeken herkennen |
| naam tegenpartij | sterk aanbevolen | regels, voorgestelde omschrijving |
| omschrijving | sterk aanbevolen | trefwoord-regels, eigen tekst, vingerafdruk |
| saldo vóór of ná de mutatie | sterk aanbevolen | saldoketen, naad op saldo, automatisch afstemmen |
| transactiecode | aanbevolen | onderscheid pin/incasso/overboeking bij de omschrijving |
| volgnummer van de bank | aanbevolen | volgorde binnen een dag, vingerafdruk |
| betalingskenmerk, afschriftnummer | optioneel | bewaren, vingerafdruk |

Zonder saldo werkt de import nog (geen keten, naad alleen op datum), maar valt de controle "sluit op € 0,00" weg.

### 9.7 Namen opschonen en de voorgestelde omschrijving

**Opschonen van een naam** (voor de omschrijving en de naam van een nieuwe regel; regels matchen altijd op de
ruwe tekst, bestaande boekingen worden niet hernoemd):

- spaties samenvoegen;
- pinautomaat-ruis weg: voorvoegsels als "BEA, Betaalpas", "CCV*", staarten als ",PAS123 NR:… 12.11.27/14:03";
- een landcode achteraan weg; bij pinbetalingen ook plaats en filiaalnummer;
- rechtsvormen weg: B.V., BV, N.V., VOF, C.V., GmbH, Ltd, Inc, LLC;
- alles in hoofdletters → woorden met een hoofdletter: "BAKKERIJ VOORBEELD" → "Bakkerij Voorbeeld". Tekst met
  gemengde hoofdletters blijft zoals hij is;
- **pinnamen met plaats en datum na ">"**: alles vanaf ">" weg als daarna alleen een plaats en/of een datum staat
  (en de plaats aan ">" vastzit of er een datum is); daarna een losse letter achteraan en een voorloopnummer van
  twee of meer cijfers weg; staat er vóór ">" alleen een nummer, dan wordt de plaats de naam. Voorbeelden:
  "Winkel Voorbeeld >VOORBEELDSTAD13.03.2027" → "Winkel Voorbeeld"; "0712 FRIETKRAAM DEMO S>VOORBEELDSTAD12.03.2027"
  → "Frietkraam Demo". Zo'n naam telt als pinbetaling;
- is de naam van de tegenpartij leeg: een naam uit de omschrijving (pinbetaling, `/NAME/…/`, `Naam: …`), anders de
  omschrijving zelf, hoogstens 40 tekens.

**Voorgestelde omschrijving** (als geen regel een omschrijving geeft): bij een overboeking met een korte, eigen
tekst is dat die tekst ("Zakgeld", "Oppas zaterdag", "Cadeau verjaardag"); anders de opgeschoonde tegenpartij. Geen
eigen tekst bij:

- een transactiecode van pin, geldautomaat, incasso, iDEAL, acceptgiro, kosten of rente (zoals `BEA`, `GEA`,
  `INC`, `IDB`, `ACC`, `KST`, `RNT` en de korte codes van andere banken); overboekingscodes (`OVB`, `IOB`, `POV`) en
  onbekende codes laten de keuze aan de tekst;
- gestructureerde tekst (`/`, `:`, `*`, links), vijf of meer cijfers achter elkaar, of meer cijfers dan letters;
- tekst die begint met iDEAL, SEPA, incasso, betaalautomaat en dergelijke, of een zakelijk woord bevat (factuur,
  termijn, kenmerk, contributie, polis …);
- meer dan 30 tekens of meer dan 4 woorden;
- tekst gelijk aan (een deel van) de tegenpartij;
- geen tegenpartij: dan de naam uit de omschrijving.

Een omschrijving uit een regel gaat altijd voor. Een via "Voortaan zo indelen" gemaakte regel legt de eigen tekst
niet vast (zie 7.13).

### 9.8 Downloadadvies

Op Transacties staat welke bankbestanden de gebruiker moet downloaden: "Bijwerken: download bij de bank de
CSV-export (zip, één bestand per rekening) van <rekeningen>, van <dag> tot en met <vandaag>." De begindag is de
**vroegste** laatste-banktransactiedatum over alle niet-gearchiveerde rekeningen (zonder banktransacties: de
begindatum van die rekening). Die dag zit er bewust in als overlap: dubbele regels worden overgeslagen. Bij
aanwijzen per rekening de laatste banktransactie.

---

## 9. Schermen

### 10.1 UX-lessen (gelden voor elk scherm)

Deze lessen komen uit een test met de gebruiker en zijn bindend:

- **Weinig tekst.** De eerste aanblik van elk scherm is rustig. Geen grijze uitlegzinnen onder titels; uitleg staat
  in een tooltip of achter een klik. Een begrip krijgt hoogstens één korte zin, op de plek waar het staat.
- **Kaartjes met totalen.** Bovenaan een scherm staan een paar kaartjes met het totaal en de belangrijkste details;
  de lijst staat eronder.
- **In en uit gescheiden.** Inkomsten en uitgaven staan in aparte groepen of zijn met een filter Alles / In / Uit
  te scheiden. Ook kaartjes tonen in en uit apart.
- **Nergens € 0,00 als het eigenlijk "nog niet" betekent.** Toon het plan, het werkelijke bedrag, of het plan met
  "afgevinkt".
- **Eén ding, één woord, overal** (hoofdstuk 4). Een koppeling staat aan beide kanten met dezelfde zin.
- **Bij een openstaand bedrag: zeg wat de volgende stap is**, met een knop naar de plek waar je het rechtzet.
- **Lege kaartjes niet tonen.** Een kaartje verschijnt alleen als er iets in staat.
- **Riskante knoppen kleiner.** "Sla over" (haalt een transactie uit het saldo) is kleiner dan "Boek".
- **"Maak ongedaan"** na elke actie in Nakijken en Transacties, ook na het bewaren van een regel.
- **Het maandgrid mag compact zijn**; het is het vertrouwde jaarblad. Alle andere schermen zijn ruim.
- **Venstermaten**: elk scherm werkt in de gewone en de kleinste venstermaat (in de referentie 1100 × 700 punten):
  de titel blijft op één regel, niets schuift horizontaal buiten beeld, de zijbalk blijft zichtbaar. In een smal
  venster komen tabbladen onder de titel of worden ze een keuzemenu. Grijze bijschriften moeten goed leesbaar zijn.
- **Licht en donker** worden allebei ondersteund.
- **Bedragvelden rekenen** (`249*4`).

### 10.2 Eerste start

Bij de eerste start kiest de gebruiker tussen **rondkijken met voorbeelddata** en **eigen administratie
beginnen**. Wisselen kan later bij Instellingen › Over. Eigen administratie beginnen vraagt minimaal: rekeningen
(naam, IBAN, soort, beginsaldo, begindatum), het jaar met "Minimaal op je betaalrekening aan het eind van de maand",
de posten, en de potjes met beginbedrag (de app rekent het niet toegewezen deel uit). Met voorbeelddata start de app
op het Dashboard; met de eigen administratie mag het startscherm Transacties of Dashboard zijn.

### 10.3 Zijbalk

Ingedeeld naar wat je komt doen. Eén lijst in de code, die zowel de echte zijbalk als de zelftest leest.

| Groep | Schermen | Teller |
|---|---|---|
| **Vandaag** | Dashboard · Te doen | Te doen: aantal kaartjes met inhoud |
| **Bijwerken** | Importeren en nakijken · Transacties · Tags | Nakijken: wachtende banktransacties · Transacties: nog niet gecontroleerd · Tags: tags met iets terug te ontvangen |
| **Begroting** | Posten | |
| **Sparen** | Potjes · Automatisch sparen | |
| **Inzicht** | Maandgrid (en Rapporten, zie 9.15) | |
| *(onderaan, zonder kop)* | Instellingen | |

"Nog overboeken" heeft geen eigen regel in de zijbalk; je komt er via Te doen, de balk op Transacties en het
Dashboard. Staat de app daar, dan is er in de zijbalk niets gemarkeerd.

### 10.4 Dashboard

- **Kop**: "Dashboard" met daaronder de datum voluit ("woensdag 10 maart 2027") en rechts de knop Importeren.
- **Nog te besteden deze maand** als groot getal, met de **rekensom** eronder (7.5). "Nog verwacht deze maand" is
  één regel met een pijltje; uitgeklapt de verwachte inkomsten en uitgaven per post (met "te laat" en de delen van
  kwartaalinkomsten) en "Nog over te boeken met spaar". Geen grijze uitlegtekst en geen "Vrij te besteden" op het
  Dashboard. Zolang er banktransacties op betaal wachten: waarschuwing met knop Boeken. Geen jaar: "Er is nog geen
  begroting voor <jaar>." met een knop naar Posten.
- **Aandacht** rechts naast het getal (in een smal venster eronder), alleen met wat er is, elk met een knop naar de
  plek waar je het oplost:
  - minimum aan het eind van de maand niet gehaald (nog te besteden negatief);
  - vaste posten later dan normaal (te laat), met de namen;
  - nog te boeken banktransacties;
  - nog niet gecontroleerde boekingen;
  - open regels van Nog overboeken ("€ 25,00 over te maken van spaar naar betaal (2 boekingen)." / "… van betaal
    naar spaar …" / bij netto nul "2 boekingen te verrekenen tussen potjes.");
  - overboekingen met spaar die na 5 dagen nog niet in een bankbestand gezien zijn (opent Te doen);
  - tijdelijk geleend van spaar dat nog uitstaat;
  - per tag nog terug te ontvangen;
  - grote uitgave op komst (7.18);
  - spaardoelen niet op koers (buiten de marge);
  - potjes die binnen een jaar onder nul komen;
  - saldo na import sluit niet aan (alleen als er op die rekening niets meer wacht);
  - laatste bankbestand ouder dan 14 dagen;
  - afstemming met verschil, of ouder dan 35 dagen;
  - geen begroting voor het jaar.
- **Drie kaartjes**:
  - *Periodieke transacties* (vaste posten deze maand): "x van y voldaan", Te laat (ook bij 0), Nog verwacht, en in
    en uit zoals al geboekt. Klik → **Vaste posten**.
  - *Incidentele transacties* (overig deze maand): in, uit en de drie grootste uitgaven. Klik → **Incidentele
    transacties**.
  - *Huidig saldo*: betaal, spaar en totaal; niet aanklikbaar.
- Link **Verloop van het jaar**: grafieken vrij te besteden per maandeinde (7.4) en in en uit per maand.

### 10.5 Vaste posten (achter het kaartje Periodieke transacties)

Bovenaan drie getallen: nog binnen te komen, nog af te gaan, en het saldo daarvan. Daaronder **Inkomsten** en
**Uitgaven** apart, elk in "Nog te komen" en "Verwerkt". Per post: plan, werkelijk bedrag, of plan met "afgevinkt";
nergens € 0,00. Filter Alles / In / Uit. Geen link naar het maandgrid en geen info-icoon (uitleg als tooltip op de
titel). Maand kiesbaar.

### 10.6 Incidentele transacties (achter het kaartje Incidentele transacties)

Drie kaartjes naast elkaar: **totalen** (totaal in, totaal uit, saldo), **uitgaven per tag** (alle tags met bedrag,
plus "Zonder tag") en **de 5 grootste uitgaven**. Daaronder alle transacties zonder vaste post van die
begrotingsmaand, te sorteren op datum en op bedrag (oplopend en aflopend) en te filteren op Alles / In / Uit. Geen
links naar andere pagina's. Maand kiesbaar.

### 10.7 Te doen

Alleen kaartjes met inhoud; zijn ze allemaal leeg, dan één regel "Er is niets te doen." De teller in de zijbalk is
het aantal kaartjes.

- **Nog overboeken**: het netto bedrag met de richting ("€ 25,00 van spaar naar betaal"): dat is de ene
  handeling in de bank-app. Per regel de boeking, het potje en "Nog overmaken: € …" met de knop **Afvinken…** (het
  venster laat per potje zien wat er uit gaat of in komt, met het potsaldo erna, en heet "Ik heb dit overgemaakt").
  Na afvinken grijs: "Afgevinkt, wacht op de bank", tot de import waarin de overboeking gezien is; dan verdwijnt
  de regel. Heropenen en weggooien kan zolang de bank nog niets gekoppeld heeft.
- **Terug te ontvangen**: per tag met Krijg ik terug het openstaande bedrag, met een link naar de open boekingen.
- **Tijdelijk geleend van spaar**: wat er nog uitstaat, met een link naar de gemarkeerde boekingen in Transacties.

### 10.8 Importeren en nakijken

- **Importeren**: een zip of CSV slepen of kiezen. De voorvertoning per bestand: rekening, aantal nieuw, al bekend,
  fouten (per regel), de saldoketen en de naad. Knop Importeren; bij fouten "foute regels overslaan" als bewuste
  keuze. Kolommen kiezen als geen profiel past.
- **Nakijken**: links de lijst met wachtende banktransacties (betaal en spaar te wisselen, met aantallen), met de
  regel "Nog 3 na te kijken · 4 zeker" en de knop **Boek de zekere**. Twijfelgevallen bovenaan. Achter de post
  staat "uit potje X" bij Nog overboeken.
- Rechts het voorstel voor de gekozen transactie: tegenpartij en banktekst, **Waar hoort dit bij?** (post, overig
  of potje), omschrijving (met aanvullen en "Bedoel je …?"), tags (direct aan te maken), **Nog overboeken met
  spaar** (met potje), **Hoort bij maand**, onder **Meer opties** tijdelijk geleend van spaar en splitsen, het vinkje
  **Voortaan zo indelen** of **Regel bijwerken met deze keuze** met de samenvattingszin, en **Waarom dit
  voorstel?**. Knoppen **Boek** (ook met één toets) en een kleinere **Sla over**. Na elke actie "Maak ongedaan".
- Extra herkenning in het paneel: de terugbetaling van een tag ("Is dit je € … van Tanken terug?" → "Tag
  Tanken"), de andere helft van een eigen overboeking ("+ € 250,00 op Spaarrekening, 4 mrt · wacht nog op een plek"
  met "Bekijk"), een losse overboeking naar spaar ("Niet de vaste overboeking: één potje kiezen" / "Toch de vaste
  overboeking …"), Automatisch sparen met verdeling en "verschil naar …", de overboeking met spaar ("Afvinken en
  koppelen"), en de waarschuwing bij Nog overboeken op een eigen overboeking (7.8).
- "Boek de zekere" zet de boekingen in Nakijken op **nog niet gecontroleerd** (in Transacties op gecontroleerd;
  bewust verschillend).
- Onderaan de controle van het saldo na de import (7.16): klopt het berekende saldo met het eindsaldo van het
  bestand zodra alles geboekt is.
- In de voorbeeldmodus de knop **Voorbeeldbestand importeren**.

### 10.9 Transacties

- Een lijst zoals in een bank-app, per rekening (kaartjes met saldo bovenaan), nieuwste eerst, met zoeken en
  filters: periode of maand, post, potje, tag, overig, nog niet gecontroleerd, Nog overboeken, nog terug te
  ontvangen, bedrag van/tot, in/uit.
- Onder de rekeningkaarten het **downloadadvies** (8.8). Een balk naar Nog overboeken als daar iets openstaat.
- Wachtende banktransacties staan er ook (met een puntje), met **dezelfde** voorstellen, aantallen en hetzelfde
  vinkje als in Nakijken. "Boek de zekere" zet hier op gecontroleerd.
- Detail van een boeking: alle velden te wijzigen behalve (bij een banktransactie) bedrag, dag en rekening;
  splitsen; Hoort bij maand; tijdelijk geleend; Nog overboeken; tags; notitie; gecontroleerd. Eén regel "Nog over te
  boeken: € …" of "Nog terug te ontvangen: € …" met een knop naar de plek waar je het rechtzet. Een handmatige
  boeking toevoegen (zonder banktransactie).
- Bij een boeking op een potje: rechtsklik "Eenmalig (niet in het gemiddelde)".

### 10.10 Tags

Eén scherm, links de tags, rechts per tag: uitgaven deze maand en dit jaar (per maand), en bij Krijg ik terug
"Nog terug te ontvangen: € …" met de open boekingen en de geschiedenis van oude terugbetalingen. Beheer: aanmaken,
naam, kleur, schakelaars **Krijg ik terug** en **Tel mee bij ‘nog te besteden’**, startbedrag met dag. Verwijderen
wordt geweigerd als de tag terugbetalingen heeft. Een klik op "n boekingen" opent Transacties gefilterd op de tag.

### 10.11 Posten

Het jaarplan: jaar kiezen, **jaar aanmaken** (leeg of kopiëren van een vorig jaar: posten, koppelingen en RES-regels
mee, zonder boekingen, vinkjes en wat-als), **afsluiten** en heropenen. Het veld "Minimaal op je betaalrekening aan
het eind van de maand". De posten op volgorde (slepen), per post naam, richting, plan, frequentie, verwachte maanden
en dag, met de **ketenstrook** ("Gaat via Automatisch sparen: X naar n potjes"). De opengeklapte RESERVERINGEN toont
de opbouw uit Automatisch sparen alleen-lezen met "Verdeling wijzigen bij Automatisch sparen"; de RES-regels in de
groep "RES-regels (oude opbouw)" met hun som per maand, en de waarschuwing als ze uit de pas lopen. Daaronder de
**maandbalans** met wat-als (7.14). Een post verwijderen met boekingen kan alleen als die boekingen overig mogen
worden.

### 10.12 Potjes

- Overzicht per groep (Reserveringspotjes, Spaarpotjes; spaarpotjes per eigenaar gegroepeerd), met per potje het
  saldo en een balkje voor het spaardoel. Bovenaan saldo spaarrekening, niet toegewezen en "In de min, gedekt door
  andere potjes".
- **Potdetail**: saldo; ketenstrook ("Krijgt € … per maand via Automatisch sparen: X (post Y)"); mutaties met
  lopend saldo (rechtsklik "Eenmalig (niet in het gemiddelde)"); spaardoel (doelbedrag of onderdelen, doeldatum,
  marge-keuze, status in één woord, nodig per maand, nu per maand, doel gehaald op); **vooruitblik** als grafiek
  (echt saldo doorgetrokken, verwacht gestippeld, doellijn) met "Stand op <datum>"; verwachtingen ("Elke maand" t/m),
  projecten; de schakelaar "Reken met eerdere uitgaven" met het gemiddelde; bij een negatief potje wanneer het weer
  op nul staat; **Opheffen…**. Bewerken: naam, soort, eigenaar, beginbedrag.
- Knoppen **Nieuw potje** en **Nieuw jaarbedrag…** (7.15). De zin "Verwachtingen tellen nergens anders in mee"
  staat bij de vooruitblik.

### 10.13 Automatisch sparen

Een eigen scherm. Per vaste overboeking: naam, van (betaalrekening) en naar (spaarrekening), de verdeling over
potjes (potje en bedrag, toevoegen, wijzigen, weghalen, volgorde), het totaal, en "Telt in je begroting als: post
<post>" (koppelen of ontkoppelen) met de ketenstrook en de waarschuwing als de RES-regels anders optellen. Nieuw,
archiveren, verwijderen.

### 10.14 Maandgrid (onder Inzicht)

Het jaaroverzicht zoals de Excel: posten als rijen, plan en jan–dec en jaar als kolommen, de lopende maand
gemarkeerd, toekomstige en nog open bedragen in een rustiger (maar leesbare) stijl. Onder het grid de totaalrijen
(7.3). **Vaste legenda van één regel**: Klopt / Wijkt af (± € X) / Nog verwacht / Te laat / Afgevinkt. Boven het
grid: "Juni: 5 van 15 voldaan · 3 te laat". Klik op een cel: een venster met de boekingen, de status in woorden,
"Voldaan (afvinken)", de ketenstrook bij een post met Automatisch sparen, en bij "Te laat" een hint als een
wachtende banktransactie lijkt te passen ("Er wacht een banktransactie van € 150,00 die hierbij past" met een knop
die Nakijken op die transactie opent). Dubbelklik om een boeking toe te voegen. "Toon opbouw van RESERVERINGEN"
klapt de regels van Automatisch sparen uit. Klik op IN/UIT overig toont die boekingen.

### 10.15 Rapporten

Tabbladen: **Overzicht** (jaaroverzicht: op de rekening op 1-1, IN, UIT, op de rekening, minimaal, tijdelijk
geleend, vrij te besteden, overig, gemiddelden per verstreken maand), **Vrij te besteden** (per maandeinde),
**Tags** (12 maandtotalen per tag, dit jaar t/m nu, gemiddelde, vorig jaar), **Per omschrijving** (6.17, met
samenvoegen), **Budget tegen werkelijk** (per post plan en werkelijk t/m nu, verschil, maanden boven en onder plan),
**Overige uitgaven** (per tag en de grootste), **Jaar op jaar**.

In de referentie staat Rapporten **tijdelijk niet** in de zijbalk (wens van de gebruiker); de afspraak is het terug
te zetten onder Inzicht, met Maandgrid eronder. Bouw het scherm, en zet het onder Inzicht vóór Maandgrid.

### 10.16 Instellingen

Tabbladen (in een smal venster onder de titel):

- **Rekeningen**: toevoegen, wijzigen, archiveren, volgorde; per rekening het saldo, de laatste import en
  **afstemmen** (banksaldo invullen, verschil, geschiedenis).
- **Regels**: lijst op prioriteit (slepen), aan/uit, regeleditor (voorwaarden, acties, richting van Nog
  overboeken, "test deze regel": welke bestaande banktransacties hij herkent), verwijderen.
- **Back-up**: map kiezen, aantal te bewaren (standaard 30), back-up bij afsluiten (standaard aan), "Maak nu
  back-up", lijst van back-ups (gecontroleerd), terugzetten; exports (CSV, Excel per jaar).
- **Telefoon**: zie 9.1.
- **Over**: versie, wisselen tussen eigen administratie en voorbeelddata.

### 10.17 Tooltips en uitleg

Elk begrip uit hoofdstuk 4 heeft zijn uitlegzin als tooltip op de plek waar het voor het eerst op een scherm staat
(bijvoorbeeld bij de titel of het veld). Geen grijze zinnen in beeld.

---

## 10. Telefoondashboard, back-up en export, voorbeelddata

### 11.1 Telefoondashboard

Geen hosting en geen app op de telefoon: de app schrijft **één statische pagina** (HTML, en dezelfde inhoud als
PDF) naar een cloudmap naar keuze die de gezinsleden op hun telefoon kunnen openen. Alleen lezen.

- Ontworpen voor **375 punten breed** zonder horizontaal schuiven, licht en donker (volgt de telefoon).
- **Geen internet en geen externe bestanden**: alle opmaak staat in de pagina. Hoogstens één klein ingebouwd script
  (zie punt 3); zonder script werkt de pagina ook.
- De app schrijft de pagina opnieuw als de getallen veranderen, alleen met de eigen administratie (niet in de
  voorbeeldmodus en niet in testruns). Zet erop wanneer hij gemaakt is, zodat een kijker ziet hoe actueel hij is.

Inhoud, in deze volgorde:

1. **Nog te besteden deze maand** als hoofdgetal (hetzelfde getal als het Dashboard), met "Vrij te besteden"
   eronder en per meetellende tag "Komt nog terug: <tag>". Zonder begroting: "Er is nog geen begroting voor …".
2. **Voor het gezin**: per gekozen eigenaar (een persoon of een groep, uit `pot.owner`) een kaart met het totaal en
   de potjes met saldo. Alleen de eigenaren die de gebruiker aanvinkt.
3. **Gezamenlijke spaarpot**: één gekozen potje met het saldo nu en de verwachte stand over 3, 6 en 12 maanden
   (dezelfde vooruitblik als bij het potje, 7.12). Daaronder een datumveld "Stand op een eigen datum" en een
   inklapbare lijst "Stand per maand". De app zet de verwachte stand in de pagina tot een instelbaar aantal maanden
   vooruit (standaard 36, te kiezen 12 … 120): per maand voor de lijst en per dag waarop de stand verandert voor het
   datumveld (de **peildatum**). Het ingebouwde script toont de stand op de gekozen dag; vóór vandaag of na het
   einde een korte melding. Zonder scripts (voorvertoning, PDF) is het datumveld verborgen en staat alleen de stand
   per maand er.
4. **Uitgaven deze maand**; optioneel (per onderdeel aan of uit): vaste posten, de trend "Vrij te besteden per
   maand", rekeningen en potjes.

Instellen bij Instellingen › Telefoon: aan/uit, map kiezen, "Bekijk voorbeeld", vinkjes per eigenaar, keuzelijst
met potjes voor de gezamenlijke spaarpot, het aantal maanden vooruit, en de optionele onderdelen. Zolang er niets
gekozen is, staan de onderdelen er niet op. Opgeslagen in `setting` `publish.options` (JSON; onbekende of
ontbrekende velden krijgen de standaard, zodat oudere instellingen gewoon gelezen worden).

### 11.2 Back-up en herstel

- Een back-up is een **consistente kopie** van de database via de backup-API van de database (bij SQLite de
  online-backup-API), nooit een bestandskopie van een database die open is. Eén los bestand, veilig in een
  gesynchroniseerde map. Naam `HomeFinance-yyyyMMdd-HHmmss.<ext>`; bestaat die al, dan `-2`, `-3`.
- Na schrijven **controleren**: integriteitscontrole, de tabellen en de migraties. Een onbruikbaar bestand wordt in
  de lijst gemeld.
- **Bewaren**: de nieuwste N (standaard 30, minstens één); nooit de enige gecontroleerde back-up of een
  veiligheidskopie verwijderen.
- **Automatisch** bij afsluiten (standaard aan), naar de ingestelde map en eventueel een tweede map. Herinnering
  op het Dashboard als er rekeningen zijn en de laatste back-up 7 dagen of langer geleden is.
- **Herstellen**: back-up controleren → veiligheidskopie van de huidige database (`HomeFinance-voor-herstel-…`)
  → de inhoud van de back-up in de draaiende database kopiëren → migraties uitvoeren → schermen verversen. De
  back-upinstellingen van deze computer blijven; al het andere komt uit de back-up. Gaat er iets mis, dan wordt de
  veiligheidskopie teruggezet. Een back-up van een nieuwere versie wordt geweigerd.

### 11.3 Exports (kopieën om te lezen, geen back-up)

- **CSV-export**: per tabel één `<tabel>.csv`: kopregel met kolomnamen, puntkomma als scheidingsteken, CRLF,
  UTF-8 met BOM, bedragen als `1234,56` (geen duizendtalscheiding), dagen als `2027-01-31`, ja/nee als `1`/`0`,
  leeg voor NULL, tekst met `;`, `"` of regeleinde tussen dubbele aanhalingstekens.
- **Excel-export per jaar** (`HomeFinance <jaar>.xlsx`), tabbladen:
  - *Maandgrid*: `Post | Plan | jan … dec | Jaar`, posten onder Inkomsten en Uitgaven, RES-regels ingesprongen
    met alleen hun plan (plan van RESERVERINGEN = som van de RES-regels), lege cel zonder boeking, "afgevinkt"
    bij een afgevinkte maand zonder boeking; daaronder Vaste posten, IN overig, UIT overig, Netto overig,
    Resultaat, en het jaaroverzicht op de peildag (op de rekening op 1-1, IN, UIT, op de rekening, Minimaal aan
    het eind van de maand, Tijdelijk geleend van spaar, Vrij te besteden);
  - *Transacties*: één regel per boeking van het begrotingsjaar op alle rekeningen (datum, Hoort bij maand,
    rekening, omschrijving, Post of potje, Overig, tags, bedrag, Nog overboeken met spaar, Tijdelijk geleend van
    spaar, gecontroleerd, notitie, tegenpartij, bankomschrijving), met autofilter;
  - *Potjes*: per spaarrekening de potjes met soort, eigenaar, saldo op de peildag, gestort en opgenomen in het
    jaar, doelbedrag en doeldatum; Totaal potjes, Niet toegewezen, saldo rekening;
  - *Automatisch sparen*: per overboeking de regels en het totaal;
  - *Toelichting*: exportdatum, jaar, en dat dit een leesbare kopie is en geen back-up.
  Bedragen als echte getallen met opmaak `#.##0,00`, datums als echte datumcellen, totalen als `SUM`-formules met
  de uitkomst erbij, kop en eerste kolom bevroren.

### 11.4 Voorbeelddata

De app heeft een **voorbeeldmodus** met een verzonnen gezin, om de app te demonstreren en om de zelftest op te
draaien. Eisen:

- **Apart bestand**, nooit de eigen administratie. Een vaste balk bovenaan: "Je bekijkt voorbeelddata". Wisselen
  via Instellingen › Over.
- **Deterministisch**: dezelfde "vandaag" geeft exact dezelfde data (eigen generator, vaste tijdstempels). De data
  loopt van 1 januari van het jaar van vandaag t/m vandaag.
- **Versie**: de voorbeelddata heeft een versienummer in `setting` `voorbeeld.versie`. Een voorbeeldbestand met een
  andere of onbekende versie wordt vanzelf leeggemaakt en opnieuw gevuld. Hoog de versie op bij elke wijziging.
  Weiger het vullen van een database die al rekeningen of een jaar heeft.
- **De laatste 10 dagen ontbreken** van beide rekeningen. Nakijken › "Voorbeeldbestand importeren" schrijft een zip
  in het formaat van 8.5 met precies die dagen en importeert hem met de gewone zip-import. De zip sluit aan op de
  saldi (het eerste saldo vóór mutatie is gelijk aan het saldo in de app).
- **Namen**: personen "Ouder 1", "Ouder 2", "Kind 1", "Kind 2"; bedrijven met "Voorbeeld" of "Test" in de naam;
  IBAN's `NL00TEST…`.

Wat erin moet zitten (zodat elk scherm en elke rekenregel iets laat zien):

- een betaal- en een spaarrekening; een jaar met een minimum aan het eind van de maand;
- vaste posten per maand (salarissen, huur of hypotheek, energie, verzekeringen, telecom), per kwartaal (een
  kwartaaluitkering, een contributie) en een jaarpost; RESERVERINGEN met RES-regels die precies gelijk zijn aan de
  verdeling van één Automatisch sparen ("Maandelijkse reserveringen"), gekoppeld aan RESERVERINGEN;
- reserveringspotjes; per kind spaargeld (met spaardoel), kleedgeld en zakgeld (eigenaar = het kind); een
  gezamenlijke spaarpot zonder eigenaar met een vooruitblik en een verwachte uitgave; een spaardoel uit onderdelen
  met een groep als eigenaar;
- beginbedragen per potje als "Beginsaldo …" en één boeking zonder potje (rente);
- tags (bijvoorbeeld Tanken, Uit eten, Cadeau, Vakantie), alleen op betaal; Tanken met Krijg ik terug, een
  startbedrag en "Tel mee", en maandelijkse terugbetalingen met de laatste tankbeurten nog open;
- regels voor alle vaste posten, zoals "Voortaan zo indelen" ze maakt, waaronder zakgeld per kind op IBAN met Nog
  overboeken uit het zakgeldpotje **bij geld eruit**;
- banktransacties met een sluitende saldoketen en per maand een importbatch; een paar geboekte transacties "nog
  niet gecontroleerd"; pinnamen zoals de bank ze levert met nette namen in de boekingen;
- afwijkingen van het plan in een paar maanden en één ontbrekende betaling (voor "Te laat");
- uitgaven met Nog overboeken, elke maand afgevinkt met de banktransactie aan beide kanten; in de laatste 10 dagen
  één overboeking met spaar die vastgelegd maar niet afgevinkt is;
- één afstemming met verschil € 0,00;
- in de voorbeeldzip: wekelijks zakgeld (Nog overboeken), "Oppas zaterdag" naar een oppas (eigen tekst als
  omschrijving), een losse overboeking van betaal naar spaar ("Extra voor de vakantie", geen Automatisch sparen),
  een rommelige pinnaam ("0712 FRIETKRAAM DEMO S>VOORBEELDSTAD…"), geld dat terugkomt van een kind (twijfel, geen
  Nog overboeken), en de overboeking van de open overboeking met spaar ("Afvinken en koppelen");
- de telefoonkeuzes al ingevuld (de kinderen en de gezamenlijke spaarpot), maar het telefoondashboard zelf uit.

---

## 11. Werkwijze en testvangnet

### 12.1 Bouwen in kleine rondes

- Bouw in **kleine rondes**: één wens, één onderdeel of één rekenregel per ronde, op een eigen tak, in commits die
  elk apart terug te draaien zijn.
- **Elke ronde eindigt met een testronde** (11.2). Pas als die geslaagd is, gaat de ronde naar de hoofdtak.
- **Eerst installeren, dan de gebruiker laten testen.** Na een geslaagde testronde wordt de nieuwe versie
  geïnstalleerd (de app die de gebruiker echt start) en daarna pas test de gebruiker. Nooit "het werkt in de
  tests" laten testen op een versie die niet geïnstalleerd is.
- Rekenregels krijgen **tests met uitgewerkte, verzonnen voorbeelden**, zoals in hoofdstuk 13. Elke module een
  eigen testset met een database in het geheugen.
- Een rekenregel wijzigen is een **eigen besluit** van de gebruiker. Een UX-ronde verandert alleen teksten,
  indeling en weergave; de kerncijfers (11.2) moeten dan gelijk blijven.
- Houd een **voortgangsbestand** bij: wat per ronde gebouwd is, wat getest is (en wat niet), wat openstaat. Dat is
  het overdrachtspunt tussen werksessies.

### 12.2 De testronde

Eén script dat vier dingen doet en eindigt met **TOTAAL: GESLAAGD** of **TOTAAL: NIET GESLAAGD**. Alle uitvoer gaat
naar een map buiten de broncode.

1. **Bouwen.**
2. **Alle automatische tests.**
3. **Zelftest van de echte app.** De app start (het echte programma, niet een testomgeving) met voorbeelddata in
   een tijdelijk bestand, opent het gewone venster en loopt zelf alle schermen langs. Per controle OK of FOUT in
   een logbestand, exitcode 0 of 1, harde tijdslimiet (bijvoorbeeld 90 seconden):
   - de zijbalk verschijnt met alle regels, per groep de juiste schermen in de goede volgorde, **zoals ze echt
     getekend zijn** (niet alleen in het model);
   - elk scherm verschijnt binnen 5 seconden, zonder foutmelding en zonder fout bij het lezen of schrijven;
   - elk scherm (en elk tabblad van Rapporten en Instellingen) in de **gewone en de kleinste venstermaat**: kop
     zichtbaar, titel op één regel, niets horizontaal buiten beeld, zijbalk zichtbaar;
   - schermspecifiek: op Transacties het downloadblok onder de kop; de potjes-kiezers geladen en per soort op
     alfabet; Nakijken en Transacties tonen dezelfde aantallen wachtend en zeker en dezelfde extra herkenning; Te
     doen toont precies de kaartjes met inhoud en de teller klopt.
   Laat de zelftest aantoonbaar falen als je een scherm tijdelijk weghaalt.
4. **Kerncijfers.** Een platte, gesorteerde lijst (JSON, één sleutel per regel, sleutels op alfabet) met de
   belangrijkste getallen op een peildag. Bedragen als `"-1234.56"`, aantallen als `"12"`, id's met vier cijfers:

   | Sleutel | Inhoud |
   |---|---|
   | `rekening.<id>.naam`, `.soort`, `.gearchiveerd`, `.saldo` | per rekening |
   | `rekening.<id>.laatsteImport.dag`, `.eindsaldo`, `.saldoVolgensApp` | laatste import tegen de app |
   | `pot.<id>.naam`, `.rekening`, `.gearchiveerd`, `.saldo` | per potje |
   | `besteedbaarNu` | vrij te besteden |
   | `besteedbaarNu.terugTeKrijgen` | komt nog terug, samen |
   | `nogTeBestedenDezeMaand` | het hoofdgetal ("geen begrotingsjaar" als het jaar ontbreekt) |
   | `tag.<id>.openstaand`, `.startbedrag`, `.teltMee` | per tag met Krijg ik terug |
   | `boekingen.aantal`, `banktransacties.<status>` | aantallen |
   | `verrekeningen.openNetto`, `verrekeningen.openAantal` | open Nog overboeken |
   | `afgevinkt.<jjjj-mm>` | afgevinkte posten per maand |
   | `peildag`, `kerncijfers.versie` | |

   De kerncijfers worden gemaakt voor de voorbeelddata én voor een **kopie van de echte gegevens**, en vergeleken
   met de **basis** van de vorige ronde (zelfde peildag). Elk verschil staat er als `sleutel: oud → nieuw`, of
   "geen verschillen". Een verschil is niet automatisch fout: de gebruiker beoordeelt het. Klopt de nieuwe
   uitkomst (bijvoorbeeld na een bewuste rekenregelwijziging), dan wordt die de nieuwe basis.

Startopties die het script gebruikt: een ander databasebestand openen (geweigerd in de echte gegevensmap; dan geen
back-up bij afsluiten en geen telefoonpagina), voorbeelddata in een nieuw tijdelijk bestand, de zelftest met een
logbestand, en alleen de kerncijfers schrijven (zonder venster) met een peildag. Let op: zorg dat een bestandspad op
de opdrachtregel niet als "document openen" wordt opgevat (in de referentie opende de app dan geen venster).

### 12.3 De lessen

1. **Tests en schermafbeeldingen alleen zijn niet genoeg.** In de referentie waren alle tests groen en zagen de
   schermafbeeldingen er goed uit, terwijl de geïnstalleerde app bij de gebruiker een lege zijbalk toonde. De
   schermafbeeldingen gebruikten een eigen nagebouwde zijbalk, niet de echte. Sindsdien start de testronde altijd
   het echte programma en controleert de zijbalk zoals het besturingssysteem hem tekent. Vóór het installeren
   start je de echte app, niet alleen tests of snapshots.
2. **Nooit de echte administratie aanraken, alleen kopieën.** Testscripts werken op eigen kopieën in de
   uitvoermap; het opgegeven bestand verandert niet. Het script weigert het origineel. Bouwsessies krijgen nooit
   toegang tot de echte gegevens; alleen de eigenaar draait de testronde op een kopie.
3. **Namen pas na een test met de gebruiker vastleggen.** De eerste ronde nieuwe namen was goed onderzocht en toch
   moesten na de test zes namen anders ("Nog over deze maand" werd weer "Nog te besteden deze maand",
   "Voorgeschoten" werd "Tags" met "Krijg ik terug"). Bouw namen zo dat ze op één plek te wijzigen zijn, en laat
   identifiers en de sleutels van de kerncijfers ongemoeid zodat de basis bruikbaar blijft.
4. **Minder tekst wint.** De gebruiker wilde na de test alle grijze uitlegzinnen weg en de opbouw van het hoofdgetal
   als korte rekensom in plaats van een zin.
5. **Eén getal, één functie.** Op de telefoon stond eerst een ander hoofdgetal dan op het Dashboard; nu komt het
   op beide uit één functie, en de rekensom onder het getal is getest op "telt exact op".
6. **Herkenning moet twijfel durven tonen.** Een losse overboeking naar spaar werd als de maandelijkse overboeking
   herkend en verdeelde het verschil over één potje; alle reserveringen kregen hun maandbedrag dubbel. Daarom de
   grens voor "losse overboeking" en de richting bij regels met Nog overboeken.
7. **Regels nooit stil leren.** Eerst leerde de app bij elke boeking vanzelf een regel bij; dat is vervangen door
   een vinkje (standaard uit) met een samenvattingszin, zodat de gebruiker ziet en kiest wat er voortaan gebeurt.
8. **Terugdraaien moet kunnen.** Toen een versie bij de gebruiker niet werkte en de oorzaak niet snel te vinden was,
   is de code teruggezet naar de laatste werkende versie en zijn de wijzigingen één voor één opnieuw gebouwd, elk met
   een testronde. Kleine commits maken dat mogelijk.
9. **Wat niet met de hand is doorgeklikt, staat als "niet getest" in de voortgang**, ook als de tests groen zijn.

---

## 12. Volgorde van bouwen

Een voorgestelde roadmap. Elke ronde eindigt met een testronde; vanaf ronde 3 met zelftest en kerncijfers. Ronde 0
begint pas als de twee vragen van de triage (hoofdstuk 2) beantwoord en vastgelegd zijn.

| Ronde | Wat | Klaar als … |
|---|---|---|
| 0 | **Testvangnet en skelet.** Project met de modules uit hoofdstuk 5, lege schermen in de zijbalk, testscript met bouwen en tests. | Het script geeft GESLAAGD; de echte app start en toont de zijbalk met alle regels. |
| 1 | **Kern.** Geld in centen (lezen, rekenen in velden, tonen), dag, het hele schema als eerste migratie, database in het geheugen voor tests. | Acceptatietests A1–A3 slagen; een tweede migratie kan worden toegevoegd zonder de eerste te wijzigen. |
| 2 | **Import.** CSV lezen, profiel van de referentiebank, algemeen profiel, zip, saldoketen, dubbelen, naad op saldo/datum/hand, importbatch. Scherm Importeren met voorvertoning. | B1–B7 slagen; een voorbeeldzip importeert foutloos en een tweede keer niets nieuws. |
| 3 | **Boeken en rekeningen.** Boeken, splitsen, overslaan, handmatige boekingen, saldo, afstemmen (ook automatisch), eigen overboekingen koppelen. Scherm Transacties (basis) en Instellingen › Rekeningen. Zelftest en kerncijfers in het script. | C1–C3 slagen; het berekende saldo sluit op het eindsaldo van een import. |
| 4 | **Jaar, posten en maandgrid.** Jaar aanmaken/kopiëren/afsluiten, posten met frequentie, RESERVERINGEN en RES-regels, celstatus, afvinken, Hoort bij maand, totaalrijen. Schermen Posten en Maandgrid. | D1–D6 slagen; het grid van een voorbeeldjaar komt overeen met een met de hand uitgerekend jaarblad. |
| 5 | **Regels en Nakijken.** Voorwaarden, zekerheid, winnaar, namen opschonen, voorgestelde omschrijving, "Voortaan zo indelen" met toestemming. Scherm Nakijken; Instellingen › Regels. | E1–E6 slagen; een maand importeren en nakijken lukt zonder typen. |
| 6 | **Potjes en Automatisch sparen.** Potjes met beginbedrag, niet toegewezen, in de min, verplaatsen, opheffen; Automatisch sparen met koppeling aan een post, herkenning beide kanten en losse overboeking; ketenstrook. Schermen Potjes en Automatisch sparen. | F1–F6 slagen; potjes + niet toegewezen = saldo spaarrekening. |
| 7 | **Nog overboeken en tijdelijk geleend.** Markeren, openstaand netto, vastleggen, afvinken boekt, herkennen en koppelen bij import, melding na 5 dagen. | G1–G5 slagen; na een import met de overboeking verandert geen saldo. |
| 8 | **Tags.** Tags op betaal, Krijg ik terug, startbedrag, de terugbetaling taggen en herkennen, Tel mee. Scherm Tags. | H1–H5 slagen. |
| 9 | **Vrij en nog te besteden.** De rekensom, nog verwacht met kwartaaldelen en Nog overboeken. Dashboard met kaartjes en Aandacht, Vaste posten, Incidentele transacties, Te doen. | I1–I6 slagen; de rekensom telt exact op (ook op de voorbeelddata). |
| 10 | **Spaardoel en vooruitblik.** Verwachtingen (ook elke maand), projecten, vooruitblik, spaardoel met marge en onderdelen, eerdere uitgaven. | J1–J6 slagen. |
| 11 | **Hulpje Nieuw jaarbedrag, maandbalans en wat-als.** | K1–K3 slagen. |
| 12 | **Rapporten, omschrijvingen** (totalen, aanvullen, bijna-dubbelen, samenvoegen), downloadadvies. | L1–L3 slagen. |
| 13 | **Back-up, herstel, exports.** | Een back-up is terug te zetten en geeft dezelfde kerncijfers; de Excel-export opent zonder fouten. |
| 14 | **Voorbeelddata en voorbeeldzip.** | De demo-route werkt; de zelftest draait volledig op voorbeelddata. |
| 15 | **Telefoondashboard.** | De pagina toont op 375 punten breed zonder schuiven hetzelfde hoofdgetal als het Dashboard; het datumveld werkt en zonder script staat de lijst er. |
| 16 | **UX-ronde.** Alle schermen langs de lessen van 8.1, beide venstermaten, licht en donker; daarna een test met de gebruiker en een herstelronde. | De zelftest is groen op alle schermen en venstermaten; de kerncijfers zijn ongewijzigd ("geen verschillen"); de gebruiker heeft getest en de namen goedgekeurd. |

**Wat de triage verandert aan de roadmap**

| Uitkomst van de triage | Gevolg |
|---|---|
| Platform web | Ronde 0: de testronde start een lokale server en een browser; de zelftest loopt de pagina's langs in twee schermbreedtes. Ronde 13: back-up als download of naar een map, niet via een databasebestand naast de app (afhankelijk van de opslag in de browser of op de lokale server). |
| Platform mobiel | Ronde 15 (telefoondashboard) vervalt: de app zelf is dan de telefoonweergave. De zelftest controleert een smalle en een brede maat. |
| Andere desktop (Windows, Linux) | Geen verschil in rondes; alleen de techniek van de zelftest en de mappen voor gegevens en back-up. |
| Bank levert CSV met saldo per regel | Ronde 2 zoals beschreven, met een eigen profiel voor die bank. |
| Bank levert CSV zonder saldo | Ronde 2 zonder saldoketen en naad op saldo; naad alleen op datum en met de hand. Automatisch afstemmen (ronde 3) vervalt; afstemmen met de hand blijft. Acceptatietests B1–B3 en B6 vervallen of worden aangepast. |
| Bank levert CAMT.053 of MT940 | Ronde 2 krijgt een eigen lezer voor dat formaat (saldo meestal per afschrift: reken het saldo per regel uit vanaf het beginsaldo, zoals bij een PDF). De rest van de import blijft gelijk. |
| Alleen PDF | Ronde 2 met de PDF-lezer als hoofdroute; plan extra tijd en test met het voorbeeldbestand. |
| Geen voorbeeldbestand | Ronde 2 met het algemene profiel, kolommen kiezen en het formaat van 8.5; het bankprofiel volgt zodra er een bestand is. |
| Meer dan één bank | Ronde 2 krijgt per bank een profiel; de zip-route alleen voor banken die een zip leveren. |

De standaardkeuzes veranderen de roadmap niet. Slaat de gebruiker onderweg een onderdeel over (bijvoorbeeld tags met
"Krijg ik terug" of het telefoondashboard), dan vervalt die ronde met de bijbehorende acceptatietests; de kern
(rondes 0 t/m 7 en 9) blijft altijd.

Daarna: schaduwdraaien naast de Excel tot een developer de code heeft gereviewd en de cijfers een paar maanden
gelijk zijn.

---

## 13. Acceptatietests

Met deze scenario's toon je aan dat jouw app hetzelfde rekent als de referentie. Maak van elk scenario een
automatische test op een database in het geheugen. Alle gegevens zijn verzonnen. Bedragen in euro's; in de test
zijn het centen.

### 13.1 De basisopzet (fixture)

Tenzij een scenario iets anders zegt, geldt deze opzet en is **vandaag woensdag 10 maart 2027**.

**Rekeningen**

| Rekening | Soort | IBAN | Beginsaldo | Begindatum |
|---|---|---|---|---|
| Betaalrekening | betaal | NL00TEST0000000001 | € 2.000,00 | 01-01-2027 |
| Spaarrekening | spaar | NL00TEST0000000002 | werkelijk € 1.200,00 (zie potjes) | 01-01-2027 |

**Jaar 2027**: minimaal op de rekening aan het eind van de maand € 500,00.

**Posten 2027** (in deze volgorde)

| Post | Richting | Plan per keer | Frequentie | Maanden | Dag |
|---|---|---|---|---|---|
| Salaris | IN | + € 3.000,00 | maand | | 25 |
| Kwartaaluitkering | IN | + € 300,00 | kwartaal | 1,4,7,10 | |
| Huur | UIT | − € 1.200,00 | maand | | 1 |
| Energie | UIT | − € 150,00 | maand | | 5 |
| Verzekering | UIT | − € 480,00 | jaar | 3 | 15 |
| RESERVERINGEN | UIT (isReserveTotal) | berekend | maand | | |
| RES Onderhoud | RES | − € 250,00 | maand | | (potje Onderhoud) |
| RES Vakantie | RES | − € 150,00 | maand | | (potje Vakantie) |

**Potjes** op de spaarrekening: Onderhoud (reservering, beginbedrag € 600,00), Vakantie (reservering, € 300,00),
Spaargeld Kind 1 (spaar, eigenaar "Kind 1", € 100,00). Dus `openingBalance` van de spaarrekening = 1.200,00 −
1.000,00 = **€ 200,00** (niet toegewezen).

**Automatisch sparen** "Maandelijkse reserveringen": van de betaalrekening naar de spaarrekening, Onderhoud
€ 250,00 en Vakantie € 150,00 (totaal € 400,00), "Telt in je begroting als" RESERVERINGEN. De laatste echte
storting was op 25-02-2027.

**Tegenpartijen**: Energie Test BV `NL00TEST0000000050`, Kind 1 Voorbeeld `NL00TEST0000000070`, Bakkerij Voorbeeld
`NL00TEST0000000080`, een onbekende `NL00TEST0000000099`.

### 13.2 A — Kern

| ID | Gegeven | Verwacht |
|---|---|---|
| A1 | Bedrag lezen: `1.234,56` · `-45.50` · `45,5` · `€ 12` · `1,234.56` | 123456 · −4550 · 4550 · 1200 · ongeldig |
| A2 | Rekenen in een bedragveld: `249*4` · `504/12` · `100/3` · `2/3` · `100+25,50` | 99600 · 4200 · 3333 · 67 · 12550 |
| A3 | Tonen van 123456 en −4550 | `€ 1.234,56` en `-€ 45,50` |
| A4 | Post UIT met plan + € 10,00 opslaan | geweigerd (UIT ≤ 0) |
| A5 | Tweede post met isReserveTotal in 2027 | geweigerd (hoogstens één per jaar) |

### 13.3 B — Import

Bestand X (formaat 8.5) voor de betaalrekening, drie regels:

| Regel | Datum | Saldo vóór | Bedrag | Tegenpartij | Code | Omschrijving |
|---|---|---|---|---|---|---|
| 1 | 02-03-2027 | 1000.00 | -200.00 | NL00TEST0000000099 | OVB | Terugbetaling lening |
| 2 | 03-03-2027 | 800.00 | 50.00 | NL00TEST0000000070 | OVB | Terug van schoolreisje |
| 3 | 04-03-2027 | 850.00 | -30.00 | NL00TEST0000000080 | BEA | BAKKERIJ VOORBEELD >VOORBEELDSTAD04.03.2027 |

| ID | Gegeven / actie | Verwacht |
|---|---|---|
| B1 | Voorvertoning van X (rekening heeft al banktransacties van februari, dus geen naad) | keten sluit; beginsaldo € 1.000,00; eindsaldo € 820,00; 3 nieuw |
| B2 | X met de regels in omgekeerde volgorde | keten sluit; zelfde begin- en eindsaldo |
| B3 | X waarin regel 3 saldo vóór `860.00` heeft | waarschuwing: breuk bij regel 3, verwacht € 850,00, gevonden € 860,00; importeren mag; batch `chainOK` = false |
| B4 | X twee keer importeren | tweede keer: 0 nieuw, 3 al bekend; er komt wel een importbatch met `newCount` 0 |
| B5 | Een bestand met twee volledig gelijke regels op één dag (zonder volgnummer) | beide geïmporteerd; opnieuw importeren: 0 nieuw |
| B6 | Eerste import (nog geen banktransacties); rekening met beginsaldo € 800,00 en begindatum 03-03-2027 | naad op saldo bij regel 2; regel 1 gaat niet mee, met een melding dat hij vóór regel 2 (03-03-2027) is overgeslagen omdat het saldo daar aansluit; 2 nieuw; eindsaldo € 820,00 = berekend saldo |
| B7 | Als B6, maar beginsaldo € 777,00 | melding "Geen regel in dit bestand sluit aan op het saldo € 777,00 …"; terugval op datum: regel 1 (02-03) gaat niet mee, regels 2 en 3 wel |
| B8 | Regel 2 met bedrag `abc` | fout "Regel 2: ongeldig bedrag"; importeren geweigerd; met "foute regels overslaan" 2 nieuw |
| B9 | Een zip met X en een bestand met een fout | niets van de zip geïmporteerd |
| B10 | Een zip met een bestand voor IBAN `NL00TEST0000000555` (onbekend) | dat bestand gaat niet mee: "Geen rekening met IBAN … gevonden."; de rest wel |
| B11 | Een zip met een pad `../x.csv` | hele archief geweigerd |

### 13.4 C — Boeken, saldo en eigen overboekingen

| ID | Gegeven / actie | Verwacht |
|---|---|---|
| C1 | Banktransactie − € 80,00 splitsen in − € 50,00 (post Energie) en − € 30,00 (overig) | geboekt; status `verwerkt` |
| C2 | Splitsen in − € 50,00 en − € 20,00 | geweigerd: de regels tellen niet op tot het bedrag |
| C3 | Boeking dateren op 31-12-2026 | geweigerd: vóór de begindatum |
| C4 | Banktransactie overslaan | status `overgeslagen`; telt niet in het saldo |
| C5 | Betaal − € 250,00 op 03-03 met tegenrekening NL00TEST0000000002; spaar + € 250,00 op 05-03 met tegenrekening NL00TEST0000000001 | gevonden als eigen overboeking; boekingen aan elkaar gekoppeld |
| C6 | Als C5, maar de spaarkant op 07-03 | geen paar (meer dan 3 dagen) |
| C7 | Afstemmen: banksaldo € 1.849,99, berekend € 1.850,00 | verschil + € 0,01; vastgelegd |
| C8 | Import geheel geboekt, berekend saldo op de laatste dag = eindsaldo bestand | automatisch een afstemming met verschil € 0,00 (één per rekening per dag) |
| C9 | Boeking met tag op de spaarrekening | geweigerd |

### 13.5 D — Posten, maandgrid en status

Boekingen op de betaalrekening in 2027: februari: Salaris niet geboekt, Energie − € 162,40 op 06-02; maart: Huur
− € 1.200,00 op 01-03, een pinbetaling − € 35,00 overig op 04-03. Verder niets.

| ID | Gegeven / actie | Verwacht |
|---|---|---|
| D1 | Status maart | Salaris Nog verwacht (dag 25) · Kwartaaluitkering leeg (niet verwacht) · Huur Klopt · Energie Te laat (dag 5 < 10) · Verzekering Nog verwacht (dag 15) · RESERVERINGEN Nog verwacht (geen dag) |
| D2 | Status februari | Energie Wijkt af (− € 12,40) · Salaris Te laat (maand voorbij) |
| D3 | Status april | alles zonder status (toekomst) |
| D4 | Overzicht maart | "Maart: 1 van 5 voldaan · 1 te laat" (verwacht in maart: Salaris, Huur, Energie, Verzekering, RESERVERINGEN) |
| D5 | Energie maart afvinken | status Afgevinkt; "2 van 5 voldaan · 0 te laat"; Energie telt niet meer in nog verwacht |
| D6 | Plan van RESERVERINGEN in het grid | − € 400,00 (som RES-regels); de RES-regels tellen niet in Vaste posten |
| D7 | Ruimte t.o.v. maandbudget maart | 3.000 − 1.200 − 150 − 480 − 400 + 0 (IN overig) − 35 (UIT overig) = **+ € 735,00** |
| D8 | Salaris + € 3.000,00 op 26-02 met "Hoort bij maand" 2027-03 | in de maartkolom (Klopt); februari leeg; het saldo op 26-02 bevat het |
| D9 | "Hoort bij maand" 2027-06 bij een boeking van 26-02 | geweigerd (meer dan 2 maanden) |
| D10 | Automatisch sparen aanpassen: Vakantie € 200,00 (totaal € 450,00) | opgeslagen plan RESERVERINGEN − € 450,00; in het grid en in nog verwacht nog − € 400,00; waarschuwing "Let op: de RES-regels tellen op tot € 400,00, Automatisch sparen: Maandelijkse reserveringen tot € 450,00" |
| D11 | Jaar 2028 kopiëren van 2027 | zelfde posten, RES-regels en koppeling met Automatisch sparen; geen boekingen, vinkjes of wat-als |
| D12 | 2027 afsluiten en dan een boeking van maart wijzigen | geweigerd |

### 13.6 E — Regels en omschrijvingen

Regels: R-Energie (IBAN NL00TEST0000000050, bedrag − € 150,00 → post Energie, priority 10); R-Zakgeld (IBAN
NL00TEST0000000070, geen bedrag → overig, Nog overboeken met potje Spaargeld Kind 1, richting **eruit**,
priority 20).

| ID | Banktransactie | Verwacht voorstel |
|---|---|---|
| E1 | − € 150,00 van NL00TEST0000000050 | post Energie, zekerheid hoog, groep zeker |
| E2 | − € 162,40 van NL00TEST0000000050 | post Energie, zekerheid midden, "bedrag wijkt af (verwacht − € 150,00)", groep twijfel |
| E3 | − € 10,00 naar NL00TEST0000000070 | overig, Nog overboeken met Spaargeld Kind 1, zekerheid midden, groep waarschijnlijk |
| E4 | + € 12,50 van NL00TEST0000000070 | overig, géén Nog overboeken en géén potje, zekerheid laag, met melding; groep twijfel |
| E5 | Een regel met alleen een trefwoord "contributie" en een transactie met die omschrijving | zekerheid midden |
| E6 | Een regel met alleen bedrag − € 9,99 | zekerheid laag |
| E7 | Twee regels die beide hoog matchen, priority 10 en 20 | die met 10 wint |
| E8 | − € 4,35 van NL00TEST0000000080 zonder regel; gebruiker kiest overig, vinkje "Voortaan zo indelen" aan | nieuwe regel, `origin` geleerd, voorwaarde IBAN NL00TEST0000000080, **geen** bedrag (doel is geen vaste post), achteraan; vinkje uit: geen regel |
| E9 | Tweede keer − € 150,00 van een nieuwe tegenpartij, gebruiker kiest post Energie, vinkje aan | regel met voorwaarde IBAN **en** bedrag − € 150,00 (vaste post, tweede keer gezien) |
| E10 | E3, maar de gebruiker zet Nog overboeken uit; "Regel bijwerken met deze keuze" aan | R-Zakgeld zonder Nog overboeken; voorwaarden blijven |
| E11 | E4, maar de gebruiker kiest wél Nog overboeken naar Spaargeld Kind 1, bijwerken aan | richting van R-Zakgeld wordt `beide` |
| E12 | Keuze gelijk aan het voorstel bij E1 | geen vinkje; `hitCount` + 1 |

| ID | Tegenpartij / code / omschrijving | Verwachte omschrijving |
|---|---|---|
| E13 | Oppas Voorbeeld / OVB / "Oppas zaterdag" | Oppas zaterdag |
| E14 | (leeg) / BEA / "BAKKERIJ VOORBEELD >VOORBEELDSTAD04.03.2027" | Bakkerij Voorbeeld |
| E15 | "0712 FRIETKRAAM DEMO S>VOORBEELDSTAD12.03.2027" / BEA | Frietkraam Demo |
| E16 | Energie Test BV / OVB / "Factuur 2027-0012" | Energie Test (rechtsvorm weg; zakelijke tekst) |
| E17 | Energie Test BV / INC / "Termijn maart" | Energie Test |

### 13.7 F — Potjes en Automatisch sparen

| ID | Gegeven / actie | Verwacht |
|---|---|---|
| F1 | Beginstand | Onderhoud € 600,00 · Vakantie € 300,00 · Spaargeld Kind 1 € 100,00 · niet toegewezen € 200,00 · saldo spaarrekening € 1.200,00 |
| F2 | Spaar + € 400,00 van NL00TEST0000000001 | verdeling Onderhoud € 250,00, Vakantie € 150,00, labels "Maandelijkse reserveringen: Onderhoud" enz.; groep zeker |
| F3 | Spaar + € 380,00 van NL00TEST0000000001 | verdeling plus "verschil − € 20,00"; groep twijfel; "Losse overboeking? Kies een potje" |
| F4 | Spaar + € 200,00 (precies de helft) | nog de verdeling, met verschil − € 200,00 |
| F5 | Spaar + € 199,99 | "Dit lijkt een losse overboeking …", geen verdeling, één potje voorstellen; groep twijfel |
| F6 | Spaar + € 600,00 / + € 600,01 | binnen (verdeling + verschil) / losse overboeking |
| F7 | Betaal − € 400,00 naar NL00TEST0000000002 | post RESERVERINGEN |
| F8 | Spaar + € 400,00 zonder tegenrekening / met tegenrekening NL00TEST0000000099 | herkend (exact het totaal) / niet herkend |
| F9 | Betaal − € 50,00 naar NL00TEST0000000002 met Nog overboeken gekozen | waarschuwing "Dit is een overboeking naar je eigen spaarrekening. …"; boeken mag |
| F10 | Vakantie staat op − € 120,00 | "In de min, gedekt door andere potjes" € 120,00 (1 potje); weer op nul op **25-03-2027** (+ € 150,00, deze maand nog niet binnen) |
| F11 | Ketenstrook | bij Vakantie: "Krijgt € 150,00 per maand via Automatisch sparen: Maandelijkse reserveringen (post RESERVERINGEN)."; bij de overboeking: "Telt in je begroting als: post RESERVERINGEN."; bij de post: "Gaat via Automatisch sparen: Maandelijkse reserveringen naar 2 potjes." |
| F12 | Onderhoud opheffen met saldo € 600,00 naar Vakantie | Vakantie € 900,00; Onderhoud € 0,00 en opgeheven; saldo spaar ongewijzigd |
| F13 | Potje opheffen met negatief saldo zonder doel | geweigerd |

### 13.8 G — Nog overboeken en tijdelijk geleend

| ID | Gegeven / actie | Verwacht |
|---|---|---|
| G1 | Open op betaal: garage − € 45,00 met Nog overboeken uit Onderhoud; cadeau terug + € 20,00 met Nog overboeken naar Vakantie | uit potjes € 45,00, naar potjes € 20,00, **netto + € 25,00**: "€ 25,00 over te maken van spaar naar betaal (2 boekingen)."; per potje Onderhoud € 45,00 uit, Vakantie € 20,00 in |
| G2 | Potsaldi vóór afvinken | ongewijzigd (Onderhoud € 600,00, Vakantie € 300,00) |
| G3 | G1 vastleggen en afvinken op 12-03 | spaar: Onderhoud − € 45,00, Vakantie + € 20,00; betaal: overig "Verrekening spaar" + € 25,00; gekoppeld; Onderhoud € 555,00, Vakantie € 320,00 |
| G4 | Import: betaal + € 25,00 van NL00TEST0000000002 op 14-03; spaar − € 25,00 naar NL00TEST0000000001 op 14-03 | herkend en gekoppeld; **geen nieuwe boeking**; de boekingen krijgen dag 14-03; saldi op 31-03 ongewijzigd |
| G5 | Als G4, maar de bankdag is 20-03 | niet herkend (meer dan 7 dagen) |
| G6 | Afgevinkt 12-03, nog geen bank | geen melding op 16-03; wel op 17-03: "Overboeking met spaar van € 25,00 op 12-03-2027 is nog niet gezien in een bankbestand." |
| G7 | Open: − € 20,00 uit Onderhoud en + € 20,00 naar Vakantie | netto € 0,00: "2 boekingen te verrekenen tussen potjes."; afvinken boekt alleen op spaar |
| G8 | Tijdelijk geleend: + € 300,00 op 05-03, − € 100,00 op 20-03 (beide gemarkeerd) | uitstaand op 10-03 € 300,00; op 25-03 € 200,00 |
| G9 | Daarna − € 250,00 op 28-03 (gemarkeerd) | uitstaand op 31-03 € 0,00 (niet negatief) |

### 13.9 H — Tags

Tag Tanken met Krijg ik terug vanaf 01-01-2027, startbedrag € 50,00 op 01-01-2027. Boekingen op betaal met de tag:
− € 40,00 (03-03), − € 30,00 (08-03).

| ID | Gegeven / actie | Verwacht |
|---|---|---|
| H1 | Openstaand | **€ 120,00** (50 + 40 + 30) |
| H2 | Bijschrijving + € 120,00 met tag Tanken | openstaand € 0,00; "Komt nog terug" weg; nog te besteden gelijk |
| H3 | Bijschrijving + € 100,00 met tag Tanken (in plaats van H2) | openstaand € 20,00 |
| H4 | Nieuwe bijschrijving + € 119,50 (nog niet geboekt) | "Is dit je € 120,00 van Tanken terug?" met knop "Tag Tanken"; bij + € 118,99 niet |
| H5 | Tel mee aan | Komt nog terug: Tanken € 120,00 in vrij te besteden; uit: niet |
| H6 | Na een bijschrijving + € 125,00 met de tag (openstaand − € 5,00), Tel mee aan | telt niet mee (alleen positief) |
| H7 | Tag op een boeking op spaar | geweigerd |
| H8 | Oude werkwijze: terugbetaling vastleggen voor de twee boekingen plus startbedrag | bedrag € 50,00 − (− € 70,00) = € 120,00; daarna openstaand € 0,00; startbedrag niet meer te wijzigen tot ongedaan |

### 13.10 I — Vrij en nog te besteden

| ID | Gegeven | Verwacht |
|---|---|---|
| I1 | Saldo betaal € 1.850,00 op 10-03; Huur maart geboekt; Energie, Salaris, Verzekering, RESERVERINGEN en Kwartaaluitkering maart niet geboekt; Tanken openstaand € 60,00 met Tel mee; open Nog overboeken: alleen − € 45,00 uit Onderhoud; niets tijdelijk geleend | vrij te besteden **€ 1.410,00**; nog verwacht **+ € 2.215,00** = Salaris + 3.000,00, Energie − 150,00 (te laat), Verzekering − 480,00, RESERVERINGEN − 400,00, Kwartaaluitkering + 200,00 (2 van 3 delen, komt in apr), Nog over te boeken met spaar + 45,00; **nog te besteden € 3.625,00**; de regels van de rekensom tellen exact op |
| I2 | I1 met Energie maart afgevinkt | nog verwacht + € 2.365,00; nog te besteden € 3.775,00 |
| I3 | I1 met Energie geboekt − € 162,40 (saldo nu € 1.687,60) | nog verwacht + € 2.365,00; nog te besteden **€ 3.612,60** |
| I4 | Kwartaaluitkering € 300,00 (1,4,7,10) | deel in februari € 100,00 · maart € 200,00 · april hele € 300,00 als gewone post · mei € 100,00 |
| I5 | Kwartaalinkomst € 100,00 (1,4,7,10) | februari € 33,33 · maart € 66,66 (naar beneden) |
| I6 | Jaarinkomst € 1.200,00 in mei (5) | juni € 100,00 · november € 600,00 · januari € 800,00 · april € 1.100,00 · mei hele bedrag |
| I7 | Kwartaaluitkering heeft in maart al een boeking (bijvoorbeeld een correctie) | geen deel in maart |
| I8 | Saldo € 300,00, minimaal € 500,00, nog verwacht − € 400,00, verder niets | nog te besteden − € 600,00; Aandacht: minimum niet gehaald, tekort € 600,00 |
| I9 | Met tijdelijk geleend € 200,00 uitstaand bij I1 | regel "− Tijdelijk geleend van spaar € 200,00" verschijnt; nog te besteden € 3.425,00 |
| I10 | Jaar 2026 bekijken (peildag 31-12-2026) | geen nog verwacht, geen komt nog terug, geen open Nog overboeken |
| I11 | Twee banktransacties op betaal wachten | waarschuwing bij het getal met knop Boeken |
| I12 | Grote uitgave: Verzekering − € 480,00 verwacht en niet geboekt in maart | Aandacht "grote uitgave op komst"; een maandpost van − € 300,00 niet |

### 13.11 J — Spaardoel en vooruitblik

Spaargeld Kind 1: saldo € 400,00 op 10-03-2027, doel € 1.200,00 op 31-12-2027, in Automatisch sparen € 80,00 per
maand (laatste echte storting 25-02), een open verwachting − € 100,00 op 15-06-2027, marge 0,5 %.

| ID | Gegeven / actie | Verwacht |
|---|---|---|
| J1 | Spaardoel | stortmomenten 10 (25-03 t/m 25-12); nodig per maand (800 + 100) ÷ 10 = **€ 90,00**; nu € 80,00; tekort € 10,00 per maand; verwacht op 31-12 € 1.100,00; marge € 6,00; status **tekort** |
| J2 | Storting € 89,50 in plaats van € 80,00 | verwacht op 31-12 € 1.195,00 ≥ € 1.194,00 → **op koers (binnen de marge)**; geen melding bij Aandacht |
| J3 | Marge 0 % bij J2 | tekort |
| J4 | Nog nodig € 1.000,00 en 3 stortmomenten, geen verwachtingen | nodig per maand € 333,34 (naar boven) |
| J5 | Saldo € 1.250,00 / doeldatum 01-03-2027 en saldo € 400,00 / geen datum | bereikt / verlopen / zonder datum |
| J6 | Doel uit onderdelen: 2 × € 450,00 en 1 × € 300,00 | doelbedrag € 1.200,00 (alleen-lezen) |
| J7 | Vooruitblik van Vakantie t/m 31-05-2027 met een verwachting − € 500,00 op 10-05 | + € 150,00 op 25-03, 25-04, 25-05; − € 500,00 op 10-05; open verwachting op of vóór vandaag telt niet |
| J8 | (Spaarrekening met begindatum 01-01-2025, potje met boekingen sinds 2025.) "Reken met eerdere uitgaven" aan; uitgaven op het potje maart 2026 t/m februari 2027 samen − € 720,00, waarvan − € 120,00 gemarkeerd als eenmalig | gemiddelde − € 50,00 per maand, op 15-04, 15-05 … |
| J9 | (Zelfde spaarrekening.) Potje met eerste boeking in december 2026, uitgaven dec–feb − € 100,00 | 3 maanden; gemiddelde − € 33,33 (afgerond richting nul) |
| J10 | Een boeking waarmee een verwachting is uitgekomen | telt niet in het gemiddelde |
| J11 | Verwachting "Elke maand" van 31-01-2027 t/m 30-04-2027, € 25,00, zonder project | 31-01, 28-02, 31-03, 30-04; project = de omschrijving |
| J12 | Potje met schakelaar aan, nu € 100,00, gemiddelde − € 50,00, geen stortingen | Aandacht "Potje … komt binnen een jaar onder nul" |

### 13.12 K — Hulpje, maandbalans en wat-als

| ID | Gegeven / actie | Verwacht |
|---|---|---|
| K1 | Nieuw jaarbedrag "Fietsonderhoud" € 500,00 per jaar, nieuw potje, Maandelijkse reserveringen, rekening in november | per maand **€ 41,67**; overboeking € 441,67; opgeslagen plan RESERVERINGEN − € 441,67; nieuwe RES-regel − € 41,67 (grid − € 441,67); verwachting − € 500,00 op 01-11-2027; samenvatting met "verhoog je overboeking bij de bank naar € 441,67" |
| K2 | Zelfde, rekening in februari / in maart | verwachting op 01-02-2028 / 01-03-2027 |
| K3 | Maandbalans 2027 | inkomsten 3.000 + 100 = € 3.100,00; uitgaven 1.200 + 150 + 40 + 400 = € 1.790,00; over € 1.310,00 per maand |
| K4 | Wat-als Salaris € 3.200,00 | over € 1.510,00; het plan blijft € 3.000,00 tot "Maak hier het plan van" |

### 13.13 L — Overig

| ID | Gegeven / actie | Verwacht |
|---|---|---|
| L1 | Omschrijvingen "Zakgeld" en " zakgeld" | dezelfde groep |
| L2 | Getypt "Zakgeldd" bij bestaand "Zakgeld" | "Bedoel je ‘Zakgeld’?" |
| L3 | "Zakgeld Kind 1" en "Zakgeld Kind 2" | geen bijna-dubbelen |
| L4 | Laatste banktransactie betaal 08-03, spaar 02-03 | downloadadvies: van 02-03-2027 t/m 10-03-2027, beide rekeningen |
| L5 | Keuzelijst potjes "Potje 10", "potje 2", "Àpotje" (reservering) en "Buffer" (spaar) | Àpotje, potje 2, Potje 10, Buffer |
| L6 | Back-up maken en terugzetten in een lege database | kerncijfers gelijk aan vóór de back-up |
| L7 | Kerncijfers op de fixture | sleutels op alfabet, bedragen als `"1850.00"`, `nogTeBestedenDezeMaand` gelijk aan het Dashboard |
| L8 | Telefoonpagina met de gezamenlijke spaarpot Vakantie | stand nu, over 3, 6 en 12 maanden gelijk aan de vooruitblik van Vakantie; zonder script alleen de lijst per maand |

---

*Einde van het bouwpakket. Twijfel je over iets dat hier niet staat: kies de eenvoudigste uitleg die met deze
regels en scenario's klopt, schrijf je keuze op als aanname in je eigen documentatie, en laat de gebruiker beslissen
bij de volgende test.*
