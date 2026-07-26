# Milo Product Capability Matrix

Status: founder-approved and frozen on 2026-07-23. This file is the target and
entitlement authority for Milo Pro and Milo Lite. A capability change requires
an explicit product/security review and revision here before implementation.

## Platform and distribution

| Property | Milo Pro | Milo Lite |
|---|---|---|
| Public identity | Milo by monomacaw | Milo Lite by monomacaw |
| Bundle ID | `com.monomacaw.milo` | `com.monomacaw.milo.lite` |
| Ecosystem app ID | `milo` | none |
| Distribution | Website, Developer ID, notarized | Mac App Store |
| Runtime form | `LSUIElement` menu-bar app | Sandboxed app target |
| Minimum deployment target | macOS 13 | macOS 13 until prototype evidence justifies a higher floor |
| macOS 27 | Native arm64 qualification required | Native arm64 qualification required |
| Intel claim | Universal app and pre-27 Intel test evidence required | Universal app and pre-27 Intel test evidence required |
| Purchase | Paddle in the system browser | No purchase or StoreKit UI |
| Updates | Sparkle with offline-signed appcast/artifact | App Store only |

Apple's default In-App Purchase service on the registered Lite App ID is not
product authorization to link StoreKit or offer a purchase.

## Capability ownership

| Capability | Milo Pro | Milo Lite | Enforcement boundary |
|---|---|---|---|
| Read-only process scan | Yes | Yes, only if sandbox prototype proves truthful useful visibility | separately compiled target/use case |
| Bundled signed-rule classification | Yes | Bundled rules only | target resource graph |
| Downloaded policy/rules | Signed policy | No | networking and policy module absent from Lite |
| Process signaling | Helper-mediated only | No | helper entitlement/XPC/use case absent from Lite |
| Launchd mutation | Helper-mediated, exact allowlist | No | helper policy absent from Lite |
| Root/admin operation | Typed helper only | No | no helper/sudo/AppleScript path in Lite |
| Broad filesystem access | Only narrowly justified user/system paths | No | sandbox entitlements and API graph |
| Device fingerprint | Local salted derivation for MLP | No | licensing module absent from Lite |
| Account/device enrollment | System-browser MLP pairing | No | licensing UI/service absent from Lite |
| Sign in with Apple | Website/browser flow; Pro App ID capability registered for future native need | No | Lite capability and code absent |
| Subscription entitlement | Seven-day signed offline envelope | No | MLP capability boundary |
| Pro promotion | Website/marketing outside Lite | No in-app purchase/download CTA | storefront-specific review gate |
| Usage/process telemetry | No | No | no collection pipeline |
| Local diagnostics export | Explicit, redacted, user initiated | Explicit, redacted, user initiated if implemented | allowlisted exporter |

## Pro safety rules

- Unknown, stale, heuristic-only, unsigned-policy, PID-reused,
  code-identity-mismatched, self, PID 1, or protected system targets are never
  eligible for process signaling or launchd mutation.
- Every destructive action requires current process identity, independent
  helper validation, explicit user intent, typed outcome, cancellation/deadline,
  and local redacted audit.
- AppleScript elevation, generic shell execution, broad sudoers entries, and
  Apple Events entitlement are prohibited production paths.
- A valid signed envelope grants full Pro only through its seven-day expiry.
  After expiry or clock rollback detection, Milo remains a truthful read-only
  scanner until refresh succeeds.

## Lite release gate

Lite is not shippable merely because it compiles or passes App Store signing.
A real sandboxed target on supported systems must prove that its read-only
scanner provides stable, accurately labeled, useful visibility without private
API, helper, root, broad file access, hardware identity, account, licensing,
Paddle, Sparkle, or downloaded executable policy. If the prototype cannot meet
that standard, Lite is deferred rather than weakened into misleading output.

## Change control

Any proposal to add a Lite entitlement, Pro promotion, account, network policy,
StoreKit surface, helper access, telemetry, or higher deployment floor must
include:

1. the user value and alternative;
2. Apple documentation/App Review basis;
3. privacy and threat-model delta;
4. target-graph and entitlement delta;
5. tests on every claimed architecture/OS; and
6. founder approval recorded in this file and the release evidence.
