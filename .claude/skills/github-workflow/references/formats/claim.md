# Claim value format

Board field `Claimed by` (text) takes exactly one of two forms, told apart by a literal
trailing marker — never by inference from the item's parent or board column (issue
#744):

- **Coordination lock**: `<repo-slug>-<NN> @ <ts>` — written only by `take` /
  `takeover` / `refresh`. The live signal another session checks.
- **Dispatch stamp**: `<repo-slug>-<NN> @ <ts> (stamp)` — the literal, invariant suffix
  ` (stamp)` (one space, the word `stamp`, parens) marks the value as the
  **informational** ownership stamp, written only by `stamp-claim.sh stamp`. Never a
  coordination lock, on any issue, parented or standalone — the marker is read
  mechanically, never inferred ([claims.md § Two roles](../claims.md)).

Shared fields:

- `repo-slug`: the repository name, lowercase.
- `NN`: two-digit number, lowest free at session start.
- `ts`: last refresh (start, wave start, merge) for a lock, or the dispatch time for a
  stamp, UTC, **exactly** `YYYY-MM-DDTHH:MMZ` (minute precision, literal `Z`):
  `date -u +%Y-%m-%dT%H:%MZ`. This is deliberately coarser than, and a different string
  entirely from, the session-log `ts` field (`formats/session-log.md`, second
  precision) — a human-facing board value has no need of the finer grain, and
  `stamp-claim.sh` computes the two from separate `date` calls rather than sharing one
  value between the board write and its own session-log line (issue #743). Stale rule
  (coordination locks only — a stamp is never stale, because it is never a lock): >24h
  old AND no PR/commit/comment activity on the item since.

Examples: `acme-03 @ 2026-08-29T15:10Z` (lock); `acme-03 @ 2026-08-29T15:10Z (stamp)`
(dispatch stamp).

**Legacy values**: every dispatch stamp written before issue #744 landed carries no
marker — syntactically identical to a coordination-lock value, so a reader cannot tell
the two apart from the text alone. This document states only the value's shape; the
reading rule for a legacy value (parented vs. standalone) and its migration note are
stated in exactly one place — [claims.md § Two roles](../claims.md#two-roles-for-claimed-by),
under "Legacy values and migration" — not repeated here.
