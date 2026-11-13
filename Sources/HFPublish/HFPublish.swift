// Module HFPublish: het dashboard voor de telefoon als één los HTML-bestand.
// Zie docs/api/HFPublish.md.
//
// - `PhoneDashboard.make` leest een kleine momentopname via HFInsight.
// - `PhoneDashboard.html` maakt daar één pagina van, zonder JavaScript en zonder externe bronnen.
// - `PublishOptions` en `PublishSettings` bewaren wat de gebruiker gekozen heeft.
//
// Geen AppKit, SwiftUI of WebKit: het wegschrijven (en de PDF) doet de app.
