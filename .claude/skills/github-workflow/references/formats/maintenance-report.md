# Maintenance report format

One `maintenance` event in the session log per pass. The block below is a shape sketch,
not literal JSON — `N` stands for a count, `x` for a non-integral measurement (a load
average, a percentage, a gigabyte figure), `…` elides a value or a repeated element, and
`a|b|c` marks an alternation of literal strings, so the fence carries no `json` tag and
`jq -e .` is not expected to parse it:

```
{"ts":"…","event":"maintenance","claim":"…","trigger":"start|resume|wave|serial-3|morning-cleanup",
 "triage":{"drained":N,"ready":N,"backlog":N,"duplicates":N,"folded":N,
   "batches":[{"unit":"…","members":[N,…],"riders":[N,…],"dispatchable":true},…]},
 "host":{"load":x,"mem_free_pct":x,"disk_free_gb":x,"disk_delta_gb":x,"leftover_procs":N},
 "cleanup":{"containers":N,"images":N,"volumes":N,"networks":N,"worktrees":N,"files":N},
 "rules":{"main_checkout_dirty":false,"files_outside_allowed":N,"evidence_in_tree":N,"subagent_violations":N},
 "state":{"open_off_board":N,"stale_claims":N,"epics_under_2":N,"epics_over_cap":N,"closed_parent_open_child":N,"pending_live":N,"milestone_rewritten":false,
   "missing_board_items":[N,…],"readded":N,"homed_by_others":[N,…],
   "log_consistency":{"missing_report":N,"missing_dispatch":N}},
 "actions":["…"],
 "board_audit":{"heuristic":"…","target_kind":"milestone|epic|null","missing_count":N,"missing_sample":[N,…],
   "homed_count":N,"homed_events":N,
   "homed_sample":[{"issue":N,"event":"milestoned|labeled","actor":"…","created_at":"…"},…],
   "homed_walk_truncated":false,
   "raw_log":"<scratch>/board-audit-<ts>.json"}}
```

`triage.batches` is the grouping [maintenance.md](../maintenance.md) § 1's closing
Batching step settled on this pass: one object per unit the pass grouped, carrying the
issue numbers of its **open** `deferred` members, the issue numbers of any **riders**
(#802) folded into it, and whether it met the dispatch threshold (or the end-of-scope
flush). An empty array is correct when no `deferred` item is open.

`members` and `riders` are both arrays of issue numbers, and the split between them is
load-bearing, not cosmetic. `members` holds open issues only — that is what the key has
always meant and what every consumer reads it as. `riders` holds parked issues, which
are **closed**: `batch-deferred.sh` folds a parked issue into an already-dispatchable
unit as a rider, and
[orchestration.md](../orchestration.md)'s pick step must reopen and re-add each one with
`home-deferred.sh --readd --status Ready` *before* the batch is dispatched. An
orchestrator that could not tell the two apart would dispatch a rider unreopened and its
batch PR would then try to close an already-closed issue. `riders` is **always present**
and is `[]` for a unit that placed none, so a consumer never has to distinguish "no
riders" from "an older producer that did not emit the key" — `batch-deferred.sh
--markdown` emits both keys on every batch object.

Both `state.*` arrays are derived from the saved `board-audit.sh` JSON output, whose own
`missing_board_items[]` and `homed_by_others[]` are arrays of objects, not of numbers —
the report carries issue numbers, so each needs a stated derivation:

```
jq '[.missing_board_items[].number]' "$RAW_LOG"      # -> state.missing_board_items
jq '[.homed_by_others[].issue] | unique' "$RAW_LOG"  # -> state.homed_by_others
```

`state.missing_board_items` lists the issue numbers `board-audit.sh` reported as off the
board, after `home-deferred.sh --readd` has re-added each one; `state.readded` is how many
that was (0 when the list came up empty). `state.log_consistency` is the `{missing_report,missing_dispatch}` count pair `log-consistency-check.sh --json`'s own `missing_report_count`/`missing_dispatch_count` keys report for this pass's session log — see [maintenance.md](../maintenance.md) § 5's session-log-consistency bullet for what each counts and what a non-zero value means to do next.

`state.homed_by_others` lists the *distinct*
issue numbers its heuristic reports as homed into this session's target by another
orchestrator since the previous pass — the script emits one object per timeline event, so
several events on one issue collapse to a single entry, hence the `unique` above. It is
otherwise unfiltered, because the heuristic cannot attribute an event to a session and
over-reports (it also catches this run's own homings); the list is for a human or
orchestrator glance, not blind action.

`board_audit` is a bounded summary derived from the same saved JSON the `state.*`
checks read. `target_kind` and `homed_walk_truncated` are pass-throughs of the script's
own same-named keys. `missing_count` is the length of `state.missing_board_items`.
`homed_count` is the number of distinct issues (the `unique` list) and `homed_events`
the raw per-event count, so `homed_events` ≥ `homed_count`. `missing_sample` is the
first 5 issue numbers in the script's report order; `homed_sample` is the 5
**lowest-numbered** distinct issues (`unique` sorts ascending), each as that issue's
earliest `{issue,event,actor,created_at}`, which relies on the script sorting
`homed_by_others` by `created_at`. `raw_log` is the `<scratch>/board-audit-<ts>.json`
path [maintenance.md](../maintenance.md) § 5 saves the full output to — session-local,
so it resolves for this session's readers only. One `jq` call over that saved output
builds the whole key:

```
jq --arg log "$RAW_LOG" '([.homed_by_others[].issue]|unique) as $homed | {heuristic, target_kind,
  missing_count:(.missing_board_items|length), missing_sample:[.missing_board_items[0:5][].number],
  homed_count:($homed|length), homed_events:(.homed_by_others|length),
  homed_sample:[$homed[0:5][] as $i | first(.homed_by_others[]|select(.issue==$i))|{issue,event,actor,created_at}],
  homed_walk_truncated,
  raw_log:$log}' "$RAW_LOG"
```

[maintenance.md](../maintenance.md) § 5's rule that the pass runs one GET-only
`board-audit.sh` invocation, saves its raw JSON to scratch and derives the report from
it is met by `state.missing_board_items[]` and `state.homed_by_others[]` together with
this bounded summary — never by a verbatim paste of the script's `--markdown` block.
