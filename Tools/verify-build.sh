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

CONFIGURATION_ENVIRONMENT=$(/usr/bin/plutil -extract MiloConfigurationEnvironment raw "$APP_PATH/Contents/Info.plist")
if [[ "$CONFIGURATION_ENVIRONMENT" != "production" ]]; then
  echo "distribution app is not configured for the production environment" >&2
  exit 1
fi

SERVICE_BASE_URL=$(/usr/bin/plutil -extract MiloServiceBaseURL raw "$APP_PATH/Contents/Info.plist")
if [[ "$SERVICE_BASE_URL" != "https://monomacaw.com" ]]; then
  echo "distribution app service origin is not the canonical production origin" >&2
  exit 1
fi

LICENSE_PUBLIC_KEY=$(/usr/bin/plutil -extract MiloLicensePublicKey raw "$APP_PATH/Contents/Info.plist")
if [[ ! "$LICENSE_PUBLIC_KEY" =~ ^[A-Za-z0-9_-]{43}$ ]]; then
  echo "MLP public key is missing or malformed" >&2
  exit 1
fi
if [[ -n "${MILO_LICENSE_PUBLIC_KEY:-}" && "$LICENSE_PUBLIC_KEY" != "$MILO_LICENSE_PUBLIC_KEY" ]]; then
  echo "MLP public key does not match the release input" >&2
  exit 1
fi

SPARKLE_KEY=$(/usr/bin/plutil -extract SUPublicEDKey raw "$APP_PATH/Contents/Info.plist")
if [[ ! "$SPARKLE_KEY" =~ ^[A-Za-z0-9+/]{43}=$ ]]; then
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

SPARKLE_FRAMEWORK="$APP_PATH/Contents/Frameworks/Sparkle.framework"
if [[ ! -d "$SPARKLE_FRAMEWORK" ]]; then
  echo "pinned Sparkle framework is not embedded" >&2
  exit 1
fi
if ! otool -L "$EXECUTABLE" | grep -Fq '@rpath/Sparkle.framework/Versions/B/Sparkle'; then
  echo "Milo executable is not linked to the embedded Sparkle framework" >&2
  exit 1
fi
SPARKLE_VERSION=$(/usr/bin/plutil -extract CFBundleShortVersionString raw "$SPARKLE_FRAMEWORK/Resources/Info.plist")
if [[ "$SPARKLE_VERSION" != "2.9.4" ]]; then
  echo "unexpected embedded Sparkle version: $SPARKLE_VERSION" >&2
  exit 1
fi

for REQUIRED_SPARKLE_SETTING in \
  SURequireSignedFeed \
  SUVerifyUpdateBeforeExtraction; do
  SETTING_VALUE=$(/usr/bin/plutil -extract "$REQUIRED_SPARKLE_SETTING" raw "$APP_PATH/Contents/Info.plist")
  if [[ "$SETTING_VALUE" != "true" ]]; then
    echo "Sparkle security setting is not enabled: $REQUIRED_SPARKLE_SETTING" >&2
    exit 1
  fi
done

for DISABLED_SPARKLE_SETTING in \
  SUEnableAutomaticChecks \
  SUAutomaticallyUpdate \
  SUAllowsAutomaticUpdates \
  SUEnableSystemProfiling \
  SUShowReleaseNotes; do
  SETTING_VALUE=$(/usr/bin/plutil -extract "$DISABLED_SPARKLE_SETTING" raw "$APP_PATH/Contents/Info.plist")
  if [[ "$SETTING_VALUE" != "false" ]]; then
    echo "Sparkle setting must remain disabled: $DISABLED_SPARKLE_SETTING" >&2
    exit 1
  fi
done

if /usr/bin/plutil -extract SUFeedURL raw "$APP_PATH/Contents/Info.plist" >/dev/null 2>&1; then
  echo "static Sparkle feed URL bypasses authenticated one-shot composition" >&2
  exit 1
fi

SIGNED_FEED_EXPIRY=$(/usr/bin/plutil -extract SUSignedFeedFailureExpirationInterval raw "$APP_PATH/Contents/Info.plist")
if [[ "$SIGNED_FEED_EXPIRY" != "0" ]]; then
  echo "signed feed failure expiration must be disabled" >&2
  exit 1
fi

for FORBIDDEN_SPARKLE_KEY in \
  SUEnableDownloaderService \
  SUEnableInstallerLauncherService; do
  if /usr/bin/plutil -extract "$FORBIDDEN_SPARKLE_KEY" raw "$APP_PATH/Contents/Info.plist" >/dev/null 2>&1; then
    echo "non-sandboxed Pro bundle contains sandbox-only Sparkle key: $FORBIDDEN_SPARKLE_KEY" >&2
    exit 1
  fi
done

LEGACY_SUPABASE_URL='https://seohhuietluiqeadgllu''.''supabase.co'
if strings "$EXECUTABLE" | grep -q "$LEGACY_SUPABASE_URL"; then
  echo "legacy Supabase URL leaked in binary" >&2
  exit 1
fi

FORBIDDEN_BINARY_MARKERS=(
  'MiloSupabaseAnonKey'
  'MiloPaddleClientToken'
  'Paddle.Initialize'
  'AuthenticatedUpdateFeedState'
  'verifyLicenseAndFetchSignatures'
  'localDevelopmentUnlockEnabled'
)
for MARKER in "${FORBIDDEN_BINARY_MARKERS[@]}"; do
  if strings "$EXECUTABLE" | grep -Fq "$MARKER"; then
    echo "forbidden legacy licensing marker leaked in binary: $MARKER" >&2
    exit 1
  fi
done

FORBIDDEN_FRAMEWORKS=(
  '/AuthenticationServices.framework/'
  '/WebKit.framework/'
)
for FRAMEWORK in "${FORBIDDEN_FRAMEWORKS[@]}"; do
  if otool -L "$EXECUTABLE" | grep -Fq "$FRAMEWORK"; then
    echo "forbidden desktop authentication framework linked in binary: $FRAMEWORK" >&2
    exit 1
  fi
done

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
