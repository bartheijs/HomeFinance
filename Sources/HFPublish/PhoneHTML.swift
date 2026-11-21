import Foundation
import HFCore

extension PhoneDashboard {
    /// Eén pagina voor de telefoon: alle opmaak in het bestand zelf, geen externe bronnen. Het enige script is
    /// het kleine script voor een eigen datum bij de gezamenlijke spaarpot; zonder scripts (de voorvertoning van
    /// de app Bestanden) blijft dat datumveld verborgen en werkt de rest van de pagina gewoon.
    /// Dezelfde invoer (en tijdzone) geeft exact dezelfde tekst.
    public static func html(_ snapshot: PhoneSnapshot, options: PublishOptions = PublishOptions(),
                            timeZone: TimeZone = .current) -> String {
        var body: [String] = []
        body.append(header(snapshot, timeZone: timeZone))

        body.append(snapshot.budget.map { hero($0, snapshot: snapshot) } ?? yearMissingCard(snapshot))
        // De potjes en de spaarpot staan in de momentopname alleen als ze aan staan en gekozen zijn.
        body.append(contentsOf: snapshot.childPots.map(childPotsCard))
        if let shared = snapshot.sharedPot { body.append(sharedPotCard(shared, today: snapshot.today)) }
        if let budget = snapshot.budget {
            body.append(monthCard(budget.month))
            if options.showFixedItems { body.append(fixedItemsCard(budget.fixedItems, month: budget.month.month)) }
            if options.showTrend, let chart = trendCard(budget.trend) { body.append(chart) }
        }
        if options.showAccounts, !snapshot.accounts.isEmpty { body.append(accountsCard(snapshot.accounts)) }
        if options.showPots { body.append(contentsOf: potCards(snapshot)) }
        body.append("<footer>Alleen lezen · gemaakt door HomeFinance op je Mac</footer>")

        return """
        <!DOCTYPE html>
        <html lang="nl">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
        <meta name="format-detection" content="telephone=no, date=no, address=no, email=no">
        <title>HomeFinance vandaag</title>
        <style>
        \(css)
        </style>
        </head>
        <body>
        <main>
        \(body.joined(separator: "\n"))
        </main>
        </body>
        </html>

        """
    }

    // MARK: Tekst

    /// Maakt tekst veilig voor HTML (namen van posten, potten en rekeningen komen van de gebruiker).
    public static func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for ch in text {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default: out.append(ch)
            }
        }
        return out
    }

    /// "13 nov 2026" en "14:03" in de gegeven tijdzone.
    static func dateAndTime(_ date: Date, timeZone: TimeZone) -> (date: String, time: String) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let month = Day.monthNamesShort[(c.month ?? 1) - 1]
        return ("\(c.day ?? 1) \(month) \(c.year ?? 0)", String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0))
    }

    /// Bedrag met het minteken als echt minteken en een vaste spatie na het euroteken.
    static func amount(_ money: Money) -> String {
        escape(money.formatted()).replacingOccurrences(of: "-", with: "−").replacingOccurrences(of: "€ ", with: "€&nbsp;")
    }

    /// Het grote bedrag: de centen kleiner.
    static func bigAmount(_ money: Money) -> String {
        let text = amount(money)
        guard let comma = text.lastIndex(of: ",") else { return text }
        return "\(text[..<comma])<span class=\"cents\">\(text[comma...])</span>"
    }

    // MARK: Onderdelen

    static func header(_ snapshot: PhoneSnapshot, timeZone: TimeZone) -> String {
        let stamp = dateAndTime(snapshot.generatedAt, timeZone: timeZone)
        return """
        <header>
        <div class="brand">HomeFinance</div>
        <div class="stamp">Bijgewerkt op <strong>\(stamp.date)</strong> om \(stamp.time)</div>
        </header>
        """
    }

    /// Het hoofdgetal: wat er deze maand nog te besteden is, zoals op het Dashboard van de Mac. Besteedbaar nu
    /// staat eronder; geleend geld, nog over te boeken bedragen en tags die meetellen staan in de notities.
    static func hero(_ budget: PhoneSnapshot.Budget, snapshot: PhoneSnapshot) -> String {
        var notes: [String] = []
        for tag in budget.returning {
            notes.append(row("Komt nog terug: \(tag.name)", amount(tag.amount)))
        }
        if !budget.borrowed.isZero {
            notes.append(row("Tijdelijk geleend van spaar", amount(budget.borrowed)))
        }
        if !snapshot.openReimbursement.isZero {
            notes.append(row("Nog over te boeken van spaar", amount(snapshot.openReimbursement)))
        }
        let main = budget.spendableEndOfMonth, now = budget.spendable
        let monthName = Day.monthNames[snapshot.today.month - 1]
        var lines = ["<section class=\"hero\">",
                     "<div class=\"label\">Nog te besteden deze maand</div>",
                     "<div class=\"big\(main.isNegative ? " neg" : "")\">\(bigAmount(main))</div>",
                     "<div class=\"sub\">Als alle vaste lasten en inkomsten van \(monthName) binnen zijn.</div>",
                     "<div class=\"now\">Besteedbaar nu <strong\(now.isNegative ? " class=\"neg\"" : "")>\(amount(now))</strong></div>"]
        if !notes.isEmpty {
            lines.append("<div class=\"notes\">\n\(notes.joined(separator: "\n"))\n</div>")
        }
        if !budget.returning.isEmpty {
            lines.append("<div class=\"sub fine\">Voorgeschoten geld dat nog terugkomt, telt al mee.</div>")
        }
        lines.append("</section>")
        return lines.joined(separator: "\n")
    }

    /// De potjes van één kind: totaal en per pot het saldo.
    static func childPotsCard(_ group: PhoneSnapshot.OwnerPots) -> String {
        var lines = ["<section class=\"card\">",
                     "<h2>\(escape(group.owner))</h2>",
                     "<div class=\"mid\">\(amount(group.total))</div>",
                     "<div class=\"rows\">"]
        for pot in group.pots {
            lines.append(row(pot.name, amount(pot.balance), classes: "small"))
        }
        lines.append("</div>")
        lines.append("</section>")
        return lines.joined(separator: "\n")
    }

    /// De gezamenlijke spaarpot: saldo nu, de verwachte stand over 3, 6 en 12 maanden, een eigen datum (met
    /// script) en de stand per maand (zonder script, inklapbaar).
    static func sharedPotCard(_ pot: PhoneSnapshot.SharedPot, today: Day) -> String {
        var lines = ["<section class=\"card\">",
                     "<h2>\(escape(pot.name))</h2>",
                     "<div class=\"mid\">\(amount(pot.balance))</div>",
                     "<div class=\"sub\">Nu op de spaarrekening</div>",
                     "<div class=\"rows\">"]
        for point in pot.ahead {
            let when = "\(Day.monthNamesShort[point.day.month - 1]) \(point.day.year)"
            lines.append("<div class=\"row small\"><span class=\"name\">Over \(point.months) maanden"
                         + " <span class=\"when\">\(when)</span></span><span class=\"amt\">\(amount(point.balance))</span></div>")
        }
        lines.append("</div>")
        lines.append(datePicker(pot, today: today))
        lines.append("<details class=\"months\"><summary>Stand per maand</summary>")
        lines.append("<div class=\"rows\">")
        for point in pot.monthly {
            lines.append(row(shortDate(point.day), amount(point.balance), classes: "small"))
        }
        lines.append("</div>")
        lines.append("</details>")
        lines.append("<div class=\"sub fine\">Verwacht met de vaste stortingen en de verwachte bedragen van deze pot.</div>")
        lines.append("</section>")
        return lines.joined(separator: "\n")
    }

    /// "15 jun 2027".
    static func shortDate(_ day: Day) -> String {
        "\(day.day) \(Day.monthNamesShort[day.month - 1]) \(day.year)"
    }

    /// Het datumveld voor een eigen datum. Staat verborgen tot het script het toont, zodat er zonder scripts
    /// geen veld staat dat niets doet. Het script zoekt de laatste stap op of vóór de gekozen dag op
    /// (zie `PhoneSnapshot.SharedPot.balance(on:today:)`); de bedragen staan al opgemaakt in de gegevens.
    static func datePicker(_ pot: PhoneSnapshot.SharedPot, today: Day) -> String {
        let steps = pot.steps.map { "[\(jsString($0.day.iso)),\(jsString(plainAmount($0.balance)))]" }
        let months = Day.monthNamesShort.map(jsString).joined(separator: ",")
        let data = "{from:\(jsString(today.iso)),until:\(jsString(pot.until.iso)),"
            + "start:\(jsString(plainAmount(pot.balance))),steps:[\(steps.joined(separator: ","))]}"
        return """
        <div class="pick" id="pot-pick" hidden>
        <label for="pot-pick-day">Stand op een eigen datum</label>
        <input type="date" id="pot-pick-day" min="\(today.iso)" max="\(pot.until.iso)">
        <div class="pick-result" id="pot-pick-result" hidden><span class="when" id="pot-pick-when"></span><span class="mid" id="pot-pick-amt"></span></div>
        <div class="sub" id="pot-pick-msg"></div>
        </div>
        <script>
        (function(){
        var d=\(data);
        var M=[\(months)];
        function el(id){return document.getElementById(id);}
        function nice(s){var p=s.split("-");return (+p[2])+" "+M[+p[1]-1]+" "+p[0];}
        var input=el("pot-pick-day"),result=el("pot-pick-result"),msg=el("pot-pick-msg");
        function show(){
        var v=input.value,text="";
        if(!v){text="Kies een datum tot en met "+nice(d.until)+".";}
        else if(v<d.from){text="Die datum is al voorbij. Kies een datum vanaf "+nice(d.from)+".";}
        else if(v>d.until){text="Zo ver kijkt deze pagina niet vooruit. Kies een datum tot en met "+nice(d.until)+".";}
        if(text){result.hidden=true;msg.textContent=text;msg.hidden=false;return;}
        var a=d.start;
        for(var i=0;i<d.steps.length&&d.steps[i][0]<=v;i++){a=d.steps[i][1];}
        el("pot-pick-when").textContent="Verwacht op "+nice(v);
        el("pot-pick-amt").textContent=a;
        result.hidden=false;msg.hidden=true;
        }
        input.addEventListener("input",show);
        input.addEventListener("change",show);
        el("pot-pick").hidden=false;
        show();
        })();
        </script>
        """
    }

    /// Bedrag als gewone tekst (voor het script): echt minteken en een vaste spatie na het euroteken.
    static func plainAmount(_ money: Money) -> String {
        money.formatted().replacingOccurrences(of: "-", with: "\u{2212}").replacingOccurrences(of: "€ ", with: "€\u{00A0}")
    }

    /// Tekst als JavaScript-string tussen dubbele aanhalingstekens; `<` wordt `\u003c`, zodat de tekst nooit een
    /// `</script>` kan vormen.
    static func jsString(_ text: String) -> String {
        var out = "\""
        for ch in text {
            switch ch {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "<": out += "\\u003c"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            default: out.append(ch)
            }
        }
        return out + "\""
    }

    static func monthCard(_ month: PhoneSnapshot.MonthSpending) -> String {
        let name = Day.monthNames[month.month - 1]
        var lines = ["<section class=\"card\">", "<h2>Uitgaven in \(name)</h2>",
                     "<div class=\"mid\">\(amount(month.expenses.magnitude))</div>"]
        if let percent = month.percent {
            lines.append(progressBar(percent: percent))
            lines.append("<div class=\"sub\">\(percent)% van \(amount(month.planExpenses.magnitude)) gepland</div>")
        } else {
            lines.append("<div class=\"sub\">Voor deze maand is niets gepland.</div>")
        }
        lines.append("</section>")
        return lines.joined(separator: "\n")
    }

    /// Dunne balk als inline SVG; boven de 100% is de balk vol.
    static func progressBar(percent: Int) -> String {
        let width = min(max(percent, 0), 100)
        return """
        <svg class="bar" width="100%" height="6" role="img" aria-label="\(percent)% van het plan">\
        <rect class="track" width="100%" height="6" rx="3"/>\
        <rect class="fill" width="\(width)%" height="6" rx="3"/></svg>
        """
    }

    static func fixedItemsCard(_ fixed: PhoneSnapshot.FixedItems, month: Int) -> String {
        func stat(_ count: Int, _ label: String, red: Bool = false) -> String {
            "<div class=\"stat\"><div class=\"n\(red ? " neg" : "")\">\(count)</div><div class=\"sub\">\(label)</div></div>"
        }
        var lines = ["<section class=\"card\">", "<h2>Vaste posten in \(Day.monthNames[month - 1])</h2>",
                     "<div class=\"stats\">",
                     stat(fixed.paidCount, "betaald"), stat(fixed.openCount, "open"),
                     stat(fixed.lateCount, "te laat", red: fixed.lateCount > 0),
                     "</div>"]
        if !fixed.late.isEmpty {
            lines.append("<div class=\"rows\">")
            for item in fixed.late {
                lines.append(row(item.label, amount(item.plan), classes: "neg"))
            }
            lines.append("</div>")
        }
        lines.append("</section>")
        return lines.joined(separator: "\n")
    }

    /// Vlakgrafiek van besteedbaar per maandeinde; nil bij minder dan twee punten.
    static func trendCard(_ points: [PhoneSnapshot.TrendPoint]) -> String? {
        guard points.count >= 2 else { return nil }
        let width = 340.0, top = 10.0, bottom = 100.0, left = 6.0, right = 334.0
        let values = points.map { $0.spendable.doubleValue }
        let low = min(0, values.min() ?? 0)
        var high = max(0, values.max() ?? 0)
        if high - low < 1 { high = low + 1 }
        func x(_ i: Int) -> Double { left + (right - left) * Double(i) / Double(points.count - 1) }
        func y(_ v: Double) -> Double { bottom - (v - low) / (high - low) * (bottom - top) }
        func f(_ v: Double) -> String { String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), v) }

        let line = points.indices.map { "\(f(x($0))),\(f(y(values[$0])))" }.joined(separator: " ")
        let zero = y(0)
        let area = "\(f(x(0))),\(f(zero)) \(line) \(f(x(points.count - 1))),\(f(zero))"
        var svg = ["<svg class=\"trend\" viewBox=\"0 0 \(Int(width)) 122\" width=\"100%\" role=\"img\" aria-label=\"Verloop van besteedbaar per maand\">",
                   "<polygon class=\"area\" points=\"\(area)\"/>",
                   "<line class=\"zero\" x1=\"\(f(left))\" y1=\"\(f(zero))\" x2=\"\(f(right))\" y2=\"\(f(zero))\"/>",
                   "<polyline class=\"line\" points=\"\(line)\"/>",
                   "<circle class=\"dot\" cx=\"\(f(x(points.count - 1)))\" cy=\"\(f(y(values[points.count - 1])))\" r=\"3.5\"/>"]
        for i in points.indices {
            let anchor = i == 0 ? "start" : (i == points.count - 1 ? "end" : "middle")
            svg.append("<text x=\"\(f(x(i)))\" y=\"117\" text-anchor=\"\(anchor)\">\(Day.monthNamesShort[points[i].day.month - 1])</text>")
        }
        svg.append("</svg>")

        let lowest = points.min { $0.spendable < $1.spendable }!
        let highest = points.max { $0.spendable < $1.spendable }!
        func caption(_ word: String, _ p: PhoneSnapshot.TrendPoint) -> String {
            "\(word) <strong\(p.spendable.isNegative ? " class=\"neg\"" : "")>\(amount(p.spendable))</strong> in \(Day.monthNames[p.day.month - 1])"
        }
        return """
        <section class="card">
        <h2>Besteedbaar per maand</h2>
        \(svg.joined(separator: "\n"))
        <div class="sub cap">\(caption("Laagst", lowest))<br>\(caption("Hoogst", highest))</div>
        </section>
        """
    }

    static func accountsCard(_ accounts: [PhoneSnapshot.AccountLine]) -> String {
        var lines = ["<section class=\"card\">", "<h2>Rekeningen</h2>", "<div class=\"rows\">"]
        for account in accounts {
            lines.append(row(account.name, amount(account.balance)))
        }
        lines.append("</div>")
        lines.append("</section>")
        return lines.joined(separator: "\n")
    }

    static func potCards(_ snapshot: PhoneSnapshot) -> [String] {
        var cards: [String] = []
        for group in snapshot.potGroups where !group.pots.isEmpty {
            var lines = ["<section class=\"card\">",
                         "<h2>\(group.title)</h2>",
                         "<div class=\"mid\">\(amount(group.total))</div>",
                         "<div class=\"rows\">"]
            for pot in group.pots {
                lines.append(row(pot.name, amount(pot.balance), classes: "small"))
            }
            lines.append("</div>")
            lines.append("</section>")
            cards.append(lines.joined(separator: "\n"))
        }
        if !snapshot.unallocated.isZero {
            cards.append("""
            <section class="card">
            <div class="rows plain">
            \(row("Niet toegewezen op spaar", amount(snapshot.unallocated)))
            </div>
            </section>
            """)
        }
        return cards
    }

    static func yearMissingCard(_ snapshot: PhoneSnapshot) -> String {
        """
        <section class="hero">
        <div class="label">Nog te besteden deze maand</div>
        <div class="missing">Er is nog geen begroting voor \(snapshot.today.year).</div>
        <div class="sub">Maak het jaar aan in HomeFinance op je Mac, bij Instellingen › Jaar en posten. Daarna staan hier weer je cijfers.</div>
        </section>
        """
    }

    /// Regel met links een naam (van de gebruiker, wordt hier veilig gemaakt) en rechts een bedrag (al opgemaakt).
    static func row(_ label: String, _ value: String, classes: String = "") -> String {
        "<div class=\"row\(classes.isEmpty ? "" : " " + classes)\"><span class=\"name\">\(escape(label))</span><span class=\"amt\">\(value)</span></div>"
    }

    // MARK: Opmaak

    /// Eén accentkleur; rood alleen voor te laat en voor negatief besteedbaar.
    static let css = """
    :root{color-scheme:light dark;--bg:#f3f5f3;--card:#ffffff;--text:#17211d;--muted:#6a7671;--line:#e7ebe8;\
    --accent:#1f7a5c;--soft:#dcefe7;--red:#c0392b}
    @media (prefers-color-scheme:dark){:root{--bg:#0f1412;--card:#1a211e;--text:#f1f5f3;--muted:#98a49e;\
    --line:#2a3430;--accent:#4cc79a;--soft:#1f3a30;--red:#ff7a6b}}
    *{box-sizing:border-box}
    html{-webkit-text-size-adjust:100%}
    body{margin:0;background:var(--bg);color:var(--text);\
    font:17px/1.4 -apple-system,BlinkMacSystemFont,"SF Pro Text","Helvetica Neue",Helvetica,Arial,sans-serif;\
    font-variant-numeric:tabular-nums;-webkit-font-smoothing:antialiased}
    main{max-width:480px;margin:0 auto;padding:28px 20px 44px}
    header{margin-bottom:36px}
    .brand{color:var(--accent);font-size:15px;font-weight:700;letter-spacing:.02em}
    .stamp{margin-top:2px;font-size:15px;color:var(--muted)}
    .stamp strong{color:var(--text);font-weight:600}
    .hero{margin-bottom:36px}
    .label,h2{margin:0;font-size:15px;font-weight:600;color:var(--muted)}
    .big{margin:2px 0 4px;font-size:52px;font-size:min(52px,13.5vw);line-height:1.1;font-weight:700;\
    letter-spacing:-.02em;white-space:nowrap}
    .cents{font-size:.55em;font-weight:600;letter-spacing:0}
    .missing{margin:6px 0 8px;font-size:26px;line-height:1.25;font-weight:700}
    .sub{font-size:15px;color:var(--muted)}
    .sub strong{color:var(--text);font-weight:600}
    .now{margin-top:14px;font-size:17px;color:var(--muted)}
    .now strong{color:var(--text);font-weight:600}
    .now strong.neg{color:var(--red)}
    .fine{margin-top:10px;font-size:13px}
    .when{display:block;font-size:13px;color:var(--muted)}
    .notes{margin-top:18px;border-top:1px solid var(--line)}
    .card{background:var(--card);border-radius:18px;padding:20px;margin-bottom:16px}
    .mid{margin:4px 0 2px;font-size:28px;line-height:1.2;font-weight:700;letter-spacing:-.01em}
    .bar{display:block;margin:12px 0 8px}
    .track{fill:var(--soft)}
    .fill{fill:var(--accent)}
    .stats{display:flex;margin-top:10px}
    .stat{flex:1}
    .n{font-size:28px;line-height:1.2;font-weight:700}
    .rows{margin-top:14px;border-top:1px solid var(--line)}
    .rows.plain{margin-top:0;border-top:0}
    .row{display:flex;justify-content:space-between;align-items:baseline;gap:16px;padding:11px 0;\
    border-bottom:1px solid var(--line)}
    .rows .row:last-child,.notes .row:last-child{border-bottom:0;padding-bottom:0}
    .rows.plain .row{padding:0}
    .row.small{font-size:16px;padding:9px 0}
    .name{min-width:0;overflow-wrap:anywhere}
    .amt{white-space:nowrap;font-weight:600}
    .notes .row{font-size:15px}
    .notes .name{color:var(--muted)}
    .neg,.neg .name,.neg .amt,.sub strong.neg{color:var(--red)}
    .trend{display:block;height:auto;margin-top:14px}
    .area{fill:var(--soft)}
    .line{fill:none;stroke:var(--accent);stroke-width:2.5;stroke-linejoin:round;stroke-linecap:round}
    .zero{stroke:var(--line);stroke-width:1}
    .dot{fill:var(--accent)}
    .trend text{fill:var(--muted);font-size:12px}
    .cap{margin-top:10px}
    [hidden]{display:none!important}
    .pick{margin-top:18px;padding-top:14px;border-top:1px solid var(--line)}
    .pick label{display:block;font-size:15px;font-weight:600;color:var(--muted)}
    .pick input{display:block;width:100%;min-height:44px;margin:8px 0 10px;padding:10px 12px;font:inherit;\
    color:var(--text);background:var(--bg);border:1px solid var(--line);border-radius:12px;\
    -webkit-appearance:none;appearance:none}
    .pick input::-webkit-date-and-time-value{text-align:left}
    .pick-result .when{margin-bottom:2px}
    .months{margin-top:16px}
    .months summary{cursor:pointer;font-size:15px;font-weight:600;color:var(--accent)}
    .months .rows{margin-top:8px}
    footer{margin-top:28px;text-align:center;font-size:13px;color:var(--muted)}
    """
}
