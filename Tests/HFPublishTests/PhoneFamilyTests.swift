import Testing
import Foundation
import GRDB
import HFCore
import HFInsight
@testable import HFPublish

private let now = Date(timeIntervalSince1970: 1805115780)      // 15 maart 2027, 14:03 in Amsterdam
private let amsterdam = TimeZone(identifier: "Europe/Amsterdam")!

/// Het gewone voorbeeld uit `Fixture`, met verzonnen potjes voor twee kinderen, een pot van de groep "Kids",
/// een gezamenlijke spaarpot met verwachte bedragen en een verrekentag die meetelt.
///
/// Gezamenlijke spaarpot: saldo 1.000,00 op 15-3-2027. Verwacht: +300 op 1-5-2027, −100 op 1-8-2027,
/// +500 op 10-1-2028 en +999 op 1-4-2028 (na de 12 maanden).
///   over 3 maanden (15-6-2027): 1.300,00 · over 6 maanden (15-9-2027): 1.200,00 · over 12 maanden (15-3-2028): 1.700,00
private struct Family {
    let fixture: Fixture
    let sharedPotId: Int64
    let kidsPotId: Int64

    init(withYear: Bool = true) throws {
        fixture = try Fixture(withYear: withYear)
        var shared: Int64 = 0, kids: Int64 = 0
        try fixture.db.write { db in
            let spaar = try Account.filter(Column("kind") == AccountKind.spaar.rawValue).fetchOne(db)!.id!
            func pot(_ name: String, owner: String?, balance: Int64, archived: Bool = false) throws -> Int64 {
                var p = Pot(accountId: spaar, name: name, kind: .spaar, owner: owner, sortOrder: 10, archived: archived)
                try p.insert(db)
                if balance != 0 {
                    var e = Entry(accountId: spaar, day: d("2027-02-01"), amount: eur(balance), label: "Storting", potId: p.id)
                    try e.insert(db)
                }
                return p.id!
            }
            _ = try pot("Spaargeld", owner: "Kind B", balance: 120)
            _ = try pot("Kleedgeld", owner: "Kind A", balance: 45)
            _ = try pot("Spaargeld", owner: "Kind A", balance: 300)
            _ = try pot("Oud potje", owner: "Kind A", balance: 0, archived: true)
            kids = try pot("Studie", owner: "Kids", balance: 2000)
            shared = try pot("Samen sparen", owner: nil, balance: 1000)
            for (day, amount) in [("2027-05-01", 300), ("2027-08-01", -100), ("2028-01-10", 500), ("2028-04-01", 999)] {
                var item = ForecastItem(potId: shared, day: d(day), amount: eur(Int64(amount)), label: "Verwacht")
                try item.insert(db)
            }
            var tag = Tag(name: "Tanken <auto>", settles: true, startAmount: eur(80), startDay: d("2027-03-01"),
                          countsInSpendable: true)
            try tag.insert(db)
        }
        sharedPotId = shared; kidsPotId = kids
    }

    var options: PublishOptions {
        PublishOptions(childOwners: ["Kind A", "Kind B"], sharedPotId: sharedPotId)
    }

    func snapshot(_ options: PublishOptions? = nil) throws -> PhoneSnapshot {
        let options = options ?? self.options
        return try fixture.db.read { try PhoneDashboard.make($0, today: Fixture.today, now: now, options: options) }
    }

    func page(_ options: PublishOptions? = nil) throws -> String {
        PhoneDashboard.html(try snapshot(options), options: options ?? self.options, timeZone: amsterdam)
    }
}

@Suite struct PhoneFamilyTests {
    // MARK: Hoofdgetal

    @Test func mainNumberIsWhatIsLeftThisMonth() throws {
        let family = try Family()
        let budget = try #require(try family.snapshot().budget)
        // Het voorbeeld uit Fixture plus de € 80,00 van de tag die meetelt.
        #expect(budget.spendable == eur(3890))
        #expect(budget.spendableEndOfMonth == eur(6820))
        #expect(budget.returning == [PhoneSnapshot.ReturningLine(name: "Tanken <auto>", amount: eur(80))])
        try family.fixture.db.read { db in
            let spendable = try Insight.spendable(db, year: 2027, today: Fixture.today)
            #expect(budget.spendable == spendable.spendable)
            #expect(budget.spendableEndOfMonth == spendable.spendableEndOfMonth)
        }

        let html = try family.page()
        #expect(html.contains("<div class=\"label\">Nog te besteden deze maand</div>"))
        #expect(html.contains("€&nbsp;6.820<span class=\"cents\">,00</span>"))
        #expect(html.contains("Vrij te besteden <strong>€&nbsp;3.890,00</strong>"))
        #expect(html.contains("Komt nog terug: Tanken &lt;auto&gt;"))
        #expect(html.contains("Voorgeschoten geld dat nog terugkomt, telt al mee."))
        // Het hoofdgetal staat vóór besteedbaar nu.
        #expect(html.range(of: "6.820")!.lowerBound < html.range(of: "Vrij te besteden")!.lowerBound)
    }

    @Test func noReturningLineWithoutATagThatCounts() throws {
        let html = PhoneDashboard.html(try Fixture().db.read { try PhoneDashboard.make($0, today: Fixture.today, now: now) },
                                       timeZone: amsterdam)
        #expect(!html.contains("Komt nog terug"))
        #expect(!html.contains("Voorgeschoten geld"))
    }

    // MARK: Potjes van de kinderen

    @Test func childPotsGroupedPerChosenOwner() throws {
        let s = try Family().snapshot()
        #expect(s.childPots.map(\.owner) == ["Kind A", "Kind B"])
        #expect(s.childPots[0].total == eur(345))
        #expect(s.childPots[0].pots.map(\.name).sorted() == ["Kleedgeld", "Spaargeld"])   // gearchiveerd en leeg: weg
        #expect(s.childPots[1].pots == [PhoneSnapshot.PotLine(name: "Spaargeld", balance: eur(120))])
        // De groep "Kids" en potten zonder eigenaar zijn niet gekozen.
        #expect(!s.childPots.contains { $0.owner == "Kids" })
    }

    @Test func onlyChosenOwnersAndNothingWhenOff() throws {
        let family = try Family()
        var options = family.options
        options.childOwners = ["Kind B", "Bestaat niet"]
        #expect(try family.snapshot(options).childPots.map(\.owner) == ["Kind B"])
        options.childOwners = []
        #expect(try family.snapshot(options).childPots.isEmpty)
        options = family.options
        options.showChildPots = false
        #expect(try family.snapshot(options).childPots.isEmpty)
        #expect(!(try family.page(options)).contains("<h2>Kind A</h2>"))
    }

    @Test func childPotsOnThePage() throws {
        let html = try Family().page()
        #expect(html.contains("<h2>Kind A</h2>\n<div class=\"mid\">€&nbsp;345,00</div>"))
        #expect(html.contains("<h2>Kind B</h2>"))
        #expect(!html.contains("<h2>Kids</h2>"))
        #expect(html.contains("<span class=\"name\">Kleedgeld</span><span class=\"amt\">€&nbsp;45,00</span>"))
    }

    // MARK: Gezamenlijke spaarpot

    @Test func sharedPotLooksAhead3_6And12Months() throws {
        let family = try Family()
        let pot = try #require(try family.snapshot().sharedPot)
        #expect(pot.name == "Samen sparen")
        #expect(pot.balance == eur(1000))
        #expect(pot.ahead == [
            PhoneSnapshot.AheadPoint(months: 3, day: d("2027-06-15"), balance: eur(1300)),
            PhoneSnapshot.AheadPoint(months: 6, day: d("2027-09-15"), balance: eur(1200)),
            PhoneSnapshot.AheadPoint(months: 12, day: d("2028-03-15"), balance: eur(1700)),
        ])
        // Dezelfde berekening als de vooruitblik bij een pot.
        try family.fixture.db.read { db in
            for point in pot.ahead {
                let forecast = try Insight.potForecast(db, potId: family.sharedPotId, today: Fixture.today, until: point.day)
                #expect(forecast.endBalance == point.balance)
            }
        }
    }

    @Test func sharedPotOnThePage() throws {
        let html = try Family().page()
        #expect(html.contains("<h2>Samen sparen</h2>\n<div class=\"mid\">€&nbsp;1.000,00</div>"))
        #expect(html.contains("Over 3 maanden <span class=\"when\">jun 2027</span></span><span class=\"amt\">€&nbsp;1.300,00</span>"))
        #expect(html.contains("Over 6 maanden <span class=\"when\">sep 2027</span>"))
        #expect(html.contains("Over 12 maanden <span class=\"when\">mrt 2028</span></span><span class=\"amt\">€&nbsp;1.700,00</span>"))
    }

    @Test func anyPotCanBeTheSharedPot() throws {
        let family = try Family()
        var options = family.options
        options.sharedPotId = family.kidsPotId
        #expect(try family.snapshot(options).sharedPot?.name == "Studie")
    }

    @Test func noSharedPotWhenOffUnchosenOrGone() throws {
        let family = try Family()
        var options = family.options
        options.showSharedPot = false
        #expect(try family.snapshot(options).sharedPot == nil)
        options = family.options
        options.sharedPotId = nil
        #expect(try family.snapshot(options).sharedPot == nil)
        options.sharedPotId = 9999
        #expect(try family.snapshot(options).sharedPot == nil)
        #expect(!(try family.page(options)).contains("Over 3 maanden"))
    }

    @Test func familyPartsWithoutABudgetYear() throws {
        let family = try Family(withYear: false)
        let s = try family.snapshot()
        #expect(s.budget == nil)
        #expect(s.childPots.count == 2)
        #expect(s.sharedPot != nil)
        let html = try family.page()
        #expect(html.contains("Er is nog geen begroting voor 2027."))
        #expect(html.contains("<h2>Kind A</h2>") && html.contains("Over 12 maanden"))
    }

    @Test func monthsAheadClampToTheEndOfTheMonth() {
        #expect(PhoneDashboard.adding(months: 1, to: d("2027-01-31")) == d("2027-02-28"))
        #expect(PhoneDashboard.adding(months: 12, to: d("2027-02-28")) == d("2028-02-28"))
        #expect(PhoneDashboard.adding(months: 3, to: d("2027-11-30")) == d("2028-02-29"))
        #expect(PhoneDashboard.adding(months: 6, to: d("2027-03-15")) == d("2027-09-15"))
    }

    @Test func changedFamilyNumbersAreNotTheSame() throws {
        let family = try Family()
        let a = try family.snapshot()
        var options = family.options
        options.childOwners = ["Kind A"]
        #expect(!a.hasSameNumbers(as: try family.snapshot(options)))
        #expect(a.hasSameNumbers(as: try family.snapshot()))
    }

    // MARK: Opties

    @Test func olderOptionsWithoutTheNewKeysStillLoad() throws {
        let json = #"{"showAccounts":false,"showFixedItems":true,"showPots":true,"showTrend":true}"#
        let options = try JSONDecoder().decode(PublishOptions.self, from: Data(json.utf8))
        #expect(options.showAccounts == false)
        #expect(options.showChildPots && options.showSharedPot)
        #expect(options.childOwners.isEmpty && options.sharedPotId == nil)
        #expect(!options.includesChildPots && !options.includesSharedPot)
    }

    @Test func familyChoicesAreSaved() throws {
        let db = try AppDatabase.inMemory()
        var settings = PublishSettings()
        settings.options.childOwners = ["Kind A", "Kind B"]
        settings.options.sharedPotId = 7
        settings.options.showSharedPot = false
        try db.write { try settings.save($0) }
        let loaded = try db.read { try PublishSettings.load($0) }
        #expect(loaded.options == settings.options)
    }

    @Test func pageStaysNarrowWithOnlyTheDateScript() throws {
        let html = try Family().page()
        let lower = html.lowercased()
        // Precies één script: dat van het datumveld. Geen externe bronnen of gebeurtenissen in de opmaak.
        #expect(lower.components(separatedBy: "<script").count == 2)
        #expect(!lower.contains("src=") && !lower.contains("http") && !lower.contains("fetch("))
        #expect(lower.range(of: #"\son[a-z]+\s*="#, options: .regularExpression) == nil)
        #expect(html.contains(".name{min-width:0;overflow-wrap:anywhere}"))
        #expect(html.contains("white-space:nowrap"))
    }

    // MARK: Eigen datum (6o)

    @Test func monthlyBalancesGo36MonthsAheadByDefault() throws {
        let family = try Family()
        let pot = try #require(try family.snapshot().sharedPot)
        #expect(pot.until == d("2030-03-15"))
        #expect(pot.monthly.count == 36)
        #expect(pot.monthly.map(\.months) == Array(1...36))
        #expect(pot.monthly[0] == PhoneSnapshot.AheadPoint(months: 1, day: d("2027-04-15"), balance: eur(1000)))
        #expect(pot.monthly[1] == PhoneSnapshot.AheadPoint(months: 2, day: d("2027-05-15"), balance: eur(1300)))
        #expect(pot.monthly[11].balance == eur(1700))
        #expect(pot.monthly[12] == PhoneSnapshot.AheadPoint(months: 13, day: d("2028-04-15"), balance: eur(2699)))
        #expect(pot.monthly.last?.balance == eur(2699))
        // De 3, 6 en 12 maanden blijven hetzelfde en komen overeen met de stand per maand.
        for point in pot.ahead { #expect(pot.monthly[point.months - 1] == point) }
    }

    @Test func stepsAreTheForecastAtTheEndOfEachDay() throws {
        let family = try Family()
        // Twee verwachtingen op één dag: alleen de stand aan het eind van die dag.
        try family.fixture.db.write { db in
            var item = ForecastItem(potId: family.sharedPotId, day: d("2027-05-01"), amount: eur(-50), label: "Ook verwacht")
            try item.insert(db)
        }
        let pot = try #require(try family.snapshot().sharedPot)
        #expect(pot.steps == [
            PhoneSnapshot.ForecastStep(day: d("2027-05-01"), balance: eur(1250)),
            PhoneSnapshot.ForecastStep(day: d("2027-08-01"), balance: eur(1150)),
            PhoneSnapshot.ForecastStep(day: d("2028-01-10"), balance: eur(1650)),
            PhoneSnapshot.ForecastStep(day: d("2028-04-01"), balance: eur(2649)),
        ])
        // Elke dag geeft hetzelfde als de vooruitblik bij de pot op de Mac ("Stand op …").
        try family.fixture.db.read { db in
            let forecast = try Insight.potForecast(db, potId: family.sharedPotId, today: Fixture.today, until: pot.until)
            for day in ["2027-03-15", "2027-04-30", "2027-05-01", "2027-07-31", "2028-01-10", "2029-12-31", "2030-03-15"] {
                #expect(pot.balance(on: d(day), today: Fixture.today) == forecast.balance(on: d(day)))
            }
        }
        #expect(pot.balance(on: d("2027-03-14"), today: Fixture.today) == nil)
        #expect(pot.balance(on: d("2030-03-16"), today: Fixture.today) == nil)
    }

    @Test func monthsAheadCanBeSetAndAreClamped() throws {
        let family = try Family()
        var options = family.options
        options.sharedPotMonths = 24
        var pot = try #require(try family.snapshot(options).sharedPot)
        #expect(pot.until == d("2029-03-15") && pot.monthly.count == 24)
        options.sharedPotMonths = 3          // minder dan 12 kan niet: de 12 maanden staan er altijd op
        pot = try #require(try family.snapshot(options).sharedPot)
        #expect(pot.monthly.count == 12 && pot.ahead.last?.balance == eur(1700))
        options.sharedPotMonths = 500
        #expect(try family.snapshot(options).sharedPot?.monthly.count == 120)
        // Een andere horizon is een ander getal op de pagina.
        #expect(!(try family.snapshot()).hasSameNumbers(as: try family.snapshot(options)))
    }

    @Test func monthsAheadIsSavedAndDefaultsTo36() throws {
        let json = #"{"showSharedPot":true,"sharedPotId":3}"#
        #expect(try JSONDecoder().decode(PublishOptions.self, from: Data(json.utf8)).sharedPotMonths == 36)
        let db = try AppDatabase.inMemory()
        var settings = PublishSettings()
        settings.options.sharedPotMonths = 48
        try db.write { try settings.save($0) }
        #expect(try db.read { try PublishSettings.load($0) }.options.sharedPotMonths == 48)
    }

    @Test func datePickerAndMonthListOnThePage() throws {
        let html = try Family().page()
        // Het datumveld: verborgen tot het script het toont, begrensd op vandaag … de horizon.
        #expect(html.contains("<div class=\"pick\" id=\"pot-pick\" hidden>"))
        #expect(html.contains("<input type=\"date\" id=\"pot-pick-day\" min=\"2027-03-15\" max=\"2030-03-15\">"))
        // De gegevens voor het script: dag en opgemaakt bedrag per stap.
        #expect(html.contains("var d={from:\"2027-03-15\",until:\"2030-03-15\",start:\"€\u{00A0}1.000,00\","
                              + "steps:[[\"2027-05-01\",\"€\u{00A0}1.300,00\"],[\"2027-08-01\",\"€\u{00A0}1.200,00\"],"
                              + "[\"2028-01-10\",\"€\u{00A0}1.700,00\"],[\"2028-04-01\",\"€\u{00A0}2.699,00\"]]};"))
        #expect(html.contains("Die datum is al voorbij."))
        #expect(html.contains("Zo ver kijkt deze pagina niet vooruit."))
        // Zonder script: de stand per maand, ingeklapt.
        #expect(html.contains("<details class=\"months\"><summary>Stand per maand</summary>"))
        #expect(html.contains("<span class=\"name\">15 mei 2027</span><span class=\"amt\">€&nbsp;1.300,00</span>"))
        #expect(html.contains("<span class=\"name\">15 mrt 2030</span><span class=\"amt\">€&nbsp;2.699,00</span>"))
        // Dezelfde invoer geeft dezelfde tekst.
        #expect(html == (try Family().page()))
    }

    @Test func scriptStringsCannotCloseTheScript() {
        #expect(PhoneDashboard.jsString("a</script>\"\\") == #""a\u003c/script>\"\\""#)
        #expect(PhoneDashboard.plainAmount(eur(-1234)) == "\u{2212}€\u{00A0}1.234,00"
                || PhoneDashboard.plainAmount(eur(-1234)) == "€\u{00A0}\u{2212}1.234,00")
    }
}
