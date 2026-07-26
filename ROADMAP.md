# Milo roadmap

This roadmap describes product direction without promising delivery dates. Items move to complete only after their documented acceptance gates pass.

## Development Preview

- [x] Local process and launch-item scanning.
- [x] Locally unlocked Pro feature set with no account, payment, or backend dependency.
- [x] Explicit Development Preview identity and UI labeling.
- [x] One-time `SMAppService` helper flow with no sudoers or recurring password fallback.
- [x] Signed app/helper XPC authentication and fixed privileged command policy.
- [x] PID-reuse protection before every process signal.
- [x] Reproducible signed preview build and DMG verification script.
- [x] Presentation README and demo flow.

## Process-control reliability

- Expand typed per-target results for exited, replaced, protected, denied, timed out, and launchd-respawned processes.
- Add disposable-VM integration coverage for system launchd services, helper upgrade/version skew, reboot, denial, and uninstall.
- Version the local rule catalogue and add reviewed compatibility fixtures for supported macOS releases.
- Add user-visible action history with privacy-preserving, local-only diagnostics and export.

## Safe system tuning

- Replace legacy “debloat” terminology and rules with reviewed, reversible tuning recipes.
- Add an exact before/after preview and rollback record for every setting.
- Validate each recipe on clean macOS virtual machines with default SIP and security settings.
- Remove recipes that cannot be made deterministic, reversible, and supportable.
- Replace broad user-cache deletion with an explicit, app-scoped preview and per-item rollback-safe result model before restoring it to the UI.

## Commercial Pro service

- Complete browser-approved device enrollment and signed device-key authentication.
- Complete transactional Supabase migrations, RLS policies, device quota enforcement, revocation, and audit events.
- Complete Paddle product allowlisting, webhook signature verification, idempotency, ordering, refunds, cancellations, and reconciliation.
- Complete signed license-envelope verification, offline policy, clock handling, key rotation, and recovery.
- Complete signed dynamic telemetry rules with anti-rollback, staged rollout, emergency disable, and local cache recovery.
- Complete authenticated update discovery, signed Sparkle feeds, rollout control, and rollback policy.

## Distribution and operations

- Produce Universal Developer ID builds with hardened runtime.
- Automate archive signing, notarization, stapling, DMG verification, SBOM, provenance, and immutable release records.
- Validate quarantined installation and Gatekeeper behavior on clean default-security Macs.
- Complete privacy review, threat model, independent security assessment, accessibility audit, performance profiling, and long-running soak tests.
- Establish support diagnostics, incident response, signing-key rotation, rollback, and vulnerability disclosure procedures.

## Milo Lite

- Validate the sandboxed scanner against Mac App Store review constraints.
- Keep Lite read-only, networkless where practical, and free of Pro helper, updater, payment, and licensing implementation.
- Add clear capability education and a browser handoff to the Pro product page.
- Complete App Store privacy, accessibility, metadata, receipt, archive, and review testing.

## Product experience

- Continue macOS-native visual polish for menu bar and dedicated-window modes.
- Add comprehensive VoiceOver, keyboard, reduced-motion, high-contrast, and localization coverage.
- Add safe onboarding that adapts to helper status without nagging or permission loops.
- Add a concise in-app explanation of target confidence, impact, and recovery for every action.
