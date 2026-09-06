#!/usr/bin/env bash
# test_board_audit.sh — fixture-driven regression test for board-audit.sh.
# Follows the mock-`gh` harness conventions in tests/README.md: a mocked `gh`
# binary on PATH serves fixture JSON from a private mktemp scratch dir,
# refuses any explicit non-GET verb, and no real network call is ever
# reachable. Pinned to LANG=C / LC_ALL=C for the same reason test_preflight.sh
# is: nothing under test is locale-sensitive, and pinning here catches a
# future regression that would make it so.
#
# Covers:
#  - part (a) spans two pages on both sides of the diff (project items and
#    open issues) — a missing item is reported only because the second page
#    of each listing is actually read; a truncated (page-1-only) read of
#    either side would silently reach a different, wrong answer.
#  - part (b), the "since_only" heuristic branch (this repo's fixture names
#    no second/reviewer account): a homing event after --since is reported
#    as a candidate regardless of actor, and one before --since is not.
#  - a second, independently-fixtured "clean" repo where every open issue
#    has a board item and no timeline event falls after --since: both
#    arrays come back empty.
#  - the mock records no non-GET verb, and the GraphQL project-items query
#    text is asserted to contain no "mutation" keyword.
#  - --log appends one event line; without --log the line goes to stderr,
#    never stdout.
#  - the epic-target branch (a milestone 404 falling back to sub_issues),
#    target_kind in JSON/--markdown/--log, --milestone/--epic forcing the
#    kind outright, their mutual exclusivity with --target and each other,
#    and a pull-request number refused as an epic. A number that is BOTH a
#    milestone and an issue resolves to the milestone. (#317, #327)
#  - every negative case runs under the mock via run_argerr, and a tripwire
#    asserts no gh call ever arrived from an unmocked context. (#477)
#  - --max-rows refuses every non-canonical spelling (00, 000, +5, " 5"),
#    not only the literal "0". (#476)
#  - a part-(a)-only run on a work-tracking file naming a reviewer account
#    and no automation account exits 0; the same file with --target still
#    exits 1. (#478)
#  - the actor_filter branch, corrected: the automation account's own event
#    is excluded, the second/reviewer account's own event is NOT, and a
#    second account named with no automation account line is refused. The
#    --markdown Limits wording is asserted to match whichever branch ran.
#    (#317)
#  - --max-rows truncation is asserted by bullet COUNT on both lists, not
#    only by the trailer's presence — a mutation that drops either list's
#    [0:$max] slice must fail this suite. --max-rows 0 is refused. The
#    "> Limits:" blockquote is preceded by a blank line. (#338, #339)
#  - the timeline walk's bound: an issue whose own updated_at predates
#    --since is never fetched (no fixture exists for it — a regression
#    reintroducing the full walk is caught by the mock's 404, not by a slow
#    real run); --limit caps the walk further and sets
#    homed_walk_truncated. (#416)
#  - missing_size_label, bad_priority_label, bad_severity_label (#733,
#    #745): six distinct dirty-fixture issues (#10-#15) each gate exactly
#    one outcome — a well-formed control (#10) that must never appear in any
#    of the three lists, two priority labels (#11), zero labels of any kind
#    (#12, both missing_size_label and priority_count=0), a bug with zero
#    severity (#13), two severity labels on a non-bug (#14), and a near-miss
#    label that starts with "size" but is not "size:*" (#15, `sized` — pins
#    the colon: a `startswith("size")` mutant with the colon dropped would
#    wrongly treat #15 as sized and drop it from missing_size_label) —
#    asserted in JSON, --markdown (both the count line and the per-issue
#    priority_count/severity_count detail) and the --log counts alike. The
#    clean fixture asserts all three come back empty.
set -euo pipefail
export LANG=C LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOARD_AUDIT_SH="$SCRIPT_DIR/../scripts/board-audit.sh"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/board-audit-test.XXXXXX")"
cleanup(){ rm -rf "$WORK"; }
trap cleanup EXIT

BIN="$WORK/bin"
OUT="$WORK/out"
mkdir -p "$BIN" "$OUT"

fail=0
report(){ echo "FAIL: $*" >&2; fail=1; }

# run_argerr label uniqueness (#518): two cases sharing a label would write
# to the same $OUT/<label>.{stdout,stderr}.log and the second silently
# clobbers the first's artifact, so a failure message could point at the
# wrong input. Cheap to check — one append-only log of labels seen so far.
LABELS_SEEN="$WORK/labels-seen.log"
: > "$LABELS_SEEN"

# ---------------------------------------------------------------------------
# work-tracking.md fixtures. The "dirty" one names only the automation
# account (no second/reviewer identity) -> the since_only heuristic branch.
# ---------------------------------------------------------------------------
WT_DIRTY="$WORK/work-tracking-dirty.md"
cat > "$WT_DIRTY" <<'MD'
| Layer | Here |
|---|---|
| Project board | [Global Unassigned #6](https://example.invalid/6) — owner `test-org`; automation account `machine-bot` (admin) |

| Field | Id |
|---|---|
| Project | `PVT_test123` |

Reviewer identity: none — single account.
MD

WT_CLEAN="$WORK/work-tracking-clean.md"
cp "$WT_DIRTY" "$WT_CLEAN"
sed -i 's/PVT_test123/PVT_test456/' "$WT_CLEAN"

# ---------------------------------------------------------------------------
# "Dirty" repo fixtures: open issues #10-#15 across two REST pages; project
# items across two GraphQL pages cover every number except #12 -> #12 is
# missing_board_items. Target milestone 5's one member issue (#10) has three
# timeline events: one before --since (excluded), one milestoned and one
# labeled after --since (both included — since_only reports every actor).
#
# Labels also exercise the three label-audit reports (#733, #745), each
# gated on a distinct issue so a fixture bug in one can't mask another:
#   #10 size:m, priority:high             -> clean, reported nowhere.
#   #11 priority:medium+priority:low, size:s -> bad_priority_label only
#       (priority_count=2); the exact shape (two priority labels, one added
#       by a later triage drain without removing the first) that motivated
#       #745.
#   #12 no labels at all                  -> missing_size_label AND
#       bad_priority_label (priority_count=0); size:*/priority:* are both
#       required on every open issue, not only a `bug`.
#   #13 bug, priority:high, size:s, no severity:* -> bad_severity_label only
#       (severity_count=0); severity is required only when `bug` is present
#       (a chore has none, correctly), so this is the only issue in the
#       fixture set that can exercise the zero-severity leg.
#   #14 priority:high, size:l, severity:major+severity:minor -> also
#       bad_severity_label (severity_count=2); the multiplicity leg applies
#       regardless of type, so #14 deliberately carries no `bug` label.
#   #15 sized (not size:*), priority:high -> missing_size_label only; present
#       on the board so it cannot also land in missing_board_items, isolating
#       the near-miss to the one list it is meant to gate. `sized` starts
#       with the literal substring "size" but is not "size:*", so it is the
#       fixture that makes the colon in `startswith("size:")` load-bearing.
#
# `Claimed by` values also exercise bad_claim_form (#744), on the SAME five
# on-board issues so a bug in one report cannot mask another:
#   #10 "acme-01 @ 2026-08-29T15:10Z"          -> a well-formed lock, clean.
#   #11 "acme-01 @ 2026-08-29T15:10Z (stamp)"  -> a well-formed stamp, clean
#       — proves the marker suffix does not itself trip the malformed check.
#   #13 "acme-01 2026-08-29T15:10Z"            -> malformed (no " @ ") ->
#       bad_claim_form.
#   #14 no `Claimed by` field at all (null)    -> empty, clean (never
#       flagged — only a non-empty value can be malformed).
#   #15 "acme-01 @ 2026-08-29T15:10Z (STAMP)"   -> malformed (near-miss: the
#       marker in the wrong case) -> bad_claim_form; this is the fixture
#       that makes the literal-lowercase requirement in the marker regex
#       load-bearing, the same way #15's `sized` label makes the colon in
#       `startswith("size:")` load-bearing above.
# ---------------------------------------------------------------------------
DIRTY="$WORK/fixtures-dirty"
mkdir -p "$DIRTY"
REPO_DIRTY="test-org/test-repo"
SINCE="2026-01-01T00:00:00Z"

cat > "$DIRTY/open_issues_page1.json" <<'JSON'
[
  {"number":10,"title":"issue ten","html_url":"https://example.invalid/10","labels":[{"name":"size:m"},{"name":"priority:high"}]},
  {"number":11,"title":"issue eleven","html_url":"https://example.invalid/11","labels":[{"name":"priority:medium"},{"name":"priority:low"},{"name":"size:s"}]}
]
JSON
cat > "$DIRTY/open_issues_page2.json" <<'JSON'
[
  {"number":12,"title":"issue twelve","html_url":"https://example.invalid/12","labels":[]},
  {"number":13,"title":"issue thirteen","html_url":"https://example.invalid/13","labels":[{"name":"bug"},{"name":"priority:high"},{"name":"size:s"}]},
  {"number":14,"title":"issue fourteen","html_url":"https://example.invalid/14","labels":[{"name":"priority:high"},{"name":"size:l"},{"name":"severity:major"},{"name":"severity:minor"}]},
  {"number":15,"title":"issue fifteen","html_url":"https://example.invalid/15","labels":[{"name":"sized"},{"name":"priority:high"}]}
]
JSON

cat > "$DIRTY/project_items_page1.json" <<'JSON'
{"data":{"node":{"items":{"pageInfo":{"hasNextPage":true,"endCursor":"CURSOR1"},
  "nodes":[{"id":"ITEM1","content":{"number":10,"repository":{"nameWithOwner":"test-org/test-repo"}},"claimedBy":{"text":"acme-01 @ 2026-08-29T15:10Z"}}]}}}}
JSON
cat > "$DIRTY/project_items_page2.json" <<'JSON'
{"data":{"node":{"items":{"pageInfo":{"hasNextPage":false,"endCursor":null},
  "nodes":[{"id":"ITEM2","content":{"number":11,"repository":{"nameWithOwner":"test-org/test-repo"}},"claimedBy":{"text":"acme-01 @ 2026-08-29T15:10Z (stamp)"}},
           {"id":"ITEM4","content":{"number":13,"repository":{"nameWithOwner":"test-org/test-repo"}},"claimedBy":{"text":"acme-01 2026-08-29T15:10Z"}},
           {"id":"ITEM5","content":{"number":14,"repository":{"nameWithOwner":"test-org/test-repo"}},"claimedBy":null},
           {"id":"ITEM6","content":{"number":15,"repository":{"nameWithOwner":"test-org/test-repo"}},"claimedBy":{"text":"acme-01 @ 2026-08-29T15:10Z (STAMP)"}}]}}}}
JSON

cat > "$DIRTY/milestone.json" <<'JSON'
{"number":5,"title":"milestone five"}
JSON
cat > "$DIRTY/milestone_issues.json" <<'JSON'
[{"number":10,"title":"issue ten","pull_request":null}]
JSON

cat > "$DIRTY/timeline_10.json" <<JSON
[
  {"event":"milestoned","actor":{"login":"machine-bot"},"created_at":"2025-12-01T00:00:00Z"},
  {"event":"milestoned","actor":{"login":"user-a"},"created_at":"2026-01-01T05:00:00Z"},
  {"event":"labeled","actor":{"login":"machine-bot"},"created_at":"2026-01-01T06:00:00Z"}
]
JSON

# ---------------------------------------------------------------------------
# "Clean" repo fixtures: one open issue, present on the board; target
# milestone 6's one member issue has no timeline event on/after --since.
# ---------------------------------------------------------------------------
CLEAN="$WORK/fixtures-clean"
mkdir -p "$CLEAN"
REPO_CLEAN="test-org/clean-repo"

cat > "$CLEAN/open_issues_page1.json" <<'JSON'
[{"number":20,"title":"issue twenty","html_url":"https://example.invalid/20","labels":[{"name":"size:s"},{"name":"priority:medium"}]}]
JSON
cat > "$CLEAN/open_issues_page2.json" <<'JSON'
[]
JSON
cat > "$CLEAN/project_items_page1.json" <<'JSON'
{"data":{"node":{"items":{"pageInfo":{"hasNextPage":false,"endCursor":null},
  "nodes":[{"id":"ITEM3","content":{"number":20,"repository":{"nameWithOwner":"test-org/clean-repo"}}}]}}}}
JSON
cat > "$CLEAN/milestone.json" <<'JSON'
{"number":6,"title":"milestone six"}
JSON
cat > "$CLEAN/milestone_issues.json" <<'JSON'
[{"number":20,"title":"issue twenty","pull_request":null}]
JSON
cat > "$CLEAN/timeline_20.json" <<'JSON'
[{"event":"milestoned","actor":{"login":"machine-bot"},"created_at":"2025-06-01T00:00:00Z"}]
JSON

# ---------------------------------------------------------------------------
# Mock gh: routes by endpoint shape (and, for graphql, by whether a `cursor`
# field was passed), applying the real --jq expression via the real jq
# binary against fixture JSON. Refuses any explicit non-GET verb. The
# GraphQL call's query text is captured to a file so the test can assert it
# never contains "mutation".
# ---------------------------------------------------------------------------
cat > "$BIN/gh" <<'MOCKGH'
#!/usr/bin/env bash
set -euo pipefail
# Every invocation is recorded before anything else happens, so the suite can
# assert at the end that no call went unmocked (#477). MOCK_GH_CALL_LOG is
# exported once for the whole suite, so a call arriving without it means this
# mock was reached from an environment the harness did not set up at all.
: "${MOCK_GH_CALL_LOG:?MOCK_GH_CALL_LOG must be set}"
printf 'CALL gh %s\n' "$*" >> "$MOCK_GH_CALL_LOG"
if [ -z "${MOCK_GH_FIXTURES:-}" ]; then
  # Reached with no fixture set: the caller ran the script under test without
  # the harness env. Recorded as a tripwire hit rather than silently failing,
  # so the suite reports it as an assertion instead of a network error.
  printf 'UNMOCKED-CONTEXT gh %s\n' "$*" >> "$MOCK_GH_CALL_LOG"
  echo "mock gh: invoked with no MOCK_GH_FIXTURES — unmocked call context" >&2
  exit 1
fi
: "${MOCK_GH_QUERY_LOG:?MOCK_GH_QUERY_LOG must be set}"
if [ "${1:-}" = "repo" ] && [ "${2:-}" = "view" ]; then
  echo "mock gh: repo view should not be called when --repo is passed" >&2
  exit 1
fi
if [ "${1:-}" != "api" ]; then
  echo "mock gh: unsupported command: $*" >&2
  exit 1
fi
shift
endpoint=""
jq_expr=""
method="GET"
explicit_method=0
implicit_write=0
paginate=0
has_cursor=0
query_text=""
while [ $# -gt 0 ]; do
  case "$1" in
    --paginate) paginate=1; shift ;;
    --jq) jq_expr="$2"; shift 2 ;;
    -X|--method) method="$2"; explicit_method=1; shift 2 ;;
    -X?*) method="${1#-X}"; explicit_method=1; shift ;;
    --method=*) method="${1#--method=}"; explicit_method=1; shift ;;
    -f|-F|--field|--raw-field)
      implicit_write=1
      case "$2" in
        cursor=*) has_cursor=1 ;;
        query=*) query_text="${2#query=}" ;;
      esac
      shift 2 ;;
    --input) implicit_write=1; shift 2 ;;
    *) endpoint="$1"; shift ;;
  esac
done
# Real `gh api` sends POST implicitly the moment -f/-F/--field/--raw-field/
# --input is given without an explicit -X — the mock must refuse that too.
# GraphQL is the one exception (every graphql call is transport-POST by
# protocol regardless of -f/-F), and only there: a non-graphql REST endpoint
# gets no such exemption. (finding 2)
if [ "$explicit_method" -eq 0 ] && [ "$implicit_write" -eq 1 ] && [ "$endpoint" != "graphql" ]; then
  method="POST"
fi
if [ "$method" != "GET" ]; then
  echo "mock gh: refusing non-GET method ($method) on $endpoint" >&2
  exit 1
fi
apply(){ # apply <fixture-file>
  if [ -n "$jq_expr" ]; then
    jq -c -r "$jq_expr" "$1"
  else
    cat "$1"
  fi
}
case "$endpoint" in
  graphql)
    printf '%s' "$query_text" >> "$MOCK_GH_QUERY_LOG"
    if [ "$has_cursor" -eq 1 ]; then
      cat "$MOCK_GH_FIXTURES/project_items_page2.json"
    else
      cat "$MOCK_GH_FIXTURES/project_items_page1.json"
    fi
    ;;
  repos/*/issues\?state=open*)
    apply "$MOCK_GH_FIXTURES/open_issues_page1.json"
    if [ "$paginate" -eq 1 ]; then
      apply "$MOCK_GH_FIXTURES/open_issues_page2.json"
    fi
    ;;
  repos/*/milestones/*)
    if [ -f "$MOCK_GH_FIXTURES/milestone.json" ]; then
      apply "$MOCK_GH_FIXTURES/milestone.json"
    else
      echo "gh: Not Found (HTTP 404)" >&2
      exit 1
    fi
    ;;
  repos/*/issues\?milestone=*)
    apply "$MOCK_GH_FIXTURES/milestone_issues.json"
    ;;
  repos/*/issues/*/timeline\?per_page=100)
    # `|| true` (#517): a zero-match `grep -oP` here exits 1, and under
    # `set -euo pipefail` (mock header) that would abort the whole mock with
    # no diagnostic at all; fall through to the empty-`$n` check below so the
    # caller gets a labeled stderr line instead of a bare exit 1.
    n=$(printf '%s' "$endpoint" | grep -oP '(?<=issues/)[0-9]+' || true)
    [ -n "$n" ] || { echo "mock gh: could not extract an issue number from endpoint: $endpoint" >&2; exit 1; }
    apply "$MOCK_GH_FIXTURES/timeline_$n.json"
    ;;
  repos/*/issues/*/sub_issues\?per_page=100)
    n=$(printf '%s' "$endpoint" | grep -oP '(?<=issues/)[0-9]+(?=/sub_issues)' || true)
    [ -n "$n" ] || { echo "mock gh: could not extract an issue number from endpoint: $endpoint" >&2; exit 1; }
    apply "$MOCK_GH_FIXTURES/sub_issues_$n.json"
    ;;
  repos/*/issues/*)
    n=$(printf '%s' "$endpoint" | grep -oP '(?<=issues/)[0-9]+$' || true)
    [ -n "$n" ] || { echo "mock gh: could not extract an issue number from endpoint: $endpoint" >&2; exit 1; }
    if [ -f "$MOCK_GH_FIXTURES/epic_$n.json" ]; then
      apply "$MOCK_GH_FIXTURES/epic_$n.json"
    else
      echo "gh: Not Found (HTTP 404)" >&2
      exit 1
    fi
    ;;
  *)
    echo "mock gh: unknown endpoint: $endpoint" >&2
    exit 1 ;;
esac
MOCKGH
chmod +x "$BIN/gh"

# ---------------------------------------------------------------------------
# Hermeticity barriers (#477).
#  1. PATH: the mock is prepended for the WHOLE suite, not only inside
#     run_audit, so no invocation anywhere — including every argument-error
#     case — can resolve the real `gh`, whatever the script under test does.
#     Before this, the argument-error cases ran bare and stayed hermetic only
#     as long as the arg guards fired first; deleting a guard (exactly what
#     tests/README.md's mutation-probe workflow asks for) reached the real,
#     authenticated API instead of failing an assertion.
#  2. Tripwire: the mock logs every invocation to MOCK_GH_CALL_LOG and marks
#     any call arriving without the harness env as UNMOCKED-CONTEXT; the end
#     of this file asserts the log holds no such line and that `gh` still
#     resolves to the mock.
# ---------------------------------------------------------------------------
REAL_GH="$(command -v gh || true)"
export PATH="$BIN:$PATH"
export MOCK_GH_CALL_LOG="$WORK/gh-calls.log"
: > "$MOCK_GH_CALL_LOG"
[ "$(command -v gh)" = "$BIN/gh" ] \
  || report "hermeticity: gh resolves to $(command -v gh), expected the mock at $BIN/gh"

# ---------------------------------------------------------------------------
# The mock refuses a write verb outright — sanity-check the harness itself.
# ---------------------------------------------------------------------------
QLOG="$WORK/query.log"; : > "$QLOG"
set +e
MOCK_GH_FIXTURES="$DIRTY" MOCK_GH_QUERY_LOG="$QLOG" PATH="$BIN:$PATH" \
  gh api -X POST "repos/$REPO_DIRTY/issues" >/dev/null 2>"$OUT/writeverb.stderr.log"
rc=$?
set -e
[ "$rc" -ne 0 ] || report "mock gh: expected non-GET (-X POST) to fail, exit 0"
grep -qi 'refusing non-GET' "$OUT/writeverb.stderr.log" \
  || report "mock gh: expected a 'refusing non-GET' message, got: $(cat "$OUT/writeverb.stderr.log")"

# ---------------------------------------------------------------------------
# The mock also refuses an *implicit* write — real `gh api` sends POST on its
# own when -f/-F is given with no explicit -X, which is how a mutation would
# most naturally be written. This is the reviewer's exact round-1 probe.
# (finding 2)
# ---------------------------------------------------------------------------
set +e
MOCK_GH_FIXTURES="$DIRTY" MOCK_GH_QUERY_LOG="$QLOG" PATH="$BIN:$PATH" \
  gh api "repos/$REPO_DIRTY/issues?state=open&x=1" -f labels=bug \
  >/dev/null 2>"$OUT/implicitwrite.stderr.log"
rc=$?
set -e
[ "$rc" -ne 0 ] || report "mock gh: expected implicit-POST (-f with no -X) to fail, exit 0"
grep -qi 'refusing non-GET' "$OUT/implicitwrite.stderr.log" \
  || report "mock gh: expected a 'refusing non-GET' message for implicit -f write, got: $(cat "$OUT/implicitwrite.stderr.log")"

# A GraphQL call with -f/-F but no -X is the one exception — it must still
# be treated as a legitimate read (the endpoint case dispatch, not this
# refusal, decides whether its query text is a `query` or a `mutation`).
set +e
MOCK_GH_FIXTURES="$DIRTY" MOCK_GH_QUERY_LOG="$QLOG" PATH="$BIN:$PATH" \
  gh api graphql -f query='query { viewer { login } }' \
  >/dev/null 2>"$OUT/graphqlnoflag.stderr.log"
rc=$?
set -e
[ "$rc" -eq 0 ] || report "mock gh: graphql with -f/-F and no -X should still be treated as GET, got exit $rc: $(cat "$OUT/graphqlnoflag.stderr.log")"

# ---------------------------------------------------------------------------
# Run board-audit.sh under test.
# ---------------------------------------------------------------------------
run_audit(){ # run_audit <fixtures-dir> <querylog> <args...>
  local fixtures="$1" qlog="$2"; shift 2
  local rc=0
  set +e
  MOCK_GH_FIXTURES="$fixtures" MOCK_GH_QUERY_LOG="$qlog" PATH="$BIN:$PATH" \
    "$BOARD_AUDIT_SH" "$@" > "$OUT/run.stdout.log" 2> "$OUT/run.stderr.log"
  rc=$?
  set -e
  if [ "$rc" -ne 0 ]; then
    echo "run_audit $*: exited $rc" >&2
    echo "--- stdout ---" >&2; cat "$OUT/run.stdout.log" >&2 || true
    echo "--- stderr ---" >&2; cat "$OUT/run.stderr.log" >&2 || true
    report "board-audit.sh exited $rc for args: $*"
  fi
}

# run_argerr <expected-exit> <label> <args...>
# Every negative case (argument errors and refusals alike) goes through here,
# so it runs under the same mock `gh` the success paths use and can never
# reach the network — not even if the guard it is testing is deleted (#477).
# Fixtures default to $DIRTY; override per call with RUN_ARGERR_FIXTURES=...
# stdout/stderr land in $OUT/<label>.{stdout,stderr}.log for the caller to
# grep for a reason.
run_argerr(){
  local expect="$1" label="$2"; shift 2
  local fixtures="${RUN_ARGERR_FIXTURES:-$DIRTY}"
  local rc=0
  if grep -qxF "$label" "$LABELS_SEEN" 2>/dev/null; then
    report "run_argerr: duplicate label '$label' would overwrite a previous case's $OUT artifact"
  fi
  printf '%s\n' "$label" >> "$LABELS_SEEN"
  set +e
  MOCK_GH_FIXTURES="$fixtures" MOCK_GH_QUERY_LOG="$QLOG" PATH="$BIN:$PATH" \
    "$BOARD_AUDIT_SH" "$@" >"$OUT/$label.stdout.log" 2>"$OUT/$label.stderr.log"
  rc=$?
  set -e
  [ "$rc" -eq "$expect" ] \
    || report "$label: expected exit $expect, got $rc: $(cat "$OUT/$label.stderr.log")"
}

# --- Dirty scenario: a missing item and a foreign-homed item are reported.
: > "$QLOG"
run_audit "$DIRTY" "$QLOG" --repo "$REPO_DIRTY" --target 5 --since "$SINCE" \
  --work-tracking "$WT_DIRTY"
JSON_OUT="$OUT/run.stdout.log"

if jq -e . "$JSON_OUT" >/dev/null 2>&1; then
  n_missing=$(jq '.missing_board_items|length' "$JSON_OUT")
  [ "$n_missing" = "1" ] || report "dirty: expected 1 missing_board_items, got $n_missing"
  missing_num=$(jq -r '.missing_board_items[0].number' "$JSON_OUT")
  [ "$missing_num" = "12" ] || report "dirty: expected missing issue #12, got #$missing_num"

  n_homed=$(jq '.homed_by_others|length' "$JSON_OUT")
  [ "$n_homed" = "2" ] || report "dirty: expected 2 homed_by_others candidates, got $n_homed"
  actors=$(jq -r '[.homed_by_others[].actor]|sort|join(",")' "$JSON_OUT")
  [ "$actors" = "machine-bot,user-a" ] || report "dirty: expected actors machine-bot,user-a, got $actors"
  # the pre-since event must never appear
  ! jq -e '.homed_by_others[]|select(.created_at=="2025-12-01T00:00:00Z")' "$JSON_OUT" >/dev/null 2>&1 \
    || report "dirty: a pre-since event leaked into homed_by_others"

  heuristic=$(jq -r .heuristic "$JSON_OUT")
  case "$heuristic" in since_only*) ;; *) report "dirty: expected a since_only heuristic, got: $heuristic" ;; esac

  # --- missing_size_label (#733): #12 (no labels at all) and #15 (the
  # near-miss `sized` label) are missing a size:* label; #10/#11/#13/#14 all
  # carry one.
  n_missing_size=$(jq '.missing_size_label|length' "$JSON_OUT")
  [ "$n_missing_size" = "2" ] || report "dirty: expected 2 missing_size_label, got $n_missing_size"
  missing_size_nums=$(jq -r '[.missing_size_label[].number]|sort|join(",")' "$JSON_OUT")
  [ "$missing_size_nums" = "12,15" ] || report "dirty: expected missing_size_label #12,#15, got $missing_size_nums"

  # --- bad_priority_label (#745): #11 (two priority labels) and #12 (zero).
  n_bad_priority=$(jq '.bad_priority_label|length' "$JSON_OUT")
  [ "$n_bad_priority" = "2" ] || report "dirty: expected 2 bad_priority_label, got $n_bad_priority"
  bad_priority_nums=$(jq -r '[.bad_priority_label[].number]|sort|join(",")' "$JSON_OUT")
  [ "$bad_priority_nums" = "11,12" ] || report "dirty: expected bad_priority_label #11,#12, got $bad_priority_nums"
  p11_count=$(jq -r '.bad_priority_label[]|select(.number==11)|.priority_count' "$JSON_OUT")
  [ "$p11_count" = "2" ] || report "dirty: expected #11 priority_count=2, got $p11_count"
  p12_count=$(jq -r '.bad_priority_label[]|select(.number==12)|.priority_count' "$JSON_OUT")
  [ "$p12_count" = "0" ] || report "dirty: expected #12 priority_count=0, got $p12_count"

  # --- bad_severity_label (#745): #13 (bug, zero severity) and #14 (two
  # severity labels, not a bug — the multiplicity leg has no type carve-out).
  n_bad_severity=$(jq '.bad_severity_label|length' "$JSON_OUT")
  [ "$n_bad_severity" = "2" ] || report "dirty: expected 2 bad_severity_label, got $n_bad_severity"
  bad_severity_nums=$(jq -r '[.bad_severity_label[].number]|sort|join(",")' "$JSON_OUT")
  [ "$bad_severity_nums" = "13,14" ] || report "dirty: expected bad_severity_label #13,#14, got $bad_severity_nums"
  s13_count=$(jq -r '.bad_severity_label[]|select(.number==13)|.severity_count' "$JSON_OUT")
  [ "$s13_count" = "0" ] || report "dirty: expected #13 severity_count=0, got $s13_count"
  s14_count=$(jq -r '.bad_severity_label[]|select(.number==14)|.severity_count' "$JSON_OUT")
  [ "$s14_count" = "2" ] || report "dirty: expected #14 severity_count=2, got $s14_count"
  # #10 (size:m, priority:high, no severity, not a bug) must never appear in
  # any of the three label-audit lists — the well-formed control case.
  jq -e '.missing_size_label[]|select(.number==10)' "$JSON_OUT" >/dev/null 2>&1 \
    && report "dirty: #10 unexpectedly in missing_size_label"
  jq -e '.bad_priority_label[]|select(.number==10)' "$JSON_OUT" >/dev/null 2>&1 \
    && report "dirty: #10 unexpectedly in bad_priority_label"
  jq -e '.bad_severity_label[]|select(.number==10)' "$JSON_OUT" >/dev/null 2>&1 \
    && report "dirty: #10 unexpectedly in bad_severity_label"

  # --- bad_claim_form (#744): #13 (no " @ ") and #15 (the marker in the
  # wrong case — the near-miss) are malformed; #10 (well-formed lock) and
  # #11 (well-formed stamp) are the positive controls proving the marker
  # itself is not what trips the check, and #14 (no claim at all) proves an
  # empty value is never flagged.
  n_bad_claim=$(jq '.bad_claim_form|length' "$JSON_OUT")
  [ "$n_bad_claim" = "2" ] || report "dirty: expected 2 bad_claim_form, got $n_bad_claim"
  bad_claim_nums=$(jq -r '[.bad_claim_form[].number]|sort|join(",")' "$JSON_OUT")
  [ "$bad_claim_nums" = "13,15" ] || report "dirty: expected bad_claim_form #13,#15, got $bad_claim_nums"
  c13_val=$(jq -r '.bad_claim_form[]|select(.number==13)|.claimed_by' "$JSON_OUT")
  [ "$c13_val" = "acme-01 2026-08-29T15:10Z" ] || report "dirty: expected #13 claimed_by echoed verbatim, got $c13_val"
  c15_val=$(jq -r '.bad_claim_form[]|select(.number==15)|.claimed_by' "$JSON_OUT")
  [ "$c15_val" = "acme-01 @ 2026-08-29T15:10Z (STAMP)" ] || report "dirty: expected #15 claimed_by echoed verbatim, got $c15_val"
  jq -e '.bad_claim_form[]|select(.number==10)' "$JSON_OUT" >/dev/null 2>&1 \
    && report "dirty: #10 (well-formed lock) unexpectedly in bad_claim_form"
  jq -e '.bad_claim_form[]|select(.number==11)' "$JSON_OUT" >/dev/null 2>&1 \
    && report "dirty: #11 (well-formed stamp) unexpectedly in bad_claim_form"
  jq -e '.bad_claim_form[]|select(.number==14)' "$JSON_OUT" >/dev/null 2>&1 \
    && report "dirty: #14 (no claim) unexpectedly in bad_claim_form"
else
  report "dirty: stdout is not valid JSON: $(cat "$JSON_OUT")"
fi

# --- Clean scenario: nothing reported, including the three label audits.
: > "$QLOG"
run_audit "$CLEAN" "$QLOG" --repo "$REPO_CLEAN" --target 6 --since "$SINCE" \
  --work-tracking "$WT_CLEAN"
JSON_OUT="$OUT/run.stdout.log"
if jq -e . "$JSON_OUT" >/dev/null 2>&1; then
  n_missing=$(jq '.missing_board_items|length' "$JSON_OUT")
  [ "$n_missing" = "0" ] || report "clean: expected 0 missing_board_items, got $n_missing"
  n_homed=$(jq '.homed_by_others|length' "$JSON_OUT")
  [ "$n_homed" = "0" ] || report "clean: expected 0 homed_by_others, got $n_homed"
  n_missing_size=$(jq '.missing_size_label|length' "$JSON_OUT")
  [ "$n_missing_size" = "0" ] || report "clean: expected 0 missing_size_label, got $n_missing_size"
  n_bad_priority=$(jq '.bad_priority_label|length' "$JSON_OUT")
  [ "$n_bad_priority" = "0" ] || report "clean: expected 0 bad_priority_label, got $n_bad_priority"
  n_bad_severity=$(jq '.bad_severity_label|length' "$JSON_OUT")
  [ "$n_bad_severity" = "0" ] || report "clean: expected 0 bad_severity_label, got $n_bad_severity"
  n_bad_claim=$(jq '.bad_claim_form|length' "$JSON_OUT")
  [ "$n_bad_claim" = "0" ] || report "clean: expected 0 bad_claim_form, got $n_bad_claim"
else
  report "clean: stdout is not valid JSON: $(cat "$JSON_OUT")"
fi

# --- GraphQL query text is a read: never a mutation.
grep -qi 'mutation' "$QLOG" && report "graphql query text contains 'mutation' — expected a query-only read"
grep -qi 'query(' "$QLOG" || report "graphql query text missing an operation named query(...)"

# ---------------------------------------------------------------------------
# --markdown: both sections and their counts appear, the heuristic's limits
# are restated (finding 4), and each list is capped with a "+K more, see
# JSON" trailer once it exceeds --max-rows (finding 5).
# ---------------------------------------------------------------------------
: > "$QLOG"
run_audit "$DIRTY" "$QLOG" --repo "$REPO_DIRTY" --target 5 --since "$SINCE" \
  --work-tracking "$WT_DIRTY" --markdown
MD_OUT="$OUT/run.stdout.log"
grep -qE 'Missing board items: 1' "$MD_OUT" || report "--markdown: missing 'Missing board items: 1'"
grep -qF '#12' "$MD_OUT" || report "--markdown: missing #12 in the missing-items list"
grep -qE 'others: 2' "$MD_OUT" || report "--markdown: missing homed_by_others count 2"
grep -qE 'Missing size:\* label: 2' "$MD_OUT" || report "--markdown: missing 'Missing size:* label: 2'"
SIZE_SECTION=$(awk '/^- Missing size:\* label:/{flag=1} /^- Not exactly one priority/{flag=0} flag' "$MD_OUT")
grep -qF '#12' <<<"$SIZE_SECTION" || report "--markdown: missing #12 in the missing-size-label list"
grep -qF '#15' <<<"$SIZE_SECTION" || report "--markdown: missing #15 (near-miss sized label) in the missing-size-label list"
grep -qE 'Not exactly one priority:\* label: 2' "$MD_OUT" \
  || report "--markdown: missing 'Not exactly one priority:* label: 2'"
grep -qF 'priority_count=2' "$MD_OUT" || report "--markdown: missing #11's priority_count=2 detail"
grep -qF 'priority_count=0' "$MD_OUT" || report "--markdown: missing #12's priority_count=0 detail"
grep -qE 'Bad severity:\* label.*: 2' "$MD_OUT" || report "--markdown: missing the bad-severity-label count 2"
grep -qF 'severity_count=0' "$MD_OUT" || report "--markdown: missing #13's severity_count=0 detail"
grep -qF 'severity_count=2' "$MD_OUT" || report "--markdown: missing #14's severity_count=2 detail"
grep -qE '^> Limits:' "$MD_OUT" || report "--markdown: missing the 'Limits:' line"
grep -qi 'this same run' "$MD_OUT" || report "--markdown: Limits line omits the own-session (since_only) caveat"
grep -qi 'invisible' "$MD_OUT" || report "--markdown: Limits line omits the board/sub-issue invisibility caveat"
# default --max-rows (20) does not truncate this fixture's 1/2-item lists
grep -qi 'more, see JSON' "$MD_OUT" && report "--markdown: unexpected truncation trailer under default --max-rows"

# --max-rows 1: both lists (1 missing, 2 homed) now get capped — the homed
# list must show the trailer, the missing list must not (it has exactly 1).
: > "$QLOG"
run_audit "$DIRTY" "$QLOG" --repo "$REPO_DIRTY" --target 5 --since "$SINCE" \
  --work-tracking "$WT_DIRTY" --markdown --max-rows 1
MDCAP_OUT="$OUT/run.stdout.log"
grep -qE '…and 1 more, see JSON' "$MDCAP_OUT" \
  || report "--markdown --max-rows 1: expected a '…and 1 more, see JSON' trailer on the homed list"

# ---------------------------------------------------------------------------
# --log: appends one session-log-format line (`note` event, ts/event/claim
# all present, claim null when --claim was not passed) plus the structured
# counts; without --log the line goes to stderr, and stdout stays pure JSON
# either way. (finding 1)
# ---------------------------------------------------------------------------
LOG_FILE="$WORK/session.jsonl"
: > "$QLOG"
run_audit "$DIRTY" "$QLOG" --repo "$REPO_DIRTY" --target 5 --since "$SINCE" \
  --work-tracking "$WT_DIRTY" --log "$LOG_FILE"
[ -s "$LOG_FILE" ] || report "--log: expected a non-empty log file"
n_lines=$(wc -l < "$LOG_FILE")
[ "$n_lines" = "1" ] || report "--log: expected exactly 1 line, got $n_lines"
if [ -s "$LOG_FILE" ]; then
  logrec=$(tail -1 "$LOG_FILE")
  jq -e . <<<"$logrec" >/dev/null 2>&1 || report "--log: line is not valid JSON: $logrec"
  [ "$(jq -r .event <<<"$logrec")" = "note" ] || report "--log: expected event=note, got: $logrec"
  [ "$(jq -r 'has("ts")' <<<"$logrec")" = "true" ] || report "--log: missing required key ts: $logrec"
  [ "$(jq -r 'has("claim")' <<<"$logrec")" = "true" ] || report "--log: missing required key claim: $logrec"
  [ "$(jq -r .claim <<<"$logrec")" = "null" ] || report "--log: expected claim=null (no --claim passed), got: $logrec"
  [ "$(jq -r .counts.missing_board_items <<<"$logrec")" = "1" ] || report "--log: expected counts.missing_board_items=1, got: $logrec"
  [ "$(jq -r .counts.homed_by_others <<<"$logrec")" = "2" ] || report "--log: expected counts.homed_by_others=2, got: $logrec"
  [ "$(jq -r .counts.missing_size_label <<<"$logrec")" = "2" ] || report "--log: expected counts.missing_size_label=2, got: $logrec"
  [ "$(jq -r .counts.bad_priority_label <<<"$logrec")" = "2" ] || report "--log: expected counts.bad_priority_label=2, got: $logrec"
  [ "$(jq -r .counts.bad_severity_label <<<"$logrec")" = "2" ] || report "--log: expected counts.bad_severity_label=2, got: $logrec"
fi
jq -e . "$OUT/run.stdout.log" >/dev/null 2>&1 || report "--log: stdout must still be pure JSON"

# --log with --claim: the log line's claim must carry it through.
: > "$QLOG"
run_audit "$DIRTY" "$QLOG" --repo "$REPO_DIRTY" --target 5 --since "$SINCE" \
  --work-tracking "$WT_DIRTY" --log "$LOG_FILE" --claim waypoint-01
logrec=$(tail -1 "$LOG_FILE")
[ "$(jq -r .claim <<<"$logrec")" = "waypoint-01" ] || report "--log --claim: expected claim=waypoint-01, got: $logrec"

: > "$QLOG"
run_audit "$DIRTY" "$QLOG" --repo "$REPO_DIRTY" --target 5 --since "$SINCE" \
  --work-tracking "$WT_DIRTY"
grep -q '"event":"note"' "$OUT/run.stderr.log" \
  || report "no --log: expected the event line on stderr, got: $(cat "$OUT/run.stderr.log")"
! grep -q '"event":"note"' "$OUT/run.stdout.log" \
  || report "no --log: the event line must never land on stdout"

# ---------------------------------------------------------------------------
# Argument errors: --target without --since, and an unknown flag, both exit
# 2. Run through run_argerr, i.e. under the mock — the guard firing before
# the first gh call is the behaviour under test, not the thing keeping the
# case hermetic (#477).
# ---------------------------------------------------------------------------
run_argerr 2 noargsince --target 5
run_argerr 2 badflag --bogus-flag

# ---------------------------------------------------------------------------
# --since validation (#330): a non-conforming value is a hard argument error,
# and the comparison against created_at is epoch-based, not lexical, so a
# --since value exactly equal to an event's created_at is included (>=).
# ---------------------------------------------------------------------------
run_argerr 2 badsince --repo "$REPO_DIRTY" --target 5 --since "2026-01-01T00:00:00+02:00" \
  --work-tracking "$WT_DIRTY"
grep -qi -- '--since' "$OUT/badsince.stderr.log" \
  || report "--since with a non-Z offset: expected a --since-naming error, got: $(cat "$OUT/badsince.stderr.log")"

# Same-instant boundary: --since exactly equal to the milestoned-by-user-a
# event's created_at (2026-01-01T05:00:00Z) must still include that event
# (>=, not >), and the later labeled event too.
: > "$QLOG"
run_audit "$DIRTY" "$QLOG" --repo "$REPO_DIRTY" --target 5 --since "2026-01-01T05:00:00Z" \
  --work-tracking "$WT_DIRTY"
BOUNDARY_OUT="$OUT/run.stdout.log"
if jq -e . "$BOUNDARY_OUT" >/dev/null 2>&1; then
  n_homed=$(jq '.homed_by_others|length' "$BOUNDARY_OUT")
  [ "$n_homed" = "2" ] \
    || report "--since same-instant boundary: expected 2 homed_by_others (inclusive), got $n_homed"
else
  report "--since same-instant boundary: stdout is not valid JSON: $(cat "$BOUNDARY_OUT")"
fi

# Date-only form is accepted (midnight UTC) — same result as the full-Z form.
: > "$QLOG"
run_audit "$DIRTY" "$QLOG" --repo "$REPO_DIRTY" --target 5 --since "2026-01-01" \
  --work-tracking "$WT_DIRTY"
DATEONLY_OUT="$OUT/run.stdout.log"
if jq -e . "$DATEONLY_OUT" >/dev/null 2>&1; then
  n_homed=$(jq '.homed_by_others|length' "$DATEONLY_OUT")
  [ "$n_homed" = "2" ] || report "--since date-only: expected 2 homed_by_others, got $n_homed"
else
  report "--since date-only: stdout is not valid JSON: $(cat "$DATEONLY_OUT")"
fi

# ===========================================================================
# Epic-target branch (#317): a --target whose milestone lookup 404s is tried
# as an epic issue number instead — sub_issues served, not a milestone
# listing. Also exercises target_kind="epic" in JSON/--markdown/--log (#327).
# ===========================================================================
EPIC="$WORK/fixtures-epic"
mkdir -p "$EPIC"
REPO_EPIC="test-org/epic-repo"
cat > "$EPIC/open_issues_page1.json" <<'JSON'
[{"number":40,"title":"issue forty","html_url":"https://example.invalid/40"}]
JSON
cat > "$EPIC/open_issues_page2.json" <<'JSON'
[]
JSON
cat > "$EPIC/project_items_page1.json" <<'JSON'
{"data":{"node":{"items":{"pageInfo":{"hasNextPage":false,"endCursor":null},
  "nodes":[{"id":"ITEM4","content":{"number":40,"repository":{"nameWithOwner":"test-org/epic-repo"}}}]}}}}
JSON
# No milestone.json -> the milestone lookup 404s, falling through to epic.
cat > "$EPIC/epic_99.json" <<'JSON'
{"number":99,"pull_request":null}
JSON
cat > "$EPIC/sub_issues_99.json" <<'JSON'
[{"number":50,"updated_at":"2026-01-01T06:00:00Z"}]
JSON
cat > "$EPIC/timeline_50.json" <<'JSON'
[{"event":"milestoned","actor":{"login":"user-a"},"created_at":"2026-01-01T05:30:00Z"}]
JSON

: > "$QLOG"
run_audit "$EPIC" "$QLOG" --repo "$REPO_EPIC" --target 99 --since "$SINCE" \
  --work-tracking "$WT_DIRTY"
EPIC_OUT="$OUT/run.stdout.log"
if jq -e . "$EPIC_OUT" >/dev/null 2>&1; then
  [ "$(jq -r .target_kind "$EPIC_OUT")" = "epic" ] \
    || report "epic-target: expected target_kind=epic, got: $(jq -r .target_kind "$EPIC_OUT")"
  n_homed=$(jq '.homed_by_others|length' "$EPIC_OUT")
  [ "$n_homed" = "1" ] || report "epic-target: expected 1 homed_by_others, got $n_homed"
else
  report "epic-target: stdout is not valid JSON: $(cat "$EPIC_OUT")"
fi

: > "$QLOG"
run_audit "$EPIC" "$QLOG" --repo "$REPO_EPIC" --target 99 --since "$SINCE" \
  --work-tracking "$WT_DIRTY" --markdown
EPIC_MD="$OUT/run.stdout.log"
grep -qE '^- Target: #99 \(epic\)' "$EPIC_MD" \
  || report "epic-target --markdown: expected '- Target: #99 (epic)' line"

# --epic forces the kind outright, skipping the milestone probe entirely —
# proven by never providing a milestone.json for this fixture set at all.
: > "$QLOG"
run_audit "$EPIC" "$QLOG" --repo "$REPO_EPIC" --epic 99 --since "$SINCE" \
  --work-tracking "$WT_DIRTY"
EPICFLAG_OUT="$OUT/run.stdout.log"
[ "$(jq -r .target_kind "$EPICFLAG_OUT" 2>/dev/null)" = "epic" ] \
  || report "--epic: expected target_kind=epic, got: $(cat "$EPICFLAG_OUT")"

# --milestone forces the milestone kind outright on the (unrelated) dirty
# fixture set, where a bare --target already resolves to milestone anyway —
# proves the flag path is reachable and produces the same target_kind.
: > "$QLOG"
run_audit "$DIRTY" "$QLOG" --repo "$REPO_DIRTY" --milestone 5 --since "$SINCE" \
  --work-tracking "$WT_DIRTY"
MSFLAG_OUT="$OUT/run.stdout.log"
[ "$(jq -r .target_kind "$MSFLAG_OUT" 2>/dev/null)" = "milestone" ] \
  || report "--milestone: expected target_kind=milestone, got: $(cat "$MSFLAG_OUT")"

# ===========================================================================
# The ambiguous --target (#327 AC3): a number that is BOTH a milestone and an
# issue in the same repository. This fixture set serves milestone.json for
# number 30 AND epic_30.json for issue 30, so either interpretation would
# resolve — which is exactly the collision #327's Summary describes ("milestone
# 2 and issue 2 both exist ... --target 2 silently resolves to the milestone").
# Bare --target must take the milestone, per the milestone-wins precedence the
# script header states. The two interpretations lead to disjoint member issues
# (#31 via the milestone listing, #32 via sub_issues) with disjoint timeline
# actors, so the assertion below pins WHICH endpoint was consulted, not just
# the label: reordering the resolution chain to try issues/ first fails it.
# ===========================================================================
AMBIG="$WORK/fixtures-ambig"
mkdir -p "$AMBIG"
REPO_AMBIG="test-org/ambig-repo"
cat > "$AMBIG/open_issues_page1.json" <<'JSON'
[{"number":30,"title":"issue thirty","html_url":"https://example.invalid/30"}]
JSON
cat > "$AMBIG/open_issues_page2.json" <<'JSON'
[]
JSON
cat > "$AMBIG/project_items_page1.json" <<'JSON'
{"data":{"node":{"items":{"pageInfo":{"hasNextPage":false,"endCursor":null},
  "nodes":[{"id":"ITEM7","content":{"number":30,"repository":{"nameWithOwner":"test-org/ambig-repo"}}}]}}}}
JSON
# Milestone 30 exists...
cat > "$AMBIG/milestone.json" <<'JSON'
{"number":30,"title":"milestone thirty"}
JSON
cat > "$AMBIG/milestone_issues.json" <<'JSON'
[{"number":31,"title":"i31","pull_request":null,"updated_at":"2026-01-01T06:00:00Z"}]
JSON
# ...and issue 30 exists too, with its own sub-issues: the collision.
cat > "$AMBIG/epic_30.json" <<'JSON'
{"number":30,"pull_request":null}
JSON
cat > "$AMBIG/sub_issues_30.json" <<'JSON'
[{"number":32,"title":"i32","updated_at":"2026-01-01T06:00:00Z"}]
JSON
cat > "$AMBIG/timeline_31.json" <<'JSON'
[{"event":"milestoned","actor":{"login":"user-milestone-side"},"created_at":"2026-01-01T06:30:00Z"}]
JSON
cat > "$AMBIG/timeline_32.json" <<'JSON'
[{"event":"milestoned","actor":{"login":"user-epic-side"},"created_at":"2026-01-01T06:30:00Z"}]
JSON

: > "$QLOG"
run_audit "$AMBIG" "$QLOG" --repo "$REPO_AMBIG" --target 30 --since "$SINCE" \
  --work-tracking "$WT_DIRTY"
AMBIG_OUT="$OUT/run.stdout.log"
if jq -e . "$AMBIG_OUT" >/dev/null 2>&1; then
  [ "$(jq -r .target_kind "$AMBIG_OUT")" = "milestone" ] \
    || report "ambiguous --target 30: expected target_kind=milestone (milestone wins on collision), got: $(jq -r .target_kind "$AMBIG_OUT")"
  actors=$(jq -r '[.homed_by_others[].actor]|sort|join(",")' "$AMBIG_OUT")
  [ "$actors" = "user-milestone-side" ] \
    || report "ambiguous --target 30: expected the milestone listing's member to be walked (user-milestone-side), got: $actors"
  ! jq -e '.homed_by_others[]|select(.actor=="user-epic-side")' "$AMBIG_OUT" >/dev/null 2>&1 \
    || report "ambiguous --target 30: the epic (sub_issues) interpretation was used — milestone-wins precedence inverted"
else
  report "ambiguous --target 30: stdout is not valid JSON: $(cat "$AMBIG_OUT")"
fi

# The same fixture resolves as an epic when the caller forces it, proving the
# issue-30 side of the collision genuinely exists (otherwise the assertion
# above would pass for the trivial reason that only one interpretation is
# servable, which is what made the pre-existing $DIRTY/$EPIC fixtures unable
# to cover this criterion).
: > "$QLOG"
run_audit "$AMBIG" "$QLOG" --repo "$REPO_AMBIG" --epic 30 --since "$SINCE" \
  --work-tracking "$WT_DIRTY"
AMBIG_EPIC_OUT="$OUT/run.stdout.log"
[ "$(jq -r .target_kind "$AMBIG_EPIC_OUT" 2>/dev/null)" = "epic" ] \
  || report "--epic 30 on the ambiguous fixture: expected target_kind=epic, got: $(cat "$AMBIG_EPIC_OUT")"
[ "$(jq -r '[.homed_by_others[].actor]|join(",")' "$AMBIG_EPIC_OUT" 2>/dev/null)" = "user-epic-side" ] \
  || report "--epic 30 on the ambiguous fixture: expected the sub_issues member to be walked (user-epic-side)"

# --target/--milestone/--epic are mutually exclusive.
run_argerr 2 mutex1 --target 5 --milestone 5 --since "$SINCE"
run_argerr 2 mutex2 --epic 5 --milestone 5 --since "$SINCE"

# A pull-request number resolved as an epic is refused, never treated as one.
cat > "$EPIC/epic_77.json" <<'JSON'
{"number":77,"pull_request":{"url":"https://example.invalid/pulls/77"}}
JSON
RUN_ARGERR_FIXTURES="$EPIC" run_argerr 1 prasepic --repo "$REPO_EPIC" --epic 77 \
  --since "$SINCE" --work-tracking "$WT_DIRTY"
grep -qi 'pull request' "$OUT/prasepic.stderr.log" \
  || report "--epic on a PR number: expected a pull-request-naming reason, got: $(cat "$OUT/prasepic.stderr.log")"

# ===========================================================================
# actor_filter branch, corrected semantics (#317): --work-tracking names a
# second/reviewer account -> events are excluded when their actor is the
# AUTOMATION account (this session's own identity), not the reviewer
# account. Both the reviewer account's own event and a third party's event
# must survive the filter; only the automation account's event is dropped.
# ===========================================================================
WT_ACTOR="$WORK/work-tracking-actor.md"
cat > "$WT_ACTOR" <<'MD'
| Layer | Here |
|---|---|
| Project board | [Global Unassigned #6](https://example.invalid/6) — owner `test-org`; automation account `machine-bot` (admin) |

| Field | Id |
|---|---|
| Project | `PVT_test789` |

Reviewer identity: `reviewer-x`.
MD

ACTOR="$WORK/fixtures-actor"
mkdir -p "$ACTOR"
REPO_ACTOR="test-org/actor-repo"
cat > "$ACTOR/open_issues_page1.json" <<'JSON'
[{"number":70,"title":"issue seventy","html_url":"https://example.invalid/70"}]
JSON
cat > "$ACTOR/open_issues_page2.json" <<'JSON'
[]
JSON
cat > "$ACTOR/project_items_page1.json" <<'JSON'
{"data":{"node":{"items":{"pageInfo":{"hasNextPage":false,"endCursor":null},
  "nodes":[{"id":"ITEM5","content":{"number":70,"repository":{"nameWithOwner":"test-org/actor-repo"}}}]}}}}
JSON
cat > "$ACTOR/milestone.json" <<'JSON'
{"number":15,"title":"milestone fifteen"}
JSON
cat > "$ACTOR/milestone_issues.json" <<'JSON'
[{"number":71,"title":"issue seventy-one","pull_request":null,"updated_at":"2026-01-01T06:00:00Z"}]
JSON
cat > "$ACTOR/timeline_71.json" <<JSON
[
  {"event":"milestoned","actor":{"login":"machine-bot"},"created_at":"2026-01-01T05:00:00Z"},
  {"event":"milestoned","actor":{"login":"reviewer-x"},"created_at":"2026-01-01T05:10:00Z"},
  {"event":"labeled","actor":{"login":"user-c"},"created_at":"2026-01-01T05:20:00Z"}
]
JSON

: > "$QLOG"
run_audit "$ACTOR" "$QLOG" --repo "$REPO_ACTOR" --target 15 --since "$SINCE" \
  --work-tracking "$WT_ACTOR"
ACTOR_OUT="$OUT/run.stdout.log"
if jq -e . "$ACTOR_OUT" >/dev/null 2>&1; then
  heuristic=$(jq -r .heuristic "$ACTOR_OUT")
  case "$heuristic" in
    actor_filter*machine-bot*) ;;
    *) report "actor_filter: expected heuristic to name machine-bot as excluded, got: $heuristic" ;;
  esac
  n_homed=$(jq '.homed_by_others|length' "$ACTOR_OUT")
  [ "$n_homed" = "2" ] || report "actor_filter: expected 2 homed_by_others (reviewer-x, user-c), got $n_homed"
  actors=$(jq -r '[.homed_by_others[].actor]|sort|join(",")' "$ACTOR_OUT")
  [ "$actors" = "reviewer-x,user-c" ] || report "actor_filter: expected actors reviewer-x,user-c, got $actors"
  ! jq -e '.homed_by_others[]|select(.actor=="machine-bot")' "$ACTOR_OUT" >/dev/null 2>&1 \
    || report "actor_filter: the automation account's own event leaked into homed_by_others"
else
  report "actor_filter: stdout is not valid JSON: $(cat "$ACTOR_OUT")"
fi

# --work-tracking naming a second account with no automation account line is
# a refused configuration, not a silent no-op filter.
WT_NOAUTO="$WORK/work-tracking-noauto.md"
cat > "$WT_NOAUTO" <<'MD'
| Field | Id |
|---|---|
| Project | `PVT_testNOA` |

Reviewer identity: `reviewer-x`.
MD
RUN_ARGERR_FIXTURES="$ACTOR" run_argerr 1 noauto --repo "$REPO_ACTOR" --target 15 \
  --since "$SINCE" --work-tracking "$WT_NOAUTO"
grep -qi 'automation account' "$OUT/noauto.stderr.log" \
  || report "second account with no automation account: expected an automation-account-naming reason, got: $(cat "$OUT/noauto.stderr.log")"

# ...but ONLY on runs that reach part (b). A part-(a)-only run (no --target)
# never consults the automation account, so the same configuration must keep
# working there — exit 0 with a full missing_board_items report (#478).
: > "$QLOG"
run_audit "$ACTOR" "$QLOG" --repo "$REPO_ACTOR" --work-tracking "$WT_NOAUTO"
NOAUTO_A_OUT="$OUT/run.stdout.log"
if jq -e . "$NOAUTO_A_OUT" >/dev/null 2>&1; then
  jq -e 'has("missing_board_items")' "$NOAUTO_A_OUT" >/dev/null \
    || report "part-(a)-only with no automation account: missing_board_items key absent"
  [ "$(jq -r '.homed_by_others|length' "$NOAUTO_A_OUT")" = "0" ] \
    || report "part-(a)-only with no automation account: expected an empty homed_by_others"
  case "$(jq -r .heuristic "$NOAUTO_A_OUT")" in
    n/a*) ;;
    *) report "part-(a)-only: expected the n/a heuristic, got: $(jq -r .heuristic "$NOAUTO_A_OUT")" ;;
  esac
else
  report "part-(a)-only with no automation account: stdout is not valid JSON: $(cat "$NOAUTO_A_OUT")"
fi

# --markdown Limits wording matches the heuristic that actually ran: the
# actor_filter branch's caveat sentence, never the since_only-specific one.
: > "$QLOG"
run_audit "$ACTOR" "$QLOG" --repo "$REPO_ACTOR" --target 15 --since "$SINCE" \
  --work-tracking "$WT_ACTOR" --markdown
ACTOR_MD="$OUT/run.stdout.log"
grep -qi "session's own noise" "$ACTOR_MD" \
  || report "actor_filter --markdown: Limits line missing the actor_filter-specific caveat"
grep -qi 'this same run' "$ACTOR_MD" \
  && report "actor_filter --markdown: Limits line wrongly carries the since_only-specific caveat"

# ===========================================================================
# The "none" sentinel is matched EXACTLY, never as a substring of the whole
# line (#746). "nonesuch" contains "none" as a substring — the buggy
# `grep -qi 'none'` on the whole line misread it as not-configured and fell
# back to since_only; the fixed check must still select actor_filter,
# narrowed to the "nonesuch" account, reusing the $ACTOR issue/timeline
# fixtures (only the work-tracking file's reviewer identity changes).
# ===========================================================================
WT_NONESUCH="$WORK/work-tracking-nonesuch.md"
cat > "$WT_NONESUCH" <<'MD'
| Layer | Here |
|---|---|
| Project board | [Global Unassigned #6](https://example.invalid/6) — owner `test-org`; automation account `machine-bot` (admin) |

| Field | Id |
|---|---|
| Project | `PVT_testNONESUCH` |

Reviewer identity: `nonesuch`.
MD

cat > "$ACTOR/timeline_71_nonesuch.json" <<JSON
[
  {"event":"milestoned","actor":{"login":"machine-bot"},"created_at":"2026-01-01T05:00:00Z"},
  {"event":"milestoned","actor":{"login":"nonesuch"},"created_at":"2026-01-01T05:10:00Z"},
  {"event":"labeled","actor":{"login":"user-c"},"created_at":"2026-01-01T05:20:00Z"}
]
JSON
# The mock resolves the timeline fixture by issue number, not by the caller
# naming a file — reuse the same numbered fixture the $ACTOR case already
# serves, since the account name does not change which issue is walked.
# Back up first and restore after, the same way every other block below
# that overwrites this shared fixture does (#759) — otherwise this block's
# data leaks into whatever runs after it.
cp "$ACTOR/timeline_71.json" "$ACTOR/timeline_71.json.bak"
cp "$ACTOR/timeline_71_nonesuch.json" "$ACTOR/timeline_71.json"

: > "$QLOG"
run_audit "$ACTOR" "$QLOG" --repo "$REPO_ACTOR" --target 15 --since "$SINCE" \
  --work-tracking "$WT_NONESUCH"
NONESUCH_OUT="$OUT/run.stdout.log"
if jq -e . "$NONESUCH_OUT" >/dev/null 2>&1; then
  heuristic=$(jq -r .heuristic "$NONESUCH_OUT")
  case "$heuristic" in
    actor_filter*machine-bot*) ;;
    *) report "nonesuch (#746): expected actor_filter naming machine-bot as excluded (nonesuch must NOT read as the 'none' sentinel), got: $heuristic" ;;
  esac
  actors=$(jq -r '[.homed_by_others[].actor]|sort|join(",")' "$NONESUCH_OUT")
  [ "$actors" = "nonesuch,user-c" ] \
    || report "nonesuch (#746): expected actors nonesuch,user-c (actor_filter branch), got $actors"
else
  report "nonesuch (#746): stdout is not valid JSON: $(cat "$NONESUCH_OUT")"
fi
mv "$ACTOR/timeline_71.json.bak" "$ACTOR/timeline_71.json"

# The "none" sentinel is still not-configured even with a trailing rationale
# (the documented "none — <reason>" form): a part-(a)-only run keeps working
# and part (b) falls back to since_only. The rationale text below also
# carries a backtick-quoted token (`machine-bot`) so this fixture actually
# exercises the sentinel-vs-extract branch (#746): a bare
# "Reviewer identity: none" line with no backtick anywhere would leave
# SECOND_ACCOUNT empty no matter which branch fires, so a mutation breaking
# the sentinel comparison would go undetected here — see
# board-audit.sh's reviewer_sentinel_lc check.
WT_NONE_BARE="$WORK/work-tracking-none-bare.md"
cat > "$WT_NONE_BARE" <<'MD'
| Layer | Here |
|---|---|
| Project board | [Global Unassigned #6](https://example.invalid/6) — owner `test-org`; automation account `machine-bot` (admin) |

| Field | Id |
|---|---|
| Project | `PVT_testNONEBARE` |

Reviewer identity: none — single account; audited by `machine-bot` alone
MD
cp "$ACTOR/timeline_71.json" "$ACTOR/timeline_71.json.bak"
cat > "$ACTOR/timeline_71.json" <<JSON
[
  {"event":"milestoned","actor":{"login":"machine-bot"},"created_at":"2026-01-01T05:00:00Z"},
  {"event":"labeled","actor":{"login":"user-c"},"created_at":"2026-01-01T05:20:00Z"}
]
JSON
: > "$QLOG"
run_audit "$ACTOR" "$QLOG" --repo "$REPO_ACTOR" --target 15 --since "$SINCE" \
  --work-tracking "$WT_NONE_BARE"
NONEBARE_OUT="$OUT/run.stdout.log"
if jq -e . "$NONEBARE_OUT" >/dev/null 2>&1; then
  case "$(jq -r .heuristic "$NONEBARE_OUT")" in
    since_only*) ;;
    *) report "bare none (#746): expected since_only (unconfigured), got: $(jq -r .heuristic "$NONEBARE_OUT")" ;;
  esac
  n_homed=$(jq '.homed_by_others|length' "$NONEBARE_OUT")
  [ "$n_homed" = "2" ] \
    || report "bare none (#746): expected since_only to report both events (2), got $n_homed"
else
  report "bare none (#746): stdout is not valid JSON: $(cat "$NONEBARE_OUT")"
fi
mv "$ACTOR/timeline_71.json.bak" "$ACTOR/timeline_71.json"

# ===========================================================================
# #757: the selection grep (`grep -m1 -i '^Reviewer identity:'`) is
# case-insensitive but the label-strip sed was not, so a mixed-case label
# ("Reviewer Identity:") was SELECTED then failed to STRIP — reviewer_value
# kept the whole line, its first word read "Reviewer" (not "none"), and the
# line was misread as a configured second account. This fixture uses the
# exact capitalization from the bug report and carries a backtick-quoted
# account token so a strip failure is directly observable: under the bug,
# heuristic becomes actor_filter (SECOND_ACCOUNT parsed from the backtick);
# fixed, the sentinel strips cleanly, reads "none", and heuristic stays
# since_only. Gate: board-audit.sh's `reviewer_value=$(... sed ...)` line
# and the `reviewer_sentinel_lc` compare immediately after it.
# ===========================================================================
WT_REVIEWER_CAP="$WORK/work-tracking-reviewer-cap.md"
cat > "$WT_REVIEWER_CAP" <<'MD'
| Layer | Here |
|---|---|
| Project board | [Global Unassigned #6](https://example.invalid/6) — owner `test-org`; automation account `machine-bot` (admin) |

| Field | Id |
|---|---|
| Project | `PVT_testREVCAP` |

Reviewer Identity: none — single account; audited by `machine-bot` alone
MD
cp "$ACTOR/timeline_71.json" "$ACTOR/timeline_71.json.bak"
cat > "$ACTOR/timeline_71.json" <<JSON
[
  {"event":"milestoned","actor":{"login":"machine-bot"},"created_at":"2026-01-01T05:00:00Z"},
  {"event":"labeled","actor":{"login":"user-c"},"created_at":"2026-01-01T05:20:00Z"}
]
JSON
: > "$QLOG"
run_audit "$ACTOR" "$QLOG" --repo "$REPO_ACTOR" --target 15 --since "$SINCE" \
  --work-tracking "$WT_REVIEWER_CAP"
REVCAP_OUT="$OUT/run.stdout.log"
if jq -e . "$REVCAP_OUT" >/dev/null 2>&1; then
  case "$(jq -r .heuristic "$REVCAP_OUT")" in
    since_only*) ;;
    *) report "reviewer-identity capital-I (#757): expected since_only (bare 'none' must strip regardless of label case), got: $(jq -r .heuristic "$REVCAP_OUT")" ;;
  esac
  n_homed=$(jq '.homed_by_others|length' "$REVCAP_OUT")
  [ "$n_homed" = "2" ] \
    || report "reviewer-identity capital-I (#757): expected since_only to report both events (2), got $n_homed"
else
  report "reviewer-identity capital-I (#757): stdout is not valid JSON: $(cat "$REVCAP_OUT")"
fi
mv "$ACTOR/timeline_71.json.bak" "$ACTOR/timeline_71.json"

# Near-miss control: an all-lowercase label ("reviewer identity:") already
# matched both the old and new strip pattern (the character class the bug
# report names only omitted "Identity"'s capital I, never lowercase
# letters) — this fixture proves the fix has not overcorrected into
# rejecting the all-lowercase spelling.
WT_REVIEWER_LOWER="$WORK/work-tracking-reviewer-lower.md"
cat > "$WT_REVIEWER_LOWER" <<'MD'
| Layer | Here |
|---|---|
| Project board | [Global Unassigned #6](https://example.invalid/6) — owner `test-org`; automation account `machine-bot` (admin) |

| Field | Id |
|---|---|
| Project | `PVT_testREVLOW` |

reviewer identity: none — single account; audited by `machine-bot` alone
MD
cp "$ACTOR/timeline_71.json" "$ACTOR/timeline_71.json.bak"
cat > "$ACTOR/timeline_71.json" <<JSON
[
  {"event":"milestoned","actor":{"login":"machine-bot"},"created_at":"2026-01-01T05:00:00Z"},
  {"event":"labeled","actor":{"login":"user-c"},"created_at":"2026-01-01T05:20:00Z"}
]
JSON
: > "$QLOG"
run_audit "$ACTOR" "$QLOG" --repo "$REPO_ACTOR" --target 15 --since "$SINCE" \
  --work-tracking "$WT_REVIEWER_LOWER"
REVLOW_OUT="$OUT/run.stdout.log"
if jq -e . "$REVLOW_OUT" >/dev/null 2>&1; then
  case "$(jq -r .heuristic "$REVLOW_OUT")" in
    since_only*) ;;
    *) report "reviewer-identity all-lowercase (#757): expected since_only, got: $(jq -r .heuristic "$REVLOW_OUT")" ;;
  esac
else
  report "reviewer-identity all-lowercase (#757): stdout is not valid JSON: $(cat "$REVLOW_OUT")"
fi
mv "$ACTOR/timeline_71.json.bak" "$ACTOR/timeline_71.json"

# ===========================================================================
# #770: bad_claim_form's timestamp segment accepted any non-space run, so a
# structurally malformed timestamp (truncated, missing its literal `Z`, or
# not a timestamp at all) read as well-formed. This is a standalone,
# part-(a)-only fixture set (no --target/--since needed — bad_claim_form is
# part of part (a)) so a bug in it cannot be masked by, or mask, the DIRTY
# set's own bad_claim_form assertions (#13/#15). #200 is the well-formed
# control; #201-#205 are timestamp near-misses one boundary away from valid
# on each side (missing `Z`, truncated to date-only, non-timestamp text, a
# trailing space, and a doubled `(stamp)` marker) — the last two were
# already rejected by the pre-#770 regex too (the `$` anchor and the
# optional-group shape already excluded them), kept here as boundary
# controls proving the fix has not loosened those legs.
#
# #806: #200 exercises the plain coordination-lock shape (no marker) and
# #204/#205 are marker-adjacent near-misses asserted REJECTING — none of
# the six values in this set exercises the optional ` (stamp)` marker group
# in its ACCEPTING direction. #206 is that accepted-stamp control: the same
# well-formed timestamp as #200 plus a single trailing ` (stamp)` marker,
# asserted absent from bad_claim_form, so a future edit that narrows,
# re-anchors, or removes the marker group would fail here even if every
# other CLAIMTS fixture stayed green.
# ===========================================================================
CLAIMTS="$WORK/fixtures-claimts"
mkdir -p "$CLAIMTS"
REPO_CLAIMTS="test-org/claimts-repo"
cat > "$CLAIMTS/open_issues_page1.json" <<'JSON'
[
  {"number":200,"title":"issue two hundred","html_url":"https://example.invalid/200","labels":[{"name":"size:s"},{"name":"priority:high"}]},
  {"number":201,"title":"issue two-oh-one","html_url":"https://example.invalid/201","labels":[{"name":"size:s"},{"name":"priority:high"}]},
  {"number":202,"title":"issue two-oh-two","html_url":"https://example.invalid/202","labels":[{"name":"size:s"},{"name":"priority:high"}]}
]
JSON
cat > "$CLAIMTS/open_issues_page2.json" <<'JSON'
[
  {"number":203,"title":"issue two-oh-three","html_url":"https://example.invalid/203","labels":[{"name":"size:s"},{"name":"priority:high"}]},
  {"number":204,"title":"issue two-oh-four","html_url":"https://example.invalid/204","labels":[{"name":"size:s"},{"name":"priority:high"}]},
  {"number":205,"title":"issue two-oh-five","html_url":"https://example.invalid/205","labels":[{"name":"size:s"},{"name":"priority:high"}]},
  {"number":206,"title":"issue two-oh-six","html_url":"https://example.invalid/206","labels":[{"name":"size:s"},{"name":"priority:high"}]}
]
JSON
cat > "$CLAIMTS/project_items_page1.json" <<'JSON'
{"data":{"node":{"items":{"pageInfo":{"hasNextPage":true,"endCursor":"CLAIMTSCURSOR"},
  "nodes":[{"id":"CT1","content":{"number":200,"repository":{"nameWithOwner":"test-org/claimts-repo"}},"claimedBy":{"text":"acme-01 @ 2026-08-29T15:10Z"}},
           {"id":"CT2","content":{"number":201,"repository":{"nameWithOwner":"test-org/claimts-repo"}},"claimedBy":{"text":"acme-01 @ 2026-08-29T15:10"}},
           {"id":"CT3","content":{"number":202,"repository":{"nameWithOwner":"test-org/claimts-repo"}},"claimedBy":{"text":"acme-01 @ 2026-08-29"}}]}}}}
JSON
cat > "$CLAIMTS/project_items_page2.json" <<'JSON'
{"data":{"node":{"items":{"pageInfo":{"hasNextPage":false,"endCursor":null},
  "nodes":[{"id":"CT4","content":{"number":203,"repository":{"nameWithOwner":"test-org/claimts-repo"}},"claimedBy":{"text":"acme-01 @ banana"}},
           {"id":"CT5","content":{"number":204,"repository":{"nameWithOwner":"test-org/claimts-repo"}},"claimedBy":{"text":"acme-01 @ 2026-08-29T15:10Z "}},
           {"id":"CT6","content":{"number":205,"repository":{"nameWithOwner":"test-org/claimts-repo"}},"claimedBy":{"text":"acme-01 @ 2026-08-29T15:10Z (stamp) (stamp)"}},
           {"id":"CT7","content":{"number":206,"repository":{"nameWithOwner":"test-org/claimts-repo"}},"claimedBy":{"text":"acme-01 @ 2026-08-29T15:10Z (stamp)"}}]}}}}
JSON

: > "$QLOG"
run_audit "$CLAIMTS" "$QLOG" --repo "$REPO_CLAIMTS" --work-tracking "$WT_DIRTY"
CLAIMTS_OUT="$OUT/run.stdout.log"
if jq -e . "$CLAIMTS_OUT" >/dev/null 2>&1; then
  n_bad_claimts=$(jq '.bad_claim_form|length' "$CLAIMTS_OUT")
  [ "$n_bad_claimts" = "5" ] \
    || report "claimts (#770): expected 5 bad_claim_form (all timestamp near-misses), got $n_bad_claimts"
  bad_claimts_nums=$(jq -r '[.bad_claim_form[].number]|sort|join(",")' "$CLAIMTS_OUT")
  [ "$bad_claimts_nums" = "201,202,203,204,205" ] \
    || report "claimts (#770): expected bad_claim_form #201,#202,#203,#204,#205, got $bad_claimts_nums"
  jq -e '.bad_claim_form[]|select(.number==200)' "$CLAIMTS_OUT" >/dev/null 2>&1 \
    && report "claimts (#770): #200 (well-formed timestamp) unexpectedly in bad_claim_form"
  jq -e '.bad_claim_form[]|select(.number==206)' "$CLAIMTS_OUT" >/dev/null 2>&1 \
    && report "claimts (#806): #206 (well-formed timestamp with a single ' (stamp)' marker) unexpectedly in bad_claim_form"
  c201_val=$(jq -r '.bad_claim_form[]|select(.number==201)|.claimed_by' "$CLAIMTS_OUT")
  [ "$c201_val" = "acme-01 @ 2026-08-29T15:10" ] \
    || report "claimts (#770): expected #201 claimed_by echoed verbatim (missing Z), got $c201_val"
  c202_val=$(jq -r '.bad_claim_form[]|select(.number==202)|.claimed_by' "$CLAIMTS_OUT")
  [ "$c202_val" = "acme-01 @ 2026-08-29" ] \
    || report "claimts (#770): expected #202 claimed_by echoed verbatim (truncated date), got $c202_val"
else
  report "claimts (#770): stdout is not valid JSON: $(cat "$CLAIMTS_OUT")"
fi

# ===========================================================================
# --max-rows truncation is load-bearing (#338, and #733/#745's three new
# lists): assert bullet COUNT, not only the trailer's presence, on all five
# lists — a dedicated fixture with 2+ items on every side so a missing
# [0:$max] slice is actually observable, and each list's bullets are counted
# from its OWN section (not a global bullet-shape grep, which cannot tell
# one list's rows from another's — the same scoping mistake finding 2 made).
# #80/#81 carry no labels at all, gating missing_size_label AND
# bad_priority_label together; #82/#83 are well-formed on size/priority but
# gate bad_severity_label (a bug with none, and two on a non-bug) — kept
# separate from #80/#81 so a fixture bug in one pairing cannot mask the
# other. None of #80-#83 is on the board, so missing_board_items also gets
# real (4-item) truncation coverage in the same run.
# ===========================================================================
TRUNC="$WORK/fixtures-trunc"
mkdir -p "$TRUNC"
REPO_TRUNC="test-org/trunc-repo"
cat > "$TRUNC/open_issues_page1.json" <<'JSON'
[
  {"number":80,"title":"issue eighty","html_url":"https://example.invalid/80","labels":[]},
  {"number":81,"title":"issue eighty-one","html_url":"https://example.invalid/81","labels":[]}
]
JSON
cat > "$TRUNC/open_issues_page2.json" <<'JSON'
[
  {"number":82,"title":"issue eighty-two","html_url":"https://example.invalid/82","labels":[{"name":"bug"},{"name":"size:s"},{"name":"priority:high"}]},
  {"number":83,"title":"issue eighty-three","html_url":"https://example.invalid/83","labels":[{"name":"size:s"},{"name":"priority:high"},{"name":"severity:major"},{"name":"severity:minor"}]}
]
JSON
cat > "$TRUNC/project_items_page1.json" <<'JSON'
{"data":{"node":{"items":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}}
JSON
cat > "$TRUNC/milestone.json" <<'JSON'
{"number":16,"title":"milestone sixteen"}
JSON
cat > "$TRUNC/milestone_issues.json" <<'JSON'
[{"number":85,"title":"issue eighty-five","pull_request":null,"updated_at":"2026-01-01T06:00:00Z"}]
JSON
cat > "$TRUNC/timeline_85.json" <<JSON
[
  {"event":"milestoned","actor":{"login":"user-a"},"created_at":"2026-01-01T05:00:00Z"},
  {"event":"labeled","actor":{"login":"user-b"},"created_at":"2026-01-01T05:10:00Z"}
]
JSON

: > "$QLOG"
run_audit "$TRUNC" "$QLOG" --repo "$REPO_TRUNC" --target 16 --since "$SINCE" \
  --work-tracking "$WT_DIRTY" --markdown --max-rows 1
TRUNC_MD="$OUT/run.stdout.log"
trunc_section(){ awk -v s="$1" -v e="$2" '$0 ~ s{flag=1} $0 ~ e{flag=0} flag' "$TRUNC_MD"; }
MISSING_SECTION=$(trunc_section '^- Missing board items:' '^- Homed into target')
HOMED_SECTION=$(trunc_section '^- Homed into target' '^- Missing size:\* label:')
SIZE_SECTION_T=$(trunc_section '^- Missing size:\* label:' '^- Not exactly one priority')
PRIORITY_SECTION_T=$(trunc_section '^- Not exactly one priority' '^- Bad severity:\* label')
SEVERITY_SECTION_T=$(trunc_section '^- Bad severity:\* label' '^> Limits:')
missing_bullets=$(grep -cE '^  - #[0-9]+ ' <<<"$MISSING_SECTION" || true)
homed_bullets=$(grep -cE '^  - issue #[0-9]+ ' <<<"$HOMED_SECTION" || true)
size_bullets=$(grep -cE '^  - #[0-9]+ ' <<<"$SIZE_SECTION_T" || true)
priority_bullets=$(grep -cE '^  - #[0-9]+ ' <<<"$PRIORITY_SECTION_T" || true)
severity_bullets=$(grep -cE '^  - #[0-9]+ ' <<<"$SEVERITY_SECTION_T" || true)
[ "$missing_bullets" = "1" ] \
  || report "--max-rows 1: expected exactly 1 missing bullet, got $missing_bullets"
[ "$homed_bullets" = "1" ] \
  || report "--max-rows 1: expected exactly 1 homed bullet, got $homed_bullets"
[ "$size_bullets" = "1" ] \
  || report "--max-rows 1: expected exactly 1 missing-size bullet, got $size_bullets"
[ "$priority_bullets" = "1" ] \
  || report "--max-rows 1: expected exactly 1 bad-priority bullet, got $priority_bullets"
[ "$severity_bullets" = "1" ] \
  || report "--max-rows 1: expected exactly 1 bad-severity bullet, got $severity_bullets"
trailers=$(grep -cE 'more, see JSON' "$TRUNC_MD" || true)
[ "$trailers" = "5" ] \
  || report "--max-rows 1: expected 5 truncation trailers (one per list), got $trailers"

# ===========================================================================
# --max-rows 0 is refused (#339); the '> Limits:' blockquote is preceded by
# a blank line.
# ===========================================================================
RUN_ARGERR_FIXTURES="$TRUNC" run_argerr 2 maxrows0 --repo "$REPO_TRUNC" --target 16 \
  --since "$SINCE" --work-tracking "$WT_DIRTY" --markdown --max-rows 0
grep -qi -- '--max-rows' "$OUT/maxrows0.stderr.log" \
  || report "--max-rows 0: expected a --max-rows-naming reason, got: $(cat "$OUT/maxrows0.stderr.log")"

# Every non-canonical spelling of the same value is refused identically —
# `00`/`000` are all-digit and non-empty, so the old literal-`0` match let
# them through and `jq --argjson` read them back as 0: zero bullets plus an
# "…and N more" trailer, the state #339 was filed to eliminate (#476). Each
# case gets an index-based label (never derived from the value) so `+5` and
# `" 5"` — which both strip to the same `5` — cannot collide on one
# $OUT/<label>.{stdout,stderr}.log artifact (#518); every case also gets its
# own reason-grep here, inline, instead of two greps tacked on after the
# loop that left the `+5`/`" 5"` cases without any reason assertion at all.
maxrows_nc_i=0
for bad in 00 000 +5 " 5"; do
  maxrows_nc_i=$((maxrows_nc_i + 1))
  maxrows_nc_label="maxrows_nc_$maxrows_nc_i"
  RUN_ARGERR_FIXTURES="$TRUNC" run_argerr 2 "$maxrows_nc_label" \
    --repo "$REPO_TRUNC" --target 16 --since "$SINCE" \
    --work-tracking "$WT_DIRTY" --markdown --max-rows "$bad"
  grep -qi -- '--max-rows' "$OUT/$maxrows_nc_label.stderr.log" \
    || report "--max-rows '$bad' ($maxrows_nc_label): expected a --max-rows-naming reason, got: $(cat "$OUT/$maxrows_nc_label.stderr.log")"
done

blank_before_limits=$(awk '/^> Limits:/{print prev} {prev=$0}' "$TRUNC_MD" | wc -l | tr -d ' ')
prev_line=$(awk '/^> Limits:/{print prev} {prev=$0}' "$TRUNC_MD")
[ -z "$prev_line" ] \
  || report "'> Limits:' is not preceded by a blank line: previous line was '$prev_line' (matches: $blank_before_limits)"

# ===========================================================================
# Bounding the timeline walk (#416): an issue whose own updated_at predates
# --since is never fetched at all — no timeline fixture exists for it, so a
# regression that drops the filter is caught by the mock's unknown-endpoint
# refusal, not by a slow real run. --limit caps the walk further and is
# reflected in homed_walk_truncated.
# ===========================================================================
BOUND="$WORK/fixtures-bound"
mkdir -p "$BOUND"
REPO_BOUND="test-org/bound-repo"
cat > "$BOUND/open_issues_page1.json" <<'JSON'
[{"number":60,"title":"issue sixty","html_url":"https://example.invalid/60"}]
JSON
cat > "$BOUND/open_issues_page2.json" <<'JSON'
[]
JSON
cat > "$BOUND/project_items_page1.json" <<'JSON'
{"data":{"node":{"items":{"pageInfo":{"hasNextPage":false,"endCursor":null},
  "nodes":[{"id":"ITEM6","content":{"number":60,"repository":{"nameWithOwner":"test-org/bound-repo"}}}]}}}}
JSON
cat > "$BOUND/milestone.json" <<'JSON'
{"number":9,"title":"milestone nine"}
JSON
# Issue #61 is deliberately given no timeline_61.json fixture: its
# updated_at predates --since, so a correct run never fetches its timeline.
cat > "$BOUND/milestone_issues.json" <<'JSON'
[
  {"number":60,"title":"i60","pull_request":null,"updated_at":"2026-01-01T06:00:00Z"},
  {"number":61,"title":"i61","pull_request":null,"updated_at":"2025-06-01T00:00:00Z"},
  {"number":62,"title":"i62","pull_request":null,"updated_at":"2026-01-01T07:00:00Z"}
]
JSON
cat > "$BOUND/timeline_60.json" <<'JSON'
[{"event":"milestoned","actor":{"login":"user-a"},"created_at":"2026-01-01T06:30:00Z"}]
JSON
cat > "$BOUND/timeline_62.json" <<'JSON'
[{"event":"milestoned","actor":{"login":"user-b"},"created_at":"2026-01-01T07:30:00Z"}]
JSON

: > "$QLOG"
run_audit "$BOUND" "$QLOG" --repo "$REPO_BOUND" --target 9 --since "$SINCE" \
  --work-tracking "$WT_DIRTY"
BOUND_OUT="$OUT/run.stdout.log"
if jq -e . "$BOUND_OUT" >/dev/null 2>&1; then
  n_homed=$(jq '.homed_by_others|length' "$BOUND_OUT")
  [ "$n_homed" = "2" ] \
    || report "since-floor: expected 2 homed_by_others (#61 skipped, never fetched), got $n_homed"
  [ "$(jq -r .homed_walk_truncated "$BOUND_OUT")" = "false" ] \
    || report "since-floor: expected homed_walk_truncated=false with no --limit"
else
  report "since-floor: stdout is not valid JSON: $(cat "$BOUND_OUT")"
fi

: > "$QLOG"
run_audit "$BOUND" "$QLOG" --repo "$REPO_BOUND" --target 9 --since "$SINCE" \
  --work-tracking "$WT_DIRTY" --limit 1
LIMIT_OUT="$OUT/run.stdout.log"
if jq -e . "$LIMIT_OUT" >/dev/null 2>&1; then
  n_homed=$(jq '.homed_by_others|length' "$LIMIT_OUT")
  [ "$n_homed" = "1" ] \
    || report "--limit 1: expected 1 homed_by_others (only #60 walked), got $n_homed"
  [ "$(jq -r .homed_walk_truncated "$LIMIT_OUT")" = "true" ] \
    || report "--limit 1: expected homed_walk_truncated=true"
else
  report "--limit 1: stdout is not valid JSON: $(cat "$LIMIT_OUT")"
fi

# --limit rejects a negative/non-numeric value.
run_argerr 2 badlimit --target 5 --since "$SINCE" --limit -1

# ===========================================================================
# --limit shares --max-rows's canonical-positive-integer check (#507): one
# helper (canonical_uint), two call sites. Every non-canonical spelling
# --max-rows refuses is refused identically by --limit, with the same
# "in canonical form (no leading zeros, no sign, no whitespace)" wording
# (only the flag name and the domain noun ahead of it differ) and the same
# exit code. --limit 0 (its own "unlimited" value), unlike --max-rows 0, is
# accepted — the two flags share the canonical-FORM rule but not the same
# minimum, and (#580) not the same domain noun either: --max-rows keeps "a
# positive integer" while --limit substitutes "a non-negative integer" so
# the message never asserts "positive integer" and accepts 0 in the same
# breath.
# ===========================================================================
CANONICAL_MSG='in canonical form (no leading zeros, no sign, no whitespace)'
grep -q "$CANONICAL_MSG" "$OUT/maxrows_nc_1.stderr.log" \
  || report "--max-rows 00: expected canonical-form wording, got: $(cat "$OUT/maxrows_nc_1.stderr.log")"
# Pin --max-rows's own domain noun so a lost/blanked default (${4:-a
# positive integer}) fails here rather than only in the negative greps
# below, which would still pass against a blanked noun.
grep -q 'must be a positive integer' "$OUT/maxrows_nc_1.stderr.log" \
  || report "--max-rows 00: expected the 'must be a positive integer' domain noun, got: $(cat "$OUT/maxrows_nc_1.stderr.log")"

limit_nc_i=0
for bad in 00 000 007 +5 " 5"; do
  limit_nc_i=$((limit_nc_i + 1))
  limit_nc_label="limit_nc_$limit_nc_i"
  run_argerr 2 "$limit_nc_label" --target 5 --since "$SINCE" --limit "$bad"
  grep -qi -- '--limit' "$OUT/$limit_nc_label.stderr.log" \
    || report "--limit '$bad' ($limit_nc_label): expected a --limit-naming reason, got: $(cat "$OUT/$limit_nc_label.stderr.log")"
  grep -q "$CANONICAL_MSG" "$OUT/$limit_nc_label.stderr.log" \
    || report "--limit '$bad' ($limit_nc_label): expected the same canonical-form wording --max-rows uses, got: $(cat "$OUT/$limit_nc_label.stderr.log")"
done

# --limit 0 is accepted (the flag's own "unlimited" value).
run_argerr 0 limitzero --repo "$REPO_DIRTY" --target 5 --since "$SINCE" \
  --limit 0 --work-tracking "$WT_DIRTY"

# ===========================================================================
# --limit's refusal states the 0=unlimited domain hint; --max-rows's refusal
# does not, since 0 is not accepted there (#545).
# ===========================================================================
run_argerr 2 limitneg --target 5 --since "$SINCE" --limit -1
grep -qi '0 is accepted' "$OUT/limitneg.stderr.log" \
  || report "--limit -1: expected the '0 is accepted' domain hint, got: $(cat "$OUT/limitneg.stderr.log")"
# Pin --limit's own domain noun so a lost/blanked custom noun
# ('a non-negative integer (0 is accepted...)') fails here rather than only
# via the '0 is accepted' substring, which a differently-worded noun could
# still satisfy.
grep -q 'must be a non-negative integer' "$OUT/limitneg.stderr.log" \
  || report "--limit -1: expected the 'must be a non-negative integer' domain noun, got: $(cat "$OUT/limitneg.stderr.log")"

grep -qi '0 is accepted' "$OUT/maxrows_nc_1.stderr.log" \
  && report "--max-rows 00: did not expect the '0 is accepted' domain hint (0 is refused for --max-rows), got: $(cat "$OUT/maxrows_nc_1.stderr.log")"

# ===========================================================================
# #580: --limit's refusal must not simultaneously assert "must be a positive
# integer" and accept 0 — the two claims contradict each other. It states
# its own domain ("a non-negative integer") instead.
# ===========================================================================
grep -qi 'must be a positive integer' "$OUT/limitneg.stderr.log" \
  && report "--limit -1: did not expect the 'must be a positive integer' wording alongside '0 is accepted', got: $(cat "$OUT/limitneg.stderr.log")"
[ "$(grep -c . "$OUT/limitneg.stderr.log")" = "1" ] \
  || report "--limit -1: expected exactly one stderr line, got: $(cat "$OUT/limitneg.stderr.log")"

# ===========================================================================
# An out-of-range but canonical, all-digit value exits 2 with exactly one
# clean `board-audit:`-prefixed stderr line — no bare bash "integer
# expression expected" line ahead of it (#546).
# ===========================================================================
run_argerr 2 limitrange --target 5 --since "$SINCE" \
  --limit 99999999999999999999999999
[ "$(wc -l < "$OUT/limitrange.stderr.log")" -eq 1 ] \
  || report "--limit (out of range): expected exactly one stderr line, got: $(cat "$OUT/limitrange.stderr.log")"
grep -q '^board-audit:' "$OUT/limitrange.stderr.log" \
  || report "--limit (out of range): expected the line to start 'board-audit:', got: $(cat "$OUT/limitrange.stderr.log")"
grep -qi 'integer expression expected' "$OUT/limitrange.stderr.log" \
  && report "--limit (out of range): did not expect a bare bash 'integer expression expected' line, got: $(cat "$OUT/limitrange.stderr.log")"

run_argerr 2 maxrowsrange --target 5 --since "$SINCE" \
  --max-rows 99999999999999999999999999
[ "$(wc -l < "$OUT/maxrowsrange.stderr.log")" -eq 1 ] \
  || report "--max-rows (out of range): expected exactly one stderr line, got: $(cat "$OUT/maxrowsrange.stderr.log")"
grep -q '^board-audit:' "$OUT/maxrowsrange.stderr.log" \
  || report "--max-rows (out of range): expected the line to start 'board-audit:', got: $(cat "$OUT/maxrowsrange.stderr.log")"
grep -qi 'integer expression expected' "$OUT/maxrowsrange.stderr.log" \
  && report "--max-rows (out of range): did not expect a bare bash 'integer expression expected' line, got: $(cat "$OUT/maxrowsrange.stderr.log")"

# ===========================================================================
# #581: canonical_uint's stderr-redirected `[ -ge ]` test (#546) must not
# swallow a `[` failure caused by a malformed <min> — no current call site
# passes one (both pass literals), so this exercises the function directly,
# extracted verbatim from the script under test rather than reimplemented,
# to prove a defective future call site would be diagnosed by name and not
# blamed on the user's own value.
# ===========================================================================
CU_FN="$WORK/canonical_uint_fn.sh"
sed -n '/^die(){/,/^argerr(){/p; /^canonical_uint(){/,/^}/p' "$BOARD_AUDIT_SH" > "$CU_FN"
CU_OUT="$WORK/canonical_uint.stderr.log"
# shellcheck disable=SC1090  # extracted verbatim from the script under test, not a fixed path.
if ( set -e; . "$CU_FN"; canonical_uint --limit 5 notanumber ) 2>"$CU_OUT"; then
  report "canonical_uint with malformed <min>: expected a non-zero exit, got 0"
else
  cu_status=$?
  [ "$cu_status" = "1" ] \
    || report "canonical_uint with malformed <min>: expected die's exit 1, got $cu_status"
fi
grep -qi -- '<min>' "$CU_OUT" \
  || report "canonical_uint with malformed <min>: expected a diagnostic naming <min>, got: $(cat "$CU_OUT")"
grep -qi 'must be a positive integer\|must be a non-negative integer' "$CU_OUT" \
  && report "canonical_uint with malformed <min>: did not expect the <value>-blaming refusal wording, got: $(cat "$CU_OUT")"
[ "$(grep -c . "$CU_OUT")" = "1" ] \
  || report "canonical_uint with malformed <min>: expected exactly one stderr line, got: $(cat "$CU_OUT")"

# A leading-zero <min> ("08") is all-digits but not itself canonical form —
# the <min> guard must refuse it the same way the <value> guard's own
# `0?*` alternative refuses a leading-zero <value>, or a canonical <value>
# (5) gets silently misjudged non-canonical by a malformed <min> instead of
# the <min> guard naming <min> as the actual defect.
CU_OUT2="$WORK/canonical_uint_min0.stderr.log"
# shellcheck disable=SC1090  # extracted verbatim from the script under test, not a fixed path.
if ( set -e; . "$CU_FN"; canonical_uint --limit 5 08 ) 2>"$CU_OUT2"; then
  report "canonical_uint with leading-zero <min>: expected a non-zero exit, got 0"
else
  cu_status2=$?
  [ "$cu_status2" = "1" ] \
    || report "canonical_uint with leading-zero <min>: expected die's exit 1, got $cu_status2"
fi
grep -qi -- '<min>' "$CU_OUT2" \
  || report "canonical_uint with leading-zero <min>: expected a diagnostic naming <min>, got: $(cat "$CU_OUT2")"
grep -qi 'must be a positive integer\|must be a non-negative integer' "$CU_OUT2" \
  && report "canonical_uint with leading-zero <min>: did not expect the <value>-blaming refusal wording, got: $(cat "$CU_OUT2")"
[ "$(grep -c . "$CU_OUT2")" = "1" ] \
  || report "canonical_uint with leading-zero <min>: expected exactly one stderr line, got: $(cat "$CU_OUT2")"

# ===========================================================================
# PAGFAIL (#867 round-1 finding 2): the shared walk's fail-closed refusal —
# a `hasNextPage: true` page with no usable `endCursor` — now reaches
# board-audit.sh's own project-items walk via lib/project-items-walk.sh, a
# path it never carried before that extraction. No fixture in this suite
# ever produced that shape: every existing project_items_page*.json here is
# either hasNextPage:false or carries a real cursor. The guard must die
# after exactly one GraphQL call (it can never loop), with a non-zero exit
# and a message naming pagination.
# ===========================================================================
PAGFAIL="$WORK/fixtures-pagfail"
mkdir -p "$PAGFAIL"
REPO_PAGFAIL="test-org/pagfail-repo"
cat > "$PAGFAIL/project_items_page1.json" <<'JSON'
{"data":{"node":{"items":{"pageInfo":{"hasNextPage":true,"endCursor":null},"nodes":[]}}}}
JSON
pagfail_calls_before="$(wc -l < "$MOCK_GH_CALL_LOG")"
RUN_ARGERR_FIXTURES="$PAGFAIL" run_argerr 1 pagfail --repo "$REPO_PAGFAIL" --work-tracking "$WT_DIRTY"
grep -qi 'pagination' "$OUT/pagfail.stderr.log" \
  || report "PAGFAIL: expected stderr to name pagination, got: $(cat "$OUT/pagfail.stderr.log")"
pagfail_graphql_calls="$(tail -n "+$((pagfail_calls_before + 1))" "$MOCK_GH_CALL_LOG" | grep -c '^CALL gh api graphql' || true)"
[ "$pagfail_graphql_calls" -eq 1 ] \
  || report "PAGFAIL: expected the fail-closed guard to die after exactly 1 graphql call, got $pagfail_graphql_calls"

# ===========================================================================
# Hermeticity tripwire (#477): the mock recorded every invocation it served,
# and none of them arrived from an unmocked context. A bare invocation of the
# script under test (no harness env) would have logged UNMOCKED-CONTEXT here
# instead of reaching the real, authenticated API.
# ===========================================================================
[ -s "$MOCK_GH_CALL_LOG" ] \
  || report "hermeticity: the mock recorded zero invocations — the call log is not wired up"
if grep -q '^UNMOCKED-CONTEXT ' "$MOCK_GH_CALL_LOG"; then
  report "hermeticity: a gh call was made from an unmocked context: $(grep -m1 '^UNMOCKED-CONTEXT ' "$MOCK_GH_CALL_LOG")"
fi
[ "$(command -v gh)" = "$BIN/gh" ] \
  || report "hermeticity: gh resolves to $(command -v gh), not the mock at $BIN/gh (real gh: ${REAL_GH:-none})"

if [ "$fail" -ne 0 ]; then
  echo "test_board_audit: FAILED" >&2
  exit 1
fi

echo "test_board_audit: all assertions passed (repo=$REPO_DIRTY, target=5)"
