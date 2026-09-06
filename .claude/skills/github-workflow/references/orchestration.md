# Execution and orchestration

Read this at step 5. Solo mode uses the same loop with this session playing the
implementer and fix-round roles; the reviewer is a fresh agent in every mode.

## Division of labour

| Party | Model | May | May not |
|---|---|---|---|
| Orchestrator (this session) | — | dispatch agents, restart a stalled one; relay a round's `minor` in-diff findings to the resumed implementer and resume the reviewer (Report-handling checklist, `relay`); triage, sequence, batch and home issues; move Triage/Backlog/Ready; set and release claims; file issues agents left unfiled; body/doc-only fixes to its own side's PRs; run maintenance; rewrite milestone state | implement, review or merge non-trivial work; decide genuine design questions |
| Implementer | Routing table | implement ONE issue (or one named cohesive group — a deferred batch is one) in its own worktree; open the PR; file deferred issues; set **In progress** at start; when resumed once with relayed findings, the resume contract in [templates/implementer.md](templates/implementer.md)'s closing paragraph | spawn subagents; review; merge; touch the main checkout; decide design; fix anything beyond the relayed findings on resume |
| Fix-round agent | Routing table | fix exactly the review findings in the author worktree; post Fixes Applied; set **In progress** at start | spawn subagents; merge; expand scope |
| Reviewer | Routing table, fresh every round | everything in `github-pr-review`: set **In review** at start, route findings, commit `note`-severity fixes under the reviewer-applied gate, verdict, squash-merge, tick ACs, set `Verified` on merge (the `workflow-merge-verifier` writes it on the hand-back path), close-outs named in its handoff; may spawn helpers, never above its own tier, and only the `workflow-calibrator` type (Routing table's Calibrator row; canonical rule in `agent-rules.md`'s `helper-tier` block); may be resumed once within its round with a relayed head | be reused across rounds; merge a round in which it committed anything; spawn a helper above its own tier, or of any other type |
| Validation agent | Routing table | run a real stack; file bugs into the validation epic; flip `Verified` per issue; post summaries; close the validation epic when green | fix anything; dispatch anything |

Genuine design decisions go to the owner: label `help`, comment the options with a
recommendation, keep independent work moving. Owner-permission blockers (branch rules,
CI scope) get `help` too — surface, do not retry. The Model column above and every model
decision elsewhere in this file point at the **Routing table** below instead of naming a
model directly — read it there. Each role dispatches under a fixed identity that
resolves to its definition and pins its tool allowlist; see
[references/platform-claude.md](platform-claude.md) for how that pinning and the
model-precedence rule work on this harness.

## Routing table

Roles and rounds are dispatched at one of three tiers — `small (Claude: Haiku)`, `mid
(Claude: Sonnet)`, `large (Claude: Opus)` — never a bare model name; the Claude example
in parentheses is illustrative only, and the canonical tier→model mapping for whichever
harness is running lives in [platform-claude.md](platform-claude.md).

| Role / round | Tier |
|---|---|
| Implementer | mid (Claude: Sonnet) |
| Fix round 1, not design-shaped | mid (Claude: Sonnet) |
| Fix round ≥2 | large (Claude: Opus) |
| Fix round, final-entering | large (Claude: Opus) |
| Fix round, reviewer-labelled design-shaped | large (Claude: Opus) |
| Review, default | large (Claude: Opus) |
| Review round 1 of a doc-only PR | mid (Claude: Sonnet) |
| Review, residual-only final round | mid (Claude: Sonnet) |
| Merge-verification | mid (Claude: Sonnet) |
| Rebase | mid (Claude: Sonnet) |
| Calibrator | mid (Claude: Sonnet) |
| Validation agent | large (Claude: Opus) |
| Other helpers | small (Claude: Haiku) |

A fix round is **final-entering** when `reviews so far + 1 == the PR class's round cap`
— `reviews so far` is the round count `preflight.sh` reports (issue #658: this now
counts a completed `escalated` round the same as `changes_requested` and
`decomposition_requested`, so it no longer undercounts by one after an escalation), and
the cap comes from **PR class and round caps** below, as an integer: **3** for
executable-code, **2** for test-only/doc-only (one fix cycle). When `preflight.sh`
reports `rounds_is_lower_bound: true` (an unrecognized-verdict comment exists — issue
#716), treat the round being dispatched as final-entering regardless of what the
arithmetic above says: the true round count is at least one higher than what is
reported, so the count can read e.g. `1 + 1 == 3` false on a round that is actually
final-entering, and routing that round to the lighter tier is exactly the failure #658
fixed one instance of (issue #861) — the conservative branch is the only safe one when
the count itself is admittedly a lower bound. Worked example on an
executable-code PR (cap 3): round 1 comes back `changes_requested` (reviews so far now
1), round 2 comes back `escalated` and an owner ruling reopens it (reviews so far now
2, correctly — not 1) — the fix round dispatched next is round 3, and
`2 + 1 == 3` correctly marks it final-entering and routes it to the large tier; before
this fix, the miscount would have read `reviews so far` as 1 and routed that same round
at mid. This table is exhaustive: a role or round not listed
uses its tier's row default above (implementer default is mid; review default is large;
any other helper is small). The `Other helpers` row is that small-tier default and
nothing else: **no role documented here spawns it today** — the orchestrator dispatches
only the roles carrying their own rows above, the reviewer may spawn helpers of the
`Calibrator` row's type alone, and every other role either denies the Agent and Task
tools outright in its own `.claude/agents/` definition or, where it has no definition
file, is stated not to dispatch in the reference that defines it — the validation agent,
in [validation.md](validation.md). The row is kept so a helper type added later has a
tier before anyone argues one, not because some role reaches it now. Always set
`model` explicitly at dispatch; the resolution chain, and why an omission
is silent, are in [platform-claude.md § Subagent type pinning and model
precedence](platform-claude.md#subagent-type-pinning-and-model-precedence).

The implement and fix roles are never the same agent, in any round: a fresh fix-round
agent is dispatched every round, and the implementer is never resumed after a Changes
Requested verdict
— because routing switches tiers between rounds, the implementer's context is longest
exactly when the fixes are needed, and a fix agent anchored to its own PR's author is a
weaker check on that PR than a fresh one dispatched to fix it. The **relay** is the one
bounded exception and is not a fix round: `minor` findings inside the diff
(`github-pr-review` Step 7) go to the implementer resumed once, and the same reviewer
re-verifies them, inside one review round. Mechanics and the fallback where the harness
cannot resume: [platform-claude.md § Resuming a finished
agent](platform-claude.md#resuming-a-finished-agent).

## Column ownership (one owner each)

| Transition | Owner |
|---|---|
| Triage → Backlog / Ready; Backlog → Ready | orchestrator (during triage) |
| → In progress | implementer or fix-round agent, at its start — in solo mode that is **you**, the moment you start implementing or fixing. **Assign the issue to the acting account in the same breath**: the timeline's first `assigned` event is the durable start timestamp the estimator reads. |
| → In review | reviewer, at its start, every round |
| → Done | board automation on close |
| `Verified` at merge (`n/a` / `pending-live`) | reviewer, on the ordinary merge path; the `workflow-merge-verifier` writes it on the hand-back path (§ Entry paths, below) |
| `Verified` → `live-verified` / `live-failed` | validation agent |

Nobody sets a column they do not own. If a transition is missing, the owning role's
prompt is missing the instruction — fix the prompt, not the board.

## The loop, per issue

1. **Pick** the next issue, in this order: `blocked by` chain position first (an
   unblocked item whose dependants are waiting outranks a leaf with nothing behind it);
   then severity (bugs outrank non-bugs at equal chain depth); then `priority:*`; then
   age. Chain position leads because clearing a blocker pays off every issue queued
   behind it, while severity and priority only ever describe the one issue they are on.
   A **deferred batch** the triage drain marked dispatchable
   ([maintenance.md § Batching, after the per-item checklist](maintenance.md#batching-after-the-per-item-checklist))
   is picked as one item at the position of its highest-ranked member, and dispatched as
   one named cohesive group whose name is the batch's unit; its PR closes every member.
   A `deferred` item whose unit the latest `maintenance` event's `triage.batches` marks
   waiting is skipped here — it is picked with its batch, never alone. A batch's
   **riders** (parked issues `batch-deferred.sh` folded in, #802) are reopened and
   re-added with `home-deferred.sh --readd --status Ready` before the batch is
   dispatched, and the batch's PR closes them along with its regular members. Re-read
   the epic body; confirm the issue still fits; note anything a recent merge changed
   about it (comment on the issue if its scope moved).
2. **Dispatch** the implementer ([templates/implementer.md](templates/implementer.md))
   in the background, or implement yourself in solo mode. Run the **Dispatch checklist**
   below for every dispatch, in both modes — it is what actually stamps the claim, sets
   the model, and regenerates the manifest; this step names only the outcome.
3. **On the report**: run the **Report-handling checklist** below — its `deferrals` item
   is what files every finding the agent *mentioned* but did not file (dup-scan first),
   and `verdict` is what routes the round. For a reviewer's report the verdict comment
   is grepped there for the hand-back marker (§ Entry paths, below); a hit routes
   straight to the merge-verification round, which is the only place an
   approved-but-unmerged report can be caught, since it never reaches step 6's
   **Merged** trigger. A reviewer report that stopped on a `## Review Findings — relay`
   comment instead of a verdict is handled by the `relay` item. Also verify here, since
   no checklist item names it: a PR actually exists and is not draft, and labels are
   mirrored; copy the agent's strong claims into the reviewer's scrutiny points.
4. **Dispatch the reviewer** ([templates/review-dispatch.md](templates/review-dispatch.md)).
   Round *n* = number of **terminal verdict** comments + 1 — `## PR Review — Approved` /
   `Changes Requested` / `Decomposition Requested` / `Escalated`, all four, since every
   one is a round that happened (an `escalated` round is not an exception) — counted
   from the PR via `preflight.sh`, never from memory. A `## Review Findings — relay`
   comment is explicitly not one of the four and never advances the count. When an owner
   ruling reopens a PR that stopped on `Escalated`, the escalated round already counted,
   so the next dispatched round is `n`, not `n - 1`: do not subtract the escalation back
   out.
5. **Changes Requested** → dispatch a fix-round agent into the author worktree
   ([templates/fix-round.md](templates/fix-round.md)); body/doc-only findings you may fix
   yourself (run every Suggested Test Step you write before posting). Then a **fresh**
   reviewer. Round cap is by PR class (see **PR class and round caps** below):
   executable-code PRs get three rounds, then the reviewer escalates with `help` and you
   stop; test-only/doc-only PRs get one fix cycle, then the round-2 reviewer merges with
   deferred residuals per that section.
6. **Merged** → confirm on GitHub (reviewer reports occasionally outpace it): issue
   closed, branch gone, `Verified` set, and confirm the **Report-handling checklist**
   below already carried this same report's single pass on through its merge-only items
   (`metrics`, `epic-event`, `cleanup`, `claim-refresh`) at step 3 — together these are
   the worktree removal, the `-D`'d local branch, the `pull
   --ff-only`, the metrics closing comment
   ([templates/issue-metrics.md](templates/issue-metrics.md)) with the issue's estimate
   next to its actuals and the machine-readable footer the estimator reads, and the
   event comment on the epic ([templates/epic-event.md](templates/epic-event.md)) — what
   landed, drift from the design, findings worth remembering. Re-check whether the merge invalidates any in-flight
   sibling; a conflicting PR still in review gets a rebase directive to its author agent
   before the next review round. An **approved** PR that conflicts before merge instead
   goes through the **merge-verification round** below — not ordinary review; the
   hand-back variant of that same routing is detected earlier, at step 3's `verdict`
   item, since a hand-back report never reaches this **Merged** trigger.
7. **Epic children all closed** → the last reviewer closes the epic (name it in the
   handoff); you verify and post the closing event; rewrite the milestone's *Current
   state* wholly if the story's state changed.

## Dispatch checklist

Every dispatch runs this checklist — implementer at loop step 2, reviewer at loop step
4, fix round at loop step 5, rebase and merge-verifier at the **Merge-verification
round** below (including its Entry path variant), and the validation agent at
[validation.md](validation.md)'s own loop step 2. The **Routing table** above is
the authority for which tier each of these roles dispatches at; it is not a list
of orchestrator-dispatched roles, since its `Calibrator` row is reviewer-spawned,
its `Other helpers` row is a tier default for helpers no orchestrator dispatch
runs this checklist for, and its fix-round and review rows are rounds and variants
of one role. Where a role the orchestrator dispatches is added later, it runs
this checklist too even before this line names it. Run it in order, logging each
item as a `dispatch-item` event and closing with a `dispatch-complete` event
([formats/session-log.md](formats/session-log.md)); skip an item only with a `why`. A
dispatch step skipped when attention is already on the next thing leaves no trace unless
the log says it happened, so log every item — including the ones that plainly do not
apply to this dispatch — rather than letting silence stand in for "not needed here".

1. **`card-read`** — the session card is re-read, not re-derived from memory
   ([SKILL.md](../SKILL.md) step 0 item 6).
2. **`pick`** — the target issue's epic and body are re-read; confirm the issue still
   fits and note any scope drift a recent merge caused (loop step 1, above).
3. **`claim-stamp`** — the issue's own `Claimed by` is stamped with the session's claim
   id — the **informational** role in [claims.md](claims.md), distinct from the
   epic-level coordination claim; **write it now and never clear it**. It is written
   once, at the issue's first dispatch, so a later dispatch on the same issue (a fix
   round, or the reviewer) logs this item skipped with that as the `why` rather than
   re-stamping. This is `stamp-claim.sh stamp`'s own `claim-stamp` event, not folded
   into this item (see the naming note at that event's entry in
   [formats/session-log.md](formats/session-log.md)).
4. **`worktree`** — the worktree path and branch this dispatch owns is decided and named
   in the prompt.
5. **`board`** — the transition this dispatch's role owns is instructed, never made by
   the orchestrator acting as orchestrator (Column ownership, above): **In progress** by
   the implementer or fix-round agent at its own start, **In review** by the reviewer at
   the start of its round. Orchestrated: the item confirms the prompt carries that
   instruction, not that the column has already moved. Solo: for the implement or fix
   role there is no dispatched agent and you are that role — "in solo mode that is
   **you**" — so you set **In progress** yourself, assigning the issue to the acting
   account in the same breath, before the first commit.
6. **`model`** — the tier is set explicitly from the Routing table above; never a bare
   model name, never left to resolve by default.
7. **`preflight`** — reviewer dispatches only: `preflight.sh --markdown`'s block is
   generated and pasted into the prompt (skip with why for every other role).
8. **`evidence-key`** — the dispatch names its primary issue for evidence purposes
   (`agent-rules.md`'s evidence block) so a PR born from more than one issue still keys
   its evidence to one number.
9. **`manifest`** — the parallel-agent manifest (below) is regenerated from the log and
   included in the prompt.
10. **`dispatch`** — the dispatch itself is logged as a `dispatch` event
    (role/model/issue/pr/agent).

Close with `dispatch-complete`. A relay resume is not a dispatch: it runs no checklist
and is logged by the Report-handling checklist's `relay` item.

## Report-handling checklist

Every agent report runs this checklist exactly **once**, at loop step 3, logging each
item as a `report-item` event and closing with `report-complete`; skip only with a
`why`. When the report's outcome is a merge, that same single pass continues on through
the merge-only items below in order — loop step 6's reference to this checklist's
merge-only items names that continuation of step 3's pass, not a second run of items
1–7 at step 6; step 6 itself only confirms on GitHub that the merge happened and that
pass completed. The same risk applies here as at dispatch: a report read and half-acted
on while attention is already moving to the next dispatch leaves no trace that the rest
was ever meant to happen unless the log says so.

1. **`card-read`** — the session card is re-read.
2. **`report`** — the report is logged as a `report` event, carrying `tokens`,
   `duration_s`, `model`, and `outcome`.
3. **`self-corrections`** — the report's required `Self-corrections` section
   (`agent-rules.md`'s `report` block) is read; each line in it becomes its own
   `self-correction` event ([formats/session-log.md](formats/session-log.md)); `none`
   logs nothing further here.
4. **`deferrals`** — every item the agent mentioned but did not file is dup-scanned and
   filed, homed per the deferred-items homing rule (`SKILL.md`'s Rules that do not
   bend). On a reviewer report that stopped on a relay, skip with `relay pending`: the
   round's deferrals are filed once, at its verdict report. When the report names an
   issue a reviewer reopened by a second `Seen again:` comment (`github-pr-review`
   SKILL.md Step 8's sighting reopen), this item re-adds it to the board with
   `home-deferred.sh --readd --status Triage` so `maintenance.md` § 1's drain picks it
   up as a fresh triage input — see that file's sighting-reopen paragraph.
5. **`verdict`** — for a reviewer's report: grep the verdict comment for the hand-back
   marker (§ Entry paths, below) — a hit routes to the round the slug names:
   `shared-constant-race` and `stale-base` to the rebase then the merge-verifier,
   `reviewer-applied` to the merge-verifier directly; otherwise route to a fix round,
   the next review round, or **step 6 of § The loop, per issue** (not item 6 of this
   checklist) on approval. A reviewer report that carries no verdict because it stopped
   on a relay is not a verdict yet — log this item skipped with `relay pending` and
   handle it at the next item.
6. **`relay`** — when the reviewer's report names a relay (its `## Review Findings —
   relay` comment exists and no `## PR Review — …` verdict for this round does): resume
   **the author of the head under review** by message with that comment's findings
   verbatim, the PR number and the resume contract — the implementer in round 1; after
   any fix round, the previous round's fix agent, since it is that agent's context that
   matches the code the finding is about, not the original implementer's
   ([templates/implementer.md](templates/implementer.md)'s closing paragraph for an
   implementer resume, or [templates/fix-round.md](templates/fix-round.md)'s resume
   paragraph — which points at the same contract — for a fix-agent resume); on its
   reply, resume the reviewer by message with that reply verbatim. Log a `relay` event
   for each leg ([formats/session-log.md](formats/session-log.md)). The reviewer's next
   report is the round's verdict and re-enters this checklist at item 1 as a new report.
   One relay per round (`github-pr-review` Step 7 § Relay). Where the harness cannot
   resume a finished agent — the cloud sandbox, or an agent whose transcript is gone —
   the fallback is a fix-round dispatch on the relayed findings
   ([templates/fix-round.md](templates/fix-round.md), pointed at the relay comment)
   followed by a fresh reviewer at the same round number: a relay comment is not a
   verdict comment, so the round count does not advance, and the log's `relay` event
   (`fallback: true`) is the only trace. Skip this item, with why, on every report that
   names no relay.
7. **`board`** — the transition this report's outcome calls for is confirmed made by
   the role that owns it (Column ownership, above): **In review** by the reviewer at the
   start of its round, `Verified` by the reviewer at merge (by the
   `workflow-merge-verifier` on the hand-back path), `live-verified` /
   `live-failed` by the validation agent, **Done** by board automation on close. The
   orchestrator owns none of them here, so this item checks the owner made
   the move and never makes it for them; a missing transition means the owning role's
   prompt is missing the instruction — fix the prompt, not the board.

On a merge outcome only, the checklist continues:

8. **`metrics`** — the metrics closing comment
   ([templates/issue-metrics.md](templates/issue-metrics.md)) is posted on the issue.
9. **`epic-event`** — the event comment
   ([templates/epic-event.md](templates/epic-event.md)) is posted on the epic.
10. **`cleanup`** — the worktree is removed, the local branch `-D`'d, `main` pulled
    `--ff-only`.
11. **`claim-refresh`** — the **coordination** claim's timestamp is refreshed at merge,
    so the stale rule reads this session's activity honestly ([claims.md](claims.md)
    § Granularity: "refresh the timestamp whenever you merge something") — the
    epic-level claim when the session is orchestrated, or the standalone-issue-level
    claim where the session worked a standalone issue with no parent epic (same
    Granularity pointer; same tell as § Two roles). The informational per-issue
    dispatch stamp is left exactly as written at dispatch — it is never cleared at
    merge (§ Two roles for `Claimed by`) — and the
    coordination claim itself is released only at handoff or when the epic closes
    (§ Releasing), not here.

Close with `report-complete`.

## Parallel-agent manifest

The "who else is in flight" paragraph that goes into every dispatch prompt is the
**union of two sources**, both mechanical, neither hand-maintained: (a) your own
session's in-flight dispatch events — a `dispatch` event with no matching `report` or
`merge` event yet for the same `issue`/`agent`, read straight from
`<scratch>/session.jsonl` ([formats/session-log.md](formats/session-log.md)); and (b)
other live claims read from the board at dispatch time — the epic-level coordination
claims and their stamped issues (`claims.md`), which never appear in your own log
because a concurrent session's agents write to *its* log, not yours. The "never
hand-maintained" rule applies to (a): a hand-kept list of your own agents drifts the
moment one reports out of order, the log does not. It equally applies to (b), which is
board-derived — read at dispatch time, never carried forward from memory or a stale
earlier read.

Shape (one paragraph, filled from both sources — the log rows for your own claim, the
board read for every other live claim — nothing added by hand):

> `<claim id>` has `<N>` agents in flight: `<role>` on #`<issue>` (`area:<x>`, PR
> `#<pr-or-pending>`) worktree `<path>`; `<role>` on #`<issue>` (`area:<y>`, PR
> `#<pr-or-pending>`) worktree `<path>`; … Also in flight: `<other claim id>` on
> epic #`<epic>` (`area:<x>`) — #`<issue>`, #`<issue>`; `<other claim id>` on
> epic #`<epic>` (`area:<y>`) — #`<issue>`. Do not touch these issues' files or
> areas; keep shared-file edits additive.

When the board read returns no other live claim, the paragraph replaces the entire
`Also in flight: … Do not touch these issues' files or areas; keep shared-file edits
additive.` segment with the standalone sentence "No other live claims." — not merely
substituting the `Also in flight: …` clause, since "Do not touch these issues'" has no
antecedent once there are no foreign claims to name. The reader must never infer the
empty case from silence.

## PR class and round caps

PR class is mechanical, determined from the diff's changed paths only — no judgment.
The rule is deliberately **conservative in one direction**: when a path is not clearly
test-only or doc-only, it falls through to executable-code and the PR keeps the
three-round cap. Never widen a class to fit a PR.

- **Test-only** — every changed path either sits under a **test root** (a path segment
  that is exactly `test`, `tests`, `spec`, `specs` or `__tests__`) **or** matches a
  test-file pattern the repo's own `docs/process/testing.md` documents. Nothing else
  classes test-only. Substring matching is never sufficient: a bare `*test*` glob
  matches basenames such as `src/latest.py`, so it is not a convention this rule
  accepts — only an anchored pattern the testing doc actually spells out (for example
  `*_test.go`, `test_*.py`, `*.test.ts`, `*.spec.ts`) counts. **A repo whose
  `docs/process/testing.md` documents no test-file conventions therefore has no
  test-only PRs at all** — every PR there is executable-code or doc-only, and the
  three-round cap applies. That is the intended default, not a gap.
- **Doc-only** — extension-based, and self-contained here: every changed path ends in
  `.md`, `.markdown`, `.rst`, or `.adoc` — docs-prose extensions only — or is a
  `README*` file at any level. No lookup, no judgment. This list is deliberately narrow,
  matching the "conservative in one direction" rule above: `LICENSE*`, `CHANGELOG*`, a
  bare `.txt` path, and anything else fall through to **executable-code** — a licence or
  changelog change is among the most consequential single-file edits a repo can take,
  and `.txt` carries no guarantee of being prose, so neither gets the reduced round cap.
  **The basename exclusions take precedence over the extension allowlist**: a path
  matching both — `LICENSE.md`, `CHANGELOG.md` — is `LICENSE*`/`CHANGELOG*` first and
  executable-code, even though it also ends in `.md`. The extension list only ever
  classes a path doc-only when the path is *not* also `LICENSE*` or `CHANGELOG*`.
- **Executable-code** — anything else, including a PR that mixes code with test or doc
  changes, and any PR whose classification is not certain under the two rules above.

The round cap follows the class:

- **Executable-code PRs** keep the **three-round cap** — the cap is **3**: three review
  rounds, then the reviewer escalates with `help` (loop step 5).
- **Test-only and doc-only PRs get a two-round cap**: round 1 review → one fix round →
  round 2 review — the cap is **2**, and the one fix cycle is what those two rounds are.
  If round 2 still reports findings and none is severity-worthy (no blocker or major
  finding, per the reviewer's own Step 6.5-gated severity judgment — see below), the
  round-2 reviewer **merges anyway**, routing every non-severe residual per
  `github-pr-review` Step 7's table, instead of requesting a third round. The class
  cap governs **findings only**: it never overrides **any of the unconditional
  Changes-Requested triggers listed in `github-pr-review`'s Step 7**. Read that list
  there and treat it as complete — every trigger on it still forces Changes Requested at
  any round, regardless of PR class.

Severity (blocker/major/minor/note) is always the reviewer's own judgment, per
`github-pr-review`'s Step 6.5 text; Step 6.5's confidence score is the gate on whether a
finding blocks at all (findings scoring below 80 move to the Notes list and keep their
severity), not the
authority that assigns severity.

**Class is re-derived every time, not cached.** `preflight.sh` computes class fresh
from the diff's current changed paths on every call — the same mechanical rule above —
and reports it alongside the round count (`class` and `round_cap` in its JSON output;
issue #703). The relay is the one mechanism that changes a PR's content without a new
review round starting (the loop's `relay` item above), so it is also the one place a
PR's class can move mid-round without anything having explicitly recomputed it: the
orchestrator resuming the reviewer with the relayed head is the point re-derivation
actually happens, because that resumed reviewer's own next `preflight.sh` call sees the
relay's added or removed paths and reports whatever class they now imply — there is no
separate "recompute class" step to remember, only the existing call re-run against a
changed diff. **When the class widens** (doc-only/test-only → executable-code), the
new, larger cap applies from the round in progress onward: the PR simply has more
rounds available than a moment ago, and no round already spent needs re-litigating.
**When the class narrows** (executable-code → doc-only/test-only) and the round in
progress would already exceed the narrower cap, treat that round as final-entering
under the narrower cap rather than reopening or discarding rounds already run — the
fix-round agent already in flight finishes at the tier it was dispatched at (tier is
chosen at dispatch and is never revisited mid-round), and the reviewer resuming after
the relay applies the narrower cap's final-entering rule above when deciding severity
and routing.

## Merge-verification round

An **approved** PR that develops a merge conflict against `main` before it is actually
merged does not go back through ordinary review. This is a bounded, named exception:

1. Dispatch a rebase agent into the author worktree, pinned to its own definition
   (dispatch mechanism: [platform-claude.md](platform-claude.md))
   (mid tier (Claude: Sonnet), per the Routing table) — record `<old-base>` (the base
   the approved head sat on) and `<approval-sha>` (the approved head) before touching
   anything; the full procedure, including how those two SHAs plus `<new-base>` and
   `<new-head>` are captured and reported, lives in that definition.

2. Dispatch a fresh **merge-verification round**, also at the merge-verification tier
   (Routing table) ([templates/review-dispatch.md](templates/review-dispatch.md)'s
   merge-verification variant), scoped to exactly two checks and nothing else — it does
   not re-review the PR's content:

   **(a) The delta since approval is exactly the rebase.** This is the canonical
   criterion; every other file states it by pointing here. The verifier computes **both
   sides itself** — `<old-base>` and `<approval-sha>` are still fetchable from the
   remote after a force-push (`git fetch origin <approval-sha>`, or the pre-force-push
   SHA recorded on the PR timeline) — and runs:

   ```sh
   git range-diff --creation-factor=999 <old-base>..<approval-sha> <new-base>..<new-head>
   ```

   `git range-diff` output is **never empty**: it prints one line per commit pair marked
   `=` (identical), `!` (paired but changed), or `<` / `>` (dropped / added). The high
   `--creation-factor` is required — at the default, a commit whose only hunk was
   rewritten by conflict resolution fails to pair and shows as `<` plus `>` instead of
   `!`. Judge the markers:

   - **Every pair `=`** → clean rebase, no conflict was resolved: **PASS**. In this case
     only, the byte-identity shortcut is equivalent — `git diff <old-base>...<approval-sha>
     | sha256sum` equals `git diff <new-base>...<new-head> | sha256sum`. It is a shortcut
     for this case and nothing more.
   - **Any pair `!`** → a conflict was resolved, which is the normal outcome here.
     **PASS only if** every hunk in that pair's interdiff (i) lies inside a region
     `main` itself modified since approval — compute the conflict surface directly with
     `git diff <old-base>..<new-base>` — (ii) introduces no text that is not `main`'s
     own text at that location, and (iii) **preserves** every line `main` changed inside
     the conflict surface: that text must still be present in `<new-head>` at that
     location, whether it arrives as unchanged context or as merged content. An additive
     resolution satisfies all three: the interdiff shows the PR's line kept and `main`'s
     line arriving as context. A **non-additive "take ours" resolution fails (iii) and
     ABORTs**, even though it satisfies (i) and (ii) under a literal reading — an
     interdiff hunk that deletes `main`'s-side text without that text surviving
     elsewhere in the result is indistinguishable, for this criterion's purpose, from
     dropping `main`'s change, and is not the rebase. If any interdiff hunk touches a
     file or region outside the conflict surface, adds any line that is neither the
     PR's approved text nor `main`'s, or removes `main`'s text without it surviving in
     `<new-head>`, it is **not** the rebase — **ABORT**. Interdiff `@@` hunk-header
     lines (`-@@ file: lN` / `+@@ file: lN`) are diff metadata reporting a line-number
     shift, not content — they are **never evidence** under (ii) or (iii) and must be
     excluded from the comparison before judging either condition.

     **Doc-only allowance on condition (ii).** This allowance is stated for **doc-only**
     PRs only (**PR class and round caps** above defines the classes; a PR mixing code
     with docs classes as executable-code and so cannot reach it). Every other class —
     executable-code, test-only, and any class added later — keeps (ii) exactly
     token-literal as stated above: code has no harmless synonyms, so a token on neither
     side is an ABORT there. Doc-only differs because prose conflicts are normally
     resolved by *harmonising* the two sides at that location, which mints a few tokens
     that are on neither side verbatim; reading (ii) literally there makes ABORT the
     automatic outcome of every correctly-resolved prose conflict, so the round never
     does its job.

     **Agent and skill instruction text is in scope.** A PR whose changed paths all sit
     under `.claude/agents/` or `.claude/skills/` classes doc-only by the rule above —
     every such path ends in `.md` — and this allowance reaches it unchanged; there is
     no path-prefix carve-out. The premise survives that, because the allowance never
     admits a synonym for anything, in prose or in instructions: (c) admits only
     connective or structural tokens, convention tokens the approved diff itself
     establishes, and back-references whose every referent is named verbatim in the same
     hunk, and any clause reworded still ABORTs unconditionally — so no content word
     naming anything on neither side can enter an instruction under it. (a) keeps
     `main`'s sentences, judged at clause granularity, with (c) governing the tokens
     that differ; (b) allows a drop only where `main`'s own text stands where the
     dropped run stood and any replacing pointer both resolves and carries it; (d)
     demands the same truth conditions, which for an instruction is the same behaviour.
     The mirrored `<!-- rule: -->` blocks — the one instruction text that must stay
     byte-identical across several files at once — carry their own drift test, so no
     resolution can split them silently. And the failure direction stays cheap: ABORT
     moves a wording question to the full review round that exists to settle it, so
     treating instruction prose as prose here costs a round at worst.

     A doc-only interdiff hunk therefore also PASSES (ii) when it lies wholly inside the
     conflict surface computed under (i) and **all four** of the following hold. Judge
     them per hunk against the two sides' literal text at that location — the PR's
     approved text (at `<approval-sha>`) and `main`'s text (at `<new-base>`).

     - **(a) `main`'s sentences all survive.** Every sentence of `main`'s text at that
       location is still present in the result. This is condition (iii) restated for
       prose, and this allowance does not weaken it. Judge it at **clause** granularity:
       where `main`'s sentence survives with tokens changed inside it, (a) yields no
       verdict and (c) governs each changed token; where a whole clause of `main`'s is
       gone, (a) **ABORTs**.
     - **(b) The PR's approved text survives except inside a superseded passage.** One
       unit governs the whole condition, and it is **computed, not chosen**, so two
       verifiers reading the same three texts draw the same boundaries. Set aside the
       tokens (c) already governs — punctuation, emphasis and list markers, item
       numbers, articles, conjunctions, prepositions, subordinators, pronouns, count
       words. Of the words left in the PR's approved text at that location, mark each
       **absent** when it appears nowhere in the result at that location. Presence is
       **whole-word**, and a **word** is a maximal run of `[A-Za-z0-9_]`: every other
       character ends one word and begins the next, the hyphen included, so
       `merge-verifier` is the two words `merge` and `verifier` and carries each of
       them. A word appearing only inside a longer word is not that word — `report`
       inside `reports`, and any other inflected form of itself. The comparison ignores
       case and any surrounding punctuation or markup. Every maximal contiguous run of
       absent words is a **passage**; those runs are the only passages, and the
       decomposition is unique. A passage is **superseded** only when `main`'s own text
       stands where the run stood, judged inside a span the run's two nearest surviving
       neighbours fix. Those neighbours are the surviving words **adjacent to the run on
       the approved side**; the span they bound is the **shortest** stretch of the
       result running from an occurrence of the left neighbour to a later occurrence of
       the right neighbour, and where two stretches tie for shortest, the earlier one.
       The span is **exclusive of its endpoints**: the two neighbour occurrences bound
       it and are not inside it, so neither counts toward the floor below — a stretch
       with nothing between the two neighbours is an empty span. Shortest, not
       first-to-first: an early occurrence of the left neighbour far from the seam
       would otherwise widen the span past the text it is meant to bound, sweeping in
       `main` text that belongs to some other clause. The window is a
       **word-occurrence construct, not a positional one**: it is fixed by where the
       neighbour words occur in the result, and when both neighbours are common words
       the shortest ordered pair can sit in a clause of the result unrelated to where
       the run stood. That is accepted, not a defect to correct by hand — a verifier
       never relocates the window to where the run "ought" to be — and a run whose
       window lands away from the seam is carried by the pointer branch below, or is
       a dropped clause. Where the result holds no such ordered pair — the two occur
       only in the opposite order, or one of them not at all — there is no span, and
       the passage supersedes nothing. A run that **begins or ends the location** has
       one neighbour only: its span runs from that neighbour's occurrence **nearest**
       the corresponding end of the location, to that end. A run that both begins and
       ends the location — every non-set-aside word at that location is absent — has
       **no neighbours, no span, and supersedes nothing**: it is a dropped clause and
       ABORTs. Inside the span the result must carry text quoted verbatim from `main`'s
       side at the same location, and that text must carry at least one word **outside
       the classes set aside above** — a span holding only set-aside tokens, a bare
       conjunction between the two neighbours say, supersedes nothing. For a
       **one-sided** run that floor is read strictly, because a one-sided span reaches
       an end of the location however it is bounded, and would otherwise be met by
       `main` text nowhere near the run: the qualifying `main` text must abut the run's
       own end of the location, with no surviving approved word standing between it and
       that end. `main` text elsewhere in a one-sided span does not supersede the run,
       so a bare connective at the seam cannot satisfy the floor there either, and such
       a run stands or falls on the pointer branch instead. Where that `main` text is a
       **pointer** to another file or section, the verifier names the target, confirms
       it exists, and quotes the target's text carrying the run's content; a pointer
       that resolves nowhere, or to a target that does not carry the run, supersedes
       nothing. A passage with nothing of `main`'s standing where it stood is a
       **dropped clause** and **ABORTs**, however plainly the surrounding text implies
       it, and however fully some other file carries the same words. Approved text may
       be absent from the result **only** inside a superseded passage; the PR's edits
       drop with the passage, because the PR was editing text that no longer exists.
       Every other part of the approved side — whole sentence or fragment of one — must
       still be present in the result; if it is not, **ABORT**. The condition never asks
       which side first wrote the text, only where the absent run sits and what stands
       in its place.
     - **(c) Every token new to both sides falls in one of two categories.** Either
       **connective or structural** — a list marker, an item number, a conjunction, a
       count word changed to match a list the hunk lengthens or shortens (`three` →
       `four` when a fourth item is added), a parenthetical or clause moved (subject to
       (d)) from where it sat to where it now reads, or the words a passage needs to be
       **recast into the grammatical voice of a list or sentence `main` created** (a
       requirement stated as a failure becoming the condition that must hold, say),
       provided (d) holds and the recast mints no token beyond the grammatical forms its
       new voice requires — verb forms, articles, conjunctions, subordinators. A
       recast that mints a content word naming anything not already named on one of the
       two sides is a rewording and **ABORTs**. Or a **convention token the PR's own
       approved diff introduces elsewhere in the same file**: a naming or formatting
       parenthetical the approved diff already established, applied here to text `main`
       wrote. To use that second category the verifier must **quote the line of the PR's
       approved diff that establishes the convention**; without that quoted line the
       token is new text and **ABORTs**. One further structural form counts: a
       **back-reference standing in for identifiers the resulting sentence already names
       verbatim earlier in the same hunk** (`those two SHAs` where `<old-base>` and
       `<approval-sha>` were just named) — de-duplication forced by joining the two
       sides into one sentence, not a rewording, since every referent token is still
       literally in the hunk. The verifier must point at each identifier's earlier
       verbatim occurrence; a back-reference to anything not named earlier in the hunk
       is new text and **ABORTs**.
     - **(d) Re-ordering preserves meaning.** A sentence that survives re-ordered,
       re-numbered, or joined with another passes only when no negation, condition, or
       quantifier has moved across a clause boundary. The check is mechanical: read the
       sentence on the side it came from, read the resulting sentence, and confirm the
       two have the same truth conditions — the same thing is negated, the same
       condition governs the same clause, the same quantifier scopes the same noun. If
       they do not, **ABORT**.

     Everything else **ABORTs** under (ii), doc-only PR or not: any new assertion,
     requirement, identifier, path, command, or SHA that is on neither side; any clause
     dropped from either side other than under (b); any pointer target changed from what
     either side pointed at; and **any clause reworded** — replaced by a synonym or a
     paraphrase, however equivalent it reads. A recast admitted by (c) is **not** a
     rewording for the purposes of this list: (c) is a stated exception and governs the
     hunks it covers, and it is the only exception — nothing else escapes the list.
     Whether a rewording preserves meaning is not this round's judgement to make; the
     post-ABORT full review round exists for exactly that case, so a reworded clause
     ABORTs here and is settled there.

     **What the verifier reports.** A verdict asserting "wording-only" without all of
     the following is not a PASS. Quote the synthesised hunk. Then, for that hunk:
     attribute every surviving sentence to the side it came from — the PR's approved
     text or `main`'s; name every PR sentence that is absent and quote the `main` text
     that superseded it, under (b); and list every token new to both sides with its
     category from (c), quoting the establishing approved-diff line for each convention
     token.
   - **Any `<` or `>`** (a commit dropped or added) at `--creation-factor=999` →
     **ABORT**.

   Note explicitly that byte-identity is *not* the general criterion: resolving a
   conflict rewrites the PR's delta relative to its new base, so the two three-dot
   hashes necessarily differ in exactly the scenario this round exists for. A verifier
   that compares hashes alone aborts every real conflict.

   **(b) CI is green on the new head.** No-CI repos: check (a) alone is sufficient.

   If both hold, squash-merge now.

3. **This round does not count against the round cap above** — it verifies merge
   mechanics, not design or code.

4. On **ABORT** — the delta since approval is **not** exactly the rebase — do not merge
   and do not fix anything: end the merge-verification round and dispatch a full review
   round at the review-default tier (Routing table) instead. The PR is back in ordinary
   review.

5. On **STOP** — the verifier could not merge for a reason outside its criterion: CI red
   on the head it would have merged, or a merge refused because the PR turned non-CLEAN
   after the reviewer's verdict — re-enter this round from the fact it reports. A
   conflict is a new hand-back on the same PR: dispatch `workflow-rebase` then the
   merge-verifier as § Entry path: the shared-constant race describes, with the slug the
   conflict's shape earns. A red check is a defect no bounded round may judge: dispatch
   a full review round as on ABORT. Neither spends a round.

This is a deliberate, bounded exception to the review-default tier (Division of labour
above and Routing table), scoped this narrowly on purpose — do not widen it to cover any
other kind of round.

### Entry path: the shared-constant race

PRs that touch a shared file whose constant counts its own entries — a list plus a
count of how many entries it holds, edited concurrently by two or more PRs — merge
**serially**, never in parallel: whichever PR merges first changes the count out from
under every sibling still in flight. This is generic; it applies to any shared file with
that shape, not to one named file or one kind of entry.

When a sibling merges first, the later-approved PR's reviewer does not open a re-review
round over it — the review itself found nothing blocking, only the count went stale.
The reviewer instead posts the **hand-back variant**
(`github-pr-review/references/templates/approved.md` § Hand-back variant): it records
the approval, does not merge, does not rebase, does not touch the branch, and does not
set `Verified` — on this path `Verified` is written by the `workflow-merge-verifier`
agent, on PASS, exactly as `review-dispatch.md`'s merge-verification variant already
assigns it.

On reading that reviewer's report, detect the hand-back by grepping the verdict comment
for a `<!-- handback: ... -->` marker — the trailing footer's `"handback":true` key
also says a hand-back happened, but only the marker's slug says which round to dispatch,
so the footer detects and the marker routes; this is the signal `approved.md` promises
and the reader this file supplies for it. The marker carries one of three slugs. Two
enter here:
`shared-constant-race` for this section's race, and `stale-base` for a branch
`github-pr-review/references/verdict-rules.md` § *Stale base vs. a base that moved*
qualifies as needing a rebase before it can land (`approved.md`'s hand-back variant
states the tie-break when a PR fits both). The third, `reviewer-applied`, enters at the
next section. Between the first two the slug changes nothing about the round — both run
the two steps below, `workflow-rebase` then `workflow-merge-verifier` — only which
resolution rule step 1 hands the rebase agent. Then run this round exactly as above,
dispatched in two steps:

1. Dispatch `subagent_type: workflow-rebase` (mid tier (Claude: Sonnet), per the
   Routing table) into the PR's own author worktree. On a `shared-constant-race`
   hand-back its definition (`.claude/agents/workflow-rebase.md`) carries the union rule
   for this shape of conflict — keep every sibling's entries and recount the constant at
   push time — so it is not re-typed here. On a `stale-base` hand-back there is no union
   to compute: instruct it to rebase the branch onto current `origin/main` additively,
   keeping every file `main` gained and re-applying only the PR's own diff, and to
   confirm before pushing that condition 1 of that same *Stale base* section, run as
   written there, is empty.
2. On its report, dispatch `subagent_type: workflow-merge-verifier` (mid tier, Routing
   table) with the four SHAs the rebase agent reported — `<old-base>`, `<approval-sha>`,
   `<new-base>`, `<new-head>` — per step 2 above.

Log both dispatches and both reports with `role: rebase` then `role: merge-verifier`
([formats/session-log.md](formats/session-log.md)), and the round itself as a `review`
event with `kind: merge-verification`. Like every merge-verification round, this one
does not count against the round cap (item 3 above).

**ABORT** on this path is the same ABORT as the general procedure: it does not stay a
merge-verification concern — dispatch a full review round at the review-default (large)
tier, per item 4 above.

### Entry path: reviewer-applied commits

A reviewer that routed one or more findings **reviewer-applied** (`github-pr-review`
Step 7) has committed on the branch under review and posts the hand-back variant with
the `<!-- handback: reviewer-applied -->` marker instead of merging. The same grep
detects it; the round it
enters is the merge-verification round with **step 1 skipped** — there is no rebase to
verify — and step 2's check (a) replaced by the **reviewer-applied gate**
(`github-pr-review/references/verdict-rules.md` § Reviewer-applied gate):

1. Dispatch `subagent_type: workflow-merge-verifier` (mid tier, Routing table) with
   [templates/review-dispatch.md](templates/review-dispatch.md)'s merge-verification
   variant in its `reviewer-applied` form: the slug, `<approval-sha>` — the head the
   reviewer's commits sit on: the relayed head its verdict Summary names when the round
   relayed, else the head in the round's pre-flight block — `<new-head>`,
   the head the reviewer pushed, and the PR's base branch name. Its definition carries
   the check: every commit in `<approval-sha>..<new-head>` carries the trailer and
   passes the five gate conditions, and CI is green on `<new-head>`.
2. On **PASS** the verifier squash-merges and sets `Verified`, exactly as on the other
   two slugs. On **FAIL** it reverts and still merges (`verdict-rules.md` §
   Reviewer-applied gate, *Handling a failed gate*);
   file each reverted finding as a deferred issue at this report's `deferrals` item,
   with the verifier's report as provenance.

This slug never coincides with a rebase (`github-pr-review` Step 7).

Log the dispatch and report with `role: merge-verifier` and the round as a `review`
event with `kind: merge-verification` (item 3 above governs the round cap).

## AC amendment

A review can find that one of an issue's own acceptance criteria is wrong rather than
unmet: it contradicts the issue's own Summary or Proposed Changes section, the parent
epic's Scope section (or the milestone's Scope / Non-goals, for a milestone-direct
issue), or the ratified design record it was drawn from. That is a planning defect, not
a review finding about the code, and it gets fixed at the source — the issue body —
instead of carried forward as a criterion nothing can ever satisfy.

1. The reviewer names the contradiction in its verdict: which AC, and the exact
   Summary/Proposed-Changes, Scope, or design-record text it conflicts with. This is a
   finding like any other, not an approval.
2. The orchestrator, not the reviewer or the implementer, rewrites the AC. Edit the
   issue body through a **body file** (`gh issue edit <n> --body-file <path>`), never an
   inline `--body` string, and verify the resulting body's length before posting —
   truncation silently drops the criteria a reviewer is about to judge against.
3. Post the [scope-note comment](templates/scope-note.md) on the issue: date, the
   flagging review (PR + round), the old AC verbatim, the new AC verbatim, the
   delivering sibling (the issue that now owns any scope the amendment carved off, or
   `none`), and one line on why this was a planning defect rather than an
   inconvenience.
4. Log an `amend` event ([formats/session-log.md](formats/session-log.md)): `issue`,
   `review`, `old_ac`, `new_ac`, `sibling` (omit `sibling` when nothing was carved off).
5. The next review round judges the PR against the issue's **current** body. It does not
   re-litigate the amendment — that was the orchestrator's call, made and logged before
   the round started.

This procedure is not for making a failing PR pass. An AC the implementation simply
fails to meet stays exactly as written, however inconvenient; only a genuine
contradiction with the issue's Summary/Proposed Changes, the parent epic's Scope, or the
design record qualifies. The distinction matters because the AC is the only contract the
reviewer has — a reviewer that cannot trust the criteria in front of it to hold still
has nothing left to judge the PR against, and an orchestrator willing to soften an AC
under review pressure has quietly become the implementer's advocate instead of the
process's referee.

## Dispatch prompts

The standing rules (no-subagents / helper-tier, bounded-wait recipe, git rules, log
filenames, CI gate, foreground-only, quiet structured reporting) live in the agent
definitions under `.claude/agents/` and are pinned to the correct role at dispatch
— they are not re-typed into the prompt (dispatch mechanism:
[platform-claude.md](platform-claude.md)). Every subagent prompt still
contains, in this order and without softening, the per-issue specifics the definitions
cannot know:

- The repository's **sanitization / public-repo rule** as pointed to by `docs/process`.
- The **worktree path and branch** it owns, and the main checkout it must not touch.
- The **scratch root** the repo names (e.g. `docs/process/worktrees.md`'s Scratch line),
  plus the instruction to work under a uniquely-named subdirectory of it rather than a
  guessable shared name (`<scratch>/probe/`, `<scratch>/f1/`) — the scratch root is
  shared by every agent in the session, so an unnamed or collision-prone location is how
  temp files end up in `/tmp`, the repo tree, or clobbered by a sibling agent.
- The **claim id** and the areas/issues other agents hold ("a parallel agent owns
  `area:frontend` (#N) — do not touch it; keep shared-file edits additive").
- The **exact test, lint and sanitize commands with environment** from
  `docs/process/testing.md` and `testing.local.md` — copied in, not referenced, because
  agents do not discover context reliably.
- The **token-discipline** paragraph from the `local-model-delegate` skill when the
  repo uses it.
- The board transition it owns, and the board/field ids it needs.

Scale prompts, not trust: put the sharp questions in the **reviewer's** prompt (scrutiny
points derived from the implementer's claims, the change's blast radius, and the session's
live defect classes) and treat the implementer's report as unverified until the reviewer
or the repo confirms it.

## Parallel safety

- Parallelise only work with **disjoint surfaces**. `area:*` is the first filter (two
  issues sharing an area are serialised unless you have checked their file sets); the
  file sets named in the issues are the second; anything touching a shared sequence
  resource (numbered migrations, generated ledgers, lockfiles — the repo names them in
  `docs/process`) is the third.
- Pre-assign shared sequence slots across your own agents; when another live claim
  exists, downgrade to "verify at branch time and state the assumption in the PR body".
  Whichever PR merges second renumbers and reconciles. When the shared resource is a
  numbered migration, the **migration-ledger line is pre-assigned together with the
  migration slot** — one act, not two — so no agent can take the slot number without
  also reserving its ledger line, and the two never drift apart.
- Name the other in-flight agents and their areas in every prompt, from the manifest
  above (own-session log rows plus other live board claims) — do not hand-add to either
  source; a cross-session agent still belongs in the prompt, but only because the board
  read put it there.
- Serialise anything sharing a screen, module or subsystem. Two agents in one module
  produce a merge conflict and a review that has to reason about both.

## Restarting a stalled agent

An interrupted or stalled agent is given an explicit next-step list and set going again.
Check the worktree first (`git status`, `git log origin/main..HEAD`) so the directive
matches reality; if the agent died on a usage limit, its work is uncommitted in the
worktree and step 1 is "commit the WIP". Tell implementers to commit early rather than
hold one large uncommitted change.
