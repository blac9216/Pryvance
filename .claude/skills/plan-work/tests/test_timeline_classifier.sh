#!/usr/bin/env bash
# test_timeline_classifier.sh — regression test for timeline.sh's hours
# classifier: hours per issue come from the issue's own `size:*` label
# mapped through --defaults (built-in table when the flag is absent), never
# from issue-body prose. Also proves --repo is required, exit 2, before any
# `gh` call.
# Self-contained: runs timeline.sh against a mocked `gh` on PATH serving
# fixture JSON built in a private scratch dir under $TMPDIR (or /tmp),
# removed on exit. No network access, no repository content read.
# Follows ../../github-workflow/tests/README.md's shape (#778): the mocked
# `gh`, the UNMOCKED-CONTEXT tripwire, and every negative case routed
# through one helper (run_timeline_negative) that sets the FULL mock env and
# asserts the call log did not grow.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TIMELINE_SH="$SCRIPT_DIR/../scripts/timeline.sh"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/timeline-classifier-test.XXXXXX")"
cleanup(){ rm -rf "$WORK"; }
trap cleanup EXIT

FIXTURES="$WORK/fixtures"
BIN="$WORK/bin"
OUT="$WORK/out"
mkdir -p "$FIXTURES" "$BIN" "$OUT"

REPO="test-org/test-repo"

printf '[{"number":1,"title":"Test Milestone","due_on":null,"created_at":"2020-01-01T00:00:00Z"}]' \
  > "$FIXTURES/milestones.json"
printf '[]' > "$FIXTURES/blocked_by.json"

# ---------------------------------------------------------------------------
# Fixture matrix: one issue per size:* label, plus one with no size:* label
# at all. Each row states what a run with the built-in --defaults table
# expects; individual runs below also exercise --defaults overrides.
# id|label|expected_hours(built-in)|expected_source
# ---------------------------------------------------------------------------
# Rows 5 and 6 (#888) exercise two documented-but-previously-uncovered
# behaviours from timeline.sh's header comment: a REPEATED size:* label
# resolves to the first one jq's array order returns (row 5: size:s then
# size:l -> S wins, per "should never occur but if it does" wording), and a
# NON-CANONICAL-CASE label (row 6: size:M, uppercase) is treated as no label
# at all -- the size read is case-sensitive to the canonical lowercase form
# -- so it falls back to the M default and emits the same stderr line a
# genuinely unlabelled issue does. `label` here is a pipe-free encoding the
# loop below expands into a labels array; a single "|"-free token is one
# label, and "size:s,size:l" (comma-joined) becomes two.
ROWS=(
  "1|size:s|2|label-default"
  "2|size:m|6|label-default"
  "3|size:l|16|label-default"
  "4||6|no-label-default-M"
  "5|size:s,size:l|2|label-default"
  "6|size:M|6|no-label-default-M"
)

issue_number(){ echo $(( 300 + $1 )); }

build_issues_fixture(){
  local dest="$1"
  : > "$WORK/issues_raw.ndjson"
  local row id label expected source n labels_json
  for row in "${ROWS[@]}"; do
    IFS='|' read -r id label expected source <<<"$row"
    n=$(issue_number "$id")
    if [ -n "$label" ]; then
      # The split is `tr`'s, not the shell's: an `IFS=','` here would be
      # dead, since nothing in this pipeline is word-split (round-1 note 8).
      labels_json=$(printf '%s\n' "$label" | tr ',' '\n' | jq -R '{name:.}' | jq -s -c '.')
    else
      labels_json="[]"
    fi
    jq -cn --argjson number "$n" --argjson labels "$labels_json" \
      '{number:$number,state:"open",pull_request:null,created_at:"2020-01-01T00:00:00Z",closed_at:null,assignee:null,labels:$labels}' \
      >> "$WORK/issues_raw.ndjson"
  done
  jq -s '.' "$WORK/issues_raw.ndjson" > "$dest"
}
build_issues_fixture "$FIXTURES/issues.json"

# ---------------------------------------------------------------------------
# Mock gh: serves the three endpoints timeline.sh calls, applying the real
# --jq expression (via the real jq binary) against the fixture, exactly as
# `gh api --jq` would against live API output. Refuses any non-GET method,
# including the glued -XPOST and --method=POST spellings. Every invocation is
# appended to MOCK_GH_CALL_LOG (when set), and one arriving with no
# MOCK_GH_FIXTURES set is additionally marked UNMOCKED-CONTEXT (#778's
# tripwire, first established in test_history.sh) instead of the real,
# authenticated gh ever being reachable.
# ---------------------------------------------------------------------------
cat > "$BIN/gh" <<'MOCKGH'
#!/usr/bin/env bash
set -euo pipefail
if [ -n "${MOCK_GH_CALL_LOG:-}" ]; then
  printf 'CALL gh %s\n' "$*" >> "$MOCK_GH_CALL_LOG"
  if [ -z "${MOCK_GH_FIXTURES:-}" ]; then
    printf 'UNMOCKED-CONTEXT gh %s\n' "$*" >> "$MOCK_GH_CALL_LOG"
  fi
fi
: "${MOCK_GH_FIXTURES:?MOCK_GH_FIXTURES must be set}"
if [ "${1:-}" != "api" ]; then
  echo "mock gh: unsupported command: $*" >&2
  exit 1
fi
shift
endpoint=""
jq_expr=""
method="GET"
while [ $# -gt 0 ]; do
  case "$1" in
    --paginate) shift ;;
    --jq) jq_expr="$2"; shift 2 ;;
    -X|--method) method="$2"; shift 2 ;;
    -X?*) method="${1#-X}"; shift ;;
    --method=*) method="${1#--method=}"; shift ;;
    *) endpoint="$1"; shift ;;
  esac
done
case "$endpoint" in
  repos/*/issues/*/dependencies/blocked_by) raw="$MOCK_GH_FIXTURES/blocked_by.json" ;;
  repos/*/issues\?milestone=*)              raw="$MOCK_GH_FIXTURES/issues.json" ;;
  repos/*/milestones*)                      raw="$MOCK_GH_FIXTURES/milestones.json" ;;
  *) echo "mock gh: unknown endpoint: $endpoint" >&2; exit 1 ;;
esac
if [ "$method" != "GET" ]; then
  echo "mock gh: refusing non-GET method ($method) on $endpoint" >&2
  exit 1
fi
if [ -n "$jq_expr" ]; then
  # -c -r together: -c keeps multi-line object/array results on one line
  # each (so a downstream `jq -s` sees one JSON doc per line, matching how
  # gh api --jq actually emits results), and -r additionally strips quotes
  # from scalar string results, matching `gh api --jq`'s raw-output
  # behavior for e.g. `.foo//empty`.
  jq -c -r "$jq_expr" "$raw"
else
  cat "$raw"
fi
MOCKGH
chmod +x "$BIN/gh"

# ---------------------------------------------------------------------------
# run_timeline captures timeline.sh's stdout/stderr into logs under $WORK
# (deleted by the `cleanup` EXIT trap above). If timeline.sh crashes, the
# uncaught non-zero return would, under this script's own `set -e`, exit
# test_timeline_classifier.sh immediately — the EXIT trap fires and the logs
# are gone before anything is printed. Capture the exit status with
# `set +e`/`set -e` around the call and dump both logs on an unexpected
# non-zero exit, before returning control to the (still `set -e`) caller.
# ---------------------------------------------------------------------------
CALL_LOG="$WORK/gh-calls.log"
: > "$CALL_LOG"

run_timeline(){
  local out_dir="$1"; shift
  local rc=0
  set +e
  MOCK_GH_FIXTURES="$FIXTURES" MOCK_GH_CALL_LOG="$CALL_LOG" PATH="$BIN:$PATH" \
    "$TIMELINE_SH" --repo "$REPO" --milestones "Test Milestone" --out "$out_dir" "$@" \
    > "$out_dir.stdout.log" 2> "$out_dir.stderr.log"
  rc=$?
  set -e
  return "$rc"
}

fail=0
report(){ echo "FAIL: $*" >&2; fail=1; }

check_rc(){
  local label="$1" out_dir="$2"; shift 2
  local rc=0
  run_timeline "$out_dir" "$@" || rc=$?
  if [ "$rc" -ne 0 ]; then
    report "$label: $TIMELINE_SH exited $rc"
    echo "--- stdout ($out_dir.stdout.log) ---" >&2; cat "$out_dir.stdout.log" >&2 || true
    echo "--- stderr ($out_dir.stderr.log) ---" >&2; cat "$out_dir.stderr.log" >&2 || true
  fi
}

check_row(){
  local issues_jsonl="$1" stderr_log="$2" id="$3" label="$4" expected_hours="$5" expected_source="$6"
  local n; n=$(issue_number "$id")
  local rec; rec=$(jq -c --argjson n "$n" 'select(.issue==$n)' "$issues_jsonl")
  if [ -z "$rec" ]; then
    report "issue #$n (label=\"$label\"): no record emitted in issues.jsonl"
    return
  fi
  local got_source got_hours
  got_source=$(jq -r '.hours_source' <<<"$rec")
  got_hours=$(jq -r '.hours' <<<"$rec")
  [ "$got_source" = "$expected_source" ] || report "issue #$n (label=\"$label\"): expected hours_source=$expected_source, got \"$got_source\""
  awk -v got="$got_hours" -v want="$expected_hours" 'BEGIN{exit !(got==want)}' \
    || report "issue #$n (label=\"$label\"): expected hours=$expected_hours, got $got_hours"
  # The stderr fallback line is keyed to expected_source (whether the label
  # actually resolved), not to the raw fixture label text: row 6 (#888)
  # carries a non-empty label ("size:M") that is nonetheless a no-label case
  # once case-sensitivity is applied, and must fire the same fallback line
  # as row 4's genuinely absent label.
  if [ "$expected_source" = "no-label-default-M" ]; then
    grep -qF "timeline: issue #$n has no size:* label; falling back to the M default" "$stderr_log" \
      || report "issue #$n (label=\"$label\"): expected stderr fallback message not found"
  else
    if grep -q "issue #$n has" "$stderr_log"; then
      report "issue #$n (label=\"$label\"): expected no fallback message on stderr, but found one"
    fi
  fi
}

# ---------------------------------------------------------------------------
# Run 1: built-in --defaults table (no --defaults flag). Every row's
# expected hours/source above is exactly what the built-in table produces.
# ---------------------------------------------------------------------------
mkdir -p "$OUT/builtin"
check_rc "builtin defaults" "$OUT/builtin"
for row in "${ROWS[@]}"; do
  IFS='|' read -r id label expected source <<<"$row"
  check_row "$OUT/builtin/issues.jsonl" "$OUT/builtin.stderr.log" "$id" "$label" "$expected" "$source"
done

# ---------------------------------------------------------------------------
# Run 2: --defaults M=3 overrides only the M bucket; the size:m issue must
# now report 3 hours, still sourced label-default.
# ---------------------------------------------------------------------------
mkdir -p "$OUT/override_m"
check_rc "defaults M=3" "$OUT/override_m" --defaults M=3
check_row "$OUT/override_m/issues.jsonl" "$OUT/override_m.stderr.log" 2 "size:m" 3 "label-default"

# ---------------------------------------------------------------------------
# Run 3: --defaults S=10,L=20 overrides S and L only; M keeps its built-in
# default (proves an omitted size in --defaults falls back to the built-in
# table rather than to zero/empty).
# ---------------------------------------------------------------------------
mkdir -p "$OUT/override_sl"
check_rc "defaults S=10,L=20" "$OUT/override_sl" --defaults S=10,L=20
check_row "$OUT/override_sl/issues.jsonl" "$OUT/override_sl.stderr.log" 1 "size:s" 10 "label-default"
check_row "$OUT/override_sl/issues.jsonl" "$OUT/override_sl.stderr.log" 3 "size:l" 20 "label-default"
check_row "$OUT/override_sl/issues.jsonl" "$OUT/override_sl.stderr.log" 2 "size:m" 6 "label-default"

# ---------------------------------------------------------------------------
# Negative cases (#778): routed through one helper that sets the FULL mock
# env (MOCK_GH_FIXTURES, MOCK_GH_CALL_LOG, PATH) exactly as run_timeline
# does, and asserts the call log did not grow -- per
# github-workflow/tests/README.md's "Negative cases" section, a case that
# passes only because a guard fires before the first `gh` call stops being
# hermetic the moment that guard regresses.
# ---------------------------------------------------------------------------
NEG_RC=0
run_timeline_negative(){ # label, then timeline.sh args
  local label="$1"; shift
  local before after rc=0
  before=$(grep -c "^CALL gh " "$CALL_LOG" || true)
  set +e
  MOCK_GH_FIXTURES="$FIXTURES" MOCK_GH_CALL_LOG="$CALL_LOG" PATH="$BIN:$PATH" \
    "$TIMELINE_SH" "$@" >"$OUT/$label.stdout.log" 2>"$OUT/$label.stderr.log"
  rc=$?
  set -e
  after=$(grep -c "^CALL gh " "$CALL_LOG" || true)
  [ "$before" = "$after" ] \
    || report "$label: expected zero gh calls, but the call log grew by $((after - before)): $(awk -v n="$before" 'NR>n' "$CALL_LOG" | head -1)"
  NEG_RC=$rc
  return 0
}

# --repo is required: exit 2, a message naming the flag, and no `gh` call at
# all -- proven before touching any fixture.
run_timeline_negative norepo --milestones "Test Milestone" --out "$OUT/norepo"
[ "$NEG_RC" -eq 2 ] || report "--repo omitted: expected exit 2, got $NEG_RC"
grep -qi -- '--repo' "$OUT/norepo.stderr.log" || report "--repo omitted: expected stderr to name --repo, got: $(cat "$OUT/norepo.stderr.log")"

# ---------------------------------------------------------------------------
# Named mutation probe (#778): the hours-classifier jq expression's
# `startswith`/`test("^size:[sml]$")` match is the one line every row check
# above depends on. Probed by hand against a mutated copy of timeline.sh
# (the regex changed to accept uppercase, e.g. `^size:[sSmMlL]$`) — row 6
# (#888's size:M case) then resolves label-default/M instead of
# no-label-default-M and check_row above fails, proving the row is
# load-bearing rather than vacuous. Not re-run automatically here (the
# mutation lives outside the tree per the splice-restore recipe); recorded
# in the PR body's Splice results.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# #898: with no --history-dir and no --parallelism, timeline.sh's same-run
# default guess must find history.sh's repo-keyed parallelism.txt
# ($TMPDIR/plan-work-history/<owner>__<name>/parallelism.txt), not fall back
# to the un-keyed pre-#898 layout (which no history.sh run has written
# since #889). A private TMPDIR keeps this hermetic to $WORK.
# ---------------------------------------------------------------------------
PARTMP="$WORK/xdg-tmp"
mkdir -p "$PARTMP/plan-work-history/${REPO%%/*}__${REPO#*/}"
printf '2.75\n' > "$PARTMP/plan-work-history/${REPO%%/*}__${REPO#*/}/parallelism.txt"
mkdir -p "$OUT/par898"
set +e
TMPDIR="$PARTMP" MOCK_GH_FIXTURES="$FIXTURES" MOCK_GH_CALL_LOG="$CALL_LOG" PATH="$BIN:$PATH" \
  "$TIMELINE_SH" --repo "$REPO" --milestones "Test Milestone" --out "$OUT/par898" \
  > "$OUT/par898.stdout.log" 2> "$OUT/par898.stderr.log"
rc=$?
set -e
[ "$rc" -eq 0 ] || report "#898 parallelism guess: expected exit 0, got $rc"
grep -qF "parallelism 2.75" "$OUT/par898/timeline.md" \
  || report "#898 parallelism guess: expected the repo-keyed parallelism.txt (2.75) to be used, got: $(grep -m1 parallelism "$OUT/par898/timeline.md" 2>/dev/null || echo '<no timeline.md>')"
grep -q "no history at" "$OUT/par898.stderr.log" \
  && report "#898 parallelism guess: expected no fallback-to-1.5 stderr line, but got one: $(cat "$OUT/par898.stderr.log")"

# ---------------------------------------------------------------------------
# Hermeticity (#778): the tripwire itself is load-bearing (an unmocked call
# really is caught), and no call anywhere in this run was made from an
# unmocked context.
# ---------------------------------------------------------------------------
TRIPWIRE_LOG="$WORK/tripwire.log"
: > "$TRIPWIRE_LOG"
set +e
env -u MOCK_GH_FIXTURES PATH="$BIN:$PATH" MOCK_GH_CALL_LOG="$TRIPWIRE_LOG" \
  gh api "repos/$REPO/milestones" >/dev/null 2>&1
set -e
grep -q '^UNMOCKED-CONTEXT ' "$TRIPWIRE_LOG" \
  || report "tripwire probe: an unmocked-context gh call was NOT marked -- the tripwire is not load-bearing"

[ -s "$CALL_LOG" ] || report "hermeticity: the mock recorded zero invocations -- the call log is not wired up"
if grep -q '^UNMOCKED-CONTEXT ' "$CALL_LOG"; then
  report "hermeticity: a gh call was made from an unmocked context: $(grep -m1 '^UNMOCKED-CONTEXT ' "$CALL_LOG")"
fi

if [ "$fail" -ne 0 ]; then
  echo "test_timeline_classifier: FAILED" >&2
  exit 1
fi

echo "test_timeline_classifier: all rows and the --repo-required check passed (repo=$REPO)"
