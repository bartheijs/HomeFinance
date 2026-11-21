# Feedback uit de test van de UX-ronde

*Verzameld tijdens de test door de gebruiker (21 november 2026). Wordt in één herstelronde op `ux-ronde`
verwerkt.*

## Dashboard

Algemeen: **te veel informatie**.

1. Datumregel onder de titel: **"zaterdag 21 november 2026"**: het jaartal erachter, en **niet** "November 2026"
   ervoor.
2. Titel van het hoofdgetal: terug naar **"Nog te besteden deze maand"** (niet "Nog over deze maand").
3. De grijze uitlegzin onder die titel **weg**.
4. De opbouw-zin onder het getal ("Nu staat er … er komt nog … en gaat nog … af. … laat je minimaal staan") is
   niet duidelijk. **Vervangen door de korte versie van "Hoe is dit opgebouwd?"**: één regel met alleen het
   totaal **"Nog verwacht deze maand: € …"** en een pijltje om de opbouw uit te klappen.
5. **"Vrij te besteden"** (− € 3.808,42) zegt de gebruiker weinig: **weg van het Dashboard**.
6. **Nieuw kaartje "Overige uitgaven"** (alles zonder vaste post) voor de gekozen maand, naast of in plaats van
   een van de bestaande kaartjes. Met het totaal en de details: de grootste posten of omschrijvingen (bijv. top 5
   met bedrag), en een klik naar de volledige lijst. Reden van de gebruiker: vaste posten en periodieke uitgaven
   zijn interessant, maar bij de overige uitgaven kun je direct besparen.

### Dashboard, uitgewerkt door de gebruiker (vervangt 3 t/m 6 waar het overlapt)

- **Alle grijze tekst weg** (uitlegzinnen, rekenzin, "Vrij te besteden").
- **Opbouw als korte rekensom** onder de titel "Nog te besteden deze maand":

  ```
    Huidig saldo betaalrekening            € …
  − Minimaal op de rekening aan het eind van de maand   € …   (de buffer, nu € 5.000)
  + Komt nog terug                         € …   (voorgeschoten, als "telt mee" aan staat)
  + Nog verwacht deze maand                € …   ▸ uitklappen: alle verwachte inkomsten (en uitgaven) per post
  = Nog te besteden deze maand             € …
  ```

  Let op voor de bouw: de regels moeten **exact optellen** tot het hoofdgetal. "Nog verwacht deze maand" is
  netto (verwachte inkomsten min verwachte vaste uitgaven); uitgeklapt beide, per post. Controleer met de
  kerncijfers dat het totaal gelijk blijft.
- **Drie kaartjes**: **Periodieke transacties** (vaste posten: x van y voldaan, te laat, nog verwacht) ·
  **Incidentele transacties** (overige uitgaven deze maand: totaal + grootste uitgaven, klik naar de lijst) ·
  **Huidig saldo** (betaal, spaar en het totaal samen; **niet** aanklikbaar, het scherm Rekeningen erachter voegt
  weinig toe).
- **Aandacht** blijft, en krijgt er meer bij:
  - vaste posten die **later zijn dan normaal** (te laat);
  - **spaardoelen die niet op koers liggen**;
  - nog meer wat aandacht verdient, bijvoorbeeld: de buffer wordt aan het eind van de maand niet gehaald (nog te
    besteden negatief), het saldo sluit niet aan na een import, de laatste import is lang geleden, een grote
    verwachte uitgave komt eraan, afgevinkte verrekeningen die nog niet bij de bank gezien zijn.
- **Knop "Maandgrid" rechtsboven weg.** De gebruiker verwacht het maandgrid weinig te gebruiken.
- **Kaartjes Periodiek en Incidenteel tonen zowel inkomende als uitgaande transacties** (in en uit, elk met
  totaal). Op de pagina erachter een **filter in / uit** (en alles).
- **Maandgrid in de zijbalk onder Inzicht**, direct onder Rapporten (niet meer bij Begroting).

## Vaste posten (pagina achter het kaartje Periodiek)

1. Icoon en link naar het maandgrid (rechtsboven in het blok) **weg**.
2. Het **info-icoontje doet niets**: laten werken (uitleg tonen) of weghalen.
3. **"te laat" ook op het kaartje op het Dashboard tonen, ook als het 0 is.**
4. **Bovenaan de lijst een samenvatting van wat er nog gaat gebeuren**: totaal **nog binnen te komen**, totaal
   **nog af te gaan**, en het **saldo** daarvan.
5. **In de lijst duidelijker wat verwerkt is en wat nog komt**:
   - **nergens € 0,00**: altijd het bedrag van de post (plan), en bij een verwerkte post het werkelijke bedrag;
     een afgevinkte post zonder boeking toont het planbedrag met "afgevinkt";
   - **duidelijk onderscheid tussen in- en uitgaande posten** (bijv. aparte groepen "Inkomsten" en "Uitgaven",
     of kleur en teken);
   - **duidelijk of een post deze maand al verwerkt is of nog moet komen** (bijv. groepen "Nog te komen" en
     "Verwerkt", of een duidelijke status per regel).

## Incidentele transacties (pagina achter het kaartje Incidenteel)

Opbouw van boven naar beneden, voor de gekozen maand:

1. **Totalen**: Totaal in · Totaal uit · Saldo.
2. **Uitgaven per tag** in die maand (alle tags met bedrag; niet "top tags").
3. **De 5 grootste uitgaven** van die maand.
4. **Alle transacties in een lijst**, met:
   - sorteren op **datum** en op **bedrag**, oplopend en aflopend;
   - filter **inkomsten / uitgaven** (en alles).
5. **Geen links naar andere pagina's** op deze pagina.
6. **Indeling**: punt 1 (totalen), 2 (per tag) en 3 (5 grootste uitgaven) als **drie kaartjes naast elkaar
   bovenaan**; de lijst met alle transacties eronder.

## Naam scherm "Nog rechtzetten"

- Wordt **"Te doen"** (zijbalk, titel, links en teller). Het kaartje "Aandacht" op het Dashboard blijft zo heten.

## Tags (was "Voorgeschoten")

- **Zijbalkregel "Voorgeschoten" wordt "Tags"**: één plek per tag met de uitgaven deze maand en dit jaar, en het
  beheer (aanmaken, kleur, schakelaars). Tagbeheer verhuist uit Instellingen. Rapporten: tabblad "Categorieën"
  wordt "Tags". Geen "categorieën" gebruiken (botst met posten).
- **Het woord "voorgeschoten" verdwijnt** overal.
- Schakelaars bij een tag:
  - "Verrekenen" → **"Krijg ik terug"**;
  - "Telt mee in nog te besteden" → **"Tel alvast mee bij 'nog te besteden'"** (twee schakelaars blijven).
- Status bij een tag met "Krijg ik terug": **"Nog terug te ontvangen: € …"**.
- **Knop "Het is binnen…" / "Ontvangen…" weg.** De gebruiker tagt de terugbetaling gewoon met de tag; volgens de
  rekenregel (openstaand = − som van de boekingen met de tag zonder verrekening, plus startbedrag) wordt het
  openstaande bedrag dan 0. **Eerst in de code controleren** dat dit klopt, ook met het startbedrag en met een
  bestaande verrekening; pas dan de knop weghalen. Nakijken/Transacties stellen bij een bijschrijving die op het
  openstaande bedrag lijkt de tag voor ("Is dit je € … van Tanken terug? → tag Tanken").
