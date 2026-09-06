#!/usr/bin/env bash
# test_grant.sh — fixture-driven regression test for grant.sh's --audit branch,
# specifically the invitation-check block (#480, #481). Follows the mock-`gh`
# harness conventions from github-workflow/tests/README.md (copied from
# test_preflight.sh): a mocked `gh` binary on PATH serves fixture JSON from a
# private mktemp scratch dir, refuses any non-GET verb, and no real network
# call is ever reachable. Only --audit is exercised here — audit mode is
# GET-only by design, and this test never invokes apply mode, so the mock
# never needs to accept a write verb from grant.sh itself; the refusal check
# below still proves the mock rejects one if grant.sh ever grew to send one.
#
# Covers:
#  - #480: the invitations call distinguishes 403 (no admin rights) from a
#    5xx, from a connection failure that never produces a status line at
#    all — each gets its own wording, never the 403 wording for a non-403
#    cause.
#  - #481: a malformed 2xx invitations body — a JSON object instead of an
#    array, non-JSON text, and an oversized array (formerly piped through
#    `head -1`, reachable to a SIGPIPE/141 abort under set -euo pipefail) —
#    reports and continues rather than aborting grant.sh --audit, and is
#    worded distinctly from "never granted".
#  - #509/#537: an empty 2xx invitations body, and a non-empty but
#    whitespace-only 2xx body, are each reported as "check unavailable" —
#    never as a definitive "never granted" (`jq -rs` on empty or
#    whitespace-only stdin slurps zero documents and exits 0 with no output,
#    so both cases must be guarded explicitly before ever being handed to
#    jq).
#  - #511: a matching invitation on page 2 of the invitations endpoint is
#    still found — grant.sh's call carries `--paginate`, and a future
#    regression that drops it would revert this scenario's page-2-only
#    match to ok_none's "never granted" outcome, which the assertion below
#    would then catch.
#  - the unguarded-call baseline (an empty array, and an array naming only
#    the account under test) still reports plainly / as pending.
#  - every scenario below still prints exactly one `grants:` line (the
#    file's own stated invariant), and exits 1 (drift=1, from the "none"
#    collaborator permission every scenario shares).
set -euo pipefail
# Pin the locale (LANG=C/LC_ALL=C, following the README convention below) so
# the mock's HTTP-status/header text and grant.sh's own awk/jq output compare
# byte-for-byte the same on every machine this runs on — the assertions below
# are exact-string `grep -F` checks, not a defect class C-vs-UTF-8 would
# itself catch, but any locale-dependent variance in that text would still
# make this test flaky rather than deterministic.
export LANG=C LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GRANT_SH="$SCRIPT_DIR/../scripts/grant.sh"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/grant-test.XXXXXX")"
cleanup(){ rm -rf "$WORK"; }
trap cleanup EXIT

FIXTURES="$WORK/fixtures"
BIN="$WORK/bin"
OUT="$WORK/out"
mkdir -p "$FIXTURES" "$BIN" "$OUT"

REPO="test-org/test-repo"
OWNER="test-owner"
NUM=7
MACHINE="machine-bot"

fail=0
report(){ echo "FAIL: $*" >&2; fail=1; }

# ---------------------------------------------------------------------------
# Fixtures shared by every scenario: project resolves, viewer login differs
# from MACHINE (keeps the project-admin branch on its "unknown/verify
# manually" path so it never interferes with the assertions under test),
# collaborator permission is "none" (forces the invitation-check branch),
# and the account's node id resolves (keeps the per-account loop past the
# collaborator block without an unrelated failure).
# ---------------------------------------------------------------------------
cat > "$FIXTURES/project.json" <<'JSON'
{"data":{"user":{"projectV2":{"id":"PVT_kwHOAAsomeId","viewerCanUpdate":true}}}}
JSON
cat > "$FIXTURES/viewer.json" <<'JSON'
{"login":"someone-else"}
JSON
cat > "$FIXTURES/perm.json" <<'JSON'
{"permission":"none"}
JSON
cat > "$FIXTURES/nodeid.json" <<'JSON'
{"node_id":"MDQ6VXNlcjE="}
JSON

# ---------------------------------------------------------------------------
# Mock gh: routes by endpoint shape. graphql/user/permission/node-id
# endpoints apply the script's actual --jq expression against the fixture
# JSON with the real `jq` binary (`jq -c -r "$jq_expr" "$fixture"`, per
# github-workflow/tests/README.md's Shape section — `-c` keeps a future
# object/array result on one line the way `gh api --jq` emits it, even
# though every expression grant.sh passes today yields a scalar). The
# invitations endpoint is driven by $MOCK_INV_MODE, one scenario per test
# case below, and honours -i the way real `gh api -i` does — verified
# against the live API while designing this test: a status line, headers,
# a blank line, then the body, on both a 2xx AND a non-2xx response; a
# genuine connection failure (MOCK_INV_MODE=network) produces none of that
# framing at all. grant.sh's own success-path call never passes -i (#511 —
# status capture moved to a separate, unpaginated `-i` call made only on
# failure), so `include` only ever comes back 1 on that second call in this
# test; some invitations modes below still branch on it to keep the mock
# generic. Also honours --paginate (#511): when set, `paginated_match`
# serves the single already-merged array real `gh api --paginate` emits for
# a same-shaped-array endpoint (verified live against gh 2.97.0), carrying
# the page-2 match; `grant.sh`'s `jq -rs` (slurp) also tolerates the
# alternative concatenated-top-level-arrays shape github-workflow/tests/
# README.md item 3 prescribes for mocks generally, since `-s` slurps
# however many documents are present — only the merged shape is modelled
# here because it is what this gh actually produces on the wire. Refuses
# any non-GET verb.
# ---------------------------------------------------------------------------
cat > "$BIN/gh" <<'MOCKGH'
#!/usr/bin/env bash
set -euo pipefail
: "${MOCK_GH_CALL_LOG:?MOCK_GH_CALL_LOG must be set}"
printf 'CALL gh %s\n' "$*" >> "$MOCK_GH_CALL_LOG"
if [ -z "${MOCK_GH_FIXTURES:-}" ] || [ -z "${MOCK_INV_MODE:-}" ] || [ -z "${MACHINE_LOGIN:-}" ]; then
  # Reached with the harness env not fully set up (an argument-error case
  # whose guard fired late, or a bare invocation outside run_grant/
  # run_argerr): recorded as a tripwire hit, per
  # ../../github-workflow/tests/README.md, rather than a bare `:` failure
  # with no trace of which call reached here.
  printf 'UNMOCKED-CONTEXT gh %s\n' "$*" >> "$MOCK_GH_CALL_LOG"
  echo "mock gh: invoked with incomplete harness env — unmocked call context" >&2
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
include=0
paginate=0
while [ $# -gt 0 ]; do
  case "$1" in
    --jq) jq_expr="$2"; shift 2 ;;
    -X|--method) method="$2"; shift 2 ;;
    -X?*) method="${1#-X}"; shift ;;
    --method=*) method="${1#--method=}"; shift ;;
    -i|--include) include=1; shift ;;
    --paginate) paginate=1; shift ;;
    -f|-F) shift 2 ;;
    *) endpoint="$1"; shift ;;
  esac
done
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
status_body(){ # status_body <status-line-text> <body-text>
  local status="$1" body="$2"
  if [ "$include" = 1 ]; then
    printf 'HTTP/2.0 %s\r\nContent-Type: application/json; charset=utf-8\r\n\r\n' "$status"
  fi
  printf '%s' "$body"
}
case "$endpoint" in
  graphql)
    apply "$MOCK_GH_FIXTURES/project.json" ;;
  user)
    apply "$MOCK_GH_FIXTURES/viewer.json" ;;
  repos/*/collaborators/*/permission)
    apply "$MOCK_GH_FIXTURES/perm.json" ;;
  repos/*/invitations)
    case "$MOCK_INV_MODE" in
      ok_none)
        status_body "200 OK" '[]'
        exit 0 ;;
      ok_match)
        status_body "200 OK" "[{\"id\":1,\"invitee\":{\"login\":\"$MACHINE_LOGIN\"}}]"
        exit 0 ;;
      forbidden403)
        status_body "403 Forbidden" '{"message":"Must have admin rights to Repository.","status":"403"}'
        echo "gh: Must have admin rights to Repository. (HTTP 403)" >&2
        exit 1 ;;
      servererr500)
        status_body "500 Internal Server Error" '{"message":"Internal Server Error"}'
        echo "gh: Internal Server Error (HTTP 500)" >&2
        exit 1 ;;
      network)
        # A genuine connection failure never produces any HTTP framing at
        # all — no status line, no body — unlike a 5xx, which does.
        echo "gh: connection reset by peer" >&2
        exit 1 ;;
      malformed_object)
        status_body "200 OK" '{"message":"Not Found"}'
        exit 0 ;;
      malformed_nonjson)
        status_body "200 OK" 'this is not json at all'
        exit 0 ;;
      malformed_oversized)
        # All 3000 entries match the account under test — formerly piped
        # through `head -1` under pipefail, reachable to a SIGPIPE/141
        # abort (#481).
        body=$(jq -nc --arg a "$MACHINE_LOGIN" '[range(3000) | {id: ., invitee: {login: $a}}]')
        status_body "200 OK" "$body"
        exit 0 ;;
      empty_body)
        # A 2xx whose body gh returned empty (server closed the connection
        # after headers, or otherwise truncated) — #509.
        status_body "200 OK" ''
        exit 0 ;;
      no_blank_line)
        # #509's other originally-named fixture was truncated -i framing (a 2xx
        # whose header/body blank-line separator never arrives). Under the #511
        # redesign this endpoint's success path never passes -i any more (status
        # capture moved to a separate call made only on failure), so that framing
        # scenario has no call left to exercise here — as exercised it was
        # identical to empty_body (both print nothing with include=0), a
        # duplicate assertion rather than independent coverage (#536, N2).
        # Repurposed to the nearest surviving #509-adjacent gap this PR's guard
        # did not close: a 2xx body that is NON-empty but whitespace-only (a
        # single space). `[ -z "$inv_raw" ]` alone catches only a literally
        # empty string, so this must report the same "check unavailable"
        # wording, never fall through to the plain "-> write" line (#537).
        status_body "200 OK" ' '
        exit 0 ;;
      paginated_match)
        # #511: the matching invitation sits on page 2 only. Real `gh api
        # --paginate` MERGES same-shaped array pages into one top-level JSON
        # array before printing it — verified live against the installed gh
        # 2.97.0 on a real two-page REST array endpoint: one document, one `[`,
        # both pages' items inside, never two concatenated top-level arrays
        # (#536, N1). This mode models that real merged shape directly: with
        # --paginate the endpoint returns the already-merged array carrying the
        # page-2 match; without it (page 1 alone), the array would be empty.
        # Note: grant.sh's `jq -rs` (slurp) tolerates EITHER shape — the
        # concatenated-arrays pattern github-workflow/tests/README.md item 3
        # prescribes for mocks, and this single merged array — since `-s`
        # slurps however many top-level JSON documents are actually present;
        # only the merged shape is exercised here because it is what this gh
        # actually emits. A future regression that drops --paginate from
        # grant.sh reverts this scenario to ok_none's "never granted" outcome —
        # caught by the "invited, not accepted" assertion below.
        if [ "$paginate" = 1 ]; then
          status_body "200 OK" "[{\"id\":2,\"invitee\":{\"login\":\"$MACHINE_LOGIN\"}}]"
        else
          status_body "200 OK" '[]'
        fi
        exit 0 ;;
      *)
        echo "mock gh: unknown MOCK_INV_MODE: $MOCK_INV_MODE" >&2
        exit 1 ;;
    esac
    ;;
  users/*)
    apply "$MOCK_GH_FIXTURES/nodeid.json" ;;
  *)
    echo "mock gh: unknown endpoint: $endpoint" >&2
    exit 1 ;;
esac
MOCKGH
chmod +x "$BIN/gh"

# ---------------------------------------------------------------------------
# Hermeticity barrier, per ../../github-workflow/tests/README.md: the mock is
# prepended for the WHOLE suite, not only inside run_grant/run_argerr, so no
# invocation anywhere — including every argument-error case below — can
# resolve the real `gh` even if the guard it exercises regresses.
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
set +e
MOCK_GH_FIXTURES="$FIXTURES" MOCK_INV_MODE=ok_none MACHINE_LOGIN="$MACHINE" PATH="$BIN:$PATH" \
  gh api -X POST "repos/$REPO/collaborators/$MACHINE" -f permission=push >/dev/null 2>"$OUT/writeverb.stderr.log"
rc=$?
set -e
[ "$rc" -ne 0 ] || report "mock gh (-X POST): expected exit non-zero, got 0"
grep -qi 'refusing non-GET' "$OUT/writeverb.stderr.log" \
  || report "mock gh (-X POST): expected a 'refusing non-GET' message, got: $(cat "$OUT/writeverb.stderr.log")"

# ---------------------------------------------------------------------------
# Run grant.sh --audit under test for one MOCK_INV_MODE scenario, capturing
# stderr (grant.sh's `say` writes everything there) and stdout separately.
# ---------------------------------------------------------------------------
run_grant(){ # run_grant <mode> <expected-exit>
  local mode="$1" want_rc="$2" rc=0
  set +e
  MOCK_GH_FIXTURES="$FIXTURES" MOCK_INV_MODE="$mode" MACHINE_LOGIN="$MACHINE" PATH="$BIN:$PATH" \
    "$GRANT_SH" --repo "$REPO" --owner "$OWNER" --project "$NUM" --machine "$MACHINE" --audit \
    > "$OUT/$mode.stdout.log" 2> "$OUT/$mode.stderr.log"
  rc=$?
  set -e
  if [ "$rc" -ne "$want_rc" ]; then
    echo "run_grant $mode: exited $rc, expected $want_rc" >&2
    echo "--- stdout ---" >&2; cat "$OUT/$mode.stdout.log" >&2 || true
    echo "--- stderr ---" >&2; cat "$OUT/$mode.stderr.log" >&2 || true
    report "grant.sh --audit ($mode) exited $rc, expected $want_rc"
  fi
}

grants_line_count(){ grep -c '^grants:' "$OUT/$1.stderr.log" || true; }

check_one_grants_line(){ # check_one_grants_line <mode>
  local n; n=$(grants_line_count "$1")
  [ "$n" -eq 1 ] || report "$1: expected exactly one grants: line, got $n"
}

check_contains(){ # check_contains <mode> <needle> <label>
  grep -qF -- "$2" "$OUT/$1.stderr.log" \
    || report "$1: expected stderr to contain ($3): $2 — got: $(cat "$OUT/$1.stderr.log")"
}

check_not_contains(){ # check_not_contains <mode> <needle> <label>
  grep -qF -- "$2" "$OUT/$1.stderr.log" \
    && report "$1: expected stderr to NOT contain ($3): $2 — got: $(cat "$OUT/$1.stderr.log")"
  true
}

check_no_exact_line(){ # check_no_exact_line <mode> <line> <label> — a whole-line match, not a
  # substring: the plain "-> write" wording is itself a substring of the
  # longer "-> write (invitation check unavailable — …)" wording, so a
  # plain `grep -qF` substring check for the former can never distinguish
  # the two paths. Anchor to the full line instead.
  grep -qxF -- "$2" "$OUT/$1.stderr.log" \
    && report "$1: expected stderr to NOT contain the exact line ($3): $2 — got: $(cat "$OUT/$1.stderr.log")"
  true
}

# Every scenario below shares perm=none -> drift=1 -> exit 1, "grants: 1 unresolved".
WANT_RC=1

# --- baseline: unguarded call succeeds, no matching invitation. -------------
run_grant ok_none "$WANT_RC"
check_one_grants_line ok_none
check_contains ok_none "collaborator $MACHINE: none -> write" "plain, no unavailable clause"
check_not_contains ok_none "unavailable" "plain path names no unavailable clause"

# --- baseline: unguarded call succeeds, invitation pending. -----------------
run_grant ok_match "$WANT_RC"
check_one_grants_line ok_match
check_contains ok_match "invited, not accepted" "pending-invitation wording"

# --- #480: 403 (no admin rights) keeps its specific wording. ----------------
run_grant forbidden403 "$WANT_RC"
check_one_grants_line forbidden403
check_contains forbidden403 "needs admin rights on $REPO" "403 wording"
check_not_contains forbidden403 "an API or network error" "403 must not use the generic wording"

# --- #480: a 5xx gets its own wording, not the 403 wording. -----------------
run_grant servererr500 "$WANT_RC"
check_one_grants_line servererr500
check_contains servererr500 "HTTP 500" "5xx status surfaced"
check_contains servererr500 "not a permissions error" "5xx wording distinct from 403"
check_not_contains servererr500 "needs admin rights on $REPO" "5xx must not use the 403 wording"

# --- #480: a connection failure (no status line at all) gets its own -------
# --- wording too, not the 403 wording. --------------------------------------
run_grant network "$WANT_RC"
check_one_grants_line network
check_contains network "no response" "no-status-line case surfaced distinctly"
check_not_contains network "needs admin rights on $REPO" "network failure must not use the 403 wording"

# --- #481: a malformed 2xx body (object, not array) reports and continues --
# --- rather than aborting grant.sh --audit under set -euo pipefail. --------
run_grant malformed_object "$WANT_RC"
check_one_grants_line malformed_object
check_contains malformed_object "could not parse" "malformed-body wording"
check_not_contains malformed_object "needs admin rights on $REPO" "malformed body must not use the 403 wording"

# --- #481: a non-JSON 2xx body reports and continues. -----------------------
run_grant malformed_nonjson "$WANT_RC"
check_one_grants_line malformed_nonjson
check_contains malformed_nonjson "could not parse" "non-JSON-body wording"

# --- #481: an oversized array (formerly `| head -1` under pipefail, ---------
# --- reachable to a SIGPIPE/141 abort) does not abort and does not report --
# --- "unavailable" — the match is found, same as ok_match. ------------------
run_grant malformed_oversized "$WANT_RC"
check_one_grants_line malformed_oversized
check_contains malformed_oversized "invited, not accepted" "oversized-array match still found"
check_not_contains malformed_oversized "could not parse" "oversized array is not a parse failure"

# --- #509: an empty 2xx body reports "check unavailable", never a plain ----
# --- "-> write" (a false "never granted"). ----------------------------------
run_grant empty_body "$WANT_RC"
check_one_grants_line empty_body
check_contains empty_body "returned a response this token could not parse" "empty-body wording"
check_no_exact_line empty_body "collaborator $MACHINE: none -> write" "empty body must not fall through to the plain never-granted wording"

# --- #537: a non-empty but whitespace-only 2xx body reports the same -------
# --- "check unavailable" wording, never a plain "-> write" -----------------
# --- ([ -z "$inv_raw" ] alone would miss this; the guard must strip -------
# --- whitespace first). ------------------------------------------------------
run_grant no_blank_line "$WANT_RC"
check_one_grants_line no_blank_line
check_contains no_blank_line "returned a response this token could not parse" "whitespace-only-body wording"
check_no_exact_line no_blank_line "collaborator $MACHINE: none -> write" "whitespace-only body must not fall through to the plain never-granted wording"

# --- #511: a matching invitation on page 2 is found, proving --paginate ----
# --- is actually in effect (page 1 alone is an empty array). ---------------
run_grant paginated_match "$WANT_RC"
check_one_grants_line paginated_match
check_contains paginated_match "invited, not accepted" "page-2 match found"
check_not_contains paginated_match "could not parse" "page-2 match is not a parse failure"

# ---------------------------------------------------------------------------
# Argument errors (#787): every one of grant.sh's four required flags
# (--repo/--owner/--project/--machine) exits 2 before a single gh call, and
# an unrecognized flag does too. run_argerr is the one negative-case helper
# every case goes through, per ../../github-workflow/tests/README.md — it
# runs under the same mocked PATH the success paths use, so a deleted usage
# guard would fail loudly (the zero-gh-calls assertion below) rather than
# reaching the real, authenticated API.
# ---------------------------------------------------------------------------
LABELS_SEEN="$WORK/labels-seen.log"; : > "$LABELS_SEEN"
run_argerr(){ # run_argerr <expected-exit> <label> <args...>
  local expect="$1" label="$2"; shift 2
  local rc=0 before after
  if grep -qxF "$label" "$LABELS_SEEN" 2>/dev/null; then
    report "run_argerr: duplicate label '$label' would overwrite a previous case's $OUT artifact"
  fi
  printf '%s\n' "$label" >> "$LABELS_SEEN"
  before=$(wc -l < "$MOCK_GH_CALL_LOG")
  set +e
  MOCK_GH_FIXTURES="$FIXTURES" MOCK_INV_MODE=ok_none MACHINE_LOGIN="$MACHINE" PATH="$BIN:$PATH" \
    "$GRANT_SH" "$@" >"$OUT/$label.stdout.log" 2>"$OUT/$label.stderr.log"
  rc=$?
  set -e
  after=$(wc -l < "$MOCK_GH_CALL_LOG")
  [ "$rc" -eq "$expect" ] \
    || report "$label: expected exit $expect, got $rc: $(cat "$OUT/$label.stderr.log")"
  [ "$before" -eq "$after" ] \
    || report "$label: expected zero gh calls before the usage guard fires, log grew by $((after - before))"
}

run_argerr 2 badflag --repo "$REPO" --owner "$OWNER" --project "$NUM" --machine "$MACHINE" --bogus-flag
run_argerr 2 missingrepo --owner "$OWNER" --project "$NUM" --machine "$MACHINE"
run_argerr 2 missingowner --repo "$REPO" --project "$NUM" --machine "$MACHINE"
run_argerr 2 missingproject --repo "$REPO" --owner "$OWNER" --machine "$MACHINE"
run_argerr 2 missingmachine --repo "$REPO" --owner "$OWNER" --project "$NUM"
run_argerr 2 missingall

# ===========================================================================
# Hermeticity tripwire, per ../../github-workflow/tests/README.md: the mock
# recorded every call it served, and none of them arrived from an unmocked
# context. A bare invocation of grant.sh whose usage guard had regressed
# would have logged UNMOCKED-CONTEXT here instead of reaching the real,
# authenticated API.
# ===========================================================================
[ -s "$MOCK_GH_CALL_LOG" ] \
  || report "hermeticity: the mock recorded zero invocations — the call log is not wired up"
if grep -q '^UNMOCKED-CONTEXT ' "$MOCK_GH_CALL_LOG"; then
  report "hermeticity: a gh call was made from an unmocked context: $(grep -m1 '^UNMOCKED-CONTEXT ' "$MOCK_GH_CALL_LOG")"
fi
[ "$(command -v gh)" = "$BIN/gh" ] \
  || report "hermeticity: gh resolves to $(command -v gh), not the mock at $BIN/gh (real gh: ${REAL_GH:-none})"

if [ "$fail" -ne 0 ]; then
  echo "test_grant: FAILED" >&2
  exit 1
fi

echo "test_grant: all assertions passed (repo=$REPO, machine=$MACHINE)"
