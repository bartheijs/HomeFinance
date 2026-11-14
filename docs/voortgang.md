# Voortgang en openstaand werk

*Bijgewerkt op 13 november 2026, bij een pauze. Dit bestand is het overdrachtspunt voor de volgende werksessie.*

## Besluiten van vandaag

- Overgang van Excel naar de app per **8 november 2026** (laatste boeking in de Excel). Daarna schaduwdraaien.
- De Excel bevat alleen echte bedragen; vooruit ingevulde verwachtingen haalt de gebruiker altijd weer weg.
- De naad tussen Excel-historie en bank wordt op **saldo** gezocht, niet op datum.
- "Gereserveerd" op de betaalrekening is vervallen; dat geld gaat naar een pot op de spaarrekening.
- "Tijdelijk anti-rood" volgt uit boekingen met de markering *tijdelijk geleend van spaar*.
- Back-up naar iCloud Drive; dashboard voor de telefoon als bestand in een cloudmap (geen hosting).

## Koerswijziging 14 november 2026

- **Start met alleen beginstanden**, geen historie. De gebruiker richt zelf in (posten, potten met beginbedrag)
  om de app te leren kennen. De historie-import staat in de wacht; de oorzaak van de mislukte proefdraai en de
  oplossing staan hieronder en blijven geldig voor later.
- **Vaste storting met verdeling** wordt een eigen instelling (naam, potten met bedrag, totaal); er kunnen er
  meer zijn. Vervangt het maandbedrag per pot en de RES-regels als bron van de verdeling.
- **Een post voor een maand met de hand afvinken** als voldaan.
- **Een boeking kan in een andere maand meetellen** dan zijn datum (`Entry.period`); het saldo volgt de datum.
- Schema v4 staat erin. `HFBudget` en `HFInsight` bouwen de logica; daarna de schermen.

## Stand per onderdeel

| Onderdeel | Stand |
|---|---|
| Naad op saldo in `HFImport` + importvenster | Gebouwd, 66 tests in de module; het venster is alleen in code nagelopen. |
| Telefoondashboard (`HFPublish`, tabblad Telefoon, tweede back-upmap) | Gebouwd, 17 tests; nog niet door de orchestrator nagekeken en niet op een iPhone geprobeerd. |
| Regels leren uit Excel-historie + bankexport (`HistoryRuleSeeder`) | Module gebouwd, 63 tests; de knop in het scherm Regels ontbreekt nog. |
| Verrekenen per tag (Tanken) | Schema v3 staat erin. `SettlementService` (HFBudget) en de leesfuncties (HFInsight) waren in aanbouw bij de pauze; schermen nog niet. |
| Totalen per omschrijving, aanvullen bij typen, bijna-dubbelen, samenvoegen | In aanbouw in HFInsight en HFBudget; schermen nog niet. |
| Excel-historie importeren (`HFHistory`) | Gebouwd, 50 tests op nagebootste bestanden. **De proefdraai op de echte Excels is mislukt; er is niets geïmporteerd.** Zie hieronder. |
| Tijdlijn van de samenwerking als HTML-pagina | Nog niet gemaakt; gevraagd door de gebruiker, te doen na de lopende aanpassingen. |

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

## Nog te doen, in volgorde

1. `HFHistory` aanpassen volgens hierboven; proefdraai; bij succes rekeningen aanmaken en importeren.
2. Wachten tot `HFBudget` en `HFInsight` klaar zijn met verrekenen en omschrijvingen; alles samen testen.
3. Schermen: verrekenen (tag-instelling, actie bij de storting, openstaand bedrag), totalen per omschrijving,
   aanvullen bij typen, omschrijvingen samenvoegen, knop "Leer regels uit bankhistorie".
4. Telefoondashboard nakijken; de regel voor de tweede back-upmap in `Support/ModuleGlue.swift` zetten.
5. Alles bouwen, testen, schermen nakijken, app opnieuw in de map Apps zetten, committen.
6. De tijdlijn als HTML-pagina maken.

## Bekende beperkingen

- De app is nog niet met de hand getest: klikken, vensters en slepen zijn alleen in code nagelopen.
- Datum en maandkolom: de app leidt de maand af uit de datum. Een paar Excel-regels staan bewust in een
  naastgelegen maandkolom en vallen in de app dus in een andere maand.
- Bij de pauze compileerden de tests van `HFInsight` niet (een sessie was halverwege); de app zelf bouwt wel.
