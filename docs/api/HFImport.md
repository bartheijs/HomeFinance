# HFImport

Leest een bank-CSV of een PDF-rekeningafschrift voor één rekening, toont een voorbeeld en importeert het als `BankTransaction`-regels
(status `nieuw`) met één `ImportBatch`. Hangt alleen af van `HFCore` en GRDB. Doet geen voorstellen voor
boekingen; dat is `HFRules`.

## Gebruik

```swift
import HFCore
import HFImport

let importer = BankImporter(database: appDatabase)

// 1. Voorbeeld (schrijft niets). Zonder profiel wordt het geraden.
let preview = try importer.preview(url: fileURL, accountId: account.id!)

preview.rows            // gelezen transacties, in de volgorde van het bestand
preview.errors          // foute regels: regelnummer + Nederlandse melding
preview.warnings        // bv. IBAN hoort niet bij de rekening, saldoketen sluit niet
preview.newCount        // wordt geïmporteerd
preview.duplicateCount  // staat al in de database
preview.chainOK         // true / false / nil (bestand levert geen saldo)
preview.openingBalance  // saldo vóór de eerste regel
preview.closingBalance  // saldo ná de laatste regel

// 2. Importeren, in één databasetransactie.
let result = try importer.commit(preview)                        // weigert bij foute regels
let result2 = try importer.commit(preview, skipFaultyRows: true) // slaat foute regels bewust over
result.batch            // de ImportBatch
result.transactions     // de nieuwe BankTransaction-regels, van oud naar nieuw

// Of in één keer:
try importer.importFile(url: fileURL, accountId: account.id!)
```

Fouten zijn `ImportError` (`LocalizedError`, Nederlandse `errorDescription`):
`unreadable`, `emptyFile`, `noProfile`, `accountNotFound`, `columnNotFound(naam)`, `rowErrors(aantal)`,
voor PDF `pdfUnreadable`, `pdfWithoutText`, `noTransactionTable`, en voor zip `archiveUnreadable`,
`archiveUnsafePath(naam)`, `nothingToImport`.

Een PDF gaat via dezelfde aanroepen: `preview(url:…)` en `preview(data:fileName:…)` herkennen een PDF aan
de inhoud (`%PDF`) of de extensie, en geven een gewone `ImportPreview`. `profile` telt dan niet mee.
`PDFStatement.isPDF(data:fileName:)` vertelt een scherm vooraf of het kolommen kiezen kan overslaan.

### Zip van de bank (hoofdroute)

De bank levert één zip met één CSV per rekening; de bestandsnaam begint met het IBAN
(`NL00TEST0000000001-13-11-2026T13_33_15.csv`).

```swift
let archive = try importer.previewArchive(url: zipURL)      // of previewArchive(data:fileName:)

for item in archive.items {
    item.fileName   // pad binnen de zip
    item.iban       // uit de regels, anders uit de bestandsnaam
    item.account    // de rekening met dat IBAN, of nil
    item.preview    // ImportPreview als er een rekening is
    item.message    // waarom het bestand niet meegaat, bv. "Geen rekening met IBAN … gevonden."
}
archive.importableItems; archive.skippedItems
archive.newCount; archive.duplicateCount; archive.errorCount; archive.canCommit

// Alles in één databasetransactie: alles of niets.
let results = try importer.commitArchive(archive)            // [ArchiveImportResult]
let results2 = try importer.commitArchive(archive, skipFaultyRows: true)
results[0].account; results[0].fileName; results[0].result   // result is een ImportResult
```

### Eerste bankimport van een rekening: de naad zoeken

Een rekening start met een beginsaldo en een begindatum, of met Excel-historie (boekingen met
`note == "Excel-historie"`, zonder banktransactie). Wat vóór dat startpunt ligt, herkent de vingerafdruk
niet. De volgorde is: **eerst op saldo, dan op datum, dan met de hand.**

```swift
guard try importer.needsSeam(accountId: id) else { /* gewone import; de vingerafdruk doet het werk */ }

let preview = try importer.preview(
    url: fileURL, accountId: id,
    skipThrough: try importer.defaultSkipThrough(accountId: id),   // terugval op datum
    resumeFromBalance: try importer.resumeBalance(accountId: id))  // saldo van de rekening in de app

if let seam = preview.seam {
    seam.method          // .foundByBalance, .alreadyProcessed, .byDate, .notFound, .manual
    seam.lineNumber      // eerste regel die meegaat (nil als er niets meegaat)
    seam.day; seam.balance; seam.skippedCount
    seam.seamCandidates  // regelnummers waar het saldo aansluit; meer dan één = twijfel
    seam.isAmbiguous; seam.balanceNotFound
    seam.soughtBalance; seam.fileOpeningBalance; seam.fileClosingBalance
}

// Niet gevonden of twijfel: de gebruiker kiest zelf per regel. Geeft een nieuw voorbeeld terug.
let chosen = preview.overriding(includeLineNumbers: [12], excludeLineNumbers: [3, 4])
try importer.commit(chosen)   // volgt de keuze

// Zip: per rekening een eigen saldo (alleen rekeningen waarvoor needsSeam true is).
try importer.previewArchive(url: zipURL, skipThroughByAccount: [checkingId: dayA],
                            resumeFromBalance: [checkingId: saldoA, savingsId: saldoB])
```

### Overgangsdag op datum (terugval)

Alles tot en met de overgangsdag staat al als Excel-historie in de app (boekingen met
`note == "Excel-historie"`, zonder banktransactie). Die regels herkent de vingerafdruk niet, dus ze moeten
op datum buiten de import blijven.

```swift
let cutover = try importer.historyCutover(accountId: id)     // laatste historie-dag, of nil
let preview = try importer.preview(url: fileURL, accountId: id, skipThrough: cutover)

preview.cutoverSkippedCount   // regels van op of vóór de overgangsdag
preview.rows[0].isBeforeCutover
preview.newCount              // telt ze niet mee
preview.openingBalance        // saldo vóór de eerste regel die wel meegaat
preview.fileOpeningBalance    // saldo vóór de allereerste regel van het bestand
try importer.commit(preview)  // importeert alleen de latere regels

// Zip: één dag voor alles, of per rekening een eigen dag (gaat voor).
try importer.previewArchive(url: zipURL, skipThrough: cutover)
try importer.previewArchive(url: zipURL, skipThroughByAccount: [checkingId: dayA, savingsId: dayB])
```

### Los bestand: bij welke rekening hoort het?

```swift
let match = try importer.matchAccount(data: data, fileName: name)   // vóór de gebruiker een rekening kiest
match.account    // voorstel, of nil
match.message    // "Geen rekening met IBAN … gevonden." of "… geen IBAN; kies zelf de rekening."

try importer.matchAccount(forFileNamed: name, rows: preview.rows)   // als er al een voorbeeld is

// Koos de gebruiker de verkeerde rekening, dan zegt de waarschuwing welke het wel is:
preview.warnings.first { $0.kind == .ibanMismatch }?.suggestedAccount
```

### Kolommen met de hand kiezen

Als `preview` de fout `noProfile` geeft, of de gebruiker de indeling wil aanpassen:

```swift
let file = try CSVFile(data: data)   // codering en scheidingsteken worden geraden
file.rawRows(limit: 10)              // [[String]]: de eerste regels onbewerkt
file.columnCount
detectProfile(for: file)             // BankProfile? (hetzelfde als BankProfile.detect(for:))

var profile = BankProfile(id: "eigen", name: "Mijn bank", hasHeader: true,
                          day: .header("Datum"), dateFormats: ["dd-MM-yyyy"], amount: .index(6),
                          debitCredit: DebitCreditIndicator(column: .header("Af Bij")),
                          balance: BalanceColumn(column: .index(9), kind: .after),
                          counterpartyName: .index(1), description: [.index(8)])
let preview = try importer.preview(data: data, fileName: name, accountId: id, profile: profile)

// Bewaren als JSON in Setting:
let json = String(decoding: try JSONEncoder().encode(profile), as: UTF8.self)
```

## Publieke API

| Type | Wat |
|---|---|
| `BankImporter` | `init(database:)`, `preview(data:fileName:accountId:profile:skipThrough:)`, `preview(url:accountId:profile:skipThrough:)`, `commit(_:skipFaultyRows:)`, `importFile(data:…)`, `importFile(url:…)` (beide met `skipThrough:`), `historyCutover(accountId:)`, `previewArchive(url:skipThrough:skipThroughByAccount:)`, `previewArchive(data:fileName:skipThrough:skipThroughByAccount:)`, `commitArchive(_:skipFaultyRows:)`, `matchAccount(forFileNamed:rows:)`, `matchAccount(data:fileName:)` |
| `ImportSeam` | `method`, `soughtBalance`, `lineNumber`, `day`, `balance`, `skippedCount`, `seamCandidates`, `closingBalanceMatches`, `isAmbiguous`, `balanceNotFound`, `fileOpeningBalance`, `fileClosingBalance` |
| `ImportPreview` (naad) | `seam`, `overriding(includeLineNumbers:excludeLineNumbers:)`; `preview(…)`, `importFile(…)` en `ImportPreview.build(…)` hebben `resumeFromBalance: Money?`, `previewArchive(…)` heeft `resumeFromBalance: [Int64: Money]` |
| `BankImporter` (naad) | `needsSeam(accountId:)`, `resumeBalance(accountId:)`, `defaultSkipThrough(accountId:)`, `historyCutover(accountId:)` |
| `ArchivePreview` | `fileName`, `items`, `importableItems`, `skippedItems`, `newCount`, `duplicateCount`, `cutoverSkippedCount`, `errorCount`, `canCommit` |
| `ArchiveItem` | `fileName`, `iban`, `account`, `preview`, `message`, `isImportable` |
| `ArchiveImportResult` | `fileName`, `account`, `result` |
| `AccountMatch` | `iban`, `account`, `message` |
| `ImportPreview` | `rows`, `errors`, `warnings`, `rowsChronological`, `chainOK`, `chainBreaks`, `openingBalance`, `fileOpeningBalance`, `closingBalance`, `firstDay`, `lastDay`, `skipThrough`, `rowCount`, `newCount`, `duplicateCount`, `cutoverSkippedCount`, `errorCount`, `canCommit`, `profile`, `encodingName`, `dialect`; `ImportPreview.build(file:fileName:account:profile:existingFingerprints:skipThrough:)` zonder database |
| `ImportRow` | `lineNumber`, `day`, `amount`, `balanceBefore`, `balanceAfter`, `counterpartyName`, `counterpartyIban`, `descriptionText`, `reference`, `transactionCode`, `sequence`, `statementNumber`, `ownIban`, `fingerprint`, `isDuplicate`, `isBeforeCutover` |
| `ImportRowError` | `lineNumber`, `message`, `fields`, `description` ("Regel 12: …") |
| `ChainBreak` | `lineNumber`, `previousLineNumber`, `expected`, `found`, `message` |
| `ImportWarning` | `kind` (`ibanMismatch`, `chainBroken`, `chainNotChecked`, `beforeCutover`, `seamNotFound`, `seamAmbiguous`, `alreadyProcessed`, `manualSelection`), `message`, `suggestedAccount` (bij `ibanMismatch`) |
| `ImportResult` | `batch`, `transactions`, `duplicateCount`, `cutoverSkippedCount`, `skippedErrorCount` |
| `ImportError` | zie hierboven |
| `BankProfile` | Codable. `BankProfile.asn`, `BankProfile.generic(headers:)`, `BankProfile.detect(for:)`, `BankProfile.parseDay(_:formats:)` |
| `ColumnRef` | `.index(Int)` (vanaf 0) of `.header(String)`; in JSON een getal of een tekst |
| `DebitCreditIndicator` | `column`, `debitValues`, `creditValues` (standaard af/d/debet…, bij/c/credit…) |
| `BalanceColumn` | `column`, `kind` (`.before` of `.after`) |
| `CSVFile` | `init(data:dialect:)`, `init(text:encoding:dialect:)`, `records`, `rawRows(limit:)`, `columnCount`, `dialect`, `encoding`, `encodingName`, `reparsed(with:)` |
| `CSVReader` | `decode(_:)`, `detectDialect(_:)`, `parse(_:dialect:limit:)` |
| `CSVDialect`, `CSVRecord` | scheidingsteken en aanhalingsteken; regel met `lineNumber`, `fields`, `unterminatedQuote` |
| `Fingerprint` | `make(accountId:day:amount:counterpartyIban:sequence:statementNumber:description:occurrence:)` |
| `PDFStatement` | `isPDF(data:fileName:)` |
| `BankProfile.pdfStatement` | het profiel dat een voorbeeld uit een PDF meekrijgt (`id == "pdf"`), alleen ter informatie |
| `detectProfile(for:)` | losse functie, gelijk aan `BankProfile.detect(for:)` |

## Gedrag

**CSV lezen.** Codering: UTF-8 (met of zonder BOM), dan Windows-1252, dan ISO-8859-1. Scheidingsteken
(`,` `;` tab) en aanhalingsteken (`"` `'`) worden geraden uit de eerste 100 regels. Velden tussen
aanhalingstekens mogen het scheidingsteken, regeleinden en een verdubbeld aanhalingsteken bevatten. Lege
regels (ook regels met alleen scheidingstekens) tellen niet mee. Regelnummers beginnen bij 1 en wijzen naar
de regel in het bestand, kopregel meegeteld.

**Profielen.**
- `asn`: bevestigd met echte exports van de bank (profiel herkend, geen fouten, saldoketen sluit, opnieuw
  importeren geeft niets nieuws). Geen kopregel, 19 kolommen: 0 datum (dd-mm-jjjj), 1 eigen IBAN, 2 tegenrekening, 3 naam, 8 saldo
  vóór mutatie, 10 bedrag met teken, 14 globale transactiecode, 15 volgnummer, 16 betalingskenmerk,
  17 omschrijving, 18 afschriftnummer. Alleen datum en bedrag zijn verplicht; ontbrekende kolommen
  daarna geven een lege waarde.
- `generic(headers:)`: bouwt een profiel uit de kopregel door gangbare Nederlandse en Engelse namen te
  herkennen (datum/date, bedrag/amount, naam/name, tegenrekening, rekening/iban, omschrijving/mededelingen/
  description, saldo na/voor mutatie, af bij, volgnr, …). Geeft `nil` zonder datum- en bedragkolom.
- `detect(for:)`: kopregel herkend → `generic`; anders, als kolom 0 een datum en kolom 10 een bedrag is →
  `asn`; anders `nil`.
- Datumnotaties: letters `d`, `M`, `y`. Met scheidingstekens (`dd-MM-yyyy`, `yyyy-MM-dd`, `MM/dd/yyyy`,
  `dd-MM-yy`) mag het teken in het bestand afwijken en mag er een tijd achter staan; zonder (`yyyyMMdd`) is
  de breedte vast. De notaties worden in volgorde geprobeerd.
- Bedragen gaan door `Money(parsing:)`. Met `debitCredit` bepaalt die kolom het teken; een onbekende
  waarde is een fout op de regel.

**Voorbeeld.** Elke regel wordt een `ImportRow` of een `ImportRowError`; er verdwijnt niets stil. Meldingen:
ongeldige datum, ongeldig bedrag, ongeldig saldo, onbekende af/bij-aanduiding, te weinig kolommen,
aanhalingsteken niet afgesloten.

**Saldoketen.** Alleen als elke gelezen regel een saldo heeft (anders `chainOK == nil`). De regels worden op
dag gesorteerd; binnen een dag wordt de volgorde gekozen (volgnummer, bestandsvolgorde of omgekeerd) die de
minste breuken geeft. Zo maakt het niet uit of het bestand oud→nieuw of nieuw→oud staat. Elke breuk staat
in `chainBreaks`. Een gebroken keten is een waarschuwing en houdt importeren niet tegen; `ImportBatch.chainOK`
wordt dan `false`. Zonder saldo in het bestand is `ImportBatch.chainOK` `true` en zijn begin- en eindsaldo
`nil`.

**Dubbelen.** Vingerafdruk = SHA-256 over rekening-id, dag, bedrag, tegenrekening (IBAN), volgnummer,
afschriftnummer, omschrijving en een volgnummer voor verder gelijke regels binnen hetzelfde bestand. Twee
echt gelijke regels op één dag worden dus allebei geïmporteerd; hetzelfde of een overlappend bestand
opnieuw importeren voegt niets dubbel toe. Naam van de tegenpartij en saldo tellen niet mee.

**Importeren.** `commit` doet alles in één `write`: `ImportBatch` invoegen, daarna de nieuwe regels van oud
naar nieuw. Dubbelen worden binnen de transactie opnieuw bepaald. Bij een fout wordt alles teruggedraaid.
Ook als alle regels dubbel zijn komt er een `ImportBatch` (met `newCount == 0`), zodat de poging en het
eindsaldo vastliggen. `ImportBatch.rowCount` telt goede en foute regels samen.

## De naad met de Excel-historie

Alleen nodig bij de eerste bankimport van een rekening. Dat geldt voor een rekening die met alleen een
beginsaldo start én voor een rekening met Excel-historie.

- **`needsSeam(accountId:)`** is true zolang de rekening nog geen enkele `bankTransaction` heeft, met of
  zonder Excel-historie. Daarna herkent de vingerafdruk wat al geïmporteerd is en geef je niets mee.
- **`resumeBalance(accountId:)`** is het saldo van de rekening in de app: `Account.openingBalance` plus alle
  boekingen op die rekening (handmatige boekingen en Excel-historie tellen mee). Gebruik dit als
  `resumeFromBalance`, zodat elke aanroeper hetzelfde bedrag gebruikt.
- **`defaultSkipThrough(accountId:)`** is de dag voor de terugval op datum: de laatste dag van de
  Excel-historie als die er is, anders de dag vóór `Account.openingDate`. Regels óp de begindatum gaan dan
  mee; regels van daarvoor niet. `historyCutover(accountId:)` blijft bestaan en geeft nil zonder historie.
- **Tekst van de waarschuwing bij overslaan op datum:** met Excel-historie "… die periode staat al in je
  Excel-historie.", zonder "… die vallen vóór je beginsaldo." De andere teksten spreken van "je
  administratie" en gelden voor beide.

**1. Op saldo (`resumeFromBalance`).** Het bestand moet voor elke regel een saldo hebben (CSV met saldokolom,
of PDF met beginsaldo). In tijdsvolgorde wordt de regel gezocht waarvan het saldo vóór mutatie gelijk is aan
het saldo van de administratie. Dat werkt ook midden op een dag, waar een datum tekortschiet.
- **Gevonden (`foundByBalance`):** alle regels daarvóór krijgen `isBeforeCutover` en gaan niet mee;
  `openingBalance` is het gezochte saldo. Zijn er regels overgeslagen, dan volgt een waarschuwing
  `beforeCutover` ("N regels vóór regel X (datum) zijn overgeslagen: het saldo … sluit daar aan.").
- **Meer kandidaten:** de vroegste waarvoor de keten daarna nergens breekt wint. `seamCandidates` bevat alle
  regelnummers, `isAmbiguous` is true en er komt een waarschuwing `seamAmbiguous`. Breekt de keten na elke
  kandidaat, dan wint het eindsaldo als dat aansluit, anders de vroegste kandidaat.
- **Alles al verwerkt (`alreadyProcessed`):** het saldo is gelijk aan het saldo ná de laatste regel en geen
  regel sluit beter aan. Alle regels krijgen `isBeforeCutover`, `newCount == 0`, waarschuwing
  `alreadyProcessed`. Sluit het saldo ook op een regel aan, dan wint die regel (met `seamAmbiguous`).
- **Niet gevonden:** waarschuwing `seamNotFound` ("Geen regel in dit bestand sluit aan op het saldo € … van je
  administratie. Het bestand begint met € … en eindigt met € ….") en `seam.balanceNotFound` is true. Levert
  het bestand geen saldo per regel, dan zegt de waarschuwing dat.

**2. Op datum (`skipThrough`).** Alleen als het saldo niet is gevonden of niet is meegegeven: `seam.method`
is `.byDate` en de regels hieronder gelden. Zonder datum is het `.notFound` en gaan alle regels mee.

**3. Met de hand.** `preview.overriding(includeLineNumbers:excludeLineNumbers:)` geeft een nieuw voorbeeld
waarin regels zijn aan- of uitgezet (uitzetten wint als een regel in beide staat). `seam.method` wordt
`.manual`, tellingen, `openingBalance`, `firstDay` en `lastDay` worden opnieuw bepaald, en er komt een
waarschuwing `manualSelection` als er regels uit staan. De waarschuwing `seamNotFound` blijft staan.
`commit` volgt de keuze. Een regel die al in de database staat (`isDuplicate`) wordt ook na aanzetten niet
opnieuw geïmporteerd. De functie werkt op elk voorbeeld, ook zonder naad.

`isBeforeCutover` betekent dus in alle drie de gevallen: deze regel gaat niet mee. `seam` is nil als er geen
`resumeFromBalance` en geen `skipThrough` is meegegeven. Het saldo van de administratie rekent `HFImport`
niet zelf uit; dat komt van het scherm (via `HFInsight`).

## Overgangsdag op datum (`skipThrough`)

- **Standaard nil:** dan verandert er niets. Met een dag krijgen regels met `day <= skipThrough` de vlag
  `isBeforeCutover`; ook de regels óp de dag zelf. Ze blijven in `rows` staan (het scherm kan ze grijs tonen),
  tellen niet mee in `newCount` of `duplicateCount`, en `commit`/`commitArchive` importeren ze niet.
- **Waarschuwing `beforeCutover`:** "N regels van dd-mm-jjjj of eerder zijn overgeslagen: die periode staat
  al in je Excel-historie." Alleen als er echt regels zijn overgeslagen.
- **Saldoketen:** wordt over alle regels van het bestand gecontroleerd, ook de overgeslagen; een breuk in
  het overgeslagen deel wordt dus nog steeds gemeld.
- **`openingBalance`** is het saldo vóór de eerste regel na de overgangsdag (in tijdsvolgorde), zodat het
  scherm het kan vergelijken met het berekende saldo in de app op de overgangsdag. `fileOpeningBalance` is
  het saldo vóór de allereerste regel van het bestand. `closingBalance` blijft het saldo na de laatste regel.
  `firstDay`/`lastDay` gaan over de regels die meegaan. Gaat er niets mee, dan zijn die nil en is
  `openingBalance` gelijk aan `closingBalance`.
- **`ImportBatch`** beschrijft wat er geïmporteerd is: `openingBalance`, `firstDay` en `lastDay` volgen de
  preview (dus vanaf de eerste regel na de overgangsdag), zodat beginsaldo + de regels van de batch-periode
  = eindsaldo. Zonder `skipThrough` is dat hetzelfde als voorheen: het saldo vóór de eerste regel van het
  bestand. `rowCount` telt alle regels van het bestand; het aantal overgeslagen regels staat niet in de
  tabel maar wel in `ImportResult.cutoverSkippedCount`.
- **Foute regels** hebben geen leesbare datum en blijven fouten, ook als ze in de oude periode vallen.
- **`historyCutover(accountId:)`** is `MAX(day)` van de boekingen van die rekening met
  `note = 'Excel-historie'`; nil als die er niet zijn.
- **PDF:** werkt hetzelfde; het saldo per regel is daar uitgerekend vanaf het beginsaldo van het afschrift.

## Zip van de bank

- **Uitpakken:** met `/usr/bin/unzip` naar een eigen tijdelijke map, die na het lezen weer wordt verwijderd.
  Bevat de zip een pad dat buiten de map uitkomt (`..`, absoluut pad), dan wordt het hele archief geweigerd
  met `archiveUnsafePath`. Snelkoppelingen worden niet gelezen maar wel gemeld. Geen geldige zip:
  `archiveUnreadable`.
- **Per bestand een `ArchiveItem`**, op naam gesorteerd. CSV (`.csv`, `.txt`) en PDF worden gelezen; een
  ander bestandstype, een leeg bestand, een bestand zonder IBAN, een onbekend IBAN of een onleesbaar bestand
  krijgt een `message` en gaat niet mee. Alleen `__MACOSX/` en `.DS_Store` worden zonder melding genegeerd.
- **Rekening:** het meest voorkomende eigen IBAN in de regels (ASN: kolom 1; PDF: de kop), anders het IBAN
  in de bestandsnaam. Vergelijken gaat zonder spaties en hoofdletterongevoelig, ook met gearchiveerde
  rekeningen.
- **`commitArchive`:** importeert alle `importableItems` in één `write`; bij een fout in één bestand wordt
  niets van de hele zip geïmporteerd. Foute regels in een van de bestanden geven `rowErrors` (totaal), tenzij
  `skipFaultyRows`. Geen enkel importeerbaar bestand: `nothingToImport`. Per bestand komt er een eigen
  `ImportBatch`. Twee bestanden voor dezelfde rekening in één zip mogen overlappen.

## PDF-rekeningafschrift

CSV is de hoofdroute; de PDF is de terugvaloptie.

De tekstlaag wordt met PDFKit gelezen en op patronen doorzocht, niet op regelnummers (de kopregels staan in
de tekstlaag soms door elkaar). `ImportRow.lineNumber` is de regel in de tekstlaag, doorgeteld over de
pagina's.

- **Kop:** het eerste IBAN buiten de tabel is het eigen IBAN (met of zonder spaties). "Beginsaldo op
  dd-mm-jjjj" en "Eindsaldo op dd-mm-jjjj" met het bedrag op dezelfde regel, of op de eerstvolgende regel
  die alleen een bedrag is (staan beide labels eerst, dan horen de bedragen er in dezelfde volgorde bij).
- **Tabel:** begint per pagina na de regel "Datum Bij/Af Bedrag (€) Omschrijving". Een pagina zonder die
  regel is een vervolgpagina. Een transactie is `dd-mm-jjjj Bij|Af bedrag omschrijving`; Bij is positief,
  Af negatief.
- **Vervolgregels:** regels na een transactie die niet met een datum beginnen horen bij de omschrijving
  (samengevoegd met een spatie), ook over een paginagrens. Overgeslagen worden: de kop van elke pagina,
  "Blad", "x van y", "Rekeningafschrift", de periode-regel, "Kredietlimiet", "Rekeninghouder", de
  saldoregels en losse bedragen met €.
- **Tegenpartij:** het eerste IBAN in de omschrijving dat niet het eigen IBAN is, met als naam de rest van
  die regel; of een regel "Naam: …". Anders leeg.
- **Fouten:** elke regel in de tabel die met een datum begint maar niet te lezen is, wordt een
  `ImportRowError` (ongeldig bedrag, onbekende af/bij-aanduiding, ongeldige datum, geen leesbare
  transactie). Vervolgregels van zo'n foute regel vervallen.
- **Saldo:** `balanceBefore` wordt per regel uitgerekend vanaf het beginsaldo, in tijdsvolgorde (de datums
  van de eerste en laatste regel bepalen of het bestand oplopend of aflopend is). `chainOK` is true als
  beginsaldo + som van de regels gelijk is aan het eindsaldo; anders false met een waarschuwing
  `chainBroken` waarin de bedragen staan (`chainBreaks` blijft leeg, er is geen regel aan te wijzen).
  Ontbreekt een begin- of eindsaldo, dan is `chainOK` nil met waarschuwing `chainNotChecked`.
  `openingBalance` en `closingBalance` komen uit de kop.
- **Dubbelen:** dezelfde vingerafdruk als bij CSV, zonder volgnummer en afschriftnummer; gelijke regels op
  één dag worden onderscheiden door hun volgorde. Witruimte in de omschrijving wordt samengevoegd, zodat
  hetzelfde afschrift altijd dezelfde vingerafdruk geeft. Een overlappend afschrift importeert alleen de
  nieuwe regels.
- **Fouten voor het hele bestand:** `pdfUnreadable` (geen geldige PDF), `pdfWithoutText` (geen tekstlaag,
  bv. een scan), `noTransactionTable` (geen tabelkop en geen transacties gevonden). Een afschrift met
  tabelkop maar zonder transacties geeft een leeg voorbeeld; `commit` weigert dat met `emptyFile`.

## Aannames
- De PDF-indeling is afgeleid van één voorbeeld (spaarrekening, één transactie). Meerregelige omschrijvingen,
  vervolgpagina's en de plek van tegenpartijnaam en IBAN zijn niet met een echt bestand gecontroleerd.
- Een transactie staat in de tekstlaag op één regel. Staat de datum los van de rest, dan wordt dat een
  gemelde fout, geen stille misser.
- Een vervolgregel die zelf met een datum begint (dd-mm-jjjj) wordt als foute transactieregel gemeld.
- Dezelfde transactie uit een CSV en uit een PDF heeft een andere vingerafdruk (andere omschrijving, geen
  volgnummer). Gebruik per rekening één van beide bronnen, anders komen regels dubbel binnen.

- De zip is getest met in de test gemaakte bestanden, niet met een echte export van de bank.
- `BankTransaction` heeft geen veld voor het afschriftnummer; het zit wel in de vingerafdruk en in
  `ImportRow.statementNumber`, maar wordt niet bewaard.
- Van de twee ASN-transactiecodes wordt de globale (kolom 14) bewaard in `transactionCode`.
- Een IBAN dat niet bij de rekening hoort geeft alleen een waarschuwing; het scherm beslist of importeren
  dan mag.
