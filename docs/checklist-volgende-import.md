# Checklist: de volgende keer transacties verwerken

*Opgesteld op 16 november 2026. Doel: je transacties verwerken en daarbij nagaan of de laatste aanpassingen werken.
Vink af wat klopt. Klopt iets niet, maak dan een screenshot en noteer wat je zag.*

## 1. Voorbereiden

- [ ] **Back-up instellen** (eenmalig): Instellingen › Back-up › kies een map in iCloud Drive. Maak meteen een
      eerste back-up, vóór je importeert.
- [ ] Download bij de bank de transacties vanaf de dag van je vorige import, voor **beide rekeningen** (één zip).
- [ ] Werk je Excel zoals gewoonlijk bij (schaduwdraaien), zodat je straks kunt vergelijken.

## 2. Importeren

- [ ] Sleep de zip op *Importeren en nakijken*.
- [ ] De saldoketen sluit op beide rekeningen; regels die er al in stonden worden overgeslagen.
- [ ] **Nieuw: automatisch afstemmen.** Na de import staat bij beide rekeningen een verschil van **€ 0,00**
      (Instellingen › Rekeningen). Je hoeft het banksaldo niet meer zelf in te vullen.

## 3. Nakijken

- [ ] **Correctie (21 november), zakgeld van een kind.** Betaalkant: divers, verrekenen op Nee. Spaarkant: laat
      staan en meld het aan de orchestrator (hoort op de spaarpot van dat kind; de app biedt alleen de vaste storting aan).
- [ ] **Twee correctie-overboekingen (21 november).** Je maakte twee bedragen over van betaal naar spaar om
      een verrekening recht te zetten. Spaarkant: de ene op de rentepot, de andere op de spaarpot van een kind.
      Betaalkant: beide **zonder pot**, als divers.
- [ ] **Overboeking naar de rentepot.** Een overboeking naar spaar staat twee keer in de app. Kies de pot
      de pot alleen bij de **spaarkant** (bijschrijving op de spaarrekening). Aan de **betaalkant** kies je
      geen pot: een pot daar betekent "deze uitgave moet uit de pot terugkomen" en komt in de verrekening.
      Stelt de app bij de spaarkant de vaste storting "Reserveringen" voor terwijl het bedrag niet klopt, neem dat
      voorstel dan niet over.
- [ ] **Nieuw: tags bij het nakijken.** Geef een tankbeurt de tag *Tanken*, direct in het nakijkscherm. Probeer
      ook een nieuwe tag aan te maken vanuit dat scherm.
- [ ] **Nieuw: boekingen die elkaar opheffen** (heen en terug, zelfde bedrag) boek je als divers, zonder pot.
      Daarover mag geen melding meer verschijnen.
- [ ] **Verrekeningen met spaar.** Heb je eerder iets afgevinkt bij "Nog overboeken" (vroeger "verrekenen met spaar"), dan herkent de import
      de overboeking en koppelt hem. De verrekening staat daarna niet meer als open.

## 4. Dashboard controleren

- [ ] **Hoofdgetal "Nog te besteden deze maand".** Vergelijk met de forecast in je Excel. Let op de verschillen
      die zo horen:
  - kinderbijslag telt in de app elke maand mee (een derde van het kwartaalbedrag);
  - open verrekeningen met spaar tellen nu mee.
- [ ] **Meldingen.** Verrekeningen die nog niet in een bankbestand zijn gezien, staan samen in **één regel** en
      niet als losse meldingen. Na deze import horen ze grotendeels weg te zijn.

## 5. Potten en spaardoelen

- [ ] De saldi van de **potten per persoon** komen overeen met je spaar-Excel.
- [ ] **Spaardoelen met onderdelen** (studie, rijbewijs) tonen een doelbedrag, een doeldatum en wat er per maand
      bij moet.
- [ ] De tags per kind voor het rijbewijs staan erbij en tellen goed op.

## 6. Maandgrid

- [ ] Posten van november die vóór de start al betaald waren, staan afgevinkt.
- [ ] Vervallen posten (schoonmaak, zangles en kindgebonden budget voor november) staan niet meer als
      verwacht.
- [ ] Nieuwe transacties vallen in de goede maand. Gebruik *telt mee in* als iets voor een andere maand bedoeld is.

## 7. Afsluiten

- [ ] Saldo betaalrekening, saldo spaarrekening en "nog over deze maand" (vroeger "nog te besteden") zijn gelijk aan je Excel, of het verschil is
      verklaard.
- [ ] Maak een back-up.
- [ ] Geef de afwijkingen door aan de orchestrator.

## Nog te beslissen

- Wat er vanaf december gebeurt met de kindgerelateerde posten (kindgebonden budget en zang- en dansles):
  aanpassen of laten vervallen.

## Eén keer per jaar: de zorgpremie

De premie wordt jaarlijks in één keer betaald en "geleend" van het studiespaargeld. Elke maand gaat 1/12 terug via
de vaste storting naar de pot *Zorg voorschieten (uit studiegeld)*; aan de betaalkant telt dat als de post van de
zorgverzekeraar. Bij de jaarbetaling zelf:

- [ ] Vanaf de **spaarrekening** betaald: boek de afschrijving op de pot *Zorg voorschieten*. Geen post.
- [ ] Vanaf de **betaalrekening** betaald: kies **Divers** met **Nog overboeken met spaar: Zorg voorschieten**, maak
      het bedrag over van spaar naar betaal en vink de verrekening af. **Niet** op de post van de verzekeraar,
      anders telt de premie dubbel.
