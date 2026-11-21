#!/bin/bash
# Testronde: bouwt de app, draait alle tests, start de echte app voor een zelftest en schrijft de kerncijfers.
#
# Gebruik:
#   scripts/testronde.sh --uit <map>
#       Alleen met voorbeelddata.
#   scripts/testronde.sh --uit <map> --database <kopie.sqlite> [--basis <vorige-kerncijfers.json>] [--dag jjjj-mm-dd]
#       Ook op een KOPIE van de echte administratie. Het script maakt daar zelf nog een kopie van in <map>, zodat
#       <kopie.sqlite> zelf niet verandert. Met --basis toont het de verschillen met de kerncijfers van een vorige
#       ronde. Zonder --dag neemt het de peildag van de basis (of anders vandaag).
#
# De uitvoer (logbestanden, kerncijfers, kopieën) gaat naar <map>, nooit in de repo. De echte administratie
# (~/Library/Application Support/HomeFinance/) wordt geweigerd. Eindigt met GESLAAGD (exitcode 0) of
# NIET GESLAAGD (exitcode 1).
set -u
cd "$(dirname "$0")/.."
REPO="$(pwd -P)"

UIT=""; DATABASE=""; BASIS=""; DAG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --uit) UIT="${2:-}"; shift 2 ;;
    --database) DATABASE="${2:-}"; shift 2 ;;
    --basis) BASIS="${2:-}"; shift 2 ;;
    --dag) DAG="${2:-}"; shift 2 ;;
    *) echo "Onbekende optie: $1" >&2; exit 2 ;;
  esac
done

fout() { echo "FOUT: $*" >&2; exit 2; }
[ -n "$UIT" ] || fout "geef een uitvoermap op met --uit <map> (buiten de repo)"
mkdir -p "$UIT" || fout "kan $UIT niet maken"
UIT="$(cd "$UIT" && pwd -P)"
case "$UIT/" in "$REPO"/*) fout "de uitvoermap $UIT ligt in de repo; kies een map erbuiten" ;; esac

ECHT="$(cd "$HOME/Library/Application Support" 2>/dev/null && pwd -P)/HomeFinance"
if [ -n "$DATABASE" ]; then
  [ -f "$DATABASE" ] || fout "database $DATABASE bestaat niet"
  DBDIR="$(cd "$(dirname "$DATABASE")" && pwd -P)"
  case "$DBDIR/" in "$ECHT"/*) fout "$DATABASE is de echte administratie; geef een kopie op een andere plek" ;; esac
fi
if [ -n "$BASIS" ]; then
  [ -f "$BASIS" ] || fout "basis $BASIS bestaat niet"
  if [ -z "$DAG" ]; then
    DAG="$(sed -n 's/^  "peildag" : "\(.*\)",\{0,1\}$/\1/p' "$BASIS")"
  fi
fi
[ -n "$DAG" ] || DAG="$(date +%Y-%m-%d)"

GEFAALD=0
REGELS=()
uitslag() {  # uitslag <0|1> <tekst>
  if [ "$1" = 0 ]; then REGELS+=("OK    $2"); else REGELS+=("FOUT  $2"); GEFAALD=1; fi
  echo "  → $( [ "$1" = 0 ] && echo OK || echo FOUT ): $2"
}

# Draait een opdracht met een harde tijdslimiet; stopt alleen dat eigen proces (op zijn PID).
met_limiet() {  # met_limiet <seconden> <opdracht...>
  local limiet="$1"; shift
  "$@" & local pid=$!
  ( sleep "$limiet"; kill -9 "$pid" 2>/dev/null && echo "  (gestopt na $limiet s: tijdslimiet)" ) &
  local bewaker=$!
  wait "$pid"; local rc=$?
  kill "$bewaker" 2>/dev/null; wait "$bewaker" 2>/dev/null
  return $rc
}

echo "== Testronde $(date '+%Y-%m-%d %H:%M') · commit $(git rev-parse --short HEAD)$(git diff --quiet HEAD || echo ' + niet gecommitte wijzigingen') · peildag $DAG"
echo "   uitvoer: $UIT"

echo "== 1. Bouwen"
if swift build > "$UIT/bouwen.log" 2>&1; then uitslag 0 "bouwen"; else uitslag 1 "bouwen (zie bouwen.log)"; fi
APP="$(swift build --show-bin-path)/HomeFinance"

echo "== 2. Alle tests (swift test)"
if swift test > "$UIT/swift-test.log" 2>&1; then
  uitslag 0 "swift test: $(grep -E '^(✔|✘) Test run with' "$UIT/swift-test.log" | tail -1 | sed 's/^[^T]*Test run/Test run/')"
else
  uitslag 1 "swift test (zie swift-test.log): $(grep -E '^✘ Test run with' "$UIT/swift-test.log" | tail -1 | sed 's/^[^T]*Test run/Test run/')"
fi

zelftest() {  # zelftest <naam> <opties...>
  local naam="$1"; shift
  local log="$UIT/zelftest-$naam.log"
  rm -f "$log"
  met_limiet 120 "$APP" "$@" --zelftest "$log" > "$UIT/zelftest-$naam.uitvoer" 2>&1
  local rc=$?
  local samen; samen="$(grep -E '[0-9]+ OK, [0-9]+ FOUT' "$log" 2>/dev/null | tail -1 | sed 's/^[^ ]* //')"
  if [ $rc = 0 ] && grep -q "UITSLAG: GESLAAGD" "$log" 2>/dev/null; then
    uitslag 0 "zelftest $naam: $samen"
  else
    uitslag 1 "zelftest $naam (exitcode $rc): ${samen:-geen uitslag}"
    grep "FOUT" "$log" 2>/dev/null | sed 's/^/      /'
  fi
}

kerncijfers() {  # kerncijfers <naam> <opties...>
  local naam="$1"; shift
  local uit="$UIT/kerncijfers-$naam.json"
  rm -f "$uit"
  if met_limiet 60 "$APP" "$@" --kerncijfers "$uit" --dag "$DAG" > "$UIT/kerncijfers-$naam.uitvoer" 2>&1 && [ -s "$uit" ]; then
    uitslag 0 "kerncijfers $naam: $(grep -c '" : "' "$uit") waarden"
  else
    uitslag 1 "kerncijfers $naam (zie kerncijfers-$naam.uitvoer)"
  fi
}

echo "== 3. Voorbeelddata: zelftest en kerncijfers"
zelftest voorbeeld --voorbeeld
kerncijfers voorbeeld --voorbeeld

if [ -n "$DATABASE" ]; then
  echo "== 4. Kopie van de administratie: zelftest en kerncijfers"
  # Eigen kopieën, zodat het opgegeven bestand niet verandert (openen kan een nieuwe migratie uitvoeren).
  kopie() {  # kopie <doelmap>
    rm -rf "$1"; mkdir -p "$1"
    cp "$DATABASE" "$1/administratie.sqlite"
    for x in -wal -shm; do [ -f "$DATABASE$x" ] && cp "$DATABASE$x" "$1/administratie.sqlite$x"; done
  }
  kopie "$UIT/kopie-kerncijfers"; kopie "$UIT/kopie-zelftest"
  kerncijfers kopie --database "$UIT/kopie-kerncijfers/administratie.sqlite"
  zelftest kopie --database "$UIT/kopie-zelftest/administratie.sqlite"

  if [ -n "$BASIS" ]; then
    echo "== 5. Verschillen met de basis ($BASIS)"
    NIEUW="$UIT/kerncijfers-kopie.json"
    vlak() { sed -n 's/^  "\(.*\)" : "\(.*\)",\{0,1\}$/\1	\2/p' "$1"; }
    if [ -s "$NIEUW" ]; then
      awk -F'\t' '
        NR == FNR { oud[$1] = $2; next }
        { nieuw[$1] = $2 }
        END {
          for (k in oud) if (!(k in nieuw)) print k ": " oud[k] " → (ontbreekt)"
          for (k in nieuw) if (!(k in oud)) print k ": (ontbreekt) → " nieuw[k]
          for (k in nieuw) if ((k in oud) && oud[k] != nieuw[k] && k != "kerncijfers.versie") print k ": " oud[k] " → " nieuw[k]
        }' <(vlak "$BASIS") <(vlak "$NIEUW") | LC_ALL=C sort > "$UIT/verschillen.txt"
      if [ -s "$UIT/verschillen.txt" ]; then
        sed 's/^/      /' "$UIT/verschillen.txt"
        uitslag 1 "kerncijfers wijken af van de basis: $(wc -l < "$UIT/verschillen.txt" | tr -d ' ') verschillen (zie verschillen.txt)"
      else
        echo "      geen verschillen"
        uitslag 0 "kerncijfers gelijk aan de basis: geen verschillen"
      fi
    else
      uitslag 1 "vergelijken met de basis kon niet: geen nieuwe kerncijfers"
    fi
  fi
fi

echo
echo "== Samenvatting"
printf '%s\n' "${REGELS[@]}" | tee "$UIT/uitslag.txt"
if [ $GEFAALD = 0 ]; then
  echo "TOTAAL: GESLAAGD" | tee -a "$UIT/uitslag.txt"; exit 0
else
  echo "TOTAAL: NIET GESLAAGD" | tee -a "$UIT/uitslag.txt"; exit 1
fi
