# Voorstel: begrippen en koppelingen

*21 november 2026. Spoor 1 van de UX-ronde (spoor 2, de user journeys, staat in `journeys-review.md`).
Gebaseerd op een inventaris van de teksten in de app en onderzoek naar YNAB, Monzo, bunq, ING, Rabobank,
ABN AMRO, Dyme, Revolut en het Nibud (bronnen onderaan). Dit is een voorstel: de gebruiker kiest.*

## De drie grootste knelpunten

1. **"Regel" betekent drie dingen**: een voorstelregel ("Onthoud als regel"), een **bankregel** (een transactie
   uit het bankbestand) en een regel in de begroting (RES-regel). → Alleen de voorstelregel heet nog "regel";
   een transactie van de bank heet overal **banktransactie**.
2. **"Verrekenen" wordt voor twee verschillende dingen gebruikt**: iets uit een pot rechtzetten ("Verrekenen
   met spaar") en voorgeschoten geld terugkrijgen ("Verrekenen" bij een tag, zoals Tanken). → Twee eigen namen.
3. **Koppelingen zijn maar van één kant zichtbaar**: bij een vaste storting zie je de post, maar bij de post en
   bij de pot zie je niet waar het geld vandaan komt of heen gaat. → Overal aan beide kanten één zin.

## Per begrip

| Nu | Voorstel | Uitleg van één zin in de app | Waarom |
|---|---|---|---|
| Post / Vaste post / Jaar en posten | **Post** (overal hetzelfde); scherm "Begroting" i.p.v. "Jaar en posten" | Een post is een regel in je begroting met het bedrag dat je per maand, kwartaal of jaar verwacht. | Past bij een begroting en bij de Excel; banken zeggen "categorie", dat kan tussen haakjes bij het eerste gebruik. |
| Divers / IN divers / UIT divers | **Overig** (zonder post) | Boekingen die bij geen enkele post horen. | "Divers" klinkt als een eigen post. |
| Pot / Potten en sparen | **Potje** (scherm: "Potjes") | Een deel van je spaargeld met een eigen bestemming. | Rabobank en de media zeggen "potjes"; warmer en herkenbaarder. |
| Reserveringspotten | **Reserveren** (groep) | Geld opzijzetten voor iets dat zeker komt, maar niet elke maand. | Nibud: "reserveringsuitgaven"; sluit aan bij de Excel. |
| Spaarpotten | **Sparen** (groep), met **spaardoel** bij een potje | Geld voor een persoon of wens; met een spaardoel spaar je naar een bedrag op een datum. | Banken zeggen "spaardoel". |
| Vaste storting | **Automatisch sparen** (subregel: "vaste overboeking per maand, verdeeld over potjes") | Elke maand gaat dit bedrag naar je spaarrekening en wordt het over deze potjes verdeeld. | Rabobank, ABN AMRO: "automatisch sparen". |
| "Hoort bij post" (bij vaste storting) | **"Telt in je begroting als"** + post | Op je betaalrekening is deze overboeking een uitgave op deze post. | Zegt wat het doet. |
| Verrekenen met spaar | **Nog overboeken** (met spaar) | Je betaalde dit vanaf je betaalrekening, maar het hoort bij een potje. Zet het later in één overboeking recht. | Zegt wat je moet doen; geen boekhoudterm. |
| Verrekenen (per tag), "Te verrekenen" | **Voorgeschoten** — status "nog terug te krijgen: € X" | Uitgaven die je voorschiet en terugkrijgt, zoals tankkosten van je werk. | "Voorschieten" en "declareren" zijn dagelijkse woorden. |
| Telt mee in nog te besteden (tag) | **Reken mee als inkomen dat nog komt** | Het bedrag dat je nog terugkrijgt, telt mee in wat je deze maand kunt uitgeven. | Zegt wat het effect is. |
| Telt mee in (maand) | **Hoort bij maand** | Deze boeking telt mee in een andere maand dan de datum, bijvoorbeeld loon dat op de 25e binnenkomt voor de maand erna. | Duidelijker dan "telt mee in". |
| Regel / Onthoud als regel | **Regel**; de actie heet **"Voortaan zo indelen"** | Boekingen van deze tegenpartij krijgen voortaan deze post of dit potje voorgesteld. | "Voortaan" legt uit wat er gebeurt. |
| Bankregel / bankregel aanhangen | **Banktransactie** / "koppelen aan de banktransactie" | — | Lost botsing met "regel" op. |
| Tijdelijk geleend van spaar / Geleend uit andere potten | **Tijdelijk geleend van spaar** (één naam) | Geld dat je even van je spaarrekening haalt en later terugzet. | Twee namen voor hetzelfde. |
| Toewijzen aan post… / Toewijzen aan pot… | **Indelen bij post… / Indelen bij potje…** | — | "Indelen" past bij "Voortaan zo indelen". |
| Afvinken | **Afvinken** (blijft) | Markeer een post als voldaan voor deze maand, ook zonder boeking. | Al vanzelfsprekend. |
| Status gelijk / afwijkend / open / te laat | **Klopt / Wijkt af (± € X) / Nog verwacht / Te laat** | — | "Gelijk" is vaag; het verschil tonen helpt. |
| Besteedbaar nu | **Vrij te besteden** | Wat er nu op je betaalrekening staat, min wat je wilt laten staan en wat je van spaar hebt geleend. | Gangbaarder woord. |
| Nog te besteden deze maand | **Nog over deze maand** | Wat je deze maand nog kunt uitgeven, na de vaste posten die nog komen. | Korter, alledaags. |
| Anti-rood | **Minimaal op je betaalrekening** | Dit bedrag laat je altijd staan, zodat je niet rood komt. | "Anti-rood" is een eigen woord; "buffer" bewust niet (Nibud-buffer is iets anders). |
| Vooruitblik | **Vooruitblik** (blijft) | Wat dit potje naar verwachting doet, met de bedragen die je nog verwacht. Telt nergens in mee. | ING heeft "Kijk vooruit"; herkenbaar. |
| Spaardoel uit onderdelen | **Spaardoel, opgebouwd uit onderdelen** — onderdelen zichtbaar onder het doel | — | Geen voorbeeld gevonden bij anderen; zichtbaar maken is genoeg. |

## Koppelingen: aan beide kanten één zin

De app laat elke koppeling zien op beide plekken, met dezelfde woorden:

- **Bij een post** (Begroting en maandgrid): "Gaat via *Automatisch sparen: Extra spaar* naar 1 potje (*Spaar B&D*)."
- **Bij een potje**: "Krijgt € 500 per maand via *Automatisch sparen: Extra spaar* (post *Sparen*)."
- **Bij Automatisch sparen**: zoals nu, plus "Telt in je begroting als: *Sparen*".
- **Bij een boeking met "Nog overboeken"**: "Hoort bij potje *X* — nog over te boeken: € Y. Maak één overboeking van
  spaar naar betaal en vink af bij *Nog overboeken*."
- **Bij een voorgeschoten boeking**: "Voorgeschoten (*Tanken*) — nog terug te krijgen: € Z."

## Principes (uit het onderzoek)

1. Gebruik de woorden van de gebruikers zelf; toets ze met echte mensen (NN/g).
2. Is een term nodig maar onbekend: gewone omschrijving plus vakterm tussen haakjes (NN/g).
3. Leg een begrip uit **op de plek** waar het staat, kort; langer in een tooltip (NN/g).
4. Gewone taal helpt ook experts, juist bij geld (NN/g; SEC-onderzoek).
5. Eén ding, één woord, overal.
6. Bij een openstaand bedrag: zeg wat de volgende stap is.

## Voorstel voor de volgorde van bouwen (pas na keuze door de gebruiker)

1. Botsingen oplossen: banktransactie i.p.v. bankregel; twee namen voor verrekenen; één naam voor geleend.
2. Koppelingen aan beide kanten tonen (post ↔ automatisch sparen ↔ potje).
3. Hernoemen van de overige begrippen, met uitleg van één zin (tooltip of onderschrift).
4. Statussen in het maandgrid (Klopt / Wijkt af ± € X / Nog verwacht / Te laat).

Telkens: alleen teksten en weergave, geen wijziging in de berekeningen; testronde zoals gewoonlijk.

## Doorgevoerd (UX-stap C, 21 november 2026)

Gebouwd op de tak `ux-ronde`, in vier commits die elk apart terug te draaien zijn (`git revert <commit>`):
C1 indeling, C2 botsingen, C3 overige namen, C4 controle. Alleen teksten, indeling en weergave; geen rekenregel,
geen migratie, geen hernoemde identifiers of databasekolommen. De gebruiker beoordeelt de namen nog en kiest per
begrip; een naam terugzetten is een tekstwijziging.

### Zijbalk (C1)

| Groep | Schermen |
|---|---|
| Vandaag | Dashboard |
| Bijwerken | Importeren en nakijken · Transacties |
| Begroting | Maandgrid · Posten (was Instellingen › Jaar en posten; jaar aanmaken en afsluiten gaan mee) |
| Sparen | Potjes · Automatisch sparen (was een knop op Potten) · Nog overboeken |
| Inzicht | Rapporten |
| *(onderaan)* | Instellingen (Rekeningen, Regels, Tags, Back-up, Telefoon, Over) |

Het geplande scherm "Nog rechtzetten" (journeys-review #2) is **niet** gebouwd; de groep Vandaag heeft nu alleen
het Dashboard.

### Woorden

| Oud | Nieuw | Stap | Uitlegzin (grijs, op de eerste plek) |
|---|---|---|---|
| bankregel | banktransactie ("koppelen aan de banktransactie") | C2 | — |
| Verrekenen met spaar (scherm, schakelaar, acties) | Nog overboeken; schakelaar "Nog overboeken met spaar"; een vastgelegde overboeking heet "overboeking met spaar", afgerond = "overgeboekt" | C2 | Nog overboeken: "Je betaalde dit vanaf je betaalrekening, maar het hoort bij een potje (of het kwam binnen en moet naar een potje). Zet het later in één overboeking recht." |
| Verrekenen (bij een tag), te verrekenen, terugstorting | Voorgeschoten, "nog terug te krijgen: € X", terugbetaling, knop "Het geld is terug…" | C2 | Instellingen › Tags: "Voorgeschoten is voor uitgaven die je voorschiet en terugkrijgt, zoals tankkosten van je werk." |
| Tijdelijk geleend / Geleend uit andere potten | Tijdelijk geleend van spaar (overal voluit); het cijfer voor potjes in de min heet "In de min, gedekt door andere potjes" (in C2 nog "potten") | C2 | (bestond al bij Posten) |
| Divers / IN divers / UIT divers | Overig / IN overig / UIT overig | C3 | Rapporten › Overige uitgaven: "Overig: boekingen die bij geen enkele post horen." |
| Pot / Potten (en samenstellingen) | Potje / Potjes | C3 | Potjes: "Een potje is een deel van je spaargeld met een eigen bestemming." |
| Vaste storting / Vaste stortingen | Automatisch sparen (zijbalk en scherm); een losse storting heet "vaste overboeking"; met naam "Automatisch sparen: X" | C3 | Subregel: "Vaste overboeking per maand, verdeeld over potjes. Elke maand gaat dit bedrag naar je spaarrekening en wordt het over deze potjes verdeeld." |
| Hoort bij post (bij een vaste storting) | Telt in je begroting als | C3 | "Op je betaalrekening is deze overboeking een uitgave op deze post." |
| Telt mee in (maand) | Hoort bij maand | C3 | "Deze boeking telt mee in een andere maand dan de datum, bijvoorbeeld loon dat op de 25e binnenkomt voor de maand erna." |
| Onthoud als regel | Voortaan zo indelen | C3 | "Boekingen van deze tegenpartij krijgen voortaan deze post of dit potje voorgesteld." |
| Toewijzen aan post… / pot… | Indelen bij post… / potje… | C3 | — |
| Besteedbaar nu / besteedbaar | Vrij te besteden | C3 | Dashboard: "Wat er nu op je betaalrekening staat, min wat je wilt laten staan en wat je van spaar hebt geleend." |
| Nog te besteden deze maand | Nog over deze maand | C3 | Dashboard: "Wat je deze maand nog kunt uitgeven, na de vaste posten die nog komen." |
| Telt mee in nog te besteden (tag) | Reken mee als inkomen dat nog komt | C3 | (zin bij Instellingen › Tags) |
| Anti-rood | Minimaal op je betaalrekening aan het eind van de maand (kort: "Minimaal aan het eind van de maand") | C3 | Posten: "Dit bedrag laat je altijd staan, zodat je niet rood komt." |
| Status open (Dashboard, telefoon) | Nog verwacht (naast Klopt / Wijkt af / Te laat uit stap A2) | C3 | (legenda bestond al) |

Ook bijgewerkt: telefoonpagina, Excel-export (bladen "Potjes" en "Automatisch sparen", kolomkoppen "Hoort bij
maand", "Post of potje", "Overig", "Nog overboeken met spaar", "Tijdelijk geleend van spaar"; rijen "IN/UIT/Netto
overig", "Minimaal aan het eind van de maand", "Vrij te besteden"), foutmeldingen, README, docs/api (met een
kader "Namen in de interface") en de importchecklist.

### Bewust niet veranderd

- Identifiers, enum-waarden, databasekolommen en de sleutels van de kerncijfers (`besteedbaarNu`,
  `verrekeningen.*`), zodat de testronde dezelfde basis kan blijven gebruiken.
- Opgeslagen gegevens: de omschrijving "Verrekening spaar" en de notitie "Verrekening #id" van boekingen die bij het
  afvinken worden gemaakt, en namen in de voorbeelddata. Bestaande boekingen hebben die tekst al; een andere tekst
  voor nieuwe boekingen zou twee namen voor hetzelfde geven. Apart te beslissen.
- De CSV-export: dat is een ruwe kopie van de tabellen, met de kolomnamen uit de database.
- De import van de Excel-historie (`HFHistory`): de herkenning leest de Excel-woorden zoals ze zijn, en ook de
  meldingen en de samenvatting zeggen nog "pot"/"potten". Een eerste poging om die mee te nemen brak drie tests
  (testronde C4 NIET GESLAAGD) en is teruggedraaid; apart op te pakken.
- "Geleend uit andere potten" is niet "Tijdelijk geleend van spaar" genoemd: het is een ander getal (potjes in de
  min binnen de spaarrekening). Het heet nu "In de min, gedekt door andere potjes", zodat "geleend" alleen nog voor
  geld van spaar naar betaal staat.
- De groepen "Reserveringspotten" en "Spaarpotten" in de kiezers heten nu "Reserveringspotjes" en "Spaarpotjes"
  (niet "Reserveren" en "Sparen" uit de tabel hierboven).

## Bronnen

- YNAB Glossary: https://support.ynab.com/en_us/ynab-glossary-a-guide-BJd80SORq.md
- YNAB Getting a Month Ahead: https://support.ynab.com/en_us/getting-a-month-ahead-HJidy13C5.md
- Monzo Pots: https://monzo.com/features/pots · Salary Sorter: https://monzo.com/ie/help/managing-money/help-salary-sorter
- bunq budgetgids: https://www.bunq.com/nl-be/blog/the-ultimate-guide-to-budgeting-with-bunq
- Rabobank spaarpotjes: https://www.rabobank.nl/particulieren/sparen/service/spaarpotjes/ · automatisch sparen:
  https://www.rabobank.nl/particulieren/sparen/automatisch-sparen
- ABN AMRO Budgetten: https://www.abnamro.nl/nl/prive/themas/overzicht-en-inzicht/budgetten.html
- ING Kijk vooruit (Consumentenbond): https://www.consumentenbond.nl/betaalrekening/ing-kijkt-vooruit
- Nibud-indeling (via CBS): https://cbs.nl/-/media/_pdf/2024/42/bijlage-wat-is-genoeg-om-van-te-leven.pdf
- Revolut categorieën: https://help.revolut.com/nl-NL/help/accounts/budget-and-analytics/how-to-assign-and-adjust-categories-for-your-transactions/
- NN/g Technical Jargon: https://www.nngroup.com/articles/technical-jargon/ · Plain language for experts:
  https://www.nngroup.com/articles/plain-language-experts/
- SEC, jargon en fondskosten: https://www.sec.gov/files/jargon-mutual-fund-fees.pdf

Beperking: sommige bankpagina's (Rabobank, ABN AMRO, Nibud) waren niet volledig te openen; daar is uitgegaan van
zoekresultaten. De labels in de apps van bunq en ING zijn niet in de apps zelf gecontroleerd.
