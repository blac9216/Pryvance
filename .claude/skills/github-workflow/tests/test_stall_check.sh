#!/usr/bin/env bash
# test_stall_check.sh — fixture-driven regression test for stall-check.sh
# (issue #681's Acceptance Criteria, plus PR #696 round-1 findings F2-F4 and
# round-2 finding F3). No `gh` call is involved (grep the script under test:
# none) — a pure
# local-file `jq` pass, the same UNMOCKED-CONTEXT exemption tests/README.md's
# Shape section documents for test_agent_rules_drift.sh and
# test_session_log_slugs.sh. Pinned to LANG=C / LC_ALL=C.
#
# Covers the three failure shapes issue #681 names, each against a fixture
# built with timestamps relative to the real wall clock at run time (the
# same `date -u -d '<n> ago'` pattern test_stamp_claim.sh uses for its
# live/stale fixtures, since the script under test reads real `date -u +%s`):
#  - shape 1 (blind to a role with no `dispatch`): out of scope for this
#    script (log-consistency-check.sh's job) — not asserted here.
#  - shape 2: a RESUMED agent (relay leg, already has one earlier `report`)
#    that goes idle past the limit after being resumed IS reported; the same
#    agent BEFORE the limit is not.
#  - shape 3: a relay's two legs, filed under different agent ids, pair by
#    pr+round. Leg 1 (implementer) with a landed leg 2 (reviewer) is not
#    reported even though leg 1's own agent id shows no closing event. Leg 2
#    itself, with nothing after it, genuinely stalled, IS reported — proving
#    the pairing is one-directional and does not paper over a real reviewer
#    stall (the defect the reference implementation this issue was filed
#    against would have hidden).
#  - a plain dispatched agent past the limit is reported; the same agent
#    with a later `report` is not.
#  - an agent whose PR has merged is not reported regardless of idle time.
#  - PR #696 round-1 F2/F3: a schema-shaped, pr-LESS implementer `dispatch`
#    — one fixture pinned verbatim to formats/session-log.md's own
#    documented example (issue 1140, agent a1b2, no `pr` key) — is reported
#    when nothing closes it, and NOT reported when a `merge` names its
#    `issue` (there being no `pr` on the dispatch to match against).
#  - PR #696 round-1 F4: a `stall` event logged for an agent does not
#    silence the detector — the same agent, still idle after the `stall`,
#    is still reported; a `resume` shortly after clears it; a `resume` that
#    itself goes stale past the limit is reported again; and either
#    `report` or `merge` closes the leg the same as they would a plain
#    `dispatch`.
#  - PR #696 round-2 F3: a `stall` does not RESET the idle clock either —
#    `idle_min` is measured from the agent's most recent `dispatch`/
#    `relay`/`resume`/`report` (never a `stall`), so an agent stalled
#    repeatedly (240m/180m/30m ago, dispatched 300m ago) still reads as
#    ~300m idle, not ~30m since the last notice.
#  - --json emits parseable JSON with the expected count.
#  - usage errors: missing args (exit 2), non-numeric idle-minutes (exit 2),
#    unreadable log (exit 1).
#  - mutation probes: commenting out the merge-exclusion, the issue-based
#    half of the merge-exclusion, the relay-pairing exclusion, the
#    stall/resume leg-open filter, the idle-limit filter, or the
#    acted-vs-last idle-clock source, each turn a case that must NOT report
#    an agent into one that DOES (or vice versa for the limit filter),
#    proving each guard is load-bearing rather than redundant.
#  - issue #719: a record with no `ts`, an unparseable `ts`, or a `ts` using
#    a `+00:00` offset instead of `Z` is named on stderr and excluded from
#    the pass instead of aborting the whole `jq` invocation with a raw
#    `strptime`/`fromdateiso8601` error and exit 5 — a healthy, over-limit
#    agent logged beside any of the three is still reported.
#  - issue #720: `--help` prints the predicate to stdout and exits 0; a
#    genuine argument error (missing args) still exits 2 on stderr.
#  - issue #725: a `stall` event carrying `"terminal": true` administratively
#    closes a leg — the agent stops being reported even with nothing else
#    (no `report`, `relay`, or `merge`) ever closing it; a plain, non-
#    terminal `stall` is unaffected and still keeps the agent visible.
#  - round 1 F1: `terminal` is compared by IDENTITY, not `jq` truthiness —
#    `"terminal": "false"`, `"no"`, `0`, `""`, and `[]` must all leave the
#    leg open.
#  - round 1 F2: a terminal `stall` with no non-empty string `reason` must
#    NOT close the leg either, and is named on stderr.
#  - mutation probes: reverting the `ts` guard to the pre-fix bare `epoch`
#    definition, reverting `--help` to the pre-fix `argerr` routing,
#    removing the terminal-stall exclusion, reverting `terminal` back to
#    jq truthiness, and removing the required-reason check, each turn a
#    case that must NOT report (or must not abort/close) into one that DOES
#    (or does), proving each fix is load-bearing rather than redundant.
set -euo pipefail
export LANG=C LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/../scripts/stall-check.sh"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/stall-check-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

fail=0
report(){ echo "FAIL: $*" >&2; fail=1; }

ago(){ date -u -d "$1 minutes ago" +%Y-%m-%dT%H:%M:%SZ; }

run_stall(){
  local out rc
  out="$(bash "$SCRIPT" "$@" 2>"$WORK/stderr")" && rc=0 || rc=$?
  cat "$WORK/stderr" >&2
  printf '%s' "$out"
  return "$rc"
}

# --- fixture: main shapes ---
T90=$(ago 90); T80=$(ago 80); T30=$(ago 30); T5=$(ago 5)
MAIN="$WORK/main.jsonl"
cat > "$MAIN" <<EOF
{"ts":"$T90","event":"dispatch","claim":"c","role":"implementer","agent":"a1","pr":100,"issue":1}
{"ts":"$T30","event":"dispatch","claim":"c","role":"implementer","agent":"a2","pr":200,"issue":2}
{"ts":"$T90","event":"relay","claim":"c","pr":400,"round":1,"role":"implementer","agent":"a3"}
{"ts":"$T80","event":"relay","claim":"c","pr":400,"round":1,"role":"reviewer","agent":"r3"}
{"ts":"$T90","event":"dispatch","claim":"c","role":"implementer","agent":"a5","pr":600,"issue":6}
{"ts":"$T30","event":"report","claim":"c","role":"implementer","agent":"a5","pr":600,"issue":6,"outcome":"pr"}
{"ts":"$T5","event":"relay","claim":"c","pr":600,"round":2,"role":"implementer","agent":"a5"}
{"ts":"$T90","event":"dispatch","claim":"c","role":"reviewer","agent":"r7","pr":700,"issue":7}
{"ts":"$T80","event":"merge","claim":"c","pr":700,"issue":7,"rounds":1,"verified":"n/a"}
{"ts":"$T90","event":"dispatch","claim":"c","role":"implementer","agent":"a8","pr":800,"issue":8}
{"ts":"$T30","event":"report","claim":"c","role":"implementer","agent":"a8","pr":800,"issue":8,"outcome":"pr"}
EOF

out="$(run_stall 60 "$MAIN")" && rc=0 || rc=$?
[ "$rc" -eq 1 ] || report "main fixture: expected exit 1 (stalls present), got $rc"
echo "$out" | grep -q '^  a1 dispatch role=implementer pr=100' \
  || report "plain dispatched agent idle 90m > 60m limit not reported"
echo "$out" | grep -q '^  a2' \
  && report "dispatched agent idle 30m < 60m limit was reported (false positive)"
echo "$out" | grep -q '^  a3' \
  && report "relay leg 1 (implementer) with a landed leg 2 was reported (should be closed by pairing)"
echo "$out" | grep -q '^  r3 relay role=reviewer pr=400 round=1 idle=80m' \
  || report "relay leg 2 (reviewer) genuinely stalled at 80m was NOT reported (pairing over-closed it)"
echo "$out" | grep -q '^  a5' \
  && report "resumed agent (relay 5m ago) idle < limit was reported (false positive)"
echo "$out" | grep -q '^  r7' \
  && report "agent whose PR merged was reported despite the merge"
echo "$out" | grep -q '^  a8' \
  && report "dispatched agent with a later report was reported (report did not close it)"

# --- shape 2 isolated: resumed agent that stalls AFTER its first report ---
T90=$(ago 90); T65=$(ago 65); T10=$(ago 10)
RESUMED_STALLED="$WORK/resumed-stalled.jsonl"
cat > "$RESUMED_STALLED" <<EOF
{"ts":"$T90","event":"dispatch","claim":"c","role":"implementer","agent":"a9","pr":900,"issue":9}
{"ts":"$T90","event":"report","claim":"c","role":"implementer","agent":"a9","pr":900,"issue":9,"outcome":"pr"}
{"ts":"$T65","event":"relay","claim":"c","pr":900,"round":2,"role":"implementer","agent":"a9"}
EOF
out="$(run_stall 60 "$RESUMED_STALLED")" && rc=0 || rc=$?
[ "$rc" -eq 1 ] || report "resumed-stalled fixture: expected exit 1, got $rc"
echo "$out" | grep -q '^  a9 relay role=implementer pr=900 round=2 idle=65m' \
  || report "AC3: resumed agent stalling after its first report was NOT reported"

RESUMED_FRESH="$WORK/resumed-fresh.jsonl"
cat > "$RESUMED_FRESH" <<EOF
{"ts":"$T90","event":"dispatch","claim":"c","role":"implementer","agent":"a9","pr":900,"issue":9}
{"ts":"$T90","event":"report","claim":"c","role":"implementer","agent":"a9","pr":900,"issue":9,"outcome":"pr"}
{"ts":"$T10","event":"relay","claim":"c","pr":900,"round":2,"role":"implementer","agent":"a9"}
EOF
out="$(run_stall 60 "$RESUMED_FRESH")" && rc=0 || rc=$?
[ "$rc" -eq 0 ] || report "resumed-fresh fixture: expected exit 0 (no stalls), got $rc"
! echo "$out" | grep -q '^  ' || report "resumed-fresh fixture reported an agent that is not idle past the limit"

# --- AC2: relayed agent whose leg 2 has landed is not reported (isolated) ---
T90=$(ago 90); T85=$(ago 85)
RELAY_CLOSED="$WORK/relay-closed.jsonl"
cat > "$RELAY_CLOSED" <<EOF
{"ts":"$T90","event":"relay","claim":"c","pr":1000,"round":1,"role":"implementer","agent":"aX"}
{"ts":"$T85","event":"relay","claim":"c","pr":1000,"round":1,"role":"reviewer","agent":"rX"}
{"ts":"$T85","event":"report","claim":"c","role":"reviewer","agent":"rX","pr":1000,"issue":10,"outcome":"approved"}
EOF
out="$(run_stall 60 "$RELAY_CLOSED")" && rc=0 || rc=$?
[ "$rc" -eq 0 ] || report "relay-closed fixture: expected exit 0, got $rc: $out"
! echo "$out" | grep -q '^  ' || report "AC2: relayed agent whose leg 2 landed was still reported as in flight"

# --- PR #696 round-1 F2/F3: pr-less implementer dispatch, schema-pinned ---
# Verbatim from formats/session-log.md's own example (no `pr` key at all —
# the PR doesn't exist yet at dispatch time).
SCHEMA_UNCLOSED="$WORK/schema-unclosed.jsonl"
cat > "$SCHEMA_UNCLOSED" <<'EOF'
{"ts":"2026-08-29T15:10:00Z","event":"dispatch","claim":"acme-03","role":"implementer","model":"mid","issue":1140,"agent":"a1b2"}
EOF
out="$(run_stall 60 "$SCHEMA_UNCLOSED")" && rc=0 || rc=$?
[ "$rc" -eq 1 ] || report "schema-pinned pr-less dispatch with nothing closing it: expected exit 1, got $rc"
echo "$out" | grep -q '^  a1b2 dispatch role=implementer' \
  || report "schema-pinned pr-less dispatch (a1b2, issue 1140, no pr) was NOT reported (F3 coverage gap)"

SCHEMA_MERGED="$WORK/schema-merged.jsonl"
cat > "$SCHEMA_MERGED" <<'EOF'
{"ts":"2026-08-29T15:10:00Z","event":"dispatch","claim":"acme-03","role":"implementer","model":"mid","issue":1140,"agent":"a1b2"}
{"ts":"2026-08-29T15:20:00Z","event":"merge","claim":"acme-03","pr":1141,"issue":1140,"rounds":1,"verified":"n/a"}
EOF
out="$(run_stall 60 "$SCHEMA_MERGED")" && rc=0 || rc=$?
[ "$rc" -eq 0 ] || report "F2: schema-pinned pr-less dispatch closed by a merge matching its issue: expected exit 0, got $rc: $out"
! echo "$out" | grep -q 'a1b2' || report "F2: pr-less dispatch closed by an issue-matching merge was still reported"

# --- PR #696 round-1 F4: a logged `stall` must not permanently silence the
# detector for that agent ---
T200=$(ago 200); T150=$(ago 150); T100=$(ago 100); T5=$(ago 5)
STALL_STILL_IDLE="$WORK/stall-still-idle.jsonl"
cat > "$STALL_STILL_IDLE" <<EOF
{"ts":"$T200","event":"dispatch","claim":"c","role":"implementer","agent":"s1","pr":1200,"issue":12}
{"ts":"$T150","event":"stall","claim":"c","agent":"s1","reason":"no worktree activity"}
EOF
out="$(run_stall 60 "$STALL_STILL_IDLE")" && rc=0 || rc=$?
[ "$rc" -eq 1 ] || report "F4: agent idle after its own logged stall: expected exit 1, got $rc"
echo "$out" | grep -q '^  s1 stall' \
  || report "F4: a logged stall event permanently silenced the detector for that agent (idle grown to 150m not reported)"

STALL_THEN_RESUME_FRESH="$WORK/stall-then-resume-fresh.jsonl"
cat > "$STALL_THEN_RESUME_FRESH" <<EOF
{"ts":"$T200","event":"dispatch","claim":"c","role":"implementer","agent":"s2","pr":1300,"issue":13}
{"ts":"$T150","event":"stall","claim":"c","agent":"s2","reason":"no worktree activity"}
{"ts":"$T5","event":"resume","claim":"c","agent":"s2","reason":"worktree active again"}
EOF
out="$(run_stall 60 "$STALL_THEN_RESUME_FRESH")" && rc=0 || rc=$?
[ "$rc" -eq 0 ] || report "F4: agent resumed 5m ago: expected exit 0, got $rc: $out"
! echo "$out" | grep -q 's2' || report "F4: freshly-resumed agent (5m ago) was reported as idle (false positive)"

STALL_THEN_RESUME_STALE="$WORK/stall-then-resume-stale.jsonl"
cat > "$STALL_THEN_RESUME_STALE" <<EOF
{"ts":"$T200","event":"dispatch","claim":"c","role":"implementer","agent":"s3","pr":1400,"issue":14}
{"ts":"$T150","event":"stall","claim":"c","agent":"s3","reason":"no worktree activity"}
{"ts":"$T100","event":"resume","claim":"c","agent":"s3","reason":"worktree active again"}
EOF
out="$(run_stall 60 "$STALL_THEN_RESUME_STALE")" && rc=0 || rc=$?
[ "$rc" -eq 1 ] || report "F4: agent resumed 100m ago (stale again): expected exit 1, got $rc"
echo "$out" | grep -q '^  s3 resume' \
  || report "F4: a resumed leg that stalled again was NOT reported"

STALL_THEN_REPORT="$WORK/stall-then-report.jsonl"
cat > "$STALL_THEN_REPORT" <<EOF
{"ts":"$T200","event":"dispatch","claim":"c","role":"implementer","agent":"s4","pr":1500,"issue":15}
{"ts":"$T150","event":"stall","claim":"c","agent":"s4","reason":"no worktree activity"}
{"ts":"$T100","event":"report","claim":"c","role":"implementer","agent":"s4","pr":1500,"issue":15,"outcome":"pr"}
EOF
out="$(run_stall 60 "$STALL_THEN_REPORT")" && rc=0 || rc=$?
[ "$rc" -eq 0 ] || report "F4: agent stalled then reported: expected exit 0, got $rc: $out"
! echo "$out" | grep -q 's4' || report "F4: a report after a stall did not close the leg"


# --- PR #696 round-2 F3: a repeatedly-logged `stall` must not reset the
# idle clock. Reviewer's reproduction: dispatch 300m ago, stalls at
# 240m/180m/30m ago -> idle must read ~300m (time since the agent last
# actually acted), not ~30m (time since the last stall note).
T300=$(ago 300); T240=$(ago 240); T180=$(ago 180); T30=$(ago 30)
REPEAT_STALL_NO_RESET="$WORK/repeat-stall-no-reset.jsonl"
cat > "$REPEAT_STALL_NO_RESET" <<EOF
{"ts":"$T300","event":"dispatch","claim":"c","role":"implementer","agent":"s5","pr":1600,"issue":16}
{"ts":"$T240","event":"stall","claim":"c","agent":"s5","reason":"no worktree activity"}
{"ts":"$T180","event":"stall","claim":"c","agent":"s5","reason":"no worktree activity"}
{"ts":"$T30","event":"stall","claim":"c","agent":"s5","reason":"no worktree activity"}
EOF
out="$(run_stall 60 "$REPEAT_STALL_NO_RESET")" && rc=0 || rc=$?
[ "$rc" -eq 1 ] || report "F3: repeatedly-stalled agent (300m real silence): expected exit 1, got $rc"
echo "$out" | grep -q '^  s5 stall role=- pr=- round=- idle=300m' \
  || report "F3: idle_min reset to time-since-last-stall instead of measuring from the agent's last real action (300m ago)"

# --- PR #696 round-2 G1: an agent whose logged history is NOTHING but
# `stall` events must be reported, not abort the whole jq pass (exit 5) for
# every agent in the run. Two shapes: several stalls and nothing else, and
# exactly one stall and nothing else. idle_min is measured from the
# EARLIEST stall on record (the only evidence we have of when this agent's
# silence started).
T500=$(ago 500); T300=$(ago 300); T50=$(ago 50)
ALL_STALL="$WORK/all-stall.jsonl"
cat > "$ALL_STALL" <<EOF
{"ts":"$T500","event":"stall","claim":"c","agent":"s6","reason":"no worktree activity"}
{"ts":"$T300","event":"stall","claim":"c","agent":"s6","reason":"no worktree activity"}
{"ts":"$T50","event":"stall","claim":"c","agent":"s6","reason":"no worktree activity"}
EOF
out="$(run_stall 60 "$ALL_STALL")" && rc=0 || rc=$?
[ "$rc" -eq 1 ] || report "G1: all-stall agent (s6): expected exit 1, got $rc"
echo "$out" | grep -q '^  s6 stall role=- pr=- round=- idle=500m' \
  || report "G1: all-stall agent (s6) not reported with idle measured from its EARLIEST stall (500m), got: $out"

T45=$(ago 45)
SINGLE_STALL_ONLY="$WORK/single-stall-only.jsonl"
cat > "$SINGLE_STALL_ONLY" <<EOF
{"ts":"$T45","event":"stall","claim":"c","agent":"s7","reason":"no worktree activity"}
EOF
out="$(run_stall 30 "$SINGLE_STALL_ONLY")" && rc=0 || rc=$?
[ "$rc" -eq 1 ] || report "G1: single-stall-only agent (s7): expected exit 1, got $rc"
echo "$out" | grep -q '^  s7 stall role=- pr=- round=- idle=45m' \
  || report "G1: single-stall-only agent (s7) not reported with idle=45m, got: $out"

# --- --json output ---
outj="$(run_stall 60 "$MAIN" --json)" || true
echo "$outj" | jq -e . > /dev/null 2>&1 || report "--json output does not parse as JSON"
cnt="$(echo "$outj" | jq -r '.count')"
[ "$cnt" = "2" ] || report "--json count: expected 2 (a1, r3), got $cnt"

# --- usage errors ---
if bash "$SCRIPT" >/dev/null 2>&1; then report "no args: expected non-zero exit"; fi
rc=0; bash "$SCRIPT" >/dev/null 2>"$WORK/e1" || rc=$?
[ "$rc" -eq 2 ] || report "no args: expected exit 2, got $rc"

rc=0; bash "$SCRIPT" abc "$MAIN" >/dev/null 2>"$WORK/e2" || rc=$?
[ "$rc" -eq 2 ] || report "non-numeric idle-minutes: expected exit 2, got $rc"

rc=0; bash "$SCRIPT" 60 "$WORK/does-not-exist.jsonl" >/dev/null 2>"$WORK/e3" || rc=$?
[ "$rc" -eq 1 ] || report "unreadable log: expected exit 1, got $rc"

# --- mutation probes: prove each guard is load-bearing ---
MUT_DIR="$WORK/mut"
mkdir -p "$MUT_DIR"

# Probe 1: disable the merge-exclusion entirely -> the merged agent (r7)
# must now appear where it did not before.
MUT1="$MUT_DIR/no-merge-guard.sh"
python3 - "$SCRIPT" "$MUT1" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
text = open(src).read()
old = '''        | map(select(
            ((.leg_start.issue // null) as $i | $i != null and (($merged_issues | index($i)) != null))
            or ((.leg_start.pr // null) as $p | $p != null and (($merged_prs | index($p)) != null))
            | not
          ))
'''
assert old in text, "pattern not found for mutation probe 1"
text = text.replace(old, "        | map(select(true))\n")
open(dst, "w").write(text)
PY
chmod +x "$MUT1"
outm="$(bash "$MUT1" 60 "$MAIN" 2>/dev/null)" || true
echo "$outm" | grep -q '^  r7' \
  || report "mutation probe 1: merge-exclusion removed but merged agent still not reported (guard not load-bearing / probe broken)"

# Probe 1b: drop only the issue-based half of the merge-exclusion (revert to
# pr-only matching) -> the schema-pinned pr-less dispatch closed by an
# issue-matching merge (F2) must now reappear as idle.
MUT1B="$MUT_DIR/pr-only-merge-guard.sh"
python3 - "$SCRIPT" "$MUT1B" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
text = open(src).read()
old = '''        | map(select(
            ((.leg_start.issue // null) as $i | $i != null and (($merged_issues | index($i)) != null))
            or ((.leg_start.pr // null) as $p | $p != null and (($merged_prs | index($p)) != null))
            | not
          ))
'''
new = '''        | map(select(
            ((.leg_start.pr // null) as $p | $p != null and (($merged_prs | index($p)) != null))
            | not
          ))
'''
assert old in text, "pattern not found for mutation probe 1b"
text = text.replace(old, new)
open(dst, "w").write(text)
PY
chmod +x "$MUT1B"
outm="$(bash "$MUT1B" 60 "$SCHEMA_MERGED" 2>/dev/null)" || true
echo "$outm" | grep -q 'a1b2' \
  || report "mutation probe 1b: issue-based merge match removed but pr-less merged dispatch (F2) still not reported (guard not load-bearing / probe broken)"

# Probe 2: disable the relay pairing exclusion -> leg-1 agent (a3) must now
# incorrectly appear as stalled.
MUT2="$MUT_DIR/no-relay-pairing.sh"
python3 - "$SCRIPT" "$MUT2" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
text = open(src).read()
old = '''        | map(select(
            .last.event != "relay"
            or .last.role != "implementer"
            or (("\\(.last.pr)/\\(.last.round)") as $k | $reviewer_legs_seen | index($k)) == null
          ))
'''
assert old in text, "pattern not found for mutation probe 2"
text = text.replace(old, "        | map(select(true))\n")
open(dst, "w").write(text)
PY
chmod +x "$MUT2"
outm="$(bash "$MUT2" 60 "$MAIN" 2>/dev/null)" || true
echo "$outm" | grep -q '^  a3' \
  || report "mutation probe 2: relay-pairing guard removed but leg-1 agent still not reported (guard not load-bearing / probe broken)"

# Probe 3: disable the idle-limit filter -> a2 (idle only 30m, under the 60m
# limit) must now incorrectly appear as stalled.
MUT3="$MUT_DIR/no-idle-filter.sh"
python3 - "$SCRIPT" "$MUT3" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
text = open(src).read()
old = "        | map(select(.idle_min > $lim))\n"
assert old in text, "pattern not found for mutation probe 3"
text = text.replace(old, "        | map(select(true))\n")
open(dst, "w").write(text)
PY
chmod +x "$MUT3"
outm="$(bash "$MUT3" 60 "$MAIN" 2>/dev/null)" || true
echo "$outm" | grep -q '^  a2' \
  || report "mutation probe 3: idle-limit filter removed but under-threshold agent still not reported (guard not load-bearing / probe broken)"

# Probe 4 (F4): restrict the leg-open filter back to dispatch/relay only ->
# the still-idle-after-stall agent (s1) must now disappear.
MUT4="$MUT_DIR/no-stall-leg-open.sh"
python3 - "$SCRIPT" "$MUT4" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
text = open(src).read()
old = '''        | map(select(
            .last.event == "dispatch" or .last.event == "relay"
            or .last.event == "stall" or .last.event == "resume"
          ))
'''
new = '''        | map(select(
            .last.event == "dispatch" or .last.event == "relay"
          ))
'''
assert old in text, "pattern not found for mutation probe 4"
text = text.replace(old, new)
open(dst, "w").write(text)
PY
chmod +x "$MUT4"
outm="$(bash "$MUT4" 60 "$STALL_STILL_IDLE" 2>/dev/null)" || true
echo "$outm" | grep -q 's1' \
  && report "mutation probe 4: stall/resume leg-open filter removed but still-idle-after-stall agent (F4) still reported (guard not load-bearing / probe broken)"

# Probe 5 (F3): revert the idle clock to measure from `.last` instead of
# `.acted` -> the repeatedly-stalled agent (s5, real silence 300m, last
# stall only 30m ago) must now read as under the limit ("none idle").
MUT5="$MUT_DIR/idle-from-last.sh"
python3 - "$SCRIPT" "$MUT5" <<'INNERPY'
import sys
src, dst = sys.argv[1], sys.argv[2]
text = open(src).read()
old = "        | map(. + {idle_min: (($now - (.acted | epoch)) / 60 | floor)})\n"
assert old in text, "pattern not found for mutation probe 5"
text = text.replace(old, "        | map(. + {idle_min: (($now - (.last | epoch)) / 60 | floor)})\n")
open(dst, "w").write(text)
INNERPY
chmod +x "$MUT5"
outm="$(bash "$MUT5" 60 "$REPEAT_STALL_NO_RESET" 2>/dev/null)" || true
echo "$outm" | grep -qi 'none idle' \
  || report "mutation probe 5: idle clock reverted to .last but repeatedly-stalled agent (s5) still read as truly idle (guard not load-bearing / probe broken)"

# Probe 6 (G1): revert the acted-fallback to the pre-fix definition (no
# fallback to the earliest event when every event is a stall) -> running
# against the all-stall fixture (s6) must abort with jq's non-string-input
# error instead of reporting it, proving the fallback is load-bearing.
MUT6="$MUT_DIR/no-acted-fallback.sh"
python3 - "$SCRIPT" "$MUT6" <<'INNERPY'
import sys
src, dst = sys.argv[1], sys.argv[2]
text = open(src).read()
old = '            acted: ((sort_by(epoch) | map(select(.event != "stall")) | last) // (sort_by(epoch) | first))\n'
assert old in text, "pattern not found for mutation probe 6"
text = text.replace(old, '            acted: (sort_by(epoch) | map(select(.event != "stall")) | last)\n', 1)
open(dst, "w").write(text)
INNERPY
chmod +x "$MUT6"
rc=0; bash "$MUT6" 60 "$ALL_STALL" >/dev/null 2>"$WORK/mut6-stderr" || rc=$?
[ "$rc" -ne 0 ] && [ "$rc" -ne 1 ] \
  || report "mutation probe 6: acted-fallback removed but all-stall fixture did not abort (expected a jq crash, guard not load-bearing / probe broken), rc=$rc"
grep -qi 'strptime\|fromdateiso8601\|string' "$WORK/mut6-stderr" \
  || report "mutation probe 6: expected a jq null/string-input error in stderr, got: $(cat "$WORK/mut6-stderr")"

# --- issue #719: one unparseable/missing/wrongly-offset `ts` must not abort
# the whole pass, and the healthy agent beside it must still be reported ---
T90=$(ago 90)
MALFORMED_TS="$WORK/malformed-ts.jsonl"
{
  printf '%s\n' "{\"ts\":\"$T90\",\"event\":\"dispatch\",\"claim\":\"c\",\"role\":\"implementer\",\"agent\":\"m1\",\"pr\":9000,\"issue\":90}"
  printf '%s\n' '{"event":"dispatch","claim":"c","role":"implementer","agent":"m-noTS","pr":9001,"issue":91}'
  printf '%s\n' '{"ts":"not-a-date","event":"dispatch","claim":"c","role":"implementer","agent":"m-badTS","pr":9002,"issue":92}'
  printf '%s\n' '{"ts":"2026-09-05T01:00:00+00:00","event":"dispatch","claim":"c","role":"implementer","agent":"m-offsetTS","pr":9003,"issue":93}'
  printf '%s\n' '{"ts":"2026-09-05T01:00Z","event":"dispatch","claim":"c","role":"implementer","agent":"m-minuteTS","pr":9004,"issue":94}'
} > "$MALFORMED_TS"
out="$(run_stall 60 "$MALFORMED_TS" 2>"$WORK/malformed-stderr")" && rc=0 || rc=$?
[ "$rc" -eq 1 ] || report "#719: malformed-ts fixture: expected a defined exit 1 (healthy agent still idle), got $rc"
echo "$out" | grep -q '^  m1 dispatch role=implementer pr=9000' \
  || report "#719: healthy agent beside malformed-ts lines was NOT reported (one bad line took the whole pass dark)"
for bad in m-noTS m-badTS m-offsetTS m-minuteTS; do
  grep -q "$bad" "$WORK/malformed-stderr" \
    || report "#719: malformed record for agent $bad was not named on stderr"
done
! grep -qi 'strptime\|jq: error' "$WORK/malformed-stderr" \
  || report "#719: a raw jq/strptime error leaked to stderr instead of a named malformed-record warning"

# --- issue #743: a schema-shaped, MINUTE-precision ts (the exact shape the
# pre-#743 stamp-claim.sh wrote, and what pre-#743 archived logs still
# contain) is present and parseable-by-eye — it must be diagnosed as
# "unsupported precision", never lumped into "malformed (missing/
# unparseable ts)", and it must still be excluded from the pass either way.
# ---
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
grep -qi '^stall-check: malformed record (missing ts)' "$WORK/malformed-stderr" \
  || report "#743: missing-ts record was not diagnosed distinctly as 'missing ts'"
grep -qi '^stall-check: malformed record (unparseable ts)' "$WORK/malformed-stderr" \
  || report "#743: unparseable-ts record was not diagnosed distinctly as 'unparseable ts'"

# --- issue #720: --help prints the predicate and exits 0; a genuine
# argument error still exits 2 on stderr ---
helpout="$(bash "$SCRIPT" --help 2>"$WORK/help-stderr")" && helprc=0 || helprc=$?
[ "$helprc" -eq 0 ] || report "#720: --help expected exit 0, got $helprc"
echo "$helpout" | grep -qi 'idle_min\|idle time\|CLOSED by' \
  || report "#720: --help stdout did not contain a distinctive line of the predicate"
[ -s "$WORK/help-stderr" ] && report "#720: --help wrote to stderr (expected a clean stdout predicate)"
rc=0; bash "$SCRIPT" >/dev/null 2>"$WORK/argerr-stderr" || rc=$?
[ "$rc" -eq 2 ] || report "#720: a genuine argument error (no args) must still exit 2, got $rc"

# --- issue #725: a stall carrying "terminal": true administratively closes
# a leg — the stopped agent must stop being reported even though nothing
# else (report/relay/merge) ever closes it ---
T200=$(ago 200); T150=$(ago 150)
TERMINAL_CLOSED="$WORK/terminal-closed.jsonl"
cat > "$TERMINAL_CLOSED" <<EOF
{"ts":"$T200","event":"dispatch","claim":"c","role":"reviewer","agent":"t1","pr":7120,"issue":712}
{"ts":"$T150","event":"stall","claim":"c","agent":"t1","reason":"declared dead and stopped; re-dispatched","terminal":true}
EOF
out="$(run_stall 60 "$TERMINAL_CLOSED")" && rc=0 || rc=$?
[ "$rc" -eq 0 ] || report "#725: terminally-closed leg (t1) still reported: expected exit 0, got $rc: $out"
! echo "$out" | grep -q 't1' || report "#725: a stall carrying terminal:true did not close the leg"

NONTERMINAL_STILL_OPEN="$WORK/nonterminal-still-open.jsonl"
cat > "$NONTERMINAL_STILL_OPEN" <<EOF
{"ts":"$T200","event":"dispatch","claim":"c","role":"reviewer","agent":"t2","pr":7130,"issue":713}
{"ts":"$T150","event":"stall","claim":"c","agent":"t2","reason":"no worktree activity"}
EOF
out="$(run_stall 60 "$NONTERMINAL_STILL_OPEN")" && rc=0 || rc=$?
[ "$rc" -eq 1 ] || report "#725: non-terminal stall (t2) should still be reported: expected exit 1, got $rc"
echo "$out" | grep -q '^  t2 stall' \
  || report "#725: a non-terminal stall was wrongly treated as an administrative close"

# --- round 1 F1: `terminal` must be compared by identity, never jq
# truthiness — a hand-written "false"/"no"/0/""/[] must all leave the leg
# OPEN, not close it ---
for val in '"false"' '"no"' 0 '""' '[]'; do
  TRUTHY="$WORK/truthy-terminal.jsonl"
  cat > "$TRUTHY" <<EOF
{"ts":"$T200","event":"dispatch","claim":"c","role":"reviewer","agent":"t3","pr":7140,"issue":714}
{"ts":"$T150","event":"stall","claim":"c","agent":"t3","reason":"looked idle","terminal":$val}
EOF
  out="$(run_stall 60 "$TRUTHY" 2>/dev/null)" && rc=0 || rc=$?
  [ "$rc" -eq 1 ] || report "round 1 F1: terminal=$val must NOT close the leg (jq truthiness, not identity): expected exit 1, got $rc: $out"
  echo "$out" | grep -q '^  t3 stall' \
    || report "round 1 F1: terminal=$val wrongly treated as an administrative close"
done

# --- round 1 F2: a terminal stall with no non-empty reason must NOT close
# the leg either, and must be named on stderr ---
REASONLESS="$WORK/reasonless-terminal.jsonl"
cat > "$REASONLESS" <<EOF
{"ts":"$T200","event":"dispatch","claim":"c","role":"reviewer","agent":"t4","pr":7150,"issue":715}
{"ts":"$T150","event":"stall","claim":"c","agent":"t4","terminal":true}
EOF
out="$(run_stall 60 "$REASONLESS" 2>"$WORK/reasonless-stderr")" && rc=0 || rc=$?
[ "$rc" -eq 1 ] || report "round 1 F2: reason-less terminal stall (t4) must NOT close the leg: expected exit 1, got $rc: $out"
echo "$out" | grep -q '^  t4 stall' \
  || report "round 1 F2: a reason-less terminal stall was wrongly treated as an administrative close"
grep -q 't4' "$WORK/reasonless-stderr" \
  || report "round 1 F2: reason-less terminal stall (t4) was not named on stderr"

REASON_EMPTY="$WORK/empty-reason-terminal.jsonl"
cat > "$REASON_EMPTY" <<EOF
{"ts":"$T200","event":"dispatch","claim":"c","role":"reviewer","agent":"t5","pr":7160,"issue":716}
{"ts":"$T150","event":"stall","claim":"c","agent":"t5","reason":"","terminal":true}
EOF
out="$(run_stall 60 "$REASON_EMPTY" 2>/dev/null)" && rc=0 || rc=$?
[ "$rc" -eq 1 ] || report "round 1 F2: empty-string-reason terminal stall (t5) must NOT close the leg: expected exit 1, got $rc: $out"

# --- mutation probes for #719, #720, #725 ---

# Probe 7 (#719): revert `epoch`/malformed-guard back to the pre-fix bare
# definition -> the malformed-ts fixture must now abort with a raw jq error
# instead of reporting the healthy agent beside it.
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
rc=0; bash "$MUT7" 60 "$MALFORMED_TS" >/dev/null 2>"$WORK/mut7-stderr" || rc=$?
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
text = text.replace(old, '    -h|--help) argerr "usage: stall-check.sh <idle-minutes> <session.jsonl> [--json]" ;;\n')
open(dst, "w").write(text)
PY
chmod +x "$MUT8"
rc=0; bash "$MUT8" --help >/dev/null 2>"$WORK/mut8-stderr" || rc=$?
[ "$rc" -eq 2 ] \
  || report "mutation probe 8: --help reverted to argerr but did not exit 2 (guard not load-bearing / probe broken), rc=$rc"

# Probe 9 (#725): drop the terminal-stall exclusion -> the terminally-closed
# leg (t1) must now reappear as stalled forever.
MUT9="$MUT_DIR/no-terminal-close.sh"
python3 - "$SCRIPT" "$MUT9" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
text = open(src).read()
old = '''        | map(select(
            (.last.event != "stall")
            or (.last.terminal != true)
            or ((.last | has_reason) | not)
          ))
'''
assert old in text, "pattern not found for mutation probe 9"
text = text.replace(old, "")
open(dst, "w").write(text)
PY
chmod +x "$MUT9"
outm="$(bash "$MUT9" 60 "$TERMINAL_CLOSED" 2>/dev/null)" || true
echo "$outm" | grep -q 't1' \
  || report "mutation probe 9: terminal-stall exclusion removed but terminally-closed leg (t1) still not reported (guard not load-bearing / probe broken)"

# Probe 10 (round 1 F1): revert `terminal == true` back to the pre-fix jq
# truthiness (`.terminal // false`) -> a stringified "terminal": "false"
# must now wrongly close the leg (t3 drops out of the report).
MUT10="$MUT_DIR/truthy-terminal.sh"
python3 - "$SCRIPT" "$MUT10" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
text = open(src).read()
old = '''        | map(select(
            (.last.event != "stall")
            or (.last.terminal != true)
            or ((.last | has_reason) | not)
          ))
'''
assert old in text, "pattern not found for mutation probe 10"
new = '''        | map(select(
            (.last.event != "stall") or ((.last.terminal // false) | not)
          ))
'''
text = text.replace(old, new)
open(dst, "w").write(text)
PY
chmod +x "$MUT10"
TRUTHY_T3="$WORK/truthy-terminal.jsonl"
cat > "$TRUTHY_T3" <<EOF
{"ts":"$T200","event":"dispatch","claim":"c","role":"reviewer","agent":"t3","pr":7140,"issue":714}
{"ts":"$T150","event":"stall","claim":"c","agent":"t3","reason":"looked idle","terminal":"false"}
EOF
outm="$(bash "$MUT10" 60 "$TRUTHY_T3" 2>/dev/null)" || true
! echo "$outm" | grep -q 't3' \
  || report "mutation probe 10: terminal truthiness reverted but stringified terminal:\"false\" still correctly left the leg open (guard not load-bearing / probe broken)"

# Probe 11 (round 1 F2): revert the required-reason check back to no check
# at all -> the reason-less terminal stall (t4) must now wrongly close the
# leg.
MUT11="$MUT_DIR/no-reason-required.sh"
python3 - "$SCRIPT" "$MUT11" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
text = open(src).read()
old = '''        | map(select(
            (.last.event != "stall")
            or (.last.terminal != true)
            or ((.last | has_reason) | not)
          ))
'''
assert old in text, "pattern not found for mutation probe 11"
new = '''        | map(select(
            (.last.event != "stall") or (.last.terminal != true)
          ))
'''
text = text.replace(old, new)
open(dst, "w").write(text)
PY
chmod +x "$MUT11"
outm="$(bash "$MUT11" 60 "$REASONLESS" 2>/dev/null)" || true
! echo "$outm" | grep -q 't4' \
  || report "mutation probe 11: required-reason check removed but reason-less terminal stall (t4) still correctly left the leg open (guard not load-bearing / probe broken)"

if [ "$fail" -eq 0 ]; then
  echo "test_stall_check: all assertions passed"
  exit 0
else
  exit 1
fi
