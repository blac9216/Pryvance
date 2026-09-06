#!/usr/bin/env bash
# check-reviewer-commits.sh — the reviewer-applied gate
# (github-pr-review/references/verdict-rules.md § Reviewer-applied gate) mechanised.
# READ-ONLY: issues no mutation of any kind, locally or against GitHub.
#
# Usage: check-reviewer-commits.sh <pr> --base <approval-sha> [--head <sha>]
#                                   [--repo owner/name] [--markdown]
#
# <approval-sha> is the PR's approved head *before* any reviewer-applied commits — the
# same SHA the merge-verifier's dispatch carries and fetches
# (`git fetch origin <approval-sha>`) before running this. There is no reliable way to
# derive that SHA from the PR alone (an "Approved" verdict's footer names a round, not
# a head), so --base is required; omitting it is a usage error (exit 2), not a guess.
# --head defaults to the PR's current head SHA, read live via `gh api`.
#
# Must run from inside a git checkout that already has both SHAs reachable locally
# (`git cat-file -e`) — the caller's job, exactly as the merge-verifier prose states it
# fetches <approval-sha> itself first. This script never runs `git fetch`: a network
# write-adjacent call is not something a READ-ONLY script issues on its own, even one
# aimed at origin rather than at the PR.
#
# The five conditions, verbatim from verdict-rules.md § Reviewer-applied gate:
#   1. Tagged, one finding per commit — `Reviewer-applied: PR #<P> round <R> finding <F>`
#      trailer, this PR's number, no more than one `Reviewer-applied:` trailer per commit.
#   2. Files within the PR's diff — every path in a reviewer commit lands within
#      `git diff --name-only origin/<base-branch>...<approval-sha>`.
#   3. Strip-and-compare on every touched, non-exempt file: whole-line comments,
#      trailing comments, and all whitespace stripped (comment syntax by extension);
#      Markdown/reStructuredText/AsciiDoc/plain text exempt UNLESS the path sits under
#      `.claude/agents/`, `.claude/skills/`, or a path the head tree's
#      docs/process/testing.md names as agent instructions (agent-read instruction text,
#      stripped by `<!-- ... -->` and whitespace only, per the gate's own carve-out).
#   4. At most ten changed lines per round, summed `git diff --numstat` over every
#      reviewer-applied commit in the range.
#   5. CI green on <head> — via `gh api` check-runs, falling back to the legacy status
#      API exactly as preflight.sh does when check-runs itself reports zero runs; that
#      fallback counts only when the response actually carries statuses
#      (`.statuses | length > 0`), since GitHub answers state:"pending" with an empty
#      statuses array for a commit that has none. On a
#      no-CI repository (docs/process/testing.md — read from the <head> tree, like every
#      other condition's read — declares, verbatim, "no suites — review-only",
#      and neither check-runs, a legacy status, nor a .github/workflows definition exists)
#      this condition is reported PASS-BY-DECLARATION: the script cannot itself re-run a
#      PR's Suggested Test Steps, so the caller (reviewer or merge-verifier) records that
#      half by hand, per the gate's own text ("never vacuously").
#
# Output: one line per commit x condition on stdout (or --markdown for a report table),
# then a summary line. Exit 0 = every reviewer-applied commit in range passes every
# condition (including the empty-range case: nothing to check is not a failure). Exit 1
# = at least one commit failed at least one condition — each failure line names the
# commit and the condition. Exit 2 = usage error.
#
# No repository- or owner-specific nouns appear in this script; the target repo comes
# from --repo or, failing that, `gh repo view` on the current checkout.
#
# THIS SCRIPT IS THE SUITE'S ONE STATED EXCEPTION to the no-runtime-document-reads rule
# (#748, github-tools.md's extraction-vs-interpretation section): condition 3's exemption
# carve-out and condition 5's no-CI declaration are both read from docs/process/testing.md
# at the PR's <head> tree, not taken as a caller-supplied argument. The reason is the gate
# itself — this script arbitrates conditions a PR's own author is being judged against, so
# the source of truth has to be the tree actually under review, never the caller's belief
# about it. A caller-supplied value here would let a PR author configure the very gate
# that judges their own commits (e.g. asserting "no CI" to skip condition 5, or naming
# their own file as agent-instruction text to dodge condition 3's stricter comparison) —
# exactly the trust boundary #736's "the calling agent already knows" argument does not
# reach across. `check-manifest.sh`'s `--lint` and `preflight.sh`'s dropped testing.md
# report went the other way (#748) because neither decides a gate condition about the
# tree under review; this one does.
set -euo pipefail

die(){ echo "check-reviewer-commits: $*" >&2; exit 1; }
argerr(){ echo "check-reviewer-commits: $*" >&2; exit 2; }

PR=""; REPO=""; BASE=""; HEAD=""; MARKDOWN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) [ $# -ge 2 ] || argerr "--repo needs a value"; REPO="$2"; shift 2 ;;
    --base) [ $# -ge 2 ] || argerr "--base needs a value"; BASE="$2"; shift 2 ;;
    --head) [ $# -ge 2 ] || argerr "--head needs a value"; HEAD="$2"; shift 2 ;;
    --markdown) MARKDOWN=1; shift ;;
    -*) argerr "unknown flag $1" ;;
    *)
      [ -z "$PR" ] || argerr "unexpected extra argument $1"
      PR="$1"; shift ;;
  esac
done
[ -n "$PR" ] || argerr "usage: check-reviewer-commits.sh <pr> --base <approval-sha> [--head <sha>] [--repo owner/name] [--markdown]"
case "$PR" in ''|*[!0-9]*) argerr "<pr> must be a positive integer, got: $PR" ;; esac
[ -n "$BASE" ] || argerr "--base <approval-sha> is required — there is no way to derive the approved head from the PR alone"

git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || argerr "must run from inside a git checkout with <approval-sha> and <head> already fetched"

# Condition 3's block-comment strips (`/* ... */`, `<!-- ... -->`) need a lazy,
# multi-line regex, which GNU sed's line-based ERE cannot express. perl is the
# only hard dependency beyond git/gh/jq; say so rather than silently degrading.
command -v perl >/dev/null 2>&1 \
  || die "perl is required: condition 3 strips block comments that may span lines"

[ -n "$REPO" ] || REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null) \
  || die "could not resolve --repo and 'gh repo view' failed — pass --repo owner/name"

git cat-file -e "${BASE}^{commit}" 2>/dev/null \
  || die "--base $BASE is not a commit reachable in this checkout — fetch it first (git fetch origin $BASE)"

PR_JSON=$(gh api "repos/$REPO/pulls/$PR" --jq '{head:.head.sha, base:.base.ref}' 2>&1) \
  || die "GET repos/$REPO/pulls/$PR failed: $PR_JSON"
PR_HEAD=$(jq -r .head <<<"$PR_JSON")
PR_BASE_BRANCH=$(jq -r .base <<<"$PR_JSON")
[ -n "$HEAD" ] || HEAD="$PR_HEAD"
[ -n "$HEAD" ] && [ "$HEAD" != "null" ] || die "could not resolve --head; PR #$PR returned no head SHA"

git cat-file -e "${HEAD}^{commit}" 2>/dev/null \
  || die "--head $HEAD is not a commit reachable in this checkout — fetch it first"

# The PR's own diff base — the set of paths a reviewer-applied commit is allowed to
# touch (condition 2). `origin/<base-branch>` must be present locally; a missing
# tracking ref is a usage problem, not a gate finding.
git rev-parse --verify "origin/$PR_BASE_BRANCH" >/dev/null 2>&1 \
  || die "origin/$PR_BASE_BRANCH is not present locally — fetch the base branch first"
ALLOWED_PATHS_FILE=$(mktemp "${TMPDIR:-/tmp}/check-reviewer-commits.allowed.XXXXXX")
WORK=$(mktemp -d "${TMPDIR:-/tmp}/check-reviewer-commits.XXXXXX")
# shellcheck disable=SC2329 # invoked indirectly via `trap cleanup EXIT` on the next line
cleanup(){ rm -rf "$WORK" "$ALLOWED_PATHS_FILE"; }
trap cleanup EXIT
git diff --name-only "origin/$PR_BASE_BRANCH...$BASE" > "$ALLOWED_PATHS_FILE" 2>"$WORK/allowed.err" \
  || die "git diff --name-only origin/$PR_BASE_BRANCH...$BASE failed: $(cat "$WORK/allowed.err")"

# ---------------------------------------------------------------------------
# strip <path-at-ref> — comment-and-whitespace-stripped content of a file at a
# given revision, per the gate's comment-syntax table. Exempt formats (below)
# never call this; the caller decides exemption first.
# ---------------------------------------------------------------------------
strip_html_comments(){ # strip_html_comments <file> -> stdout, <!-- ... --> removed
  # perl, not sed: GNU sed's ERE has no lazy quantifier (`.*?` is greedy there)
  # and sed is line-based, so `s/<!--.*?-->//g` deletes real text sitting
  # between two comments on one line and misses a comment spanning lines --
  # divergences from verdict-rules.md in both directions. `-0` slurps the whole
  # file; `s`, plus a lazy `.*?`, makes `.` match newlines and stop at the
  # first `-->`. Same shape the C-family arm uses for `/* ... */`.
  perl -0pe 's{<!--.*?-->}{}gs' "$1"
}

strip_for_ext(){ # strip_for_ext <ext-lowercased> <content-file> -> stdout
  local ext="$1" f="$2"
  case "$ext" in
    md|markdown|rst|adoc|txt)
      # Instruction-text carve-out only: <!-- ... --> plus whitespace.
      strip_html_comments "$f" | tr -d '[:space:]' ;;
    py|sh|bash|yml|yaml|rb|pl|toml|ini|env|cfg|conf|dockerfile|makefile)
      sed -E 's/[[:space:]]*#.*$//' "$f" | sed '/^[[:space:]]*$/d' | tr -d '[:space:]' ;;
    sql)
      sed -E 's/[[:space:]]*--.*$//' "$f" | sed '/^[[:space:]]*$/d' | tr -d '[:space:]' ;;
    c|h|cc|hh|cpp|hpp|cxx|java|js|jsx|ts|tsx|go|rs|swift|kt|cs|php|json5|scss|less|css)
      # Whole-line // comments, trailing // comments, and /* ... */ block
      # comments (non-greedy, may span lines) — order matters: block comments
      # first so a `//` inside one is not mistaken for a line comment.
      perl -0pe 's{/\*.*?\*/}{}gs' "$f" \
        | sed -E 's#[[:space:]]*//.*$##' | sed '/^[[:space:]]*$/d' | tr -d '[:space:]' ;;
    xml|html|htm|svg)
      strip_html_comments "$f" | sed '/^[[:space:]]*$/d' | tr -d '[:space:]' ;;
    *)
      # Data/config formats with no comment syntax of their own (json, lock
      # files, and anything unlisted): whitespace-only strip. "Something
      # reads it" (the gate's own words) means it is executable-for-this-
      # purpose but has nothing to comment out, so only whitespace is inert.
      tr -d '[:space:]' < "$f" ;;
  esac
}

# NOTE: case patterns above are matched against ext_of's output, which is always
# lowercased -- so the `#`-comment arm spells `dockerfile`, not `Dockerfile`.
#
# is_recognized_extension <ext-lowercased> -- true (0) iff the trailing dotted
# segment itself denotes a distinct, known comment syntax (or a documented
# absence of one, e.g. json). ext_of consults this BEFORE ever considering the
# Dockerfile/Makefile/.env basename override below, so a real trailing
# extension always wins over the basename it happens to sit on top of
# (issue #644 round-1 finding F1: `Dockerfile.md`, `Makefile.js`, `.env.md`,
# `.environment.md` and `dockerfile.json` were all wrongly normalised to
# `dockerfile`/`env` because the override ran unconditionally on any dotted
# suffix, not only on suffixes that match no known extension). json is listed
# here even though it has no arm of its own in strip_for_ext -- it still
# denotes a real, distinct format (no comment syntax at all; the default
# whitespace-only strip is the CORRECT behaviour for it, not a fallback for an
# unrecognized token the way `prod`/`local`/`example` are).
is_recognized_extension(){
  case "$1" in
    md|markdown|rst|adoc|txt|py|sh|bash|yml|yaml|rb|pl|toml|ini|env|cfg|conf|dockerfile|makefile|sql|\
    c|h|cc|hh|cpp|hpp|cxx|java|js|jsx|ts|tsx|go|rs|swift|kt|cs|php|json|json5|scss|less|css|\
    xml|html|htm|svg) return 0 ;;
    *) return 1 ;;
  esac
}

ext_of(){ # ext_of <path> -> lowercase extension, or the whole basename with no dot
  local base="${1##*/}" ext first trailing trailing_lc
  case "$base" in
    *.*) trailing="${base##*.}" ;;
    *) trailing="" ;;
  esac
  trailing_lc=$(printf '%s' "$trailing" | tr '[:upper:]' '[:lower:]')
  # A real, recognized trailing extension always wins -- bounded to the
  # actual trailing suffix, never overridden by the basename it sits on.
  if [ -n "$trailing" ] && is_recognized_extension "$trailing_lc"; then
    printf '%s' "$trailing_lc"; return
  fi
  # Only an UNRECOGNIZED trailing suffix (an arbitrary variant/environment
  # tag: `prod`, `local`, `example`, ...), or no suffix at all, falls back to
  # the extensionless, comment-syntax-bearing basename's own syntax
  # (Dockerfile.prod, Makefile.local, .env.example -- issue #644).
  first="${base%%.*}"
  case "$first" in
    [Dd][Oo][Cc][Kk][Ee][Rr][Ff][Ii][Ll][Ee]) printf '%s' "dockerfile"; return ;;
    [Mm][Aa][Kk][Ee][Ff][Ii][Ll][Ee]) printf '%s' "makefile"; return ;;
  esac
  case "$base" in
    .env*) printf '%s' "env"; return ;;
  esac
  case "$base" in
    *.*) ext="$trailing_lc" ;;
    *) ext="$base" ;;
  esac
  printf '%s' "$ext" | tr '[:upper:]' '[:lower:]'
}

# verdict-rules.md condition 3 names three sources of agent-read instruction
# text: `.claude/agents/`, `.claude/skills/`, "or under a path the repo's
# docs/process/testing.md names as agent instructions". The third is read from
# the $HEAD tree (same tree as every other condition-3 read): every backticked
# path-looking token on a line of that document mentioning "agent instructions"
# is taken as a prefix. A repo whose testing.md names none — this one — yields
# an empty list and the first two clauses alone decide, exactly as before.
INSTRUCTION_PREFIXES_FILE="$WORK/instruction-prefixes"
: > "$INSTRUCTION_PREFIXES_FILE"
if instruction_doc=$(git cat-file blob "$HEAD:docs/process/testing.md" 2>/dev/null); then
  # shellcheck disable=SC2016 # literal backtick pattern; nothing here is meant to expand
  printf '%s\n' "$instruction_doc" \
    | grep -i 'agent instructions' \
    | grep -oE '`[^`]+`' \
    | tr -d '`' \
    | grep '/' \
    | sed -E 's#/+$##' \
    | sort -u > "$INSTRUCTION_PREFIXES_FILE" || :
fi

is_instruction_path(){ # true (0) iff path is agent-read instruction text
  local path="$1" prefix
  case "$path" in
    .claude/agents/*|.claude/skills/*) return 0 ;;
  esac
  while IFS= read -r prefix; do
    [ -n "$prefix" ] || continue
    case "$path" in
      "$prefix"|"$prefix"/*) return 0 ;;
    esac
  done < "$INSTRUCTION_PREFIXES_FILE"
  return 1
}

is_exempt(){ # true (0) iff path is exempt from condition 3's strip-and-compare
  local path="$1" ext
  ext=$(ext_of "$path")
  case "$ext" in
    md|markdown|rst|adoc|txt)
      is_instruction_path "$path" && return 1
      return 0 ;;
    *) return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# Condition 5: CI on <head>. Mirrors preflight.sh's check-runs-then-legacy-
# status fallback. Reports PASS-BY-DECLARATION on a documented no-CI repo,
# since the human half (re-running Suggested Test Steps) is out of this
# script's reach.
# ---------------------------------------------------------------------------
check_ci(){
  local runs total other state=unknown legacy legacy_json legacy_count workflow_tree
  local TESTING_DOC doc_state
  runs=$(gh api --paginate "repos/$REPO/commits/$HEAD/check-runs?per_page=100" \
    --jq '.check_runs[]? | {status,conclusion}' 2>"$WORK/ci.err") \
    || { echo "ci-error: GET check-runs failed: $(cat "$WORK/ci.err")"; return 1; }
  total=$(printf '%s\n' "$runs" | grep -c . || true)
  if [ "$total" -eq 0 ]; then
    # `.state` alone is NOT evidence that a legacy status exists: GitHub answers
    # {"state":"pending","total_count":0,"statuses":[]} for a commit with no
    # statuses at all, so gating on the state reports every no-CI head as
    # "pending" and never reaches the branches below. preflight.sh gates this
    # same fallback on `.statuses | length > 0` for exactly that reason
    # (issues #299/#300); mirror it rather than re-introducing the bug.
    # A failed GET is not an empty result: swallowing it (`|| legacy_json=""`)
    # folds a 5xx, a rate-limit response or an auth failure into the shape a
    # commit with genuinely no statuses produces, and on a no-CI repo that
    # reaches PASS-BY-DECLARATION -- an unestablished claim printed as an
    # observed one. preflight.sh dies on this same call; surface it here the
    # way the check-runs GET eleven lines above surfaces its own failure.
    legacy_json=$(gh api "repos/$REPO/commits/$HEAD/status" \
      --jq '{state:.state, count:([.statuses[]?] | length)}' 2>"$WORK/legacy.err") \
      || { echo "ci-error: GET commit status failed: $(cat "$WORK/legacy.err")"; return 1; }
    legacy=""; legacy_count=0
    if [ -n "$legacy_json" ]; then
      legacy=$(printf '%s' "$legacy_json" | jq -r '.state // ""' 2>/dev/null) || legacy=""
      legacy_count=$(printf '%s' "$legacy_json" | jq -r '.count // 0' 2>/dev/null) || legacy_count=0
    fi
    case "$legacy_count" in ''|*[!0-9]*) legacy_count=0 ;; esac
    if [ "$legacy_count" -gt 0 ] && [ -n "$legacy" ] && [ "$legacy" != "null" ]; then
      state="$legacy"
    else
      # Reached only when the head reported zero check-runs AND no legacy
      # status -- the evidence of CI takes precedence over any wording in the
      # doc, because zero check-runs on a repo that has CI means CI did not run
      # on this head, which is exactly what the gate must fail. A workflow
      # definition in the head tree is that same evidence, so it also bars this
      # branch.
      # Captured to a variable and fed to `grep` via a HERE-STRING, never a
      # pipe: under `set -o pipefail`, `grep -q` exits at its first match
      # while the pipeline's other end is still writing, so that writer dies
      # of SIGPIPE (141) and pipefail reports that as the pipeline's status
      # -- the `if` reads false and this bar is silently skipped once the
      # tree listing exceeds the pipe buffer (issue #652). This is true of
      # ANY writer on the left of a `| grep -q`, including a `printf` builtin
      # standing in for one -- a pipe still forks a subshell for each side,
      # so capturing into a variable and re-piping through `printf` merely
      # moves the same race from `git` to `printf` without closing it. A
      # here-string has no pipe at all (bash writes it to a temp file), so
      # there is nothing for `grep -q` to race against.
      workflow_tree=$(git ls-tree -r --name-only "$HEAD" -- .github/workflows 2>/dev/null)
      if grep -qE '\.ya?ml$' <<<"$workflow_tree"; then
        echo "ci: FAIL (no check-runs and no legacy status on $HEAD, but .github/workflows defines CI -- CI did not run on this head)"
        return 1
      fi
      # Read the declaration from the SAME tree as the workflow bar above: the
      # script never checks out $HEAD, so the process's working directory may
      # be on any ref (or be a subdirectory of the checkout, where a relative
      # `cat` finds nothing at all). Present-but-unreadable is reported as its
      # own error, never as an absent declaration.
      TESTING_DOC=""; doc_state=absent
      if git cat-file -e "$HEAD:docs/process/testing.md" 2>/dev/null; then
        if TESTING_DOC=$(git cat-file blob "$HEAD:docs/process/testing.md" 2>"$WORK/doc.err"); then
          doc_state=present
        else
          doc_state=unreadable
        fi
      fi
      if [ "$doc_state" = unreadable ]; then
        echo "ci: ERROR (no check-runs and no legacy status on $HEAD, and docs/process/testing.md exists in the $HEAD tree but could not be read: $(tr -d '\n' < "$WORK/doc.err")) — cannot tell whether this repo declares no CI"
        return 1
      fi
      # verdict-rules.md condition 5 requires the declaration *verbatim*; a
      # looser match passes a repo whose doc merely uses the words.
      if printf '%s' "$TESTING_DOC" | grep -qF 'no suites — review-only'; then
        echo "ci: PASS-BY-DECLARATION (no check-runs, no legacy status; docs/process/testing.md declares no CI — the reviewer/merge-verifier must record the Suggested Test Steps re-run by hand)"
        return 0
      fi
      if [ "$doc_state" = absent ]; then
        echo "ci: FAIL (no check-runs and no legacy status found, and the $HEAD tree has no docs/process/testing.md to declare, verbatim, \"no suites — review-only\")"
      else
        echo "ci: FAIL (no check-runs and no legacy status found, and docs/process/testing.md in the $HEAD tree does not declare, verbatim, \"no suites — review-only\")"
      fi
      return 1
    fi
  else
    other=$(printf '%s\n' "$runs" | jq -c 'select(.status != "completed" or (.conclusion != "success" and .conclusion != "neutral" and .conclusion != "skipped"))' | grep -c . || true)
    if [ "$other" -eq 0 ]; then state=success; else state=failure; fi
  fi
  if [ "$state" = success ]; then
    echo "ci: PASS (state=$state)"
    return 0
  else
    echo "ci: FAIL (state=$state)"
    return 1
  fi
}

# ---------------------------------------------------------------------------
# Enumerate commits in (BASE, HEAD].
# ---------------------------------------------------------------------------
COMMITS=()
while IFS= read -r sha; do
  [ -n "$sha" ] && COMMITS+=("$sha")
done < <(git log --format='%H' "$BASE..$HEAD" 2>"$WORK/log.err") || die "git log $BASE..$HEAD failed: $(cat "$WORK/log.err")"

FAIL=0
declare -a REPORT_LINES=()
TOTAL_CHANGED_LINES=0

if [ "${#COMMITS[@]}" -eq 0 ]; then
  REPORT_LINES+=("no reviewer-applied commits in range $BASE..$HEAD — nothing to check")
else
  for sha in "${COMMITS[@]}"; do
    subject_body=$(git log -1 --format='%B' "$sha")

    # Condition 1: exactly one Reviewer-applied trailer, this PR's number.
    trailers=$(printf '%s\n' "$subject_body" | grep -c '^Reviewer-applied:' || true)
    trailer_line=$(printf '%s\n' "$subject_body" | grep -m1 '^Reviewer-applied:' || true)
    if [ "$trailers" -eq 0 ]; then
      FAIL=1
      REPORT_LINES+=("$sha condition1 FAIL: no Reviewer-applied trailer")
    elif [ "$trailers" -gt 1 ]; then
      FAIL=1
      REPORT_LINES+=("$sha condition1 FAIL: more than one Reviewer-applied trailer")
    elif ! printf '%s' "$trailer_line" | grep -qE "^Reviewer-applied: PR #$PR round [0-9]+ finding [0-9A-Za-z._-]+\$"; then
      FAIL=1
      REPORT_LINES+=("$sha condition1 FAIL: trailer malformed or names a different PR: $trailer_line")
    else
      REPORT_LINES+=("$sha condition1 PASS: $trailer_line")
    fi

    # Files this commit touches.
    files=$(git diff-tree --no-commit-id --name-only -r "$sha")

    # Condition 2: every touched path within the PR's own diff.
    cond2_fail=0
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      if ! grep -qxF "$f" "$ALLOWED_PATHS_FILE"; then
        cond2_fail=1
        FAIL=1
        REPORT_LINES+=("$sha condition2 FAIL: $f is outside the PR's own diff (origin/$PR_BASE_BRANCH...$BASE)")
      fi
    done <<<"$files"
    [ "$cond2_fail" -eq 0 ] && REPORT_LINES+=("$sha condition2 PASS: every touched path within the PR's diff")

    # Condition 3: strip-and-compare per non-exempt touched file.
    if ! parent=$(git rev-parse "$sha^" 2>/dev/null); then
      FAIL=1
      REPORT_LINES+=("$sha condition3 FAIL: no parent commit (root commit) — cannot strip-compare")
      parent=""
    fi
    if [ -n "$parent" ]; then
      while IFS= read -r f; do
        [ -n "$f" ] || continue
        if is_exempt "$f"; then
          REPORT_LINES+=("$sha condition3 EXEMPT: $f")
          continue
        fi
        ext=$(ext_of "$f")
        pf="$WORK/parent.$$.tmp"; cf="$WORK/commit.$$.tmp"
        if ! git show "$parent:$f" > "$pf" 2>/dev/null; then
          FAIL=1
          REPORT_LINES+=("$sha condition3 FAIL: $f did not exist at parent — added file is a semantic change")
          rm -f "$pf" "$cf"
          continue
        fi
        if ! git show "$sha:$f" > "$cf" 2>/dev/null; then
          FAIL=1
          REPORT_LINES+=("$sha condition3 FAIL: $f removed by this commit — semantic change")
          rm -f "$pf" "$cf"
          continue
        fi
        stripped_parent=$(strip_for_ext "$ext" "$pf")
        stripped_commit=$(strip_for_ext "$ext" "$cf")
        rm -f "$pf" "$cf"
        if [ "$stripped_parent" = "$stripped_commit" ]; then
          REPORT_LINES+=("$sha condition3 PASS: $f identical after strip")
        else
          FAIL=1
          REPORT_LINES+=("$sha condition3 FAIL: $f differs after strip — a semantic change")
        fi
      done <<<"$files"
    fi

    # Condition 4 numstat contribution, per commit; summed after the loop.
    while IFS=$'\t' read -r add del path; do
      [ -n "$path" ] || continue
      if [ "$add" = '-' ] || [ "$del" = '-' ]; then
        continue # binary file; numstat reports '-' — no line count to add
      fi
      TOTAL_CHANGED_LINES=$((TOTAL_CHANGED_LINES + add + del))
    done < <(git diff --numstat "$sha^..$sha" 2>/dev/null || git diff --numstat --root "$sha" 2>/dev/null)
  done

  if [ "$TOTAL_CHANGED_LINES" -le 10 ]; then
    REPORT_LINES+=("round condition4 PASS: $TOTAL_CHANGED_LINES changed lines (<=10)")
  else
    FAIL=1
    REPORT_LINES+=("round condition4 FAIL: $TOTAL_CHANGED_LINES changed lines (>10)")
  fi

  ci_line=$(check_ci) || FAIL=1
  ci_line=$(printf '%s' "$ci_line" | sed -E 's/^ci: /round condition5 /')
  REPORT_LINES+=("$ci_line")
fi

if [ "$MARKDOWN" -eq 1 ]; then
  echo "### Reviewer-applied gate — PR #$PR ($BASE..$HEAD)"
  echo
  for line in "${REPORT_LINES[@]}"; do
    echo "- $line"
  done
  echo
  if [ "$FAIL" -eq 0 ]; then
    echo "**Result: PASS**"
  else
    echo "**Result: FAIL**"
  fi
else
  for line in "${REPORT_LINES[@]}"; do
    echo "$line"
  done
  if [ "$FAIL" -eq 0 ]; then
    echo "check-reviewer-commits: PASS — PR #$PR, ${#COMMITS[@]} commit(s) checked"
  else
    echo "check-reviewer-commits: FAIL — PR #$PR" >&2
  fi
fi

exit "$FAIL"
