#!/bin/zsh
# Bouwt de app met alleen JOUW scherm echt en de andere schermen als lege plek, in een eigen kopie.
# Zo heb je geen last van half geschreven code van andere sessies.
# Gebruik: scripts/build-screen.sh <Naam> [snapshot] [--dark]
#   <Naam> = Dashboard | Review | Grid | Transactions | Pots | Reimbursements | Reports | Rules | Settings
#   snapshot: schrijft na het bouwen .build-ui-<Naam>/snap/<scherm>.png met voorbeelddata (vandaag = 18-06-2027)
set -uo pipefail
NAME="$1"; ROOT="$(cd "$(dirname "$0")/.." && pwd)"; W="$ROOT/.build-ui-$NAME"
mkdir -p "$W/src"
rsync -a --delete --exclude '.build*' --exclude .git --exclude dist "$ROOT/" "$W/src/"
for d in "$W"/src/Sources/HomeFinance/Screens/*/; do
  n="$(basename "$d")"
  if [ "$n" != "$NAME" ] && [ -f "$ROOT/scripts/screen-stubs/${n}Screen.swift" ]; then
    rm -rf "$d"/*; cp "$ROOT/scripts/screen-stubs/${n}Screen.swift" "$d"
  fi
done
cd "$W/src"
swift build --scratch-path "$W/build" --product HomeFinance 2>&1 | grep -E "error:|warning: (var|unused|immutable|initialization)|Build of product|Compiling HomeFinance" | sort -u | tail -40
[ "${pipestatus[1]}" -eq 0 ] || { echo "BOUWEN MISLUKT"; exit 1; }
if [ "${2:-}" = "snapshot" ]; then
  "$W/build/debug/HomeFinance" --snapshot "$W/snap" --only "${NAME:l}" ${3:-}
fi
