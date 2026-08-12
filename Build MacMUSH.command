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
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
codesign --force --deep -s - "$APP" 2>/dev/null || true
"$LSREGISTER" -f "$APP" >/dev/null 2>&1 || true
touch "$APP" 2>/dev/null || true

# ---- 5. Install into /Applications ------------------------------------
# Because a build that stays in dist/ is a build you are not running. Copy it
# there once by hand and every later build lands on top of it, which is the
# whole point: otherwise you fix something, rebuild, launch the copy in
# Applications, and spend an hour wondering why the fix isn't there.
INSTALLED="/Applications/MacMUSH.app"
DO_INSTALL=no

if [ -d "$INSTALLED" ]; then
  DO_INSTALL=yes                    # already installed: keep it up to date
else
  echo ""
  printf "Install into /Applications? [y/N] "
  # `|| answer=""` because `set -e` is on and a `read` with no tty to read from
  # fails — which would abort the whole build at the last step, after it had
  # already succeeded, for a question nobody was there to answer.
  read -r answer || answer=""
  case "$answer" in [Yy]*) DO_INSTALL=yes ;; esac
fi

if [ "$DO_INSTALL" = yes ]; then
  # Replacing the bundle underneath a running copy leaves it half old and half
  # new — the executable it already mapped, the resources it hasn't loaded yet.
  if pgrep -x MacMUSH >/dev/null 2>&1; then
    echo "⚠︎  MacMUSH is running. Quit it (⌘Q) and press return to continue,"
    printf "   or press Ctrl-C to leave the installed copy alone. "
    read -r _ || true
  fi

  # rm first, rather than copying over the top: a stale file from an older
  # build that this one no longer produces would otherwise survive forever.
  if rm -rf "$INSTALLED" 2>/dev/null && cp -R "$APP" "$INSTALLED" 2>/dev/null; then
    "$LSREGISTER" -f "$INSTALLED" >/dev/null 2>&1 || true
    touch "$INSTALLED" 2>/dev/null || true
    echo "✓ Installed  $INSTALLED"

    # The Dock caches icons hard, and a rebuilt app at a path it has already
    # seen is exactly the case it gets wrong — you get the old icon, or the
    # generic one, and nothing you do to the bundle changes it. Restarting the
    # Dock is the reliable fix; it takes about a second and loses nothing.
    killall Dock 2>/dev/null || true
  else
    echo "⚠︎  Couldn't write to /Applications. Drag dist/MacMUSH.app there yourself,"
    echo "   or run:  sudo cp -R \"$PWD/$APP\" /Applications/"
  fi
fi

echo ""
echo "${BOLD}✓ Done!${NORM}  $PWD/$APP"
if [ "$DO_INSTALL" != yes ]; then
  echo "Drag MacMUSH.app into Applications, or run it right here."
  open dist 2>/dev/null || true
fi
read -n 1 -s -r -p "Press any key to close…"; echo ""
