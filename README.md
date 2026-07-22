# Milo Engineering Bootstrap

Milo is a local-first macOS menu-bar process-management app. The active product architecture is the `App/Milo` SwiftPM executable plus `Packages/MiloKit`.

## Current Build Paths

### MiloKit Package

The v2 package lives under `Packages/MiloKit`:

```bash
cd Packages/MiloKit
swift package resolve
swift build
```

`MiloHardening` is split into a C target plus a Swift wrapper target because SwiftPM does not support mixed C and Swift source files in a single target. The public design boundary is unchanged: security-critical decisions live in C; Swift coordinates.

## Backend Contract

The backend lives in `/Volumes/Internal HD/Developer/monomacaw/website`. Milo does not own Supabase migrations, Paddle webhooks, or license Edge Functions. The app consumes Monomacaw License Protocol v1 from the website repo.

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
cd Packages/MiloKit
swift package describe
swift build

cd ../..
swift build -c release
./build_app.sh release
Tools/verify-build.sh /path/to/Milo.app
```

`./build_app.sh release` intentionally produces an ad-hoc signed QA artifact. It is not a production release.

## Release Machine Setup

Production release signing happens only on the dedicated release machine with the Developer ID private key available locally, preferably through the YubiKey-backed keychain identity.

Verify the signing identity:

```bash
security find-identity -v -p codesigning
```

The identity must be:

```text
Developer ID Application: <legal Apple developer name> (883MM2YM4N)
```

Store notarization credentials once on the release machine:

```bash
xcrun notarytool store-credentials milo-notary \
  --apple-id "$APPLE_ID" \
  --team-id 883MM2YM4N \
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
export DEVELOPER_ID="Developer ID Application: <legal Apple developer name> (883MM2YM4N)"
export NOTARY_KEYCHAIN_PROFILE="milo-notary"
export SPARKLE_PUBLIC_ED_KEY="<Sparkle Ed25519 public key>"

./build_app.sh release notarize
Tools/verify-build.sh Milo.app
spctl --assess --type open --context context:primary-signature -vv Milo-2.0.0.dmg
```

The signed release path fails before compilation if the Developer ID identity is missing, the Team ID does not match `883MM2YM4N`, or `SPARKLE_PUBLIC_ED_KEY` is absent or still a placeholder.

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

`Milo/Sources/Secrets.swift` is ignored and must not be printed, committed, or pasted into logs. Milo 2.0 moves secrets that must ship in the app into the obfuscated string pipeline described in `GEMINI.md`.
