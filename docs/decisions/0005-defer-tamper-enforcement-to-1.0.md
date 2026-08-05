# 0005. The runtime signature check detects; it does not enforce. Enforcement is deferred to 1.0

- **Status:** Accepted
- **Date:** 2026-08-05
- **Supersedes:** nothing. Constrained by decision 0002 (licensing deferred to 1.0)

## Context

`CLAUDE.md` described Milo's binary hardening as: the app calls `SecStaticCodeCheckValidity` at
the absolute entry point, and if a cracker modifies the binary "the code signature breaks, and the
app instantly crashes (`exit(173)`)".

A deliberate negative tamper test on 2026-08-05 (HANDOFF section 10) established that **every part
of that sentence was false**:

| Claim | Reality |
|---|---|
| `exit(173)` on failure | No `exit(173)` exists anywhere in the repository — and `Tests/redteam/Exit173RegressionTest.swift` **fails the build if the literal appears** under `App`, `Packages`, `Tools`, or `Tests` |
| At the absolute entry point | `MiloApp.init()` handles only the two test flags. The check runs in `applicationDidFinishLaunching`, after `LicenseManager` and `DebloatManager` are constructed |
| `SecStaticCodeCheckValidity` | It is `SecCodeCheckValidity` on `SecCodeCopySelf` — dynamic validation, which is why a `__LINKEDIT` modification that `codesign --verify` catches passes the runtime check |

What actually happened on failure: a `Milo.integrity.compromised` user default was written, a
warning was logged, and the app ran normally. Grepping `App`, `Helper`, `Packages` and `Tests`
found exactly one reference to that key — the write. An ad-hoc re-signed bundle launched and ran
indefinitely, fully functional.

So the question was not "why is enforcement broken" but "what should enforcement be", which had
never actually been decided.

## Decision

**Keep the check as a detection signal. Add no enforcement before 1.0.** Specifically:

1. The launch-time check stays, and continues to log `runtime.integrity-failed` on failure.
2. The packaged smoke suite keeps asserting the same requirement. That assertion is load-bearing
   for a different reason than piracy — see Consequences.
3. The write-only `Milo.integrity.compromised` default is **removed**. A flag nothing reads is
   worse than no flag: it reads as a control when it is a note to nobody, and it is exactly the
   sort of thing a later session wires an action to without re-opening this decision.
4. Documentation stops calling this "binary hardening" in a sense that implies it stops anyone.
   It is described as what it is: evidence about *which build is running*.

Three reasons, in order of weight:

**There is nothing to pirate.** Decision 0002 defers licensing to 1.0. No backend is deployed, no
device is enrolled, there are no paid users, and the Public Preview deliberately unlocks the local
Pro feature set for free. Enforcement today would defend a free build against a threat that does
not exist, and would be designed before anyone knows what it is defending — the response has to fit
the licensing model, and the licensing model is not built.

**Somebody already decided against the obvious enforcement, and guarded it.**
`Exit173RegressionTest.swift` exists specifically to keep `exit(173)` out. Its reasoning is
recorded nowhere, which is itself the argument for caution: overruling a guarded prior decision, to
solve a problem that does not yet exist, is how a project acquires the debt its own mandate
forbids. This record is the place that reasoning should have lived; the test survives, and now has
a decision record pointing at it.

**Refusing to run is the weakest option on its merits anyway.** It is trivially patched out by the
same person it targets — a cracker editing the binary edits the exit too — while a false positive
on a beta OS, a partially-written update, or an unusual signing state bricks the app for a
legitimate user with no recourse. That trade is bad in both directions.

## Explicitly not in scope

- Any UI for a compromised state. There is no state to show.
- Disabling privileged actions on a failed check. The helper's own code-signing requirement is the
  security boundary for the privileged path, and it is unaffected by this decision.
- The `__LINKEDIT` gap. A static check of the on-disk bundle would close it; that belongs with
  whatever enforcement is eventually built, not before it.
- Removing the check. It earns its place — see below.

## Consequences

**The smoke suite's *Runtime code signature* check becomes the primary justification for the code
existing at all, and must not be removed as "unused".** It is what proved the gonggong rename had
not broken the requirement string in `MiloHardening/Integrity.c`. A mistake there produces a false
compromise verdict at launch rather than a build failure, so nothing else would have caught it.

**Milo must not be described as protected against a cracked build.** Not in `README.md`, not in
marketing, not in an interview. It detects and reports; it does not prevent. Saying otherwise is a
false security claim about a product that handles a root helper.

**When licensing lands, this decision is revisited as part of that work, not separately.** The
enforcement response has to fit the licensing model — what a failed check means depends on whether
there is a license to check. At that point, pair it with a static on-disk check to close the
`__LINKEDIT` gap, and decide the `exit(173)` question deliberately, superseding this record.

**A user default may linger.** `Milo.integrity.compromised` is no longer written, but a machine
where a build once failed the check still has it. It is inert — nothing reads it, and `true` is
indistinguishable from absent to every current code path. No migration is warranted; deleting a
key nobody reads would be busywork with its own failure modes.

## Required external actions

None.

## Verification evidence

The measurements this record rests on are in HANDOFF section 10, "Negative tamper test, measured on
2026-08-05". Summary: an ad-hoc re-signed bundle and a `__TEXT` byte flip both produce
`[FAIL] Runtime code signature`; the ad-hoc bundle launched and ran indefinitely; a `__LINKEDIT`
flip passes the runtime check while `codesign --verify` reports the bundle modified.

`DetectionOnlyIntegrityTests` pins this decision in code: it asserts the compromised
default is gone, that the check still runs and still logs, and that no termination call reaches the
failure path.

## Rollback

Reverting means choosing an enforcement response, which is the 1.0 conversation. If it is taken
earlier, supersede this record rather than editing it, and note what changed about the threat —
because the reason for this decision is the absence of anything to protect, not the difficulty of
protecting it.
