# 0003. Release and development process

- **Status:** Accepted
- **Date:** 2026-08-04
- **Supersedes:** nothing

## Context

Releasing was manual and undocumented, and it drifted in ways nobody noticed until a later session
went looking:

- `preview.1`'s checksum sidecar described a different build than the DMG sitting beside it, because
  the build script rewrote one and not the other;
- the app installed in `/Applications` fell four commits behind the source and nobody could tell,
  so live observations proved nothing about HEAD;
- a local tag `v2.0.0-preview.1` recorded a numbering scheme that had already been abandoned;
- "verified" meant "builds, signs, tests pass", which never once exercised the privileged helper at
  runtime — the single riskiest path in the product.

Each of these is cheap to prevent with a check and expensive to discover by accident.

## Decision

### Versioning

`MAJOR.MINOR.PATCH`, optionally `-preview.N`. Milo is pre-1.0.

- The **marketing version** (`CFBundleShortVersionString`) stays `0.2.0` across the preview series.
- The **build number** (`CFBundleVersion`) increments by one for every published release: 20, 21, 22.
  It must strictly exceed the highest build number of any existing tag. Two releases never share one.
- Tags are `v<version>`, for example `v0.2.0-preview.2`.
- Bump to `0.3.0` at a meaningful feature milestone. `1.0.0` only when licensing and notarization
  ship together.
- Both `App/Milo/Info.plist` and `App/MiloLite/Info.plist` carry the same numbers.

Releases are immutable. A published tag is never moved; the next problem gets the next number.

### Branching

Every change goes through a branch and a pull request. No direct commits to `main`.

The repository is public and `main` is gated by `unit-tests`, `conventional-commits`, and
`changelog-check`. Committing directly to `main` bypasses all three, which is how a release-blocking
mistake reaches the default branch unnoticed. Releases are cut from `main` after the merge.

### Releasing

`Tools/release.sh <version>` prepares a release and **stops before publishing**. It:

1. refuses a dirty working tree, and warns when run outside `main`;
2. refuses a version that already has a tag;
3. checks both `Info.plist` files agree, and that the build number exceeds every released build;
4. requires a matching `## [<version>]` section in `CHANGELOG.md`;
5. runs SwiftLint, both SwiftPM suites, and the Xcode test targets;
6. builds and packages the signed DMG with its checksum sidecar, and requires `6 passed, 0 failed`;
7. writes release notes from the changelog, including the verification checksum;
8. creates the annotated tag **locally only**;
9. prints the exact `git push` and `gh release create` commands, and exits.

A human runs the publish commands. Nothing about publishing is automated, because publishing is the
one step that cannot be undone quietly.

CI does not build releases. GitHub Actions cannot reproduce the local Apple Development signing
identity, so a CI-built artifact would be unsigned or would require signing secrets in the build
environment. Neither is acceptable for an artifact users execute.

### Definition of done for a release

The mechanical gates above are necessary and not sufficient. Before publishing, a human runs the
**live smoke check** in `HANDOFF.md` section 19: install the built DMG, launch it, confirm the
Public Preview badge, exercise one non-mutating privileged helper request, and terminate one
disposable synthetic process.

This exists because static verification structurally cannot catch the failures that matter most
here. A wrong code-signing requirement, a helper that registers but never launches, or a rejected
XPC peer all compile, sign, lint, and pass tests perfectly, then fail the first time a real user
clicks the button.

## Consequences

- Releasing is slower, and the slow parts are the ones that were silently skipped.
- The build-number check makes an abandoned tag actively blocking. `v2.0.0-preview.1` recorded build
  `200` under the discarded numbering scheme, which would have demanded `>200` forever; it was
  deleted (local-only, never pushed) rather than weakening the check.
- `Tools/release.sh` writes to `dist/`, which stays gitignored.
- The live smoke check cannot run unattended. That is deliberate; it is the human gate.

## Verification

`Tools/release.sh` was exercised end to end against `0.2.0-preview.2`. Its version, changelog, and
tag checks were each confirmed to fail correctly when given bad input, and a full successful run
produced the DMG, sidecar, notes, and local tag without publishing anything.

## Rollback

Delete `Tools/release.sh` and release by hand from the checklist in `HANDOFF.md` section 19. The
versioning and branching rules stand on their own and do not depend on the script.
