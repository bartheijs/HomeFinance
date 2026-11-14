import Foundation
import GRDB
import HFCore
import Testing
@testable import HFInsight

private let today = Fixture.today

@Suite struct LabelMatcherTests {
    let labels = [
        LabelSuggestion(label: "Boodschappen", count: 30, lastUsed: d("2027-03-03")),
        LabelSuggestion(label: "Zakgeld Kind 1", count: 10, lastUsed: d("2027-03-01")),
        LabelSuggestion(label: "Zakgeld Kind 2", count: 8, lastUsed: d("2027-02-01")),
        LabelSuggestion(label: "Zakdoeken", count: 8, lastUsed: d("2027-03-01")),
        LabelSuggestion(label: "Café Test", count: 3, lastUsed: d("2027-01-10")),
        LabelSuggestion(label: "Verzekering zak", count: 2, lastUsed: d("2027-01-05")),
        LabelSuggestion(label: "Cadeau", count: 1, lastUsed: d("2027-01-22")),
        LabelSuggestion(label: "Tanken", count: 5, lastUsed: d("2027-02-20")),
    ]

    @Test func suggestPrefixBeforeContains() {
        // Begint met "zak": op aantal (10, 8, 8), bij gelijk aantal de laatst gebruikte eerst; daarna bevat "zak".
        #expect(LabelMatcher.suggest("zak", from: labels).map(\.label)
                == ["Zakgeld Kind 1", "Zakdoeken", "Zakgeld Kind 2", "Verzekering zak"])
        #expect(LabelMatcher.suggest("  ZAK", from: labels, limit: 2).map(\.label) == ["Zakgeld Kind 1", "Zakdoeken"])
        #expect(LabelMatcher.suggest("kind", from: labels).map(\.label) == ["Zakgeld Kind 1", "Zakgeld Kind 2"])
        #expect(LabelMatcher.suggest("cafe", from: labels).map(\.label) == ["Café Test"])   // accentongevoelig
        #expect(LabelMatcher.suggest("xyz", from: labels).isEmpty)
    }

    @Test func suggestEmptyTextGivesMostUsed() {
        #expect(LabelMatcher.suggest("", from: labels, limit: 3).map(\.label) == ["Boodschappen", "Zakgeld Kind 1", "Zakdoeken"])
    }

    @Test func similarFindsNearDuplicates() {
        #expect(LabelMatcher.similar("Boodschapen", in: labels)?.label == "Boodschappen")       // tikfout
        #expect(LabelMatcher.similar("Zakgelt Kind 1", in: labels)?.label == "Zakgeld Kind 1")  // tikfout in één woord
        #expect(LabelMatcher.similar("Bood schappen", in: labels)?.label == "Boodschappen")     // extra spatie
        #expect(LabelMatcher.similar("Zakgeld-Kind 1", in: labels)?.label == "Zakgeld Kind 1")  // leesteken
        #expect(LabelMatcher.similar("Cafe Test", in: labels)?.label == "Café Test")            // accent
        #expect(LabelMatcher.similar("Zakdoek", in: labels)?.label == "Zakdoeken")              // meervoud -en
        #expect(LabelMatcher.similar("Cadeaus", in: labels)?.label == "Cadeau")                 // meervoud -s
        #expect(LabelMatcher.similar("Tankne", in: labels)?.label == "Tanken")                  // verwisselde letters
    }

    @Test func similarStaysQuietWhenExactOrDifferent() {
        #expect(LabelMatcher.similar("Boodschappen", in: labels) == nil)        // bestaat al
        #expect(LabelMatcher.similar("  boodschappen ", in: labels) == nil)     // gelijk na normalisatie
        #expect(LabelMatcher.similar("Zakgeld Kind 3", in: labels) == nil)      // ander cijfer
        #expect(LabelMatcher.similar("Zakgeld Oma 1", in: labels) == nil)       // ander woord
        #expect(LabelMatcher.similar("Zakgeld Hond 1", in: labels) == nil)
        #expect(LabelMatcher.similar("Sportclub", in: labels) == nil)
        #expect(LabelMatcher.similar("Tinkon", in: labels) == nil)              // 6 letters: afstand 2 is te veel
        #expect(LabelMatcher.similar("", in: labels) == nil)
    }

    @Test func nearDuplicateRule() {
        #expect(!LabelMatcher.isNearDuplicate("Zakgeld Kind 1", "Zakgeld Kind 2"))
        #expect(!LabelMatcher.isNearDuplicate("Kind A", "Kind B"))              // woord korter dan 4 letters
        #expect(!LabelMatcher.isNearDuplicate("Huur", "huur"))                  // gelijk, niet bijna gelijk
        #expect(!LabelMatcher.isNearDuplicate("Zakgeld", "Zakgeld Kind"))       // heel woord extra
        #expect(LabelMatcher.isNearDuplicate("Verzekering", "Verzekreing"))
        #expect(LabelMatcher.isNearDuplicate("Verzekering auto", "Verzekeringen auto"))
        #expect(LabelMatcher.isNearDuplicate("Uit eten", "Uiteten"))
        #expect(LabelMatcher.editDistance(Array("zakgeld"), Array("zakgelt")) == 1)
        #expect(LabelMatcher.editDistance(Array("tanken"), Array("tankne")) == 1)
    }
}

@Suite struct LabelSuggestionDatabaseTests {
    let f: Fixture
    init() throws {
        f = try Fixture()
        try f.db.write { db in
            var rule = Rule(name: "Vakantiehuis", targetItemLabel: "Huur", entryLabel: "Vakantiehuis Test",
                            tagIds: "\(f.tagUitEten)")
            try rule.insert(db)
            var existing = Rule(name: "Tanken", entryLabel: "tanken")     // bestaat al als boeking: geen extra suggestie
            try existing.insert(db)
        }
    }

    @Test func suggestionsWhileTyping() throws {
        try f.db.read { db in
            // "ta": Tanken (2×) en Tandarts (1×) beginnen ermee; Terugbetaling bevat het.
            let ta = try Insight.labelSuggestions(db, matching: "ta", today: today)
            #expect(ta.map(\.label) == ["Tanken", "Tandarts", "Terugbetaling"])
            #expect(ta[0].count == 2)
            #expect(ta[0].lastUsed == d("2027-02-20"))
            #expect(ta[0].tags.map(\.name) == ["tanken"])
            #expect(ta[0].itemLabel == nil)

            // "va": de regel begint ermee (0× gebruikt); daarna bevat: Storting Vakantie (2×), Opname vakantie (1×).
            let va = try Insight.labelSuggestions(db, matching: "va", today: today)
            #expect(va.map(\.label) == ["Vakantiehuis Test", "Storting Vakantie", "Opname vakantie"])
            #expect(va[0].count == 0)
            #expect(va[0].lastUsed == nil)
            #expect(va[0].itemLabel == "Huur")
            #expect(va[0].tags.map(\.name) == ["uit eten"])
            // Alleen betaalrekening: de spaarboekingen vallen weg, de regel zonder rekening blijft.
            try #expect(Insight.labelSuggestions(db, matching: "va", accountKind: .betaal, today: today).map(\.label)
                        == ["Vakantiehuis Test"])

            let huur = try #require(try Insight.labelSuggestions(db, matching: "huu", today: today).first)
            #expect(huur.count == 3)
            #expect(huur.itemLabel == "Huur")
            try #expect(Insight.labelSuggestions(db, matching: "s", limit: 2, today: today).count == 2)
        }
    }

    @Test func emptyTextGivesMostUsedOfLastTwelveMonths() throws {
        try f.db.read { db in
            try #expect(Insight.labelSuggestions(db, matching: "", limit: 1, today: today).map(\.label) == ["Huur"])
            // Peildag 10-3-2028: alleen boekingen vanaf 10-3-2027 tellen (Tandarts 10-3, Terugbetaling 12-3).
            try #expect(Insight.labelSuggestions(db, matching: " ", today: d("2028-03-10")).map(\.label)
                        == ["Terugbetaling", "Tandarts"])
        }
    }

    @Test func allLabelsMergesSpellings() throws {
        try f.db.write { db in
            for label in ["BOODSCHAPPEN", "  boodschappen"] {
                var e = Entry(accountId: f.betaal, day: d("2027-03-05"), amount: eur(-1), label: label)
                try e.insert(db)
            }
        }
        let all = try f.db.read { try Insight.allLabels($0) }
        let b = try #require(all.first { $0.id == "boodschappen" })
        #expect(b.count == 4)                       // 2 uit de fixture + 2
        #expect(b.label == "Boodschappen")          // 2× tegen 1× "BOODSCHAPPEN" en 1× "boodschappen"
        #expect(b.lastUsed == d("2027-03-05"))
        #expect(b.tags.isEmpty)                     // tag boodschappen bij 2 van de 4: geen meerderheid
        #expect(all.filter { $0.id == "tanken" }.count == 1)
        #expect(all.first?.count == 4)              // meest gebruikte eerst
    }

    @Test func similarGroups() throws {
        try f.db.write { db in
            for label in ["Boodschapen", "Tanken.", "Zakgeld Kind 1", "Zakgeld Kind 2"] {
                var e = Entry(accountId: f.betaal, day: d("2027-03-06"), amount: eur(-1), label: label)
                try e.insert(db)
            }
        }
        let groups = try f.db.read { try Insight.similarLabelGroups($0) }
        // Twee groepen van elk 3 boekingen; bij gelijke grootte alfabetisch. "Zakgeld Kind 1/2" en
        // "Lening deel 1/2" zijn geen bijna-dubbelen.
        #expect(groups.map { $0.map(\.label) } == [["Boodschappen", "Boodschapen"], ["Tanken", "Tanken."]])
        #expect(groups[0].map(\.count) == [2, 1])
        try #expect(Fixture().db.read { try Insight.similarLabelGroups($0) }.isEmpty)
    }
}
