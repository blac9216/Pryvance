#!/usr/bin/env bash
# delivered.sh — for every open issue in scope that carries a `size:*`
# label (the machine-checkable proxy for "has an Estimate section"; this
# script never reads issue-body prose), list the merged PRs that reference
# it and their net LOC. READ-ONLY, GET-only.
#
# Usage: delivered.sh --repo owner/name (--issues N,N,… | --milestone N)
#   [--min-remaining N (default 50)] [--batch-size N (default 20)]
#   [--out <file> (default: stdout)]
# Exit codes — this list is EXHAUSTIVE: 0 completed, nothing dropped; 1 a
#   `gh` call failed or returned output that is not JSON, the GraphQL
#   response carried errors or omitted a requested issue's node, a page
#   said `hasNextPage` without giving a cursor to follow it with, or the
#   rate-limit guard stopped the run (a stderr line names which); 2 usage
#   error (missing --repo, a --repo that is not owner/name, neither/both of
#   --issues/--milestone given, an empty --issues value, a non-numeric
#   --milestone/--min-remaining/--batch-size, or an unknown flag) — no `gh`
#   call is made on this path.
# Class: machine (github-workflow/references/github-tools.md § "Extraction
#   vs. interpretation"). `--repo` is REQUIRED (#736's outer boundary):
#   no `gh repo view` fallback, no local config read.
#
# Scope: exactly one of `--issues N,N,…` (an explicit, comma-split list) or
#   `--milestone N` (every OPEN issue in that milestone carrying a
#   `size:*` label — the has-an-Estimate proxy). The milestone listing is
#   `--paginate`d: a milestone holding more than one page of open issues is
#   read in full, never silently truncated to page 1. Neither reads or
#   writes anything about a CLOSED issue.
#
# Data channel — the mechanism #202's Scope note of 2026-09-05 ratified
# (decisions A1/A3/B4 of the #285 interrogation record): for each issue,
# the union of
#   (a) `closedByPullRequestsReferences` (the linked closing PRs), and
#   (b) the merged pull requests among the sources of the issue's
#       `timelineItems(itemTypes:[CROSS_REFERENCED_EVENT])`,
# keeping MERGED pull requests only, deduplicated by number, each carrying
# `number`/`additions`/`deletions`/`mergedAt` from the same round trip.
# Both halves are load-bearing and neither subsumes the other: an issue
# closed by a linked PR need not be cross-referenced, and a PR that
# delivers scope without closing the issue (the common case for a
# partially-delivered L) appears only in the timeline. Cross-reference
# sources that are issues rather than pull requests, and pull requests that
# are OPEN or closed-unmerged, are dropped.
#
# This replaces an earlier `gh pr list --search "<N>"` text query plus a
# local "#N as a whole token" regex. That channel was measured against
# #202's own Acceptance-Criteria list on 2026-09-06 to drop 2 of 5 merged
# PRs on waypoint#1077, 3 of 5 on waypoint#514, and the only one on
# waypoint#908 — a PR that references an issue from a commit message, a
# review comment or a linked branch rather than from its own title/body is
# invisible to a title/body search, and omission is the direction a reading
# agent cannot see. There is no local text matching left in this script:
# the references it reports are the ones GitHub itself recorded.
#
# Requests: issues are batched with GraphQL aliases — up to --batch-size
# (default 20) issues share ONE `gh api graphql` POST, which also carries
# that response's own `rateLimit`. A further call is spent per issue only
# for each extra page of a connection reporting `hasNextPage`. Measured
# against blac9216/waypoint on 2026-09-06 over AC-3's four issues
# (#1002, #1077, #514, #908): 1 request in total, i.e. 0.25 requests per
# issue, no connection needing a second page. The worst case is bounded by
# 1/--batch-size plus one call per extra page, well inside the
# ≤2-calls-per-issue budget #202's Acceptance Criteria set.
#
# Rate guard (the same shape as history.sh, #201 — literally, not by
# analogy): the authenticated remaining/reset is read off each GraphQL
# response's own `rateLimit{remaining resetAt}` field, NEVER a separate
# `gh api rate_limit` call. That matters beyond saving a request: this
# script's per-issue work spends the GraphQL budget, and REST `core`,
# GraphQL and `search` are independent buckets — a guard reading `core`
# passes at full headroom while GraphQL is exhausted, which is the normal
# state for a token that has been running GraphQL work. Before each call
# after the first, a remaining below --min-remaining stops the run, named
# on stderr with the reset time, exit 1. A remaining that is absent or
# non-numeric, or a resetAt that is not an ISO-8601 UTC instant, is a hard
# stop too — an unknown budget is never read as headroom. The first call is
# necessarily unguarded (it is the one that reads the budget), exactly as
# in history.sh.
#
# Output: one markdown table row per issue in scope — issue number,
# matched PR numbers (or "(none)"), net LOC, and, for the Estimate section
# convention this feeds (#202, estimate.md), the exact
# "Delivered so far: PR #… (n LOC)" line to paste when net LOC is > 0. The
# table is emitted only after every issue has been collected, so a run the
# rate guard stops emits no half-table. To stdout by default; --out writes
# the same table to a file instead.
#
# Deciding whether the remainder should be closed-as-delivered or re-sized
# is the reading agent's job (decompose.md/estimate.md step 0), not this
# script's: net LOC vs. the issue's own size bucket is a comparison a human
# or agent makes, not a verdict this script renders.
set -euo pipefail

REPO=""
ISSUES=""
MILESTONE=""
MIN_REMAINING=50
BATCH_SIZE=20
OUT=""

while [ $# -gt 0 ]; do
  case $1 in
    --repo) REPO=$2; shift 2 ;;
    --issues) ISSUES=$2; shift 2 ;;
    --milestone) MILESTONE=$2; shift 2 ;;
    --min-remaining) MIN_REMAINING=$2; shift 2 ;;
    --batch-size) BATCH_SIZE=$2; shift 2 ;;
    --out) OUT=$2; shift 2 ;;
    *) echo "unknown arg $1" >&2; exit 2 ;;
  esac
done

say(){ printf '%s\n' "$*" >&2; }
die(){ say "error: $*"; exit 1; }

[ -n "$REPO" ] || { echo "--repo is required (owner/name) — no gh repo view fallback (#736)" >&2; exit 2; }
if [ -n "$ISSUES" ] && [ -n "$MILESTONE" ]; then
  echo "--issues and --milestone are mutually exclusive — pass exactly one" >&2
  exit 2
fi
if [ -z "$ISSUES" ] && [ -z "$MILESTONE" ]; then
  echo "exactly one of --issues N,N,… or --milestone N is required" >&2
  exit 2
fi
if [ -n "$MILESTONE" ]; then
  case $MILESTONE in ''|*[!0-9]*) echo "--milestone must be a positive integer, got '$MILESTONE'" >&2; exit 2 ;; esac
fi
case $MIN_REMAINING in ''|*[!0-9]*) echo "--min-remaining must be a non-negative integer, got '$MIN_REMAINING'" >&2; exit 2 ;; esac
case $BATCH_SIZE in ''|*[!0-9]*|0) echo "--batch-size must be a positive integer, got '$BATCH_SIZE'" >&2; exit 2 ;; esac

# `--repo` is validated against the character set GitHub actually allows in
# an owner or a repository name BEFORE it reaches any call. The strict form
# matters beyond tidiness: OWNER/NAME are passed to GraphQL as variables
# (see `gql` below), and a value carrying a quote or a brace has no business
# reaching the API layer at all. Anything else is a usage error, exit 2.
if [[ ! $REPO =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
  echo "--repo must be owner/name, got '$REPO'" >&2
  exit 2
fi
OWNER=${REPO%%/*}
NAME=${REPO#*/}

ISSUE_LIST=()
if [ -n "$ISSUES" ]; then
  IFS=',' read -ra raw <<<"$ISSUES"
  for n in "${raw[@]}"; do
    case $n in ''|*[!0-9]*) echo "--issues: '$n' is not a positive integer" >&2; exit 2 ;; esac
    ISSUE_LIST+=("$n")
  done
  [ "${#ISSUE_LIST[@]}" -gt 0 ] || { echo "--issues: empty list" >&2; exit 2; }
fi

WORK=$(mktemp -d "${TMPDIR:-/tmp}/delivered.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

# ---------------------------------------------------------------------------
# Milestone scope. Two distinct omission failures are guarded here, and they
# are not the same defect:
#   (a) `--paginate` is what keeps a milestone with more than one page of
#       open issues from being read as only its first page: without it the
#       extra issues are not an error, they are simply absent.
#   (b) the listing's EXIT STATUS is checked explicitly. The listing is
#       captured to a file and its status tested, never read through
#       `done < <(gh api …)`: a process substitution's exit status is
#       discarded and `set -euo pipefail` does not cover it, so a `gh` that
#       fails outright — a mistyped `--milestone` is an HTTP 422 today —
#       or one that dies partway through `--paginate` would leave an empty
#       or short list that this script would then report as "nothing
#       delivered" with exit 0. A confident empty answer is precisely the
#       invisible omission #202 exists to prevent, and it would contradict
#       both this header's exhaustive exit-code list and its claim that the
#       listing is read in full. `check-reviewer-commits.sh` L382 guards
#       the identical shape the same way.
# ---------------------------------------------------------------------------
if [ -n "$MILESTONE" ]; then
  say "reading milestone $MILESTONE's open, size:*-labelled issues …"
  ms_rc=0
  gh api --paginate "repos/$REPO/issues?milestone=$MILESTONE&state=open&per_page=100" \
    --jq '.[]|select(.pull_request==null)|select([.labels[].name]|any(test("^size:[sml]$")))|.number' \
    > "$WORK/milestone.txt" 2> "$WORK/milestone.err" || ms_rc=$?
  [ "$ms_rc" -eq 0 ] || die "gh api repos/$REPO/issues?milestone=$MILESTONE&state=open failed (exit $ms_rc) — refusing to report a failed or partial milestone listing as an empty one: $(tr '\n' ' ' < "$WORK/milestone.err" | head -c 400)"
  while IFS= read -r n; do
    [ -n "$n" ] && ISSUE_LIST+=("$n")
  done < "$WORK/milestone.txt"
fi

if [ "${#ISSUE_LIST[@]}" -eq 0 ]; then
  say "no open size:*-labelled issues in scope — nothing to report"
fi

# ---------------------------------------------------------------------------
# Rate-guard state, read off each response (never a separate rate_limit
# call). Empty until the first response has been parsed.
# ---------------------------------------------------------------------------
RL_REMAINING=""
RL_RESET=""
GQL_CALLS=0

# The Issue selection, parameterised by the `after:` cursors so a follow-up
# page asks only for the connection that still has one. An exhausted
# connection ("-") is omitted from the follow-up rather than re-fetched.
issue_field(){ # $1 issue number, $2 closed-refs cursor or "-", $3 timeline cursor or "-"
  local n=$1 cc=$2 tc=$3 out="" arg=""
  out="    i${n}: issue(number:${n}) {"$'\n'"      number"$'\n'
  if [ "$cc" != "-" ]; then
    arg="first:100"
    [ -z "$cc" ] || arg="first:100, after:\"$cc\""
    out+="      closedByPullRequestsReferences(${arg}, includeClosedPrs:true) {"$'\n'
    out+="        pageInfo { hasNextPage endCursor }"$'\n'
    out+="        nodes { number state additions deletions mergedAt }"$'\n'
    out+="      }"$'\n'
  fi
  if [ "$tc" != "-" ]; then
    arg="first:100"
    [ -z "$tc" ] || arg="first:100, after:\"$tc\""
    out+="      timelineItems(${arg}, itemTypes:[CROSS_REFERENCED_EVENT]) {"$'\n'
    out+="        pageInfo { hasNextPage endCursor }"$'\n'
    out+="        nodes { ... on CrossReferencedEvent { source { ... on PullRequest { number state additions deletions mergedAt } } } }"$'\n'
    out+="      }"$'\n'
  fi
  out+="    }"$'\n'
  printf '%s' "$out"
}

# One GraphQL round trip: $1 is the body of `repository { … }`, $2 the file
# the response is written to. Enforces the budget BEFORE spending the call,
# then refreshes it from the response this call produced. The response goes
# to a FILE, not stdout, on purpose: a `$(gql …)` capture would run this in a
# subshell and the refreshed RL_REMAINING/RL_RESET/GQL_CALLS would be
# discarded with it, leaving the guard permanently unarmed.
# The owner and the name are GraphQL VARIABLES, never interpolated into the
# document text — the same shape history.sh uses (`query($owner:String!,
# $name:String!, …)` with `-F "owner=$OWNER" -F "name=$NAME"`, L395-398 and
# L513). Interpolating them would make the document's structure depend on
# their contents: a `--repo` value carrying a quote could close the argument
# list and inject a selection of its own. `--repo` is agent-supplied rather
# than attacker-controlled and is strictly validated above, so this is
# defence in depth, not a live hole — but the variable form costs nothing
# and removes the class outright.
gql(){
  local fields=$1 dest=$2 query resp errs rem reset
  if [ -n "$RL_REMAINING" ] && [ "$RL_REMAINING" -lt "$MIN_REMAINING" ]; then
    die "rate guard: $RL_REMAINING GraphQL requests remaining (< $MIN_REMAINING), resets at $RL_RESET — stopping before the next call"
  fi
  query="query(\$owner:String!, \$name:String!) {"$'\n'"  rateLimit { remaining resetAt }"$'\n'"  repository(owner: \$owner, name: \$name) {"$'\n'"$fields""  }"$'\n'"}"$'\n'
  resp=$(gh api graphql -f query="$query" -F "owner=$OWNER" -F "name=$NAME" 2>&1) \
    || die "gh api graphql failed: $resp"
  GQL_CALLS=$((GQL_CALLS + 1))
  errs=$(jq -r 'if (.errors // empty) then (.errors|map(.message)|join("; ")) else "" end' <<<"$resp" 2>/dev/null) \
    || die "gh api graphql returned output that is not JSON: $(head -c 200 <<<"$resp")"
  [ -z "$errs" ] || die "GraphQL errors: $errs"

  rem=$(jq -r '.data.rateLimit.remaining // empty' <<<"$resp")
  reset=$(jq -r '.data.rateLimit.resetAt // empty' <<<"$resp")
  case $rem in
    ''|*[!0-9]*) die "unreadable rate limit: rateLimit.remaining is '${rem:-<absent>}', not a number — refusing to treat an unknown budget as headroom" ;;
  esac
  case $reset in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) ;;
    *) die "unreadable rate limit: rateLimit.resetAt is '${reset:-<absent>}', not an ISO-8601 UTC instant — refusing to treat an unknown budget as headroom" ;;
  esac
  RL_REMAINING=$rem
  RL_RESET=$reset
  printf '%s' "$resp" > "$dest"
}

# The merged pull requests from ONE issue's node, both halves of the union.
# A cross-reference whose source is an issue rather than a pull request comes
# back as `{}` (the inline PullRequest fragment matches no field on it), so it
# is excluded by the `.state == "MERGED"` test — that test, not the `.number`
# one, is what actually drops it, and the suite's splice confirms as much.
# `.number != null` is kept as a deliberate belt-and-braces precondition: a
# node with no number could not be rendered into the table even if some
# future schema gave a non-PullRequest source a `state`. It is redundant
# today and is not claimed to be independently load-bearing.
NODE_FILTER='
  [ (.closedByPullRequestsReferences.nodes // [])[],
    ((.timelineItems.nodes // [])[] | .source) ]
  | map(select(.number != null and .state == "MERGED"))
'

# A connection cursor, fail-closed: a page claiming hasNextPage without an
# endCursor cannot be followed, and carrying on would silently return a
# truncated set — the very failure the search channel's --limit had.
cursor_of(){ # $1 response file, $2 issue number, $3 connection -> cursor, or "-" when done
  local resp=$1 n=$2 conn=$3 has cur
  has=$(jq -r --arg c "$conn" ".data.repository.i${n}[\$c].pageInfo.hasNextPage // false" "$resp")
  if [ "$has" != "true" ]; then printf '%s' "-"; return 0; fi
  cur=$(jq -r --arg c "$conn" ".data.repository.i${n}[\$c].pageInfo.endCursor // empty" "$resp")
  [ -n "$cur" ] || die "issue #$n: $conn reports hasNextPage with no endCursor — refusing to report a truncated set as complete"
  printf '%s' "$cur"
}

# ---------------------------------------------------------------------------
# Collection: up to --batch-size issues share one call, then each issue that
# still has pages left is followed to exhaustion.
# ---------------------------------------------------------------------------
collect(){
  local i=0 total=${#ISSUE_LIST[@]} batch fields n cc tc page
  local resp="$WORK/.resp.json" presp="$WORK/.presp.json"
  while [ "$i" -lt "$total" ]; do
    batch=(); fields=""
    while [ "$i" -lt "$total" ] && [ "${#batch[@]}" -lt "$BATCH_SIZE" ]; do
      batch+=("${ISSUE_LIST[$i]}")
      i=$((i + 1))
    done
    for n in "${batch[@]}"; do fields+=$(issue_field "$n" "" ""); done
    gql "$fields" "$resp"

    for n in "${batch[@]}"; do
      jq -e --arg k "i$n" '.data.repository[$k] != null' "$resp" >/dev/null \
        || die "issue #$n: no node in the GraphQL response — refusing to report it as undelivered"
      jq -c ".data.repository.i${n} | $NODE_FILTER" "$resp" > "$WORK/$n.json"

      page=1
      cc=$(cursor_of "$resp" "$n" closedByPullRequestsReferences)
      tc=$(cursor_of "$resp" "$n" timelineItems)
      while [ "$cc" != "-" ] || [ "$tc" != "-" ]; do
        page=$((page + 1))
        say "issue #$n: fetching page $page …"
        gql "$(issue_field "$n" "$cc" "$tc")" "$presp"
        jq -c -s 'add' "$WORK/$n.json" \
          <(jq -c ".data.repository.i${n} | $NODE_FILTER" "$presp") > "$WORK/$n.next"
        mv "$WORK/$n.next" "$WORK/$n.json"
        [ "$cc" = "-" ] || cc=$(cursor_of "$presp" "$n" closedByPullRequestsReferences)
        [ "$tc" = "-" ] || tc=$(cursor_of "$presp" "$n" timelineItems)
      done
    done
  done
}

emit(){
  echo "| Issue | Merged PRs | Net LOC | Estimate-section line |"
  echo "|---|---|---|---|"
  local n merged count net_loc pr_list
  for n in "${ISSUE_LIST[@]}"; do
    merged=$(jq -c 'unique_by(.number)' "$WORK/$n.json")
    count=$(jq 'length' <<<"$merged")
    if [ "$count" -eq 0 ]; then
      echo "| #$n | (none) | 0 | (not delivered) |"
      continue
    fi
    # Net LOC is |additions − deletions| summed over the matched merged PRs:
    # each PR's net is taken in ABSOLUTE value before the sum, so a +50/−50
    # PR contributes 0 and a 0/−300 PR contributes 300. That is deliberate
    # and is the repo's settled convention, not an oversight — history.sh
    # L490 computes its own per-PR `net_loc` with the identical formula, and
    # estimate.md/decompose.md state it where the reading agent meets it.
    net_loc=$(jq '[.[]|(.additions - .deletions)|if .<0 then -. else . end]|add' <<<"$merged")
    pr_list=$(jq -r '[.[].number]|sort|map("#\(.)")|join(", ")' <<<"$merged")
    # The convention is "Delivered so far: PR #… (n LOC)" (#202's Proposed
    # Changes, estimate.md). The `PR` token is part of the line, not
    # decoration around it: this column exists to be pasted verbatim into an
    # Estimate section, so a line missing it puts the violation into every
    # issue that pastes it.
    echo "| #$n | $pr_list | $net_loc | Delivered so far: PR $pr_list ($net_loc LOC) |"
  done
}

collect
# With nothing in scope no call is made, so there is no response-borne
# rate-limit reading to report: saying "  remaining, resets at " with two
# empty fields reads as a budget of nothing rather than as no reading taken.
if [ "$GQL_CALLS" -eq 0 ]; then
  say "collected ${#ISSUE_LIST[@]} issue(s) in 0 GraphQL request(s); no rate-limit reading taken (no call was made)"
else
  say "collected ${#ISSUE_LIST[@]} issue(s) in $GQL_CALLS GraphQL request(s); $RL_REMAINING remaining, resets at $RL_RESET"
fi

# --out writes to the named file; absent --out, emit writes to this
# process's own stdout, inherited as-is. Never `> /dev/stdout`: when the
# caller has already redirected this script's stdout to a real file (e.g.
# `delivered.sh ... >> log` inside a larger recorded run), reopening
# /dev/stdout with `>` truncates that SAME underlying file out from under
# the caller, silently discarding everything written to it before this
# script ran -- `{ echo before; sh -c 'echo x > /dev/stdout'; } >> log`
# loses "before" for exactly this reason. Writing to the inherited
# descriptor instead of a reopened path makes that failure unreachable.
if [ -n "$OUT" ]; then
  emit > "$OUT"
else
  emit
fi
