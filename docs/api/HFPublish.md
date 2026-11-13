# HFPublish — het dashboard voor de telefoon

Maakt van de belangrijkste cijfers één los HTML-bestand dat je op een telefoon opent. Er is geen webserver: de
Mac-app zet het bestand in een map die synchroniseert (iCloud Drive of Google Drive) en op de telefoon open je
het met de app Bestanden of Drive.

Hangt af van `HFCore`, `HFInsight` en GRDB. Dit is de enige module die een andere module gebruikt: de pagina is
een weergave van dezelfde cijfers, dus alle getallen komen uit `Insight` en worden hier niet opnieuw berekend.
Geen AppKit, SwiftUI of WebKit; wegschrijven en de PDF doet de app (`Sources/HomeFinance/Publish/`).

```swift
import HFCore
import HFPublish

let snapshot = try appDatabase.read { db in try PhoneDashboard.make(db, today: .today()) }
let html = PhoneDashboard.html(snapshot, options: PublishOptions())
try Data(html.utf8).write(to: folder.appendingPathComponent("HomeFinance vandaag.html"))
```

## Momentopname

`PhoneDashboard.make(_ db: Database, today: Day, now: Date = Date()) -> PhoneSnapshot`

| Veld | Inhoud | Bron in `Insight` |
|---|---|---|
| `today`, `generatedAt` | peildag en moment van maken | |
| `budget` | nil als het begrotingsjaar van `today` niet bestaat | |
| `budget.spendable`, `.spendableEndOfMonth` | besteedbaar nu en eind van de maand | `spendable` |
| `budget.borrowed` | tijdelijk geleend van spaar dat nog uitstaat (nul = niets) | `temporaryLoanOutstanding` |
| `budget.month` | `expenses` en `planExpenses` (beide negatief) en `percent` (nil zonder plan) | `dashboard` |
| `budget.fixedItems` | `paidCount`, `openCount`, `lateCount` en `late` (naam en planbedrag) | `fixedItemsStatus` |
| `budget.trend` | besteedbaar per maandeinde t/m vandaag | `spendableSeries` |
| `accounts` | naam, soort en saldo van de rekeningen die niet gearchiveerd zijn | `dashboard` |
| `potGroups` | per soort (`Reserveringen`, `Sparen`) het totaal en de potten | `potOverview` |
| `unallocated` | saldo op spaar zonder pot | `potOverview` |
| `openReimbursement` | nog over te boeken van spaar (positief) | `openReimbursements` |

- Gearchiveerde potten met saldo nul staan niet in de lijst; het totaal van de groep is dat van `Insight`.
- `percent` is afgerond op hele procenten en kan boven de 100 komen.
- `snapshot.hasSameNumbers(as:)` vergelijkt alles behalve `generatedAt`. De app gebruikt dit om geen nieuw
  bestand te schrijven als er niets veranderd is.

## Pagina

`PhoneDashboard.html(_ snapshot:, options: PublishOptions = .init(), timeZone: TimeZone = .current) -> String`

Eén volledig HTML-document voor een telefoon:

- UTF-8, `<meta name="viewport">`, alle opmaak in één `<style>`-blok.
- **Geen JavaScript en geen externe bronnen** (geen lettertypen, afbeeldingen, links of CDN's). De voorvertoning
  van de app Bestanden op de iPhone voert geen scripts uit; de pagina moet daar gewoon werken.
- Grafieken zijn inline SVG, in Swift gemaakt: een vlakgrafiek voor het verloop en een dunne balk voor de maand.
- Licht en donker via `prefers-color-scheme`; systeemlettertype.
- Bovenaan "HomeFinance" en "Bijgewerkt op 15 mrt 2027 om 14:03". Zonder scripts kan de pagina niet zelf melden
  dat hij oud is; daarom staat de datum duidelijk bovenaan.
- Volgorde: besteedbaar (groot), eind van de maand, eventueel "tijdelijk geleend van spaar" en "nog over te
  boeken van spaar", uitgaven van de maand tegen plan, vaste posten, verloop, rekeningen, potten.
- Eén accentkleur. Rood alleen voor posten die te laat zijn en voor een negatief besteedbaar.
- Bedragen via `Money.formatted()`, maanden via `Day.monthNames` en `Day.monthNamesShort`.
- Alle tekst van de gebruiker (namen van rekeningen, posten en potten) gaat door `PhoneDashboard.escape`.
- Bestaat het begrotingsjaar niet, dan staat er "Er is nog geen begroting voor <jaar>." met wat je moet doen;
  rekeningen en potten staan er dan nog wel.
- Dezelfde momentopname, opties en tijdzone geven exact dezelfde tekst.

## Opties en instellingen

`PublishOptions` (Codable, standaard alles aan): `showFixedItems`, `showTrend`, `showAccounts`, `showPots`.
Besteedbaar en de uitgaven van de maand staan er altijd op. Ontbrekende sleutels bij het lezen betekenen "aan".

`PublishSettings` staat in de tabel `setting` onder `publish.*`:

| Veld | Sleutel | Standaard |
|---|---|---|
| `enabled` | `publish.enabled` | uit: de gebruiker zet dit zelf aan |
| `folderPath` (`folderURL`) | `publish.folderPath` | geen map |
| `options` | `publish.options` (JSON) | alles aan |
| `lastPublishedAt` | `publish.lastPublishedAt` | nil |
| `lastError` | `publish.lastError` | nil |

- `PublishSettings.load(db)` en `settings.save(db)`. `save` bewaart alleen de keuzes (aan/uit, map, opties).
- `PublishSettings.recordSuccess(db, at:)` bewaart het moment en wist de fout.
- `PublishSettings.recordFailure(db, message:)` bewaart de melding en schrijft niets als dezelfde melding er al
  staat. Dat voorkomt een kring: elke schrijfactie in de database plant in de app een nieuwe versie in.

## Wat de app ermee doet

`Sources/HomeFinance/Publish/PublishSupport.swift`:

- `schedule(model)` na elke wijziging in de database: tien seconden na de laatste wijziging wordt er buiten de
  hoofdthread gelezen en geschreven. Alleen als het aan staat en niet met voorbeelddata.
- `publishNow(model)` bij afsluiten; wacht tot het klaar is.
- `publish(model, force:)` voor de knop "Nu bijwerken"; `preview(model)` schrijft naar een tijdelijke map en
  opent de pagina in de browser (werkt ook met voorbeelddata).
- Twee bestanden in de gekozen map: `HomeFinance vandaag.html` en `HomeFinance vandaag.pdf`. Elk bestand komt
  eerst onder een tijdelijke naam (beginnend met een punt) in dezelfde map en vervangt dan in één stap het oude.
- De PDF is dezelfde pagina, getekend op 390 punten breed met een `WKWebView` buiten beeld
  (`PhonePDFRenderer`): één lange pagina, lichte weergave. Mislukt de PDF, dan wordt het HTML-bestand toch
  bijgewerkt en staat dat bij de laatste fout.
- Bestaat de map boven de gekozen map niet (cloudschijf uit), dan wordt er niets aangemaakt. Fouten geven geen
  melding in beeld; de laatste fout staat bij Instellingen › Telefoon.
- `SecondBackupSupport` (zelfde bestand) regelt de tweede back-upmap: sleutel `backup.secondFolderPath`.

## Niet getest op een echte telefoon

De pagina is bekeken in WebKit op de Mac op 390 punten breed, licht en donker, en de PDF is nagekeken. Hoe de
app Bestanden en de app Google Drive op een iPhone de bestanden tonen, is niet gecontroleerd.
