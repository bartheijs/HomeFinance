import Testing
import Foundation
import GRDB
import HFCore
@testable import HFInsight

/// Kerncijfers voor de testronde: vaste sleutels, bedragen uit de bestaande leesfuncties, stabiel JSON.
@Suite struct KeyFiguresTests {
    let f: Fixture
    init() throws { f = try Fixture() }

    private func figures(_ day: Day = Fixture.today) throws -> [String: String] {
        try f.db.read { try Insight.keyFigures($0, today: day).values }
    }

    private func key(_ kind: String, _ id: Int64, _ field: String) -> String {
        "\(kind).\(String(format: "%04lld", id)).\(field)"
    }

    @Test func accountsWithBalanceAndLastImport() throws {
        let v = try figures()
        #expect(v["peildag"] == "2027-03-15")
        #expect(v[key("rekening", f.betaal, "naam")] == "Betaalrekening")
        #expect(v[key("rekening", f.betaal, "soort")] == "betaal")
        #expect(v[key("rekening", f.betaal, "saldo")] == "3540.00")
        #expect(v[key("rekening", f.betaal, "laatsteImport.dag")] == "2027-03-14")
        #expect(v[key("rekening", f.betaal, "laatsteImport.eindsaldo")] == "3482.50")
        #expect(v[key("rekening", f.betaal, "laatsteImport.saldoVolgensApp")] == "3540.00")
        #expect(v[key("rekening", f.spaar, "saldo")] == "5335.00")
        #expect(v[key("rekening", f.spaar, "laatsteImport.dag")] == "geen")
    }

    @Test func potsByNameAndId() throws {
        let v = try figures()
        #expect(v[key("pot", f.potAuto, "naam")] == "Auto")
        #expect(v[key("pot", f.potAuto, "saldo")] == "200.00")
        #expect(v[key("pot", f.potVakantie, "saldo")] == "100.00")
        #expect(v[key("pot", f.potKind, "saldo")] == "25.00")
        #expect(v[key("pot", f.potKind, "rekening")] == String(format: "%04lld", f.spaar))
    }

    @Test func spendableComesFromInsight() throws {
        let v = try figures()
        let s = try f.db.read { try Insight.spendable($0, year: 2027, today: Fixture.today) }
        #expect(v["besteedbaarNu"] == "3040.00")
        #expect(s.spendable == eur(3040))
        let end = s.spendableEndOfMonth
        let expected = "\(end.cents < 0 ? "-" : "")\(abs(end.cents) / 100).\(String(format: "%02lld", abs(end.cents) % 100))"
        #expect(v["nogTeBestedenDezeMaand"] == expected)
    }

    @Test func countsAndOpenReimbursements() throws {
        try f.db.write { db in
            var c = ItemCheck(budgetItemId: f.energie, month: 2, note: "")
            try c.insert(db)
        }
        let v = try figures()
        #expect(v["boekingen.aantal"] == "29")
        #expect(v["banktransacties.nieuw"] == "2")
        #expect(v["banktransacties.verwerkt"] == "1")
        #expect(v["banktransacties.overgeslagen"] == "0")
        #expect(v["verrekeningen.openAantal"] == "2")
        let net = try f.db.read { try Insight.openReimbursements($0).net }
        #expect(net == eur(195))
        #expect(v["verrekeningen.openNetto"] == "195.00")
        #expect(v["afgevinkt.2027-02"] == "1")
        #expect(v["afgevinkt.2027-03"] == nil)
    }

    @Test func negativeAmountsAndMissingYear() throws {
        try f.db.write { db in
            var e = Entry(accountId: f.betaal, day: d("2027-03-14"), amount: eur(-4000, 5), label: "Grote uitgave")
            try e.insert(db)
        }
        #expect(try figures()[key("rekening", f.betaal, "saldo")] == "-460.05")
        let later = try figures(d("2028-01-05"))
        #expect(later["besteedbaarNu"] == "geen begrotingsjaar")
        #expect(later["nogTeBestedenDezeMaand"] == "geen begrotingsjaar")
    }

    @Test func jsonIsStableAndSorted() throws {
        let a = try f.db.read { try Insight.keyFigures($0, today: Fixture.today).json() }
        let b = try f.db.read { try Insight.keyFigures($0, today: Fixture.today).json() }
        #expect(a == b)
        let text = String(decoding: a, as: UTF8.self)
        let keys = text.split(separator: "\n").compactMap { line -> String? in
            guard let q = line.firstIndex(of: "\"") else { return nil }
            let rest = line[line.index(after: q)...]
            return rest.firstIndex(of: "\"").map { String(rest[..<$0]) }
        }
        #expect(keys.count == (try figures()).count)
        #expect(keys == keys.sorted())
    }
}
