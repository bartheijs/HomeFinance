import Testing
import Foundation
import GRDB
import HFCore
import HFInsight
@testable import HFPublish

private let now = Date(timeIntervalSince1970: 1805115780)      // 15 maart 2027, 14:03 in Amsterdam
private let amsterdam = TimeZone(identifier: "Europe/Amsterdam")!

private func snapshot(_ fixture: Fixture) throws -> PhoneSnapshot {
    try fixture.db.read { try PhoneDashboard.make($0, today: Fixture.today, now: now) }
}

@Suite struct SnapshotTests {
    @Test func numbersMatchTheWorkedExample() throws {
        let s = try snapshot(Fixture())
        let budget = try #require(s.budget)
        #expect(budget.spendable == eur(3810))
        #expect(budget.spendableEndOfMonth == eur(6740))   // 6.620 + de open verrekening van € 120,00 (tandarts uit spaar)
        #expect(budget.borrowed == eur(250))
        #expect(budget.month == PhoneSnapshot.MonthSpending(month: 3, expenses: eur(-1410), planExpenses: eur(-1390), percent: 101))
        #expect(budget.fixedItems.paidCount == 1)
        #expect(budget.fixedItems.openCount == 2)
        #expect(budget.fixedItems.lateCount == 1)
        #expect(budget.fixedItems.late == [PhoneSnapshot.LateItem(label: Fixture.trickyItem, plan: eur(-40))])
        #expect(budget.trend.map(\.spendable) == [eur(3910), eur(5220), eur(3810)])
        #expect(s.accounts.map(\.balance) == [eur(4560), eur(985)])
        #expect(s.potGroups.map(\.total) == [eur(200), eur(25)])
        #expect(s.potGroups.map(\.title) == ["Reserveringen", "Sparen"])
        #expect(s.unallocated == eur(760))
        #expect(s.openReimbursement == eur(120))
        #expect(s.generatedAt == now)
    }

    @Test func numbersEqualInsight() throws {
        let fixture = try Fixture()
        let s = try snapshot(fixture)
        let budget = try #require(s.budget)
        try fixture.db.read { db in
            let today = Fixture.today
            let spendable = try Insight.spendable(db, year: today.year, today: today)
            #expect(budget.spendable == spendable.spendable)
            #expect(budget.spendableEndOfMonth == spendable.spendableEndOfMonth)
            #expect(budget.borrowed == (try Insight.temporaryLoanOutstanding(db, on: today)))

            let dashboard = try Insight.dashboard(db, today: today)
            #expect(budget.month.expenses == dashboard.monthExpenses)
            #expect(budget.month.planExpenses == dashboard.planExpenses)
            #expect(s.accounts.map(\.name) == dashboard.accounts.map(\.name))
            #expect(s.accounts.map(\.balance) == dashboard.accounts.map(\.balance))

            let fixed = try Insight.fixedItemsStatus(db, year: today.year, month: today.month, today: today)
            #expect(budget.fixedItems.paidCount == fixed.paidCount)
            #expect(budget.fixedItems.openCount == fixed.openCount)
            #expect(budget.fixedItems.lateCount == fixed.lateCount)
            #expect(budget.fixedItems.late.map(\.label) == fixed.items.filter { $0.state == .teLaat }.map(\.label))

            let pots = try Insight.potOverview(db, today: today)
            #expect(s.potGroups.map(\.total) == pots.byKind.map(\.total))
            #expect(s.potGroups.flatMap(\.pots).map(\.balance) == pots.byKind.flatMap(\.pots).map(\.balance))
            #expect(s.unallocated == pots.totalUnallocated)
            #expect(s.openReimbursement == (try Insight.openReimbursements(db).transferAmount))

            let series = try Insight.spendableSeries(db, year: today.year, today: today)
            #expect(budget.trend.map(\.day) == series.map(\.day))
            #expect(budget.trend.map(\.spendable) == series.map(\.spendable))
        }
    }

    @Test func missingYearGivesNoBudgetButKeepsAccountsAndPots() throws {
        let s = try snapshot(Fixture(withYear: false))
        #expect(s.budget == nil)
        #expect(s.accounts.count == 2)
        #expect(s.potGroups.count == 2)
    }

    @Test func sameNumbersIgnoresTheMomentOfMaking() throws {
        let fixture = try Fixture()
        let first = try snapshot(fixture)
        let later = try fixture.db.read { try PhoneDashboard.make($0, today: Fixture.today, now: now.addingTimeInterval(600)) }
        #expect(first != later)
        #expect(first.hasSameNumbers(as: later))
        try fixture.db.write { db in
            try db.execute(sql: "UPDATE entry SET amount = amount - 100 WHERE label = 'Tandarts'")
        }
        #expect(!first.hasSameNumbers(as: try snapshot(fixture)))
    }

    @Test func percentRoundsAndHandlesNoPlan() {
        #expect(PhoneDashboard.percent(eur(-50), of: eur(-200)) == 25)
        #expect(PhoneDashboard.percent(eur(-1), of: eur(-3)) == 33)
        #expect(PhoneDashboard.percent(eur(-2), of: eur(-3)) == 67)
        #expect(PhoneDashboard.percent(eur(-10), of: .zero) == nil)
    }
}

@Suite struct HTMLTests {
    private func page(_ options: PublishOptions = PublishOptions(), withYear: Bool = true) throws -> String {
        PhoneDashboard.html(try snapshot(Fixture(withYear: withYear)), options: options, timeZone: amsterdam)
    }

    @Test func isSelfContainedWithoutScripts() throws {
        for html in [try page(), try page(withYear: false)] {
            let lower = html.lowercased()
            #expect(!lower.contains("<script"))
            #expect(!lower.contains("http://"))
            #expect(!lower.contains("https://"))
            #expect(!lower.contains("src="))
            #expect(!lower.contains("href="))
            #expect(!lower.contains("url("))
            #expect(!lower.contains("@import"))
            #expect(!lower.contains("javascript:"))
            #expect(!lower.contains("<link"))
            #expect(!lower.contains("<img"))
            #expect(!lower.contains("<iframe"))
            // Geen gebeurtenissen als onclick= of onload=.
            #expect(lower.range(of: #"\son[a-z]+\s*="#, options: .regularExpression) == nil)
        }
    }

    @Test func isAPhonePage() throws {
        let html = try page()
        #expect(html.hasPrefix("<!DOCTYPE html>"))
        #expect(html.contains("<meta charset=\"utf-8\">"))
        #expect(html.contains("<meta name=\"viewport\" content=\"width=device-width"))
        #expect(html.contains("<style>"))
        #expect(html.contains("@media (prefers-color-scheme:dark)"))
        #expect(html.contains("color-scheme:light dark"))
        #expect(html.contains("-apple-system"))
        #expect(html.contains("<svg"))
    }

    @Test func showsTheNumbersInDutchFormat() throws {
        let html = try page()
        #expect(html.contains("Bijgewerkt op <strong>15 mrt 2027</strong> om 14:03"))
        #expect(html.contains("€&nbsp;3.810<span class=\"cents\">,00</span>"))
        #expect(html.contains("Eind van de maand <strong>€&nbsp;6.740,00</strong>"))
        #expect(html.contains("Uitgaven in maart"))
        #expect(html.contains("101% van €&nbsp;1.390,00 gepland"))
        #expect(html.contains("Tijdelijk geleend van spaar"))
        #expect(html.contains("Nog over te boeken van spaar"))
        #expect(html.contains("Niet toegewezen op spaar"))
        #expect(html.contains("−€&nbsp;40,00"))
        #expect(html.contains(">jan</text>") && html.contains(">mrt</text>"))
    }

    @Test func escapesLabelsFromTheUser() throws {
        let html = try page()
        #expect(html.contains("Kind &quot;A&quot; &amp; &lt;b&gt;co&lt;/b&gt;&#39;s pot"))
        #expect(html.contains("Water &lt;script&gt;alert(1)&lt;/script&gt; &amp; Co"))
        #expect(html.contains("Betaal &lt;img alt=x&gt; &amp; &#39;meer&#39;"))
        #expect(!html.contains("<b>co</b>"))
        #expect(!html.contains("<img"))
        #expect(PhoneDashboard.escape("a<b>&\"'") == "a&lt;b&gt;&amp;&quot;&#39;")
    }

    @Test func missingYearExplainsWhatToDo() throws {
        let html = try page(withYear: false)
        #expect(html.contains("Er is nog geen begroting voor 2027."))
        #expect(html.contains("Maak het jaar aan in HomeFinance op je Mac"))
        #expect(!html.contains("Eind van de maand"))
        #expect(html.contains("Rekeningen"))
    }

    @Test func optionsLeaveSectionsOut() throws {
        let all = try page()
        #expect(all.contains("Vaste posten in maart") && all.contains("Besteedbaar per maand")
                && all.contains("<h2>Rekeningen</h2>") && all.contains("<h2>Reserveringen</h2>"))
        let none = try page(PublishOptions(showAccounts: false, showFixedItems: false, showTrend: false, showPots: false))
        #expect(!none.contains("Vaste posten in maart"))
        #expect(!none.contains("Besteedbaar per maand"))
        #expect(!none.contains("<h2>Rekeningen</h2>"))
        #expect(!none.contains("<h2>Reserveringen</h2>"))
        #expect(!none.contains("Niet toegewezen"))
        #expect(none.contains("Uitgaven in maart"))
    }

    @Test func isDeterministic() throws {
        #expect(try page() == (try page()))
        let s = try snapshot(Fixture())
        #expect(PhoneDashboard.html(s, timeZone: amsterdam) != PhoneDashboard.html(s, timeZone: TimeZone(identifier: "UTC")!))
    }

    @Test func negativeSpendableIsMarked() throws {
        let fixture = try Fixture()
        try fixture.db.write { try $0.execute(sql: "UPDATE budgetYear SET antiRood = 900000") }
        let html = PhoneDashboard.html(try snapshot(fixture), timeZone: amsterdam)
        #expect(html.contains("<div class=\"big neg\">−€&nbsp;4.690"))
    }

    /// Schrijft de pagina van de fixture weg om hem te bekijken: HF_PUBLISH_EXAMPLE=<pad> swift test …
    @Test func writesExampleWhenAsked() throws {
        guard let path = ProcessInfo.processInfo.environment["HF_PUBLISH_EXAMPLE"] else { return }
        try page().write(toFile: path, atomically: true, encoding: .utf8)
    }
}

@Suite struct SettingsTests {
    @Test func defaultsAreOffAndEverythingShown() throws {
        let db = try AppDatabase.inMemory()
        let s = try db.read { try PublishSettings.load($0) }
        #expect(s == PublishSettings())
        #expect(!s.enabled)
        #expect(s.folderURL == nil)
        #expect(s.options == PublishOptions(showAccounts: true, showFixedItems: true, showTrend: true, showPots: true))
    }

    @Test func roundTripAndResult() throws {
        let db = try AppDatabase.inMemory()
        var s = PublishSettings(enabled: true, folderPath: "/tmp/test map")
        s.options.showPots = false
        try db.write { try s.save($0) }
        try db.write { try PublishSettings.recordFailure($0, message: "De map bestaat niet.") }
        var loaded = try db.read { try PublishSettings.load($0) }
        #expect(loaded.enabled && loaded.folderPath == "/tmp/test map" && !loaded.options.showPots)
        #expect(loaded.lastError == "De map bestaat niet." && loaded.lastPublishedAt == nil)

        // Opnieuw opslaan van de keuzes laat het resultaat staan.
        try db.write { try s.save($0) }
        try db.write { try PublishSettings.recordSuccess($0, at: now) }
        loaded = try db.read { try PublishSettings.load($0) }
        #expect(loaded.lastError == nil && loaded.lastPublishedAt == now)
        #expect(try db.read { try Setting.get($0, "publish.enabled") } == "1")
    }

    @Test func optionsFromAnOlderVersionDefaultToOn() throws {
        let options = try JSONDecoder().decode(PublishOptions.self, from: Data(#"{"showPots":false}"#.utf8))
        #expect(options == PublishOptions(showPots: false))
    }
}
