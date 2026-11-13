import Foundation
import HFCore

/// Schrijft het dashboard voor de telefoon als bestand naar een cloudmap.
/// De app roept `schedule` aan na elke wijziging in de database en `publishNow` bij afsluiten.
@MainActor
enum PublishSupport {
    /// Plant een nieuwe versie in (samengevoegd: niet vaker dan eens per paar seconden).
    static func schedule(_ model: AppModel) {
        // Wordt nog gebouwd.
    }

    /// Schrijft direct een nieuwe versie, als de gebruiker dit aan heeft staan.
    static func publishNow(_ model: AppModel) {
        // Wordt nog gebouwd.
    }
}
