# Overnight, status, and the morning ritual

## The session log (always on)

From step 0, every session appends one JSON line per event to the log file in the
session's scratch directory ([formats/session-log.md](formats/session-log.md)): dispatch,
agent report, review round and verdict, fix round, merge, stall, resume, escalation,
validation considered/started/result, maintenance pass, claim change; per agent: model,
tokens, wall-clock. Cheap to write, and the only source for the metrics in a brief. `jq`
aggregates it; do not re-read it into context to count things.

## Quiet mode

Chat gets one line on: dispatch, merge, blocked-on-owner, escalation, validation result.
Every ten logged events, a three-line summary. Nothing else. The owner reads the brief,
not a narration.

## Heartbeat

Armed at session start on every horizon, never conditioned on it: an `interactive`
session is one usage-limit interruption away from being an overnight one, and horizon is
a self-declared field nothing later re-evaluates, so the only defensible bar is
unconditional. Create an hourly cron whose prompt is the single word `heartbeat`. It
exists so a usage-limit interruption resumes itself. Beyond that, it does no work except
one cheap check, run as [`scripts/stall-check.sh <idle-minutes>
<scratch>/session.jsonl`](../scripts/stall-check.sh) rather than re-derived by hand each
session, logging a `stall-check` event on every run whether or not it found anything —
the log entry, not the memory of having armed the cron, is what lets a later reader of
the archive tell whether a stall check actually ran this hour
([formats/session-log.md](formats/session-log.md)'s `stall-check` row) —
`stall-check.sh`'s own header comment block states its predicate in full, and
`stall-check.sh --help` states it too (issue #720: exits 0 and prints the predicate, not
the one-line usage-error string a genuine argument mistake still gets on stderr with exit
2), and `tests/test_stall_check.sh` proves it against the three of the four shapes below
that are this predicate's to hold — the first (blind to a role whose `dispatch` went
unlogged) is `log-consistency-check.sh`'s, the separate consistency check named just
below, and that suite explicitly disclaims it rather than asserting it here. In one
sentence: an agent is in flight when its most recent logged event is a `dispatch`, a
`relay` naming it as the party being resumed, a `stall` (the heartbeat's own note that it
found this agent idle — logging that note must not stop the next run from seeing the same
agent, still idle, again), or a `resume` (work picked back up — an opener, same as a
fresh `dispatch`, never a closer), and that leg is not yet closed by a later `report`
from the same agent, by the matching leg-2 `relay` for the same `pr`+`round` (a relay's
two legs are filed under different agent ids — see
[formats/session-log.md](formats/session-log.md)'s `relay` row — so pairing is by
`pr`+`round`, never by agent id alone), by a `merge` matching that agent's `issue`
**or** `pr` (an implementer's `dispatch` often has no `pr` yet — the PR doesn't exist at
dispatch time — so pr-only matching would leave such a leg unclosable by any merge), or
by a `stall` carrying `"terminal": true` and a required `reason` (issue #725 — the
orchestrator's own administrative close, written when it declares the agent dead; see
the dead-agent paragraph below).
The idle duration reported is measured from the agent's most recent `dispatch`/`relay`/
`resume`/`report` — never from a `stall`, which is the heartbeat's bookkeeping about the
agent, not evidence the agent did anything; measuring from it would make a repeatedly
flagged agent read as freshly idle between notices instead of the true duration of its
silence. When an agent's entire logged history IS `stall` events and nothing else, there
is no non-`stall` event to measure from at all; the script falls back to that agent's
EARLIEST logged `stall` — a stated lower bound on how long it has actually been silent,
not a claim about exactly when it went idle. This fixes four ways the older one-`jq`-pass description under-reported: it is
not blind to a role whose `dispatch` went unlogged (that gap is the separate consistency
check below, not this predicate); "most recent event", not "has no report at all", so a
**resumed** agent that stalls again after its first report is still caught; pairing
relay legs by `pr`+`round` means a relay leg genuinely closed does not read as
permanently in flight, while a relay leg genuinely stalled (most often the second,
reviewer, leg) still is; and logging the very `stall` this heartbeat writes below does
not remove the agent from view, nor does it reset how long it has actually been silent.
For each agent the script names as idle, inspect its worktree (`git status`, tail
the last log lines), then resume it per
[orchestration.md § Restarting a stalled agent](orchestration.md#restarting-a-stalled-agent),
or, when the worktree state is not safe to resume unattended, **report**: write a
`stall` event to the session log and send the one-line chat notice — nothing more,
since the heartbeat does no maintenance and starts no new dispatch. When instead you
declare the agent dead — stop the task, confirm it (no filesystem write, no host
process, no answer), and re-dispatch its work under a fresh agent — writing that
decision is part of the same act, not a follow-up: log the `stall` (or a fresh one, if
none is pending) with `"terminal": true` and a `reason` stating why (issue #725,
`formats/session-log.md`'s `stall.terminal` row). That is what stops
`stall-check.sh`/`log-consistency-check.sh` from reporting the dead agent's leg
forever — a `merge` on the leg's own `issue`/`pr` closes it too, but that can be hours
away, and the terminal `stall` closes it the moment you make the call instead of
leaving the report noisy in between. Delete the cron at
handoff or when the owner ends the session, regardless of which horizon the session
declared at start. The scheduled-prompt mechanism itself is harness-specific — see
[platform-claude.md § Porting this
suite](platform-claude.md#porting-this-suite) for what a different harness must
supply for orchestrator self-resume.

## Overnight

- Owner-gated decisions: label `help`, comment options + recommendation, route around
  them; the brief lists them first.
- Honour the repo's standing overnight limits from `docs/process` (read-only lab, scope
  ceilings, no destructive operations).
- On resume after an interruption: Orient again from GitHub, verify every in-flight
  agent's worktree state before resuming it, then continue.

## `status`

Archive the session log first — `save-log.sh --log <scratch>/session.jsonl --claim <claim
id>` — then produce the brief ([templates/brief.md](templates/brief.md)) from the log
and the board, carrying the archive commit URL the script printed on the brief's
**Session log** line (or `not configured` when the script exits 2 because
`docs/process/work-tracking.md` names no archive). **Do not stop or slow any work.** The
owner may then choose to run the ritual below or say nothing and let the session
continue. The bare `save` keyword ([SKILL.md](../SKILL.md) § Entry) runs the same
archive call and prints the same URL without producing a brief.

## `good morning`

1. **Freeze**: no new dispatches. In-flight agents finish their current step (a review
   round completes, a fix lands); nothing new starts.
2. **Drain**: wait for in-flight reports; update the board and log as they arrive.
3. **Brief**: archive the session log exactly as `status` does, then the full template,
   with "dispatch frozen, in-flight drained" in the headline and the archive URL on the
   **Session log** line.
4. **Ritual**: the owner answers the open questions and corrects drift; apply each
   correction on GitHub as it is given (comment, re-label, move, rewrite).
5. The owner may then say **`morning cleanup`**: consider validation (start a loop if a
   trigger holds), run the full maintenance pass, report the validation status, and ask:
   **handoff or continue?**
6. **Handoff** → run the **Close checklist** below. **Continue** → resume dispatch from
   the proposed next dispatch in the brief; the session is not closing, so the Close
   checklist does not run — claims stay held and the heartbeat stays live.

## Close checklist

Runs at handoff (`good morning` item 6, above), logging each item as a `close-item`
event and closing with `close-complete`
([formats/session-log.md](formats/session-log.md)); skip only with a `why`. The same
rationale as the other logged checklists applies here too: a close step skipped while
the session is winding down leaves no trace unless the log records it, and a session
that ends without confirming its own claims and heartbeat are cleared hands the next
session a stale board to untangle.

1. **`card-read`** — the session card is re-read.
2. **`save-log`** — the session log is archived to the configured per-session archive
   with `save-log.sh --log <scratch>/session.jsonl --claim <claim id>` (the archive
   location comes from `docs/process/work-tracking.md`'s `Session-log archive:` line;
   the file's name from `session-start.session_id`,
   [formats/session-log.md](formats/session-log.md)) — skip with why when the script
   exits 2 because no archive is configured for this repo. The archive commit URL it
   prints goes on the brief's **Session log** line at the next item.
3. **`brief`** — the full brief ([templates/brief.md](templates/brief.md)) is produced,
   the closing one for the session.
4. **`claims-released`** — every **coordination** claim this session holds is released:
   the epic-level claim, or the standalone-issue-level claim where the session worked a
   standalone issue ([claims.md](claims.md) § Releasing). The informational per-issue
   dispatch stamps are **not** touched — they are never cleared, at handoff or at merge
   (§ Two roles for `Claimed by`, and § Releasing's exemption); a closed issue keeps its
   stamp as the ownership ledger.
5. **`heartbeat-off`** — the heartbeat cron is deleted. Non-skippable, unlike every
   other item in this checklist: the heartbeat is armed unconditionally at startup
   (§ Heartbeat, above), so there is never a state in which it was not armed and this
   item has nothing to undo.
6. **`handoff`** — the chat-only handoff ([templates/handoff.md](templates/handoff.md))
   is written, and memory is updated.

Close with `close-complete`.
