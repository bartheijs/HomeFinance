# Testlijst UX-ronde (tak `ux-ronde`)

*21 november 2026. Alle stappen zijn getest op een kopie van de administratie: testronde geslaagd, kerncijfers
gelijk aan de basis, zelftest 211 keer OK in twee venstermaten. Deze lijst is voor de test door de gebruiker.
Bevalt iets niet: noteer het; elke stap is een losse commit en kan apart terug. Terug naar de versie van vóór de
UX-ronde kan in één stap (markering `voor-ux-ronde`).*

## Eerst

- [ ] Instellingen › Over: de commit achter de versie is die van `ux-ronde`.
- [ ] De zijbalk staat er, met de groepen **Vandaag / Bijwerken / Begroting / Sparen / Inzicht**.
- [ ] Afsluiten en opnieuw openen gaat goed; de zijbalk komt terug.

## Per stap

| Stap | Wat | Zo test je het |
|---|---|---|
| A1 | Uitleg onder het grote getal | Dashboard: staat er onder "Nog over deze maand" een zin met wat er nu staat, wat er nog binnenkomt en afgaat? Klopt dat met je gevoel? |
| A2 | Status in woorden | Maandgrid: legenda onder het grid, "x van y voldaan · z te laat" erboven. Open een cel die te laat is. |
| A3 | Potlabel | Transacties: bij een boeking uit een potje of voorgeschoten staat dat erbij; in het detail "nog over te boeken / nog terug te krijgen". |
| B1 | Verdeling uit Automatisch sparen | Maandgrid of Posten: klap Reserveringen open; je ziet de verdeling over potjes. |
| B2 | Koppelingen aan beide kanten | Open een potje (bijv. de gezamenlijke spaarpot): "Krijgt € … per maand via …". Open de post Sparen: "Gaat via … naar 1 potje". Klik door naar de andere kant. |
| B3 | Hulpje Nieuw jaarbedrag | Potjes › Nieuw jaarbedrag…: vul een voorbeeld in en lees de samenvatting. **Annuleer** als je het niet echt wilt aanmaken. |
| C1 | Nieuwe zijbalk | Posten en Automatisch sparen staan nu in de zijbalk; Regels onder Instellingen. |
| C2 | Botsingen | "Nog overboeken" (was Verrekenen met spaar), "Voorgeschoten" (Tanken), "banktransactie". |
| C3 | Nieuwe namen | Loop een paar schermen langs: Overig, Potje, Automatisch sparen, Vrij te besteden, Nog over deze maand, Minimaal aan het eind van de maand, Klopt / Wijkt af / Nog verwacht / Te laat. Welke namen voelen goed, welke niet? |
| D1 | Boeken gelijk getrokken | Transacties en Importeren en nakijken tonen dezelfde voorstellen en aantallen; "Voortaan zo indelen" werkt op beide. |
| D2 | Meer herkenning | Pas bij een volgende import: terugstorting Tanken, eigen overboeking, losse overboeking naar een potje. |
| D3 | Voorgeschoten eigen plek | Voorgeschoten: Tanken met openstaand bedrag en "Het is binnen…". |
| D4 | Nog rechtzetten | Zijbalk › Nog rechtzetten: vier blokken met de volgende stap; teller in de zijbalk. |

## Na de test

- Alles goed: de tak `ux-ronde` wordt samengevoegd met `main`.
- Een deel niet goed: alleen die commit terugdraaien, de rest samenvoegen.
- Alles niet goed: terug naar `voor-ux-ronde`.
