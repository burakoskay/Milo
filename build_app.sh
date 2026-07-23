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
# Environment variables (for signed releases):
#   DEVELOPER_ID             – e.g. "Developer ID Application: Your Name (8N738727QB)"
#   NOTARY_KEYCHAIN_PROFILE  – notarytool profile, defaults to "milo-notary"
#   SPARKLE_PUBLIC_ED_KEY     – public Sparkle verification key
#   MILO_SERVICE_BASE_URL    – public MLP service root (`https://monomacaw.com`)
#   MILO_LICENSE_PUBLIC_KEY  – public MLP Ed25519 verification key (unpadded base64url)
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

APP_NAME="Milo"
APP_DIR="$APP_NAME.app"
TEAM_ID="8N738727QB"
BUNDLE_ID="com.monomacaw.milo"
BUILD_MODE="${1:-dev}"     # dev | release
SIGN_MODE="${2:-}"         # sign | notarize | (empty)
VERSION=$(grep -A1 CFBundleShortVersionString App/Milo/Info.plist | tail -1 | sed -E 's/.*<string>(.*)<\/string>/\1/')
ICON_WORK_DIR=".build_icons"
NOTARY_KEYCHAIN_PROFILE="${NOTARY_KEYCHAIN_PROFILE:-milo-notary}"

if [[ "$BUILD_MODE" != "dev" && "$BUILD_MODE" != "release" ]]; then
    echo "✘  Invalid build mode: $BUILD_MODE"
    echo "   Usage: ./build_app.sh [dev|release] [sign|notarize]"
    exit 64
fi

if [[ -n "$SIGN_MODE" && "$SIGN_MODE" != "sign" && "$SIGN_MODE" != "notarize" ]]; then
    echo "✘  Invalid signing mode: $SIGN_MODE"
    echo "   Usage: ./build_app.sh [dev|release] [sign|notarize]"
    exit 64
fi

if [[ "$SIGN_MODE" == "sign" || "$SIGN_MODE" == "notarize" ]]; then
    if [[ -z "${DEVELOPER_ID:-}" ]]; then
        echo "✘  DEVELOPER_ID environment variable is required for signed releases."
        echo "   Example: export DEVELOPER_ID=\"Developer ID Application: Your Name ($TEAM_ID)\""
        exit 1
    fi

    if [[ "$DEVELOPER_ID" != *"($TEAM_ID)"* ]]; then
        echo "✘  DEVELOPER_ID must be for Team ID $TEAM_ID."
        exit 1
    fi

    if ! security find-identity -v -p codesigning | grep -F "$DEVELOPER_ID" >/dev/null; then
        echo "✘  Developer ID identity is not available in the current keychain: $DEVELOPER_ID"
        exit 1
    fi

    if [[ "$SIGN_MODE" == "notarize" && -z "$NOTARY_KEYCHAIN_PROFILE" ]]; then
        echo "✘  NOTARY_KEYCHAIN_PROFILE is required for notarization."
        exit 1
    fi
fi

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
mkdir -p "$APP_DIR/Contents/Frameworks"
mkdir -p "$APP_DIR/Contents/Resources"

# ── Step 3: Compile ─────────────────────────────────────────────────────────
SWIFTPM_CONFIGURATION="debug"
SWIFT_BUILD_FLAGS=(--product "$APP_NAME" -c "$SWIFTPM_CONFIGURATION")

if [[ "$BUILD_MODE" == "release" ]]; then
    echo "→ Building SwiftPM product (release, optimised)..."
    SWIFTPM_CONFIGURATION="release"
    SWIFT_BUILD_FLAGS=(--product "$APP_NAME" -c "$SWIFTPM_CONFIGURATION")
else
    echo "→ Building SwiftPM product (dev)..."
fi

if [[ "$SIGN_MODE" != "sign" && "$SIGN_MODE" != "notarize" ]]; then
    SWIFT_BUILD_FLAGS+=(-Xswiftc -DAD_HOC -Xcc -DAD_HOC)
fi

swift build "${SWIFT_BUILD_FLAGS[@]}"
BIN_PATH=$(swift build -c "$SWIFTPM_CONFIGURATION" --show-bin-path)
cp "$BIN_PATH/$APP_NAME" "$APP_DIR/Contents/MacOS/$APP_NAME"

# ── Step 4: Copy Info.plist ──────────────────────────────────────────────────
echo "→ Copying Info.plist..."
cp App/Milo/Info.plist "$APP_DIR/Contents/Info.plist"
if [[ -n "${MILO_SERVICE_BASE_URL:-}" ]]; then
    /usr/bin/plutil -replace MiloServiceBaseURL -string "$MILO_SERVICE_BASE_URL" "$APP_DIR/Contents/Info.plist"
fi
if [[ -n "${MILO_LICENSE_PUBLIC_KEY:-}" ]]; then
    /usr/bin/plutil -replace MiloLicensePublicKey -string "$MILO_LICENSE_PUBLIC_KEY" "$APP_DIR/Contents/Info.plist"
fi
if [[ -n "${SPARKLE_PUBLIC_ED_KEY:-}" ]]; then
    /usr/bin/plutil -replace SUPublicEDKey -string "$SPARKLE_PUBLIC_ED_KEY" "$APP_DIR/Contents/Info.plist"
fi

if [[ "$SIGN_MODE" == "sign" || "$SIGN_MODE" == "notarize" ]]; then
    COPIED_BUNDLE_ID=$(/usr/bin/plutil -extract CFBundleIdentifier raw "$APP_DIR/Contents/Info.plist")
    if [[ "$COPIED_BUNDLE_ID" != "$BUNDLE_ID" ]]; then
        echo "✘  Bundle identifier mismatch: $COPIED_BUNDLE_ID"
        exit 1
    fi

    for REQUIRED_KEY in \
        MiloServiceBaseURL \
        MiloLicensePublicKey \
        SUPublicEDKey; do
        REQUIRED_VALUE=$(/usr/bin/plutil -extract "$REQUIRED_KEY" raw "$APP_DIR/Contents/Info.plist")
        if [[ -z "$REQUIRED_VALUE" || "$REQUIRED_VALUE" == *'$('* || "$REQUIRED_VALUE" == *"REPLACE"* ]]; then
            echo "✘  Signed release plist does not contain $REQUIRED_KEY."
            exit 1
        fi
    done
fi

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
if [[ "$SIGN_MODE" == "sign" || "$SIGN_MODE" == "notarize" ]]; then
    cat > "$ENTITLEMENTS_PATH" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.automation.apple-events</key>
    <true/>
</dict>
</plist>
EOF
else
    cat > "$ENTITLEMENTS_PATH" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.automation.apple-events</key>
    <true/>
</dict>
</plist>
EOF
fi

# ── Step 7: Code signing ────────────────────────────────────────────────────
if [[ "$SIGN_MODE" == "sign" || "$SIGN_MODE" == "notarize" ]]; then
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
    echo "→ Ad-hoc code signing (local QA only)..."
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
    DMG_NAME="${APP_NAME}-${VERSION:-1.0}.dmg"
    echo "→ Submitting $DMG_NAME for notarization..."

    xcrun notarytool submit "$DMG_NAME" \
        --keychain-profile "$NOTARY_KEYCHAIN_PROFILE" \
        --wait

    echo "→ Stapling notarization ticket..."
    xcrun stapler staple "$DMG_NAME"
    xcrun stapler validate "$DMG_NAME"
    spctl --assess --type open --context context:primary-signature -vv "$DMG_NAME"

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
