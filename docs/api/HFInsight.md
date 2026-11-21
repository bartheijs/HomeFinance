# HFInsight — lezen en rekenen

Alle alleen-lezen queries en berekeningen voor de schermen. Hangt alleen af van `HFCore` en GRDB; geen SwiftUI.

- Alle functies staan in de naamruimte `Insight` en krijgen een GRDB `Database`. Ze werken dus in
  `db.read { }` én in een `ValueObservation`. Ze schrijven nooit.
- "Vandaag" is altijd een parameter (`today: Day`), nooit de systeemklok.
- Resultaten zijn gewone `Sendable`, `Equatable` structs; lijsten zijn `Identifiable`.
- Fouten: `InsightError` (`yearNotFound`, `accountNotFound`, `potNotFound`) met een Nederlandse
  `localizedDescription`.

```swift
import HFCore
import HFInsight
import GRDB

let today = Day.today()

// Eenmalig lezen
let grid = try appDatabase.read { db in try Insight.monthGrid(db, year: 2027, today: today) }

// Live bijwerken in een scherm
let observation = ValueObservation.tracking { db in try Insight.dashboard(db, today: today) }
for try await dashboard in observation.values(in: appDatabase.reader) {
    print(dashboard.spendable?.spendable ?? .zero, dashboard.attention.map(\.message))
}
```

## Begrotingsmaand (`Entry.period`)

Een boeking telt voor de begroting mee in zijn **begrotingsmaand**: `period` ("yyyy-MM") als die gezet is, anders
de maand van `day`. Intern is dat één SQL-expressie (`Q.period`).

- **Volgt de begrotingsmaand:** `monthGrid`, `cellEntries`, `diversEntries`, `fixedItemsStatus`, "nog verwacht
  deze maand" in `spendable`, `monthlyResults`, `budgetVsActual`, `tagYear`, `tagEntries`, `topTags`,
  `topDiversExpenses`, `diversByTag`, `yearOverYear`, `labelTotals`, `labelEntries`, `labelYears`, IN/UIT in
  `yearSummary`, de maandcijfers in `dashboard`, en `year`/`month` in `EntryFilter`.
- **Volgt de echte datum `day`:** saldi, besteedbaar "nu", potsaldi, saldoreeksen, en `from`/`to` in `EntryFilter`.
- `EntryRow` heeft `period` en de afgeleide `budgetYear` en `budgetMonth`.
- `YearSummary`: `income`/`expenses` gaan over het begrotingsjaar, `balance` en `openingBalance` volgen de datum.
  `shiftedAcrossYear` is het verschil, zodat altijd geldt:
  `openingBalance + income + expenses − shiftedAcrossYear == balance`.

## Maandgrid en vaste posten

| Functie | Geeft |
|---|---|
| `monthGrid(db, year:today:)` | `MonthGrid`: `rows` (op `sortOrder`), `monthTotals` (12×) en `yearTotals` |
| `cellEntries(db, itemId:year:month:)` | `[EntryRow]` achter één cel |
| `diversEntries(db, year:month:positive:)` | `[EntryRow]` IN divers (`true`) of UIT divers (`false`) |
| `fixedItemsStatus(db, year:month:today:)` | `FixedItemsOverview`: per verwachte post `voldaan` / `open` / `teLaat`, aantallen en totalen |

- `GridRow`: `plan`, 12 `cells`, `yearTotal`, `planYearTotal` (plan × verwachte maanden), `kind`
  (`item`, `reserveTotal`, `reserveLine`). RES-regels hebben `isInformational == true`: tonen, niet optellen.
  Het plan van RESERVERINGEN is de som van de RES-regels.
- `GridCell`: `sum`, `entryCount`, `status`, `expected` (nil = niet verwacht), `difference`.
- `CellStatus`: `gelijk`, `afwijkend`, `nietVerwacht`, `open`, `teLaat`, `afgevinkt`. Een boeking in een maand waarin de post
  niet verwacht wordt, is `afwijkend`. Zonder boeking: toekomstige maand → `nietVerwacht`; voorbije maand →
  `teLaat`; lopende maand → `teLaat` als `expectedDay` voorbij is, anders `open`.
- `GridTotals`: `fixed` (zonder RES-regels), `inDivers`, `uitDivers`, `nettoDivers`, `result` (alles),
  `planExpected` en `ruimte` = `planExpected` + IN divers + UIT divers.
- Alleen boekingen op betaalrekeningen tellen mee.
- **Afvinken (`ItemCheck`):** `GridCell.isChecked` en `FixedItemStatus.isChecked`. Afgevinkt zónder boeking geeft
  `CellStatus.afgevinkt` en in `fixedItemsStatus` de stand `voldaan` (met `actual` € 0,00); het telt mee in
  `paidCount`, niet in open/te laat, niet in "nog verwacht deze maand" van `spendable` en niet als maand
  "onder plan" in `budgetVsActual`. Afgevinkt mét boeking houdt de gewone status (`gelijk`/`afwijkend`).

## Saldo en rekeningen

| Functie | Geeft |
|---|---|
| `balance(db, accountId:on:)` | saldo = beginsaldo + boekingen t/m die dag |
| `checkingBalance(db, on:)` | saldo van alle betaalrekeningen samen |
| `accountOverview(db, today:)` | `[AccountOverview]`: saldo, laatste afstemming met verschil, aantal `nieuw`, aantal nog na te kijken, laatste import |
| `balanceSeries(db, accountId:from:to:step:)` | `[BalancePoint]` per dag (`.daily`) of per maandeinde (`.monthEnd`) |
| `checkingBalanceSeries(db, from:to:step:)` | hetzelfde voor alle betaalrekeningen samen |

## Besteedbaar en jaaroverzicht

| Functie | Geeft |
|---|---|
| `spendable(db, year:today:)` | `Spendable`: `balance`, `antiRood`, `tijdelijkAntiRood`, `returningTags` / `returningTotal`, `spendable`, en de simulatie: `expectedItems`, `expectedTotal`, `pendingSettlement`, `spendableEndOfMonth` |
| `temporaryLoanOutstanding(db, on:)` | wat er op een dag nog uitstaat van tijdelijk van spaar geleend geld (boekingen met `temporaryLoan`) |
| `temporaryLoanEntries(db)` | de gemarkeerde boekingen, nieuwste eerst |
| `yearSummary(db, year:today:)` | `YearSummary`: op de rekening op 1-1, IN, UIT, op de rekening, buffers, besteedbaar, IN/UIT divers en gemiddelden per verstreken maand |
| `spendableSeries(db, year:today:)` | `[SpendablePoint]` per maandeinde t/m de peildag |

De peildag (`asOf`) is vandaag in het lopende jaar en 31-12 voor een voorbij jaar. De simulatie is alleen gevuld
als vandaag in het gevraagde jaar valt.

## Potten en verrekenen met spaar

| Functie | Geeft |
|---|---|
| `potOverview(db, accountId:today:)` | `PotOverview`: `accounts` (saldo, `potTotal`, `unallocated`, `pots`), `byKind`, `byOwner`, totalen |
| `potHistory(db, potId:)` | `[PotHistoryRow]`: boekingen oudste eerst met `runningBalance` |
| `unallocatedSavingsOverview(db, accountId:)` | `UnallocatedSavings`: boekingen zonder pot, met de paren die elkaar opheffen apart |
| `unallocatedSavingsEntries(db, accountId:)` | alleen `entries` van het overzicht hierboven (**gewijzigde betekenis**, zie onder) |
| `openReimbursements(db)` | `OpenReimbursements`: de open gemarkeerde boekingen, gesaldeerd (zie "Verrekenen met spaar") |
| `savingsTransfers(db)` | `[SavingsTransferDetail]`: overboekingen (nieuwste eerst) met richting, boekingen, `perPot` en potmutaties |

### Boekingen zonder pot en opgeheven paren

Boekingen op een spaarrekening zonder pot zijn "niet toegewezen". Twee zulke boekingen die elkaar wegstrepen
(iets voorgeschoten en teruggekregen) horen niet als "nog geen pot" gemeld te worden.

`unallocatedSavingsOverview(db, accountId:)` geeft `UnallocatedSavings`:

- `entries`: de boekingen zonder pot die niet zijn opgeheven, nieuwste eerst;
- `cancelledPairs: [CancelledPair]` (`first`, `second`, `amount`): paren van twee boekingen zonder pot op dezelfde
  spaarrekening met exact tegengestelde bedragen, hooguit `Insight.cancellationWindowDays` (45) dagen uit elkaar.
  Per bedrag wordt greedy gekoppeld aan de dichtstbijzijnde dag (bij gelijke afstand de oudste eerst); elke
  boeking zit in hoogstens één paar; nooit over rekeningen heen. `first` is de oudste van het paar;
- `remainingTotal`: de som van `entries`;
- `cancelledCount`: aantal opgeheven **boekingen** (2 × het aantal paren), dus het getal dat het scherm eerder als
  "boekingen zonder pot" meldde.

**Gewijzigde betekenis:** `unallocatedSavingsEntries` geeft voortaan alleen `entries` van dit overzicht terug, dus
zonder de opgeheven paren. De rekenregel van `SavingsAccountPots.unallocated` (saldo − potten) is niet veranderd:
opgeheven boekingen tellen daar gewoon mee en zijn samen € 0,00. Boekingen met een pot doen niet mee.

### Open verrekeningen in "nog te besteden"

`Spendable.pendingSettlement` is het netto bedrag van alle open verrekeningen met spaar: gemarkeerde boekingen op
betaalrekeningen die nog niet in een afgevinkte verrekening zitten (dezelfde berekening als `net` van
`openReimbursements`). Het teken is vanuit de betaalrekening gezien: positief = er komt nog geld van spaar naar
betaal, negatief = er moet nog geld van betaal naar spaar. Alleen in het lopende jaar (zoals `expectedItems`);
anders € 0,00.

`spendableEndOfMonth` = `spendable` + `expectedTotal` + `pendingSettlement`: het hoofdgetal gaat uit van een
situatie waarin alles verrekend is. `spendable` (besteedbaar nu) verandert niet.

### Verrekentags in besteedbaar (6g)

Per tag kan "telt mee in nog te besteden" aan staan (`Tag.countsInSpendable`, standaard uit). Voor elke tag met
`settles` én `countsInSpendable` en een positief openstaand bedrag (uit `settlementOverview`, dus inclusief een
nog open startbedrag) staat er een `ReturningTag` (`id`, `name`, `amount`) in `Spendable.returningTags`;
`returningTotal` is de som. Alleen in het lopende jaar, anders leeg.

`spendable` = `balance` − `antiRood` − `tijdelijkAntiRood` + `returningTotal`, en dus telt het ook mee in
`spendableEndOfMonth`, het jaaroverzicht van het lopende jaar en de telefoonpagina. `spendableSeries` (de trend)
rekent het niet mee: dat is de stand per maandeinde volgens de boekingen. Het Dashboard toont per tag een regel
"+ Komt nog terug: <tag>" boven "Besteedbaar nu", met één zin uitleg.

### Samengevatte melding bij onbevestigde verrekeningen

`AttentionItem.unconfirmedSettlements(count:total:oldestDay:)` vervangt de losse meldingen zodra er **meer dan
één** afgevinkte verrekening is die na 5 dagen nog niet aan beide kanten in een bankbestand is gezien: aantal,
samen (bedragen zonder teken) en de dag van de oudste. Tekst: "N verrekeningen (samen € …) zijn nog niet gezien
in een bankbestand, de oudste van <dag>." Bij precies één blijft `unconfirmedSettlement(amount:day:)`.
**Nieuwe `case`: schermen met een uitputtende `switch` op `AttentionItem` moeten hem afhandelen.**

### Verrekenen met spaar (twee richtingen)

`Entry.reimburse` op een betaalrekening geldt voor uitgaven ("uit deze pot") én voor bijschrijvingen ("doorstorten
naar deze pot"). Alles wordt gesaldeerd tot één overboeking; `SavingsTransfer.amount` is het netto bedrag met teken
(positief = van spaar naar betaal, negatief = van betaal naar spaar).

- `OpenReimbursements`: `entries`, `fromSavings` (som uitgaven, positief), `toSavings` (som bijschrijvingen,
  positief), `net` (`fromSavings` − `toSavings`), `transferAmount` (|`net`|), `direction`
  (`SavingsTransferDirection`: `.fromSavings`, `.toSavings`, `.none`), `perPot` en `withoutPotCount`.
- `ReimbursementPotTotal`: `amount` is wat de pot uit gaat (positief) of in komt (negatief), `balanceAfter` het
  potsaldo na het verrekenen (nil zonder pot en in de historie), `count`, en `total` (som van de boekingen met teken).
- `SavingsTransferDetail`: `amount` (netto, met teken), `transferAmount`, `direction`, `done`, `entries` (de
  verrekende boekingen op de betaalrekening), `entriesTotal` (hoort −`amount` te zijn), `perPot`, `potEntries` en
  `potMutationsBooked`.
- `PotSummary.pendingSettlement`: wat er volgens de open gemarkeerde boekingen nog uit de pot gaat (positief) of
  erin komt (negatief).
- `EntryRow.settlementDirection`: `.fromPot` (gemarkeerde uitgave), `.toPot` (gemarkeerde bijschrijving) of nil.
- `AttentionItem.openReimbursements(amount:count:direction:)`: `amount` is het netto bedrag zonder teken. Tekst:
  "€ 310,00 over te maken van spaar naar betaal (5 boekingen)." / "… van betaal naar spaar …" / bij netto nul
  "5 boekingen te verrekenen tussen potten."

**Gewijzigd voor de schermen** (was "vergoeden uit spaar", alleen uitgaven):

| Was | Is nu |
|---|---|
| `OpenReimbursements.transferAmount` = −`total`, altijd van spaar naar betaal | |`net`|; de richting staat in `direction` |
| `OpenReimbursements.total` altijd ≤ 0 | som van de boekingen met teken (= −`net`); kan positief zijn |
| `ReimbursementPotTotal.total` (negatief) | bestaat nog; gebruik `amount` (positief = de pot uit) |
| `SavingsTransferDetail.amount` altijd positief | netto met teken; gebruik `transferAmount` en `direction` voor weergave |
| `SavingsTransferDetail.entries` = alle gekoppelde boekingen | alleen die op de betaalrekening; potmutaties staan in `potEntries` |
| `AttentionItem.openReimbursements(amount:count:)` | heeft er `direction:` bij |
| alleen uitgaven | ook gemarkeerde bijschrijvingen; alleen boekingen op betaalrekeningen tellen |

### Boeken bij afvinken

Een verrekening wordt volledig geboekt zodra de gebruiker hem afvinkt (`markDone` in `HFBudget`): de potmutaties op
de spaarrekening en de tegenboeking op de betaalrekening. Bankregels worden er bij een latere import aan gehangen.

- `EntryRow.isSettlementBooking` (en `settlementTransferId`): de boeking is door een verrekening zelf gemaakt. Toon
  hem als "Verrekening". Op de betaalrekening is de tegenboeking in de begroting een **gewone diverse boeking**
  (de uitgave bij UIT divers, de terugstorting bij IN divers, zoals in de Excel); hij telt dus mee in het grid.
- `SavingsTransferDetail`: `isDone`, `bookings` (alle verrekeningsboekingen), `potEntries` (die op de spaarrekening),
  `potMutationsBooked`, `checkingBankConfirmed`, `savingsBankConfirmed` en `bankConfirmed` (beide kanten; bij netto
  nul altijd waar). `entries` bevat alleen de gemarkeerde boekingen, niet de verrekeningsboekingen.
- `PotSummary.pendingSettlement` telt alleen gemarkeerde boekingen die nog niet in een afgevinkte verrekening
  zitten: open, of in een verrekening die nog niet is afgevinkt.
- `AttentionItem.unconfirmedSettlement(amount:day:)`: een afgevinkte verrekening (netto niet nul) waar
  `Insight.settlementConfirmationDays` (5) dagen na het boeken nog niet aan beide kanten een bankregel hangt. Tekst: "Verrekening van € 105,00 op 05-03-2027 is nog niet gezien in een bankbestand."
  **Nieuwe `case`: schermen met een uitputtende `switch` op `AttentionItem` moeten hem afhandelen.**

**Hoe een verrekeningsboeking herkend wordt** (precies zoals `HFBudget` ze markeert, `SavingsTransferService.markDone`):

- de instelling `savingsTransfer.<id>.entries` bevat de id's van de boekingen die het afvinken heeft gemaakt: de
  potmutaties op de spaarrekening en de boeking op de betaalrekening. Alleen die lijst telt; de notitie
  "Verrekening #<id>" is voor de gebruiker en wordt niet gelezen;
- een kant (betaal of spaar) is door de bank bevestigd als een verrekeningsboeking op die rekeningsoort een
  `bankTransactionId` heeft (`attach` hangt de bankregel aan de boekingen van die kant);
- `SavingsTransferDetail.unconfirmedSince` is de oudste dag van een verrekeningsboeking zonder bankregel (een
  bankregel verschuift de boeking naar de bankdag). De melding komt als die dag + `Insight.settlementConfirmationDays`
  (5) op of voor vandaag ligt: dezelfde regel als `SavingsTransferService.unconfirmed`. Een afgevinkte verrekening
  zonder verrekeningsboekingen (oude gegevens) geeft dus geen melding.

Het oude formaat (notitie "Verrekening met spaar #<id>" en de sleutels `.potEntries`, `.checkingTransaction`,
`.savingsTransaction`) wordt niet meer gelezen. `Tests/IntegrationTests/SettlementMarkersTests.swift` gebruikt de
echte `HFBudget`-weg, zodat de twee niet meer uit elkaar kunnen lopen.

`PotSummary` heeft `balance`, `monthlyAmount`, `targetAmount`, `progress` (0…1, alleen weergave),
`remainingToTarget`, `depositsThisYear`, `withdrawalsThisYear`, `lastMovement`. Alleen boekingen op de
spaarrekening van de pot tellen in het potsaldo; een te vergoeden uitgave op de betaalrekening met een `potId` niet.

## Tags en rapporten

| Functie | Geeft |
|---|---|
| `tagYear(db, year:today:)` | `[TagYearRow]`: 12 maandtotalen, `yearToDate`, `averagePerMonth`, `previousYearToDate`, `previousYearTotal` (nil zonder gegevens van vorig jaar) |
| `tagEntries(db, tagId:year:month:)` | boekingen met een tag in een jaar of maand |
| `topTags(db, year:month:limit:)` | `[TagAmount]` grootste tags van een maand |
| `monthlyResults(db, year:)` | `[MonthResult]` (12×): IN, UIT, resultaat |
| `budgetVsActual(db, year:today:)` | `[BudgetVsActualRow]`: plan en werkelijk t/m nu, verschil, `monthsOver`, `monthsUnder` |
| `topDiversExpenses(db, year:month:limit:)` | grootste diverse uitgaven van een jaar of maand |
| `diversByTag(db, year:month:)` | `DiversBreakdown`: UIT divers per tag, "Zonder tag" als eigen groep (`tagId == nil`) |
| `yearOverYear(db)` | `[YearTotals]` voor alle jaren met boekingen |
| `tagUsage(db)` | `[tagId: TagUsage]`: aantal boekingen per tag, `onPayment` (betaalrekening), `onSavings` (spaarrekening, van vóór de regel "tags alleen op de betaalrekening") en `total`. Alleen tags met boekingen. |
| `tagFilterTarget(db, tagId:)` | `TagFilterTarget?` (`accountId`, `tagId`): waar Transacties heen gaat bij een klik op "n boekingen" in Instellingen › Tags. Altijd een betaalrekening: die met de meeste boekingen met de tag, anders de eerste niet-gearchiveerde op volgorde. nil zonder betaalrekening. |

## Transacties en nakijken

| Functie | Geeft |
|---|---|
| `searchEntries(db, filter:)` | `EntrySearchResult`: `rows` (één pagina), `totalCount` en `totalSum` (alle gevonden boekingen) |
| `reviewQueue(db, accountId:)` | `[ReviewItem]`: banktransacties met status `nieuw`, oudste eerst, met `bookedAmount` en `remaining` |
| `recentEntries(db, limit:)` | de laatste boekingen |
| `downloadAdvice(db, today:)` | `DownloadAdvice?`: welke bankbestanden je downloadt om bij te werken (nil zonder rekeningen) |

```swift
var filter = EntryFilter(accountId: accountId, year: 2027, month: 3, text: "tank", sort: .dayDescending, limit: 50)
filter.diversOnly = true
let page = try appDatabase.read { db in try Insight.searchEntries(db, filter: filter) }
```

`EntryFilter`: `accountId`, `year` (+ `month`), `from`/`to`, `text` (label, notitie, tegenpartij,
bankomschrijving), `budgetItemId`, `potId`, `tagId`, `diversOnly`, `unreviewedOnly`, `reimburseOnly`,
`unsettledOnly` (betaalrekening, tag met `settles`, nog geen `settlementId`),
`minAmount`/`maxAmount` (op het bedrag zonder teken), `sign`, `sort`, `limit`, `offset`.

`EntryRow` bevat de boeking plus `accountName`, `accountKind`, `itemLabel`, `potName`, `settlementId`, `tags` en `bank`
(`BankFields`, nil bij handinvoer); `isDivers` is true voor een boeking op een betaalrekening zonder vaste post.

### Downloadadvies (`downloadAdvice`)

Voor het blok onder de rekeningkaarten op het scherm Transacties (`Sources/HFInsight/DownloadAdvice.swift`).
`DownloadAdvice` heeft `accounts` (`[DownloadAccount]`: niet-gearchiveerde rekeningen in de volgorde van de app,
elk met `lastBankDay` = datum van de laatste banktransactie en `fromDay`), `from`, `through` (= `today`) en
`hasEarlierImport`.

- `fromDay` van een rekening is haar laatste banktransactiedatum, of zonder banktransacties de startdatum van het
  beginsaldo (`Account.openingDate`), nooit later dan vandaag.
- `from` is de vroegste `fromDay` over alle rekeningen. Die dag zit er bewust in als overlap: de import slaat
  regels over die er al zijn.
- De teksten voor het scherm komen ook hieruit: `instruction` ("Bijwerken: download bij de bank de CSV-export (zip,
  één bestand per rekening) van A en B, van … tot en met …"), `note` (waar de begindag vandaan komt en dat overlap
  geen kwaad kan) en `perAccount` (per rekening de laatste banktransactie, voor de uitleg bij het aanwijzen).

### Volgorde in pot-kiezers (`pickerOrder`)

`Insight.pickerOrder(_:)` (voor `[Pot]` en `[PotSummary]`, of generiek met `kind:` en `name:`;
`Sources/HFInsight/PickerOrder.swift`) zet potten in de volgorde van een keuzelijst: eerst reserveringspotten, dan
spaarpotten, binnen elke groep op alfabet (hoofdletter- en accentongevoelig, Nederlandse sortering, "Pot 2" vóór
"Pot 10"; gelijke namen houden hun oude volgorde). Alle pot-kiezers in de app gebruiken deze ene functie; "Nee",
"Geen pot" en dergelijke zet de kiezer zelf bovenaan. Het overzicht Potten (per persoon) gebruikt hem
niet. `Insight.compareNames(_:_:)` is de vergelijking die erachter zit. Tests in `PickerOrderTests`.

`Insight.itemPickerOrder(_:)` (voor `[BudgetItem]`, of generiek met `direction:` en `label:`) doet hetzelfde voor
vaste posten: eerst UIT, dan IN (RES als laatste), binnen elke groep op alfabet met `compareNames`. Alle
post-kiezers gebruiken hem (Nakijken "Waar hoort dit bij?", vaste storting "Hoort bij post", regeleditor, splitsen,
nieuwe boeking, transactiedetail, filter); "Divers (geen vaste post)" en "Geen" zet de kiezer zelf bovenaan. Het
maandgrid en het jaarplan houden hun eigen volgorde. Tests in `ItemPickerOrderTests`.

## Verrekenen per tag

Voor tags met `Tag.settles`. Openstaand = − som van de boekingen op betaalrekeningen met die tag en zonder
`settlementId`, plus het startbedrag (`Tag.startAmount`) zolang `Tag.startSettlementId` nil is (positief; een
retour met dezelfde tag telt eraf). Schrijven doet `HFBudget`.

| Functie | Geeft |
|---|---|
| `settlementOverview(db, today:)` | `[TagSettlementSummary]`: `outstanding` (met open startbedrag), `openStart`, `openCount` (boekingen, +1 voor een open startbedrag), `oldestOpenDay` (ook de dag van het startbedrag), `countsInSpendable`, `lastSettlementDay` / `lastSettlementAmount` (beginstanden tellen niet), `settledThisYear` |
| `openSettlementEntries(db, tagId:)` | `[EntryRow]` openstaand, oudste eerst (zonder startbedrag) |
| `settlementStart(db, tagId:)` | `SettlementStart?` (`amount`, `day`, `settlementId`, `isOpen`); nil zonder startbedrag |
| `settlementHistory(db, tagId:)` | `[SettlementDetail]` nieuwste eerst: `settlement`, `deposit` (`EntryRow?`), `entries`, `entriesTotal`, `startAmount` (het meegenomen startbedrag, anders € 0,00; `startAmount − entriesTotal = settlement.amount`) |

## Totalen per omschrijving

Diverse boekingen (betaalrekening, geen vaste post) met dezelfde omschrijving, bv. zakgeld. Hoofdletters en
extra spaties maken geen verschil; `label` is de meest gebruikte schrijfwijze.

| Functie | Geeft |
|---|---|
| `labelTotals(db, year:today:filter:)` | `[LabelTotal]`: `count`, `total`, 12 `months`, `activeMonths`, `averagePerActiveMonth`, `firstDay`, `lastDay`, `tags` (bij meer dan de helft); grootste absolute totaal eerst |
| `labelEntries(db, year:label:)` | `[EntryRow]` achter één omschrijving, oudste eerst (`year` nil = alle jaren) |
| `labelYears(db, label:)` | `[LabelYear]`: per jaar `count` en `total` |
| `normalizedLabel(_:)` | de groepeersleutel (`LabelTotal.id`) |

`LabelFilter(kind:minCount:text:)`: `kind` is `.expenses`, `.income` of `.both`; `minCount` standaard 2.
Voor een totaal in het transactiescherm: `searchEntries` met `text` geeft `totalCount` en `totalSum`.

```swift
let zakgeld = try appDatabase.read { db in
    try Insight.labelTotals(db, year: 2027, today: today, filter: LabelFilter(kind: .expenses, text: "zakgeld"))
}
```

### Aanvullen bij typen en bijna-dubbelen

| Functie | Geeft |
|---|---|
| `labelSuggestions(db, matching:accountKind:limit:today:)` | `[LabelSuggestion]`: begint-met vóór bevat, dan aantal keer gebruikt, dan laatst gebruikt; lege tekst = meest gebruikt in de laatste 12 maanden |
| `allLabels(db, accountKind:since:)` | alle omschrijvingen van boekingen plus `entryLabel` van regels, meest gebruikte eerst; te bewaren en te doorzoeken met `LabelMatcher` |
| `LabelMatcher.suggest(_:from:limit:)` | hetzelfde zoeken zonder database, op een bewaarde lijst |
| `LabelMatcher.similar(_:in:)` | de bestaande omschrijving die bijna gelijk is aan de getypte tekst, of nil ("Bedoel je ‘Zakgeld’?") |
| `LabelMatcher.isNearDuplicate(_:_:)` | de regel zelf |
| `similarLabelGroups(db, accountKind:)` | `[[LabelSuggestion]]`: groepen bijna-gelijke omschrijvingen, grootste eerst, voor "Omschrijvingen samenvoegen" |

`LabelSuggestion`: `id` (genormaliseerd), `label` (meest gebruikte schrijfwijze), `count`, `lastUsed`, `itemLabel`
(label van de vaste post bij meer dan de helft van de boekingen; posten bestaan per jaar) en `tags` (bij meer dan
de helft). Een omschrijving die alleen in een regel staat heeft `count == 0` en neemt post en tags van de regel over.

Bijna gelijk (maar niet gelijk na normalisatie) is: alleen een verschil in spaties, leestekens of accenten; of
evenveel woorden waarvan precies één verschilt als enkelvoud/meervoud (-s, -en) of als tikfout (bewerkingsafstand
1 bij woorden t/m 6 letters, 2 bij langere; twee verwisselde letters tellen als 1). Een verschil in een cijfer, in
een heel woord of in een woord korter dan 4 letters telt als anders: "Zakgeld Kind 1" en "Zakgeld Kind 2" zijn
geen bijna-dubbelen. `labelTotals` voegt bijna-gelijken niet samen.

```swift
let labels = try appDatabase.read { db in try Insight.allLabels(db, accountKind: .betaal) }   // bewaren
let suggestions = LabelMatcher.suggest(typed, from: labels)          // bij elke toetsaanslag
if let existing = LabelMatcher.similar(typed, in: labels) { /* "Bedoel je ‘\(existing.label)’?" */ }
```

## Vaste stortingen en beginstanden

| Functie | Geeft |
|---|---|
| `distributions(db, today:)` | `[DistributionSummary]`: naam, rekening, `lines` (pot-id, potnaam, bedrag), `total`, `item` (gekoppelde post van het jaar van `today`: label en plan) en `planMatchesTotal` (nil zonder post) |
| `distributionUsage(db, potId:)` | `[PotDistributionUsage]`: in welke stortingen de pot zit, met `amount` en `distributionTotal` |
| `openingOverview(db, accountId:)` | `OpeningOverview`: `accountOpeningBalance`, `pots` (beginboekingen per pot, notitie `Insight.openingNote` = "Beginsaldo"), `potTotal`, `unallocated`, `total` |

`PotSummary.distributionAmount` is de som van de regels van de pot in alle niet-gearchiveerde stortingen (naast
`monthlyAmount`). Voor de beginstand geldt `total == potTotal + unallocated`, waarbij `total` =
`Account.openingBalance` + alle boekingen met notitie "Beginsaldo".

### Opbouw van RESERVERINGEN (UX-stap B1)

| Functie | Geeft |
|---|---|
| `reserveBuildup(db, year:)` | `ReserveBuildup?` (nil zonder jaar of zonder post RESERVERINGEN): de gekoppelde storting (`distribution`), haar regels (`lines`, `distributionTotal`), de som en het aantal RES-regels (`reserveLineTotal`, `reserveLineCount`), `isOutOfStep`, de zinnen `sentence`, `warning` en `reserveLinesNote`, en `gridRows` (de regels als informatieve rijen voor het maandgrid, met negatieve id's) |

Alleen weergave. Het plan van RESERVERINGEN in het maandgrid, de rapporten, de maandbalans en "nog te besteden"
blijft de som van de RES-regels (`PlanSet`), ook als er een storting met een ander totaal aan gekoppeld is.
`warning` meldt dat verschil.

### De keten post ↔ vaste storting ↔ potje (UX-stap B2)

| Functie | Geeft |
|---|---|
| `chain(db, year:)` | `ChainOverview` van één begrotingsjaar: alle stortingen (`ChainDistribution`: naam, totaal, potnamen, gekoppelde posten van dat jaar), met `pot(_:)` → `PotChain`, `item(_:)` → `ItemChain` en `distribution(_:)` → `DistributionChain?` |

De zinnen staan in de typen zelf: `PotChain.sentence` ("Krijgt € 42,00 per maand via vaste storting X (post Y)."; bij
meer stortingen "… via 2 vaste stortingen:" met het lijstje in `lines[].line`), `ItemChain.sentence` ("Gaat via vaste
storting X naar 28 potjes."), `DistributionChain.sentence` ("Telt in je begroting als: post Y."). Gearchiveerde
stortingen tellen niet mee bij een potje.

## Vooruitblik per pot

Staat los van de werkelijkheid: raakt geen enkel ander cijfer. Schrijven (`ForecastItem`) doet `HFBudget`.

| Functie | Geeft |
|---|---|
| `potForecast(db, potId:today:until:)` | `PotForecast`: `startBalance`, `events`, `overdue`, `points`, `lowestPoint`, `endBalance`, `balance(on:)` |
| `forecastItems(db, potId:)` | `[ForecastItem]`: eerst de open (oudste dag eerst), dan de uitgekomen (nieuwste eerst) |

- `startBalance`: het echte potsaldo op `today`.
- `events: [ForecastEvent]` van morgen t/m `until`, oplopend op dag (op één dag eerst wat erbij komt), elk met
  `day`, `amount`, `label`, `kind` en `balanceAfter`. `kind` is `.oneOff(forecastItemId:)` of
  `.recurring(distributionId:)`.
  - **Los:** niet-uitgekomen `ForecastItem`s met een dag ná vandaag.
  - **Terugkerend:** per niet-gearchiveerde vaste storting met een regel voor de pot één bijschrijving per maand.
    De dag van de maand is die van de laatste echte bijschrijving van precies dat bedrag op de pot (bij voorkeur
    gesplitst uit een banktransactie met het totaal van de storting); anders de 25e
    (`Insight.defaultDistributionDay`). In kortere maanden de laatste dag. De lopende maand telt alleen mee als
    de storting nog niet binnen is; is de gewone dag al voorbij, dan staat hij op morgen.
- `overdue: [ForecastItem]`: niet-uitgekomen losse verwachtingen met een dag op of vóór vandaag; tellen niet mee.
- `points: [ForecastPoint]` (`day`, `balance`, `isForecast`): echt saldo per maandeinde van de afgelopen 12
  maanden (of vanaf de eerste boeking) t/m vandaag, daarna één punt per dag met een verwachte mutatie en een
  slotpunt op `until`.
- `balance(on:)`: het verwachte saldo aan het eind van een dag, nil buiten `today` … `until`.
- `lowestPoint`: dag en saldo van het laagste verwachte saldo vanaf vandaag (onder nul = tekort).
- `PotSummary.openForecastCount`: aantal losse verwachtingen dat nog niet is uitgekomen.

```swift
let forecast = try appDatabase.read { db in
    try Insight.potForecast(db, potId: potId, today: today, until: Day(year: 2027, month: 8, day: 31)!)
}
if forecast.lowestPoint.balance < .zero { /* de pot komt onder nul op forecast.lowestPoint.day */ }
```

## Spaardoel per pot

Een pot met `Pot.targetAmount` (en optioneel `Pot.targetDate`) heeft een spaardoel.

| Functie | Geeft |
|---|---|
| `potGoal(db, potId:today:)` | `PotGoal?` (nil zonder doelbedrag) |
| `PotSummary.goal`, `PotSummary.targetDate` | hetzelfde `PotGoal` per pot in `potOverview`, zonder extra aanroepen |
| `PotForecast.targetAmount`, `PotForecast.targetDate` | het doel, om als lijn in de grafiek te tekenen |

`PotGoal`:

- `targetAmount`, `targetDate`, `balance`, `remaining` (doel − saldo, minimaal € 0,00);
- `expectedOneOffs`: open losse verwachtingen van morgen t/m de doeldatum (uitgaven negatief);
- `monthsLeft`: stortmomenten van morgen t/m de doeldatum, met dezelfde stortdag als `potForecast` (het ritme van
  de eerste vaste storting van de pot; zonder vaste storting de 25e);
- `requiredPerMonth`: (`remaining` − `expectedOneOffs`) ÷ `monthsLeft`, naar boven afgerond op centen, minimaal
  € 0,00; nil zonder doeldatum of zonder stortmoment;
- `currentPerMonth`: de regels van de pot in niet-gearchiveerde vaste stortingen;
- `shortfallPerMonth`: `requiredPerMonth` − `currentPerMonth` (positief = te weinig, negatief = ruimte over);
- `projectedOnTargetDate`: het verwachte saldo op de doeldatum volgens de vooruitblik (nil zonder datum);
- `status` (`PotGoalStatus`): `bereikt` (saldo ≥ doel), `opKoers`, `tekort`, `verlopen` (datum voorbij en niet
  bereikt), `zonderDatum`;
- `projectedReachDate`: de eerste dag waarop de vooruitblik het doel haalt, tot 10 jaar vooruit; vandaag als het
  doel al bereikt is; nil als het zo niet gehaald wordt.

```swift
for pot in overview.accounts.flatMap(\.pots) {
    switch pot.goal?.status {
    case .tekort?: print("\(pot.name): \(pot.goal!.shortfallPerMonth!.formatted()) per maand te weinig")
    case .opKoers?: print("\(pot.name): op koers")
    default: break
    }
}
```

### Spaardoel uit onderdelen en projecten

- `PotGoal.parts: [GoalPartRow]` (`label`, `quantity`, `unitAmount`, `amount`) en `PotGoal.partsTotal`: de
  onderdelen (`GoalPart`) waaruit het doelbedrag is opgebouwd. Zonder onderdelen leeg en € 0,00. Het doel zelf
  blijft `Pot.targetAmount`; de onderdelen zijn de onderbouwing.
- `forecastProjects(db, potId:today:)` geeft `[ForecastProject]`: per niet-lege `ForecastItem.project` de regels
  (`items`, elk met `realizedAmount`), `planned` (alle regels), `realized` (afgevinkte regels: het bedrag van de
  gekoppelde echte boeking, anders het verwachte bedrag), `remaining` (open regels), `count`, `openCount`,
  `overdueCount`, `firstDay` en `lastDay`. Het project met de laatste dag het verst weg staat eerst.
- `ForecastEvent.project`: het project van een losse gebeurtenis in `PotForecast.events`, of nil.

## Potten die in de min staan

Een pot mag bewust negatief staan (iets vooruit betaald); het geld is dan geleend van de andere potten op dezelfde
spaarrekening.

- `PotSummary.recovery: PotRecovery?`: alleen bij een negatief saldo, anders nil.
  - `shortfall`: het bedrag onder nul (positief).
  - `perMonth`: wat er per maand bij komt via niet-gearchiveerde vaste stortingen.
  - `recoveryDate`: de eerste dag waarop de vooruitblik (vaste stortingen en open losse verwachtingen) op of boven
    nul komt, tot 10 jaar vooruit.
  - `status` (`PotRecoveryStatus`): `herstelt` (met datum), `wordtNietAangevuld` (geen vaste storting en geen
    verwachting die het oplost) of `duurtLangerDan10Jaar` (er komt wel geld bij, maar niet genoeg).
- `SavingsAccountPots.borrowedFromOtherPots` en `negativePotCount`, en dezelfde twee als totaal in `PotOverview`:
  de som van de negatieve potsaldi als positief bedrag, en het aantal van die potten.

Het herstel gebruikt dezelfde gedeelde gegevens als het spaardoel: geen extra queries per pot.

## Maandbalans met wat-als

`planBalance(db, year:)` geeft één `PlanBalance`: wat er per maand overblijft van de vaste posten, voor het plan en
voor de wat-als-variant (`BudgetItem.scenarioAmount`).

- `rows: [PlanBalanceRow]`: eerst de inkomsten, dan de uitgaven, elk op `sortOrder` (ook als `incomeRows` en
  `expenseRows`). RES-regels doen niet mee; RESERVERINGEN en posten bij een vaste storting wel.
  Per rij: `label`, `direction`, `frequency`, `timesPerYear`, `plan` (per keer), `planPerMonth`
  (plan × `timesPerYear` ÷ 12, afgerond op centen), `scenario` en `scenarioPerMonth` (nil als niet ingevuld) en
  `difference` (`scenarioPerMonth` − `planPerMonth`).
- `plan`, `scenario`, `difference`: `PlanBalanceTotals` per maand (`income`, `expenses`, `surplus`). In de variant
  tellen posten zonder wat-als-bedrag met hun plan.
- `planYear`, `scenarioYear`, `differenceYear`: dezelfde bedragen per jaar (plan × aantal keer, zonder de
  afronding per maand).
- `hasScenario`: er is bij minstens één post iets ingevuld.
- Wat-als voor RESERVERINGEN: het eigen `scenarioAmount`; is dat leeg maar hebben RES-regels er een, dan de som
  van de RES-regels (wat-als waar ingevuld, anders hun plan).

```swift
let balance = try appDatabase.read { db in try Insight.planBalance(db, year: 2027) }
print(balance.plan.surplus, balance.hasScenario ? balance.scenario.surplus : nil)
```

## Dashboard

`dashboard(db, today:recentLimit:tagLimit:)` geeft één `Dashboard`:

- `spendable` (nu en eind van de maand) en `fixedItems`: beide nil als het jaar van vandaag nog niet bestaat;
- `accounts` (niet-gearchiveerd) met saldo; `paidCount`, `openCount`, `lateCount`;
- `attention: [AttentionItem]`, elk met een Nederlandse `message`: `yearMissing`, `newBankTransactions`,
  `unreviewedEntries`, `openReimbursements`, `reconciliationDiffers`, `reconciliationOld` (ouder dan
  `Insight.reconciliationMaxAgeDays` = 35 dagen, of nooit afgestemd sinds de begindatum),
  `openSettlement(tagId:tagName:amount:count:)` per tag waarvoor nog iets terug te storten is;
- `recentEntries`, `monthIncome` / `monthExpenses` tegen `planIncome` / `planExpenses`, `topTags`.

## Kerncijfers (testronde)

`keyFigures(db, today:)` geeft `KeyFigures` (`day`, `values: [String: String]`, `json()`): een platte lijst om
twee versies van de app op dezelfde gegevens te vergelijken. Rekent niet zelf; bedragen komen uit
`accountOverview`, `balance`, `potOverview`, `spendable` en `openReimbursements`.

- Bedragen als `"-1234.56"`, aantallen als `"12"`; id's met vier cijfers (`rekening.0001.saldo`).
- Sleutels: `rekening.<id>.naam|soort|gearchiveerd|saldo|laatsteImport.dag|laatsteImport.eindsaldo|laatsteImport.saldoVolgensApp`,
  `pot.<id>.naam|rekening|gearchiveerd|saldo`, `besteedbaarNu`, `nogTeBestedenDezeMaand` ("geen begrotingsjaar"
  als het jaar ontbreekt), `besteedbaarNu.terugTeKrijgen` (`Spendable.returningTotal`),
  `tag.<id>.openstaand|startbedrag|teltMee` voor elke tag met verrekenen (vanaf versie 2), `boekingen.aantal`, `banktransacties.<status>`, `verrekeningen.openNetto|openAantal`,
  `afgevinkt.<jjjj-mm>`, `peildag`, `kerncijfers.versie` (`Insight.keyFiguresVersion`).
- `json()` is stabiel: sleutels op alfabet, één per regel.

## Gekozen uitleg

- Boekingen met een datum ná de peildag tellen niet mee in saldo, besteedbaar en potsaldi; het
  maandgrid toont wel alle boekingen van het jaar.
- "Op de rekening op 1-1" = op de rekening − IN − UIT. Het beginsaldo van een betaalrekening die in de loop van
  het jaar start, zit daar dus in.
- Een verwachte post met plan € 0,00 en zonder boeking is `nietVerwacht` en staat niet in `fixedItemsStatus`.
- Een boeking met twee tags telt bij beide tags mee (`tagYear`, `diversByTag`).
- Zoeken op tekst is hoofdletterongevoelig voor ASCII (SQLite `LIKE`), niet voor letters met accenten.
