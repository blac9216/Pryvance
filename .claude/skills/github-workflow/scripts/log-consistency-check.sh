#!/usr/bin/env bash
# log-consistency-check.sh — the maintenance pass's cheap cross-check against
# an under-logged `dispatch`/`report` pair (issue #681's third Proposed
# Change). READ-ONLY: a pure `jq` pass over a local session-log file. No `gh`
# call, no network — see the file-vs-file exemption note below.
#
# Usage: log-consistency-check.sh <session.jsonl> [--json]
#
# This is a MAINTENANCE-pass check, not the heartbeat's stall-check.sh:
# maintenance.md says the heartbeat does no maintenance, so the two stay
# separate scripts each dispatched from its own place, per the issue's Risks
# section.
#
# Two reports, keyed by role+agent — deliberately NOT by `pr` — with each
# pairing also required to respect logged order, so a pairing failure names
# exactly which dispatch/report it is about, not just a bare count:
#   missing_report    a `dispatch` (role, agent) with no LATER `report`
#                      (by `ts`) from that same agent AND no `merge`
#                      matching either the dispatch's `issue` or its `pr`.
#                      This is the exact gap #681 was filed over: this
#                      session logged `dispatch` for implementers only, and
#                      34 reviewer / 12 fix / 6 merge-verifier dispatches
#                      went unmatched with nothing to notice.
#   missing_dispatch   a `report` (role, agent) with no EARLIER `dispatch`
#                      (by `ts`) for that same agent — a report that was
#                      logged for work nothing on record ever started.
#
# Why role+agent, not role+pr+agent: formats/session-log.md's own documented
# example of an implementer `dispatch` carries no `pr` key at all — the PR
# does not exist yet at dispatch time — while the matching `report`, logged
# once the implementer has opened the PR, does. Requiring `pr` equality
# treats "absent" as a distinct value from whatever `pr` the report later
# carries, so a correctly logged implementer pair fails both directions at
# once: reported as `missing_report` (the dispatch's `pr` is null, no report
# has a null `pr`) AND as `missing_dispatch` (the report's `pr` is a real
# number, no dispatch has that number). `role`+`agent` is the right key
# regardless of whether `agent` values ever repeat: `formats/session-log.md`
# defines `report.role` as "the same enum as `dispatch.role`" and its
# `report`/`dispatch` rows both list `agent` as the identity of the
# dispatched worker being reported on — a `report` names the role+agent of
# the `dispatch` it answers, which is what this key matches on, independent
# of `pr`. `agent` values DO repeat: a relay resumes an already-dispatched
# agent under its own original agent id (see the `relay` exclusion below),
# so the same (role, agent) can legitimately open a second leg. Ordering by
# `ts` is what tells the two legs apart — see the missing_report/
# missing_dispatch definitions above and the `epoch` comparisons below —
# rather than existence alone, which would let an earlier leg's `report`
# stand in for a later leg's and mask that later leg going unreported.
#
# The `ts` comparisons in both directions are NON-STRICT (`>=` / `<=`), not
# `>`/`<`: a `dispatch` and its `report` sharing one whole-second `ts` are a
# real, legitimate pair, not a misordering. maintenance.md's own remedy for
# a missing event is to hand-log it, and the most direct way to hand-log a
# missing dispatch is to backfill it with its report's own timestamp -- the
# two then read as EQUAL, not report-after-dispatch. session-log.md's own
# `ts` field is whole-second resolution, so exact ties are routine, not an
# edge case (round-2 G2's session had several backfilled events sharing one
# timestamp). PR #696 round-2 G2: with the strict comparison this replaces,
# such a pair was reported as BOTH a false `missing_report` (no report has a
# LATER ts) AND a false `missing_dispatch` (no dispatch has an EARLIER ts) --
# F1's shape through a different door. Equal timestamps pair in BOTH
# directions here (a shared ts satisfies the dispatch's search for a report
# and the report's search for a dispatch); this is deliberately an
# existence check per role+agent, not a strict 1:1 matching, so a single
# event at a shared ts can in principle close more than one counterpart
# that shares that same key+ts -- accepted here because this script's job is
# flagging gaps, not accounting for exact multiplicity. Genuine ordering
# (dispatch strictly before its report, or vice versa) still works exactly
# as before; only the equal case changes from "neither pairs" to "both
# pair".
#
# The merge exclusion on `missing_report` matches on `issue` OR `pr`,
# whichever the dispatch actually carries: an implementer dispatch has
# `issue` but may lack `pr`; every other role's dispatch has both. Checking
# both means neither field's absence on one side blinds the check.
#
# A `relay` leg intentionally does NOT stand in for a `dispatch` here: a
# relay resumes an already-dispatched agent, so pairing dispatch<->report
# stays keyed off the original `dispatch` regardless of how many relay legs
# came between them.
#
# Issue #725: a `stall` event carrying `"terminal": true` AND a non-empty
# `reason` also closes a `missing_report` gap — the orchestrator's
# administrative record that this dispatch will never get a `report`
# because the agent was declared dead and will not be resumed. Matched the
# same way a `report` is: same `agent`, at or after the dispatch's own `ts`
# (`stall` carries no `role`, so matching is by `agent` alone). Without
# this, an abandoned dispatch is a `missing_report` forever, even though
# `stall-check.sh` already stops reporting the same leg once its terminal
# `stall` is logged (see that script's own header comment) — this check
# has the identical exposure on the same event, just a different symptom
# (`missing_report` instead of a stall report that never clears).
#
# Round 1 F1/F2: `terminal` is compared by IDENTITY (`== true`), never `jq`
# truthiness — a hand-written `"terminal": "false"` (or `"no"`, `0`, `""`,
# `[]`) must NOT close the gap, since this field is written by hand at the
# moment an agent is declared dead. `reason` is REQUIRED by session-log.md
# whenever `terminal` is true; a terminal `stall` with no non-empty string
# `reason` does not close the gap either, and is named on stderr the same
# way a malformed record is.
#
# Issue #719: one schema-invalid `ts` used to abort this whole pass with a
# raw `jq` error and exit 5. A record failing `ts_ok` (not an object, no
# `ts`, `ts` not a string, or unparseable) is set aside into a `malformed`
# bucket, named on stderr, and excluded from the rest of the pass, which
# runs over every remaining record exactly as before — the same fix as
# stall-check.sh, so the two scripts agree.
#
# Issue #743: `malformed` is not one shape. A `ts` that is present, a
# string, and schema-shaped ISO-8601 at MINUTE precision (the exact form
# the pre-#743 `stamp-claim.sh` wrote, and what every archived pre-#743
# session log still contains) is neither "missing" nor "unparseable" — it
# is a real, well-formed timestamp the schema simply does not accept at
# that precision. The three outcomes — missing, unsupported precision,
# unparseable — are named separately on stderr, while all three remain
# excluded from `$good` exactly as `malformed` was before. Same fix as
# stall-check.sh, so the two scripts still agree.
#
# UNMOCKED-CONTEXT: not applicable. This script issues no `gh` invocation at
# all (grep the file: none) — it is a pure local-file `jq` pass, the same
# exemption tests/README.md's Shape section documents for
# test_agent_rules_drift.sh and test_session_log_slugs.sh. There is no mock
# to bypass and no tripwire to wire up.
set -euo pipefail

die(){ echo "log-consistency-check: $*" >&2; exit 1; }
argerr(){ echo "log-consistency-check: $*" >&2; exit 2; }

print_help(){
  cat <<'EOF'
usage: log-consistency-check.sh <session.jsonl> [--json]

Predicate: report missing_report for a dispatch (role, agent) with no
later report from that same agent, no merge matching its issue or pr, and
no stall event for that agent carrying "terminal": true (compared by
identity, never truthiness) AND a non-empty "reason" (an administrative
close, with a required reason, written when the orchestrator declares the
agent dead and will never resume or report on it — see
references/overnight-and-status.md and references/formats/session-log.md);
report missing_dispatch for a report (role, agent) with no earlier
dispatch for that same agent. A terminal stall missing its reason does NOT
close the gap and is named on stderr. Matching is by role+agent (never
role+pr+agent — an implementer dispatch often has no pr yet), ordered by
ts with non-strict comparisons so a dispatch and its report sharing one
whole-second ts still pair. A record whose "ts" is missing, unparseable,
or at unsupported precision (present but not exactly
formats/session-log.md's required second-precision form) is named on
stderr with which of those three it is and excluded from the pass rather
than aborting it. See this script's own header comment for the full
predicate and its failure-mode history.
EOF
}

json=0
args=()
for a in "$@"; do
  case "$a" in
    --json) json=1 ;;
    -h|--help) print_help; exit 0 ;;
    *) args+=("$a") ;;
  esac
done
[ "${#args[@]}" -eq 1 ] || argerr "usage: log-consistency-check.sh <session.jsonl> [--json]"

log="${args[0]}"
[ -r "$log" ] || die "cannot read session log: $log"

combined="$(
  jq -cs '
    def epoch: (.ts | fromdateiso8601);
    # A record is ts_ok when its "ts" is present, a string, and iso8601-
    # parseable. try/catch also absorbs any other malformed shape (a
    # non-object line, etc.) rather than letting it abort the whole pass —
    # issue #719. has_ts / ts_minute_precision split a rejected record into
    # three distinct outcomes (issue #743) — see the header comment above.
    def has_ts: (type == "object") and has("ts") and (.ts != null);
    def ts_string: has_ts and ((.ts | type) == "string");
    def ts_minute_precision: ts_string
      and (.ts | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}Z$"));
    def ts_ok: try (has_ts and ts_string and ((.ts | fromdateiso8601) != null)) catch false;
    # Issue #725 round 1 F2: session-log.md requires "reason" whenever
    # "terminal" is true. has_reason is a strict type/non-empty check so a
    # bare {"terminal": true} cannot close the gap silently.
    def has_reason: (.reason? != null) and ((.reason | type) == "string") and (.reason != "");

    (map(select(ts_ok | not))) as $rejected
    | ($rejected | map(select(has_ts | not))) as $missing_ts
    | ($rejected | map(select(has_ts and ts_minute_precision))) as $precision_ts
    | ($rejected | map(select(has_ts and (ts_minute_precision | not)))) as $unparseable_ts
    | ($missing_ts + $precision_ts + $unparseable_ts) as $malformed
    | (map(select(ts_ok))) as $good

    # Issue #725 round 1 F2: a terminal stall with no reason must NOT close
    # the gap — named on stderr below, the same as a malformed record.
    | ($good | [ .[] | select(.event == "stall" and .terminal == true and (has_reason | not)) ]) as $bad_terminal

    | ($good | [ .[] | select(.event == "merge") | .issue ] | unique) as $merged_issues
    | ($good | [ .[] | select(.event == "merge") | .pr ] | unique) as $merged_prs
    | ($good | [ .[] | select(.event == "dispatch") ]) as $dispatches
    | ($good | [ .[] | select(.event == "report") ]) as $reports
    | ($good | [ .[] | select(.event == "stall" and .terminal == true and has_reason) ]) as $terminal_stalls
    | {
        missing_report: [
          $dispatches[] as $d
          | select(
              ([ $reports[] | select(.role == $d.role and .agent == $d.agent and (epoch >= ($d|epoch))) ] | length) == 0
              and ([ $terminal_stalls[] | select(.agent == $d.agent and (epoch >= ($d|epoch))) ] | length) == 0
              and (($d.issue != null and (($merged_issues | index($d.issue)) != null))
                   or ($d.pr != null and (($merged_prs | index($d.pr)) != null))
                   | not)
            )
          | {role: $d.role, pr: $d.pr, agent: $d.agent, issue: $d.issue}
        ],
        missing_dispatch: [
          $reports[] as $r
          | select(
              [ $dispatches[] | select(.role == $r.role and .agent == $r.agent and (epoch <= ($r|epoch))) ] | length == 0
            )
          | {role: $r.role, pr: $r.pr, agent: $r.agent, issue: $r.issue}
        ]
      } as $result
    | {result: $result, malformed: $malformed, missing_ts: $missing_ts, precision_ts: $precision_ts, unparseable_ts: $unparseable_ts, bad_terminal: $bad_terminal}
  ' "$log"
)"

result="$(printf '%s' "$combined" | jq -c '.result')"
malformed="$(printf '%s' "$combined" | jq -c '.malformed')"
mcount="$(printf '%s' "$malformed" | jq -r 'length')"
missing_ts="$(printf '%s' "$combined" | jq -c '.missing_ts')"
precision_ts="$(printf '%s' "$combined" | jq -c '.precision_ts')"
unparseable_ts="$(printf '%s' "$combined" | jq -c '.unparseable_ts')"
bad_terminal="$(printf '%s' "$combined" | jq -c '.bad_terminal')"
bcount="$(printf '%s' "$bad_terminal" | jq -r 'length')"

# Three distinct diagnostics (issue #743) — see the header comment above.
if [ "$(printf '%s' "$missing_ts" | jq -r 'length')" -gt 0 ]; then
  printf '%s\n' "$missing_ts" | jq -c '.[]' | while IFS= read -r rec; do
    echo "log-consistency-check: malformed record (missing ts), skipping: $rec" >&2
  done
fi
if [ "$(printf '%s' "$precision_ts" | jq -r 'length')" -gt 0 ]; then
  printf '%s\n' "$precision_ts" | jq -c '.[]' | while IFS= read -r rec; do
    echo "log-consistency-check: ts at unsupported precision (minute, not seconds — see formats/session-log.md), skipping: $rec" >&2
  done
fi
if [ "$(printf '%s' "$unparseable_ts" | jq -r 'length')" -gt 0 ]; then
  printf '%s\n' "$unparseable_ts" | jq -c '.[]' | while IFS= read -r rec; do
    echo "log-consistency-check: malformed record (unparseable ts), skipping: $rec" >&2
  done
fi

if [ "$bcount" -gt 0 ]; then
  printf '%s\n' "$bad_terminal" | jq -c '.[]' | while IFS= read -r rec; do
    echo "log-consistency-check: terminal stall with no reason, gap NOT closed: $rec" >&2
  done
fi

mr_count="$(printf '%s' "$result" | jq -r '.missing_report | length')"
md_count="$(printf '%s' "$result" | jq -r '.missing_dispatch | length')"

if [ "$json" -eq 1 ]; then
  printf '%s\n' "$result" | jq -c --argjson mcount "$mcount" --argjson bcount "$bcount" '{missing_report_count: (.missing_report|length), missing_dispatch_count: (.missing_dispatch|length), malformed: $mcount, bad_terminal: $bcount} + .'
else
  if [ "$mr_count" -eq 0 ] && [ "$md_count" -eq 0 ]; then
    if [ "$mcount" -gt 0 ]; then
      echo "consistent: every dispatch has a report or a merge; every report has a dispatch (${mcount} malformed record(s) skipped — see stderr)"
    else
      echo "consistent: every dispatch has a report or a merge; every report has a dispatch"
    fi
  else
    if [ "$mr_count" -gt 0 ]; then
      echo "dispatch with no report and no merge:"
      printf '%s\n' "$result" | jq -r '.missing_report[] | "  role=\(.role) pr=\(.pr) agent=\(.agent) issue=\(.issue // "-")"'
    fi
    if [ "$md_count" -gt 0 ]; then
      echo "report with no matching dispatch:"
      printf '%s\n' "$result" | jq -r '.missing_dispatch[] | "  role=\(.role) pr=\(.pr) agent=\(.agent) issue=\(.issue // "-")"'
    fi
    if [ "$mcount" -gt 0 ]; then
      echo "(${mcount} malformed record(s) skipped — see stderr)"
    fi
  fi
fi

[ "$mr_count" -eq 0 ] && [ "$md_count" -eq 0 ] || exit 1
exit 0
