# HFBudget — schrijven

Alle schrijfacties van HomeFinance: boeken, splitsen, potten, overboekingen, afstemming, jaar en posten,
rekeningen, tags, verrekenen per tag, vaste stortingen, afvinken, omschrijvingen en verwachte bedragen per pot. Lezen en rapporteren (grid, besteedbaar, grafieken) zit in `HFInsight`.

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

// Een storting op de spaarrekening verdelen volgens een vaste storting.
try appDatabase.write { db in
    if let storting = try DistributionService.match(db, accountId: transactie.accountId, amount: transactie.amount).first {
        let voorstel = try DistributionService.allocations(db, distributionId: storting.id!, for: transactie.amount)
        try BookingService.book(db, bankTransactionId: transactie.id!, allocations: voorstel.allocations)
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
alleen op een betaalrekening), `period?` ("yyyy-MM": de maand waarin de boeking meetelt, zie EntryService).

Regels bij boeken (ook voor handmatige boekingen):

- De regels tellen exact op tot het bankbedrag.
- De dag ligt niet vóór de begindatum van de rekening, en het jaar is niet afgesloten.
- **Betaalrekening:** `budgetItemId` mag (post van het jaar van de transactie; geen RES-regel, wel de regel
  RESERVERINGEN); `potId` alleen samen met `reimburse`; `reimburse` ("verrekenen met spaar") kan bij een
  uitgave (uit de pot) én bij een bijschrijving (doorstorten naar de pot), niet bij een bedrag van nul.
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
| `setReimburse(db, entryId:, Bool, potId:)` | Verrekenen met spaar aan/uit, met optioneel de pot. Uitzetten wordt geweigerd als de boeking in een spaaroverboeking zit. |
| `setTemporaryLoan(db, entryId:, Bool)` | Markeert een boeking op een betaalrekening als tijdelijk geleend van spaar (bij het lenen én bij het terugboeken). `Allocation` en `EntryDraft` hebben hetzelfde veld `temporaryLoan`. |
| `setPeriod(db, entryId:, year:, month:)` | Laat de boeking in een andere maand meetellen; `nil`/`nil` = terug naar de maand van de datum. `Allocation` en `EntryDraft` hebben hetzelfde veld `period` ("yyyy-MM"). |
| `delete(db, entryId:)` | Alleen handmatige boekingen. |
| `setReviewed(db, entryIds:, Bool)` | Nagekeken aan/uit. |
| `markAllReviewed(db, accountId:) -> Int` | Alles van een rekening nagekeken (afgesloten jaren overgeslagen); geeft het aantal. |
| `setTags(db, entryId:, tagIds:)` / `tagIds(db, entryId:)` | Tags van een boeking. |

Een verrekende boeking (met `settlementId`) houdt zijn bedrag, zijn rekening en de tag van de verrekening:
`update`, `setTags` en `delete` weigeren dat met `BudgetError.inSettlement`. Label, notitie, post en extra
tags wijzigen mag wel. Een gekoppelde terugstorting verwijderen wordt geweigerd met `depositLinked`.

**Periode (`Entry.period`).** Het rekeningsaldo volgt altijd de datum; de periode bepaalt alleen in welke
maand de boeking meetelt voor de begroting.

- Vorm "yyyy-MM", hoogstens 2 maanden vóór of na de maand van de datum; anders `periodInvalid` of
  `periodTooFar`. De maand van de datum zelf wordt als `nil` bewaard.
- Valt de periode in een ander jaar dan de datum (december ↔ januari), dan hoort de boeking bij de post met
  hetzelfde label in het jaar van de periode. Geef je de post van het andere jaar mee, dan wordt die vervangen;
  bestaat de post daar niet, dan `itemMissingInYear`. Terugzetten naar `nil` verhuist de boeking terug.
  Het teruggegeven `Entry.budgetItemId` kan dus een andere zijn dan je meegaf.
- Zowel het jaar van de datum als dat van de periode moeten open zijn.

## LabelService — omschrijvingen gelijktrekken

| Functie | Doet |
|---|---|
| `renameLabel(db, from:, to:) -> LabelRenameResult` | Geeft alle boekingen met omschrijving `from` de omschrijving `to`, en ook `Rule.entryLabel`. Bestaat `to` al, dan is dit samenvoegen. |
| `mergeLabels(db, [String], into:) -> LabelRenameResult` | Hetzelfde voor meer schrijfwijzen in één transactie. |
| `spellingVariants(db) -> [[String]]` | Groepen omschrijvingen die alleen in hoofdletters of spaties verschillen. |
| `normalize(String) -> String` | De vergelijkingsvorm. |

Vergelijken gaat genormaliseerd: spaties vooraan en achteraan weg, meervoudige spaties samengevoegd,
hoofdletterongevoelig. `LabelRenameResult` heeft `entryCount` en `ruleCount`: het aantal werkelijk gewijzigde
boekingen en regels (wat al precies `to` heette telt niet mee; niets te doen geeft 0). Een lege `to` wordt
geweigerd. **Boekingen in een afgesloten jaar gaan mee**: een omschrijving is een schrijfwijze, geen bedrag of
toewijzing, en anders blijft de dubbele schrijfwijze in de historie staan.

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
| `create(db, Pot, openingBalance:, on:)` | Maakt de pot; met een beginbedrag (niet nul) komt er een handmatige boeking "Beginsaldo <potnaam>" op de spaarrekening. `on` standaard de begindatum van de rekening. |
| `setOpeningBalance(db, potId:, amount:, on:) -> Entry?` | Past de beginboeking aan of maakt hem; nul verwijdert hem. Herkend aan `note == PotService.openingNote` ("Beginsaldo"). |
| `openingSummary(db, accountId:) -> PotOpeningSummary` | `accountOpening` (niet toegewezen), `potOpenings` (per pot), `potTotal` en `total`. |
| `goalParts(db, potId:) -> [GoalPart]` / `setGoalParts(db, potId:, [GoalPart])` | Spaardoel uit onderdelen (aantal × bedrag per stuk); `setGoalParts` vervangt ze in één keer en zet `Pot.targetAmount` op de som. |
| `update(db, Pot)` / `delete(db, potId:)` | Beheer. Alleen op een spaarrekening; verwijderen alleen zonder boekingen (de pot verdwijnt dan ook uit vaste stortingen). |
| `reorder(db, accountId:, orderedIds:)` | Volgorde (alle pot-id's van de rekening). |
| `archive(db, potId:)` / `unarchive(db, potId:)` | Archiveren kan alleen bij saldo € 0,00. |
| `balance(db, potId:) -> Money` | Som van de boekingen op de spaarrekening met deze pot. |
| `distribution(db, for:, accountId:) -> [Allocation]?` | **Oude weg**, blijft werken voor bestaande aanroepen; nieuwe code gebruikt `DistributionService`. Eén regel per reserveringspot als het bedrag gelijk is aan de som van hun maandbedragen; anders `nil`. |
| `moveBetweenPots(db, from:, to:, amount:, day:, label:) -> (from: Entry, to: Entry)` | Twee handmatige boekingen op dezelfde rekening die samen nul zijn. |

**Spaardoel uit onderdelen.** Aantal ≥ 1, bedrag per stuk ≥ 0, label mag leeg; de volgorde van de lijst is de
volgorde van de onderdelen (`potId`, `id` en `sortOrder` in de meegegeven onderdelen worden genegeerd). Met
onderdelen is `Pot.targetAmount` altijd hun som: `PotService.update` weigert een ander bedrag niet maar
overschrijft het, zodat een naamswijziging met een verouderde kopie van de pot niet mislukt. Het scherm hoort
het doelveld dan alleen-lezen te tonen. Met een lege lijst verdwijnen de onderdelen, blijft `targetAmount` wat
het was en is het weer vrij in te vullen.

**Beginsaldo van een spaarrekening met potten.** Een beginboeking van een pot telt mee in het rekeningsaldo.
Daarom is de regel: `Account.openingBalance` is het NIET toegewezen deel, en beginsaldo bij de bank =
`accountOpening` + `potTotal` (= `total`). `AccountService.setOpeningFromPots(db, accountId:, totalOpening:)`
rekent dat uit: het zet `Account.openingBalance` op het werkelijke beginsaldo min de beginboekingen van de
potten. Roep het opnieuw aan nadat beginbedragen zijn gewijzigd. `Pot.monthlyAmount` wordt door de schermen
niet meer bewerkt.

## DistributionService — vaste storting met verdeling

Een vaste storting is een bedrag dat regelmatig van de betaalrekening naar een spaarrekening gaat en daar over
potten wordt verdeeld. Er kunnen er meer zijn.

| Functie | Doet |
|---|---|
| `create(db, name:, accountId:, sourceAccountId:) -> Distribution` | Nieuwe storting op een spaarrekening (doel), nog zonder regels. `sourceAccountId` is de betaalrekening waar het geld vandaan komt (optioneel). |
| `setSource(db, distributionId:, sourceAccountId:)` | Herkomstrekening zetten of weghalen (`nil`). Moet een betaalrekening zijn, niet dezelfde als het doel. |
| `rename(db, distributionId:, name:)` / `delete(db, distributionId:)` | Naam wijzigen; verwijderen (gekoppelde posten raken de koppeling kwijt en houden hun plan). |
| `setArchived(db, distributionId:, Bool)` / `reorder(db, orderedIds:)` / `all(db, includeArchived:)` | Archiveren, volgorde, lijst. |
| `lines(db, distributionId:) -> [DistributionLine]` | De regels op volgorde. |
| `setLines(db, distributionId:, [(potId:, amount:)])` | Vervangt de verdeling in één keer; de volgorde van de lijst is de volgorde van de regels. |
| `setLine(db, distributionId:, potId:, amount:)` / `removeLine(db, distributionId:, potId:)` | Eén pot wijzigen, toevoegen of weghalen. |
| `total(db, distributionId:) -> Money` | Som van de regels. |
| `link(db, distributionId:, budgetItemId:)` / `unlink(db, budgetItemId:)` / `linkedItems(db, distributionId:)` | Koppeling met de UIT-post op de betaalrekening. |
| `allocations(db, distributionId:, for:) -> DistributionProposal` | De regels als `[Allocation]` (label "<storting>: <pot>") voor een gestort bedrag. |
| `match(db, accountId:, amount:) -> [Distribution]` | Eenvoudige variant: niet-gearchiveerde stortingen van die spaarrekening met precies dit totaal. Voor het nakijkscherm is `recognize` de betere weg. |
| `recognize(db, bankTransaction:) -> DistributionMatch?` | Herkent beide kanten van de overboeking bij een banktransactie; zie hieronder. |
| `recognizeAll(db, accountId:) -> [Int64: DistributionMatch]` | `recognize` voor alle transacties met status `nieuw` van een rekening, per transactie-id. |
| `proposal(db, distributionId:, for:) -> DistributionMatch` | Het voorstel voor één gekozen storting, nadat `recognize` meer kandidaten gaf. |
| `createFromPots(db, accountId:, name:, year:) -> Distribution` | Eenmalige hulp: storting uit de reserveringspotten met `monthlyAmount > 0`; koppelt de regel RESERVERINGEN van `year` (standaard het lopende jaar) als die bestaat en het jaar open is. |

- Validatie: naam niet leeg; de rekening is een spaarrekening; elke pot hoort bij die rekening
  (`potWrongAccount`); bedragen > 0; een pot hoogstens één keer per storting.
- **Gekoppelde post:** zolang `BudgetItem.distributionId` gezet is, is het plan altijd − het totaal van de
  storting. Het wordt bijgewerkt na elke wijziging van de regels, voor posten in niet afgesloten jaren.
  `YearService.updateItem` weigert een ander plan niet, maar overschrijft het. Na `unlink` blijft het plan
  staan en is het weer vrij.
- Is de regel RESERVERINGEN (`isReserveTotal`) gekoppeld, dan gaat de storting voor op de som van de
  RES-regels; na `unlink` volgt hij die som weer.
- `DistributionProposal`: `distribution`, `allocations`, `total`, `difference` (gestort − totaal) en `isExact`.
  Bij een afwijkend bedrag blijven de regels de vaste verdeling en tellen ze dus NIET op tot het gestorte
  bedrag; er wordt niets automatisch verrekend. De UI laat de gebruiker kiezen waar het verschil heen gaat en
  past de regels aan vóór `BookingService.book`.

**Herkennen (`recognize`).** Alleen niet-gearchiveerde stortingen; IBAN's worden vergeleken zonder spaties
en hoofdletters.

- **Doelkant** (bijschrijving op de spaarrekening van de storting): past als de tegenrekening het IBAN van de
  herkomstrekening is, ook als het bedrag afwijkt van het totaal. Is er geen herkomst ingesteld, heeft de
  herkomstrekening geen IBAN of heeft de transactie geen tegenrekening, dan alleen bij een bedrag dat exact het
  totaal is. Een bekende, andere tegenrekening past niet, ook niet bij het exacte bedrag.
- **Herkomstkant** (afschrijving op de herkomstrekening): past als de tegenrekening het IBAN van de
  spaarrekening is. Zonder herkomstrekening wordt deze kant niet herkend.
- Passen er meer stortingen, dan wint de ene waarvan het totaal gelijk is aan het bedrag. Is die er niet
  precies één keer, dan komen alle kandidaten terug.

`DistributionMatch`: `distributions` (kandidaten), `distribution` (de ene, of `nil`), `isAmbiguous`, `side`
(`.source` / `.destination`), `exactAmount`, `difference` (overgeboekt − totaal), `allocations` en `warning`
(Nederlandse tekst of `nil`).

- Doelkant: `allocations` is de verdeling over de potten. Bij een afwijkend bedrag tellen ze niet op tot het
  bankbedrag; de gebruiker kiest waar het verschil heen gaat.
- Herkomstkant: één regel met het bankbedrag op de post die in het jaar van de transactie aan de storting
  gekoppeld is. Is er geen gekoppelde post, dan is de regel divers en zegt `warning` dat.
- Meer kandidaten: `allocations` is leeg, `exactAmount` is `false` en `difference` is nul; vraag na de keuze
  `proposal(db, distributionId:, for:)` op.

## ForecastService — verwachte bedragen per pot

Voor de vooruitblik: een verwacht bedrag bij een pot op een datum (gift, bonus, vakantiegeld, of een verwachte
uitgave). Het telt nergens in mee behalve in de vooruitblik. Terugkerende stortingen horen hier niet; die leidt
`HFInsight` af uit de vaste stortingen.

| Functie | Doet |
|---|---|
| `create(db, potId:, day:, amount:, label:, project:) -> ForecastItem` | Nieuwe verwachting. Bedrag met teken, niet nul; omschrijving mag leeg; een datum in het verleden mag. `project` wordt getrimd; leeg = geen project. |
| `update(db, ForecastItem)` / `delete(db, forecastItemId:)` | Wijzigen (pot, datum, bedrag, omschrijving, project) en verwijderen. |
| `renameProject(db, potId:, from:, to:) -> Int` | Hernoemt een project van die pot, ook bij uitgekomen verwachtingen; geeft het aantal gewijzigde verwachtingen. Bestaat `to` al, dan gaan ze samen; een lege `to` haalt ze uit het project; een lege `from` wordt geweigerd. |
| `projects(db, potId:) -> [String]` | De projecten van een pot op naam, ook van uitgekomen verwachtingen. |
| `markRealized(db, forecastItemId:, entryId:, at:)` | Markeert als uitgekomen en koppelt optioneel de echte boeking. |
| `reopen(db, forecastItemId:)` | Maakt hem weer open en verbreekt de koppeling. |
| `suggestRealization(db, entryId:) -> [ForecastItem]` | Open verwachtingen van de pot van die boeking, zelfde teken, bedrag exact of binnen 5 % van het verwachte bedrag, datum binnen 45 dagen; exact eerst. |
| `items(db, potId:, includeRealized:) -> [ForecastItem]` | De verwachtingen van een pot op datum, standaard alleen de open. |

- De pot moet bestaan en mag niet gearchiveerd zijn.
- De gekoppelde boeking staat op de spaarrekening van de pot en heeft hetzelfde teken; het bedrag mag
  afwijken. Een boeking hoort bij hoogstens één verwachting.
- `update` laat `realizedAt` en `realizedEntryId` ongemoeid; die lopen via `markRealized` en `reopen`.

## ItemCheckService — post met de hand afvinken

| Functie | Doet |
|---|---|
| `setChecked(db, budgetItemId:, month:, Bool, note:)` | Vinkt een post af voor een maand (1–12) van zijn jaar, of haalt het vinkje weg. Opnieuw afvinken werkt de notitie bij. |
| `checks(db, yearId:) -> [ItemCheck]` | Alle vinkjes van een jaar, op post en maand. |

Geweigerd in een afgesloten jaar (ook het weghalen) en voor RES-regels; de regel RESERVERINGEN kan wel.

## SavingsTransferService — verrekenen met spaar

Twee richtingen, gesaldeerd. Een boeking op de betaalrekening met `reimburse`:

- **uitgave** (negatief): het bedrag moet uit de pot (`potId`) terugkomen;
- **bijschrijving** (positief): het bedrag moet doorgestort worden naar de pot.

De openstaande boekingen worden gesaldeerd tot één verrekening. **Netto positief = van spaar naar betaal,
negatief = van betaal naar spaar.** Bij het **afvinken** wordt de verrekening meteen volledig geboekt. De
bankregels van de echte overboeking worden bij een latere import alleen nog herkend en aan die boekingen
gehangen; er komen dan geen boekingen bij.

| Functie | Doet |
|---|---|
| `openReimbursements(db) -> OpenReimbursements` | Openstaande boekingen, gesaldeerd en per pot. |
| `openWithoutPot(db) -> [Entry]` | Openstaande boekingen zonder pot, om voor te waarschuwen. |
| `createSavingsTransfer(db, entryIds:, day:, note:) -> SavingsTransfer` | Legt de verrekening vast; `amount` is het netto bedrag met teken (nul mag). Boekt nog niets. |
| `markDone(db, savingsTransferId:, on:, at:) -> SavingsTransfer` | Vinkt af en boekt de verrekening op `on` (standaard vandaag). |
| `reopen(db, savingsTransferId:)` | Terug naar 'nog te doen'; verwijdert de boekingen van het afvinken. |
| `delete(db, savingsTransferId:)` | Verwijdert de verrekening en haar boekingen; de gemarkeerde boekingen staan weer open. |
| `summary(db, savingsTransferId:) -> SavingsTransferSummary` | Saldo, per pot, de boekingen van het afvinken en de aangehangen bankregels. |
| `recognize(db, bankTransaction:) -> SavingsTransferMatch?` / `recognizeAll(db, accountId:)` | Herkent de bankregel van een verrekening; boekt niets. `recognizeAll` voor alle `nieuw`e van een rekening, per transactie-id. |
| `attach(db, savingsTransferId:, bankTransactionId:) -> SavingsTransferSummary` | Hangt een bankregel aan de boeking(en) van een afgevinkte verrekening. |
| `attachAll(db, accountId:) -> Int` | Hangt alle eenduidige bankregels van een rekening aan; geeft het aantal. |
| `detach(db, bankTransactionId:)` | Koppelt een aangehangen bankregel los; de banktransactie wordt weer `nieuw`. |
| `unconfirmed(db, today:) -> [SavingsTransfer]` | Afgevinkte verrekeningen waar na 5 dagen nog niet aan beide kanten een bankregel hangt. |
| `entries(db, savingsTransferId:) -> [Entry]` | De gemarkeerde boekingen in de verrekening. |

**`OpenReimbursements`**: `entries`, `fromSavings` (som van de uitgaven, positief), `toSavings` (som van de
bijschrijvingen, positief), `net` = `fromSavings − toSavings`, en `perPot: [PotMovement]`. `PotMovement` heeft
`pot` (nil = zonder pot) en `amount`: positief = de pot UIT, negatief = de pot IN; samen zijn ze `net`. Het
oude veld `total` bestaat nog en is nu gelijk aan `net` (kan dus negatief of nul zijn).

**`SavingsTransfer.amount`** is het netto bedrag met teken, niet meer altijd positief.

**`SavingsTransferSummary`**: `transfer`, `entries`, `fromSavings`, `toSavings`, `perPot`, `net`,
`needsBankTransfer` (false bij netto nul), `bookedEntries` (de boekingen van het afvinken),
`checkingAccountId`, `savingsAccountId`, `checkingTransactionId`, `savingsTransactionId` en `isConfirmed`.

**Rekeningen.** De gemarkeerde boekingen moeten op één betaalrekening staan en hun potten op één
spaarrekening; anders weigert `createSavingsTransfer` (maak per rekeningpaar een aparte verrekening). Heeft
geen enkele boeking een pot, dan is de spaarrekening de enige niet-gearchiveerde spaarrekening; zijn er meer,
dan weigert `markDone` met de vraag om een pot te kiezen.

**Afvinken (`markDone`)** boekt in één transactie, als handmatige boekingen op `on`:

- spaarrekening: per pot één boeking (uit de pot negatief, erin positief) en één regel zonder pot voor
  boekingen zonder pot; samen −netto;
- betaalrekening: één diverse boeking "Verrekening spaar" van +netto, zonder `reimburse`;
- bij netto nul: niets op de betaalrekening, en de potmutaties zijn samen nul;
- de betaal- en spaarkant verwijzen naar elkaar via `counterEntryId`, en alle boekingen krijgen de notitie
  "Verrekening #<id>".

Nog eens afvinken boekt niet opnieuw. Welke boekingen bij de verrekening horen staat in `Setting`
(`savingsTransfer.<id>.entries`); de notitie is alleen voor de gebruiker en mag gewijzigd worden.

**Herkennen (`recognize`)**, voor verrekeningen met netto ≠ 0:

- bedrag: op de betaalrekening +netto, op de spaarrekening −netto;
- afgevinkte verrekening: haar boeking op deze rekening heeft nog geen bankregel;
- nog niet afgevinkte verrekening: de rekening past bij haar boekingen en potten; `needsMarkDone` is dan
  `true`. Het scherm biedt "Afvinken en aanhangen" aan: `markDone(on: <dag van de bankregel>)` en dan `attach`;
- heeft de transactie een tegenrekening, dan moet dat de andere rekening van de verrekening zijn (als daarvan
  het IBAN bekend is; anders een eigen rekening van de andere soort). Zonder tegenrekening telt het bedrag.
  IBAN's worden vergeleken zonder spaties en hoofdletters;
- de dag ligt hoogstens 7 dagen van de dag van het afvinken (niet afgevinkt: de dag van de verrekening);
- precies één kandidaat: `transfer` is gezet. Meer: `isAmbiguous`, alle kandidaten in `transfers`, en de
  gebruiker kiest.

`SavingsTransferMatch`: `transfers`, `transfer`, `isAmbiguous`, `side` (`.checking` / `.savings`),
`needsMarkDone`.

**Aanhangen (`attach`)** zet op de bestaande boeking(en) van die rekening de banktransactie en neemt haar DAG
over; de banktransactie wordt `verwerkt`. Er komen geen boekingen bij en het eindsaldo verandert niet; alleen
het saldo op de dagen tussen het afvinken en de bankregel kan verschuiven. Geweigerd als de verrekening niet
is afgevinkt, de banktransactie niet `nieuw` is, die kant al een bankregel heeft of de som niet gelijk is aan
het bankbedrag. `attachAll` slaat twijfelgevallen en niet afgevinkte verrekeningen over.

**Bescherming.** Boekingen van het afvinken worden bij Spaaroverboekingen beheerd:

- `BookingService.book` / `unbook` op een aangehangen bankregel, `EntryService.delete`, en een wijziging van
  bedrag, rekening, dag of pot via `EntryService.update` worden geweigerd met
  `BudgetError.savingsTransferBooking`. Label, notitie en tags wijzigen mag.
- `reopen` en `delete` weigeren zolang er een bankregel aan hangt; eerst `detach`.
- `BalanceService.importCheck` klopt: een aangehangen bankregel is `verwerkt` en telt één keer.

**Let op:** boek de bankregel van een afgevinkte verrekening niet op een andere manier (regels, of
`TransferService.linkTransfer`); dan staat het bedrag er twee keer. Draai daarom altijd eerst `attachAll`.

**Volgorde in het nakijkscherm:** eerst `SavingsTransferService.attachAll` en `recognizeAll` (per rekening),
dan `DistributionService.recognizeAll`, dan de regels (`HFRules`).

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
| `createYear(db, year:, copyingFrom:)` | Kopieert buffers en alle posten, inclusief de koppeling met een vaste storting (zonder boekingen en vinkjes). |
| `updateBuffers(db, year:, antiRood:, tijdelijkAntiRood:)` | Buffers wijzigen. |
| `closeYear(db, year:)` / `reopenYear(db, year:)` | Afsluiten en heropenen. |
| `createItem(db, BudgetItem)` / `updateItem(db, BudgetItem)` | Post maken of wijzigen; geeft de opgeslagen post terug. Het plan van een post met `distributionId` wordt overschreven met − het totaal van de storting. |
| `deleteItem(db, itemId:, convertEntriesToDivers:)` | Met boekingen alleen als ze "divers" mogen worden. |
| `reorderItems(db, yearId:, orderedIds:)` | Volgorde (alle post-id's van het jaar). |
| `setScenario(db, itemId:, amount:) -> BudgetItem` | Zet het wat-als-bedrag van een post; `nil` wist het. |
| `clearScenario(db, yearId:) -> Int` | Wist alle wat-als-bedragen van het jaar; geeft het aantal. |
| `applyScenario(db, yearId:) -> ScenarioApplyResult` | Maakt van elk wat-als-bedrag het plan en wist daarna alle wat-als-bedragen. |

- Teken: IN ≥ 0, UIT en RES ≤ 0.
- Hoogstens één post per jaar met `isReserveTotal` (moet UIT zijn). Zijn plan is altijd de som van het plan
  van de RES-regels van dat jaar; een zelf ingevuld plan wordt overschreven.
- Kwartaal- en jaarposten hebben `expectedMonths` nodig ("1,4,7,10"); bij maandposten wordt het geleegd.
- **Wat-als (`BudgetItem.scenarioAmount`)**: zelfde tekenregels als het plan (IN ≥ 0, UIT ≤ 0, nul mag); niet
  voor RES-regels; geweigerd in een afgesloten jaar. Een post met een vaste storting en de regel RESERVERINGEN
  mogen een wat-als-bedrag hebben, maar hun plan wordt berekend: `applyScenario` slaat ze over en geeft ze terug
  in `ScenarioApplyResult.skipped` (met het niet toegepaste bedrag nog in `scenarioAmount`); `appliedCount` is
  het aantal toegepaste posten. Na `applyScenario` zijn alle wat-als-bedragen van het jaar gewist, ook die van
  de overgeslagen posten.
- `createItem` en `updateItem` schrijven het wat-als-bedrag niet: het wijzigt alleen via `setScenario`, en
  vervalt als de richting van de post wijzigt. `createYear(copyingFrom:)` neemt wat-als-bedragen niet mee.
- Nieuwe posten, potten, rekeningen en tags komen achteraan; de volgorde wijzig je met `reorder…`.

## AccountService en TagService

| Functie | Doet |
|---|---|
| `AccountService.create / update / delete` | IBAN wordt genormaliseerd (hoofdletters, geen spaties) en is uniek. Verwijderen alleen als de rekening nergens gebruikt wordt. |
| `AccountService.setArchived(db, accountId:, Bool)` / `reorder(db, orderedIds:)` | Archiveren en volgorde. |
| `AccountService.normalizeIBAN(String)` | De normalisatie zelf. |
| `AccountService.setOpeningFromPots(db, accountId:, totalOpening:)` | Zet het beginsaldo op het niet toegewezen deel; zie PotService. |
| `TagService.create(db, name:, color:)` / `update` / `delete` / `reorder` | Naam uniek (hoofdletterongevoelig), kleur `#RRGGBB`. `update` laat `settles` ongemoeid (dat loopt via `SettlementService`). `delete` verwijdert ook de verrekeningen van de tag. |

## Aannames

- `reimburse` kan alleen op een betaalrekening, bij een uitgave of een bijschrijving (niet bij nul).
- Het afgesloten jaar wordt bepaald door het kalenderjaar van de dag van de boeking, voor alle rekeningen.
  Een boeking in een spaaroverboeking opnemen of eruit halen valt daar niet onder.
- Verplaatsen tussen potten koppelt de twee boekingen niet via `counterEntryId`; dat veld is voor
  overboekingen tussen twee eigen rekeningen.
- Een developer reviewt deze module vóór gebruik met echte gegevens.
