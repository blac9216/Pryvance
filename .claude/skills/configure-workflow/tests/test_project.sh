#!/usr/bin/env bash
# test_project.sh — fixture-driven regression test for configure-workflow's
# project.sh. Follows the mock-`gh` harness conventions in
# ../../github-workflow/tests/README.md (this skill has no README of its own;
# test_grant.sh, the pre-existing suite here, points at the same file): a
# mocked `gh` binary on PATH serves fixture JSON from a private mktemp
# scratch dir, records every invocation, marks a call reached with no
# fixture env set as UNMOCKED-CONTEXT, and no real network call is ever
# reachable.
#
# project.sh reads manifests/project.json relative to its own script
# location (`_lib.sh`'s MANIFESTS="$HERE/../manifests", no env override), so
# this suite copies the real, unmodified project.sh + _lib.sh into a private
# "skel" tree alongside a fixture manifest, and invokes the copy — never the
# tracked script — exactly the shape the git rules require for a splice
# probe (mutate a COPY outside the worktree).
#
# Covers (#785):
#  - field drift: a custom field the manifest names but live does not have
#    (the "one field renamed" splice case) is reported and, under --audit,
#    fails the run (exit 1) without ever issuing a mutation.
#  - view drift: a view whose live filter differs from the manifest is
#    reported and corrected.
#  - DRY_RUN=1: drift is still detected and printed (`DRY gql: mutation …`)
#    but zero mutations ever reach the mock.
#  - a real (non-dry, non-audit) apply issues exactly the mutations drift
#    implies, recorded by the mock's classification of each GraphQL call's
#    leading token (`query` vs `mutation`) — GraphQL is transport-POST
#    regardless, so verb-refusal doesn't apply; call classification is what
#    "write verbs recorded" means for this script.
#  - a live view absent from the manifest is reported ("not in the
#    manifest") without being counted as drift.
#  - a workflow the manifest names but live reports disabled is reported and
#    fails --audit.
#  - the UI-only checklist line is printed on every run.
#  - --owner/--project argument errors (including an unrecognized flag,
#    which is what a bad --repo would hit — project.sh takes no --repo) exit
#    2 before a single gh call is made.
set -euo pipefail
# Pin the locale so the mock's output and every exact-string `grep -F` assertion below compare byte-for-byte on any host (tests/README.md § Shape).
export LANG=C LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REAL_SCRIPTS="$SCRIPT_DIR/../scripts"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/project-test.XXXXXX")"
cleanup(){ rm -rf "$WORK"; }
trap cleanup EXIT

BIN="$WORK/bin"
OUT="$WORK/out"
F="$WORK/fixtures"
mkdir -p "$BIN" "$OUT" "$F"

fail=0
report(){ echo "FAIL: $*" >&2; fail=1; }

# ---------------------------------------------------------------------------
# The skel tree: an unmodified copy of project.sh + _lib.sh, next to a
# fixture manifests/project.json. One manifest serves every scenario below —
# only the mocked "live" responses vary per scenario, which is what "drift"
# means in the first place.
# ---------------------------------------------------------------------------
SKEL="$WORK/skel"
mkdir -p "$SKEL/scripts" "$SKEL/manifests"
cp "$REAL_SCRIPTS/project.sh" "$SKEL/scripts/project.sh"
cp "$REAL_SCRIPTS/_lib.sh" "$SKEL/scripts/_lib.sh"
chmod +x "$SKEL/scripts/project.sh"
PROJECT_SH="$SKEL/scripts/project.sh"

cat > "$SKEL/manifests/project.json" <<'JSON'
{
  "custom_fields": [
    {"name":"Status","dataType":"SINGLE_SELECT","options":[{"name":"A","color":"GRAY","description":""},{"name":"B","color":"BLUE","description":""}]}
  ],
  "views": [
    {"name":"Board","layout":"TABLE_LAYOUT","filter":"","columns":["Title"],"group_by":[],"board_columns":[],"sort":[]}
  ],
  "workflows": ["Item added"]
}
JSON

# ---------------------------------------------------------------------------
# Fixture builder: every scenario needs a pid.json (project id resolution)
# and a wf.json (final workflows-only re-fetch); only live1 (fields loop)
# and live2 (views loop + extra-views report) vary per scenario, per
# project.sh's own call order (verified by reading the script: `live` is
# reassigned between the fields loop and the views loop).
# ---------------------------------------------------------------------------
mkfixdir(){ # mkfixdir <dir>
  mkdir -p "$1"
  cat > "$1/pid.json" <<'JSON'
{"data":{"user":{"projectV2":{"id":"PID_TEST_1"}}}}
JSON
  cat > "$1/wf.json" <<'JSON'
{"workflows":{"nodes":[{"name":"Item added","enabled":true}]}}
JSON
}

SYNC_LIVE1='{"fields":{"nodes":[{"id":"F_TITLE","name":"Title","dataType":"TITLE"},{"id":"F_STATUS","name":"Status","dataType":"SINGLE_SELECT","options":[{"id":"O1","name":"A"},{"id":"O2","name":"B"}]}]},"views":{"nodes":[{"id":"V_BOARD","name":"Board","layout":"TABLE_LAYOUT","filter":"","fields":{"nodes":[{"name":"Title"}]}}]},"workflows":{"nodes":[{"name":"Item added","enabled":true}]}}'
SYNC_LIVE2='{"fields":{"nodes":[{"id":"F_TITLE","name":"Title"},{"id":"F_STATUS","name":"Status"}]},"views":{"nodes":[{"id":"V_BOARD","name":"Board","layout":"TABLE_LAYOUT","filter":"","fields":{"nodes":[{"name":"Title"}]}}]}}'

# --- sync: nothing to do anywhere.
mkfixdir "$F/sync"
printf '%s\n' "$SYNC_LIVE1" > "$F/sync/live1.json"
printf '%s\n' "$SYNC_LIVE2" > "$F/sync/live2.json"

# --- field_drift: "Status" is absent from live (the splice AC's "one field
# renamed" case — from the script's point of view a renamed field IS a
# missing field) — nothing else drifts, so --audit's exit 1 can only come
# from its own gate at the end of the script, never from an incidental
# abort elsewhere (see field_drift's use in drift_audit below).
mkfixdir "$F/field_drift"
cat > "$F/field_drift/live1.json" <<'JSON'
{"fields":{"nodes":[{"id":"F_TITLE","name":"Title","dataType":"TITLE"}]},"views":{"nodes":[{"id":"V_BOARD","name":"Board","layout":"TABLE_LAYOUT","filter":"","fields":{"nodes":[{"name":"Title"}]}}]},"workflows":{"nodes":[{"name":"Item added","enabled":true}]}}
JSON
cat > "$F/field_drift/live2.json" <<'JSON'
{"fields":{"nodes":[{"id":"F_TITLE","name":"Title"}]},"views":{"nodes":[{"id":"V_BOARD","name":"Board","layout":"TABLE_LAYOUT","filter":"","fields":{"nodes":[{"name":"Title"}]}}]}}
JSON

# --- drift: "Status" is absent from live (same field drift as field_drift
# above), and Board's live filter ("is:open") differs from the manifest's
# (""), so both the field loop and the view loop report drift. Used by the
# AUDIT=0 cases (drift_dry, drift_apply) below, and — since #890's fix —
# also by drift_audit_view below to prove the views loop's AUDIT=1 guards no
# longer abort the script early: before the fix, the view-drift branch's
# `[ $AUDIT = 0 ] && … ; fi` guards ran as standalone (non-if-condition)
# statements inside a `set -euo pipefail` pipeline, and under AUDIT=1 their
# own exit status was nonzero, which aborted the script via errexit+pipefail
# BEFORE the workflow check and the UI checklist ever printed, and before
# the script's own `--audit` gate at the end ran. field_drift isolates the
# one drift type that reached the real gate even pre-fix, which is why it
# stays the case for that isolated assertion.
mkfixdir "$F/drift"
cat > "$F/drift/live1.json" <<'JSON'
{"fields":{"nodes":[{"id":"F_TITLE","name":"Title","dataType":"TITLE"}]},"views":{"nodes":[{"id":"V_BOARD","name":"Board","layout":"TABLE_LAYOUT","filter":"is:open","fields":{"nodes":[{"name":"Title"}]}}]},"workflows":{"nodes":[{"name":"Item added","enabled":true}]}}
JSON
cat > "$F/drift/live2.json" <<'JSON'
{"fields":{"nodes":[{"id":"F_TITLE","name":"Title"}]},"views":{"nodes":[{"id":"V_BOARD","name":"Board","layout":"TABLE_LAYOUT","filter":"is:open","fields":{"nodes":[{"name":"Title"}]}}]}}
JSON

# --- extra_view: fields/views/workflows all match the manifest, but live2
# (what the extra-views report reads) also carries a view the manifest never
# named.
mkfixdir "$F/extra_view"
printf '%s\n' "$SYNC_LIVE1" > "$F/extra_view/live1.json"
cat > "$F/extra_view/live2.json" <<'JSON'
{"fields":{"nodes":[{"id":"F_TITLE","name":"Title"},{"id":"F_STATUS","name":"Status"}]},"views":{"nodes":[{"id":"V_BOARD","name":"Board","layout":"TABLE_LAYOUT","filter":"","fields":{"nodes":[{"name":"Title"}]}},{"id":"V_EXTRA","name":"Extra","layout":"TABLE_LAYOUT","filter":"","fields":{"nodes":[{"name":"Title"}]}}]}}
JSON

# --- wf_disabled: fields/views match; the live workflow is not enabled.
mkfixdir "$F/wf_disabled"
printf '%s\n' "$SYNC_LIVE1" > "$F/wf_disabled/live1.json"
printf '%s\n' "$SYNC_LIVE2" > "$F/wf_disabled/live2.json"
cat > "$F/wf_disabled/wf.json" <<'JSON'
{"workflows":{"nodes":[{"name":"Item added","enabled":false}]}}
JSON

# ---------------------------------------------------------------------------
# Mock gh: project.sh only ever calls `gh api graphql`, either as a read
# (`-f query=… --jq …`, real `--jq` applied via real jq per tests/README.md)
# or, for a mutation, via `_lib.sh`'s gql() (`--input -`, JSON piped on
# stdin, no --jq — the caller parses the raw response itself). The mock
# classifies each call by its query text's leading keyword and routes reads
# by which of "projectV2(number", "views(first:30)" and "workflows(first:30)"
# the query text contains, per project.sh's own three-call sequence (PID,
# fields+views+workflows, fields+views again, workflows alone) verified by
# reading the script.
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
endpoint=""; jq_expr=""; query_text=""; input_stdin=0
while [ $# -gt 0 ]; do
  case "$1" in
    --jq) jq_expr="$2"; shift 2 ;;
    --input) [ "$2" = "-" ] && input_stdin=1; shift 2 ;;
    -f|-F)
      case "$2" in query=*) query_text="${2#query=}" ;; esac
      shift 2 ;;
    *) endpoint="$1"; shift ;;
  esac
done
if [ "$input_stdin" -eq 1 ]; then
  body="$(cat)"
  query_text="$(printf '%s' "$body" | jq -r '.query')"
fi
if [ "$endpoint" != "graphql" ]; then
  echo "mock gh: unsupported endpoint for project.sh: $endpoint" >&2
  exit 1
fi
apply(){ if [ -n "$jq_expr" ]; then jq -c -r "$jq_expr" "$1"; else cat "$1"; fi; }
apply_node(){ # apply_node <raw-node-json-file> — wraps raw fixture content
  # (the ProjectV2 node's own fields) in the {"data":{"node":…}} envelope
  # project.sh's --jq .data.node expression expects, so fixtures can be
  # written as the plain node shape instead of duplicating that envelope.
  printf '{"data":{"node":%s}}' "$(cat "$1")" | jq -c -r "$jq_expr"
}
firstword="$(printf '%s' "$query_text" | sed -n 's/^[[:space:]]*//p' | head -c 8)"
case "$firstword" in
  mutation*)
    printf '%s\n' "$query_text" >> "$MOCK_MUTATIONS_LOG"
    if printf '%s' "$query_text" | grep -q 'createProjectV2View'; then
      echo '{"data":{"createProjectV2View":{"projectV2View":{"id":"VIEW_NEW_ID"}}}}'
    elif printf '%s' "$query_text" | grep -q 'createProjectV2Field'; then
      echo '{"data":{"createProjectV2Field":{"projectV2Field":{"id":"FIELD_NEW_ID"}}}}'
    else
      echo '{"data":{}}'
    fi
    exit 0 ;;
esac
if printf '%s' "$query_text" | grep -q 'projectV2(number'; then
  apply "$MOCK_GH_FIXTURES/pid.json"
elif printf '%s' "$query_text" | grep -q 'workflows(first:30)' && printf '%s' "$query_text" | grep -q 'views(first:30)'; then
  apply_node "$MOCK_GH_FIXTURES/live1.json"
elif printf '%s' "$query_text" | grep -q 'views(first:30)'; then
  apply_node "$MOCK_GH_FIXTURES/live2.json"
elif printf '%s' "$query_text" | grep -q 'workflows(first:30)'; then
  apply_node "$MOCK_GH_FIXTURES/wf.json"
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
# run_project <label> <scenario-dir> <audit 0|1> <dry 0|1> <expect-exit>
# ---------------------------------------------------------------------------
run_project(){
  local label="$1" fixtures="$2" audit="$3" dry="$4" want="$5" rc=0
  local mlog="$OUT/$label.mutations.log"; : > "$mlog"
  local args=(--owner test-owner --project 9)
  [ "$audit" = 1 ] && args+=(--audit)
  set +e
  MOCK_GH_FIXTURES="$fixtures" MOCK_MUTATIONS_LOG="$mlog" DRY_RUN="$dry" PATH="$BIN:$PATH" \
    "$PROJECT_SH" "${args[@]}" > "$OUT/$label.stdout.log" 2> "$OUT/$label.stderr.log"
  rc=$?
  set -e
  if [ "$rc" -ne "$want" ]; then
    echo "run_project $label: exited $rc, expected $want" >&2
    echo "--- stdout ---" >&2; cat "$OUT/$label.stdout.log" >&2 || true
    echo "--- stderr ---" >&2; cat "$OUT/$label.stderr.log" >&2 || true
    report "project.sh ($label) exited $rc, expected $want"
  fi
}

# --- sync: nothing to do; zero mutations.
run_project sync "$F/sync" 0 0 0
grep -qF "project: in sync" "$OUT/sync.stderr.log" \
  || report "sync: expected 'project: in sync', got: $(cat "$OUT/sync.stderr.log")"
[ -s "$OUT/sync.mutations.log" ] \
  && report "sync: expected zero mutations, got: $(cat "$OUT/sync.mutations.log")"
grep -qF "UI checklist (cannot be set via API)" "$OUT/sync.stderr.log" \
  || report "sync: expected the UI-only checklist header to be printed"
grep -qF "workflows: Item added" "$OUT/sync.stderr.log" \
  || report "sync: expected the checklist to name the workflow"

# --- field drift + --audit: reported, exit 1, zero mutations (audit is
# read-only). Uses field_drift, not drift — drift also carries a view
# mismatch, and field_drift isolates the one drift type whose exit 1 is
# provably the gate's on its own, independent of the views loop: a splice
# that removes `[ $AUDIT = 1 ] && exit 1` from a copy of project.sh must
# turn this case red, and does (see the PR's Splice results).
run_project drift_audit "$F/field_drift" 1 0 1
grep -qF "create field Status (SINGLE_SELECT)" "$OUT/drift_audit.stderr.log" \
  || report "drift_audit: expected the missing-field drift message"
[ -s "$OUT/drift_audit.mutations.log" ] \
  && report "drift_audit: --audit must never issue a mutation, got: $(cat "$OUT/drift_audit.mutations.log")"

# --- field drift + view drift, both under --audit (#890 regression): before
# the fix, the views loop's AUDIT=0 guards aborted the script via
# errexit+pipefail as soon as this fixture's drifted view was reached, so
# neither the workflow check nor the UI checklist ever printed even though
# the run still exited 1 — an invisible abort masquerading as the intended
# audit-gate failure. This case proves both sections are reached: the
# missing-field message, the drifted-view message, the workflow line, and
# the UI checklist header all print, and the run still exits 1 from the
# audit gate at the end (not from an early abort) with zero mutations
# issued. Splicing out the views-loop `if`/`fi` fix (restoring the bare
# `[ $AUDIT = 0 ] && … ; fi` AND-lists) must turn this case red by losing
# the workflow line and the UI checklist (see the PR's Splice results).
run_project drift_audit_view "$F/drift" 1 0 1
grep -qF "create field Status (SINGLE_SELECT)" "$OUT/drift_audit_view.stderr.log" \
  || report "drift_audit_view: expected the missing-field drift message"
grep -qF "correct view Board" "$OUT/drift_audit_view.stderr.log" \
  || report "drift_audit_view: expected the drifted-view message"
grep -qF "UI checklist (cannot be set via API)" "$OUT/drift_audit_view.stderr.log" \
  || report "drift_audit_view: expected the UI checklist to be reached, not aborted past — got: $(cat "$OUT/drift_audit_view.stderr.log")"
grep -qF "workflows: Item added" "$OUT/drift_audit_view.stderr.log" \
  || report "drift_audit_view: expected the workflows: line to be reached, not aborted past — got: $(cat "$OUT/drift_audit_view.stderr.log")"
[ -s "$OUT/drift_audit_view.mutations.log" ] \
  && report "drift_audit_view: --audit must never issue a mutation, got: $(cat "$OUT/drift_audit_view.mutations.log")"

# --- drift + DRY_RUN=1 (apply mode, not audit): drift still detected and
# printed via gql()'s own "DRY gql:" message, but zero real mutations reach
# the mock — gql() short-circuits before ever invoking gh.
run_project drift_dry "$F/drift" 0 1 0
grep -qF "project: applied" "$OUT/drift_dry.stderr.log" \
  || report "drift_dry: expected 'project: applied', got: $(cat "$OUT/drift_dry.stderr.log")"
grep -qF "DRY gql: mutation" "$OUT/drift_dry.stderr.log" \
  || report "drift_dry: expected a 'DRY gql: mutation' line, got: $(cat "$OUT/drift_dry.stderr.log")"
[ -s "$OUT/drift_dry.mutations.log" ] \
  && report "drift_dry: DRY_RUN=1 must never issue a real mutation, got: $(cat "$OUT/drift_dry.mutations.log")"

# --- drift, real apply: exactly the two mutations the drift implies.
run_project drift_apply "$F/drift" 0 0 0
grep -qF "project: applied" "$OUT/drift_apply.stderr.log" \
  || report "drift_apply: expected 'project: applied', got: $(cat "$OUT/drift_apply.stderr.log")"
n_mut=$(grep -c . "$OUT/drift_apply.mutations.log" || true)
[ "$n_mut" = "2" ] \
  || report "drift_apply: expected 2 mutations (create field + correct view), got $n_mut: $(cat "$OUT/drift_apply.mutations.log")"
grep -q 'createProjectV2Field' "$OUT/drift_apply.mutations.log" \
  || report "drift_apply: expected a createProjectV2Field mutation"
grep -q 'updateProjectV2View' "$OUT/drift_apply.mutations.log" \
  || report "drift_apply: expected an updateProjectV2View mutation"

# --- extra_view: a live view outside the manifest is reported, but is not
# drift — --audit still exits 0.
run_project extra_view "$F/extra_view" 1 0 0
grep -qF "view 'Extra' is not in the manifest" "$OUT/extra_view.stderr.log" \
  || report "extra_view: expected the not-in-manifest note, got: $(cat "$OUT/extra_view.stderr.log")"

# --- wf_disabled: a manifest-named workflow reported disabled on live fails
# --audit.
run_project wf_disabled "$F/wf_disabled" 1 0 1
grep -qF "workflow NOT enabled: Item added" "$OUT/wf_disabled.stderr.log" \
  || report "wf_disabled: expected the disabled-workflow message, got: $(cat "$OUT/wf_disabled.stderr.log")"

# ---------------------------------------------------------------------------
# Argument errors exit 2 before a single gh call. run_argerr is the one
# negative-case helper every case goes through, per tests/README.md — it
# runs under the very same mocked PATH the success paths use, so a deleted
# guard would fail loudly (the zero-gh-calls assertion below) rather than
# reaching the real network.
# ---------------------------------------------------------------------------
LABELS_SEEN="$WORK/labels-seen.log"; : > "$LABELS_SEEN"
run_argerr(){ # run_argerr <expected-exit> <label> <args...>
  local expect="$1" label="$2"; shift 2
  local rc=0
  if grep -qxF "$label" "$LABELS_SEEN" 2>/dev/null; then
    report "run_argerr: duplicate label '$label'"
  fi
  printf '%s\n' "$label" >> "$LABELS_SEEN"
  local before after
  before=$(wc -l < "$MOCK_GH_CALL_LOG")
  set +e
  MOCK_GH_FIXTURES="$F/sync" MOCK_MUTATIONS_LOG="$OUT/$label.mutations.log" PATH="$BIN:$PATH" \
    "$PROJECT_SH" "$@" >"$OUT/$label.stdout.log" 2>"$OUT/$label.stderr.log"
  rc=$?
  set -e
  after=$(wc -l < "$MOCK_GH_CALL_LOG")
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
  echo "test_project: FAILED" >&2
  exit 1
fi

echo "test_project: all assertions passed"
