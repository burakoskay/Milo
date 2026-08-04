# 0002. Defer licensing to 1.0, and make HANDOFF.md the single source of truth

- **Status:** Accepted
- **Date:** 2026-08-04
- **Supersedes:** nothing

## Context

Two problems surfaced while reconciling repository state after the gonggong rename.

**Licensing had a CI dependency on a repository that no longer carries the contract.** The
`unit-tests` workflow checked out `burakoskay/monomacaw-website` to compare MLP-v1 golden fixtures
against the canonical copy. The new site repository, `burakoskay/gonggong-site`, is an Astro
marketing site with no `tests/fixtures` directory. The contract did not move with the brand. The
step could therefore only ever pass against a stale repository, and only while a deploy key for it
kept working.

**State was spread across too many documents.** `HANDOFF.md`, `README.md`, `ROADMAP.md`,
`CHANGELOG.md`, `docs/`, plus untracked `CLAUDE.md`, `GEMINI.md`, a 133 KB `July27plan.md`, and an
audit report all described the project. Several disagreed with each other and with the code — the
handoff still named a merged branch as current, and the archived plan still described a release
program that predates both the rename and the version scheme. A session picking this up had no way
to know which document to believe.

## Decision

### Licensing is out of scope until 1.0

There are no paid users, no deployed backend, and no enrolled devices. The commercial stack —
enrollment, Supabase, Paddle, signed license envelopes, dynamic telemetry rules, authenticated
updates — is deferred and treated as **one coordinated body of work**, not as individually
shippable items. It is listed as such in `HANDOFF.md` section 18.

The cross-repository contract check was **removed from CI**, not repointed. MiloKit keeps both
golden fixtures and `MLP1GoldenVectorTests` still exercises them in `swift test`, so the client's
own signing behaviour stays under regression test. `Tools/verify-mlp-golden-fixture.sh` remains in
the tree, dormant, for whenever a repository owns the contract again.

The MLP-v1 client code stays in MiloKit rather than being deleted. It compiles, it is tested, and
removing it would cost more than it saves.

### HANDOFF.md is the single source of truth

Exactly four documents carry state, with no overlap:

| Document | Answers |
|---|---|
| `HANDOFF.md` | What is built, installed, verified, unfinished, and next — right now |
| `docs/decisions/` | Why a consequential choice was made and what it obligates |
| `CHANGELOG.md` | What shipped, per release |
| `README.md` | The public-facing product, install, and limitation guide |

`ROADMAP.md` was folded into `HANDOFF.md` as section 18 ("Next") and deleted; a separate roadmap had
become a second place to describe unfinished work, which is precisely the confusion being removed.
Public links in `README.md` and `SECURITY.md` now point at that section.

`July27plan.md` and the GPT-5 audit report moved to `docs/archive/`. They remain gitignored and
local-only — `July27plan.md` was deliberately kept out of a public repository. They are history, and
explicitly **not instructions**.

If two documents disagree, `HANDOFF.md` wins and the other is stale.

## Consequences

- The `MONOMACAW_WEBSITE_REPOSITORY` and `MONOMACAW_CONTRACT_REF` variables and the
  `MONOMACAW_CONTRACT_DEPLOY_KEY` secret are now unused and can be deleted from repository settings.
- CI no longer needs any access to a second repository, which removes a private-repo deploy key from
  the build's trust surface.
- A drift between MiloKit's fixtures and a future backend will no longer be caught automatically.
  Restoring the check is listed in `HANDOFF.md` section 18 under the deferred commercial stack.
- Anyone looking for a roadmap file will not find one. That is intentional.

## Verification

`swift test --package-path Packages/MiloKit` passes, including `MLP1GoldenVectorTests`, with the CI
contract step removed. Full gate results are recorded in `HANDOFF.md` section 10.

## Rollback

Restore the two `unit-tests.yml` steps and point `repository:` at whichever repository owns the
contract. `Tools/verify-mlp-golden-fixture.sh` needs no change; set `MLP_GOLDEN_FIXTURE_DIR`.
