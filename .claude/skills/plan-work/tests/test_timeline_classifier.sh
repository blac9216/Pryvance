#!/usr/bin/env bash
# test_timeline_classifier.sh — regression test for timeline.sh's hours
# classifier: hours per issue come from the issue's own `size:*` label
# mapped through --defaults (built-in table when the flag is absent), never
# from issue-body prose. Also proves --repo is required, exit 2, before any
# `gh` call.
# Self-contained: runs timeline.sh against a mocked `gh` on PATH serving
# fixture JSON built in a private scratch dir under $TMPDIR (or /tmp),
# removed on exit. No network access, no repository content read.
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
ROWS=(
  "1|size:s|2|label-default"
  "2|size:m|6|label-default"
  "3|size:l|16|label-default"
  "4||6|no-label-default-M"
)

issue_number(){ echo $(( 300 + $1 )); }

build_issues_fixture(){
  local dest="$1"
  : > "$WORK/issues_raw.ndjson"
  local row id label expected source n labels_json
  for row in "${ROWS[@]}"; do
    IFS='|' read -r id label expected source <<<"$row"
    n=$(issue_number "$id")
    if [ -n "$label" ]; then labels_json="[{\"name\":\"$label\"}]"; else labels_json="[]"; fi
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
# including the glued -XPOST and --method=POST spellings. Every invocation
# is appended to MOCK_GH_CALLLOG (when set) so a test can assert no `gh`
# call was ever made (the --repo-required check below).
# ---------------------------------------------------------------------------
cat > "$BIN/gh" <<'MOCKGH'
#!/usr/bin/env bash
set -euo pipefail
: "${MOCK_GH_FIXTURES:?MOCK_GH_FIXTURES must be set}"
if [ -n "${MOCK_GH_CALLLOG:-}" ]; then printf '%s\n' "$*" >> "$MOCK_GH_CALLLOG"; fi
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
run_timeline(){
  local out_dir="$1"; shift
  local rc=0
  set +e
  MOCK_GH_FIXTURES="$FIXTURES" PATH="$BIN:$PATH" \
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
  if [ -z "$label" ]; then
    grep -qF "timeline: issue #$n has no size:* label; falling back to the M default" "$stderr_log" \
      || report "issue #$n (no label): expected stderr fallback message not found"
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
# --repo is required: exit 2, a message naming the flag, and no `gh` call at
# all (the mock's call log stays empty) — proven before touching any fixture.
# ---------------------------------------------------------------------------
CALLLOG="$WORK/gh-calls.log"
: > "$CALLLOG"
rc=0
MOCK_GH_FIXTURES="$FIXTURES" MOCK_GH_CALLLOG="$CALLLOG" PATH="$BIN:$PATH" \
  "$TIMELINE_SH" --milestones "Test Milestone" --out "$OUT/norepo" \
  > "$OUT/norepo.stdout.log" 2> "$OUT/norepo.stderr.log" || rc=$?
[ "$rc" -eq 2 ] || report "--repo omitted: expected exit 2, got $rc"
grep -qi -- '--repo' "$OUT/norepo.stderr.log" || report "--repo omitted: expected stderr to name --repo, got: $(cat "$OUT/norepo.stderr.log")"
[ ! -s "$CALLLOG" ] || report "--repo omitted: expected no gh call, but the mock's call log is non-empty: $(cat "$CALLLOG")"

if [ "$fail" -ne 0 ]; then
  echo "test_timeline_classifier: FAILED" >&2
  exit 1
fi

echo "test_timeline_classifier: all rows and the --repo-required check passed (repo=$REPO)"
