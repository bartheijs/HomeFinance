# HFBackup

Back-up en herstel van de database, export van de complete dataset als CSV, en verzonnen voorbeelddata.
Hangt alleen af van `HFCore` en GRDB. Alle meldingen voor de gebruiker zijn Nederlands
(`error.localizedDescription`).

## Back-up en herstel (`Backup`)

Een back-up is een consistente kopie via de online-backup-API van SQLite, nooit een bestandskopie van een
database die in gebruik is. Het resultaat is één los bestand (geen `-wal`/`-shm`), dus veilig in een map die
iCloud Drive of Google Drive synchroniseert.

| Functie | Doet |
|---|---|
| `Backup.createBackup(from:to:now:) -> BackupInfo` | Schrijft `HomeFinance-yyyyMMdd-HHmmss.sqlite` in de map (maakt de map zo nodig aan), controleert het bestand en legt het moment vast als laatste back-up. Bestaat de naam al, dan komt er `-2`, `-3` achter. |
| `Backup.verify(backupAt:) -> BackupInfo` | Opent alleen-lezen, draait `PRAGMA integrity_check`, controleert de tabellen en de migraties. Gooit `BackupError` als het geen bruikbare back-up is. |
| `Backup.listBackups(in:) -> [BackupInfo]` | Alle back-ups in de map, nieuwste eerst, elk gecontroleerd. Een onbruikbaar bestand staat erbij met `problem` gevuld. Bevat ook veiligheidskopieën (`kind == .safety`). |
| `Backup.prune(in:keep:) -> [URL]` | Bewaart de nieuwste `keep` gewone back-ups (minstens één). Verwijdert nooit de enige gecontroleerde back-up en nooit een veiligheidskopie. Geeft de verwijderde bestanden terug. |
| `Backup.restore(from:into:safetyFolder:now:) -> RestoreResult` | Zie hieronder. |
| `Backup.isBackupDue(_:now:) -> Bool` | Waar als er rekeningen zijn en de laatste back-up ontbreekt of 7 dagen of langer geleden is. |
| `Backup.backupUsingSettings(_:now:) -> BackupInfo?` | Back-up in de ingestelde map plus opruimen volgens `keepCount`; `nil` als er geen map is ingesteld. Bedoeld voor "back-up bij afsluiten". |
| `Backup.counts(_ db: Database) -> BackupCounts` | Aantallen van de geopende database. |
| `Backup.exportAllAsCSV(_:to:) -> [CSVExportFile]` | Eén `<tabel>.csv` per tabel, zie onder. |
| `Backup.exportYearAsExcel(_:year:to:now:) -> URL` | Eén leesbaar Excel-bestand van een jaar, zie onder. |

### Herstellen

`restore` doet achtereenvolgens: de back-up controleren; een veiligheidskopie van de huidige database schrijven
in `safetyFolder` (`HomeFinance-voor-herstel-yyyyMMdd-HHmmss.sqlite`); de inhoud van de back-up via de
backup-API ín de draaiende database kopiëren; migraties uitvoeren. De app hoeft geen bestanden te wisselen en
niet te herstarten.

- De back-upinstellingen van deze Mac (map, aantal, automatisch, laatste back-up) blijven behouden; al het
  andere komt uit de back-up.
- Gaat er iets mis, dan blijft de database zoals hij was: vóór het kopiëren gebeurt er niets, daarna wordt de
  veiligheidskopie teruggezet (`BackupError.restoreFailed`). Lukt ook dat niet, dan noemt
  `restoreFailedNotRolledBack` het pad van de veiligheidskopie.
- Na afloop wordt `notifyChanges(in: .fullDatabase)` aangeroepen, zodat `ValueObservation`s verversen. Schermen
  die zelf gegevens vasthouden moeten opnieuw laden.
- Roep `restore` niet aan terwijl er elders een schrijftransactie loopt.

### Typen

- `BackupInfo`: `url`, `date`, `size` (bytes), `kind` (`.regular` / `.safety`), `counts`, `firstEntryDay`,
  `lastEntryDay`, `appliedMigrations`, `problem` (nil = in orde), `isVerified`, `fileName`.
- `BackupCounts`: `accounts`, `years`, `entries`, `bankTransactions`.
- `RestoreResult`: `restored`, `safetyBackup`, `migrationsApplied`, `counts`.
- `BackupError` (`LocalizedError`): `fileNotFound`, `notADatabase`, `corrupt`, `notHomeFinance`, `newerVersion`,
  `folderUnavailable`, `restoreFailed`, `restoreFailedNotRolledBack`.

### Instellingen (`BackupSettings`)

Opgeslagen in de tabel `setting` onder `backup.*`.

| Veld | Standaard |
|---|---|
| `folderPath: String?`, `folderBookmark: Data?` | geen map |
| `keepCount: Int` | 30 |
| `autoBackupOnQuit: Bool` | aan |
| `lastBackupAt: Date?` | nil |

`BackupSettings.load(db)`, `settings.save(db)`, `settings.setFolder(url)` (pad plus bookmark),
`settings.folderURL` (bookmark als die nog klopt, anders het pad), `BackupSettings.setLastBackup(db, date)`.

### Voorbeeld

```swift
import HFBackup

// Instellingenscherm: map kiezen
try db.write { database in
    var settings = try BackupSettings.load(database)
    settings.setFolder(chosenFolder)
    try settings.save(database)
}

// Bij afsluiten
let settings = try db.read { try BackupSettings.load($0) }
if settings.autoBackupOnQuit { try Backup.backupUsingSettings(db) }

// Herinnering op het dashboard
if try Backup.isBackupDue(db) { /* toon "maak een back-up" */ }

// Lijst en herstel
let backups = Backup.listBackups(in: folder)          // nieuwste eerst
do {
    let result = try Backup.restore(from: backups[0].url, into: db, safetyFolder: folder)
    print("Teruggezet: \(result.counts.entries) boekingen; veiligheidskopie: \(result.safetyBackup.fileName)")
} catch {
    print(error.localizedDescription)                  // Nederlandse melding
}
```

## Complete export (`Backup.exportAllAsCSV`)

Schrijft per tabel één bestand `<tabel>.csv` in de map: kopregel met de kolomnamen, puntkomma als
scheidingsteken, regeleinde CRLF, UTF-8 met BOM (Excel opent het direct). Bedragen als `1234,56` en `-0,05`
(geen duizendtalscheiding), dagen als `2027-01-31`, ja/nee als `1`/`0`, leeg voor NULL. Tekst met een
puntkomma, aanhalingsteken of regeleinde staat tussen dubbele aanhalingstekens.

```swift
let files = try Backup.exportAllAsCSV(db, to: exportFolder)   // [CSVExportFile(table:url:rowCount:)]
```

## Jaarexport naar Excel (`Backup.exportYearAsExcel`)

Een leesbare kopie van één begrotingsjaar in één bestand, voor Excel, Numbers of Google Sheets.

| Functie | Doet |
|---|---|
| `Backup.exportYearAsExcel(_:year:to:now:) -> URL` | Schrijft `HomeFinance <jaar>.xlsx` in de map (maakt de map zo nodig aan; een bestaand bestand met die naam wordt vervangen). `now` bepaalt de exportdag. |
| `Backup.excelFileName(year:)` | `HomeFinance <jaar>.xlsx` |
| `ExportError` (`LocalizedError`) | `yearNotFound(Int)`: het jaar heeft geen begroting. `writeFailed(String)`: inpakken of schrijven mislukte. Een onbruikbare map geeft `BackupError.folderUnavailable`. |

```swift
do {
    let url = try Backup.exportYearAsExcel(db, year: 2027, to: exportFolder)
    NSWorkspace.shared.activateFileViewerSelecting([url])
} catch {
    print(error.localizedDescription)     // bv. "Er is geen begroting voor het jaar 2031. …"
}
```

Tabbladen:

- **Maandgrid**: `Post | Plan | jan … dec | Jaar`. De vaste posten op volgorde onder de kopjes Inkomsten en
  Uitgaven; RES-regels ingesprongen met alleen hun plan. Een maand zonder boeking is leeg; een met de hand
  afgevinkte maand zonder boeking toont "afgevinkt". Daaronder Vaste posten, IN divers, UIT divers, Netto divers
  en Resultaat, en het jaaroverzicht op de peildag (op de rekening op 1-1, IN, UIT, op de rekening, anti-rood,
  tijdelijk geleend, besteedbaar).
- **Transacties**: één regel per boeking van het begrotingsjaar, op alle rekeningen: datum, telt mee in
  (`jjjj-mm`), rekening, omschrijving, post of pot, divers, tags, bedrag, vergoeden uit spaar, tijdelijk geleend,
  nagekeken, notitie, tegenpartij en bankomschrijving. Met autofilter.
- **Potten**: per spaarrekening de potten met soort, eigenaar, saldo op de peildag, gestort en opgenomen in het
  jaar, doelbedrag en doeldatum; daaronder Totaal potten, Niet toegewezen en het saldo van de rekening. Een
  gearchiveerde pot zonder saldo of beweging staat er niet in.
- **Vaste stortingen**: per storting de regels (pot, bedrag) en het totaal.
- **Toelichting**: exportdatum, jaar, en dat dit een leesbare kopie is en geen back-up.

Rekenregels: dezelfde als het maandgrid in de app. Een boeking telt mee in de begrotingsmaand
`COALESCE(period, maand van day)`; saldi volgen `day`. De peildag is de exportdag, of 31-12 voor een voorbij
jaar. Staat er (tegen de regels in) een boeking op een RES-regel, dan toont die regel het bedrag en telt het mee
in Vaste posten, zodat Resultaat blijft aansluiten op de rekening.

Techniek: de xlsx wordt zonder bibliotheek geschreven (eigen XML, ingepakt met `/usr/bin/zip`). Bedragen zijn
echte getallen met opmaak `#.##0,00`, datums echte datumcellen (`dd-mm-jjjj`), koppen en totalen vet, eerste rij
en kolom bevroren. Totalen zijn `SUM`-formules met de uitkomst erbij bewaard, zodat het bestand ook klopt in een
programma dat niet herberekent.

## Back-up, CSV-export of Excel-export?

| | Back-up | CSV-export | Excel-export |
|---|---|---|---|
| Functie | `createBackup` | `exportAllAsCSV` | `exportYearAsExcel` |
| Wat | het databasebestand, compleet | elke tabel ruw, één bestand per tabel | één jaar, opgemaakt in vijf tabbladen |
| Voor | terugzetten met `restore` | de gegevens meenemen naar iets anders | lezen en doorrekenen |
| Terugzetten in de app | ja | nee | nee |
| Volledig | ja, alle jaren en instellingen | ja, alle tabellen (id's en centen als `1234,56`) | nee: alleen wat op de tabbladen staat |

Alleen de back-up is een back-up. De twee exports zijn kopieën om te lezen; de app kan ze niet inlezen.

## Voorbeelddata (`DemoData`)

Verzonnen gezin ("Ouder 1", "Ouder 2", "Kind 1", "Kind 2"), verzonnen bedrijven, IBAN's `NL00TEST…`.
Dezelfde `today` geeft altijd exact dezelfde data (eigen generator, vaste tijdstempels). Versie 3 (6m) laat
alles zien wat er tot en met 6l in de app kwam; de demo-route staat in de README ("Demonstreren").

| Functie | Doet |
|---|---|
| `DemoData.seed(into:today:leaveRecentForImport:) -> DemoSummary` | Vult een lege database. Gooit `DemoDataError.databaseNotEmpty` als er al rekeningen of een jaar zijn. Met `leaveRecentForImport: true` ontbreken de transacties van de laatste 10 dagen op **beide** rekeningen; die komen uit de voorbeeldzip. |
| `DemoData.openDemo(at:today:leaveRecentForImport:afterSeed:) -> AppDatabase` | Opent het voorbeeldbestand. Leeg: vullen, `voorbeeld.versie` vastleggen en `afterSeed` aanroepen. Andere versie (of geen): het bestand leegmaken en opnieuw vullen. Zelfde versie: niets. Weigert de eigen administratie (`AppDatabase.defaultURL`, ook via een koppeling) vóór er iets geopend wordt. |
| `DemoData.version`, `DemoData.versionKey` | `3`, `"voorbeeld.versie"`. Hoog de versie op bij elke wijziging in de voorbeelddata. |
| `DemoData.writeSampleArchive(today:to:) -> URL` | Schrijft `voorbeeld-bank-<dag>.zip` in de map: per rekening `<IBAN>-<dd-mm-jjjj>.csv` met de laatste 10 dagen (een rekening zonder transacties ontbreekt). Ingepakt met `/usr/bin/zip`. |
| `DemoData.sampleCSV(today:)`, `DemoData.sampleSavingsCSV(today:)` | De CSV van de betaal- of spaarrekening uit die zip (spaar: leeg als er niets was). |
| `DemoData.sampleCSVFileName(today:)`, `DemoData.sampleArchiveFileName(today:)` | `voorbeeld-betaalrekening-<dag>.csv`, `voorbeeld-bank-<dag>.zip` |
| `DemoData.checkingIban`, `DemoData.savingsIban` | De twee eigen IBAN's. |
| `DemoData.sharedPotName`, `DemoData.childOwners` | "Buffer gezin" en ["Kind 1", "Kind 2"], voor het telefoondashboard. De app zet die keuze na het vullen (`DemoSupport.configurePhone`, met HFPublish); HFBackup zelf kent HFPublish niet. |

`DemoSummary`: `checkingAccountId`, `savingsAccountId`, `budgetItemCount`, `potCount`, `bankTransactionCount`,
`newTransactionCount`, `entryCount`, `checkingBalance`, `bookedThrough`.

Wat erin zit, van 1 januari van het jaar van `today` t/m `today`:

- Betaalrekening (beginsaldo € 6.850) en spaarrekening; jaar met anti-rood € 4.500 (`reserveBase` blijft 0).
- 17 vaste posten (salarissen, kinderbijslag en sportvereniging per kwartaal, hypotheek, verzekeringen, energie,
  telecom, streaming, privélening, RESERVERINGEN) en 28 RES-regels, elk met een pot.
- **Potten:** 20 reserveringspotten, de rentepot voor de privélening, per kind spaargeld (met doel), kleedgeld en
  zakgeld, doelen voor Ouder 1 en Ouder 2, "Buffer gezin" (zonder eigenaar, de gezamenlijke spaarpot) en
  "Studie en rijbewijs" met eigenaar **Kids** (een groep) en een spaardoel uit vier onderdelen (`GoalPart`) met
  doeldatum eind augustus volgend jaar.
- **Vaste storting:** één, "Maandelijkse reserveringen", van betaal naar spaar, gekoppeld aan RESERVERINGEN en
  precies verdeeld zoals de RES-regels. (Bewust één: met meer vaste stortingen vanaf dezelfde rekening vraagt
  Nakijken bij een losse overboeking eerst welke storting het is.)
- **Vooruitblik:** de rentepot (rente per maand eraf, schenking van volgend jaar erbij) en "Buffer gezin"
  (€ 150 per maand via de vaste storting en een verwachte "Nieuwe wasmachine" over 75 dagen).
- De spaarrekening heeft beginsaldo € 0,00; wat er op 1 januari staat is per pot geboekt als handboeking
  "Beginsaldo <pot>". Eén boeking zonder pot: de rentebijschrijving van 2 januari (€ 12,84).
- **Tags** Tanken, Uit eten, Cadeau, Vakantie, Rijbewijs Kind 1, Rijbewijs Kind 2, alleen op boekingen van de
  betaalrekening (6h).
- **Tanken verrekent** (6g): startbedrag € 86,40 op 1 januari, "telt mee in nog te besteden" aan, een beginstand
  (`Settlement.isOpening`, € 0). Elke 12e betaalt "Declaraties Werkgever Voorbeeld" de tankbeurten van de maand
  ervoor terug (in januari het startbedrag); elke geboekte terugstorting is een verrekening met de storting
  gekoppeld, zoals `SettlementService.settle`. De tankbeurten van de laatste weken staan open.
- **Regels:** voor alle vaste posten, de tankstations, de rijschool (per kind op de omschrijving) en de jaarrekeningen
  op spaar. Zoals "Onthoud als regel" ze maakt (`origin` geleerd, 6i): zakgeld per kind ("Kind 1 Voorbeeld": op
  IBAN, geen bedrag, geen vaste omschrijving, verrekenen met de zakgeldpot **bij geld eruit**, 6f), restaurants,
  winkels met verrekenen en de declaraties.
- Banktransacties met sluitende saldoketen en per maand een importbatch. Geboekt t/m `today − 10`; daarna
  status `nieuw` (of, met `leaveRecentForImport`, in de voorbeeldzip). De laatste zes geboekte transacties op de
  betaalrekening staan op "nog nakijken". Pinnamen staan er zoals de bank ze levert ("Bakkerij Voorbeeld
  >VOORBEELDSTAD13.11.2027"); de boekingen hebben de nette naam.
- Afwijkingen van het plan (energie in maart, mobiel in februari, salaris met vakantiegeld in mei,
  zorgverzekering in augustus) en één ontbrekende betaling (Water) voor een "te laat".
- Uitgaven met `reimburse` en pot (zakgeld, kleding per kind, rijlessen, garage, tandarts …, de rente op de
  privélening): elke maand op de 27e verrekend in één afgevinkte `SavingsTransfer` met de boekingen van het
  afvinken (notitie `Verrekening #<id>`, `Setting` `savingsTransfer.<id>.entries`) en aan beide kanten de
  banktransactie. In de laatste 10 dagen staat één verrekening die **vastgelegd maar niet afgevinkt** is (op de 27e,
  anders op `today − 5`); zij dekt de geboekte uitgaven tot `today − 10`, en haar overboeking zit in de zip.
- Eén afstemming met verschil € 0,00 op `bookedThrough`.

Wat de laatste 10 dagen (de voorbeeldzip) altijd bevatten, als die dagen in het jaar vallen: wekelijks zakgeld
(6f), "Oppas zaterdag" naar "Oppas Voorbeeld" (eigen tekst, 6b), "Extra voor de vakantie" € 250 van betaal naar
spaar (losse overboeking, 6e), "0712 FRIETKRAAM DEMO S>VOORBEELDSTAD…" (6j), "Terug van schoolreisje" € 12,50
van Kind 1 (geld erin, 6f) en de overboeking van de open verrekening met spaar.

### Voorbeeldzip importeren

```swift
// Zo doet de app het in de voorbeeldmodus:
let db = try DemoData.openDemo(at: demoURL, today: .today(), afterSeed: DemoSupport.configurePhone)
let zip = try DemoData.writeSampleArchive(today: .today(), to: FileManager.default.temporaryDirectory)
// … en daarna het gewone importeren van een zip (HFImport `previewArchive` / `commitArchive`).
```

De zip sluit aan op de saldi van de `leaveRecentForImport`-variant: per rekening is het eerste "saldo vóór
mutatie" gelijk aan het saldo in de app. Importeer hem niet in een database die zonder die optie is gevuld: daar
staan dezelfde regels al als `nieuw`, met een eigen vingerafdruk (`voorbeeld|…`).

Formaat per CSV: 19 kolommen, geen kopregel, komma als scheidingsteken, geen aanhalingstekens, bedragen met een
punt (`-12.50`), regeleinde LF. Kolommen: 0 datum `dd-mm-jjjj`, 1 eigen IBAN, 2 IBAN tegenpartij, 3 naam
tegenpartij, 4 adres, 5 postcode, 6 plaats (leeg), 7 valuta rekening, 8 saldo vóór mutatie, 9 valuta mutatie,
10 bedrag met teken, 11 journaaldatum, 12 valutadatum, 13 interne code, 14 globale code (`PIN`, `INC`, `OVB`),
15 volgnummer, 16 betalingskenmerk, 17 omschrijving, 18 afschriftnummer.
