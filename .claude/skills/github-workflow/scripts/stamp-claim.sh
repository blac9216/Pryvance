#!/usr/bin/env bash
# stamp-claim.sh — take/refresh/release/takeover a board claim, or write the
# per-issue dispatch stamp, per references/claims.md and formats/claim.md.
#
# Usage: stamp-claim.sh <take|refresh|release|takeover|stamp> --item <issue-number>
#                        --id <claim-id> [--repo owner/name] [--log <path>]
#                        [--work-tracking <path>]
#
# Contract: refuse rather than guess. Every refusal path below exits non-zero
# BEFORE issuing any GraphQL mutation — the read that decides the outcome
# always happens first, and a refusal never reaches the mutation call. Board
# and field ids are parsed from docs/process/work-tracking.md's ids table
# (default path relative to the repo root, overridable with
# --work-tracking); they are never hard-coded here, and neither is any
# repository- or owner-specific noun — the target repo comes from --repo or,
# failing that, `gh repo view` on the current checkout.
#
# Verbs, applied to the `Claimed by` project field on the item named by
# --item (per claims.md's "two roles" section — this script does not itself
# decide whether an item is epic-level or standalone; the caller passes the
# item that holds the coordination lock, or the dispatched issue for
# `stamp`):
#   take      — write <id> @ <now> when the field is empty, the existing
#               value carries the dispatch-stamp marker (formats/claim.md's
#               trailing ` (stamp)`, issue #744 — a stamp is never a
#               coordination claim, so `take` treats it exactly like an
#               empty field), or the existing claim is stale. Refuses on a
#               live claim held by someone else. A live claim that is
#               already MINE (its id equals --id) is an idempotent no-op: no
#               mutation, `applied:false`, exit 0 — a resumed session
#               re-taking its own live claim has nothing to change, and
#               callers must not have to recognize that case by grepping a
#               refusal message (issue #262 round 1, F8). When taking over a
#               stale claim (not an empty field, not a stamp), logs the
#               superseded id and prints the same epic-comment reminder as
#               `takeover` below.
#   takeover  — write <id> @ <now> over an existing claim, only when that
#               claim is stale; logs the superseded id and prints a stderr
#               reminder that claims.md requires an event comment on the
#               epic naming the superseded claim and its timestamp — this
#               script does not post that comment, the caller must (a silent
#               takeover is exactly what the announcement rule prevents). A
#               marked (stamp-form) value refuses exactly like an empty
#               field — there is nothing to take over, use `take` (#744).
#   refresh   — rewrite the timestamp to now. Only when the existing claim's
#               id already matches --id AND it is not a marked stamp value
#               (#744 — a stamp was never a coordination claim of anyone's
#               to refresh). Refuses otherwise, live, stale, or stamped.
#   release   — clear the field. Only when the existing claim's id matches
#               --id and it is not a marked stamp value, or the field is
#               already empty, in which case it is an idempotent no-op that
#               issues no mutation (prints a stderr note instead). Refuses
#               on someone else's claim and on a marked stamp value (#744 —
#               a stamp is the never-cleared ownership ledger, `release` is
#               not how it goes away).
#   stamp     — unconditionally write <id> @ <now> (stamp) — the literal
#               trailing marker, formats/claim.md — to --item's own
#               `Claimed by` field: the informational, never-cleared dispatch
#               stamp (claims.md "Two roles for Claimed by"). No live/stale
#               check applies — it is not the coordination lock, and the
#               marker is what lets a reader (this script, or a human) tell
#               it apart from one mechanically, without consulting the
#               issue's parent (#744). Deliberately unconditional even over
#               a live coordination lock on a standalone issue (issue #771)
#               — see claims.md's Script subsection for why this is a design
#               property, not a gap, and what actually prevents the clobber.
#
# Staleness (claims.md): a claim is stale when its timestamp is more than
# 24h old AND the item has had no PR/commit/comment activity since that
# timestamp. Both conditions. Activity is read from the issue timeline
# (covers commented / cross-referenced / referenced / committed events) via
# a paginated GET — never guessed from the timestamp alone. Staleness is
# never evaluated on a marked stamp value — it is never a coordination claim
# to begin with, so "stale" does not apply (#744).
#
# Output: one JSON object on stdout — {item, field, action, before, after,
# superseded, applied} — printed ONLY on a completed run: a mutation that
# landed, or one of the idempotent no-ops below (`applied:false` on those:
# release on an already-empty field; take on a live claim already mine).
# Every refusal or hard failure goes through `die()`/`refuse()` below, which
# print the reason to stderr and exit non-zero BEFORE this object is ever
# built — a refusal is stderr-plus-exit-code, never `applied:false` on
# stdout, and is signalled by the exit code below instead.
# `--log <path>` appends one session-log event line (`claim` for
# take/refresh/release/takeover, `claim-stamp` for `stamp` — a name distinct
# from the orchestrator's own `dispatch` event so the two are never
# double-counted by a `dispatch`-keyed aggregation) to that file; without
# `--log` the same line is echoed to stderr instead of being silently
# dropped.
#
# EXIT-CODE-CONTRACT:BEGIN (mirrored verbatim in claims.md; issue #627)
# Exit codes:
# 0 = applied, or an idempotent no-op (release on an already-empty field;
# take on a live claim that is already mine). 2 = argument error -- a defect
# in the call itself, not in the board state. 3 = a business-rule REFUSAL:
# the board state legitimately says no (live foreign claim on take/takeover,
# takeover with nothing to take over, refresh/release of a claim that is not
# mine). 1 = a HARD FAILURE: the GraphQL read or mutation failed, the item is
# not on the board, the stored claim value or its timestamp is malformed, or
# the timeline GET failed -- i.e. the script could not determine or write the
# outcome at all. 4 = the verb SUCCEEDED (the mutation landed, or the no-op
# applied, and the JSON was printed) but the --log line could not be appended
# -- a local filesystem problem, never a claim problem. It is its own code
# precisely so a caller cannot read it as a failed claim and act on a board
# that was in fact written (issue #262 round 2, F1). 3-vs-1 exists so a
# caller can act on the difference without parsing prose: a refusal is a
# normal concurrent-session outcome to skip over, a hard failure is a defect
# or an outage and must be loud. In every non-zero case the reason is on
# stderr, and nothing is printed on stdout on 1, 2 or 3. On 2 and 3 no
# mutation is ever attempted. On 1, most paths (argument/board/timeline
# reads, malformed stored values) also precede any mutation, but two paths
# run only after a mutation has already been attempted or has already landed:
# the GraphQL mutation call itself failing exits 1 with the outcome unknown
# (landed server-side or not); and, after a mutation that IS known to have
# landed, the result or log-event JSON failing to build (issue #638) also
# exits 1, with the outcome known-applied but unreported on stdout. This is
# exactly why 1 means "could not determine or write the outcome at all, or
# could not report an outcome that is known to have landed" rather than
# "definitely nothing changed". On 4 the mutation DID happen and the success
# JSON is still the last line on stdout -- no non-zero code ever reports a
# partial success as a full one, and none reports a completed write as if
# nothing was written.
# EXIT-CODE-CONTRACT:END
set -euo pipefail

die(){ echo "stamp-claim: $*" >&2; exit 1; }      # hard failure
refuse(){ echo "stamp-claim: $*" >&2; exit 3; }   # business-rule refusal
argerr(){ echo "stamp-claim: $*" >&2; exit 2; }

VERB=""; ITEM=""; ID=""; REPO=""; LOG_PATH=""; WORK_TRACKING=""
while [ $# -gt 0 ]; do
  case "$1" in
    take|refresh|release|takeover|stamp)
      [ -z "$VERB" ] || argerr "unexpected extra argument $1"
      VERB="$1"; shift ;;
    --item) ITEM="${2:?--item needs a value}"; shift 2 ;;
    --id) ID="${2:?--id needs a value}"; shift 2 ;;
    --repo) REPO="${2:?--repo needs a value}"; shift 2 ;;
    --log) LOG_PATH="${2:?--log needs a value}"; shift 2 ;;
    --work-tracking) WORK_TRACKING="${2:?--work-tracking needs a value}"; shift 2 ;;
    -*) argerr "unknown flag $1" ;;
    *) argerr "unexpected extra argument $1" ;;
  esac
done
[ -n "$VERB" ] || argerr "usage: stamp-claim.sh <take|refresh|release|takeover|stamp> --item <issue-number> --id <claim-id> [--repo owner/name] [--log <path>] [--work-tracking <path>]"
[ -n "$ITEM" ] || argerr "--item is required"
case "$ITEM" in ''|*[!0-9]*) argerr "--item must be a positive integer, got: $ITEM" ;; esac
[ -n "$ID" ] || argerr "--id is required"

[ -n "$REPO" ] || REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null) \
  || die "could not resolve --repo and 'gh repo view' failed — pass --repo owner/name"
OWNER="${REPO%%/*}"; NAME="${REPO#*/}"
[ -n "$OWNER" ] && [ -n "$NAME" ] && [ "$OWNER" != "$REPO" ] || argerr "--repo must be owner/name, got: $REPO"

if [ -z "$WORK_TRACKING" ]; then
  REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) \
    || die "could not resolve the repo root to find docs/process/work-tracking.md — pass --work-tracking"
  WORK_TRACKING="$REPO_ROOT/docs/process/work-tracking.md"
fi
[ -f "$WORK_TRACKING" ] || die "work-tracking doc not found: $WORK_TRACKING (pass --work-tracking)"

# ---------------------------------------------------------------------------
# Board/field ids: parsed from the "| Field | Id |" table, never hard-coded.
# A row's id is the sole backtick-quoted token in that exact-label row.
# ---------------------------------------------------------------------------
parse_id(){ # parse_id <exact-label> <file>
  # sed's `-n ... p` (not `grep -oP`, a PCRE extension BSD/macOS grep lacks)
  # prints the sole backtick-quoted token ONLY on a line that has one — no
  # match means no output, same as the old pattern's `|| true` — portable to
  # any POSIX sed, not just Linux's GNU grep.
  local label="$1" file="$2" val
  # shellcheck disable=SC2016 # single-quoted on purpose - the sed backreference is not meant to expand
  val=$(grep -E "^\| ${label} \|" "$file" | head -1 | sed -n -E 's/^.*`([^`]+)`.*$/\1/p')
  [ -n "$val" ] || die "could not find '| $label |' with a backtick-quoted id in $file"
  printf '%s' "$val"
}
PROJECT_ID=$(parse_id "Project" "$WORK_TRACKING")
FIELD_ID=$(parse_id "Claimed by" "$WORK_TRACKING")

WORK="$(mktemp -d "${TMPDIR:-/tmp}/stamp-claim.XXXXXX")"
cleanup(){ rm -rf "$WORK"; }
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Resolve --item's project item id (within PROJECT_ID) and its current
# `Claimed by` text, in one GraphQL read. A ProjectV2 text field has no
# native "empty" distinct from an empty string — an absent fieldValueByName
# node and a text of "" both mean unclaimed.
# ---------------------------------------------------------------------------
# shellcheck disable=SC2016 # single-quoted GraphQL document — its $vars are server-side, resolved by -F, not shell expansion
NODES=$(gh api graphql -f query='
  query($owner:String!,$name:String!,$number:Int!){
    repository(owner:$owner,name:$name){
      issue(number:$number){
        projectItems(first:20){
          nodes{
            id
            project{ id }
            fieldValueByName(name:"Claimed by"){
              ... on ProjectV2ItemFieldTextValue{ text }
            }
          }
        }
      }
    }
  }' -F owner="$OWNER" -F name="$NAME" -F number="$ITEM" \
  --jq '.data.repository.issue.projectItems.nodes' 2>"$WORK/read.err") \
  || die "GraphQL read for issue #$ITEM failed: $(cat "$WORK/read.err")"

ITEM_ID=$(jq -r --arg p "$PROJECT_ID" '.[]|select(.project.id==$p)|.id' <<<"$NODES" | head -1)
[ -n "$ITEM_ID" ] || die "issue #$ITEM has no project item on project $PROJECT_ID — is it on the board?"
CURRENT=$(jq -r --arg p "$PROJECT_ID" '.[]|select(.project.id==$p)|(.fieldValueByName.text // "")' <<<"$NODES" | head -1)

# ---------------------------------------------------------------------------
# Parse the existing claim value "<id> @ <ISO-UTC>[ (stamp)]" (formats/claim.md).
# Empty means unclaimed. The literal trailing " (stamp)" marker (issue #744)
# is stripped into CUR_IS_STAMP so every coordination verb below can tell a
# dispatch stamp apart from a coordination claim by the value's own text —
# never by the item's parent, which this script does not read at all.
# ---------------------------------------------------------------------------
CUR_ID=""; CUR_TS=""; CUR_IS_STAMP=0
if [ -n "$CURRENT" ]; then
  CUR_ID=$(printf '%s' "$CURRENT" | sed -E 's/^([^[:space:]]+) @ (.*)$/\1/')
  CUR_REST=$(printf '%s' "$CURRENT" | sed -E 's/^([^[:space:]]+) @ (.*)$/\2/')
  { [ -n "$CUR_ID" ] && [ -n "$CUR_REST" ] && [ "$CUR_ID" != "$CURRENT" ]; } \
    || die "existing 'Claimed by' value does not match '<id> @ <ISO-UTC>[ (stamp)]': $CURRENT"
  case "$CUR_REST" in
    *' (stamp)')
      CUR_IS_STAMP=1
      CUR_TS="${CUR_REST% (stamp)}"
      [ -n "$CUR_TS" ] || die "existing 'Claimed by' value does not match '<id> @ <ISO-UTC>[ (stamp)]': $CURRENT"
      ;;
    *)
      CUR_TS="$CUR_REST"
      ;;
  esac
fi

# ---------------------------------------------------------------------------
# Staleness: >24h old AND no PR/commit/comment activity on the item since
# CUR_TS, read from the issue timeline (commented / cross-referenced /
# referenced / committed events cover PR, commit and comment activity in one
# paginated GET). Only evaluated when there is an existing claim to judge.
# `committed` timeline events carry no `created_at` (the date lives under
# `committer.date`); the filter below falls back to that field so a null
# `created_at` is tolerated rather than aborting `fromdate` (issue #319).
# Called at most once per run (take and takeover are mutually exclusive
# verbs, and take's own branches are mutually exclusive too), so it is
# called directly — no memoizing wrapper, nothing to cache.
# ---------------------------------------------------------------------------
is_stale(){
  local now_epoch cur_epoch age activity
  now_epoch=$(date -u +%s)
  cur_epoch=$(date -u -d "$CUR_TS" +%s 2>/dev/null) \
    || die "existing claim timestamp is not a valid date: $CUR_TS"
  age=$((now_epoch - cur_epoch))
  [ "$age" -gt 86400 ] || return 1
  gh api --paginate "repos/$REPO/issues/$ITEM/timeline?per_page=100" \
    --jq '.[]|{event:.event,created_at:(.created_at // .committer.date // null)}' \
    > "$WORK/timeline.raw" 2>"$WORK/timeline.err" \
    || die "GET repos/$REPO/issues/$ITEM/timeline failed: $(cat "$WORK/timeline.err")"
  jq -s '.' "$WORK/timeline.raw" > "$WORK/timeline.json"
  activity=$(jq --argjson cur "$cur_epoch" \
    '[.[]|select(.event=="commented" or .event=="cross-referenced" or .event=="referenced" or .event=="committed")
       |select(.created_at != null)
       |select((.created_at|fromdate) > $cur)]|length' "$WORK/timeline.json")
  [ "$activity" -eq 0 ]
}

# Two distinct timestamp formats, deliberately not the same variable:
# NOW_TS is the board's `Claimed by` field value — minute precision, per
# formats/claim.md's now-exact spec (`YYYY-MM-DDTHH:MMZ`), a human-facing
# board string. LOG_TS is the session-log `ts` field — second precision, per
# formats/session-log.md's now-exact spec (`YYYY-MM-DDTHH:MM:SSZ`), read by
# stall-check.sh and log-consistency-check.sh's strict `ts_ok` predicate.
# Issue #743: these two used to share one minute-precision value, so every
# `claim-stamp`/`claim` line this script wrote was silently discarded by
# both readers as a malformed record.
NOW_TS=$(date -u +%Y-%m-%dT%H:%MZ)
LOG_TS=$(date -u +%FT%TZ)
NEW_VALUE=""; SUPERSEDED_ID=""; HAS_SUPERSEDED=false; LOG_EVENT="claim"; SKIP_MUTATION=0

# Reminder helper for the two paths that write over a superseded claim
# (claims.md § Collisions and takeovers): the script performs the write but
# never posts the required epic event comment — that stays on the caller, or
# the write looks silent and the superseded session is blindsided rather
# than seeing it was superseded, which is exactly what the announcement
# rule exists to prevent.
warn_supersede(){
  echo "stamp-claim: reminder — claims.md requires an event comment on the epic naming the superseded claim ('$1' @ $2) and its timestamp; this script does not post it, the caller (orchestrator) must." >&2
}

case "$VERB" in
  take)
    if [ -z "$CURRENT" ] || [ "$CUR_IS_STAMP" -eq 1 ]; then
      # Empty field, OR the field holds only a dispatch stamp (issue #744):
      # a stamp was never a coordination claim, so `take` treats it exactly
      # like an empty field — no superseded id, since nothing coordination-
      # level is being overtaken.
      NEW_VALUE="$ID @ $NOW_TS"
    elif is_stale; then
      NEW_VALUE="$ID @ $NOW_TS"
      if [ "$CUR_ID" != "$ID" ]; then
        SUPERSEDED_ID="$CUR_ID"; HAS_SUPERSEDED=true
        warn_supersede "$CUR_ID" "$CUR_TS"
      fi
    elif [ "$CUR_ID" = "$ID" ]; then
      # Live and already mine: idempotent no-op, no mutation, exit 0.
      NEW_VALUE="$CURRENT"
      SKIP_MUTATION=1
      echo "stamp-claim: take on #$ITEM is a no-op — 'Claimed by' already holds my own live claim ('$ID' @ $CUR_TS), no mutation issued" >&2
    else
      refuse "refusing take on #$ITEM: live claim held by '$CUR_ID' (since $CUR_TS) — not empty, not stale, not mine"
    fi
    ;;
  takeover)
    { [ -n "$CURRENT" ] && [ "$CUR_IS_STAMP" -eq 0 ]; } \
      || refuse "refusing takeover on #$ITEM: field is empty or holds only an informational dispatch stamp ('$CURRENT') — nothing to take over, use 'take'"
    is_stale || refuse "refusing takeover on #$ITEM: live claim held by '$CUR_ID' (since $CUR_TS) — takeover requires a stale claim"
    NEW_VALUE="$ID @ $NOW_TS"
    SUPERSEDED_ID="$CUR_ID"; HAS_SUPERSEDED=true
    warn_supersede "$CUR_ID" "$CUR_TS"
    ;;
  refresh)
    { [ "$CUR_ID" = "$ID" ] && [ "$CUR_IS_STAMP" -eq 0 ]; } \
      || refuse "refusing refresh on #$ITEM: current claim is '$CURRENT'$( [ "$CUR_IS_STAMP" -eq 1 ] && echo ", an informational dispatch stamp — never a coordination claim to refresh" || echo ", not mine ($ID)")"
    NEW_VALUE="$ID @ $NOW_TS"
    ;;
  release)
    if [ -z "$CURRENT" ]; then
      # Idempotent no-op: nothing is claimed, so there is nothing to clear.
      # Per issue #321, skip the mutation entirely rather than writing ""
      # over "" — same applied:false/exit-0 contract as every other no-op.
      NEW_VALUE=""
      SKIP_MUTATION=1
      echo "stamp-claim: release on #$ITEM is a no-op — 'Claimed by' is already empty, no mutation issued" >&2
    elif [ "$CUR_IS_STAMP" -eq 1 ]; then
      refuse "refusing release on #$ITEM: current value '$CURRENT' is an informational dispatch stamp — it is never cleared at release, it is the never-cleared ownership ledger (claims.md § Two roles)"
    elif [ "$CUR_ID" = "$ID" ]; then
      NEW_VALUE=""
    else
      refuse "refusing release on #$ITEM: current claim is '$CURRENT', not mine ($ID)"
    fi
    ;;
  stamp)
    NEW_VALUE="$ID @ $NOW_TS (stamp)"
    LOG_EVENT="claim-stamp"
    ;;
esac

# ---------------------------------------------------------------------------
# Mutation — only reached past every refusal above, and skipped on the
# release-already-empty no-op (SKIP_MUTATION, issue #321).
# ---------------------------------------------------------------------------
if [ "$SKIP_MUTATION" -eq 0 ]; then
  # shellcheck disable=SC2016 # single-quoted GraphQL document — its $vars are server-side, resolved by -F, not shell expansion
  gh api graphql -f query='
    mutation($project:ID!,$item:ID!,$field:ID!,$value:String!){
      updateProjectV2ItemFieldValue(input:{
        projectId:$project itemId:$item fieldId:$field value:{ text:$value }
      }){ projectV2Item{ id } }
    }' -F project="$PROJECT_ID" -F item="$ITEM_ID" -F field="$FIELD_ID" -F value="$NEW_VALUE" \
    >"$WORK/mutate.out" 2>"$WORK/mutate.err" \
    || die "GraphQL mutation for #$ITEM failed: $(cat "$WORK/mutate.err")"
fi

APPLIED=true
[ "$SKIP_MUTATION" -eq 0 ] || APPLIED=false
# Issue #638: SUPERSEDED_ID is board-derived free text (parsed from the
# existing 'Claimed by' value — a hand-edited or corrupted claim id could
# contain a double quote) and MUST NEVER be spliced into a JSON literal and
# handed to --argjson: a value like 'a"b' there is malformed JSON, and jq
# exits 2 on it, which collides with argerr's exit 2 (documented as
# "argument error, always pre-mutation") on a call that runs AFTER the
# mutation above has already landed. --arg takes the raw string as jq's own
# string type instead, so no value of SUPERSEDED_ID can make either jq call
# below fail on that account; HAS_SUPERSEDED (an internal true/false, never
# board-derived) selects null vs the string inside the filter. Every jq
# call below is additionally guarded with `|| die` so that ANY unexpected
# post-mutation failure (this one included) maps to the contracted exit 1
# rather than leaking jq's own uncontracted status.
RESULT=$(jq -n --argjson item "$ITEM" --arg action "$VERB" --arg before "$CURRENT" --arg after "$NEW_VALUE" \
  --arg superseded_id "$SUPERSEDED_ID" --argjson has_superseded "$HAS_SUPERSEDED" --argjson applied "$APPLIED" \
  '{item:$item, field:"Claimed by", action:$action, before:$before, after:$after,
    superseded:(if $has_superseded then $superseded_id else null end), applied:$applied}') \
  || die "building the result JSON for #$ITEM failed after the mutation had already landed"
printf '%s\n' "$RESULT"

if [ "$LOG_EVENT" = "claim-stamp" ]; then
  LOG_LINE=$(jq -nc --arg ts "$LOG_TS" --arg claim "$ID" --argjson issue "$ITEM" \
    '{ts:$ts, event:"claim-stamp", claim:$claim, issue:$issue}') \
    || die "building the claim-stamp log line for #$ITEM failed after the mutation had already landed"
else
  LOG_LINE=$(jq -nc --arg ts "$LOG_TS" --arg claim "$ID" --arg action "$VERB" --argjson item "$ITEM" \
    --arg superseded_id "$SUPERSEDED_ID" --argjson has_superseded "$HAS_SUPERSEDED" \
    '{ts:$ts, event:"claim", claim:$claim, action:$action, item:$item,
      superseded:(if $has_superseded then $superseded_id else null end)}') \
    || die "building the claim log line for #$ITEM failed after the mutation had already landed"
fi
# The board write above has already landed and its JSON is already on
# stdout. A failure to append the session-log line is therefore NOT a claim
# failure, and must never be reported as one: under `set -e` an unwritable
# --log path used to abort here non-zero with the claim written, which a
# caller reading exit codes (home-deferred.sh does) took as "nothing was
# written" and so never released. Warn loudly, echo the line so it is not
# lost, and exit 4 — its own code, distinct from 1/2/3 (issue #262 round 2,
# F1).
LOG_RC=0
if [ -n "$LOG_PATH" ]; then
  { mkdir -p "$(dirname "$LOG_PATH")" && printf '%s\n' "$LOG_LINE" >> "$LOG_PATH"; } 2>"$WORK/log.err" || LOG_RC=$?
  if [ "$LOG_RC" -ne 0 ]; then
    echo "stamp-claim: WARNING — $VERB on #$ITEM SUCCEEDED (the JSON on stdout is authoritative, the board WAS written) but its session-log line could not be appended to $LOG_PATH: $(cat "$WORK/log.err" 2>/dev/null) — the line follows on stderr so it is not lost; exiting 4, which is NOT a claim failure" >&2
    printf '%s\n' "$LOG_LINE" >&2
  fi
else
  printf '%s\n' "$LOG_LINE" >&2
fi
[ "$LOG_RC" -eq 0 ] || exit 4
