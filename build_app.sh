#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# Milo — Build & Package Script
#
# Usage:
#   ./build_app.sh                  # Dev build (ad-hoc signed)
#   ./build_app.sh release          # Release build (optimised, hardened)
#   ./build_app.sh release sign     # Release + Developer ID signing
#   ./build_app.sh release notarize # Release + sign + notarize for distribution
#
# Environment variables (for signing / notarisation):
#   DEVELOPER_ID    – e.g. "Developer ID Application: Your Name (TEAMID)"
#   APPLE_ID        – Apple ID email for notarization
#   APPLE_TEAM_ID   – 10-char team identifier
#   APP_PASSWORD    – App-specific password for notarytool
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

APP_NAME="Milo"
APP_DIR="$APP_NAME.app"
SOURCES="Milo/Sources/*.swift"
BUILD_MODE="${1:-dev}"     # dev | release
SIGN_MODE="${2:-}"         # sign | notarize | (empty)
VERSION=$(grep -A1 CFBundleShortVersionString Milo/Info.plist | tail -1 | sed -E 's/.*<string>(.*)<\/string>/\1/')
ICON_WORK_DIR=".build_icons"

echo "╔══════════════════════════════════════════╗"
echo "║  Milo Build Script  v${VERSION:-1.0}               ║"
echo "╚══════════════════════════════════════════╝"
echo ""

# ── Step 1: Clean ────────────────────────────────────────────────────────────
echo "→ Cleaning previous build..."
rm -rf "$APP_DIR" "$ICON_WORK_DIR" "${APP_NAME}.dmg"

# ── Step 2: Create bundle structure ──────────────────────────────────────────
echo "→ Creating app bundle structure..."
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

# ── Step 3: Compile ─────────────────────────────────────────────────────────
SWIFT_FLAGS="-target $(uname -m)-apple-macosx13.0"

if [[ "$BUILD_MODE" == "release" ]]; then
    echo "→ Compiling Swift sources (release, optimised)..."
    SWIFT_FLAGS="$SWIFT_FLAGS -O -whole-module-optimization"
else
    echo "→ Compiling Swift sources (dev)..."
    SWIFT_FLAGS="$SWIFT_FLAGS -D DEBUG"
fi

if [[ "$SIGN_MODE" != "sign" && "$SIGN_MODE" != "notarize" ]]; then
    SWIFT_FLAGS="$SWIFT_FLAGS -D AD_HOC"
fi

# shellcheck disable=SC2086
swiftc $SOURCES $SWIFT_FLAGS \
    -framework WebKit \
    -o "$APP_DIR/Contents/MacOS/$APP_NAME"

# ── Step 4: Copy Info.plist ──────────────────────────────────────────────────
echo "→ Copying Info.plist..."
cp Milo/Info.plist "$APP_DIR/Contents/Info.plist"

# ── Step 4b: Copy resource images ────────────────────────────────────────────
echo "→ Copying resource images..."
RESOURCE_IMAGES=(Milo/Resources/*.png)
if [[ ! -e "${RESOURCE_IMAGES[0]}" ]]; then
    echo "✘  No PNG resources found in Milo/Resources."
    exit 1
fi
cp "${RESOURCE_IMAGES[@]}" "$APP_DIR/Contents/Resources/"

# ── Step 5: Generate icons ──────────────────────────────────────────────────
echo "→ Generating app icons..."
mkdir -p "$ICON_WORK_DIR"

LIGHT_PNG="Icons/Icon Exports/Milo-iOS-Default-1024x1024@1x.png"
DARK_PNG="Icons/Icon Exports/Milo-iOS-Dark-1024x1024@1x.png"

for style in Light Dark; do
    PNG_SRC=$LIGHT_PNG
    if [[ "$style" == "Dark" ]]; then
        PNG_SRC=$DARK_PNG
    fi
    
    if [[ -f "$PNG_SRC" ]]; then
        ICONSET="$ICON_WORK_DIR/Milo${style}.iconset"
        mkdir -p "$ICONSET"
        sips -z 16 16     "$PNG_SRC" --out "$ICONSET/icon_16x16.png" >/dev/null
        sips -z 32 32     "$PNG_SRC" --out "$ICONSET/icon_16x16@2x.png" >/dev/null
        sips -z 32 32     "$PNG_SRC" --out "$ICONSET/icon_32x32.png" >/dev/null
        sips -z 64 64     "$PNG_SRC" --out "$ICONSET/icon_32x32@2x.png" >/dev/null
        sips -z 128 128   "$PNG_SRC" --out "$ICONSET/icon_128x128.png" >/dev/null
        sips -z 256 256   "$PNG_SRC" --out "$ICONSET/icon_128x128@2x.png" >/dev/null
        sips -z 256 256   "$PNG_SRC" --out "$ICONSET/icon_256x256.png" >/dev/null
        sips -z 512 512   "$PNG_SRC" --out "$ICONSET/icon_256x256@2x.png" >/dev/null
        sips -z 512 512   "$PNG_SRC" --out "$ICONSET/icon_512x512.png" >/dev/null
        sips -z 1024 1024 "$PNG_SRC" --out "$ICONSET/icon_512x512@2x.png" >/dev/null
        
        /usr/bin/iconutil -c icns "$ICONSET" -o "$APP_DIR/Contents/Resources/Milo${style}.icns"
    else
        echo "  ⚠  Missing source PNG for $style icon — app will use fallback icon"
    fi
done
# ── Step 6: Write entitlements ───────────────────────────────────────────────
ENTITLEMENTS_PATH=".Milo.entitlements"
cat > "$ENTITLEMENTS_PATH" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.automation.apple-events</key>
    <true/>
    <key>com.apple.developer.applesignin</key>
    <array>
        <string>Default</string>
    </array>
</dict>
</plist>
EOF

# ── Step 7: Code signing ────────────────────────────────────────────────────
if [[ "$SIGN_MODE" == "sign" || "$SIGN_MODE" == "notarize" ]]; then
    if [[ -z "${DEVELOPER_ID:-}" ]]; then
        echo "✘  DEVELOPER_ID environment variable is required for signing."
        echo "   Example: export DEVELOPER_ID=\"Developer ID Application: Your Name (TEAMID)\""
        exit 1
    fi
    echo "→ Signing with Developer ID..."
    codesign --force \
        --sign "$DEVELOPER_ID" \
        --options runtime \
        --entitlements "$ENTITLEMENTS_PATH" \
        --timestamp \
        "$APP_DIR/Contents/MacOS/$APP_NAME"
    codesign --force \
        --sign "$DEVELOPER_ID" \
        --options runtime \
        --entitlements "$ENTITLEMENTS_PATH" \
        --timestamp \
        "$APP_DIR"

    echo "→ Verifying signature..."
    codesign --verify --deep --strict "$APP_DIR"
    spctl --assess --type execute "$APP_DIR" 2>&1 || echo "  (spctl may fail until notarized)"
else
    echo "→ Ad-hoc code signing (dev)..."
    codesign --force \
        --sign - \
        --options runtime \
        --entitlements "$ENTITLEMENTS_PATH" \
        "$APP_DIR/Contents/MacOS/$APP_NAME"
    codesign --force \
        --sign - \
        --options runtime \
        --entitlements "$ENTITLEMENTS_PATH" \
        "$APP_DIR"
fi

rm -f "$ENTITLEMENTS_PATH"

# ── Step 8: Create DMG (release only) ───────────────────────────────────────
if [[ "$BUILD_MODE" == "release" ]]; then
    DMG_NAME="${APP_NAME}-${VERSION:-1.0}.dmg"
    echo "→ Creating distributable DMG: $DMG_NAME ..."

    DMG_STAGING=".dmg_staging"
    rm -rf "$DMG_STAGING"
    mkdir -p "$DMG_STAGING"
    cp -R "$APP_DIR" "$DMG_STAGING/"
    ln -s /Applications "$DMG_STAGING/Applications"

    hdiutil create -volname "$APP_NAME" \
        -srcfolder "$DMG_STAGING" \
        -ov -format UDZO \
        "$DMG_NAME" \
        -quiet

    rm -rf "$DMG_STAGING"

    # Sign the DMG too
    if [[ "$SIGN_MODE" == "sign" || "$SIGN_MODE" == "notarize" ]]; then
        codesign --force --sign "$DEVELOPER_ID" --timestamp "$DMG_NAME"
    fi

    echo "  ✔ DMG created: $DMG_NAME"
fi

# ── Step 9: Notarize (if requested) ─────────────────────────────────────────
if [[ "$SIGN_MODE" == "notarize" ]]; then
    if [[ -z "${APPLE_ID:-}" || -z "${APPLE_TEAM_ID:-}" || -z "${APP_PASSWORD:-}" ]]; then
        echo "✘  Notarization requires APPLE_ID, APPLE_TEAM_ID, and APP_PASSWORD env vars."
        exit 1
    fi

    DMG_NAME="${APP_NAME}-${VERSION:-1.0}.dmg"
    echo "→ Submitting $DMG_NAME for notarization..."

    xcrun notarytool submit "$DMG_NAME" \
        --apple-id "$APPLE_ID" \
        --team-id "$APPLE_TEAM_ID" \
        --password "$APP_PASSWORD" \
        --wait

    echo "→ Stapling notarization ticket..."
    xcrun stapler staple "$DMG_NAME"

    echo "  ✔ Notarization complete!"
fi

# ── Done ─────────────────────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════"
echo "  Build complete: $APP_DIR"
if [[ "$BUILD_MODE" == "release" ]]; then
    echo "  DMG: ${APP_NAME}-${VERSION:-1.0}.dmg"
fi
echo "════════════════════════════════════════════"
