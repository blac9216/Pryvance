#!/usr/bin/env bash
# history.sh — build the estimation calibration table from repository history
# via GraphQL. READ-ONLY.
#
# Usage: history.sh --repo owner/name [--since YYYY-MM-DD (default: 90 days
#   ago)] [--adoption-date YYYY-MM-DD] [--out <dir>] [--refresh]
#   [--aggregate-only] [--min-remaining N (default 1500)] [--page-size N
#   (default 20)] [--logs <dir> (archived session-log JSONL, optional)]
# Exit codes — this list is EXHAUSTIVE. 0 full run, or --aggregate-only,
#   completed with nothing dropped; 1 rate-guard stopped the run before
#   exhaustion (calibration.md carries a "PARTIAL — N of ~M merged PRs
#   processed" header — see below), or a fatal collection error: a `gh api
#   graphql` call failed, the response's rate limit was unreadable, --out is
#   stale (provenance mismatch or absent), issues.jsonl exists but is not
#   readable, or issues.jsonl carries a malformed record line that is NOT its
#   trailing partial line (see "Resume" below); 2 usage error (missing --repo, unknown/invalid flag) —
#   no `gh` call is made on this path; 3 the run finished every page but at
#   least one merged PR node's record extraction failed, so the output is
#   missing every issue those PRs closed (each one named on stderr, and
#   counted in completeness.dropped_pr_nodes). A dropped record is never
#   silent and never exits 0. Nothing else is emitted, and the guarantee does
#   not rest on the escaped status being outside the list above: every
#   deliberate exit raises an EXIT_INTENDED sentinel first, so the EXIT trap
#   reports ANY unsentinelled failure as 1 — including one whose raw status
#   happens to be 2 or 3 (awk exits 2 on an unreadable file) and would
#   otherwise reach the caller wearing another code's documented meaning.
#
# Resume tolerance (AC-4): a run interrupted mid-append leaves a truncated
#   final line in issues.jsonl. That one trailing partial line is repaired —
#   dropped, loudly, on stderr — and the run resumes from the complete
#   records before it. The "issue:pr" dedupe set is built line by line and is
#   NEVER emptied by a parse failure: emptying it would silently re-append
#   records the file already holds and glue them onto the partial line. A
#   malformed line anywhere else is corruption rather than an interruption
#   artifact and is a named stop (exit 1) pointing at --refresh.
#
# AC-6 (EXIT trap): once collection has begun, EVERY exit path rebuilds
#   calibration.md/.json from the issues.jsonl that exists at exit — the
#   clean paths call `aggregate` directly, and any other exit (a failed `gh`
#   call, an unreadable rate limit, an unexpected error) is caught by the
#   EXIT trap, which rebuilds the table with a "CUT SHORT" header. A
#   calibration table describing fewer records than issues.jsonl holds is
#   unreachable by construction, not by remembering to add a call.
#
# PARTIAL header (AC-5): "N of ~M merged PRs processed" counts merged PRs on
#   both sides — N is the --since-window PRs processed from the pages
#   fetched, ~M is N plus the merged PRs never fetched (totalCount − PRs
#   seen). ~M is an upper bound: `pullRequests.totalCount` is not filtered by
#   --since. Issue records are NOT the unit here (the measured run below
#   yielded 473 records from 202 merged PRs, ≈2.3 records per merged PR),
#   and their count is reported separately on the table's "Records:" line.
#
# A malformed `<!-- metrics {...} -->` footer costs only that field:
#   the record is kept with `metrics: null` and `metrics_malformed: true`,
#   counted as completeness.malformed_metrics. Losing the whole record — and
#   with it every sibling issue on the same PR — is the failure exit 3 exists
#   to make visible, not something a single bad footer should trigger.
#
# size_est comes from the issue's `size:*` label (`size:s|m|l` → S|M|L, no
#   label → null), per #734 and #201's scope note (decision B4) — never from
#   the `## Estimate` prose. `estimate_text` is still recorded as free text
#   for reference, but nothing parses it.
#
# rounds/findings (#289, epic #773 decision B3, amended 2026-09-06): the
#   `<!-- review {"v":1,"round":N,"verdict":…,"findings":[…]} -->` footer on
#   a PR comment is the ONLY round/findings source. There is NO heading
#   fallback: B3 reads "Count rounds from the review footer only. PRs
#   without a footer get rounds=null and are excluded from round
#   statistics; the exclusion count is printed. No heading fallback." A PR
#   carrying at least one parseable footer records `rounds` = the max
#   `.round` across its footers, `findings` = the per-footer `.findings`
#   length array, and `rounds_source: "footer"`. A PR carrying none records
#   `rounds: null`, `findings: []` and `rounds_source: null` — it still
#   counts toward `n`, cycle_hours and net_loc, which are measured
#   independently of any footer, but never toward rounds_p50 or
#   first_pass_rate. `aggregate` reports `rounds_n` (how many of a block's
#   `n` records carried a footer) and `rounds_excluded` (`n - rounds_n`)
#   next to those two figures, prints the repo-wide exclusion count on
#   stderr, and carries both into calibration.md's table and its
#   "Rounds statistics" line, so a rounds_p50 drawn from a subset of `n` is
#   never silent.
#
# first_pass_rate (#289, round-1 finding 1): "first pass" is defined for
#   footer semantics, where a review round starts at 1 — NOT as `rounds==0`,
#   which was the pre-footer heading-count shape and is unsatisfiable under
#   footer sourcing (no footer ever carries round 0), so reusing it renders
#   the statistic a constant 0. A record is first-pass when ALL of:
#   (a) it is footer-sourced; (b) no footer on the PR carries a
#   `changes_requested`, `decomposition_requested` or `escalated` verdict;
#   (c) its max footer round is 1; and (d) the round-1 footer's verdict is
#   `approved`. That is "approved at round 1 with no earlier changes
#   requested", recorded per record as the boolean `first_pass` (null when
#   the record is not footer-sourced) and aggregated as the percentage of
#   `rounds_n` that are true. The verdict vocabulary is
#   github-pr-review's: approved / changes_requested /
#   decomposition_requested / escalated.
#
# Footer extraction (round-1 finding 6) matches only a footer occupying a
#   WHOLE LINE of a comment body — `(?m)^<!-- review ({…}) -->$` — so a
#   footer quoted inside prose, indented, or trailed by other text on the
#   same line is not mistaken for a real one, and takes the LAST such line
#   in a body, since a comment that quotes an example emits its own footer
#   after it. `fromjson` is tried PER candidate rather than around the whole
#   extraction chain: an unparseable candidate can never void a comment's
#   valid footer, and a comment whose last whole-line candidate does not
#   parse is counted in the record's `review_footers_malformed` and in
#   completeness.malformed_review_footers rather than silently dropped.
#
# triage (#289): each record's `triage_at`/`triage_source`/`triage_decision`
#   answer "when, and how, was this issue triaged". The primary source is an
#   archived session log's `triage` event (see --logs below) naming this
#   issue — `triage_source: "session-log"`, `triage_at` its `ts`,
#   `triage_decision` its `decision` text. Without log coverage, the
#   fallback is the issue's own `LabeledEvent`/`MilestonedEvent` timeline
#   items — `triage_source: "timeline"`, `triage_at` the EARLIEST of the two
#   kinds' `createdAt`. Neither present → all three fields `null`.
#
# --logs <dir> (optional, #289): a directory of archived session-log JSONL
#   files (one event per line, `../../github-workflow/references/formats/
#   session-log.md`). Every `*.jsonl` file directly under it is read (not
#   recursive). Two event kinds are consulted, both matched by their
#   `.issue` field: `triage` (see above) and `report` (role `implementer`,
#   `issue` set) — the latter's `tokens`/`duration_s`/`outcome` are recorded
#   as `metrics`/`metrics_source: "session-log"` in place of the PR comment's
#   `<!-- metrics {…} -->` footer, since the log already carries them
#   without needing that footer parsed for this issue. When more than one
#   `report` line names the same issue, the chronologically LAST one wins.
#   `--logs` is optional and additive in its OUTPUT: a run without it
#   behaves exactly as before, sourcing metrics from the footer alone and
#   triage from the timeline alone.
#
#   The saving is a real API saving, not a parse saving (round-1 finding 3).
#   Issue-level `comments(first: 100)` is fetched for one reason only — the
#   `<!-- metrics {…} -->` footer — so when the archive already carries an
#   issue's metrics that sub-selection is waste. Whenever `--logs` yields a
#   NON-EMPTY metrics map the page query is the LIGHT variant, which omits
#   the issue-level comments sub-selection entirely; the page's issues are
#   then partitioned against the archive and the comments of the UNCOVERED
#   ones only are fetched in a second, aliased `issue(number: N)` request.
#   A page every one of whose issues the archive covers therefore makes ONE
#   request and fetches no issue comments at all — that is #289's
#   "fixture archived log yields metrics without the comments call". The
#   honest accounting of the other cases, since a saving stated only in the
#   best case is the reframing this replaces: with no `--logs` (or an
#   archive with no metrics lines) the query is unchanged and a page costs
#   one request as before; with `--logs` and PARTIAL coverage a page costs
#   TWO requests — one light page request plus one comments request for the
#   uncovered issues — which is the price of the saving being real rather
#   than notional. PR-level comments are never affected: they carry the
#   review footers and are always fetched.
#
#   An unreadable `--logs` directory is a named argument error, never an
#   empty archive (round-1 finding 5): `[ -d ]` alone is TRUE for a
#   `chmod 000` directory whose parent is traversable, so the `*.jsonl`
#   glob would fail to expand and the run would be byte-identical to one
#   whose archive covered nothing, silently. Readability and searchability
#   are checked alongside existence, and a `--logs` directory that IS
#   readable but holds no event lines is reported on stderr — "I read the
#   archive and it covered nothing" must be distinguishable from "I could
#   not read the archive".
# Class: machine + minimal-heuristics (github-workflow/references/github-tools.md
#   § "Extraction vs. interpretation"). `--repo` is REQUIRED (#736's outer
#   boundary): there is no `gh repo view` fallback, and the script reads no
#   local config file to discover it.
# Output: <out>/issues.jsonl (resumable — keyed by "issue:pr", one record per
#   closed issue with a merged PR), <out>/calibration.json,
#   <out>/calibration.md, <out>/.provenance.json (the --repo/--since that
#   built issues.jsonl; a mismatched reuse is a hard stop, not a quiet
#   pooling of two samples — --refresh rebuilds), and <out>/.state.json (a
#   resume cursor, deleted on a clean full completion). --out defaults to
#   $TMPDIR/plan-work-history/<owner>__<name>, keyed by repository so two
#   repos' runs cannot land in one directory by default.
#
# Requests: one `gh api graphql` POST per page of up to $PAGE_SIZE merged
#   PRs — plus, on a `--logs` run whose archive covers only SOME of a
#   page's issues, one further request fetching just the uncovered issues'
#   comments (see --logs above; a fully-covered page adds none). Each page
#   returns, in the same round trip, every linked issue's
#   labels/milestone/parent/timeline/comments and the PR's own review
#   comments and diff stats — the REST design this replaces spent 6-8+ calls
#   per issue record (a `pulls/{n}` call, a `pulls/{n}/comments` call, and
#   per linked issue an `issues/{i}` call, a paginated
#   `issues/{i}/timeline` call, a paginated `issues/{i}/comments` call, and
#   a second `issues/{i}` call just for `parent_issue_url` — see #201). The
#   authenticated rate-limit remaining/reset is read off each response's own
#   `rateLimit{remaining resetAt}` field, never a separate `rate_limit`
#   call. Measured against blac9216/storage on 2026-09-06 with
#   --since 2026-06-01: 11 GraphQL page requests (202 merged PRs, page
#   size 20) produced 473 issue records — ≈0.023 requests/record, against
#   the ~15 REST calls/record (with pagination) the design it replaces
#   spent. Requests and records are what this script measures and what the
#   ratio above rests on; point cost is NOT, and varies run to run with the
#   node counts each page returns. The "remaining requests at exit" figure
#   the script prints is the ACCOUNT-WIDE hourly GraphQL budget, so it also
#   moves with whatever else is using the same token: successive runs of THIS
#   SAME command have exited anywhere between ~4,000 and ~4,800 remaining. No
#   exact figure is quoted here on purpose — one would be stale by the next
#   run and would contradict whichever run's stderr it was read against. Do
#   not read a per-run cost off it by subtraction; requests and records, and
#   the ratio above, are what this script actually measures.
#
# `Issue.parent` (GitHub's sub-issues GraphQL field) may not exist on every
# account's schema version; if the primary query is rejected for it, the
# script retries once with that field dropped from the query for the rest
# of the run, and every record's `parent` is `null` for that run (a
# stderr warning names this).
set -euo pipefail

REPO=""
SINCE=$(date -u -d "90 days ago" +%F 2>/dev/null || date -u -v-90d +%F)
ADOPT=""
OUT=""   # default is repo-keyed; set after --repo is parsed (see below)
REFRESH=0
AGG_ONLY=0
MIN_REMAINING=1500
PAGE_SIZE=20
LOGS_DIR=""

while [ $# -gt 0 ]; do
  case $1 in
    --repo) REPO=$2; shift 2 ;;
    --since) SINCE=$2; shift 2 ;;
    --adoption-date) ADOPT=$2; shift 2 ;;
    --out) OUT=$2; shift 2 ;;
    --refresh) REFRESH=1; shift ;;
    --aggregate-only) AGG_ONLY=1; shift ;;
    --min-remaining) MIN_REMAINING=$2; shift 2 ;;
    --page-size) PAGE_SIZE=$2; shift 2 ;;
    --logs) LOGS_DIR=$2; shift 2 ;;
    *) echo "unknown arg $1" >&2; exit 2 ;;
  esac
done

if [ -z "$REPO" ]; then
  echo "--repo is required (owner/name) — no gh repo view fallback (#736)" >&2
  exit 2
fi

case $MIN_REMAINING in ''|*[!0-9]*) echo "--min-remaining must be a non-negative integer, got '$MIN_REMAINING'" >&2; exit 2 ;; esac
case $PAGE_SIZE in ''|*[!0-9]*|0) echo "--page-size must be a positive integer, got '$PAGE_SIZE'" >&2; exit 2 ;; esac
if [ -n "$LOGS_DIR" ]; then
  if [ ! -d "$LOGS_DIR" ]; then
    echo "--logs directory not found: $LOGS_DIR" >&2
    exit 2
  fi
  # A chmod 000 directory is still `-d` when its parent is traversable, and
  # the `*.jsonl` glob below then expands to nothing — indistinguishable
  # from an archive that covered nothing, with nothing on stderr (round-1
  # finding 5). Reading the directory needs BOTH read (to list it) and
  # execute (to stat/open what is listed), so both are checked here.
  if [ ! -r "$LOGS_DIR" ] || [ ! -x "$LOGS_DIR" ]; then
    echo "--logs directory is not readable: $LOGS_DIR (need read and execute permission to list and open its *.jsonl files; refusing to read an unreadable archive as an empty one)" >&2
    exit 2
  fi
fi

# The default --out is keyed by repository: two runs against different repos
# must never land in the same directory and silently pool their records
# (issues.jsonl reuse is guarded by provenance below, but the guard should
# not be the only thing standing between two repos' samples).
[ -n "$OUT" ] || OUT="${TMPDIR:-/tmp}/plan-work-history/${REPO%%/*}__${REPO#*/}"

say(){ printf '%s\n' "$*" >&2; }
# Every DELIBERATE exit past the trap's installation raises EXIT_INTENDED
# first, so the trap can tell a status this script chose from one that escaped
# out of an internal command (see on_exit below). `die` is one of them.
EXIT_INTENDED=0
die(){ say "error: $*"; EXIT_INTENDED=1; exit 1; }

mkdir -p "$OUT"
ISSUES_JSONL="$OUT/issues.jsonl"
STATE="$OUT/.state.json"
[ -f "$ISSUES_JSONL" ] || : > "$ISSUES_JSONL"

# ---------------------------------------------------------------------------
# Aggregation: area × size (size = estimate if present else actual net LOC
# bucket). Extracted into a function so --aggregate-only can re-run it on an
# existing issues.jsonl without any collection (AC-7). $1 is the header
# status line ("" for a clean/full run, or "PARTIAL — N of M records" text).
# $2 is a reset-time note appended to the header when non-empty (partial
# runs only). $3 is the number of merged PR nodes whose record extraction
# failed this run, surfaced as completeness.dropped_pr_nodes so a lossy run
# is visible in the aggregate and not only on stderr; it is JSON `null` on
# the --aggregate-only path, which collects nothing and therefore has no
# figure of its own to report.
# ---------------------------------------------------------------------------
aggregate(){
  local status="$1" reset_note="$2" dropped="${3:-null}"
  jq -s --argjson dropped "$dropped" '
    def bucket: if .size_est!=null then .size_est elif .net_loc<=100 then "S" elif .net_loc<=400 then "M" else "L" end;
    def pct(p): sort | if length==0 then null else .[((length-1)*p)|floor] end;
    # rounds_p50/first_pass_rate (decision B3, #289) are computed ONLY over
    # footer-sourced records — a footer-less record carries rounds null and
    # still counts toward n/cycle/LOC, but never toward these two figures.
    # rounds_n reports how many of n contributed to them and rounds_excluded
    # the rest, so a rounds_p50 drawn from a subset of n is never silent.
    #
    # first_pass_rate is the share of rounds_n whose `first_pass` is true —
    # approved at round 1 with no earlier changes_requested (see the header;
    # round-1 finding 1). The pre-fix predicate was `select(.rounds==0)`,
    # written for heading-count semantics; the round on a review footer
    # starts at 1, so under footer sourcing it is unsatisfiable and the
    # statistic was a structural constant 0.
    def stats: (map(select(.rounds_source=="footer"))) as $withrounds |
      {n:length, cycle_h_p50:(map(.cycle_hours)|pct(0.5)), cycle_h_p80:(map(.cycle_hours)|pct(0.8)),
       rounds_p50:($withrounds|map(.rounds)|pct(0.5)), rounds_n:($withrounds|length),
       rounds_excluded:(length - ($withrounds|length)),
       first_pass_rate:(($withrounds|length) as $n | if $n==0 then null else (($withrounds|map(select(.first_pass==true))|length)/$n*100|round) end),
       loc_p50:(map(.net_loc)|pct(0.5))};
    (map(. + {bucket:bucket})) as $all |
    { repo_median:($all|stats),
      by_size:($all|group_by(.bucket)|map({size:.[0].bucket} + stats)),
      by_area_size:($all|map(. as $r|($r.areas|if length==0 then ["(none)"] else . end)[]|{area:., size:$r.bucket, r:$r})|group_by([.area,.size])|map({area:.[0].area,size:.[0].size} + (map(.r)|stats))),
      estimate_vs_actual:($all|map(select(.size_est!=null))|map({issue,size_est,net_loc,actual_bucket:(if .net_loc<=100 then "S" elif .net_loc<=400 then "M" else "L" end),cycle_hours,rounds,rounds_source})),
      completeness:{with_assigned_start:($all|map(select(.start_source=="assigned"))|length), with_estimate:($all|map(select(.size_est!=null))|length), with_metrics:($all|map(select(.metrics!=null))|length), metrics_from_logs:($all|map(select(.metrics_source=="session-log"))|length), malformed_metrics:($all|map(select(.metrics_malformed==true))|length), with_area:($all|map(select(.areas|length>0))|length), with_footer_rounds:($all|map(select(.rounds_source=="footer"))|length), without_footer_rounds:($all|map(select(.rounds_source!="footer"))|length), malformed_review_footers:($all|map(select((.review_footers_malformed//0)>0))|length), first_pass_records:($all|map(select(.first_pass==true))|length), with_triage:($all|map(select(.triage_source!=null))|length), triage_from_logs:($all|map(select(.triage_source=="session-log"))|length), dropped_pr_nodes:$dropped, total:($all|length)},
      parallelism_note:"observed parallelism requires overlapping started..merged windows; see calibration.md" }' "$ISSUES_JSONL" > "$OUT/calibration.json"
  # Observed parallelism. A failure here (one malformed `started`/`merged`
  # value is enough — the expression calls fromdate on every record) must
  # never render as a plausible-looking number: a literal `1` would reach
  # calibration.md as "observed parallelism: 1.00", indistinguishable from a
  # genuinely computed 1.00, and timeline.sh consumes parallelism.txt as a
  # planning input. The fallback is therefore an EMPTY parallelism.txt — the
  # shape timeline.sh already treats as "no history" and reports falling back
  # from — plus a named stderr note, never a default value.
  local par_display par_value
  if jq -s '[.[]|{s:(.started|fromdate),e:(.merged|fromdate)}]|sort_by(.s)|. as $w|( [$w[].s,$w[].e]|min ) as $t0|( [$w[].e]|max ) as $t1| if $t1<=$t0 then 1 else ([$w[]|(.e-.s)]|add)/($t1-$t0) end' "$ISSUES_JSONL" > "$OUT/parallelism.txt" 2>"$OUT/.par-err"; then
    par_value=$(cat "$OUT/parallelism.txt")
  else
    par_value=""
  fi
  case $par_value in
    ''|*[!0-9.eE+-]*|*[!0-9]) par_display="" ;;
    *) par_display=$(printf '%.2f' "$par_value" 2>/dev/null || echo "") ;;
  esac
  if [ -z "$par_display" ]; then
    say "warning: observed parallelism could not be computed from $ISSUES_JSONL (jq: $(tr '\n' ' ' < "$OUT/.par-err" 2>/dev/null | sed 's/  */ /g'))${par_value:+ — value was: $par_value} — reporting it as 'unavailable' and leaving $OUT/parallelism.txt empty rather than writing a plausible-looking default"
    : > "$OUT/parallelism.txt"
    par_display="unavailable"
  fi
  rm -f "$OUT/.par-err"
  {
    if [ -n "$status" ]; then
      echo "# Calibration — $REPO ($(date -u +%F)) — $status"
      [ -n "$reset_note" ] && echo "# $reset_note"
    else
      echo "# Calibration — $REPO ($(date -u +%F))"
    fi
    echo
    echo "Records: $(jq -s length "$ISSUES_JSONL") · completeness: $(jq -c .completeness "$OUT/calibration.json") · observed parallelism: $par_display"
    echo
    # rounds n / rounds excl. are columns in their own right (round-1 note
    # 7, and decision B3's "the exclusion count is printed"): rounds p50 and
    # first-pass % are computed over the footer-sourced subset alone, so a
    # reader must be able to see, in the same row, how much of that row's n
    # contributed to them. first-pass % is "approved at round 1 with no
    # earlier changes_requested", over rounds n.
    echo "| Area | Size | n | rounds n | rounds excl. | cycle p50 (h) | cycle p80 (h) | rounds p50 | first-pass % | LOC p50 |"
    echo "|---|---|---|---|---|---|---|---|---|---|"
    jq -r '.by_area_size[]|"| \(.area) | \(.size) | \(.n) | \(.rounds_n) | \(.rounds_excluded) | \(.cycle_h_p50) | \(.cycle_h_p80) | \(.rounds_p50) | \(.first_pass_rate) | \(.loc_p50) |"' "$OUT/calibration.json"
    echo
    echo "Rounds statistics (decision B3): rounds p50 and first-pass % are computed over the $(jq -r '.repo_median.rounds_n' "$OUT/calibration.json") footer-sourced record(s) only; $(jq -r '.repo_median.rounds_excluded' "$OUT/calibration.json") record(s) carry no review footer, have rounds null, and are excluded from both. first-pass % = approved at round 1 with no earlier changes_requested."
    echo
    echo "By size: $(jq -c '.by_size' "$OUT/calibration.json")"
    echo
    echo "Repo median: $(jq -c '.repo_median' "$OUT/calibration.json")"
    echo
    echo "Estimate vs actual (n=$(jq '.estimate_vs_actual|length' "$OUT/calibration.json")): $(jq -c '.estimate_vs_actual' "$OUT/calibration.json")"
  } > "$OUT/calibration.md"
  # Decision B3: "the exclusion count is printed". On stderr as well as in
  # the table, so a run watched from a terminal shows how much of the sample
  # the rounds statistics rest on without opening the file.
  say "rounds statistics: $(jq -r '.repo_median.rounds_n' "$OUT/calibration.json") of $(jq -r '.repo_median.n' "$OUT/calibration.json") record(s) are footer-sourced; $(jq -r '.repo_median.rounds_excluded' "$OUT/calibration.json") excluded from rounds_p50/first_pass_rate (no review footer, rounds null) — decision B3"
  say "calibration → $OUT/calibration.md"
}

# ---------------------------------------------------------------------------
# AC-6 (finding 1, round 2): the calibration table must never describe a
# SMALLER issues.jsonl than the one that exists at exit. The clean exits call
# `aggregate` themselves, but a run that appends records and then dies — a
# failed `gh api graphql` page, an unreadable rateLimit block, any unexpected
# error — used to leave the PREVIOUS run's table in place over a file that had
# since grown, which is verbatim the 2026-08-30 incident AC-6 names. One EXIT
# trap makes the stale-table state unreachable by construction instead of by
# remembering to add a call to each new exit path: whenever collection has
# begun and no deliberate `aggregate` has already run, the trap rebuilds the
# table from the file as it stands, headed CUT SHORT.
#
# The trap also normalises the exit status: the documented code set (0/1/2/3)
# is exhaustive, so an unexpected status from an internal command is named on
# stderr and reported as 1 rather than escaping as an undocumented code.
# ---------------------------------------------------------------------------
COLLECTING=0          # 1 once the collection loop may have appended records
AGG_DONE=0            # 1 once a deliberate `aggregate` call has run
failed_nodes=0        # PR nodes whose record extraction failed (see below)

on_exit(){
  local rc=$?
  trap - EXIT
  if [ "$COLLECTING" -eq 1 ] && [ "$AGG_DONE" -eq 0 ] && [ -s "$ISSUES_JSONL" ]; then
    say "the run was cut short (exit $rc) after collection began — rebuilding the calibration table from $ISSUES_JSONL as it stands, so the table can never describe fewer records than the file holds (AC-6)"
    if aggregate "CUT SHORT — the run exited $rc before finishing; rebuilt from $ISSUES_JSONL as it stood at exit" "resume with the same --out (no --refresh), or rebuild from empty with --refresh" "$failed_nodes"; then
      :
    else
      say "ERROR: rebuilding the calibration table failed — $OUT/calibration.md may not describe $ISSUES_JSONL; treat it as stale and re-run with --aggregate-only"
    fi
  fi
  # Normalising only statuses OUTSIDE the documented set is not enough: an
  # internal command escaping under `set -e` with a status that HAPPENS to be
  # 1, 2 or 3 would reach the caller wearing another code's documented meaning
  # (awk exits 2 on an unreadable file, which reads as this script's "usage
  # error"). So the test is not the VALUE but whether this script chose it:
  # every deliberate exit past this point raises EXIT_INTENDED first, and
  # anything unsentinelled is an escape, reported as 1 whatever its status.
  if [ "$rc" -ne 0 ] && [ "$EXIT_INTENDED" -ne 1 ]; then
    say "internal error: the run failed with status $rc at a point that is not one of this script's own exits — an internal command failed under 'set -e'. Reporting it as 1 (fatal collection error); the documented exit codes are 0, 1, 2 and 3 and that list is exhaustive (see this script's header)."
    rc=1
  fi
  exit "$rc"
}
trap on_exit EXIT

if [ "$AGG_ONLY" -eq 1 ]; then
  [ -s "$ISSUES_JSONL" ] || { say "--aggregate-only: $ISSUES_JSONL is missing or empty"; EXIT_INTENDED=1; exit 1; }
  aggregate "" ""
  AGG_DONE=1
  exit 0
fi

# ---------------------------------------------------------------------------
# Resume (AC-4): --out reuse skips records already in issues.jsonl (keyed by
# "issue:pr"); --refresh forces a full rebuild (drops both the data file and
# the resume cursor).
# ---------------------------------------------------------------------------
if [ "$REFRESH" -eq 1 ]; then
  : > "$ISSUES_JSONL"
  rm -f "$STATE"
fi

# ---------------------------------------------------------------------------
# Provenance (AC-4 staleness guard): issues.jsonl records which --repo and
# --since built it. Reusing a file built from a different repo or window
# would fold foreign records into the exit count and the aggregate (and the
# "issue:pr" dedupe key can collide across repositories), so a mismatch — or
# a non-empty data file with no provenance at all, whose origin is
# unknowable — is a hard stop naming both sides, never a quiet reuse.
# --refresh is the way through: it rebuilds from empty.
# ---------------------------------------------------------------------------
PROV="$OUT/.provenance.json"
if [ -s "$ISSUES_JSONL" ]; then
  if [ ! -s "$PROV" ]; then
    die "$ISSUES_JSONL exists but carries no provenance ($PROV): the --repo/--since that built it are unknown, so its records cannot be assumed to be this run's (repo '$REPO', since '$SINCE'). Re-run with --refresh, or use a different --out."
  fi
  pv_repo=$(jq -r '.repo // ""' "$PROV" 2>/dev/null || echo "")
  pv_since=$(jq -r '.since // ""' "$PROV" 2>/dev/null || echo "")
  if [ "$pv_repo" != "$REPO" ] || [ "$pv_since" != "$SINCE" ]; then
    die "$ISSUES_JSONL was built from repo '$pv_repo' since '$pv_since'; this run is repo '$REPO' since '$SINCE'. Re-run with --refresh to rebuild it, or use a different --out."
  fi
fi
jq -n --arg repo "$REPO" --arg since "$SINCE" '{repo:$repo,since:$since}' > "$PROV"

# ---------------------------------------------------------------------------
# AC-4's resume dedupe set (finding 2, round 2). The set is what stops a
# resumed run re-appending records issues.jsonl already holds, so building it
# with a single `jq -r ... || : > "$SEEN"` was exactly the wrong shape: jq's
# stderr was discarded, `set -euo pipefail` carried its failure out of the
# pipeline, the `||` fired, and the whole set was TRUNCATED TO EMPTY without a
# word — after which the run re-collected records it already had and appended
# them onto the malformed line.
#
# The interruption AC-4 exists to survive (a run killed mid-append) leaves
# precisely one defect: a truncated FINAL line. So the set is built line by
# line; the trailing partial line is repaired loudly (dropped, with the file
# truncated to its last complete record) rather than written into; and a
# malformed line anywhere earlier is corruption, not an interruption artifact,
# and stops the run with a named error pointing at --refresh. No path here
# empties the set on a parse failure.
# ---------------------------------------------------------------------------
SEEN="$OUT/.seen"
build_seen(){
  : > "$SEEN"
  [ -s "$ISSUES_JSONL" ] || return 0
  # Read access is checked explicitly rather than left to whichever command
  # touches the file first. An unreadable issues.jsonl would otherwise fail
  # inside `awk` below, and awk's own exit status (2) would surface as this
  # script's "usage error" code carrying only awk's raw "Permission denied" —
  # no error: prefix, no file named, no remedy. Fail here instead, in the same
  # shape the provenance and corrupt-line guards use.
  [ -r "$ISSUES_JSONL" ] || die "$ISSUES_JSONL exists but is not readable (permission denied), so the resume dedupe set cannot be built from it. Appending to a file whose existing records cannot be read would duplicate every one of them. Fix the file's permissions, or re-run with --refresh (rebuilds from empty), or use a different --out."

  local total ends_nl=1 lineno=0 line key kept=0 truncated=0
  # awk counts a final line with no trailing newline as a record; a non-empty
  # `tail -c 1` capture means the file does not end in one (command
  # substitution strips trailing newlines).
  total=$(awk 'END{print NR}' "$ISSUES_JSONL")
  [ -z "$(tail -c 1 "$ISSUES_JSONL")" ] || ends_nl=0

  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno+1))
    [ -n "$line" ] || continue
    if key=$(jq -er 'if (.issue!=null and .pr!=null) then "\(.issue):\(.pr)" else error("record has no .issue/.pr") end' <<<"$line" 2>"$OUT/.seen-err"); then
      printf '%s\n' "$key" >> "$SEEN"
      kept=$((kept+1))
    elif [ "$lineno" -eq "$total" ] && [ "$ends_nl" -eq 0 ]; then
      # The trailing partial line: the signature of a run interrupted
      # mid-append. Never silent, never appended onto.
      truncated=1
      say "warning: $ISSUES_JSONL ends in a TRUNCATED record (line $lineno, no trailing newline) — the mark of a run interrupted mid-append. Dropping that partial line and resuming from the $kept complete record(s) before it; jq said: $(tr '\n' ' ' < "$OUT/.seen-err")"
    else
      rm -f "$OUT/.seen-err"
      die "$ISSUES_JSONL line $lineno is not a valid record and is not the file's trailing partial line, so it is corruption rather than an interrupted append: $(jq -er '.' <<<"$line" 2>&1 | tr '\n' ' ' | cut -c1-200). Re-run with --refresh to rebuild it from empty, or use a different --out."
    fi
  done < "$ISSUES_JSONL"
  rm -f "$OUT/.seen-err"

  if [ "$truncated" -eq 1 ]; then
    # Repair by keeping only the complete, newline-terminated lines. Appending
    # to a file whose last line is a fragment would glue the next record onto
    # it and lose both.
    local repaired="$OUT/.issues-repaired"
    head -n "$((total - 1))" "$ISSUES_JSONL" > "$repaired"
    mv "$repaired" "$ISSUES_JSONL"
    say "repaired $ISSUES_JSONL: $((total - 1)) complete record line(s) kept, the truncated line dropped (use --refresh to rebuild from empty instead)"
  fi

  sort -u "$SEEN" -o "$SEEN"
}
build_seen

CURSOR=""
if [ -f "$STATE" ]; then
  st_repo=$(jq -r '.repo // ""' "$STATE" 2>/dev/null || echo "")
  st_since=$(jq -r '.since // ""' "$STATE" 2>/dev/null || echo "")
  if [ "$st_repo" = "$REPO" ] && [ "$st_since" = "$SINCE" ]; then
    CURSOR=$(jq -r '.cursor // ""' "$STATE" 2>/dev/null || echo "")
    [ "$CURSOR" = "null" ] && CURSOR=""
  fi
fi

# ---------------------------------------------------------------------------
# --logs (#289, optional): build a small lookup object from every archived
# session-log JSONL file directly under $LOGS_DIR (not recursive) — a
# per-issue `triage` record and a per-issue `report` (role implementer)
# metrics record, each keyed by issue number as a string (jq object keys are
# strings). Absent --logs, this is the empty-map shape below and every
# record's triage/metrics fall back to the timeline/footer sources exactly
# as they did before this flag existed.
# ---------------------------------------------------------------------------
LOGS_JSON='{"triage":{},"metrics":{}}'
LIGHT=0   # 1 => page query omits the issue-level comments sub-selection
if [ -n "$LOGS_DIR" ]; then
  logs_cat="$OUT/.logs-cat.jsonl"
  : > "$logs_cat"
  for f in "$LOGS_DIR"/*.jsonl; do
    [ -e "$f" ] || continue
    cat "$f" >> "$logs_cat"
  done
  if [ -s "$logs_cat" ]; then
    LOGS_JSON=$(jq -s '
      {
        triage: (map(select(.event=="triage" and .issue!=null))
                 | map({key:(.issue|tostring), value:{at:.ts, decision:(.decision//null), applied:(.applied//[])}})
                 | from_entries),
        metrics: (map(select(.event=="report" and .role=="implementer" and .issue!=null))
                  | sort_by(.ts)
                  | group_by(.issue) | map(.[-1])
                  | map({key:(.issue|tostring), value:{tokens:(.tokens//null), duration_s:(.duration_s//null), outcome:(.outcome//null)}})
                  | from_entries)
      }' "$logs_cat") || die "--logs $LOGS_DIR: one or more *.jsonl files could not be parsed as JSONL by jq"
  else
    # The directory is readable (checked at argument time) and really held
    # no event lines. Say so: an archive that covered nothing must not read
    # the same as one that could not be opened (round-1 finding 5).
    say "warning: --logs $LOGS_DIR is readable but its *.jsonl files hold no event lines — every record will fall back to the timeline/footer sources, as if --logs had not been passed"
  fi
  rm -f "$logs_cat"
  logs_metrics_n=$(jq -r '.metrics|length' <<<"$LOGS_JSON")
  logs_triage_n=$(jq -r '.triage|length' <<<"$LOGS_JSON")
  say "--logs $LOGS_DIR: archive covers $logs_metrics_n issue(s) for metrics and $logs_triage_n for triage"
  # The light-query saving (round-1 finding 3) only pays when the archive
  # actually covers metrics: with an empty metrics map every issue would be
  # uncovered, so the light page query plus a comments request for all of
  # them would cost one request MORE per page and save nothing.
  [ "$logs_metrics_n" -gt 0 ] && LIGHT=1
fi

OWNER="${REPO%%/*}"
NAME="${REPO#*/}"

read -r -d '' QUERY_FULL <<'GRAPHQL' || true
query($owner:String!, $name:String!, $cursor:String, $pageSize:Int!) {
  rateLimit { remaining resetAt }
  repository(owner:$owner, name:$name) {
    pullRequests(states: MERGED, first: $pageSize, after: $cursor, orderBy: {field: UPDATED_AT, direction: DESC}) {
      totalCount
      pageInfo { hasNextPage endCursor }
      nodes {
        number
        additions
        deletions
        changedFiles
        createdAt
        mergedAt
        headRefName
        comments(first: 100) { nodes { body createdAt } }
        closingIssuesReferences(first: 20) {
          nodes {
            number
            title
            state
            createdAt
            closedAt
            body
            labels(first: 20) { nodes { name } }
            milestone { title }
            parent { number }
            timelineItems(first: 100, itemTypes: [ASSIGNED_EVENT, CROSS_REFERENCED_EVENT, LABELED_EVENT, MILESTONED_EVENT]) {
              nodes {
                __typename
                ... on AssignedEvent { createdAt }
                ... on CrossReferencedEvent { createdAt source { ... on Issue { number } } }
                ... on LabeledEvent { createdAt }
                ... on MilestonedEvent { createdAt }
              }
            }
            comments(first: 100) { nodes { body } }   # ISSUE-COMMENTS
          }
        }
      }
    }
  }
}
GRAPHQL

# Fallback query, used only if the primary is rejected for `Issue.parent`
# not existing on this account's GraphQL schema version — same shape minus
# that one field. `parent` is `null` on every record for the rest of the run
# when this branch is taken (a stderr warning names it once).
QUERY_NOPARENT=$(printf '%s' "$QUERY_FULL" | grep -v '^ *parent { number }$')

# LIGHT variants (round-1 finding 3): the same queries with the ISSUE-level
# `comments(first: 100)` sub-selection removed — the one marked
# `# ISSUE-COMMENTS` above. It exists solely to carry the
# `<!-- metrics {…} -->` footer, so when --logs already supplies an issue's
# metrics, requesting it is waste. The PR-level comments line is NOT touched:
# it carries the review footers and is always needed. Stripping by the marker
# rather than by shape keeps the two `comments(first: 100)` lines apart even
# if they are later edited to look alike.
strip_issue_comments(){ grep -v '# ISSUE-COMMENTS$'; }
QUERY_FULL_LIGHT=$(printf '%s' "$QUERY_FULL" | strip_issue_comments)
QUERY_NOPARENT_LIGHT=$(printf '%s' "$QUERY_NOPARENT" | strip_issue_comments)

PARENT_SUPPORTED=1
# The query in force is a function of two independent facts — whether this
# account's schema has Issue.parent, and whether --logs makes the light
# variant worth using — so it is selected in one place rather than assigned
# at each of the points either fact changes.
select_query(){
  if [ "$PARENT_SUPPORTED" -eq 1 ]; then
    if [ "$LIGHT" -eq 1 ]; then QUERY="$QUERY_FULL_LIGHT"; else QUERY="$QUERY_FULL"; fi
  else
    if [ "$LIGHT" -eq 1 ]; then QUERY="$QUERY_NOPARENT_LIGHT"; else QUERY="$QUERY_NOPARENT"; fi
  fi
}
QUERY=""
select_query
[ "$LIGHT" -eq 1 ] && say "--logs: page queries omit the issue-level comments sub-selection; only issues the archive does not cover will have their comments fetched"

RECORD_JQ='
  . as $pr
  | (($pr.comments.nodes) // []) as $prcomments
  | ([$prcomments[]|.body // ""]) as $prbodies
  # rounds/findings (#289, decision B3 as amended 2026-09-06): the
  # `<!-- review {…} -->` footer is the ONLY source. There is no heading
  # fallback — a PR with no parseable footer records rounds null and is
  # excluded from the rounds statistics by `aggregate` (see header).
  #
  # Extraction (round-1 finding 6): `(?m)^…$` anchors each candidate to a
  # WHOLE LINE, so a footer quoted in prose, indented, or followed by other
  # text on its line is not a candidate at all; `[^\n]*` keeps a candidate
  # inside one line even if the regex engine is asked for dotall. `scan`
  # yields EVERY whole-line candidate in a body rather than the single one
  # capture() returns, and `last` takes the final candidate: a comment that
  # quotes a footer example emits its own footer after it. fromjson is tried
  # PER candidate, never around the whole chain: an unparseable candidate
  # must not be able to void a valid footer on the same PR.
  | ([$prbodies[] | [scan("(?m)^<!-- review (\\{[^\n]*\\}) -->$")] | map(.[0]) | last] | map(select(.!=null))) as $footer_raws
  | ($footer_raws | map(try fromjson catch null)) as $footer_parsed
  | ($footer_parsed | map(select(.!=null))) as $footers
  # Counted, not swallowed: a comment whose last whole-line candidate does
  # not parse is visible in the record and in completeness.
  | (($footer_raws|length) - ($footers|length)) as $footers_malformed
  | ([$footers[]|.verdict // ""]) as $verdicts
  | ($footers|map(.round // 0)|max) as $maxround
  # first_pass (round-1 finding 1): approved at round 1 with no earlier
  # changes requested. `rounds==0` — the pre-footer heading-count predicate
  # — can never hold here, since a review round starts at 1.
  | (if ($footers|length) == 0 then null
     else (($verdicts|map(select(.=="changes_requested" or .=="decomposition_requested" or .=="escalated"))|length) == 0)
          and ($maxround == 1)
          and (($footers|map(select((.round // 0) == 1))|map(.verdict // "")|any(. == "approved")))
     end) as $first_pass
  | (if ($footers|length) > 0 then
       { rounds: $maxround,
         findings: ($footers|map((.findings // [])|length)),
         rounds_source: "footer", first_pass: $first_pass }
     else
       { rounds: null, findings: [], rounds_source: null, first_pass: null }
     end) as $review
  | (($pr.closingIssuesReferences.nodes) // [])[]
  | . as $iss
  | (($iss.labels.nodes // [])|map(.name)) as $labels
  | ($labels|map(select(startswith("area:")))) as $areas
  | ($labels|map(select(.=="bug" or .=="enhancement" or .=="chore" or .=="epic"))|.[0]) as $type
  | (($iss.timelineItems.nodes) // []) as $tl
  | ([$tl[]|select(.__typename=="AssignedEvent" and .createdAt<$pr.mergedAt)|.createdAt]|min) as $assigned
  | ([$tl[]|select(.__typename=="CrossReferencedEvent" and (.source.number!=null))|.source.number]|unique) as $xref
  # triage (#289): a log-recorded triage event for this issue wins outright;
  # without one, the earliest LabeledEvent/MilestonedEvent timeline item is
  # the fallback source. Neither present -> all three fields null.
  | ($logs.triage[($iss.number|tostring)]) as $triage_log
  | ([$tl[]|select(.__typename=="LabeledEvent" or .__typename=="MilestonedEvent")|.createdAt]|sort|.[0]) as $triage_tl_at
  | (if $triage_log!=null then $triage_log.at
     elif $triage_tl_at!=null then $triage_tl_at
     else null end) as $triage_at
  | (if $triage_log!=null then "session-log" elif $triage_tl_at!=null then "timeline" else null end) as $triage_source
  | (($iss.comments.nodes // [])|map(.body)) as $icomments
  | ([$icomments[]|try capture("<!-- metrics (?<m>\\{.*?\\}) -->";"s") catch null|.m]|map(select(.!=null))|last // "") as $metrics_raw
  # A malformed metrics footer must cost that one field, never the whole
  # record (and never, as it did before, every issue closed by the same PR):
  # it records metrics null with metrics_malformed true, which is what keeps
  # it distinguishable from an issue that simply has no footer.
  | (if $metrics_raw=="" then null else ($metrics_raw|try fromjson catch null) end) as $metrics_footer
  | (($metrics_raw!="") and ($metrics_footer==null)) as $metrics_bad
  # An archived session logs "report" (role implementer) line for this
  # issue is a metrics source in its own right (#289, see --logs above) and
  # takes precedence over the footer when present: it needs no PR-comment
  # footer parsed for this issue at all.
  | ($logs.metrics[($iss.number|tostring)]) as $metrics_log
  | (if $metrics_log!=null then $metrics_log else $metrics_footer end) as $metrics
  | (if $metrics_log!=null then "session-log" elif $metrics_footer!=null then "footer" else null end) as $metrics_source
  # size_est comes from the size:* label on the issue (#734, and decision B4
  # of the #201 scope note) — never from the "## Estimate" prose. A
  # size:s|m|l label maps to S|M|L; any other size:* value, or no size label
  # at all, records null. estimate_text below is kept deliberately, as free
  # text only: nothing parses it and it never feeds size_est.
  | ($labels|map(select(test("^size:[sSmMlL]$")))|.[0]) as $size_label
  | (if $size_label==null then null else ($size_label|sub("^size:";"")|ascii_upcase) end) as $size
  | (($iss.body // "")|(capture("## Estimate\\s*\\n(?<e>[^#]*)") // {})) as $cap
  | (if $assigned!=null and $assigned!="" then $assigned elif $pr.createdAt!=null then $pr.createdAt else $iss.createdAt end) as $start
  | {
      issue: $iss.number, title: $iss.title, pr: $pr.number, type: $type, areas: $areas,
      severity: ($labels|map(select(startswith("severity:")))|.[0]),
      priority: ($labels|map(select(startswith("priority:")))|.[0]),
      milestone: ($iss.milestone.title // null),
      parent: (if $parent_supported == true then ($iss.parent.number // null) else null end),
      created: $iss.createdAt, started: $start,
      start_source: (if $assigned!=null and $assigned!="" then "assigned" elif $pr.createdAt!=null then "pr-open" else "issue-created" end),
      pr_opened: $pr.createdAt, merged: $pr.mergedAt, closed: $iss.closedAt,
      cycle_hours: (((($pr.mergedAt|fromdateiso8601)-($start|fromdateiso8601))/3600*10|round)/10),
      cycle_days: (((($pr.mergedAt|fromdateiso8601)-($start|fromdateiso8601))/86400*100|round)/100),
      rounds: $review.rounds, findings: $review.findings, rounds_source: $review.rounds_source,
      first_pass: $review.first_pass, review_footers_malformed: $footers_malformed,
      triage_at: $triage_at, triage_source: $triage_source, triage_decision: ($triage_log.decision // null),
      additions: $pr.additions, deletions: $pr.deletions, files: $pr.changedFiles,
      net_loc: (($pr.additions-$pr.deletions)|if .<0 then -. else . end),
      size_est: $size,
      estimate_text: (if ($cap.e // "")=="" then null else (($cap.e|gsub("\n";" ")|gsub("  +";" "))) end),
      metrics: $metrics, metrics_source: $metrics_source, metrics_malformed: $metrics_bad, deferred: $xref,
      era: (if $adopt=="" then null elif $iss.createdAt>=$adopt then "post-adoption" else "pre-adoption" end)
    }
'

remaining=""
reset_at=""
total_prs=""
stop=0
records_written=0
failed_prs=""          # failed_nodes is initialised with the EXIT trap above
prs_seen=0            # merged PRs pulled off the pages actually fetched
prs_in_window=0       # of those, the ones merged on/after --since

# From here on every exit rebuilds the table (see the EXIT trap above).
COLLECTING=1

while :; do
  cursor_args=()
  [ -n "$CURSOR" ] && cursor_args=(-F "cursor=$CURSOR")
  if resp=$(gh api graphql -f query="$QUERY" -F "owner=$OWNER" -F "name=$NAME" -F "pageSize=$PAGE_SIZE" "${cursor_args[@]}" 2>"$OUT/.gql-err"); then
    :
  else
    if [ "$PARENT_SUPPORTED" -eq 1 ] && grep -qi "parent" "$OUT/.gql-err"; then
      say "warning: this account's GraphQL schema rejects Issue.parent — retrying without it; every record's parent will be null for this run"
      PARENT_SUPPORTED=0
      select_query
      resp=$(gh api graphql -f query="$QUERY" -F "owner=$OWNER" -F "name=$NAME" -F "pageSize=$PAGE_SIZE" "${cursor_args[@]}")
    else
      cat "$OUT/.gql-err" >&2
      EXIT_INTENDED=1
      exit 1
    fi
  fi
  rm -f "$OUT/.gql-err"

  # AC-5: the rate guard must fail CLOSED. `jq -r` renders a missing or null
  # rateLimit block as the string "null", and an unvalidated `[ "$x" -lt N ]`
  # errors on it and reads as "not below the floor" — i.e. as headroom the
  # response never reported. Validate both fields and stop on anything
  # unreadable instead of charging on.
  remaining=$(jq -r '.data.rateLimit.remaining // empty' <<<"$resp")
  reset_at=$(jq -r '.data.rateLimit.resetAt // empty' <<<"$resp")
  case $remaining in
    ''|*[!0-9]*) die "unreadable rate limit: rateLimit.remaining is '${remaining:-<absent>}', not a number — refusing to treat an unknown budget as headroom (the response's rateLimit block is missing or malformed)" ;;
  esac
  case $reset_at in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) ;;
    *) die "unreadable rate limit: rateLimit.resetAt is '${reset_at:-<absent>}', not an ISO 8601 instant — refusing to treat an unknown budget as headroom" ;;
  esac
  total_prs=$(jq -r '.data.repository.pullRequests.totalCount' <<<"$resp")
  has_next=$(jq -r '.data.repository.pullRequests.pageInfo.hasNextPage' <<<"$resp")
  end_cursor=$(jq -r '.data.repository.pullRequests.pageInfo.endCursor' <<<"$resp")

  if [ "$PARENT_SUPPORTED" -eq 1 ]; then parent_arg=true; else parent_arg=false; fi

  # -------------------------------------------------------------------------
  # --logs phase 2 (round-1 finding 3): under the light query this page
  # carries NO issue-level comments at all, so the saving is a request GitHub
  # never served, not a footer this script declined to parse. Partition the
  # page's issues against the archive and fetch the comments of the UNCOVERED
  # ones only — one further request, or NONE when the archive covers them
  # all, which is the case #289's Verification names. The fetched comments
  # are merged back into the page response so RECORD_JQ below sees exactly
  # the shape it would have seen from a full query.
  # -------------------------------------------------------------------------
  if [ "$LIGHT" -eq 1 ]; then
    uncovered=()
    while IFS= read -r n; do
      [ -n "$n" ] && uncovered+=("$n")
    done < <(jq -r --argjson logs "$LOGS_JSON" '
      [ .data.repository.pullRequests.nodes[]? | (.closingIssuesReferences.nodes // [])[]? | .number | select(.!=null) ]
      | unique | map(select($logs.metrics[(tostring)] == null)) | .[]' <<<"$resp")
    if [ "${#uncovered[@]}" -eq 0 ]; then
      say "--logs: the archive covers every issue on this page — its issue comments were neither requested nor fetched"
    else
      icq="query(\$owner:String!, \$name:String!) { rateLimit { remaining resetAt } repository(owner:\$owner, name:\$name) {"
      for n in "${uncovered[@]}"; do
        icq="$icq i${n}: issue(number: ${n}) { number comments(first: 100) { nodes { body } } }"
      done
      icq="$icq } }"
      say "--logs: ${#uncovered[@]} issue(s) on this page are not covered by the archive — fetching only their comments"
      if ! icresp=$(gh api graphql -f query="$icq" -F "owner=$OWNER" -F "name=$NAME" 2>"$OUT/.gqlic-err"); then
        cat "$OUT/.gqlic-err" >&2
        rm -f "$OUT/.gqlic-err"
        die "--logs: the follow-up issue-comments request failed for ${#uncovered[@]} uncovered issue(s) — refusing to record them as simply having no metrics footer"
      fi
      rm -f "$OUT/.gqlic-err"
      # This request spends budget too, so the guard must see its figure —
      # and must fail closed on it exactly as it does on a page response.
      ic_remaining=$(jq -r '.data.rateLimit.remaining // empty' <<<"$icresp")
      ic_reset=$(jq -r '.data.rateLimit.resetAt // empty' <<<"$icresp")
      case $ic_remaining in
        ''|*[!0-9]*) die "unreadable rate limit on the --logs follow-up issue-comments response: rateLimit.remaining is '${ic_remaining:-<absent>}', not a number" ;;
      esac
      [ -n "$ic_reset" ] && reset_at="$ic_reset"
      remaining="$ic_remaining"
      icmap=$(jq -c '[ .data.repository | to_entries[] | select((.value|type) == "object") | select(.value.number != null)
                       | {key:(.value.number|tostring), value:(.value.comments // {nodes:[]})} ] | from_entries' <<<"$icresp")         || die "--logs: the follow-up issue-comments response could not be read as JSON"
      resp=$(jq -c --argjson ic "$icmap" '
        .data.repository.pullRequests.nodes |= map(
          .closingIssuesReferences.nodes |= ((. // []) | map(. + {comments: ($ic[(.number|tostring)] // null)}))
        )' <<<"$resp")         || die "--logs: the fetched issue comments could not be merged back into the page response"
    fi
  fi

  while IFS= read -r node; do
    prs_seen=$((prs_seen+1))
    merged=$(jq -r '.mergedAt' <<<"$node")
    [ -n "$merged" ] && [ "$merged" \< "$SINCE" ] && continue
    prs_in_window=$((prs_in_window+1))
    # A jq failure here means every issue this PR closes is missing from the
    # output. That must never be indistinguishable from a PR that closed no
    # issues: name the PR, print jq's own diagnostic, count it, and exit
    # non-zero at the end (exit 3). Silence here is the failure #201 was
    # filed against.
    if node_recs=$(jq -c --argjson parent_supported "$parent_arg" --arg adopt "$ADOPT" --argjson logs "$LOGS_JSON" "$RECORD_JQ" <<<"$node" 2>"$OUT/.rec-err"); then
      while IFS= read -r rec; do
        [ -n "$rec" ] || continue
        i=$(jq -r '.issue' <<<"$rec")
        p=$(jq -r '.pr' <<<"$rec")
        key="$i:$p"
        grep -qxF "$key" "$SEEN" && continue
        echo "$rec" >> "$ISSUES_JSONL"
        echo "$key" >> "$SEEN"
        records_written=$((records_written+1))
      done <<<"$node_recs"
    else
      pr_num=$(jq -r '.number // "unknown"' <<<"$node" 2>/dev/null || echo unknown)
      failed_nodes=$((failed_nodes+1))
      failed_prs="$failed_prs $pr_num"
      say "ERROR: record extraction failed for merged PR #$pr_num — every issue it closes is MISSING from $ISSUES_JSONL:"
      sed 's/^/  jq: /' "$OUT/.rec-err" >&2 || true
    fi
    rm -f "$OUT/.rec-err"
  done < <(jq -c '.data.repository.pullRequests.nodes[]' <<<"$resp")

  CURSOR="$end_cursor"
  jq -n --arg repo "$REPO" --arg since "$SINCE" --arg cursor "$CURSOR" '{repo:$repo,since:$since,cursor:$cursor}' > "$STATE"

  if [ "$remaining" -lt "$MIN_REMAINING" ]; then
    stop=1
    break
  fi
  [ "$has_next" = "true" ] || break
done

n_now=$(jq -s length "$ISSUES_JSONL")

# AC-5's PARTIAL header counts merged PRs on BOTH sides — the unit the run
# actually paginates over — because issue records and merged PRs are not
# commensurable (this repository yields ~2.3 issue records per merged PR, so
# "N records of M PRs" reads as N > M in the normal case). N is the merged
# PRs processed from the pages fetched that fall in the --since window; M is
# that N plus the merged PRs not yet fetched (totalCount − PRs seen), and it
# is an UPPER BOUND: totalCount is not filtered by --since, so some of the
# unfetched remainder would have been skipped as too old. The record count
# is reported separately, in the table's own "Records:" line.
prs_unfetched=$((total_prs - prs_seen))
[ "$prs_unfetched" -ge 0 ] || prs_unfetched=0
m_est=$((prs_in_window + prs_unfetched))

if [ "$stop" -eq 1 ]; then
  say "rate guard: $remaining requests remaining (< $MIN_REMAINING), reset at $reset_at — stopping before exhaustion"
  say "PARTIAL: $prs_in_window of ~$m_est merged PRs processed (~M is an upper bound: the $prs_unfetched not yet fetched are not --since-filtered); $n_now issue records in $ISSUES_JSONL; resume with the same --out (no --refresh) after $reset_at"
  aggregate "PARTIAL — $prs_in_window of ~$m_est merged PRs processed" "~M is an upper bound (not --since-filtered); $n_now issue records so far; reset at $reset_at" "$failed_nodes"
  AGG_DONE=1
  say "remaining requests at exit: $remaining"
  [ "$failed_nodes" -eq 0 ] || say "INCOMPLETE: $failed_nodes merged PR node(s) failed record extraction and are missing from the output:$failed_prs"
  EXIT_INTENDED=1
  exit 1
fi

if [ "$failed_nodes" -ne 0 ]; then
  say "$n_now issue records → $ISSUES_JSONL ($records_written written this run)"
  aggregate "" "" "$failed_nodes"
  AGG_DONE=1
  say "INCOMPLETE: $failed_nodes of $prs_in_window merged PR node(s) failed record extraction — every issue closed by$failed_prs is MISSING from $ISSUES_JSONL"
  say "remaining requests at exit: $remaining"
  EXIT_INTENDED=1
  exit 3
fi

rm -f "$STATE" "$SEEN"
say "$n_now issue records → $ISSUES_JSONL ($records_written written this run)"
aggregate "" "" "$failed_nodes"
AGG_DONE=1
say "remaining requests at exit: $remaining"
