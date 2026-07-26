#!/bin/zsh

set -euo pipefail

SCRIPT_DIRECTORY="${0:A:h}"
REPOSITORY_ROOT="${SCRIPT_DIRECTORY:h}"
XCODE_APPLICATION="${MILO_XCODE_APPLICATION:-/Applications/Xcode-beta.app}"
DERIVED_DATA="${REPOSITORY_ROOT}/build/DevelopmentPreviewDerivedData"
DIST_DIRECTORY="${REPOSITORY_ROOT}/dist"
STAGING_DIRECTORY="${REPOSITORY_ROOT}/build/DevelopmentPreviewDMG"
APP_SOURCE="${DERIVED_DATA}/Build/Products/Preview/Milo.app"
APP_STAGED="${STAGING_DIRECTORY}/Milo.app"
HELPER_RELATIVE_PATH="Contents/Resources/MiloPrivilegedHelper"
HELPER_STAGED="${APP_STAGED}/${HELPER_RELATIVE_PATH}"
DMG_PATH="${DIST_DIRECTORY}/Milo-Development-Preview.dmg"
TEAM_ID="8N738727QB"

fail() {
    print -u2 -- "Development Preview build failed: $1"
    exit 1
}

[[ -d "${XCODE_APPLICATION}" ]] || fail "Xcode was not found at ${XCODE_APPLICATION}."
[[ "${REPOSITORY_ROOT}" != "/" && -n "${REPOSITORY_ROOT}" ]] || fail "Invalid repository root."

export DEVELOPER_DIR="${XCODE_APPLICATION}/Contents/Developer"

rm -rf -- "${DERIVED_DATA}" "${STAGING_DIRECTORY}"
mkdir -p -- "${DIST_DIRECTORY}" "${STAGING_DIRECTORY}"
rm -f -- "${DMG_PATH}"

xcodebuild \
    -workspace "${REPOSITORY_ROOT}/Milo.xcworkspace" \
    -scheme MiloPro \
    -configuration Preview \
    -destination "platform=macOS,arch=arm64" \
    -derivedDataPath "${DERIVED_DATA}" \
    clean build

[[ -d "${APP_SOURCE}" ]] || fail "The Preview app product was not created."
/usr/bin/ditto "${APP_SOURCE}" "${APP_STAGED}"
[[ -x "${HELPER_STAGED}" ]] || fail "The privileged helper is missing from the app bundle."

/usr/bin/codesign --verify --deep --strict --verbose=2 "${APP_STAGED}"
/usr/bin/codesign \
    --verify \
    --strict \
    -R="anchor apple generic and identifier \"com.monomacaw.milo.preview\" and certificate leaf[subject.OU] = \"${TEAM_ID}\"" \
    "${APP_STAGED}"
/usr/bin/codesign \
    --verify \
    --strict \
    -R="anchor apple generic and identifier \"com.monomacaw.milo.helper\" and certificate leaf[subject.OU] = \"${TEAM_ID}\"" \
    "${HELPER_STAGED}"

APP_IDENTIFIER=$(/usr/bin/codesign -dv "${APP_STAGED}" 2>&1 | /usr/bin/sed -n 's/^Identifier=//p')
HELPER_IDENTIFIER=$(/usr/bin/codesign -dv "${HELPER_STAGED}" 2>&1 | /usr/bin/sed -n 's/^Identifier=//p')
[[ "${APP_IDENTIFIER}" == "com.monomacaw.milo.preview" ]] || fail "Unexpected app identifier."
[[ "${HELPER_IDENTIFIER}" == "com.monomacaw.milo.helper" ]] || fail "Unexpected helper identifier."

LLVM_PROFILE_FILE="${DERIVED_DATA}/MiloPreview-%p.profraw" \
    "${APP_STAGED}/Contents/MacOS/Milo" --preview-smoke-test

ln -s /Applications "${STAGING_DIRECTORY}/Applications"
/usr/sbin/diskutil image create from \
    --volumeName "Milo Development Preview" \
    --format UDZO \
    "${STAGING_DIRECTORY}" \
    "${DMG_PATH}"
/usr/bin/hdiutil verify "${DMG_PATH}"

print -- "Development Preview ready: ${DMG_PATH}"
