# Summary

## What changed

## Why

## Test plan

## Release notes

- [ ] `CHANGELOG.md` updated under `[Unreleased]`, or this PR is documentation/process-only with no user-visible behavior change.

## Compatibility

- [ ] Preserves Monomacaw License Protocol v1, or includes the coordinated website protocol change.
- [ ] Does not alter the `deviceId = SHA-256(serial || 0x00 || userId)` algorithm.
- [ ] Does not introduce immediate-crash tamper behavior.

## Security review

- [ ] No force unwraps, silent error swallowing, or forced casts.
- [ ] Security-critical verification remains in `MiloHardening` C code, with Swift limited to approved coordinator or primitive-trampoline roles.
- [ ] Any change touching `Packages/MiloKit/Sources/MiloHardening/`, `Packages/MiloKit/Sources/MiloLicense/`, entitlements, or `Info.plist` is marked for two-review approval.
