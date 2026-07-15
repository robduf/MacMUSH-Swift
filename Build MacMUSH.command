#!/bin/bash
# Builds MacMUSH.app from the Swift package. Double-click me in Finder.
# Requires the Swift toolchain (from Xcode or the Command Line Tools).
set -e
cd "$(dirname "$0")"

BOLD=$(tput bold 2>/dev/null || true); NORM=$(tput sgr0 2>/dev/null || true)
echo ""
echo "${BOLD}  ┌──────────────────────────────────────┐${NORM}"
echo "${BOLD}  │   MacMUSH (Swift) — build for this Mac │${NORM}"
echo "${BOLD}  └──────────────────────────────────────┘${NORM}"
echo ""

# ---- 1. Swift toolchain check -----------------------------------------
if ! command -v swift >/dev/null 2>&1; then
  echo "Swift wasn't found. Install one of:"
  echo "  • Xcode (free, Mac App Store) — full toolchain + SDK, or"
  echo "  • Command Line Tools:   xcode-select --install"
  echo ""
  echo "Then run this again."
  read -n 1 -s -r -p "Press any key to close…"; echo ""
  exit 1
fi
echo "✓ Swift $(swift --version 2>/dev/null | head -1 | sed 's/.*Swift version //; s/ .*//')"

# ---- 2. Compile (release) ---------------------------------------------
echo "→ Building (release)… first build fetches nothing but takes a minute."
swift build -c release
BIN="$(swift build -c release --show-bin-path)/MacMUSH"
if [ ! -f "$BIN" ]; then
  echo "⚠︎  Build did not produce the expected binary at: $BIN"
  read -n 1 -s -r -p "Press any key to close…"; echo ""
  exit 1
fi
echo "✓ Compiled"

# ---- 3. Assemble the .app bundle --------------------------------------
APP="dist/MacMUSH.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/MacMUSH"
[ -f assets/icon.icns ] && cp assets/icon.icns "$APP/Contents/Resources/icon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>MacMUSH</string>
  <key>CFBundleDisplayName</key><string>MacMUSH</string>
  <key>CFBundleExecutable</key><string>MacMUSH</string>
  <key>CFBundleIdentifier</key><string>com.rob.macmush</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleIconFile</key><string>icon</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
</dict>
</plist>
PLIST

echo "✓ Bundle assembled"

# ---- 4. Ad-hoc sign + refresh Finder ----------------------------------
codesign --force --deep -s - "$APP" 2>/dev/null || true
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP" >/dev/null 2>&1 || true
touch "$APP" 2>/dev/null || true

echo ""
echo "${BOLD}✓ Done!${NORM}  $PWD/$APP"
echo "Drag MacMUSH.app into Applications, or run it right here."
open dist 2>/dev/null || true
read -n 1 -s -r -p "Press any key to close…"; echo ""
