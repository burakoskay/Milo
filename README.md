# Milo Engineering Bootstrap

Milo is a local-first macOS menu-bar process-management app. The canonical app build is the tracked `Milo.xcworkspace`; reusable domains remain in `Packages/MiloKit` as local Swift packages.

## Current Build Paths

### Xcode app workspace

Generate the tracked project only with the repository-pinned XcodeGen version:

```bash
brew install xcodegen
Tools/generate-xcode-project.sh
```

`Tools/generate-xcode-project.sh` fails unless XcodeGen 2.46.0 is active. Open `Milo.xcworkspace`, not the nested project. The generated project contains these explicit boundaries:

| Target | Current responsibility |
|---|---|
| `MiloPro` | Direct-distribution menu-bar app and the only app target that embeds `MiloPrivilegedHelper`. |
| `MiloLite` | Standalone sandboxed, networkless, read-only AppKit scanner prototype with no MiloKit, licensing, update, or helper dependency. Sandbox usefulness remains a Phase 12 release gate. |
| `MiloPrivilegedHelper` | Hardened command-line helper embedded at the `SMAppService` daemon layout. Its current XPC delegate denies every connection; authenticated operations are intentionally not implemented yet. |
| `MiloRedTeamTests` | Hostless shipping-source security regression tests. |
| `MiloUnitTests` | Hostless domain unit tests. |
| `MiloIntegrationTests` | Generated-target, entitlement, helper-layout, and product-boundary contract tests. |
| `MiloLiteUITests` | Milo Lite launch and truthful-capability UI smoke tests. |

Run the canonical Pro and Lite test schemes with:

```bash
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
xcodebuild \
  -workspace Milo.xcworkspace \
  -scheme MiloPro \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  CODE_SIGNING_ALLOWED=NO \
  clean test

xcodebuild \
  -workspace Milo.xcworkspace \
  -scheme MiloLite \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  CODE_SIGNING_ALLOWED=NO \
  clean test
```

The generated project is committed so clean CI does not depend on installing XcodeGen. Any change to `project.yml` must regenerate the project and commit both together.

Build the helper directly when validating it independently from the Pro embedding phase:

```bash
xcodebuild \
  -project Milo.xcodeproj \
  -target MiloPrivilegedHelper \
  -configuration Release \
  CODE_SIGNING_ALLOWED=NO \
  ONLY_ACTIVE_ARCH=NO \
  'ARCHS=arm64 x86_64' \
  clean build
```

### MiloKit Package

The v2 package lives under `Packages/MiloKit`:

```bash
cd Packages/MiloKit
swift package resolve
swift build
```

`MiloHardening` is split into a C target plus a Swift wrapper target because SwiftPM does not support mixed C and Swift source files in a single target. The public design boundary is unchanged: security-critical decisions live in C; Swift coordinates.

MiloKit publishes only implemented boundaries: `MiloDomain`, `MiloHardening`,
`MiloLicense`, `MiloUpdates`, and `MiloSparkle`. Feature-shaped placeholder
products are deliberately absent; the active app implementation remains under
`App/Milo` until a later phase extracts a complete, tested domain boundary.

## Backend Contract

The backend lives in `/Volumes/Internal HD/Developer/monomacaw/website`. Milo does not own Supabase migrations, Paddle webhooks, or license Edge Functions. The app consumes Monomacaw License Protocol v1 from the website repo.

The Pro app has one licensing path: `LicenseManager` adapts the
`MLPDeviceLicenseClient` device-key flow. It restores verified Keychain state,
starts and completes browser-approved pairing, refreshes with signed device
requests, and fails closed when client configuration is absent or invalid.
Account authentication and Paddle checkout stay in the system browser. The
desktop app contains no website session, Supabase user token, Paddle token,
embedded checkout, or custom auth callback.

Direct updates use the same enrolled device key. `MiloUpdates` validates the
MLP-selected HTTPS appcast and exact SHA-256 before a tokenized, loopback-only
bridge supplies those unchanged bytes to the Pro-only `MiloSparkle` adapter.
Sparkle 2.9.4 is pinned exactly, signed feeds can never fail open, archives are
verified before extraction, remote release-note downloads and automatic checks
are disabled, and Lite contains no updater code. See
`App/Milo/Sparkle/README.md` for the trust and release configuration.

The MLP-v1 golden fixture is copied into
`Packages/MiloKit/Tests/MiloLicenseTests/Fixtures/mlp-v1-golden.json` only so
SwiftPM tests can run without reaching into a sibling checkout at runtime. The
website repo remains canonical. Before changing license envelope shape, signing
bytes, or protocol-version semantics, update the fixture in the website repo,
run `npm run contract:fixture:sync` from the website checkout, then rerun:

```bash
Tools/verify-mlp-golden-fixture.sh
swift test --package-path Packages/MiloKit
```

CI checks out the website fixture into `_contract/website` and fails if Milo's
local fixture diverges. If the website repo is private, configure
`MONOMACAW_CONTRACT_READ_TOKEN` with read-only access and set
`MONOMACAW_WEBSITE_REPOSITORY` if the repository has moved.

## Release Governance

Milo follows SemVer 2.0.0 from `v2.0.0` onward. Commits on `main` use Conventional Commits 1.0.0, release tags are immutable annotated GPG-signed tags, and every product PR updates `CHANGELOG.md`.

Required process files live under `.github/`:

```text
.github/pull_request_template.md
.github/branch-protection.json
.github/workflows/conventional-commits.yml
.github/workflows/changelog-check.yml
.github/workflows/mirror.yml
.github/dependabot.yml
```

## Verification Spine

Use this order for local release checks:

```bash
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
Tools/generate-xcode-project.sh
xcodebuild \
  -workspace Milo.xcworkspace \
  -scheme MiloPro \
  -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  CODE_SIGNING_ALLOWED=NO \
  clean build

swift test --package-path Packages/MiloKit
swift build -c release
./build_app.sh release
Tools/verify-build.sh /path/to/Milo.app
```

`./build_app.sh release` is retained only for migration-era ad-hoc QA packaging. It is not the canonical Xcode build and does not produce a production release.

## Release Machine Setup

Production release signing happens only on the dedicated release machine with the Developer ID private key available locally, preferably through the YubiKey-backed keychain identity.

Verify the signing identity:

```bash
security find-identity -v -p codesigning
```

The identity must be:

```text
Developer ID Application: <legal Apple developer name> (8N738727QB)
```

Store notarization credentials once on the release machine:

```bash
xcrun notarytool store-credentials milo-notary \
  --apple-id "$APPLE_ID" \
  --team-id 8N738727QB \
  --password "$APP_PASSWORD"
```

Generate the Sparkle Ed25519 key pair on the offline/release machine. The private key never leaves encrypted offline storage. Only the public key is exported into the release shell:

```bash
swift Tools/sign-appcast.swift generate-key \
  /Volumes/Offline/Milo/sparkle-ed25519-private.raw \
  /Volumes/Offline/Milo/sparkle-ed25519-public.txt
```

```bash
export SPARKLE_PUBLIC_ED_KEY="$(cat /Volumes/Offline/Milo/sparkle-ed25519-public.txt)"
```

Build, sign, notarize, staple, and verify:

```bash
export DEVELOPER_ID="Developer ID Application: <legal Apple developer name> (8N738727QB)"
export NOTARY_KEYCHAIN_PROFILE="milo-notary"
export SPARKLE_PUBLIC_ED_KEY="<Sparkle Ed25519 public key>"
export MILO_SERVICE_BASE_URL="https://monomacaw.com"
export MILO_LICENSE_PUBLIC_KEY="<MLP Ed25519 public verification key in unpadded base64url>"

./build_app.sh release notarize
Tools/verify-build.sh Milo.app
spctl --assess --type open --context context:primary-signature -vv Milo-2.0.0.dmg
```

The signed release path fails if the Developer ID identity is missing, the Team
ID does not match `8N738727QB`, or required public verification/configuration
values are absent or still placeholders. These are public client inputs; all
private signing, Paddle, Supabase service-role, and browser-session material
remains outside the app and its build metadata.

## Update Feed Release Rows

`update-feed` is served by the website Supabase project and filters `app_releases` by the caller's license row:

- `app_releases.app_id = licenses.app_id`
- `app_releases.channel = 'production'`
- `app_releases.is_active = true`
- `app_releases.version <= licenses.max_app_version`
- `app_releases.release_date <= licenses.update_entitled_until`

Seed a signed Milo release only after the DMG is notarized and the Sparkle archive signature is produced offline:

```bash
swift Tools/sign-appcast.swift sign-release \
  Milo-2.0.0.dmg \
  /Volumes/Offline/Milo/sparkle-ed25519-private.raw \
  Milo-2.0.0.dmg.ed25519
```

```sql
INSERT INTO public.app_releases (
  app_id,
  channel,
  version,
  build_number,
  release_date,
  minimum_system_version,
  download_url,
  file_size,
  ed_signature,
  release_notes_url
) VALUES (
  'milo',
  'production',
  '2.0.0',
  '200',
  now(),
  '13.0',
  'https://monomacaw.com/products/milo/download/Milo-2.0.0.dmg',
  <byte_size>,
  '<contents of Milo-2.0.0.dmg.ed25519>',
  'https://monomacaw.com/products/milo/changelog#200'
);
```

Update checks use the device-key signing model documented in the website protocol registry. No app-shipped HMAC material is accepted.

## Secret Rules

The local compatibility file `App/Milo/Runtime/Secrets.swift` is ignored and must not be printed, committed, or pasted into logs. Tracked app code does not read it. Client-visible configuration is supplied through signed bundle metadata and validated without logging values; server secrets remain in server-side secret storage and are never shipped in the app.
