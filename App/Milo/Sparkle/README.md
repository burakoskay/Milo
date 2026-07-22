# Sparkle Release Configuration

`SUPublicEDKey` is injected through the `SPARKLE_PUBLIC_ED_KEY` build setting on the release machine.

Do not commit the Sparkle private key. The private key lives offline and is used only by `Tools/sign-appcast.swift sign-release` or Sparkle's official signing tooling during release.

The flat compatibility build path also injects `SPARKLE_PUBLIC_ED_KEY` into `Milo.app/Contents/Info.plist` from `build_app.sh` for signed and notarized releases. A signed release fails before compilation if this environment variable is absent or still a placeholder.
