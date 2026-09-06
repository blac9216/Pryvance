#!/usr/bin/env bash
# batch-deferred.sh — read-only batch proposals for the triage drain's
# Batching step (references/maintenance.md § 1, "Batching, after the
# per-item checklist"). Lists open `deferred` issues, derives each one's
# **unit** from a structured `Unit:` body marker (see below — this has
# moved off maintenance.md § 1 step 9's Affected-Files-row-1 prose per the
# 2026-09-05 owner ruling on #732; that prose itself is still stale as of
# this PR and needs its own follow-up, tracked separately since
# maintenance.md is out of this script's file scope), applies its
# exclusions, and prints proposed batches: unit, members ordered by
# priority, dispatchable yes/no, and which derivation path each member
# used. GET-only, no mutation of any kind — same read-only contract as
# `board-audit.sh`, which this script follows for skeleton, header and
# conventions.
#
# Usage: batch-deferred.sh [--milestone <n>] [--min 3] [--max 8] [--flush]
#                           [--markdown] [--repo owner/name]
#                           [--work-tracking <path>] [--no-board-status]
#
# --milestone <n> scopes the candidate pool to that milestone's open
# `deferred` issues PLUS open `deferred` issues carrying no milestone at
# all (the prose's "a member with no milestone counts toward the flush of
# whichever milestone the other members share" rule needs those in the
# pool to begin with). Without --milestone every open `deferred` issue in
# the repo is the pool instead — the flush rule itself is not conditioned
# on how the pool was scoped, only on which real milestone(s) a given
# unit's members actually carry, so a repo-wide run still auto-flushes a
# unit whose members share one real milestone with no open planned
# children, and a unit whose members span two or more distinct real
# milestones still never flushes (threshold only), in either mode.
#
# --min (default 3) and --max (default 8) are the dispatch threshold and
# the per-batch cap the prose names. --flush is a manual override: when
# given, every unit is treated as though its milestone's open planned
# children are already exhausted (dispatchable at any size), without the
# script issuing the extra GET the automatic flush check would otherwise
# make. Without --flush the script still auto-detects the flush: for each
# distinct real milestone number appearing in the candidate pool it GETs
# that milestone's open issues and checks whether any lack the `deferred`
# label (a "planned child" still open); zero such issues flushes every
# unit whose members share only that milestone (and/or no milestone).
#
# Unit derivation — structured marker ONLY (2026-09-05 owner ruling on #732,
# item 5, "minimal heuristics": a check that must choose between guessing
# and refusing, refuses; implemented by #751 once #733's label work
# unblocked it). The marker's lexical form and the batch-key normalisation
# below are NOT invented here — they are SKILL.md's Deferred Items rule
# ("Every deferred filing carries a `Unit:` line") and
# maintenance.md § 1 step 9 (the "single locator → batch key" normalisation),
# landed by #800/#808 (`0261c13`) after three review rounds; this script
# reads that settled text, it does not restate or re-derive it:
#
#   Lexical form (SKILL.md): on the body's raw text, a line beginning at
#   column 1 with the exact ASCII key `Unit:` — case-sensitive, no bold, no
#   backticks, no list marker before it — then one or more spaces/tabs,
#   then the value running to end of line (leading/trailing whitespace
#   stripped; nothing else may share the line — no trailing comment, no
#   trailing punctuation, no second path). The FIRST matching line in the
#   body is the marker; any later one is ignored (SKILL.md is explicit:
#   "The first matching line in the body is the marker and any later one
#   is ignored" — this script does not treat a second line as an error).
#   Extraction is `grep -m1 -E '^Unit:[[:blank:]]+'` plus a strip — one
#   line, no PCRE, no multi-line parsing. `[[:blank:]]`, never `[ \t]`: in
#   a POSIX ERE bracket expression a backslash is not special, so `[ \t]`
#   is the three-character set {space, backslash, `t`}, not "space or
#   tab" — a real tab-separated `Unit:` line is legal under SKILL.md and
#   must not be refused by an extractor that got this bracket wrong (the
#   defect that cost #800/#808 a full review round).
#
#   Value (SKILL.md): exactly one of three forms — a repo-relative FILE
#   path; a repo-relative DIRECTORY path with a trailing `/`; or an
#   `area:*` LABEL, for a finding with no path at all. Repo-relative, not
#   skill-relative, matching the body's own Affected Files table rooting.
#   Anything else on the line — a second path, a comma list, backtick
#   wrapping, trailing prose or punctuation — is not one of the three
#   forms and fails closed.
#
#   Batch-key normalisation (maintenance.md § 1 step 9 — "this
#   normalisation is the only mapping between the value a filer writes and
#   the key a batch groups by, and both scripts use it"; #802's rider
#   placement compares keys this script produces, so this script must not
#   invent a second, parallel normalisation):
#     - a FILE path whose basename is `<x>.sh` or `test_<x>.sh` (equally
#       `test-<x>.sh`) maps to the bare stem `<x>`, underscores folded to
#       hyphens — a script and its own test are one unit, REGARDLESS of
#       which directory either one lives in (the mapping is basename-only,
#       not "basename AND parent-directory" the way the old, now-removed
#       Affected-Files derivation required);
#     - any OTHER file path maps to its directory, WITH the trailing `/`
#       (a repo-ROOT file with no directory component at all — `AGENTS.md`,
#       `Makefile` — is a case step 9's own examples never exercise; this
#       script reads its directory as the repo root and keys it `./`, the
#       same value `dirname(1)` would print, never the filename itself
#       with a slash appended — a relayed PR #830 round-1 finding);
#     - a DIRECTORY path (already trailing `/`) maps to itself, slash kept;
#     - an `area:*` LABEL maps to that label unchanged — "an area-level
#       batch can mix unrelated files, and that is the filer's defect to
#       stop repeating, not a reason to leave the item unbatched"
#       (maintenance.md § 1 step 9).
#   (derivation: unit-marker)
#
#   This is deliberately NOT a `size:*` label (#733): size names an
#   issue's estimated effort, not the file set a PR would touch — an S and
#   an M issue in the same area are not the same unit, and forcing size to
#   double as unit would silently merge unrelated batches.
#
#   NO FALLBACK to the old Affected-Files-row-1 / backtick-span derivation
#   for an issue with no `Unit:` line, and NO FALLBACK for a malformed
#   one either — this stance was proposed in #751's own PR body and
#   adopted in the settled text: "`batch-deferred.sh` refuses: it excludes
#   the item from every batch with that reason recorded, because a guessed
#   unit puts real work in the wrong batch silently" (SKILL.md). Triage
#   repairs by hand instead (maintenance.md § 1 step 9); the dup-scan
#   degrades to keyword search (github-pr-review Step 8) — two different,
#   lower-stakes responses to the same absence, neither of which is this
#   script's job. "A missing line is a filing defect, not a date stamp"
#   (SKILL.md): absence never proves an issue predates the marker, so no
#   reader — including this one — may treat it as evidence of age and
#   guess accordingly.
#
#   Anything short of exactly one valid marker is a derivation FAILURE,
#   reported in excluded[] with a reason naming which way it failed —
#   never guessed at:
#     - no `Unit:` line anywhere in the body (0 occurrences) — the match
#       requires the exact, case-sensitive token `Unit:` at the START of
#       a line, followed by whitespace and a non-blank value; a miscased,
#       missing-space, or embedded-mid-sentence occurrence falls in this
#       bucket on purpose, since a near-miss is not evidence of intent
#       and picking one to honor is the interpretation #732 forbids.
#     - a `Unit:` line whose value is empty, is not one of the three legal
#       forms (a repo-relative file path, a repo-relative directory path
#       with a trailing `/`, or an `area:*` label), or maps (via the
#       script/test convention) to an empty unit string (e.g. a bare
#       `test_.sh` marker) — the marker is present but malformed. A
#       SECOND `Unit:` line in the same body is NOT an error condition —
#       per SKILL.md the first line wins and any later one is silently
#       ignored, so this script does not report or exclude on that basis.
#
# Exclusions (each reported with its reason, never silently dropped):
#   - a `blocked by` link (native issue-dependency; the item waits for its
#     blocker) — read from the bulk listing's own `issue_dependencies_summary
#     .blocked_by` count, no extra call.
#   - a decision-shaped item — read mechanically as the `question` type
#     label (the closed label set's only type meaning "asks a question
#     rather than states a fix"; docs/process/labels.md).
#   - a planned child of an epic — `parent_issue_url` set AND the parent
#     issue itself carries the `epic` label (one GET per distinct parent,
#     cached). A deferred item should carry no parent at all under the
#     no-parent-ever homing rule (references/maintenance.md § 1 step 6);
#     this exclusion covers the case where one does anyway.
#   - already in an open PR (#738) — the board's own `Status` field (read
#     from --work-tracking's `Project` id, one paginated GraphQL walk of
#     every item on the project, same query skeleton `board-audit.sh` uses)
#     is `In progress` or `In review`, which means exactly that a PR is
#     open on this issue right now; dispatching a second agent onto it
#     collides with the first. Recomputed AFTER this exclusion — a unit
#     that drops below --min once its in-flight members are removed
#     reports `dispatchable: false`, never stale-true.
#     This exclusion FAILS CLOSED (#738 round 1): --work-tracking defaults to
#     `<git root>/docs/process/work-tracking.md` (resolved against the repo
#     root exactly as stamp-claim.sh L155-158 resolves the same default, never
#     against the caller's cwd), and a work-tracking path that is missing, not
#     a regular file, unreadable, unreadable-by-grep, or carrying no parsable
#     `Project` id is a `die`, never a skip — the first cut skipped silently in
#     three of those cases and so reproduced #738's own reported symptom
#     (`"excluded": []` with a stale `dispatchable: true`) whenever the config
#     was merely misplaced. The ONLY way to run without this exclusion is to
#     ask for it: --no-board-status, which also names itself in the output's
#     `exclusions_skipped[]` so the omission is visible to whoever reads the
#     proposal instead of being inferable only from an absence.
# Excluded items are never grouped into a batch; they are listed
# separately so the orchestrator can see why.
#
# Parked riders (#802) — a SECOND, closed-issue pool, fetched with the same
# milestone scoping as the open pool but `labels=parked&state=closed`: each
# parked issue's unit is read from its body's `Unit:` marker, exactly the
# same derivation the open pool uses (no separate rule; a parked item was
# filed under the same SKILL.md marker requirement before it was closed).
# A parked issue carrying a `Rejected:` comment (the milestone-end review's
# own park-mechanics text) is excluded with that reason and never rides.
# Every other valid parked candidate joins a batch ONLY as a **rider**: only
# when that batch is ALREADY dispatchable from its OPEN members alone (a
# rider never contributes to the >=3 threshold and never flips a waiting
# unit to dispatchable), and only up to the same ~8 cap counting riders
# together with open members — riders fill whatever room is left, highest
# `priority:*` first. A rider a batch has no room for, or whose unit has no
# dispatchable batch at all, simply is not placed; it stays parked. Each
# placed rider carries `role: "rider"` in its member object (an open member
# carries `role: "member"`), and `--markdown` lists riders in their own
# sub-list under each batch.
#
# Output: one JSON object on stdout (`repo`, `milestone`, `min`, `max`,
# `flush_override`, `excluded[]`, `exclusions_skipped[]`, `batches[]`,
# `generated_at`), or `--markdown` for a paste-ready block shaped for
# `formats/maintenance-report.md`'s `triage.batches` key — the
# `{unit, members:[N,…], riders:[N,…], dispatchable}` shape that key
# documents, plus the derivation-path detail the JSON carries for the
# orchestrator to skim.
#
# `triage.batches`'s `members` holds the unit's OPEN `deferred` issue numbers
# and nothing else; placed riders (closed, parked) are carried in the sibling
# `riders` key, ALWAYS present and `[]` when a unit placed none (#738/#802
# round 1, F2). `members` is not retyped to carry `role` — every existing
# consumer reads it as an array of numbers, so a rider silently appearing
# there is a closed issue the orchestrator's pick step would treat as an
# ordinary member and dispatch without first running the reopen step
# (`home-deferred.sh --readd --status Ready`, orchestration.md § The loop
# step 1); its PR would then try to close an already-closed issue. Adding a
# key is additive, retyping one is a break — hence the sibling array.
#
# Exit codes: 2 = argument error. 1 = die(), e.g. a GET call failed for a
# reason other than a legitimate 404, --repo could not be resolved, or the
# --work-tracking board config is missing/unreadable/unparsable (above).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/project-items-walk.sh disable=SC1091
. "$SCRIPT_DIR/lib/project-items-walk.sh"

die(){ echo "batch-deferred: $*" >&2; exit 1; }
argerr(){ echo "batch-deferred: $*" >&2; exit 2; }

MILESTONE=""; MIN=3; MAX=8; FLUSH=0; MARKDOWN=0; REPO=""
# Empty means "not passed" — resolved against the GIT ROOT below, never against
# the caller's cwd (#738 round 1: a bare relative default silently regressed the
# whole board-Status exclusion for any run started outside the repo root).
# stamp-claim.sh L155-158 resolves the same default the same way.
WORK_TRACKING=""
BOARD_STATUS=1
while [ $# -gt 0 ]; do
  case "$1" in
    --milestone) MILESTONE="${2:?--milestone needs a value}"; shift 2 ;;
    --min) MIN="${2:?--min needs a value}"; shift 2 ;;
    --max) MAX="${2:?--max needs a value}"; shift 2 ;;
    --flush) FLUSH=1; shift ;;
    --markdown) MARKDOWN=1; shift ;;
    --repo) REPO="${2:?--repo needs a value}"; shift 2 ;;
    --work-tracking) WORK_TRACKING="${2:?--work-tracking needs a value}"; shift 2 ;;
    --no-board-status) BOARD_STATUS=0; shift ;;
    -*) argerr "unknown flag $1" ;;
    *) argerr "unexpected argument $1" ;;
  esac
done

# Canonical non-negative-integer form for --milestone/--min/--max — no
# leading zeros, no sign, no whitespace — the same discipline
# board-audit.sh's canonical_uint applies to --max-rows/--limit (#476/#507).
canonical_uint(){ # canonical_uint <flag> <value> <min>
  case "$2" in
    ''|*[!0-9]*|0?*) argerr "$1 must be a positive integer in canonical form (no leading zeros, no sign, no whitespace), got: $2" ;;
  esac
  [ "$2" -ge "$3" ] 2>/dev/null || argerr "$1 must be >= $3, got: $2"
}
[ -z "$MILESTONE" ] || canonical_uint --milestone "$MILESTONE" 1
canonical_uint --min "$MIN" 1
canonical_uint --max "$MAX" 1
[ "$MAX" -ge "$MIN" ] || argerr "--max ($MAX) must be >= --min ($MIN)"

[ -n "$REPO" ] || REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null) \
  || die "could not resolve --repo and 'gh repo view' failed — pass --repo owner/name"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/batch-deferred.XXXXXX")"
cleanup(){ rm -rf "$WORK"; }
trap cleanup EXIT

# Every way this block can fail to run is LOUD (#738 round 1, F1). The first
# cut skipped the walk whenever the file was missing, unreadable, or carried no
# parsable id — exit 0, empty `excluded[]`, stale `dispatchable: true`: the
# byte-for-byte symptom #738 was filed to remove, reintroduced whenever the
# config was merely misplaced. Both siblings already refuse instead
# (board-audit.sh dies on the missing file AND the unparseable id;
# stamp-claim.sh dies on the missing file), and #805 settled the shape for
# save-log.sh: a present-but-unparseable config is a distinct, loud failure,
# never folded into a quiet "not configured". Skipping the exclusion is
# therefore only ever an EXPLICIT caller choice (--no-board-status), and even
# then it is recorded in `exclusions_skipped[]` so the omission is visible in
# the artifact the orchestrator reads rather than inferred from its absence.
BOARD_STATUS_SKIPPED='[]'
if [ "$BOARD_STATUS" -eq 0 ]; then
  BOARD_STATUS_SKIPPED='["board-status (--no-board-status): issues already in an open PR are NOT excluded"]'
else
  if [ -z "$WORK_TRACKING" ]; then
    REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) \
      || die "could not resolve the repo root to find docs/process/work-tracking.md — pass --work-tracking (or --no-board-status to run without the #738 in-flight exclusion)"
    WORK_TRACKING="$REPO_ROOT/docs/process/work-tracking.md"
  fi
  [ -e "$WORK_TRACKING" ] \
    || die "--work-tracking file not found: $WORK_TRACKING (pass --work-tracking, or --no-board-status to run without the #738 in-flight exclusion)"
  [ -f "$WORK_TRACKING" ] \
    || die "--work-tracking is not a regular file: $WORK_TRACKING"
  # `-r` is the fast, specific answer for the ordinary permission case; the
  # grep exit-status check below is the general one, because -r cannot see an
  # I/O error and is trivially true for a privileged caller.
  [ -r "$WORK_TRACKING" ] \
    || die "--work-tracking file is not readable: $WORK_TRACKING"
  # grep's own exit status, split three ways: 0 = matched, 1 = no match (a
  # legitimate "no Project row", handled by the -n test below), >=2 = a real
  # read error, which the first cut swallowed with `|| true` and which is
  # exactly how the chmod-000 fail-open got in.
  grep_rc=0
  # shellcheck disable=SC2016 # single-quoted on purpose: nothing here is meant to expand
  PROJECT_ID=$(grep -m1 -oP '(?<=\| Project \| `)[^`]+' "$WORK_TRACKING" 2>"$WORK/wt.err") || grep_rc=$?
  [ "$grep_rc" -lt 2 ] \
    || die "could not read $WORK_TRACKING (grep exit $grep_rc): $(cat "$WORK/wt.err")"
  [ -n "$PROJECT_ID" ] \
    || die "could not parse a Project id out of $WORK_TRACKING (expected a '| Project | \`<id>\` |' row)"
fi

# ---------------------------------------------------------------------------
# Candidate pool: open `deferred` issues. --milestone scopes to that
# milestone's members PLUS milestone-less deferred issues (the flush rule
# needs both in the same pool); no --milestone pulls every open deferred
# issue repo-wide and the flush check never runs.
# ---------------------------------------------------------------------------
: > "$WORK/issues.jsonl"
JQ_ISSUE='.[] | select(.pull_request==null) | {number:.number, title:.title, body:(.body//""), labels:[.labels[].name], milestone:(.milestone.number//null), parent_issue_url:(.parent_issue_url//null), blocked_by:(.issue_dependencies_summary.blocked_by//0)}'
if [ -n "$MILESTONE" ]; then
  gh api --paginate "repos/$REPO/issues?labels=deferred&state=open&milestone=$MILESTONE&per_page=100" \
    --jq "$JQ_ISSUE" >> "$WORK/issues.jsonl" 2>"$WORK/err1" \
    || die "GET repos/$REPO/issues?milestone=$MILESTONE failed: $(cat "$WORK/err1")"
  gh api --paginate "repos/$REPO/issues?labels=deferred&state=open&milestone=none&per_page=100" \
    --jq "$JQ_ISSUE" >> "$WORK/issues.jsonl" 2>"$WORK/err2" \
    || die "GET repos/$REPO/issues?milestone=none failed: $(cat "$WORK/err2")"
else
  gh api --paginate "repos/$REPO/issues?labels=deferred&state=open&per_page=100" \
    --jq "$JQ_ISSUE" >> "$WORK/issues.jsonl" 2>"$WORK/err3" \
    || die "GET repos/$REPO/issues?labels=deferred failed: $(cat "$WORK/err3")"
fi

# ---------------------------------------------------------------------------
# Parked pool (#802 riders): closed issues carrying `parked`, same
# milestone scoping as the open pool above.
# ---------------------------------------------------------------------------
: > "$WORK/parked.jsonl"
if [ -n "$MILESTONE" ]; then
  gh api --paginate "repos/$REPO/issues?labels=parked&state=closed&milestone=$MILESTONE&per_page=100" \
    --jq "$JQ_ISSUE" >> "$WORK/parked.jsonl" 2>"$WORK/perr1" \
    || die "GET repos/$REPO/issues?labels=parked&milestone=$MILESTONE failed: $(cat "$WORK/perr1")"
  gh api --paginate "repos/$REPO/issues?labels=parked&state=closed&milestone=none&per_page=100" \
    --jq "$JQ_ISSUE" >> "$WORK/parked.jsonl" 2>"$WORK/perr2" \
    || die "GET repos/$REPO/issues?labels=parked&milestone=none failed: $(cat "$WORK/perr2")"
else
  gh api --paginate "repos/$REPO/issues?labels=parked&state=closed&per_page=100" \
    --jq "$JQ_ISSUE" >> "$WORK/parked.jsonl" 2>"$WORK/perr3" \
    || die "GET repos/$REPO/issues?labels=parked failed: $(cat "$WORK/perr3")"
fi

# ---------------------------------------------------------------------------
# Board Status per issue (#738): one paginated GraphQL walk of every item on
# the project named by --work-tracking's `Project` id, the same query
# skeleton board-audit.sh's part (a) uses — the pagination loop itself is
# shared via lib/project-items-walk.sh (#867); only the query's own field
# selection and the per-page extraction below are specific to this script.
# An issue at Status "In progress" or "In review" already has a live agent
# or open PR on it; batching it again is the collision #738 exists to
# prevent.
# ---------------------------------------------------------------------------
: > "$WORK/board_status.jsonl"
if [ "$BOARD_STATUS" -eq 1 ]; then
  # shellcheck disable=SC2016 # single-quoted on purpose: $id/$cursor are GraphQL variables, not shell ones
  GQL_STATUS_QUERY='query($id: ID!, $cursor: String = null) { node(id: $id) { ... on ProjectV2 { items(first: 100, after: $cursor) { pageInfo { hasNextPage endCursor } nodes { content { ... on Issue { number repository { nameWithOwner } } } status: fieldValueByName(name: "Status") { ... on ProjectV2ItemFieldSingleSelectValue { name } } } } } } }'
  gh_project_items_walk "$PROJECT_ID" "$GQL_STATUS_QUERY" "$WORK/board_status.pages" "project-status"
  jq -c --arg repo "$REPO" '.data.node.items.nodes[] | select(.content!=null) | select(.content.repository.nameWithOwner==$repo) | {number:.content.number, status:(.status.name // "")}' \
    "$WORK/board_status.pages" >> "$WORK/board_status.jsonl"
fi
board_status_of(){ # board_status_of <issue-number> — prints Status name, or "" if off-board
  # `jq -s … | first`, never `jq … | head -1` (N6): under `set -o pipefail`,
  # `head` closing the pipe on a second matching row would SIGPIPE jq and abort
  # the whole script at this assignment.
  jq -rs --argjson n "$1" '(map(select(.number==$n)) | first | .status) // ""' "$WORK/board_status.jsonl"
}

# ---------------------------------------------------------------------------
# Unit derivation + exclusions, per issue.
# ---------------------------------------------------------------------------
unit_has_line(){ # unit_has_line <body-file>
  # SKILL.md's own normative extraction, verbatim:
  # `grep -m1 -E '^Unit:[[:blank:]]+'` — `-m1` takes the FIRST match only
  # (a second `Unit:` line is not an error; it is simply never read), and
  # `[[:blank:]]` (space or tab), NEVER the hand-rolled class `[ \t]`: in a
  # POSIX ERE bracket expression a backslash has no special meaning, so
  # `[ \t]` is the three-literal-character set {space, backslash, `t`},
  # not "space or tab" — a real tab-separated `Unit:` line is legal and a
  # `[ \t]`-based extractor refuses it (the defect that cost #800/#808 a
  # full review round). Returns success (exit 0) iff a match exists; the
  # caller uses this only as a yes/no gate, not a count — see the header
  # comment for why a second line is not itself a failure mode.
  grep -qm1 -E '^Unit:[[:blank:]]+' "$1"
}

unit_marker_value(){ # unit_marker_value <body-file>
  # Precondition (checked by the caller via unit_has_line first): at least
  # one `Unit:` line exists. `grep -m1` takes the FIRST such line only, per
  # SKILL.md ("The first matching line in the body is the marker and any
  # later one is ignored"). Strips the `Unit:` key and the blanks after
  # it, then trims trailing whitespace — nothing else may share the line,
  # so anything left over (a trailing comment, a second path, backtick
  # wrapping, a comma list) is not a value this function accepts and is
  # left for the charset/form check in the caller to refuse. Prints the
  # raw value UNVALIDATED; validating it against the three legal forms
  # (file path / directory path / area:* label) is the caller's job, since
  # this function's only responsibility is the lexical strip.
  local body="$1" line
  line=$(grep -m1 -E '^Unit:[[:blank:]]+' "$body")
  printf '%s' "$line" | sed -E 's/^Unit:[[:blank:]]+//; s/[[:space:]]+$//'
}

unit_value_form(){ # unit_value_form <value> — prints "area", "dir", "file", or nothing (invalid)
  # SKILL.md: "Exactly one of three forms and nothing else: a
  # repo-relative file path …; a repo-relative directory path with a
  # trailing `/` …; or an `area:*` label … when the finding has no path at
  # all." A colon anywhere outside the literal `area:` prefix, or any
  # character outside a path-safe charset, is not one of the three forms.
  # A trailing "." is refused outright regardless of form — SKILL.md's
  # lexical rule states "nothing else may share the line — no trailing
  # comment, no trailing punctuation" and no legitimate repo-relative path
  # or `area:*` label in this repo ends in a bare period, so a trailing
  # one is sentence punctuation a filer left on the line, not part of the
  # value (see B-trailing-period fixture: this is what catches it).
  local v="$1"
  case "$v" in
    '') return 1 ;;
    *.) return 1 ;;
    area:*)
      case "$v" in
        area:*[!a-z0-9-]*|area:) return 1 ;;
        *) printf 'area'; return 0 ;;
      esac
      ;;
  esac
  case "$v" in
    *[!A-Za-z0-9_./-]*) return 1 ;;
  esac
  case "$v" in
    */) printf 'dir' ;;
    *) printf 'file' ;;
  esac
}

unit_batch_key(){ # unit_batch_key <value> <form>
  # maintenance.md § 1 step 9's normalisation, verbatim — the ONLY mapping
  # between a `Unit:` value and the batch key two items compare on; #802's
  # rider placement compares keys THIS function produces, so it must not
  # be reimplemented differently anywhere else in this script:
  #   - a FILE path whose basename is `<x>.sh` or `test_<x>.sh` (equally
  #     `test-<x>.sh`) maps to the bare stem `<x>`, underscores folded to
  #     hyphens — basename-only, regardless of which directory either one
  #     lives in (no "parent must be scripts/tests" requirement — that
  #     belonged to the old, now-removed Affected-Files derivation only);
  #   - any OTHER file path maps to its directory, WITH the trailing `/`;
  #   - a DIRECTORY value (already trailing `/`) maps to itself, unchanged;
  #   - an `area:*` value maps to itself, unchanged.
  local v="$1" form="$2" base stem
  case "$form" in
    area) printf '%s' "$v"; return ;;
    dir) printf '%s' "$v"; return ;;
  esac
  base="${v##*/}"
  case "$base" in
    test_*.sh|test-*.sh)
      stem="${base#test_}"; stem="${stem#test-}"; stem="${stem%.sh}"
      printf '%s' "${stem//_/-}"
      ;;
    *.sh)
      stem="${base%.sh}"
      printf '%s' "${stem//_/-}"
      ;;
    *)
      # step 9's own words are "any other file path maps to its
      # directory, with the trailing `/`" — a repo-ROOT file (no `/` in
      # the value at all: `AGENTS.md`, `Makefile`) has no directory
      # component for step 9 to name, and step 9's own examples are all
      # skill-scoped paths that never exercise this case, so this is a
      # gap in step 9 rather than a case it answers (relayed finding on
      # #751/PR #830 review round 1; see the PR body for the argument).
      # This function's own reading: the "directory" a repo-root file
      # sits in IS the repo root, and the unambiguous, dirname(1)-
      # consistent way to name that directory — never the filename
      # itself with a slash appended, which collides a real directory
      # named `AGENTS.md/` with a file `AGENTS.md` and is not "its
      # directory" under any reading — is `./`. #802 compares batch keys
      # against this function's output, so the value has to be something
      # a second repo-root file can also produce and match: `./` is
      # exactly that, the same way `dirname AGENTS.md` prints `.` and
      # every other repo-root file would too.
      case "$v" in
        */*) printf '%s/' "${v%/*}" ;;
        *) printf './' ;;
      esac
      ;;
  esac
}

PARENT_LABEL_CACHE="$WORK/parent_labels"
mkdir -p "$PARENT_LABEL_CACHE"
parent_has_epic_label(){ # parent_has_epic_label <parent-number>
  local n="$1"
  local cache="$PARENT_LABEL_CACHE/$n"
  if [ ! -f "$cache" ]; then
    gh api "repos/$REPO/issues/$n" --jq '[.labels[].name] | join(",")' > "$cache" 2>"$WORK/perr_$n" \
      || die "GET repos/$REPO/issues/$n (parent lookup) failed: $(cat "$WORK/perr_$n")"
  fi
  tr ',' '\n' < "$cache" | grep -qx 'epic'
}

: > "$WORK/candidates.jsonl"
: > "$WORK/excluded.jsonl"
while IFS= read -r rec; do
  [ -n "$rec" ] || continue
  number=$(jq -r .number <<<"$rec")
  title=$(jq -r .title <<<"$rec")
  labels_csv=$(jq -r '.labels|join(",")' <<<"$rec")
  milestone=$(jq -r '.milestone // "null"' <<<"$rec")
  blocked_by=$(jq -r .blocked_by <<<"$rec")
  parent_url=$(jq -r '.parent_issue_url // ""' <<<"$rec")

  # --- exclusions, in the prose's own order ---
  if [ "$blocked_by" != "0" ] && [ "$blocked_by" != "null" ]; then
    jq -nc --argjson n "$number" --arg t "$title" --arg r "blocked-by link ($blocked_by open blocker(s))" \
      '{issue:$n, title:$t, reason:$r}' >> "$WORK/excluded.jsonl"
    continue
  fi
  if printf '%s' "$labels_csv" | tr ',' '\n' | grep -qx 'question'; then
    jq -nc --argjson n "$number" --arg t "$title" --arg r "decision-shaped (question label): asks for a decision rather than a fix" \
      '{issue:$n, title:$t, reason:$r}' >> "$WORK/excluded.jsonl"
    continue
  fi
  if [ -n "$parent_url" ]; then
    parent_num="${parent_url##*/}"
    if [[ "$parent_num" =~ ^[0-9]+$ ]] && parent_has_epic_label "$parent_num"; then
      jq -nc --argjson n "$number" --arg t "$title" --arg r "planned child of epic #$parent_num" \
        '{issue:$n, title:$t, reason:$r}' >> "$WORK/excluded.jsonl"
      continue
    fi
  fi
  board_status=$(board_status_of "$number")
  if [ "$board_status" = "In progress" ] || [ "$board_status" = "In review" ]; then
    jq -nc --argjson n "$number" --arg t "$title" --arg r "already in an open PR (board Status: $board_status) — #738" \
      '{issue:$n, title:$t, reason:$r}' >> "$WORK/excluded.jsonl"
    continue
  fi

  # --- unit derivation: structured "Unit:" marker only (#751; lexical
  # form SKILL.md, batch-key normalisation maintenance.md § 1 step 9) ---
  bodyfile="$WORK/body_$number.md"
  jq -r .body <<<"$rec" > "$bodyfile"
  note=""
  if ! unit_has_line "$bodyfile"; then
    jq -nc --argjson n "$number" --arg t "$title" \
      --arg r "no Unit: marker in body — cannot derive a unit (structured-marker-only derivation, #751 — no fallback, see SKILL.md's Deferred Items rule)" \
      '{issue:$n, title:$t, reason:$r}' >> "$WORK/excluded.jsonl"
    continue
  fi
  value=$(unit_marker_value "$bodyfile")
  form=$(unit_value_form "$value" || true)
  if [ -z "$form" ]; then
    jq -nc --argjson n "$number" --arg t "$title" \
      --arg r "Unit: marker present but not one of the three legal forms (file path / directory path with trailing / / area:* label) — cannot derive a unit" \
      '{issue:$n, title:$t, reason:$r}' >> "$WORK/excluded.jsonl"
    continue
  fi
  unit=$(unit_batch_key "$value" "$form")
  if [ -z "$unit" ]; then
    jq -nc --argjson n "$number" --arg t "$title" \
      --arg r "Unit: marker \`$value\` mapped to no usable unit — cannot derive a unit" \
      '{issue:$n, title:$t, reason:$r}' >> "$WORK/excluded.jsonl"
    continue
  fi
  derivation="unit-marker"

  # --- priority rank, highest first ---
  if printf '%s' "$labels_csv" | tr ',' '\n' | grep -qx 'priority:high'; then rank=3; prio="high"
  elif printf '%s' "$labels_csv" | tr ',' '\n' | grep -qx 'priority:medium'; then rank=2; prio="medium"
  elif printf '%s' "$labels_csv" | tr ',' '\n' | grep -qx 'priority:low'; then rank=1; prio="low"
  else rank=0; prio="none"
  fi

  jq -nc --argjson n "$number" --arg t "$title" --arg u "$unit" --arg d "$derivation" \
    --arg note "$note" --arg prio "$prio" --argjson rank "$rank" \
    --argjson ms "$milestone" \
    '{issue:$n, title:$t, unit:$u, derivation:$d, note:$note, priority:$prio, rank:$rank, milestone:$ms, role:"member"}' \
    >> "$WORK/candidates.jsonl"
done < "$WORK/issues.jsonl"

# ---------------------------------------------------------------------------
# Parked riders (#802): unit derivation is the SAME function set the open
# pool uses above — a parked item was filed under the same `Unit:` marker
# requirement before it was closed, so there is no second derivation rule.
# A parked candidate whose body carries no valid marker is excluded (same
# reason shape, "(parked candidate)" appended so the reader can tell the
# two pools apart); one carrying a `Rejected:` comment is excluded with
# that reason and never rides. Everything else lands in riders.jsonl, ready
# for the grouping loop below to place — or not — by unit and cap.
# ---------------------------------------------------------------------------
: > "$WORK/riders.jsonl"
while IFS= read -r rec; do
  [ -n "$rec" ] || continue
  number=$(jq -r .number <<<"$rec")
  title=$(jq -r .title <<<"$rec")
  labels_csv=$(jq -r '.labels|join(",")' <<<"$rec")

  comments_json=$(gh api --paginate "repos/$REPO/issues/$number/comments" --jq '[.[].body]' 2>"$WORK/cerr_$number") \
    || die "GET repos/$REPO/issues/$number/comments failed: $(cat "$WORK/cerr_$number")"
  rejected_reason=$(jq -r '[.[] | select(startswith("Rejected:"))] | first // ""' <<<"$comments_json")
  if [ -n "$rejected_reason" ]; then
    jq -nc --argjson n "$number" --arg t "$title" --arg r "rider excluded: $rejected_reason" \
      '{issue:$n, title:$t, reason:$r}' >> "$WORK/excluded.jsonl"
    continue
  fi

  bodyfile="$WORK/rbody_$number.md"
  jq -r .body <<<"$rec" > "$bodyfile"
  if ! unit_has_line "$bodyfile"; then
    jq -nc --argjson n "$number" --arg t "$title" \
      --arg r "no Unit: marker in body (parked candidate) — cannot derive a unit" \
      '{issue:$n, title:$t, reason:$r}' >> "$WORK/excluded.jsonl"
    continue
  fi
  value=$(unit_marker_value "$bodyfile")
  form=$(unit_value_form "$value" || true)
  if [ -z "$form" ]; then
    jq -nc --argjson n "$number" --arg t "$title" \
      --arg r "Unit: marker present but not one of the three legal forms (parked candidate) — cannot derive a unit" \
      '{issue:$n, title:$t, reason:$r}' >> "$WORK/excluded.jsonl"
    continue
  fi
  unit=$(unit_batch_key "$value" "$form")
  if [ -z "$unit" ]; then
    jq -nc --argjson n "$number" --arg t "$title" \
      --arg r "Unit: marker \`$value\` mapped to no usable unit (parked candidate) — cannot derive a unit" \
      '{issue:$n, title:$t, reason:$r}' >> "$WORK/excluded.jsonl"
    continue
  fi

  if printf '%s' "$labels_csv" | tr ',' '\n' | grep -qx 'priority:high'; then rank=3; prio="high"
  elif printf '%s' "$labels_csv" | tr ',' '\n' | grep -qx 'priority:medium'; then rank=2; prio="medium"
  elif printf '%s' "$labels_csv" | tr ',' '\n' | grep -qx 'priority:low'; then rank=1; prio="low"
  else rank=0; prio="none"
  fi

  jq -nc --argjson n "$number" --arg t "$title" --arg u "$unit" \
    --arg prio "$prio" --argjson rank "$rank" \
    '{issue:$n, title:$t, unit:$u, derivation:"unit-marker", note:"", priority:$prio, rank:$rank, milestone:null, role:"rider"}' \
    >> "$WORK/riders.jsonl"
done < "$WORK/parked.jsonl"

take_riders_for_unit(){ # take_riders_for_unit <unit> <room> — prints a
  # JSON array of at most <room> riders for <unit>, highest priority:*
  # first (issue number ascending as a stable tiebreak), and REMOVES them
  # from riders.jsonl so a later chunk of the same unit never reuses one.
  local u="$1" room="$2" taken taken_issues
  if [ "$room" -le 0 ]; then echo '[]'; return; fi
  taken=$(jq -c --arg u "$u" 'select(.unit==$u)' "$WORK/riders.jsonl" \
    | jq -s --argjson n "$room" 'sort_by([-.rank, (.issue|tonumber)]) | .[0:$n]')
  taken_issues=$(jq -c '[.[].issue]' <<<"$taken")
  jq -c --argjson ti "$taken_issues" 'select((.issue as $x | ($ti|index($x))) | not)' "$WORK/riders.jsonl" \
    > "$WORK/riders.jsonl.tmp" || true
  mv "$WORK/riders.jsonl.tmp" "$WORK/riders.jsonl"
  printf '%s' "$taken"
}

# ---------------------------------------------------------------------------
# Flush detection: for each distinct real (non-null) milestone number
# appearing among the candidates, GET its open issues and check whether any
# lack the `deferred` label (a still-open planned child). Skipped entirely
# under --flush (every milestone is treated as flushed without the extra
# call) and skipped when the candidate pool has no real milestone at all.
# ---------------------------------------------------------------------------
: > "$WORK/flushed_milestones.txt"
if [ "$FLUSH" -eq 0 ]; then
  MS_NUMS=$(jq -r 'select(.milestone!=null) | .milestone' "$WORK/candidates.jsonl" | sort -un || true)
  for m in $MS_NUMS; do
    [ -n "$m" ] || continue
    open_planned=$(gh api --paginate "repos/$REPO/issues?milestone=$m&state=open&per_page=100" \
      --jq '.[] | select(.pull_request==null) | select([.labels[].name] | index("deferred") | not)' 2>"$WORK/ferr_$m" \
      | wc -l) || die "GET repos/$REPO/issues?milestone=$m (flush check) failed: $(cat "$WORK/ferr_$m")"
    if [ "$open_planned" -eq 0 ]; then
      echo "$m" >> "$WORK/flushed_milestones.txt"
    fi
  done
fi

# ---------------------------------------------------------------------------
# Group by unit, order members by priority (rank desc, issue number asc as
# a stable tiebreak), determine dispatchable/flush-eligible, split >MAX.
# ---------------------------------------------------------------------------
UNITS=$(jq -r '.unit' "$WORK/candidates.jsonl" | sort -u)
: > "$WORK/batches.jsonl"
while IFS= read -r unit; do
  [ -n "$unit" ] || continue
  members_sorted=$(jq -c --arg u "$unit" 'select(.unit==$u)' "$WORK/candidates.jsonl" \
    | jq -s 'sort_by([-.rank, (.issue|tonumber)])')
  n=$(jq 'length' <<<"$members_sorted")

  # Flush eligibility: all members share a single real milestone (nulls
  # allowed alongside it) and that milestone is in flushed_milestones.txt,
  # OR --flush was given. Members spanning more than one real milestone
  # never flush (threshold only).
  real_ms=$(jq -r '[.[] | select(.milestone!=null) | .milestone] | unique | .[]' <<<"$members_sorted")
  real_ms_count=$(printf '%s\n' "$real_ms" | grep -c . || true)
  flush_eligible=0
  if [ "$FLUSH" -eq 1 ]; then
    flush_eligible=1
  elif [ "$real_ms_count" -eq 1 ]; then
    only_ms=$(printf '%s\n' "$real_ms" | head -1)
    if grep -qx "$only_ms" "$WORK/flushed_milestones.txt" 2>/dev/null; then
      flush_eligible=1
    fi
  fi

  dispatchable=0
  if [ "$n" -ge "$MIN" ] || [ "$flush_eligible" -eq 1 ]; then
    dispatchable=1
  fi

  if [ "$n" -gt "$MAX" ] && [ "$dispatchable" -eq 1 ]; then
    # Split by priority order, highest first: full MAX-sized chunks are
    # dispatchable (the whole unit already met threshold/flush); the
    # remainder is its own batch of the same unit and always waits, per
    # the prose ("the remainder waits as its own batch of the same unit").
    offset=0
    while [ "$offset" -lt "$n" ]; do
      chunk=$(jq -c --argjson off "$offset" --argjson max "$MAX" '.[$off:$off+$max]' <<<"$members_sorted")
      remaining=$((n - offset))
      if [ "$remaining" -ge "$MAX" ]; then
        chunk_dispatchable=true
      else
        chunk_dispatchable=false
      fi
      # Riders (#802): only a dispatchable chunk gets any, only up to
      # whatever room is left under --max after this chunk's OPEN members
      # — a full MAX-sized chunk has none.
      if [ "$chunk_dispatchable" = true ]; then
        chunk_len=$(jq 'length' <<<"$chunk")
        room=$((MAX - chunk_len))
        riders_taken=$(take_riders_for_unit "$unit" "$room")
        chunk=$(jq -c --argjson r "$riders_taken" '. + $r' <<<"$chunk")
      fi
      jq -c --arg u "$unit" --argjson d "$chunk_dispatchable" --argjson fe "$([ "$flush_eligible" -eq 1 ] && echo true || echo false)" \
        '{unit:$u, dispatchable:$d, flush_eligible:$fe, members:.}' <<<"$chunk" >> "$WORK/batches.jsonl"
      offset=$((offset + MAX))
    done
  else
    if [ "$dispatchable" -eq 1 ]; then
      room=$((MAX - n))
      riders_taken=$(take_riders_for_unit "$unit" "$room")
      members_sorted=$(jq -c --argjson r "$riders_taken" '. + $r' <<<"$members_sorted")
    fi
    jq -c --arg u "$unit" --argjson d "$([ "$dispatchable" -eq 1 ] && echo true || echo false)" \
      --argjson fe "$([ "$flush_eligible" -eq 1 ] && echo true || echo false)" \
      '{unit:$u, dispatchable:$d, flush_eligible:$fe, members:.}' <<<"$members_sorted" >> "$WORK/batches.jsonl"
  fi
done <<<"$UNITS"

BATCHES=$(jq -s '.' "$WORK/batches.jsonl" 2>/dev/null || echo '[]')
[ -n "$BATCHES" ] || BATCHES='[]'
EXCLUDED=$(jq -s '.' "$WORK/excluded.jsonl" 2>/dev/null || echo '[]')
[ -n "$EXCLUDED" ] || EXCLUDED='[]'
GENERATED_AT=$(date -u +%FT%TZ)

RESULT=$(jq -n \
  --arg repo "$REPO" --arg milestone "$MILESTONE" --argjson min "$MIN" --argjson max "$MAX" \
  --argjson flush_override "$([ "$FLUSH" -eq 1 ] && echo true || echo false)" \
  --argjson excluded "$EXCLUDED" --argjson batches "$BATCHES" --arg generated_at "$GENERATED_AT" \
  --argjson exclusions_skipped "$BOARD_STATUS_SKIPPED" \
  '{
    repo: $repo,
    milestone: (if $milestone=="" then null else ($milestone|tonumber) end),
    min: $min, max: $max, flush_override: $flush_override,
    excluded: $excluded,
    exclusions_skipped: $exclusions_skipped,
    batches: $batches,
    generated_at: $generated_at
  }')

if [ "$MARKDOWN" -eq 1 ]; then
  jq -r '
    "### Batch proposals — \(.repo)" +
    (if .milestone != null then " (milestone #\(.milestone))" else "" end) + "\n" +
    "- min=\(.min) max=\(.max) flush_override=\(.flush_override)\n" +
    ( .batches | map(
        "- unit `\(.unit)`: " + (.members|length|tostring) + " member(s), dispatchable=" +
        (.dispatchable|tostring) + " (flush_eligible=" + (.flush_eligible|tostring) + ")\n" +
        ( .members | map(select(.role!="rider")) | map("  - #\(.issue) [\(.priority)] via \(.derivation)" +
            (if .note != "" then " — \(.note)" else "" end)) | join("\n") ) +
        ( ( .members | map(select(.role=="rider")) ) as $riders |
          if ($riders|length) > 0 then
            "\n  - riders:\n" + ( $riders | map("    - #\(.issue) [\(.priority)] (rider)") | join("\n") )
          else "" end )
      ) | join("\n") ) +
    (if (.excluded|length) > 0 then
      "\n\n#### Excluded\n" + ( .excluded | map("- #\(.issue) — \(.reason)") | join("\n") )
     else "" end) +
    "\n\n#### triage.batches\n```json\n" +
    ( [ .batches[] | {
          unit,
          members:[.members[]|select(.role!="rider")|.issue|tonumber],
          riders:[.members[]|select(.role=="rider")|.issue|tonumber],
          dispatchable
        } ] | tostring ) +
    "\n```"
  ' <<<"$RESULT"
else
  printf '%s\n' "$RESULT"
fi
