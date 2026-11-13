# HomeFinance (macOS)

Native macOS-gezinsbegroting: Swift 6, SwiftUI, SQLite via GRDB 7. Eén SwiftPM-package, geen Xcode-project.

- Ontwerp en rekenregels: `docs/spec/2026-11-13-homefinance-v1-design.md`. Lees dit eerst.
- Datamodel: `Sources/HFCore/Records.swift` en `Schema.swift`.
- Publieke API per module: `docs/api/<Module>.md`.

## Regels

- **Geen echte gegevens.** Geen echte namen, IBAN's of bedragen in code, tests, fixtures of commits. Testdata is
  verzonnen (IBAN's als `NL00TEST0000000001`). Lees nooit bestanden buiten deze repo.
- **Geld is `Money` (centen), datums zijn `Day`.** Nooit `Double` voor geld.
- **Uitgaven negatief, inkomsten positief.**
- **Geen rekenlogica in SwiftUI-views.** Views roepen de modules aan.
- **Schema:** bestaande migraties nooit aanpassen; een wijziging is een nieuwe migratie in `HFCore/Schema.swift`.
- **Modules kennen elkaar niet** (`HFImport`, `HFRules`, `HFBudget`, `HFInsight`, `HFBackup` hangen alleen af van `HFCore`).
- Tests met Swift Testing (`import Testing`) en `AppDatabase.inMemory()`.
- Interface en documentatie in het Nederlands; identifiers in het Engels.
- Niet committen zonder dat erom gevraagd is.

## Commando's

```bash
swift build                          # alles bouwen
swift test                           # alle tests
swift test --filter HFBudgetTests    # één module
./scripts/run.sh                     # app bouwen en starten
```

Werk je als bouwsessie naast andere sessies in dezelfde map: gebruik een eigen bouwmap
(`--scratch-path .build-<naam>`) en bouw alleen je eigen target (`swift build --target <Module>`), zodat je
geen last hebt van half geschreven code van een ander.
