import Foundation
import GRDB
import HFCore

/// Welke onderdelen op de pagina voor de telefoon staan. Standaard alles; de potjes van de kinderen en de
/// gezamenlijke spaarpot verschijnen pas als de gebruiker eigenaren of een pot gekozen heeft.
public struct PublishOptions: Codable, Equatable, Sendable {
    /// Saldo per rekening.
    public var showAccounts: Bool
    /// Vaste posten van deze maand (betaald, open, te laat).
    public var showFixedItems: Bool
    /// Verloop van besteedbaar per maandeinde.
    public var showTrend: Bool
    /// Potten op de spaarrekening.
    public var showPots: Bool
    /// De potjes van de gekozen eigenaren (de kinderen), per eigenaar gegroepeerd.
    public var showChildPots: Bool
    /// Eigenaren (zoals bij de pot ingevuld) van wie de potjes op de pagina staan. Leeg = niemand.
    public var childOwners: [String]
    /// Eén gekozen spaarpot met de verwachte stand over 3, 6 en 12 maanden.
    public var showSharedPot: Bool
    /// Id van die spaarpot, of nil als er nog geen gekozen is.
    public var sharedPotId: Int64?
    /// Hoeveel maanden vooruit de pagina de verwachte stand van die spaarpot meegeeft, voor de eigen datum en
    /// de stand per maand (standaard 36). Wordt bij gebruik begrensd op 12 … 120 (`sharedPotMonthRange`).
    public var sharedPotMonths: Int

    /// De toegestane waarden voor `sharedPotMonths`.
    public static let sharedPotMonthRange = 12...120
    public static let defaultSharedPotMonths = 36

    public init(showAccounts: Bool = true, showFixedItems: Bool = true, showTrend: Bool = true, showPots: Bool = true,
                showChildPots: Bool = true, childOwners: [String] = [], showSharedPot: Bool = true,
                sharedPotId: Int64? = nil, sharedPotMonths: Int = PublishOptions.defaultSharedPotMonths) {
        self.showAccounts = showAccounts; self.showFixedItems = showFixedItems
        self.showTrend = showTrend; self.showPots = showPots
        self.showChildPots = showChildPots; self.childOwners = childOwners
        self.showSharedPot = showSharedPot; self.sharedPotId = sharedPotId
        self.sharedPotMonths = sharedPotMonths
    }

    enum CodingKeys: String, CodingKey {
        case showAccounts, showFixedItems, showTrend, showPots, showChildPots, childOwners, showSharedPot, sharedPotId, sharedPotMonths
    }

    /// Ontbrekende sleutels (oudere versie) betekenen "aan", geen eigenaren, geen pot en 36 maanden vooruit.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        showAccounts = try c.decodeIfPresent(Bool.self, forKey: .showAccounts) ?? true
        showFixedItems = try c.decodeIfPresent(Bool.self, forKey: .showFixedItems) ?? true
        showTrend = try c.decodeIfPresent(Bool.self, forKey: .showTrend) ?? true
        showPots = try c.decodeIfPresent(Bool.self, forKey: .showPots) ?? true
        showChildPots = try c.decodeIfPresent(Bool.self, forKey: .showChildPots) ?? true
        childOwners = try c.decodeIfPresent([String].self, forKey: .childOwners) ?? []
        showSharedPot = try c.decodeIfPresent(Bool.self, forKey: .showSharedPot) ?? true
        sharedPotId = try c.decodeIfPresent(Int64.self, forKey: .sharedPotId)
        sharedPotMonths = try c.decodeIfPresent(Int.self, forKey: .sharedPotMonths) ?? Self.defaultSharedPotMonths
    }

    /// Of de potjes van de kinderen op de pagina komen: aan en er is minstens één eigenaar gekozen.
    public var includesChildPots: Bool { showChildPots && !childOwners.isEmpty }
    /// Of de gezamenlijke spaarpot op de pagina komt: aan en er is een pot gekozen.
    public var includesSharedPot: Bool { showSharedPot && sharedPotId != nil }
    /// `sharedPotMonths` binnen 12 … 120.
    public var sharedPotMonthsClamped: Int {
        min(max(sharedPotMonths, Self.sharedPotMonthRange.lowerBound), Self.sharedPotMonthRange.upperBound)
    }
}

/// Instellingen voor het dashboard op de telefoon, opgeslagen in de tabel `setting` onder `publish.*`.
public struct PublishSettings: Equatable, Sendable {
    /// De app werkt de bestanden automatisch bij. Standaard uit: de gebruiker zet dit zelf aan.
    public var enabled: Bool
    /// Map waarin de bestanden komen, of nil als er nog geen gekozen is.
    public var folderPath: String?
    public var options: PublishOptions
    /// Moment waarop de bestanden voor het laatst geschreven zijn.
    public var lastPublishedAt: Date?
    /// Melding van de laatste mislukte poging; nil als de laatste poging lukte.
    public var lastError: String?

    public init(enabled: Bool = false, folderPath: String? = nil, options: PublishOptions = PublishOptions(),
                lastPublishedAt: Date? = nil, lastError: String? = nil) {
        self.enabled = enabled; self.folderPath = folderPath; self.options = options
        self.lastPublishedAt = lastPublishedAt; self.lastError = lastError
    }

    public enum Key {
        public static let enabled = "publish.enabled"
        public static let folderPath = "publish.folderPath"
        public static let options = "publish.options"
        public static let lastPublishedAt = "publish.lastPublishedAt"
        public static let lastError = "publish.lastError"
    }

    public var folderURL: URL? {
        folderPath.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
    }

    /// Leest de instellingen; ontbrekende of onleesbare waarden krijgen de standaard.
    public static func load(_ db: Database) throws -> PublishSettings {
        var s = PublishSettings()
        s.enabled = try Setting.get(db, Key.enabled) == "1"
        s.folderPath = try Setting.get(db, Key.folderPath)
        if let json = try Setting.get(db, Key.options)?.data(using: .utf8),
           let options = try? JSONDecoder().decode(PublishOptions.self, from: json) {
            s.options = options
        }
        s.lastPublishedAt = try Setting.get(db, Key.lastPublishedAt).flatMap(Double.init)
            .map { Date(timeIntervalSince1970: $0) }
        s.lastError = try Setting.get(db, Key.lastError)
        return s
    }

    /// Slaat de keuzes van de gebruiker op (aan/uit, map, onderdelen). Het resultaat van de laatste poging
    /// blijft staan; dat legt `recordSuccess` of `recordFailure` vast.
    public func save(_ db: Database) throws {
        try Setting.set(db, Key.enabled, enabled ? "1" : "0")
        try Setting.set(db, Key.folderPath, folderPath)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try Setting.set(db, Key.options, String(data: try encoder.encode(options), encoding: .utf8))
    }

    /// De bestanden zijn geschreven: bewaart het moment en wist de laatste fout.
    public static func recordSuccess(_ db: Database, at date: Date) throws {
        try Setting.set(db, Key.lastPublishedAt, String(date.timeIntervalSince1970))
        try Setting.set(db, Key.lastError, nil)
    }

    /// Het schrijven is mislukt: bewaart de melding. Verandert niets als dezelfde melding er al staat.
    public static func recordFailure(_ db: Database, message: String) throws {
        guard try Setting.get(db, Key.lastError) != message else { return }
        try Setting.set(db, Key.lastError, message)
    }
}
