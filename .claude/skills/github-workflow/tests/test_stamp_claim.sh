#!/usr/bin/env bash
# test_stamp_claim.sh — fixture-driven regression test for stamp-claim.sh.
# Follows the mock-`gh` harness conventions in tests/README.md: a mocked `gh`
# binary on PATH serves fixture JSON from a private mktemp scratch dir, and
# no real network call is ever reachable. Pinned to LANG=C / LC_ALL=C —
# nothing in stamp-claim.sh's own parsing is locale-sensitive, and pinning
# here catches a future regression that would make it so.
#
# Unlike preflight.sh, stamp-claim.sh is a WRITER: it issues a GraphQL
# mutation on every non-refused verb. The mock here records every mutation
# call it sees (to $OUT/mutations.log) so a refusal path can be proven to
# have issued none — a test that only checks the exit code hasn't proven the
# refusal-before-mutation contract. The mock additionally records each
# mutation's full -F payload (project/item/field/value) to
# $OUT/mutations.log, one JSON object per line, so a test can assert the ids
# that actually reached the mutation match the ids the script parsed out of
# the work-tracking fixture — not just that a mutation happened.
#
# Covers (per issue #261's Acceptance Criteria and claims.md):
#  - take: happy path on an empty claim; happy path taking over a stale
#    claim (logs superseded, and the stderr epic-comment reminder); refusal
#    on a live foreign claim, with zero mutation calls recorded; idempotent
#    no-op (zero mutations, applied:false, exit 0) when the live claim is
#    already mine.
#  - exit codes are pinned exactly, not merely as "non-zero": 3 = a
#    business-rule refusal (live foreign claim, takeover with nothing to
#    take over, refresh/release of a claim that is not mine), 1 = a hard
#    failure (here: the item is not on the board, so there is no field to
#    read or write). A caller acts on that difference — `home-deferred.sh`
#    skips a record on 3 and REJECTS it, flipping its own exit code, on
#    anything else — so a reworded message must not be able to change it.
#  - takeover: happy path on a stale claim (logs superseded, and the stderr
#    epic-comment reminder); refusal when the field is empty; refusal on a
#    live claim.
#  - refresh: happy path when the current claim is mine; refusal when it is
#    someone else's (live or stale — refresh never overrides mismatched id).
#  - release: happy path clearing my own claim; idempotent no-op when
#    already empty (issue #321 — zero mutations, applied:false, exit 0);
#    refusal on someone else's claim.
#  - stamp: unconditional write regardless of the current value, logging a
#    `claim-stamp` event instead of `claim` or `dispatch` (issue #322 — kept
#    distinct from the orchestrator's own `dispatch` event so a wired-up
#    script never double-counts it).
#  - --log appends exactly one JSON line accepted by
#    `jq -e '.event and .claim and .ts'`; without --log the line goes to
#    stderr, never stdout.
#  - an UNWRITABLE --log path exits 4, NOT 1: the mutation has already
#    landed by then, so a log failure must never be reportable as a failed
#    claim (round-2 F1). The success JSON is still the last stdout line and
#    the lost log line is echoed to stderr.
#
# Exit-code diagnostics capture the status into RC before reporting: `$?`
# inside `if ! cmd; then` is the negated condition's status (always 0) and
# would make every "got ..." message lie (round-2 F2).
#  - board/field ids are parsed from a work-tracking.md fixture, never
#    hard-coded — a second fixture (WT2) with different ids, run through
#    `take`, proves the mutation payload tracks whichever fixture was
#    supplied rather than a value baked into the script. Every mutation
#    assertion below also checks the parsed ids, the item id AND the written
#    value against the fixture (issue #335 — not just the two ids), so a
#    hard-coded id in the script or a wrong value written to the right ids
#    would fail loudly (reviewer's probe, reproduced at the bottom of this
#    file: hard-coding FIELD_ID in the script turns this suite red).
#  - a `committed` timeline event with a null `created_at` (GitHub's real
#    shape for that event — the date lives under `committer.date` instead)
#    is tolerated rather than aborting `is_stale` (issue #319): counted via
#    the `committer.date` fallback when present, silently skipped when
#    absent, either way never a crash.
set -euo pipefail
export LANG=C LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STAMP_CLAIM_SH="$SCRIPT_DIR/../scripts/stamp-claim.sh"
STALL_CHECK_SH="$SCRIPT_DIR/../scripts/stall-check.sh"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/stamp-claim-test.XXXXXX")"
cleanup(){ rm -rf "$WORK"; }
trap cleanup EXIT

FIXTURES="$WORK/fixtures"
BIN="$WORK/bin"
OUT="$WORK/out"
mkdir -p "$FIXTURES" "$BIN" "$OUT"

REPO="test-org/test-repo"
ITEM=42
OFFBOARD_ITEM=999   # never has a project item in the mock: the hard-failure case
PROJECT_ID="PVT_test123"
FIELD_ID="PVTF_test456"
ITEM_ID="PVTI_itemABC"
ME="test-01"

fail=0
report(){ echo "FAIL: $*" >&2; fail=1; }

# ---------------------------------------------------------------------------
# work-tracking.md fixture: a minimal ids table shaped like the real one,
# with deliberately distinctive ids so a test that accidentally hard-coded
# the real repo's ids would fail loudly.
# ---------------------------------------------------------------------------
WT="$WORK/work-tracking.md"
cat > "$WT" <<DOC
# Work tracking

| Field | Id |
|---|---|
| Project | \`$PROJECT_ID\` |
| Status | \`PVTSSF_test\` |
| Claimed by | \`$FIELD_ID\` |
DOC

# ---------------------------------------------------------------------------
# Mock gh: routes `api graphql` (read query vs mutation, distinguished by
# whether the query text contains "mutation") and the REST timeline
# endpoint. Every graphql call is appended to calls.log; every mutation call
# is additionally appended to mutations.log so a refusal test can assert
# zero mutations were issued. The current claim value served by the read
# query is controlled by $MOCK_GH_FIELD_VALUE (set per test).
# ---------------------------------------------------------------------------
cat > "$BIN/gh" <<'MOCKGH'
#!/usr/bin/env bash
set -euo pipefail
# Hermeticity tripwire (#568, following tests/README.md's convention and
# #477): every invocation is logged before anything else happens, and one
# arriving without the per-run harness env (MOCK_GH_CALLS/MOCK_GH_MUTATIONS/
# MOCK_GH_PROJECT_ID/MOCK_GH_ITEM_ID, set only by run_stamp_claim()) is
# recorded as UNMOCKED-CONTEXT instead of silently reaching the real,
# authenticated gh.
: "${MOCK_GH_CALL_LOG:?MOCK_GH_CALL_LOG must be set}"
printf 'CALL gh %s\n' "$*" >> "$MOCK_GH_CALL_LOG"
if [ -z "${MOCK_GH_CALLS:-}" ] || [ -z "${MOCK_GH_MUTATIONS:-}" ] \
  || [ -z "${MOCK_GH_PROJECT_ID:-}" ] || [ -z "${MOCK_GH_ITEM_ID:-}" ]; then
  printf 'UNMOCKED-CONTEXT gh %s\n' "$*" >> "$MOCK_GH_CALL_LOG"
  echo "mock gh: invoked with no MOCK_GH_CALLS/MOCK_GH_MUTATIONS/MOCK_GH_PROJECT_ID/MOCK_GH_ITEM_ID -- unmocked call context" >&2
  exit 1
fi
: "${MOCK_GH_CALLS:?MOCK_GH_CALLS must be set}"
: "${MOCK_GH_MUTATIONS:?MOCK_GH_MUTATIONS must be set}"
: "${MOCK_GH_PROJECT_ID:?}"
: "${MOCK_GH_ITEM_ID:?}"
: "${MOCK_GH_FIELD_VALUE-}"
: "${MOCK_GH_TIMELINE:-}"

if [ "${1:-}" = "repo" ] && [ "${2:-}" = "view" ]; then
  echo "mock gh: repo view should not be called when --repo is passed" >&2
  exit 1
fi

if [ "${1:-}" = "api" ] && [ "${2:-}" = "graphql" ]; then
  echo "graphql-call" >> "$MOCK_GH_CALLS"
  shift 2
  query=""
  jq_expr=""
  f_project=""; f_item=""; f_field=""; f_value=""; f_number=""
  while [ $# -gt 0 ]; do
    case "$1" in
      -f) if [[ "$2" == query=* ]]; then query="${2#query=}"; fi; shift 2 ;;
      --jq) jq_expr="$2"; shift 2 ;;
      -F)
        case "$2" in
          project=*) f_project="${2#project=}" ;;
          item=*) f_item="${2#item=}" ;;
          field=*) f_field="${2#field=}" ;;
          value=*) f_value="${2#value=}" ;;
          number=*) f_number="${2#number=}" ;;
        esac
        shift 2 ;;
      *) shift ;;
    esac
  done
  if printf '%s' "$query" | grep -q 'mutation('; then
    jq -nc --arg project "$f_project" --arg item "$f_item" --arg field "$f_field" --arg value "$f_value" \
      '{project:$project, item:$item, field:$field, value:$value}' >> "$MOCK_GH_MUTATIONS"
    resp=$(jq -nc --arg id "$MOCK_GH_ITEM_ID" '{data:{updateProjectV2ItemFieldValue:{projectV2Item:{id:$id}}}}')
  else
    if [ -n "${MOCK_GH_OFFBOARD_ITEM:-}" ] && [ "$f_number" = "${MOCK_GH_OFFBOARD_ITEM:-}" ]; then
      # Not on the board at all — no project item, so no `Claimed by` field.
      resp='{"data":{"repository":{"issue":{"projectItems":{"nodes":[]}}}}}'
    else
      resp=$(jq -nc --arg pid "$MOCK_GH_PROJECT_ID" --arg iid "$MOCK_GH_ITEM_ID" --arg val "${MOCK_GH_FIELD_VALUE-}" \
        '{data:{repository:{issue:{projectItems:{nodes:[
          {id:$iid, project:{id:$pid}, fieldValueByName:(if $val=="" then null else {text:$val} end)}
        ]}}}}}')
    fi
  fi
  if [ -n "$jq_expr" ]; then
    jq -c -r "$jq_expr" <<<"$resp"
  else
    printf '%s\n' "$resp"
  fi
  exit 0
fi

if [ "${1:-}" = "api" ]; then
  shift
  endpoint=""
  jq_expr=""
  paginate=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --paginate) paginate=1; shift ;;
      --jq) jq_expr="$2"; shift 2 ;;
      -X|--method) echo "mock gh: refusing non-GET method ($2) on a REST endpoint" >&2; exit 1 ;;
      *) endpoint="$1"; shift ;;
    esac
  done
  case "$endpoint" in
    repos/*/issues/*/timeline\?per_page=100)
      [ -n "$paginate" ] # silence unused-var lint in some shells
      src="$MOCK_GH_TIMELINE"
      if [ -z "$src" ] || [ ! -f "$src" ]; then
        src="$(mktemp)"; echo "[]" > "$src"
      fi
      if [ -n "$jq_expr" ]; then jq -c -r "$jq_expr" "$src"; else cat "$src"; fi
      ;;
    *)
      echo "mock gh: unknown endpoint: $endpoint" >&2
      exit 1 ;;
  esac
  exit 0
fi

echo "mock gh: unsupported command: $*" >&2
exit 1
MOCKGH
chmod +x "$BIN/gh"

export MOCK_GH_CALL_LOG="$OUT/gh-calls.log"
: > "$MOCK_GH_CALL_LOG"

run_stamp_claim(){ # run_stamp_claim <field-value> <timeline-fixture-or-empty> <args...>
  local field_value="$1" timeline="$2"; shift 2
  : > "$OUT/calls.log"
  : > "$OUT/mutations.log"
  local rc=0
  set +e
  MOCK_GH_CALLS="$OUT/calls.log" MOCK_GH_MUTATIONS="$OUT/mutations.log" \
    MOCK_GH_PROJECT_ID="$PROJECT_ID" MOCK_GH_ITEM_ID="$ITEM_ID" \
    MOCK_GH_FIELD_VALUE="$field_value" MOCK_GH_TIMELINE="$timeline" \
    MOCK_GH_OFFBOARD_ITEM="$OFFBOARD_ITEM" \
    PATH="$BIN:$PATH" \
    "$STAMP_CLAIM_SH" "$@" --repo "$REPO" --work-tracking "$WT" \
    > "$OUT/run.stdout.log" 2> "$OUT/run.stderr.log"
  rc=$?
  set -e
  return $rc
}
n_mutations(){ wc -l < "$OUT/mutations.log" | tr -d ' '; }

# rc_of <expected-rc> <label> <args to run_stamp_claim...> — asserts the
# exact exit code, not merely "non-zero". The 3-vs-1 split (business-rule
# refusal vs hard failure) is a machine-readable contract callers act on —
# `home-deferred.sh` skips a record on 3 and REJECTS it on anything else —
# so it is pinned here rather than left to a caller grepping prose.
rc_of(){
  local want="$1" label="$2"; shift 2
  local rc=0
  run_stamp_claim "$@" || rc=$?
  [ "$rc" = "$want" ] || report "$label: expected exit $want, got $rc — stderr: $(cat "$OUT/run.stderr.log")"
}

# assert_mutation_ids <label> <expected-project-id> <expected-field-id>
#                      <expected-item-id> <expected-value-glob> —
# checks the last recorded mutation's payload carries exactly the parsed
# project/field/item ids (not a hard-coded value baked into the script) AND
# the value actually written, matched against a glob (a timestamp-bearing
# value like "$ME @ <now>" cannot be pinned exactly, so callers pass "$ME
# @"'*'). This is the drift guard: without the id checks, a hard-coded
# FIELD_ID in stamp-claim.sh would leave the suite green (see the FIELD_ID
# probe at the bottom of this file); without the value check, a mutation
# that wrote the WRONG text to the right ids would also leave it green — the
# round-1 review's required change named "the fixture's PROJECT_ID/FIELD_ID
# and the expected value" (issue #335), and only checking .after on stdout
# is not equivalent to checking what was actually sent to the mutation.
assert_mutation_ids(){
  local label="$1" exp_project="$2" exp_field="$3" exp_item="$4" exp_value_glob="$5" mut val
  mut=$(tail -1 "$OUT/mutations.log")
  [ "$(jq -r .project <<<"$mut")" = "$exp_project" ] \
    || report "$label: mutation project id mismatch — expected $exp_project, got: $mut"
  [ "$(jq -r .field <<<"$mut")" = "$exp_field" ] \
    || report "$label: mutation field id mismatch — expected $exp_field, got: $mut"
  [ "$(jq -r .item <<<"$mut")" = "$exp_item" ] \
    || report "$label: mutation item id mismatch — expected $exp_item, got: $mut"
  val=$(jq -r .value <<<"$mut")
  # shellcheck disable=SC2254 # the glob is intentional, not a literal case pattern to quote
  case "$val" in
    $exp_value_glob) : ;;
    *) report "$label: mutation value mismatch — expected to match '$exp_value_glob', got: $mut" ;;
  esac
}

# ---------------------------------------------------------------------------
# take: empty claim -> happy path, one mutation, no superseded.
# ---------------------------------------------------------------------------
RC=0; run_stamp_claim "" "" take --item "$ITEM" --id "$ME" || RC=$?
if [ "$RC" -ne 0 ]; then
  report "take (empty): expected exit 0, got $RC — stderr: $(cat "$OUT/run.stderr.log")"
fi
[ "$(n_mutations)" = "1" ] || report "take (empty): expected exactly 1 mutation, got $(n_mutations)"
assert_mutation_ids "take (empty)" "$PROJECT_ID" "$FIELD_ID" "$ITEM_ID" "$ME @"'*'
if jq -e . "$OUT/run.stdout.log" >/dev/null 2>&1; then
  [ "$(jq -r .applied "$OUT/run.stdout.log")" = "true" ] || report "take (empty): expected applied=true"
  [ "$(jq -r .superseded "$OUT/run.stdout.log")" = "null" ] || report "take (empty): expected superseded=null"
  [[ "$(jq -r .after "$OUT/run.stdout.log")" == "$ME @"* ]] || report "take (empty): expected after to start with '$ME @', got $(jq -r .after "$OUT/run.stdout.log")"
else
  report "take (empty): stdout is not valid JSON: $(cat "$OUT/run.stdout.log")"
fi

# ---------------------------------------------------------------------------
# take: live foreign claim (fresh timestamp, well within 24h) -> refusal,
# zero mutations.
# ---------------------------------------------------------------------------
LIVE_TS=$(date -u -d '1 hour ago' +%Y-%m-%dT%H:%MZ)
if run_stamp_claim "other-07 @ $LIVE_TS" "" take --item "$ITEM" --id "$ME"; then
  report "take (live foreign): expected non-zero exit, got 0"
fi
[ "$(n_mutations)" = "0" ] || report "take (live foreign): expected zero mutations on refusal, got $(n_mutations)"
grep -qi 'live claim' "$OUT/run.stderr.log" || report "take (live foreign): expected a live-claim refusal message, got: $(cat "$OUT/run.stderr.log")"
rc_of 3 "take (live foreign) exit code" "other-07 @ $LIVE_TS" "" take --item "$ITEM" --id "$ME"

# ---------------------------------------------------------------------------
# take: the claim is already MINE and live -> idempotent no-op. Zero
# mutations, applied:false, exit 0 — the machine-readable signal a caller
# needs to tell "I already hold this" from "someone else holds this",
# without matching a refusal message (issue #262 round 1, F8).
# ---------------------------------------------------------------------------
RC=0; run_stamp_claim "$ME @ $LIVE_TS" "" take --item "$ITEM" --id "$ME" || RC=$?
if [ "$RC" -ne 0 ]; then
  report "take (already mine, live): expected exit 0, got $RC — stderr: $(cat "$OUT/run.stderr.log")"
fi
[ "$(n_mutations)" = "0" ] || report "take (already mine, live): expected zero mutations (nothing to change), got $(n_mutations)"
[ "$(jq -r .applied "$OUT/run.stdout.log")" = "false" ] || report "take (already mine, live): expected applied=false, got: $(cat "$OUT/run.stdout.log")"
[ "$(jq -r .after "$OUT/run.stdout.log")" = "$ME @ $LIVE_TS" ] || report "take (already mine, live): expected the claim value left untouched, got: $(cat "$OUT/run.stdout.log")"
grep -qi 'no-op' "$OUT/run.stderr.log" || report "take (already mine, live): expected a no-op note on stderr, got: $(cat "$OUT/run.stderr.log")"

# ---------------------------------------------------------------------------
# take: stale claim (>24h old, no activity since) -> happy path, superseded
# carries the old id.
# ---------------------------------------------------------------------------
STALE_TS=$(date -u -d '48 hours ago' +%Y-%m-%dT%H:%MZ)
RC=0; run_stamp_claim "other-08 @ $STALE_TS" "" take --item "$ITEM" --id "$ME" || RC=$?
if [ "$RC" -ne 0 ]; then
  report "take (stale): expected exit 0, got $RC — stderr: $(cat "$OUT/run.stderr.log")"
fi
[ "$(n_mutations)" = "1" ] || report "take (stale): expected exactly 1 mutation, got $(n_mutations)"
assert_mutation_ids "take (stale)" "$PROJECT_ID" "$FIELD_ID" "$ITEM_ID" "$ME @"'*'
[ "$(jq -r .superseded "$OUT/run.stdout.log")" = "other-08" ] || report "take (stale): expected superseded=other-08, got: $(cat "$OUT/run.stdout.log")"
grep -qi 'event comment on the epic' "$OUT/run.stderr.log" \
  || report "take (stale): expected an epic-event-comment reminder on stderr, got: $(cat "$OUT/run.stderr.log")"

# ---------------------------------------------------------------------------
# take: old timestamp (>24h) but WITH activity since -> not stale -> refusal.
# ---------------------------------------------------------------------------
ACTIVITY_AFTER=$(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ)
TIMELINE="$WORK/timeline_active.json"
printf '[{"event":"commented","created_at":"%s"}]\n' "$ACTIVITY_AFTER" > "$TIMELINE"
if run_stamp_claim "other-09 @ $STALE_TS" "$TIMELINE" take --item "$ITEM" --id "$ME"; then
  report "take (old but active): expected non-zero exit, got 0"
fi
[ "$(n_mutations)" = "0" ] || report "take (old but active): expected zero mutations on refusal, got $(n_mutations)"
rc_of 3 "take (old but active) exit code" "other-09 @ $STALE_TS" "$TIMELINE" take --item "$ITEM" --id "$ME"

# ---------------------------------------------------------------------------
# take: timeline carries a `committed` event with a null `created_at` (real
# GitHub behaviour — the date lives under `committer.date` instead). Must
# not abort `is_stale` (issue #319): a null `created_at` is skipped by the
# activity filter rather than crashing `fromdate` on `null`.
#
# Sub-case A — the committed event's `committer.date` IS recent: counted as
# real activity via that fallback field, so the old timestamp is NOT stale
# -> refusal, zero mutations.
# ---------------------------------------------------------------------------
TIMELINE_COMMITTED_RECENT="$WORK/timeline_committed_recent.json"
printf '[{"event":"committed","created_at":null,"committer":{"date":"%s"}}]\n' "$ACTIVITY_AFTER" \
  > "$TIMELINE_COMMITTED_RECENT"
if run_stamp_claim "other-14 @ $STALE_TS" "$TIMELINE_COMMITTED_RECENT" take --item "$ITEM" --id "$ME"; then
  report "take (committed, null created_at, recent committer.date): expected non-zero exit, got 0"
fi
[ "$(n_mutations)" = "0" ] || report "take (committed, null created_at, recent committer.date): expected zero mutations, got $(n_mutations)"
rc_of 3 "take (committed, null created_at, recent committer.date) exit code" \
  "other-14 @ $STALE_TS" "$TIMELINE_COMMITTED_RECENT" take --item "$ITEM" --id "$ME"

# ---------------------------------------------------------------------------
# Sub-case B — the committed event has NEITHER `created_at` NOR
# `committer.date` (fully null): the null tolerance must skip it rather than
# aborting jq, and with no other activity the old claim IS stale -> happy
# path, one mutation.
# ---------------------------------------------------------------------------
TIMELINE_COMMITTED_NULL="$WORK/timeline_committed_null.json"
printf '[{"event":"committed","created_at":null}]\n' > "$TIMELINE_COMMITTED_NULL"
RC=0; run_stamp_claim "other-15 @ $STALE_TS" "$TIMELINE_COMMITTED_NULL" take --item "$ITEM" --id "$ME" || RC=$?
if [ "$RC" -ne 0 ]; then
  report "take (committed, fully null): expected exit 0 (tolerated, treated as stale), got $RC — stderr: $(cat "$OUT/run.stderr.log")"
fi
[ "$(n_mutations)" = "1" ] || report "take (committed, fully null): expected exactly 1 mutation, got $(n_mutations)"
[ "$(jq -r .superseded "$OUT/run.stdout.log")" = "other-15" ] || report "take (committed, fully null): expected superseded=other-15, got: $(cat "$OUT/run.stdout.log")"

# A hard failure is NOT a refusal: the item is not on the board at all, so
# there is no `Claimed by` field to read or write. Exit 1, never 3.
rc_of 1 "take (item not on the board) exit code" "" "" take --item "$OFFBOARD_ITEM" --id "$ME"
[ "$(n_mutations)" = "0" ] || report "take (item not on the board): expected zero mutations, got $(n_mutations)"
grep -qi 'no project item' "$OUT/run.stderr.log" || report "take (item not on the board): expected an off-board hard-failure message, got: $(cat "$OUT/run.stderr.log")"

# ---------------------------------------------------------------------------
# takeover: refuses on an empty field (nothing to take over).
# ---------------------------------------------------------------------------
if run_stamp_claim "" "" takeover --item "$ITEM" --id "$ME"; then
  report "takeover (empty): expected non-zero exit, got 0"
fi
[ "$(n_mutations)" = "0" ] || report "takeover (empty): expected zero mutations, got $(n_mutations)"
rc_of 3 "takeover (empty) exit code" "" "" takeover --item "$ITEM" --id "$ME"

# ---------------------------------------------------------------------------
# takeover: refuses on a live claim.
# ---------------------------------------------------------------------------
if run_stamp_claim "other-10 @ $LIVE_TS" "" takeover --item "$ITEM" --id "$ME"; then
  report "takeover (live): expected non-zero exit, got 0"
fi
[ "$(n_mutations)" = "0" ] || report "takeover (live): expected zero mutations, got $(n_mutations)"
rc_of 3 "takeover (live) exit code" "other-10 @ $LIVE_TS" "" takeover --item "$ITEM" --id "$ME"

# ---------------------------------------------------------------------------
# takeover: happy path on a stale claim, logs superseded.
# ---------------------------------------------------------------------------
RC=0; run_stamp_claim "other-11 @ $STALE_TS" "" takeover --item "$ITEM" --id "$ME" || RC=$?
if [ "$RC" -ne 0 ]; then
  report "takeover (stale): expected exit 0, got $RC — stderr: $(cat "$OUT/run.stderr.log")"
fi
[ "$(n_mutations)" = "1" ] || report "takeover (stale): expected exactly 1 mutation, got $(n_mutations)"
assert_mutation_ids "takeover (stale)" "$PROJECT_ID" "$FIELD_ID" "$ITEM_ID" "$ME @"'*'
[ "$(jq -r .superseded "$OUT/run.stdout.log")" = "other-11" ] || report "takeover (stale): expected superseded=other-11, got: $(cat "$OUT/run.stdout.log")"
grep -qi 'event comment on the epic' "$OUT/run.stderr.log" \
  || report "takeover (stale): expected an epic-event-comment reminder on stderr, got: $(cat "$OUT/run.stderr.log")"

# ---------------------------------------------------------------------------
# refresh: happy path when current claim is mine (even if it were stale,
# refresh only checks identity — no staleness gate).
# ---------------------------------------------------------------------------
RC=0; run_stamp_claim "$ME @ $STALE_TS" "" refresh --item "$ITEM" --id "$ME" || RC=$?
if [ "$RC" -ne 0 ]; then
  report "refresh (mine): expected exit 0, got $RC — stderr: $(cat "$OUT/run.stderr.log")"
fi
[ "$(n_mutations)" = "1" ] || report "refresh (mine): expected exactly 1 mutation, got $(n_mutations)"
assert_mutation_ids "refresh (mine)" "$PROJECT_ID" "$FIELD_ID" "$ITEM_ID" "$ME @"'*'
[[ "$(jq -r .after "$OUT/run.stdout.log")" == "$ME @"* ]] || report "refresh (mine): expected refreshed value to start with '$ME @'"

# ---------------------------------------------------------------------------
# refresh: refusal on someone else's claim (live or stale — identity only).
# ---------------------------------------------------------------------------
if run_stamp_claim "other-12 @ $LIVE_TS" "" refresh --item "$ITEM" --id "$ME"; then
  report "refresh (not mine): expected non-zero exit, got 0"
fi
[ "$(n_mutations)" = "0" ] || report "refresh (not mine): expected zero mutations, got $(n_mutations)"
rc_of 3 "refresh (not mine) exit code" "other-12 @ $LIVE_TS" "" refresh --item "$ITEM" --id "$ME"

# ---------------------------------------------------------------------------
# release: happy path clearing my own claim.
# ---------------------------------------------------------------------------
RC=0; run_stamp_claim "$ME @ $LIVE_TS" "" release --item "$ITEM" --id "$ME" || RC=$?
if [ "$RC" -ne 0 ]; then
  report "release (mine): expected exit 0, got $RC — stderr: $(cat "$OUT/run.stderr.log")"
fi
[ "$(n_mutations)" = "1" ] || report "release (mine): expected exactly 1 mutation, got $(n_mutations)"
assert_mutation_ids "release (mine)" "$PROJECT_ID" "$FIELD_ID" "$ITEM_ID" ""
[ "$(jq -r .after "$OUT/run.stdout.log")" = "" ] || report "release (mine): expected after='', got: $(cat "$OUT/run.stdout.log")"

# ---------------------------------------------------------------------------
# release: idempotent no-op when already empty (issue #321) — no mutation is
# issued (the field would be written "" over "", a wasted board write), the
# script still exits 0, and stdout reports applied:false.
# ---------------------------------------------------------------------------
RC=0; run_stamp_claim "" "" release --item "$ITEM" --id "$ME" || RC=$?
if [ "$RC" -ne 0 ]; then
  report "release (already empty): expected exit 0, got $RC — stderr: $(cat "$OUT/run.stderr.log")"
fi
[ "$(n_mutations)" = "0" ] || report "release (already empty): expected zero mutations (idempotent no-op), got $(n_mutations)"
[ "$(jq -r .applied "$OUT/run.stdout.log")" = "false" ] || report "release (already empty): expected applied=false"
grep -qi 'no-op' "$OUT/run.stderr.log" || report "release (already empty): expected a no-op note on stderr, got: $(cat "$OUT/run.stderr.log")"

# ---------------------------------------------------------------------------
# release: refusal on someone else's claim.
# ---------------------------------------------------------------------------
if run_stamp_claim "other-13 @ $LIVE_TS" "" release --item "$ITEM" --id "$ME"; then
  report "release (not mine): expected non-zero exit, got 0"
fi
[ "$(n_mutations)" = "0" ] || report "release (not mine): expected zero mutations, got $(n_mutations)"
rc_of 3 "release (not mine) exit code" "other-13 @ $LIVE_TS" "" release --item "$ITEM" --id "$ME"

# ---------------------------------------------------------------------------
# stamp: unconditional write over a live foreign value (informational stamp,
# no coordination check) — logs a `claim-stamp` event, not `claim` or
# `dispatch` (issue #322: kept distinct from the orchestrator's own
# `dispatch` event so a wired-up script never double-counts it).
# ---------------------------------------------------------------------------
LOG_FILE="$WORK/session.jsonl"
RC=0; run_stamp_claim "someone-else @ $LIVE_TS" "" stamp --item "$ITEM" --id "$ME" --log "$LOG_FILE" || RC=$?
if [ "$RC" -ne 0 ]; then
  report "stamp: expected exit 0, got $RC — stderr: $(cat "$OUT/run.stderr.log")"
fi
[ "$(n_mutations)" = "1" ] || report "stamp: expected exactly 1 mutation, got $(n_mutations)"
assert_mutation_ids "stamp" "$PROJECT_ID" "$FIELD_ID" "$ITEM_ID" "$ME @"'*'' (stamp)'
[[ "$(jq -r .after "$OUT/run.stdout.log")" == "$ME @"* ]] || report "stamp: expected after to start with '$ME @'"
# Issue #744: the written value MUST carry the literal trailing ' (stamp)'
# marker — the sole discriminator the concurrent-session check reads. A
# fixture that only checked the "$ME @"* prefix (as this test did before
# #744) cannot tell a marked write from an unmarked one; this splice-tested
# assertion (see the F744 splice probe near the end of this file) can.
[[ "$(jq -r .after "$OUT/run.stdout.log")" == *' (stamp)' ]] \
  || report "stamp (#744 marker): expected 'after' to end with the literal ' (stamp)' marker, got: $(jq -r .after "$OUT/run.stdout.log")"
# Issue #771: the fixture above ("someone-else @ $LIVE_TS", a live,
# UNMARKED lock — indistinguishable from a genuine standalone coordination
# claim someone else is solo-working) already pins the decision #771 made:
# `stamp` stays unconditional even here. #771 found that, since #744 gave
# the stamp a marker, this same clobber now leaves a value ("$ME @ <ts>
# (stamp)") that a later `take` treats exactly like an empty field — so the
# reduction in defence-in-depth #771 describes is real and is exactly what
# this assertion already exercises end to end: the write happens (1
# mutation, exit 0, asserted above) and the result carries the marker
# (asserted above). #771 concluded this stays a documented design property
# (claims.md's Script subsection now names the standalone case explicitly,
# not just the epic case) rather than a bug to fix in `stamp` itself — see
# claims.md for the reasoning — so this fixture's job is to pin that chosen
# behaviour: an accidental future live/stale check added to `stamp` would
# turn this into a refusal (exit 3) or a different mutation count, and
# this assertion would catch it.
RC=0; run_stamp_claim "someone-else @ $LIVE_TS" "" stamp --item "$ITEM" --id "$ME" || RC=$?
[ "$RC" -eq 0 ] \
  || report "stamp over live standalone lock (#771): expected exit 0 (unconditional write, by design), got $RC — stderr: $(cat "$OUT/run.stderr.log")"
[ "$(n_mutations)" = "1" ] \
  || report "stamp over live standalone lock (#771): expected exactly 1 mutation (unconditional write), got $(n_mutations)"

# ---------------------------------------------------------------------------
# Issue #744 — the acceptance scenario: a board holding BOTH a live
# standalone coordination lock AND a set of standalone dispatch stamps, and
# the two are told apart mechanically by the marker alone, with no parent
# and no handoff read. Fixture values below are shaped exactly like the 28
# `storage-03 @ 2026-09-05T10:1{4,5,6}Z` stamps the motivating incident
# describes, now written in the post-#744 marked form, alongside one
# genuinely live standalone lock with no marker at all — both under two
# hours old, so the OLD (pre-#744) rule of "standalone means lock" would
# have misjudged every stamped one.
# ---------------------------------------------------------------------------
LIVE_LOCK_VALUE="storage-03 @ $LIVE_TS"
LIVE_STAMP_VALUE="storage-03 @ $LIVE_TS (stamp)"

# take: a marked stamp is never a live claim to refuse on — `take` succeeds
# exactly as it would on an empty field (no superseded id: nothing
# coordination-level was overtaken).
RC=0; run_stamp_claim "$LIVE_STAMP_VALUE" "" take --item "$ITEM" --id "$ME" || RC=$?
if [ "$RC" -ne 0 ]; then
  report "take (over a live-looking stamp, #744): expected exit 0 (a stamp is never a lock), got $RC — stderr: $(cat "$OUT/run.stderr.log")"
fi
[ "$(n_mutations)" = "1" ] || report "take (over a live-looking stamp, #744): expected exactly 1 mutation, got $(n_mutations)"
[ "$(jq -r .superseded "$OUT/run.stdout.log")" = "null" ] \
  || report "take (over a live-looking stamp, #744): expected superseded=null (a stamp is not a coordination claim to supersede), got: $(cat "$OUT/run.stdout.log")"
[[ "$(jq -r .after "$OUT/run.stdout.log")" == "$ME @"* ]] && [[ "$(jq -r .after "$OUT/run.stdout.log")" != *' (stamp)' ]] \
  || report "take (over a live-looking stamp, #744): expected a fresh UNMARKED lock value, got: $(jq -r .after "$OUT/run.stdout.log")"

# The same value, by contrast, WITHOUT the marker, at the same age, is a
# genuine live foreign lock — `take` must still refuse it. This is the
# negative half of the same fixture pair: it proves the refusal above was
# because of the marker, not because `take` stopped checking staleness.
if run_stamp_claim "$LIVE_LOCK_VALUE" "" take --item "$ITEM" --id "$ME"; then
  report "take (live lock, no marker, #744 near-miss): expected non-zero exit, got 0"
fi
[ "$(n_mutations)" = "0" ] || report "take (live lock, no marker, #744 near-miss): expected zero mutations, got $(n_mutations)"
rc_of 3 "take (live lock, no marker, #744 near-miss) exit code" "$LIVE_LOCK_VALUE" "" take --item "$ITEM" --id "$ME"

# takeover: a marked stamp refuses exactly like an empty field — nothing to
# take over — never treated as a live-or-stale coordination claim.
if run_stamp_claim "$LIVE_STAMP_VALUE" "" takeover --item "$ITEM" --id "$ME"; then
  report "takeover (over a stamp, #744): expected non-zero exit, got 0"
fi
[ "$(n_mutations)" = "0" ] || report "takeover (over a stamp, #744): expected zero mutations, got $(n_mutations)"
rc_of 3 "takeover (over a stamp, #744) exit code" "$LIVE_STAMP_VALUE" "" takeover --item "$ITEM" --id "$ME"

# refresh: a marked stamp, even one that carries MY OWN id, refuses — a
# stamp is never mine-as-a-coordination-claim to refresh.
if run_stamp_claim "$ME @ $LIVE_TS (stamp)" "" refresh --item "$ITEM" --id "$ME"; then
  report "refresh (my own stamp, #744): expected non-zero exit, got 0"
fi
[ "$(n_mutations)" = "0" ] || report "refresh (my own stamp, #744): expected zero mutations, got $(n_mutations)"
rc_of 3 "refresh (my own stamp, #744) exit code" "$ME @ $LIVE_TS (stamp)" "" refresh --item "$ITEM" --id "$ME"

# release: same — a marked stamp with my own id refuses release; it is the
# never-cleared ownership ledger, not something `release` clears.
if run_stamp_claim "$ME @ $LIVE_TS (stamp)" "" release --item "$ITEM" --id "$ME"; then
  report "release (my own stamp, #744): expected non-zero exit, got 0"
fi
[ "$(n_mutations)" = "0" ] || report "release (my own stamp, #744): expected zero mutations, got $(n_mutations)"
rc_of 3 "release (my own stamp, #744) exit code" "$ME @ $LIVE_TS (stamp)" "" release --item "$ITEM" --id "$ME"

# ---------------------------------------------------------------------------
# --log: exactly one line, jq -e '.event and .claim and .ts' accepts it, and
# the stamp verb's line carries event=claim-stamp.
# ---------------------------------------------------------------------------
[ -s "$LOG_FILE" ] || report "--log: expected a non-empty log file"
n_lines=$(wc -l < "$LOG_FILE")
[ "$n_lines" = "1" ] || report "--log: expected exactly 1 line, got $n_lines"
if [ -s "$LOG_FILE" ]; then
  logrec=$(tail -1 "$LOG_FILE")
  jq -e '.event and .claim and .ts' <<<"$logrec" >/dev/null 2>&1 \
    || report "--log: line rejected by 'jq -e .event and .claim and .ts': $logrec"
  [ "$(jq -r .event <<<"$logrec")" = "claim-stamp" ] || report "--log (stamp): expected event=claim-stamp, got: $logrec"
  [ "$(jq -r .claim <<<"$logrec")" = "$ME" ] || report "--log (stamp): expected claim=$ME, got: $logrec"
  [ "$(jq -r .issue <<<"$logrec")" = "$ITEM" ] || report "--log (stamp): expected issue=$ITEM, got: $logrec"

  # -------------------------------------------------------------------------
  # Issue #743: pin the emitted ts to formats/session-log.md's exact,
  # second-precision form (YYYY-MM-DDTHH:MM:SSZ) — not merely "jq -e .ts
  # exists", which the pre-#743 minute-precision bug also satisfied. A
  # fixture that only checks presence cannot tell buggy from fixed; see the
  # splice/mutation probe near the end of this file that proves this one can.
  # -------------------------------------------------------------------------
  ts_val="$(jq -r .ts <<<"$logrec")"
  [[ "$ts_val" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] \
    || report "--log (stamp): ts '$ts_val' is not exactly YYYY-MM-DDTHH:MM:SSZ (session-log.md, issue #743)"

  # Round-trip fixture (issue #743): the record stamp-claim.sh actually just
  # wrote to --log must not be skipped by stall-check.sh's ts_ok predicate —
  # a healthy over-limit agent recorded beside it in the same log is still
  # reported, proving the reader consumed the writer's own line rather than
  # discarding it as malformed/unsupported-precision.
  RT_LOG="$WORK/roundtrip.jsonl"
  cp "$LOG_FILE" "$RT_LOG"
  RT_OLD_TS="$(date -u -d '90 minutes ago' +%FT%TZ)"
  printf '%s\n' "{\"ts\":\"$RT_OLD_TS\",\"event\":\"dispatch\",\"claim\":\"c\",\"role\":\"implementer\",\"agent\":\"rt1\",\"pr\":9500,\"issue\":950}" >> "$RT_LOG"
  rt_out="$(bash "$STALL_CHECK_SH" 60 "$RT_LOG" 2>"$WORK/roundtrip-stderr")" && rt_rc=0 || rt_rc=$?
  [ "$rt_rc" -eq 1 ] || report "round-trip: expected exit 1 (rt1 idle over limit), got $rt_rc — stderr: $(cat "$WORK/roundtrip-stderr")"
  echo "$rt_out" | grep -q '^  rt1 dispatch' \
    || report "round-trip: rt1 (healthy, over limit) was not reported alongside stamp-claim.sh's own line"
  grep -qi 'unsupported precision\|malformed' "$WORK/roundtrip-stderr" \
    && report "round-trip: stamp-claim.sh's own --log line was rejected by stall-check.sh's ts_ok: $(cat "$WORK/roundtrip-stderr")"
fi

# ---------------------------------------------------------------------------
# --log: a `claim` verb logs event=claim with action/item/superseded, and
# the same jq acceptance test passes.
# ---------------------------------------------------------------------------
LOG_FILE2="$WORK/session2.jsonl"
RC=0; run_stamp_claim "" "" take --item "$ITEM" --id "$ME" --log "$LOG_FILE2" || RC=$?
if [ "$RC" -ne 0 ]; then
  report "take --log: expected exit 0, got $RC"
fi
logrec2=$(tail -1 "$LOG_FILE2")
jq -e '.event and .claim and .ts' <<<"$logrec2" >/dev/null 2>&1 \
  || report "--log (claim): line rejected by 'jq -e .event and .claim and .ts': $logrec2"
[ "$(jq -r .event <<<"$logrec2")" = "claim" ] || report "--log (claim): expected event=claim, got: $logrec2"
[ "$(jq -r .action <<<"$logrec2")" = "take" ] || report "--log (claim): expected action=take, got: $logrec2"
[ "$(jq -r .item <<<"$logrec2")" = "$ITEM" ] || report "--log (claim): expected item=$ITEM, got: $logrec2"

# ---------------------------------------------------------------------------
# Without --log the event line goes to stderr, never stdout, and stdout
# stays pure JSON.
# ---------------------------------------------------------------------------
RC=0; run_stamp_claim "" "" take --item "$ITEM" --id "$ME" || RC=$?
if [ "$RC" -ne 0 ]; then
  report "take (no --log): expected exit 0, got $RC"
fi
grep -q '"event":"claim"' "$OUT/run.stderr.log" \
  || report "no --log: expected the event line on stderr, got: $(cat "$OUT/run.stderr.log")"
! grep -q '"event":"claim"' "$OUT/run.stdout.log" \
  || report "no --log: the event line must never land on stdout"
jq -e . "$OUT/run.stdout.log" >/dev/null 2>&1 || report "no --log: stdout must still be pure JSON"

# ---------------------------------------------------------------------------
# An UNWRITABLE --log path must not masquerade as a failed claim (issue #262
# round 2, F1). The mutation lands before the log append, so aborting
# non-zero there told a caller reading exit codes ("anything but 3 is a hard
# failure") that nothing was written while the claim sat on the board. The
# contract now: the mutation still happens, the success JSON is still the
# LAST line on stdout, the warning names the success on stderr, and the exit
# code is 4 — its own code, distinct from 1 (hard failure) and 3 (refusal).
# ---------------------------------------------------------------------------
NOWRITE_DIR="$WORK/nowrite"
mkdir -p "$NOWRITE_DIR"
chmod 500 "$NOWRITE_DIR"
BAD_LOG="$NOWRITE_DIR/session.jsonl"
RC=0; run_stamp_claim "" "" take --item "$ITEM" --id "$ME" --log "$BAD_LOG" || RC=$?
[ "$RC" = "4" ] || report "unwritable --log: expected exit 4 (write succeeded, log did not), got $RC — stderr: $(cat "$OUT/run.stderr.log")"
[ "$(n_mutations)" = "1" ] || report "unwritable --log: the claim mutation must still have been issued exactly once, got $(n_mutations)"
[ ! -f "$BAD_LOG" ] || report "unwritable --log: the log file must not exist (the directory is unwritable)"
# stdout carries exactly ONE JSON document — the success object — and
# nothing after it: `jq -s` slurps the whole stream, so length==1 proves the
# success JSON is the last thing printed on stdout.
jq -e -s 'length==1 and .[0].applied==true and .[0].action=="take"' "$OUT/run.stdout.log" >/dev/null 2>&1 \
  || report "unwritable --log: stdout must carry exactly one JSON document — the success object, printed last — got: $(cat "$OUT/run.stdout.log")"
[ "$(tail -1 "$OUT/run.stdout.log")" = "}" ] \
  || report "unwritable --log: the success JSON must be the last thing on stdout, got last line: $(tail -1 "$OUT/run.stdout.log")"
grep -qi 'SUCCEEDED' "$OUT/run.stderr.log" \
  || report "unwritable --log: stderr must say the claim SUCCEEDED, so the caller does not read exit 4 as a lost claim: $(cat "$OUT/run.stderr.log")"
grep -q '"event":"claim"' "$OUT/run.stderr.log" \
  || report "unwritable --log: the log line itself must be echoed to stderr rather than lost: $(cat "$OUT/run.stderr.log")"
chmod 700 "$NOWRITE_DIR"

# ---------------------------------------------------------------------------
# Drift guard: a second work-tracking fixture with DIFFERENT ids from the
# first (WT/PROJECT_ID/FIELD_ID above), run through `take`. If stamp-claim.sh
# ever hard-coded an id instead of parsing --work-tracking, this fixture's
# mutation would carry the FIRST fixture's ids (or fail outright) instead of
# its own — assert_mutation_ids below catches that.
# ---------------------------------------------------------------------------
PROJECT_ID2="PVT_second789"
FIELD_ID2="PVTF_second012"
ITEM_ID2="PVTI_itemXYZ"
WT2="$WORK/work-tracking-2.md"
cat > "$WT2" <<DOC
# Work tracking (second fixture)

| Field | Id |
|---|---|
| Project | \`$PROJECT_ID2\` |
| Status | \`PVTSSF_test2\` |
| Claimed by | \`$FIELD_ID2\` |
DOC

: > "$OUT/calls.log"
: > "$OUT/mutations.log"
set +e
MOCK_GH_CALLS="$OUT/calls.log" MOCK_GH_MUTATIONS="$OUT/mutations.log" \
  MOCK_GH_PROJECT_ID="$PROJECT_ID2" MOCK_GH_ITEM_ID="$ITEM_ID2" \
  MOCK_GH_FIELD_VALUE="" MOCK_GH_TIMELINE="" \
  PATH="$BIN:$PATH" \
  "$STAMP_CLAIM_SH" take --item "$ITEM" --id "$ME" --repo "$REPO" --work-tracking "$WT2" \
  > "$OUT/run.stdout.log" 2> "$OUT/run.stderr.log"
rc=$?
set -e
[ "$rc" -eq 0 ] || report "take (second fixture): expected exit 0, got $rc — stderr: $(cat "$OUT/run.stderr.log")"
[ "$(n_mutations)" = "1" ] || report "take (second fixture): expected exactly 1 mutation, got $(n_mutations)"
assert_mutation_ids "take (second fixture)" "$PROJECT_ID2" "$FIELD_ID2" "$ITEM_ID2" "$ME @"'*'

# ---------------------------------------------------------------------------
# Argument errors: no verb, no --item, no --id, unknown flag — all exit 2
# without ever reaching the mock (no PATH override; a stray gh call would
# fail outright since the real gh is not authenticated in this sandbox, but
# we check the exit code and message directly rather than relying on that).
# ---------------------------------------------------------------------------
set +e
"$STAMP_CLAIM_SH" --item "$ITEM" --id "$ME" >/dev/null 2>"$OUT/noverb.stderr.log"
rc=$?
set -e
[ "$rc" -eq 2 ] || report "no verb: expected exit 2, got $rc"

set +e
"$STAMP_CLAIM_SH" take --id "$ME" >/dev/null 2>"$OUT/noitem.stderr.log"
rc=$?
set -e
[ "$rc" -eq 2 ] || report "no --item: expected exit 2, got $rc"

set +e
"$STAMP_CLAIM_SH" take --item "$ITEM" >/dev/null 2>"$OUT/noid.stderr.log"
rc=$?
set -e
[ "$rc" -eq 2 ] || report "no --id: expected exit 2, got $rc"

set +e
"$STAMP_CLAIM_SH" take --item "$ITEM" --id "$ME" --bogus-flag >/dev/null 2>"$OUT/badflag.stderr.log"
rc=$?
set -e
[ "$rc" -eq 2 ] || report "unknown flag: expected exit 2, got $rc"

# ---------------------------------------------------------------------------
# Hermeticity tripwire (#568, #477): the mock recorded every invocation it
# served, and none of them arrived from a context the harness did not set
# up. Proved load-bearing first, against its own throwaway log: the script
# under test is run with the mock on PATH but WITHOUT the per-run harness
# env, and the marker must appear.
# ---------------------------------------------------------------------------
TRIPWIRE_LOG="$OUT/tripwire-probe.log"
: > "$TRIPWIRE_LOG"
set +e
env -u MOCK_GH_CALLS -u MOCK_GH_MUTATIONS -u MOCK_GH_PROJECT_ID -u MOCK_GH_ITEM_ID \
  PATH="$BIN:$PATH" MOCK_GH_CALL_LOG="$TRIPWIRE_LOG" \
  "$STAMP_CLAIM_SH" take --item "$ITEM" --id "$ME" --repo "$REPO" --work-tracking "$WT" \
  >/dev/null 2>&1
set -e
grep -q '^UNMOCKED-CONTEXT ' "$TRIPWIRE_LOG" \
  || report "tripwire probe: an unmocked-context gh call was NOT marked — the tripwire is not load-bearing"

[ -s "$MOCK_GH_CALL_LOG" ] \
  || report "hermeticity: the mock recorded zero invocations — the call log is not wired up"
if grep -q '^UNMOCKED-CONTEXT ' "$MOCK_GH_CALL_LOG"; then
  report "hermeticity: a gh call was made from an unmocked context: $(grep -m1 '^UNMOCKED-CONTEXT ' "$MOCK_GH_CALL_LOG")"
fi

# ---------------------------------------------------------------------------
# Issue #638: a 'Claimed by' claim id containing a double quote — corrupted
# or hand-edited board data; formats/claim.md's own grammar never produces
# one. Before the fix, the id reached a splice
# (SUPERSEDED="\"$CUR_ID\"") that fed an unescaped id straight into a JSON
# literal handed to `jq --argjson`. A quote there is malformed JSON, and jq
# exits 2 on it — colliding with argerr's exit 2 ("argument error, always
# pre-mutation", the script's own header) on a jq call that runs only AFTER
# the board mutation a few lines above has already landed. Drives a stale
# foreign claim whose id carries a quote through `takeover` (which writes a
# `superseded` id, the code path the splice lived in) and asserts: the
# mutation still lands exactly once (the gate: `n_mutations` after a run
# that must reach the mutation call), the exit code is 0 — a contracted,
# non-2 code — and the id survives intact both on stdout's `.superseded`
# and in the --log line's `.superseded`, proving no JSON was corrupted
# along the way. Splice-tested by hand against the pre-fix script (reverts
# SUPERSEDED to the string-splice form): this fixture then fails with exit
# 2 and zero surviving `.superseded`, restored and reconfirmed green
# (implementer's evidence log, round 0).
# ---------------------------------------------------------------------------
BADID='bad"actor'
STALE_TS2=$(date -u -d '48 hours ago' +%Y-%m-%dT%H:%MZ)
LOGQ="$WORK/session-quote.jsonl"
RC=0; run_stamp_claim "$BADID @ $STALE_TS2" "" takeover --item "$ITEM" --id "$ME" --log "$LOGQ" || RC=$?
[ "$RC" -eq 0 ] \
  || report "takeover (quote in superseded id, #638): expected exit 0 (a contracted code, not jq's own status), got $RC — stderr: $(cat "$OUT/run.stderr.log")"
[ "$(n_mutations)" = "1" ] \
  || report "takeover (quote in superseded id, #638): expected exactly 1 mutation (past the gate that proves this runs post-mutation), got $(n_mutations)"
[ "$(jq -r .superseded "$OUT/run.stdout.log" 2>/dev/null)" = "$BADID" ] \
  || report "takeover (quote in superseded id, #638): expected stdout .superseded to survive intact as '$BADID', got: $(cat "$OUT/run.stdout.log" 2>/dev/null)"
logrecq=$(tail -1 "$LOGQ" 2>/dev/null || true)
jq -e '.event and .claim and .ts' <<<"$logrecq" >/dev/null 2>&1 \
  || report "takeover (quote in superseded id, #638): --log line is not valid JSON accepted by the usual predicate: $logrecq"
[ "$(jq -r .superseded <<<"$logrecq" 2>/dev/null)" = "$BADID" ] \
  || report "takeover (quote in superseded id, #638): expected the --log line's .superseded to also survive intact as '$BADID', got: $logrecq"

# ---------------------------------------------------------------------------
# Drift guard (issue #627): stamp-claim.sh's own exit-code contract (its
# header, between the EXIT-CODE-CONTRACT:BEGIN/:END comment markers) and
# claims.md's Script subsection (between the matching
# <!-- exit-code-contract:begin/:end --> markers) must carry the SAME
# prose — nothing previously checked that, and #614 round 1 found the two
# had drifted (maintenance.md's copy, out of this suite's reach, drifted
# too, but this test cannot touch that file — #627/dispatch note). The gate
# this depends on is the marker pair in each file; extraction strips each
# format's comment leader and collapses whitespace so line-wrap differences
# don't cause a false mismatch, then diffs the two byte-for-byte. Proven
# load-bearing immediately below: a one-word mutation to a SCRATCH COPY of
# claims.md's block (never the real file) must change the extracted text,
# or the comparison could pass by extracting nothing from either side.
# ---------------------------------------------------------------------------
CLAIMS_MD="$SCRIPT_DIR/../references/claims.md"
[ -f "$CLAIMS_MD" ] || report "drift guard (#627): claims.md not found at $CLAIMS_MD"

extract_contract(){ # extract_contract <file> <begin-regex> <end-regex> <leader-regex>
  local file="$1" begin="$2" end="$3" leader="$4"
  awk -v b="$begin" -v e="$end" '
    $0 ~ b {inblock=1; next}
    $0 ~ e {inblock=0}
    inblock {print}
  ' "$file" | sed -E "s/^$leader//" | tr '\n' ' ' | sed -E 's/ +/ /g; s/^ +//; s/ +$//'
}

CONTRACT_SCRIPT=$(extract_contract "$STAMP_CLAIM_SH" '# EXIT-CODE-CONTRACT:BEGIN' '# EXIT-CODE-CONTRACT:END' '# ?')
CONTRACT_CLAIMS=$(extract_contract "$CLAIMS_MD" '<!-- exit-code-contract:begin' '<!-- exit-code-contract:end -->' '')

[ -n "$CONTRACT_SCRIPT" ] \
  || report "drift guard (#627): extracted zero text from stamp-claim.sh's EXIT-CODE-CONTRACT block — marker missing or moved"
[ -n "$CONTRACT_CLAIMS" ] \
  || report "drift guard (#627): extracted zero text from claims.md's exit-code-contract block — marker missing or moved"
[ "$CONTRACT_SCRIPT" = "$CONTRACT_CLAIMS" ] \
  || report "drift guard (#627): stamp-claim.sh header and claims.md disagree on the exit-code contract — header: [$CONTRACT_SCRIPT] vs claims.md: [$CONTRACT_CLAIMS]"

# Self-test: mutate one word in a SCRATCH COPY of claims.md's block (never
# the real file — this suite must not write into the tree it is testing)
# and confirm the extraction changes, so a real drift could not sail
# through this guard by accident.
DRIFT_SCRATCH="$WORK/claims-drift.md"
sed 's/a business-rule REFUSAL/a BUSINESS-rule REFUSAL/' "$CLAIMS_MD" > "$DRIFT_SCRATCH"
CONTRACT_CLAIMS_MUTATED=$(extract_contract "$DRIFT_SCRATCH" '<!-- exit-code-contract:begin' '<!-- exit-code-contract:end -->' '')
[ -n "$CONTRACT_CLAIMS_MUTATED" ] \
  || report "drift guard self-test (#627): the scratch mutation extracted zero text — the self-test cannot prove anything"
[ "$CONTRACT_CLAIMS_MUTATED" != "$CONTRACT_CLAIMS" ] \
  || report "drift guard self-test (#627): mutating a word inside claims.md's exit-code-contract block did not change the extracted text — the sed target text was not found where expected"
[ "$CONTRACT_SCRIPT" != "$CONTRACT_CLAIMS_MUTATED" ] \
  || report "drift guard self-test (#627): mutating claims.md's block still compares equal to the script's — the guard is not load-bearing"

if [ "$fail" -ne 0 ]; then
  echo "test_stamp_claim: FAILED" >&2
  exit 1
fi

echo "test_stamp_claim: all assertions passed (repo=$REPO, item=$ITEM)"
