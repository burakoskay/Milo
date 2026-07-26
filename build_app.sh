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
#   MILO_BUILD_OUTPUT_DIR    – isolated output directory, defaults to repository root
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

if [[ -z "${DEVELOPER_DIR:-}" ]]; then
    if [[ -d "/Applications/Xcode-beta.app/Contents/Developer" ]]; then
        export DEVELOPER_DIR="/Applications/Xcode-beta.app/Contents/Developer"
    elif [[ -d "/Applications/Xcode.app/Contents/Developer" ]]; then
        export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
    else
        echo "✘  A complete Xcode installation is required; Command Line Tools are insufficient."
        exit 69
    fi
fi

if [[ ! -x "$DEVELOPER_DIR/usr/bin/xcodebuild" ]]; then
    echo "✘  DEVELOPER_DIR does not identify a complete Xcode installation."
    exit 69
fi

APP_NAME="Milo"
OUTPUT_ROOT="${MILO_BUILD_OUTPUT_DIR:-.}"
mkdir -p "$OUTPUT_ROOT"
OUTPUT_ROOT=$(cd "$OUTPUT_ROOT" && pwd -P)
if [[ "$OUTPUT_ROOT" == "/" || "$OUTPUT_ROOT" == "$HOME" ]]; then
    echo "✘  Refusing unsafe build output directory: $OUTPUT_ROOT"
    exit 64
fi
APP_DIR="$OUTPUT_ROOT/$APP_NAME.app"
BUILD_MODE="${1:-dev}"     # dev | release
SIGN_MODE="${2:-}"         # sign | notarize | (empty)
VERSION=$(/usr/bin/plutil -extract CFBundleShortVersionString raw App/Milo/Info.plist)
ICON_WORK_DIR="$OUTPUT_ROOT/.build_icons"
DERIVED_DATA_DIR="$OUTPUT_ROOT/.milo-derived-data"
NOTARY_KEYCHAIN_PROFILE="${NOTARY_KEYCHAIN_PROFILE:-milo-notary}"

read_xcconfig_value() {
    local key="$1"
    local file="$2"
    /usr/bin/awk -v expected_key="$key" '
        {
            separator = index($0, "=")
            if (separator == 0) {
                next
            }
            candidate = substr($0, 1, separator - 1)
            sub(/^[[:space:]]+/, "", candidate)
            sub(/[[:space:]]+$/, "", candidate)
        }
        candidate == expected_key {
            value = substr($0, separator + 1)
            sub(/^[[:space:]]+/, "", value)
            sub(/[[:space:]]+$/, "", value)
            print value
            exit
        }
    ' "$file"
}

TEAM_ID=$(read_xcconfig_value MILO_TEAM_ID Configurations/Shared.xcconfig)
BUNDLE_ID=$(read_xcconfig_value MILO_BUNDLE_ID Configurations/MiloPro.Release.xcconfig)
if [[ ! "$TEAM_ID" =~ ^[A-Z0-9]{10}$ || "$BUNDLE_ID" != "com.monomacaw.milo" ]]; then
    echo "✘  Tracked Milo identity configuration is invalid."
    exit 78
fi

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

CONFIGURATION_TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/milo-build-configuration.XXXXXX")
GENERATED_XCCONFIG="$CONFIGURATION_TEMP_DIR/Milo.generated.xcconfig"
cleanup_configuration() {
    rm -rf "$CONFIGURATION_TEMP_DIR"
}
trap cleanup_configuration EXIT

if [[ "$BUILD_MODE" == "release" ]]; then
    export MILO_CONFIGURATION_ENVIRONMENT="production"
    export MILO_SERVICE_BASE_URL="${MILO_SERVICE_BASE_URL:-https://monomacaw.com}"
    export MILO_LICENSE_PUBLIC_KEY="${MILO_LICENSE_PUBLIC_KEY:-}"
else
    export MILO_CONFIGURATION_ENVIRONMENT="development"
    export MILO_SERVICE_BASE_URL="${MILO_SERVICE_BASE_URL:-https://milo-development.invalid}"
    export MILO_LICENSE_PUBLIC_KEY="${MILO_LICENSE_PUBLIC_KEY:-}"
fi
export SPARKLE_PUBLIC_ED_KEY="${SPARKLE_PUBLIC_ED_KEY:-}"
Tools/generate-build-configuration.sh "$GENERATED_XCCONFIG"

MILO_CONFIGURATION_ENVIRONMENT=$(read_xcconfig_value MILO_CONFIGURATION_ENVIRONMENT "$GENERATED_XCCONFIG")
GENERATED_SERVICE_BASE_URL=$(read_xcconfig_value MILO_SERVICE_BASE_URL "$GENERATED_XCCONFIG")
XCCONFIG_EMPTY_REFERENCE='$()'
MILO_SERVICE_BASE_URL="${GENERATED_SERVICE_BASE_URL//$XCCONFIG_EMPTY_REFERENCE/}"
MILO_LICENSE_PUBLIC_KEY=$(read_xcconfig_value MILO_LICENSE_PUBLIC_KEY "$GENERATED_XCCONFIG")
SPARKLE_PUBLIC_ED_KEY=$(read_xcconfig_value SPARKLE_PUBLIC_ED_KEY "$GENERATED_XCCONFIG")
export \
    MILO_CONFIGURATION_ENVIRONMENT \
    MILO_SERVICE_BASE_URL \
    MILO_LICENSE_PUBLIC_KEY \
    SPARKLE_PUBLIC_ED_KEY

echo "╔══════════════════════════════════════════╗"
echo "║  Milo Build Script  v${VERSION:-1.0}               ║"
echo "╚══════════════════════════════════════════╝"
echo ""

# ── Step 1: Clean ────────────────────────────────────────────────────────────
echo "→ Cleaning previous build..."
rm -rf \
    "$APP_DIR" \
    "$ICON_WORK_DIR" \
    "$DERIVED_DATA_DIR" \
    "$OUTPUT_ROOT/${APP_NAME}-${VERSION:-1.0}.dmg"

# ── Step 2: Build the canonical Xcode product ───────────────────────────────
XCODE_CONFIGURATION="Debug"
XCODE_DESTINATION=( -destination "platform=macOS,arch=$(uname -m)" )
if [[ "$BUILD_MODE" == "release" ]]; then
    XCODE_CONFIGURATION="Release"
    XCODE_DESTINATION=( -destination "generic/platform=macOS" )
    echo "→ Building canonical Xcode product (Release, Universal)..."
else
    echo "→ Building canonical Xcode product (Debug)..."
fi

xcodebuild \
    -workspace Milo.xcworkspace \
    -scheme MiloPro \
    -configuration "$XCODE_CONFIGURATION" \
    "${XCODE_DESTINATION[@]}" \
    -derivedDataPath "$DERIVED_DATA_DIR" \
    CODE_SIGNING_ALLOWED=NO \
    MILO_CONFIGURATION_ENVIRONMENT="$MILO_CONFIGURATION_ENVIRONMENT" \
    MILO_SERVICE_BASE_URL="$MILO_SERVICE_BASE_URL" \
    MILO_LICENSE_PUBLIC_KEY="$MILO_LICENSE_PUBLIC_KEY" \
    SPARKLE_PUBLIC_ED_KEY="$SPARKLE_PUBLIC_ED_KEY" \
    build

BUILT_APP="$DERIVED_DATA_DIR/Build/Products/$XCODE_CONFIGURATION/Milo.app"
if [[ ! -d "$BUILT_APP" ]]; then
    echo "✘  Xcode did not produce Milo.app at the expected path."
    exit 1
fi
/usr/bin/ditto "$BUILT_APP" "$APP_DIR"

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
# ── Step 6: Use the checked-in, reviewed Pro entitlements ───────────────────
ENTITLEMENTS_PATH="App/Milo/Milo.entitlements"

# ── Step 7: Code signing ────────────────────────────────────────────────────
if [[ "$SIGN_MODE" == "sign" || "$SIGN_MODE" == "notarize" ]]; then
    echo "→ Signing with Developer ID..."
    for NESTED_SPARKLE_COMPONENT in \
        "$APP_DIR/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc" \
        "$APP_DIR/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc" \
        "$APP_DIR/Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app" \
        "$APP_DIR/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate"; do
        codesign --force \
            --sign "$DEVELOPER_ID" \
            --options runtime \
            --timestamp \
            "$NESTED_SPARKLE_COMPONENT"
    done
    codesign --force \
        --sign "$DEVELOPER_ID" \
        --options runtime \
        --timestamp \
        "$APP_DIR/Contents/Frameworks/Sparkle.framework"
    codesign --force \
        --sign "$DEVELOPER_ID" \
        --options runtime \
        --timestamp \
        "$APP_DIR/Contents/Resources/MiloPrivilegedHelper"
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
    for NESTED_SPARKLE_COMPONENT in \
        "$APP_DIR/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc" \
        "$APP_DIR/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc" \
        "$APP_DIR/Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app" \
        "$APP_DIR/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate"; do
        codesign --force \
            --sign - \
            --options runtime \
            "$NESTED_SPARKLE_COMPONENT"
    done
    codesign --force \
        --sign - \
        --options runtime \
        "$APP_DIR/Contents/Frameworks/Sparkle.framework"
    codesign --force \
        --sign - \
        --options runtime \
        "$APP_DIR/Contents/Resources/MiloPrivilegedHelper"
    codesign --force \
        --sign - \
        --options runtime \
        --entitlements "$ENTITLEMENTS_PATH" \
        "$APP_DIR"
fi

# ── Step 8: Create DMG (release only) ───────────────────────────────────────
if [[ "$BUILD_MODE" == "release" ]]; then
    DMG_NAME="$OUTPUT_ROOT/${APP_NAME}-${VERSION:-1.0}.dmg"
    echo "→ Creating distributable DMG: $DMG_NAME ..."

    DMG_STAGING="$OUTPUT_ROOT/.dmg_staging"
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
    DMG_NAME="$OUTPUT_ROOT/${APP_NAME}-${VERSION:-1.0}.dmg"
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
    echo "  DMG: $OUTPUT_ROOT/${APP_NAME}-${VERSION:-1.0}.dmg"
fi
echo "════════════════════════════════════════════"
