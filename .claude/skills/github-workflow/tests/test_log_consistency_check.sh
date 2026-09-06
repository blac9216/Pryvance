#!/usr/bin/env bash
# test_log_consistency_check.sh — fixture-driven regression test for
# log-consistency-check.sh (issue #681's fourth Acceptance Criterion: "The
# maintenance pass reports any report without a dispatch, or any dispatch
# with neither a report nor a merge"), plus PR #696 round-2 finding F5. No
# `gh` call is involved (grep the script under test: none) — a pure
# local-file `jq` pass, the same UNMOCKED-CONTEXT exemption tests/README.md's
# Shape section documents for test_agent_rules_drift.sh and
# test_session_log_slugs.sh. Pinned to LANG=C / LC_ALL=C.
#
# Covers:
#  - a dispatch with a matching report -> not reported.
#  - the PR #696 round-1 regression: formats/session-log.md's own documented
#    implementer `dispatch` example carries NO `pr` key (the PR doesn't
#    exist yet), pinned here verbatim, paired with a report that DOES carry
#    a `pr` (logged once the PR exists) -> not reported in either direction.
#    Matching must be role+agent, not role+pr+agent, or this pair reads as
#    both a false missing_report and a false missing_dispatch.
#  - a dispatch with no report but a merge on its pr -> not reported (its
#    work is moot once the PR merged).
#  - a dispatch with no report, no pr at all, but a merge on its issue ->
#    not reported (the merge exclusion must match on issue when the dispatch
#    has no pr to match on).
#  - a dispatch with neither a report nor a merge -> reported under
#    missing_report.
#  - a report with a matching dispatch -> not reported.
#  - a report with no matching dispatch at all -> reported under
#    missing_dispatch (this is the exact gap #681 was filed over: reviewer,
#    fix and merge-verifier dispatches went unlogged for an entire session
#    while their reports were logged).
#  - a relay event does NOT stand in for a dispatch (a report following only
#    a relay, no original dispatch, is still reported as missing_dispatch).
#  - PR #696 round-2 F5: an agent id reused across two relay legs (the same
#    role+agent dispatched twice, e.g. an original dispatch then a
#    relay-resume dispatch) is disambiguated by `ts`, not existence alone —
#    an earlier leg's `report` must not be allowed to stand in for a later
#    leg's still-missing `report`.
#  - --json emits parseable JSON with both counts.
#  - usage errors: missing arg (exit 2), unreadable log (exit 1).
#  - issue #719: a record with no `ts`, an unparseable `ts`, or a `ts` using
#    a `+00:00` offset instead of `Z` is named on stderr and excluded from
#    the pass instead of aborting the whole `jq` invocation — a genuine
#    `missing_report` logged beside any of the three is still reported.
#  - issue #720: `--help` prints the predicate to stdout and exits 0; a
#    genuine argument error (missing arg) still exits 2 on stderr.
#  - issue #725: a `stall` event carrying `"terminal": true` closes a
#    `missing_report` gap the same way a `report` or `merge` would; a plain,
#    non-terminal `stall` is unaffected and the dispatch stays reported.
#  - round 1 F1: `terminal` is compared by IDENTITY, not `jq` truthiness —
#    `"terminal": "false"`, `"no"`, `0`, `""`, and `[]` must all leave the
#    missing_report gap open.
#  - round 1 F2: a terminal `stall` with no non-empty string `reason` must
#    NOT close the gap either, and is named on stderr.
#  - mutation probes: disabling the merge-exclusion on missing_report,
#    reinstating the old pr-equality requirement (a mutation that must
#    invert the round-1 regression fixture back into a false positive),
#    dropping the `ts`-ordering guard (a mutation that must invert the
#    masked-second-leg fixture back into a false "consistent"), disabling
#    the missing_dispatch check entirely, reverting the `ts` guard to the
#    pre-fix bare `epoch` definition, reverting `--help` to the pre-fix
#    `argerr` routing, removing the terminal-stall exclusion, reverting
#    `terminal` back to jq truthiness, or removing the required-reason
#    check, each turn a case that must NOT report (or must not abort/close)
#    into one that DOES (or does), proving each guard is load-bearing.
set -euo pipefail
export LANG=C LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/../scripts/log-consistency-check.sh"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/log-consistency-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

fail=0
report(){ echo "FAIL: $*" >&2; fail=1; }

run_check(){
  local out rc
  out="$(bash "$SCRIPT" "$@" 2>"$WORK/stderr")" && rc=0 || rc=$?
  cat "$WORK/stderr" >&2
  printf '%s' "$out"
  return "$rc"
}

MAIN="$WORK/main.jsonl"
cat > "$MAIN" <<'EOF'
{"ts":"2026-09-05T00:00:00Z","event":"dispatch","claim":"c","role":"implementer","agent":"a1","pr":100,"issue":1}
{"ts":"2026-09-05T00:05:00Z","event":"report","claim":"c","role":"implementer","agent":"a1","pr":100,"issue":1,"outcome":"pr"}
{"ts":"2026-08-29T15:10:00Z","event":"dispatch","claim":"acme-03","role":"implementer","model":"mid","issue":1140,"agent":"a1b2"}
{"ts":"2026-08-29T15:40:00Z","event":"report","claim":"acme-03","role":"implementer","agent":"a1b2","model":"mid","issue":1140,"pr":1141,"tokens":9000,"duration_s":600,"outcome":"pr"}
{"ts":"2026-09-05T00:00:00Z","event":"dispatch","claim":"c","role":"reviewer","agent":"r1","pr":200,"issue":2}
{"ts":"2026-09-05T00:10:00Z","event":"merge","claim":"c","pr":200,"issue":2,"rounds":1,"verified":"n/a"}
{"ts":"2026-09-05T00:00:00Z","event":"dispatch","claim":"c","role":"implementer","agent":"a2","issue":4}
{"ts":"2026-09-05T00:10:00Z","event":"merge","claim":"c","pr":400,"issue":4,"rounds":1,"verified":"n/a"}
{"ts":"2026-09-05T00:00:00Z","event":"dispatch","claim":"c","role":"fix","agent":"f1","pr":300,"issue":3}
{"ts":"2026-09-05T00:00:00Z","event":"report","claim":"c","role":"reviewer","agent":"r9","pr":900,"issue":9,"outcome":"approved"}
{"ts":"2026-09-05T00:00:00Z","event":"relay","claim":"c","pr":1000,"round":1,"role":"implementer","agent":"aX"}
{"ts":"2026-09-05T00:20:00Z","event":"report","claim":"c","role":"implementer","agent":"aX","pr":1000,"issue":10,"outcome":"pr"}
EOF

out="$(run_check "$MAIN")" && rc=0 || rc=$?
[ "$rc" -eq 1 ] || report "main fixture: expected exit 1 (inconsistencies present), got $rc"
echo "$out" | grep -q 'role=implementer pr=100 ' \
  && report "dispatch/report pair (a1) was reported as missing (false positive)"
echo "$out" | grep -q 'agent=a1b2' \
  && report "schema-example pair (a1b2: pr-less dispatch, pr-bearing report) was reported as missing (round-1 regression)"
echo "$out" | grep -q 'role=reviewer pr=200' \
  && report "dispatch closed by merge (r1/pr200) was reported as missing_report (merge exclusion not honored)"
echo "$out" | grep -q 'agent=a2' \
  && report "pr-less dispatch (a2/issue4) closed by a merge matching its issue was reported as missing_report (issue-based merge exclusion not honored)"
echo "$out" | grep -q 'role=fix pr=300 agent=f1' \
  || report "dispatch with neither report nor merge (f1/pr300) was NOT reported under missing_report"
echo "$out" | grep -q 'role=reviewer pr=900 agent=r9' \
  || report "report with no matching dispatch at all (r9/pr900) was NOT reported under missing_dispatch (the #681 gap this script exists to catch)"
echo "$out" | grep -q 'agent=aX' \
  || report "relay-then-report (aX/pr1000, no original dispatch) was NOT reported as missing_dispatch (a relay wrongly stood in for a dispatch)"

CLEAN="$WORK/clean.jsonl"
cat > "$CLEAN" <<'EOF'
{"ts":"2026-09-05T00:00:00Z","event":"dispatch","claim":"c","role":"implementer","agent":"a1","pr":100,"issue":1}
{"ts":"2026-09-05T00:05:00Z","event":"report","claim":"c","role":"implementer","agent":"a1","pr":100,"issue":1,"outcome":"pr"}
EOF
out="$(run_check "$CLEAN")" && rc=0 || rc=$?
[ "$rc" -eq 0 ] || report "clean fixture: expected exit 0, got $rc"
echo "$out" | grep -qi 'consistent' || report "clean fixture: expected a 'consistent' message, got: $out"

# PR #696 round-2 F5: agent id reused across two dispatched legs (the
# reviewer's real-log shape: a relay-resume re-dispatches under the SAME
# agent id). The first leg's report must not mask the second leg's missing
# report.
MASKED_LEG="$WORK/masked-leg.jsonl"
cat > "$MASKED_LEG" <<'EOF'
{"ts":"2026-09-05T01:21:04Z","event":"dispatch","claim":"c","role":"reviewer","agent":"a2f22b9","pr":694,"issue":70}
{"ts":"2026-09-05T01:30:00Z","event":"report","claim":"c","role":"reviewer","agent":"a2f22b9","pr":694,"issue":70,"outcome":"relay"}
{"ts":"2026-09-05T01:41:23Z","event":"dispatch","claim":"c","role":"reviewer","agent":"a2f22b9","pr":694,"issue":70,"kind":"relay-resume"}
EOF
out="$(run_check "$MASKED_LEG")" && rc=0 || rc=$?
[ "$rc" -eq 1 ] || report "F5: masked-second-leg fixture (a2f22b9's second dispatch has no later report): expected exit 1, got $rc"
mr_lines="$(echo "$out" | grep -c 'agent=a2f22b9' || true)"
[ "$mr_lines" -eq 1 ] || report "F5: expected exactly one missing_report line for a2f22b9's second (unanswered) leg, got $mr_lines"

MASKED_LEG_CLOSED="$WORK/masked-leg-closed.jsonl"
cat > "$MASKED_LEG_CLOSED" <<'EOF'
{"ts":"2026-09-05T01:21:04Z","event":"dispatch","claim":"c","role":"reviewer","agent":"a2f22b9","pr":694,"issue":70}
{"ts":"2026-09-05T01:30:00Z","event":"report","claim":"c","role":"reviewer","agent":"a2f22b9","pr":694,"issue":70,"outcome":"relay"}
{"ts":"2026-09-05T01:41:23Z","event":"dispatch","claim":"c","role":"reviewer","agent":"a2f22b9","pr":694,"issue":70,"kind":"relay-resume"}
{"ts":"2026-09-05T01:55:00Z","event":"report","claim":"c","role":"reviewer","agent":"a2f22b9","pr":694,"issue":70,"outcome":"approved"}
EOF
out="$(run_check "$MASKED_LEG_CLOSED")" && rc=0 || rc=$?
[ "$rc" -eq 0 ] || report "F5: both legs answered (a2f22b9): expected exit 0, got $rc: $out"
! echo "$out" | grep -q 'a2f22b9' || report "F5: both legs answered but a2f22b9 was still reported"

# PR #696 round-2 G2: a dispatch and its report sharing one whole-second ts
# (the direct result of hand-backfilling a missing event per maintenance.md
# section 5) must pair in BOTH directions, not read as both a false
# missing_report and a false missing_dispatch.
EQUAL_TS="$WORK/equal-ts.jsonl"
cat > "$EQUAL_TS" <<'EOF'
{"ts":"2026-09-05T02:00:00Z","event":"dispatch","claim":"c","role":"fix","agent":"e1","pr":500,"issue":50}
{"ts":"2026-09-05T02:00:00Z","event":"report","claim":"c","role":"fix","agent":"e1","pr":500,"issue":50,"outcome":"pr"}
EOF
out="$(run_check "$EQUAL_TS")" && rc=0 || rc=$?
[ "$rc" -eq 0 ] || report "G2: equal-ts dispatch/report pair (e1): expected exit 0, got $rc: $out"
! echo "$out" | grep -q 'e1' || report "G2: equal-ts dispatch/report pair (e1) was misreported (false missing_report or missing_dispatch)"


outj="$(run_check "$MAIN" --json)" || true
echo "$outj" | jq -e . > /dev/null 2>&1 || report "--json output does not parse as JSON"
mrc="$(echo "$outj" | jq -r '.missing_report_count')"
mdc="$(echo "$outj" | jq -r '.missing_dispatch_count')"
[ "$mrc" = "1" ] || report "--json missing_report_count: expected 1 (f1/pr300), got $mrc"
[ "$mdc" = "2" ] || report "--json missing_dispatch_count: expected 2 (r9/pr900, aX/pr1000), got $mdc"

if bash "$SCRIPT" >/dev/null 2>&1; then report "no args: expected non-zero exit"; fi
rc=0; bash "$SCRIPT" >/dev/null 2>"$WORK/e1" || rc=$?
[ "$rc" -eq 2 ] || report "no args: expected exit 2, got $rc"

rc=0; bash "$SCRIPT" "$WORK/does-not-exist.jsonl" >/dev/null 2>"$WORK/e2" || rc=$?
[ "$rc" -eq 1 ] || report "unreadable log: expected exit 1, got $rc"

MUT_DIR="$WORK/mut"
mkdir -p "$MUT_DIR"

# Probe 1: disable the merge exclusion on missing_report -> r1/pr200 (closed
# by merge) must now incorrectly appear.
MUT1="$MUT_DIR/no-merge-guard.sh"
python3 - "$SCRIPT" "$MUT1" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
text = open(src).read()
old = '''              and (($d.issue != null and (($merged_issues | index($d.issue)) != null))
                   or ($d.pr != null and (($merged_prs | index($d.pr)) != null))
                   | not)
'''
assert old in text, "pattern not found for mutation probe 1"
text = text.replace(old, "              and true\n")
open(dst, "w").write(text)
PY
chmod +x "$MUT1"
outm="$(bash "$MUT1" "$MAIN" 2>/dev/null)" || true
echo "$outm" | grep -q 'role=reviewer pr=200' \
  || report "mutation probe 1: merge-exclusion removed but merged dispatch still not reported (guard not load-bearing / probe broken)"

# Probe 2: reinstate the old pr-equality requirement on the missing_report
# match -> the schema-example pair (a1b2, pr-less dispatch / pr-bearing
# report) must now incorrectly appear as missing_report (this is the exact
# round-1 regression: matching by role+pr+agent instead of role+agent).
MUT2="$MUT_DIR/pr-equality-restored.sh"
python3 - "$SCRIPT" "$MUT2" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
text = open(src).read()
old = "[ $reports[] | select(.role == $d.role and .agent == $d.agent and (epoch >= ($d|epoch))) ] | length"
assert old in text, "pattern not found for mutation probe 2"
text = text.replace(
    old,
    "[ $reports[] | select(.role == $d.role and .pr == $d.pr and .agent == $d.agent and (epoch >= ($d|epoch))) ] | length",
    1,
)
open(dst, "w").write(text)
PY
chmod +x "$MUT2"
outm="$(bash "$MUT2" "$MAIN" 2>/dev/null)" || true
echo "$outm" | grep -q 'agent=a1b2' \
  || report "mutation probe 2: pr-equality restored but the pr-less/pr-bearing pair (a1b2) still not misreported (guard not load-bearing / probe broken)"

# Probe 3: disable the missing_dispatch check entirely -> r9/pr900 must now
# disappear from the report.
MUT3="$MUT_DIR/no-missing-dispatch.sh"
python3 - "$SCRIPT" "$MUT3" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
text = open(src).read()
old = '''        missing_dispatch: [
          $reports[] as $r
          | select(
              [ $dispatches[] | select(.role == $r.role and .agent == $r.agent and (epoch <= ($r|epoch))) ] | length == 0
            )
          | {role: $r.role, pr: $r.pr, agent: $r.agent, issue: $r.issue}
        ]
'''
assert old in text, "pattern not found for mutation probe 3"
text = text.replace(old, "        missing_dispatch: []\n")
open(dst, "w").write(text)
PY
chmod +x "$MUT3"
outm="$(bash "$MUT3" "$MAIN" 2>/dev/null)" || true
echo "$outm" | grep -q 'role=reviewer pr=900' \
  && report "mutation probe 3: missing_dispatch check disabled but r9/pr900 still reported (guard not load-bearing / probe broken)"

# Probe 4 (F5): drop the ts-ordering guard on missing_report (existence only,
# no epoch comparison) -> the masked-second-leg fixture must now read as
# "consistent" (the first leg's report wrongly stands in for the second
# leg's missing report).
MUT4="$MUT_DIR/no-ts-order-missing-report.sh"
python3 - "$SCRIPT" "$MUT4" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
text = open(src).read()
old = "[ $reports[] | select(.role == $d.role and .agent == $d.agent and (epoch >= ($d|epoch))) ] | length"
assert old in text, "pattern not found for mutation probe 4"
text = text.replace(
    old,
    "[ $reports[] | select(.role == $d.role and .agent == $d.agent) ] | length",
    1,
)
open(dst, "w").write(text)
PY
chmod +x "$MUT4"
outm="$(bash "$MUT4" "$MASKED_LEG" 2>/dev/null)" || true
echo "$outm" | grep -qi 'consistent' \
  || report "mutation probe 4: ts-ordering guard removed but masked-second-leg fixture still reported (guard not load-bearing / probe broken)"

# Probe 5 (G2): revert the missing_report comparison from non-strict (>=)
# back to strict (>) -> the equal-ts pair (e1) must now incorrectly reappear
# as missing_report.
MUT5="$MUT_DIR/strict-missing-report.sh"
python3 - "$SCRIPT" "$MUT5" <<'INNERPY'
import sys
src, dst = sys.argv[1], sys.argv[2]
text = open(src).read()
old = "[ $reports[] | select(.role == $d.role and .agent == $d.agent and (epoch >= ($d|epoch))) ] | length"
assert old in text, "pattern not found for mutation probe 5"
text = text.replace(
    old,
    "[ $reports[] | select(.role == $d.role and .agent == $d.agent and (epoch > ($d|epoch))) ] | length",
    1,
)
open(dst, "w").write(text)
INNERPY
chmod +x "$MUT5"
outm="$(bash "$MUT5" "$EQUAL_TS" 2>/dev/null)" || true
echo "$outm" | grep -q 'role=fix pr=500 agent=e1' \
  || report "mutation probe 5: missing_report reverted to strict > but equal-ts pair (e1) still not misreported (guard not load-bearing / probe broken)"

# Probe 6 (G2): revert the missing_dispatch comparison from non-strict (<=)
# back to strict (<) -> the equal-ts pair (e1) must now incorrectly reappear
# as missing_dispatch.
MUT6B="$MUT_DIR/strict-missing-dispatch.sh"
python3 - "$SCRIPT" "$MUT6B" <<'INNERPY'
import sys
src, dst = sys.argv[1], sys.argv[2]
text = open(src).read()
old = "[ $dispatches[] | select(.role == $r.role and .agent == $r.agent and (epoch <= ($r|epoch))) ] | length == 0"
assert old in text, "pattern not found for mutation probe 6"
text = text.replace(
    old,
    "[ $dispatches[] | select(.role == $r.role and .agent == $r.agent and (epoch < ($r|epoch))) ] | length == 0",
    1,
)
open(dst, "w").write(text)
INNERPY
chmod +x "$MUT6B"
outm="$(bash "$MUT6B" "$EQUAL_TS" 2>/dev/null)" || true
echo "$outm" | grep -q 'role=fix pr=500 agent=e1' \
  || report "mutation probe 6: missing_dispatch reverted to strict < but equal-ts pair (e1) still not misreported (guard not load-bearing / probe broken)"

# --- issue #719: one unparseable/missing/wrongly-offset `ts` must not abort
# the whole pass, and a genuine inconsistency beside it must still surface ---
MALFORMED_TS="$WORK/malformed-ts.jsonl"
cat > "$MALFORMED_TS" <<'EOF'
{"ts":"2026-09-05T03:00:00Z","event":"dispatch","claim":"c","role":"fix","agent":"m1","pr":9100,"issue":91}
{"event":"dispatch","claim":"c","role":"implementer","agent":"m-noTS","pr":9101,"issue":92}
{"ts":"not-a-date","event":"dispatch","claim":"c","role":"implementer","agent":"m-badTS","pr":9102,"issue":93}
{"ts":"2026-09-05T03:00:00+00:00","event":"dispatch","claim":"c","role":"implementer","agent":"m-offsetTS","pr":9103,"issue":94}
{"ts":"2026-09-05T03:00Z","event":"dispatch","claim":"c","role":"implementer","agent":"m-minuteTS","pr":9104,"issue":95}
EOF
out="$(run_check "$MALFORMED_TS" 2>"$WORK/malformed-stderr")" && rc=0 || rc=$?
[ "$rc" -eq 1 ] || report "#719: malformed-ts fixture: expected a defined exit 1 (genuine missing_report present), got $rc"
echo "$out" | grep -q 'role=fix pr=9100 agent=m1' \
  || report "#719: genuine missing_report (m1) beside malformed-ts lines was NOT reported (one bad line took the whole pass dark)"
for bad in m-noTS m-badTS m-offsetTS m-minuteTS; do
  grep -q "$bad" "$WORK/malformed-stderr" \
    || report "#719: malformed record for agent $bad was not named on stderr"
done
! grep -qi 'jq: error' "$WORK/malformed-stderr" \
  || report "#719: a raw jq error leaked to stderr instead of a named malformed-record warning"

# --- issue #743: a schema-shaped, MINUTE-precision ts (the exact shape the
# pre-#743 stamp-claim.sh wrote, and what pre-#743 archived logs still
# contain) must be diagnosed as "unsupported precision", never lumped into
# "malformed (missing/unparseable ts)", and still excluded from the pass. ---
minute_line="$(grep -F 'm-minuteTS' "$WORK/malformed-stderr")"
echo "$minute_line" | grep -qi 'unsupported precision' \
  || report "#743: minute-precision ts diagnosed as something other than 'unsupported precision': $minute_line"
echo "$minute_line" | grep -qi 'missing ts\|unparseable ts' \
  && report "#743: minute-precision ts was ALSO reported as missing/unparseable, not distinct: $minute_line"
for bad in m-noTS m-badTS m-offsetTS; do
  bad_line="$(grep -F "$bad" "$WORK/malformed-stderr")"
  echo "$bad_line" | grep -qi 'unsupported precision' \
    && report "#743: genuinely malformed record ($bad) was misdiagnosed as 'unsupported precision': $bad_line"
done
grep -qi '^log-consistency-check: malformed record (missing ts)' "$WORK/malformed-stderr" \
  || report "#743: missing-ts record was not diagnosed distinctly as 'missing ts'"
grep -qi '^log-consistency-check: malformed record (unparseable ts)' "$WORK/malformed-stderr" \
  || report "#743: unparseable-ts record was not diagnosed distinctly as 'unparseable ts'"

# A second fixture pairs the malformed-ts dispatch with a matching report,
# so the mutation probe below actually forces an `epoch` comparison against
# the bad `ts` (with no matching report, the comparison's iteratee is empty
# and `epoch` is never invoked on the malformed record at all).
MALFORMED_TS_PAIRED="$WORK/malformed-ts-paired.jsonl"
cat > "$MALFORMED_TS_PAIRED" <<'EOF'
{"ts":"not-a-date","event":"dispatch","claim":"c","role":"implementer","agent":"m-badTS","pr":9102,"issue":93}
{"ts":"2026-09-05T03:05:00Z","event":"report","claim":"c","role":"implementer","agent":"m-badTS","pr":9102,"issue":93,"outcome":"pr"}
EOF
out="$(run_check "$MALFORMED_TS_PAIRED" 2>"$WORK/malformed-paired-stderr")" && rc=0 || rc=$?
[ "$rc" -eq 1 ] || report "#719: malformed-ts-paired fixture: expected a defined exit 1 (malformed dispatch excluded, its report reads as missing_dispatch), got $rc"
echo "$out" | grep -q 'role=implementer pr=9102 agent=m-badTS' \
  || report "#719: malformed-ts-paired: the surviving report was not reported as missing_dispatch once its malformed dispatch was excluded"
grep -q 'm-badTS' "$WORK/malformed-paired-stderr" \
  || report "#719: malformed-ts-paired record was not named on stderr"

# --- issue #720: --help prints the predicate and exits 0; a genuine
# argument error still exits 2 on stderr ---
helpout="$(bash "$SCRIPT" --help 2>"$WORK/help-stderr")" && helprc=0 || helprc=$?
[ "$helprc" -eq 0 ] || report "#720: --help expected exit 0, got $helprc"
echo "$helpout" | grep -qi 'missing_report\|missing_dispatch' \
  || report "#720: --help stdout did not contain a distinctive line of the predicate"
[ -s "$WORK/help-stderr" ] && report "#720: --help wrote to stderr (expected a clean stdout predicate)"
rc=0; bash "$SCRIPT" >/dev/null 2>"$WORK/argerr-stderr" || rc=$?
[ "$rc" -eq 2 ] || report "#720: a genuine argument error (no args) must still exit 2, got $rc"

# --- issue #725: a stall carrying "terminal": true closes a missing_report
# gap the same way a report or merge would ---
TERMINAL_CLOSED="$WORK/terminal-closed.jsonl"
cat > "$TERMINAL_CLOSED" <<'EOF'
{"ts":"2026-09-05T04:00:00Z","event":"dispatch","claim":"c","role":"reviewer","agent":"t1","pr":7120,"issue":712}
{"ts":"2026-09-05T06:38:00Z","event":"stall","claim":"c","agent":"t1","reason":"declared dead and stopped; re-dispatched","terminal":true}
EOF
out="$(run_check "$TERMINAL_CLOSED")" && rc=0 || rc=$?
[ "$rc" -eq 0 ] || report "#725: terminally-closed dispatch (t1) still reported: expected exit 0, got $rc: $out"
! echo "$out" | grep -q 't1' || report "#725: a stall carrying terminal:true did not close the missing_report gap"

NONTERMINAL_STILL_MISSING="$WORK/nonterminal-still-missing.jsonl"
cat > "$NONTERMINAL_STILL_MISSING" <<'EOF'
{"ts":"2026-09-05T04:00:00Z","event":"dispatch","claim":"c","role":"reviewer","agent":"t2","pr":7130,"issue":713}
{"ts":"2026-09-05T04:10:00Z","event":"stall","claim":"c","agent":"t2","reason":"no worktree activity"}
EOF
out="$(run_check "$NONTERMINAL_STILL_MISSING")" && rc=0 || rc=$?
[ "$rc" -eq 1 ] || report "#725: non-terminal stall (t2) should still leave missing_report open: expected exit 1, got $rc"
echo "$out" | grep -q 'role=reviewer pr=7130 agent=t2' \
  || report "#725: a non-terminal stall was wrongly treated as closing missing_report"

# --- round 1 F1: `terminal` must be compared by identity, never jq
# truthiness — a hand-written "false"/"no"/0/""/[] must all leave the
# missing_report gap OPEN, not close it ---
for val in '"false"' '"no"' 0 '""' '[]'; do
  TRUTHY="$WORK/truthy-terminal.jsonl"
  cat > "$TRUTHY" <<EOF
{"ts":"2026-09-05T04:00:00Z","event":"dispatch","claim":"c","role":"reviewer","agent":"t3","pr":7140,"issue":714}
{"ts":"2026-09-05T04:10:00Z","event":"stall","claim":"c","agent":"t3","reason":"looked idle","terminal":$val}
EOF
  out="$(run_check "$TRUTHY" 2>/dev/null)" && rc=0 || rc=$?
  [ "$rc" -eq 1 ] || report "round 1 F1: terminal=$val must NOT close missing_report (jq truthiness, not identity): expected exit 1, got $rc: $out"
  echo "$out" | grep -q 'role=reviewer pr=7140 agent=t3' \
    || report "round 1 F1: terminal=$val wrongly treated as closing missing_report"
done

# --- round 1 F2: a terminal stall with no non-empty reason must NOT close
# the gap either, and must be named on stderr ---
REASONLESS="$WORK/reasonless-terminal.jsonl"
cat > "$REASONLESS" <<'EOF'
{"ts":"2026-09-05T04:00:00Z","event":"dispatch","claim":"c","role":"reviewer","agent":"t4","pr":7150,"issue":715}
{"ts":"2026-09-05T04:10:00Z","event":"stall","claim":"c","agent":"t4","terminal":true}
EOF
out="$(run_check "$REASONLESS" 2>"$WORK/reasonless-stderr")" && rc=0 || rc=$?
[ "$rc" -eq 1 ] || report "round 1 F2: reason-less terminal stall (t4) must NOT close missing_report: expected exit 1, got $rc: $out"
echo "$out" | grep -q 'role=reviewer pr=7150 agent=t4' \
  || report "round 1 F2: a reason-less terminal stall was wrongly treated as closing missing_report"
grep -q 't4' "$WORK/reasonless-stderr" \
  || report "round 1 F2: reason-less terminal stall (t4) was not named on stderr"

# --- mutation probes for #719, #720, #725 ---

# Probe 7 (#719): revert the ts-guard to the pre-fix bare `epoch` -> the
# malformed-ts fixture must now abort with a raw jq error instead of
# reporting the genuine missing_report beside it.
MUT7="$MUT_DIR/no-ts-guard.sh"
python3 - "$SCRIPT" "$MUT7" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
text = open(src).read()
old = 'def ts_ok: try (has_ts and ts_string and ((.ts | fromdateiso8601) != null)) catch false;\n'
assert old in text, "pattern not found for mutation probe 7"
text = text.replace(old, 'def ts_ok: true;\n')
open(dst, "w").write(text)
PY
chmod +x "$MUT7"
rc=0; bash "$MUT7" "$MALFORMED_TS_PAIRED" >/dev/null 2>"$WORK/mut7-stderr" || rc=$?
[ "$rc" -ne 0 ] && [ "$rc" -ne 1 ] \
  || report "mutation probe 7: ts-guard removed but malformed-ts fixture did not abort (expected a jq crash, guard not load-bearing / probe broken), rc=$rc"
grep -qi 'strptime\|fromdateiso8601\|string\|null\|does not match format\|jq: error' "$WORK/mut7-stderr" \
  || report "mutation probe 7: expected a jq date-parse error in stderr, got: $(cat "$WORK/mut7-stderr")"

# Probe 8 (#720): revert --help to the pre-fix argerr routing -> exit 2 on
# stderr instead of the predicate on stdout with exit 0.
MUT8="$MUT_DIR/help-argerr.sh"
python3 - "$SCRIPT" "$MUT8" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
text = open(src).read()
old = '    -h|--help) print_help; exit 0 ;;\n'
assert old in text, "pattern not found for mutation probe 8"
text = text.replace(old, '    -h|--help) argerr "usage: log-consistency-check.sh <session.jsonl> [--json]" ;;\n')
open(dst, "w").write(text)
PY
chmod +x "$MUT8"
rc=0; bash "$MUT8" --help >/dev/null 2>"$WORK/mut8-stderr" || rc=$?
[ "$rc" -eq 2 ] \
  || report "mutation probe 8: --help reverted to argerr but did not exit 2 (guard not load-bearing / probe broken), rc=$rc"

# Probe 9 (#725): drop the terminal-stall exclusion on missing_report -> the
# terminally-closed dispatch (t1) must now reappear as missing_report.
MUT9="$MUT_DIR/no-terminal-close.sh"
python3 - "$SCRIPT" "$MUT9" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
text = open(src).read()
old = "              and ([ $terminal_stalls[] | select(.agent == $d.agent and (epoch >= ($d|epoch))) ] | length) == 0\n"
assert old in text, "pattern not found for mutation probe 9"
text = text.replace(old, "")
open(dst, "w").write(text)
PY
chmod +x "$MUT9"
outm="$(bash "$MUT9" "$TERMINAL_CLOSED" 2>/dev/null)" || true
echo "$outm" | grep -q 't1' \
  || report "mutation probe 9: terminal-stall exclusion removed but terminally-closed dispatch (t1) still not reported (guard not load-bearing / probe broken)"

# Probe 10 (round 1 F1): revert `.terminal == true` back to the pre-fix jq
# truthiness (`.terminal // false`) -> a stringified "terminal": "false"
# must now wrongly close the missing_report gap.
MUT10="$MUT_DIR/truthy-terminal.sh"
python3 - "$SCRIPT" "$MUT10" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
text = open(src).read()
old = '($good | [ .[] | select(.event == "stall" and .terminal == true and has_reason) ]) as $terminal_stalls'
assert old in text, "pattern not found for mutation probe 10"
new = '($good | [ .[] | select(.event == "stall" and (.terminal // false)) ]) as $terminal_stalls'
text = text.replace(old, new)
open(dst, "w").write(text)
PY
chmod +x "$MUT10"
TRUTHY_T3="$WORK/truthy-terminal.jsonl"
cat > "$TRUTHY_T3" <<'EOF'
{"ts":"2026-09-05T04:00:00Z","event":"dispatch","claim":"c","role":"reviewer","agent":"t3","pr":7140,"issue":714}
{"ts":"2026-09-05T04:10:00Z","event":"stall","claim":"c","agent":"t3","reason":"looked idle","terminal":"false"}
EOF
outm="$(bash "$MUT10" "$TRUTHY_T3" 2>/dev/null)" || true
! echo "$outm" | grep -q 't3' \
  || report "mutation probe 10: terminal truthiness reverted but stringified terminal:\"false\" still correctly left missing_report open (guard not load-bearing / probe broken)"

# Probe 11 (round 1 F2): revert the required-reason check back to no check
# at all -> the reason-less terminal stall (t4) must now wrongly close the
# missing_report gap.
MUT11="$MUT_DIR/no-reason-required.sh"
python3 - "$SCRIPT" "$MUT11" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
text = open(src).read()
old = '($good | [ .[] | select(.event == "stall" and .terminal == true and has_reason) ]) as $terminal_stalls'
assert old in text, "pattern not found for mutation probe 11"
new = '($good | [ .[] | select(.event == "stall" and .terminal == true) ]) as $terminal_stalls'
text = text.replace(old, new)
open(dst, "w").write(text)
PY
chmod +x "$MUT11"
outm="$(bash "$MUT11" "$REASONLESS" 2>/dev/null)" || true
! echo "$outm" | grep -q 't4' \
  || report "mutation probe 11: required-reason check removed but reason-less terminal stall (t4) still correctly left missing_report open (guard not load-bearing / probe broken)"

if [ "$fail" -eq 0 ]; then
  echo "test_log_consistency_check: all assertions passed"
  exit 0
else
  exit 1
fi
