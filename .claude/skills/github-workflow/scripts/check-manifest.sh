#!/usr/bin/env bash
# check-manifest.sh — hold a posted `## Test Evidence` manifest to the field spec in
# ../references/templates/implementer.md, mechanically. READ-ONLY.
#
# Usage: check-manifest.sh <pr> --lint installed|not-installed|none [--repo owner/name]
#                           [--round N] [--evidence-root <dir>] [--markdown]
#
# Contract: GET-only (never a write verb). Three reads, all `gh api`: the PR (for its
# current head SHA), every issue-thread comment across all pages, and
# `docs/process/testing.md` (for the ONE fact `env-quote` extracts from it below — a
# verbatim literal-string match, never a decision inferred from the doc's prose). The
# raw log is read from local disk at the absolute path the manifest states, when that
# file is present — a manifest whose log is on another machine still gets every check
# that does not need the file.
#
# **Lint state**, by contrast, is NOT re-derived from that fetch (#748): the caller reads
# `docs/process/testing.md` itself at startup, already knows whether it names a
# conditional linter, and passes the fact as `--lint installed|not-installed|none` — a
# required flag with three values, not two (#748 round-1 relay finding: the first cut of
# this flag dropped the vocabulary for `implementer.md`'s own third case — "omit only
# when docs/process/testing.md names no linter at all" — a doc/code disagreement even
# though this repository's own testing.md never hits that branch). `none` means the doc
# names no linter concept at all, so the Lint state bullet is not required; `not-installed`
# means the doc DOES name a linter, and this run's is absent — a bullet is still required,
# naming that fact. The check this --lint flag replaced, `grep -qi 'installed'` against
# the doc's raw text, is the clearest violation of the extraction-vs-interpretation rule
# below: this repository's own testing.md states "not installed — review-only", which
# *contains* "installed" as a substring, so that grep read the negation as the
# affirmative. It happened not to produce a wrong verdict here only because both branches
# of this script's own conditional-linter sentence use the word "installed" — luck about
# which branch the substring landed in, not correctness (see github-tools.md's
# extraction-vs-interpretation rule and its check-reviewer-commits.sh exception, which
# this script's `--lint` and env-quote's literal-string extraction both follow).
#
# Why this exists: `preflight.sh` reports "hash OK" off the `<!-- evidence … -->` footer
# and stops there, so a manifest can pass pre-flight while failing the reviewer's Step 5
# trust test (`github-pr-review/references/evidence-paths.md`, Path 2) on points that are
# purely mechanical — a required field bullet that was never emitted, a **Command** entry
# the raw log does not echo. Each such failure costs the reviewer a full redundant suite
# re-run of work that was already done correctly, which is the cost the whole evidence
# spec is written to avoid. This script runs the same checks the reviewer runs, before
# the reviewer does, so the author can fix them while it is still cheap.
#
# The checks, one report line each:
#   fields        every field bullet implementer.md marks required is present. Required:
#                 Command, Env, Head SHA, Exit code, Results, Log SHA-256, Raw log,
#                 Coverage. **Lint state** is conditional, per --lint (#748): required
#                 when --lint is installed or not-installed (the caller found a
#                 conditional-linter sentence in docs/process/testing.md), n/a when
#                 --lint is none (the doc names no linter at all) — the same two-way
#                 split implementer.md's own spec draws, now taken as an argument
#                 instead of re-derived by fetching and pattern-matching the doc.
#   footer        the `<!-- evidence {…} -->` footer parses as JSON and carries exactly
#                 the seven canonical keys (issue, round, head, exit, log, sha256,
#                 command) — no more, no fewer.
#   footer-agree  the footer's `head`, `log` and `sha256` equal the visible bullets'.
#                 The spec says each mirrors its bullet; a machine consumer reads the
#                 footer and a human reads the bullet, so a disagreement misleads one of
#                 them without either being able to see it.
#   head          manifest **Head SHA** == the PR's current head SHA. This is the
#                 reviewer's Path 2 check 1: a manifest posted before a later push
#                 describes a tree that is no longer under review.
#   log-path      **Raw log** is an absolute path with no unexpanded placeholder
#                 (`<scratch>`, `$VAR`, `~`). A manifest naming a placeholder names a
#                 path that exists nowhere and hard-fails the reviewer's check 3.
#   digest        **Log SHA-256** is 64 lowercase hex characters and, when the log is on
#                 this disk, equals `sha256sum` of it. This is check 3 condition 2.
#   commands      every **Command** entry appears in the raw log as a line of its own
#                 (bare, or behind a runner's `$ `/`+ `/`> ` prompt prefix), and — when the
#                 log carries exit markers at all — each entry is followed by its own
#                 `[exit=N]` before the next entry. This is check 3 condition 3, the one
#                 a log that names its commands only in prose section headers fails.
#   env-quote     when `docs/process/testing.md` states, verbatim, "no suites —
#                 review-only", **Env** must quote that declaration. Quoting instead a
#                 sentence that only says suites are not *required*, or the doc's
#                 conditional lint-state phrase, is what check 2 excludes by name — both
#                 read alike and sit within a few lines of the declaration, so this check
#                 names which one was quoted rather than reporting a bare miss.
#   exit-count    **Exit code** carries one entry per **Command** entry, counted over
#                 the entry shapes implementer.md documents and NO others — a sub-bullet
#                 list (required as soon as any entry carries an annotation), a bare
#                 inline list with no annotation at all, or the aggregate `0 (every
#                 command above)`. A field that is annotated AND written inline is a
#                 manifest defect, reported as one and never parsed; guessing inflates the
#                 total until a genuinely short list passes, which is the very failure
#                 #602 was filed against. An inline value that is neither a clean bare
#                 list nor annotation prose — a leading, trailing or doubled comma — is
#                 reported as malformed punctuation, a distinct diagnostic from the
#                 annotated-inline defect (#660): neither is counted. A defect fixture
#                 dated before the 2026-09-04 owner ruling
#                 (PR #626#issuecomment-5545298875) that first required the sub-bullet
#                 form is named as historical rather than as a defect to re-post — the
#                 PR is necessarily merged already, so there is nothing to re-post
#                 (#657); the manifest still FAILs, since the checker arbitrates every
#                 manifest against the spec as it stands today. The count is then
#                 cross-checked against the run's OWN per-command exit record: the
#                 `<log>.exits` sidecar implementer.md's recipe writes when it sits
#                 beside the named log and is readable, otherwise the bounded scan
#                 the `commands` check performs; SKIP when neither is available. Never a
#                 whole-file `grep -c '^\[exit='`, which issue #539 established
#                 miscounts because a command's own output can print such a line (#602's
#                 amended second criterion). Nothing else in this script counted the two
#                 lists against each other, so a manifest that silently drops a trailing
#                 entry (#602's PR #530 finding) read as clean. The aggregate form names
#                 no per-command entry, so its COUNT agrees by construction — but when the
#                 sidecar (the one record with per-command VALUES) is readable and records
#                 a non-zero exit, the aggregate's own claim ("every command above" is
#                 `0`) is checked against it and FAILs if it disagrees (#646); the bounded
#                 scan carries no values, so an aggregate form backed only by the scan
#                 stays a plain count check, same as before. A sidecar line is read
#                 whitespace/CR-tolerant, so a genuinely-zero record contaminated by a
#                 trailing space or a CRLF line ending is not misread as non-zero, and a
#                 line that is not a decimal integer at all is reported as a malformed
#                 record rather than as a non-zero exit (#677).
#   results-count       **Results** states a number immediately before "check(s)" or
#                 "assertion(s)" ("66 checks passed"); that number must appear as a
#                 standalone token in the raw log (#629). Never any other numeric prose —
#                 a Command-derived count phrased another way is not this check's concern.
#                 `results-log-section` and `results-command`, the other two checks #629
#                 originally added alongside this one, were removed by #732: both decided
#                 whether a **Results** sentence *asserted* something (that the raw log
#                 carries a labelled section, that a named command was run), which is
#                 interpretation of English prose rather than extraction from an agreed
#                 marker, and both reported `n/a` on every manifest posted in this repo to
#                 date. That judgement is now the reviewer's, per github-tools.md's
#                 extraction-vs-interpretation rule.
#
# Output: one `PASS`/`FAIL`/`SKIP`/`n/a` line per check on stdout, then a one-line
# summary. Exit 0 when every check that could run passed, 1 when any FAILed, 2 on an
# argument error or a manifest this PR does not carry, and 3 when nothing FAILed but at
# least one check SKIPped — "could not verify" is not "verified" (#589). A SKIP reports a
# limit of this run, most often a raw log that is on another machine, and with the log
# absent the checks that arbitrate the manifest against it (`digest`, `commands`, and
# `exit-count`'s marker cross-check) skip; a caller branching on the exit code alone has
# to be able to see that. `n/a` never sets the status: it reports a check this
# repository's testing doc does not put in scope at all, which is a fact about the repo,
# not a limit of the run.
#
# `--markdown` additionally renders every check result as a markdown table after the
# plain-text report (unchanged, for a caller/test parsing it) — a paste-ready block a
# reviewer can drop into a pre-flight comment, surfacing a check like `exit-count`'s
# mismatch without the reviewer re-running the script themselves.
#
# No repository- or owner-specific nouns appear in this script; the target repo comes
# from --repo or, failing that, `gh repo view` on the current checkout.
set -euo pipefail
export LC_ALL=C

# The owner ruling (#657) that first required an annotated Exit code field to be
# written one entry per sub-bullet — https://github.com/blac9216/storage/pull/626#issuecomment-5545298875.
# A constant, not a fourth GET: the manifest comment's own `created_at` (already
# read in the same GET this script makes for every comment) is the fact compared
# against it, so a pre-ruling manifest is named as historical rather than as a
# defect to re-post.
RULING_AT="2026-09-04T19:10:26Z"

die(){ echo "check-manifest: $*" >&2; exit 1; }
argerr(){ echo "check-manifest: $*" >&2; exit 2; }

PR=""; REPO=""; ROUND=""; EVIDENCE_ROOT=""; MARKDOWN=0; LINT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="${2:?--repo needs a value}"; shift 2 ;;
    --round) ROUND="${2:?--round needs a value}"; shift 2 ;;
    --evidence-root) EVIDENCE_ROOT="${2:?--evidence-root needs a value}"; shift 2 ;;
    --lint) LINT="${2:?--lint needs a value}"; shift 2 ;;
    --markdown) MARKDOWN=1; shift ;;
    -*) argerr "unknown flag $1" ;;
    *)
      [ -z "$PR" ] || argerr "unexpected extra argument $1"
      PR="$1"; shift ;;
  esac
done
[ -n "$PR" ] || argerr "usage: check-manifest.sh <pr> [--repo owner/name] [--round N] [--evidence-root <dir>] --lint installed|not-installed|none [--markdown]"
case "$PR" in ''|*[!0-9]*) argerr "<pr> must be a positive integer, got: $PR" ;; esac
case "$ROUND" in ''|*[!0-9]*) [ -z "$ROUND" ] || argerr "--round must be a non-negative integer, got: $ROUND" ;; esac
# #748: lint state is caller-supplied (the caller read docs/process/testing.md itself at
# startup), never re-derived here by pattern-matching the doc's prose. Exact-match ONLY —
# a substring/glob test (e.g. `*installed*`) would match "not-installed" as "installed"
# too, reproducing in the argument domain the exact defect this replaces in the doc
# domain (#748's "not installed — review-only" case). Three values, not two (#748
# round-1 relay): `none` is its own literal, exact-matched the same way, never folded
# into `not-installed` by a prefix/substring test either.
[ -n "$LINT" ] || argerr "--lint installed|not-installed|none is required (usage: check-manifest.sh <pr> [--repo owner/name] [--round N] [--evidence-root <dir>] --lint installed|not-installed|none [--markdown])"
case "$LINT" in
  installed|not-installed|none) ;;
  *) argerr "--lint must be 'installed', 'not-installed' or 'none', got: $LINT" ;;
esac

[ -n "$REPO" ] || REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null) \
  || die "could not resolve --repo and 'gh repo view' failed — pass --repo owner/name"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/check-manifest.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

fail=0
pass_n=0; fail_n=0; skip_n=0
# RESULTS[] mirrors every reported line, one "STATUS\tNAME\tMSG" entry each, so
# --markdown can render the same verdicts as a table without re-running any
# check or duplicating the plain-text report above it.
RESULTS=()
ok(){    printf 'PASS %-12s %s\n' "$1" "$2"; pass_n=$((pass_n+1)); RESULTS+=("PASS	$1	$2"); }
bad(){   printf 'FAIL %-12s %s\n' "$1" "$2"; fail_n=$((fail_n+1)); fail=1; RESULTS+=("FAIL	$1	$2"); }
skip(){  printf 'SKIP %-12s %s\n' "$1" "$2"; skip_n=$((skip_n+1)); RESULTS+=("SKIP	$1	$2"); }
na(){    printf 'n/a  %-12s %s\n' "$1" "$2"; RESULTS+=("n/a	$1	$2"); }

# ---------------------------------------------------------------------------
# Reads. A hard failure on the PR or the comment list is fatal — there is
# nothing to check without them. A 404 on testing.md is a fact (the file is
# absent), not a failure, exactly as preflight.sh treats it.
# ---------------------------------------------------------------------------
HEAD_SHA=$(gh api "repos/$REPO/pulls/$PR" --jq '.head.sha' 2>"$WORK/pr.err") \
  || die "GET repos/$REPO/pulls/$PR failed: $(cat "$WORK/pr.err")"
[ -n "$HEAD_SHA" ] && [ "$HEAD_SHA" != "null" ] || die "PR #$PR returned no head SHA"

gh api --paginate "repos/$REPO/issues/$PR/comments?per_page=100" \
  --jq '.[]|{body:(.body//""),url:.html_url,created_at:.created_at}' \
  > "$WORK/comments.raw" 2>"$WORK/comments.err" \
  || die "GET repos/$REPO/issues/$PR/comments failed: $(cat "$WORK/comments.err")"

TESTING=""
if content_b64=$(gh api "repos/$REPO/contents/docs/process/testing.md" --jq '.content' 2>"$WORK/testing.err"); then
  TESTING=$(printf '%s' "$content_b64" | tr -d '\n' | base64 -d 2>/dev/null || true)
elif ! grep -qi '404' "$WORK/testing.err"; then
  die "GET repos/$REPO/contents/docs/process/testing.md failed: $(cat "$WORK/testing.err")"
fi
printf '%s\n' "$TESTING" > "$WORK/testing.md"

# ---------------------------------------------------------------------------
# Pick the manifest comment. Heading separators are the same four spellings
# preflight.sh accepts (em dash, en dash, `--`, plain hyphen); the body is read
# with fenced code blocks stripped so a manifest quoted inside an example fence
# — this script's own tests carry several — never outranks a real one.
# ---------------------------------------------------------------------------
strip_fences(){ printf '%s\n' "$1" | awk '/^```/{f=!f; next} !f'; }

best_round=-1; BODY=""; URL=""; COMMENT_AT=""
while IFS= read -r c; do
  body=$(jq -r .body <<<"$c")
  nofence=$(strip_fences "$body")
  r=$(printf '%s\n' "$nofence" | grep -m1 -oP '^## Test Evidence (?:—|–|--|-)\s*round \K[0-9]+' || true)
  [ -n "$r" ] || continue
  if [ -n "$ROUND" ]; then
    [ "$r" = "$ROUND" ] || continue
  fi
  # Later comments win a tie, so a re-posted round supersedes the one it replaces.
  if [ "$r" -ge "$best_round" ]; then
    best_round="$r"; BODY="$nofence"; URL=$(jq -r .url <<<"$c")
    COMMENT_AT=$(jq -r '.created_at//""' <<<"$c")
  fi
done < <(jq -c '.' "$WORK/comments.raw")

if [ "$best_round" -lt 0 ]; then
  if [ -n "$ROUND" ]; then
    argerr "PR #$PR carries no '## Test Evidence — round $ROUND' comment"
  fi
  argerr "PR #$PR carries no '## Test Evidence — round N' comment"
fi
printf '%s\n' "$BODY" > "$WORK/body.md"
echo "check-manifest: PR #$PR ($REPO) — round $best_round manifest, $URL"

# ---------------------------------------------------------------------------
# strip_span — unwrap a value's code span, on stdin, one line at a time. A
# leading backtick run is removed only when a run of the SAME length closes the
# line AND no run of that same length appears between them: that is exactly the
# shape of one span wrapping the whole value, including the recipe's widened
# ``…`` fence around a command that itself carries a backtick. Anything else is
# passed through byte for byte.
#
# A value carrying two spans — `cmd` (run from `dir`), or `a` and `b` — is
# therefore left alone. Stripping one backtick off each end of such a value
# yields text with unbalanced backticks, and that mangled text is what the
# diagnostic then shows the author, on the one output a checker has to get right
# (#589). The verdict does not change either way: a two-span value is a prose
# paraphrase, not a command, and fails the `commands` check on its own merits.
# ---------------------------------------------------------------------------
strip_span(){
  awk '
    function inner_ok(s, n,   ok) {
      ok = 1
      while (match(s, /`+/)) { if (RLENGTH == n) ok = 0; s = substr(s, RSTART + RLENGTH) }
      return ok
    }
    { line = $0
      nlead = match(line, /^`+/) ? RLENGTH : 0
      ntrail = match(line, /`+$/) ? RLENGTH : 0
      if (nlead > 0 && nlead == ntrail && length(line) > nlead + ntrail) {
        inner = substr(line, nlead + 1, length(line) - nlead - ntrail)
        if (inner_ok(inner, nlead)) {
          sub(/^[ ]/, "", inner); sub(/[ ]$/, "", inner)
          line = inner
        }
      }
      print line }'
}

# ---------------------------------------------------------------------------
# field <name> — the value of `- <name>: <v>` / `- **<name>**: <v>` /
# `- **<name>** — <v>`, backticks and surrounding whitespace stripped. Same
# tolerance preflight.sh's field() carries (#363): the canonical template emits
# the unbolded colon form and real manifests drift to the bolded one, and a
# reader that accepts only one shape reports a present field as missing.
# ---------------------------------------------------------------------------
field(){
  local name="$1" out rc=0
  out=$(grep -m1 -oP "^- (\*\*)?${name}(\*\*)?(:|:? —)\s*\K.*" "$WORK/body.md" 2>"$WORK/field.err") || rc=$?
  case "$rc" in
    0) printf '%s\n' "$out" | sed -E "s/[[:space:]]+\$//" | strip_span ;;
    1) printf '' ;;
    *) die "grep -P failed while reading field \"$name\": $(cat "$WORK/field.err")" ;;
  esac
}

# has_field <name> — the bullet exists at all, value or not. A field whose
# bullet is present but empty (`- Results:`) is a different defect from a field
# that was never emitted, and only the second is what the required-field check
# is about; both are reported, distinctly.
has_field(){ grep -qP "^- (\*\*)?$1(\*\*)?(:|:? —)" "$WORK/body.md"; }

# sublist <name> — the indented sub-bullets under `- <name>:`, one per line,
# code-span fences and their padding spaces stripped. This is how **Command**
# is written (one bullet per command) and how the recipe emits **Exit code**.
# The unwrapping is `strip_span`'s, the same one `field` uses, so an inline
# value and a sub-bullet carrying the same text are rendered identically (#589).
sublist(){
  awk -v name="$1" '
    BEGIN { pat = "^- (\\*\\*)?" name "(\\*\\*)?(:|:? —)" }
    $0 ~ pat { inb = 1; next }
    inb {
      if ($0 ~ /^[ \t]+- /) {
        line = $0
        sub(/^[ \t]+- /, "", line)
        sub(/[ \t]+$/, "", line)
        print line
        next
      }
      if ($0 ~ /^[ \t]*$/) next
      inb = 0
    }
  ' "$WORK/body.md" | strip_span
}

# ---------------------------------------------------------------------------
# fields — every bullet implementer.md marks required.
# ---------------------------------------------------------------------------
missing=""; empty=""
for f in Command Env "Head SHA" "Exit code" Results "Log SHA-256" "Raw log" Coverage; do
  if ! has_field "$f"; then
    missing="$missing, $f"
  else
    v=$(field "$f")
    # Command and Exit code legitimately carry their value as sub-bullets, so an
    # empty inline value is only a defect when the sub-list is empty too.
    if [ -z "$v" ] && [ -z "$(sublist "$f")" ]; then empty="$empty, $f"; fi
  fi
done
if [ -n "$missing" ]; then
  bad fields "required bullet(s) absent: ${missing#, }"
elif [ -n "$empty" ]; then
  bad fields "bullet present but carries no value: ${empty#, }"
else
  ok fields "all 8 required bullets present with a value"
fi

# **Lint state** (#748, round-1 relay): the caller's --lint value replaces the
# doc-fetch-and-grep this check used to run, but keeps the same two-way split
# implementer.md's spec draws ("Omit only when docs/process/testing.md names no linter
# at all") rather than collapsing it to "always required". --lint none is its own
# DECISION, not just different report text: the field-presence check below is skipped
# entirely (na), exactly as the old doc-derived n/a branch skipped it — this is the
# genuine verdict this check makes, restored rather than merely relabelled.
#
# --lint installed vs not-installed, by contrast, both still require the field (a
# conditional-linter sentence exists in the doc either way) and differ only in
# LINT_LABEL, the text named in the PASS/FAIL message — that has never been, and still
# is not, a PASS/FAIL decision on its own; it reports which state the caller declared,
# nothing more. Whether the manifest's own Lint state VALUE actually agrees with the
# caller's declared installed/not-installed state is not checked here — reintroducing
# that as a verdict would be a lint-derived judgement of manifest CONTENT, a scope
# question of its own, not silently added by this fix.
#
# LINT_LABEL is derived by EXACT string equality against the one literal value that
# means "installed" — never a substring test. `printf '%s' "$LINT" | grep -qi
# 'installed'` in place of the `[ "$LINT" = "installed" ]` test below would misread
# "not-installed" as "installed" for the identical reason the doc-prose version of that
# grep misread this repository's own "not installed — review-only" sentence (see the
# header note): the negation contains the affirmative word as a substring.
if [ "$LINT" = "none" ]; then
  na lint-state "--lint none: docs/process/testing.md names no linter at all"
else
  if [ "$LINT" = "installed" ]; then LINT_LABEL="installed"; else LINT_LABEL="not installed"; fi
  if has_field "Lint state" && [ -n "$(field "Lint state")" ]; then
    ok lint-state "present: $(field "Lint state") — declared $LINT_LABEL via --lint"
  else
    bad lint-state "--lint declared $LINT_LABEL, so the Lint state bullet is required"
  fi
fi

# ---------------------------------------------------------------------------
# footer — parses, and carries exactly the seven canonical keys.
# ---------------------------------------------------------------------------
FOOTER=$(grep -m1 -oP '<!-- evidence \K\{.*\}(?= -->)' "$WORK/body.md" || true)
F_HEAD=""; F_LOG=""; F_SHA=""; FOOTER_OK=0
if [ -z "$FOOTER" ]; then
  bad footer "no '<!-- evidence {…} -->' footer — machine consumers read this first and see no manifest at all"
elif ! jq -e . >/dev/null 2>&1 <<<"$FOOTER"; then
  bad footer "footer is present but does not parse as JSON — read as no manifest at all"
else
  keys=$(jq -r 'keys_unsorted|sort|join(",")' <<<"$FOOTER")
  want="command,exit,head,issue,log,round,sha256"
  if [ "$keys" = "$want" ]; then
    ok footer "parses, with exactly the seven canonical keys"
  else
    bad footer "keys are [$keys], expected [$want]"
  fi
  F_HEAD=$(jq -r '.head//""' <<<"$FOOTER")
  F_LOG=$(jq -r '.log//""' <<<"$FOOTER")
  F_SHA=$(jq -r '.sha256//""' <<<"$FOOTER")
  FOOTER_OK=1
fi

B_HEAD=$(field "Head SHA")
B_LOG=$(field "Raw log")
B_SHA=$(field "Log SHA-256")

# footer-agree skips whenever the footer did not yield parsed values to compare
# — a present-but-unparseable footer is exactly that, not a bullet-vs-bullet
# match that happens to compare "" against "" (#596): the `footer` check above
# already reports the parse failure, and reporting PASS here on top of it would
# claim an agreement this run never established.
if [ "$FOOTER_OK" -eq 0 ]; then
  skip footer-agree "no parsed footer to compare the bullets against"
else
  disagree=""
  [ "$F_HEAD" = "$B_HEAD" ] || disagree="$disagree, head ($F_HEAD != $B_HEAD)"
  [ "$F_LOG" = "$B_LOG" ]   || disagree="$disagree, log ($F_LOG != $B_LOG)"
  [ "$F_SHA" = "$B_SHA" ]   || disagree="$disagree, sha256 ($F_SHA != $B_SHA)"
  if [ -n "$disagree" ]; then
    bad footer-agree "footer disagrees with the visible bullet(s): ${disagree#, }"
  else
    ok footer-agree "footer head/log/sha256 mirror the visible bullets"
  fi
fi

# ---------------------------------------------------------------------------
# head — the reviewer's check 1.
# ---------------------------------------------------------------------------
if [ -z "$B_HEAD" ]; then
  bad head "no Head SHA to compare against the PR head $HEAD_SHA"
elif [ "$B_HEAD" = "$HEAD_SHA" ]; then
  ok head "$B_HEAD == PR head"
else
  bad head "manifest $B_HEAD != PR head $HEAD_SHA — stale manifest, re-run and re-post"
fi

# ---------------------------------------------------------------------------
# log-path / digest / commands.
# ---------------------------------------------------------------------------
RESOLVED=""
if [ -z "$B_LOG" ]; then
  bad log-path "no Raw log bullet — there is no log to arbitrate the manifest against"
else
  case "$B_LOG" in
    *'<'*'>'*) bad log-path "names an unexpanded placeholder: $B_LOG" ;;
    *'$'*)     bad log-path "names an unexpanded variable: $B_LOG" ;;
    '~'*)      bad log-path "names an unexpanded home shorthand: $B_LOG" ;;
    /*)        ok log-path "absolute, fully expanded: $B_LOG"; RESOLVED="$B_LOG" ;;
    *)         bad log-path "not an absolute path: $B_LOG" ;;
  esac
fi
if [ -n "$RESOLVED" ] && [ -n "$EVIDENCE_ROOT" ] && [ ! -f "$RESOLVED" ]; then
  RESOLVED="$EVIDENCE_ROOT/${B_LOG#/}"
fi

if [ -z "$B_SHA" ]; then
  bad digest "no Log SHA-256 bullet — nothing to recompute against, which fails the same as a mismatch"
elif ! printf '%s' "$B_SHA" | grep -qE '^[0-9a-f]{64}$'; then
  bad digest "not 64 lowercase hex characters: $B_SHA"
elif [ -n "$RESOLVED" ] && [ -f "$RESOLVED" ]; then
  actual=$(sha256sum "$RESOLVED" | awk '{print $1}')
  if [ "$actual" = "$B_SHA" ]; then
    ok digest "recomputed digest matches"
  else
    bad digest "recomputed $actual != stated $B_SHA"
  fi
else
  skip digest "well-formed, but the log is not on this disk — recompute where it is"
fi

# The per-command exit record `exit-count` cross-checks against (#602), decided
# once here so the check does not re-read the log or duplicate the "log
# unresolved / not on this disk" guard. Two sources, in this preference order,
# and NEVER a whole-file `grep -c '^\[exit='`:
#   1. `<log>.exits`, the sidecar implementer.md's recipe writes — one line per
#      command, written by the runner itself, so nothing a command prints can
#      reach it.
#   2. otherwise the bounded per-command marker scan the `commands` check below
#      already performs: an entry is credited only with a marker between its own
#      echoed line and the next command's, so a phantom line inside one command's
#      output is at worst that command's own marker and is never counted twice.
# Neither available (log off this disk, or the scan could not complete because
# an entry is unechoed) is a SKIP, not a FAIL. The whole-file read-back is
# excluded because issue #539 established that a command's own output can print
# a line starting with `[exit=` — it recorded 26 commands against 29 grepped
# markers on PR #498's shipped log, and implementer.md's own worked example
# prints `grep -c '^\[exit=' "$LOG" -> 3` against `wc -l < "$LOG.exits" -> 2`.
# The sidecar exists to replace that read-back; PR #573's approved review
# records it as the accepted resolution.
LOG_HAS_MARKERS=0        # does the log carry ANY marker (a gate, not a count)
EXITS_N=""               # the per-command exit record's count
EXITS_SRC=""             # "" | sidecar | scan
EXITS_UNREADABLE=0       # the sidecar is there, but this run cannot read it
SCAN_RAN=0; SCAN_MARKED=0; SCAN_UNECHOED=0
if [ -n "$RESOLVED" ] && [ -f "$RESOLVED" ]; then
  if grep -q '^\[exit=' "$RESOLVED"; then LOG_HAS_MARKERS=1; fi
  # `-r` as well as `-f`: a reviewer runs this against another agent's scratch
  # directory on a shared host, where the sidecar can exist and be unreadable.
  # Reading it anyway aborts the whole run under `set -euo pipefail` at exit 2 —
  # the code `argerr` reserves for a bad invocation — and truncates every check
  # after this one. Falling through to the bounded scan (or to the SKIP) keeps
  # the report whole; `exit-count` names the unreadable sidecar in its detail so
  # it is not silently read as absent.
  if [ -f "$RESOLVED.exits" ]; then
    if [ -r "$RESOLVED.exits" ]; then
      EXITS_N=$(awk 'END { print NR }' "$RESOLVED.exits")
      EXITS_SRC=sidecar
    else
      EXITS_UNREADABLE=1
    fi
  fi
fi

cmds=(); while IFS= read -r l; do [ -n "$l" ] && cmds+=("$l"); done < <(sublist Command)
if [ "${#cmds[@]}" -eq 0 ]; then
  inline=$(field Command)
  [ -n "$inline" ] && cmds+=("$inline")
fi
if [ "${#cmds[@]}" -eq 0 ]; then
  bad commands "the Command field names no command"
elif [ -z "$RESOLVED" ] || [ ! -f "$RESOLVED" ]; then
  skip commands "${#cmds[@]} $([ "${#cmds[@]}" -eq 1 ] && echo entry || echo entries) to check, but the log is not on this disk"
else
  markers="$LOG_HAS_MARKERS"
  SCAN_RAN=1
  # Every entry, normalised the same way the echo test normalises a log line, so
  # the marker scan below can recognise the next command on a log that echoes
  # its commands bare. Written to a file rather than passed with `-v` for the
  # same escape-expansion reason the echo test uses ENVIRON.
  printf '%s\n' "${cmds[@]}" > "$WORK/cmds.list"
  unechoed=""; unmarked=""
  for c in "${cmds[@]}"; do
    # An entry counts as echoed when some LINE of the log *is* that command,
    # allowing only a runner's own prompt prefix (`$ `, `+ `, `> `) in front of
    # it. A substring match would accept a command named inside a prose section
    # header (`=== <cmd> ===`), and that is the exact shape the reviewer's check
    # 3 condition 3 fails: the literal command line must appear as a line.
    # The command reaches awk through the environment, never through `-v`: awk
    # processes escape sequences in a `-v` assignment, so a command containing
    # `\n`, `\t` or `\\` — `tr '\n' ' '` is an ordinary one — arrives with that
    # escape already expanded and can never equal the log's literal line. That
    # misses as a FAIL on an honest manifest, which is the one verdict this
    # script must never produce. ENVIRON does no such processing.
    ln=$(CM_ENTRY="$c" awk '
      BEGIN { cmd = ENVIRON["CM_ENTRY"] }
      { line = $0; sub(/^[$+>][ \t]*/, "", line); sub(/[ \t]+$/, "", line)
        if (line == cmd) { print NR; exit } }' "$RESOLVED")
    if [ -z "$ln" ]; then
      unechoed="$unechoed, $c"
      # Counted on its own line, never on the accumulator above: the suite's
      # `commands` mutation probe neuters that accumulator, and the bounded
      # scan still has to know it did not complete.
      SCAN_UNECHOED=$((SCAN_UNECHOED + 1))
      continue
    fi
    [ "$markers" -gt 0 ] || continue
    # The entry's own exit marker: the first `[exit=` line after the line that
    # echoes it. A marker further down, past the next echoed command, belongs to
    # that command and not to this one — so the scan has to stop where the next
    # command starts, and it has to recognise that line the same way the echo
    # test above does. A prompt-prefixed line is one boundary; a line that IS
    # another **Command** entry, bare, is the other. Without the second, a log
    # from a runner that echoes bare (`set -x` off, `echo "$cmd"`) has no
    # boundary at all: the scan runs past every later command to the first
    # marker in the file and credits this entry with a marker belonging to
    # another one — a false PASS on the check this script exists for (#589
    # review, finding 5).
    if ! awk -v start="$ln" -v listf="$WORK/cmds.list" '
      BEGIN { while ((getline l < listf) > 0) is_cmd[l] = 1 }
      NR <= start { next }
      /^\[exit=/ { found = 1; exit }
      /^[$+>][ \t]/ { exit }
      { line = $0; sub(/^[$+>][ \t]*/, "", line); sub(/[ \t]+$/, "", line)
        if (line in is_cmd) exit }
      END { exit (found ? 0 : 1) }' "$RESOLVED"; then
      unmarked="$unmarked, $c"
    else
      SCAN_MARKED=$((SCAN_MARKED + 1))
    fi
  done
  if [ -n "$unechoed" ]; then
    bad commands "the log does not echo: ${unechoed#, } — a command named only in a prose section header fails the reviewer's check 3"
  elif [ -n "$unmarked" ]; then
    bad commands "echoed, but with no [exit=N] of its own before the next command: ${unmarked#, }"
  elif [ "$markers" -eq 0 ]; then
    ok commands "all ${#cmds[@]} entries echoed verbatim (the log carries no [exit=N] markers, so per-command exits were not checkable)"
  else
    ok commands "all ${#cmds[@]} entries echoed verbatim, each with its own [exit=N]"
  fi
fi

# ---------------------------------------------------------------------------
# exit-count — **Exit code** carries one entry per **Command** entry, and, when
# the run's own per-command exit record is available, that record's count
# agrees with both (#602). The record is the `<log>.exits` sidecar or the
# bounded per-command scan selected above — never a whole-file `grep -c`; see
# the block that sets EXITS_SRC for why.
#
# Counting is attempted only on a shape implementer.md makes unambiguous. Per
# the owner ruling of 2026-09-04 (#651, PR #626#issuecomment-5545298875):
# ANNOTATED and INLINE are two independent properties of the field, never one
# inferred from the other. An annotated **Exit code** field (one that carries
# prose alongside the exit codes) is written one entry per sub-bullet, so an
# entry is a line and there is no separator to parse at all. A bare list that
# carries no annotation at all may stay inline. A field that is BOTH annotated
# AND written inline is the reported defect — never guessed at, never parsed.
# That leaves exactly three cases:
#
#   sub-bullets                 -> count the lines
#   bare inline list, unannotated -> count the commas ("0", "0, 0, 1, 0")
#   annotated AND inline        -> a manifest defect: report it, do not parse it
#
# The third case is reported rather than guessed at, because guessing is what
# three review rounds of this check got wrong. Splitting an annotated inline
# value means telling the commas that separate entries from the commas inside
# annotation prose, and prose routinely carries a number followed by a comma or
# a paren ("0 — clean, lines 7, 9, 12 matched"). Each rule tried read some
# prose as an entry, and an entry invented out of prose covers for a missing
# one — so a manifest omitting the entry for a command that exited non-zero
# read as clean, which is #602's own failure mode. There is deliberately no
# separator heuristic here any more: the field spec removed the separator
# instead of asking this script to guess where it is. #678: telling annotated
# from unannotated is done on whether the value carries any alphabetic
# character at all (see `punct_only`), never on which punctuation character
# separates the entries — a value can use any separator and still be
# unannotated, and the punctuation branch below reports that shape rather than
# misreading it as prose.
#
# The aggregate form `0 (every command above)` is annotated in appearance but
# is the whole field rather than an entry within a list, so it stays inline and
# is recognised before the bare/annotated test below.
# ---------------------------------------------------------------------------

# bare_inline <value> — true when the value is an unannotated inline entry
# list: exit codes separated by commas, and nothing else. Whole-string
# anchored, so anything past digits, commas and spaces — prose, a dash, a
# paren, a code span, an unpaired backtick — is annotation and falls to the
# defect branch rather than being read through. Nothing here scans for code
# spans: there is no shape this accepts in which a backtick could appear, so
# the unpaired-backtick reading that used to leave a scanner stuck mid-span
# (and false-FAIL an honest manifest) has no code left to go wrong in.
bare_inline(){ printf '%s' "$1" | grep -qE '^[0-9]+([[:space:]]*,[[:space:]]*[0-9]+)*$'; }

# punct_only <value> — true when the value carries no alphabetic character at
# all, so it COULD have been an exit-code list but for some punctuation or
# separator mistake (`bare_inline`'s anchor already rejected it, so at minimum
# a leading, trailing or doubled comma, or a non-comma separator, is present).
# Reached only for a value `bare_inline` already rejected.
#
# The owner ruling of 2026-09-04 (PR #626#issuecomment-5545298875) is the
# governing rule here, and it settles two properties as independent: whether a
# field is ANNOTATED (carries prose alongside the exit codes) is a separate
# fact from whether it is written INLINE (on the field's own line) rather than
# one entry per sub-bullet. An annotated field is written one entry per
# sub-bullet; a bare, unannotated list may stay inline; a field that is BOTH
# annotated AND inline is the reported defect (#660) — never guessed at, never
# parsed. #678: `punct_only` used to test only a fixed digit/comma/whitespace
# character set, so any OTHER separator (`;`, `|`, `/`, `-`, a bare space) fell
# through to the annotated-inline branch and was misreported as carrying
# prose it does not have — the same defect #660 was filed against, merely
# narrowed to comma shapes rather than eliminated. Testing for the absence of
# any alphabetic character is what actually distinguishes "no annotation" from
# "annotation", independently of which punctuation the author used — nothing
# here re-introduces the separator inference the 2026-09-04 ruling removed:
# an unannotated value found this way is STILL never counted, only reported.
punct_only(){ ! printf '%s' "$1" | grep -qE '[[:alpha:]]'; }

# punct_shape <value> — names the actual separator/punctuation shape found in
# an unannotated value `punct_only` accepted, for the diagnostic. #678: this
# used to name only the three comma shapes, so a value using any other
# separator (a semicolon, a pipe, a slash, a hyphen, a bare space with no comma
# at all) fell to a generic "stray punctuation" fallback that did not say what
# the actual mistake was. Comma shapes are checked first since more than one
# can co-occur; anything else names the literal character found, or, when the
# only separator is whitespace with no comma anywhere, says so directly.
punct_shape(){
  local v="$1" out="" other
  printf '%s' "$v" | grep -qE '^[[:space:]]*,' && out="${out:+$out, }a leading comma"
  printf '%s' "$v" | grep -qE ',[[:space:]]*$' && out="${out:+$out, }a trailing comma"
  printf '%s' "$v" | grep -qE ',[[:space:]]*,' && out="${out:+$out, }a doubled comma"
  if [ -z "$out" ]; then
    other=$(printf '%s' "$v" | grep -oE '[^0-9[:space:],]' | sort -u | tr -d '\n')
    if [ -n "$other" ]; then
      out="entries separated by '${other:0:1}' rather than a comma"
    elif printf '%s' "$v" | grep -qE '[0-9][[:space:]]+[0-9]'; then
      out="entries separated by whitespace, with no comma at all"
    fi
  fi
  [ -n "$out" ] || out="stray punctuation"
  printf '%s' "$out"
}

# count_bare_entries <value> — entries in a bare inline list: one more than the
# commas. Only ever reached for a value `bare_inline` accepted, where every
# comma is a separator by construction.
count_bare_entries(){
  local commas
  commas=$(printf '%s' "$1" | tr -cd ',' | wc -c)
  printf '%s\n' "$((commas + 1))"
}

# same_count <command-entries> <exit-entries> — the one guard the exit-count
# mutation probe neuters.
same_count(){ [ "$1" -eq "$2" ]; }

exit_sub=(); while IFS= read -r l; do [ -n "$l" ] && exit_sub+=("$l"); done < <(sublist "Exit code")
AGGREGATE_RE='^0[[:space:]]*\(every[[:space:]]+command[[:space:]]+above\)$'
EXIT_DEFECT=0; EXIT_DEFECT_KIND=""; exit_field=""
if [ "${#exit_sub[@]}" -gt 0 ]; then
  exit_n="${#exit_sub[@]}"; exit_src="sub-bullet list"
else
  exit_field=$(field "Exit code")
  if printf '%s' "$exit_field" | grep -qE "$AGGREGATE_RE"; then
    # The aggregate form names no per-command entry, so it counts as one per
    # Command entry by definition — implementer.md allows it only when every
    # marker really is 0. This check arbitrates counts here; whether the
    # record's VALUES are all zero is arbitrated separately below (#646), once
    # EXITS_SRC/the sidecar are resolved.
    exit_n="${#cmds[@]}"; exit_src="aggregate form '0 (every command above)'"
  elif [ -z "$exit_field" ]; then
    exit_n=0; exit_src="empty"
  elif bare_inline "$exit_field"; then
    exit_n=$(count_bare_entries "$exit_field"); exit_src="bare inline list"
  elif punct_only "$exit_field"; then
    EXIT_DEFECT=1; EXIT_DEFECT_KIND=punct; exit_n=0; exit_src="malformed punctuation"
  else
    EXIT_DEFECT=1; EXIT_DEFECT_KIND=annot; exit_n=0; exit_src="annotated inline list"
  fi
fi

# The bounded scan's count is usable only when the scan actually ran over every
# entry; an unechoed entry is reported by `commands` and leaves this check
# without a record to compare against.
if [ -z "$EXITS_SRC" ] && [ "$SCAN_RAN" -eq 1 ] && [ "$SCAN_UNECHOED" -eq 0 ]; then
  EXITS_N="$SCAN_MARKED"; EXITS_SRC=scan
fi
case "$EXITS_SRC" in
  sidecar) exits_desc="marker count from the run's own $(basename "$RESOLVED").exits sidecar" ;;
  scan)    exits_desc="marker count from the bounded per-command scan" ;;
  *)       exits_desc="" ;;
esac
# An unreadable sidecar is named in the diagnostic rather than silently treated
# as absent: the fall-back to the scan (or to the SKIP) keeps the rest of the
# report whole, and the reader still learns the record was there and unusable.
[ "$EXITS_UNREADABLE" -eq 1 ] && exits_desc="${exits_desc:+$exits_desc; }a $(basename "$RESOLVED").exits sidecar sits beside the log but is not readable, so it was not used"

# #646 — the aggregate form's count agrees with Command's by construction (it
# names no per-command entry), which is exactly why the COUNT comparison can
# never catch a manifest that claims "every command above" is `0` when one of
# them was not. Arbitrated here instead, against the one record that carries
# per-command VALUES rather than just a count: the `<log>.exits` sidecar. The
# bounded scan only ever counts markers, never reads them, so an aggregate form
# backed by the scan (no readable sidecar) is not arbitrable this way and stays
# a plain count check, same as before #646.
#
# #677 — a sidecar line is judged with a whitespace-tolerant anchor (the C
# locale's [[:space:]] class covers a trailing CR as well as a plain space or
# tab), so a genuinely-zero record written on a CRLF host, or with a stray
# trailing space, is read as zero rather than as one of the "sidecar records:
# 0 , 0" false FAILs #677 reported. A line that is not a decimal integer at
# all once that padding is allowed for — blank, or non-numeric junk — is a
# different fact from a command having exited non-zero: it is a malformed
# record, and it is named as one below rather than folded into the non-zero
# list, so the reader is never told a `0` they can see is somehow not zero.
SIDECAR_INT_RE='^[[:space:]]*[0-9]+[[:space:]]*$'
AGGREGATE_NONZERO=""
AGGREGATE_MALFORMED=""
if [ "$exit_src" = "aggregate form '0 (every command above)'" ] && [ "$EXITS_SRC" = sidecar ]; then
  all_vals=""; has_nonzero=0; malformed=""
  # #1 (round 1) — `read` returns non-zero on a final record with no
  # trailing newline, and a plain `while read; do …; done` loop tests only
  # that return status, so the record it still populated `rec` with is
  # silently dropped rather than counted. The `|| [ -n "$rec" ]` disjunct
  # lets a trailing, newline-less record through the body one last time,
  # while a genuinely empty final read (the ordinary case, file ends with a
  # newline) still ends the loop without a phantom blank record.
  while IFS= read -r rec || [ -n "$rec" ]; do
    if printf '%s' "$rec" | grep -qE "$SIDECAR_INT_RE"; then
      val=$(printf '%s' "$rec" | tr -d '[:space:]')
      all_vals="${all_vals:+$all_vals, }$val"
      # #5 (round 1) — a numeric comparison, not a string one: `[ "$val" =
      # "0" ]` treats "00" as a distinct value from "0" and misreports a
      # genuinely-zero record as non-zero.
      [ "$val" -eq 0 ] 2>/dev/null || has_nonzero=1
    else
      shown=$(printf '%s' "$rec" | tr -d '\r')
      # #712 round 2, note 5 — a whitespace-only record (spaces/tabs, no CR)
      # survived the `\r`-only strip above as a non-empty, invisible string
      # and rendered as nothing at all instead of "<blank>". Test emptiness
      # against the fully-stripped value, but keep displaying `shown` (only
      # `\r` removed) so a record that carries visible non-numeric junk is
      # still shown as typed.
      if [ -z "$(printf '%s' "$shown" | tr -d '[:space:]')" ]; then shown="<blank>"; fi
      malformed="${malformed:+$malformed, }$shown"
    fi
  done < "$RESOLVED.exits"
  [ "$has_nonzero" -eq 1 ] && AGGREGATE_NONZERO="$all_vals"
  AGGREGATE_MALFORMED="$malformed"
fi

if [ "$EXIT_DEFECT" -eq 1 ] && [ "$EXIT_DEFECT_KIND" = punct ]; then
  bad exit-count "Exit code is inline, but malformed: $(punct_shape "$exit_field") makes it unsafe to count as a list. This value carries no prose of any kind, so it is not the defect of being written with annotation (#660) — it is a punctuation mistake. Fix it (one entry per comma, no leading/trailing/doubled comma), or re-post with one entry per sub-bullet"
elif [ "$EXIT_DEFECT" -eq 1 ] && [ -n "$COMMENT_AT" ] && [ "$COMMENT_AT" \< "$RULING_AT" ]; then
  bad exit-count "Exit code is annotated and written inline — a manifest defect per templates/implementer.md's Exit code bullet, which writes an annotated field one entry per sub-bullet. Not counted: inside annotation prose an entry cannot be told from a comma. This manifest's own comment was posted $COMMENT_AT, before the $RULING_AT owner ruling (https://github.com/blac9216/storage/pull/626#issuecomment-5545298875) first required the sub-bullet form — it was written correctly for the spec at the time, and its PR is necessarily already merged, so there is nothing to re-post; this FAIL is historical record, not a live defect (#657)"
elif [ "$EXIT_DEFECT" -eq 1 ]; then
  bad exit-count "Exit code is annotated and written inline — a manifest defect per templates/implementer.md's Exit code bullet, which writes an annotated field one entry per sub-bullet. Not counted: inside annotation prose an entry cannot be told from a comma. Re-post the manifest with one entry per sub-bullet"
elif [ "${#cmds[@]}" -eq 0 ]; then
  bad exit-count "no Command entries to compare Exit code's $exit_n against (see commands)"
elif [ "$exit_n" -eq 0 ]; then
  bad exit-count "Exit code carries no entries to compare against ${#cmds[@]} Command entries"
elif ! same_count "${#cmds[@]}" "$exit_n"; then
  bad exit-count "Command lists ${#cmds[@]} entries, Exit code lists $exit_n ($exit_src) — counts disagree"
elif [ -n "$AGGREGATE_MALFORMED" ]; then
  bad exit-count "Exit code claims the aggregate form '0 (every command above)', but the run's own $(basename "$RESOLVED").exits sidecar carries a record that is not a decimal integer: $AGGREGATE_MALFORMED — a malformed record, which is a different fact from a command having exited non-zero (#677). Fix the sidecar, or re-post with the sub-bullet Exit code list naming the actual per-command exits"
elif [ -n "$AGGREGATE_NONZERO" ]; then
  bad exit-count "Exit code claims the aggregate form '0 (every command above)', but the run's own $(basename "$RESOLVED").exits sidecar records: $AGGREGATE_NONZERO — the aggregate form is only correct when every marker really is 0 (#646). Re-post with the sub-bullet Exit code list naming the actual per-command exits"
elif [ -z "$EXITS_SRC" ]; then
  skip exit-count "${#cmds[@]} Command entries and $exit_n Exit code entries ($exit_src) agree, but there is no per-command exit record to cross-check them against — no readable <log>.exits sidecar beside the log, and no complete per-command scan (see commands)${exits_desc:+ ($exits_desc)}"
elif [ "$EXITS_SRC" = scan ] && [ "$LOG_HAS_MARKERS" -eq 0 ]; then
  ok exit-count "${#cmds[@]} Command entries and $exit_n Exit code entries ($exit_src) agree (the log carries no [exit=N] markers, so the count could not be cross-checked against it)"
elif [ "$EXITS_N" -ne "${#cmds[@]}" ]; then
  bad exit-count "Command (${#cmds[@]}) and Exit code ($exit_n, $exit_src) agree with each other, but the log carries $EXITS_N [exit=N] marker(s) — disagreement with the raw log ($exits_desc)"
else
  ok exit-count "${#cmds[@]} Command entries, $exit_n Exit code entries ($exit_src), $EXITS_N log [exit=N] markers — all three counts agree ($exits_desc)"
fi

# ---------------------------------------------------------------------------
# env-quote — check 2's no-suites exception and the two look-alikes it excludes.
# ---------------------------------------------------------------------------
DECL='no suites — review-only'
ENV_V=$(field Env)
if ! grep -qF -- "$DECL" "$WORK/testing.md"; then
  na env-quote "docs/process/testing.md states no '$DECL' declaration"
elif [ -z "$ENV_V" ]; then
  bad env-quote "no Env bullet to carry the declaration this repo's Command check passes by"
elif printf '%s' "$ENV_V" | grep -qF -- "$DECL"; then
  ok env-quote "quotes the declaration verbatim"
else
  # Name which look-alike was quoted instead, rather than reporting a bare miss:
  # the three sentences read alike and sit within a few lines of each other, and
  # "the wrong one" is the whole finding.
  why="it quotes neither"
  if printf '%s' "$ENV_V" | grep -qiE 'not (installed|available)'; then
    why="it quotes the doc's conditional lint-state phrase, which arbitrates the Lint state bullet instead"
  elif printf '%s' "$ENV_V" | grep -qiE 'not required|no .*required'; then
    why="it quotes the 'suites are not required' sentence, which check 2 excludes by name"
  fi
  bad env-quote "Env does not quote '$DECL' — $why"
fi

# ---------------------------------------------------------------------------
# results-count — #629. A **Results** field is free-text prose and this
# script never tries to verify prose in general: an attempt to do so is
# exactly what produces false positives on legitimate summaries ("2 commands,
# 0 unexpected failures" names the Command count, not something read off the
# log, and must never FAIL for that). This check is instead anchored on the
# ONE narrow, literal shape PR #621's round-0 manifest actually got wrong —
# never a general semantic read of Results — so a manifest using ordinary
# language outside that shape is simply untouched (na), not guessed at.
#
#   results-count       Results states a number immediately before the word
#                        "check(s)" or "assertion(s)" ("66 checks passed").
#                        That number must appear as a standalone token
#                        somewhere in the raw log; #629's own finding is that
#                        "66" appeared in neither the log nor the suite's own
#                        output. A **Command**-derived count phrased some other
#                        way ("2 commands") never matches this narrow trigger
#                        and is never touched.
#
# `results-log-section` and `results-command` — the other two checks #629
# originally added alongside this one — were removed by #732
# (extraction-vs-interpretation): both decided whether a **Results** sentence
# *asserted* something about the raw log's shape or about a command having
# been run, which is a judgement about what an English sentence means rather
# than extraction from an agreed marker, and both reported `n/a` on every
# manifest posted in this repo to date. That judgement is now the reviewer's.
#
# What this deliberately does NOT attempt: a general check that "everything
# Results claims is true", or that a check-count phrased any other way
# reconciles with the log. A natural-language field cannot be fully verified
# against a log without guessing at meaning, and guessing is the
# false-positive failure mode #602 and #660 were both filed against in the
# neighbouring exit-count check — the same restraint applies here.
# ---------------------------------------------------------------------------
RESULTS_V=$(field Results)

# results-count
count_claims=$(printf '%s' "$RESULTS_V" | grep -oiP '\b[0-9]+(?=[[:space:]]+(?:checks?|assertions?)\b)' || true)
if [ -z "$count_claims" ]; then
  na results-count "Results states no '<N> check(s)'/'<N> assertion(s)' count to verify"
elif [ -z "$RESOLVED" ] || [ ! -f "$RESOLVED" ]; then
  skip results-count "Results states a check/assertion count, but the log is not on this disk to verify it against"
else
  unseen=""
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    grep -qE "(^|[^0-9])$n([^0-9]|\$)" "$RESOLVED" || unseen="${unseen:+$unseen, }$n"
  done <<<"$count_claims"
  if [ -n "$unseen" ]; then
    bad results-count "Results states a count of $unseen check(s)/assertion(s), but that number appears nowhere in the raw log (#629)"
  else
    ok results-count "every check/assertion count Results states appears in the raw log"
  fi
fi

echo "check-manifest: #$PR round $best_round — $pass_n pass, $fail_n fail, $skip_n skipped"

# ---------------------------------------------------------------------------
# --markdown — the same verdicts above, rendered as a paste-ready table after
# the plain-text report. The plain-text report above is unchanged either way,
# so a caller (or this script's own test) parsing it sees identical output
# with or without this flag.
# ---------------------------------------------------------------------------
if [ "$MARKDOWN" -eq 1 ]; then
  echo
  echo "### check-manifest — PR #$PR round $best_round"
  echo "| Status | Check | Detail |"
  echo "|---|---|---|"
  for r in "${RESULTS[@]}"; do
    IFS=$'\t' read -r rstatus rname rmsg <<<"$r"
    rmsg="${rmsg//|/\\|}"
    printf '| %s | %s | %s |\n' "$rstatus" "$rname" "$rmsg"
  done
  echo
  echo "$pass_n pass, $fail_n fail, $skip_n skipped"
fi

[ "$fail" -eq 0 ] || exit 1
[ "$skip_n" -eq 0 ] || exit 3
exit 0
