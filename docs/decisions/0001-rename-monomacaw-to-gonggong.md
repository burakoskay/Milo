# 0001. Rename monomacaw to gonggong

- **Status:** Accepted, and deliberately incomplete. Required external actions below are **not done**.
- **Date:** 2026-08-04
- **Branch:** `refactor/gonggong-rebrand`
- **Supersedes:** nothing

## Context

The company operating Milo is now named **gonggong**, on the live domain **gonggong.tech**
(verified 2026-08-04: HTTPS 200, valid Google Trust Services certificate issued 2026-07-28).
The previous name, monomacaw, was embedded in 42 tracked files across three unrelated layers:
brand prose, the pinned backend origin, and Apple bundle identifiers used in code-signing
requirements.

Those layers carry very different risk. Prose is cosmetic. The origin is a live network contract.
Bundle identifiers are load-bearing in code-signing designated requirements, the `SMAppService`
mach service name, and the launchd plist filename — a mismatch there does not fail loudly at build
time, it fails as a refused XPC connection or a false integrity-compromise state at runtime.

## Decision

Rename brand prose **and** bundle identifiers to `com.gonggong.*`, and repoint the production
origin to `https://gonggong.tech`.

Renamed:

| Layer | Before | After |
|---|---|---|
| Pro bundle | `com.monomacaw.milo` | `com.gonggong.milo` |
| Preview bundle | `com.monomacaw.milo.preview` | `com.gonggong.milo.preview` |
| Lite bundle | `com.monomacaw.milo.lite` | `com.gonggong.milo.lite` |
| Helper / mach service | `com.monomacaw.milo.helper` | `com.gonggong.milo.helper` |
| Helper launchd plist | `com.monomacaw.milo.helper.plist` | `com.gonggong.milo.helper.plist` |
| Test bundles | `com.monomacaw.milo.*-tests` | `com.gonggong.milo.*-tests` |
| Log subsystem | `com.monomacaw.milo` | `com.gonggong.milo` |
| Production origin | `https://monomacaw.com` | `https://gonggong.tech` |
| UI and doc prose | Monomacaw | Gonggong |

The signing requirement strings in `App/Milo/Runtime/PrivilegedHelperClient.swift`,
`Helper/MiloPrivilegedHelper/main.swift`, and
`Packages/MiloKit/Sources/MiloHardening/Integrity.c` were updated together, in the same commit.
They must always agree; changing one alone breaks the privileged boundary at runtime.

## Deliberately NOT renamed

These kept the `monomacaw` string on purpose. Renaming any of them is a separate, coordinated change.

| Item | Location | Why it stayed |
|---|---|---|
| `com.monomacaw.milo.mlp-v1` (Keychain service) | `LicenseService.swift` | Persistent storage key for device registration and pending enrollment. Renaming orphans enrolled devices, which then appear unenrolled with no error. |
| `com.monomacaw.milo.mlp-v1.device-key` (key tag) | `LicenseService.swift` | Secure Enclave key tag. Renaming orphans the device key and breaks request signing. |
| `com.monomacaw.milo.license` (Keychain service) | `LicenseService.swift` | Same store as the two above. The blanket rename initially hit only this one, which would have split one logical store across two service names; it was reverted so all three migrate together. |
| `mlp-v1-device-request-golden.json` | `MiloLicenseTests/Fixtures` | The `monomacaw.invalid` host is **inside signed request material**. Editing it invalidates the golden signature and the cross-repository contract vector. |
| "Monomacaw License Protocol v1" | prose, PR template | Proper name of the unchanged v1 wire format. Rename it when the protocol version changes, not before. |
| `MONOMACAW_*` secrets and vars | `.github/workflows/` | Names of GitHub secrets and variables that exist in repository settings. Renaming the YAML before renaming the secrets breaks CI immediately. |
| `burakoskay/monomacaw-website` | `.github/workflows/unit-tests.yml` | Real repository name. Not ours to guess. |
| Historical `CHANGELOG.md` entries | `CHANGELOG.md` | A changelog records what shipped under the name it shipped under. |

Net effect: **all Keychain state stays on the old service names.** That is coherent and safe today,
and it is a migration debt. When it is paid, it needs read-old/write-new with a fallback, not a
rename.

## Consequences

### Existing installs are orphaned, not upgraded

A rebranded build does not adopt anything the old build registered. On any Mac carrying a
pre-rebrand install:

- the Background Item `system/com.monomacaw.milo.helper` remains registered and independent of the
  new `system/com.gonggong.milo.helper`;
- the login item registered via `SMLoginItemSetEnabled("com.monomacaw.milo")` remains;
- preferences under the old bundle domain remain;
- Keychain items are unaffected, because those names deliberately did not change.

**Required order on this host** (the installed `/Applications/Milo.app` is still the pre-rebrand
`2.0.0` (`200`) build, and its helper is registered):

1. Launch the **old** app and unregister its helper through its own UI, so `SMAppService` removes
   `com.monomacaw.milo.helper` cleanly.
2. Confirm removal: `launchctl print system/com.monomacaw.milo.helper` should fail.
3. Only then install the rebranded build and enable its helper.

Do not delete launchd or BTM database files by hand to clear the old entry.

### Signing identity is unchanged

Team ID `8N738727QB` is unchanged. Only bundle identifiers moved.

## Required external actions — NOT DONE

These are outside this repository and block a production build:

1. **Apple Developer portal.** Register App IDs for `com.gonggong.milo`, `com.gonggong.milo.preview`,
   `com.gonggong.milo.lite`, and `com.gonggong.milo.helper` under Team `8N738727QB`, and reissue any
   provisioning profile. The `com.apple.developer.applesignin` entitlement is bound to the App ID and
   must be re-enabled for the new one.
2. **Backend.** `gonggong.tech` must serve the MLP endpoints and `/releases/milo/appcast.xml` before a
   production build validates. `Tools/generate-build-configuration.sh` and `Tools/verify-build.sh` now
   hard-require `https://gonggong.tech` and will fail the build otherwise.
3. **GitHub.** Rename the `MONOMACAW_*` secrets and variables, rename the website repository, then
   update `.github/workflows/` in one commit. Doing the YAML first breaks CI.
4. **Published artifacts.** Release `v0.2.0-preview.1` and its DMG remain pre-rebrand. They were not
   rewritten. The next release carries the new identifiers and is not an in-place upgrade of the old.

## Verification

Run on 2026-08-04 at the rebrand commit, macOS 27.0 (`26A5388g`), Xcode 27.0 beta (`27A5228h`),
Swift 6.4:

| Gate | Result |
|---|---|
| `swiftlint --strict` | 0 violations |
| `swift test` (root) | 18 red-team tests, 0 failures |
| `swift test` (MiloKit) | 29 tests, 0 failures, **including the MLP golden vector** |
| `xcodebuild -scheme MiloPro test` | 18 + 1 + 16, `** TEST SUCCEEDED **` |
| `Tools/build-development-preview.sh` | Clean build, `6 passed, 0 failed`, DMG verified |
| Signed app identifier | `com.gonggong.milo.preview` |
| Signed helper identifier | `com.gonggong.milo.helper` |

The packaged smoke check *Runtime code signature* passing is the meaningful evidence: it proves the
rewritten requirement in `Integrity.c` matches the newly signed identity. A mistake there would have
produced a false compromise state at launch rather than a build failure.

Not verified: any live launch, helper XPC round trip, or privileged action under the new identifiers.

## Rollback

`git revert` the rebrand commit and rebuild. Nothing outside the repository was mutated — no
Developer portal entry, no GitHub secret, no registered helper, and no published release was
changed — so a revert is complete on its own.
