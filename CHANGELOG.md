# Changelog

All notable changes to Milo are documented here. Format: Keep a Changelog 1.1.0.
This project adheres to Semantic Versioning 2.0.0 from version 2.0.0 onward;
version 1.x predates this regime.

## [Unreleased]

### Added

- Typed, generation-aware operation lifecycle primitives covering every planned application operation domain and terminal outcome.
- Separately compiled `MiloLite` sandbox target with a networkless read-only application scanner, explicit capability limitations, and a no-collection privacy manifest.
- Minimal `MiloPrivilegedHelper` launch-daemon target embedded in the Apple `SMAppService` bundle layout with a deny-all XPC connection boundary.
- Dedicated red-team, unit, integration, and Milo Lite UI test targets in the canonical Xcode project.

### Changed

- Moves Pro, Lite, and helper identity/environment values into explicit per-target Xcode configuration files and makes the canonical Xcode product the only input to app/DMG packaging.
- Migrates every shipping target to Swift 6 complete concurrency checking, main-actor-isolates UI and persistence state, and makes the MLP device-license client an actor.
- Makes the browser-approved MLP-v1 device-key client the sole Pro licensing path and presents explicit pairing, refresh, account-management, and disconnect states in the paywall.
- Restricts the Pro bundle to a validated Monomacaw service URL plus the public MLP verification key.
- Reduces MiloKit to implemented domain, hardening, licensing, update-policy, and Sparkle boundaries.
- Replaces query-string license/device update routing with device-authenticated MLP discovery, exact SHA-256 appcast preflight, and a Pro-only Sparkle 2.9.4 composition path.

### Deprecated

### Removed

- Removes desktop-held Supabase sessions, native Sign in with Apple, email magic-link handling, the custom auth callback, embedded Paddle/WebKit checkout, and the Debug/Ad Hoc Pro bypass.
- Removes ten unused feature-shaped package placeholders, including the duplicate unsynchronized package `ProcessManager`.

### Fixed

- Prevent overlapping process scans from publishing stale results and prevent scan failures from appearing as a clean system.
- Normalize the tracked `Milo_black.png` resource casing so Xcode project generation is byte-identical on case-sensitive clean clones.

### Security

- Runs allowlisted commands in private POSIX process groups with strict deadlines, task-cancellation propagation, bounded cleanup, and group-wide termination on timeout, cancellation, or output overflow.
- Restricts runtime logs to stable public event codes while keeping all caller-supplied diagnostic details private, with regression tests that reject free-form or caller-public logging.
- Bound combined subprocess stdout and stderr to a fixed byte budget and expose truncation as an explicit failed termination state.
- Separates Debug from production service configuration, validates all public verification-key inputs without logging values, keeps private credentials out of the client build, and rejects incomplete production packages.
- Enables current Xcode hardening defaults, requires documented synchronization proofs for every `@unchecked Sendable` boundary, and rejects unsafe concurrency escape hatches in regression tests.
- Disables Xcode base-entitlement injection for Release builds so distribution artifacts cannot inherit `com.apple.security.get-task-allow`.
- Adds source and release-binary regression gates that reject legacy desktop authentication/licensing markers and AuthenticationServices/WebKit linkage.
- Pins Sparkle exactly, disables its sandbox-only downloader service in Pro, rejects remote appcast redirects and oversized/encoded/untrusted responses, requires signed feeds without fail-open expiry, verifies archives before extraction, and keeps automatic update checks disabled until authenticated scheduling is implemented.

## [2.0.0] - 2026-XX-XX

### Added

- Sparkle 2 direct updates selected through authenticated MLP entitlement buckets.
- Keychain storage for signed license envelopes.
- Unified Monomacaw License Protocol v1 direction.
- C-backed hardening boundary for integrity checks, anti-debugging, anti-instrumentation, device fingerprinting, constant-time comparison, and honeypot consensus.
- GitHub release governance: Conventional Commits, changelog checks, protected tags, Dependabot, and nightly mirror workflow.
- Canonical generated Xcode workspace with a strict Swift 6 Pro target and shared hostless regression-test scheme while retaining MiloKit as local Swift packages.

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
- Aligns the runtime code-signing requirement and release verifier with the live Apple Developer Team ID.

## [1.x] - pre-SemVer

- See historical release notes at https://monomacaw.com/products/milo/changelog-legacy.
