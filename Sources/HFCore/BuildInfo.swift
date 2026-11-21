import Foundation

/// Welke build er draait. `scripts/run.sh` zet de gegevens bij elke build in de `Info.plist` van de app:
/// - `CFBundleShortVersionString`: de versie, bv. "1.0";
/// - `HFBuildCommit`: de korte commit-hash, met een `+` erachter als er niet-gecommitte wijzigingen waren;
/// - `HFBuildDate`: de bouwdatum als "jjjj-mm-dd uu:mm".
///
/// Zonder die gegevens (bijvoorbeeld bij `swift run` of `swift build`) is het een ontwikkelversie.
public struct BuildInfo: Sendable, Equatable {
    public static let commitKey = "HFBuildCommit"
    public static let dateKey = "HFBuildDate"

    public let version: String?
    public let commit: String?
    /// Als "jjjj-mm-dd uu:mm".
    public let builtAt: String?

    public init(version: String?, commit: String?, builtAt: String?) {
        func clean(_ s: String?) -> String? {
            guard let t = s?.trimmingCharacters(in: .whitespaces), !t.isEmpty else { return nil }
            return t
        }
        self.version = clean(version)
        self.commit = clean(commit)
        self.builtAt = clean(builtAt)
    }

    public init(infoDictionary info: [String: Any]?) {
        self.init(version: info?["CFBundleShortVersionString"] as? String,
                  commit: info?[Self.commitKey] as? String,
                  builtAt: info?[Self.dateKey] as? String)
    }

    /// De build van de draaiende app.
    public static var current: BuildInfo { BuildInfo(infoDictionary: Bundle.main.infoDictionary) }

    /// True als versie, commit en bouwdatum er alle drie zijn.
    public var isComplete: Bool { version != nil && commit != nil && displayDate != nil }

    /// Bv. "1.0 · gebouwd 21-11-2026 14:50 · 7931616", of "ontwikkelversie" als er iets ontbreekt.
    public var displayText: String {
        guard let version, let commit, let date = displayDate else { return "ontwikkelversie" }
        return "\(version) · gebouwd \(date) · \(commit)"
    }

    /// "jjjj-mm-dd uu:mm" → "dd-mm-jjjj uu:mm"; nil als het formaat niet klopt.
    var displayDate: String? {
        guard let builtAt else { return nil }
        let parts = builtAt.split(separator: " ")
        guard parts.count == 2 else { return nil }
        let ymd = parts[0].split(separator: "-")
        let hm = parts[1].split(separator: ":")
        guard ymd.count == 3, ymd[0].count == 4, ymd[1].count == 2, ymd[2].count == 2,
              hm.count == 2, hm[0].count == 2, hm[1].count == 2,
              (ymd + hm).allSatisfy({ $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) })
        else { return nil }
        return "\(ymd[2])-\(ymd[1])-\(ymd[0]) \(parts[1])"
    }
}
