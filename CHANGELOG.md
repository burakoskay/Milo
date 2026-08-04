# Changelog

All notable changes to Milo are documented here. Format: Keep a Changelog 1.1.0.
This project adheres to Semantic Versioning 2.0.0. Milo is pre-1.0: the public preview
series is `0.2.x`, and no 1.x release has shipped.

## [Unreleased]

## [0.2.0-preview.2] - 2026-08-04

Second Public Preview, and the first build under the gonggong name. Apple Development signed and
not notarized; macOS blocks the first launch until the user explicitly allows it.

This preview does **not** upgrade an installed `0.2.0-preview.1` in place. Its bundle identifiers
changed, so macOS treats it as a different application. Unregister the old helper from the old app
before installing — see the install notes in `README.md`.

### Changed

- Renamed the company from monomacaw to gonggong. Bundle identifiers move from `com.monomacaw.*` to `com.gonggong.*`, the privileged helper's mach service and launchd plist follow, Keychain service names and the device-key tag move with them, and the production service origin becomes `https://gonggong.tech`. See `docs/decisions/0001-rename-monomacaw-to-gonggong.md` for what deliberately did not move.
- A rebranded build does not adopt a previous install's registered helper or login item. Unregister the old helper from the old app before installing, or the pre-rebrand Background Item persists alongside the new one.
- Optimized process scanning performance in `DebloatManager.anyWidgetProcessesRunning` to avoid unnecessary string allocations.

### Added

- `docs/decisions/`, a numbered record of consequential decisions, their non-scope, and the external actions they oblige.

### Removed

- The secondary git mirror. The `gitlab` remote and the scheduled `mirror` workflow that pushed to it are gone. That workflow ran an unattended, destructive `git push --mirror` to a destination named only inside a secret; `origin` is now the single remote. See `docs/decisions/0004-retire-the-secondary-git-mirror.md`.
- The cross-repository MLP-v1 contract check in CI. Licensing is out of scope until 1.0, no backend is deployed, and the contract did not move to the new site repository, so the step could only pass against a stale repository. MiloKit's golden fixtures remain and are still exercised by `swift test`.

### Performance

- Eliminated redundant `/bin/ps` spawns during bulk termination, reducing overhead when terminating multiple processes.

### Fixed

- `Tools/build-development-preview.sh` now writes and re-verifies the `dist/Milo-Public-Preview.dmg.sha256` sidecar in the same run that produces the image. A rebuild previously replaced the DMG while leaving the previous build's checksum file beside it, so the recorded hash no longer described the artifact.

### Security

- Reject non-regular or oversized persistence files before decoding stats and whitelist configurations.

## [0.2.0-preview.1] - 2026-07-27

First Public Preview. Apple Development signed and not notarized;
macOS blocks the first launch until the user explicitly allows it.


### Added

- Instantaneous CPU measurement that differentiates cumulative task CPU time across two observations per scan, replacing the lifetime average reported by `ps -o %cpu`.
- Dynamic launchd detection via a read-only `launchctl list`, so processes managed by launchd are identified even when absent from the static rule catalogue.
- A distinct `wasRespawned` outcome separating "launchd restarted this agent" from "termination failed".
- An Actions menu owning every process shortcut, plus a keyboard shortcut reference in Settings.
- A preference controlling whether the dedicated window's close button hides Milo or quits it.
- Statistics, hidden processes, persistent launch items, and Quit in the dedicated window, which previously offered none of them.
- Screenshots and a public-facing README covering install, permission model, and limitations.
- A separately identified, locally unlocked Public Preview configuration and reproducible verified DMG build path.
- A signed `SMAppService` privileged helper with authenticated XPC, a fixed command policy, bounded execution, and process-identity metadata.
- Presentation-ready product documentation and a timeless roadmap separating preview capability from commercial release work.
- Typed, generation-aware operation lifecycle primitives covering every planned application operation domain and terminal outcome.
- Separately compiled `MiloLite` sandbox target with a networkless read-only application scanner, explicit capability limitations, and a no-collection privacy manifest.
- Minimal `MiloPrivilegedHelper` launch-daemon target embedded in the Apple `SMAppService` bundle layout with a deny-all XPC connection boundary.
- Dedicated red-team, unit, integration, and Milo Lite UI test targets in the canonical Xcode project.

### Changed

- Restricts SwiftUI hosting to the active presentation surface, so the menu bar panel and the dedicated window can no longer both present the same confirmation.
- Derives view-mode transitions from an actual preference change rather than from every write in the application's `UserDefaults` domain.
- Returns the quit decision synchronously from `applicationShouldTerminate`, so choosing Quit terminates the application.
- Closes the dedicated window to the menu bar by default instead of running a termination flow that could not report a decision.
- Centralises menu bar panel geometry, which at its previous width clipped the header and footer at both edges.
- Routes privileged actions through a one-time macOS background-helper approval flow with explicit status and recovery UI.
- Labels the former Debloat surface as System Tuning while preserving the existing reversible tuning stack.
- Injects the cloud-rule service into process scanning instead of resolving mutable global state inside scan logic.
- Moves Pro, Lite, and helper identity/environment values into explicit per-target Xcode configuration files and makes the canonical Xcode product the only input to app/DMG packaging.
- Migrates every shipping target to Swift 6 complete concurrency checking, main-actor-isolates UI and persistence state, and makes the MLP device-license client an actor.
- Makes the browser-approved MLP-v1 device-key client the sole Pro licensing path and presents explicit pairing, refresh, account-management, and disconnect states in the paywall.
- Restricts the Pro bundle to a validated Monomacaw service URL plus the public MLP verification key.
- Reduces MiloKit to implemented domain, hardening, licensing, update-policy, and Sparkle boundaries.
- Replaces query-string license/device update routing with device-authenticated MLP discovery, exact SHA-256 appcast preflight, and a Pro-only Sparkle 2.9.4 composition path.

### Deprecated

### Removed

- Removes sudoers installation, cached passwordless-sudo state, and AppleScript administrator-prompt fallback from runtime actions.
- Removes desktop-held Supabase sessions, native Sign in with Apple, email magic-link handling, the custom auth callback, embedded Paddle/WebKit checkout, and the Debug/Ad Hoc Pro bypass.
- Removes ten unused feature-shaped package placeholders, including the duplicate unsynchronized package `ProcessManager`.

### Fixed

- Prevent overlapping process scans from publishing stale results and prevent scan failures from appearing as a clean system.
- Normalize the tracked `Milo_black.png` resource casing so Xcode project generation is byte-identical on case-sensitive clean clones.
- Fix string interpolation bug in SelfTestRunner that generated invalid temporary directory paths for cache tests.

### Security

- Revalidates executable path and kernel process start time before every TERM or KILL signal in both the app and privileged helper, rejecting PID reuse.
- Runs allowlisted commands and synthetic self-test children in private POSIX process groups with strict deadlines, task-cancellation propagation, bounded cleanup, and group-wide termination on timeout, cancellation, or output overflow.
- Restricts runtime logs to stable public event codes while keeping all caller-supplied diagnostic details private, with regression tests that reject free-form or caller-public logging.
- Bound combined subprocess stdout and stderr to a fixed byte budget and expose truncation as an explicit failed termination state.
- Separates Debug from production service configuration, validates all public verification-key inputs without logging values, keeps private credentials out of the client build, and rejects incomplete production packages.
- Enables current Xcode hardening defaults, requires documented synchronization proofs for every `@unchecked Sendable` boundary, and rejects unsafe concurrency escape hatches in regression tests.
- Disables Xcode base-entitlement injection for Release builds so distribution artifacts cannot inherit `com.apple.security.get-task-allow`.
- Adds source and release-binary regression gates that reject legacy desktop authentication/licensing markers and AuthenticationServices/WebKit linkage.
- Pins Sparkle exactly, disables its sandbox-only downloader service in Pro, rejects remote appcast redirects and oversized/encoded/untrusted responses, requires signed feeds without fail-open expiry, verifies archives before extraction, and keeps automatic update checks disabled until authenticated scheduling is implemented.

## [1.0.0] - 2026-XX-XX

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
