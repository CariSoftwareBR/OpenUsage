#!/bin/bash
# Builds OpenUsage.app from OpenUsage.swift with the Xcode Command Line Tools.
# Usage: widget-mac/build.sh [destination.app]   (default: ~/Applications/OpenUsage.app)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:-$HOME/Applications/OpenUsage.app}"

if ! command -v swiftc >/dev/null 2>&1; then
  echo "swiftc not found. Install the Xcode Command Line Tools: xcode-select --install" >&2
  exit 1
fi
# Apps started from Finder do not get the shell's PATH, so remember where node is now.
NODE="$(command -v node || true)"
[ -z "$NODE" ] && echo "warning: node not found on PATH; the widget will try a login shell" >&2

# Quit a running copy so its bundle can be replaced.
pkill -x OpenUsage 2>/dev/null && sleep 1 || true

BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT
CONTENTS="$BUILD/OpenUsage.app/Contents"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"

swiftc -O -target "$(uname -m)-apple-macos12.0" -o "$CONTENTS/MacOS/OpenUsage" "$ROOT/widget-mac/OpenUsage.swift"

printf '%s\n' "$ROOT" > "$CONTENTS/Resources/root.txt"
printf '%s\n' "$NODE" > "$CONTENTS/Resources/node.txt"

ICONSET="$BUILD/OpenUsage.iconset"
mkdir -p "$ICONSET"
for s in 16 32 128 256; do
  sips -z $s $s "$ROOT/docs/icon.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  d=$((s * 2))
  [ $d -le 256 ] && sips -z $d $d "$ROOT/docs/icon.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$CONTENTS/Resources/OpenUsage.icns"

cat > "$CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.openusage.widget</string>
  <key>CFBundleName</key><string>OpenUsage</string>
  <key>CFBundleDisplayName</key><string>OpenUsage</string>
  <key>CFBundleExecutable</key><string>OpenUsage</string>
  <key>CFBundleIconFile</key><string>OpenUsage</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>12.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# Ad-hoc signature: built locally, so Gatekeeper has nothing to quarantine.
codesign --force --sign - "$BUILD/OpenUsage.app" >/dev/null 2>&1 || true

mkdir -p "$(dirname "$APP")"
rm -rf "$APP"
mv "$BUILD/OpenUsage.app" "$APP"
echo "Built $APP"
