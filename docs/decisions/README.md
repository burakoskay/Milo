# Decision records

One file per consequential decision, numbered in the order it was taken. A record explains **why**
a choice was made and what it obligates, so a later session does not silently undo it.

Write a record when a decision:

- changes an identifier, wire format, or stored key that something outside this repository depends on;
- deliberately leaves a known inconsistency in place;
- constrains future work (a migration that must happen, an order operations must follow);
- or would otherwise be re-litigated from scratch by someone reading only the code.

Do not write one for ordinary implementation choices the code already explains.

## Format

Copy an existing record. Each has: status, date, context, decision, explicit non-scope, consequences,
required external actions, verification evidence, and rollback.

Set **Status** to `Accepted`, `Superseded by NNNN`, or `Reverted`. Never delete a record — supersede it.

## Index

| # | Title | Status | Date |
|---|---|---|---|
| [0001](0001-rename-monomacaw-to-gonggong.md) | Rename monomacaw to gonggong | Accepted, incomplete | 2026-08-04 |
| [0002](0002-defer-licensing-and-consolidate-docs.md) | Defer licensing to 1.0, HANDOFF.md is the single source of truth | Accepted | 2026-08-04 |

## Related documents

| Document | Purpose |
|---|---|
| `../../HANDOFF.md` | **Single source of truth**: what is built, installed, verified, unfinished, and next |
| `../../CHANGELOG.md` | What shipped, per release |
| `../../CLAUDE.md` | Agent directives and non-negotiable engineering rules |
