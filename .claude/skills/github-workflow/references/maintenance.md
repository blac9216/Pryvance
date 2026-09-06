# Maintenance

For the `card-read` slug that opens each logged checklist, and startup's exception to
it, see [formats/session-log.md](formats/session-log.md).

A fixed step, not a mood. It runs at session start, on every resume, before each parallel
wave or every three serial issues, and on "morning cleanup". It never runs on the heartbeat;
the one exception to that never-runs-on-heartbeat rule is the 60-minute silence check on
in-flight agents ([overnight-and-status.md § Overnight](overnight-and-status.md#overnight))
— that check is not a maintenance pass. Each pass writes one
[formats/maintenance-report.md](formats/maintenance-report.md) record to the session log so
the brief can show what was found. Five steps, in order.

## 1. Triage drain

The Triage column is the intake for everything anyone filed since the last pass —
reviewer and implementer deferrals, validation bugs, owner-filed issues. Some of that
intake carries the `deferred` label and some does not, and the `home` step below turns on
exactly that difference. The filer set basic labels; the filer cannot decide precedence,
so the orchestrator drains the column
by working an ordered checklist per item, logging a `triage-item` event per step
(`item` = the canonical slug, `skipped` + `why` when a step is skipped for that item)
and closing the item with a `triage-complete` event once every step has passed or been
logged skipped. Cadence is the maintenance drain only, not a per-report obligation — an
item may sit in Triage for several passes before its turn. **Done-triage** means every
item has exactly one priority label, `blocked by`/`blocking` links wherever order
matters, a severity label if it is a bug, and its correct home — nothing left for a
later pass to redo.

**Fetch the board once per pass.** This drain, like every other step below that reads
board Status or fields, reads the project board **once** at the start of the pass into
a scratch file and answers every item's question from that file — never a fresh
paginated walk per item. A per-item re-fetch burns the same shared secondary GraphQL
rate limit a mis-paginated query does, just from the caller's side instead of the
query's ([github-tools.md § Reading the board](github-tools.md#reading-the-board-pagination-and-the-cursor-name-trap)
has both recipes and the reason).

Triage is **universal**: any orchestrator, on any target, may triage any item in the
column to completion, because deciding labels, home and sequence needs only the item
itself, not target-specific context — a session that reaches the column first keeps it
honest rather than waiting for the item's eventual owner to show up. Execution stays
**targeted**: dispatching or doing the work an item describes stays with the claimed
target's own session, because that work depends on the target's worktree, claim and
in-flight state in a way triage decisions do not.

The checklist, in order:

1. **`card-read`** — read the session card's facts (board and field ids, claim id,
   thresholds) rather than re-deriving them from memory before touching anything below.
2. **`claim`** — `stamp-claim.sh take` the item before deciding anything about it. This
   is coordination between concurrent orchestrators draining the same Triage column, not
   the epic-level lock: the first claimant to take an item decides it, and a live claim
   is never overwritten. Act on the **exit code**, never on the message text; `take` has
   four outcomes and each has a different next move:
   - **0** — taken (the field was empty, or the old claim was stale), or the claim was
     already yours and live, which is an idempotent no-op. Work the rest of the
     checklist for this item.
   - **3** — refused: another session holds a live claim on it. That is the skip signal
     for this item and a normal concurrent outcome, not a defect. Log `triage-item`
     `claim` skipped with why, close the item with a `triage-complete` naming the
     remaining slugs as skipped for the same reason — an item with no `triage-complete`
     cannot be told apart from one this pass never reached — and move to the next item
     rather than waiting for the other session.
   - **4** — the claim **was written** and the board is correct, but the script could not
     append its session-log line. Never read this as a failed claim: the item is yours,
     so carry on down the checklist and re-log the `claim` event by hand.
     (`home-deferred.sh` instead rejects the record and hands the claim back on 4; it is
     an unattended batch that cannot repair a log line mid-run, while an orchestrator
     working this checklist can. Same rule — never leave a written claim unrecorded —
     under different repair powers.)
   - **1** — hard failure: the item is not on the board, a GraphQL read or write failed,
     or the stored claim value or timestamp is malformed. Whether a mutation was
     attempted before the failure is not uniform across those paths — see
     [claims.md](claims.md) § Script for the exact split — so be loud either way: name
     it in the maintenance report as a failed item and continue with the next item
     rather than guessing at this one. (**2** is an argument error, a defect in the call
     itself, and is uniformly pre-mutation; same report treatment.)
   A stale claim may be taken over per [claims.md](claims.md) §
   Per-item triage claims.
3. **`provenance`** — for anything carrying the `deferred` label, confirm the body's
   Home section carries the provenance line in one of its two canonical forms:
   `Spawned by #<N>` (the discovering issue) or `Spawned by PR #<P> round <R>` (a review
   finding), and the required `Unit:` line on the line immediately after it. A deferred
   filing with no traceable origin cannot be trusted to be deduped or homed correctly,
   and one with no unit cannot be batched at all — `batch-deferred.sh` excludes an
   unmarked item rather than guessing its unit. Both lines' exact form is
   [SKILL.md](../SKILL.md)'s Deferred Items rule; a missing `Unit:` line is repaired
   here or at step 9, not read as evidence that the item predates the rule.
4. **`dedupe`** — dup-scan open issues; a duplicate is closed with reason `duplicate`
   and a pointer to the issue it duplicates. A closed duplicate leaves the checklist
   here: nothing below it applies to an issue nobody will work. So finish it here rather
   than dropping it mid-list — release the claim taken at `claim`
   (`stamp-claim.sh release --item <N> --id <claim>`, the same call `board` makes for
   items that survive), log the remaining slugs skipped with `duplicate of #<M>` as the
   reason, and close the item with `triage-complete`. Without that release the claim
   outlives the issue by the full stale window.
5. **`labels-complete`** — exactly one type label; a `size:*` label (`size:s`/`size:m`/
   `size:l`; #733 — every issue is sized, not only code, and a `size:l` slipping through
   to here is itself a defect: split it, or fold it into an epic, before it leaves this
   step — except on an epic itself (`issue-epic.md`): decomposition into sub-issues is
   an epic's entire purpose, so a `size:l` epic is the expected shape at scope past 8
   planned children, not a defect, and this step never splits or folds an epic on that
   basis); `concern:*` if it is a found-issue; at least one `area:*` from the repo's
   closed set (`docs/process/labels.md`). The filer proposes `priority:*` and, for bugs,
   `severity:*`; the filer cannot see the rest of the queue, so the orchestrator
   completes them. This is a gate, not a courtesy: no item leaves Triage, and no
   deferred filing is homed, without exactly one `priority:*` and, for bugs, exactly one
   `severity:*`. **Setting either is a replacement, not an addition** (#745): when this
   step changes an item's priority or severity, it removes the label(s) that no longer
   apply in the same edit that adds the new one — never leave the old value in place
   alongside the new. This is not hypothetical: eleven open issues were found carrying
   two `priority:*` labels apiece because an earlier drain of this same step added a
   raised priority without removing the original, so `priority:high` and
   `priority:medium` both matched issues whose actual priority was only one of the two,
   and every count over the field was wrong in both directions until a by-hand pass
   collapsed them. `board-audit.sh`'s state audit (§ 5 below) now reports any open issue
   with zero or more than one `priority:*` label, and the identical zero-or-multiple
   check for `severity:*` restricted to issues carrying `bug` (a chore correctly has
   none) — treat either as this step re-opened, not as a new defect. An unprioritised
   item cannot be placed in the dispatch pick order ([orchestration.md](orchestration.md)
   "The loop, per issue" step 1: `blocked by` chain position, then severity, then
   `priority:*`, then age), and an unclassified bug breaks that same order at its
   severity key — severity is what lets a bug outrank a non-bug at equal chain depth, so
   leaving it unset makes that half of the order undefined too, not just the priority
   half. `home-deferred.sh` enforces this gate at the point of homing and refuses any
   record that fails it.
6. **`home`** — where the item lands depends on whether it is a deferred filing; the two
   paths differ only in whether an epic parent is allowed.
   - **`deferred`-labelled items** take the parentless path (SKILL.md's Deferred Items
     Rule): homed to the milestone the discovering work belongs to, or left in Triage
     when no milestone applies, and **never** re-parented as a sub-issue of an epic —
     except a live-test blocker gating the active epic's proof, which takes the
     non-deferred path below whatever label it arrived with (see below). Before homing,
     decide **work now** or **park** (epic #798 owner decision 4): this decision is
     **severity and unit only — priority plays no part**, because it costs the reviewer
     nothing to assign a priority label, so a `priority:*` value is never read here.
     Work now when any of three holds: **(a)** the item is a `bug` at `severity:major` or
     `severity:blocker`; **(b)** the item's **unit key** equals a unit key of an
     open **released** issue in the same milestone — both terms are defined
     immediately below, because neither side of that comparison is decidable without
     them; or **(c)** the item is open and carries **two or more** `Seen again:`
     comments. Park every other item.
     - **(c)'s floor.** An item that reaches work-now through (c) — a sighting
       reactivation — is not re-parked by the session that reactivated it, nor by the
       drain immediately following that reactivation, whatever (a) and (b) say on
       their own: the comment count that satisfies (c) does not fall back to zero
       between drains, `Seen again:` comments are never removed, so once (c) holds it
       keeps holding on every later pass too — the floor is a restatement of what (c)
       already guarantees for the one drain a triager might otherwise second-guess,
       not a separate exception. The `Rejected: <reason>` outcome (below, under
       Batching) still overrides (c) as it overrides (a) and (b): a reviewer cannot
       undo a deliberate rejection by repeating the same sighting. A reactivated item
       that is worked and closed needs nothing further — closing it is the ordinary
       outcome, and there is nothing left for the floor to protect.
       Worked example: a `chore` at `severity:minor` — fails (a) — whose unit matches
       no open released issue — fails (b) — is parked at 21:14 Monday. A reviewer's
       second `Seen again:` comment lands at 21:48; Step 8 reopens it and it is
       re-added to Triage. The drain that runs at 23:33 that same night reads two
       `Seen again:` comments, satisfies (c), and leaves the item at work-now — it is
       not parked again even though it still fails (a) and (b) on their own.
     - **Both sides of (b) are batch keys.** Derive the item's key from its `Unit:`
       line by step 9's normalisation below. Derive a candidate's keys by running
       **every row of its Affected Files table through that same normalisation**: the
       table holds raw paths, and a raw path is not comparable to a key, so the
       candidate contributes one key per row. (b) holds when the item's key
       **string-equals** any of them. Equality is exact — no prefix or containment
       reading, because the normalisation is not recursive, so `…/references/` and
       `…/references/templates/` are two different keys and neither is "inside" the
       other. Worked both ways: a unit of `…/scripts/batch-deferred.sh` derives the
       stem key `batch-deferred`, and a candidate row naming
       `…/tests/test_batch_deferred.sh` derives `batch-deferred` as well — equal, so
       (b) holds; a unit of `…/references/maintenance.md` derives the directory key
       `…/references/`, and a candidate row naming
       `…/references/templates/issue-bug.md` derives `…/references/templates/` —
       unequal, so that row does not satisfy (b). Three outcomes fall out of the
       mapping and are decisions, not gaps: an **`area:*` unit** never satisfies (b),
       because no file path normalises to a label; a candidate with **no Affected
       Files table** contributes no keys and so satisfies (b) for nothing; and an item
       whose body gives you no unit to derive at all fails (b) too — record that in
       the decision, as step 9 requires, rather than inventing a unit that makes (b)
       true.
     - **An "open released issue"** is one in the same milestone that is open and
       carries none of `deferred`, `backlog` or `epic`. It is spelled out here rather
       than named, because both senses of "planned child" already in this file are
       wrong for (b): `backlog` means "don't work it" (step 10 below), and scheduling
       a residual against work nobody may start yet is the outcome the park rule
       exists to prevent, while an `epic` is a container whose children carry the work
       and which has no Affected Files table to derive keys from. This is deliberately
       **narrower** than the flush trigger's "no open planned children" further below,
       which counts every open non-`deferred` issue, `backlog` ones included: a
       `backlog` item does mean the milestone is unfinished, which is the flush's
       question, but it does not mean there is work to ride along with, which is
       (b)'s. Do not collapse the two.
     **Depth one overrides both conditions**: when the item's provenance names a PR
     that was itself a deferred-batch PR (a PR whose merge closed two or more
     `deferred` issues), the item always parks, whatever its severity or unit — a
     review of residual work records further residuals, it does not schedule them. The
     lookup is `gh pr view <PR> --json closingIssuesReferences` followed by one label
     read per number it returns; two or more of them carrying `deferred` fires the
     override, and one or none leaves the outcome to (a) and (b).
     - **Park mechanics**, applied by `home-deferred.sh`'s park path once #801 lands and
       by hand until then (four calls, in any order, all before this item leaves the
       checklist): close the issue with reason *not planned*; add the `parked` label
       while keeping `deferred` and the provenance line as they are; post a comment
       carrying exactly these two lines —

       ```
       Unit: <unit>
       Wake: second sighting | unit batch | milestone review
       ```

       — where the `Wake:` line is a **fixed literal, copied as written**: all three
       triggers always apply to every parked item, so there is nothing per-item to
       select. A second sighting reopens any parked item (`github-pr-review` SKILL.md
       Step 8), a dispatchable batch on the item's unit carries it as a rider (#802),
       and the milestone-end review reads *every* parked issue in the milestone (the
       flush rule below). Naming one trigger would tell a later reader that the other
       two do not apply to that item, which is false for every item.
       Finally, **remove the project item from the board** rather than leaving it on
       the board at any Status. `gh project item-delete` identifies the row by its
       `PVTI_` node id and accepts no issue number, so resolve the id first — one call
       per issue, and cheaper than paging the whole board:

       ```
       gh api graphql -f query='query($o:String!,$r:String!,$n:Int!){
           repository(owner:$o,name:$r){issue(number:$n){
             projectItems(first:10){nodes{id project{number}}}}}}' \
         -F o=<owner> -F r=<repo> -F n=<issue> \
         --jq '.data.repository.issue.projectItems.nodes[]
               | select(.project.number==<project-number>) | .id'
       gh project item-delete <project-number> --owner <owner> --id <PVTI_…>
       ```

       `<owner>` and `<project-number>` come from the repository's work-tracking doc
       (`docs/process/work-tracking.md`); an issue already off the board returns no
       node and needs no delete. Removal is the one mechanic that is not obvious:
       board automation moves a closed item to the Done column, and a parked item
       sitting in Done reads as delivered work when it was in fact never scheduled —
       removing the item is what keeps the board from lying about a park.
   - **Every other item** — owner-filed features, validation bugs, live-test blockers —
     may be homed under an epic: sub-issue of the epic it belongs to, or milestone
     directly, or neither if it is a standalone theme. Check the target epic's child
     count against that same 100-sub-issue cap before adding to it, and home to the
     milestone instead when it is near it.
   `home-deferred.sh` applies the decision record — `{issue, milestone, status,
   priority?, severity?, blocked_by[]?, labels[]?}`, `issue`/`milestone`/`status`
   required and the rest optional exactly as the script's own header marks them
   (`priority` is optional as a *field* only because it may arrive already prefixed
   inside `labels`; the `labels-complete` gate above still requires it in substance).
   `status` is the Ready/Backlog call `board` (step 10 below) states the rule for — make
   that call now, using step 10's rule, rather than deferring it past this point.
   The record has no `parent` field by design and the script refuses any record carrying
   one rather than silently dropping it — so on the epic path the parent link is a
   separate by-hand write, `gh api repos/{owner}/{repo}/issues/<epic>/sub_issues -F
   sub_issue_id=<id>` ([github-tools.md](github-tools.md)), and the script still applies
   the milestone, labels, links and Status for that item from its parentless record.
   Pass it `--claim <your claim id>` — the same id `claim` took above. The script takes
   the per-item claim itself before applying anything, and a `take` of a live claim that
   is already yours is an idempotent no-op (exit 0); pass a different id and it reads
   your own claim as a foreign one and skips every record on exit 3.
   Read the script's own exit code and its per-record REJECTED lines on stderr rather
   than assuming the record landed: a record missing `.milestone`, one whose
   `stamp-claim.sh take` returns 4, or one that fails the completeness gate is REJECTED
   and applies nothing to that item — no milestone, no labels, no Status, and (for the
   `take`-4 case) the claim the script itself took is handed back rather than left on
   the item. Nothing is stranded, but nothing is homed either: do not carry that item on
   to `chain`, `priority-order` or `board` as though it were — log it skipped with the
   rejection reason instead, the same as any other failed checklist step, and revisit it
   next pass.
7. **`chain`** — native `blocked by` links where order matters; fold small items into
   the in-flight issue whose natural home they are (say so on both).
8. **`priority-order`** — confirm this item's priority and severity (set at
   `labels-complete`) and its `blocked by` links (set at `chain`) are exactly the values
   the dispatch pick order in [orchestration.md](orchestration.md) § The loop, per
   issue, step 1 reads; that order lives in one place and is only ever pointed at from here, so
   a later change to it is a one-place edit instead of a hunt through every triaged item
   for a stale restatement of it.
9. **`batch`** — for a `deferred`-labelled item only (skip with why otherwise): derive
   its **unit** and record it as the `triage` event's `unit` key, so that the drain's
   closing step below can group it. A unit is the thing one PR would change, and it comes
   from one place: the body's `Unit:` line, the marker [SKILL.md](../SKILL.md)'s Deferred
   Items rule defines and `batch-deferred.sh` reads (#751). Normalise that line's value
   into the
   **batch key** two items compare on — this normalisation is the only mapping between
   the value a filer writes and the key a batch groups by, and both scripts use it:
   - a **file path** whose basename is `<x>.sh` or `test_<x>.sh` (equally `test-<x>.sh`)
     maps to the bare stem `<x>`, underscores folded to hyphens
     (`.claude/skills/github-workflow/tests/test_check_manifest.sh` and
     `.claude/skills/github-workflow/scripts/check-manifest.sh` both map to
     `check-manifest`): a script and its own test are one unit. This mapping is
     single-valued but not injective — it discards the path, so same-named scripts in
     two different skills collide on one key; that is accepted, not overlooked, and a
     batch that turns out to span two skills under one collided key is the triager's
     signal to split it by hand;
   - any **other file path** maps to its directory, with the trailing `/`;
   - a **directory path** maps to itself;
   - an **`area:*` label** maps to that label, and the decision says so — an area-level
     batch can mix unrelated files, and that is the filer's defect to stop repeating,
     not a reason to leave the item unbatched.
   **No `Unit:` line.** Absence proves nothing about the item's age — it predates the
   marker or its filer skipped a required line, and the body cannot tell you which — so
   do not record a unit you inferred silently. `batch-deferred.sh` excludes such an item
   from every batch with that reason, which is what keeps the unconverted backlog
   visible. You are not a script and can repair it instead: work the Deferred Items
   rule's *Choosing the value* steps yourself against the body's Affected Files table
   (or its `area:*` label when the body names no path), **write the `Unit:` line into the
   body**, and derive from the line you wrote — that repair, one triaged item at a time,
   is how the backlog converts. Note the repair in the decision, since the filer owed the
   line. If the body gives you nothing to write it from, say so in the decision and leave
   the item unbatched rather than guessing.
   Excluded from batching, each with the reason in the decision: an item with a
   `blocked by` link (it waits for its blocker); an item that asks for a decision
   rather than a fix; an item that is a planned child of an epic (planned work is never
   folded into a residual batch); an item already in an open PR — board Status
   `In progress` or `In review` (#738) — since batching it again dispatches a second
   agent onto work another agent is mid-round on; recompute dispatchable AFTER this
   exclusion, so a unit that drops below the threshold once its in-flight members are
   removed reports waiting, never stale-dispatchable. This exclusion refuses rather
   than degrades: a board config the tool cannot read is an error, never a quiet skip
   that would leave the batch looking clean while nothing was excluded. Excluded items
   are sequenced individually as before.
10. **`board`** — Backlog is NOT the default. An item that belongs to the active story or
   claimed epic, or that blocks its honest completion (review residuals, found defects
   in what just merged), goes to **Ready** — or is folded into an in-flight issue — as
   part of this pass, without waiting for an owner release. **Backlog** is only for
   items genuinely outside the current scope. "Park" for a `deferred` item's own
   Backlog vs. Ready call is not this step's Backlog at all — it is the closed,
   labelled, off-board outcome step 6's `home` decides above, before this step ever
   sees the item; see that step for the rule. When it is unclear whether the owner wants
   an item now, put the question in the brief rather than defaulting to Backlog (add the
   `backlog` label on what does land there; a milestone may or may not be set — Backlog
   means "don't work it", not "unplanned"). Once the Status move lands, **release the
   per-item claim** taken at `claim`: `stamp-claim.sh release --item <N> --id <claim>`
   (cloud/by-hand: clear the item's `Claimed by` field yourself). The claim's only job
   was to keep two orchestrators off the same item while it was being decided, and that
   job ends here — a claim left on a drained item misreports an item nobody is triaging
   as still live-claimed and blocks the next session from touching it for the whole
   24-hour stale window. Release whichever way the item went — Ready, Backlog, still in
   Triage for want of a milestone, or closed because it was folded into an in-flight
   issue — the claim covers the triage decision, not the item's residence. Releasing
   costs nothing later: when the item is eventually dispatched, the orchestrator writes
   the **informational** dispatch stamp to that same field (`stamp-claim.sh stamp`,
   logged as `claim-stamp`), which is the other of [claims.md](claims.md)'s two roles —
   unconditional, never a coordination lock, and never cleared. `release` on an
   already-empty field is an idempotent no-op, so re-running it is safe; an item skipped
   at `claim` on exit 3 has nothing to release, because this pass never took its claim.

Live-test blockers that gate the active epic's proof are active work by definition —
they take `home`'s non-deferred path and go straight to Ready under that epic, whatever
label they arrived with. That includes one filed with the `deferred` label: the label
records how the item was found, while the Deferred Items rule's parentless path governs
deferral filings queued for later, not work already gating the epic's proof. The epic's
child count is still checked before the item is added to it.

**Sighting reopen** is a new triage input, distinct from the milestone-end review
above: a parked issue that a reviewer reopened via a second `Seen again:` comment
(`github-pr-review` SKILL.md Step 8's dup-scan; the reopen there is the reviewer's
action, not this checklist's — triage still decides the outcome once the item is back
in Triage) lands back in the Triage column open and no longer `parked`. It runs the
whole checklist above as a fresh item, exactly like any first-time filing, with one
exception: `home`'s condition (c) above and its floor mean the item's two-or-more
`Seen again:` comments carry forward into this pass and hold it at work-now through the
drain that follows its reactivation, so the reopen is not undone by the very next
drain. `orchestration.md`'s Report-handling `deferrals` item re-adds a
sighting-reopened issue to the board with `home-deferred.sh --readd --status Triage`
before this drain reaches it.

### Batching, after the per-item checklist

Once every item in the column has been through the checklist, group the open
`deferred` items — the ones just drained and the ones already in Ready — by unit (the
`unit` key their `triage` events recorded; derive it now, by the same rules, for any
Ready member that has none), and mark each unit **dispatchable** or **waiting**:

- A unit is dispatchable at **three or more** open members. Below that it waits for a
  later drain, unless the milestone every member belongs to has **no open planned
  children** left — then every unit of *open* members flushes, at any size. A member
  with no milestone counts toward the flush of whichever milestone the other members
  share; a unit whose members share no milestone flushes only at the threshold. That
  same "no open planned children" trigger also turns the milestone's **parked** items
  into a **milestone-end review**, not a work order (epic #798 owner decision 6): read
  every `parked` issue in that milestone and either promote it — reopen it, remove the
  `parked` label, and run it back through this checklist as a fresh item — or leave it
  parked with a `Rejected: <reason>` comment added. A rejected item stays closed,
  stays `parked`, and stays found by the `github-pr-review` dup-scan; it is not
  closed-and-forgotten, because staying findable is what stops a later reviewer
  re-filing the same finding. A parked item never joins a batch on its own; it only
  rides a dispatchable batch of its own unit as a rider, per #802.
- A waiting member stays in Ready but is not picked on its own: the loop's pick
  ([orchestration.md § The loop, per issue, step 1](orchestration.md#the-loop-per-issue))
  reads the latest `maintenance` event's `triage.batches` and skips a `deferred` item
  whose unit is waiting.
- A dispatchable unit holds at most **about eight** members per batch, or fewer when
  the members' stated sizes would push the PR past the review budget (≤ ~400 net LOC /
  ≤ 15 files). Split a larger unit by `priority:*`, highest first, and the remainder
  waits as its own batch of the same unit.
- Batches on **different** units may run in parallel; batches on the **same** unit run
  serially — the unit is the file set, so it is the conflict boundary
  [orchestration.md § Parallel safety](orchestration.md#parallel-safety) already uses.
- A batch is picked and dispatched by the loop
  ([orchestration.md § The loop, per issue, step 1](orchestration.md#the-loop-per-issue))
  as one named cohesive group, and its PR is an ordinary PR: classed and capped like any
  other, reviewed under the same rules, and its residuals land in Triage and join the
  unit's next batch. Nothing about the review changes because the PR closes several
  issues.

Record the grouping in the maintenance report's `triage.batches` (unit, members,
dispatchable); each member's own `triage` event already carries its `unit`.
[`batch-deferred.sh`](../scripts/batch-deferred.sh) proposes this grouping read-only from
the issue bodies, GET-only, applying the same unit derivation, exclusions, threshold,
cap-split and flush rules stated above (`github-tools.md`'s Scripts table has its full
row); the orchestrator still derives it by hand from the same fields, in the same order,
whenever the script is unavailable (a cloud dispatch with no local `gh`, most often) —
but the by-hand derivation is not a drop-in substitute for the script on the no-table
fallback specifically: a by-hand reading that takes "the first backticked path in the
body" literally, rather than preferring a bare `<name>.sh` token first, diverges from
the script on real items with no Affected Files table (5 of 21 in this repo's own
corpus). Follow the amended rule above by hand too, not the older literal wording.

## 2. Host audit

Read CPU load, memory and disk free; list processes older than the session that look like
test leftovers (containers, runners, servers, stray node/dotnet processes). Compare disk
usage to the previous pass — a large jump is a signal to investigate before continuing,
not a number to log. Thresholds are the repo's (`docs/process/maintenance.md` if it
exists); absent that, use judgment and say what you used.

## 3. Cleanup

Remove what tests left behind: containers, images, volumes and networks with the repo's
test prefix, temp worktrees from finished reviews, untracked garbage in the repo tree
(`git status --porcelain` outside the allowed scratch locations). Never a blanket prune —
other sessions share the host. List what you removed in the report.

## 4. Rule audit

The rules agents are most likely to break silently:

- Anyone working in the **main checkout** (`git status` there should be clean and on
  main; a dirty main checkout is an agent that skipped its worktree).
- Files written **outside the allowed locations** (repo tree, the documented worktree
  root, the documented scratch dir).
- Evidence or captures containing anything the repo's sanitization rule forbids, sitting
  inside the repo tree even untracked.
- Agents that spawned subagents against instruction (their reports will say so if asked;
  a suspiciously fast large diff is the tell).

Findings become issues or resume directives; a repeated finding becomes a
[failure-modes.md](failure-modes.md) entry.

## 5. State audit

The board is the coordination surface, so its lies are expensive. Every pass runs one
GET-only invocation of [`board-audit.sh`](../scripts/board-audit.sh):

```
board-audit.sh --repo <owner/name> --target <session's target> --since <ts> --claim <claim id>
```

`--target` is the session's milestone number, or its epic's issue number when the
session targets an epic; the script tries a milestone first and falls back to an epic
on a 404, and its `target_kind` key states which ran. `--since` is the `ts` of the last
`maintenance` event in the session log, or session start on the first pass:

```
jq -rs '(map(select(.event=="maintenance"))|last|.ts) // (map(select(.event=="session-start"))|first|.ts)' <scratch>/session.jsonl
```

Save this run's JSON output to `<scratch>/board-audit-<ts>.json` (`<ts>` the run's UTC
start, `YYYYMMDDTHHMMSSZ`) — the `raw_log` pointer the report carries, session-local and
ephemeral. This one run is the sole source for `missing_board_items[]`,
`homed_by_others[]`, `missing_size_label[]`, `bad_priority_label[]`,
`bad_severity_label[]` and the `board_audit` report key
([formats/maintenance-report.md](formats/maintenance-report.md)); never run it twice
per pass. Do not pass `--limit` here: `homed_by_others` feeds the check below, and the
script's own `updated_at` pre-filter and bounded concurrency already bound the walk
([../scripts/board-audit.sh](../scripts/board-audit.sh) documents the flags). The script
only reports, it never mutates, so the remaining checks stay separate work on top of
its output. Check:

- Every open issue is on the board — `board-audit.sh`'s `missing_board_items[]` names the
  gap directly; re-add each one with `home-deferred.sh --readd` (bare issue numbers on
  stdin; it adds the missing project item and sets Status) and log what was re-added.
  None is In progress / In review without a live PR or agent; nothing is Done while open —
  a reopened issue still showing Done goes back to Triage (there is no reopen automation
  on personal-account Projects).
- `homed_by_others[]` — items the script's heuristic says were homed into this session's
  target since the last pass, apparently by another orchestrator — goes straight into the
  report unfiltered: the timeline the heuristic reads cannot attribute an event to a
  session, so the list over-reports (it also catches this run's own homings) and is meant
  for a human or orchestrator glance, not blind action. This line is the second half of
  cross-session visibility — the first half is the fresh pick each loop makes at
  [orchestration.md](orchestration.md) § The loop, per issue, step 1 off whatever § 1
  Triage drain has already homed. Together they stand in for a cross-session inbox no
  session has to maintain by hand.
- `missing_size_label[]`, `bad_priority_label[]`, `bad_severity_label[]` (#733, #745) —
  every open issue this run flags for a missing `size:*`, a `priority:*` count other
  than exactly one, or a `bad_severity_label` hit (a `bug` with zero `severity:*`, or
  any issue with more than one). None of these three is remediated here: file the
  gap into Triage the same as any other found defect (`labels-complete`, § 1 above, is
  where the fix actually lands) — this step's job is to surface the count, not silently
  backfill 50+ historical issues in one maintenance pass.
- Claims: yours is current; others' are live or stale (take over per
  [claims.md](claims.md)).
- Epics: every open epic has >1 child, is under the 100-child cap, and its parent (if any)
  is open; no open child of a closed parent.
- Milestone descriptions still describe reality; if a story-wide assumption changed since
  the last rewrite, rewrite the *Current state* section wholly now and add a decision
  ledger entry.
- `pending-live` count — feeds the validation trigger check
  ([validation.md](validation.md)).
- Session log consistency — one run of
  [`log-consistency-check.sh <scratch>/session.jsonl`](../scripts/log-consistency-check.sh),
  a second cheap `jq` pass over the log distinct from the heartbeat's
  [`stall-check.sh`](../scripts/stall-check.sh) (this check runs on the maintenance pass,
  never the heartbeat — the heartbeat does no maintenance, per this file's opening
  paragraph). It reports any `report` with no matching `dispatch` — same-or-earlier by `ts` — for
  the same role+agent (a role whose `dispatch` never got logged, which is what let this
  session's 34 reviewer, 12 fix and 6 merge-verifier dispatches go unnoticed for hours;
  `pr` is deliberately not part of the key — an implementer's `dispatch` has no `pr` yet
  while its own matching `report` does — and ordering by `ts` is what still tells apart
  two legs that share the same role+agent, such as a relay-resumed dispatch reusing its
  original agent id; a dispatch and its report sharing one whole-second `ts` — the direct
  result of hand-logging a missing event per this file's own remedy below — pair as
  same-or-earlier/same-or-later, not as a mismatch in both directions), and any
  `dispatch` with no matching `report` — same-or-later by `ts` — and closed by neither
  that nor a `merge` matching its `issue` or its `pr`. A `relay` leg never stands in for
  the original `dispatch` it resumes. Findings become
  issues (an under-logged role) or a same-pass fix (log the missing event by hand once
  its provenance is confirmed from chat/PR history); log what was found in the
  `state.log_consistency` report key.
