#!/usr/bin/env bash
set -euo pipefail

APP_PATH="${1:-}"
EXPECTED_BUNDLE_ID="${EXPECTED_BUNDLE_ID:-com.monomacaw.milo}"
EXPECTED_TEAM_ID="${EXPECTED_TEAM_ID:-8N738727QB}"
EXPECTED_VERSION="${EXPECTED_VERSION:-2.0.0}"
EXPECTED_BUILD="${EXPECTED_BUILD:-200}"

if [[ -z "$APP_PATH" ]]; then
  echo "usage: Tools/verify-build.sh /path/to/Milo.app" >&2
  exit 64
fi

if [[ ! -d "$APP_PATH" ]]; then
  echo "app bundle not found: $APP_PATH" >&2
  exit 66
fi

codesign --verify --deep --strict --verbose=4 "$APP_PATH"
spctl --assess --type execute -vv "$APP_PATH"

BUNDLE_ID=$(/usr/bin/plutil -extract CFBundleIdentifier raw "$APP_PATH/Contents/Info.plist")
if [[ "$BUNDLE_ID" != "$EXPECTED_BUNDLE_ID" ]]; then
  echo "bundle id mismatch: expected $EXPECTED_BUNDLE_ID, got $BUNDLE_ID" >&2
  exit 1
fi

VERSION=$(/usr/bin/plutil -extract CFBundleShortVersionString raw "$APP_PATH/Contents/Info.plist")
if [[ "$VERSION" != "$EXPECTED_VERSION" ]]; then
  echo "version mismatch: expected $EXPECTED_VERSION, got $VERSION" >&2
  exit 1
fi

BUILD=$(/usr/bin/plutil -extract CFBundleVersion raw "$APP_PATH/Contents/Info.plist")
if [[ "$BUILD" != "$EXPECTED_BUILD" ]]; then
  echo "build mismatch: expected $EXPECTED_BUILD, got $BUILD" >&2
  exit 1
fi

TEAM_ID=$(codesign -dv --verbose=4 "$APP_PATH" 2>&1 | awk -F= '/^TeamIdentifier=/{print $2; exit}')
if [[ "$TEAM_ID" != "$EXPECTED_TEAM_ID" ]]; then
  echo "team id mismatch: expected $EXPECTED_TEAM_ID, got ${TEAM_ID:-none}" >&2
  exit 1
fi

SPARKLE_KEY=$(/usr/bin/plutil -extract SUPublicEDKey raw "$APP_PATH/Contents/Info.plist")
if [[ -z "$SPARKLE_KEY" || "$SPARKLE_KEY" == *'$('* || "$SPARKLE_KEY" == *"REPLACE"* ]]; then
  echo "Sparkle public key is missing or still a placeholder" >&2
  exit 1
fi

if [[ -n "${SPARKLE_PUBLIC_ED_KEY:-}" && "$SPARKLE_KEY" != "$SPARKLE_PUBLIC_ED_KEY" ]]; then
  echo "Sparkle public key does not match SPARKLE_PUBLIC_ED_KEY" >&2
  exit 1
fi

EXECUTABLE="$APP_PATH/Contents/MacOS/Milo"
if [[ ! -x "$EXECUTABLE" ]]; then
  echo "missing executable: $EXECUTABLE" >&2
  exit 65
fi

LEGACY_SUPABASE_URL='https://seohhuietluiqeadgllu''.''supabase.co'
if strings "$EXECUTABLE" | grep -q "$LEGACY_SUPABASE_URL"; then
  echo "legacy Supabase URL leaked in binary" >&2
  exit 1
fi

FORBIDDEN_MARKER='exit''(173)'
if strings "$EXECUTABLE" | grep -q "$FORBIDDEN_MARKER"; then
  echo "forbidden tamper-exit marker leaked in binary" >&2
  exit 1
fi

if otool -l "$EXECUTABLE" | grep -q '__DWARF'; then
  echo "debug segment present in release binary" >&2
  exit 1
fi

echo "verify-build passed"
