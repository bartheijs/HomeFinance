# HFBudget — schrijven

Alle schrijfacties van HomeFinance: boeken, splitsen, potten, overboekingen, afstemming, jaar en posten,
rekeningen, tags en verrekenen per tag. Lezen en rapporteren (grid, besteedbaar, grafieken) zit in `HFInsight`.

## Zo werkt het

- Elke service is een `enum` met statische functies. De eerste parameter is altijd een GRDB-`Database`.
- Elke functie draait in een eigen savepoint: hij slaagt helemaal of verandert niets. Meerdere aanroepen
  binnen één `AppDatabase.write { db in … }` vormen samen één transactie.
- Fouten zijn `BudgetError` (`LocalizedError`, `Equatable`). `error.localizedDescription` is een Nederlandse
  melding die je direct aan de gebruiker kunt tonen.
- Een **afgesloten jaar** weigert elke wijziging van zijn boekingen en posten met `BudgetError.yearClosed(jaar)`.

```swift
import HFBudget
import HFCore

// Een banktransactie van -80,00 splitsen over een vaste post en "divers".
do {
    try appDatabase.write { db in
        try BookingService.book(db, bankTransactionId: id, allocations: [
            Allocation(amount: Money(cents: -5_000), label: "Boodschappen", budgetItemId: boodschappenId),
            Allocation(amount: Money(cents: -3_000), label: "Cadeau", tagIds: [cadeauTagId]),
        ])
    }
} catch {
    melding = error.localizedDescription   // bv. "De regels tellen op tot …"
}

// Een storting op de spaarrekening verdelen over de reserveringspotten.
try appDatabase.write { db in
    if let split = try PotService.distribution(db, for: transactie.amount, accountId: transactie.accountId) {
        try BookingService.book(db, bankTransactionId: transactie.id!, allocations: split)
    }
}
```

## BookingService — banktransacties boeken

| Functie | Doet |
|---|---|
| `book(db, bankTransactionId:, allocations:) -> [Entry]` | Boekt als één of meer regels; vervangt bestaande boekingen; status `verwerkt`. |
| `bookAll(db, [BookingRequest]) -> [Entry]` | Veel transacties in één keer, alles of niets. |
| `unbook(db, bankTransactionId:)` | Verwijdert de boekingen; status `nieuw`. |
| `skip(db, bankTransactionId:)` | Status `overgeslagen`. Geweigerd als de transactie al geboekt is. |
| `unskip(db, bankTransactionId:)` | Terug naar `nieuw`. |

`Allocation`: `amount`, `label`, `budgetItemId?`, `potId?`, `reimburse`, `tagIds`, `note`, `ruleId?`,
`confidence?`, `reviewed` (standaard `false` = nog nakijken), `temporaryLoan` (tijdelijk geleend van spaar;
alleen op een betaalrekening).

Regels bij boeken (ook voor handmatige boekingen):

- De regels tellen exact op tot het bankbedrag.
- De dag ligt niet vóór de begindatum van de rekening, en het jaar is niet afgesloten.
- **Betaalrekening:** `budgetItemId` mag (post van het jaar van de transactie; geen RES-regel, wel de regel
  RESERVERINGEN); `potId` alleen samen met `reimburse`; `reimburse` alleen bij een negatief bedrag.
- **Spaarrekening:** geen `budgetItemId`, geen `reimburse`; de pot hoort bij die rekening.
- Opnieuw boeken of ongedaan maken wordt geweigerd zolang een boeking in een spaaroverboeking zit.
  Een koppeling als overboeking vervalt bij opnieuw boeken.
- Hetzelfde geldt zolang een boeking verrekend is (`BudgetError.inSettlement`) of als terugstorting aan een
  verrekening gekoppeld is (`BudgetError.depositLinked`); zie SettlementService.

## EntryService — losse boekingen

| Functie | Doet |
|---|---|
| `create(db, EntryDraft) -> Entry` | Handmatige boeking (zonder banktransactie), standaard nagekeken. |
| `draft(db, entryId:) -> EntryDraft` | Huidige waarden, om te bewerken. |
| `update(db, entryId:, EntryDraft) -> Entry` | Alles wijzigen; bij een boeking uit de bank liggen bedrag, dag en rekening vast. |
| `setReimburse(db, entryId:, Bool, potId:)` | Vergoeden aan/uit. Uitzetten wordt geweigerd als de boeking in een spaaroverboeking zit. |
| `setTemporaryLoan(db, entryId:, Bool)` | Markeert een boeking op een betaalrekening als tijdelijk geleend van spaar (bij het lenen én bij het terugboeken). `Allocation` en `EntryDraft` hebben hetzelfde veld `temporaryLoan`. |
| `delete(db, entryId:)` | Alleen handmatige boekingen. |
| `setReviewed(db, entryIds:, Bool)` | Nagekeken aan/uit. |
| `markAllReviewed(db, accountId:) -> Int` | Alles van een rekening nagekeken (afgesloten jaren overgeslagen); geeft het aantal. |
| `setTags(db, entryId:, tagIds:)` / `tagIds(db, entryId:)` | Tags van een boeking. |

Een verrekende boeking (met `settlementId`) houdt zijn bedrag, zijn rekening en de tag van de verrekening:
`update`, `setTags` en `delete` weigeren dat met `BudgetError.inSettlement`. Label, notitie, post en extra
tags wijzigen mag wel. Een gekoppelde terugstorting verwijderen wordt geweigerd met `depositLinked`.

## TransferService — overboekingen tussen eigen rekeningen

| Functie | Doet |
|---|---|
| `findTransferPairs(db) -> [TransferPair]` | Nog niet gekoppelde paren: tegengesteld bedrag, tegenrekening = andere eigen rekening, ≤ 3 dagen. Elke transactie in hoogstens één paar. |
| `linkTransfer(db, fromBankTransactionId:, toBankTransactionId:)` | Boekt een nog niet geboekte kant als "Overboeking naar/van …" en koppelt de boekingen over en weer (`counterEntryId`). |
| `unlinkTransfer(db, bankTransactionId:)` | Verbreekt de koppeling aan beide kanten; de boekingen blijven. |

Is een kant gesplitst (bv. de storting verdeeld over potten), dan verwijst elke regel naar de eerste regel van
de andere kant. `linkTransfer` eist alleen verschillende rekeningen en tegengestelde bedragen, zodat de
gebruiker ook met de hand kan koppelen.

## PotService — potten

| Functie | Doet |
|---|---|
| `create(db, Pot)` / `update(db, Pot)` / `delete(db, potId:)` | Beheer. Alleen op een spaarrekening; verwijderen alleen zonder boekingen. |
| `reorder(db, accountId:, orderedIds:)` | Volgorde (alle pot-id's van de rekening). |
| `archive(db, potId:)` / `unarchive(db, potId:)` | Archiveren kan alleen bij saldo € 0,00. |
| `balance(db, potId:) -> Money` | Som van de boekingen op de spaarrekening met deze pot. |
| `distribution(db, for:, accountId:) -> [Allocation]?` | Eén regel per reserveringspot als het bedrag gelijk is aan de som van hun maandbedragen; anders `nil`. |
| `moveBetweenPots(db, from:, to:, amount:, day:, label:) -> (from: Entry, to: Entry)` | Twee handmatige boekingen op dezelfde rekening die samen nul zijn. |

## SavingsTransferService — vergoeden uit spaar

| Functie | Doet |
|---|---|
| `openReimbursements(db) -> OpenReimbursements` | Openstaande `reimburse`-boekingen en het (positieve) totaal. |
| `createSavingsTransfer(db, entryIds:, day:, note:) -> SavingsTransfer` | Legt de overboeking vast met het positieve totaal en koppelt de boekingen. |
| `markDone(db, savingsTransferId:)` / `reopen(db, savingsTransferId:)` | Gedaan aan/uit. |
| `delete(db, savingsTransferId:)` | Verwijdert; de boekingen staan weer open. |
| `entries(db, savingsTransferId:) -> [Entry]` | De boekingen in de overboeking. |

## SettlementService — verrekenen per tag

Voor uitgaven met een tag (bv. Tanken) die de gebruiker periodiek terugstort op de betaalrekening.
**Openstaand** = − de som van de boekingen op betaalrekeningen met die tag en zonder `settlementId`; een retour
met dezelfde tag telt eraf, boekingen op een spaarrekening tellen niet mee. De terugstorting is een gewone
bijschrijving zonder de tag en wordt gekoppeld via `Settlement.depositEntryId`.

| Functie | Doet |
|---|---|
| `enable(db, tagId:, from:) -> Settlement` | Zet `Tag.settles` aan en maakt één beginstand (`isOpening`) met alle open boekingen van vóór `from` (bedrag mag 0 zijn). Opnieuw aanroepen vervangt de beginstand; echte verrekeningen blijven. |
| `disable(db, tagId:)` | Zet `settles` uit; verrekeningen blijven staan. |
| `open(db, tagId:) -> (entries: [Entry], amount: Money)` | Openstaande boekingen (oudste eerst) en het openstaande bedrag. |
| `settle(db, tagId:, entryIds:, day:, depositEntryId:, note:) -> SettlementResult` | Legt een verrekening vast voor de gekozen open boekingen; bedrag = − hun som. Koppelt optioneel meteen de storting. |
| `suggestDeposit(db, tagId:, asOf:) -> [Entry]` | Mogelijke terugstortingen: bijschrijvingen op betaalrekeningen van de laatste 45 dagen, zonder vaste post, niet gekoppeld, bedrag gelijk aan het openstaande bedrag (exact eerst, daarna binnen € 1,00), nieuwste eerst. |
| `linkDeposit(db, settlementId:, depositEntryId:) -> SettlementResult` | Koppelt (of vervangt) de storting; `nil` ontkoppelt. |
| `delete(db, settlementId:)` | Verwijdert de verrekening; de boekingen staan weer open. Een beginstand kan zo niet weg. |
| `history(db, tagId:) -> [Settlement]` | Verrekeningen, nieuwste eerst (inclusief de beginstand). |
| `entries(db, settlementId:) -> [Entry]` | De boekingen in een verrekening. |
| `result(db, settlementId:) -> SettlementResult` | Bestaande verrekening met storting en verschil, bv. voor de historie. |

`SettlementResult`: `settlement`, `deposit: Entry?` en `difference: Money?` = storting − verrekend bedrag
(positief = te veel gestort, negatief = te weinig, `nil` zonder storting).

```swift
try appDatabase.write { db in
    let open = try SettlementService.open(db, tagId: tankenId)             // wat staat er nog open?
    let voorstel = try SettlementService.suggestDeposit(db, tagId: tankenId).first
    let result = try SettlementService.settle(db, tagId: tankenId, entryIds: open.entries.map { $0.id! },
                                              day: .today(), depositEntryId: voorstel?.id)
    verschil = result.difference                                           // nil, € 0,00 of een afwijking
}
```

Validatie (`BudgetError`, Nederlandse melding):

- `tagNotSettling`: verrekenen staat niet aan voor de tag.
- `notSettleable`: de boeking heeft de tag niet, staat niet op een betaalrekening of is al verrekend.
- `depositInvalid`: de storting is geen bijschrijving op een betaalrekening, heeft zelf de tag, hoort al bij
  een andere verrekening, of de verrekening is een beginstand.
- Minstens één boeking; een selectie die samen een negatief bedrag oplevert wordt geweigerd (nul mag).

Een afgesloten jaar blokkeert het verrekenen niet: het is een koppeling, geen wijziging van de boeking.
Een boeking heeft één `settlementId`; heeft hij twee tags die verrekend worden, dan is hij na verrekening voor
de ene tag ook voor de andere niet meer open.

## BalanceService — saldo en afstemming

| Functie | Doet |
|---|---|
| `balance(db, accountId:, on:) -> Money` | Beginsaldo + boekingen t/m de dag. |
| `reconcile(db, accountId:, day:, actualBalance:) -> Reconciliation` | Legt de controle vast; `.difference` = berekend − werkelijk. |
| `history(db, accountId:) -> [Reconciliation]` | Eerdere controles, nieuwste eerst. |
| `importCheck(db, batchId:) -> ImportCheck` | Controle na import (spec Import stap 7). |

`ImportCheck`: `newCount`, `processedCount`, `skippedCount`, `allHandled`, `closingBalance`,
`calculatedBalance`, `difference`, `openUpToLastDay`, `skippedUpToLastDay`, `balanceIsMeaningful`,
`balanceMatches` (`nil` = nog niet te zeggen) en `summary` (Nederlandse tekst). De saldovergelijking heeft
alleen betekenis als het bestand een eindsaldo heeft en alle transacties van de rekening t/m de laatste dag
geboekt zijn. Overgeslagen transacties tellen niet mee in het saldo en geven dus een verschil, tenzij er een
handmatige boeking tegenover staat.

## YearService — jaar en vaste posten

| Functie | Doet |
|---|---|
| `createYear(db, year:, antiRood:, tijdelijkAntiRood:)` | Leeg jaar. |
| `createYear(db, year:, copyingFrom:)` | Kopieert buffers en alle posten (zonder boekingen). |
| `updateBuffers(db, year:, antiRood:, tijdelijkAntiRood:)` | Buffers wijzigen. |
| `closeYear(db, year:)` / `reopenYear(db, year:)` | Afsluiten en heropenen. |
| `createItem(db, BudgetItem)` / `updateItem(db, BudgetItem)` | Post maken of wijzigen; geeft de opgeslagen post terug. |
| `deleteItem(db, itemId:, convertEntriesToDivers:)` | Met boekingen alleen als ze "divers" mogen worden. |
| `reorderItems(db, yearId:, orderedIds:)` | Volgorde (alle post-id's van het jaar). |

- Teken: IN ≥ 0, UIT en RES ≤ 0.
- Hoogstens één post per jaar met `isReserveTotal` (moet UIT zijn). Zijn plan is altijd de som van het plan
  van de RES-regels van dat jaar; een zelf ingevuld plan wordt overschreven.
- Kwartaal- en jaarposten hebben `expectedMonths` nodig ("1,4,7,10"); bij maandposten wordt het geleegd.
- Nieuwe posten, potten, rekeningen en tags komen achteraan; de volgorde wijzig je met `reorder…`.

## AccountService en TagService

| Functie | Doet |
|---|---|
| `AccountService.create / update / delete` | IBAN wordt genormaliseerd (hoofdletters, geen spaties) en is uniek. Verwijderen alleen als de rekening nergens gebruikt wordt. |
| `AccountService.setArchived(db, accountId:, Bool)` / `reorder(db, orderedIds:)` | Archiveren en volgorde. |
| `AccountService.normalizeIBAN(String)` | De normalisatie zelf. |
| `TagService.create(db, name:, color:)` / `update` / `delete` / `reorder` | Naam uniek (hoofdletterongevoelig), kleur `#RRGGBB`. `update` laat `settles` ongemoeid (dat loopt via `SettlementService`). `delete` verwijdert ook de verrekeningen van de tag. |

## Aannames

- `reimburse` kan alleen op een uitgave (negatief bedrag) op een betaalrekening.
- Het afgesloten jaar wordt bepaald door het kalenderjaar van de dag van de boeking, voor alle rekeningen.
  Een boeking in een spaaroverboeking opnemen of eruit halen valt daar niet onder.
- Verplaatsen tussen potten koppelt de twee boekingen niet via `counterEntryId`; dat veld is voor
  overboekingen tussen twee eigen rekeningen.
- Een developer reviewt deze module vóór gebruik met echte gegevens.
