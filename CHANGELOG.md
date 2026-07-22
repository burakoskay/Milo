# Changelog

All notable changes to Milo are documented here. Format: Keep a Changelog 1.1.0.
This project adheres to Semantic Versioning 2.0.0 from version 2.0.0 onward;
version 1.x predates this regime.

## [Unreleased]

### Added

### Changed

### Deprecated

### Removed

### Fixed

### Security

## [2.0.0] - 2026-XX-XX

### Added

- Sparkle 2 auto-update with per-license entitlement filtering.
- Keychain storage for signed license envelopes.
- Unified Monomacaw License Protocol v1 direction.
- C-backed hardening boundary for integrity checks, anti-debugging, anti-instrumentation, device fingerprinting, constant-time comparison, and honeypot consensus.
- GitHub release governance: Conventional Commits, changelog checks, protected tags, Dependabot, and nightly mirror workflow.

### Changed

- Removes the standalone Milo backend from this repository. The website owns licensing, Paddle webhooks, device enrollment, update-feed filtering, and app policy documents.
- License cache fallback is bounded to 30 days from `issuedAt`.
- Device fingerprint comparison moves to the owned `mh_ct_equals` constant-time primitive.

### Removed

- App-local Supabase functions, migrations, and standalone backend migration scaffolding.

### Security

- Adds TLS SPKI pinning for Monomacaw backend traffic.
- Adds per-build salt support for integrity hashes, local-state derivation, and honeypot canaries.
- Adds red-team test scaffolding for crash-on-tamper regression.

## [1.x] - pre-SemVer

- See historical release notes at https://monomacaw.com/products/milo/changelog-legacy.
