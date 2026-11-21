import Foundation
import HFCore
import HFInsight

/// `HomeFinance --database <kopie> --kerncijfers <uitvoer.json> [--dag jjjj-mm-dd]` (of met `--voorbeeld`):
/// schrijft de kerncijfers (`Insight.keyFigures`) als stabiel gesorteerd JSON, zonder venster. Exitcode 0 als het
/// gelukt is, anders 1 met de fout op stderr.
enum KeyFiguresCommand {
    static func run(output: URL) -> Never {
        do {
            guard LaunchOptions.isTestRun else {
                throw CommandError("--kerncijfers werkt alleen samen met --database <kopie> of --voorbeeld.")
            }
            let day = try LaunchOptions.day()
            let db = try LaunchOptions.openTestDatabase()
            let figures = try db.read { try Insight.keyFigures($0, today: day) }
            try FileManager.default.createDirectory(at: output.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try figures.json().write(to: output, options: .atomic)
            print("kerncijfers geschreven: \(output.path) (\(figures.values.count) waarden, peildag \(day.iso))")
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("Kerncijfers mislukt: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    struct CommandError: Error, LocalizedError {
        let errorDescription: String?
        init(_ text: String) { errorDescription = text }
    }
}
