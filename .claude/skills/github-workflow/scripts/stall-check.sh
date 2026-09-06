#!/usr/bin/env bash
# stall-check.sh — the heartbeat's 60-minute-silence check, as a script with a
# stated predicate, instead of a one-sentence description every session
# re-derives for itself. READ-ONLY: a pure `jq` pass over a local session-log
# file. No `gh` call, no network — see the file-vs-file exemption note below.
#
# Usage: stall-check.sh <idle-minutes> <session.jsonl> [--json]
#
# Predicate (issue #681): an agent is IN FLIGHT when its most recently logged
# event is one that leaves its current leg of work OPEN — a `dispatch`; a
# `relay` naming it as the party being resumed (`relay.agent` is the resumed
# agent's own id; see formats/session-log.md's `relay` row); a `stall` (the
# heartbeat's own note that this agent was found idle — logging that fact
# must not stop the next heartbeat run from seeing the same agent, still
# idle, again); or a `resume` (work picked back up after a stall — a
# leg-OPENING event, the same as a fresh `dispatch` for this purpose, never a
# closer) — and that leg is not yet CLOSED. A leg is closed by any one of:
#   - a later `report` event from that same agent (the ordinary case: the
#     "last event per agent" grouping below already makes this automatic,
#     since a `report` newer than the `dispatch`/`relay`/`stall`/`resume`
#     becomes that agent's last event and is filtered out by the event-type
#     check below);
#   - for a relay's IMPLEMENTER leg only (`relay.role == "implementer"`): the
#     existence of the matching REVIEWER leg for the same `pr`+`round`
#     (`relay.role == "reviewer"`). session-log.md files the two legs under
#     different agent ids (leg 1 carries the implementer's, leg 2 the
#     reviewer's), so a per-agent scan can never see leg 1 close on its own
#     agent id — the reviewer leg's mere presence is the only evidence leg 1
#     ever finished. This is deliberately one-directional: the reviewer leg
#     is NOT closed by anything symmetric here, only by its own later
#     `report`/`review` or by the merge case below — a reviewer leg with no
#     further event after it is a real stall and must still be reported.
#   - a `merge` event matching that leg's own `issue` OR `pr` (its work is
#     moot once its PR has merged, regardless of what did or didn't get
#     logged in between). The leg's issue/pr is read off the leg-opening
#     `dispatch`/`relay` event, not necessarily the agent's literal last
#     event: an implementer `dispatch` carries `issue` but often no `pr` yet
#     (the PR doesn't exist at dispatch time — see
#     formats/session-log.md's own example), so pr-only matching would leave
#     such a leg unclosable by any merge no matter how long afterward it
#     lands; matching on issue-or-pr means whichever field the leg-opening
#     event actually carries is enough.
#   - a `stall` event carrying `"terminal": true` AND a non-empty `reason`
#     (issue #725, round 1 F1/F2): the orchestrator's own administrative
#     close, written when it declares an agent dead and will never resume or
#     report on it — see overnight-and-status.md's dead-agent handling.
#     `terminal` is compared for IDENTITY (`== true`), never `jq` truthiness
#     (`"false"`, `"no"`, `0`, `""`, and `[]` are all truthy to `jq` and must
#     NOT close a leg — this is hand-written input at the moment an agent is
#     declared dead, so a stringified flag is a realistic mistake, not a
#     contrived one). `reason` is REQUIRED by session-log.md whenever
#     `terminal` is true; a terminal `stall` with no non-empty string
#     `reason` does NOT close the leg either — it is named on stderr the
#     same way a malformed record is, so a mis-written administrative close
#     fails loudly rather than silently dropping the agent from view. This
#     is the ONLY new closer this predicate needed: the leg's most recent
#     event is still a `stall`, so the ordinary "last event per agent"
#     grouping already sees it; a well-formed terminal stall simply removes
#     it from the leg-OPENING set above instead of leaving it open until a
#     `merge` on the (possibly never-merging) PR eventually arrives. A
#     non-terminal `stall` is unaffected and still keeps the agent visible
#     exactly as before.
#
# `idle_min` is measured from the most recent event that shows the AGENT
# itself acted — `dispatch`, `relay`, `resume`, or `report` — never from a
# `stall`. A `stall` is the heartbeat's own bookkeeping about the agent, not
# evidence the agent did anything; if the reported figure reset to
# time-since-last-stall every time the heartbeat wrote one, an agent flagged
# repeatedly would read as freshly idle between notices instead of the real
# duration of its silence. `stall` still counts as a leg-OPENING event above
# (round 1's fix for failure mode 4 below still holds: logging a `stall`
# must not make the agent disappear from the report), it just is not what
# the clock measures from.
#
# PR #696 round-2 G1: an agent whose LOGGED HISTORY is nothing but `stall`
# events (every heartbeat pass found it idle and none of them, nor anything
# else, ever recorded a genuine action for it) has no non-`stall` event to
# measure `idle_min` from -- `acted` above is `null` for it, and
# `($now - (null | epoch))` aborts the whole `jq` pass with exit 5, taking
# the heartbeat dark for every OTHER agent in the same run too, not just
# this one. This is reachable, not academic: the heartbeat itself writes
# `stall` for an agent it judges unsafe to resume, and issue #681's own
# premise is that whole roles' `dispatch` events go unlogged -- an agent
# known to the log only through heartbeat-written `stall`s sits at the
# intersection of both. The fix: when no non-`stall` event exists, `acted`
# falls back to the EARLIEST event on record for that agent (necessarily a
# `stall`, by construction of this case) rather than `null`. `idle_min` for
# such an agent then reads as time since the FIRST stall we ever logged for
# it -- a stated lower bound on how long it has actually been silent (we
# have no earlier evidence of real activity to measure from), not a claim
# about when it truly went idle. This still reports the agent -- the worst
# outcome here is a silent abort that hides every agent in the run, not an
# approximate number for one of them.
#
# This predicate is the fix for four failure modes discovery-tested against
# a real >400-line session log (2026-09-04 overnight run):
#   1. blindness to any role that never gets a `dispatch` event logged for it
#      — not a defect of this predicate; a separate consistency check
#      (log-consistency-check.sh) catches an under-logged dispatch instead.
#   2. "no logged event" as the closing test, which misses a stall in a
#      RESUMED agent's second leg (it already has one `report`, so a naive
#      "has no report at all" filter clears it forever) — fixed by keying off
#      "most recent event", not "has any report".
#   3. a relay's two legs filed under different agent ids, which a per-agent
#      scan can never pair — fixed by the pr+round pairing above.
#   4. logging the very `stall` event this predicate's own consumer
#      (overnight-and-status.md's heartbeat) is instructed to write when it
#      finds an agent idle removes that agent from view forever after,
#      because only `dispatch`/`relay` counted as leg-opening events — fixed
#      by counting `stall`/`resume` as leg-opening too, so an agent that
#      stays idle keeps showing up until a `resume`, `report`, or `merge`
#      actually closes it, with `idle_min` measured from the agent's last
#      real action per the paragraph above (never reset by the `stall` that
#      keeps it visible).
#
# Issue #719: one schema-invalid `ts` — absent, unparseable, or a `+00:00`
# offset instead of the required `Z` (formats/session-log.md L6) — used to
# abort the ENTIRE `jq` pass with a raw `strptime`/`fromdateiso8601` error
# and exit 5, printing nothing at all: every OTHER agent in the run went
# dark too, not just the one malformed line. A record failing `ts_ok` (not
# an object, no `ts`, `ts` not a string, or `ts` not iso8601-parseable) is
# now set aside into a `malformed` bucket instead of being fed to `epoch`:
# it is named on stderr (so the bad line is visible, not silently dropped)
# and excluded from the rest of this pass, which runs over every remaining
# record exactly as before. A check that fails closed on one bad line is
# worse than one that names the bad line and keeps going.
#
# Issue #743: `malformed` is not one shape. A `ts` that is present, a
# string, and schema-shaped ISO-8601 at MINUTE precision (the exact form
# the pre-#743 `stamp-claim.sh` wrote, and what every archived pre-#743
# session log still contains) is neither "missing" nor "unparseable" — it
# is a real, well-formed timestamp the schema simply does not accept at
# that precision. Reporting it as "malformed (unparseable/missing ts)" was
# itself a bug: it pointed nowhere near the actual defect (a writer using
# `%Y-%m-%dT%H:%MZ` instead of `%FT%TZ`). The three outcomes are now split
# and named separately on stderr — missing, unsupported precision,
# unparseable — while all three remain excluded from `$good` exactly as
# `malformed` was before.
#
# UNMOCKED-CONTEXT: not applicable. This script issues no `gh` invocation at
# all (grep the file: none) — it is a pure local-file `jq` pass, the same
# exemption tests/README.md's Shape section documents for
# test_agent_rules_drift.sh and test_session_log_slugs.sh. There is no mock
# to bypass and no tripwire to wire up.
set -euo pipefail

die(){ echo "stall-check: $*" >&2; exit 1; }
argerr(){ echo "stall-check: $*" >&2; exit 2; }

print_help(){
  cat <<'EOF'
usage: stall-check.sh <idle-minutes> <session.jsonl> [--json]

Predicate: report an agent whose most recently logged event leaves its
current leg of work OPEN — a dispatch; a relay naming it as the party being
resumed; a stall; or a resume — and whose idle time (minutes since its most
recent dispatch/relay/resume/report, never a stall) exceeds <idle-minutes>.
A leg is CLOSED by a later report from that agent, by the matching
reviewer leg for the same pr+round (implementer leg only), by a merge
event matching the leg's issue or pr, or by a stall event carrying
"terminal": true (compared by identity, never truthiness) AND a non-empty
"reason" (an administrative close, with a required reason, written when
the orchestrator declares the agent dead and will never resume or report
on it — see references/overnight-and-status.md and
references/formats/session-log.md). A terminal stall missing its reason
does NOT close the leg and is named on stderr. A record whose "ts" is
missing, unparseable, or at unsupported precision (present but not exactly
formats/session-log.md's required second-precision form) is named on
stderr with which of those three it is and excluded from the pass rather
than aborting it. See this script's own header comment for the full
predicate, its failure-mode history, and citations.
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
[ "${#args[@]}" -eq 2 ] || argerr "usage: stall-check.sh <idle-minutes> <session.jsonl> [--json]"

lim="${args[0]}"
log="${args[1]}"

case "$lim" in
  ''|*[!0-9]*) argerr "idle-minutes must be a non-negative integer, got: $lim" ;;
esac
[ -r "$log" ] || die "cannot read session log: $log"

now="$(date -u +%s)"

combined="$(
  jq -cs --argjson now "$now" --argjson lim "$lim" '
    def epoch: (.ts | fromdateiso8601);
    # formats/session-log.md (issue #743) states the sole accepted "ts" form
    # exactly: YYYY-MM-DDTHH:MM:SSZ (second precision). has_ts / ts_string /
    # ts_ok / ts_minute_precision below split a rejected record into three
    # DISTINCT, mutually exclusive outcomes instead of one "malformed"
    # bucket, so the diagnostic printed for each says why it was rejected:
    #   - missing: no "ts" key, or "ts" is null.
    #   - unsupported precision: "ts" is a schema-shaped ISO-8601 string at
    #     minute precision (e.g. "2026-09-04T16:52Z") — the exact shape the
    #     pre-#743 stamp-claim.sh wrote and every archived pre-#743 log
    #     still contains. Present, parseable by eye, but not the form this
    #     schema requires.
    #   - unparseable: "ts" is present and a string but neither ts_ok nor
    #     minute-precision-shaped (not a string at all, wrong offset, junk
    #     text, etc.).
    # try/catch on ts_ok still absorbs any other malformed shape (a
    # non-object line, etc.) rather than letting it abort the whole pass —
    # issue #719.
    def has_ts: (type == "object") and has("ts") and (.ts != null);
    def ts_string: has_ts and ((.ts | type) == "string");
    def ts_minute_precision: ts_string
      and (.ts | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}Z$"));
    def ts_ok: try (has_ts and ts_string and ((.ts | fromdateiso8601) != null)) catch false;
    # Issue #725 round 1 F2: session-log.md requires "reason" whenever
    # "terminal" is true. has_reason is a strict type/non-empty check so a
    # bare {"terminal": true} cannot close a leg silently.
    def has_reason: (.reason? != null) and ((.reason | type) == "string") and (.reason != "");

    (map(select(ts_ok | not))) as $rejected
    | ($rejected | map(select(has_ts | not))) as $missing_ts
    | ($rejected | map(select(has_ts and ts_minute_precision))) as $precision_ts
    | ($rejected | map(select(has_ts and (ts_minute_precision | not)))) as $unparseable_ts
    | ($missing_ts + $precision_ts + $unparseable_ts) as $malformed
    | (map(select(ts_ok))) as $good

    # Issue #725 round 1 F2: a terminal stall with no reason must NOT close
    # the leg — named on stderr below, the same as a malformed record.
    | ($good | [ .[] | select(.event == "stall" and .terminal == true and (has_reason | not)) ]) as $bad_terminal

    | ($good | [ .[] | select(.event == "merge") | .issue ] | unique) as $merged_issues
    | ($good | [ .[] | select(.event == "merge") | .pr ] | unique) as $merged_prs
    | ($good | [ .[] | select(.event == "relay" and .role == "reviewer")
        | "\(.pr)/\(.round)" ] | unique) as $reviewer_legs_seen
    | (
        $good
        | [ .[] | select(.agent != null) ]
        | group_by(.agent)
        | map({
            agent: .[0].agent,
            last: (sort_by(epoch) | last),
            leg_start: (sort_by(epoch) | map(select(.event == "dispatch" or .event == "relay")) | last),
            acted: ((sort_by(epoch) | map(select(.event != "stall")) | last) // (sort_by(epoch) | first))
          })
        | map(select(
            .last.event == "dispatch" or .last.event == "relay"
            or .last.event == "stall" or .last.event == "resume"
          ))
        | map(select(
            (.last.event != "stall")
            or (.last.terminal != true)
            or ((.last | has_reason) | not)
          ))
        | map(select(
            ((.leg_start.issue // null) as $i | $i != null and (($merged_issues | index($i)) != null))
            or ((.leg_start.pr // null) as $p | $p != null and (($merged_prs | index($p)) != null))
            | not
          ))
        | map(select(
            .last.event != "relay"
            or .last.role != "implementer"
            or (("\(.last.pr)/\(.last.round)") as $k | $reviewer_legs_seen | index($k)) == null
          ))
        | map(. + {idle_min: (($now - (.acted | epoch)) / 60 | floor)})
        | map(select(.idle_min > $lim))
        | sort_by(-.idle_min)
      ) as $result
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

# Three distinct diagnostics (issue #743) instead of one "malformed
# (unparseable/missing ts)" message: a record whose ts is present, a
# string, and schema-shaped ISO-8601 at minute precision is neither missing
# nor unparseable — it is rejected for precision, and saying so points at
# the actual fix (a writer stuck on %Y-%m-%dT%H:%MZ instead of %FT%TZ).
if [ "$(printf '%s' "$missing_ts" | jq -r 'length')" -gt 0 ]; then
  printf '%s\n' "$missing_ts" | jq -c '.[]' | while IFS= read -r rec; do
    echo "stall-check: malformed record (missing ts), skipping: $rec" >&2
  done
fi
if [ "$(printf '%s' "$precision_ts" | jq -r 'length')" -gt 0 ]; then
  printf '%s\n' "$precision_ts" | jq -c '.[]' | while IFS= read -r rec; do
    echo "stall-check: ts at unsupported precision (minute, not seconds — see formats/session-log.md), skipping: $rec" >&2
  done
fi
if [ "$(printf '%s' "$unparseable_ts" | jq -r 'length')" -gt 0 ]; then
  printf '%s\n' "$unparseable_ts" | jq -c '.[]' | while IFS= read -r rec; do
    echo "stall-check: malformed record (unparseable ts), skipping: $rec" >&2
  done
fi

if [ "$bcount" -gt 0 ]; then
  printf '%s\n' "$bad_terminal" | jq -c '.[]' | while IFS= read -r rec; do
    echo "stall-check: terminal stall with no reason, leg NOT closed: $rec" >&2
  done
fi

count="$(printf '%s' "$result" | jq -r 'length')"

if [ "$json" -eq 1 ]; then
  printf '%s\n' "$result" | jq -c --argjson lim "$lim" --argjson mcount "$mcount" --argjson bcount "$bcount" '{idle_over_min: $lim, count: length, malformed: $mcount, bad_terminal: $bcount, agents: .}'
else
  if [ "$count" -eq 0 ]; then
    if [ "$mcount" -gt 0 ]; then
      echo "none idle over ${lim}m (${mcount} malformed record(s) skipped — see stderr)"
    else
      echo "none idle over ${lim}m"
    fi
  else
    printf '%s\n' "$result" | jq -r '.[] | "  \(.agent) \(.last.event) role=\(.last.role // "-") pr=\(.last.pr // "-") round=\(.last.round // "-") idle=\(.idle_min)m"'
    if [ "$mcount" -gt 0 ]; then
      echo "(${mcount} malformed record(s) skipped — see stderr)"
    fi
  fi
fi

[ "$count" -eq 0 ] || exit 1
exit 0
