import Foundation
import GRDB
import HFCore

/// Eén geëxporteerd CSV-bestand.
public struct CSVExportFile: Equatable, Sendable {
    /// Naam van de tabel.
    public var table: String
    public var url: URL
    /// Aantal gegevensregels (zonder de kopregel).
    public var rowCount: Int
}

extension Backup {
    /// Kolommen met een geldbedrag (in de database in centen), per tabel.
    static let moneyColumns: [String: Set<String>] = [
        "account": ["openingBalance"],
        "budgetYear": ["antiRood", "tijdelijkAntiRood"],
        "budgetItem": ["planAmount"],
        "pot": ["monthlyAmount", "targetAmount"],
        "importBatch": ["openingBalance", "closingBalance"],
        "bankTransaction": ["amount", "balanceBefore"],
        "entry": ["amount"],
        "rule": ["amount"],
        "reconciliation": ["actualBalance", "calculatedBalance"],
        "savingsTransfer": ["amount"],
    ]

    /// Exporteert de complete dataset: één CSV per tabel (`<tabel>.csv`) in `folder`, met kopregel.
    /// Puntkomma als scheidingsteken, bedragen als `1234,56`, UTF-8 met BOM zodat Excel het direct opent.
    @discardableResult
    public static func exportAllAsCSV(_ db: AppDatabase, to folder: URL) throws -> [CSVExportFile] {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            throw BackupError.folderUnavailable(folder.path)
        }
        // Alles in één leestransactie, zodat de bestanden bij elkaar horen.
        let tables: [(name: String, text: String, rows: Int)] = try db.read { database in
            let names = try String.fetchAll(database, sql: """
                SELECT name FROM sqlite_master
                WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name NOT LIKE 'grdb_%'
                ORDER BY name
                """)
            return try names.map { table in
                let money = moneyColumns[table] ?? []
                let columns = try database.columns(in: table).map(\.name)
                var lines = [columns.map(csvField).joined(separator: ";")]
                let cursor = try Row.fetchCursor(database, sql: "SELECT * FROM \"\(table)\" ORDER BY rowid")
                while let row = try cursor.next() {
                    let fields = columns.map { column -> String in
                        let value: DatabaseValue = row[column]
                        switch value.storage {
                        case .null: return ""
                        case .int64(let i): return money.contains(column) ? csvMoney(i) : String(i)
                        case .double(let d): return String(d).replacingOccurrences(of: ".", with: ",")
                        case .string(let s): return csvField(s)
                        case .blob(let data): return data.base64EncodedString()
                        }
                    }
                    lines.append(fields.joined(separator: ";"))
                }
                return (table, "\u{FEFF}" + lines.joined(separator: "\r\n") + "\r\n", lines.count - 1)
            }
        }
        return try tables.map { table in
            let url = folder.appendingPathComponent("\(table.name).csv")
            try Data(table.text.utf8).write(to: url, options: .atomic)
            return CSVExportFile(table: table.name, url: url, rowCount: table.rows)
        }
    }

    /// Centen als `1234,56` (zonder duizendtalscheiding, min vooraan).
    static func csvMoney(_ cents: Int64) -> String {
        let a = cents.magnitude
        return (cents < 0 ? "-" : "") + "\(a / 100)," + String(format: "%02d", Int(a % 100))
    }

    /// Tekstveld; tussen aanhalingstekens als het een puntkomma, aanhalingsteken of regeleinde bevat.
    static func csvField(_ text: String) -> String {
        guard text.contains(where: { $0 == ";" || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return text }
        return "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
