# Claims

A claim tells every other session *who holds this work right now*. Assignees cannot do
this job: automation shares one GitHub account, so two orchestrators look identical.
The claim lives in the board's `Claimed by` text field and is the only coordination
signal the workflow trusts.

## Format

`<repo-slug>-<NN> @ <ISO-8601 UTC>` — e.g. `acme-03 @ 2026-08-29T15:10Z`. A dispatch
stamp (Two roles, below) is the same shape plus a literal trailing ` (stamp)` marker —
e.g. `acme-03 @ 2026-08-29T15:10Z (stamp)`. Schema in
[formats/claim.md](formats/claim.md).

## Taking an id at session start

1. Read every `Claimed by` value on the board (one query; filter to non-empty).
2. A claim is **stale** when its timestamp is more than 24 hours old **and** the claimed
   item has had no PR, commit or comment activity since that timestamp. Both conditions —
   an overnight session that is quietly merging is not stale.
3. Take the lowest number not held by a live claim. Record it in the session log.

## Granularity

- Orchestrated: claim the **epic**. Its issues inherit; nobody else works inside a claimed
  epic. A milestone target claims each epic as you start it, not all at once.
- Solo on a standalone issue: claim the issue.
- Refresh the timestamp whenever you merge something or start a wave, so the stale rule
  reads activity honestly.

## Collisions and takeovers

- A live claim by another id means the work is theirs. Do not touch its issues, PRs or
  file areas. Report the collision in chat (one line) and pick the next target or ask.
- A stale claim may be taken over: write your id, then post an event comment on the epic
  naming the superseded claim and its timestamp, so a resuming session sees it was
  superseded rather than discovering silently that its work moved.

## Two roles for `Claimed by`

The claim id plays two distinct roles that share one board field but never the same
purpose:

- **Coordination** (this file, above): the **epic-level** (or standalone-issue-level)
  claim is the live signal another session checks before touching anything. It is taken,
  refreshed and released per the rules above — a session collides on it, or defers to it.
- **Information**: at **dispatch**, the orchestrator also writes its claim id into the
  **dispatched issue's own** `Claimed by` field, in the dispatch-stamp form
  (`formats/claim.md`'s trailing ` (stamp)` marker) — purely a board-visible ownership
  stamp for the in-flight view, not a second coordination lock. It answers "whose agent
  is working this issue" at a glance across concurrent sessions; nothing reads it to
  decide whether work is safe to start — the coordination claim still governs that. It
  is written once, at dispatch, and is **never cleared at merge**: a closed issue keeps
  its stamp as the ownership ledger, the same way `Verified` is never cleared on a
  closed item.

**The tell** (issue #744): for any value written from #744 forward, the literal
` (stamp)` marker on the value's own text, read mechanically — never the issue's parent,
never its board column. A value carrying the marker is always a dispatch stamp, on any
issue, parented or standalone. A value with no marker is a coordination lock, subject to
the stale rule, **except** the one legacy carve-out the next paragraph states in full —
this is the only tell going forward, because parent presence alone could never resolve
the standalone case even before #744: a **standalone** issue's `Claimed by` plays either
role depending on how the work was dispatched — solo-worked as its own target
(Granularity, above: `take` writes the plain, unmarked lock form directly onto the
issue), or dispatched as one piece of an orchestrated session whose real coordination
claim lives elsewhere (an epic, or nothing at all, when the session works a milestone of
parentless deferred issues) — in which case its own field only ever carries a dispatch
stamp, marker and all, even though it has no parent. The marker removes the inference
entirely for new values (#732's extraction-vs-interpretation rule: a script reads the
marker, it never infers meaning from context).

**Legacy values and migration — the one place the parent still matters**: every dispatch
stamp written before #744 landed carries no marker, so it remains syntactically
identical to a coordination lock. This is the exception the tell above carves out: on a
**parented** issue, an unmarked legacy value is still read as a dispatch stamp, resolved
by the pre-#744 rule (parent presence) rather than by the marker that value never had
the chance to carry — the marker is additive from #744 forward, not a retroactive
requirement. On a **standalone** issue, an unmarked legacy value stays genuinely
ambiguous — it could be either role — until it ages past the 24-hour stale window (after
which the normal stale-takeover path resolves it regardless) or is migrated by hand; this
is exactly the ambiguity that bit `acme-04` at its own startup once (28 standalone
issues, each carrying a dispatch stamp indistinguishable-by-parent from a live lock). The
concurrent-session check (SKILL.md startup item 7, `concurrent-check`) reads every
non-empty `Claimed by` value on the board and skips as a dispatch stamp, never a lock:
every marked value, on any issue, plus every unmarked legacy value on a **parented**
issue; an unmarked value on a standalone issue is read as a coordination lock, subject to
the stale rule, until it is migrated or ages out. This PR does not retroactively rewrite
existing board values — a machine cannot tell a standalone issue's un-marked, still-live-
looking value apart from a real lock any more than the pre-#744 rule could, so a bulk
rewrite risks silently clobbering a live claim. A one-time, human-reviewed pass over
standalone issues' `Claimed by` values is filed separately as #767 (`deferred`,
`area:skills`) rather than attempted here.

## Releasing

Clear the **coordination** claim's `Claimed by` (epic or standalone issue) on handoff, on
`good morning` when the owner ends the session, and when the epic closes. A claim you
forget to release costs the next session a day (the stale window) — releasing is part of
finishing, not housekeeping. The **informational** issue-level stamp is exempt from this:
it is never cleared, at handoff or at merge.

## Per-item triage claims

[maintenance.md § 1 Triage drain](maintenance.md#1-triage-drain)'s `claim` step takes a
claim on the **item being triaged itself**, not on its epic (a Triage-column item has no
epic parent while it sits in the column; whether it ends up with one at all is what
`home` decides — a non-deferred item may be homed under an epic, a `deferred`-labelled
one never is) and not on the orchestrator's own claimed
epic/issue from the Granularity section above. It exists purely to coordinate concurrent
orchestrators draining the same Triage column at the same time: `stamp-claim.sh take`
against the item, first claimant decides the whole checklist for that item, a live claim
is never overwritten (`take` refuses with exit **3** when someone else already holds it —
the caller skips that item rather than waiting; act on the exit code, and see the Script
subsection below for all of them, exit **4** in particular), and a stale one may be taken
over by the same rule as any other claim (Collisions and takeovers, above).

It is a **coordination** claim in the Two roles sense, not the informational stamp: its
job ends the moment the item stops being contested, which is when `board` moves it out
of Triage — so `board` releases it (`stamp-claim.sh release --item <N> --id <claim>`,
[maintenance.md § 1](maintenance.md#1-triage-drain) step 10), the same way a coordination
claim is released on handoff. Leaving it set past that point would misreport an item
nobody is triaging anymore as still live-claimed, the same failure mode the stale-claim
rule exists to catch everywhere else.

**Cloud/by-hand equivalent**: the same as the Script subsection's below — read the
item's current claim, apply `take`/`takeover` by hand, and clear it by hand once `board`
moves the item out of Triage.

## Script

`scripts/stamp-claim.sh <take|refresh|release|takeover|stamp> --item <issue-number> --id
<claim-id> [--repo owner/name] [--log <path>] [--work-tracking <path>]` mechanises every
rule above: `take` (empty or stale only), `refresh`/`release` (mine only, and `release` on
an already-empty field is an idempotent no-op that issues no mutation), `takeover` (stale
only, logs the superseded id), and `stamp` for the informational dispatch stamp
(unconditional write of the marked `<id> @ <ts> (stamp)` form, never a coordination
check, logged as `claim-stamp`, never as `dispatch` — `formats/session-log.md` states
why). The four coordination verbs read the current `Claimed by` value and the item's
activity first and refuse — without issuing any mutation — before ever writing, exactly
per the rules in this file; `tests/test_stamp_claim.sh` proves the refusal paths issue
zero mutations against a mocked `gh`. A marked value (the literal ` (stamp)` suffix) is
never treated as a coordination claim by any of the four: `take` treats it exactly like
an empty field (writes a fresh, unmarked lock); `takeover`/`refresh`/`release` all
refuse it, the same as they refuse any value that is not theirs to act on, since a
stamp was never a coordination claim to take over, refresh or release. `stamp` is the
exception: it writes unconditionally, runs no live/stale check, and cannot tell an epic
from a dispatched issue on its own — pointing `--item` at an epic silently overwrites
that epic's live coordination claim, so the caller must always pass the dispatched
issue, never the epic, per the Two roles section above. The same clobber hazard applies
to a **standalone** issue that is simultaneously a coordination target (a session
solo-working it, per Granularity above) and a dispatch target (another session's
orchestrator stamping it): `stamp` cannot tell that configuration apart from the
ordinary case either, so it overwrites the live lock with a value that reads as a
takeable stamp (issue #771) exactly as unconditionally as it overwrites an epic's claim.
This is deliberate, not an oversight — `stamp` never runs the live/stale check by
design, the same design this paragraph already states for the epic case — and the
concurrent-session check (SKILL.md startup item 7) is what is supposed to prevent an
orchestrator from ever reaching this call in the first place: a session that skips that
check has already broken the rule that makes the clobber unreachable, so the fix belongs
in never skipping the check, not in adding a live/stale check to `stamp` that would
contradict the property this whole paragraph documents. A `take` on a live claim that is
already yours is an idempotent no-op (no mutation, `applied:false`, exit 0), so a
resumed session re-taking its own claim changes nothing.
<!-- exit-code-contract:begin — mirrored verbatim from stamp-claim.sh's header; issue #627 -->
Exit codes:
0 = applied, or an idempotent no-op (release on an already-empty field; take on a
live claim that is already mine). 2 = argument error -- a defect in the call itself,
not in the board state. 3 = a business-rule REFUSAL: the board state legitimately
says no (live foreign claim on take/takeover, takeover with nothing to take over,
refresh/release of a claim that is not mine). 1 = a HARD FAILURE: the GraphQL read or
mutation failed, the item is not on the board, the stored claim value or its
timestamp is malformed, or the timeline GET failed -- i.e. the script could not
determine or write the outcome at all. 4 = the verb SUCCEEDED (the mutation landed,
or the no-op applied, and the JSON was printed) but the --log line could not be
appended -- a local filesystem problem, never a claim problem. It is its own code
precisely so a caller cannot read it as a failed claim and act on a board that was in
fact written (issue #262 round 2, F1). 3-vs-1 exists so a caller can act on the
difference without parsing prose: a refusal is a normal concurrent-session outcome to
skip over, a hard failure is a defect or an outage and must be loud. In every
non-zero case the reason is on stderr, and nothing is printed on stdout on 1, 2 or 3. On
2 and 3 no mutation is ever attempted. On 1, most paths (argument/board/timeline
reads, malformed stored values) also precede any mutation, but two paths run only
after a mutation has already been attempted or has already landed: the GraphQL
mutation call itself failing exits 1 with the outcome unknown (landed server-side or
not); and, after a mutation that IS known to have landed, the result or log-event
JSON failing to build (issue #638) also exits 1, with the outcome known-applied but
unreported on stdout. This is exactly why 1 means "could not determine or write the
outcome at all, or could not report an outcome that is known to have landed" rather
than "definitely nothing changed". On 4 the mutation DID happen and the success JSON
is still the last line on stdout -- no non-zero code ever reports a partial success
as a full one, and none reports a completed write as if nothing was written.
<!-- exit-code-contract:end -->
Board and field ids come from `docs/process/work-tracking.md`, not from this file. On both
a `takeover` and a `take` that supersedes a stale claim, the script prints a stderr
reminder of — but never itself posts — the epic event-comment obligation above: the write
happens, the announcement stays the caller's job.

**Cloud/MCP equivalent** (no local `gh`, e.g. a cloud-run session): read the item's
current claim with the GitHub MCP server's project-items read tool (or an equivalent
GraphQL `projectV2Item` query) filtered to the `Claimed by` field; apply the same
take/refresh/release/takeover/stamp rules above by hand, checking staleness against the
item's recent PR/commit/comment activity; then write the new value with the project
field-update mutation (`updateProjectV2ItemFieldValue`) — the same mutation the script
issues, just invoked directly instead of through it.
