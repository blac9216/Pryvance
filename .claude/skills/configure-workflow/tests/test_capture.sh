#!/usr/bin/env bash
# test_capture.sh — fixture-driven regression test for configure-workflow's
# capture.sh (#786). Follows the mock-`gh` harness conventions in
# ../../github-workflow/tests/README.md (this skill has no README of its
# own; test_grant.sh and test_project.sh, the pre-existing suites here,
# point at the same file): a mocked `gh` binary on PATH serves fixture JSON
# from a private mktemp scratch dir, records every invocation, marks a call
# reached with no fixture env set as UNMOCKED-CONTEXT, and no real network
# call is ever reachable.
#
# capture.sh writes to `$(dirname "$0")/../manifests/project.json` by
# default (no env override) — the REAL path resolves inside this repo's
# tracked manifests/, which already carries a real project.json (see
# .claude/skills/configure-workflow/manifests/project.json). Invoking the
# tracked script directly with no --out would therefore overwrite a real,
# committed file. So — exactly like test_project.sh's "skel" tree — this
# suite copies the real, unmodified capture.sh into a private scratch tree
# alongside an EMPTY manifests/ dir, and invokes the copy, never the
# tracked script, so a default---out run lands inside the scratch dir.
#
# Covers (#786):
#  - the written manifest is compared byte-for-byte against a hand-written
#    expected file, not re-derived from the same jq filter under test —
#    including a view whose sort the API exposes (groupByFields,
#    verticalGroupByFields, sortByFields), a view with no filter/group/sort
#    at all, and a custom-field type sweep (SINGLE_SELECT with options,
#    TEXT, NUMBER, DATE, ITERATION) that also proves the TITLE field is
#    excluded and a disabled workflow is excluded.
#  - --out is honoured: a custom --out path receives the manifest, and the
#    default path is untouched when --out is given.
#  - PID resolution falls back from the user endpoint to the organization
#    endpoint when the user query resolves no project (real API shape:
#    `.data.user.projectV2` null, `.id` on null is a jq error, caught by
#    capture.sh's own `2>/dev/null || true`).
#  - capture.sh is read-only: the mock records every call and refuses any
#    query whose leading keyword is `mutation`, and a direct sanity check
#    proves that refusal fires at all (not just that capture.sh happens
#    never to trigger it). Zero mutations ever land in the mutations log on
#    any real capture.sh path below.
#  - argument errors (unknown flag, missing --owner, missing --project,
#    missing both) exit 2 before a single gh call, all routed through one
#    run_argerr helper that sets the full mock env (PATH + fixtures dir +
#    call log), so the zero-calls assertions are load-bearing rather than
#    passing by virtue of an unset mock guard aborting first.
set -euo pipefail
# Pin the locale so the mock's output and every exact-string `grep -F`/`diff`
# assertion below compare byte-for-byte on any host (tests/README.md § Shape).
export LANG=C LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REAL_SCRIPTS="$SCRIPT_DIR/../scripts"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/capture-test.XXXXXX")"
cleanup(){ rm -rf "$WORK"; }
trap cleanup EXIT

BIN="$WORK/bin"
OUT="$WORK/out"
F="$WORK/fixtures"
mkdir -p "$BIN" "$OUT" "$F"

fail=0
report(){ echo "FAIL: $*" >&2; fail=1; }

# ---------------------------------------------------------------------------
# The skel tree: an unmodified copy of capture.sh, next to an EMPTY
# manifests/ dir, so a default---out run never touches the tracked
# manifests/project.json.
# ---------------------------------------------------------------------------
mkskel(){ # mkskel <dir> — fresh skel copy, isolated per scenario so
  # default---out runs in different scenarios never collide.
  mkdir -p "$1/scripts" "$1/manifests"
  cp "$REAL_SCRIPTS/capture.sh" "$1/scripts/capture.sh"
  chmod +x "$1/scripts/capture.sh"
}

# ---------------------------------------------------------------------------
# Expected manifest (hand-written, not derived from capture.sh's own jq
# filter — see the header comment).
# ---------------------------------------------------------------------------
cat > "$F/expected.json" <<'JSON'
{
  "captured_from": {
    "owner": "test-owner",
    "project": 9,
    "title": "Demo Project"
  },
  "custom_fields": [
    {
      "name": "Status",
      "dataType": "SINGLE_SELECT",
      "options": [
        {
          "name": "Todo",
          "color": "GRAY",
          "description": "d1"
        },
        {
          "name": "Done",
          "color": "GREEN",
          "description": "d2"
        }
      ]
    },
    {
      "name": "Notes",
      "dataType": "TEXT",
      "options": []
    },
    {
      "name": "Estimate",
      "dataType": "NUMBER",
      "options": []
    },
    {
      "name": "Due",
      "dataType": "DATE",
      "options": []
    },
    {
      "name": "Iteration",
      "dataType": "ITERATION",
      "options": []
    }
  ],
  "views": [
    {
      "name": "Board",
      "layout": "BOARD_LAYOUT",
      "filter": "is:open",
      "columns": [
        "Title",
        "Status"
      ],
      "group_by": [
        "Status"
      ],
      "board_columns": [],
      "sort": [
        "Due:ASC"
      ]
    },
    {
      "name": "Table",
      "layout": "TABLE_LAYOUT",
      "filter": "",
      "columns": [
        "Title"
      ],
      "group_by": [],
      "board_columns": [],
      "sort": []
    }
  ],
  "workflows": [
    "Item added"
  ]
}
JSON

# ---------------------------------------------------------------------------
# Fixtures: PID resolution (user + org), and the main node query. "Title" is
# TITLE-typed (must be excluded from custom_fields but still appear as a
# view column); "Board" carries a live sort/group-by (the checklist-visible
# view); "Table" carries neither, and its filter is JSON null (capture.sh's
# `.filter//""` must turn that into "", not the literal string "null").
# "Item closed" is a disabled workflow, excluded from the manifest.
# ---------------------------------------------------------------------------
cat > "$F/pid_user.json" <<'JSON'
{"data":{"user":{"projectV2":{"id":"PID_TEST_1"}}}}
JSON
# No pid_user_empty.json: the org_fallback scenario below omits
# pid_user.json entirely from its own fixtures dir, and the mock treats a
# missing pid_user.json as a failed call (exit 1, no stdout) — modeling a
# genuine call failure. A JSON fixture shaped like
# {"data":{"user":{"projectV2":null}}} would NOT model an empty PID: jq's
# null propagation makes `.data.user.projectV2.id` evaluate to null, and
# `--jq`'s `-r` prints that as the four-character text "null", which is
# non-empty and would make `[ -n "$PID" ]` (wrongly) true — a real
# behavior worth flagging (deferred), but not what this fallback scenario
# is testing here.
cat > "$F/pid_org.json" <<'JSON'
{"data":{"organization":{"projectV2":{"id":"PID_TEST_ORG"}}}}
JSON
cat > "$F/node.json" <<'JSON'
{"data":{"node":{"title":"Demo Project",
  "fields":{"nodes":[
    {"name":"Title","dataType":"TITLE"},
    {"name":"Status","dataType":"SINGLE_SELECT","options":[{"name":"Todo","color":"GRAY","description":"d1"},{"name":"Done","color":"GREEN","description":"d2"}]},
    {"name":"Notes","dataType":"TEXT"},
    {"name":"Estimate","dataType":"NUMBER"},
    {"name":"Due","dataType":"DATE"},
    {"name":"Iteration","dataType":"ITERATION"}
  ]},
  "views":{"nodes":[
    {"number":1,"name":"Board","layout":"BOARD_LAYOUT","filter":"is:open",
     "fields":{"nodes":[{"name":"Title"},{"name":"Status"}]},
     "groupByFields":{"nodes":[{"name":"Status"}]},
     "verticalGroupByFields":{"nodes":[]},
     "sortByFields":{"nodes":[{"field":{"name":"Due"},"direction":"ASC"}]}},
    {"number":2,"name":"Table","layout":"TABLE_LAYOUT","filter":null,
     "fields":{"nodes":[{"name":"Title"}]},
     "groupByFields":{"nodes":[]},
     "verticalGroupByFields":{"nodes":[]},
     "sortByFields":{"nodes":[]}}
  ]},
  "workflows":{"nodes":[
    {"name":"Item added","enabled":true},
    {"name":"Item closed","enabled":false}
  ]}
}}}
JSON

# ---------------------------------------------------------------------------
# Mock gh: capture.sh only ever calls `gh api graphql`, always as a read
# (`-f query=… --jq …` for PID resolution, real `--jq` applied via real jq
# per tests/README.md; no --jq at all for the main node query, whose raw
# envelope capture.sh pipes into its own local jq filter). The mock routes
# the two PID queries by whether the query text names "user(login" or
# "organization(login", and treats an absent --jq as the main node query
# (capture.sh's only call shaped that way). Records every call; refuses and
# logs any query whose leading keyword is "mutation" (capture.sh never
# sends one — this is the negative-path proof required by #786) and any
# explicit write-verb flag (-X/--method/glued -XPOST), the latter exercised
# directly below rather than by capture.sh itself, which never passes one.
# ---------------------------------------------------------------------------
cat > "$BIN/gh" <<'MOCKGH'
#!/usr/bin/env bash
set -euo pipefail
: "${MOCK_GH_CALL_LOG:?MOCK_GH_CALL_LOG must be set}"
printf 'CALL gh %s\n' "$*" >> "$MOCK_GH_CALL_LOG"
if [ -z "${MOCK_GH_FIXTURES:-}" ]; then
  printf 'UNMOCKED-CONTEXT gh %s\n' "$*" >> "$MOCK_GH_CALL_LOG"
  echo "mock gh: invoked with no MOCK_GH_FIXTURES — unmocked call context" >&2
  exit 1
fi
: "${MOCK_MUTATIONS_LOG:?MOCK_MUTATIONS_LOG must be set}"
if [ "${1:-}" != "api" ]; then
  echo "mock gh: unsupported command: $*" >&2
  exit 1
fi
shift
endpoint=""; jq_expr=""; query_text=""
while [ $# -gt 0 ]; do
  case "$1" in
    --jq) jq_expr="$2"; shift 2 ;;
    -f|-F)
      case "$2" in query=*) query_text="${2#query=}" ;; esac
      shift 2 ;;
    -X|--method)
      printf 'WRITE-VERB %s\n' "$2" >> "$MOCK_MUTATIONS_LOG"
      echo "mock gh: refusing write verb ($2) on capture.sh's graphql endpoint" >&2
      exit 1 ;;
    --method=*)
      printf 'WRITE-VERB %s\n' "${1#--method=}" >> "$MOCK_MUTATIONS_LOG"
      echo "mock gh: refusing write verb (${1#--method=}) on capture.sh's graphql endpoint" >&2
      exit 1 ;;
    -X?*)
      printf 'WRITE-VERB %s\n' "${1#-X}" >> "$MOCK_MUTATIONS_LOG"
      echo "mock gh: refusing write verb (${1#-X}) on capture.sh's graphql endpoint" >&2
      exit 1 ;;
    *) endpoint="$1"; shift ;;
  esac
done
if [ "$endpoint" != "graphql" ]; then
  echo "mock gh: unsupported endpoint for capture.sh: $endpoint" >&2
  exit 1
fi
firstword="$(printf '%s' "$query_text" | sed -n 's/^[[:space:]]*//p' | head -c 8)"
case "$firstword" in
  mutation*)
    printf '%s\n' "$query_text" >> "$MOCK_MUTATIONS_LOG"
    echo "mock gh: refusing a mutation — capture.sh is read-only" >&2
    exit 1 ;;
esac
apply(){ if [ -n "$jq_expr" ]; then jq -c -r "$jq_expr" "$1"; else cat "$1"; fi; }
if printf '%s' "$query_text" | grep -q 'user(login'; then
  if [ -f "$MOCK_GH_FIXTURES/pid_user.json" ]; then
    apply "$MOCK_GH_FIXTURES/pid_user.json"
  else
    # No fixture: models a failed call (exit 1, no stdout) — capture.sh's
    # own `2>/dev/null || true` swallows this and leaves PID empty, which
    # is what actually drives the org fallback (see the fixture-block
    # comment above for why a JSON null payload would not).
    echo "mock gh: simulated failure resolving user login" >&2
    exit 1
  fi
elif printf '%s' "$query_text" | grep -q 'organization(login'; then
  apply "$MOCK_GH_FIXTURES/pid_org.json"
elif [ -z "$jq_expr" ]; then
  apply "$MOCK_GH_FIXTURES/node.json"
else
  echo "mock gh: unrecognized graphql query: $query_text" >&2
  exit 1
fi
MOCKGH
chmod +x "$BIN/gh"

# ---------------------------------------------------------------------------
# Hermeticity barrier: the mock is on PATH for the WHOLE suite (including
# every argument-error case), never only inside a per-scenario runner.
# ---------------------------------------------------------------------------
REAL_GH="$(command -v gh || true)"
export PATH="$BIN:$PATH"
export MOCK_GH_CALL_LOG="$WORK/gh-calls.log"
: > "$MOCK_GH_CALL_LOG"
[ "$(command -v gh)" = "$BIN/gh" ] \
  || report "hermeticity: gh resolves to $(command -v gh), expected the mock at $BIN/gh"

# ---------------------------------------------------------------------------
# Sanity check: the mock actually refuses a write verb (proof the refusal
# mechanism works at all, independent of whether capture.sh ever triggers
# it — capture.sh never passes -X, so this is exercised directly).
# ---------------------------------------------------------------------------
WVLOG="$OUT/writeverb.mutations.log"; : > "$WVLOG"
set +e
MOCK_GH_FIXTURES="$F" MOCK_MUTATIONS_LOG="$WVLOG" PATH="$BIN:$PATH" \
  gh api graphql -X POST -f query='query{viewer{login}}' >/dev/null 2>"$OUT/writeverb.stderr.log"
rc=$?
set -e
[ "$rc" -ne 0 ] || report "mock gh (-X POST): expected exit non-zero, got 0"
grep -qi 'refusing write verb' "$OUT/writeverb.stderr.log" \
  || report "mock gh (-X POST): expected a 'refusing write verb' message, got: $(cat "$OUT/writeverb.stderr.log")"
[ -s "$WVLOG" ] \
  || report "mock gh (-X POST): expected the write verb to be recorded in the mutations log"

# ---------------------------------------------------------------------------
# run_capture <label> <skel-dir> <fixtures-dir> <expect-exit> [extra args…]
# ---------------------------------------------------------------------------
run_capture(){
  local label="$1" skel="$2" fixtures="$3" want="$4" rc=0; shift 4
  local mlog="$OUT/$label.mutations.log"; : > "$mlog"
  set +e
  MOCK_GH_FIXTURES="$fixtures" MOCK_MUTATIONS_LOG="$mlog" PATH="$BIN:$PATH" \
    "$skel/scripts/capture.sh" --owner test-owner --project 9 "$@" \
    > "$OUT/$label.stdout.log" 2> "$OUT/$label.stderr.log"
  rc=$?
  set -e
  if [ "$rc" -ne "$want" ]; then
    echo "run_capture $label: exited $rc, expected $want" >&2
    echo "--- stdout ---" >&2; cat "$OUT/$label.stdout.log" >&2 || true
    echo "--- stderr ---" >&2; cat "$OUT/$label.stderr.log" >&2 || true
    report "capture.sh ($label) exited $rc, expected $want"
  fi
  if [ -s "$mlog" ]; then
    report "$label: expected zero mutations, got: $(cat "$mlog")"
  fi
}

# --- full: default --out, byte-for-byte manifest match. ---------------------
SKEL_FULL="$WORK/skel-full"; mkskel "$SKEL_FULL"
run_capture full "$SKEL_FULL" "$F" 0
diff -u "$F/expected.json" "$SKEL_FULL/manifests/project.json" > "$OUT/full.diff" 2>&1 \
  || report "full: manifest did not match expected byte-for-byte: $(cat "$OUT/full.diff")"
grep -qF "captured 5 custom fields, 2 views, 1 enabled workflows" "$OUT/full.stdout.log" \
  || report "full: expected the captured-counts summary line, got: $(cat "$OUT/full.stdout.log")"

# --- out_honoured: a custom --out path receives the manifest; the default --
# --- path (this scenario's own fresh skel) is never created. ---------------
SKEL_OUT="$WORK/skel-out"; mkskel "$SKEL_OUT"
CUSTOM_OUT="$OUT/custom-manifest.json"
run_capture out_honoured "$SKEL_OUT" "$F" 0 --out "$CUSTOM_OUT"
diff -u "$F/expected.json" "$CUSTOM_OUT" > "$OUT/out_honoured.diff" 2>&1 \
  || report "out_honoured: --out path did not match expected byte-for-byte: $(cat "$OUT/out_honoured.diff")"
[ -e "$SKEL_OUT/manifests/project.json" ] \
  && report "out_honoured: expected the default manifest path to stay untouched when --out is given"

# --- org_fallback: the user query fails outright (no pid_user.json fixture
# — see the fixture-block comment above); capture.sh's own
# `2>/dev/null || true` catches that and leaves PID empty, which triggers
# the fallback to the organization query, which does resolve — the
# manifest is still produced correctly, and the call log shows both PID
# queries plus the node query (3 total).
SKEL_ORG="$WORK/skel-org"; mkskel "$SKEL_ORG"
F_ORG="$WORK/fixtures-org"; mkdir -p "$F_ORG"
cp "$F/pid_org.json" "$F_ORG/pid_org.json"
cp "$F/node.json" "$F_ORG/node.json"
before=$(grep -c "^CALL gh" "$MOCK_GH_CALL_LOG" || true)
run_capture org_fallback "$SKEL_ORG" "$F_ORG" 0
after=$(grep -c "^CALL gh" "$MOCK_GH_CALL_LOG" || true)
diff -u "$F/expected.json" "$SKEL_ORG/manifests/project.json" > "$OUT/org_fallback.diff" 2>&1 \
  || report "org_fallback: manifest did not match expected byte-for-byte: $(cat "$OUT/org_fallback.diff")"
[ "$((after - before))" -eq 3 ] \
  || report "org_fallback: expected exactly 3 gh calls (user PID, org PID, node), got $((after - before))"

# ---------------------------------------------------------------------------
# Argument errors exit 2 before a single gh call. run_argerr is the one
# negative-case helper every case goes through, per tests/README.md — it
# runs under the very same mocked PATH the success paths use, so a deleted
# guard would fail loudly (the zero-gh-calls assertion below) rather than
# reaching the real network.
# ---------------------------------------------------------------------------
SKEL_ARGERR="$WORK/skel-argerr"; mkskel "$SKEL_ARGERR"
LABELS_SEEN="$WORK/labels-seen.log"; : > "$LABELS_SEEN"
run_argerr(){ # run_argerr <expected-exit> <label> <args...>
  local expect="$1" label="$2"; shift 2
  local rc=0
  if grep -qxF "$label" "$LABELS_SEEN" 2>/dev/null; then
    report "run_argerr: duplicate label '$label'"
  fi
  printf '%s\n' "$label" >> "$LABELS_SEEN"
  local before after
  before=$(grep -c "^CALL gh" "$MOCK_GH_CALL_LOG" || true)
  set +e
  MOCK_GH_FIXTURES="$F" MOCK_MUTATIONS_LOG="$OUT/$label.mutations.log" PATH="$BIN:$PATH" \
    "$SKEL_ARGERR/scripts/capture.sh" "$@" >"$OUT/$label.stdout.log" 2>"$OUT/$label.stderr.log"
  rc=$?
  set -e
  after=$(grep -c "^CALL gh" "$MOCK_GH_CALL_LOG" || true)
  [ "$rc" -eq "$expect" ] \
    || report "$label: expected exit $expect, got $rc: $(cat "$OUT/$label.stderr.log")"
  [ "$before" -eq "$after" ] \
    || report "$label: expected zero gh calls before the arg guard fires, log grew by $((after - before))"
}

run_argerr 2 badflag --owner acme --project 9 --repo acme/repo
run_argerr 2 missingowner --project 9
run_argerr 2 missingproject --owner acme
run_argerr 2 missingboth

# ===========================================================================
# Hermeticity tripwire, per tests/README.md: the mock recorded every call it
# served, and none of them arrived from an unmocked context.
# ===========================================================================
[ -s "$MOCK_GH_CALL_LOG" ] \
  || report "hermeticity: the mock recorded zero invocations — the call log is not wired up"
if grep -q '^UNMOCKED-CONTEXT ' "$MOCK_GH_CALL_LOG"; then
  report "hermeticity: a gh call was made from an unmocked context: $(grep -m1 '^UNMOCKED-CONTEXT ' "$MOCK_GH_CALL_LOG")"
fi
[ "$(command -v gh)" = "$BIN/gh" ] \
  || report "hermeticity: gh resolves to $(command -v gh), not the mock at $BIN/gh (real gh: ${REAL_GH:-none})"

if [ "$fail" -ne 0 ]; then
  echo "test_capture: FAILED" >&2
  exit 1
fi

echo "test_capture: all assertions passed"
