#!/bin/zsh

# Prepares a Milo release and stops before publishing.
#
# This script does everything that is mechanical and easy to get wrong: it checks that the tree,
# version numbers, changelog, and tag agree, runs every verification gate, produces the signed DMG
# and its checksum sidecar, and writes release notes. It deliberately does NOT push, tag remotely,
# or publish. It ends by printing the exact commands to run, so a human decides to publish.
#
#   Tools/release.sh 0.2.0-preview.3
#
# See docs/decisions/0003-release-and-development-process.md for the policy this enforces.

set -euo pipefail

SCRIPT_DIRECTORY="${0:A:h}"
REPOSITORY_ROOT="${SCRIPT_DIRECTORY:h}"
DIST_DIRECTORY="${REPOSITORY_ROOT}/dist"
DMG_PATH="${DIST_DIRECTORY}/Milo-Public-Preview.dmg"
DMG_CHECKSUM_PATH="${DMG_PATH}.sha256"
NOTES_PATH="${DIST_DIRECTORY}/release-notes.md"
APP_INFO_PLIST="${REPOSITORY_ROOT}/App/Milo/Info.plist"
LITE_INFO_PLIST="${REPOSITORY_ROOT}/App/MiloLite/Info.plist"
XCODE_APPLICATION="${MILO_XCODE_APPLICATION:-/Applications/Xcode-beta.app}"

fail() {
    print -u2 -- "release: $1"
    exit 1
}

step() {
    print -- ""
    print -- "── $1"
}

VERSION="${1:-}"
[[ -n "${VERSION}" ]] || fail "usage: Tools/release.sh <version>, for example 0.2.0-preview.3"

# Enforces the versioning rule: MAJOR.MINOR.PATCH, optionally -preview.N.
if [[ ! "${VERSION}" =~ '^[0-9]+\.[0-9]+\.[0-9]+(-preview\.[0-9]+)?$' ]]; then
    fail "version '${VERSION}' must look like 0.2.0 or 0.2.0-preview.3"
fi

MARKETING_VERSION="${VERSION%%-*}"
TAG="v${VERSION}"

[[ -d "${XCODE_APPLICATION}" ]] || fail "Xcode was not found at ${XCODE_APPLICATION}."
export DEVELOPER_DIR="${XCODE_APPLICATION}/Contents/Developer"

cd -- "${REPOSITORY_ROOT}"

step "Checking repository state"

if [[ -n "$(git status --porcelain)" ]]; then
    git status --short
    fail "the working tree is dirty. Commit or stash before releasing."
fi

CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
if [[ "${CURRENT_BRANCH}" != "main" ]]; then
    print -- "   warning: releasing from '${CURRENT_BRANCH}', not main."
    print -- "   Policy is to release from main after the change has merged through a PR."
    print -n -- "   Continue anyway? [y/N] "
    read -r reply
    [[ "${reply}" == "y" || "${reply}" == "Y" ]] || fail "aborted."
fi

if git rev-parse -q --verify "refs/tags/${TAG}" > /dev/null; then
    fail "tag ${TAG} already exists. Releases are immutable; pick the next version."
fi

step "Checking version numbers"

read_plist_value() {
    /usr/bin/plutil -extract "$1" raw -o - -- "$2"
}

APP_SHORT_VERSION=$(read_plist_value CFBundleShortVersionString "${APP_INFO_PLIST}")
APP_BUILD=$(read_plist_value CFBundleVersion "${APP_INFO_PLIST}")
LITE_SHORT_VERSION=$(read_plist_value CFBundleShortVersionString "${LITE_INFO_PLIST}")
LITE_BUILD=$(read_plist_value CFBundleVersion "${LITE_INFO_PLIST}")

[[ "${APP_SHORT_VERSION}" == "${MARKETING_VERSION}" ]] \
    || fail "App/Milo/Info.plist CFBundleShortVersionString is ${APP_SHORT_VERSION}, expected ${MARKETING_VERSION}."
[[ "${LITE_SHORT_VERSION}" == "${MARKETING_VERSION}" ]] \
    || fail "App/MiloLite/Info.plist CFBundleShortVersionString is ${LITE_SHORT_VERSION}, expected ${MARKETING_VERSION}."
[[ "${APP_BUILD}" == "${LITE_BUILD}" ]] \
    || fail "build numbers disagree: Milo is ${APP_BUILD}, Lite is ${LITE_BUILD}."
[[ "${APP_BUILD}" =~ '^[0-9]+$' ]] || fail "CFBundleVersion '${APP_BUILD}' is not a number."

# The build number must strictly increase, so two releases never share one. Compare against the
# highest build number recorded by an existing tag rather than trusting the working tree.
PREVIOUS_BUILD=0
PREVIOUS_PLIST=$(/usr/bin/mktemp -t milo-release-plist)
trap 'rm -f -- "${PREVIOUS_PLIST}"' EXIT INT TERM
for previous_tag in $(git tag --list 'v*'); do
    # plutil cannot read a plist from a pipe, so materialise each tagged copy first.
    git show "${previous_tag}:App/Milo/Info.plist" > "${PREVIOUS_PLIST}" 2> /dev/null || continue
    previous_value=$(/usr/bin/plutil -extract CFBundleVersion raw -o - -- "${PREVIOUS_PLIST}" 2> /dev/null) || continue
    [[ "${previous_value}" =~ '^[0-9]+$' ]] || continue
    (( previous_value > PREVIOUS_BUILD )) && PREVIOUS_BUILD=${previous_value}
done

(( APP_BUILD > PREVIOUS_BUILD )) \
    || fail "CFBundleVersion ${APP_BUILD} must be greater than ${PREVIOUS_BUILD}, the highest already released. Bump it in both Info.plist files."

print -- "   version ${MARKETING_VERSION}, build ${APP_BUILD} (previous released build: ${PREVIOUS_BUILD})"

step "Checking the changelog"

grep -q "^## \[${VERSION}\]" CHANGELOG.md \
    || fail "CHANGELOG.md has no '## [${VERSION}]' section. Write the release notes first."

step "Running verification gates"

print -- "   swiftlint"
swiftlint --strict --quiet

print -- "   swift test"
swift test > /dev/null

print -- "   swift test (MiloKit)"
swift test --package-path Packages/MiloKit > /dev/null

print -- "   xcodebuild test"
xcodebuild -quiet \
    -workspace Milo.xcworkspace \
    -scheme MiloPro \
    -configuration Debug \
    -destination "platform=macOS,arch=arm64" \
    CODE_SIGNING_ALLOWED=NO \
    test > /dev/null

step "Building and packaging"

Tools/build-development-preview.sh > "${DIST_DIRECTORY}/build.log" 2>&1 \
    || { tail -40 "${DIST_DIRECTORY}/build.log" >&2; fail "the preview build failed. Full log: ${DIST_DIRECTORY}/build.log"; }

# The packaged smoke suite must pass completely and must not have silently shrunk.
#
# This gate used to demand an exact "6 passed, 0 failed", which blocked the release the moment open
# discovery added six checks to the suite — a coverage increase reported as a release failure. The
# asymmetry that actually matters is: gaining checks is fine, losing them is not. Raise the minimum
# when the suite grows, so a check that quietly disappears still fails the release.
MINIMUM_SMOKE_CHECKS=12

SMOKE_SUMMARY=$(grep -m1 -E '^Summary: [0-9]+ passed, [0-9]+ failed$' "${DIST_DIRECTORY}/build.log") \
    || fail "the packaged smoke suite printed no summary line. Log: ${DIST_DIRECTORY}/build.log"

SMOKE_PASSED=$(print -r -- "${SMOKE_SUMMARY}" | /usr/bin/awk '{ print $2 }')
SMOKE_FAILED=$(print -r -- "${SMOKE_SUMMARY}" | /usr/bin/awk '{ print $4 }')

(( SMOKE_FAILED == 0 )) \
    || fail "the packaged smoke suite reported ${SMOKE_FAILED} failed. Log: ${DIST_DIRECTORY}/build.log"

(( SMOKE_PASSED >= MINIMUM_SMOKE_CHECKS )) \
    || fail "the packaged smoke suite reported only ${SMOKE_PASSED} passing checks, fewer than the ${MINIMUM_SMOKE_CHECKS} expected. A check disappeared rather than failed. Log: ${DIST_DIRECTORY}/build.log"

print -- "   packaged smoke suite: ${SMOKE_PASSED} passed, 0 failed (minimum ${MINIMUM_SMOKE_CHECKS})"

[[ -f "${DMG_PATH}" && -f "${DMG_CHECKSUM_PATH}" ]] || fail "the DMG or its checksum sidecar is missing."

CHECKSUM=$(/usr/bin/awk '{ print $1 }' "${DMG_CHECKSUM_PATH}")

step "Writing release notes"

# Extracts this version's section from the changelog, stopping at the next version heading.
{
    print -- "Milo ${VERSION}"
    print -- ""
    /usr/bin/sed -n "/^## \[${VERSION}\]/,/^## \[/p" CHANGELOG.md \
        | /usr/bin/sed '1d;$d'
    print -- ""
    print -- "### Verifying this download"
    print -- ""
    print -- '```'
    print -- "shasum -a 256 Milo-Public-Preview.dmg"
    print -- "${CHECKSUM}"
    print -- '```'
    print -- ""
    print -- "Apple Development signed and **not notarized**. macOS blocks the first launch until you"
    print -- "explicitly allow it; see the install section of the README."
} > "${NOTES_PATH}"

step "Tagging locally"

git tag -a "${TAG}" -m "Milo ${VERSION}"

print -- ""
print -- "Prepared ${VERSION} — nothing has been pushed or published."
print -- ""
print -- "  DMG       ${DMG_PATH}"
print -- "  SHA-256   ${CHECKSUM}"
print -- "  Notes     ${NOTES_PATH}"
print -- "  Tag       ${TAG} (local only)"
print -- ""
print -- "Before publishing, run the live smoke check from HANDOFF.md section 19:"
print -- "install the DMG, launch it, confirm the Public Preview badge, exercise one"
print -- "non-mutating helper request, and terminate one disposable synthetic process."
print -- ""
print -- "Then publish with:"
print -- ""
print -- "  git push origin ${CURRENT_BRANCH}"
print -- "  git push origin ${TAG}"
print -- "  gh release create ${TAG} \\"
print -- "    --prerelease \\"
print -- "    --title 'Milo ${VERSION}' \\"
print -- "    --notes-file '${NOTES_PATH}' \\"
print -- "    '${DMG_PATH}' '${DMG_CHECKSUM_PATH}'"
print -- ""
print -- "To undo the local tag: git tag -d ${TAG}"
