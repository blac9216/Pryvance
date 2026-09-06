# Session log format

Append-only JSON lines at `<scratch>/session.jsonl`, from step 0, in every mode.
One object per event. `jq` aggregates; the model does not re-read the file to count.

Required keys: `ts`, `event`, `claim`. `ts` is UTC, **exactly**
`YYYY-MM-DDTHH:MM:SSZ` (second precision, literal `Z` — no fractional seconds, no
`+00:00` offset, no bare-minute form): `date -u +%FT%TZ`, e.g. `2026-09-04T16:52:31Z`.
This is the sole form `stall-check.sh` and `log-consistency-check.sh` accept — a `ts`
at any other precision (e.g. minute-only, `2026-09-04T16:52Z`) is schema-invalid and
both readers reject it, distinctly diagnosed on stderr as "ts at unsupported
precision" rather than lumped in with a missing or unparseable `ts` (issue #743).
Every script that appends to this log must emit this exact form; do not reuse a
different timestamp variable (e.g. one computed for a human-facing board field, see
`claim.md`'s `Claimed by` format, which is intentionally minute precision and is a
different string entirely) for `ts`.

Archived logs in `blac9216/workflow-logs` written before this issue (#743) contain
`claim`/`claim-stamp` records at minute precision, from the pre-fix `stamp-claim.sh`.
Those records were already silently discarded by both readers before this schema
statement existed; this change does not make anything that used to parse stop
parsing — it only makes a reader's rejection of that historical shape identifiable
via its own diagnostic ("ts at unsupported precision") instead of the misleading
"malformed (unparseable/missing ts)". Repairing or backfilling the archive itself is
out of scope here — see #737, which tracks historical-log archiving separately.

Optional keys by event:

| event | keys |
|---|---|
| `session-start` | `target`, `mode` (`solo` / `orchestrated serial` / `orchestrated parallel`, see [SKILL.md](../../SKILL.md)'s Entry section), `horizon` (`interactive` / `overnight`, same section), `main_sha`, `session_id` |
| `startup-item` | `item` (canonical slug, see below), `skipped` (bool), `why` (required if `skipped`) |
| `startup-complete` | `skipped` (array of the same canonical slugs, empty if none), `why` (map item→reason) |
| `triage-item` | `item` (canonical slug, see below), `skipped` (bool), `why` (required if `skipped`) |
| `triage-complete` | `skipped` (array of the same canonical slugs, empty if none), `why` (map item→reason) |
| `dispatch-item` | `item` (canonical slug, see below), `skipped` (bool), `why` (required if `skipped`) |
| `dispatch-complete` | `skipped` (array of the same canonical slugs, empty if none), `why` (map item→reason) |
| `report-item` | `item` (canonical slug, see below), `skipped` (bool), `why` (required if `skipped`) |
| `report-complete` | `skipped` (array of the same canonical slugs, empty if none), `why` (map item→reason) |
| `close-item` | `item` (canonical slug, see below), `skipped` (bool), `why` (required if `skipped`) |
| `close-complete` | `skipped` (array of the same canonical slugs, empty if none), `why` (map item→reason) |
| `claim` | `action` (take/refresh/takeover/release), `item`, `superseded` |
| `claim-stamp` | `issue` |
| `dispatch` | `role` (implementer/fix/reviewer/validation/helper/rebase/merge-verifier/calibrator), `model`, `issue`, `pr`, `agent` |
| `report` | `role` (same enum as `dispatch.role`), `agent`, `model`, `issue`, `pr`, `tokens`, `duration_s`, `outcome`, `helpers` (reviewer only, optional) |
| `review` | `pr`, `round`, `kind` (standard/merge-verification/residual), `verdict` (approved/changes/decomposition/escalated), `findings`, `agent` |
| `relay` | `pr`, `round`, `role` (implementer/reviewer — which agent was resumed), `agent`, `findings` (count relayed), `head` (the SHA carried on the reviewer leg), `fallback` (bool — true when the harness could not resume and a fix-round dispatch stood in) |
| `merge` | `pr`, `issue`, `rounds`, `verified` |
| `board` | `issue`, `from`, `to`, `by` |
| `stall-check` | `idle_count` (agents `stall-check.sh` found idle this run, 0 when none) — logged on every heartbeat run, whether or not any agent was idle, so an archived log proves the check ran even on a clean pass; a `stall` event (below) is the separate, conditional record of what was found |
| `stall` / `resume` | `agent`, `reason`, `terminal` (bool, `stall` only, optional — see below) |
| `escalation` | `issue`, `pr`, `reason` |
| `triage` | `issue`, `decision`, `applied` (array of mutations made), `unit` (deferred items only) |
| `amend` | `issue`, `review`, `old_ac`, `new_ac`, `sibling` |
| `self-correction` | `agent`, `rule`, `what_happened`, `correction` |
| `validation-considered` | `trigger`, `decision`, `reason` |
| `validation` | `epic`, `run`, `result` (pass/fail counts), `bugs` |
| `maintenance` | the maintenance-report object |
| `brief` | `kind` (status/morning), `path` |
| `note` | `text` — free text, sparingly |

`session-start.session_id`: the harness- or run-assigned session identifier, if the
platform exposes one; otherwise a value the orchestrator mints itself at startup (e.g. a
short random token). It names the session file
(`logs/<repo>/<session-start-ISO>-<session_id>.jsonl` in the archive) and distinguishes
concurrent sessions sharing a claim id — a claim id is not unique across unrelated
sessions and is not an identity on its own.

Canonical `item` slugs, in checklist order (used verbatim by both `startup-item` and
`startup-complete.skipped`): `log-open`, `quiet-mode`, `target-mode-horizon`, `orient`,
`agent-defs`, `session-card`, `concurrent-check`, `claim`, `timeline-sanity`,
`readiness-gate`, `maintenance`, `heartbeat`.

Every other logged checklist (triage, dispatch, report-handling, close) opens with
`card-read` as its first slug — confirming the session card was consulted, not
re-derived from memory — then continues with slugs specific to that transition. All four
lists below are settled; the owning reference for each is where the checklist itself is
defined, and any future rewording of a slug name lands there first, propagating here
without changing this file's `-item`/`-complete` mechanism.

Canonical `item` slugs for the **triage** checklist, in order: `card-read`, `claim`,
`provenance`, `dedupe`, `labels-complete`, `home`, `chain`, `priority-order`, `batch`,
`board`.

Canonical `item` slugs for the **dispatch** checklist, in order (owning reference: the
Dispatch checklist section of `orchestration.md`): `card-read`, `pick`, `claim-stamp`,
`worktree`, `board`, `model`, `preflight`, `evidence-key`, `manifest`, `dispatch`. That
`claim-stamp` step's own `claim-stamp` event (above) records `stamp-claim.sh stamp`'s
write of the informational per-issue dispatch stamp; it is deliberately not named
`dispatch` — the orchestrator already emits its own `dispatch` event for the same
dispatch (role/model/issue/pr/agent), and giving the stamp step a distinct event name
keeps the two from being double-counted by a `dispatch`-keyed aggregation. That final
`dispatch` item is the checklist's own record that the `dispatch` event above was in fact
emitted; it is a checklist item, not a second event of its own.

Canonical `item` slugs for the **report-handling** checklist, in order (owning
reference: the Report-handling checklist section of `orchestration.md`, covering merge
as one outcome): `card-read`, `report`, `self-corrections`, `deferrals`, `verdict`,
`relay`, `board`, `metrics`, `epic-event`, `cleanup`, `claim-refresh`. The last four
(`metrics`, `epic-event`, `cleanup`, `claim-refresh`) apply only when the outcome being
handled is a merge; every other outcome closes the checklist after `board`.

Canonical `item` slugs for the **close** checklist, in order (owning reference: the
Close checklist section of `overnight-and-status.md`): `card-read`, `save-log`, `brief`,
`claims-released`, `heartbeat-off`, `handoff`.

Logged checklists exist because a step skipped when attention moves on is invisible
unless the log says so; recording every item, skipped ones with their `why`, lets a
later reader tell "not needed here" from "forgotten".

`report.model`: what ran the role — the tier (`small`, `mid`, or `large`, see
`orchestration.md`'s Routing table) or, where the harness reports one, the concrete
model name (Claude: `haiku`, `sonnet`, `opus`). **Both forms are valid values of this
field**, so records written before the tier vocabulary existed stay on-schema and the
field keeps the name `model`; prefer the tier when the dispatch chose one. Whichever
form is used, it is the same value the matching `dispatch` event carries for that role.
The orchestrator writes the `report` line and already knows what it dispatched, so
recording it there too makes each `report` event self-contained — a `jq` filter over
`report` events alone can fill `roles{}.model` (the chronologically last value seen for
that role, with the optional `roles{}.models` companion holding every distinct value in
first-seen order when more than one ran) without also joining `dispatch`.

`report.helpers` (reviewer role only): array of the helpers the reviewer spawned this
round, one object per helper — `model` (same two accepted forms), `purpose`, `tokens`
(optional; record explicit `null` rather than estimate when the harness does not surface
it). Same field names as
[github-pr-review/SKILL.md](../../../github-pr-review/SKILL.md)'s handoff enumeration
and `issue-metrics.md`'s footer `helpers` key. Numbers the orchestrator cannot see stay
explicit `null` — never estimated.

A reviewer's helper is recorded **only** inside that reviewer's `report.helpers` array —
it never gets its own `dispatch`/`report` pair. `helper` remains a valid `role` for the
`dispatch`/`report` enum above solely for a helper spawned directly by the orchestrator
outside a reviewer round (e.g. an ad hoc pre-flight check); `helper` is not a `roles{}`
key in the `issue-metrics.md` footer, and its `report` events are excluded from the
`roles{}` aggregation one-liner there. That one-liner aggregates exactly the three
aggregated footer roles — `implementer`/`fix`/`reviewer` — so `helper`, `validation`,
`calibrator`, and any other role on the enum above that is not one of those three is
excluded from it the same way, not just `helper`. Since footer `"v":2`, `rebase` and
`merge-verifier` are also `roles{}` keys, but each is filled straight from its own
single `report` event rather than through that one-liner — see `issue-metrics.md` for
why. Logging a reviewer-spawned helper both inside `report.helpers` and as its own
`role:"helper"` dispatch/report pair double-counts its tokens and must not be done.

`triage`: one line per item the triage checklist homes, carrying the decision record —
what was decided about the item, not the mechanics of the checklist steps that produced
it — and `applied`, the array of mutations the decision actually caused (labels set,
milestone assigned, links added, board column moved). `applied` lets a later reader
confirm the decision was carried out, not just recorded. A `deferred` item also carries
`unit`, the batch unit the `batch` step derived (`maintenance.md` § 1, `batch`); the
grouping the drain then settled on is in that pass's `maintenance` event. `decision` is
free text describing the outcome, not a closed enum, but two values name the park
mechanism specifically and are used verbatim when they apply: `parked` (the item was
closed not planned, labelled `parked`, and removed from the board — `maintenance.md`
§ 1 step 6) and `promoted` (a milestone-end review reopened and re-triaged a previously
parked item — `maintenance.md` § 1's Batching section). A parked item that instead gets
a `Rejected:` comment and stays parked is not a `triage` event at all — it is logged
where the milestone-end review records it, since the item's triage state does not
change.

`stall.terminal` (issue #725): `true` marks the leg CLOSED administratively — the
orchestrator's own assertion that this agent will never resume and never report,
written when it declares the agent dead (see `overnight-and-status.md`'s dead-agent
handling) rather than merely idle. `reason` is REQUIRED whenever `terminal` is `true`: a
leg closed with no stated reason is indistinguishable from one silently dropped, which
is exactly the failure this field exists to rule out. `stall-check.sh` and
`log-consistency-check.sh` both stop reporting a leg once its most recent (or, for
`log-consistency-check.sh`, any later) event is a terminal `stall` — see each script's
own header comment. Omit `terminal` (or set it `false`) for the ordinary heartbeat
`stall` — the note that an agent was merely found idle this pass, which must not
silence the next pass's report of the same agent still idle.

`relay`: one line per leg of a relay (`orchestration.md`'s Report-handling checklist,
`relay`): the implementer leg carries the findings count, the reviewer leg carries the
head SHA the implementer reported. `fallback: true` marks a leg the harness could not
resume, where a fix-round dispatch stood in; the round count does not advance.

`amend`: logged whenever a review changes an issue's acceptance criteria mid-flight
(scope-note territory) rather than filing a new issue. `sibling` names the issue that
will deliver the work the amendment carved off, if any; omit it when the amendment only
narrows or clarifies the existing AC with nothing carved off.

`self-correction`: logged the moment the orchestrator notices it (or an agent's report
surfaces it) — never solicited by a reflection prompt, and never written to pad the log.
`rule` names the standing rule that was nearly or actually broken; `what_happened`
states the deviation plainly; `correction` states what was done about it. One line, no
elaboration.

Example:
`{"ts":"2026-08-29T15:10:00Z","event":"dispatch","claim":"acme-03","role":"implementer","model":"mid","issue":1140,"agent":"a1b2"}`

Reviewer report with helpers:
`{"ts":"2026-08-29T16:40:00Z","event":"report","claim":"acme-03","role":"reviewer","agent":"c3d4","model":"large","issue":1140,"pr":1141,"tokens":48000,"duration_s":900,"outcome":"approved","helpers":[{"model":"mid","purpose":"calibrate-findings","tokens":1204}]}`

Rebase/merge-verifier/calibrator roles:
`{"ts":"2026-08-29T17:05:00Z","event":"dispatch","claim":"acme-03","role":"rebase","model":"mid","issue":1140,"pr":1141,"agent":"e5f6"}`
`{"ts":"2026-08-29T17:20:00Z","event":"report","claim":"acme-03","role":"merge-verifier","agent":"g7h8","model":"mid","issue":1140,"pr":1141,"tokens":9000,"duration_s":300,"outcome":"verified"}`

Review with `kind`:
`{"ts":"2026-08-29T17:25:00Z","event":"review","claim":"acme-03","pr":1141,"round":2,"kind":"merge-verification","verdict":"approved","findings":0,"agent":"g7h8"}`

Session start with `session_id`:
`{"ts":"2026-08-30T09:00:00Z","event":"session-start","claim":"acme-01","target":"epic-1140","mode":"orchestrated parallel","horizon":"overnight","main_sha":"d815a47","session_id":"s-9f3c"}`

Startup checklist example:
`{"ts":"2026-08-30T09:00:03Z","event":"startup-item","claim":"acme-01","item":"concurrent-check","skipped":false}`
`{"ts":"2026-08-30T09:00:45Z","event":"startup-complete","claim":"acme-01","skipped":["timeline-sanity"],"why":{"timeline-sanity":"no due_on or milestone-start data returned by Orient this session"}}`

Triage, dispatch, report-handling and close checklist examples:
`{"ts":"2026-08-30T09:15:03Z","event":"triage-item","claim":"acme-01","item":"provenance","skipped":false}`
`{"ts":"2026-08-30T09:15:40Z","event":"triage-complete","claim":"acme-01","skipped":[],"why":{}}`
`{"ts":"2026-08-30T09:16:00Z","event":"dispatch-item","claim":"acme-01","item":"preflight","skipped":true,"why":"implementer dispatch, preflight is reviewer-only"}`
`{"ts":"2026-08-30T09:16:10Z","event":"dispatch-complete","claim":"acme-01","skipped":["preflight"],"why":{"preflight":"implementer dispatch, preflight is reviewer-only"}}`
`{"ts":"2026-08-30T17:22:00Z","event":"report-item","claim":"acme-01","item":"self-corrections","skipped":false}`
`{"ts":"2026-08-30T17:22:30Z","event":"report-complete","claim":"acme-01","skipped":[],"why":{}}`
`{"ts":"2026-08-30T18:00:00Z","event":"close-item","claim":"acme-01","item":"claims-released","skipped":false}`
`{"ts":"2026-08-30T18:00:20Z","event":"close-complete","claim":"acme-01","skipped":[],"why":{}}`

Triage decision record:
`{"ts":"2026-08-30T09:20:00Z","event":"triage","claim":"acme-01","issue":1204,"decision":"homed to the current milestone, no epic parent (loose item)","applied":["milestone:current","label:priority:low"]}`

Amend:
`{"ts":"2026-08-30T10:05:00Z","event":"amend","claim":"acme-01","issue":1140,"review":1141,"old_ac":"single endpoint handles both cases","new_ac":"single endpoint handles the primary case","sibling":1205}`

Self-correction:
`{"ts":"2026-08-30T10:30:00Z","event":"self-correction","claim":"acme-01","agent":"orchestrator","rule":"never merge own work","what_happened":"began squash-merging PR 1141 from the orchestrating session","correction":"stopped; dispatched a merge-verifier instead"}`

Claim and claim-stamp:
`{"ts":"2026-08-30T09:05:00Z","event":"claim","claim":"acme-01","action":"take","item":1140,"superseded":null}`
`{"ts":"2026-08-30T09:16:05Z","event":"claim-stamp","claim":"acme-01","issue":1141}`
