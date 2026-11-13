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
- `CellStatus`: `gelijk`, `afwijkend`, `nietVerwacht`, `open`, `teLaat`. Een boeking in een maand waarin de post
  niet verwacht wordt, is `afwijkend`. Zonder boeking: toekomstige maand → `nietVerwacht`; voorbije maand →
  `teLaat`; lopende maand → `teLaat` als `expectedDay` voorbij is, anders `open`.
- `GridTotals`: `fixed` (zonder RES-regels), `inDivers`, `uitDivers`, `nettoDivers`, `result` (alles),
  `planExpected` en `ruimte` = `planExpected` + IN divers + UIT divers.
- Alleen boekingen op betaalrekeningen tellen mee.

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
| `spendable(db, year:today:)` | `Spendable`: `balance`, `antiRood`, `tijdelijkAntiRood`, `spendable`, en de simulatie: `expectedItems`, `expectedTotal`, `spendableEndOfMonth` |
| `temporaryLoanOutstanding(db, on:)` | wat er op een dag nog uitstaat van tijdelijk van spaar geleend geld (boekingen met `temporaryLoan`) |
| `temporaryLoanEntries(db)` | de gemarkeerde boekingen, nieuwste eerst |
| `yearSummary(db, year:today:)` | `YearSummary`: op de rekening op 1-1, IN, UIT, op de rekening, buffers, besteedbaar, IN/UIT divers en gemiddelden per verstreken maand |
| `spendableSeries(db, year:today:)` | `[SpendablePoint]` per maandeinde t/m de peildag |

De peildag (`asOf`) is vandaag in het lopende jaar en 31-12 voor een voorbij jaar. De simulatie is alleen gevuld
als vandaag in het gevraagde jaar valt.

## Potten en spaaroverboekingen

| Functie | Geeft |
|---|---|
| `potOverview(db, accountId:today:)` | `PotOverview`: `accounts` (saldo, `potTotal`, `unallocated`, `pots`), `byKind`, `byOwner`, totalen |
| `potHistory(db, potId:)` | `[PotHistoryRow]`: boekingen oudste eerst met `runningBalance` |
| `unallocatedSavingsEntries(db, accountId:)` | boekingen op spaarrekeningen zonder pot |
| `openReimbursements(db)` | `OpenReimbursements`: `entries`, `total` (negatief), `transferAmount` (positief), `perPot` |
| `savingsTransfers(db)` | `[SavingsTransferDetail]`: overboekingen (nieuwste eerst) met hun boekingen |

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

## Transacties en nakijken

| Functie | Geeft |
|---|---|
| `searchEntries(db, filter:)` | `EntrySearchResult`: `rows` (één pagina), `totalCount` en `totalSum` (alle gevonden boekingen) |
| `reviewQueue(db, accountId:)` | `[ReviewItem]`: banktransacties met status `nieuw`, oudste eerst, met `bookedAmount` en `remaining` |
| `recentEntries(db, limit:)` | de laatste boekingen |

```swift
var filter = EntryFilter(accountId: accountId, year: 2027, month: 3, text: "tank", sort: .dayDescending, limit: 50)
filter.diversOnly = true
let page = try appDatabase.read { db in try Insight.searchEntries(db, filter: filter) }
```

`EntryFilter`: `accountId`, `year` (+ `month`), `from`/`to`, `text` (label, notitie, tegenpartij,
bankomschrijving), `budgetItemId`, `potId`, `tagId`, `diversOnly`, `unreviewedOnly`, `reimburseOnly`,
`minAmount`/`maxAmount` (op het bedrag zonder teken), `sign`, `sort`, `limit`, `offset`.

`EntryRow` bevat de boeking plus `accountName`, `accountKind`, `itemLabel`, `potName`, `tags` en `bank`
(`BankFields`, nil bij handinvoer); `isDivers` is true voor een boeking op een betaalrekening zonder vaste post.

## Dashboard

`dashboard(db, today:recentLimit:tagLimit:)` geeft één `Dashboard`:

- `spendable` (nu en eind van de maand) en `fixedItems`: beide nil als het jaar van vandaag nog niet bestaat;
- `accounts` (niet-gearchiveerd) met saldo; `paidCount`, `openCount`, `lateCount`;
- `attention: [AttentionItem]`, elk met een Nederlandse `message`: `yearMissing`, `newBankTransactions`,
  `unreviewedEntries`, `openReimbursements`, `reconciliationDiffers`, `reconciliationOld` (ouder dan
  `Insight.reconciliationMaxAgeDays` = 35 dagen, of nooit afgestemd sinds de begindatum);
- `recentEntries`, `monthIncome` / `monthExpenses` tegen `planIncome` / `planExpenses`, `topTags`.

## Gekozen uitleg

- Boekingen met een datum ná de peildag tellen niet mee in saldo, besteedbaar en potsaldi; het
  maandgrid toont wel alle boekingen van het jaar.
- "Op de rekening op 1-1" = op de rekening − IN − UIT. Het beginsaldo van een betaalrekening die in de loop van
  het jaar start, zit daar dus in.
- Een verwachte post met plan € 0,00 en zonder boeking is `nietVerwacht` en staat niet in `fixedItemsStatus`.
- Een boeking met twee tags telt bij beide tags mee (`tagYear`, `diversByTag`).
- Zoeken op tekst is hoofdletterongevoelig voor ASCII (SQLite `LIKE`), niet voor letters met accenten.
