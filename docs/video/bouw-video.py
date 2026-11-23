#!/usr/bin/env python3
"""Bouwt de uitlegvideo van HomeFinance uit schermafbeeldingen met voorbeelddata.

Gebruik (vanuit de repo):
    swift run HomeFinance --snapshot <shots>          # schermen + telefoon.html met voorbeelddata
    python3 docs/video/bouw-video.py <shots> <werkmap>

Nodig: macOS `say` met de stem Xander, ffmpeg en Google Chrome (headless, voor kaarten en ondertitels).
Schrijft docs/video/homefinance-uitleg.mp4, .srt en script.md.
"""
import html, json, re, subprocess, sys
from pathlib import Path

SHOTS = Path(sys.argv[1]).resolve()
WORK = Path(sys.argv[2]).resolve()
HERE = Path(__file__).resolve().parent
CARDS = HERE / "kaarten"
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
W, H, FPS, XF = 1920, 1200, 30, 0.5     # uitvoer, beelden per seconde, duur overgang
PAD_IN, PAD_OUT = 0.5, 0.7              # stilte voor en na de stem per scène

# Uitspraak: alleen voor de stem, niet in de ondertitels.
SPEAK = [("HomeFinance", "Hoom-fainens"), ("Excels", "Eksels"), ("Excel", "Eksel"), ("tags", "teks"),
         ("AI-agents", "A.I.-eedzjents"), ("agent", "eedzjent"), ("Mac-app", "Mek-ep")]

# (scènetitel, beeld, zoom van, zoom tot, focus x, focus y, tekst)
SCENES = [
    ("HomeFinance", "kaart:titel", 1.00, 1.04, .3, .5,
     "HomeFinance: je gezinsbegroting, zonder Excel."),
    ("1 · Het probleem", "kaart:probleem", 1.00, 1.05, .3, .4,
     "Bij ons stonden de begroting en de spaarpotjes in twee aparte Excels. Elke maand betekende dat: "
     "afschriften downloaden, bedragen overtikken en uitzoeken waar het geld gebleven was."),
    ("2 · Wat is het?", "grid.png", 1.00, 1.12, .2, .2,
     "Daarom is er HomeFinance: een eigen Mac-app. Alles blijft op je eigen computer, zonder account en "
     "zonder cloud. Je downloadt het bestand van je bank en importeert het. De rest doet de app."),
    ("3 · Dashboard", "dashboard.png", 1.05, 1.30, .25, .35,
     "Het dashboard begint met één getal: nog te besteden deze maand. Daaronder staat de rekensom: het "
     "saldo, min wat er minimaal op de rekening moet blijven, plus wat nog terugkomt en wat er nog "
     "binnenkomt. Rechts staat Aandacht, met wat je nog moet doen. En onderaan de kaartjes voor "
     "periodieke en incidentele transacties en het saldo."),
    ("4 · Importeren en nakijken", "review.png", 1.00, 1.25, .85, .5,
     "Na het importeren stelt de app per boeking een post of potje voor. De zekere boek je in één keer. "
     "Vink je Voortaan zo indelen aan, dan onthoudt de app dat. Regels komen er alleen met jouw "
     "toestemming."),
    ("5 · Potjes", "pots.png", 1.00, 1.20, .3, .1,
     "Het spaargeld is verdeeld over potjes, zoals vakantie of onderhoud huis. Spaardoelen laten zien of "
     "je op koers ligt, en de vooruitblik rekent uit wat er straks in een potje zit."),
    ("5 · Automatisch sparen", "distributions.png", 1.00, 1.15, .5, .2,
     "Automatisch sparen verdeelt de vaste overboeking elke maand over de potjes. Wordt iets duurder, dan "
     "rekent het hulpje Nieuw jaarbedrag uit wat je per maand opzij zet."),
    ("6 · Te doen", "settleUp.png", 1.10, 1.30, .2, .1,
     "Te doen laat zien wat er nog overgeboekt moet worden tussen de spaar- en de betaalrekening."),
    ("6 · Tags", "tags.png", 1.05, 1.30, .25, .1,
     "Met tags volg je uitgaven over posten heen, bijvoorbeeld tanken. Staat Krijg ik terug aan, dan houdt "
     "de app bij wat je nog terugkrijgt, bijvoorbeeld via een declaratie."),
    ("7 · Op de telefoon", "telefoon-frame.png", 1.00, 1.10, .35, .4,
     "Voor het hele gezin is er een pagina op de telefoon: wat er nog te besteden is, de potjes van de "
     "kinderen en de buffer. Alleen lezen, zonder account."),
    ("8 · Hoe is hij gebouwd?", "kaart:gebouwd", 1.00, 1.05, .3, .5,
     "De app is niet door een ontwikkelteam geschreven, maar gebouwd met AI-agents. In kleine rondes, elk "
     "met een eigen opdracht en een vangnet van automatische tests. Elke versie is eerst getest op een "
     "kopie van de administratie."),
    ("Iets voor jou?", "kaart:eind", 1.00, 1.04, .3, .5,
     "Iets voor jou? Met het bouwpakket kan een agent hem bouwen voor jouw platform en jouw bank."),
]


def run(*cmd, **kw):
    subprocess.run(cmd, check=True, **kw)


def chrome_png(src: Path, out: Path, transparent=False):
    args = [CHROME, "--headless=new", "--disable-gpu", "--hide-scrollbars", "--allow-file-access-from-files",
            "--force-device-scale-factor=1", f"--window-size={W},{H}", "--virtual-time-budget=1500",
            f"--screenshot={out}"]
    if transparent:
        args.append("--default-background-color=00000000")
    run(*args, src.as_uri(), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def duration(path: Path) -> float:
    out = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "json", str(path)],
                         check=True, capture_output=True, text=True).stdout
    return float(json.loads(out)["format"]["duration"])


def chunks(text: str):
    """Ondertitelregels: per zin, lange zinnen geknipt bij een komma of dubbele punt."""
    out = []
    for s in re.split(r"(?<=[.?!])\s+", text.strip()):
        while len(s) > 95:
            cut = max((m.end() for m in re.finditer(r"[,:]\s", s) if m.end() <= 95), default=0)
            if cut == 0:
                cut = s.rfind(" ", 0, 95) + 1
            out.append(s[:cut].strip())
            s = s[cut:].strip()
        out.append(s)
    return out


def subtitle_png(title: str, line: str, out: Path):
    page = WORK / "sub.html"
    page.write_text(f"""<!doctype html><html><head><meta charset="utf-8"><style>
html,body{{margin:0;width:{W}px;height:{H}px;background:transparent;font-family:-apple-system,Helvetica,sans-serif}}
.b{{position:absolute;left:50%;bottom:56px;transform:translateX(-50%);max-width:1500px;background:rgba(20,28,24,.82);
color:#fff;border-radius:18px;padding:18px 34px 22px;text-align:center}}
.t{{font-size:24px;font-weight:600;color:#9fd3b8;letter-spacing:.5px;margin-bottom:6px}}
.l{{font-size:40px;line-height:1.3}}</style></head><body><div class="b"><div class="t">{html.escape(title)}</div>
<div class="l">{html.escape(line)}</div></div></body></html>""", encoding="utf-8")
    chrome_png(page, out, transparent=True)


def srt_time(t: float) -> str:
    ms = int(round(t * 1000))
    return f"{ms // 3600000:02}:{ms // 60000 % 60:02}:{ms // 1000 % 60:02},{ms % 1000:03}"


def main():
    WORK.mkdir(parents=True, exist_ok=True)
    segments, srt, script = [], [], []
    start = 0.0
    for i, (title, image, z0, z1, fx, fy, text) in enumerate(SCENES):
        # Beeld
        if image.startswith("kaart:"):
            img = WORK / f"{image[6:]}.png"
            chrome_png(CARDS / f"{image[6:]}.html", img)
        else:
            img = SHOTS / image
        # Stem
        spoken = text
        for a, b in SPEAK:
            spoken = spoken.replace(a, b)
        aiff, wav = WORK / f"s{i:02}.aiff", WORK / f"s{i:02}.wav"
        run("say", "-v", "Xander", "-r", "175", "-o", str(aiff), spoken)
        run("ffmpeg", "-y", "-v", "error", "-i", str(aiff), "-af",
            f"adelay={int(PAD_IN * 1000)}:all=1,apad=pad_dur={PAD_OUT},aresample=48000", "-ac", "2", str(wav))
        voice = duration(aiff)
        dur = PAD_IN + voice + PAD_OUT
        # Ondertitels: tijd per regel naar verhouding van het aantal tekens
        lines = chunks(text)
        total = sum(len(l) for l in lines)
        t, overlays = PAD_IN, []
        for j, line in enumerate(lines):
            d = voice * len(line) / total
            png = WORK / f"sub{i:02}_{j}.png"
            subtitle_png(title, line, png)
            overlays.append((png, t, t + d))
            srt.append((start + t, start + t + d, f"[{title}] {line}" if j == 0 else line))
            t += d
        # Segment: Ken Burns + ondertitels
        frames = int(round(dur * FPS))
        z = f"{z0}+({z1}-{z0})*on/{frames}"
        vf = [f"[0:v]scale={W * 2}:{H * 2}:flags=lanczos,setsar=1,"
              f"zoompan=z='{z}':x='(iw-iw/zoom)*{fx}':y='(ih-ih/zoom)*{fy}':d={frames}:s={W}x{H}:fps={FPS}[v0]"]
        inputs = ["-loop", "1", "-framerate", str(FPS), "-t", f"{dur:.3f}", "-i", str(img)]
        for k, (png, a, b) in enumerate(overlays):
            inputs += ["-i", str(png)]
            vf.append(f"[v{k}][{k + 1}:v]overlay=0:0:enable='between(t,{a:.3f},{b:.3f})'[v{k + 1}]")
        seg = WORK / f"seg{i:02}.mp4"
        run("ffmpeg", "-y", "-v", "error", *inputs, "-i", str(wav), "-filter_complex", ";".join(vf),
            "-map", f"[v{len(overlays)}]", "-map", f"{len(overlays) + 1}:a", "-t", f"{dur:.3f}",
            "-c:v", "libx264", "-preset", "medium", "-crf", "20", "-pix_fmt", "yuv420p", "-r", str(FPS),
            "-c:a", "aac", "-b:a", "160k", str(seg))
        segments.append((seg, dur))
        script.append((title, image, text, dur))
        start += dur - XF
        print(f"scène {i}: {dur:.1f} s  {title}")

    # Aan elkaar met een korte overgang
    inputs, vf, af = [], [], []
    for seg, _ in segments:
        inputs += ["-i", str(seg)]
    offset, vprev, aprev = 0.0, "[0:v]", "[0:a]"
    for k in range(1, len(segments)):
        offset += segments[k - 1][1] - XF
        vf.append(f"{vprev}[{k}:v]xfade=transition=fade:duration={XF}:offset={offset:.3f}[x{k}]")
        af.append(f"{aprev}[{k}:a]acrossfade=d={XF}[y{k}]")
        vprev, aprev = f"[x{k}]", f"[y{k}]"
    final = HERE / "homefinance-uitleg.mp4"
    run("ffmpeg", "-y", "-v", "error", *inputs, "-filter_complex", ";".join(vf + af), "-map", vprev, "-map", aprev,
        "-c:v", "libx264", "-preset", "slow", "-crf", "21", "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "160k",
        "-movflags", "+faststart", str(final))

    (HERE / "homefinance-uitleg.srt").write_text(
        "\n".join(f"{n}\n{srt_time(a)} --> {srt_time(b)}\n{l}\n" for n, (a, b, l) in enumerate(srt, 1)),
        encoding="utf-8")
    md = ["# Uitlegvideo HomeFinance: script", "",
          "Voor collega's die willen weten of zo'n app iets voor hen is. Ongeveer twee minuten, vertelstem Xander "
          "(`say -r 175`). Alle beelden zijn voorbeelddata (het verzonnen gezin Ouder 1, Ouder 2, Kind 1, Kind 2).",
          "", "Opnieuw bouwen: zie de kop van `bouw-video.py`.", ""]
    words = 0
    for title, image, text, dur in script:
        words += len(text.split())
        beeld = f"kaart `{image[6:]}`" if image.startswith("kaart:") else f"scherm `{image}`"
        md += [f"## {title}", "", f"*Beeld: {beeld} · {dur:.0f} s*", "", text, ""]
    md.insert(4, f"Totaal {words} woorden.")
    md.insert(5, "")
    (HERE / "script.md").write_text("\n".join(md), encoding="utf-8")
    print(f"klaar: {final}  ({duration(final):.1f} s, {words} woorden)")


if __name__ == "__main__":
    main()
