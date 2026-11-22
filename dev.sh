#!/bin/bash
# Crisper — standalone fast dev build & run (Command Line Tools only; with Xcode
# installed it also builds Shortcuts actions metadata via scripts/appintents.sh).
#
# Compiles Crisper and crisperctl with swiftc, builds /Applications/Crisper.app
# from scratch (or updates it in place) with Info.plist, AppIcon.icns, compiled
# .lproj localizations, entitlements, and ad-hoc or local signing, then launches.
# Never fetches Sparkle and never overwrites /Applications/Crisp.app.
#
# Override the target app with:  CRISPER_APP=/path/to/Crisper.app ./dev.sh
# Skip launching with:           CRISPER_NO_LAUNCH=1 ./dev.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd -P)"
cd "$ROOT"
APP="${CRISPER_APP:-/Applications/Crisper.app}"

if [ "$APP" = "/Applications/Crisp.app" ]; then
    echo "error: refusing to overwrite upstream /Applications/Crisp.app." >&2
    exit 1
fi

# Single source of truth for the version: project.yml.
VERSION=$(grep -E '^[[:space:]]*MARKETING_VERSION:' project.yml | head -1 | sed -E 's/.*"([^"]+)".*/\1/')
BUILD=$(grep -E '^[[:space:]]*CURRENT_PROJECT_VERSION:' project.yml | head -1 | sed -E 's/.*"([^"]+)".*/\1/')

TMP_WORK="$(mktemp -d -t crisper-dev)"
trap 'rm -rf "$TMP_WORK"' EXIT

source scripts/appintents.sh
SWIFTC=(swiftc)
AI_FLAGS=""
AI_DEV=""
if appintents_init "$TMP_WORK/appintents"; then
    SWIFTC=(env DEVELOPER_DIR="$AI_DEV" xcrun swiftc)
    AI_FLAGS=$(appintents_swiftc_flags arm64)
fi

echo "==> Compiling Crisper $VERSION ($BUILD)..."
# shellcheck disable=SC2086 # AI_FLAGS is a list of flags
"${SWIFTC[@]}" -O -swift-version 6 -parse-as-library $AI_FLAGS \
    -target arm64-apple-macos14.0 \
    -import-objc-header Crisp/Crisp-Bridging-Header.h \
    -framework AppKit -framework SwiftUI -framework IOKit -framework CoreAudio \
    -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
    -Xlinker -undefined -Xlinker dynamic_lookup \
    Crisp/App/*.swift Crisp/Models/*.swift Crisp/Services/*.swift \
    Crisp/Views/*.swift Crisp/Utilities/*.swift \
    -o Crisper-bin

echo "==> Compiling crisperctl..."
swiftc -O -swift-version 6 -target arm64-apple-macos14.0 \
    Sources/crispctl/*.swift Crisp/Models/CrispControlModel.swift Crisp/Models/BrightnessKeySteps.swift \
    -o crisperctl-bin

echo "==> Packaging standalone ${APP}..."
if pgrep -x Crisper >/dev/null; then
    osascript -e 'quit app "Crisper"' >/dev/null 2>&1 || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -x Crisper >/dev/null || break; sleep 0.5; done
    pkill -x Crisper 2>/dev/null || true
    sleep 1
fi

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Crisper-bin "$APP/Contents/MacOS/Crisper"
cp crisperctl-bin "$APP/Contents/MacOS/crisperctl"
chmod +x "$APP/Contents/MacOS/Crisper" "$APP/Contents/MacOS/crisperctl"

if [ -n "$AI_DEV" ]; then
    echo "==> Writing Shortcuts actions metadata..."
    CRISPER_BUNDLE_ID="com.crisper.app" appintents_metadata "$APP/Contents/MacOS/Crisper" "$APP/Contents/Resources" arm64
else
    echo "==> Shortcuts actions not rebuilt (needs Xcode)"
fi

echo "==> Building AppIcon.icns from asset catalog..."
ICONSET="$TMP_WORK/AppIcon.iconset"
mkdir -p "$ICONSET"
ICONS="Crisp/Assets.xcassets/AppIcon.appiconset"
cp "$ICONS/icon_16.png"   "$ICONSET/icon_16x16.png"
cp "$ICONS/icon_32.png"   "$ICONSET/icon_16x16@2x.png"
cp "$ICONS/icon_32.png"   "$ICONSET/icon_32x32.png"
cp "$ICONS/icon_64.png"   "$ICONSET/icon_32x32@2x.png"
cp "$ICONS/icon_128.png"  "$ICONSET/icon_128x128.png"
cp "$ICONS/icon_256.png"  "$ICONSET/icon_128x128@2x.png"
cp "$ICONS/icon_256.png"  "$ICONSET/icon_256x256.png"
cp "$ICONS/icon_512.png"  "$ICONSET/icon_256x256@2x.png"
cp "$ICONS/icon_512.png"  "$ICONSET/icon_512x512.png"
cp "$ICONS/icon_1024.png" "$ICONSET/icon_512x512@2x.png"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

echo "==> Compiling localizations from String Catalog..."
LANGS=$(python3 "$ROOT/scripts/xcstrings-compile.py" Crisp/Resources/Localizable.xcstrings "$APP/Contents/Resources")
LOC_XML=""
for l in $LANGS; do LOC_XML="${LOC_XML}<string>${l}</string>"; done

echo "==> Writing Info.plist / PkgInfo..."
printf 'APPL????' > "$APP/Contents/PkgInfo"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key><string>Crisper</string>
	<key>CFBundleDisplayName</key><string>Crisper</string>
	<key>CFBundleIdentifier</key><string>com.crisper.app</string>
	<key>CFBundleExecutable</key><string>Crisper</string>
	<key>CFBundleIconFile</key><string>AppIcon</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
	<key>CFBundleDevelopmentRegion</key><string>en</string>
	<key>CFBundleLocalizations</key><array>${LOC_XML}</array>
	<key>CFBundleShortVersionString</key><string>${VERSION}</string>
	<key>CFBundleVersion</key><string>${BUILD}</string>
	<key>LSMinimumSystemVersion</key><string>14.0</string>
	<key>LSUIElement</key><true/>
	<key>NSHumanReadableCopyright</key><string>Crisper (based on Crisp, MIT License)</string>
	<key>NSAppleEventsUsageDescription</key><string>Crisper uses System Events to switch Dark Mode with the system's animated transition.</string>
	<key>CFBundleSupportedPlatforms</key><array><string>MacOSX</string></array>
</dict>
</plist>
PLIST

xattr -cr "$APP"
SIGN_ID="${CRISPER_SIGN_ID:-Crisper Dev}"
if security find-identity -p codesigning 2>/dev/null | grep -qF "$SIGN_ID"; then
    echo "==> Signing with identity: $SIGN_ID"
else
    echo "==> Signing ad hoc ($SIGN_ID not found)"
    SIGN_ID="-"
fi
codesign --force -s "$SIGN_ID" "$APP/Contents/MacOS/crisperctl"
codesign --force -s "$SIGN_ID" --entitlements Crisp/Crisp.entitlements "$APP"

if [ "${CRISPER_NO_LAUNCH:-0}" = "1" ]; then
    echo "Done. Crisper $VERSION packaged at $APP (launch skipped)."
else
    echo "==> Launching..."
    open "$APP"
    echo "Done. Crisper $VERSION running."
fi
