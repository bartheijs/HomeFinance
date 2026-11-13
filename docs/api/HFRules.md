# HFRules — publieke API

Regels toepassen op banktransacties, voorstellen met zekerheid, leren van correcties.
De module **stelt alleen voor** en beheert regels; boeken (`Entry`) doet `HFBudget`.
Hangt alleen af van `HFCore` en GRDB. Alle functies krijgen een `Database` en draaien dus binnen
`appDatabase.read { db in … }` of `appDatabase.write { db in … }`.

## Voorbeeld

```swift
import HFCore
import HFRules

// Reviewscherm: voorstellen voor alle nieuwe transacties van één rekening.
let suggestions = try appDatabase.read { db in
    try RuleEngine.suggestAll(db, accountId: accountId)      // [transactie-id: Suggestion]
}
let s = suggestions[transaction.id!]!
// s.confidence (.hoog/.midden/.laag/.geen), s.budgetItemId, s.potId, s.label, s.tagIds, s.reimburse,
// s.reason ("Regel 'Energie': tegenpartij en bedrag"), s.amountDiffers + s.expectedAmount, s.warnings

// Na het boeken (door HFBudget) met een andere of dezelfde keuze:
let result = try appDatabase.write { db in
    try RuleEngine.learn(from: Correction(bankTransaction: transaction, itemLabel: "Energie",
                                          potId: nil, entryLabel: nil, tagIds: [], reimburse: false), db)
}
// result.outcome: .created / .updated / .unchanged; result.message: "Regel geleerd: 'Stroomhuis' → post 'Energie'"
// Ongedaan maken:
try appDatabase.write { db in try RuleEngine.undoLearning(result, db) }
```

## `RuleEngine`

| Functie | Doet |
|---|---|
| `suggest(for: BankTransaction, _ db) -> Suggestion` | Voorstel voor één transactie. Altijd een resultaat; zonder regel `confidence == .geen`. |
| `suggestAll(_ db, accountId: Int64? = nil) -> [Int64: Suggestion]` | Voorstellen voor alle transacties met status `nieuw`, per transactie-id. Laadt de regels één keer. |
| `recordUse(ruleId:, _ db, at: Date = Date())` | `hitCount` + 1 en `lastUsed`. Aanroepen als een boeking met het voorstel van die regel is gemaakt. |
| `rules(_ db) -> [Rule]` | Alle regels op `priority`, daarna id. |
| `rule(id:, _ db) -> Rule?` | Eén regel. |
| `validate(_ rule)` | Gooit `RuleError.emptyName` of `.noConditions`. |
| `save(_ rule: inout Rule, _ db)` | Nieuw of gewijzigd opslaan na `validate`; lege tekstvelden worden nil, IBAN zonder spaties in hoofdletters. |
| `delete(ruleId:, _ db) -> Bool` | Verwijderen; false als hij niet bestond. |
| `setEnabled(ruleId:, _ enabled: Bool, _ db)` | Aan/uit; gooit `RuleError.notFound`. |
| `reorder(ruleIds: [Int64], _ db)` | Genoemde regels krijgen priority 10, 20, 30 … in die volgorde; de rest volgt in de oude volgorde. |
| `testRule(_ rule, against: db, limit: Int? = nil) -> [RuleTestHit]` | Welke bestaande banktransacties (alle statussen, nieuwste eerst) een — eventueel niet opgeslagen — regel herkent. Negeert `enabled`. |
| `learn(from: Correction, _ db, now: Date = Date()) -> LearnResult` | Leren van een correctie (zie onder). |
| `undoLearning(_ result: LearnResult, _ db)` | Gemaakte regel verwijderen of aangepaste regel terugzetten. |

`RuleError` is een `LocalizedError` met Nederlandse meldingen (`errorDescription`).

## Matchen en zekerheid

Een regel herkent een transactie als **alle ingevulde voorwaarden** kloppen:
`counterpartyContains` (in de naam van de tegenpartij), `counterpartyIban` (gelijk, zonder spaties/hoofdletters),
`descriptionContains` (in de omschrijving), `amount` (exact, met teken) en optioneel `accountId`.
Tekst is hoofdletter- en accentongevoelig; dubbele spaties tellen niet. Uitgeschakelde regels en regels zonder
voorwaarde (alleen `accountId` telt niet als voorwaarde) matchen nooit.

| Situatie (`MatchBasis`) | Zekerheid |
|---|---|
| Tegenpartij (naam of IBAN) en bedrag kloppen (`counterpartyAndAmount`) | `hoog` |
| Tegenpartij klopt, regel heeft geen bedrag (`counterparty`) | `midden` |
| Tegenpartij klopt, bedrag van de regel wijkt af (`counterpartyAmountDiffers`) | `midden`, met `amountDiffers` en `expectedAmount` |
| Trefwoord in de omschrijving, zonder tegenpartij (`keyword`); ook als er een bedrag bij staat dat klopt | `midden` |
| Alleen bedrag (`amountOnly`) | `laag` |
| Geen regel | `geen` |

Winnaar: hoogste zekerheid → laagste `priority` → volledige match vóór "bedrag wijkt af" → meeste kloppende
voorwaarden (`accountId` telt mee) → laagste id.

## `Suggestion`

`bankTransactionId`, `confidence`, `ruleId`, `ruleName`, `targetItemLabel`, `budgetItemId`, `potId`, `label`,
`tagIds`, `reimburse`, `amountDiffers`, `expectedAmount`, `reason`, `warnings`.

- `budgetItemId`: de `BudgetItem` met label `targetItemLabel` (hoofdletterongevoelig) in het `BudgetYear` van de
  **dag van de transactie**. Bestaat het jaar of de post niet, dan is hij nil en staat er een melding in `warnings`
  ("Het jaar 2028 bestaat nog niet; …", "De post 'X' bestaat niet in 2027."). `targetItemLabel == nil` = divers.
- `label`: `entryLabel` van de regel, anders de opgeschoonde tegenpartij, anders "Onbekend".

## `RuleMatcher`

`RuleMatcher(db)` laadt regels, jaren en posten één keer; `suggest(for:)` en `bestRule(for:)` zijn daarna puur
rekenwerk (handig voor lijsten). `RuleMatcher.match(rule, transaction, ignoreEnabled:)` test één regel.
`RuleMatcher(rules:budgetYears:budgetItems:)` werkt zonder database (previews).

## `LabelCleaner` en `TextNormalizer`

- `LabelCleaner.cleanLabel(_ raw: String) -> String`: spaties, pinautomaat-ruis ("BEA, Betaalpas", "CCV*",
  ",PAS123 NR:… 12.11.27/14:03"), landcode achteraan, bij pinbetalingen ook plaats en filiaalnummer, rechtsvormen
  (B.V., BV, N.V., VOF, C.V., GmbH, Ltd, Inc, LLC) en hoofdletters ("BAKKERIJ DE KORENAAR" → "Bakkerij de Korenaar").
  Tekst met gemengde hoofdletters blijft zoals hij is.
- `LabelCleaner.cleanLabel(counterparty:description:)`: de tegenpartij, of bij een lege naam een naam uit de
  omschrijving (pinbetaling, `/NAME/…/`, `Naam: …`; anders de omschrijving zelf, hoogstens 40 tekens).
- `TextNormalizer.normalize(_:)` en `normalizeIban(_:)`: dezelfde vergelijking als de regels gebruiken.

## Leren (`learn`)

`Correction`: `bankTransaction`, `itemLabel` (nil = divers), `potId`, `entryLabel` (nil = voorgesteld label),
`tagIds`, `reimburse`. `LearnResult`: `outcome`, `rule`, `previousRule`, `usedRuleId`, `message`.

1. **Tegenpartij bepalen**: IBAN als die er is, anders de naam, anders een trefwoord uit een herkenbare
   omschrijving (pinbetaling of naamveld). Lukt dat niet → `unchanged`, "Niets geleerd: …".
2. **Keuze gelijk aan het voorstel** van de winnende regel → alleen `recordUse` (`unchanged`, `usedRuleId` gezet).
   Uitzondering: is dat de geleerde regel van deze tegenpartij en moet zijn bedragvoorwaarde veranderen, dan
   wordt hij bijgewerkt.
3. Anders: de **geleerde regel** (`origin == .geleerd`) van deze tegenpartij wordt aangepast (`updated`), of er
   wordt er een gemaakt (`created`). Handmatige regels worden nooit aangepast. Staat de geleerde regel uit, dan
   gebeurt er niets.
4. **Bedrag als voorwaarde** alleen als het doel een vaste post is én tegenpartij + bedrag minstens twee keer
   gezien zijn (deze transactie telt mee); anders blijft het bedrag leeg en matcht de regel als `midden`.
   Een regel met alleen een bedrag wordt nooit geleerd.
5. Won er tot nu toe een **andere** regel, dan krijgt de geleerde regel een priority net vóór die regel, zodat
   de correctie de volgende keer effect heeft.

`learn` telt het gebruik alleen in geval 2. Roep `recordUse` niet nog eens aan voor dezelfde boeking.
