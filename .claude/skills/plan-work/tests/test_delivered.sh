#!/usr/bin/env bash
# test_delivered.sh — fixture-driven regression test for delivered.sh (#202).
# Follows the mock-`gh` harness conventions from
# ../../github-workflow/tests/README.md (first established in
# test_history.sh and test_timeline_classifier.sh): a mocked `gh` on PATH
# serving fixture JSON from a private mktemp scratch dir, refusing any
# non-GET call and any GraphQL mutation, and the UNMOCKED-CONTEXT tripwire —
# every invocation is logged before anything else happens, and one arriving
# without MOCK_GH_FIXTURES set is recorded as UNMOCKED-CONTEXT instead of
# silently reaching the real, authenticated gh. Every negative case is
# routed through run_delivered_negative, which sets the FULL mock env and
# asserts the call log did not grow.
#
# The GraphQL fixtures are keyed by MOCK_GH_GQL_SCENARIO and a per-scenario
# call counter: the Nth `gh api graphql` of scenario S is answered from
# gql_S_N.json. When gql_S_N.expect exists, every line in it must appear
# literally in that call's query or the mock fails the call — which is what
# makes the pagination assertions load-bearing rather than decorative (a
# follow-up page that forgot its `after:` cursor is a mock failure, not a
# quietly identical second page).
#
# Covers:
#  - the ratified data channel: merged PRs are the UNION of
#    closedByPullRequestsReferences and the merged PRs among
#    CROSS_REFERENCED_EVENT timeline sources, deduplicated by number.
#  - the channel's traps: a cross-reference whose source is an issue rather
#    than a PR (the API's `{}` node), an OPEN PR and a closed-unmerged PR
#    are each excluded; a PR appearing in BOTH halves is counted once.
#  - an issue delivered by more than one merged PR sums net LOC across all
#    of them and lists every PR number.
#  - the literal Estimate-section line, "Delivered so far: PR #… (n LOC)",
#    asserted as exact text (the column exists to be pasted verbatim).
#  - pagination: a connection reporting hasNextPage is followed with its
#    endCursor until exhausted, and the PR that lives on page 2 reaches the
#    table; hasNextPage with no endCursor is a hard stop, never a silently
#    truncated set.
#  - the rate guard reads rateLimit{remaining resetAt} off each GraphQL
#    RESPONSE and never calls `gh api rate_limit` at all: a run whose first
#    response reports an exhausted GraphQL budget stops before the next
#    call even though the REST core bucket the old guard read is full.
#  - a non-numeric remaining, a non-ISO resetAt, and a GraphQL errors block
#    each fail closed (exit 1).
#  - --milestone reads the milestone's open issues WITH --paginate and keeps
#    only the ones carrying a size:* label; an issue on page 2 is reported.
#  - usage errors (missing --repo; a --repo that is not owner/name; both
#    --issues and --milestone; neither; a non-numeric --milestone; a
#    non-numeric --batch-size) exit 2 before any gh call.
#  - the mock's non-GET refusal and its GraphQL-mutation refusal, asserted
#    directly against the mock.
set -euo pipefail
LANG=C
LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DELIVERED_SH="$SCRIPT_DIR/../scripts/delivered.sh"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/delivered-test.XXXXXX")"
cleanup(){ rm -rf "$WORK"; }
trap cleanup EXIT

FIXTURES="$WORK/fixtures"
BIN="$WORK/bin"
OUT="$WORK/out"
COUNTERS="$WORK/counters"
mkdir -p "$FIXTURES" "$BIN" "$OUT" "$COUNTERS"

REPO="test-org/test-repo"
CALL_LOG="$WORK/calls.log"
: > "$CALL_LOG"

fail=0
report(){ echo "FAIL: $*" >&2; fail=1; }

RL_OK='"rateLimit":{"remaining":4000,"resetAt":"2026-09-06T12:00:00Z"}'

# ---------------------------------------------------------------------------
# REST fixture: the milestone listing, two pages. Page 2 exists to prove the
# listing is --paginate'd -- without it, issue #103 is not an error, it is
# simply absent from the table.
# ---------------------------------------------------------------------------
cat > "$FIXTURES/milestone_issues_1.json" <<'JSON'
[
  {"number": 101, "pull_request": null, "labels": [{"name": "size:s"}, {"name": "area:tests"}]},
  {"number": 999, "pull_request": null, "labels": [{"name": "area:tests"}]}
]
JSON
cat > "$FIXTURES/milestone_issues_2.json" <<'JSON'
[
  {"number": 103, "pull_request": null, "labels": [{"name": "size:m"}]}
]
JSON

# ---------------------------------------------------------------------------
# Scenario "issues": #101, #102, #103 batched into ONE GraphQL call.
#  #101 -- one closing PR (#601), net |40-10| = 30.
#  #102 -- three cross-references, NONE of which counts: an issue source
#          (the API's `{}`), an OPEN PR, and a closed-unmerged PR.
#  #103 -- PR #701 appears in BOTH halves of the union (closing link and
#          cross-reference) and must be counted once; #702 only in the
#          timeline. Net = |30-5| + |12-2| = 35; double-counting #701
#          would give 60.
# ---------------------------------------------------------------------------
cat > "$FIXTURES/gql_issues_1.json" <<JSON
{"data":{$RL_OK,"repository":{
  "i101":{"number":101,
    "closedByPullRequestsReferences":{"pageInfo":{"hasNextPage":false,"endCursor":null},
      "nodes":[{"number":601,"state":"MERGED","additions":40,"deletions":10,"mergedAt":"2026-01-10T00:00:00Z"}]},
    "timelineItems":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}},
  "i102":{"number":102,
    "closedByPullRequestsReferences":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]},
    "timelineItems":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[
      {"source":{}},
      {"source":{"number":602,"state":"OPEN","additions":5,"deletions":1,"mergedAt":null}},
      {"source":{"number":603,"state":"CLOSED","additions":5,"deletions":1,"mergedAt":null}}]}},
  "i103":{"number":103,
    "closedByPullRequestsReferences":{"pageInfo":{"hasNextPage":false,"endCursor":null},
      "nodes":[{"number":701,"state":"MERGED","additions":30,"deletions":5,"mergedAt":"2026-02-01T00:00:00Z"}]},
    "timelineItems":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[
      {"source":{"number":701,"state":"MERGED","additions":30,"deletions":5,"mergedAt":"2026-02-01T00:00:00Z"}},
      {"source":{"number":702,"state":"MERGED","additions":12,"deletions":2,"mergedAt":"2026-02-05T00:00:00Z"}}]}}
}}}
JSON
# Note 2: the repository is addressed through GraphQL VARIABLES, never
# interpolated into the document text. All three lines are required of the
# very first call, so a regression that went back to
# `repository(owner: "test-org", ...)` fails the call outright rather than
# quietly producing the same answer.
# shellcheck disable=SC2016  # $owner/$name are GraphQL variable names to be
# matched LITERALLY in the query document -- expanding them here is precisely
# the regression this fixture exists to catch.
printf 'i101: issue(number:101)\ni102: issue(number:102)\ni103: issue(number:103)\nquery($owner:String!, $name:String!)\nrepository(owner: $owner, name: $name)\nVARS: owner=test-org name=test-repo\n' \
  > "$FIXTURES/gql_issues_1.expect"

# ---------------------------------------------------------------------------
# Scenario "paginated": issue #104's closing-PR connection spans two pages.
# Page 1 carries #801 and a cursor; page 2 carries #803. The timeline is
# exhausted on page 1 (#802), so the follow-up must NOT ask for it again.
# Net = 10 + 20 + 5 = 35 across three PRs; an unpaginated run reports two
# PRs and 30, which is exactly the silent truncation this asserts against.
# ---------------------------------------------------------------------------
cat > "$FIXTURES/gql_paginated_1.json" <<JSON
{"data":{$RL_OK,"repository":{
  "i104":{"number":104,
    "closedByPullRequestsReferences":{"pageInfo":{"hasNextPage":true,"endCursor":"CUR-CLOSED-1"},
      "nodes":[{"number":801,"state":"MERGED","additions":10,"deletions":0,"mergedAt":"2026-03-01T00:00:00Z"}]},
    "timelineItems":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[
      {"source":{"number":802,"state":"MERGED","additions":20,"deletions":0,"mergedAt":"2026-03-02T00:00:00Z"}}]}}
}}}
JSON
cat > "$FIXTURES/gql_paginated_2.json" <<JSON
{"data":{$RL_OK,"repository":{
  "i104":{"number":104,
    "closedByPullRequestsReferences":{"pageInfo":{"hasNextPage":false,"endCursor":null},
      "nodes":[{"number":803,"state":"MERGED","additions":5,"deletions":0,"mergedAt":"2026-03-03T00:00:00Z"}]}}
}}}
JSON
# The follow-up MUST carry the cursor page 1 handed out.
printf 'after:"CUR-CLOSED-1"\n' > "$FIXTURES/gql_paginated_2.expect"

# Scenario "nocursor": hasNextPage with no endCursor -- unfollowable, so the
# run must stop rather than report a truncated set as complete.
cat > "$FIXTURES/gql_nocursor_1.json" <<JSON
{"data":{$RL_OK,"repository":{
  "i104":{"number":104,
    "closedByPullRequestsReferences":{"pageInfo":{"hasNextPage":true,"endCursor":null},
      "nodes":[{"number":801,"state":"MERGED","additions":10,"deletions":0,"mergedAt":"2026-03-01T00:00:00Z"}]},
    "timelineItems":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}
}}}
JSON

# ---------------------------------------------------------------------------
# Scenario "ratelow": the FIRST response reports an exhausted GraphQL budget.
# With --batch-size 1 the second issue needs a second call, which the guard
# must refuse. The REST core bucket is deliberately left FULL (see the
# rate_limit fixture below): a guard reading core would sail past this.
# ---------------------------------------------------------------------------
cat > "$FIXTURES/gql_ratelow_1.json" <<'JSON'
{"data":{"rateLimit":{"remaining":10,"resetAt":"2026-09-06T12:00:00Z"},"repository":{
  "i101":{"number":101,
    "closedByPullRequestsReferences":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]},
    "timelineItems":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}
}}}
JSON

# A FULL REST core bucket. Nothing in delivered.sh may consult it any more;
# the suite asserts no `gh api rate_limit` call is made at all.
cat > "$FIXTURES/rate_limit.json" <<'JSON'
{"resources":{"core":{"remaining":5000},"graphql":{"remaining":0}}}
JSON

cat > "$FIXTURES/gql_ratebad_1.json" <<'JSON'
{"data":{"rateLimit":{"remaining":"not-a-number","resetAt":"2026-09-06T12:00:00Z"},"repository":{
  "i101":{"number":101,
    "closedByPullRequestsReferences":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]},
    "timelineItems":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}
}}}
JSON

cat > "$FIXTURES/gql_resetbad_1.json" <<'JSON'
{"data":{"rateLimit":{"remaining":4000,"resetAt":"soon"},"repository":{
  "i101":{"number":101,
    "closedByPullRequestsReferences":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]},
    "timelineItems":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}
}}}
JSON

cat > "$FIXTURES/gql_gqlerror_1.json" <<'JSON'
{"errors":[{"message":"Could not resolve to a Repository with the name 'test-org/test-repo'."}]}
JSON

# Scenario "append": the no---out append regression's own single call, kept
# separate so it does not consume another scenario's fixture counter.
cat > "$FIXTURES/gql_append_1.json" <<JSON
{"data":{$RL_OK,"repository":{
  "i101":{"number":101,
    "closedByPullRequestsReferences":{"pageInfo":{"hasNextPage":false,"endCursor":null},
      "nodes":[{"number":601,"state":"MERGED","additions":40,"deletions":10,"mergedAt":"2026-01-10T00:00:00Z"}]},
    "timelineItems":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}
}}}
JSON

# Scenario "milestone": the issues the two-page milestone listing yields.
cat > "$FIXTURES/gql_milestone_1.json" <<JSON
{"data":{$RL_OK,"repository":{
  "i101":{"number":101,
    "closedByPullRequestsReferences":{"pageInfo":{"hasNextPage":false,"endCursor":null},
      "nodes":[{"number":601,"state":"MERGED","additions":40,"deletions":10,"mergedAt":"2026-01-10T00:00:00Z"}]},
    "timelineItems":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}},
  "i103":{"number":103,
    "closedByPullRequestsReferences":{"pageInfo":{"hasNextPage":false,"endCursor":null},
      "nodes":[{"number":701,"state":"MERGED","additions":30,"deletions":5,"mergedAt":"2026-02-01T00:00:00Z"}]},
    "timelineItems":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}
}}}
JSON

# ---------------------------------------------------------------------------
# Scenario "nullalias": the response carries both requested aliases, but one
# of them is null -- what GitHub returns when an issue number does not
# resolve (deleted, transferred, or simply wrong). #101 is present and
# delivered; #102 came back null. Reporting #102 as "(none) / not
# delivered" would be the invisible omission in its purest form: the
# reading agent would split an issue this script never actually looked at.
# The run must name #102 and fail.
# ---------------------------------------------------------------------------
cat > "$FIXTURES/gql_nullalias_1.json" <<JSON
{"data":{$RL_OK,"repository":{
  "i101":{"number":101,
    "closedByPullRequestsReferences":{"pageInfo":{"hasNextPage":false,"endCursor":null},
      "nodes":[{"number":601,"state":"MERGED","additions":40,"deletions":10,"mergedAt":"2026-01-10T00:00:00Z"}]},
    "timelineItems":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}},
  "i102":null
}}}
JSON

# ---------------------------------------------------------------------------
# Mock gh: routes `gh api graphql` (fixture keyed by scenario + call index),
# `gh api repos/*/issues?milestone=*` (honouring --paginate), and
# `gh api rate_limit`. Refuses any non-GET method and any GraphQL mutation.
# Every invocation is appended to MOCK_GH_CALL_LOG, and one arriving without
# MOCK_GH_FIXTURES is additionally marked UNMOCKED-CONTEXT.
# ---------------------------------------------------------------------------
cat > "$BIN/gh" <<'MOCKGH'
#!/usr/bin/env bash
set -euo pipefail
: "${MOCK_GH_CALL_LOG:?MOCK_GH_CALL_LOG must be set}"
printf 'CALL gh %s\n' "$*" >> "$MOCK_GH_CALL_LOG"
if [ -z "${MOCK_GH_FIXTURES:-}" ]; then
  printf 'UNMOCKED-CONTEXT gh %s\n' "$*" >> "$MOCK_GH_CALL_LOG"
  echo "mock gh: invoked with no MOCK_GH_FIXTURES -- unmocked call context" >&2
  exit 1
fi
case "${1:-}" in
  api)
    shift
    endpoint="" jq_expr="" method="GET" query="" paginate=0 gqlvars=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --jq) jq_expr="$2"; shift 2 ;;
        --paginate) paginate=1; shift ;;
        -f) case "$2" in query=*) query="${2#query=}" ;; esac; shift 2 ;;
        # GraphQL variables (`-F owner=… -F name=…`). Recorded so a fixture
        # can assert the repository is passed as a VARIABLE rather than
        # interpolated into the document text.
        -F) gqlvars="$gqlvars $2"; shift 2 ;;
        -X|--method) method="$2"; shift 2 ;;
        -X?*) method="${1#-X}"; shift ;;
        --method=*) method="${1#--method=}"; shift ;;
        *) endpoint="$1"; shift ;;
      esac
    done
    if [ "$method" != "GET" ]; then
      echo "mock gh: refusing non-GET method ($method) on $endpoint" >&2
      exit 1
    fi
    if [ "$endpoint" = "graphql" ]; then
      # A GraphQL document is a read only while it is a query. Anything
      # declaring a mutation is refused the same way a non-GET verb is.
      case "$query" in
        *mutation*) echo "mock gh: refusing non-GET graphql document (mutation)" >&2; exit 1 ;;
      esac
      : "${MOCK_GH_GQL_SCENARIO:?mock gh: MOCK_GH_GQL_SCENARIO must be set for a graphql call}"
      : "${MOCK_GH_COUNTERS:?mock gh: MOCK_GH_COUNTERS must be set}"
      cfile="$MOCK_GH_COUNTERS/$MOCK_GH_GQL_SCENARIO"
      n=$(( $( [ -f "$cfile" ] && cat "$cfile" || echo 0 ) + 1 ))
      printf '%s' "$n" > "$cfile"
      raw="$MOCK_GH_FIXTURES/gql_${MOCK_GH_GQL_SCENARIO}_${n}.json"
      [ -f "$raw" ] || { echo "mock gh: no graphql fixture for call $n of scenario $MOCK_GH_GQL_SCENARIO: $raw" >&2; exit 1; }
      exp="$MOCK_GH_FIXTURES/gql_${MOCK_GH_GQL_SCENARIO}_${n}.expect"
      if [ -f "$exp" ]; then
        while IFS= read -r want; do
          [ -n "$want" ] || continue
          printf '%s VARS:%s' "$query" "$gqlvars" | grep -qF -- "$want" \
            || { echo "mock gh: graphql call $n of scenario $MOCK_GH_GQL_SCENARIO does not contain: $want" >&2; exit 1; }
        done < "$exp"
      fi
      cat "$raw"
      exit 0
    fi
    case "$endpoint" in
      rate_limit) raw="$MOCK_GH_FIXTURES/rate_limit.json"; pages="$raw" ;;
      repos/*/issues\?milestone=*)
        # Failure modes, selected by MOCK_GH_MILESTONE_FAIL. Without them
        # this endpoint cannot fail at all, and a regression that stopped
        # checking the listing's exit status would leave the suite green.
        #   all   -- the call fails outright, as a mistyped --milestone does
        #            live (HTTP 422 Validation Failed).
        #   page2 -- --paginate emits page 1 and THEN dies. This is the
        #            nastier shape: the caller has a syntactically complete
        #            but SHORT list, indistinguishable from a real one
        #            unless the exit status is checked.
        case "${MOCK_GH_MILESTONE_FAIL:-}" in
          all)
            echo "gh: Validation Failed (HTTP 422)" >&2
            exit 1
            ;;
          page2)
            if [ -n "$jq_expr" ]; then
              jq -c -r "$jq_expr" "$MOCK_GH_FIXTURES/milestone_issues_1.json"
            else
              cat "$MOCK_GH_FIXTURES/milestone_issues_1.json"
            fi
            echo "gh: Bad gateway (HTTP 502) fetching page 2" >&2
            exit 1
            ;;
        esac
        # Without --paginate the caller sees page 1 only -- the mock models
        # gh's real behaviour rather than papering over it.
        if [ "$paginate" = 1 ]; then
          pages="$MOCK_GH_FIXTURES/milestone_issues_1.json $MOCK_GH_FIXTURES/milestone_issues_2.json"
        else
          pages="$MOCK_GH_FIXTURES/milestone_issues_1.json"
        fi
        ;;
      *) echo "mock gh: unknown endpoint: $endpoint" >&2; exit 1 ;;
    esac
    for raw in $pages; do
      [ -f "$raw" ] || { echo "mock gh: no fixture: $raw" >&2; exit 1; }
      if [ -n "$jq_expr" ]; then
        jq -c -r "$jq_expr" "$raw"
      else
        cat "$raw"
      fi
    done
    ;;
  *) echo "mock gh: unsupported command: $*" >&2; exit 1 ;;
esac
MOCKGH
chmod +x "$BIN/gh"

# ---------------------------------------------------------------------------
# run_delivered captures stdout/stderr into logs under $WORK. Crash-path
# diagnostics: dump both on an unexpected non-zero exit.
# ---------------------------------------------------------------------------
run_delivered(){
  local label="$1" scenario="${MOCK_GH_GQL_SCENARIO:-none}"
  local msfail="${MOCK_GH_MILESTONE_FAIL:-}"; shift
  local rc=0
  set +e
  MOCK_GH_FIXTURES="$FIXTURES" MOCK_GH_CALL_LOG="$CALL_LOG" MOCK_GH_COUNTERS="$COUNTERS" \
    MOCK_GH_GQL_SCENARIO="$scenario" MOCK_GH_MILESTONE_FAIL="$msfail" PATH="$BIN:$PATH" \
    "$DELIVERED_SH" "$@" > "$OUT/$label.stdout.log" 2> "$OUT/$label.stderr.log"
  rc=$?
  set -e
  if [ "$rc" -gt 2 ]; then
    echo "run_delivered ($label): $DELIVERED_SH exited $rc" >&2
    echo "--- stdout ---" >&2; cat "$OUT/$label.stdout.log" >&2 || true
    echo "--- stderr ---" >&2; cat "$OUT/$label.stderr.log" >&2 || true
  fi
  return "$rc"
}

# ---------------------------------------------------------------------------
# Negative cases (github-workflow/tests/README.md § Negative cases): routed
# through one helper under the FULL mock env, asserting the call log did
# not grow.
# ---------------------------------------------------------------------------
NEG_RC=0
run_delivered_negative(){ # label, then delivered.sh args
  local label="$1"; shift
  local before after rc=0
  before=$(grep -c "^CALL gh " "$CALL_LOG" || true)
  run_delivered "$label" "$@" || rc=$?
  after=$(grep -c "^CALL gh " "$CALL_LOG" || true)
  [ "$before" = "$after" ] \
    || report "$label: expected zero gh calls, but the call log grew by $((after - before)): $(awk -v n="$before" 'NR>n' "$CALL_LOG" | head -1)"
  NEG_RC=$rc
  return 0
}

run_delivered_negative norepo --issues 101
[ "$NEG_RC" -eq 2 ] || report "--repo absent: expected exit 2, got $NEG_RC"
grep -qF -- "--repo is required" "$OUT/norepo.stderr.log" \
  || report "--repo absent: expected '--repo is required' on stderr, got: $(cat "$OUT/norepo.stderr.log")"

run_delivered_negative badrepo --repo notownername --issues 101
[ "$NEG_RC" -eq 2 ] || report "--repo notownername: expected exit 2, got $NEG_RC"
grep -qF -- "must be owner/name" "$OUT/badrepo.stderr.log" \
  || report "--repo notownername: expected 'must be owner/name' on stderr, got: $(cat "$OUT/badrepo.stderr.log")"

run_delivered_negative bothscopes --repo "$REPO" --issues 101 --milestone 5
[ "$NEG_RC" -eq 2 ] || report "--issues+--milestone: expected exit 2, got $NEG_RC"
grep -qF -- "mutually exclusive" "$OUT/bothscopes.stderr.log" \
  || report "--issues+--milestone: expected 'mutually exclusive' on stderr, got: $(cat "$OUT/bothscopes.stderr.log")"

run_delivered_negative noscope --repo "$REPO"
[ "$NEG_RC" -eq 2 ] || report "neither --issues nor --milestone: expected exit 2, got $NEG_RC"

run_delivered_negative badmilestone --repo "$REPO" --milestone abc
[ "$NEG_RC" -eq 2 ] || report "--milestone abc: expected exit 2, got $NEG_RC"

run_delivered_negative badbatch --repo "$REPO" --issues 101 --batch-size 0
[ "$NEG_RC" -eq 2 ] || report "--batch-size 0: expected exit 2, got $NEG_RC"

run_delivered_negative emptyissues --repo "$REPO" --issues ""
[ "$NEG_RC" -eq 2 ] || report "--issues '': expected exit 2, got $NEG_RC"

run_delivered_negative badflag --repo "$REPO" --issues 101 --bogus-flag
[ "$NEG_RC" -eq 2 ] || report "unknown flag: expected exit 2, got $NEG_RC"

# ---------------------------------------------------------------------------
# Mock refusals, asserted directly against the mock (tests/README.md
# "Adding a new script's test" step 4): a non-GET verb, and a GraphQL
# document that declares a mutation.
# ---------------------------------------------------------------------------
set +e
MOCK_GH_FIXTURES="$FIXTURES" MOCK_GH_CALL_LOG="$CALL_LOG" MOCK_GH_COUNTERS="$COUNTERS" PATH="$BIN:$PATH" \
  gh api -X POST "repos/$REPO/issues" >/dev/null 2>"$OUT/mutation.stderr.log"
rc=$?
set -e
[ "$rc" -ne 0 ] || report "mock: expected a non-GET call to be refused"
grep -qF "refusing non-GET" "$OUT/mutation.stderr.log" \
  || report "mock: expected the non-GET refusal message, got: $(cat "$OUT/mutation.stderr.log")"

set +e
MOCK_GH_FIXTURES="$FIXTURES" MOCK_GH_CALL_LOG="$CALL_LOG" MOCK_GH_COUNTERS="$COUNTERS" PATH="$BIN:$PATH" \
  gh api graphql -f query='mutation { addComment(input:{subjectId:"x",body:"y"}) { clientMutationId } }' \
  >/dev/null 2>"$OUT/gqlmutation.stderr.log"
rc=$?
set -e
[ "$rc" -ne 0 ] || report "mock: expected a graphql mutation document to be refused"
grep -qF "refusing non-GET graphql document" "$OUT/gqlmutation.stderr.log" \
  || report "mock: expected the graphql mutation refusal, got: $(cat "$OUT/gqlmutation.stderr.log")"

# ---------------------------------------------------------------------------
# --issues 101,102,103 in ONE batched call: the union, its exclusions, the
# dedupe, and the literal Estimate-section line.
# ---------------------------------------------------------------------------
before_issues=$(grep -c "^CALL gh " "$CALL_LOG" || true)
rc=0
MOCK_GH_GQL_SCENARIO=issues run_delivered issues --repo "$REPO" --issues 101,102,103 || rc=$?
[ "$rc" -eq 0 ] || report "--issues 101,102,103: expected exit 0, got $rc"
TABLE="$OUT/issues.stdout.log"
after_issues=$(grep -c "^CALL gh " "$CALL_LOG" || true)
[ "$((after_issues - before_issues))" -eq 1 ] \
  || report "--issues 101,102,103: expected exactly 1 gh call (three issues batched into one GraphQL query), got $((after_issues - before_issues))"

row101=$(grep -F "| #101 |" "$TABLE" || true)
[ -n "$row101" ] || report "issue #101: no row in the table"
case "$row101" in
  *"#601"*"30"*) ;; # net LOC = |40-10| = 30
  *) report "issue #101: expected PR #601 and net LOC 30, got: $row101" ;;
esac

# Finding 5: the column is pasted verbatim into an Estimate section, so its
# text is asserted literally, PR token included -- not merely "contains 601".
grep -qF "Delivered so far: PR #601 (30 LOC)" "$TABLE" \
  || report "issue #101: expected the literal line 'Delivered so far: PR #601 (30 LOC)', got: $row101"

row102=$(grep -F "| #102 |" "$TABLE" || true)
[ -n "$row102" ] || report "issue #102: no row in the table"
case "$row102" in
  *"(none)"*"| 0 |"*) ;;
  *) report "issue #102 (non-PR source, OPEN PR, closed-unmerged PR): expected (none) and net LOC 0, got: $row102" ;;
esac
case "$row102" in
  *602*|*603*) report "issue #102: an OPEN or closed-unmerged PR reached the table: $row102" ;;
esac

row103=$(grep -F "| #103 |" "$TABLE" || true)
[ -n "$row103" ] || report "issue #103: no row in the table"
net103=$(awk -F'|' '/\| #103 \|/{gsub(/ /,"",$4); print $4}' "$TABLE")
[ "$net103" = "35" ] \
  || report "issue #103: expected net LOC 35 (|30-5| + |12-2|, PR #701 counted ONCE across both halves of the union), got $net103"
grep -qF "Delivered so far: PR #701, #702 (35 LOC)" "$TABLE" \
  || report "issue #103: expected the literal line 'Delivered so far: PR #701, #702 (35 LOC)', got: $row103"

# ---------------------------------------------------------------------------
# Finding 3: the guarded budget is the one the work spends. No `gh api
# rate_limit` call is made anywhere in this run -- the remaining/reset is
# read off each GraphQL response, as history.sh does.
# ---------------------------------------------------------------------------
if grep -q "^CALL gh api rate_limit" "$CALL_LOG"; then
  report "rate guard: delivered.sh called 'gh api rate_limit' -- the budget must be read off each GraphQL response instead (#201, history.sh)"
fi
grep -qF "remaining, resets at 2026-09-06T12:00:00Z" "$OUT/issues.stderr.log" \
  || report "rate guard: expected the response-borne remaining/reset on stderr, got: $(cat "$OUT/issues.stderr.log")"

# ---------------------------------------------------------------------------
# Finding 4: pagination. Page 2 is fetched with page 1's cursor (the mock
# fails the call if the cursor is missing) and its PR reaches the table.
# ---------------------------------------------------------------------------
before_pg=$(grep -c "^CALL gh " "$CALL_LOG" || true)
rc=0
MOCK_GH_GQL_SCENARIO=paginated run_delivered paginated --repo "$REPO" --issues 104 || rc=$?
[ "$rc" -eq 0 ] || report "pagination: expected exit 0, got $rc (stderr: $(cat "$OUT/paginated.stderr.log"))"
after_pg=$(grep -c "^CALL gh " "$CALL_LOG" || true)
[ "$((after_pg - before_pg))" -eq 2 ] \
  || report "pagination: expected exactly 2 gh calls (page 1 + the follow-up), got $((after_pg - before_pg))"
row104=$(grep -F "| #104 |" "$OUT/paginated.stdout.log" || true)
net104=$(awk -F'|' '/\| #104 \|/{gsub(/ /,"",$4); print $4}' "$OUT/paginated.stdout.log")
[ "$net104" = "35" ] \
  || report "pagination: expected net LOC 35 (10 + 20 + 5); an unpaginated run reports 30. Got $net104 in: $row104"
grep -qF "Delivered so far: PR #801, #802, #803 (35 LOC)" "$OUT/paginated.stdout.log" \
  || report "pagination: expected PR #803 (page 2 of the connection) in the table, got: $row104"

# hasNextPage with no endCursor is unfollowable: stop, never truncate.
before_nc=$(grep -c "^CALL gh " "$CALL_LOG" || true)
rc=0
MOCK_GH_GQL_SCENARIO=nocursor run_delivered nocursor --repo "$REPO" --issues 104 || rc=$?
[ "$rc" -eq 1 ] || report "hasNextPage with no endCursor: expected exit 1, got $rc"
grep -qF "hasNextPage with no endCursor" "$OUT/nocursor.stderr.log" \
  || report "hasNextPage with no endCursor: expected the named refusal on stderr, got: $(cat "$OUT/nocursor.stderr.log")"
after_nc=$(grep -c "^CALL gh " "$CALL_LOG" || true)
[ "$((after_nc - before_nc))" -eq 1 ] \
  || report "hasNextPage with no endCursor: expected exactly 1 gh call, got $((after_nc - before_nc))"
[ -s "$OUT/nocursor.stdout.log" ] \
  && report "hasNextPage with no endCursor: a partial table was emitted -- collection must complete before anything is printed"

# ---------------------------------------------------------------------------
# Finding 3 again, as a run: an exhausted GRAPHQL budget stops the run before
# the next call even though the REST core bucket is full (5000).
# ---------------------------------------------------------------------------
before_rate=$(grep -c "^CALL gh " "$CALL_LOG" || true)
rc=0
MOCK_GH_GQL_SCENARIO=ratelow run_delivered ratelow --repo "$REPO" --issues 101,102 --batch-size 1 --min-remaining 50 || rc=$?
[ "$rc" -eq 1 ] || report "rate guard (graphql exhausted, core full): expected exit 1, got $rc"
grep -qF "rate guard" "$OUT/ratelow.stderr.log" \
  || report "rate guard (low): expected 'rate guard' on stderr, got: $(cat "$OUT/ratelow.stderr.log")"
grep -qF "resets at 2026-09-06T12:00:00Z" "$OUT/ratelow.stderr.log" \
  || report "rate guard (low): expected the reset time in the refusal, got: $(cat "$OUT/ratelow.stderr.log")"
after_rate=$(grep -c "^CALL gh " "$CALL_LOG" || true)
[ "$((after_rate - before_rate))" -eq 1 ] \
  || report "rate guard (low): expected exactly 1 gh call (the run must stop before the second issue's call), got $((after_rate - before_rate))"

for scenario in ratebad resetbad; do
  before_b=$(grep -c "^CALL gh " "$CALL_LOG" || true)
  rc=0
  MOCK_GH_GQL_SCENARIO="$scenario" run_delivered "$scenario" --repo "$REPO" --issues 101 || rc=$?
  [ "$rc" -eq 1 ] || report "rate guard ($scenario): expected exit 1, got $rc"
  grep -qF "unreadable rate limit" "$OUT/$scenario.stderr.log" \
    || report "rate guard ($scenario): expected 'unreadable rate limit' on stderr, got: $(cat "$OUT/$scenario.stderr.log")"
  after_b=$(grep -c "^CALL gh " "$CALL_LOG" || true)
  [ "$((after_b - before_b))" -eq 1 ] \
    || report "rate guard ($scenario): expected exactly 1 gh call, got $((after_b - before_b))"
done

rc=0
MOCK_GH_GQL_SCENARIO=gqlerror run_delivered gqlerror --repo "$REPO" --issues 101 || rc=$?
[ "$rc" -eq 1 ] || report "graphql errors block: expected exit 1, got $rc"
grep -qF "GraphQL errors:" "$OUT/gqlerror.stderr.log" \
  || report "graphql errors block: expected 'GraphQL errors:' on stderr, got: $(cat "$OUT/gqlerror.stderr.log")"

# ---------------------------------------------------------------------------
# --milestone: the listing is --paginate'd, so the size:m issue on PAGE 2
# (#103) reaches the table; the unlabelled #999 on page 1 never does, and no
# GraphQL alias is ever requested for it.
# ---------------------------------------------------------------------------
before_ms=$(grep -c "^CALL gh " "$CALL_LOG" || true)
rc=0
MOCK_GH_GQL_SCENARIO=milestone run_delivered milestone --repo "$REPO" --milestone 5 || rc=$?
[ "$rc" -eq 0 ] || report "--milestone 5: expected exit 0, got $rc (stderr: $(cat "$OUT/milestone.stderr.log"))"
grep -qF "| #101 |" "$OUT/milestone.stdout.log" || report "--milestone 5: expected a row for issue #101 (page 1)"
grep -qF "| #103 |" "$OUT/milestone.stdout.log" \
  || report "--milestone 5: issue #103 lives on PAGE 2 of the milestone listing and is missing -- the listing is not paginated"
grep -qF "| #999 |" "$OUT/milestone.stdout.log" \
  && report "--milestone 5: issue #999 has no size:* label and must not appear"
if awk -v n="$before_ms" 'NR>n' "$CALL_LOG" | grep -q "i999: issue"; then
  report "--milestone 5: a GraphQL alias was requested for the unlabelled issue #999"
fi
if ! awk -v n="$before_ms" 'NR>n' "$CALL_LOG" | grep -q -- "--paginate"; then
  report "--milestone 5: the issues listing was made without --paginate"
fi

# ---------------------------------------------------------------------------
# Finding 1 (round 2): a FAILED --milestone listing must not be reported as
# an empty one. The listing used to be read through `done < <(gh api …)`,
# whose exit status bash discards -- so `gh` failing produced "no open
# size:*-labelled issues in scope -- nothing to report", an empty table and
# exit 0. A mistyped --milestone is an HTTP 422 live today, so this is a
# reachable path, not a hypothetical one.
#
# (a) the call fails outright.
# ---------------------------------------------------------------------------
before_msfail=$(grep -c "^CALL gh " "$CALL_LOG" || true)
gqlcalls_before_msfail=$(grep -c "^CALL gh api graphql" "$CALL_LOG" || true)
rc=0
MOCK_GH_MILESTONE_FAIL=all MOCK_GH_GQL_SCENARIO=msfail \
  run_delivered msfail --repo "$REPO" --milestone 5 || rc=$?
[ "$rc" -eq 1 ] \
  || report "--milestone listing fails: expected exit 1, got $rc -- a failed listing must never be reported as 'nothing to report' with exit 0"
grep -qF "issues?milestone=5" "$OUT/msfail.stderr.log" \
  || report "--milestone listing fails: expected the failed call named on stderr, got: $(cat "$OUT/msfail.stderr.log")"
grep -qF "no open size:*-labelled issues in scope" "$OUT/msfail.stderr.log" \
  && report "--milestone listing fails: the run reported an empty scope instead of the failure"
[ -s "$OUT/msfail.stdout.log" ] \
  && report "--milestone listing fails: a table was emitted; a failed listing must produce no table at all"
after_msfail=$(grep -c "^CALL gh " "$CALL_LOG" || true)
[ "$((after_msfail - before_msfail))" -eq 1 ] \
  || report "--milestone listing fails: expected exactly 1 gh call (the listing itself), got $((after_msfail - before_msfail))"
gqlcalls_msfail=$(grep -c "^CALL gh api graphql" "$CALL_LOG" || true)
[ "$gqlcalls_msfail" = "$gqlcalls_before_msfail" ] \
  || report "--milestone listing fails: a GraphQL call was made after the listing failed"

# ---------------------------------------------------------------------------
# (b) the nastier shape: --paginate emits page 1 and THEN dies. The caller
# holds a syntactically valid but SHORT list. Without an exit-status check
# #101 is reported as the complete answer and page 2's #103 is silently
# absent -- exit 0, no warning, a confidently wrong table.
# ---------------------------------------------------------------------------
before_mspage=$(grep -c "^CALL gh " "$CALL_LOG" || true)
gqlcalls_before_mspage=$(grep -c "^CALL gh api graphql" "$CALL_LOG" || true)
rc=0
MOCK_GH_MILESTONE_FAIL=page2 MOCK_GH_GQL_SCENARIO=msfail \
  run_delivered mspage --repo "$REPO" --milestone 5 || rc=$?
[ "$rc" -eq 1 ] \
  || report "--milestone listing fails mid-pagination: expected exit 1, got $rc -- a partial listing must never be reported as a complete short one"
grep -qF "issues?milestone=5" "$OUT/mspage.stderr.log" \
  || report "--milestone listing fails mid-pagination: expected the failed call named on stderr, got: $(cat "$OUT/mspage.stderr.log")"
grep -qF "| #101 |" "$OUT/mspage.stdout.log" \
  && report "--milestone listing fails mid-pagination: page 1's issue #101 was reported as the complete answer -- page 2 was lost silently"
[ -s "$OUT/mspage.stdout.log" ] \
  && report "--milestone listing fails mid-pagination: a table was emitted from a partial listing"
after_mspage=$(grep -c "^CALL gh " "$CALL_LOG" || true)
[ "$((after_mspage - before_mspage))" -eq 1 ] \
  || report "--milestone listing fails mid-pagination: expected exactly 1 gh call, got $((after_mspage - before_mspage))"
gqlcalls_mspage=$(grep -c "^CALL gh api graphql" "$CALL_LOG" || true)
[ "$gqlcalls_mspage" = "$gqlcalls_before_mspage" ] \
  || report "--milestone listing fails mid-pagination: a GraphQL call was made on a partial listing"

# ---------------------------------------------------------------------------
# Note 2 (round 2): --repo is validated against the character set GitHub
# allows before any call, so a value crafted to break out of the GraphQL
# document is a usage error rather than a request. The probe is the
# reviewer's own reproduction, which previously injected an alias and
# commented out the intended selection.
# ---------------------------------------------------------------------------
run_delivered_negative injectrepo \
  --repo 'o/n") { injected: issue(number:1) { number } } #' --issues 101
[ "$NEG_RC" -eq 2 ] \
  || report "--repo with GraphQL metacharacters: expected exit 2 before any call, got $NEG_RC"
grep -qF -- "must be owner/name" "$OUT/injectrepo.stderr.log" \
  || report "--repo with GraphQL metacharacters: expected 'must be owner/name' on stderr, got: $(cat "$OUT/injectrepo.stderr.log")"

# ---------------------------------------------------------------------------
# Note 5 (round 2): a requested alias coming back null is an issue the
# response says nothing about. It must be named and the run must fail --
# never quietly rendered as "(none) / not delivered", which reads exactly
# like a genuinely undelivered issue.
# ---------------------------------------------------------------------------
before_null=$(grep -c "^CALL gh " "$CALL_LOG" || true)
rc=0
MOCK_GH_GQL_SCENARIO=nullalias run_delivered nullalias --repo "$REPO" --issues 101,102 || rc=$?
[ "$rc" -eq 1 ] \
  || report "null alias in the response: expected exit 1, got $rc"
grep -qF "issue #102" "$OUT/nullalias.stderr.log" \
  || report "null alias in the response: expected issue #102 named on stderr, got: $(cat "$OUT/nullalias.stderr.log")"
grep -qF "| #102 |" "$OUT/nullalias.stdout.log" \
  && report "null alias in the response: #102 was rendered into the table as though it had been looked up"
[ -s "$OUT/nullalias.stdout.log" ] \
  && report "null alias in the response: a partial table was emitted"
after_null=$(grep -c "^CALL gh " "$CALL_LOG" || true)
[ "$((after_null - before_null))" -eq 1 ] \
  || report "null alias in the response: expected exactly 1 gh call, got $((after_null - before_null))"

# ---------------------------------------------------------------------------
# Regression: with no --out, delivered.sh must write to its own inherited
# stdout, never to a reopened literal /dev/stdout path. `> /dev/stdout`
# truncates the underlying file out from under a caller that has already
# redirected this script's stdout into a real file with `>>` (exactly what
# an evidence-log run() recipe does) -- reproduced directly here without
# delivered.sh at all, then proven fixed against the real script.
# ---------------------------------------------------------------------------
APPENDLOG="$WORK/append-repro.log"
: > "$APPENDLOG"
{
  echo "before-marker"
  MOCK_GH_FIXTURES="$FIXTURES" MOCK_GH_CALL_LOG="$CALL_LOG" MOCK_GH_COUNTERS="$COUNTERS" \
    MOCK_GH_GQL_SCENARIO=append PATH="$BIN:$PATH" \
    "$DELIVERED_SH" --repo "$REPO" --issues 101 2>&1
  echo "after-marker"
} >> "$APPENDLOG"
grep -qF "before-marker" "$APPENDLOG" \
  || report "no---out append regression: 'before-marker' was lost -- delivered.sh's own stdout write truncated the caller's log (the /dev/stdout reopen defect)"
grep -qF "after-marker" "$APPENDLOG" \
  || report "no---out append regression: 'after-marker' was lost"
grep -qF "| #101 |" "$APPENDLOG" \
  || report "no---out append regression: delivered.sh's own table row is missing from the appended log"

# ---------------------------------------------------------------------------
# Hermeticity: the tripwire itself is load-bearing, and no call anywhere in
# this run was made from an unmocked context.
# ---------------------------------------------------------------------------
TRIPWIRE_LOG="$WORK/tripwire.log"
: > "$TRIPWIRE_LOG"
set +e
env -u MOCK_GH_FIXTURES PATH="$BIN:$PATH" MOCK_GH_CALL_LOG="$TRIPWIRE_LOG" \
  gh api rate_limit >/dev/null 2>&1
set -e
grep -q '^UNMOCKED-CONTEXT ' "$TRIPWIRE_LOG" \
  || report "tripwire probe: an unmocked-context gh call was NOT marked -- the tripwire is not load-bearing"

[ -s "$CALL_LOG" ] || report "hermeticity: the mock recorded zero invocations -- the call log is not wired up"
if grep -q '^UNMOCKED-CONTEXT ' "$CALL_LOG"; then
  report "hermeticity: a gh call was made from an unmocked context: $(grep -m1 '^UNMOCKED-CONTEXT ' "$CALL_LOG")"
fi

if [ "$fail" -ne 0 ]; then
  echo "test_delivered: FAILED" >&2
  exit 1
fi

echo "test_delivered: all assertions passed (repo=$REPO)"
