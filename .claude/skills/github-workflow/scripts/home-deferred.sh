#!/usr/bin/env bash
# home-deferred.sh — apply the orchestrator's triage decision records
# idempotently. The orchestrator decides; this script only mutates. One
# decision record per line on stdin:
#   {"issue":N, "milestone":"<title>", "status":"<Status option name>",
#    "priority":"<high|medium|low>"?, "severity":"<critical|major|minor>"?,
#    "blocked_by":[N,...]?, "labels":["...",...]?}
# `priority`/`severity` may instead (or also) appear already-prefixed inside
# `labels` (e.g. "priority:high") — both spellings are accepted and folded
# together before the gate below is evaluated.
#
# Park records (epic #798 / #799 / #801) — a SEPARATE shape and a separate
# path, distinguished by `"status":"park"` (a keyword, never a board Status
# option name):
#   {"issue":N, "status":"park", "unit":"<unit>",
#    "milestone":"<title>"?, "priority":"<...>"?, "severity":"<...>"?,
#    "labels":["...",...]?}
# `unit` is REQUIRED for a park record and is checked BEFORE any `gh`/
# GraphQL call — a park record with no `unit` is REJECTED outright, same as
# the no-`parent` rule below. There is NO `wake` field: the comment's
# `Wake:` line is a fixed literal, emitted verbatim on every park record
# (maintenance.md § 1 step 6 — all three triggers apply to every parked
# item, so a per-item value would be false about its own item).
# `milestone` is optional here (unlike the non-park path, where
# it is required) because a parked item is normally already homed to its
# milestone — passed only to correct a record that is not. The completeness
# gate below (exactly one `priority:*`, plus `severity:*` for a `bug`) still
# applies to a park record, so a later promotion out of park finds complete
# labels. Mutations, in this fixed order (maintenance.md §1 "Park
# mechanics"): (1) milestone (if given) and labels — the record's own
# `labels`, the resolved priority/severity label, and `parked` — so a
# promoted item is already homed; (2) the two-line `Unit:`/`Wake:` comment;
# (3) close with reason "not planned"; (4) delete the project item
# (GraphQL `deleteProjectV2Item`) — an issue already off the board needs no
# delete. Every one of the four is independently idempotent (no-op, echoed,
# when the target state already holds), so a park record run twice over an
# already-parked issue makes zero mutations. The comment's no-op check
# compares the stored body to the built one with trailing whitespace
# stripped from BOTH sides, not byte-exact: a body posted through the API
# comes back with a trailing newline this script's `printf` never emits, so
# a byte-exact check would re-post over every hand-parked issue (#856).
# No project item is created for a park record and no claim is taken for
# it: a parked item is always already on the board with its per-item claim already released (the drain
# releases claims at step 10, before parking), so neither the
# ensure-project-item nor the claim step below applies to this path.
#
# Usage: home-deferred.sh [--repo owner/name] [--log <path>] [--readd]
#                          [--status <name>] [--work-tracking <path>]
#                          [--claim <id>] < decisions.jsonl
#
# Completeness gate — BEFORE any `gh`/GraphQL call for that record, no
# exceptions: exactly one `priority:*` label (from `.priority` or `.labels`),
# and, for a record whose type label is `bug` (i.e. "bug" appears in
# `.labels`), exactly one `severity:*` label (from `.severity` or `.labels`).
# A record that fails the gate is echoed to stderr naming the missing/
# ambiguous field, no call is made for it, and the run continues with the
# rest of stdin; the script's own exit code is non-zero at the end if any
# record was rejected this way. This is the maintenance.md §1 gate,
# mechanised: the dispatch pick order (orchestration.md "The loop, per
# issue" step 1) reads, in order, `blocked by` chain position, severity,
# `priority:*`, then age — an item with no `priority:*` has no place in
# that order, and a bug with no `severity:*` breaks the order at its
# severity key too, so leaving either unset defeats ordering for everything
# behind it, not just the priority half.
#
# No parent, ever. Deferred items are homed by milestone, never re-parented
# under an epic (the homing ruling) — a decision record therefore has no
# `parent` field by design. A record carrying one is refused outright (same
# gate, same "before any call" rule, same continue-the-run behavior) rather
# than silently ignored, so a caller that still thinks in sub-issue terms
# finds out immediately instead of the field being quietly dropped.
#
# Ordering — board row, then claim, then everything else. A claim LIVES ON
# THE BOARD: `stamp-claim.sh` writes the `Claimed by` project field, which
# has nowhere to be written until the issue has a project item. So for every
# record this script, in this order:
#   1. ensures the project item exists (creating it when missing — that
#      creation IS the idempotent `project_item:added` step below, not an
#      extra call), then
#   2. takes the per-item claim, then
#   3. applies milestone, labels, `blocked by` links and Status.
# Any other order cannot home an off-board issue at all — which is the whole
# point of the script and the entire input population of `--readd` (whose
# input is `board-audit.sh`'s `missing_board_items`). Step 1 therefore runs
# unclaimed, by necessity; it is a single idempotent create of an empty
# board row that carries no triage decision, so two sessions racing it at
# worst both see "already exists". If the claim is then refused, the record
# is skipped with the board row already added — that addition is echoed and
# reported in the record's summary rather than pretended away.
#
# Per-item claim: step 2 calls `stamp-claim.sh take --item <issue> --id
# <claim>` (claim id from --claim, or the HOME_DEFERRED_CLAIM environment
# variable — one of the two is required). Its outcomes are distinguished by
# EXIT CODE, never by matching its prose:
#   0 — claimed (the field was empty or stale), or the claim was already
#       mine and live (stamp-claim's own idempotent no-op). Proceed.
#   3 — business-rule refusal: a live claim held by someone else. The record
#       is SKIPPED with the reason on stderr, the run continues, and the
#       run's exit code is NOT flipped — a concurrent session is a normal
#       outcome, not a defect in the input.
#   4 — the take WROTE the claim but could not append its own session-log
#       line. The board is correct, the audit trail is not: the record is
#       REJECTED, the claim is handed back (below), and the exit code flips.
#   anything else — a hard stamp-claim failure (GraphQL error, malformed
#       claim value, unparseable timestamp, timeline GET failure). The
#       record is REJECTED with the error on stderr and the run's exit code
#       IS non-zero. A whole drain must never report success on an
#       infrastructure failure.
# On EVERY non-refusal failure (4 or anything else), a non-zero exit does
# not prove nothing was written — stamp-claim mutates before it decides its
# exit code — so this script reads `Claimed by` back (one GET) and RELEASES
# it when it holds our own id, per #350 AC2. If that read itself fails, the
# item is named on stderr as possibly still held, which is the AC's other
# permitted shape. Either way the run continues with the next record.
#
# Per-record failure isolation (issue #350): a `gh` failure while applying
# one record does not abort the batch. The record's error is echoed as
# FAILED, the claim that record took is released (`stamp-claim.sh release`)
# so the item is not stranded under a claim nobody is working, the run
# continues with the next record, and the final exit code is non-zero. A
# record that fails partway keeps whatever mutations already landed — each
# is individually idempotent, so re-running the record completes it.
#
# Mutations, each idempotent (no-op, echoed, when the target state already
# holds):
#   - milestone:  `gh issue edit --milestone`. No-op if the issue's current
#     milestone title already equals the record's.
#   - labels:     `gh issue edit --add-label` for whichever of the record's
#     labels (plus the resolved priority/severity label) the issue does not
#     already carry, in one call. No-op (no call at all) if every label is
#     already present.
#   - blocked by: the dependencies API (`.../dependencies/blocked_by`, GET
#     then POST `-F issue_id=<id>`), one POST per blocker the issue is not
#     already linked to. The payload is the blocker's numeric database `id`
#     (from the REST issue object), NOT its `node_id`, and it is sent with
#     `-F` so `gh` types it as a JSON integer — the API rejects a string
#     (github-tools.md's canonical row). No-op per blocker already linked.
#   - project item + Status: a project item is created for the issue
#     (GraphQL `addProjectV2ItemById`) if none exists yet — this is step 1
#     of the ordering above, before the claim — and its Status
#     single-select field is set to the record's `status`, after the claim,
#     if it does not already read that value. No-op on the Status set alone
#     when an existing item's Status already matches.
# Every change AND every no-op is echoed to stderr; the applied changes for
# a record are additionally collected into one JSON summary line on stdout
# per record (`{issue, claim, applied:[...]}`) and, with `--log <path>`,
# into one `triage` session-log event per record that applied at least one
# mutation (the record's own fields plus `applied:[...]`) appended to that
# file — without --log the same event line goes to stderr instead of being
# silently dropped. A record rejected by the gate writes no summary and no
# triage line at all (nothing happened). A record skipped on a claim
# refusal, or failed mid-apply, writes both only if something actually
# landed — normally nothing, or just the board row from step 1: the schema
# line reports what happened, and a `applied:[]` line would report nothing.
#
# --readd: a remediation mode for what `board-audit.sh`'s
# `missing_board_items` reports — stdin is bare issue numbers, one per line,
# instead of decision-record JSON. Each number only gets the project-item +
# Status mutation above (ensure the item exists, then set Status to
# --status, which is required in this mode) — no milestone, label or
# dependency mutation, and no completeness gate (there is no record to
# gate). The per-item claim still applies, and the same board-row-then-claim
# ordering does too: since every input here is by definition off the board,
# any other order would refuse every line it was given.
#
# Board/field ids (Project, and every "Status: <Name>" option id) are parsed
# from docs/process/work-tracking.md's ids table (default path, overridable
# with --work-tracking) — never hard-coded. No repository- or owner-specific
# noun appears in this script; the target repo comes from --repo or, failing
# that, `gh repo view` on the current checkout.
#
# Exit codes: 2 = argument error, or a failure before the first record is
# read (unresolvable repo, missing work-tracking doc). 1 = at least one
# record was REJECTED (completeness/no-parent gate, or a hard stamp-claim
# failure — the category printed per record and the category counted in the
# summary are the same word), FAILED (a `gh` call failed while
# applying it), or LOGFAIL (a `--log` line could not be written; the
# mutations it describes did land) — grep the stderr for "REJECTED",
# "FAILED" and "LOGFAIL" to find which. 0 = every record either
# applied or was skipped on a live foreign claim; a per-item claim skip does
# not by itself flip the exit code non-zero — it is a normal concurrent-
# session outcome, not a defect in the input. The batch always runs to the
# end of stdin: no single record's failure aborts the rest (issue #350).
set -euo pipefail

die(){ echo "home-deferred: $*" >&2; exit 1; }
argerr(){ echo "home-deferred: $*" >&2; exit 2; }

REPO=""; LOG_PATH=""; READD=0; STATUS_ARG=""; WORK_TRACKING=""; CLAIM="${HOME_DEFERRED_CLAIM:-}"
STAMP_CLAIM="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/stamp-claim.sh"
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="${2:?--repo needs a value}"; shift 2 ;;
    --log) LOG_PATH="${2:?--log needs a value}"; shift 2 ;;
    --readd) READD=1; shift ;;
    --status) STATUS_ARG="${2:?--status needs a value}"; shift 2 ;;
    --work-tracking) WORK_TRACKING="${2:?--work-tracking needs a value}"; shift 2 ;;
    --claim) CLAIM="${2:?--claim needs a value}"; shift 2 ;;
    -*) argerr "unknown flag $1" ;;
    *) argerr "unexpected extra argument $1" ;;
  esac
done
[ -n "$CLAIM" ] || argerr "a claim id is required — pass --claim <id> or set HOME_DEFERRED_CLAIM"
[ "$READD" -eq 0 ] || [ -n "$STATUS_ARG" ] || argerr "--readd requires --status <name>"

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
# Board/field ids: parsed from the "| Field | Id |" / "| Status: <Name> |
# Id |" rows, never hard-coded. A row's id is the sole backtick-quoted token
# in that exact-label row.
# ---------------------------------------------------------------------------
parse_id(){ # parse_id <exact-label> <file>
  # sed's `-n ... p` (not `grep -oP`, a PCRE extension BSD/macOS grep lacks)
  # prints the sole backtick-quoted token ONLY on a line that has one — no
  # match means no output — portable to any POSIX sed, not just Linux's GNU
  # grep.
  local label="$1" file="$2" val
  # shellcheck disable=SC2016 # single-quoted on purpose - the sed backreference is not meant to expand
  val=$(grep -E "^\| ${label} \|" "$file" | head -1 | sed -n -E 's/^.*`([^`]+)`.*$/\1/p')
  [ -n "$val" ] || die "could not find '| $label |' with a backtick-quoted id in $file"
  printf '%s' "$val"
}
PROJECT_ID=$(parse_id "Project" "$WORK_TRACKING")
STATUS_FIELD_ID=$(parse_id "Status" "$WORK_TRACKING")

WORK="$(mktemp -d "${TMPDIR:-/tmp}/home-deferred.XXXXXX")"
# shellcheck disable=SC2329 # invoked indirectly via `trap cleanup EXIT` on the next line; shellcheck's call-graph analysis loses that indirection in this file's size
cleanup(){ rm -rf "$WORK"; }
trap cleanup EXIT

REJECTED=0
FAILED=0
# issue #743: session-log `ts` must be exactly YYYY-MM-DDTHH:MM:SSZ
# (formats/session-log.md) — both call sites below feed a `event:"triage"`
# session-log line through emit_log, so unlike stamp-claim.sh (which reused
# one NOW_TS for both a minute-precision board field and the log) there is
# no board-facing consumer here to protect: NOW_TS is safe to fix in place
# at second precision.
NOW_TS(){ date -u +%FT%TZ; }

# The park comment's `Wake:` line, verbatim and unconditional. Fixed literal
# by design (references/maintenance.md § 1 step 6, and the #801 scope note):
# all three triggers apply to every parked item, so there is nothing
# per-item to select and no record field overrides it.
PARK_WAKE_LINE="second sighting | unit batch | milestone review"

# A --log path that cannot be written is a local filesystem problem, not a
# board one: it must not abort a drain mid-batch under `set -e` (issue #350's
# isolation rule) and must not be silent either. Warn, echo the line so it is
# not lost, and count it — LOG_FAILED flips the run's exit code in finish().
LOG_FAILED=0
emit_log(){ # emit_log <event-json-line>
  local rc=0
  if [ -n "$LOG_PATH" ]; then
    { mkdir -p "$(dirname "$LOG_PATH")" && printf '%s\n' "$1" >> "$LOG_PATH"; } 2>"$WORK/log.err" || rc=$?
    if [ "$rc" -ne 0 ]; then
      LOG_FAILED=$((LOG_FAILED+1))
      echo "home-deferred: LOGFAIL — could not append the session-log line to $LOG_PATH: $(cat "$WORK/log.err" 2>/dev/null) — the line follows on stderr; the mutations it describes DID land" >&2
      printf '%s\n' "$1" >&2
    fi
  else
    printf '%s\n' "$1" >&2
  fi
}

# ---------------------------------------------------------------------------
# Per-item claim. Outcomes are read from stamp-claim.sh's EXIT CODE — 0
# claimed (or already mine and live, its own idempotent no-op), 3 a
# business-rule refusal (live foreign claim), anything else a hard failure —
# never by matching its stderr prose. A cross-script contract carried in a
# message string silently degrades the moment either side is reworded.
# ---------------------------------------------------------------------------
CLAIM_RC=0
take_claim(){ # take_claim <issue> — sets CLAIM_RC; returns it
  local issue="$1" superseded logflag=()
  [ -z "$LOG_PATH" ] || logflag=(--log "$LOG_PATH")
  CLAIM_RC=0
  "$STAMP_CLAIM" take --item "$issue" --id "$CLAIM" --repo "$REPO" \
    --work-tracking "$WORK_TRACKING" "${logflag[@]}" \
    >"$WORK/claim_$issue.out" 2>"$WORK/claim_$issue.err" || CLAIM_RC=$?
  # A successful take over a STALE foreign claim supersedes it, and
  # claims.md requires an event comment on the epic naming the superseded
  # claim — stamp-claim.sh deliberately delegates that announcement to its
  # caller. Surface it here on the success path (both its own reminder on
  # stderr and the `superseded` field of its JSON), or a silent takeover is
  # exactly what the announcement rule exists to prevent.
  if [ "$CLAIM_RC" -eq 0 ]; then
    superseded=$(jq -r '.superseded // empty' "$WORK/claim_$issue.out" 2>/dev/null || true)
    if [ -n "$superseded" ] && [ "$superseded" != "null" ]; then
      echo "home-deferred: #$issue claim SUPERSEDED '$superseded' — claims.md requires an event comment on the epic naming the superseded claim and its timestamp; this script does not post it, the orchestrator must." >&2
      grep -F 'stamp-claim: reminder' "$WORK/claim_$issue.err" >&2 || true
    fi
  fi
  return "$CLAIM_RC"
}

# reconcile_claim <issue> — called ONLY after a non-refusal failure from
# `stamp-claim.sh take`. A non-zero exit from the take does NOT prove that
# nothing was written: the mutation lands before the session-log append and
# before the exit code is decided, so a take can fail (exit 4 on an
# unwritable --log, or any future failure past the mutation) with our claim
# already on the board (issue #262 round 2, F1). Read `Claimed by` back and
# release it if it now holds OUR id — #350 AC2 requires that an item claimed
# by an aborted step is released, or named as still held. Both outcomes are
# echoed; the read itself failing names the item, which is the AC's other
# permitted shape.
reconcile_claim(){ # reconcile_claim <issue>
  local issue="$1" nodes held held_id
  # shellcheck disable=SC2016 # single-quoted GraphQL document — its $vars are server-side, resolved by -F
  nodes=$(gh api graphql -f query='
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
    }' -F owner="$OWNER" -F name="$NAME" -F number="$issue" \
    --jq '.data.repository.issue.projectItems.nodes' 2>"$WORK/reconcile_$issue.err") \
    || { echo "home-deferred: #$issue — could not read 'Claimed by' back after the failed take ($(cat "$WORK/reconcile_$issue.err")); if the take wrote it, #$issue IS STILL HELD by '$CLAIM' until it goes stale — check it by hand" >&2; return 0; }
  held=$(jq -r --arg p "$PROJECT_ID" '.[]|select(.project.id==$p)|(.fieldValueByName.text // "")' <<<"$nodes" | head -1)
  if [ -z "$held" ]; then
    echo "home-deferred: #$issue — 'Claimed by' is empty after the failed take: nothing was written, nothing to release" >&2
    return 0
  fi
  held_id=$(printf '%s' "$held" | sed -E 's/^([^[:space:]]+) @ .*$/\1/')
  if [ "$held_id" = "$CLAIM" ]; then
    echo "home-deferred: #$issue — the failed take HAD already written our claim ('$held'); releasing it so the item is not stranded" >&2
    release_claim "$issue"
  else
    echo "home-deferred: #$issue — 'Claimed by' holds '$held', not ours: nothing of ours to release" >&2
  fi
}

# claim_gate <issue> — 0 to proceed; 1 to stop with this record, having
# already echoed why. CLAIM_OUTCOME distinguishes the two stop kinds:
# "skipped" (refusal, exit code unchanged) and "failed" (hard, counts).
CLAIM_OUTCOME=""
claim_gate(){ # claim_gate <issue>
  local issue="$1"
  if take_claim "$issue"; then CLAIM_OUTCOME="ok"; return 0; fi
  if [ "$CLAIM_RC" -eq 3 ]; then
    CLAIM_OUTCOME="skipped"
    echo "home-deferred: SKIPPED #$issue — claim refused by stamp-claim (exit 3): $(cat "$WORK/claim_$issue.err")" >&2
  elif [ "$CLAIM_RC" -eq 4 ]; then
    # stamp-claim exit 4: the claim WAS written, only its session-log append
    # failed. The board is fine; the audit trail is not, so the record does
    # not proceed and the run's exit code flips — but the claim must be
    # handed back, not left held on a record we are about to abandon.
    CLAIM_OUTCOME="failed"
    echo "home-deferred: REJECTED #$issue — stamp-claim take WROTE the claim but could not write its session-log line (exit 4): $(cat "$WORK/claim_$issue.err")" >&2
    reconcile_claim "$issue"
  else
    CLAIM_OUTCOME="failed"
    echo "home-deferred: REJECTED #$issue — stamp-claim take failed hard (exit $CLAIM_RC), this is NOT a claim refusal: $(cat "$WORK/claim_$issue.err")" >&2
    reconcile_claim "$issue"
  fi
  return 1
}

# release_claim <issue> — hand back the claim this run took, so a record
# that failed mid-apply does not strand the item under a claim nobody is
# working (issue #350). Best effort: a failure to release is itself only
# echoed, never fatal — the record's own failure is already recorded.
release_claim(){ # release_claim <issue>
  local issue="$1" rc=0
  "$STAMP_CLAIM" release --item "$issue" --id "$CLAIM" --repo "$REPO" \
    --work-tracking "$WORK_TRACKING" >"$WORK/rel_$issue.out" 2>"$WORK/rel_$issue.err" || rc=$?
  if [ "$rc" -eq 0 ]; then
    echo "home-deferred: #$issue claim released after the failure above" >&2
  else
    echo "home-deferred: #$issue claim could NOT be released (stamp-claim exit $rc) — it stays held until it goes stale: $(cat "$WORK/rel_$issue.err")" >&2
  fi
}

# ---------------------------------------------------------------------------
# Status option ids come from the work-tracking table. Unknown name is a
# per-record failure (return 1), not a whole-run abort: one bad `status` in
# a 91-record drain must not strand the other 90.
# ---------------------------------------------------------------------------
status_option_id(){ # status_option_id <name> -> option id on stdout
  # sed's `-n ... p` (not `grep -oP`, a PCRE extension BSD/macOS grep lacks)
  # prints the sole backtick-quoted token ONLY on a line that has one —
  # portable to any POSIX sed, not just Linux's GNU grep.
  local name="$1" val
  # shellcheck disable=SC2016 # single-quoted on purpose - the sed backreference is not meant to expand
  val=$(grep -E "^\| Status: ${name} \|" "$WORK_TRACKING" | head -1 | sed -n -E 's/^.*`([^`]+)`.*$/\1/p')
  [ -n "$val" ] || { echo "home-deferred: unknown Status option '$name' — no '| Status: $name |' row with a backtick-quoted id in $WORK_TRACKING" >&2; return 1; }
  printf '%s' "$val"
}

# ---------------------------------------------------------------------------
# Step 1 of the ordering: ensure a project item exists for <issue>, creating
# it when missing. Runs BEFORE the claim, because the claim is a field on
# this very row. Sets ITEM_ID and ITEM_STATUS; appends "project_item:added"
# to APPLIED when it created the row. Returns 1 (reason echoed) on a hard
# `gh` failure.
# ---------------------------------------------------------------------------
ITEM_ID=""; ITEM_STATUS=""
ensure_project_item(){ # ensure_project_item <issue>
  local issue="$1" nodes issue_node_id
  ITEM_ID=""; ITEM_STATUS=""
  # shellcheck disable=SC2016 # single-quoted GraphQL document — its $vars are server-side, resolved by -F, not shell expansion
  nodes=$(gh api graphql -f query='
    query($owner:String!,$name:String!,$number:Int!){
      repository(owner:$owner,name:$name){
        issue(number:$number){
          id
          projectItems(first:20){
            nodes{
              id
              project{ id }
              fieldValueByName(name:"Status"){
                ... on ProjectV2ItemFieldSingleSelectValue{ name }
              }
            }
          }
        }
      }
    }' -F owner="$OWNER" -F name="$NAME" -F number="$issue" \
    --jq '.data.repository.issue' 2>"$WORK/item_read_$issue.err") \
    || { echo "home-deferred: FAILED #$issue — GraphQL project-item read failed: $(cat "$WORK/item_read_$issue.err")" >&2; return 1; }
  issue_node_id=$(jq -r '.id' <<<"$nodes")
  ITEM_ID=$(jq -r --arg p "$PROJECT_ID" '.projectItems.nodes[]|select(.project.id==$p)|.id' <<<"$nodes" | head -1)
  ITEM_STATUS=$(jq -r --arg p "$PROJECT_ID" '.projectItems.nodes[]|select(.project.id==$p)|(.fieldValueByName.name // "")' <<<"$nodes" | head -1)

  if [ -z "$ITEM_ID" ]; then
    # shellcheck disable=SC2016 # single-quoted GraphQL document — its $vars are server-side, resolved by -F, not shell expansion
    ITEM_ID=$(gh api graphql -f query='
      mutation($project:ID!,$content:ID!){
        addProjectV2ItemById(input:{ projectId:$project contentId:$content }){ item{ id } }
      }' -F project="$PROJECT_ID" -F content="$issue_node_id" \
      --jq '.data.addProjectV2ItemById.item.id' 2>"$WORK/item_add_$issue.err") \
      || { echo "home-deferred: FAILED #$issue — GraphQL addProjectV2ItemById failed: $(cat "$WORK/item_add_$issue.err")" >&2; return 1; }
    APPLIED+=("project_item:added")
    echo "home-deferred: #$issue project item added" >&2
    ITEM_STATUS=""
  else
    echo "home-deferred: #$issue project item already exists — no-op" >&2
  fi
}

# ---------------------------------------------------------------------------
# Step 3 (last): set the item's Status if it does not already read the
# target. Uses ITEM_ID/ITEM_STATUS from ensure_project_item. Returns 1
# (reason echoed) on a hard `gh` failure or an unknown status name.
# ---------------------------------------------------------------------------
set_status(){ # set_status <issue> <target-status-name>
  local issue="$1" target="$2" option_id
  if [ "$ITEM_STATUS" = "$target" ]; then
    echo "home-deferred: #$issue Status already '$target' — no-op" >&2
    return 0
  fi
  option_id=$(status_option_id "$target") \
    || { echo "home-deferred: FAILED #$issue — cannot resolve Status option '$target'" >&2; return 1; }
  # shellcheck disable=SC2016 # single-quoted GraphQL document — its $vars are server-side, resolved by -F, not shell expansion
  gh api graphql -f query='
    mutation($project:ID!,$item:ID!,$field:ID!,$option:String!){
      updateProjectV2ItemFieldValue(input:{
        projectId:$project itemId:$item fieldId:$field value:{ singleSelectOptionId:$option }
      }){ projectV2Item{ id } }
    }' -F project="$PROJECT_ID" -F item="$ITEM_ID" -F field="$STATUS_FIELD_ID" -F option="$option_id" \
    >"$WORK/status_$issue.out" 2>"$WORK/status_$issue.err" \
    || { echo "home-deferred: FAILED #$issue — GraphQL Status mutation failed: $(cat "$WORK/status_$issue.err")" >&2; return 1; }
  APPLIED+=("status:$target")
  echo "home-deferred: #$issue Status set to '$target'" >&2
}

# ---------------------------------------------------------------------------
# Summary emitters, shared by both modes. A record that applied nothing
# still prints its stdout summary (so a caller sees one line per record it
# handled) but writes no triage log event.
# ---------------------------------------------------------------------------
applied_json(){ printf '%s\n' "${APPLIED[@]:-}" | jq -R -s -c 'split("\n")|map(select(length>0))'; }

# ---------------------------------------------------------------------------
# check_completeness — the gate shared by the normal path and the park path:
# exactly one `priority:*` (from .priority or .labels), and, for a record
# whose `.labels` names `bug`, exactly one `severity:*` too. Reads REC/ISSUE
# globals, sets PRIORITY_LABEL/SEVERITY_LABEL, echoes REJECTED and returns 1
# on failure — the caller counts REJECTED and continues with the next line.
# ---------------------------------------------------------------------------
check_completeness(){
  PRIORITY_LABEL=$(jq -r '
    ((.priority // "") | if . == "" then [] elif startswith("priority:") then [.] else ["priority:" + .] end) as $p
    | ((.labels // []) | map(select(startswith("priority:")))) as $l
    | ($p + $l) | unique | .[]
  ' <<<"$REC" 2>/dev/null | sort -u)
  local n_priority
  n_priority=$(printf '%s\n' "$PRIORITY_LABEL" | grep -c . || true)
  if [ "$n_priority" -ne 1 ]; then
    echo "home-deferred: REJECTED #$ISSUE — completeness gate: expected exactly one priority:*, found $n_priority (${PRIORITY_LABEL:-none})" >&2
    return 1
  fi

  local is_bug
  is_bug=$(jq -r '(.labels // []) | index("bug") != null' <<<"$REC")
  SEVERITY_LABEL=""
  if [ "$is_bug" = "true" ]; then
    SEVERITY_LABEL=$(jq -r '
      ((.severity // "") | if . == "" then [] elif startswith("severity:") then [.] else ["severity:" + .] end) as $s
      | ((.labels // []) | map(select(startswith("severity:")))) as $l
      | ($s + $l) | unique | .[]
    ' <<<"$REC" 2>/dev/null | sort -u)
    local n_severity
    n_severity=$(printf '%s\n' "$SEVERITY_LABEL" | grep -c . || true)
    if [ "$n_severity" -ne 1 ]; then
      echo "home-deferred: REJECTED #$ISSUE — completeness gate: bug record expected exactly one severity:*, found $n_severity (${SEVERITY_LABEL:-none})" >&2
      return 1
    fi
  fi
  return 0
}

# ---------------------------------------------------------------------------
# apply_park — the four park mechanics (maintenance.md §1 "Park mechanics"),
# in fixed order, each independently idempotent. Reads ISSUE/REC/
# PRIORITY_LABEL/SEVERITY_LABEL and appends to APPLIED. Returns 1 (echoed as
# FAILED) on the first `gh`/GraphQL failure — same per-record isolation as
# apply_record.
# ---------------------------------------------------------------------------
apply_park(){
  local unit comment_body
  local rec_milestone current_milestone
  local final_labels current_labels missing_labels n_missing add_csv l
  local existing_comments already_commented
  local state_json cur_state cur_reason
  local nodes item_id

  unit=$(jq -r '.unit // empty' <<<"$REC")
  # The `Wake:` line is a FIXED LITERAL, never per-item (maintenance.md § 1
  # step 6): all three triggers apply to every parked item, so any per-item
  # value would be false about the item it is written on.
  comment_body=$(printf 'Unit: %s\nWake: %s' "$unit" "$PARK_WAKE_LINE")

  # -- (1a) Milestone, only if the record names one. --
  rec_milestone=$(jq -r '.milestone // empty' <<<"$REC")
  if [ -n "$rec_milestone" ]; then
    current_milestone=$(gh issue view "$ISSUE" --repo "$REPO" --json milestone --jq '.milestone.title // ""' 2>"$WORK/park_ms_read_$ISSUE.err") \
      || { echo "home-deferred: FAILED #$ISSUE — reading current milestone failed: $(cat "$WORK/park_ms_read_$ISSUE.err")" >&2; return 1; }
    if [ "$current_milestone" = "$rec_milestone" ]; then
      echo "home-deferred: #$ISSUE milestone already '$rec_milestone' — no-op" >&2
    else
      gh issue edit "$ISSUE" --repo "$REPO" --milestone "$rec_milestone" >"$WORK/park_ms_$ISSUE.out" 2>"$WORK/park_ms_$ISSUE.err" \
        || { echo "home-deferred: FAILED #$ISSUE — setting milestone failed: $(cat "$WORK/park_ms_$ISSUE.err")" >&2; return 1; }
      APPLIED+=("milestone:$rec_milestone")
      echo "home-deferred: #$ISSUE milestone set to '$rec_milestone'" >&2
    fi
  fi

  # -- (1b) Labels: record's .labels, resolved priority/severity, and 'parked'. --
  final_labels=$(jq -c --arg p "$PRIORITY_LABEL" --arg s "$SEVERITY_LABEL" \
    '((.labels // []) + [$p] + (if $s != "" then [$s] else [] end) + ["parked"]) | map(select(. != "")) | unique' <<<"$REC")
  current_labels=$(gh issue view "$ISSUE" --repo "$REPO" --json labels --jq '[.labels[].name]' 2>"$WORK/park_lbl_read_$ISSUE.err") \
    || { echo "home-deferred: FAILED #$ISSUE — reading current labels failed: $(cat "$WORK/park_lbl_read_$ISSUE.err")" >&2; return 1; }
  missing_labels=$(jq -nc --argjson final "$final_labels" --argjson current "$current_labels" '$final - $current')
  n_missing=$(jq 'length' <<<"$missing_labels")
  if [ "$n_missing" -eq 0 ]; then
    echo "home-deferred: #$ISSUE labels already present ($(jq -r 'join(", ")' <<<"$final_labels")) — no-op" >&2
  else
    add_csv=$(jq -r 'join(",")' <<<"$missing_labels")
    gh issue edit "$ISSUE" --repo "$REPO" --add-label "$add_csv" >"$WORK/park_lbl_$ISSUE.out" 2>"$WORK/park_lbl_$ISSUE.err" \
      || { echo "home-deferred: FAILED #$ISSUE — adding labels failed: $(cat "$WORK/park_lbl_$ISSUE.err")" >&2; return 1; }
    while IFS= read -r l; do
      [ -n "$l" ] || continue
      APPLIED+=("label:$l")
      echo "home-deferred: #$ISSUE label added: $l" >&2
    done < <(jq -r '.[]' <<<"$missing_labels")
  fi

  # -- (2) Comment: post only if this exact body is not already there. --
  existing_comments=$(gh issue view "$ISSUE" --repo "$REPO" --json comments --jq '[.comments[].body]' 2>"$WORK/park_cmt_read_$ISSUE.err") \
    || { echo "home-deferred: FAILED #$ISSUE — reading existing comments failed: $(cat "$WORK/park_cmt_read_$ISSUE.err")" >&2; return 1; }
  # Compare NORMALISED, not byte-exact: a body posted through the API is
  # stored with a trailing newline this script's `printf` does not emit, so
  # an exact match would re-post over every hand-parked issue (#856).
  already_commented=$(jq -r --arg b "$comment_body" \
    'def norm: sub("[[:space:]]+$"; ""); map(select(norm == ($b | norm))) | length > 0' <<<"$existing_comments")
  if [ "$already_commented" = "true" ]; then
    echo "home-deferred: #$ISSUE park comment already posted — no-op" >&2
  else
    gh issue comment "$ISSUE" --repo "$REPO" --body "$comment_body" >"$WORK/park_cmt_$ISSUE.out" 2>"$WORK/park_cmt_$ISSUE.err" \
      || { echo "home-deferred: FAILED #$ISSUE — posting the park comment failed: $(cat "$WORK/park_cmt_$ISSUE.err")" >&2; return 1; }
    APPLIED+=("comment:posted")
    echo "home-deferred: #$ISSUE park comment posted (unit: $unit)" >&2
  fi

  # -- (3) Close as not planned. --
  state_json=$(gh issue view "$ISSUE" --repo "$REPO" --json state,stateReason 2>"$WORK/park_state_read_$ISSUE.err") \
    || { echo "home-deferred: FAILED #$ISSUE — reading current state failed: $(cat "$WORK/park_state_read_$ISSUE.err")" >&2; return 1; }
  cur_state=$(jq -r '.state' <<<"$state_json")
  cur_reason=$(jq -r '.stateReason // ""' <<<"$state_json")
  if [ "$cur_state" = "CLOSED" ] && [ "$cur_reason" = "NOT_PLANNED" ]; then
    echo "home-deferred: #$ISSUE already closed not planned — no-op" >&2
  else
    gh issue close "$ISSUE" --repo "$REPO" --reason "not planned" >"$WORK/park_close_$ISSUE.out" 2>"$WORK/park_close_$ISSUE.err" \
      || { echo "home-deferred: FAILED #$ISSUE — closing as not planned failed: $(cat "$WORK/park_close_$ISSUE.err")" >&2; return 1; }
    APPLIED+=("closed:not_planned")
    echo "home-deferred: #$ISSUE closed as not planned" >&2
  fi

  # -- (4) Remove the project item, so a closed park never sits in Done. --
  # shellcheck disable=SC2016 # single-quoted GraphQL document — its $vars are server-side, resolved by -F, not shell expansion
  nodes=$(gh api graphql -f query='
    query($owner:String!,$name:String!,$number:Int!){
      repository(owner:$owner,name:$name){
        issue(number:$number){
          projectItems(first:10){ nodes{ id project{ id } } }
        }
      }
    }' -F owner="$OWNER" -F name="$NAME" -F number="$ISSUE" \
    --jq '.data.repository.issue.projectItems.nodes' 2>"$WORK/park_item_read_$ISSUE.err") \
    || { echo "home-deferred: FAILED #$ISSUE — GraphQL project-item read failed: $(cat "$WORK/park_item_read_$ISSUE.err")" >&2; return 1; }
  item_id=$(jq -r --arg p "$PROJECT_ID" '.[]|select(.project.id==$p)|.id' <<<"$nodes" | head -1)
  if [ -z "$item_id" ]; then
    echo "home-deferred: #$ISSUE already off the board — no-op" >&2
  else
    # shellcheck disable=SC2016 # single-quoted GraphQL document — its $vars are server-side, resolved by -F, not shell expansion
    gh api graphql -f query='
      mutation($project:ID!,$item:ID!){
        deleteProjectV2Item(input:{ projectId:$project itemId:$item }){ deletedItemId }
      }' -F project="$PROJECT_ID" -F item="$item_id" \
      >"$WORK/park_item_del_$ISSUE.out" 2>"$WORK/park_item_del_$ISSUE.err" \
      || { echo "home-deferred: FAILED #$ISSUE — GraphQL deleteProjectV2Item failed: $(cat "$WORK/park_item_del_$ISSUE.err")" >&2; return 1; }
    APPLIED+=("project_item:removed")
    echo "home-deferred: #$ISSUE project item removed" >&2
  fi
}

# ---------------------------------------------------------------------------
# apply_record — steps 3 of one decision record, in order: milestone,
# labels, `blocked by` links, Status. Reads the record globals set by the
# gate above (ISSUE, REC, MILESTONE, PRIORITY_LABEL, SEVERITY_LABEL,
# TARGET_STATUS) and appends to APPLIED. Returns 1 on the first `gh`
# failure, having echoed it as FAILED — the batch is never aborted for one
# record (issue #350); the caller releases the claim and continues.
# ---------------------------------------------------------------------------
apply_record(){
  local current_milestone final_labels current_labels missing_labels n_missing add_csv
  local blockers blocker blocker_id current_blocked_by l

  # -- Milestone. --
  current_milestone=$(gh issue view "$ISSUE" --repo "$REPO" --json milestone --jq '.milestone.title // ""' 2>"$WORK/ms_read_$ISSUE.err") \
    || { echo "home-deferred: FAILED #$ISSUE — reading current milestone failed: $(cat "$WORK/ms_read_$ISSUE.err")" >&2; return 1; }
  if [ "$current_milestone" = "$MILESTONE" ]; then
    echo "home-deferred: #$ISSUE milestone already '$MILESTONE' — no-op" >&2
  else
    gh issue edit "$ISSUE" --repo "$REPO" --milestone "$MILESTONE" >"$WORK/ms_$ISSUE.out" 2>"$WORK/ms_$ISSUE.err" \
      || { echo "home-deferred: FAILED #$ISSUE — setting milestone failed: $(cat "$WORK/ms_$ISSUE.err")" >&2; return 1; }
    APPLIED+=("milestone:$MILESTONE")
    echo "home-deferred: #$ISSUE milestone set to '$MILESTONE'" >&2
  fi

  # -- Labels: record's .labels plus the one resolved priority/severity label. --
  final_labels=$(jq -c --arg p "$PRIORITY_LABEL" --arg s "$SEVERITY_LABEL" \
    '((.labels // []) + [$p] + (if $s != "" then [$s] else [] end)) | map(select(. != "")) | unique' <<<"$REC")
  current_labels=$(gh issue view "$ISSUE" --repo "$REPO" --json labels --jq '[.labels[].name]' 2>"$WORK/lbl_read_$ISSUE.err") \
    || { echo "home-deferred: FAILED #$ISSUE — reading current labels failed: $(cat "$WORK/lbl_read_$ISSUE.err")" >&2; return 1; }
  missing_labels=$(jq -nc --argjson final "$final_labels" --argjson current "$current_labels" '$final - $current')
  n_missing=$(jq 'length' <<<"$missing_labels")
  if [ "$n_missing" -eq 0 ]; then
    echo "home-deferred: #$ISSUE labels already present ($(jq -r 'join(", ")' <<<"$final_labels")) — no-op" >&2
  else
    add_csv=$(jq -r 'join(",")' <<<"$missing_labels")
    gh issue edit "$ISSUE" --repo "$REPO" --add-label "$add_csv" >"$WORK/lbl_$ISSUE.out" 2>"$WORK/lbl_$ISSUE.err" \
      || { echo "home-deferred: FAILED #$ISSUE — adding labels failed: $(cat "$WORK/lbl_$ISSUE.err")" >&2; return 1; }
    while IFS= read -r l; do
      [ -n "$l" ] || continue
      APPLIED+=("label:$l")
      echo "home-deferred: #$ISSUE label added: $l" >&2
    done < <(jq -r '.[]' <<<"$missing_labels")
  fi

  # -- blocked by: dependency links, one POST per blocker not yet linked. --
  blockers=$(jq -r '(.blocked_by // [])[]?' <<<"$REC")
  if [ -n "$blockers" ]; then
    current_blocked_by=$(gh api "repos/$REPO/issues/$ISSUE/dependencies/blocked_by" --jq '[.[].number]' 2>"$WORK/dep_read_$ISSUE.err") \
      || { echo "home-deferred: FAILED #$ISSUE — reading blocked_by failed: $(cat "$WORK/dep_read_$ISSUE.err")" >&2; return 1; }
    while IFS= read -r blocker; do
      [ -n "$blocker" ] || continue
      if jq -e --argjson b "$blocker" 'index($b) != null' <<<"$current_blocked_by" >/dev/null 2>&1; then
        echo "home-deferred: #$ISSUE already blocked by #$blocker — no-op" >&2
        continue
      fi
      # The dependencies API wants the blocker's numeric database `id` (not
      # its node_id), typed as a JSON integer — hence `-F`, per
      # github-tools.md's canonical row. `-f` would send it as a string.
      blocker_id=$(gh api "repos/$REPO/issues/$blocker" --jq .id 2>"$WORK/dep_node_$ISSUE.err") \
        || { echo "home-deferred: FAILED #$ISSUE — reading id for blocker #$blocker failed: $(cat "$WORK/dep_node_$ISSUE.err")" >&2; return 1; }
      gh api -X POST "repos/$REPO/issues/$ISSUE/dependencies/blocked_by" -F issue_id="$blocker_id" \
        >"$WORK/dep_add_$ISSUE.out" 2>"$WORK/dep_add_$ISSUE.err" \
        || { echo "home-deferred: FAILED #$ISSUE — linking blocked by #$blocker failed: $(cat "$WORK/dep_add_$ISSUE.err")" >&2; return 1; }
      APPLIED+=("blocked_by:$blocker")
      echo "home-deferred: #$ISSUE now blocked by #$blocker" >&2
    done <<<"$blockers"
  fi

  # -- Status (the board row itself was ensured before the claim). --
  set_status "$ISSUE" "$TARGET_STATUS" || return 1
}

# ---------------------------------------------------------------------------
# finish — one exit rule for both modes: rejected records and failed
# records both flip the exit code; claim skips do not.
# ---------------------------------------------------------------------------
finish(){
  [ "$REJECTED" -eq 0 ] || echo "home-deferred: $REJECTED record(s) rejected — see REJECTED lines above" >&2
  [ "$FAILED" -eq 0 ] || echo "home-deferred: $FAILED record(s) failed mid-apply — see FAILED lines above; each is individually re-runnable" >&2
  [ "$LOG_FAILED" -eq 0 ] || echo "home-deferred: $LOG_FAILED session-log line(s) could not be written — see LOGFAIL lines above; the mutations they describe DID land" >&2
  [ $((REJECTED + FAILED + LOG_FAILED)) -eq 0 ] || exit 1
  exit 0
}

# ---------------------------------------------------------------------------
# --readd mode: bare issue numbers on stdin, project item + Status only.
# ---------------------------------------------------------------------------
if [ "$READD" -eq 1 ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    line=$(printf '%s' "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    [ -n "$line" ] || continue
    case "$line" in
      *[!0-9]*) echo "home-deferred: REJECTED — --readd expects a bare issue number, got: $line" >&2; REJECTED=$((REJECTED+1)); continue ;;
    esac
    ISSUE="$line"
    APPLIED=()

    # Step 1 — the board row, before the claim (see the ordering note in the
    # header): every --readd input is by definition off the board.
    if ! ensure_project_item "$ISSUE"; then
      FAILED=$((FAILED+1)); continue
    fi

    # Step 2 — the claim.
    if ! claim_gate "$ISSUE"; then
      # claim_gate prints REJECTED for a hard failure, so count REJECTED —
      # the per-record line and finish()'s summary must name one category.
      [ "$CLAIM_OUTCOME" != "failed" ] || REJECTED=$((REJECTED+1))
      APPLIED_JSON=$(applied_json)
      [ "$(jq 'length' <<<"$APPLIED_JSON")" -eq 0 ] || \
        jq -nc --argjson issue "$ISSUE" --arg claim "$CLAIM" --argjson applied "$APPLIED_JSON" \
          '{issue:$issue, claim:$claim, applied:$applied}'
      continue
    fi

    # Step 3 — Status.
    if ! set_status "$ISSUE" "$STATUS_ARG"; then
      release_claim "$ISSUE"
      FAILED=$((FAILED+1)); continue
    fi

    APPLIED_JSON=$(applied_json)
    jq -nc --argjson issue "$ISSUE" --arg claim "$CLAIM" --argjson applied "$APPLIED_JSON" \
      '{issue:$issue, claim:$claim, applied:$applied}'
    if [ "$(jq 'length' <<<"$APPLIED_JSON")" -gt 0 ]; then
      LOG_LINE=$(jq -nc --arg ts "$(NOW_TS)" --arg claim "$CLAIM" --argjson issue "$ISSUE" \
        --arg status "$STATUS_ARG" --argjson applied "$APPLIED_JSON" \
        --arg decision "readd: ensured on board, status=$STATUS_ARG" \
        '{ts:$ts, event:"triage", claim:$claim, issue:$issue, status:$status, decision:$decision, applied:$applied}')
      emit_log "$LOG_LINE"
    fi
  done
  finish
fi

# ---------------------------------------------------------------------------
# Normal mode: one decision-record JSON object per stdin line.
# ---------------------------------------------------------------------------
while IFS= read -r line || [ -n "$line" ]; do
  line=$(printf '%s' "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
  [ -n "$line" ] || continue

  if ! jq -e . >/dev/null 2>&1 <<<"$line"; then
    echo "home-deferred: REJECTED — not valid JSON: $line" >&2
    REJECTED=$((REJECTED+1)); continue
  fi
  REC="$line"

  ISSUE=$(jq -r '.issue // empty' <<<"$REC")
  case "$ISSUE" in ''|*[!0-9]*) echo "home-deferred: REJECTED — missing/invalid .issue: $REC" >&2; REJECTED=$((REJECTED+1)); continue ;; esac

  if jq -e 'has("parent")' <<<"$REC" >/dev/null 2>&1; then
    echo "home-deferred: REJECTED #$ISSUE — record carries a 'parent' field; deferred items are homed by milestone, never re-parented (no-parent-ever rule): $REC" >&2
    REJECTED=$((REJECTED+1)); continue
  fi

  TARGET_STATUS=$(jq -r '.status // empty' <<<"$REC")
  [ -n "$TARGET_STATUS" ] || { echo "home-deferred: REJECTED #$ISSUE — missing .status" >&2; REJECTED=$((REJECTED+1)); continue; }

  # -----------------------------------------------------------------------
  # Park path: "status":"park" is a keyword, not a board Status option
  # name — a separate shape (header doc), a separate gate (unit, before any
  # call) and a separate apply (apply_park), with no project-item creation
  # and no claim (a parked item is already on the board with its claim
  # already released).
  # -----------------------------------------------------------------------
  if [ "$TARGET_STATUS" = "park" ]; then
    PARK_UNIT=$(jq -r '.unit // empty' <<<"$REC")
    if [ -z "$PARK_UNIT" ]; then
      echo "home-deferred: REJECTED #$ISSUE — park record missing required .unit: $REC" >&2
      REJECTED=$((REJECTED+1)); continue
    fi

    if ! check_completeness; then
      REJECTED=$((REJECTED+1)); continue
    fi

    APPLIED=()
    if ! apply_park; then
      FAILED=$((FAILED+1))
      APPLIED_JSON=$(applied_json)
      jq -nc --argjson issue "$ISSUE" --arg claim "$CLAIM" --argjson applied "$APPLIED_JSON" \
        '{issue:$issue, claim:$claim, applied:$applied, failed:true}'
      continue
    fi

    APPLIED_JSON=$(applied_json)
    jq -nc --argjson issue "$ISSUE" --arg claim "$CLAIM" --argjson applied "$APPLIED_JSON" \
      '{issue:$issue, claim:$claim, applied:$applied}'

    if [ "$(jq 'length' <<<"$APPLIED_JSON")" -gt 0 ]; then
      LOG_LINE=$(jq -nc --arg ts "$(NOW_TS)" --arg claim "$CLAIM" --argjson rec "$REC" --argjson applied "$APPLIED_JSON" \
        '$rec + {ts:$ts, event:"triage", claim:$claim, decision:"parked", applied:$applied}')
      emit_log "$LOG_LINE"
    fi
    continue
  fi

  MILESTONE=$(jq -r '.milestone // empty' <<<"$REC")
  [ -n "$MILESTONE" ] || { echo "home-deferred: REJECTED #$ISSUE — missing .milestone" >&2; REJECTED=$((REJECTED+1)); continue; }

  if ! check_completeness; then
    REJECTED=$((REJECTED+1)); continue
  fi

  # -- Gate passed. Board row (step 1), claim (step 2), mutations (step 3). --
  APPLIED=()

  if ! ensure_project_item "$ISSUE"; then
    FAILED=$((FAILED+1)); continue
  fi

  if ! claim_gate "$ISSUE"; then
    # See the --readd path: a hard claim failure is printed as REJECTED, so
    # it is counted as REJECTED.
    [ "$CLAIM_OUTCOME" != "failed" ] || REJECTED=$((REJECTED+1))
    APPLIED_JSON=$(applied_json)
    [ "$(jq 'length' <<<"$APPLIED_JSON")" -eq 0 ] || \
      jq -nc --argjson issue "$ISSUE" --arg claim "$CLAIM" --argjson applied "$APPLIED_JSON" \
        '{issue:$issue, claim:$claim, applied:$applied}'
    continue
  fi

  # apply_record — every mutation for one record. Returns 1 (reason already
  # echoed as FAILED) on the first `gh` failure instead of killing the run:
  # the caller releases the claim and moves to the next record (issue #350).
  if ! apply_record; then
    release_claim "$ISSUE"
    FAILED=$((FAILED+1))
    APPLIED_JSON=$(applied_json)
    jq -nc --argjson issue "$ISSUE" --arg claim "$CLAIM" --argjson applied "$APPLIED_JSON" \
      '{issue:$issue, claim:$claim, applied:$applied, failed:true}'
    continue
  fi

  APPLIED_JSON=$(applied_json)
  jq -nc --argjson issue "$ISSUE" --arg claim "$CLAIM" --argjson applied "$APPLIED_JSON" \
    '{issue:$issue, claim:$claim, applied:$applied}'

  if [ "$(jq 'length' <<<"$APPLIED_JSON")" -gt 0 ]; then
    LOG_LINE=$(jq -nc --arg ts "$(NOW_TS)" --arg claim "$CLAIM" --argjson rec "$REC" --argjson applied "$APPLIED_JSON" \
      '$rec + {ts:$ts, event:"triage", claim:$claim,
               decision:("homed to milestone \($rec.milestone // "?"), status \($rec.status // "?")"),
               applied:$applied}')
    emit_log "$LOG_LINE"
  fi
done

finish
