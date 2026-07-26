# Milo build configuration

These tracked `.xcconfig` files contain non-secret target identity and safe,
fail-closed defaults. Debug Pro builds use the MLP golden-fixture public key and
an RFC 2606 `.invalid` service host, so development cannot mutate production by
accident. A repository-only Release build deliberately has empty public signing
keys and is not distributable.

`Tools/generate-build-configuration.sh` validates release inputs and writes an
ephemeral override for `xcodebuild`. The override contains public verification
keys, never private signing material. Developer ID and notarization credentials
remain in the macOS Keychain; backend, Paddle, Supabase, license-signing, and
Sparkle private keys must never enter an app build setting, plist, source file,
artifact, or log.
