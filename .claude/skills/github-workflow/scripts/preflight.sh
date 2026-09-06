#!/usr/bin/env bash
# preflight.sh — deterministic pre-flight facts for a PR review dispatch. READ-ONLY.
# Usage: preflight.sh <pr> [--repo owner/name] [--markdown] [--evidence-root <dir>] [--log <path>]
#
# Contract: GET-only (never a write verb); never guesses. Every fact below is either
# read straight from the GitHub API / local disk, or the script exits non-zero naming
# what it could not determine — it does not fall back to a plausible-looking default.
#
# Reads, all via paginated `gh api` (never `gh pr view --json comments`, which silently
# truncates a long comment list and would undercount review rounds):
#   - the PR itself: state, draft, mergeable, head SHA
#   - every changed file path on the PR, across all pages, from which PR class
#     (`class`: `test-only` / `doc-only` / `executable-code`) and the round cap
#     it implies (`round_cap`: 2 or 3) are computed mechanically, per
#     `orchestration.md` § PR class and round caps. Recomputed from the
#     current diff on every call, never cached, so a relay that changes the
#     path set is reflected the next time this script runs against the
#     relayed head — the one mechanism that can move a PR's class mid-round
#     without a new review round starting (issue #703).
#   - every issue-thread comment on the PR, across all pages
#   - CI check-run states for the head SHA, falling back to the legacy commit-status API
#     (`.../commits/<sha>/status`) only when the Checks API reports zero check-runs —
#     a repo whose CI still posts through the older Status API instead of check-runs
#     would otherwise read as a false "no CI" rather than the true state (issue #299).
#     `ci.source` names which endpoint actually supplied `ci.state`: `check_runs` (the
#     normal case — check-runs was non-empty), `legacy_status` (check-runs was empty,
#     the status endpoint was not), or `none` (both endpoints were queried and both are
#     genuinely empty — true absence, not merely unchecked).
# This script no longer fetches docs/process/testing.md at all (#748). It used to
# report the doc's presence and a heuristic CI/no-CI classification (issue #300's
# two-pattern contract), but no caller in this skill consumed either fact — the
# calling agent already reads that doc itself at session start to arbitrate the
# CI-gate rule (`agent-rules.md`) and holds the result on its own session card, so this
# script's independent re-derivation was pure duplication of exactly the kind of
# discovery-by-parsing #736 rules out. Dropped rather than converted to an argument,
# since nothing downstream would have read the argument either.
#
# From the comments it derives:
#   - round count: comments carrying any of the four TERMINAL verdicts the review
#     templates define — `approved`, `changes_requested`, `decomposition_requested`,
#     `escalated` — i.e. `## PR Review — Approved` / `Changes Requested` /
#     `Decomposition Requested` / `Escalated`. Every one of the four is a round that
#     happened, including `escalated` (issue #658): an escalated round was invisible to
#     the count before, so the next round — after an owner ruling reopened the PR — was
#     numbered one low, which also silently misrouted a final-entering fix round to the
#     lighter tier at exactly the point the cap was about to be reached. A comment's
#     verdict is read from its `<!-- review {"v":1,"round":N,"verdict":...,
#     "findings":[...]} -->` footer when present; the `## PR Review — <Verdict>` heading
#     is the mandatory fallback so this works on comments posted before footers existed.
#     Only a slug from the closed set above is ever recorded as a verdict, from either
#     source; a heading (or footer) that slugs to anything else (an off-template
#     `## PR Review - notes`, say) is reported under `unrecognized_verdicts` instead —
#     never silently dropped, and never eligible to become `latest_verdict` or count
#     toward the round total (issue #448). A `## Review Findings — relay` comment carries
#     neither a `## PR Review — …` heading nor a `verdict` footer key, so it is never a
#     verdict comment and never counted — a relay is explicitly not a round (issue #658).
#     `--markdown` names each one (verdict value + slug + comment URL) on its own line, and
#     says nothing when the list is empty, so a reviewer reading only the rendered block
#     sees the same fact a JSON consumer does (issue #493) — the "never silently dropped"
#     promise above held only for a JSON consumer before this, since `--markdown` is the
#     block github-pr-review/SKILL.md Step 0 actually pastes into a dispatch.
#     A non-empty `unrecognized_verdicts` is reported LOUDLY, not as a quiet bucket (issue
#     #716 — an off-vocabulary footer, e.g. `"verdict":"changes"` instead of the required
#     `changes_requested`, was silently filed here while `rounds` under-reported, and a
#     wrong round count silently misroutes a final-entering fix round the same way #658's
#     uncounted `escalated` round did): every such comment prints a `WARNING` line to
#     stderr — regardless of `--markdown`, so a JSON-only caller is not the only one left
#     in the dark — naming the comment's URL and its recorded value. For a footer-sourced
#     entry that value is the exact raw string the footer carried, not just its slug
#     (`"changes"`, say, distinct from a slug that happens to read the same). For a
#     heading-sourced entry the raw heading text was never kept in the first place (only
#     its slug, computed at match time): both `verdict` and `verdict_slug` carry that same
#     slug, so the WARNING and the JSON record show the slug twice, not the original
#     heading prose. `rounds_is_lower_bound` is `true` in the JSON output whenever
#     `unrecognized_verdicts` is non-empty, and `--markdown` qualifies the "Review rounds
#     so far" line with `(LOWER BOUND — …)` in that case: the round happened (a verdict
#     comment was posted), it is simply not counted because its footer or heading named
#     something outside the closed set, and a reader must not take the number at face
#     value without checking this flag.
#   - the latest verdict of any kind (including `approved`) among the recognised-slug
#     records above, by comment creation time.
#   - every `## Test Evidence — round N` manifest: its stated raw-log path, whether that
#     file exists on this disk, and whether its SHA-256 matches the file's recomputed
#     hash. A `<!-- evidence {"issue","round","head","exit","log","sha256","command"} -->`
#     footer is preferred when present; the bullet-list fields
#     (Command/Env/Head SHA/Exit code/Results/Log SHA-256/Raw log) are the fallback. A
#     footer that is present but fails to parse as JSON is reported as `MALFORMED
#     FOOTER` (record `source:"malformed_footer"`, round read from the accompanying
#     `## Test Evidence — round N` heading), never misdescribed as "no path stated" —
#     that phrase means the manifest genuinely never named a path, a different fault
#     from a footer the script could not read at all (issue #438). The malformed-footer
#     branch still resolves every visible bullet field via the same `field()` fallback
#     the heading-only path uses, rather than discarding them — a manifest can name a
#     real path and get a real hash verdict even though its footer failed to parse
#     (record `source:"malformed_footer+field"` when any bullet resolved, so the mixed
#     provenance is reported truthfully, same pattern as `footer+field` below); `--markdown`
#     renders the path and hash verdict alongside the "MALFORMED FOOTER" note in that
#     case (issue #494). Separately, "footer parsed but named no `log`/`log_path` key"
#     (`source:"footer"`/`"footer+field"` with a null `log_path`) renders as "footer
#     parsed, no log key stated" in `--markdown`, distinct from "no footer and no Raw
#     log bullet at all" (`source:"heading"` with a null `log_path`, still "no path
#     stated") — the two were indistinguishable in the rendered block before (issue
#     #494).
#     The canonical footer keys are `head`/`log`/`sha256`/`exit` (issue #269);
#     manifests posted before that schema landed instead used `head_sha`/`log_path`/
#     `log_sha256`/`exit_code`, so each key is read as its canonical name first,
#     falling back to the pre-#269 spelling — never a HASH MISMATCH, or a null exit
#     code, purely from a key-name difference. When a footer is present but neither
#     spelling of the digest key is set, the digest still falls back to the visible
#     **Log SHA-256** bullet field, same as the heading-only path — and `source` is
#     then reported as `footer+field`, not plain `footer`, so a consumer can tell the
#     digest's provenance is mixed (issue #362). The bullet-field fallback itself
#     (`field()`) matches both the unbolded canonical-template form
#     (`- Log SHA-256: …`) and the bolded form real manifests drift to
#     (`- **Log SHA-256**: …` / `- **Raw log** — …`), colon- or em-dash-separated
#     (issue #363); it strips fenced code blocks from the body before matching, so a
#     decoy bullet quoted inside an example fence never wins over the real one
#     (issue #374). Every alias pair above (`head`/`head_sha`, `log`/`log_path`,
#     `sha256`/`log_sha256`, `exit`/`exit_code`) treats an empty-string canonical value
#     as absent, not present — a generator that emits `""` for a value it could not
#     compute must still fall through to the legacy spelling (issue #374).
#
#     A manifest record's `source` is one of exactly five values: `heading` (no
#     footer, or a footer with no usable digest, resolved entirely from bullet fields),
#     `footer` (the footer supplied its own digest, under either key spelling),
#     `footer+field` (the footer parsed but named neither digest-key spelling, so the
#     digest alone was recovered from the visible bullet), `malformed_footer` (the
#     footer failed to parse as JSON and no bullet field resolved either), or
#     `malformed_footer+field` (the footer failed to parse but at least one bullet
#     field — path, hash, or otherwise — still resolved; issue #494). A *verdict*
#     record's `source` is unrelated and only ever `heading` or `footer` — the two
#     record types each carry their own `source` field with a different value set.
#
#     Every manifest record also carries `log_readable`, false only when the Raw log path
#     exists on disk but this process cannot read it (a `chmod`-restricted file) —
#     distinct from `log_exists:false` (no file there at all) and from a genuine
#     `sha256_match:false` (the file was read and its content disagrees). `[ -f ]` alone
#     tests existence, not readability, so this is checked with `[ -r ]` explicitly
#     rather than inferred from `sha256sum`'s exit status; `--markdown` renders it as
#     `UNREADABLE (permission denied)`, never as `HASH MISMATCH` (issue #601).
#
#     Every manifest record also carries `superseded`, computed within groups keyed on
#     BOTH `round` AND `log_path` together, not round alone: true for every manifest in
#     such a group except the newest by `created_at`. An author who legitimately re-runs
#     and re-posts a round (implementer.md and the Evidence rule both require this after
#     a push) still names the SAME log path in every post, whose content has since
#     changed — comparing an older manifest's stated digest against the now-rewritten
#     file is not a meaningful check, so `--markdown` renders `superseded (hash not
#     checked)` for it instead of a hash verdict; the newest manifest in the group is
#     unaffected and keeps its real `hash OK` / `HASH MISMATCH` / `MISSING on disk` /
#     `UNREADABLE` verdict (issue #585). Grouping on round alone would also catch two
#     same-round manifests naming DIFFERENT, untouched logs — exactly the shape this
#     repo's own relay round produces every time (a pre-relay `test-rN.log` and a
#     post-relay `test-rN-relay.log` in one round, agent-rules.md's Evidence rule) — and
#     wrongly suppress a real mismatch on either one; keying on `log_path` too means a
#     manifest naming its own distinct log is never superseded by another manifest's
#     timing (issue #585 round-1 finding F2). `superseded` applies only where a hash
#     verdict would otherwise be rendered — a manifest with `log_path:null` (no path
#     stated, footer unparseable, or footer-parsed-no-log-key) keeps its own distinct
#     rendering regardless of it.
#
#     Every heading fallback below (`## PR Review`, `## Test Evidence — round N`)
#     accepts an em dash, en dash, `--`, or a plain hyphen as the separator (issue
#     #306): matching the whole heading and cutting at `\K` rather than a lookbehind,
#     since PCRE lookbehind requires a fixed-width pattern and the separator forms are
#     not the same width. Both heading matchers, like `field()`, match against the
#     comment body with fenced code blocks stripped first — computed once per comment
#     and shared across the verdict-heading, evidence-heading, and `field()` matchers,
#     so a decoy heading or bullet quoted inside an example fence can never outrank a
#     real one, for any of the three (issue #448). Fence stripping matches 3-or-more
#     backticks or tildes as the marker (CommonMark), allows up to 3 leading spaces,
#     and requires a closing marker to use the same character and be at least as long
#     as the opener — a shorter or different-character marker nested inside cannot
#     close it early. An unterminated fence (no closing marker before end of comment)
#     is NOT treated as fenced: its content is flushed raw instead of discarded, so a
#     real heading following a broken or decoy-only fence is never permanently hidden
#     (issue #496).
#
#   - malformed @-path comments: any issue-thread comment whose whole body, trimmed of
#     leading/trailing whitespace, matches `^@\S+$` — the literal-path posting defect
#     (`gh ... --body "@file"` run instead of `-F body=@file` or a --body-file
#     equivalent), where the comment's visible text is the shell-quoted path itself
#     rather than the file's content. Reported as `malformed_comments: [{id, url}]` in
#     the JSON output and as a warning line in `--markdown`, so a reviewer is told
#     rather than left to notice by chance, as happened with a mis-posted comment on a
#     different PR than the one under review (issue #512).
#
# Output: one JSON object on stdout (see the top-level keys built at the bottom of this
# file). `--markdown` instead renders a paste-ready dispatch block on stdout summarizing
# the same facts. `--log <path>` appends one session-log event line
# (`{"ts","event":"preflight","pr",...}`) to that file; without `--log` the line is
# echoed to stderr instead, never silently dropped.
#
# Exit codes: 2 = argument error. 1 = either of two sources: a required API call
# failed; or a local parsing failure the script refuses to read as absence (`grep -P`
# unavailable, or failing for a reason other than "no match" while reading a bullet
# field). Either way the reason is on stderr and no partial JSON is printed.
#
# No repository- or owner-specific nouns appear in this script; the target repo comes
# from --repo or, failing that, `gh repo view` on the current checkout.
set -euo pipefail

die(){ echo "preflight: $*" >&2; exit 1; }
argerr(){ echo "preflight: $*" >&2; exit 2; }

PR=""; REPO=""; MARKDOWN=0; EVIDENCE_ROOT=""; LOG_PATH=""
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="${2:?--repo needs a value}"; shift 2 ;;
    --markdown) MARKDOWN=1; shift ;;
    --evidence-root) EVIDENCE_ROOT="${2:?--evidence-root needs a value}"; shift 2 ;;
    --log) LOG_PATH="${2:?--log needs a value}"; shift 2 ;;
    -*) argerr "unknown flag $1" ;;
    *)
      [ -z "$PR" ] || argerr "unexpected extra argument $1"
      PR="$1"; shift ;;
  esac
done
[ -n "$PR" ] || argerr "usage: preflight.sh <pr> [--repo owner/name] [--markdown] [--evidence-root <dir>] [--log <path>]"
case "$PR" in ''|*[!0-9]*) argerr "<pr> must be a positive integer, got: $PR" ;; esac

[ -n "$REPO" ] || REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null) \
  || die "could not resolve --repo and 'gh repo view' failed — pass --repo owner/name"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/preflight.XXXXXX")"
cleanup(){ rm -rf "$WORK"; }
trap cleanup EXIT

# ---------------------------------------------------------------------------
# PR detail: state, draft, mergeable, head SHA. A hard API failure here is not
# recoverable — everything downstream keys off the head SHA.
# ---------------------------------------------------------------------------
PR_JSON=$(gh api "repos/$REPO/pulls/$PR" \
  --jq '{state:.state,draft:.draft,mergeable:.mergeable,head:.head.sha}' 2>"$WORK/pr.err") \
  || die "GET repos/$REPO/pulls/$PR failed: $(cat "$WORK/pr.err")"
HEAD_SHA=$(jq -r .head <<<"$PR_JSON")
[ -n "$HEAD_SHA" ] && [ "$HEAD_SHA" != "null" ] || die "PR #$PR returned no head SHA"

# ---------------------------------------------------------------------------
# Changed file paths, every page — feeds PR class (issue #703). Class is
# mechanical, computed fresh from the diff as it currently stands every time
# this script runs (`orchestration.md` § PR class and round caps): a relay is
# the one mechanism that changes a PR's content without a new review round
# starting, and it is picked up automatically the next time a reviewer's
# preflight call sees the relayed head — there is no separate "recompute
# class" step. `orchestration.md` states test-only and doc-only as
# independent whole-set predicates over ALL changed paths, not an exclusive
# per-path bucketing — a single path can satisfy both (e.g. `tests/README.md`
# sits under a test root AND is a README file) without disqualifying either
# predicate, so both flags are computed per path and reduced with `all()`
# over the whole set, separately:
#   - test-only: every path has a "test"/"tests"/"spec"/"specs"/"__tests__"
#     path segment (#748 removed this script's runtime testing.md read, so
#     that half of the doc's rule is unimplementable in any repo).
#   - doc-only: every path's basename ends in .md/.markdown/.rst/.adoc, or is
#     README* (case-sensitive — the doc capitalizes it; a lowercase
#     `readme.txt` matches neither the extension list nor the README* glob
#     and falls through to executable-code) — UNLESS that basename is also
#     LICENSE*/CHANGELOG* (which takes precedence and falls through to
#     executable-code).
#   - executable-code: anything else, including a PR with zero changed
#     paths at all (never treated as vacuously test-only or doc-only) and any
#     PR where the test-only and doc-only whole-set predicates both fail.
# ---------------------------------------------------------------------------
gh api --paginate "repos/$REPO/pulls/$PR/files?per_page=100" \
  --jq '.[].filename' \
  > "$WORK/files.raw" 2>"$WORK/files.err" \
  || die "GET repos/$REPO/pulls/$PR/files failed: $(cat "$WORK/files.err")"
PR_CLASS=$(jq -R -s -r '
  (split("\n") | map(select(length>0))) as $paths
  | if ($paths|length)==0 then "executable-code"
    else
      ($paths | map(
        (split("/")|last) as $base
        | (split("/")|any(.=="test" or .=="tests" or .=="spec" or .=="specs" or .=="__tests__")) as $under_test_root
        | ($base | test("^(LICENSE|CHANGELOG)"; "i")) as $excluded_basename
        | (($base | test("\\.(md|markdown|rst|adoc)$"; "i")) or ($base | test("^README"))) as $doc_ext
        | { is_test: $under_test_root, is_doc: ($doc_ext and ($excluded_basename|not)) }
      )) as $flags
      | if ($flags | all(.is_test)) then "test-only"
        elif ($flags | all(.is_doc)) then "doc-only"
        else "executable-code" end
    end
' "$WORK/files.raw")
case "$PR_CLASS" in
  test-only|doc-only) ROUND_CAP=2 ;;
  *) ROUND_CAP=3 ;;
esac

# ---------------------------------------------------------------------------
# All issue-thread comments, every page. This is the one call the motivating
# incident got wrong by using `gh pr view --json comments` instead.
# ---------------------------------------------------------------------------
gh api --paginate "repos/$REPO/issues/$PR/comments?per_page=100" \
  --jq '.[]|{id:.id,body:(.body//""),created_at:.created_at,url:.html_url}' \
  > "$WORK/comments.raw" 2>"$WORK/comments.err" \
  || die "GET repos/$REPO/issues/$PR/comments failed: $(cat "$WORK/comments.err")"
jq -s '.' "$WORK/comments.raw" > "$WORK/comments.json"

# ---------------------------------------------------------------------------
# Classify each comment as a verdict comment (footer preferred, heading
# fallback) or a Test Evidence manifest (same preference order), one JSON
# object per line, aggregated with jq -s afterwards — the same jsonl-then-slurp
# shape as plan-work/scripts/history.sh.
# ---------------------------------------------------------------------------
slug(){ # "Changes Requested" -> changes_requested
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z]+/_/g; s/^_+//; s/_+$//'
}
is_known_verdict(){ # closed set the review templates define (issue #448) — anything
                     # else is reported, not recorded, as a verdict.
  case "$1" in
    approved|changes_requested|decomposition_requested|escalated) return 0 ;;
    *) return 1 ;;
  esac
}
strip_fences(){ # strip_fences <body> — fenced code blocks removed, once, so every
                 # matcher that reads off the body (heading regexes and field()) shares
                 # the same fence-blind-proof view rather than each stripping (or not
                 # stripping) its own copy (issue #448). Matches 3-or-more backticks or
                 # tildes as the fence marker (CommonMark), up to 3 leading spaces of
                 # indent, and requires the closing marker to share the opener's
                 # character and be at least as long — a shorter or different-character
                 # marker nested inside (e.g. a 3-backtick inner fence within a
                 # 4-backtick outer one) cannot close it early (issue #496). An
                 # unterminated fence (never closed before end of input) is NOT treated
                 # as fenced: its buffered content is flushed raw at end-of-input
                 # instead of being discarded, so a real heading following a broken or
                 # decoy-only fence is never permanently hidden (issue #496).
  printf '%s\n' "$1" | awk '
    {
      line = $0
      # `{3,}`/interval expressions are a gawk-only extension mawk needs
      # --re-interval for (not on by default) — use `+` (one-or-more, plain
      # POSIX ERE) plus an explicit length>=3 check instead, so this runs the
      # same under mawk and gawk.
      is_marker = 0
      if (match(line, /^ ? ? ?(`+|~+)/)) {
        marker = substr(line, RSTART, RLENGTH)
        gsub(/^ +/, "", marker)
        if (length(marker) >= 3) {
          is_marker = 1
          mchar = substr(marker, 1, 1)
          mlen = length(marker)
        }
      }
      if (is_marker) {
        if (f == 0) {
          f = 1; fchar = mchar; flen = mlen; n = 0
          next
        } else if (mchar == fchar && mlen >= flen) {
          f = 0; n = 0
          next
        } else {
          n++; buf[n] = line
          next
        }
      }
      if (f == 0) { print line } else { n++; buf[n] = line }
    }
    END {
      if (f == 1) { for (i = 1; i <= n; i++) print buf[i] }
    }
  '
}
field(){ # field <name> <nofence-body> — value of "- <name>: <value>" (unbolded,
         # colon), or "- **<name>**: <value>" / "- **<name>** — <value>" (bolded,
         # colon or em dash), backticks stripped. #363: the canonical templates emit
         # the unbolded form, but real manifests drift to the bolded form, and the
         # unbolded-only regex read those as unset without any error. The caller
         # passes the body already run through strip_fences() (issue #448) — a decoy
         # bullet quoted inside an example fence never outranks the real one. A
         # `grep -P` failure (exit >1 — a `grep` built without `-P`, or a
         # pattern-encoding failure) is reported via `die`, distinct from exit 1 ("no
         # match", a legitimate absence) which yields an empty string same as before
         # (issue #374). The trailing-strip runs whitespace first, then the backtick
         # pair: a value with a trailing backtick immediately followed by trailing
         # whitespace (e.g. a bullet line with trailing spaces before the newline)
         # would otherwise leave the closing backtick unstripped, since stripping it
         # first requires the backtick to already be the very last character on the
         # line (issue #431).
  local name="$1" nofence="$2" out rc
  set +e
  out=$(printf '%s\n' "$nofence" | grep -m1 -oP "^- (\*\*)?${name}(\*\*)?(: | — )\K.*" 2>"$WORK/field.err")
  rc=$?
  set -e
  case "$rc" in
    0) printf '%s\n' "$out" | sed -E "s/[[:space:]]+\$//; s/^\`//; s/\`\$//" ;;
    1) printf '' ;;
    *) die "grep -P failed while reading field \"$name\": $(cat "$WORK/field.err")" ;;
  esac
}

: > "$WORK/verdicts.jsonl"
: > "$WORK/manifests.jsonl"
: > "$WORK/unrecognized.jsonl"
: > "$WORK/malformed_comments.jsonl"
while IFS= read -r c; do
  cid=$(jq -r .id <<<"$c")
  body=$(jq -r .body <<<"$c")
  created_at=$(jq -r .created_at <<<"$c")
  url=$(jq -r .url <<<"$c")
  # #448: one fence-stripped view of the body, shared by the verdict-heading,
  # evidence-heading, and field() matchers below — never a per-matcher copy that could
  # drift out of sync with the others.
  nofence=$(strip_fences "$body")

  # #512: a comment whose entire trimmed body is a lone `@`-prefixed path
  # (e.g. `@dispatch.md`) is the literal-path posting defect — `gh ... --body
  # "@file"` was run instead of `-F body=@file` (or its body-file
  # equivalent), so the comment's visible text is the shell-quoted path
  # itself rather than the file's content. Flag it so the next round's
  # reviewer is told rather than left to notice by chance (as happened with
  # PR #414, spotted only on a different PR than the one under review).
  # Trim leading/trailing whitespace of the WHOLE body (sed -z: the whole
  # input is one record, so ^/$ anchor start/end of the entire string, not
  # per line) and then match with a bash regex, whose ^/$ likewise anchor
  # the whole string rather than each line. `grep -q` without `-z` is
  # line-oriented and would wrongly flag a multi-line comment that merely
  # contains a lone `@token` line (issue #512 round-2 finding 1) — the same
  # per-line-vs-whole-value class of bug save-log.sh hit.
  trimmed=$(printf '%s' "$body" | sed -Ez 's/^[[:space:]]+//; s/[[:space:]]+$//')
  if [[ "$trimmed" =~ ^@[^[:space:]]+$ ]]; then
    jq -nc --arg id "$cid" --arg u "$url" '{id:($id|tonumber? // $id), url:$u}' \
      >> "$WORK/malformed_comments.jsonl"
  fi

  footer=$(printf '%s' "$body" | grep -zoP '(?s)(?<=<!-- review )\{.*?\}(?= -->)' 2>/dev/null | tr -d '\0' || true)
  if [ -n "$footer" ] && verdict=$(jq -er '.verdict' <<<"$footer" 2>/dev/null); then
    round=$(jq -r '.round//empty' <<<"$footer")
    vslug=$(slug "$verdict")
    if is_known_verdict "$vslug"; then
      jq -nc --arg v "$verdict" --arg vs "$vslug" --arg r "$round" --arg s footer --arg c "$created_at" --arg u "$url" \
        '{verdict:$v, verdict_slug:$vs, round:(if $r=="" then null else ($r|tonumber) end), source:$s, created_at:$c, url:$u}' \
        >> "$WORK/verdicts.jsonl"
    else
      jq -nc --arg v "$verdict" --arg vs "$vslug" --arg s footer --arg c "$created_at" --arg u "$url" \
        '{verdict:$v, verdict_slug:$vs, source:$s, created_at:$c, url:$u}' >> "$WORK/unrecognized.jsonl"
    fi
  else
    heading=$(printf '%s\n' "$nofence" | grep -m1 -oP '^## PR Review (?:—|–|--|-)\s*\K.*' | sed -E 's/[[:space:]]+$//' || true)
    if [ -n "$heading" ]; then
      v=$(slug "$heading")
      if is_known_verdict "$v"; then
        jq -nc --arg v "$v" --arg vs "$v" --arg s heading --arg c "$created_at" --arg u "$url" \
          '{verdict:$v, verdict_slug:$vs, round:null, source:$s, created_at:$c, url:$u}' >> "$WORK/verdicts.jsonl"
      else
        # #448: a heading beginning `## PR Review <sep> <anything>` whose slug is not
        # in the closed set the templates define — e.g. an off-template
        # `## PR Review - notes` — is reported here, not recorded as a verdict: it
        # must never displace a genuine earlier verdict as `.latest_verdict`, nor
        # count toward `.rounds`.
        jq -nc --arg v "$v" --arg vs "$v" --arg s heading --arg c "$created_at" --arg u "$url" \
          '{verdict:$v, verdict_slug:$vs, source:$s, created_at:$c, url:$u}' >> "$WORK/unrecognized.jsonl"
      fi
    fi
  fi

  ev_footer=$(printf '%s' "$body" | grep -zoP '(?s)(?<=<!-- evidence )\{.*?\}(?= -->)' 2>/dev/null | tr -d '\0' || true)
  ev_heading_round=$(printf '%s\n' "$nofence" | grep -m1 -oP '^## Test Evidence (?:—|–|--|-)\s*round \K[0-9]+' || true)
  if [ -n "$ev_footer" ] && jq -e . >/dev/null 2>&1 <<<"$ev_footer"; then
    round=$(jq -r '.round//empty' <<<"$ev_footer")
    issue=$(jq -r '.issue//empty' <<<"$ev_footer")
    # Canonical key (issue #269) preferred; pre-#269 spelling as fallback — a
    # footer emitted before the canonical schema landed must never be read as
    # empty just because its key name differs. Each side is guarded with
    # `select(. != null and . != "")` (issue #374): plain `//` treats an
    # empty-string canonical value as present, which would silently discard a
    # populated legacy alias behind it.
    head=$(jq -r '(.head|select(.!=null and .!=""))//(.head_sha|select(.!=null and .!=""))//empty' <<<"$ev_footer")
    # #363: `exit_code` is the pre-#269 spelling of the canonical `exit` key,
    # same alias treatment as head/log/sha256 below — canonical name first.
    exitc=$(jq -r '(.exit|select(.!=null and .!=""))//(.exit_code|select(.!=null and .!=""))//empty' <<<"$ev_footer")
    command=$(jq -r '.command//empty' <<<"$ev_footer")
    log=$(jq -r '(.log|select(.!=null and .!=""))//(.log_path|select(.!=null and .!=""))//empty' <<<"$ev_footer")
    sha=$(jq -r '(.sha256|select(.!=null and .!=""))//(.log_sha256|select(.!=null and .!=""))//empty' <<<"$ev_footer")
    if [ -n "$sha" ]; then
      src=footer
    else
      # #362: the footer parsed but named neither digest-key spelling, so the
      # digest is recovered from the visible bullet instead — report that
      # mixed provenance truthfully rather than the unconditional "footer".
      sha=$(field "Log SHA-256" "$nofence")
      if [ -n "$sha" ]; then
        src="footer+field"
      else
        src=footer
      fi
    fi
  elif [ -n "$ev_footer" ]; then
    # #438: the footer is present but failed the `jq -e .` parse above — a distinct
    # fault from a manifest that never named a path at all, so it is reported as such
    # rather than falling through to "no path stated". Only recoverable when the
    # accompanying `## Test Evidence — round N` heading is present too (the case the
    # motivating incident showed); with no heading either, there is no round number to
    # key a record on, and the comment yields nothing (same as any other unclassified
    # comment).
    if [ -n "$ev_heading_round" ]; then
      round="$ev_heading_round"
      issue=""
      # #494: the footer failed to parse, but the visible bullet fields — if any —
      # are still readable via the same field() fallback the heading-only path uses;
      # discarding them lost real, recoverable data (a real path, a real hash
      # verdict) on any manifest whose footer became unparseable but whose bullet
      # list still used the dashed/bolded form. Report the mixed provenance
      # truthfully (malformed_footer+field) rather than the unconditional
      # malformed_footer when anything actually resolved.
      head=$(field "Head SHA" "$nofence")
      exitc=$(field "Exit code" "$nofence")
      command=$(field "Command" "$nofence")
      log=$(field "Raw log" "$nofence")
      sha=$(field "Log SHA-256" "$nofence")
      if [ -n "$head$exitc$command$log$sha" ]; then
        src="malformed_footer+field"
      else
        src="malformed_footer"
      fi
    else
      round=""
    fi
  elif [ -n "$ev_heading_round" ]; then
    round="$ev_heading_round"
    issue=""
    head=$(field "Head SHA" "$nofence")
    exitc=$(field "Exit code" "$nofence")
    command=$(field "Command" "$nofence")
    log=$(field "Raw log" "$nofence")
    sha=$(field "Log SHA-256" "$nofence")
    src=heading
  else
    round=""
  fi
  if [ -n "$round" ]; then
    log_exists=false; log_readable=true; actual_sha=""; sha_match=false
    if [ -n "$log" ]; then
      resolved="$log"
      if [ -n "$EVIDENCE_ROOT" ]; then
        case "$log" in /*) ;; *) resolved="$EVIDENCE_ROOT/$log" ;; esac
      fi
      if [ -f "$resolved" ]; then
        log_exists=true
        # #601: `[ -f ]` tests existence, not readability. An existing but
        # permission-denied log must never be read as a hash mismatch — the
        # same rendered words a genuinely disagreeing log gets. Unguarded,
        # `sha256sum` on an unreadable file fails under `set -o pipefail` and
        # aborts the whole run: exit 1, a bare `Permission denied` on stderr,
        # and no pre-flight block at all — never a rendered HASH MISMATCH.
        # `[ -r ]` is checked explicitly (rather than inferred from
        # sha256sum's exit status) so this state is never guessed from a
        # command failure that could have other causes.
        if [ -r "$resolved" ]; then
          actual_sha=$(sha256sum "$resolved" | awk '{print $1}')
          [ -n "$sha" ] && [ "$actual_sha" = "$sha" ] && sha_match=true
        else
          log_readable=false
        fi
      fi
      log="$resolved"
    fi
    jq -nc --arg round "$round" --arg issue "$issue" --arg head "$head" --arg exitc "$exitc" \
      --arg command "$command" --arg log "$log" --arg sha "$sha" --arg actual "$actual_sha" \
      --arg exists "$log_exists" --arg readable "$log_readable" --arg match "$sha_match" --arg src "$src" --arg url "$url" \
      --arg created_at "$created_at" \
      '{round:($round|tonumber), issue:(if $issue=="" then null else ($issue|tonumber) end),
        head:(if $head=="" then null else $head end), exit:(if $exitc=="" then null else ($exitc|tonumber? // $exitc) end),
        command:(if $command=="" then null else $command end),
        log_path:(if $log=="" then null else $log end), stated_sha256:(if $sha=="" then null else $sha end),
        log_exists:($exists=="true"), log_readable:($readable=="true"), actual_sha256:(if $actual=="" then null else $actual end),
        sha256_match:($match=="true"), source:$src, url:$url, created_at:$created_at}' \
      >> "$WORK/manifests.jsonl"
  fi
done < <(jq -c '.[]' "$WORK/comments.json")

# #658: a completed round is any TERMINAL verdict comment — approved,
# changes_requested, decomposition_requested, or escalated (all four
# `is_known_verdict` slugs) — not only the two that used to gate a further
# round. An escalated round still happened and must count, or the next
# round after an owner ruling reopens the PR is numbered one low, which
# also silently routes a final-entering fix round at the lighter tier
# right when the cap is about to be reached. A relay comment
# (`## Review Findings — relay`) is never a verdict comment (no
# `## PR Review — …` heading, no `verdict` footer key), so it is never in
# verdicts.jsonl and this count never sees it.
ROUNDS=$(jq -s '[.[]|select(.verdict_slug=="approved" or .verdict_slug=="changes_requested" or .verdict_slug=="decomposition_requested" or .verdict_slug=="escalated")]|length' "$WORK/verdicts.jsonl")
LATEST_VERDICT=$(jq -s 'if length==0 then null else sort_by(.created_at)|last end' "$WORK/verdicts.jsonl")
# #585 (round-1 relay finding F2): group manifests by round AND log_path
# together, not round alone. Two same-round manifests naming DIFFERENT logs
# are never in supersession over each other — #585's rationale is that a
# same-round re-post still names the same log path, whose content has since
# been rewritten; a manifest naming its own distinct, untouched log has
# nothing superseding it, however the round's other manifests are timed.
# Grouping on round alone wrongly swallowed exactly the shape this repo's own
# relay round produces every time (agent-rules.md's Evidence rule; SKILL.md
# Step 0's resume contract): a pre-relay `test-rN.log` and a post-relay
# `test-rN-relay.log` in the same round, each its own real log. Within each
# (round, log_path) group, the newest by created_at keeps its verdict as-is;
# every older manifest in the SAME group (same round, same log path) is
# marked superseded so --markdown never renders a hash verdict for it — the
# digest of a stale manifest against a log whose content has since been
# rewritten by a legitimate re-post is not a meaningful comparison.
EVIDENCE=$(jq -s '
  group_by([.round, .log_path])
  | map(
      sort_by(.created_at) as $g
      | ($g|length) as $n
      | [range(0;$n) | $g[.] + {superseded: (. != ($n-1))}]
    )
  | add // []
  | sort_by(.round, .created_at)
' "$WORK/manifests.jsonl")
UNRECOGNIZED_VERDICTS=$(jq -s 'sort_by(.created_at)' "$WORK/unrecognized.jsonl")
MALFORMED_COMMENTS=$(jq -s '.' "$WORK/malformed_comments.jsonl")
# #716: a non-empty unrecognized_verdicts is not a quiet bucket — it means a
# verdict comment exists (an off-vocabulary footer or heading, e.g. a footer's
# "verdict":"changes" instead of "changes_requested") that ROUNDS above does
# not count, so ROUNDS is a lower bound, not the true round total. Loud on
# stderr regardless of --markdown (a JSON-only caller must not be the only
# one left in the dark), naming the comment (its URL) and the exact value it
# carried (not just the derived slug), one line per unrecognized comment.
ROUNDS_IS_LOWER_BOUND=false
N_UNRECOGNIZED=$(jq 'length' <<<"$UNRECOGNIZED_VERDICTS")
if [ "$N_UNRECOGNIZED" -gt 0 ]; then
  ROUNDS_IS_LOWER_BOUND=true
  while IFS= read -r urec; do
    uv=$(jq -r '.verdict' <<<"$urec")
    uu=$(jq -r '.url' <<<"$urec")
    us=$(jq -r '.source' <<<"$urec")
    echo "preflight: WARNING: unrecognized verdict \"$uv\" (from $us) on $uu — Review rounds so far ($ROUNDS) is a LOWER BOUND, not the true round total: this comment is a round that happened but is not counted" >&2
  done < <(jq -c '.[]' <<<"$UNRECOGNIZED_VERDICTS")
fi

# ---------------------------------------------------------------------------
# CI check-run states for the head SHA. When the Checks API reports zero
# check-runs, fall back to the legacy commit-status API (issue #299): a repo
# whose CI still posts through the older Status API instead of check-runs
# would otherwise read as a false "no CI" here. Only queried when check-runs
# is genuinely empty — a repo with check-runs never touches this endpoint.
# ---------------------------------------------------------------------------
gh api --paginate "repos/$REPO/commits/$HEAD_SHA/check-runs?per_page=100" \
  --jq '.check_runs[]|{name:.name,status:.status,conclusion:.conclusion}' \
  > "$WORK/checks.raw" 2>"$WORK/checks.err" \
  || die "GET repos/$REPO/commits/$HEAD_SHA/check-runs failed: $(cat "$WORK/checks.err")"
CHECKS=$(jq -s '.' "$WORK/checks.raw")
CI_SOURCE=check_runs
if [ "$(jq 'length' <<<"$CHECKS")" -eq 0 ]; then
  gh api "repos/$REPO/commits/$HEAD_SHA/status" \
    --jq '{state:.state, statuses:[.statuses[]|{context:.context,state:.state}]}' \
    > "$WORK/status.raw" 2>"$WORK/status.err" \
    || die "GET repos/$REPO/commits/$HEAD_SHA/status failed: $(cat "$WORK/status.err")"
  STATUS_JSON=$(jq -c '.' "$WORK/status.raw")
  if [ "$(jq '.statuses|length' <<<"$STATUS_JSON")" -gt 0 ]; then
    # Fold the legacy statuses into the same {name,status,conclusion} shape
    # check-runs uses, so CI_STATE and --markdown's rendering need no
    # separate code path — a legacy "error" state is folded in alongside
    # "failure" below, matching how the Status API itself treats the two.
    # The Status API's state vocabulary is error/failure/pending/success
    # (issue #299 follow-up): a genuinely pending legacy status must resolve
    # to CI_STATE "pending", not "unknown" — hardcoding status:"completed"
    # for every state (including "pending") satisfied neither the failure
    # disjuncts nor the success `all(...)` below, landing on "unknown". Only
    # "pending" maps to status:"in_progress" (conclusion left as the raw
    # "pending" state, unused by CI_STATE's pending branch which keys off
    # status); the other three states are genuinely terminal and keep
    # status:"completed".
    CI_SOURCE=legacy_status
    CHECKS=$(jq '[.statuses[]|{name:.context,
      status:(if .state=="pending" then "in_progress" else "completed" end),
      conclusion:.state}]' <<<"$STATUS_JSON")
  else
    # Both endpoints were queried and both are genuinely empty: true absence,
    # not merely "check-runs empty, status not checked".
    CI_SOURCE=none
  fi
fi
# #591: the checks API's conclusion vocabulary also includes "action_required"
# (a check completed but demands a human step before it can be trusted — closer
# to a failure than to anything else, since the PR is not mergeable-clean on
# its account) and "stale" (GitHub itself no longer considers a prior run's
# conclusion current, e.g. after new commits landed without a re-run — the
# same "do not trust this as final yet" posture as a still-running check, so
# it folds into "pending" rather than "failure" or the "unknown" catch-all).
# Both are named explicitly rather than left to the catch-all so a reviewer's
# Step 2.5 branch (fail / green / missing) always has a real bucket for them.
CI_STATE=$(jq -r '
  if length==0 then "none"
  elif any(.conclusion=="failure" or .conclusion=="timed_out" or .conclusion=="cancelled" or .conclusion=="error" or .conclusion=="action_required") then "failure"
  elif any(.status!="completed" or .conclusion=="stale") then "pending"
  elif all(.conclusion=="success" or .conclusion=="neutral" or .conclusion=="skipped") then "success"
  else "unknown" end' <<<"$CHECKS")

GENERATED_AT=$(date -u +%FT%TZ)

RESULT=$(jq -n \
  --arg repo "$REPO" --argjson pr "$PR" --arg head "$HEAD_SHA" \
  --argjson pr_json "$PR_JSON" --argjson rounds "$ROUNDS" --argjson latest "$LATEST_VERDICT" \
  --argjson evidence "$EVIDENCE" --argjson unrecognized_verdicts "$UNRECOGNIZED_VERDICTS" \
  --argjson rounds_is_lower_bound "$ROUNDS_IS_LOWER_BOUND" \
  --arg pr_class "$PR_CLASS" --argjson round_cap "$ROUND_CAP" \
  --arg ci_state "$CI_STATE" --argjson checks "$CHECKS" --arg ci_source "$CI_SOURCE" \
  --arg generated_at "$GENERATED_AT" \
  --argjson malformed_comments "$MALFORMED_COMMENTS" \
  '{
    repo: $repo, pr: $pr, head_sha: $head,
    state: $pr_json.state, draft: $pr_json.draft, mergeable: $pr_json.mergeable,
    class: $pr_class, round_cap: $round_cap,
    rounds: $rounds, rounds_is_lower_bound: $rounds_is_lower_bound,
    latest_verdict: $latest, evidence: $evidence,
    unrecognized_verdicts: $unrecognized_verdicts,
    malformed_comments: $malformed_comments,
    ci: {state: $ci_state, checks: $checks, source: $ci_source},
    generated_at: $generated_at
  }')

if [ "$MARKDOWN" -eq 1 ]; then
  jq -r '
    "### Pre-flight — PR #\(.pr) (\(.repo))\n" +
    "- Head SHA: `\(.head_sha)`\n" +
    "- State: \(.state)" + (if .draft then " (draft)" else "" end) + " · mergeable: \(.mergeable)\n" +
    "- PR class: \(.class) (round cap \(.round_cap))\n" +
    "- Review rounds so far: \(.rounds)" +
    (if .rounds_is_lower_bound then " (LOWER BOUND — see WARNING below, not the true round total)" else "" end) +
    (if .latest_verdict then " · latest verdict: \(.latest_verdict.verdict) (\(.latest_verdict.source))" else " · no verdict comment yet" end) + "\n" +
    (if (.unrecognized_verdicts|length) > 0 then
      "- WARNING: unrecognized verdict (round count above is a LOWER BOUND, not counted): \(.unrecognized_verdicts|length) (" +
      ([.unrecognized_verdicts[]|"\"\(.verdict)\" (slug \(.verdict_slug)) — \(.url)"]|join(", ")) + ")\n"
     else "" end) +
    (if (.malformed_comments|length) > 0 then
      "- WARNING: malformed @-path comment bodies: \(.malformed_comments|length) (" +
      ([.malformed_comments[]|"\(.url)"]|join(", ")) + ")\n"
     else "" end) +
    "- CI: \(.ci.state)" + (if .ci.source=="legacy_status" then " (via legacy status API)" else "" end) +
    (if (.ci.checks|length)>0 then " (" + ([.ci.checks[]|"\(.name)=\(.conclusion//.status)"]|join(", ")) + ")" else "" end) + "\n" +
    "- Test Evidence manifests:\n" +
    (if (.evidence|length)==0 then "  - none\n" else
      ([.evidence[]|
        # #438/finding 1: the backticked slot must be source-aware, not
        # computed independently of the explanation that follows it — a
        # malformed_footer record with no recoverable path is a footer the
        # script could not read at all, never the "no path stated" fact
        # (that phrase means the manifest genuinely never named a path, a
        # different fault). Only a record whose footer parsed (or was
        # entirely absent) and whose log_path is still null renders the
        # literal "no path stated" text.
        "  - round \(.round): `" +
        (if .log_path==null and (.source|startswith("malformed_footer")) then "footer unparseable"
         else (.log_path // "no path stated") end) +
        "` — " +
        (if .log_path==null then
          (if (.source|startswith("malformed_footer")) then "footer unparseable"
           elif (.source=="footer" or .source=="footer+field") then "footer parsed, no log key stated"
           else "no path stated" end)
         elif .superseded then "superseded (hash not checked)"
         elif .log_exists|not then "MISSING on disk"
         elif .log_readable|not then "UNREADABLE (permission denied)"
         elif .sha256_match then "hash OK"
         else "HASH MISMATCH" end) +
        (if (.source|startswith("malformed_footer")) then " — MALFORMED FOOTER (round \(.round))" else "" end)
      ]|join("\n")) + "\n" end)
  ' <<<"$RESULT"
else
  printf '%s\n' "$RESULT"
fi

LOG_LINE=$(jq -nc --arg ts "$GENERATED_AT" --argjson pr "$PR" --arg repo "$REPO" --argjson rounds "$ROUNDS" \
  --argjson latest "$LATEST_VERDICT" --arg head "$HEAD_SHA" \
  '{ts:$ts, event:"preflight", pr:$pr, repo:$repo, rounds:$rounds,
    verdict:(if $latest then $latest.verdict else null end), head:$head}')
if [ -n "$LOG_PATH" ]; then
  mkdir -p "$(dirname "$LOG_PATH")"
  printf '%s\n' "$LOG_LINE" >> "$LOG_PATH"
else
  printf '%s\n' "$LOG_LINE" >&2
fi
