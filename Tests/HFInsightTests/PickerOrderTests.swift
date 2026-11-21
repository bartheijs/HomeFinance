import Testing
import HFCore
@testable import HFInsight

@Suite struct PickerOrderTests {
    private func pot(_ id: Int64, _ name: String, _ kind: PotKind, account: Int64 = 1) -> Pot {
        Pot(id: id, accountId: account, name: name, kind: kind, sortOrder: Int(id))
    }

    @Test func reservationsFirstThenSavingsEachAlphabetical() {
        let pots = [
            pot(1, "zwemles", .spaar), pot(2, "Wegenbelasting", .reservering), pot(3, "Auto", .spaar),
            pot(4, "abonnement", .reservering), pot(5, "Muziek", .reservering, account: 2),
        ]
        #expect(Insight.pickerOrder(pots).map(\.name)
                == ["abonnement", "Muziek", "Wegenbelasting", "Auto", "zwemles"])
    }

    @Test func ignoresCaseAndSortsAccentsWithTheirLetter() {
        let pots = [pot(1, "Fiets", .reservering), pot(2, "école", .reservering), pot(3, "Energie", .reservering),
                    pot(4, "eten", .reservering), pot(5, "Écht", .reservering), pot(6, "aap", .reservering)]
        #expect(Insight.pickerOrder(pots).map(\.name) == ["aap", "Écht", "école", "Energie", "eten", "Fiets"])
    }

    @Test func numbersInNamesSortAsNumbers() {
        let pots = [pot(1, "Pot 10", .spaar), pot(2, "pot 2", .spaar), pot(3, "Pot 1", .spaar),
                    pot(4, "2e auto", .spaar), pot(5, "10 jaar", .spaar)]
        #expect(Insight.pickerOrder(pots).map(\.name) == ["2e auto", "10 jaar", "Pot 1", "pot 2", "Pot 10"])
    }

    @Test func equalNamesKeepTheirOriginalOrder() {
        let pots = [pot(7, "Vakantie", .spaar, account: 2), pot(3, "vakantie", .spaar, account: 1),
                    pot(5, "Vakantie", .spaar, account: 1)]
        let sorted = Insight.pickerOrder(pots)
        // Hoofdletterongevoelig gelijk; daarna kleine letter vóór hoofdletter, gelijke namen in de oude volgorde.
        #expect(sorted.map(\.id) == [3, 7, 5])
    }

    @Test func emptyAndSingleListsStayTheSame() {
        #expect(Insight.pickerOrder([Pot]()).isEmpty)
        #expect(Insight.pickerOrder([pot(1, "Enige", .spaar)]).map(\.name) == ["Enige"])
    }

    @Test func worksForPotSummariesFromTheOverview() throws {
        let db = try AppDatabase.inMemory()
        let summaries = try db.write { db -> [PotSummary] in
            var a = Account(name: "Spaar", iban: "NL00TEST0000000002", kind: .spaar, openingDate: d("2027-01-01"))
            try a.insert(db)
            let id = try #require(a.id)
            for (name, kind) in [("Zomer", PotKind.spaar), ("banden", .reservering), ("Appel", .spaar), ("Ánanas", .reservering)] {
                var p = Pot(accountId: id, name: name, kind: kind)
                try p.insert(db)
            }
            return try Insight.potOverview(db, today: d("2027-03-01")).accounts.flatMap(\.pots)
        }
        #expect(Insight.pickerOrder(summaries).map(\.name) == ["Ánanas", "banden", "Appel", "Zomer"])
    }
}
