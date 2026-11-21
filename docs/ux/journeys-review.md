# UX-review: routes en opbouw van de app

*21 november 2026. Spoor 2 van de UX-ronde. Spoor 1 (de namen van begrippen) staat in `begrippen-voorstel.md`.
Dit is een voorstel; er is niets gebouwd of gewijzigd.*

## In het kort

1. **De app is ingedeeld naar soort scherm, niet naar wat je komt doen.** De begroting zelf (posten) zit onder
   Instellingen, de vaste stortingen achter een knop op Potten, voorgeschoten geld (Tanken) heeft geen eigen plek.
   Wie een jaarbedrag wil opzetten, moet drie schermen kennen en de volgorde zelf bedenken.
2. **Er zijn twee plekken om nieuwe banktransacties te boeken, en twee betekenissen van "nakijken".** Transacties
   en Importeren en nakijken doen hetzelfde werk, met een ander aantal "zekere" (5 en 4 in de voorbeelddata).
3. **Openstaande zaken zijn versnipperd.** Uit een pot betaald, voorgeschoten, tijdelijk geleend en een
   overboeking die nog niet bij de bank gezien is: vier soorten "dit moet nog rechtgezet", op vier plekken.
4. **De verdeling over potten staat op twee plekken die niet aan elkaar vastzitten** (RES-regels in de begroting
   en de regels van de vaste storting). Dat is meer dan verwarrend: ze kunnen uit elkaar gaan lopen.

De grootste winst zit in drie stappen: één scherm "Nog rechtzetten", de begroting uit Instellingen halen, en een
hulpje "Nieuw jaarbedrag" dat pot, storting en post in één keer goed zet.

## Hoe ik heb gekeken

- Gelezen: `README.md`, de spec, `docs/voortgang.md`, `begrippen-voorstel.md` en alle schermen in
  `Sources/HomeFinance/Screens`.
- Bekeken: de negen schermafbeeldingen van `--snapshot` (licht en donker) en `telefoon.html`, met voorbeelddata.
- Voorbeelddata nagekeken in een tijdelijk bestand (`--voorbeeld --database <tijdelijk> --kerncijfers`).
- De echte administratie is niet geopend of gelezen.

**Beperkingen, eerlijk gezegd:**

- Ik heb de routes **niet met de muis doorgeklikt**. De schermafbeeldingen tonen alleen de eerste aanblik van elk
  scherm. Wat achter een klik zit (potdetail, vooruitblik, vaste stortingen, celvenster in het grid, de
  verrekenvensters) heb ik beoordeeld op de schermcode en de teksten. Opmaak en gevoel van die onderdelen kan ik
  dus niet beoordelen; de stappen en teksten wel.
- `--snapshot --size 1100x700` geeft in deze stand van de code dezelfde afbeelding als zonder (2880 × 1800). Het
  smalle venster is dus niet bekeken. Los puntje voor de bouwsessie; zie "Zijdelings gevonden".

Ernst: **blokkerend** = een nieuwe gebruiker komt er zonder uitleg niet uit of doet het fout zonder het te
merken. **Verwarrend** = het lukt, maar met twijfel of een omweg. **Klein** = schoonheidsfout.

---

## Route 1 — Eerste keer rondkijken: wat is er te besteden?

**Wat ik zie.** Het welkomstscherm is helder (rondkijken of beginnen). Daarna opent **Transacties**: twee
saldokaarten, een regel uitleg over downloaden bij de bank, een blauwe balk "17 nieuwe transacties · Boek de 5
zekere" en een balk "€ 144,42 Tanken nog terug te storten". Het antwoord op "wat is er te besteden" staat op
**Dashboard**, het derde item in de zijbalk.

| Ernst | Knelpunt |
|---|---|
| Verwarrend | **Je landt op een werklijst, niet op het antwoord.** Als nieuwe gebruiker zie ik saldi en taken, maar niet "wat kan ik uitgeven". Dat staat twee klikken verder. De keuze voor Transacties als start ("als een bank-app") is logisch voor wie dagelijks werkt, niet voor wie rondkijkt. |
| Verwarrend | **Twee getallen, het grote is hoger dan het kleine.** "Nog te besteden deze maand € 10.143" en daaronder "Besteedbaar nu € 6.648". Dat je eind van de maand méér hebt dan nu (het salaris moet nog komen) snap je pas na "Hoe is dit opgebouwd?". Eén zin erbij ("er komt deze maand nog € … binnen en gaat nog € … af") lost dat op. |
| Verwarrend | **Het grote getal klopt nog niet, en dat staat er niet bij.** Er wachten 19 banktransacties. Zolang die niet geboekt zijn, tellen ze niet mee in het saldo. Het blok Aandacht meldt ze wel, maar legt geen verband met het getal ernaast. |
| Verwarrend | **De uitleg van begrippen zit in tooltips.** Anti-rood, divers, vaste post, pot: alles is goed uitgelegd, maar alleen als je de muis erboven houdt. Een nieuwe gebruiker weet niet dat daar iets staat. |
| Klein | De voorbeelddata speelt in juni 2027, terwijl het nu november 2026 is. De balk bovenaan zegt wel "verzonnen", niet "en het is hier juni 2027". |
| Klein | Zijbalk: bij Transacties staat "6", bij Importeren en nakijken "19". Het ene telt "nog nakijken", het andere "nog boeken". Dat zie je nergens. |

**Goed zoals het is:** de balk "Je bekijkt voorbeelddata", het ene grote getal, het uitklapbare "Hoe is dit
opgebouwd?", het rustige Dashboard.

## Route 2 — Bankbestand importeren en nakijken

**Wat ik zie.** Importeren en nakijken heeft een lijst links (Na te kijken 13, Zeker 4) en rechts het voorstel:
"Waar hoort dit bij?", tags, "Verrekenen met spaar: Nee", "Telt mee in", "Onthoud als regel", "Meer opties".
Rechtsboven wissel je tussen betaalrekening (17) en spaarrekening (2).

| Ernst | Knelpunt |
|---|---|
| Blokkerend | **Twee plekken voor hetzelfde werk.** Nieuwe banktransacties staan én in Transacties ("Boek de 5 zekere", "Kies post…") én in Importeren en nakijken ("Boek de 4 zekere"). De aantallen verschillen. Ik weet niet waar ik hoor te beginnen, en of boeken op de ene plek hetzelfde doet als op de andere (in Transacties kun je bijvoorbeeld geen regel laten onthouden). |
| Blokkerend | **"Nakijken" betekent twee dingen.** In het schermnaam: nieuwe banktransacties een plek geven. In Transacties en op het Dashboard: achteraf controleren wat automatisch is geboekt. Op het Dashboard staan ze onder elkaar: "19 moeten nog geboekt worden → Boeken" (gaat naar het scherm dat *Nakijken* heet) en "6 moeten nog nagekeken worden → Nakijken" (gaat naar *Transacties*). |
| Verwarrend | **De spaarkant zie je alleen als je zelf wisselt.** De losse overboeking van € 250 staat aan de betaalkant als "Maandelijkse reserveringen · ander bedrag"; de andere helft ("Extra voor de vakantie") staat achter de knop Spaarrekening. Eén overboeking, twee keer nakijken, op twee tabbladen, zonder dat de app zegt "dit hoort bij elkaar". Er bestaat een melding "overboekingen tussen je eigen rekeningen gevonden · Koppel alle", maar die helpt alleen als het voorstel al goed is. |
| Verwarrend | **Losse overboeking naar spaar: het label helpt niet.** "… · ander bedrag" zegt wat er mis is, niet wat ik moet doen. De keuze "Niet de vaste storting: één pot kiezen" staat pas in het paneel rechts. De tekst "Losse overboeking? Kies pot" bestaat al, maar alleen als het bedrag héél anders is. |
| Verwarrend | **Zakgeld naar een kind: in de lijst zie je de pot niet.** Het voorstel (regel "Kind 1 Voorbeeld": verrekenen met de zakgeldpot) toont in de lijst alleen "Divers". Dat er iets uit een pot komt, zie je pas na aanklikken. Bij geld dat terugkomt van hetzelfde kind krijg je een twijfelgeval zonder dat de lijst zegt waarom. |
| Verwarrend | **Een betaling uit een pot: het woord zegt niet wat het gevolg is.** "Verrekenen met spaar: Nee/Ja + pot" staat goed in beeld. Maar wat gebeurt er daarna? Nergens in dit scherm staat "je moet dit bedrag later zelf overmaken, dat doe je bij …". Na het boeken verschijnt wel een korte melding met het openstaande saldo. |
| Verwarrend | **De terugstorting van voorgeschoten geld wordt hier niet herkend.** "Declaratie brandstof + € 144,42" krijgt het voorstel "Divers". Dat dit precies het openstaande bedrag van Tanken is, zegt de app pas in Transacties, via "Verrekenen…" of rechtsklik. In Nakijken boek je hem dus argeloos weg. |
| Verwarrend | **"Onthoud als regel" tegenover "Regel bijwerken met deze keuze".** Goed dat het een vinkje is en standaard uit staat. De samenvattingszin ("Voortaan bij X: …") is sterk. Twijfel: het vinkje verschijnt alleen als er geen regel was; bij een afwijkend voorstel heet het anders en staat het lager. Dat is logisch, maar voelt als twee functies. |
| Klein | Onderaan: "saldo controleren kan zodra alles geboekt is". Goed, maar het is grijs en klein, terwijl dit de eindcontrole van de hele route is. Na de laatste boeking hoort hier een duidelijke afsluiting: "Klaar: saldo klopt met de bank (€ …)". |
| Klein | "Sla over" staat even groot naast "Boek". Overslaan haalt een transactie uit het saldo; dat is een zeldzame, riskante keuze en mag kleiner. |

**Goed zoals het is:** slepen van de zip, de voorvertoning met saldoketen en dubbelen, "Zeker betekent: …" boven
de lijst, twijfelgevallen eerst, één toets om te boeken, "Maak ongedaan" na elke actie, "Waarom dit voorstel?".

## Route 3 — De maand volgen in het maandgrid

**Wat ik zie.** Het grid lijkt op het Excel-jaarblad: posten als rijen, maanden als kolommen, de lopende maand
gemarkeerd. Kleuren: rood getint = te laat, oranje getint = ander bedrag, grijs puntje = nog verwacht, schuin
grijs = toekomst. De uitleg zit achter het ⓘ-knopje. Klik op een cel opent een venstertje met de boekingen en
"Voldaan (afvinken)".

| Ernst | Knelpunt |
|---|---|
| Verwarrend | **"Te laat" terwijl het geld al van de rekening is.** Energie, Water en Internet staan in juni rood. Tegelijk wachten precies die betalingen in Nakijken. Het grid weet dat niet te melden. Een nieuwe gebruiker denkt: niet betaald, of gaat afvinken (en dan staat de post straks dubbel voldaan: afgevinkt én geboekt). Het celvenster zou moeten zeggen: "Er wacht een banktransactie van € 185,00 die hierbij past → boek hem". |
| Verwarrend | **De status zit alleen in kleur en een puntje.** De legenda staat achter ⓘ. Zonder die te openen weet je niet wat rood, oranje en het puntje betekenen. Een vaste, korte legenda onder het grid (één regel) kost weinig ruimte. |
| Verwarrend | **Afvinken is niet te vinden zonder te klikken.** Er is geen vinkje in beeld; je moet weten dat je op een cel klikt, of rechtsklikt. De tekst op het Dashboard ("vink hem af in het maandgrid") stuurt je erheen, maar daar zie je niet waar. |
| Verwarrend | **Geen samenvatting van de maand.** "5 van 15 voldaan · 3 te laat · 7 open" staat op het Dashboard, niet boven het grid. In het grid moet je zelf de kolom aflopen. |
| Verwarrend | **RESERVERINGEN in hoofdletters met een pijltje.** Uitklappen toont "RES-regels" die niet meetellen. Voor wie de Excel niet kent is dit het moeilijkste stuk van het scherm: één regel die eigenlijk "naar spaar" betekent, met daaronder regels waar niets op geboekt wordt. Zie ook route 4. |
| Verwarrend | **Uitgaven uit een pot tellen hier als UIT divers.** Een jaarrekening die een pot betaalt, staat in het grid als diverse uitgave, en de latere overboeking van spaar als IN divers. Per saldo klopt het, maar "UIT divers" en "x % van plan" op het Dashboard zijn die maand hoger dan je verwacht. Een regel "waarvan uit potten" zou dat verklaren. |
| Klein | "Ruimte t.o.v. maandbudget" is een afkorting met een boekhoudklank. (Naam: spoor 1.) |
| Klein | De leesbaarheid van de schuine grijze bedragen is al genoemd in de voortgang. |

**Goed zoals het is:** het grid zelf. Het is het vertrouwde jaarblad en compact mag hier. Ook goed: klik op een
cel voor de boekingen, "telt in dec", dubbelklik om toe te voegen.

## Route 4 — Een nieuw jaarbedrag opzetten

Dit is de route waar een nieuwe gebruiker het meest vastloopt. Wat er nu nodig is, in de goede volgorde:

1. **Potten en sparen › Nieuwe pot…** (soort reservering).
2. **Potten en sparen › Vaste stortingen** (knop rechtsboven) › de storting openen › "Pot toevoegen" › jaarbedrag
   gedeeld door 12 invullen › bewaren. Het plan van de post RESERVERINGEN volgt vanzelf.
3. *Eventueel* **Instellingen › Jaar en posten › Reserveringen**: een RES-regel toevoegen en "Vult pot" kiezen,
   anders klopt de uitgeklapte opbouw in het maandgrid niet meer.
4. Als de rekening komt: in **Nakijken** de betaling op "Verrekenen met spaar → uit pot" zetten, en "Onthoud als
   regel" aanvinken.
5. Later bij **Verrekenen met spaar** het saldo overmaken en afvinken.
6. *Eventueel* in de pot een **verwachting** zetten voor de jaarbetaling, zodat de vooruitblik de dip toont.

| Ernst | Knelpunt |
|---|---|
| Blokkerend | **Niets vertelt je dat dit de stappen zijn.** Het lege scherm van Potten zegt "maak een pot voor elk doel", het lege scherm van Vaste stortingen zegt "maak een storting". De volgorde en het verband moet je zelf bedenken. Een pot zonder regel in een vaste storting krijgt nooit geld, en dat merk je pas maanden later. |
| Blokkerend | **De verdeling staat op twee plekken die niet aan elkaar vastzitten.** In de voorbeelddata staan dezelfde 28 bedragen als RES-regels in de begroting én als regels van de vaste storting. Het *plan* van RESERVERINGEN volgt de vaste storting; de *uitgeklapte opbouw* in het maandgrid toont de RES-regels. Voeg je een pot toe aan de storting, dan verandert het totaal, maar de RES-regels niet. De tooltip in het grid zegt nog "het plan is de som van de RES-regels", Instellingen zegt "het planbedrag volgt de vaste storting". Voor een nieuwe gebruiker is niet te zien welke van de twee waar is. |
| Verwarrend | **"Vaste stortingen" is een knop, geen plek.** Het is het hart van het spaarsysteem, maar staat als tweede knop rechtsboven op Potten. Vanuit de zijbalk is het onvindbaar. |
| Verwarrend | **De post staat onder Instellingen.** "Jaar en posten" is de begroting zelf. Onder een tandwiel verwacht je voorkeuren, geen begroting. |
| Verwarrend | **Je moet zelf door 12 delen.** Het bedragveld accepteert een som (`504/12`), dat is fijn maar onzichtbaar. De app vraagt nergens "hoeveel per jaar, en wanneer komt de rekening". |
| Verwarrend | **Jaarpost of pot?** Een post kan ook "per jaar" zijn (met verwachte maand). Voor een jaarlijkse rekening zijn er dus twee manieren: een jaarpost op de betaalrekening, of maandelijks reserveren in een pot. De app legt het verschil nergens uit. Wie beide doet, telt de uitgave dubbel in zijn hoofd. |
| Verwarrend | **De jaarbetaling zelf heeft geen plek in de begroting.** Hij wordt "Divers + verrekenen met spaar". Dat is juist, maar voelt fout: je hebt er net een pot voor gemaakt en nu is het "divers". |
| Klein | Het potdetail toont wel "Per maand" en "uit de vaste storting X", maar niet de post waar het op de betaalrekening onder valt. |

**Goed zoals het is:** het idee van één vaste storting met een verdeling; dat het plan van de post vanzelf volgt;
"Dit bedrag volgt uit je vaste stortingen. Je wijzigt het daar." in het potvenster; verwachtingen en projecten in
de vooruitblik.

## Route 5 — Voorgeschoten geld terugkrijgen, en iets uit een pot betalen

Twee dingen die op elkaar lijken ("later komt er geld terug op de betaalrekening") maar heel anders in de app
zitten.

| | Voorgeschoten (tag, bv. Tanken) | Uit een pot (verrekenen met spaar) |
|---|---|---|
| Aanzetten | Instellingen › Tags › schakelaar "Verrekenen" | Per boeking: "Verrekenen met spaar" + pot |
| Markeren | Tag op de boeking | Keuzelijst op de boeking |
| Overzicht van wat openstaat | Balk op Transacties, regel op Dashboard, Instellingen › Tags | Eigen scherm in de zijbalk |
| Afronden | Venster via "Verrekenen…" of rechtsklik op de bijschrijving | Scherm Verrekenen met spaar, of "Afvinken en aanhangen" in Nakijken |
| Telt mee in besteedbaar | Alleen met "telt mee in nog te besteden" aan | Altijd |

| Ernst | Knelpunt |
|---|---|
| Blokkerend | **Voorgeschoten geld heeft geen eigen plek.** Het hele proces loopt via een balk, een rechtsklikmenu en een tabblad van Instellingen. Wie de balk niet ziet (hij verdwijnt bij nul) weet niet dat de functie bestaat. Een eerdere verrekening terugvinden kan alleen door het venster opnieuw te openen. |
| Verwarrend | **Hetzelfde woord, andere handeling.** (Naam: spoor 1.) Voor de route betekent het: "Verrekenen…" op Transacties opent iets heel anders dan "Verrekenen met spaar" in de zijbalk. |
| Verwarrend | **"Nog terug te storten" leest alsof jíj moet betalen.** Het is geld dat je terugkrijgt. (Naam: spoor 1.) |
| Verwarrend | **Het scherm Verrekenen met spaar spreekt zichzelf tegen.** Bovenaan een kaart "Vastgelegd op 13 jun, nog niet verrekend · € 535,12" en direct daaronder groot "Er staat niets open". Beide kloppen (er zijn geen *nieuwe* boekingen), maar zo lees je het niet. |
| Verwarrend | **Twee manieren om dezelfde verrekening af te ronden.** Op het scherm: "Zet op verrekend". In Nakijken bij de bankregel: "Afvinken en aanhangen". Wie het eerste doet en daarna importeert, ziet de bankregel nog eens langskomen, nu als "aanhangen". Dat is veilig gebouwd, maar het voelt als dubbel werk. |
| Verwarrend | **De volgorde "eerst overmaken, dan afvinken" staat klein.** De knop heet "Ik heb dit overgemaakt" (goed!), maar het bedrag en de richting ("Maak over van spaar naar betaal") mogen de kop van het scherm zijn: dat is de ene handeling die je in je bank-app moet doen. |
| Verwarrend | **Bij een boeking zie je niet waar hij in het proces zit.** Op de regel staat "uit Kleding" en in het detail "Zit in de verrekening van 13 jun (nog niet gedaan)". Er is geen vaste plek die zegt: betaald → wacht op overboeking → overgemaakt → gezien bij de bank. |
| Klein | "Toch niet…" als knopnaam voor het weggooien van een vastgelegde verrekening is onduidelijk zonder de tooltip. |
| Klein | Tijdelijk geleend van spaar is een derde soort "staat nog open", met de uitleg op Instellingen › Jaar en posten en het vinkje onder "Meer opties". |

**Goed zoals het is:** dat afvinken meteen boekt en de bankregel er later vanzelf aan hangt; de melding na 5
dagen; netto één bedrag over alle potten; het saldo per pot "erna"; het startbedrag bij een tag.

## Route 6 — Een kind laten zien wat er in zijn potjes zit

**Wat ik zie.** Op de Mac: Potten en sparen, groep Sparen, gegroepeerd per eigenaar. Op de telefoon: een kaart
per kind met het totaal en de drie potjes.

| Ernst | Knelpunt |
|---|---|
| Verwarrend | **Op de Mac laat je het kind alles zien.** Het scherm opent met het saldo van de spaarrekening en 21 reserveringen; de potjes van het kind staan daaronder, na scrollen. Er is geen "alleen Kind 1". |
| Verwarrend | **Op de telefoon ook.** De pagina is er één voor het hele gezin: bovenaan "Nog te besteden deze maand € 10.143", daaronder Tanken, dan pas de kinderen, daarna alle rekeningen en potten. Voor een kind staat er veel dat niet voor hem bedoeld is. Het kan per onderdeel uit, maar dan mist de ouder het weer. |
| Verwarrend | **De instelling zit ver weg van de pot.** Of een kind op de telefoon komt, hangt af van het veld "Eigenaar" in het potvenster (vrije tekst) en een vinkje bij Instellingen › Telefoon. Een typfout in de eigenaar geeft een tweede "kind". |
| Verwarrend | **Het kind ziet een stand, geen verhaal.** Er staat "Zakgeld € 35,00", niet "+ € 7,50 op 13 juni" of "nog € 1.135 tot je doel". De spaardoelen van de kinderen (beiden € 2.500) staan niet op de telefoonkaart. |
| Klein | In de voorbeeldmodus zijn de knoppen van Telefoon grijs; "Bekijk voorbeeld" werkt wel. De README stuurt je naar "kies een map", wat in de voorbeeldmodus juist niet kan. |

**Goed zoals het is:** groeperen per eigenaar; geen hosting, alleen een bestand; de kaart per kind met een totaal.

## Route 7 — Een spaardoel volgen met de vooruitblik

**Wat ik zie (in de code en teksten).** In het potdetail: status ("op koers", "€ x per maand te weinig"), "Nodig
per maand", "Je stort nu per maand", "Doel gehaald op", een grafiek met een doorgetrokken en een gestippelde
lijn, een schuif "Stand op … / n mnd", losse verwachtingen, projecten, en "Elke maand uit je vaste stortingen".

| Ernst | Knelpunt |
|---|---|
| Verwarrend | **De vooruitblik zit drie lagen diep.** Potten › groep Sparen › pot aanklikken › in het paneel naar beneden. Vanaf Dashboard of zijbalk is er geen ingang; de voortgang van doelen staat nergens op de eerste aanblik behalve als balkje in de potrij. |
| Verwarrend | **Spaardoel, verwachting, project, onderdeel: vier begrippen in één paneel.** Een doel kan "uit onderdelen" bestaan (lessen, examens), een verwachting kan bij een "project" horen. Beide zijn een lijstje bedragen bij een pot; het verschil (onderdelen bepalen het doelbedrag, verwachtingen de lijn) moet je uit de tooltips halen. |
| Verwarrend | **"Te weinig per maand" heeft geen vervolgstap.** De app zegt "je stort € 40 per maand te weinig" en biedt "Vaste stortingen…". Daar moet je zelf de goede regel zoeken en het bedrag uitrekenen. "Verhoog naar € … per maand" zou de route afmaken. |
| Verwarrend | **Verwachtingen "over tijd" verdwijnen uit de lijn.** Een verwachting waarvan de datum voorbij is en die niet is afgevinkt, telt niet meer mee. Dat staat er wel, maar een verwachte grote uitgave die een week later komt, laat de lijn dus even te mooi zien. |
| Klein | De telefoon toont voor de gezamenlijke pot 3, 6 en 12 maanden en een eigen datum; op de Mac heet hetzelfde "Stand op" met een schuif in maanden. Zelfde berekening, andere bediening. |

**Goed zoals het is:** "Verwachtingen tellen nergens in mee" (staat er meerdere keren, terecht); het laagste punt
("rond … komt deze pot op …"); afvinken van een verwachting koppelt de boeking; de status in één woord.

---

## Voorstel voor de opbouw

### 1. De zijbalk indelen naar wat je komt doen

Nu: *Overzicht* (Transacties, Importeren en nakijken, Dashboard, Maandgrid) · *Spaarrekening* (Potten en sparen,
Verrekenen met spaar) · *Inzicht* (Rapporten, Regels) · Instellingen.

Wat schuurt: "Overzicht" bevat een werkscherm; Regels is geen inzicht maar inrichting; de begroting en de vaste
stortingen staan er niet in; voorgeschoten geld ook niet.

Voorstel (schermnamen zijn werknamen; de definitieve woorden komen uit spoor 1):

| Groep | Schermen | Verandert er iets? |
|---|---|---|
| **Vandaag** | Dashboard · Nog rechtzetten *(nieuw, met teller)* | Dashboard bovenaan. Nog rechtzetten vervangt "Verrekenen met spaar". |
| **Bijwerken** | Importeren en nakijken · Transacties | Zelfde schermen, andere groep. |
| **Begroting** | Maandgrid · Posten *(nu Instellingen › Jaar en posten)* | Posten komt uit Instellingen. |
| **Sparen** | Potten · Vaste stortingen *(nu een knop op Potten)* | Vaste stortingen krijgt een eigen regel. |
| **Inzicht** | Rapporten | Regels eruit. |
| *(onderaan)* | Instellingen: Rekeningen, Regels, Tags, Back-up, Telefoon, Over | "Jaar en posten" eruit, Regels erin. Jaar aanmaken en afsluiten blijven bij Posten. |

Het startscherm hoeft niet te veranderen voor wie dagelijks werkt. Wel: in de voorbeeldmodus en bij de allereerste
start op het Dashboard openen, en bovenaan Transacties één regel "Nog te besteden deze maand: € …" met een klik
naar het Dashboard.

### 2. Eén scherm "Nog rechtzetten"

Alles wat nog een handeling van jou buiten de app vraagt, of nog terug moet komen, op één plek, in vier blokken
met dezelfde opzet (bedrag · wat moet ik doen · knop):

1. **Uit potten betaald** — "Maak € … over van spaar naar betaal" → *Ik heb dit overgemaakt*.
2. **Voorgeschoten** (per tag) — "Je krijgt nog € … terug (Tanken)" → *Het is binnen…*
3. **Tijdelijk geleend van spaar** — "Er staat nog € … uit" → *naar de boekingen*.
4. **Wacht op de bank** — verrekeningen die zijn afgevinkt maar nog niet in een bankbestand gezien.

De zijbalk toont het aantal open blokken. De rekenregels blijven zoals ze zijn; dit is alleen een andere plek en
indeling. Het bestaande scherm Verrekenen met spaar wordt blok 1 en 4, het bestaande tagvenster wordt blok 2.

### 3. De keten "post ↔ vaste storting ↔ pot" in één oogopslag

De koppelingen bestaan al, maar staan in tooltips en uitgeklapte rijen, en steeds maar één stap ver. Voorstel:
**één vaste strook van drie blokjes**, overal dezelfde, met het blokje waar je nu bent gemarkeerd en de andere
twee aanklikbaar:

```
┌ Betaalrekening ────────┐     ┌ Vaste storting ─────────┐     ┌ Spaarrekening ─────────┐
│ Post RESERVERINGEN     │ ──▶ │ Maandelijkse            │ ──▶ │ Pot Wegenbelasting     │
│ € 1.593,50 per maand   │     │ reserveringen · 28 potten│     │ € 42,00 per maand      │
└────────────────────────┘     └─────────────────────────┘     └────────────────────────┘
```

Waar hij komt te staan:

- **Potdetail**, boven de mutaties (nu: "Per maand" met een tooltip).
- **Vaste storting**, boven de verdeling (nu: "Hoort bij post" onderaan).
- **Posten**, in de opengeklapte post (nu: één zin met een knop).
- **Maandgrid**, in het celvenster van RESERVERINGEN (nu: tooltip bij aanwijzen).

Dit is hetzelfde idee als "aan beide kanten één zin" uit spoor 1, maar als vast beeld. Een kanttekening bij
spoor 1: het potdetail en de post tonen de vaste storting nu al; wat ontbreekt is de derde schakel en de
zichtbaarheid zonder aanwijzen.

**En maak er één bron van.** De RES-regels in de begroting en de regels van de vaste storting beschrijven
hetzelfde. Laat de uitgeklapte opbouw van RESERVERINGEN (grid en Posten) de regels van de gekoppelde vaste storting
tonen, alleen-lezen, met "wijzigen bij Vaste stortingen". Dan kan het niet meer uit elkaar lopen en verdwijnt het
woord "RES-regel" uit beeld. *Aanname:* een RES-regel heeft geen andere functie meer dan tonen; dat volgt uit de
spec ("vervangt … de RES-regels als bron van de verdeling"), maar een developer moet het bevestigen voordat de
groep verdwijnt. De bestaande rijen in de database blijven staan.

### 4. De keten "boeking ↔ verrekening" in één oogopslag

Bij elke boeking die nog iets tegoed heeft, in het detail en als tooltip op het label in de lijst, **één
voortgangsregel** met vaste stappen:

- Uit een pot: `Betaald van betaal ✓ → Nog overmaken van spaar (in € 535,12) → Overgemaakt → Gezien bij de bank`
- Voorgeschoten: `Voorgeschoten ✓ → Nog terug te krijgen (in € 144,42 Tanken) → Teruggekregen`

De stap waar de boeking nu staat is vet en is een knop naar het juiste blok van "Nog rechtzetten". In de lijst
van Nakijken krijgt een voorstel met een pot het label "post · uit pot X" in plaats van alleen de post.

### 5. Importeren en nakijken wordt de enige plek om te boeken

- **Importeren en nakijken**: nieuwe banktransacties een plek geven. Hier, en alleen hier, staan "Boek de zekere"
  en "Onthoud als regel".
- **Transacties**: alles wat geboekt is, zoeken en wijzigen. Nieuwe transacties blijven zichtbaar (met het blauwe
  puntje), maar de balk zegt "17 nieuwe transacties → Naar nakijken" in plaats van zelf te boeken.
- De controle achteraf ("automatisch geboekt, nog niet door jou gecontroleerd") krijgt een ander woord dan
  "nakijken" (spoor 1), en de knop op het Dashboard dus ook.
- In Nakijken staan beide rekeningen in één lijst met een kopje per rekening, of op zijn minst toont een
  overboeking tussen eigen rekeningen zijn andere helft in het paneel rechts ("de andere kant: + € 250,00 op
  Spaarrekening, 11 jun → pot kiezen").

*Afweging:* de gebruiker boekt nu soms vanuit Transacties. Als dat een bewuste, prettige werkwijze is, is de
lichtere variant: laat het in Transacties staan, maar maak de aantallen gelijk en bied daar hetzelfde "Onthoud als
regel". De keuze is aan de gebruiker.

### 6. Hulpje "Nieuw jaarbedrag"

Eén venster, te openen vanaf Potten ("Nieuwe pot…" krijgt de vraag "waarvoor?") en vanaf Posten:

1. Naam (bv. Wegenbelasting).
2. Hoeveel per jaar, en in welke maand komt de rekening? De app toont "dat is € 42,00 per maand".
3. Bij welke vaste storting? (Eén storting: al gekozen.)
4. Samenvatting met de strook van drie blokjes: "Pot Wegenbelasting wordt gemaakt · € 42,00 per maand erbij in
   Maandelijkse reserveringen (wordt € 1.635,50) · het plan van de post RESERVERINGEN volgt."
5. Vinkje: "Zet de jaarbetaling als verwachting in de pot (− € 504,00 in maart)".
6. Na afloop één zin: "Komt de rekening, kies dan bij het nakijken *uit pot Wegenbelasting* en laat het onthouden."

Het hulpje doet niets wat nu niet kan; het doet de bestaande stappen in de goede volgorde.

### 7. Tabbladen

- **Instellingen** (na het verplaatsen): Rekeningen · Regels · Tags · Back-up · Telefoon · Over. Dat zijn dan
  allemaal echte instellingen. Afstemmen blijft bij Rekeningen, maar krijgt een ingang aan het eind van Nakijken.
- **Rapporten** (zeven tabbladen): de indeling is goed; "Categorieën" tegenover "Tags" is al genoemd in de
  voortgang. "Besteedbaar" als rapport en "Verloop van het jaar" op het Dashboard overlappen; één van de twee kan
  een link naar de ander worden.
- **Importeren en nakijken**: de wissel per rekening rechtsboven is geen tabblad maar een filter; zie punt 5.

---

## Top 10 verbeteringen

Elk los te bouwen. Omvang: klein = een paar uur, alleen teksten of weergave; middel = één scherm of onderdeel
met tests; groot = meerdere schermen. Het zijn inschattingen als bandbreedte, geen toezegging; een developer
reviewt het resultaat voor het in gebruik gaat. Geen van deze stappen verandert een rekenregel.

| # | Verbetering | Lost op (route) | Omvang | Grootste risico |
|---|---|---|---|---|
| 1 | **Zijbalk opnieuw indelen**: groepen Vandaag / Bijwerken / Begroting / Sparen / Inzicht; Posten uit Instellingen, Vaste stortingen als eigen regel, Regels naar Instellingen. Schermen zelf blijven gelijk. | 1, 4 | Middel | Links tussen schermen ("Naar Instellingen", "Naar Vaste stortingen") en de zelftest moeten mee. De lege zijbalk van 20 november maakt dit een plek om extra voorzichtig te testen in de echte app. |
| 2 | **Scherm "Nog rechtzetten"** met vier blokken (uit potten, voorgeschoten, tijdelijk geleend, wacht op de bank) en een teller in de zijbalk. | 5 | Groot | Het tagvenster en het verrekenscherm samenbrengen zonder gedrag te wijzigen. In twee stappen te bouwen: eerst blok 2 als eigen plek, dan samenvoegen. |
| 3 | **Eén plek om te boeken**: Transacties verwijst nieuwe transacties door naar Nakijken (of, lichte variant: gelijke aantallen en "Onthoud als regel" op beide). Ander woord voor de controle achteraf. | 2 | Middel | Raakt de dagelijkse werkwijze van de gebruiker; eerst kiezen welke variant. |
| 4 | **Ketenstrook post → vaste storting → pot** op vier plekken (potdetail, vaste storting, post, celvenster grid). | 4, 7 | Middel | Meer dan één vaste storting of een pot in twee stortingen: de strook moet dan een lijstje worden. |
| 5 | **Eén bron voor de verdeling**: de opbouw van RESERVERINGEN toont de regels van de vaste storting; de groep RES-regels wordt alleen-lezen of verdwijnt uit beeld. | 3, 4 | Middel | De aanname dat RES-regels nergens anders voor nodig zijn (rapporten, export naar Excel, jaar kopiëren). Eerst nagaan. Geen migratie die bestaande rijen wijzigt. |
| 6 | **Hulpje "Nieuw jaarbedrag"** (pot + regel in de vaste storting + optioneel een verwachting). | 4 | Middel | Bestaat er nog geen vaste storting of geen post RESERVERINGEN, dan moet het hulpje die eerst (laten) maken. |
| 7 | **Voortgangsregel bij een boeking** (uit pot / voorgeschoten) en het label "post · uit pot X" in de lijst van Nakijken. | 2, 5 | Klein tot middel | Smal venster: het label wordt langer. |
| 8 | **Nakijken herkent meer in de lijst**: de terugstorting van een tag ("Is dit je € 144,42 van Tanken?"), de andere helft van een eigen overboeking in het paneel, en "Losse overboeking? Kies pot" ook bij een kleiner verschil. | 2, 5 | Middel | De tagherkenning bestaat al voor het venster in Transacties; hergebruiken, niet opnieuw bedenken. |
| 9 | **Maandgrid: status in woorden en een hint bij "te laat"**: vaste legenda van één regel onder het grid, "5 van 15 voldaan · 3 te laat" erboven, en in het celvenster "er wacht een banktransactie die hierbij past → boek hem". | 3 | Klein tot middel | De hint vraagt een zoekactie in de wachtrij per cel; alleen bij openen van het venster doen. |
| 10 | **Dashboard en eerste aanblik**: één zin onder het grote getal ("nu € … vrij; er komt nog € … binnen en gaat nog € … af"), een waarschuwing bij het getal zolang er transacties wachten, en in de voorbeeldmodus op het Dashboard starten met een regel "het is hier juni 2027". | 1 | Klein | Geen. |

Net buiten de top 10, wel de moeite waard:

- **Telefoon per persoon**: een tweede pagina per kind (alleen zijn potjes, met de laatste mutaties en het
  spaardoel), naast de gezinspagina. Middel. Lost route 6 op.
- **"Verhoog naar € … per maand"** bij een spaardoel dat niet op koers ligt. Klein tot middel.
- **Regel "waarvan uit potten"** in het maandgrid en bij "deze maand uitgegeven". Middel; alleen tonen, de
  totalen blijven gelijk.
- **Uitleg zichtbaar zonder aanwijzen**: bij de eerste keer dat een begrip op een scherm staat een grijze zin
  eronder in plaats van een tooltip. Klein per scherm; meenemen met de naamsronde van spoor 1.

**Voorgestelde volgorde:** 10, 9 en 7 (klein, direct merkbaar) → 5 (haalt een bron van fouten weg) → 4 en 6
(maken route 4 begaanbaar) → 1 → 3 → 8 → 2. De naamswijzigingen van spoor 1 kunnen het best samen met stap 1
landen, zodat de gebruiker één keer moet wennen.

---

## Wat ik bewust niet zou veranderen

- **Het maandgrid als compact jaarblad.** Het is het enige drukke scherm en dat hoort zo; het is de brug met de
  Excel. Alleen de leeshulp eromheen verbeteren.
- **Regels alleen met toestemming** ("Onthoud als regel" standaard uit, de samenvattingszin, "Regel bijwerken met
  deze keuze"). Dit is beter dan wat de meeste bank-apps doen.
- **Afvinken van een verrekening boekt meteen, de bankregel hangt er later aan.** De volgorde is goed; alleen de
  uitleg en de plek kunnen beter.
- **De importvoorvertoning**: saldoketen, dubbelen, aansluiting op het beginsaldo, "geen regel verdwijnt stil".
- **"Maak ongedaan" na elke actie in Nakijken**, ook voor een bewaarde regel.
- **Eén groot getal op het Dashboard** met de opbouw achter een klik, en het blok Aandacht.
- **De voorbeeldmodus** met de vaste balk bovenaan en de strikte scheiding van de eigen administratie.
- **Geen hosting voor de telefoon**: een bestand in een eigen cloudmap. Simpel en veilig.
- **De rekenregels en het datamodel.** Alles hierboven is indeling, weergave en tekst. Besteedbaar, de potsaldi
  en het grid rekenen na deze voorstellen precies hetzelfde; de testronde met kerncijfers moet dat na elke stap
  laten zien ("geen verschillen").
- **De zin "Verwachtingen tellen nergens in mee".** Hij staat er vaak, en dat is goed.

## Zijdelings gevonden (geen UX, wel melden)

- `--snapshot --size 1100x700` wordt in de huidige code genegeerd: de afbeelding is 2880 × 1800, gelijk aan die
  zonder `--size`. De README en de opdracht voor deze ronde noemen de optie wel. Waarschijnlijk hoort dit bij wat
  na het terugzetten naar 16 november nog opnieuw gebouwd wordt.
- De README stuurt bij "Demonstreren", stap 6, naar "kies een map" op Instellingen › Telefoon. In de
  voorbeeldmodus is die knop uitgeschakeld; alleen "Bekijk voorbeeld" werkt.
- Tooltip in het maandgrid bij RESERVERINGEN ("het plan is de som van de RES-regels") en de tekst in het
  jaaroverzicht ("anti-rood … plus tijdelijk anti-rood") lopen achter op de spec.
