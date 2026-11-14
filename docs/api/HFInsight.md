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
`unsettledOnly` (betaalrekening, tag met `settles`, nog geen `settlementId`),
`minAmount`/`maxAmount` (op het bedrag zonder teken), `sign`, `sort`, `limit`, `offset`.

`EntryRow` bevat de boeking plus `accountName`, `accountKind`, `itemLabel`, `potName`, `settlementId`, `tags` en `bank`
(`BankFields`, nil bij handinvoer); `isDivers` is true voor een boeking op een betaalrekening zonder vaste post.

## Verrekenen per tag

Voor tags met `Tag.settles`. Openstaand = − som van de boekingen op betaalrekeningen met die tag en zonder
`settlementId` (positief; een retour met dezelfde tag telt eraf). Schrijven doet `HFBudget`.

| Functie | Geeft |
|---|---|
| `settlementOverview(db, today:)` | `[TagSettlementSummary]`: `outstanding`, `openCount`, `oldestOpenDay`, `lastSettlementDay` / `lastSettlementAmount` (beginstanden tellen niet), `settledThisYear` |
| `openSettlementEntries(db, tagId:)` | `[EntryRow]` openstaand, oudste eerst |
| `settlementHistory(db, tagId:)` | `[SettlementDetail]` nieuwste eerst: `settlement`, `deposit` (`EntryRow?`), `entries`, `entriesTotal` |

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

## Gekozen uitleg

- Boekingen met een datum ná de peildag tellen niet mee in saldo, besteedbaar en potsaldi; het
  maandgrid toont wel alle boekingen van het jaar.
- "Op de rekening op 1-1" = op de rekening − IN − UIT. Het beginsaldo van een betaalrekening die in de loop van
  het jaar start, zit daar dus in.
- Een verwachte post met plan € 0,00 en zonder boeking is `nietVerwacht` en staat niet in `fixedItemsStatus`.
- Een boeking met twee tags telt bij beide tags mee (`tagYear`, `diversByTag`).
- Zoeken op tekst is hoofdletterongevoelig voor ASCII (SQLite `LIKE`), niet voor letters met accenten.
