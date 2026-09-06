#!/usr/bin/env bash
# test_home_deferred.sh — fixture-driven regression test for home-deferred.sh.
# Follows the mock-`gh` harness conventions in tests/README.md: a mocked `gh`
# binary on PATH serves fixture files from a private mktemp scratch dir, and
# no real network call is ever reachable. Pinned to LANG=C / LC_ALL=C.
#
# home-deferred.sh is a WRITER that also shells out to the real
# stamp-claim.sh (not a re-implementation of it — the same mocked `gh`
# serves both). The mock records every mutation it sees, by kind, to
# $OUT/mutations.log (one JSON object per line: {op, ...}) so a refusal or
# no-op path can be proven to have issued zero mutations of the relevant
# kind, not just asserted by exit code.
#
# Fixture state per issue lives in flat files under $FIXTURES (milestone_N,
# labels_N.json, claim_N, item_N, blocked_N.json, node_N) that the mock
# reads fresh on every `gh` invocation. Between assertions in this file the
# test edits those files directly to simulate "the prior run has now landed
# on the real board". WITHIN one run the mock also applies the three state
# transitions its own recorded mutations would cause on the real board —
# add-item creates item_N, set-status rewrites it, set-claim rewrites
# claim_N — because a single run genuinely reads back what it just wrote:
# home-deferred.sh creates the project row and then claims a field ON that
# row, and releases a claim it took moments earlier. A mock that served the
# pre-mutation state to those reads would be modelling an impossible board.
#
# Board membership is ONE fact. Both read queries — `name:"Claimed by"` and
# `name:"Status"` — answer from the same `item_N` fixture, so an issue is
# either on the board for both or off the board for both. (Round-1 review
# F2: a mock that served an on-board `Claimed by` node for an issue with no
# `item_N` fixture hid the fact that the script could not home an off-board
# issue at all. Flipping that branch back to unconditional turns this suite
# red — the load-bearing probe.)
#
# Covers (per issue #262's Acceptance Criteria, plus round-1 review and #350):
#  - a valid, OFF-BOARD record is applied: exact mutations asserted, and the
#    board row is created BEFORE the claim is taken (a claim is a field on
#    the row, so no other order can home an off-board issue at all).
#  - missing priority is refused: zero mutations, zero `gh` calls, non-zero
#    final exit.
#  - a bug record without severity is refused: zero mutations, non-zero exit.
#  - a record carrying `parent` is refused: zero mutations.
#  - a second run of the same (now-applied) record is a no-op: zero
#    mutations, after the fixtures are updated to reflect the first run's
#    result and with the claim LIVE and already ours — `stamp-claim.sh take`
#    treats its own live claim as an idempotent no-op (exit 0, applied:false,
#    no mutation), which is the signal home-deferred.sh reads, by exit code.
#  - a live FOREIGN claim on the item skips the record: zero mutations,
#    exit 0 (stamp-claim exit 3 = refusal).
#  - a stale foreign claim is taken over AND the supersede reminder reaches
#    stderr (claims.md's announcement rule; stamp-claim delegates it).
#  - a HARD stamp-claim failure (its GraphQL read fails) is NOT a refusal:
#    the record is REJECTED and the run's exit code flips (exit 1 ≠ exit 3).
#  - a `gh` failure mid-batch fails only that record: its claim is released,
#    the next record still applies, and the run exits non-zero (issue #350).
#  - the release ITSELF can fail (issue #361 problem 3): when a mid-apply
#    failure's own hand-back release also fails, the record is still FAILED
#    under the true original cause (not the release), the item is named as
#    STILL HELD, and the next record on stdin still applies.
#  - `--readd`: bare issue numbers (all off-board by definition), project
#    item + Status only.
#  - the dependencies POST sends `issue_id` with `-F` (typed integer), per
#    github-tools.md's canonical row — the mock records the flag it saw.
#  - `--log` line shape: `jq -e '.event=="triage" and .claim and .ts'`.
#  - an UNWRITABLE `--log` path: each record is REJECTED naming the log (not
#    the claim subsystem) as the cause, the claim the take had ALREADY
#    written is read back and released, the batch runs to the end of stdin,
#    and a re-run with a writable log applies both records in full (round-2
#    F1 / #350 AC2).
#
# Exit-code diagnostics capture the status into RC before reporting: `$?`
# inside `if ! cmd; then` is the negated condition's status (always 0) and
# would make every "got ..." message lie (round-2 F2).
set -euo pipefail
export LANG=C LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOME_DEFERRED_SH="$SCRIPT_DIR/../scripts/home-deferred.sh"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/home-deferred-test.XXXXXX")"
# shellcheck disable=SC2329 # invoked indirectly via `trap cleanup EXIT` on the next line
cleanup(){ rm -rf "$WORK"; }
trap cleanup EXIT

FIXTURES="$WORK/fixtures"
BIN="$WORK/bin"
OUT="$WORK/out"
mkdir -p "$FIXTURES" "$BIN" "$OUT"

REPO="test-org/test-repo"
PROJECT_ID="PVT_test123"
STATUS_FIELD_ID="PVTSSF_teststatus"
CLAIMED_FIELD_ID="PVTF_testclaimed"
READY_OPT="opt_ready"; BACKLOG_OPT="opt_backlog"
ME="test-01"
# option-id -> Status name, so the mock can reflect a set-status back into
# the item_N fixture the same way the real board would.
OPT_NAMES="$READY_OPT=Ready,$BACKLOG_OPT=Backlog"

fail=0
report(){ echo "FAIL: $*" >&2; fail=1; }

WT="$WORK/work-tracking.md"
cat > "$WT" <<DOC
# Work tracking

| Field | Id |
|---|---|
| Project | \`$PROJECT_ID\` |
| Status | \`$STATUS_FIELD_ID\` |
| Status: Ready | \`$READY_OPT\` |
| Status: Backlog | \`$BACKLOG_OPT\` |
| Claimed by | \`$CLAIMED_FIELD_ID\` |
DOC

# ---------------------------------------------------------------------------
# Fixture helpers. A missing file means "not set" (empty milestone, no
# labels, unclaimed, not on the board, no blockers, default node id).
# ---------------------------------------------------------------------------
set_milestone(){ printf '%s' "$2" > "$FIXTURES/milestone_$1"; }
set_labels(){ printf '%s' "$2" > "$FIXTURES/labels_$1.json"; }
set_claim(){ printf '%s' "$2" > "$FIXTURES/claim_$1"; }
set_item(){ printf '%s' "$2" > "$FIXTURES/item_$1"; } # content = current Status name, "" = on board no status, file absent = not on board
set_blocked(){ printf '%s' "$2" > "$FIXTURES/blocked_$1.json"; }
set_state(){ printf '%s' "$2" > "$FIXTURES/state_$1"; } # content = "STATE:REASON", e.g. "CLOSED:NOT_PLANNED"; file absent = "OPEN:"
set_comments(){ printf '%s' "$2" > "$FIXTURES/comments_$1.json"; } # content = JSON array of comment body strings
clear_fixtures(){
  rm -f "$FIXTURES"/milestone_"$1" "$FIXTURES"/labels_"$1".json "$FIXTURES"/claim_"$1" \
        "$FIXTURES"/item_"$1" "$FIXTURES"/blocked_"$1".json "$FIXTURES"/state_"$1" \
        "$FIXTURES"/comments_"$1".json
}

# ---------------------------------------------------------------------------
# Mock gh.
# ---------------------------------------------------------------------------
cat > "$BIN/gh" <<'MOCKGH'
#!/usr/bin/env bash
set -euo pipefail
# Hermeticity tripwire (#568, following tests/README.md's convention and
# #477): every invocation is logged before anything else happens, and one
# arriving without the per-run harness env (MOCK_FIXTURES/MOCK_OUT/
# MOCK_PROJECT_ID, set only by mockgh()/run()) is recorded as
# UNMOCKED-CONTEXT instead of silently reaching the real, authenticated gh.
: "${MOCK_GH_CALL_LOG:?MOCK_GH_CALL_LOG must be set}"
printf 'CALL gh %s\n' "$*" >> "$MOCK_GH_CALL_LOG"
if [ -z "${MOCK_FIXTURES:-}" ] || [ -z "${MOCK_OUT:-}" ] || [ -z "${MOCK_PROJECT_ID:-}" ]; then
  printf 'UNMOCKED-CONTEXT gh %s\n' "$*" >> "$MOCK_GH_CALL_LOG"
  echo "mock gh: invoked with no MOCK_FIXTURES/MOCK_OUT/MOCK_PROJECT_ID -- unmocked call context" >&2
  exit 1
fi
: "${MOCK_FIXTURES:?}"
: "${MOCK_OUT:?}"
: "${MOCK_PROJECT_ID:?}"

log(){ printf '%s\n' "$1" >> "$MOCK_OUT/mutations.log"; }
read_fixture(){ # read_fixture <path> <default>
  if [ -f "$1" ]; then cat "$1"; else printf '%s' "$2"; fi
}

if [ "${1:-}" = "repo" ] && [ "${2:-}" = "view" ]; then
  echo "mock gh: repo view should not be called when --repo is passed" >&2
  exit 1
fi

if [ "${1:-}" = "issue" ] && [ "${2:-}" = "view" ]; then
  n="$3"; shift 3
  want=""; jqexpr=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo) shift 2 ;;
      --json) want="$2"; shift 2 ;;
      --jq) jqexpr="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  if [ "$want" = "milestone" ]; then
    m=$(read_fixture "$MOCK_FIXTURES/milestone_$n" "")
    resp=$(jq -nc --arg m "$m" '{milestone:(if $m=="" then null else {title:$m} end)}')
  elif [ "$want" = "labels" ]; then
    l=$(read_fixture "$MOCK_FIXTURES/labels_$n.json" "[]")
    resp=$(jq -nc --argjson l "$l" '{labels:($l|map({name:.}))}')
  elif [ "$want" = "state,stateReason" ]; then
    s=$(read_fixture "$MOCK_FIXTURES/state_$n" "OPEN:")
    st="${s%%:*}"; rs="${s#*:}"
    resp=$(jq -nc --arg st "$st" --arg rs "$rs" '{state:$st, stateReason:(if $rs=="" then null else $rs end)}')
  elif [ "$want" = "comments" ]; then
    c=$(read_fixture "$MOCK_FIXTURES/comments_$n.json" "[]")
    resp=$(jq -nc --argjson c "$c" '{comments:($c|map({body:.}))}')
  else
    echo "mock gh: unsupported issue view --json $want" >&2; exit 1
  fi
  if [ -n "$jqexpr" ]; then jq -r "$jqexpr" <<<"$resp"; else printf '%s\n' "$resp"; fi
  exit 0
fi

if [ "${1:-}" = "issue" ] && [ "${2:-}" = "edit" ]; then
  n="$3"; shift 3
  ms=""; lbl=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo) shift 2 ;;
      --milestone) ms="$2"; shift 2 ;;
      --add-label) lbl="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  if [ -n "${MOCK_FAIL_MILESTONE:-}" ] && [ "$n" = "$MOCK_FAIL_MILESTONE" ] && [ -n "$ms" ]; then
    echo "mock gh: injected failure setting the milestone on #$n" >&2
    exit 1
  fi
  [ -z "$ms" ] || log "$(jq -nc --argjson n "$n" --arg v "$ms" '{op:"milestone",issue:$n,value:$v}')"
  [ -z "$lbl" ] || log "$(jq -nc --argjson n "$n" --arg v "$lbl" '{op:"add-label",issue:$n,value:$v}')"
  exit 0
fi

if [ "${1:-}" = "issue" ] && [ "${2:-}" = "close" ]; then
  n="$3"; shift 3
  reason=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo) shift 2 ;;
      --reason) reason="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  if [ -n "${MOCK_FAIL_CLOSE:-}" ] && [ "$n" = "$MOCK_FAIL_CLOSE" ]; then
    echo "mock gh: injected failure closing #$n" >&2
    exit 1
  fi
  log "$(jq -nc --argjson n "$n" --arg v "$reason" '{op:"close",issue:$n,value:$v}')"
  rs=$(printf '%s' "$reason" | tr '[:lower:] ' '[:upper:]_')
  printf 'CLOSED:%s' "$rs" > "$MOCK_FIXTURES/state_$n"
  exit 0
fi

if [ "${1:-}" = "issue" ] && [ "${2:-}" = "comment" ]; then
  n="$3"; shift 3
  body=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo) shift 2 ;;
      --body) body="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  if [ -n "${MOCK_FAIL_COMMENT:-}" ] && [ "$n" = "$MOCK_FAIL_COMMENT" ]; then
    echo "mock gh: injected failure commenting on #$n" >&2
    exit 1
  fi
  log "$(jq -nc --argjson n "$n" --arg v "$body" '{op:"comment",issue:$n,value:$v}')"
  cur=$(read_fixture "$MOCK_FIXTURES/comments_$n.json" "[]")
  new=$(jq -nc --argjson cur "$cur" --arg b "$body" '$cur + [$b]')
  printf '%s' "$new" > "$MOCK_FIXTURES/comments_$n.json"
  echo "https://github.com/test-org/test-repo/issues/$n#issuecomment-1"
  exit 0
fi

if [ "${1:-}" = "api" ] && [ "${2:-}" = "graphql" ]; then
  shift 2
  query=""; jqexpr=""
  owner=""; name=""; number=""; project=""; content=""; item=""; field=""; option=""; value=""
  while [ $# -gt 0 ]; do
    case "$1" in
      -f|-F)
        case "$2" in
          query=*) query="${2#query=}" ;;
          owner=*) owner="${2#owner=}" ;;
          name=*) name="${2#name=}" ;;
          number=*) number="${2#number=}" ;;
          project=*) project="${2#project=}" ;;
          content=*) content="${2#content=}" ;;
          item=*) item="${2#item=}" ;;
          field=*) field="${2#field=}" ;;
          option=*) option="${2#option=}" ;;
          value=*) value="${2#value=}" ;;
        esac
        shift 2 ;;
      --jq) jqexpr="$2"; shift 2 ;;
      *) shift ;;
    esac
  done

  if printf '%s' "$query" | grep -q 'mutation('; then
    if printf '%s' "$query" | grep -q 'addProjectV2ItemById'; then
      n="${content#node-}"
      log "$(jq -nc --arg project "$project" --arg content "$content" '{op:"add-item",project:$project,content:$content}')"
      # The row now exists on the board: subsequent reads in THIS run
      # (notably `Claimed by`, which lives on this row) must see it.
      printf '' > "$MOCK_FIXTURES/item_$n"
      resp=$(jq -nc --arg id "item-$n" '{data:{addProjectV2ItemById:{item:{id:$id}}}}')
    elif printf '%s' "$query" | grep -q 'singleSelectOptionId'; then
      log "$(jq -nc --arg project "$project" --arg item "$item" --arg field "$field" --arg option "$option" \
        '{op:"set-status",project:$project,item:$item,field:$field,option:$option}')"
      # Reflect the new Status onto the row, as the real board would.
      n="${item#item-}"
      sname=""
      oldifs="$IFS"; IFS=','
      for pair in ${MOCK_OPT_NAMES:-}; do
        case "$pair" in "$option="*) sname="${pair#*=}" ;; esac
      done
      IFS="$oldifs"
      [ -z "$sname" ] || printf '%s' "$sname" > "$MOCK_FIXTURES/item_$n"
      resp=$(jq -nc --arg id "$item" '{data:{updateProjectV2ItemFieldValue:{projectV2Item:{id:$id}}}}')
    elif printf '%s' "$query" | grep -q 'text:\$value'; then
      n="${item#item-}"
      if [ -n "${MOCK_FAIL_RELEASE:-}" ] && [ "$n" = "$MOCK_FAIL_RELEASE" ] && [ -z "$value" ]; then
        # Simulate the RELEASE mutation itself failing (value=="" is always a
        # release/clear, never a take/refresh/takeover/stamp write) — issue
        # #361 problem 3's untested branch: the claim stays held.
        echo "mock gh: injected failure on the release mutation for #$n" >&2
        exit 1
      fi
      log "$(jq -nc --arg project "$project" --arg item "$item" --arg field "$field" --arg value "$value" \
        '{op:"set-claim",project:$project,item:$item,field:$field,value:$value}')"
      printf '%s' "$value" > "$MOCK_FIXTURES/claim_$n"
      resp=$(jq -nc --arg id "$item" '{data:{updateProjectV2ItemFieldValue:{projectV2Item:{id:$id}}}}')
    elif printf '%s' "$query" | grep -q 'deleteProjectV2Item'; then
      n="${item#item-}"
      if [ -n "${MOCK_FAIL_DELETE_ITEM:-}" ] && [ "$n" = "$MOCK_FAIL_DELETE_ITEM" ]; then
        echo "mock gh: injected failure deleting the project item for #$n" >&2
        exit 1
      fi
      log "$(jq -nc --arg project "$project" --arg item "$item" '{op:"delete-item",project:$project,item:$item}')"
      # Board removal: the row is gone, so any later read in the SAME run
      # (an already-parked no-op check, or a second park record for the
      # same issue) sees it as off the board, same as a real delete.
      rm -f "$MOCK_FIXTURES/item_$n"
      resp=$(jq -nc --arg id "$item" '{data:{deleteProjectV2Item:{deletedItemId:$id}}}')
    else
      echo "mock gh: unrecognized mutation query" >&2; exit 1
    fi
  else
    n="$number"
    node=$(read_fixture "$MOCK_FIXTURES/node_$n" "node-$n")
    if [ -n "${MOCK_FAIL_CLAIM_READ:-}" ] && [ "$n" = "$MOCK_FAIL_CLAIM_READ" ] \
       && printf '%s' "$query" | grep -q 'name:"Claimed by"'; then
      echo "mock gh: injected GraphQL failure on the Claimed by read for #$n" >&2
      exit 1
    fi
    if printf '%s' "$query" | grep -q 'name:"Claimed by"'; then
      # Board membership is one fact: an issue with no item_N fixture is off
      # the board for THIS query exactly as it is for the Status query below.
      # A `Claimed by` value only exists on a row that exists.
      if [ -f "$MOCK_FIXTURES/item_$n" ]; then
        cur=$(read_fixture "$MOCK_FIXTURES/claim_$n" "")
        nodes=$(jq -nc --arg iid "item-$n" --arg pid "$MOCK_PROJECT_ID" --arg val "$cur" \
          '[{id:$iid, project:{id:$pid}, fieldValueByName:(if $val=="" then null else {text:$val} end)}]')
      else
        nodes='[]'
      fi
      resp=$(jq -nc --argjson nodes "$nodes" '{data:{repository:{issue:{projectItems:{nodes:$nodes}}}}}')
    elif printf '%s' "$query" | grep -q 'name:"Status"'; then
      if [ -f "$MOCK_FIXTURES/item_$n" ]; then
        st=$(cat "$MOCK_FIXTURES/item_$n")
        nodes=$(jq -nc --arg iid "item-$n" --arg pid "$MOCK_PROJECT_ID" --arg st "$st" \
          '[{id:$iid, project:{id:$pid}, fieldValueByName:(if $st=="" then null else {name:$st} end)}]')
      else
        nodes='[]'
      fi
      resp=$(jq -nc --arg id "$node" --argjson nodes "$nodes" '{data:{repository:{issue:{id:$id, projectItems:{nodes:$nodes}}}}}')
    elif printf '%s' "$query" | grep -q 'projectItems(first:10)'; then
      # apply_park's own item-lookup query (park mechanic 4): id + project.id
      # only, no fieldValueByName — the mock distinguishes it from the
      # Claimed-by/Status reads above (both first:20) by its first:10.
      if [ -f "$MOCK_FIXTURES/item_$n" ]; then
        nodes=$(jq -nc --arg iid "item-$n" --arg pid "$MOCK_PROJECT_ID" '[{id:$iid, project:{id:$pid}}]')
      else
        nodes='[]'
      fi
      resp=$(jq -nc --argjson nodes "$nodes" '{data:{repository:{issue:{projectItems:{nodes:$nodes}}}}}')
    else
      echo "mock gh: unrecognized read query" >&2; exit 1
    fi
  fi
  if [ -n "$jqexpr" ]; then jq -c -r "$jqexpr" <<<"$resp"; else printf '%s\n' "$resp"; fi
  exit 0
fi

if [ "${1:-}" = "api" ]; then
  shift
  method="GET"; endpoint=""; issue_id=""; issue_id_flag=""
  while [ $# -gt 0 ]; do
    case "$1" in
      -X|--method) method="$2"; shift 2 ;;
      --paginate) shift ;;
      --jq) jqexpr="${2:-}"; shift 2 ;;
      -f|-F) case "$2" in issue_id=*) issue_id="${2#issue_id=}"; issue_id_flag="$1" ;; esac; shift 2 ;;
      *) endpoint="$1"; shift ;;
    esac
  done
  case "$endpoint" in
    repos/*/issues/*/timeline\?per_page=100)
      printf '[]\n' | { [ -n "${jqexpr:-}" ] && jq -c -r "$jqexpr" || cat; }
      ;;
    repos/*/issues/*/dependencies/blocked_by)
      n=$(printf '%s' "$endpoint" | sed -E 's#repos/[^/]+/[^/]+/issues/([0-9]+)/.*#\1#')
      if [ "$method" = "POST" ]; then
        log "$(jq -nc --argjson n "$n" --arg id "$issue_id" --arg flag "$issue_id_flag" \
          '{op:"blocked-by-add",issue:$n,blocker_id:$id,issue_id_flag:$flag}')"
      else
        b=$(read_fixture "$MOCK_FIXTURES/blocked_$n.json" "[]")
        resp=$(jq -nc --argjson b "$b" '$b|map({number:.})')
        if [ -n "${jqexpr:-}" ]; then jq -c -r "$jqexpr" <<<"$resp"; else printf '%s\n' "$resp"; fi
      fi
      ;;
    repos/*/issues/*)
      n=$(printf '%s' "$endpoint" | sed -E 's#repos/[^/]+/[^/]+/issues/([0-9]+)$#\1#')
      node=$(read_fixture "$MOCK_FIXTURES/node_$n" "node-$n")
      resp=$(jq -nc --arg id "$node" '{id:$id}')
      if [ -n "${jqexpr:-}" ]; then jq -r "$jqexpr" <<<"$resp"; else printf '%s\n' "$resp"; fi
      ;;
    *)
      echo "mock gh: unknown endpoint: $endpoint (method=$method)" >&2; exit 1 ;;
  esac
  exit 0
fi

echo "mock gh: unsupported command: $*" >&2
exit 1
MOCKGH
chmod +x "$BIN/gh"

export MOCK_GH_CALL_LOG="$OUT/gh-calls.log"
: > "$MOCK_GH_CALL_LOG"

# ---------------------------------------------------------------------------
# Harness self-check (tests/README convention 4: assert against the mock
# directly rather than relying on the script under test to exercise it).
# Board membership is ONE fact: both read queries — `Claimed by` and
# `Status` — must agree for the same issue, because real GitHub returns one
# `projectItems` list for both. Round-1 review F2: a `Claimed by` branch
# that served an on-board node unconditionally modelled an issue as
# simultaneously on and off the board, and that fiction hid the fact that
# the script could not home an off-board issue at all. Pin it here, or the
# fidelity is only a convention a future edit can quietly drop.
# ---------------------------------------------------------------------------
mockgh(){
  MOCK_FIXTURES="$FIXTURES" MOCK_OUT="$OUT" MOCK_PROJECT_ID="$PROJECT_ID" \
    MOCK_OPT_NAMES="$OPT_NAMES" MOCK_FAIL_MILESTONE="" MOCK_FAIL_CLAIM_READ="" MOCK_FAIL_RELEASE="" \
    PATH="$BIN:$PATH" gh "$@"
}
mock_nodes(){ # mock_nodes <issue> <field-name>
  mockgh api graphql -f query="query(\$owner:String!,\$name:String!,\$number:Int!){ repository { issue { id projectItems { nodes { id project{id} fieldValueByName(name:\"$2\"){ text name } } } } } }" \
    -F owner=x -F name=y -F number="$1" --jq '.data.repository.issue.projectItems.nodes'
}
clear_fixtures 900
: > "$OUT/mutations.log"
off_claimed=$(mock_nodes 900 'Claimed by'); off_status=$(mock_nodes 900 'Status')
[ "$(jq 'length' <<<"$off_claimed")" = "0" ] \
  || report "mock fidelity: an issue with no item_900 fixture is OFF the board — the 'Claimed by' query must return zero projectItems, got: $off_claimed"
[ "$(jq 'length' <<<"$off_status")" = "0" ] \
  || report "mock fidelity: an issue with no item_900 fixture is OFF the board — the 'Status' query must return zero projectItems, got: $off_status"
[ "$(jq 'length' <<<"$off_claimed")" = "$(jq 'length' <<<"$off_status")" ] \
  || report "mock fidelity: the two read queries disagree about whether #900 is on the board (Claimed by: $off_claimed, Status: $off_status) — real GitHub returns one projectItems list for both"
set_item 900 ""
on_claimed=$(mock_nodes 900 'Claimed by'); on_status=$(mock_nodes 900 'Status')
[ "$(jq 'length' <<<"$on_claimed")" = "1" ] \
  || report "mock fidelity: with an item_900 fixture the 'Claimed by' query must return the row, got: $on_claimed"
[ "$(jq 'length' <<<"$on_status")" = "1" ] \
  || report "mock fidelity: with an item_900 fixture the 'Status' query must return the row, got: $on_status"
clear_fixtures 900

run(){ # run <stdin-file> <args...>
  local stdin_file="$1"; shift
  : > "$OUT/mutations.log"
  local rc=0
  set +e
  MOCK_FIXTURES="$FIXTURES" MOCK_OUT="$OUT" MOCK_PROJECT_ID="$PROJECT_ID" \
    MOCK_OPT_NAMES="$OPT_NAMES" \
    MOCK_FAIL_MILESTONE="${MOCK_FAIL_MILESTONE:-}" MOCK_FAIL_CLAIM_READ="${MOCK_FAIL_CLAIM_READ:-}" \
    MOCK_FAIL_RELEASE="${MOCK_FAIL_RELEASE:-}" MOCK_FAIL_CLOSE="${MOCK_FAIL_CLOSE:-}" \
    MOCK_FAIL_COMMENT="${MOCK_FAIL_COMMENT:-}" MOCK_FAIL_DELETE_ITEM="${MOCK_FAIL_DELETE_ITEM:-}" \
    PATH="$BIN:$PATH" \
    "$HOME_DEFERRED_SH" --repo "$REPO" --work-tracking "$WT" --claim "$ME" "$@" \
    < "$stdin_file" > "$OUT/run.stdout.log" 2> "$OUT/run.stderr.log"
  rc=$?
  set -e
  return $rc
}
n_mut(){ wc -l < "$OUT/mutations.log" | tr -d ' '; }
mut_ops(){ jq -r .op "$OUT/mutations.log" 2>/dev/null | sort | tr '\n' ',' ; }

FRESH_TS(){ date -u -d '1 hour ago' +%Y-%m-%dT%H:%MZ; }

# ---------------------------------------------------------------------------
# Valid record, empty claim, not yet on the board: every mutation kind
# fires exactly once, with the expected values.
# ---------------------------------------------------------------------------
clear_fixtures 100
set_blocked 100 '[]'
IN="$WORK/in_valid.jsonl"
printf '%s\n' '{"issue":100,"milestone":"GitHub workflow skill overhaul 2","status":"Ready","priority":"medium","blocked_by":[261],"labels":["deferred"]}' > "$IN"
clear_fixtures 261
set_item 261 "" # #261 is on the board already so no extra add-item mutation for it (it is only a blocker lookup, not the record's own issue)

RC=0; run "$IN" || RC=$?
if [ "$RC" -ne 0 ]; then
  report "valid record: expected exit 0, got $RC — stderr: $(cat "$OUT/run.stderr.log")"
fi
[ "$(n_mut)" = "6" ] || report "valid record: expected exactly 6 mutations (claim + 5 own), got $(n_mut): $(mut_ops)"
grep -q '"op":"set-claim"' "$OUT/mutations.log" || report "valid record: expected a set-claim mutation (empty field, first take)"
grep -q '"op":"milestone".*"issue":100' "$OUT/mutations.log" || report "valid record: expected a milestone mutation for #100"
grep -q '"op":"add-label"' "$OUT/mutations.log" || report "valid record: expected an add-label mutation"
grep -q '"op":"blocked-by-add".*"issue":100' "$OUT/mutations.log" || report "valid record: expected a blocked-by-add mutation for #100"
grep -q '"op":"add-item"' "$OUT/mutations.log" || report "valid record: expected an add-item mutation (not yet on board)"
grep -q '"op":"set-status".*"option":"'"$READY_OPT"'"' "$OUT/mutations.log" || report "valid record: expected a set-status mutation with the Ready option id"
addlabel_val=$(jq -r 'select(.op=="add-label")|.value' "$OUT/mutations.log")
[[ "$addlabel_val" == *"priority:medium"* ]] || report "valid record: expected the added labels to include priority:medium, got: $addlabel_val"
[[ "$addlabel_val" == *"deferred"* ]] || report "valid record: expected the added labels to include deferred, got: $addlabel_val"
# Ordering (round-1 F1): the board row must be created BEFORE the claim is
# taken — the claim is a field on that row, so a claim-first order cannot
# home an off-board issue at all. Assert the recorded order, not just the
# set of mutations.
# `|| true` (#517): a zero-match `grep -n` here exits 1, and under
# `set -euo pipefail` that would abort the script before the "expected both
# an add-item and a set-claim mutation to order" guard below ever runs —
# fall through to that guard on a zero-match instead.
add_item_line=$(grep -n '"op":"add-item"' "$OUT/mutations.log" | head -1 | cut -d: -f1 || true)
set_claim_line=$(grep -n '"op":"set-claim"' "$OUT/mutations.log" | head -1 | cut -d: -f1 || true)
if [ -n "$add_item_line" ] && [ -n "$set_claim_line" ]; then
  [ "$add_item_line" -lt "$set_claim_line" ] \
    || report "valid record: expected the add-item mutation BEFORE the set-claim mutation (a claim lives on the board row), got add-item at line $add_item_line, set-claim at line $set_claim_line"
else
  report "valid record: expected both an add-item and a set-claim mutation to order"
fi
# The dependencies POST must send issue_id with -F (typed integer), per
# github-tools.md's canonical row: -f would send a JSON string and 422 live.
dep_flag=$(jq -r 'select(.op=="blocked-by-add")|.issue_id_flag' "$OUT/mutations.log")
[ "$dep_flag" = "-F" ] || report "valid record: expected the blocked_by POST to send issue_id with -F (typed integer), got: '$dep_flag'"
jq -e . "$OUT/run.stdout.log" >/dev/null 2>&1 || report "valid record: stdout is not valid JSON: $(cat "$OUT/run.stdout.log")"
[ "$(jq -r .issue "$OUT/run.stdout.log")" = "100" ] || report "valid record: expected stdout .issue=100"

# ---------------------------------------------------------------------------
# Missing priority: refused before any call — zero mutations, non-zero exit.
# ---------------------------------------------------------------------------
IN2="$WORK/in_nopriority.jsonl"
printf '%s\n' '{"issue":101,"milestone":"m","status":"Ready","labels":["deferred"]}' > "$IN2"
if run "$IN2"; then
  report "missing priority: expected non-zero exit, got 0"
fi
[ "$(n_mut)" = "0" ] || report "missing priority: expected zero mutations, got $(n_mut): $(mut_ops)"
grep -qi 'REJECTED' "$OUT/run.stderr.log" || report "missing priority: expected a REJECTED message on stderr"
grep -qi 'priority' "$OUT/run.stderr.log" || report "missing priority: expected the rejection to name priority"

# ---------------------------------------------------------------------------
# Bug record without severity: refused, zero mutations.
# ---------------------------------------------------------------------------
IN3="$WORK/in_nobugseverity.jsonl"
printf '%s\n' '{"issue":102,"milestone":"m","status":"Ready","priority":"high","labels":["bug"]}' > "$IN3"
if run "$IN3"; then
  report "bug without severity: expected non-zero exit, got 0"
fi
[ "$(n_mut)" = "0" ] || report "bug without severity: expected zero mutations, got $(n_mut): $(mut_ops)"
grep -qi 'severity' "$OUT/run.stderr.log" || report "bug without severity: expected the rejection to name severity"

# A bug record WITH severity passes the gate (mixed with the priority-only
# record above in one stdin to also prove the run continues past a
# rejection and still applies the next valid record).
clear_fixtures 103
set_blocked 103 '[]'
IN3b="$WORK/in_bugok.jsonl"
{
  printf '%s\n' '{"issue":102,"milestone":"m","status":"Ready","priority":"high","labels":["bug"]}'
  printf '%s\n' '{"issue":103,"milestone":"m","status":"Ready","priority":"high","severity":"critical","labels":["bug"]}'
} > "$IN3b"
if run "$IN3b"; then
  report "mixed batch: expected non-zero exit (one record rejected), got 0"
fi
grep -q '"op":"milestone".*"issue":103' "$OUT/mutations.log" || report "mixed batch: expected #103 (valid bug+severity) to still be applied despite #102's rejection"
n103=$(jq -r 'select(.issue==103)|.op' "$OUT/mutations.log" | wc -l | tr -d ' ')
[ "$n103" -gt 0 ] || report "mixed batch: expected at least one mutation for #103"
n102=$(grep -c '"issue":102' "$OUT/mutations.log" || true)
[ "$n102" = "0" ] || report "mixed batch: expected zero mutations for rejected #102, got $n102"

# ---------------------------------------------------------------------------
# A record carrying `parent` is refused outright — zero mutations.
# ---------------------------------------------------------------------------
IN4="$WORK/in_parent.jsonl"
printf '%s\n' '{"issue":104,"parent":254,"milestone":"m","status":"Ready","priority":"low"}' > "$IN4"
if run "$IN4"; then
  report "parent field: expected non-zero exit, got 0"
fi
[ "$(n_mut)" = "0" ] || report "parent field: expected zero mutations, got $(n_mut): $(mut_ops)"
grep -qi 'parent' "$OUT/run.stderr.log" || report "parent field: expected the rejection to name 'parent'"

# ---------------------------------------------------------------------------
# Second run of the same (now-applied) record is a no-op: update the
# fixtures to reflect what run 1 actually produced, and make the claim
# LIVE and already ours (a resumed session re-triaging the same item
# within the claim's 24h window) — `stamp-claim.sh take` then refuses
# ("live claim held by 'test-01'"), which claim_ok() recognizes as
# already-mine and treats as a no-op rather than a skip, so the run
# proceeds to the (now all no-op) mutation checks below with zero calls.
# ---------------------------------------------------------------------------
set_milestone 100 "GitHub workflow skill overhaul 2"
set_labels 100 '["deferred","priority:medium"]'
set_blocked 100 '[261]'
set_item 100 "Ready"
set_claim 100 "$ME @ $(FRESH_TS)"
RC=0; run "$IN" || RC=$?
if [ "$RC" -ne 0 ]; then
  report "second run (idempotent): expected exit 0, got $RC — stderr: $(cat "$OUT/run.stderr.log")"
fi
[ "$(n_mut)" = "0" ] || report "second run (idempotent): expected zero mutations, got $(n_mut): $(mut_ops)"
grep -qi 'no-op' "$OUT/run.stderr.log" || report "second run (idempotent): expected no-op notes on stderr"
applied2=$(jq -r '.applied|length' "$OUT/run.stdout.log")
[ "$applied2" = "0" ] || report "second run (idempotent): expected an empty applied[] on stdout, got: $(cat "$OUT/run.stdout.log")"

# ---------------------------------------------------------------------------
# A live foreign claim on the item skips the record: zero mutations, run
# still exits 0 (a claim collision is not a gate rejection).
# ---------------------------------------------------------------------------
set_claim 100 "other-09 @ $(FRESH_TS)"
RC=0; run "$IN" || RC=$?
if [ "$RC" -ne 0 ]; then
  report "live foreign claim: expected exit 0 (a skip, not a rejection), got $RC — stderr: $(cat "$OUT/run.stderr.log")"
fi
[ "$(n_mut)" = "0" ] || report "live foreign claim: expected zero mutations, got $(n_mut): $(mut_ops)"
grep -qi 'SKIPPED' "$OUT/run.stderr.log" || report "live foreign claim: expected a SKIPPED message on stderr"
set_claim 100 "" # release the fixture claim for later assertions

# ---------------------------------------------------------------------------
# A STALE foreign claim is taken over — and the supersede reminder reaches
# stderr. claims.md requires an event comment on the epic naming the
# superseded claim; stamp-claim.sh deliberately delegates that announcement
# to its caller, so home-deferred.sh must surface it rather than swallow it
# with the rest of stamp-claim's stderr (round-1 F4).
# ---------------------------------------------------------------------------
STALE_TS(){ date -u -d '3 days ago' +%Y-%m-%dT%H:%MZ; }
clear_fixtures 400
set_blocked 400 '[]'
set_item 400 ""
set_claim 400 "other-77 @ $(STALE_TS)"
IN_STALE="$WORK/in_stale.jsonl"
printf '%s\n' '{"issue":400,"milestone":"m","status":"Ready","priority":"low","labels":[]}' > "$IN_STALE"
RC=0; run "$IN_STALE" || RC=$?
if [ "$RC" -ne 0 ]; then
  report "stale foreign claim: expected exit 0 (takeover succeeds), got $RC — stderr: $(cat "$OUT/run.stderr.log")"
fi
grep -q '"op":"set-claim"' "$OUT/mutations.log" || report "stale foreign claim: expected the take to write the claim (stale claims are takeable)"
grep -q '"op":"milestone".*"issue":400' "$OUT/mutations.log" || report "stale foreign claim: expected the record to be applied after the takeover"
grep -qi 'SUPERSEDED' "$OUT/run.stderr.log" || report "stale foreign claim: expected a SUPERSEDED announcement on stderr, got: $(cat "$OUT/run.stderr.log")"
grep -q 'other-77' "$OUT/run.stderr.log" || report "stale foreign claim: expected the superseded claim id on stderr"
grep -qi 'event comment on the epic' "$OUT/run.stderr.log" || report "stale foreign claim: expected claims.md's epic-comment reminder to reach stderr, not be swallowed"

# ---------------------------------------------------------------------------
# A HARD stamp-claim failure is not a refusal (round-1 F3). The GraphQL read
# behind `stamp-claim.sh take` fails; the record must be REJECTED with the
# error and the run's exit code must flip — the distinction is stamp-claim's
# exit code (1 = hard failure, 3 = refusal), never its prose.
# ---------------------------------------------------------------------------
clear_fixtures 500
set_blocked 500 '[]'
set_item 500 ""
IN_HARD="$WORK/in_hardfail.jsonl"
printf '%s\n' '{"issue":500,"milestone":"m","status":"Ready","priority":"low","labels":[]}' > "$IN_HARD"
if MOCK_FAIL_CLAIM_READ=500 run "$IN_HARD"; then
  report "hard claim failure: expected a non-zero exit (an infrastructure failure must not report success), got 0 — stderr: $(cat "$OUT/run.stderr.log")"
fi
[ "$(n_mut)" = "0" ] || report "hard claim failure: expected zero mutations, got $(n_mut): $(mut_ops)"
grep -q 'REJECTED #500' "$OUT/run.stderr.log" || report "hard claim failure: expected the record to be REJECTED, not SKIPPED, got: $(cat "$OUT/run.stderr.log")"
grep -qi 'not a claim refusal' "$OUT/run.stderr.log" || report "hard claim failure: expected the message to distinguish the hard failure from a refusal"
if grep -q 'SKIPPED #500' "$OUT/run.stderr.log"; then
  report "hard claim failure: a hard failure must not be reported as a claim skip"
fi

# ---------------------------------------------------------------------------
# A `gh` failure mid-batch fails ONLY that record (issue #350): the failing
# record's claim is released so the item is not stranded, the next record on
# stdin still applies, and the run exits non-zero.
# ---------------------------------------------------------------------------
clear_fixtures 301; set_blocked 301 '[]'
clear_fixtures 302; set_blocked 302 '[]'
IN_BATCH="$WORK/in_batch.jsonl"
{
  printf '%s\n' '{"issue":301,"milestone":"m","status":"Ready","priority":"low","labels":[]}'
  printf '%s\n' '{"issue":302,"milestone":"m","status":"Ready","priority":"low","labels":[]}'
} > "$IN_BATCH"
if MOCK_FAIL_MILESTONE=301 run "$IN_BATCH"; then
  report "mid-batch gh failure: expected a non-zero exit, got 0 — stderr: $(cat "$OUT/run.stderr.log")"
fi
grep -q 'FAILED #301' "$OUT/run.stderr.log" || report "mid-batch gh failure: expected #301 to be reported as FAILED, got: $(cat "$OUT/run.stderr.log")"
grep -q '"op":"milestone".*"issue":302' "$OUT/mutations.log" \
  || report "mid-batch gh failure: expected #302 to still be applied after #301 failed — the batch must not abort: $(mut_ops)"
grep -q '"op":"set-status"' "$OUT/mutations.log" || report "mid-batch gh failure: expected #302 to reach its Status mutation"
released=$(jq -r 'select(.op=="set-claim" and .item=="item-301")|.value' "$OUT/mutations.log" | tail -1)
[ -z "$released" ] || report "mid-batch gh failure: expected #301's claim to be RELEASED (empty Claimed by) after the failure, last set-claim value was: '$released'"
grep -qi 'claim released' "$OUT/run.stderr.log" || report "mid-batch gh failure: expected a claim-release note on stderr for #301"
n_claim_301=$(jq -r 'select(.op=="set-claim" and .item=="item-301")|.value' "$OUT/mutations.log" | wc -l | tr -d ' ')
[ "$n_claim_301" = "2" ] || report "mid-batch gh failure: expected #301 to take then release its claim (2 set-claim mutations), got $n_claim_301"

# ---------------------------------------------------------------------------
# A `gh` failure mid-batch WHOSE OWN release attempt then ALSO fails (issue
# #361 problem 3 — the one remaining path in the #350 work that can leave an
# item claimed, previously untested): #401's milestone mutation fails
# (mid-apply), release_claim then tries to hand the claim back, and that
# release mutation is injected to fail too. The record must still be
# reported FAILED (from the true, original cause — the milestone failure,
# not misattributed to the release), the run's exit code must still flip,
# the item must be named as STILL HELD, and the next record on stdin (#402)
# must still apply — a release failure isolates no worse than any other
# per-record failure.
# ---------------------------------------------------------------------------
clear_fixtures 401; set_blocked 401 '[]'
clear_fixtures 402; set_blocked 402 '[]'
IN_RELFAIL="$WORK/in_relfail.jsonl"
{
  printf '%s\n' '{"issue":401,"milestone":"m","status":"Ready","priority":"low","labels":[]}'
  printf '%s\n' '{"issue":402,"milestone":"m","status":"Ready","priority":"low","labels":[]}'
} > "$IN_RELFAIL"
if MOCK_FAIL_MILESTONE=401 MOCK_FAIL_RELEASE=401 run "$IN_RELFAIL"; then
  report "release-failure branch: expected a non-zero exit, got 0 — stderr: $(cat "$OUT/run.stderr.log")"
fi
grep -q 'FAILED #401' "$OUT/run.stderr.log" \
  || report "release-failure branch: expected #401 to be reported FAILED (the true cause is the milestone failure, not the release), got: $(cat "$OUT/run.stderr.log")"
grep -q 'setting milestone failed' "$OUT/run.stderr.log" \
  || report "release-failure branch: expected the milestone failure itself to still be named, got: $(cat "$OUT/run.stderr.log")"
grep -q 'could NOT be released' "$OUT/run.stderr.log" \
  || report "release-failure branch: expected a 'could NOT be released' note for #401, got: $(cat "$OUT/run.stderr.log")"
grep -qi 'stays held until it goes stale' "$OUT/run.stderr.log" \
  || report "release-failure branch: expected #401 to be named as STILL HELD, got: $(cat "$OUT/run.stderr.log")"
held_401=$(cat "$FIXTURES/claim_401" 2>/dev/null || true)
[ -n "$held_401" ] || report "release-failure branch: expected #401's claim to remain WRITTEN on the board (the release failed) — fixture claim_401 is empty"
grep -q '"op":"milestone".*"issue":402' "$OUT/mutations.log" \
  || report "release-failure branch: expected #402 to still be applied after #401's failed release — the batch must not abort: $(mut_ops)"
grep -q '"op":"set-status".*"item":"item-402"' "$OUT/mutations.log" \
  || report "release-failure branch: expected #402 to reach its Status mutation"
grep -q '1 record(s) failed mid-apply' "$OUT/run.stderr.log" \
  || report "release-failure branch: expected finish() to count exactly 1 FAILED record, got: $(cat "$OUT/run.stderr.log")"

# ---------------------------------------------------------------------------
# An UNWRITABLE --log path must not strand claims (issue #262 round 2, F1;
# issue #350 AC2). stamp-claim.sh writes the board BEFORE it appends its
# session-log line, so a take can fail with our claim already written. This
# script must therefore treat every non-3 take failure as "the board may
# have been written": read `Claimed by` back and release it when it holds
# our own id. Two valid records, --log into a chmod 500 directory:
#  - each record is REJECTED naming the LOG as the cause, not "failed hard";
#  - each claim that was written is RELEASED (last set-claim value is "");
#  - the batch runs to the end of stdin (record 2 is processed, not aborted);
#  - and a re-run without --log applies both records in full, proving
#    nothing was left held or half-done.
# ---------------------------------------------------------------------------
clear_fixtures 601; set_blocked 601 '[]'
clear_fixtures 602; set_blocked 602 '[]'
IN_LOGFAIL="$WORK/in_logfail.jsonl"
{
  printf '%s\n' '{"issue":601,"milestone":"m","status":"Ready","priority":"low","labels":[]}'
  printf '%s\n' '{"issue":602,"milestone":"m","status":"Ready","priority":"low","labels":[]}'
} > "$IN_LOGFAIL"
NOWRITE_DIR="$WORK/nowrite"
mkdir -p "$NOWRITE_DIR"
chmod 500 "$NOWRITE_DIR"
RC=0; run "$IN_LOGFAIL" --log "$NOWRITE_DIR/session.jsonl" || RC=$?
[ "$RC" -ne 0 ] || report "unwritable --log: expected a non-zero exit (the audit trail failed), got 0 — stderr: $(cat "$OUT/run.stderr.log")"
for n in 601 602; do
  grep -q "REJECTED #$n" "$OUT/run.stderr.log" \
    || report "unwritable --log: expected #$n to be REJECTED, got: $(cat "$OUT/run.stderr.log")"
  # The true cause, not a misattribution to the claim subsystem.
  grep -q "REJECTED #$n — stamp-claim take WROTE the claim but could not write its session-log line" "$OUT/run.stderr.log" \
    || report "unwritable --log: #$n's rejection must name the session-log write as the cause, not the claim subsystem: $(cat "$OUT/run.stderr.log")"
  # The claim was written by the take, so it must be handed back.
  n_claim=$(jq -r --arg it "item-$n" 'select(.op=="set-claim" and .item==$it)|.value' "$OUT/mutations.log" | wc -l | tr -d ' ')
  [ "$n_claim" = "2" ] || report "unwritable --log: expected #$n to take then RELEASE its claim (2 set-claim mutations), got $n_claim: $(mut_ops)"
  last_claim=$(jq -r --arg it "item-$n" 'select(.op=="set-claim" and .item==$it)|.value' "$OUT/mutations.log" | tail -1)
  [ -z "$last_claim" ] || report "unwritable --log: expected #$n's claim to end EMPTY (released), last set-claim value was: '$last_claim'"
  [ -z "$(cat "$FIXTURES/claim_$n" 2>/dev/null)" ] || report "unwritable --log: #$n is still held on the board after the run: $(cat "$FIXTURES/claim_$n")"
done
if grep -q 'failed hard' "$OUT/run.stderr.log"; then
  report "unwritable --log: a local filesystem failure must not be reported as a hard claim-subsystem failure: $(cat "$OUT/run.stderr.log")"
fi
grep -q '2 record(s) rejected' "$OUT/run.stderr.log" \
  || report "unwritable --log: the summary must count both records under the same category it printed per record (REJECTED), got: $(cat "$OUT/run.stderr.log")"
if grep -q 'failed mid-apply' "$OUT/run.stderr.log"; then
  report "unwritable --log: the summary must not point at FAILED lines that were never printed (issue #361, problem 2): $(cat "$OUT/run.stderr.log")"
fi
# No triage mutation was applied for either record (both stopped at the gate).
[ "$(grep -c '"op":"milestone"' "$OUT/mutations.log" || true)" = "0" ] \
  || report "unwritable --log: no record should have reached its milestone mutation: $(mut_ops)"
chmod 700 "$NOWRITE_DIR"

# Re-run the same two records with a WRITABLE log: both apply in full — the
# releases above left the board in a state the next run can complete, and no
# record was lost to the failed round.
LOG_OK="$WORK/session_after_logfail.jsonl"
RC=0; run "$IN_LOGFAIL" --log "$LOG_OK" || RC=$?
[ "$RC" -eq 0 ] || report "after unwritable --log: the re-run must apply both records cleanly, got exit $RC — stderr: $(cat "$OUT/run.stderr.log")"
for n in 601 602; do
  grep -q "\"op\":\"milestone\".*\"issue\":$n" "$OUT/mutations.log" \
    || report "after unwritable --log: expected #$n to be applied on the re-run: $(mut_ops)"
  grep -q "\"issue\":$n" "$LOG_OK" || report "after unwritable --log: expected a triage log line for #$n: $(cat "$LOG_OK" 2>/dev/null)"
done

# ---------------------------------------------------------------------------
# --readd: bare issue numbers, project item + Status only.
# ---------------------------------------------------------------------------
clear_fixtures 200
IN5="$WORK/in_readd.txt"
printf '200\n' > "$IN5"
LOG_READD="$WORK/session_readd.jsonl"
RC=0; run "$IN5" --readd --status Backlog --log "$LOG_READD" || RC=$?
if [ "$RC" -ne 0 ]; then
  report "--readd: expected exit 0, got $RC — stderr: $(cat "$OUT/run.stderr.log")"
fi
[ "$(n_mut)" = "3" ] || report "--readd: expected exactly 3 mutations (claim + add-item + set-status), got $(n_mut): $(mut_ops)"
grep -q '"op":"add-item"' "$OUT/mutations.log" || report "--readd: expected an add-item mutation"
grep -q '"op":"set-status".*"option":"'"$BACKLOG_OPT"'"' "$OUT/mutations.log" || report "--readd: expected a set-status mutation with the Backlog option id"

# -----------------------------------------------------------------------
# Issue #743/#754: pin the emitted ts (this call site: the --readd loop's
# own LOG_LINE, home-deferred.sh's L578 NOW_TS() call) to
# formats/session-log.md's exact second-precision form
# (YYYY-MM-DDTHH:MM:SSZ) — a presence check alone (`jq -e .ts`) also passed
# under the pre-fix minute-precision NOW_TS(), so it cannot tell buggy from
# fixed. The gate this depends on is emit_log's write of LOG_LINE inside
# the readd loop's `[ "$(jq 'length' <<<"$APPLIED_JSON")" -gt 0 ]` branch —
# reached here because --status Backlog applies a real set-status mutation,
# so APPLIED_JSON is non-empty and the branch executes.
# -----------------------------------------------------------------------
[ -s "$LOG_READD" ] || report "--readd --log: expected a non-empty log file"
readd_logline=$(grep '"event":"triage"' "$LOG_READD" | tail -1 || true)
[ -n "$readd_logline" ] || report "--readd --log: expected a triage event line, log contents: $(cat "$LOG_READD" 2>/dev/null)"
if [ -n "$readd_logline" ]; then
  readd_ts="$(jq -r .ts <<<"$readd_logline")"
  [[ "$readd_ts" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] \
    || report "--readd --log: ts '$readd_ts' is not exactly YYYY-MM-DDTHH:MM:SSZ (session-log.md, issue #743/#754)"
fi

# --readd without --status is an argument error (exit 2), zero mutations.
if run "$IN5" --readd; then
  report "--readd without --status: expected non-zero exit, got 0"
fi
[ "$(n_mut)" = "0" ] || report "--readd without --status: expected zero mutations, got $(n_mut)"

# ---------------------------------------------------------------------------
# --log: one `triage` line per applied record, shape
# jq -e '.event=="triage" and .claim and .ts'.
# ---------------------------------------------------------------------------
clear_fixtures 105
set_blocked 105 '[]'
IN6="$WORK/in_log.jsonl"
printf '%s\n' '{"issue":105,"milestone":"m","status":"Ready","priority":"low","labels":[]}' > "$IN6"
LOG_FILE="$WORK/session.jsonl"
RC=0; run "$IN6" --log "$LOG_FILE" || RC=$?
if [ "$RC" -ne 0 ]; then
  report "--log: expected exit 0, got $RC — stderr: $(cat "$OUT/run.stderr.log")"
fi
[ -s "$LOG_FILE" ] || report "--log: expected a non-empty log file"
# `|| true` (#517): a zero-match `grep` here exits 1, and under
# `set -euo pipefail` that would abort the script before the
# "expected a triage event line" guard two lines below ever runs.
logline=$(grep '"event":"triage"' "$LOG_FILE" | tail -1 || true)
[ -n "$logline" ] || report "--log: expected a triage event line, log contents: $(cat "$LOG_FILE" 2>/dev/null)"
if [ -n "$logline" ]; then
  jq -e '.event=="triage" and .claim and .ts' <<<"$logline" >/dev/null 2>&1 \
    || report "--log: line rejected by 'jq -e .event==\"triage\" and .claim and .ts': $logline"
  [ "$(jq -r .issue <<<"$logline")" = "105" ] || report "--log: expected issue=105, got: $logline"
  [ -n "$(jq -r '.decision // empty' <<<"$logline")" ] || report "--log: expected a non-empty decision, got: $logline"
  [ "$(jq -r .milestone <<<"$logline")" = "m" ] || report "--log: expected the record's own fields (milestone) folded in, got: $logline"
  jq -e '.applied|length > 0' <<<"$logline" >/dev/null 2>&1 || report "--log: expected a non-empty applied[], got: $logline"

  # -----------------------------------------------------------------------
  # Issue #743/#754: pin the emitted ts (this call site: the main triage
  # loop's LOG_LINE, home-deferred.sh's L677 NOW_TS() call) to
  # formats/session-log.md's exact second-precision form
  # (YYYY-MM-DDTHH:MM:SSZ). The gate this depends on is the same emit_log
  # write, reached here because IN6's record applies a real milestone
  # mutation, so APPLIED_JSON is non-empty and the LOG_LINE branch executes.
  # -----------------------------------------------------------------------
  log_ts="$(jq -r .ts <<<"$logline")"
  [[ "$log_ts" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] \
    || report "--log: ts '$log_ts' is not exactly YYYY-MM-DDTHH:MM:SSZ (session-log.md, issue #743/#754)"
fi

# A rejected record writes no --log line at all.
LOG_FILE2="$WORK/session2.jsonl"
IN7="$WORK/in_rejected_log.jsonl"
printf '%s\n' '{"issue":106,"milestone":"m","status":"Ready","labels":[]}' > "$IN7"
run "$IN7" --log "$LOG_FILE2" || true
if [ -f "$LOG_FILE2" ] && grep -q '"issue":106' "$LOG_FILE2"; then
  report "--log (rejected record): expected no triage line for a rejected record"
fi

# ---------------------------------------------------------------------------
# Park path (epic #798/#799, issue #801): "status":"park" is a keyword, a
# separate shape and a separate apply — never a board Status option name.
# ---------------------------------------------------------------------------
PARK_UNIT_VAL="a/b/c.sh"
PARK_WAKE_VAL="second sighting | unit batch | milestone review"
PARK_COMMENT_VAL=$(printf 'Unit: %s\nWake: %s' "$PARK_UNIT_VAL" "$PARK_WAKE_VAL")
# The body as GitHub actually STORES it, written out as a literal rather
# than built from the script's own generator (round-1 finding 3): a fixture
# derived from the same `printf` the script uses cannot tell a byte-exact
# no-op check from a normalised one, which is exactly the bug #856 reports.
# Every one of the 20 hand-parked issues in this repo carries a park-comment
# body ending in exactly one trailing newline; this literal reproduces that
# form, and NOTHING here may be re-derived from $PARK_UNIT_VAL or
# $PARK_WAKE_VAL.
PARK_COMMENT_STORED='Unit: a/b/c.sh
Wake: second sighting | unit batch | milestone review
'
# Guard the guard: the stored form must genuinely DIFFER from the built one,
# or this fixture has silently gone vacuous again.
[ "$PARK_COMMENT_STORED" != "$PARK_COMMENT_VAL" ] \
  || report "park fixture: PARK_COMMENT_STORED is byte-identical to the script-built body — the idempotence fixture is vacuous"
[ "${PARK_COMMENT_STORED%$'\n'}" = "$PARK_COMMENT_VAL" ] \
  || report "park fixture: PARK_COMMENT_STORED must equal the built body plus exactly one trailing newline, got: $(printf '%s' "$PARK_COMMENT_STORED" | od -c | tail -3)"

# Happy path: milestone omitted (already homed — optional for park), unit +
# priority given. All four mechanics fire exactly once, in the fixed order
# labels -> comment -> close -> project-item delete; no project-item CREATE
# and no claim mutation at all (park never claims).
clear_fixtures 700
set_labels 700 '["deferred"]'
set_item 700 ""
IN_PARK="$WORK/in_park.jsonl"
printf '%s\n' '{"issue":700,"status":"park","unit":"'"$PARK_UNIT_VAL"'","priority":"low","labels":["deferred"]}' > "$IN_PARK"
RC=0; run "$IN_PARK" || RC=$?
if [ "$RC" -ne 0 ]; then
  report "park happy path: expected exit 0, got $RC — stderr: $(cat "$OUT/run.stderr.log")"
fi
[ "$(n_mut)" = "4" ] || report "park happy path: expected exactly 4 mutations (label, comment, close, delete-item), got $(n_mut): $(mut_ops)"
add_label_val=$(jq -r 'select(.op=="add-label")|.value' "$OUT/mutations.log")
[[ "$add_label_val" == *"parked"* ]] || report "park happy path: expected 'parked' among the added labels, got: $add_label_val"
[[ "$add_label_val" == *"priority:low"* ]] || report "park happy path: expected 'priority:low' among the added labels, got: $add_label_val"
comment_val=$(jq -r 'select(.op=="comment")|.value' "$OUT/mutations.log")
[ "$comment_val" = "$PARK_COMMENT_VAL" ] || report "park happy path: expected the comment body to be exactly the Unit:/Wake: two-liner, got: $comment_val"
close_val=$(jq -r 'select(.op=="close")|.value' "$OUT/mutations.log")
[ "$close_val" = "not planned" ] || report "park happy path: expected close reason 'not planned', got: $close_val"
grep -q '"op":"delete-item"' "$OUT/mutations.log" || report "park happy path: expected the project item to be deleted"
if grep -q '"op":"set-claim"' "$OUT/mutations.log"; then
  report "park happy path: expected NO claim mutation — park never claims"
fi
if grep -q '"op":"add-item"' "$OUT/mutations.log"; then
  report "park happy path: expected NO project-item creation — park never creates a board row"
fi
# Ordering: labels -> comment -> close -> delete-item, in that fixed order.
lbl_line=$(grep -n '"op":"add-label"' "$OUT/mutations.log" | head -1 | cut -d: -f1 || true)
cmt_line=$(grep -n '"op":"comment"' "$OUT/mutations.log" | head -1 | cut -d: -f1 || true)
cls_line=$(grep -n '"op":"close"' "$OUT/mutations.log" | head -1 | cut -d: -f1 || true)
del_line=$(grep -n '"op":"delete-item"' "$OUT/mutations.log" | head -1 | cut -d: -f1 || true)
if [ -n "$lbl_line" ] && [ -n "$cmt_line" ] && [ -n "$cls_line" ] && [ -n "$del_line" ]; then
  [ "$lbl_line" -lt "$cmt_line" ] || report "park happy path: expected labels BEFORE the comment, got label at $lbl_line, comment at $cmt_line"
  [ "$cmt_line" -lt "$cls_line" ] || report "park happy path: expected the comment BEFORE the close, got comment at $cmt_line, close at $cls_line"
  [ "$cls_line" -lt "$del_line" ] || report "park happy path: expected the close BEFORE the project-item delete, got close at $cls_line, delete at $del_line"
else
  report "park happy path: expected all four mutations (label, comment, close, delete-item) to order: $(mut_ops)"
fi
jq -e . "$OUT/run.stdout.log" >/dev/null 2>&1 || report "park happy path: stdout is not valid JSON: $(cat "$OUT/run.stdout.log")"
[ "$(jq -r .issue "$OUT/run.stdout.log")" = "700" ] || report "park happy path: expected stdout .issue=700"

# --log: a park record writes one triage event with decision "parked".
clear_fixtures 703
set_labels 703 '["deferred"]'
set_item 703 ""
IN_PARK_LOG="$WORK/in_park_log.jsonl"
printf '%s\n' '{"issue":703,"status":"park","unit":"x/y","priority":"medium","labels":["deferred"]}' > "$IN_PARK_LOG"
LOG_PARK="$WORK/session_park.jsonl"
RC=0; run "$IN_PARK_LOG" --log "$LOG_PARK" || RC=$?
[ "$RC" -eq 0 ] || report "park --log: expected exit 0, got $RC — stderr: $(cat "$OUT/run.stderr.log")"
park_logline=$(grep '"event":"triage"' "$LOG_PARK" | tail -1 || true)
[ -n "$park_logline" ] || report "park --log: expected a triage event line, log contents: $(cat "$LOG_PARK" 2>/dev/null)"
if [ -n "$park_logline" ]; then
  [ "$(jq -r .decision <<<"$park_logline")" = "parked" ] || report "park --log: expected decision=parked, got: $park_logline"
  [ "$(jq -r .issue <<<"$park_logline")" = "703" ] || report "park --log: expected issue=703, got: $park_logline"
fi

# The park MILESTONE mechanic (round-1 note 1: previously untested — the
# whole (1a) block could be deleted with the suite still green). Two cases,
# because one alone proves nothing: it MUTATES when the record names a
# milestone the issue does not have, and it NO-OPS when it already does.
# Ordering is asserted too — milestone before labels, per #801's "labels and
# milestone first (so a promoted issue is already homed)".
clear_fixtures 705
set_labels 705 '["deferred"]'
set_milestone 705 "some other milestone"
set_item 705 ""
IN_PARK_MS="$WORK/in_park_ms.jsonl"
printf '%s\n' '{"issue":705,"status":"park","unit":"'"$PARK_UNIT_VAL"'","milestone":"GitHub workflow skill overhaul 2","priority":"low","labels":["deferred"]}' > "$IN_PARK_MS"
RC=0; run "$IN_PARK_MS" || RC=$?
[ "$RC" -eq 0 ] || report "park milestone: expected exit 0, got $RC — stderr: $(cat "$OUT/run.stderr.log")"
[ "$(n_mut)" = "5" ] || report "park milestone: expected 5 mutations (milestone, label, comment, close, delete-item), got $(n_mut): $(mut_ops)"
park_ms_val=$(jq -r 'select(.op=="milestone")|.value' "$OUT/mutations.log")
[ "$park_ms_val" = "GitHub workflow skill overhaul 2" ] \
  || report "park milestone: expected the milestone to be set to the record's value, got: $park_ms_val"
park_ms_applied=$(jq -r '.applied|map(select(startswith("milestone:")))|length' "$OUT/run.stdout.log")
[ "$park_ms_applied" = "1" ] || report "park milestone: expected one milestone: entry in applied[], got: $(cat "$OUT/run.stdout.log")"
ms_line=$(grep -n '"op":"milestone"' "$OUT/mutations.log" | head -1 | cut -d: -f1 || true)
lbl_line=$(grep -n '"op":"add-label"' "$OUT/mutations.log" | head -1 | cut -d: -f1 || true)
if [ -n "$ms_line" ] && [ -n "$lbl_line" ]; then
  [ "$ms_line" -lt "$lbl_line" ] || report "park milestone: expected the milestone BEFORE the labels, got milestone at $ms_line, label at $lbl_line"
else
  report "park milestone: expected both a milestone and a label mutation, got: $(mut_ops)"
fi

# ... and the no-op half: the issue is ALREADY in the record's milestone.
clear_fixtures 706
set_labels 706 '["deferred"]'
set_milestone 706 "GitHub workflow skill overhaul 2"
set_item 706 ""
IN_PARK_MS_NOOP="$WORK/in_park_ms_noop.jsonl"
printf '%s\n' '{"issue":706,"status":"park","unit":"'"$PARK_UNIT_VAL"'","milestone":"GitHub workflow skill overhaul 2","priority":"low","labels":["deferred"]}' > "$IN_PARK_MS_NOOP"
RC=0; run "$IN_PARK_MS_NOOP" || RC=$?
[ "$RC" -eq 0 ] || report "park milestone no-op: expected exit 0, got $RC — stderr: $(cat "$OUT/run.stderr.log")"
if grep -q '"op":"milestone"' "$OUT/mutations.log"; then
  report "park milestone no-op: expected NO milestone mutation when it already matches, got: $(mut_ops)"
fi
grep -qi 'milestone already' "$OUT/run.stderr.log" \
  || report "park milestone no-op: expected a 'milestone already' no-op note on stderr, got: $(cat "$OUT/run.stderr.log")"
[ "$(n_mut)" = "4" ] || report "park milestone no-op: expected the other 4 mechanics to still fire, got $(n_mut): $(mut_ops)"

# Park without .unit is refused BEFORE any gh call at all — not even a read.
clear_fixtures 701
set_labels 701 '["deferred"]'
set_item 701 ""
IN_PARK_NOUNIT="$WORK/in_park_nounit.jsonl"
printf '%s\n' '{"issue":701,"status":"park","priority":"low"}' > "$IN_PARK_NOUNIT"
calls_before=$(wc -l < "$MOCK_GH_CALL_LOG")
if run "$IN_PARK_NOUNIT"; then
  report "park without unit: expected non-zero exit, got 0"
fi
[ "$(n_mut)" = "0" ] || report "park without unit: expected zero mutations, got $(n_mut): $(mut_ops)"
grep -qi 'REJECTED' "$OUT/run.stderr.log" || report "park without unit: expected a REJECTED message on stderr"
grep -qi 'unit' "$OUT/run.stderr.log" || report "park without unit: expected the rejection to name unit"
calls_after=$(wc -l < "$MOCK_GH_CALL_LOG")
[ "$calls_before" = "$calls_after" ] \
  || report "park without unit: expected ZERO gh calls (refused before any call), $calls_before before vs $calls_after after"

# Park on an already-parked item (closed not-planned, fully labelled,
# comment already posted, off the board) makes NO mutation at all — the
# same log line ('no-op' notes, empty applied[]) as a fresh apply would
# report nothing new.
clear_fixtures 702
set_labels 702 '["deferred","priority:low","parked"]'
set_state 702 "CLOSED:NOT_PLANNED"
set_comments 702 "$(jq -nc --arg c "$PARK_COMMENT_STORED" '[$c]')"
# item_702 intentionally absent: already off the board.
IN_PARK_NOOP="$WORK/in_park_noop.jsonl"
printf '%s\n' '{"issue":702,"status":"park","unit":"'"$PARK_UNIT_VAL"'","priority":"low","labels":["deferred"]}' > "$IN_PARK_NOOP"
RC=0; run "$IN_PARK_NOOP" || RC=$?
if [ "$RC" -ne 0 ]; then
  report "park idempotent: expected exit 0, got $RC — stderr: $(cat "$OUT/run.stderr.log")"
fi
[ "$(n_mut)" = "0" ] || report "park idempotent: expected zero mutations, got $(n_mut): $(mut_ops)"
grep -qi 'no-op' "$OUT/run.stderr.log" || report "park idempotent: expected no-op notes on stderr"
applied_park=$(jq -r '.applied|length' "$OUT/run.stdout.log")
[ "$applied_park" = "0" ] || report "park idempotent: expected an empty applied[], got: $(cat "$OUT/run.stdout.log")"

# A park record still fails the completeness gate when priority:* is
# missing (same gate as the non-park path) — zero mutations.
clear_fixtures 704
set_labels 704 '["deferred"]'
set_item 704 ""
IN_PARK_NOPRIORITY="$WORK/in_park_nopriority.jsonl"
printf '%s\n' '{"issue":704,"status":"park","unit":"z"}' > "$IN_PARK_NOPRIORITY"
if run "$IN_PARK_NOPRIORITY"; then
  report "park missing priority: expected non-zero exit, got 0"
fi
[ "$(n_mut)" = "0" ] || report "park missing priority: expected zero mutations, got $(n_mut): $(mut_ops)"
grep -qi 'REJECTED' "$OUT/run.stderr.log" || report "park missing priority: expected a REJECTED message on stderr"
grep -qi 'priority' "$OUT/run.stderr.log" || report "park missing priority: expected the rejection to name priority"

echo "----------------------------------------"

# ---------------------------------------------------------------------------
# Hermeticity tripwire (#568, #477): the mock recorded every invocation it
# served, and none of them arrived from a context the harness did not set
# up. Proved load-bearing first, against its own throwaway log: the script
# under test is run with the mock on PATH but WITHOUT the per-run harness
# env, and the marker must appear.
# ---------------------------------------------------------------------------
IN_TRIPWIRE="$WORK/in_tripwire.jsonl"
printf '%s
' '{"issue":999,"milestone":"m","status":"Ready","priority":"low","labels":[]}' > "$IN_TRIPWIRE"
TRIPWIRE_LOG="$OUT/tripwire-probe.log"
: > "$TRIPWIRE_LOG"
set +e
env -u MOCK_FIXTURES -u MOCK_OUT -u MOCK_PROJECT_ID   PATH="$BIN:$PATH" MOCK_GH_CALL_LOG="$TRIPWIRE_LOG"   "$HOME_DEFERRED_SH" --repo "$REPO" --work-tracking "$WT" --claim "$ME"   < "$IN_TRIPWIRE" >/dev/null 2>&1
set -e
grep -q '^UNMOCKED-CONTEXT ' "$TRIPWIRE_LOG"   || report "tripwire probe: an unmocked-context gh call was NOT marked — the tripwire is not load-bearing"

[ -s "$MOCK_GH_CALL_LOG" ]   || report "hermeticity: the mock recorded zero invocations — the call log is not wired up"
if grep -q '^UNMOCKED-CONTEXT ' "$MOCK_GH_CALL_LOG"; then
  report "hermeticity: a gh call was made from an unmocked context: $(grep -m1 '^UNMOCKED-CONTEXT ' "$MOCK_GH_CALL_LOG")"
fi

if [ "$fail" -eq 0 ]; then
  echo "test_home_deferred.sh: all checks passed"
  exit 0
else
  echo "test_home_deferred.sh: FAILURES ABOVE"
  exit 1
fi
