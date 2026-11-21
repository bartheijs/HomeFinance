# HFRules — publieke API

Regels toepassen op banktransacties, voorstellen met zekerheid, een regelconcept bij een boeking (alleen
bewaard met toestemming van de gebruiker).
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

// Nakijken: wat zou de regel worden bij deze keuze? Schrijft niets.
let correction = Correction(bankTransaction: transaction, itemLabel: "Energie", potId: nil,
                            entryLabel: nil, tagIds: [], reimburse: false)
let proposal = try appDatabase.read { db in try RuleEngine.ruleProposal(for: correction, db) }
// proposal.offersChoice → toon "Onthoud als regel" (of bij proposal.isUpdate "Regel bijwerken met deze keuze")
let zin = try appDatabase.read { db in try RuleEngine.summary(of: proposal.draft!, db) }
// "Voortaan bij Stroomhuis (NL00TEST0000000050): post Energie"

// Na het boeken (door HFBudget): remember = het (eventueel in de editor aangepaste) concept, of nil (vinkje uit).
let result = try appDatabase.write { db in
    try RuleEngine.afterBooking(correction, remember: vinkjeAan ? concept : nil, db)
}
// result.outcome: .created / .updated / .unchanged; result.message: "Regel bewaard: Voortaan bij …"
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
| `ruleProposal(for: Correction, _ db) -> RuleProposal` | Het regelconcept bij een keuze; schrijft niets (zie "Regels alleen met toestemming"). |
| `applyChoice(_ correction: Correction, to: Rule) -> Rule` | Zet post, pot, verrekenen (met richting), omschrijving en tags van de keuze in een regel; voorwaarden, naam en volgorde blijven. Omschrijving: zie "Omschrijving in een regel" hieronder. Puur rekenwerk. |
| `afterBooking(_ correction:, remember: Rule?, _ db, now:) -> LearnResult` | Na het boeken: `remember` bewaren (`created`/`updated`), of zonder `remember` alleen het gebruik tellen als de keuze gelijk was aan het voorstel. |
| `summary(of: Rule, _ db) -> String` | Eén zin: "Voortaan bij X: post …, verrekenen met pot … bij geld eruit, omschrijving '…', tags …". Ook `summary(of:potName:tagNames:)` zonder database. |
| `undoLearning(_ result: LearnResult, _ db)` | Bewaarde regel verwijderen of bijgewerkte regel terugzetten. |
| `learn(from: Correction, _ db, now: Date = Date()) -> LearnResult` | Het oude, automatische leren (zie onder). De app roept dit sinds 6i niet meer aan. |

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
- `label`: `entryLabel` van de regel, anders `LabelCleaner.suggestedLabel` (eigen tekst van een overboeking of de
  opgeschoonde tegenpartij), anders "Onbekend".
- **Richting van verrekenen** (`Rule.reimburseDirection`, `.incoming` "erin" / `.outgoing` "eruit" / `.both`
  "beide"): heeft de regel `reimburse` en past de richting niet bij het bedrag van de transactie
  (`rule.reimburseApplies(to:) == false`), dan zijn `reimburse` false en `potId` nil, is `confidence` `.laag`
  en staat er een melding in `warnings` ("Regel 'X' verrekent met spaar alleen bij geld erin; …"). Post,
  omschrijving en tags blijven. Zonder `reimburse` geldt de pot altijd (bv. op de spaarrekening). Nakijken zet
  zo'n voorstel bij de twijfelgevallen, en het wordt nooit automatisch geboekt (er is een melding).

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
- `LabelCleaner.suggestedLabel(counterparty:description:transactionCode:)` (6b), ook als `suggestedLabel(for: tx)`:
  de voorgestelde omschrijving van een nieuwe boeking. Bij een overboeking met een korte, eigen tekst ("Zakgeld",
  "Cadeau verjaardag") is dat die tekst; anders hetzelfde als `cleanLabel(counterparty:description:)`. Geen eigen
  tekst bij:
  - een transactiecode van pin, geldautomaat, incasso, iDEAL, acceptgiro, kosten of rente (`BEA`, `GEA`, `INC`,
    `IDB`, `ACC`, `KST`, `RNT` … en de korte codes van andere banken). Overboekingscodes (`OVB`, `IOB`, `POV`) en
    onbekende codes laten de keuze aan de tekst;
  - gestructureerde tekst (`/`, `:`, `*`, links), vijf of meer cijfers achter elkaar of meer cijfers dan letters;
  - tekst die begint met iDEAL, SEPA, incasso, betaalautomaat en dergelijke, of een zakelijk woord bevat
    (factuur, termijn, kenmerk, contributie, polis …);
  - meer dan 30 tekens of meer dan 4 woorden;
  - tekst die gelijk is aan (een deel van) de tegenpartij;
  - geen tegenpartij: dan het oude gedrag (naam uit de omschrijving).

  `RuleMatcher.suggest` gebruikt dit als label wanneer de regel geen omschrijving (`entryLabel`) heeft; een
  omschrijving uit een regel gaat altijd voor. `cleanLabel(counterparty:description:)` blijft de naam van een
  nieuwe regel bepalen (ook in `HistoryRuleSeeder`). Het matchen zelf (IBAN, naam, trefwoord) verandert niet.
- `TextNormalizer.normalize(_:)` en `normalizeIban(_:)`: dezelfde vergelijking als de regels gebruiken.

## Regels alleen met toestemming (6i)

De app maakt of wijzigt nooit vanzelf een regel bij een boeking. Nakijken biedt een vinkje aan (standaard uit).

`RuleProposal`: `proposingRule` (de regel die het voorstel deed, of nil), `matchesProposal` (de keuze is gelijk
aan wat die regel voor déze transactie voorstelt, dus in de andere richting dan waarin verrekenen geldt zonder
verrekenen en pot), `draft` (het concept), `isUpdate` (`draft.id != nil`) en `offersChoice` (er is een concept
en de keuze is niet gelijk aan het voorstel van een regel).

- **Een regel deed het voorstel** → `draft` is die regel met `applyChoice` (zelfde id, voorwaarden blijven).
  Nakijken toont dan "Regel bijwerken met deze keuze". Is de keuze gelijk aan het voorstel, dan is er geen
  keuze (`offersChoice == false`) en telt `afterBooking` het gebruik.
- **Geen regel** → een nieuwe regel (`origin == .geleerd`, id nil) voor de tegenpartij: IBAN, anders de naam,
  anders een trefwoord uit een herkenbare omschrijving. Bedrag als voorwaarde alleen bij een vaste post en als
  tegenpartij + bedrag minstens twee keer gezien zijn. `priority` achteraan (hoogste + 10, afgerond op tientallen).
  Lukt geen tegenpartij of trefwoord, dan is `draft` nil en biedt Nakijken niets aan.
- **Verrekenen en richting** gaan via `learnReimburse` (zie onder, punt 6).
- **Omschrijving in een regel** (`applyChoice`, 6b): `correction.entryLabel == nil` betekent "de voorgestelde
  omschrijving overgenomen"; de omschrijving van de regel blijft dan zoals hij was (een nieuwe regel krijgt er
  geen). Een gekozen omschrijving gelijk aan `LabelCleaner.suggestedLabel` (wat de app zonder regel voorstelt:
  de eigen tekst van een overboeking, anders de tegenpartij) wordt niet vastgelegd (`entryLabel` nil), zodat
  elke overboeking haar eigen tekst houdt. Iets anders, ook bewust de naam van de tegenpartij, wordt vastgelegd
  en staat in `summary`. Nakijken en Transacties geven `entryLabel` nil mee als de omschrijving gelijk is aan
  `Suggestion.label`.
- `afterBooking(correction, remember:)`:
  - `remember` gezet → `RuleEngine.save` (met `validate`), `created` of `updated` (`previousRule` = de oude
    versie, voor `undoLearning`); `message` "Regel bewaard: Voortaan bij …" / "Regel bijgewerkt: …".
  - `remember == nil` en de keuze gelijk aan het voorstel → `recordUse` (`unchanged`, `usedRuleId` gezet).
  - `remember == nil` en de keuze wijkt af → niets (`unchanged`, de boeking is een uitzondering).

## Oud: automatisch leren (`learn`)

Niet meer gebruikt door de app (sinds 6i); de beschrijving blijft voor de tests en `learnReimburse`.

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

6. **Verrekenen met spaar en de richting** (`learnReimburse`): verrekenen geldt alleen in de richting (geld
   erin = bedrag positief, geld eruit = negatief) waarin de gebruiker het koos.
   - Verrekenen gekozen bij een regel die het nog niet had → richting van deze transactie.
   - Verrekenen gekozen in de andere richting dan waarin de regel het al deed → `.both`.
   - Géén verrekenen in de andere richting → verrekenen, pot en richting blijven; alleen post, omschrijving,
     tags en bedrag worden geleerd.
   - Géén verrekenen bij een regel met `.both` → alleen nog de andere richting.
   - Géén verrekenen in de richting van de regel → verrekenen uit.
   "Gelijk aan het voorstel" (stap 2) vergelijkt met wat de regel voor déze richting voorstelt (dus zonder
   verrekenen en pot in de andere richting). Het bericht noemt de richting: "…, verrekenen met spaar bij geld erin".

`learn` telt het gebruik alleen in geval 2. Roep `recordUse` niet nog eens aan voor dezelfde boeking.

Beperking: één geleerde regel per tegenpartij. Wordt dezelfde tegenpartij in de twee richtingen op een
verschillende post geboekt, dan wint de laatste keuze voor de post; verrekenen en pot blijven wel per richting.

### Migratie v9 (`v9-rule-reimburse-direction`)

Nieuwe kolom `rule.reimburseDirection` (tekst, standaard "beide"). Regels met `reimburse` krijgen de richting van
hun laatste boeking (`entry.ruleId`, `entry.reimburse = 1`, nieuwste dag en id) met verrekenen; zonder zo'n
boeking "erin" (alleen bijschrijving) als veilige keuze. Regels zonder verrekenen houden "beide"; de richting telt
pas als verrekenen aan gaat. In `Rule(...)` is de standaard `.both` (het oude gedrag).

## Regels voorstellen uit de Excel-historie (`HistoryRuleSeeder`)

Legt een bankexport naast de geïmporteerde Excel-historie (`Entry` zonder banktransactie met
`note == HistoryRuleSeeder.historyNote`, "Excel-historie") en stelt per tegenpartij een regel voor.
De bankregels zijn losse `BankTransaction`-waarden (`id == nil`); ze worden **niet opgeslagen en niet geboekt**.
`propose` schrijft niets, `apply` schrijft alleen regels.

```swift
// candidates: de regels van het bankbestand, omgezet naar BankTransaction (niet opgeslagen).
let seed = try appDatabase.read { db in
    try HistoryRuleSeeder.propose(db, candidates: candidates, accountId: accountId)
}
for p in seed.proposals {
    // p.rule (concept, origin .geleerd), p.matchCount, p.explanation ("5 keer gekoppeld aan post Energie"),
    // p.examples (dag, bedrag, historielabel), p.counterpartyName, p.counterpartyIban, p.id (stabiele sleutel)
}
// Tellingen voor de samenvatting: seed.matchedCount, ambiguousCount, noCandidateCount, mixedCount,
// alreadyCoveredCount, skippedCount, insufficientCount; details in seed.mixed en seed.alreadyCovered (SeedNote).

let rules = try appDatabase.write { db in
    try HistoryRuleSeeder.apply(db, proposals: chosen)      // [Rule], de gemaakte regels
}
```

| Naam | Doet |
|---|---|
| `HistoryRuleSeeder.propose(_ db, candidates:, accountId:) -> SeedResult` | Koppelen, groeperen, voorstellen. |
| `HistoryRuleSeeder.apply(_ db, proposals:) -> [Rule]` | Slaat voorstellen op als geleerde regels, alles of niets. Slaat over wat intussen al een regel heeft; twee keer aanroepen maakt niets dubbel. De app mag `proposal.rule` vooraf aanpassen. |
| `SeedResult` | `proposals` (meeste koppelingen eerst), `mixed`, `alreadyCovered` en de tellingen hierboven. |
| `SeedProposal` | `id`, `rule`, `counterpartyName`, `counterpartyIban`, `matchCount`, `examples`, `explanation`. |
| `SeedExample` | `day`, `amount`, `historyLabel`. |
| `SeedNote` | `counterparty`, `matchCount`, `detail`. |

**Koppelen** (zelfde rekening, zelfde bedrag, elke historieboeking hoogstens één keer), sterkste aanwijzing eerst:
1. diverse boeking met een echte datum (dag ≠ 15) op dezelfde dag;
2. diverse boeking met een echte datum binnen 2 dagen, of een boeking op een vaste post / zonder echte datum in
   dezelfde kalendermaand;
3. boeking op een vaste post / zonder echte datum in de maand ervoor of erna.

Zijn er meer kandidaten, dan wordt alleen gekozen als ze onderling gelijk zijn (zelfde post, label en tags) of
als bij precies één kandidaat alle woorden van het historielabel in de naam of omschrijving van de bank staan;
anders telt de bankregel als dubbelzinnig.

**Voorstel per tegenpartij** (IBAN, anders naam, anders een trefwoord uit een herkenbare omschrijving):
- al een regel voor die tegenpartij (handmatig of geleerd, aan of uit; het bedrag van die regel telt niet mee)
  → `alreadyCovered`;
- minder dan twee derde van de koppelingen naar hetzelfde doel → `mixed`;
- voorstel bij minstens 2 koppelingen naar hetzelfde doel, of 1 koppeling op een vaste post met een bedrag gelijk
  aan het plan van die post; anders telt de groep bij `insufficientCount`;
- `entryLabel`: naam van de post, of bij divers het historielabel als dat in minstens twee derde gelijk is;
- tags die bij minstens twee derde van de koppelingen staan; bedrag alleen bij een vaste post met minstens 2
  koppelingen die allemaal hetzelfde bedrag hebben; `reimburse` nooit.
