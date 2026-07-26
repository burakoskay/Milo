# Sparkle Release Configuration

Milo Pro is pinned to Sparkle 2.9.4 at revision
`b6496a74a087257ef5e6da1c5b29a447a60f5bd7`. Sparkle's package manifest
authenticates its 2.9.4 binary artifact with SHA-256
`cb6fdbdc8884f15d62a616e79face92b08322410fd2d425edc6596ccbf4ba3b0`.
Changing any of those values requires dependency review and the complete update
compatibility gate. Milo Lite must never link or embed Sparkle.

The Pro update path is:

1. The enrolled MLP device key authenticates `update-feed` and receives an HTTPS
   appcast URL plus its lowercase SHA-256.
2. `MiloUpdates` downloads that URL with an ephemeral, cookie-free, cache-free,
   size-bounded session that rejects redirects and encoded responses.
3. The exact downloaded bytes must match the authenticated SHA-256.
4. A random 256-bit path on an IPv4-loopback-only, two-minute HTTP listener
   serves only those verified bytes to Sparkle. The bytes are never rewritten.
5. Sparkle requires a signed appcast, never expires signing failures, verifies
   the archive before extraction, checks version progression, and validates the
   replacement app's code signature. Milo additionally restricts the channel,
   update type, and initial archive host.

Sparkle's public API cannot accept in-memory appcast data, which is why the
short-lived loopback bridge exists. `NSAllowsLocalNetworking` is the only ATS
exception and is required for that endpoint; arbitrary loads remain disabled.
Automatic checks and automatic installation stay disabled until Milo owns an
async scheduler that can refresh and preflight a new MLP descriptor before each
check. Current checks are explicit user actions. There is deliberately no
static `SUFeedURL`: the delegate supplies a one-shot local URL only after the
authenticated preflight succeeds.

`SUPublicEDKey` is injected through the `SPARKLE_PUBLIC_ED_KEY` build setting on
the release machine. Never commit the private key. It remains offline and is
used only by reviewed release tooling or Sparkle's official signing tools. The
flat compatibility build also injects the public key, embeds and signs the
pinned framework, and rejects a signed/notarized build when the public value is
absent or still a placeholder.
