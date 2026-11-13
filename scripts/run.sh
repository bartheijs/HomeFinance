#!/bin/zsh
# Bouwt HomeFinance en start het als gewone Mac-app (dist/HomeFinance.app).
# Gebruik: ./scripts/run.sh          bouwen en starten
#          ./scripts/run.sh --build    alleen bouwen
#          ./scripts/run.sh --install  bouwen, in de map Apps zetten en starten
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product HomeFinance
BIN="$(swift build -c release --show-bin-path)/HomeFinance"
APP="dist/HomeFinance.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/HomeFinance"
[ -f scripts/AppIcon.icns ] && cp scripts/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>HomeFinance</string>
  <key>CFBundleDisplayName</key><string>HomeFinance</string>
  <key>CFBundleIdentifier</key><string>nl.homefinance.app</string>
  <key>CFBundleExecutable</key><string>HomeFinance</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleDevelopmentRegion</key><string>nl</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.finance</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "Gebouwd: $APP"
case "${1:-}" in
  --build) ;;
  --install)
    # Zet de app in de map Apps, zodat hij in Launchpad en Spotlight staat.
    rm -rf "/Applications/HomeFinance.app"
    cp -R "$APP" "/Applications/HomeFinance.app"
    echo "Geinstalleerd: /Applications/HomeFinance.app"
    open "/Applications/HomeFinance.app" ;;
  *) open "$APP" ;;
esac
