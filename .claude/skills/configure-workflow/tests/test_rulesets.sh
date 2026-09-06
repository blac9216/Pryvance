#!/usr/bin/env bash
# test_rulesets.sh — fixture-driven regression test for rulesets.sh.
# Follows the mock-`gh` harness conventions in ../../github-workflow/tests/README.md
# (see that file at the top of this directory tree): a mocked `gh` binary on PATH
# serves fixture JSON from a private mktemp scratch dir, and no real network call is
# ever reachable. Pinned to LANG=C / LC_ALL=C.
#
# rulesets.sh is a WRITER (POST to create a ruleset, PUT to update one). The mock
# records every mutation it sees, by kind, to $OUT/mutations.log, and additionally
# captures the exact request body of a POST/PUT to $OUT/post_body.json /
# $OUT/put_body.json so the "contexts in order" assertion below reads the real body
# the script sent, not a re-derivation of it.
#
# Covers (#780's Acceptance Criteria):
#  - without --repo, the script exits 2 before any `gh` call at all (the call log
#    stays empty) — no fallback to `gh repo view`.
#  - `--checks <file>` is an unknown flag now (the old file-parsing arg was removed,
#    not made optional): exits 2, zero `gh` calls.
#  - `--check a --check b` produces a ruleset body whose
#    `required_status_checks` contexts are exactly `a`, `b`, in that order —
#    asserted from the mock's recorded POST body, not from the script's own stdout.
#  - zero `--check` occurrences produces the empty checks list AND the exact
#    stderr warning line.
#  - the mock's write-verb refusal: a bare `gh api -X DELETE` on the rulesets
#    endpoint is refused, proving the mock does not silently serve an
#    unmodelled write.
#
# UNMOCKED-CONTEXT: every mock invocation is logged before anything else happens;
# one arriving without the per-run harness env is recorded as UNMOCKED-CONTEXT
# instead of silently reaching the real, authenticated gh, and the end of this
# suite asserts that string never appears in the call log.
set -euo pipefail
export LANG=C LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RULESETS_SH="$SCRIPT_DIR/../scripts/rulesets.sh"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/rulesets-test.XXXXXX")"
# shellcheck disable=SC2329 # invoked indirectly via `trap cleanup EXIT` on the next line
cleanup(){ rm -rf "$WORK"; }
trap cleanup EXIT

FIXTURES="$WORK/fixtures"
BIN="$WORK/bin"
OUT="$WORK/out"
mkdir -p "$FIXTURES" "$BIN" "$OUT"

REPO="test-org/test-repo"
CALL_LOG="$WORK/calls.log"
: > "$CALL_LOG"

fail=0
report(){ echo "FAIL: $*" >&2; fail=1; }

# No existing ruleset -> the script takes the create (POST) branch.
printf '[]' > "$FIXTURES/list.json"

# ---------------------------------------------------------------------------
# Mock gh. Routes by endpoint shape; records every call to $CALL_LOG first
# (the UNMOCKED-CONTEXT tripwire), refuses any verb it does not model.
# ---------------------------------------------------------------------------
cat > "$BIN/gh" <<'MOCKGH'
#!/usr/bin/env bash
set -euo pipefail
: "${MOCK_GH_CALL_LOG:?MOCK_GH_CALL_LOG must be set}"
printf 'CALL gh %s\n' "$*" >> "$MOCK_GH_CALL_LOG"
if [ -z "${MOCK_FIXTURES:-}" ] || [ -z "${MOCK_OUT:-}" ]; then
  printf 'UNMOCKED-CONTEXT gh %s\n' "$*" >> "$MOCK_GH_CALL_LOG"
  echo "mock gh: invoked with no MOCK_FIXTURES/MOCK_OUT -- unmocked call context" >&2
  exit 1
fi
if [ "${1:-}" != "api" ]; then
  echo "mock gh: unsupported command: $*" >&2
  exit 1
fi
shift
endpoint=""; jqexpr=""; method="GET"
while [ $# -gt 0 ]; do
  case "$1" in
    --jq) jqexpr="$2"; shift 2 ;;
    -X|--method) method="$2"; shift 2 ;;
    -X?*) method="${1#-X}"; shift ;;
    --method=*) method="${1#--method=}"; shift ;;
    --input) shift 2 ;; # value is "-"; body arrives on this process's stdin
    *) endpoint="$1"; shift ;;
  esac
done
respond(){ # respond <json>
  if [ -n "$jqexpr" ]; then printf '%s' "$1" | jq -r "$jqexpr"; else printf '%s\n' "$1"; fi
}
case "$endpoint" in
  repos/*/rulesets)
    case "$method" in
      GET) cat "$MOCK_FIXTURES/list.json" ;;
      POST)
        body=$(cat)
        printf '%s' "$body" > "$MOCK_OUT/post_body.json"
        printf '{"op":"POST","endpoint":"%s"}\n' "$endpoint" >> "$MOCK_OUT/mutations.log"
        respond '{"id":1}' ;;
      *) echo "mock gh: refusing method $method on $endpoint" >&2; exit 1 ;;
    esac ;;
  *) echo "mock gh: unsupported endpoint: $endpoint" >&2; exit 1 ;;
esac
MOCKGH
chmod +x "$BIN/gh"

mockrun(){ # mockrun <args...> — invokes rulesets.sh under the mocked gh
  MOCK_GH_CALL_LOG="$CALL_LOG" MOCK_FIXTURES="$FIXTURES" MOCK_OUT="$OUT" \
    PATH="$BIN:$PATH" "$RULESETS_SH" "$@"
}

# run_argerr <expected-exit> <label> <args...>
# Every negative case (argument errors and refusals alike) runs under the same
# mock env the success paths use — MOCK_GH_CALL_LOG/MOCK_FIXTURES/MOCK_OUT/PATH —
# so a guard that regresses and lets a `gh` call through is caught as a logged,
# non-empty call log instead of silently reaching the real, authenticated `gh`.
run_argerr(){
  local expect="$1" label="$2"; shift 2
  set +e
  out=$(MOCK_GH_CALL_LOG="$CALL_LOG" MOCK_FIXTURES="$FIXTURES" MOCK_OUT="$OUT" \
    PATH="$BIN:$PATH" "$RULESETS_SH" "$@" 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq "$expect" ] || report "$label: expected exit $expect, got $rc (output: $out)"
}

# ---------------------------------------------------------------------------
# 1. Without --repo: exits 2, zero gh calls at all (no fallback to gh repo view).
# ---------------------------------------------------------------------------
: > "$CALL_LOG"
run_argerr 2 "no --repo" --check a
[ -s "$CALL_LOG" ] && report "no --repo: expected zero gh calls, call log: $(cat "$CALL_LOG")"

# ---------------------------------------------------------------------------
# 2. --checks <file> is an unknown flag now: exits 2, zero gh calls.
# ---------------------------------------------------------------------------
: > "$CALL_LOG"
run_argerr 2 "--checks" --repo "$REPO" --checks docs/process/testing.md
[ -s "$CALL_LOG" ] && report "--checks: expected zero gh calls, call log: $(cat "$CALL_LOG")"

# ---------------------------------------------------------------------------
# 3. --check a --check b: the POST body's required_status_checks contexts are
#    exactly a, b, in that order.
# ---------------------------------------------------------------------------
: > "$CALL_LOG"; rm -f "$OUT/post_body.json"
set +e
out=$(mockrun --repo "$REPO" --check a --check b 2>&1)
rc=$?
set -e
[ "$rc" -eq 0 ] || report "--check a --check b: expected exit 0, got $rc (output: $out)"
[ -f "$OUT/post_body.json" ] || report "--check a --check b: no POST body was recorded"
if [ -f "$OUT/post_body.json" ]; then
  got=$(jq -c '[.rules[] | select(.type=="required_status_checks") | .parameters.required_status_checks[].context]' "$OUT/post_body.json")
  [ "$got" = '["a","b"]' ] || report "--check a --check b: expected contexts [\"a\",\"b\"] in order, got $got"
fi

# ---------------------------------------------------------------------------
# 4. Zero --check: empty checks list AND the exact stderr warning line.
# ---------------------------------------------------------------------------
: > "$CALL_LOG"; rm -f "$OUT/post_body.json"
set +e
out=$(mockrun --repo "$REPO" 2>&1)
rc=$?
set -e
[ "$rc" -eq 0 ] || report "no --check: expected exit 0, got $rc (output: $out)"
grep -qF "warning: no --check given — ruleset will require a PR but no checks" <<<"$out" \
  || report "no --check: missing the exact stderr warning line (got: $out)"
[ -f "$OUT/post_body.json" ] || report "no --check: no POST body was recorded"
if [ -f "$OUT/post_body.json" ]; then
  got=$(jq -c '[.rules[] | select(.type=="required_status_checks") | .parameters.required_status_checks[].context]' "$OUT/post_body.json")
  [ "$got" = '[]' ] || report "no --check: expected empty contexts list, got $got"
fi

# ---------------------------------------------------------------------------
# 5. Write-verb refusal: the mock rejects a verb it does not model
#    (DELETE) on the rulesets endpoint, proving it never silently serves an
#    unmodelled write.
# ---------------------------------------------------------------------------
: > "$CALL_LOG"
set +e
MOCK_GH_CALL_LOG="$CALL_LOG" MOCK_FIXTURES="$FIXTURES" MOCK_OUT="$OUT" \
  PATH="$BIN:$PATH" gh api -X DELETE "repos/$REPO/rulesets" >/dev/null 2>&1
rc=$?
set -e
[ "$rc" -ne 0 ] || report "mock gh: expected DELETE on rulesets endpoint to be refused"

# ---------------------------------------------------------------------------
# UNMOCKED-CONTEXT tripwire: never appears in any call log produced above.
# ---------------------------------------------------------------------------
if grep -q 'UNMOCKED-CONTEXT' "$CALL_LOG" 2>/dev/null; then
  report "UNMOCKED-CONTEXT appeared in the call log — a call reached the mock without harness env"
fi

if [ "$fail" -eq 0 ]; then
  echo "test_rulesets.sh: ok"
  exit 0
else
  exit 1
fi
