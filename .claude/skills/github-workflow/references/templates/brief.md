# Brief Template

Produced on `status` (work continues) and `good morning` (dispatch frozen, in-flight
drained). Built from the session log (`jq`), the board, and — for the **Possibly
partially delivered** section only — a read of each Ready issue's body for ticked
acceptance-criteria checkboxes; not from memory.

```markdown
# Brief — <target> — <UTC timestamp> — <status | good morning>

**Headline**: one line on where the target stands. [good morning: "dispatch frozen,
in-flight drained".]

**Orchestrator's read**: a short paragraph — where this session feels it is versus
where it started. Opinion, deliberately; the sections below are the facts.

**Startup gaps**: sourced from the log's `startup-item`/`startup-complete` events —
`none` if `startup-complete` is logged with an empty `skipped` array; otherwise list each
skipped item and its `why`; `startup incomplete` if no `startup-complete` event exists yet.

**Session log**: the archive commit URL `save-log.sh` printed for this brief's save
(`status`, `good morning` and the Close checklist each archive before briefing), or
`unchanged since <URL>` when the script skipped an identical blob, or `not configured`
when `docs/process/work-tracking.md` names no archive.

## Merged since last brief
| Issue | PR | Rounds | Verified |

## In flight
| Issue | Stage | Round | Agent state (running / reporting / stalled) |

## Blocked on you
- #N — the question — **recommendation**: …

## Possibly partially delivered
Any Ready issue with ≥1 ticked acceptance-criteria checkbox (the mechanical trigger —
no other heuristic). Flagged for the owner, not gated: `#N — <count> of <total> ACs
ticked`.

## Validation
pending-live: <count> · last run: <date, result> · open validation epic: #V or none ·
next trigger check: <which trigger, when>

## Drift and anomalies
Rule-audit findings, stale claims taken over, host pressure, stalls and resumes.

## Metrics
Agents dispatched by role/model · review rounds per PR (mean, max) · first-pass approval
rate · stalls · wall-clock since session start · tokens by role.

## Proposed next dispatch
What starts if you say go, in order, with why.
```
