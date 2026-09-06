#!/usr/bin/env bash
# test_labels.sh — fixture-driven regression test for labels.sh (#779): a
# mocked `gh` binary on PATH serves fixture JSON from a private mktemp
# scratch dir, refuses any call arriving without the harness env, and no
# real network call is ever reachable. Follows the harness conventions in
# github-workflow/tests/README.md (mock `gh` on PATH, fixtures in a private
# mktemp dir, write-verb recording, `report()`/fail-counter, the
# UNMOCKED-CONTEXT tripwire) — copied from test_grant.sh's shape.
#
# Covers #779's Verification list:
#  - --repo or --areas missing exits 2 before any `gh` call (empty call log).
#  - a malformed --areas file (not an array, missing key, name without the
#    "area:" prefix) exits 2 naming the defect, before any `gh` call.
#  - a well-formed --areas file creates/corrects exactly those labels, with
#    DRY_RUN=1 output asserted verbatim.
#  - --audit is read-only: zero write calls reach the mock, even when drift
#    exists (exit 1).
set -euo pipefail
export LANG=C LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LABELS_SH="$SCRIPT_DIR/../scripts/labels.sh"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/labels-test.XXXXXX")"
cleanup(){ rm -rf "$WORK"; }
trap cleanup EXIT

FIXTURES="$WORK/fixtures"
BIN="$WORK/bin"
OUT="$WORK/out"
mkdir -p "$FIXTURES" "$OUT" "$BIN"

REPO="test-org/test-repo"

fail=0
report(){ echo "FAIL: $*" >&2; fail=1; }

# ---------------------------------------------------------------------------
# Fixtures.
# have.json: what the repo currently carries — "bug" matches the canonical
# set exactly (no drift); "chore" has a wrong color (a correct); "area:old"
# is a non-canonical area with no open issues/PRs (a prune candidate);
# "extra-label" is non-canonical but still on an open issue (must be kept,
# not pruned).
# ---------------------------------------------------------------------------
cat > "$FIXTURES/have.json" <<'JSON'
[
  {"name":"bug","color":"d73a4a","description":"Something isn't working"},
  {"name":"chore","color":"000000","description":"wrong"},
  {"name":"area:old","color":"d1e8ff","description":"stale"},
  {"name":"extra-label","color":"ffffff","description":"kept"}
]
JSON
# open-issue/PR counts per label name queried during pruning; default 0
# when a name has no entry (jq -r --arg n "$n" '.[$n] // 0').
cat > "$FIXTURES/counts.json" <<'JSON'
{"extra-label": 1}
JSON

cat > "$FIXTURES/areas-good.json" <<'JSON'
[{"name":"area:backend","color":"1d76db","description":"Server & API"}]
JSON
cat > "$FIXTURES/areas-not-array.json" <<'JSON'
{"name":"area:backend"}
JSON
cat > "$FIXTURES/areas-missing-key.json" <<'JSON'
[{"name":"area:backend","color":"1d76db"}]
JSON
cat > "$FIXTURES/areas-bad-prefix.json" <<'JSON'
[{"name":"backend","color":"1d76db","description":"no area: prefix"}]
JSON

# ---------------------------------------------------------------------------
# Mock gh: routes by argv shape. Every invocation is logged first
# (hermeticity tripwire, tests/README.md / #568-style): a call arriving
# without MOCK_GH_FIXTURES set is recorded as UNMOCKED-CONTEXT instead of
# silently reaching the real, authenticated gh. Write subcommands (label
# create/edit/delete) are recorded to mutations.log so an --audit run can
# prove zero of them fired even though drift exists.
# ---------------------------------------------------------------------------
cat > "$BIN/gh" <<'MOCKGH'
#!/usr/bin/env bash
set -euo pipefail
: "${MOCK_GH_CALL_LOG:?MOCK_GH_CALL_LOG must be set}"
: "${MOCK_MUTATIONS_LOG:?MOCK_MUTATIONS_LOG must be set}"
printf 'CALL gh %s\n' "$*" >> "$MOCK_GH_CALL_LOG"
if [ -z "${MOCK_GH_FIXTURES:-}" ]; then
  printf 'UNMOCKED-CONTEXT gh %s\n' "$*" >> "$MOCK_GH_CALL_LOG"
  echo "mock gh: invoked with no MOCK_GH_FIXTURES -- unmocked call context" >&2
  exit 1
fi
case "${1:-} ${2:-}" in
  "label list")
    cat "$MOCK_GH_FIXTURES/have.json" ;;
  "label create"|"label edit"|"label delete")
    printf '%s\n' "$*" >> "$MOCK_MUTATIONS_LOG"
    ;;
  "issue list"|"pr list")
    label=""
    while [ $# -gt 0 ]; do case "$1" in --label) label="$2"; shift 2;; *) shift;; esac; done
    n=$(jq -r --arg n "$label" '.[$n] // 0' "$MOCK_GH_FIXTURES/counts.json")
    jq -nc --argjson n "$n" '[range($n)]' | jq -r 'length'
    ;;
  *)
    echo "mock gh: unknown invocation: $*" >&2
    exit 1 ;;
esac
MOCKGH
chmod +x "$BIN/gh"

run_labels(){ # run_labels <label> <want_rc> <args…>
  local label="$1" want_rc="$2"; shift 2
  local rc=0
  : > "$OUT/$label.mutations.log"
  set +e
  MOCK_GH_FIXTURES="$FIXTURES" MOCK_GH_CALL_LOG="$OUT/$label.calls.log" \
    MOCK_MUTATIONS_LOG="$OUT/$label.mutations.log" PATH="$BIN:$PATH" \
    "$LABELS_SH" "$@" > "$OUT/$label.stdout.log" 2> "$OUT/$label.stderr.log"
  rc=$?
  set -e
  if [ "$rc" -ne "$want_rc" ]; then
    echo "--- stdout ($label) ---" >&2; cat "$OUT/$label.stdout.log" >&2 || true
    echo "--- stderr ($label) ---" >&2; cat "$OUT/$label.stderr.log" >&2 || true
    report "labels.sh ($label) exited $rc, expected $want_rc"
  fi
}

calls_empty(){ [ ! -s "$OUT/$1.calls.log" ] || report "$1: expected zero gh calls, got: $(cat "$OUT/$1.calls.log")"; }
mutations_empty(){ [ ! -s "$OUT/$1.mutations.log" ] || report "$1: expected zero write calls, got: $(cat "$OUT/$1.mutations.log")"; }
stderr_has(){ grep -qF -- "$2" "$OUT/$1.stderr.log" || report "$1: expected stderr to contain: $2 — got: $(cat "$OUT/$1.stderr.log")"; }
stderr_line(){ grep -qxF -- "$2" "$OUT/$1.stderr.log" || report "$1: expected an exact stderr line: $2 — got: $(cat "$OUT/$1.stderr.log")"; }

# --- usage: --repo missing exits 2, zero gh calls. ---------------------------
run_labels no_repo 2 --areas "$FIXTURES/areas-good.json"
calls_empty no_repo
stderr_has no_repo "usage: labels.sh"

# --- usage: --areas missing exits 2, zero gh calls. --------------------------
run_labels no_areas 2 --repo "$REPO"
calls_empty no_areas
stderr_has no_areas "usage: labels.sh"

# --- --areas not found exits 2, zero gh calls. --------------------------------
run_labels not_found 2 --repo "$REPO" --areas "$FIXTURES/does-not-exist.json"
calls_empty not_found
stderr_has not_found "--areas file not found"

# --- --areas not a JSON array exits 2 naming the defect, zero gh calls. ------
run_labels not_array 2 --repo "$REPO" --areas "$FIXTURES/areas-not-array.json"
calls_empty not_array
stderr_has not_array "not a JSON array of objects"

# --- --areas entry missing a required key exits 2, zero gh calls. -----------
run_labels missing_key 2 --repo "$REPO" --areas "$FIXTURES/areas-missing-key.json"
calls_empty missing_key
stderr_has missing_key "missing name/color/description"

# --- --areas entry whose name lacks the area: prefix exits 2, zero calls. ---
run_labels bad_prefix 2 --repo "$REPO" --areas "$FIXTURES/areas-bad-prefix.json"
calls_empty bad_prefix
stderr_has bad_prefix 'does not start with "area:"'

# --- well-formed --areas + DRY_RUN=1: exact create/correct/prune/keep lines,
# --- and the DRY: gh label create area:backend line rendered verbatim. -----
: > "$OUT/dry.mutations.log"
set +e
DRY_RUN=1 MOCK_GH_FIXTURES="$FIXTURES" MOCK_GH_CALL_LOG="$OUT/dry.calls.log" \
  MOCK_MUTATIONS_LOG="$OUT/dry.mutations.log" PATH="$BIN:$PATH" \
  "$LABELS_SH" --repo "$REPO" --areas "$FIXTURES/areas-good.json" \
  > "$OUT/dry.stdout.log" 2> "$OUT/dry.stderr.log"
rc=$?
set -e
[ "$rc" -eq 0 ] || { cat "$OUT/dry.stderr.log" >&2; report "dry: expected exit 0, got $rc"; }
stderr_line dry "create  area:backend"
grep -qF -- "DRY: gh label create area:backend --repo $REPO --color 1d76db --description Server\ \&\ API" "$OUT/dry.stderr.log" \
  || report "dry: expected the verbatim DRY create line for area:backend, got: $(cat "$OUT/dry.stderr.log")"
stderr_line dry "correct chore"
stderr_line dry "prune   area:old (unused)"
stderr_has dry "KEEP    extra-label — non-canonical but on open issues/PRs"
grep -qxF "correct bug" "$OUT/dry.stderr.log" && report "dry: bug matches canonically and must not be reported as drift"
true
mutations_empty dry

# --- --audit: read-only. Drift still exists (chore/area:old/extra-label), --
# --- so exit 1, but zero write calls ever reach the mock. -------------------
run_labels audit 1 --repo "$REPO" --areas "$FIXTURES/areas-good.json" --audit
mutations_empty audit
stderr_line audit "correct chore"

# ---------------------------------------------------------------------------
# Hermeticity tripwire: a call made with the mock on PATH but without
# MOCK_GH_FIXTURES set is recorded as UNMOCKED-CONTEXT.
# ---------------------------------------------------------------------------
TRIPWIRE_LOG="$OUT/tripwire.log"
: > "$TRIPWIRE_LOG"
set +e
env -u MOCK_GH_FIXTURES PATH="$BIN:$PATH" MOCK_GH_CALL_LOG="$TRIPWIRE_LOG" MOCK_MUTATIONS_LOG="$OUT/tripwire.mutations.log" \
  "$LABELS_SH" --repo "$REPO" --areas "$FIXTURES/areas-good.json" >/dev/null 2>&1
set -e
grep -q '^UNMOCKED-CONTEXT ' "$TRIPWIRE_LOG" \
  || report "tripwire probe: an unmocked-context gh call was NOT marked — the tripwire is not load-bearing"

for f in "$OUT"/*.calls.log; do
  if grep -q '^UNMOCKED-CONTEXT ' "$f" 2>/dev/null; then
    report "hermeticity: a gh call was made from an unmocked context in $f: $(grep -m1 '^UNMOCKED-CONTEXT ' "$f")"
  fi
done

if [ "$fail" -ne 0 ]; then
  echo "test_labels: FAILED" >&2
  exit 1
fi

echo "test_labels: all assertions passed (repo=$REPO)"
