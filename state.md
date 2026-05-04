# Milo Project State & Roadmap

## Current State: Phase 3 Completed
The foundational backend and security infrastructure is **100% complete, tested, and structurally flawless.**

*   **Rebrand:** The app was successfully globally rebranded from `pKill` to `Milo` by `monomacaw`. The bundle identifier is `com.monomacaw.milo`.
*   **Security Audit:** A rigorous "Zero Technical Debt" pass was completed. All `try?` and `!` operators were removed. File operations use safe `do-catch` blocks. `swiftlint` reports 0 serious violations.
*   **Database:** Supabase project is live. Schema (`schema.sql`) is executed with strict RLS and RPC functions.
*   **Edge Functions:** Deno functions (`paddle-webhook`, `generate-license`, `sync-signatures`) are deployed. Module conflicts with `ed25519` were resolved by shifting to pure JS `@noble/curves`.
*   **Verification:** The `test_paddle_webhook.swift` diagnostic tool successfully validated that HMAC-SHA256 signatures are correctly processed and the backend database updates properly.
*   **Binary Hardening:** `SecStaticCodeCheckValidity` is actively protecting the application's entry point (`main.swift`).

## Immediate Next Steps (Tomorrow's Session)
When the session resumes, the objective is to build the native macOS user interface that connects to our completed backend infrastructure.

1.  **Build `CheckoutManager.swift`:**
    *   Create an `ObservableObject` to manage the authentication and checkout state.
    *   Implement the Supabase Swift SDK to handle user session management.
2.  **Build the Authentication UI:**
    *   Create a gorgeous, native SwiftUI "Upgrade to Pro" paywall window.
    *   Implement "Sign in with Apple" (`ASAuthorizationAppleIDProvider`) as the primary login mechanism.
    *   Implement Email Magic Link as the fallback.
3.  **Integrate Paddle Checkout:**
    *   Wire the `paddleClientToken` and Paddle Price ID into the SwiftUI view.
    *   Ensure the Paddle checkout payload receives the Supabase `user.id` in its `custom_data` object. This is the critical link that allows the webhook to function.

## The 100% Rock-Solid Roadmap to Launch

*   **Phase 1: UI & Authentication Integration (Next Session)**
    *   Wire the UI to Supabase Auth.
    *   Connect the Paddle SDK/Web-Checkout.
    *   Test the full flow: Login -> Trial Start -> Paddle Purchase -> Webhook Fire -> Edge Function Verify -> App Unlock.
*   **Phase 2: The "Lite" App Store Build**
    *   Introduce a `#if LITE_VERSION` compiler flag.
    *   Strip out `PrivilegeManager` (sudo) and process termination execution logic for the App Store build.
    *   Replace action buttons with the "Upgrade to Pro at monomacaw.com" dialog.
    *   Verify the Lite build compiles and runs cleanly within Apple's App Sandbox.
*   **Phase 3: Telemetry & Signature Injection**
    *   Ensure the UI correctly reflects the dynamic blocklists retrieved from `CloudSignatureManager.swift`.
    *   Verify the UI gracefully handles the absence of cloud signatures if the license is expired.
*   **Phase 4: Release & Notarization**
    *   Execute `./build_app.sh release notarize` using the founder's Apple Developer ID.
    *   Verify the DMG works cleanly on a fresh macOS installation.
    *   Submit the `Lite` version to the Mac App Store.
