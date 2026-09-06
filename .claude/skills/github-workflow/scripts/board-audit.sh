#!/usr/bin/env bash
# board-audit.sh — read-only state-audit queries for the maintenance drain's
# "State audit" step. GET-only (see the "read-only contract" note below for
# the one wrinkle GraphQL introduces); never mutates the board or an issue.
# Remediation is NOT this script's job — its output only reports facts; the
# sibling `home-deferred.sh --readd` performs any fix.
#
# Usage: board-audit.sh [--target <n> | --milestone <n> | --epic <n>]
#                        [--since <ISO-8601 UTC>] [--claim <id>] [--repo owner/name]
#                        [--log <path>] [--work-tracking <path>] [--markdown]
#                        [--max-rows <N>] [--limit <N>]
#
# --target <n> is ambiguous by design: it is a milestone number OR an epic
# issue number, and this script disambiguates it live rather than by asking
# the caller — a milestone lookup on <n> is tried first; a 404 there falls
# back to reading <n> as an epic issue number. Milestone wins on collision
# (a repository can have a milestone numbered the same as an unrelated
# issue): this precedence is the stated rule, not an accident, and the
# result's `target_kind` key (JSON, `--markdown`, and the `--log` line) says
# which interpretation actually ran, always. `--milestone <n>` / `--epic <n>`
# skip the disambiguation entirely and assert the kind outright — pass one of
# these instead of bare `--target` whenever the caller already knows which
# kind it means; `--target`, `--milestone`, and `--epic` are mutually
# exclusive. Whichever way `--target`'s number resolves to an "epic", a
# result that turns out to be a pull request (pull requests and issues share
# the same number space and the same GET endpoint) is refused with a `die`,
# never silently treated as an epic.
#
# --since accepts exactly two forms: full UTC `YYYY-MM-DDTHH:MM:SSZ` (what the
# GitHub API itself emits) or date-only `YYYY-MM-DD` (midnight UTC). Anything
# else — an offset, fractional seconds, a bare time — is a `die` (exit 1),
# never a silently-wrong comparison. Comparison against each timeline event's
# `created_at` is done in epoch seconds (`date -u -d ... +%s`), not lexically,
# so the two accepted forms and the API's own timestamps always agree
# regardless of representation. (#330)
#
# Answers four questions:
#
#  (a) missing_board_items — every open issue in the repo that has no
#      matching item on the Project board. One paginated GraphQL query walks
#      every item on the project named by the board's Project id (read from
#      --work-tracking, never hard-coded); one paginated REST listing walks
#      every open issue; the set difference (open issues whose number+repo
#      appears in no item's content) is the result.
#
#  (b) homed_by_others — items homed into --target (a milestone number or an
#      epic issue number; whichever a live milestone lookup positively
#      identifies) since --since, apparently by a session other than this
#      one. HEURISTIC AND ITS LIMITS (state this in every --markdown block
#      too, not just here): the claim id this script's caller is working
#      under is NOT recorded anywhere on an issue's timeline, so there is no
#      way to positively attribute a homing event to "this session" versus
#      "another session" from the API alone. Two fallbacks, in order:
#        1. If --work-tracking names a second, distinct account beyond the
#           one automation account (a configured reviewer identity per
#           docs/process/work-tracking.md), events whose actor EQUALS the
#           automation account (the identity this very session acts as,
#           per --work-tracking's "automation account `<login>`" line) are
#           excluded, and everything else — including the second/reviewer
#           account's own events — is reported as an `actor_filter`
#           candidate. This is deliberately the automation account, not the
#           second account: issue #263 defines the goal as events "not
#           authored by my claim's session", and this session IS the
#           automation account, never the second account, so excluding the
#           second account (the opposite identity) would keep this
#           session's own noise rather than filtering it. What this DOES
#           attribute: an event authored by anything other than the
#           automation account is not this session's own doing. What it
#           CANNOT attribute: if another session also runs under the same
#           shared automation account, that other session's homing is
#           excluded too (a false negative) — the caller still cannot
#           positively tell "this session" apart from "another session on
#           the same shared account" from the API alone, only "the shared
#           account" apart from everyone else. `--work-tracking` naming a
#           second account with no automation account line is a
#           configuration error this script refuses (`die`): the exclusion
#           has nothing to filter on. That refusal fires only on runs that
#           reach part (b) — i.e. runs given --target; a part-(a)-only run
#           never consults the automation account and is unaffected (#478).
#        2. Otherwise (the common case: one shared automation account, this
#           repository's current setup) EVERY homing event on the target's
#           issues since --since is reported as a `since_only` candidate,
#           full stop. A session re-running this audit inside its own
#           dispatch window will see its own just-made changes listed here
#           too — that is a known false positive of this heuristic, not a
#           bug; the caller is expected to eyeball the list, not trust it
#           blindly.
#      "Homed" is read narrowly as a `milestoned` or `labeled` timeline
#      event, because those are the only homing-adjacent event types the
#      REST issues-timeline API actually emits — GitHub does not emit a
#      classic-Projects-style `added_to_project` (or any sub-issue-added)
#      timeline event for a ProjectV2 board or for the native sub-issue
#      relationship, so a board- or sub-issue-only homing with no
#      accompanying milestone/label change is invisible to this script.
#      That gap is a known, documented limitation, not an oversight.
#
#      BOUNDING THE WALK (#416): part (b) costs one REST call per
#      target-member issue (its timeline), so cost scales with the target's
#      size, not the repo's — a live run against ~90 target-member issues
#      took minutes. --since width does NOT bound this cost: the timeline
#      endpoint has no server-side `since` filter, so every page of every
#      walked issue's timeline is always read in full regardless of --since.
#      Two real bounds instead: (1) a free pre-filter, always on — each
#      target-member issue's own `updated_at` (already present in the
#      listing that names the members, no extra call) is compared to
#      --since first; an issue not updated since --since cannot have any
#      timeline event since --since either (a milestoned/labeled event is
#      itself an update), so its timeline is never fetched at all — this is
#      an exact filter, never a truncation, and needs no flag. (2) an
#      explicit `--limit <N>` hard cap on how many of the issues that pass
#      filter (1) get walked, for the genuinely large/first-pass case that
#      filter (1) alone cannot bound; reaching the cap sets
#      `homed_walk_truncated: true` in the JSON (also stated in the
#      `--markdown` block and the `--log` line) so the caller knows the
#      result is partial, never silently short. (3) a wall-clock mitigation
#      on top of both: the timeline GETs that filters (1)/(2) leave are
#      independent reads with no ordering requirement between them, so up
#      to 10 run concurrently rather than one at a time — still GET-only,
#      still no mutation, just less serial wait.
#
#  (c) missing_size_label — every open issue carrying no `size:*` label
#      (#733). Sizing is required at filing on every issue type, not only
#      bugs, so this check has no type carve-out: any open issue with zero
#      `size:*` labels is reported, full stop. Only a presence check, never a
#      cardinality one — no filer path assigns two `size:*` labels at once
#      today, so that failure mode is not (yet) worth a report; #733's own
#      issue is where a future multi-size defect would be filed.
#
#  (d) bad_priority_label / bad_severity_label — set-cardinality checks on
#      two other closed-set-of-one label families (#745). `priority:*` is
#      required on every open issue (`maintenance.md`'s `labels-complete`
#      triage gate), so `bad_priority_label` reports any open issue with
#      zero OR more than one `priority:*` label — both are wrong, and the
#      eleven issues that motivated #745 (two `priority:*` labels apiece,
#      left behind by a triage drain that added a raised priority without
#      removing the original) are exactly the "more than one" half of this.
#      `severity:*` has the identical closed-set-of-one SHAPE but a
#      DIFFERENT presence rule: `labels-complete` requires it only "for
#      bugs" — a chore is not broken, so a chore correctly carries no
#      severity label, and a blanket zero-severity check would flag the
#      large majority of open issues (chores/enhancements/docs) as noise.
#      So `bad_severity_label` reports an open issue when EITHER it carries
#      the `bug` label and zero `severity:*` labels, OR it carries more than
#      one `severity:*` label regardless of type (the multiplicity half of
#      the closed-set-of-one shape has no such carve-out — no issue of any
#      type should ever carry two). Each of the three lists' entries carry
#      `{number, title, url}` (`missing_size_label`) or `{number, title,
#      url, priority_count}` / `{number, title, url, severity_count}` (the
#      two cardinality reports), so the offending count is visible without a
#      second lookup.
#
#  (e) bad_claim_form — every board item whose `Claimed by` text is non-empty
#      and matches NEITHER canonical shape in formats/claim.md: the
#      coordination-lock form `<id> @ <ts>` or the dispatch-stamp form
#      `<id> @ <ts> (stamp)` (issue #744's literal trailing marker). This is
#      a pure format-validity check — it flags a structurally malformed
#      value (a typo, truncation, or manual edit that broke the shape), not
#      an ambiguous-but-well-formed one: a PRE-#744 dispatch stamp that
#      still matches the coordination-lock shape (because it was written
#      before the marker existed) is syntactically VALID and is not flagged
#      here — that ambiguity cannot be resolved from the text alone, by this
#      script or by claims.md's own rule, and is the one-time migration
#      #744 files separately as #767 rather than attempting a heuristic
#      rewrite. Entries carry `{number, title, url, claimed_by}`.
#
# Read-only contract: every REST call here is GET, and the mock harness in
# tests/ refuses any explicit non-GET verb exactly as preflight.sh's does.
# The one GraphQL call is a transport-level POST by protocol (there is no
# GET GraphQL) but is semantically a read: its query text is a `query`, never
# a `mutation`, and the tests assert that textually as well as via the
# generic write-verb refusal.
#
# Output: one JSON object on stdout — top-level keys `repo`, `target`,
# `target_kind` (`"milestone"` | `"epic"` | `null` when no --target was
# given), `since`, `heuristic`, `missing_board_items[]`, `homed_by_others[]`,
# `missing_size_label[]`, `bad_priority_label[]`, `bad_severity_label[]`,
# `bad_claim_form[]`, `homed_walk_truncated` (`--limit` was reached; always
# `false` when --limit was not given), `generated_at`. The four label/claim
# audit lists ((c), (d), (e) above) always run — they read only the same
# open-issues listing and project-items listing part (a) already fetches,
# need no --target, and are independent of part (b)'s heuristic. `--markdown`
# instead renders a paste-ready block for the maintenance report on stdout,
# each of the six lists capped at --max-rows (default 20; must be >= 1)
# with a "+K more, see JSON" trailer — the JSON itself always stays
# complete. When part (b) ran (a --target was given), the block also states
# the target's kind and restates the heuristic's
# limits, wording matched to whichever heuristic branch actually ran, in one
# "> Limits:" blockquote line, preceded by a blank line, per L24-25 above.
#
# `--log <path>` appends one session-log-format line to that file; without
# `--log` the same line goes to stderr, never stdout. `board-audit` is not
# (yet) an event `formats/session-log.md`'s table enumerates, and this PR
# must not edit that file, so the line uses the existing `note` event
# (required keys `ts`, `event`, `claim` all present; `claim` is the value of
# --claim, or JSON `null` when --claim was not passed) with a human-readable
# `text` summary plus this script's own structured extra keys (`repo`,
# `target`, `counts`) alongside it — `note`'s only documented key is `text`,
# and the format's prose describes it as "free text, sparingly", but nothing
# there forbids a caller from carrying additional self-describing keys next
# to it, and `jq -e .` stays valid either way. Sibling issue #279
# (maintenance-wiring) is where `board-audit` gains a dedicated entry in
# `session-log.md`'s event table; this script switches to it then.
#
# Exit codes: 2 = argument error. 1 = die(), e.g. a GET/GraphQL call
# failed for a reason other than a legitimate "resource absent" 404 on the
# optional --target lookups, or --repo/--work-tracking was unusable, or
# canonical_uint's <min> was itself malformed (a programming error at a call
# site, never user input; #581); in every case the reason is on stderr and
# no partial JSON is printed.
#
# No repository- or owner-specific nouns appear in this script; the target
# repo comes from --repo or, failing that, `gh repo view` on the current
# checkout. Board ids (the Project id, the automation account, an optional
# second/reviewer account) are parsed from --work-tracking, never hard-coded.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/project-items-walk.sh disable=SC1091
. "$SCRIPT_DIR/lib/project-items-walk.sh"

die(){ echo "board-audit: $*" >&2; exit 1; }
argerr(){ echo "board-audit: $*" >&2; exit 2; }

TARGET=""; TARGET_KIND_FORCED=""; SINCE=""; CLAIM=""; REPO=""; LOG_PATH=""; MARKDOWN=0
MAX_ROWS=20; LIMIT=0
WORK_TRACKING="docs/process/work-tracking.md"
while [ $# -gt 0 ]; do
  case "$1" in
    --target)
      [ -z "$TARGET_KIND_FORCED" ] || argerr "--target is mutually exclusive with --milestone/--epic"
      TARGET="${2:?--target needs a value}"; shift 2 ;;
    --milestone)
      [ -z "$TARGET" ] && [ -z "$TARGET_KIND_FORCED" ] || argerr "--milestone is mutually exclusive with --target/--epic"
      TARGET="${2:?--milestone needs a value}"; TARGET_KIND_FORCED="milestone"; shift 2 ;;
    --epic)
      [ -z "$TARGET" ] && [ -z "$TARGET_KIND_FORCED" ] || argerr "--epic is mutually exclusive with --target/--milestone"
      TARGET="${2:?--epic needs a value}"; TARGET_KIND_FORCED="epic"; shift 2 ;;
    --since) SINCE="${2:?--since needs a value}"; shift 2 ;;
    --claim) CLAIM="${2:?--claim needs a value}"; shift 2 ;;
    --repo) REPO="${2:?--repo needs a value}"; shift 2 ;;
    --log) LOG_PATH="${2:?--log needs a value}"; shift 2 ;;
    --work-tracking) WORK_TRACKING="${2:?--work-tracking needs a value}"; shift 2 ;;
    --markdown) MARKDOWN=1; shift ;;
    --max-rows) MAX_ROWS="${2:?--max-rows needs a value}"; shift 2 ;;
    --limit) LIMIT="${2:?--limit needs a value}"; shift 2 ;;
    -*) argerr "unknown flag $1" ;;
    *) argerr "unexpected argument $1" ;;
  esac
done
case "$TARGET" in ''|*[!0-9]*) [ -z "$TARGET" ] || argerr "--target must be a positive integer, got: $TARGET" ;; esac
# --max-rows and --limit both take a canonical positive-integer form, and
# share this one check (#507) rather than a per-flag copy: the earlier
# --max-rows-only guard matched the literal string `0`, so `00`/`000`
# slipped past it and `jq --argjson` read them back as 0 — zero bullets plus
# an "…and N more, see JSON" trailer, exactly the self-contradictory state
# #339 was filed to eliminate (#476) — and the same non-canonical forms
# (`007`, `+5`, embedded whitespace) were separately accepted by --limit
# until this helper unified the two. The pattern is anchored to the whole
# value (a `case` glob, not `grep -E`, which matches per line and would
# accept an embedded newline), so leading zeros, a sign, and any whitespace
# are all refused before either value reaches `jq --argjson` or a `-ge`
# arithmetic test. <min> differs per flag: --max-rows requires >=1 (0 is
# refused — an empty report with a nonzero trailer would be
# self-contradictory); --limit allows 0 (its own "unlimited" value).
canonical_uint(){ # canonical_uint <flag> <value> <min> [domain-noun]
  # <min> is a programming error, not user input, if it is not itself a
  # canonical non-negative integer literal — both current call sites pass
  # literals (1, 0), so this can only trip on a future call site's defect
  # (#581), and it dies loudly with the offending value rather than being
  # blamed on the caller's own <value>.
  case "$3" in
    ''|*[!0-9]*|0?*) die "canonical_uint: <min> must be a canonical non-negative integer, got: $3" ;;
  esac
  local msg="$1 must be ${4:-a positive integer} in canonical form (no leading zeros, no sign, no whitespace), got: $2"
  case "$2" in
    ''|*[!0-9]*|0?*) argerr "$msg" ;;
  esac
  # stderr redirected (#546): a value that is all-digits and canonical but
  # outside the shell's integer range makes `[ -ge ]` itself fail with its
  # own "integer expression expected" line on stderr ahead of this refusal
  # — captured and discarded here so the caller sees exactly one clean
  # `board-audit:`-prefixed line, not a bare bash-internal one first. The
  # `<min>` guard above (#581) only pins <min>'s canonical FORM (no leading
  # zeros, no sign, no whitespace); it does not bound <min>'s magnitude, so
  # an astronomically large but canonical <min> literal would overflow `[
  # -ge ]` the same way an out-of-range <value> does, and this redirect
  # would discard that failure too, misattributing it to <value> via $msg.
  # Both current call sites pass small literals (1, 0), so this is not a
  # live risk today; a future call site that ever needs a large <min> would
  # need this redirect revisited before it could rely on the <min> guard
  # alone.
  if ! [ "$2" -ge "$3" ] 2>/dev/null; then
    argerr "$msg"
  fi
}
canonical_uint --max-rows "$MAX_ROWS" 1
# --limit's own domain noun (#580): --max-rows keeps the default "a positive
# integer" noun phrase, but --limit's minimum is 0 (its own "unlimited"
# value), so asserting "must be a positive integer" and then accepting 0
# would contradict itself. Substituting the noun phrase per flag — rather
# than appending a hint after it — keeps the one canonical-FORM clause
# shared by both flags while stating each flag's own domain accurately.
canonical_uint --limit "$LIMIT" 0 'a non-negative integer (0 is accepted: it means unlimited)'
[ -z "$TARGET" ] || [ -n "$SINCE" ] || argerr "--target requires --since"

# --since: exactly `YYYY-MM-DDTHH:MM:SSZ` (the API's own form) or date-only
# `YYYY-MM-DD` (midnight UTC) — anything else is a hard argument error, never
# a silently-wrong lexical comparison. (#330)
SINCE_EPOCH=""
if [ -n "$SINCE" ]; then
  case "$SINCE" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) ;;
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
    *) argerr "--since must be ISO-8601 UTC (YYYY-MM-DDTHH:MM:SSZ) or date-only (YYYY-MM-DD), got: $SINCE" ;;
  esac
  SINCE_EPOCH=$(date -u -d "$SINCE" +%s 2>/dev/null) \
    || argerr "--since could not be parsed as a UTC timestamp: $SINCE"
fi

[ -n "$REPO" ] || REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null) \
  || die "could not resolve --repo and 'gh repo view' failed — pass --repo owner/name"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/board-audit.XXXXXX")"
cleanup(){ rm -rf "$WORK"; }
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Board ids: parsed from --work-tracking, never hard-coded. The Project id
# is required for part (a); an optional second/reviewer account (parsed from
# a "Reviewer identity: <account>" line that does not say "none") narrows
# part (b)'s heuristic when present.
# ---------------------------------------------------------------------------
[ -f "$WORK_TRACKING" ] || die "--work-tracking file not found: $WORK_TRACKING"
# shellcheck disable=SC2016 # these grep -P patterns are intentionally single-quoted; nothing here is meant to expand
PROJECT_ID=$(grep -m1 -oP '(?<=\| Project \| `)[^`]+' "$WORK_TRACKING" || true)
[ -n "$PROJECT_ID" ] || die "could not parse a Project id out of $WORK_TRACKING"
# shellcheck disable=SC2016 # this grep -P pattern is intentionally single-quoted; nothing here is meant to expand
AUTOMATION_ACCOUNT=$(grep -m1 -oP '(?<=automation account `)[^`]+' "$WORK_TRACKING" || true)
SECOND_ACCOUNT=""
reviewer_line=$(grep -m1 -i '^Reviewer identity:' "$WORK_TRACKING" || true)
# The "none" sentinel is matched EXACTLY and case-insensitively against the
# line's value, never as a substring of the whole line (#746) — the same
# exact-compare discipline save-log.sh uses for its own not-configured
# fallback ("never a `none*` prefix match, which would misclassify a
# genuinely configured archive like `nonesuch/logs`"). Unlike save-log.sh's
# fallback, this line's value carries free rationale text after the
# sentinel ("none — single account; ..."), so the sentinel compared is the
# value's first whitespace-delimited word, not the whole value — "nonesuch"
# and "none-two-word-account" are both a configured account, one word, not
# equal to "none".
if [ -n "$reviewer_line" ]; then
  reviewer_value=$(printf '%s' "$reviewer_line" | sed -E 's/^Reviewer identity:[[:space:]]*//I; s/[[:space:]]+$//')
  reviewer_sentinel_lc=$(printf '%s' "$reviewer_value" | awk '{print tolower($1)}')
  if [ "$reviewer_sentinel_lc" != "none" ]; then
    # shellcheck disable=SC2016 # this grep -oP pattern is intentionally single-quoted; nothing here is meant to expand
    SECOND_ACCOUNT=$(printf '%s' "$reviewer_line" | grep -oP '`\K[^`]+' | head -1 || true)
  fi
  # No refusal here: this parse block runs on every invocation, including
  # part-(a)-only runs that never consult AUTOMATION_ACCOUNT. The refusal for
  # "second account named, automation account missing" lives where the
  # actor_filter branch it guards is actually selected, under --target (#478).
fi

# ---------------------------------------------------------------------------
# Part (a), step 1: every item currently on the project board, paginated
# GraphQL. The query variable $cursor defaults to null so the first call
# needs no explicit --field for it; later calls pass the previous page's
# endCursor. Draft items (content == null, e.g. a bare board note) are kept
# out of the comparison set entirely — they can never match an issue. The
# `Claimed by` text field is fetched in the same query for part (e) below —
# no second GraphQL call, since this listing already walks every item. The
# pagination loop itself is shared with batch-deferred.sh's own board-Status
# walk via lib/project-items-walk.sh (#867); only this query's own field
# selection and the per-page extraction below are specific to this script.
# ---------------------------------------------------------------------------
# shellcheck disable=SC2016 # single-quoted on purpose: $id/$cursor are GraphQL variables, not shell ones
GQL_QUERY='query($id: ID!, $cursor: String = null) { node(id: $id) { ... on ProjectV2 { items(first: 100, after: $cursor) { pageInfo { hasNextPage endCursor } nodes { id content { ... on Issue { number repository { nameWithOwner } } } claimedBy: fieldValueByName(name: "Claimed by") { ... on ProjectV2ItemFieldTextValue { text } } } } } } }'

gh_project_items_walk "$PROJECT_ID" "$GQL_QUERY" "$WORK/items.pages"
: > "$WORK/items.raw"
jq -c '.data.node.items.nodes[]|select(.content!=null)|{number:.content.number, repo:.content.repository.nameWithOwner, claimed_by:(.claimedBy.text // "")}' \
  "$WORK/items.pages" >> "$WORK/items.raw"
jq -s --arg repo "$REPO" '[.[]|select(.repo==$repo)|.number]' "$WORK/items.raw" > "$WORK/item_numbers.json"
jq -s --arg repo "$REPO" '[.[]|select(.repo==$repo)|{number, claimed_by}]' "$WORK/items.raw" > "$WORK/item_claims.json"

# ---------------------------------------------------------------------------
# Part (a), step 2: every open issue in the repo, paginated REST, PRs
# excluded (the issues endpoint returns both; a PR node carries a
# "pull_request" key an issue never has).
# ---------------------------------------------------------------------------
gh api --paginate "repos/$REPO/issues?state=open&per_page=100" \
  --jq '.[]|select(.pull_request==null)|{number:.number,title:.title,url:.html_url,labels:[(.labels // [])[].name]}' \
  > "$WORK/open_issues.raw" 2>"$WORK/open_issues.err" \
  || die "GET repos/$REPO/issues failed: $(cat "$WORK/open_issues.err")"
jq -s '.' "$WORK/open_issues.raw" > "$WORK/open_issues.json"

MISSING=$(jq -n --slurpfile issues "$WORK/open_issues.json" --slurpfile onboard "$WORK/item_numbers.json" \
  '[$issues[0][] | select(.number as $n | ($onboard[0] | index($n)) | not)]')

# ---------------------------------------------------------------------------
# Part (c)/(d): label set-cardinality audits (#733, #745). All three read
# only the open-issues listing just fetched above (its `labels[]` array is
# fetched for exactly this purpose) — no extra call, no --target needed, and
# they run unconditionally on every invocation, part-(a)-only included. See
# the header's (c)/(d) note for why `bad_severity_label`'s zero-count leg is
# gated on the `bug` label while `bad_priority_label`'s is not.
# ---------------------------------------------------------------------------
MISSING_SIZE=$(jq -n --slurpfile issues "$WORK/open_issues.json" '
  [$issues[0][] | select((.labels // []) | any(startswith("size:")) | not)
   | {number, title, url}]')

BAD_PRIORITY=$(jq -n --slurpfile issues "$WORK/open_issues.json" '
  [$issues[0][] | . as $i
   | (($i.labels // []) | map(select(startswith("priority:"))) | length) as $c
   | select($c != 1)
   | {number: $i.number, title: $i.title, url: $i.url, priority_count: $c}]')

BAD_SEVERITY=$(jq -n --slurpfile issues "$WORK/open_issues.json" '
  [$issues[0][] | . as $i
   | (($i.labels // []) | map(select(startswith("severity:"))) | length) as $c
   | (($i.labels // []) | any(. == "bug")) as $is_bug
   | select($c > 1 or ($is_bug and $c == 0))
   | {number: $i.number, title: $i.title, url: $i.url, severity_count: $c}]')

# ---------------------------------------------------------------------------
# Part (e): bad_claim_form (#744) — a non-empty `Claimed by` value matching
# NEITHER canonical shape from formats/claim.md. Joins the open-issues
# listing (title/url) against the project-items `Claimed by` values fetched
# above in part (a) step 1 by issue number. A pre-#744 dispatch stamp that
# still matches the coordination-lock shape is NOT flagged — see the
# header's (e) note for why that ambiguity is deliberately out of scope
# here.
# ---------------------------------------------------------------------------
BAD_CLAIM_FORM=$(jq -n --slurpfile issues "$WORK/open_issues.json" --slurpfile claims "$WORK/item_claims.json" '
  ($claims[0] | map(select(.claimed_by != "")) | map({(.number|tostring): .claimed_by}) | add // {}) as $cmap
  | [$issues[0][] | . as $i
     | ($cmap[($i.number|tostring)] // "") as $c
     | select($c != "" and ($c | test("^[^[:space:]]+ @ [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}Z( \\(stamp\\))?$") | not))
     | {number: $i.number, title: $i.title, url: $i.url, claimed_by: $c}]')

# ---------------------------------------------------------------------------
# Part (b): items homed into --target since --since by (apparently) another
# session. Skipped entirely — an empty array, heuristic "n/a" — when no
# --target was given.
# ---------------------------------------------------------------------------
HOMED='[]'
HEURISTIC="n/a (no --target given)"
TARGET_KIND=""
HOMED_WALK_TRUNCATED="false"
if [ -n "$TARGET" ]; then
  if [ -n "$SECOND_ACCOUNT" ]; then
    # actor_filter is the only consumer of AUTOMATION_ACCOUNT, and it is only
    # reachable here, under --target. Refusing at the point of use keeps
    # part-(a)-only runs working on any --work-tracking configuration (#478).
    [ -n "$AUTOMATION_ACCOUNT" ] \
      || die "--work-tracking names a second/reviewer account but no automation account — nothing to exclude for actor_filter: $WORK_TRACKING"
    HEURISTIC="actor_filter (actor != $AUTOMATION_ACCOUNT, since $SINCE)"
  else
    HEURISTIC="since_only (every homing since $SINCE is a candidate; automation account: ${AUTOMATION_ACCOUNT:-unknown})"
  fi

  # Resolve --target's kind. Forced via --milestone/--epic: no probing, no
  # fallback — the caller already asserted the kind, so a lookup failure is
  # a hard error. Bare --target: probe live, milestone first (milestone
  # wins on collision, per the header) and fall back to reading it as an
  # epic issue number on a 404.
  if [ "$TARGET_KIND_FORCED" = "milestone" ]; then
    gh api "repos/$REPO/milestones/$TARGET" --jq .number >"$WORK/ms.out" 2>"$WORK/ms.err" \
      || die "GET repos/$REPO/milestones/$TARGET failed: $(cat "$WORK/ms.err")"
    TARGET_KIND="milestone"
  elif [ "$TARGET_KIND_FORCED" = "epic" ]; then
    TARGET_KIND="epic"
  elif gh api "repos/$REPO/milestones/$TARGET" --jq .number >"$WORK/ms.out" 2>"$WORK/ms.err"; then
    TARGET_KIND="milestone"
  elif grep -qi '404' "$WORK/ms.err"; then
    TARGET_KIND="epic"
  else
    die "GET repos/$REPO/milestones/$TARGET failed: $(cat "$WORK/ms.err")"
  fi

  : > "$WORK/target_issues.raw"
  if [ "$TARGET_KIND" = "milestone" ]; then
    gh api --paginate "repos/$REPO/issues?milestone=$TARGET&state=all&per_page=100" \
      --jq '.[]|select(.pull_request==null)|{number:.number,updated_at:.updated_at}' \
      >> "$WORK/target_issues.raw" 2>"$WORK/target_issues.err" \
      || die "GET repos/$REPO/issues?milestone=$TARGET failed: $(cat "$WORK/target_issues.err")"
  else
    # An epic issue number resolving to a pull request is refused outright,
    # never treated as an epic — issues and PRs share the same number space
    # and the same GET endpoint, so `.pull_request != null` is the only way
    # to tell them apart. (#327)
    gh api "repos/$REPO/issues/$TARGET" --jq '{number,pull_request}' >"$WORK/epic.out" 2>"$WORK/epic.err" \
      || die "GET repos/$REPO/issues/$TARGET failed: $(cat "$WORK/epic.err")"
    [ "$(jq -r '.pull_request' "$WORK/epic.out")" = "null" ] \
      || die "--target/--epic #$TARGET is a pull request, not an issue — an epic must be an issue"
    gh api --paginate "repos/$REPO/issues/$TARGET/sub_issues?per_page=100" \
      --jq '.[]|{number:.number,updated_at:.updated_at}' \
      >> "$WORK/target_issues.raw" 2>"$WORK/target_issues.err" \
      || die "GET repos/$REPO/issues/$TARGET/sub_issues failed: $(cat "$WORK/target_issues.err")"
  fi

  # Bound the walk (#416). Filter (1), always on: an issue not updated
  # since --since (its own `updated_at`, already in the listing above, no
  # extra call) cannot have a timeline event since --since either — a
  # milestoned/labeled event is itself an update — so its timeline is
  # never fetched. Cap (2), only with --limit: after filter (1), walk at
  # most --limit of the remaining issues; reaching the cap is recorded in
  # HOMED_WALK_TRUNCATED rather than silently dropping the rest.
  : > "$WORK/target_issues_filtered.raw"
  while IFS= read -r rec; do
    [ -n "$rec" ] || continue
    upd=$(jq -r '.updated_at // empty' <<<"$rec")
    if [ -n "$upd" ]; then
      upd_epoch=$(date -u -d "$upd" +%s 2>/dev/null || true)
      if [ -n "$upd_epoch" ] && [ "$upd_epoch" -lt "$SINCE_EPOCH" ]; then
        continue
      fi
    fi
    printf '%s\n' "$rec" >> "$WORK/target_issues_filtered.raw"
  done < "$WORK/target_issues.raw"

  # The remaining per-issue timeline GETs are independent reads with no
  # ordering requirement between them, so they are fired off up to
  # TIMELINE_CONCURRENCY at a time rather than one at a time — a wall-clock
  # mitigation on top of the two bounds above, same rationale as the "or
  # batch/parallelize" alternative #416 named. Each call's own exit status
  # is captured to a file (a backgrounded command can't `die` the whole
  # script directly) and checked once every launched call has finished.
  TIMELINE_CONCURRENCY=10
  WALK_COUNT=0
  : > "$WORK/homed.jsonl"
  WALK_NUMS=""
  while IFS= read -r rec; do
    [ -n "$rec" ] || continue
    if [ "$LIMIT" -gt 0 ] && [ "$WALK_COUNT" -ge "$LIMIT" ]; then
      HOMED_WALK_TRUNCATED="true"
      break
    fi
    WALK_COUNT=$((WALK_COUNT + 1))
    n=$(jq -r .number <<<"$rec")
    WALK_NUMS="$WALK_NUMS $n"
    (
      gh api --paginate "repos/$REPO/issues/$n/timeline?per_page=100" \
        --jq '.[]|select(.event=="milestoned" or .event=="labeled")|{issue:'"$n"',event:.event,actor:(.actor.login//"unknown"),created_at:.created_at}' \
        > "$WORK/timeline_$n.raw" 2>"$WORK/timeline_$n.err"
      echo $? > "$WORK/timeline_$n.rc"
    ) &
    while [ "$(jobs -rp | wc -l)" -ge "$TIMELINE_CONCURRENCY" ]; do
      wait -n || true
    done
  done < "$WORK/target_issues_filtered.raw"
  wait

  for n in $WALK_NUMS; do
    rc=$(cat "$WORK/timeline_$n.rc" 2>/dev/null || echo 1)
    [ "$rc" = "0" ] || die "GET repos/$REPO/issues/$n/timeline failed: $(cat "$WORK/timeline_$n.err" 2>/dev/null)"
    while IFS= read -r ev; do
      [ -n "$ev" ] || continue
      created=$(jq -r .created_at <<<"$ev")
      created_epoch=$(date -u -d "$created" +%s 2>/dev/null) || continue
      [ "$created_epoch" -ge "$SINCE_EPOCH" ] || continue
      actor=$(jq -r .actor <<<"$ev")
      if [ -n "$SECOND_ACCOUNT" ] && [ "$actor" = "$AUTOMATION_ACCOUNT" ]; then
        continue
      fi
      printf '%s\n' "$ev" >> "$WORK/homed.jsonl"
    done < "$WORK/timeline_$n.raw"
  done
  HOMED=$(jq -s 'sort_by(.created_at)' "$WORK/homed.jsonl")
fi

GENERATED_AT=$(date -u +%FT%TZ)

RESULT=$(jq -n \
  --arg repo "$REPO" --arg target "$TARGET" --arg target_kind "$TARGET_KIND" \
  --arg since "$SINCE" --arg claim "$CLAIM" \
  --arg heuristic "$HEURISTIC" --argjson missing "$MISSING" --argjson homed "$HOMED" \
  --argjson missing_size "$MISSING_SIZE" --argjson bad_priority "$BAD_PRIORITY" \
  --argjson bad_severity "$BAD_SEVERITY" --argjson bad_claim_form "$BAD_CLAIM_FORM" \
  --argjson truncated "$HOMED_WALK_TRUNCATED" \
  --arg generated_at "$GENERATED_AT" \
  '{
    repo: $repo,
    target: (if $target=="" then null else ($target|tonumber) end),
    target_kind: (if $target_kind=="" then null else $target_kind end),
    since: (if $since=="" then null else $since end),
    claim: (if $claim=="" then null else $claim end),
    heuristic: $heuristic,
    missing_board_items: $missing,
    homed_by_others: $homed,
    missing_size_label: $missing_size,
    bad_priority_label: $bad_priority,
    bad_severity_label: $bad_severity,
    bad_claim_form: $bad_claim_form,
    homed_walk_truncated: $truncated,
    generated_at: $generated_at
  }')

if [ "$MARKDOWN" -eq 1 ]; then
  jq -r --argjson max "$MAX_ROWS" '
    (.missing_board_items | map("  - #\(.number) \(.title)")) as $missing_lines |
    (.homed_by_others | map("  - issue #\(.issue) \(.event) by \(.actor) at \(.created_at)")) as $homed_lines |
    (.missing_size_label | map("  - #\(.number) \(.title)")) as $size_lines |
    (.bad_priority_label | map("  - #\(.number) \(.title) (priority_count=\(.priority_count))")) as $priority_lines |
    (.bad_severity_label | map("  - #\(.number) \(.title) (severity_count=\(.severity_count))")) as $severity_lines |
    (.bad_claim_form | map("  - #\(.number) \(.title) (claimed_by=\(.claimed_by))")) as $claim_lines |
    ($missing_lines|length) as $nm | ($homed_lines|length) as $nh |
    ($size_lines|length) as $ns | ($priority_lines|length) as $np | ($severity_lines|length) as $nv |
    ($claim_lines|length) as $nc |
    "### Board audit — \(.repo)\n" +
    (if .target != null then "- Target: #\(.target) (\(.target_kind))\n" else "" end) +
    "- Missing board items: \($nm)" +
    (if $nm>0 then "\n" + ([$missing_lines[0:$max][]]|join("\n"))
       + (if $nm>$max then "\n  - …and \($nm-$max) more, see JSON" else "" end)
     else "" end) + "\n" +
    "- Homed into target since \(.since // "n/a") by others: \($nh) — heuristic: \(.heuristic)" +
    (if $nh>0 then "\n" + ([$homed_lines[0:$max][]]|join("\n"))
       + (if $nh>$max then "\n  - …and \($nh-$max) more, see JSON" else "" end)
     else "" end) + "\n" +
    "- Missing size:* label: \($ns)" +
    (if $ns>0 then "\n" + ([$size_lines[0:$max][]]|join("\n"))
       + (if $ns>$max then "\n  - …and \($ns-$max) more, see JSON" else "" end)
     else "" end) + "\n" +
    "- Not exactly one priority:* label: \($np)" +
    (if $np>0 then "\n" + ([$priority_lines[0:$max][]]|join("\n"))
       + (if $np>$max then "\n  - …and \($np-$max) more, see JSON" else "" end)
     else "" end) + "\n" +
    "- Bad severity:* label (bug with none, or more than one): \($nv)" +
    (if $nv>0 then "\n" + ([$severity_lines[0:$max][]]|join("\n"))
       + (if $nv>$max then "\n  - …and \($nv-$max) more, see JSON" else "" end)
     else "" end) + "\n" +
    "- Malformed Claimed by value (#744, neither lock nor stamp shape): \($nc)" +
    (if $nc>0 then "\n" + ([$claim_lines[0:$max][]]|join("\n"))
       + (if $nc>$max then "\n  - …and \($nc-$max) more, see JSON" else "" end)
     else "" end) +
    (if .target != null then
      "\n\n> Limits: no positive attribution to a specific session is possible; " +
      (if (.heuristic|startswith("actor_filter")) then
        "events authored by the automation account are excluded as this " +
        "session'"'"'s own noise, but a second session sharing that same " +
        "account would be excluded too (a false negative, not a bug); "
       else
        "every since_only candidate includes homings made during this same " +
        "run (a known false positive, not a bug); "
       end) +
      "a board-only or sub-issue-only homing with no accompanying " +
      "milestone/label change is invisible to the REST timeline this " +
      "script reads." +
      (if .homed_walk_truncated then
        " The timeline walk hit --limit before covering every target " +
        "member issue; homed_by_others is a partial result."
       else "" end)
     else "" end)
  ' <<<"$RESULT"
else
  printf '%s\n' "$RESULT"
fi

# session-log.md's `note` event, used here per the header note above (#279
# will give board-audit its own event). Required keys ts/event/claim are all
# present; claim is null when --claim was not passed, same rule the stdout
# JSON's own `claim` key already follows.
LOG_MISSING=$(jq '.missing_board_items|length' <<<"$RESULT")
LOG_HOMED=$(jq '.homed_by_others|length' <<<"$RESULT")
LOG_MISSING_SIZE=$(jq '.missing_size_label|length' <<<"$RESULT")
LOG_BAD_PRIORITY=$(jq '.bad_priority_label|length' <<<"$RESULT")
LOG_BAD_SEVERITY=$(jq '.bad_severity_label|length' <<<"$RESULT")
LOG_BAD_CLAIM_FORM=$(jq '.bad_claim_form|length' <<<"$RESULT")
LOG_LINE=$(jq -nc --arg ts "$GENERATED_AT" --arg claim "$CLAIM" --arg repo "$REPO" \
  --argjson target "$(jq '.target' <<<"$RESULT")" \
  --argjson target_kind "$(jq '.target_kind' <<<"$RESULT")" \
  --argjson missing "$LOG_MISSING" --argjson homed "$LOG_HOMED" \
  --argjson missing_size "$LOG_MISSING_SIZE" --argjson bad_priority "$LOG_BAD_PRIORITY" \
  --argjson bad_severity "$LOG_BAD_SEVERITY" --argjson bad_claim_form "$LOG_BAD_CLAIM_FORM" \
  --argjson truncated "$(jq '.homed_walk_truncated' <<<"$RESULT")" \
  --arg text "board-audit $REPO: $LOG_MISSING missing_board_items, $LOG_HOMED homed_by_others, $LOG_MISSING_SIZE missing_size_label, $LOG_BAD_PRIORITY bad_priority_label, $LOG_BAD_SEVERITY bad_severity_label, $LOG_BAD_CLAIM_FORM bad_claim_form" \
  '{ts:$ts, event:"note", claim:(if $claim=="" then null else $claim end),
    text:$text, repo:$repo, target:$target, target_kind:$target_kind,
    counts:{missing_board_items:$missing, homed_by_others:$homed,
      missing_size_label:$missing_size, bad_priority_label:$bad_priority,
      bad_severity_label:$bad_severity, bad_claim_form:$bad_claim_form},
    homed_walk_truncated:$truncated}')
if [ -n "$LOG_PATH" ]; then
  mkdir -p "$(dirname "$LOG_PATH")"
  printf '%s\n' "$LOG_LINE" >> "$LOG_PATH"
else
  printf '%s\n' "$LOG_LINE" >&2
fi
