# 0004. Retire the secondary git mirror

- **Status:** Accepted
- **Date:** 2026-08-04
- **Supersedes:** nothing

## Context

The checkout carried a second remote, `gitlab`, pointing at
`git@gitlab.com:burakoskay-group/burakoskay-project.git`, holding a stale tracking ref for the
long-merged `fable/milo-test` branch. The owner confirmed that mirror should not be live.

A scheduled workflow existed to feed it. `.github/workflows/mirror.yml` ran daily and on demand:

```yaml
git remote add mirror "$MIRROR_URL"
git push --mirror mirror
```

`MIRROR_URL` came from an `INTERNAL_MIRROR_URL` secret, and the GitLab remote was the only secondary
destination configured anywhere in the project.

Two properties made this worth removing rather than leaving dormant:

- `git push --mirror` is **destructive on its target**. It forces the destination's refs to match the
  source exactly, deleting any branch or tag the destination has and the source does not.
- It ran **unattended on a schedule**, to a destination named only inside a secret, so its actual
  target could not be confirmed by reading the repository.

## Decision

Remove the mirror entirely:

- deleted the `gitlab` remote from the checkout, along with its stale tracking refs;
- deleted `.github/workflows/mirror.yml`.

The `MONOMACAW_INTERNAL_MIRROR_URL` secret is now unreferenced and should be deleted from repository
settings.

This supersedes the plan in decision 0001 to rename that secret to `GONGGONG_INTERNAL_MIRROR_URL`.
There is nothing left to rename; the workflow that read it is gone.

The decision holds regardless of where the secret actually pointed. A scheduled, destructive, and
outward-facing push to an unverifiable destination is not something to keep running for a repository
whose only known mirror target is retired. If mirroring is wanted again, it should be reintroduced
deliberately, against a named destination.

## Consequences

- `origin` is now the single remote. `main` on GitHub is the only copy of record.
- There is no longer an off-GitHub backup of the repository. If one is wanted, it should be a
  deliberate, non-destructive backup rather than a scheduled `--mirror` push.
- The GitLab project itself was not touched. Its contents are whatever the last mirror run left; the
  owner can delete or keep it independently of this repository.
- One item leaves the outstanding-actions list: no GitHub secret needs renaming.

## Rollback

`git revert` the commit to restore the workflow, re-add the remote with `git remote add`, and
recreate the secret. Consider a non-destructive `git push` rather than `--mirror` if the destination
may hold refs that the source does not.
