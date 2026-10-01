#!/usr/bin/env bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "==> [1/6] Building universal helper binaries (device_helper & airtraffic_host)..."
make clean
make all

APP_NAME="AirCard"
APP_DIR="build/${APP_NAME}.app"
CONTENTS_DIR="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"
BIN_DIR="${RESOURCES_DIR}/bin"
LIB_DIR="${RESOURCES_DIR}/lib"

echo "==> [2/6] Scaffolding ${APP_NAME}.app bundle structure..."
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$BIN_DIR" "$LIB_DIR"

# Write Info.plist
cat << 'EOF' > "${CONTENTS_DIR}/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>AirCard</string>
    <key>CFBundleIdentifier</key>
    <string>com.mak5er.aircard</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>AirCard</string>
    <key>CFBundleDisplayName</key>
    <string>AirCard</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.2.5</string>
    <key>CFBundleVersion</key>
    <string>10</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
EOF

echo "==> [3/6] Bundling universal tools & libraries..."
# Copy App Icon
if [ -f "dmg_assets/AppIcon.icns" ]; then
    cp "dmg_assets/AppIcon.icns" "${RESOURCES_DIR}/AppIcon.icns"
fi

# Copy universal device_helper and airtraffic_host. Device discovery and log
# streaming both run through device_helper, which talks to MobileDevice.framework
# directly, so the bundle needs no libimobiledevice tooling.
cp build/device_helper "$BIN_DIR/"
cp build/airtraffic_host "$BIN_DIR/"

# Copy python backend scripts
cp apply_card_skin.py "$RESOURCES_DIR/"
cp aircard.py "$RESOURCES_DIR/"
cp aircard_backend.py "$RESOURCES_DIR/"
cp card_assets.py "$RESOURCES_DIR/"
cp card_artwork.py "$RESOURCES_DIR/"
cp wallet_catalog.py "$RESOURCES_DIR/"

# A bundle without these cannot talk to a device at all, so fail here instead
# of shipping an app that reports "No iPhone found" for every user.
for tool in device_helper airtraffic_host; do
    if [ ! -x "${BIN_DIR}/${tool}" ]; then
        echo "ERROR: ${BIN_DIR}/${tool} is missing from the bundle." >&2
        exit 1
    fi
done

echo "==> [4/6] Compiling universal Swift binary (arm64 + x86_64)..."
if [ -z "${SWIFT_SDK:-}" ]; then
    SWIFT_SDK="$(xcrun --sdk macosx --show-sdk-path)"
    CLT_SWIFTUI_SDK="/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk"
    if [ "$(xcode-select -p)" = "/Library/Developer/CommandLineTools" ] && [ -d "$CLT_SWIFTUI_SDK" ]; then
        SWIFT_SDK="$CLT_SWIFTUI_SDK"
    fi
fi
swiftc -sdk "$SWIFT_SDK" -O -parse-as-library -target arm64-apple-macosx14.0 AirCardApp.swift Sources/WalletDiscovery.swift Sources/WalletDiagnosticsView.swift -o build/AirCard_arm64
swiftc -sdk "$SWIFT_SDK" -O -parse-as-library -target x86_64-apple-macosx14.0 AirCardApp.swift Sources/WalletDiscovery.swift Sources/WalletDiagnosticsView.swift -o build/AirCard_x86_64
lipo -create -output "${MACOS_DIR}/AirCard" build/AirCard_arm64 build/AirCard_x86_64
chmod +x "${MACOS_DIR}/AirCard"

echo "==> [5/6] Setting permissions and signing ${APP_NAME}.app bundle..."
chmod -R 755 "$APP_DIR"
xattr -cr "$APP_DIR" 2>/dev/null || true
# Ad-hoc by default so anyone can build this. Set CODESIGN_IDENTITY to a
# Developer ID to ship a build that Gatekeeper will accept after notarising.
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:--}"
if [ "$CODESIGN_IDENTITY" = "-" ]; then
    codesign --force --deep --sign - "$APP_DIR"
else
    # Sign inside out. --deep only walks Frameworks and PlugIns, so the helpers
    # in Resources/bin keep whatever signature they arrived with, and the notary
    # service rejects the whole bundle over one ad-hoc binary inside it.
    # Hardened runtime is required before anything can be notarised.
    for tool in "${BIN_DIR}"/*; do
        [ -f "$tool" ] || continue
        codesign --force --options runtime --timestamp \
            --sign "$CODESIGN_IDENTITY" "$tool"
    done
    codesign --force --options runtime --timestamp \
        --sign "$CODESIGN_IDENTITY" "$APP_DIR"
    codesign --verify --strict --verbose=1 "$APP_DIR"
    # Catch an ad-hoc straggler here rather than in a notary rejection. Checking
    # the bundle alone is not enough: codesign reports the top-level signature
    # only, and the binaries this is guarding are nested inside Resources.
    for nested in "$APP_DIR/Contents/MacOS"/* "$BIN_DIR"/*; do
        [ -f "$nested" ] || continue
        if codesign -dv "$nested" 2>&1 | grep -q "adhoc"; then
            echo "ERROR: $nested is still ad-hoc signed" >&2
            exit 1
        fi
    done
fi

# The plist promise is only worth anything if the binaries agree with it. A
# helper built without a minimum silently inherits the build machine's macOS.
for binary in "${MACOS_DIR}/${APP_NAME}" "${BIN_DIR}"/*; do
    [ -f "$binary" ] || continue
    actual="$(otool -l "$binary" | awk '/minos/ {print $2; exit}')"
    if [ -n "$actual" ] && [ "$actual" != "14.0" ]; then
        echo "ERROR: $(basename "$binary") targets macOS $actual, but the app claims 14.0" >&2
        exit 1
    fi
done

echo "==> [6/6] Generating styled DMG (${APP_NAME}.dmg)..."
DMG_STAGING="/tmp/aircard_dmg_staging"
rm -rf "$DMG_STAGING"
mkdir -p "$DMG_STAGING"
cp -R "$APP_DIR" "$DMG_STAGING/"

rm -f "build/${APP_NAME}.dmg"

if command -v create-dmg >/dev/null 2>&1; then
    create-dmg \
        --volname "AirCard" \
        --background "dmg_assets/background_700.png" \
        --window-pos 200 120 \
        --window-size 700 460 \
        --icon-size 110 \
        --icon "AirCard.app" 175 220 \
        --hide-extension "AirCard.app" \
        --app-drop-link 525 220 \
        --add-file "README.txt" "dmg_assets/README.txt" 350 360 \
        --filesystem APFS \
        --overwrite \
        "build/${APP_NAME}.dmg" \
        "$DMG_STAGING"
else
    ln -s /Applications "$DMG_STAGING/Applications"
    hdiutil create -volname "AirCard" -srcfolder "$DMG_STAGING" -ov -format UDZO "build/${APP_NAME}.dmg"
fi

# Sign the disk image too, otherwise the signature stops at the app inside it.
if [ "$CODESIGN_IDENTITY" != "-" ]; then
    codesign --force --sign "$CODESIGN_IDENTITY" --timestamp "build/${APP_NAME}.dmg"
fi

echo "============================================================"
echo "🎉 SUCCESS: build/${APP_NAME}.dmg is ready!"
if [ "$CODESIGN_IDENTITY" != "-" ]; then
    echo "   Signed with: $CODESIGN_IDENTITY"
    echo "   Notarise with: xcrun notarytool submit build/${APP_NAME}.dmg \\"
    echo "                    --keychain-profile <profile> --wait"
    echo "   Then staple:   xcrun stapler staple build/${APP_NAME}.dmg"
fi
echo "============================================================"
