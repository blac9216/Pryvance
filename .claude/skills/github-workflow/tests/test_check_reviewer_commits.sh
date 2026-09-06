#!/usr/bin/env bash
# test_check_reviewer_commits.sh — fixture-driven regression test for
# check-reviewer-commits.sh. Follows the mock-`gh` harness conventions in
# tests/README.md: a mocked `gh` binary on PATH serves fixture JSON from a
# private mktemp scratch dir, applies the script's own `--jq` expression with
# the real `jq` binary, refuses any non-GET verb, and carries the
# UNMOCKED-CONTEXT tripwire (a call reaching the mock with no
# MOCK_GH_FIXTURES set is logged and refused, and the suite asserts at the
# end that the tripwire never fired). No real network call is ever reachable.
#
# check-reviewer-commits.sh is a hybrid: two `gh api` reads (the PR's
# head/base, and CI state for the head) plus real local `git` operations
# against fixture repositories this suite builds under its own scratch dir —
# there is no way to mock `git log`/`git diff`/`git show` the way `gh` is
# mocked, so each case is a real, small, throwaway git repository.
#
# Covers, one case per condition of verdict-rules.md § Reviewer-applied gate,
# passing and failing, plus the line-cap and CI conditions and the usage
# errors:
#  - condition 1 (tagged, one finding per commit): a well-formed trailer
#    PASSes; a missing trailer, a trailer naming a different PR, and two
#    trailers on one commit each FAIL.
#  - condition 2 (files within the PR's diff): a touched path inside the PR's
#    own three-dot diff PASSes; a path the reviewer added that the PR itself
#    never touched (README.md, when the PR only touched script.sh) FAILs.
#  - condition 3 (strip-and-compare): a comment-only edit to a shell file
#    PASSes; a change to the executable content (semantic) FAILs; a plain
#    Markdown file governed only by the other four conditions is EXEMPT even
#    when the edit is semantic; a `.claude/agents/*.md` instruction-text file
#    is NOT exempt — a comment-only (`<!-- ... -->`) edit PASSes there but a
#    semantic edit FAILs, proving the carve-out is enforced, not merely
#    documented; instruction text rewritten BETWEEN two same-line comments
#    FAILs and an edit inside a MULTI-LINE comment PASSes (round-1 finding
#    S1, both directions); a comment-only edit to a `Dockerfile` PASSes and a
#    semantic one FAILs, exercising the `#`-arm that S4 found unreachable.
#  - condition 4 (<=10 changed lines per round): PASSes at the boundary,
#    FAILs one line over it.
#  - condition 5 (CI green): a green check-runs state PASSes; a failing one
#    FAILs; an empty check-runs response falls back to the legacy status API
#    exactly as preflight.sh does; a documented no-CI repository (a fixture
#    docs/process/testing.md declaring "no suites — review-only") reports
#    PASS-BY-DECLARATION instead of vacuously passing or failing; a repo whose
#    testing.md merely contains the words "review-only", and one carrying the
#    verbatim declaration alongside a .github/workflows definition, both FAIL
#    rather than passing by declaration (round-1 finding S2).
#    A legacy-status GET that FAILS is reported as ci-error rather than read as
#    "no statuses", so it never reaches the by-declaration branch (round-3
#    finding R1).
#  - an empty commit range (approval-sha == head) is not a failure: exit 0,
#    "nothing to check".
#  - usage errors: missing <pr> (exit 2), a non-numeric <pr> (exit 2), a
#    missing --base (exit 2) — the gate's own approval sha cannot be
#    inferred, so this is a hard requirement, not a convenience default.
#  - --markdown renders a "### Reviewer-applied gate" report with a PASS/FAIL
#    result line.
#  - the mock's write-verb refusal (`gh api -X POST`) and the
#    UNMOCKED-CONTEXT tripwire.
#  - mutation probes (issue #609 AC2): deleting any ONE of the five checks'
#    FAIL= assignments makes a case that should FAIL instead exit 0 — proving
#    each check is load-bearing rather than redundant with the others; plus
#    three round-1 probes that restore the pre-fix strip, no-CI match and
#    Dockerfile arm and assert the new cases invert.
#
# Pinned to LANG=C / LC_ALL=C.
set -uo pipefail
export LANG=C LC_ALL=C

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../scripts/check-reviewer-commits.sh"
[ -x "$SCRIPT" ] || SCRIPT="bash $SCRIPT"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/check-reviewer-commits-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

fail=0
report(){ echo "FAIL: $*" >&2; fail=1; }

BIN="$WORK/bin"; mkdir -p "$BIN"
MOCK_GH_CALL_LOG="$WORK/calls.log"; : > "$MOCK_GH_CALL_LOG"
export MOCK_GH_CALL_LOG

# ---------------------------------------------------------------------------
# Mock gh: routes by endpoint shape, applies the script's own --jq expression
# against fixture JSON with the real jq binary, refuses any non-GET verb, and
# refuses (and logs as UNMOCKED-CONTEXT) any call arriving with no
# MOCK_GH_FIXTURES set.
# ---------------------------------------------------------------------------
cat > "$BIN/gh" <<'MOCKGH'
#!/usr/bin/env bash
set -euo pipefail
: "${MOCK_GH_CALL_LOG:?MOCK_GH_CALL_LOG must be set}"
printf 'CALL gh %s\n' "$*" >> "$MOCK_GH_CALL_LOG"
if [ -z "${MOCK_GH_FIXTURES:-}" ]; then
  printf 'UNMOCKED-CONTEXT gh %s\n' "$*" >> "$MOCK_GH_CALL_LOG"
  echo "mock gh: invoked with no MOCK_GH_FIXTURES — unmocked call context" >&2
  exit 1
fi
if [ "${1:-}" != "api" ]; then
  echo "mock gh: unsupported command: $*" >&2
  exit 1
fi
shift
endpoint=""; jq_expr=""; method="GET"
while [ $# -gt 0 ]; do
  case "$1" in
    --paginate) shift ;;
    --jq) jq_expr="$2"; shift 2 ;;
    -X|--method) method="$2"; shift 2 ;;
    -X?*) method="${1#-X}"; shift ;;
    --method=*) method="${1#--method=}"; shift ;;
    *) endpoint="$1"; shift ;;
  esac
done
if [ "$method" != "GET" ]; then
  echo "mock gh: refusing non-GET verb: $method" >&2
  exit 1
fi
case "$endpoint" in
  repos/*/pulls/*) fixture="$MOCK_GH_FIXTURES/pull.json" ;;
  repos/*/commits/*/check-runs*) fixture="$MOCK_GH_FIXTURES/check-runs.json" ;;
  repos/*/commits/*/status)
    # status.fail models the GET itself failing (5xx, rate limit, auth): gh
    # prints its message on stderr and exits non-zero, which is a different
    # thing from a commit that has no statuses.
    if [ -f "$MOCK_GH_FIXTURES/status.fail" ]; then
      cat "$MOCK_GH_FIXTURES/status.fail" >&2
      exit 1
    fi
    fixture="$MOCK_GH_FIXTURES/status.json" ;;
  *) echo "mock gh: unrouted endpoint: $endpoint" >&2; exit 1 ;;
esac
[ -f "$fixture" ] || { echo "mock gh: no fixture at $fixture for $endpoint" >&2; exit 1; }
if [ -n "$jq_expr" ]; then
  jq -c -r "$jq_expr" "$fixture"
else
  cat "$fixture"
fi
MOCKGH
chmod +x "$BIN/gh"

# ---------------------------------------------------------------------------
# git-fixture builders. Every repo is a real throwaway git repo with a
# fetched `origin` remote (a same-directory bare-ish local remote is enough
# for `origin/<base>` to resolve) so condition 2's three-dot diff against
# `origin/<base-branch>` works exactly as it does against a real checkout.
# ---------------------------------------------------------------------------
new_repo(){ # new_repo <dir> [testing.md-declaration] — main branch with one
            # commit, origin remote fetched
  local dir="$1" decl="${2:-Declaration: no suites — review-only.}"
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" config user.email a@example.invalid
  git -C "$dir" config user.name "test"
  git -C "$dir" checkout -q -b main
  echo "base" > "$dir/README.md"
  mkdir -p "$dir/docs/process"
  # Present from the start (not part of any reviewer-applied commit's diff)
  # so the no-CI declaration case needs no extra untagged commit in the
  # range under test — check_ci() reads it from the $HEAD tree, not the working tree.
  printf '%s\n' "$decl" > "$dir/docs/process/testing.md"
  git -C "$dir" add README.md docs/process/testing.md
  git -C "$dir" commit -q -m "AI: init"
  git -C "$dir" remote add origin "$dir"
  git -C "$dir" fetch origin -q
}

# gh fixtures shared by every case: PR head/base resolved live, CI green by
# default. write_pull_fixture / write_ci_fixture let a case override either.
write_pull_fixture(){ # write_pull_fixture <fixdir> <head-sha> <base-branch>
  jq -cn --arg head "$2" --arg base "$3" '{head:{sha:$head},base:{ref:$base}}' > "$1/pull.json"
}
# Every fixture below is the shape GitHub itself returns, `total_count` and
# all: a mock that answers something the API never sends makes the probe that
# depends on it decorative (round-2 finding 3). In particular the combined
# Status API answers a commit with NO statuses as
# {"state":"pending","total_count":0,"statuses":[]} -- never state:null -- so
# "no CI at all" must be spelled exactly that way here.
write_ci_green(){ jq -cn '{total_count:1,check_runs:[{status:"completed",conclusion:"success"}]}' > "$1/check-runs.json"; }
write_ci_red(){ jq -cn '{total_count:1,check_runs:[{status:"completed",conclusion:"failure"}]}' > "$1/check-runs.json"; }
write_ci_empty_legacy_success(){
  jq -cn '{total_count:0,check_runs:[]}' > "$1/check-runs.json"
  jq -cn '{state:"success",total_count:1,statuses:[{context:"ci/legacy",state:"success"}]}' > "$1/status.json"
}
write_ci_empty_no_legacy(){
  jq -cn '{total_count:0,check_runs:[]}' > "$1/check-runs.json"
  jq -cn '{state:"pending",total_count:0,statuses:[]}' > "$1/status.json"
}
write_ci_empty_legacy_error(){ # zero check-runs, and the legacy-status GET
                               # itself FAILS -- not the same thing as a commit
                               # with no statuses (round-3 finding R1).
  jq -cn '{total_count:0,check_runs:[]}' > "$1/check-runs.json"
  printf 'gh: Server Error (HTTP 502)\n' > "$1/status.fail"
}

run_check(){ # run_check <fixdir> <repo-dir> <pr> <base-sha> <head-sha> [extra args...]
  local fixdir="$1" repo="$2" pr="$3" base="$4" head="$5"; shift 5
  ( cd "$repo" && MOCK_GH_FIXTURES="$fixdir" PATH="$BIN:$PATH" \
      $SCRIPT "$pr" --base "$base" --head "$head" --repo o/r "$@" \
      > "$WORK/last.out" 2> "$WORK/last.err" )
  echo $?
}

dump_on(){ # dump_on <label> — crash-path diagnostics
  echo "--- $1: stdout ---" >&2; cat "$WORK/last.out" >&2
  echo "--- $1: stderr ---" >&2; cat "$WORK/last.err" >&2
}

# ===========================================================================
# Case: condition 1 PASS + all other conditions PASS — the full green path.
# ===========================================================================
R1="$WORK/r1"; new_repo "$R1"
git -C "$R1" checkout -q -b pr-branch
printf '#!/usr/bin/env bash\necho hi\n' > "$R1/script.sh"
git -C "$R1" add script.sh; git -C "$R1" commit -q -m "AI: feat: add script"
APPROVAL1=$(git -C "$R1" rev-parse HEAD)
printf '#!/usr/bin/env bash\n# a helpful note\necho hi\n' > "$R1/script.sh"
git -C "$R1" add script.sh
git -C "$R1" commit -q -m "AI: note fix

Reviewer-applied: PR #100 round 1 finding 1"
HEAD1=$(git -C "$R1" rev-parse HEAD)
FIX1="$WORK/fix1"; mkdir -p "$FIX1"
write_pull_fixture "$FIX1" "$HEAD1" main
write_ci_green "$FIX1"
rc=$(run_check "$FIX1" "$R1" 100 "$APPROVAL1" "$HEAD1")
[ "$rc" = 0 ] || { dump_on "case1-green-path"; report "green path: expected exit 0, got $rc"; }
grep -q "condition1 PASS" "$WORK/last.out" || report "green path: missing condition1 PASS line"
grep -q "condition2 PASS" "$WORK/last.out" || report "green path: missing condition2 PASS line"
grep -q "condition3 PASS" "$WORK/last.out" || report "green path: missing condition3 PASS line"
grep -q "condition4 PASS" "$WORK/last.out" || report "green path: missing condition4 PASS line"
grep -q "condition5 PASS" "$WORK/last.out" || report "green path: missing condition5 PASS line"

# ===========================================================================
# Case: condition 1 FAIL — missing trailer.
# ===========================================================================
git -C "$R1" checkout -q -B pr-branch "$APPROVAL1"
printf '#!/usr/bin/env bash\n# note, no trailer\necho hi\n' > "$R1/script.sh"
git -C "$R1" add script.sh
git -C "$R1" commit -q -m "AI: forgot the trailer"
HEAD_NOTRAILER=$(git -C "$R1" rev-parse HEAD)
FIX_NT="$WORK/fix-notrailer"; mkdir -p "$FIX_NT"
write_pull_fixture "$FIX_NT" "$HEAD_NOTRAILER" main
write_ci_green "$FIX_NT"
rc=$(run_check "$FIX_NT" "$R1" 100 "$APPROVAL1" "$HEAD_NOTRAILER")
[ "$rc" = 1 ] || { dump_on "cond1-missing-trailer"; report "missing trailer: expected exit 1, got $rc"; }
grep -q "condition1 FAIL: no Reviewer-applied trailer" "$WORK/last.out" \
  || report "missing trailer: expected condition1 FAIL line"

# ===========================================================================
# Case: condition 1 FAIL — trailer names a different PR.
# ===========================================================================
git -C "$R1" checkout -q -B pr-branch "$APPROVAL1"
printf '#!/usr/bin/env bash\n# wrong pr\necho hi\n' > "$R1/script.sh"
git -C "$R1" add script.sh
git -C "$R1" commit -q -m "AI: wrong pr trailer

Reviewer-applied: PR #999 round 1 finding 1"
HEAD_WRONGPR=$(git -C "$R1" rev-parse HEAD)
FIX_WP="$WORK/fix-wrongpr"; mkdir -p "$FIX_WP"
write_pull_fixture "$FIX_WP" "$HEAD_WRONGPR" main
write_ci_green "$FIX_WP"
rc=$(run_check "$FIX_WP" "$R1" 100 "$APPROVAL1" "$HEAD_WRONGPR")
[ "$rc" = 1 ] || { dump_on "cond1-wrong-pr"; report "wrong-PR trailer: expected exit 1, got $rc"; }
grep -q "condition1 FAIL" "$WORK/last.out" | true
grep -q "trailer malformed or names a different PR" "$WORK/last.out" \
  || report "wrong-PR trailer: expected the malformed/different-PR message"

# ===========================================================================
# Case: condition 1 FAIL — two trailers on one commit.
# ===========================================================================
git -C "$R1" checkout -q -B pr-branch "$APPROVAL1"
printf '#!/usr/bin/env bash\n# two trailers\necho hi\n' > "$R1/script.sh"
git -C "$R1" add script.sh
git -C "$R1" commit -q -m "AI: two findings in one commit

Reviewer-applied: PR #100 round 1 finding 1
Reviewer-applied: PR #100 round 1 finding 2"
HEAD_TWOTR=$(git -C "$R1" rev-parse HEAD)
FIX_TT="$WORK/fix-twotrailers"; mkdir -p "$FIX_TT"
write_pull_fixture "$FIX_TT" "$HEAD_TWOTR" main
write_ci_green "$FIX_TT"
rc=$(run_check "$FIX_TT" "$R1" 100 "$APPROVAL1" "$HEAD_TWOTR")
[ "$rc" = 1 ] || { dump_on "cond1-two-trailers"; report "two trailers: expected exit 1, got $rc"; }
grep -q "more than one Reviewer-applied trailer" "$WORK/last.out" \
  || report "two trailers: expected the more-than-one-trailer message"

# ===========================================================================
# Case: condition 2 FAIL — reviewer touches a path outside the PR's own diff.
# ===========================================================================
R2="$WORK/r2"; new_repo "$R2"
git -C "$R2" checkout -q -b pr-branch
printf 'code\n' > "$R2/script.sh"
git -C "$R2" add script.sh; git -C "$R2" commit -q -m "AI: feat: add script"
APPROVAL2=$(git -C "$R2" rev-parse HEAD)
echo "sneaky" > "$R2/README.md"
git -C "$R2" add README.md
git -C "$R2" commit -q -m "AI: sneaky readme edit

Reviewer-applied: PR #101 round 1 finding 1"
HEAD2=$(git -C "$R2" rev-parse HEAD)
FIX2="$WORK/fix2"; mkdir -p "$FIX2"
write_pull_fixture "$FIX2" "$HEAD2" main
write_ci_green "$FIX2"
rc=$(run_check "$FIX2" "$R2" 101 "$APPROVAL2" "$HEAD2")
[ "$rc" = 1 ] || { dump_on "cond2-outside-diff"; report "outside-diff: expected exit 1, got $rc"; }
grep -q "condition2 FAIL: README.md is outside the PR's own diff" "$WORK/last.out" \
  || report "outside-diff: expected condition2 FAIL line naming README.md"

# ===========================================================================
# Case: condition 3 FAIL — semantic change to an executable file.
# ===========================================================================
git -C "$R2" checkout -q -B pr-branch "$APPROVAL2"
printf 'CHANGED code\n' > "$R2/script.sh"
git -C "$R2" add script.sh
git -C "$R2" commit -q -m "AI: semantic change disguised as a fix

Reviewer-applied: PR #101 round 1 finding 2"
HEAD_SEM=$(git -C "$R2" rev-parse HEAD)
FIX_SEM="$WORK/fix-semantic"; mkdir -p "$FIX_SEM"
write_pull_fixture "$FIX_SEM" "$HEAD_SEM" main
write_ci_green "$FIX_SEM"
rc=$(run_check "$FIX_SEM" "$R2" 101 "$APPROVAL2" "$HEAD_SEM")
[ "$rc" = 1 ] || { dump_on "cond3-semantic"; report "semantic change: expected exit 1, got $rc"; }
grep -q "condition3 FAIL: script.sh differs after strip" "$WORK/last.out" \
  || report "semantic change: expected condition3 FAIL line"

# ===========================================================================
# Case: condition 3 EXEMPT — plain Markdown, even with a semantic edit,
# governed only by the other four conditions (PASS overall).
# ===========================================================================
R3="$WORK/r3"; new_repo "$R3"
git -C "$R3" checkout -q -b pr-branch
printf 'plain text v1\n' > "$R3/NOTES.md"
git -C "$R3" add NOTES.md; git -C "$R3" commit -q -m "AI: feat: add notes"
APPROVAL3=$(git -C "$R3" rev-parse HEAD)
printf 'COMPLETELY DIFFERENT semantic content\n' > "$R3/NOTES.md"
git -C "$R3" add NOTES.md
git -C "$R3" commit -q -m "AI: semantic markdown edit

Reviewer-applied: PR #102 round 1 finding 1"
HEAD3=$(git -C "$R3" rev-parse HEAD)
FIX3="$WORK/fix3"; mkdir -p "$FIX3"
write_pull_fixture "$FIX3" "$HEAD3" main
write_ci_green "$FIX3"
rc=$(run_check "$FIX3" "$R3" 102 "$APPROVAL3" "$HEAD3")
[ "$rc" = 0 ] || { dump_on "cond3-md-exempt"; report "markdown exempt: expected exit 0, got $rc"; }
grep -q "condition3 EXEMPT: NOTES.md" "$WORK/last.out" \
  || report "markdown exempt: expected condition3 EXEMPT line"

# ===========================================================================
# Case: condition 3 — instruction-text carve-out (.claude/agents/*.md is NOT
# exempt). A comment-only edit PASSes; a semantic edit FAILs.
# ===========================================================================
R4="$WORK/r4"; new_repo "$R4"
git -C "$R4" checkout -q -b pr-branch
mkdir -p "$R4/.claude/agents"
printf 'line one\nline two\n' > "$R4/.claude/agents/foo.md"
git -C "$R4" add .claude/agents/foo.md
git -C "$R4" commit -q -m "AI: feat: add agent doc"
APPROVAL4=$(git -C "$R4" rev-parse HEAD)
printf 'line one\nline two\n<!-- a note -->\n' > "$R4/.claude/agents/foo.md"
git -C "$R4" add .claude/agents/foo.md
git -C "$R4" commit -q -m "AI: comment only

Reviewer-applied: PR #103 round 1 finding 1"
HEAD4=$(git -C "$R4" rev-parse HEAD)
FIX4="$WORK/fix4"; mkdir -p "$FIX4"
write_pull_fixture "$FIX4" "$HEAD4" main
write_ci_green "$FIX4"
rc=$(run_check "$FIX4" "$R4" 103 "$APPROVAL4" "$HEAD4")
[ "$rc" = 0 ] || { dump_on "cond3-instruction-comment"; report "instruction comment-only: expected exit 0, got $rc"; }
grep -q "condition3 PASS: .claude/agents/foo.md" "$WORK/last.out" \
  || report "instruction comment-only: expected condition3 PASS line"

git -C "$R4" checkout -q -B pr-branch "$APPROVAL4"
printf 'line ONE CHANGED\nline two\n' > "$R4/.claude/agents/foo.md"
git -C "$R4" add .claude/agents/foo.md
git -C "$R4" commit -q -m "AI: semantic instruction edit

Reviewer-applied: PR #103 round 1 finding 2"
HEAD4B=$(git -C "$R4" rev-parse HEAD)
FIX4B="$WORK/fix4b"; mkdir -p "$FIX4B"
write_pull_fixture "$FIX4B" "$HEAD4B" main
write_ci_green "$FIX4B"
rc=$(run_check "$FIX4B" "$R4" 103 "$APPROVAL4" "$HEAD4B")
[ "$rc" = 1 ] || { dump_on "cond3-instruction-semantic"; report "instruction semantic edit: expected exit 1, got $rc"; }
grep -q "condition3 FAIL: .claude/agents/foo.md differs after strip" "$WORK/last.out" \
  || report "instruction semantic edit: expected condition3 FAIL line"

# ===========================================================================
# Case: condition 4 — boundary PASS at 10 lines, FAIL at 11.
# ===========================================================================
R5="$WORK/r5"; new_repo "$R5"
git -C "$R5" checkout -q -b pr-branch
printf 'code\n' > "$R5/script.sh"
git -C "$R5" add script.sh; git -C "$R5" commit -q -m "AI: feat: add script"
APPROVAL5=$(git -C "$R5" rev-parse HEAD)
{ printf 'code\n'; printf '# c%d\n' 1 2 3 4 5 6 7 8 9 10; } > "$R5/script.sh"
git -C "$R5" add script.sh
git -C "$R5" commit -q -m "AI: ten changed lines

Reviewer-applied: PR #104 round 1 finding 1"
HEAD5=$(git -C "$R5" rev-parse HEAD)
FIX5="$WORK/fix5"; mkdir -p "$FIX5"
write_pull_fixture "$FIX5" "$HEAD5" main
write_ci_green "$FIX5"
rc=$(run_check "$FIX5" "$R5" 104 "$APPROVAL5" "$HEAD5")
[ "$rc" = 0 ] || { dump_on "cond4-boundary-pass"; report "line-cap boundary (<=10): expected exit 0, got $rc"; }
grep -q "condition4 PASS" "$WORK/last.out" || report "line-cap boundary: expected condition4 PASS"

git -C "$R5" checkout -q -B pr-branch "$APPROVAL5"
{ printf 'code\n'; printf '# c%d\n' 1 2 3 4 5 6 7 8 9 10 11; } > "$R5/script.sh"
git -C "$R5" add script.sh
git -C "$R5" commit -q -m "AI: eleven changed lines

Reviewer-applied: PR #104 round 1 finding 2"
HEAD5B=$(git -C "$R5" rev-parse HEAD)
FIX5B="$WORK/fix5b"; mkdir -p "$FIX5B"
write_pull_fixture "$FIX5B" "$HEAD5B" main
write_ci_green "$FIX5B"
rc=$(run_check "$FIX5B" "$R5" 104 "$APPROVAL5" "$HEAD5B")
[ "$rc" = 1 ] || { dump_on "cond4-over-boundary"; report "line-cap over (11): expected exit 1, got $rc"; }
grep -q "condition4 FAIL: 11 changed lines" "$WORK/last.out" \
  || report "line-cap over: expected condition4 FAIL line naming 11"

# ===========================================================================
# Case: condition 5 — CI red FAILs; empty check-runs falls back to legacy
# status; a documented no-CI repo reports PASS-BY-DECLARATION.
# ===========================================================================
R6="$WORK/r6"; new_repo "$R6"
git -C "$R6" checkout -q -b pr-branch
printf 'code\n' > "$R6/script.sh"
git -C "$R6" add script.sh; git -C "$R6" commit -q -m "AI: feat: add script"
APPROVAL6=$(git -C "$R6" rev-parse HEAD)
printf '# note\ncode\n' > "$R6/script.sh"
git -C "$R6" add script.sh
git -C "$R6" commit -q -m "AI: note fix

Reviewer-applied: PR #105 round 1 finding 1"
HEAD6=$(git -C "$R6" rev-parse HEAD)

FIX6_RED="$WORK/fix6-red"; mkdir -p "$FIX6_RED"
write_pull_fixture "$FIX6_RED" "$HEAD6" main
write_ci_red "$FIX6_RED"
rc=$(run_check "$FIX6_RED" "$R6" 105 "$APPROVAL6" "$HEAD6")
[ "$rc" = 1 ] || { dump_on "cond5-ci-red"; report "CI red: expected exit 1, got $rc"; }
grep -q "condition5 FAIL" "$WORK/last.out" || report "CI red: expected condition5 FAIL line"

FIX6_LEGACY="$WORK/fix6-legacy"; mkdir -p "$FIX6_LEGACY"
write_pull_fixture "$FIX6_LEGACY" "$HEAD6" main
write_ci_empty_legacy_success "$FIX6_LEGACY"
rc=$(run_check "$FIX6_LEGACY" "$R6" 105 "$APPROVAL6" "$HEAD6")
[ "$rc" = 0 ] || { dump_on "cond5-ci-legacy"; report "CI legacy-status fallback: expected exit 0, got $rc"; }
grep -q "condition5 PASS" "$WORK/last.out" || report "CI legacy-status fallback: expected condition5 PASS line"

FIX6_NOCI="$WORK/fix6-noci"; mkdir -p "$FIX6_NOCI"
write_pull_fixture "$FIX6_NOCI" "$HEAD6" main
write_ci_empty_no_legacy "$FIX6_NOCI"
rc=$(run_check "$FIX6_NOCI" "$R6" 105 "$APPROVAL6" "$HEAD6")
[ "$rc" = 0 ] || { dump_on "cond5-no-ci-declared"; report "no-CI declared: expected exit 0, got $rc"; }
grep -q "PASS-BY-DECLARATION" "$WORK/last.out" \
  || { dump_on "cond5-no-ci-declared"; report "no-CI declared: expected PASS-BY-DECLARATION"; }

# Condition 5 — the legacy-status GET fails outright. Even on a repo that
# declares no CI, a failed call is not evidence of no statuses: the failure is
# surfaced as ci-error the way the check-runs GET surfaces its own, never as
# PASS-BY-DECLARATION (round-3 finding R1).
FIX6_ERR="$WORK/fix6-legacy-error"; mkdir -p "$FIX6_ERR"
write_pull_fixture "$FIX6_ERR" "$HEAD6" main
write_ci_empty_legacy_error "$FIX6_ERR"
rc=$(run_check "$FIX6_ERR" "$R6" 105 "$APPROVAL6" "$HEAD6")
[ "$rc" = 1 ] || { dump_on "cond5-legacy-get-failed"; report "failed status GET: expected exit 1, got $rc"; }
grep -q "ci-error: GET commit status failed" "$WORK/last.out" \
  || { dump_on "cond5-legacy-get-failed"; report "failed status GET: expected the ci-error line"; }
grep -q "PASS-BY-DECLARATION" "$WORK/last.out" \
  && report "failed status GET: must not report PASS-BY-DECLARATION"

# ===========================================================================
# Case: empty commit range — nothing to check, exit 0.
# ===========================================================================
R7="$WORK/r7"; new_repo "$R7"
git -C "$R7" checkout -q -b pr-branch
printf 'code\n' > "$R7/script.sh"
git -C "$R7" add script.sh; git -C "$R7" commit -q -m "AI: feat: add script"
APPROVAL7=$(git -C "$R7" rev-parse HEAD)
FIX7="$WORK/fix7"; mkdir -p "$FIX7"
write_pull_fixture "$FIX7" "$APPROVAL7" main
write_ci_green "$FIX7"
rc=$(run_check "$FIX7" "$R7" 106 "$APPROVAL7" "$APPROVAL7")
[ "$rc" = 0 ] || { dump_on "empty-range"; report "empty range: expected exit 0, got $rc"; }
grep -q "nothing to check" "$WORK/last.out" || report "empty range: expected 'nothing to check' line"

# ===========================================================================
# Case: --markdown output.
# ===========================================================================
FIX_MD="$WORK/fix-md"; mkdir -p "$FIX_MD"
write_pull_fixture "$FIX_MD" "$HEAD1" main
write_ci_green "$FIX_MD"
rc=$(run_check "$FIX_MD" "$R1" 100 "$APPROVAL1" "$HEAD1" --markdown)
[ "$rc" = 0 ] || { dump_on "markdown"; report "markdown output: expected exit 0, got $rc"; }
grep -q "^### Reviewer-applied gate" "$WORK/last.out" || report "markdown output: missing heading"
grep -q '\*\*Result: PASS\*\*' "$WORK/last.out" || report "markdown output: missing Result: PASS line"

# ===========================================================================
# Usage errors — exit 2, no gh call at all (the guard fires before any).
# ===========================================================================
run_argerr(){ # run_argerr <label> <args...>
  local label="$1"; shift
  ( PATH="$BIN:$PATH" $SCRIPT "$@" > "$WORK/argerr-$label.out" 2> "$WORK/argerr-$label.err" )
  echo $?
}
rc=$(run_argerr noissue)
[ "$rc" = 2 ] || report "no args: expected exit 2, got $rc"
rc=$(run_argerr badpr abc --base deadbeef)
[ "$rc" = 2 ] || report "non-numeric PR: expected exit 2, got $rc"
rc=$(run_argerr nobase 100)
[ "$rc" = 2 ] || report "missing --base: expected exit 2, got $rc"

# ===========================================================================
# Issue #643: a flag with a missing VALUE (the flag itself present, nothing
# after it) is a usage error like any other -- exit 2, not the 1 that Bash's
# `${2:?...}` expansion raised before the fix.
# ===========================================================================
rc=$(run_argerr basenoval 100 --base)
[ "$rc" = 2 ] || report "--base with no value: expected exit 2, got $rc"
rc=$(run_argerr headnoval 100 --base deadbeef --head)
[ "$rc" = 2 ] || report "--head with no value: expected exit 2, got $rc"
rc=$(run_argerr reponoval 100 --base deadbeef --repo)
[ "$rc" = 2 ] || report "--repo with no value: expected exit 2, got $rc"

# Mutation probe (#643): restoring the old `${2:?...}` shape must turn the
# --base-with-no-value case's exit 2 into exit 1, proving the guard clause,
# not something else, is what fixes the exit code.
MUT_643="$WORK/mutant-643.sh"
cp "$HERE/../scripts/check-reviewer-commits.sh" "$MUT_643"
# shellcheck disable=SC2016 # literal pattern; nothing here is meant to expand
c643_line=$(grep -n '\-\-base) \[ \$# -ge 2 \]' "$HERE/../scripts/check-reviewer-commits.sh" | cut -d: -f1)
if [ -z "$c643_line" ]; then
  report "mutation probe (#643): could not find the guarded --base case arm"
else
  sed -i "${c643_line}s|.*|    --base) BASE=\"\${2:?--base needs a value}\"; shift 2 ;;|" "$MUT_643"
  chmod +x "$MUT_643"
  rc=$( ( PATH="$BIN:$PATH" bash "$MUT_643" 100 --base \
      > "$WORK/mut643.out" 2> "$WORK/mut643.err"; echo $? ) )
  [ "$rc" = 1 ] || report "mutation probe (#643): restoring \${2:?...} should have made --base with no value exit 1 again, got exit $rc"
fi

# ===========================================================================
# The mock's write-verb refusal, called directly against the mock.
# ===========================================================================
if ( MOCK_GH_FIXTURES="$FIX1" PATH="$BIN:$PATH" gh api -X POST repos/o/r/issues/1/comments >/dev/null 2>&1 ); then
  report "mock gh: expected -X POST to be refused"
fi

# ===========================================================================
# Case: condition 3 — instruction text BETWEEN two comments on one line. The
# comments are untouched; the real text between them is rewritten. This must
# FAIL: it is a semantic edit to agent-read instruction text. (A greedy,
# line-based strip deletes from the first `<!--` to the last `-->` and reports
# the two versions identical — round-1 finding S1, direction A.)
# ===========================================================================
R8="$WORK/r8"; new_repo "$R8"
git -C "$R8" checkout -q -b pr-branch
mkdir -p "$R8/.claude/agents"
printf 'A <!-- x --> KEEPME <!-- y --> B\n' > "$R8/.claude/agents/foo.md"
git -C "$R8" add .claude/agents/foo.md
git -C "$R8" commit -q -m "AI: feat: add agent doc"
APPROVAL8=$(git -C "$R8" rev-parse HEAD)
printf 'A <!-- x --> TOTALLY-DIFFERENT <!-- y --> B\n' > "$R8/.claude/agents/foo.md"
git -C "$R8" add .claude/agents/foo.md
git -C "$R8" commit -q -m "AI: rewrite text between two comments

Reviewer-applied: PR #107 round 1 finding 1"
HEAD8=$(git -C "$R8" rev-parse HEAD)
FIX8="$WORK/fix8"; mkdir -p "$FIX8"
write_pull_fixture "$FIX8" "$HEAD8" main
write_ci_green "$FIX8"
rc=$(run_check "$FIX8" "$R8" 107 "$APPROVAL8" "$HEAD8")
[ "$rc" = 1 ] || { dump_on "cond3-between-two-comments"; report "text between two same-line comments: expected exit 1, got $rc"; }
grep -q "condition3 FAIL: .claude/agents/foo.md differs after strip" "$WORK/last.out" \
  || report "text between two same-line comments: expected condition3 FAIL line"

# ===========================================================================
# Case: condition 3 — an edit to the text inside a MULTI-LINE `<!-- ... -->`
# comment in instruction text. This must PASS: it is the gate's main
# legitimate use. (A line-based strip leaves the comment's inner lines in
# place and calls the edit semantic — round-1 finding S1, direction B.)
# ===========================================================================
R9="$WORK/r9"; new_repo "$R9"
git -C "$R9" checkout -q -b pr-branch
mkdir -p "$R9/.claude/agents"
printf 'line one\n<!--\nnote line one\nnote line two\n-->\nline two\n' > "$R9/.claude/agents/bar.md"
git -C "$R9" add .claude/agents/bar.md
git -C "$R9" commit -q -m "AI: feat: add agent doc"
APPROVAL9=$(git -C "$R9" rev-parse HEAD)
printf 'line one\n<!--\nCOMPLETELY REWRITTEN note\nspanning two lines still\n-->\nline two\n' > "$R9/.claude/agents/bar.md"
git -C "$R9" add .claude/agents/bar.md
git -C "$R9" commit -q -m "AI: comment-only edit inside a multi-line comment

Reviewer-applied: PR #108 round 1 finding 1"
HEAD9=$(git -C "$R9" rev-parse HEAD)
FIX9="$WORK/fix9"; mkdir -p "$FIX9"
write_pull_fixture "$FIX9" "$HEAD9" main
write_ci_green "$FIX9"
rc=$(run_check "$FIX9" "$R9" 108 "$APPROVAL9" "$HEAD9")
[ "$rc" = 0 ] || { dump_on "cond3-multiline-comment"; report "multi-line comment-only edit: expected exit 0, got $rc"; }
grep -q "condition3 PASS: .claude/agents/bar.md identical after strip" "$WORK/last.out" \
  || report "multi-line comment-only edit: expected condition3 PASS line"

# ===========================================================================
# Case: condition 3 — Dockerfile takes the `#`-comment arm (round-1 finding
# S4: the arm spelled `Dockerfile`, but ext_of lowercases, so every Dockerfile
# fell through to the whitespace-only default and a comment-only edit FAILed).
# A comment-only edit PASSes; a semantic one still FAILs.
# ===========================================================================
R10="$WORK/r10"; new_repo "$R10"
git -C "$R10" checkout -q -b pr-branch
printf 'FROM scratch\nCMD ["true"]\n' > "$R10/Dockerfile"
git -C "$R10" add Dockerfile
git -C "$R10" commit -q -m "AI: feat: add Dockerfile"
APPROVAL10=$(git -C "$R10" rev-parse HEAD)
printf 'FROM scratch\n# a helpful note\nCMD ["true"]\n' > "$R10/Dockerfile"
git -C "$R10" add Dockerfile
git -C "$R10" commit -q -m "AI: comment-only Dockerfile edit

Reviewer-applied: PR #109 round 1 finding 1"
HEAD10=$(git -C "$R10" rev-parse HEAD)
FIX10="$WORK/fix10"; mkdir -p "$FIX10"
write_pull_fixture "$FIX10" "$HEAD10" main
write_ci_green "$FIX10"
rc=$(run_check "$FIX10" "$R10" 109 "$APPROVAL10" "$HEAD10")
[ "$rc" = 0 ] || { dump_on "cond3-dockerfile-comment"; report "Dockerfile comment-only edit: expected exit 0, got $rc"; }
grep -q "condition3 PASS: Dockerfile identical after strip" "$WORK/last.out" \
  || report "Dockerfile comment-only edit: expected condition3 PASS line"

git -C "$R10" checkout -q -B pr-branch "$APPROVAL10"
printf 'FROM scratch\nCMD ["false"]\n' > "$R10/Dockerfile"
git -C "$R10" add Dockerfile
git -C "$R10" commit -q -m "AI: semantic Dockerfile edit

Reviewer-applied: PR #109 round 1 finding 2"
HEAD10B=$(git -C "$R10" rev-parse HEAD)
FIX10B="$WORK/fix10b"; mkdir -p "$FIX10B"
write_pull_fixture "$FIX10B" "$HEAD10B" main
write_ci_green "$FIX10B"
rc=$(run_check "$FIX10B" "$R10" 109 "$APPROVAL10" "$HEAD10B")
[ "$rc" = 1 ] || { dump_on "cond3-dockerfile-semantic"; report "Dockerfile semantic edit: expected exit 1, got $rc"; }
grep -q "condition3 FAIL: Dockerfile differs after strip" "$WORK/last.out" \
  || report "Dockerfile semantic edit: expected condition3 FAIL line"

# ===========================================================================
# Case: condition 3 — a SUFFIXED extensionless basename (`Dockerfile.prod`)
# takes the same `#`-comment arm as plain `Dockerfile` (issue #644: ext_of
# split on the last dot, so `Dockerfile.prod` yielded `prod`, matched no arm,
# and fell to the whitespace-only default -- a comment-only edit FAILed even
# though `#` is its comment syntax). A comment-only edit PASSes; a semantic
# one still FAILs.
# ===========================================================================
R19="$WORK/r19"; new_repo "$R19"
git -C "$R19" checkout -q -b pr-branch
printf 'FROM scratch\nCMD ["true"]\n' > "$R19/Dockerfile.prod"
git -C "$R19" add Dockerfile.prod
git -C "$R19" commit -q -m "AI: feat: add Dockerfile.prod"
APPROVAL19=$(git -C "$R19" rev-parse HEAD)
printf 'FROM scratch\n# a helpful note\nCMD ["true"]\n' > "$R19/Dockerfile.prod"
git -C "$R19" add Dockerfile.prod
git -C "$R19" commit -q -m "AI: comment-only Dockerfile.prod edit

Reviewer-applied: PR #119 round 1 finding 1"
HEAD19=$(git -C "$R19" rev-parse HEAD)
FIX19="$WORK/fix19"; mkdir -p "$FIX19"
write_pull_fixture "$FIX19" "$HEAD19" main
write_ci_green "$FIX19"
rc=$(run_check "$FIX19" "$R19" 119 "$APPROVAL19" "$HEAD19")
[ "$rc" = 0 ] || { dump_on "cond3-dockerfile-prod-comment"; report "Dockerfile.prod comment-only edit: expected exit 0, got $rc"; }
grep -q "condition3 PASS: Dockerfile.prod identical after strip" "$WORK/last.out" \
  || report "Dockerfile.prod comment-only edit: expected condition3 PASS line"

git -C "$R19" checkout -q -B pr-branch "$APPROVAL19"
printf 'FROM scratch\nCMD ["false"]\n' > "$R19/Dockerfile.prod"
git -C "$R19" add Dockerfile.prod
git -C "$R19" commit -q -m "AI: semantic Dockerfile.prod edit

Reviewer-applied: PR #119 round 1 finding 2"
HEAD19B=$(git -C "$R19" rev-parse HEAD)
FIX19B="$WORK/fix19b"; mkdir -p "$FIX19B"
write_pull_fixture "$FIX19B" "$HEAD19B" main
write_ci_green "$FIX19B"
rc=$(run_check "$FIX19B" "$R19" 119 "$APPROVAL19" "$HEAD19B")
[ "$rc" = 1 ] || { dump_on "cond3-dockerfile-prod-semantic"; report "Dockerfile.prod semantic edit: expected exit 1, got $rc"; }
grep -q "condition3 FAIL: Dockerfile.prod differs after strip" "$WORK/last.out" \
  || report "Dockerfile.prod semantic edit: expected condition3 FAIL line"

# Mutation probe (#644): reverting ext_of to a plain last-dot split makes
# `ext_of Dockerfile.prod` return `prod`, which matches no comment-syntax
# arm and falls to the whitespace-only default -- the comment-only edit
# above must then FAIL instead of PASS.
MUT644="$WORK/mutant-644.sh"
cp "$HERE/../scripts/check-reviewer-commits.sh" "$MUT644"
ext_of_start=$(grep -n '^ext_of(){' "$MUT644" | head -1 | cut -d: -f1)
ext_of_end=$(grep -n '^}$' "$MUT644" | awk -F: -v s="$ext_of_start" '$1 > s {print $1; exit}')
if [ -z "$ext_of_start" ] || [ -z "$ext_of_end" ]; then
  report "mutation probe (#644): could not find the ext_of function body"
else
  {
    head -n "$((ext_of_start - 1))" "$MUT644"
    cat <<'OLDEXT'
ext_of(){ # ext_of <path> -> lowercase extension, or the whole basename with no dot
  local base="${1##*/}" ext
  case "$base" in
    *.*) ext="${base##*.}" ;;
    *) ext="$base" ;;
  esac
  printf '%s' "$ext" | tr '[:upper:]' '[:lower:]'
}
OLDEXT
    tail -n "+$((ext_of_end + 1))" "$MUT644"
  } > "$MUT644.new"
  mv "$MUT644.new" "$MUT644"
  chmod +x "$MUT644"
  rc=$( ( cd "$R19" && MOCK_GH_FIXTURES="$FIX19" PATH="$BIN:$PATH" bash "$MUT644" 119 \
      --base "$APPROVAL19" --head "$HEAD19" --repo o/r \
      > "$WORK/mut644.out" 2> "$WORK/mut644.err"; echo $? ) )
  [ "$rc" = 1 ] || report "mutation probe (#644): reverting ext_of's suffixed-basename normalisation should have made the comment-only Dockerfile.prod edit FAIL, got exit $rc"
fi

# ===========================================================================
# Case: condition 3 -- ext_of's basename-override normalisation must be
# bounded by the ACTUAL trailing suffix, never by the basename alone (round-1
# finding F1). Before this fix, `Dockerfile.md`, `Makefile.js`, `.env.md`,
# `.environment.md` and `dockerfile.json` were all wrongly normalised to
# `dockerfile`/`makefile`/`env` -- a real, different comment syntax -- purely
# because their basename happened to start with `Dockerfile`/`Makefile` or
# `.env`. Each case below plants a genuine content change (a heading or
# string value) inside a comment-shaped span (`#`) that ONLY the wrongly
# normalised extension's stripper would erase; the correctly bounded
# extension's own stripper (md's HTML-comment-only strip, js's `//`/`/* */`
# strip, or json's whitespace-only strip) leaves it as a real difference, so
# condition3 must still FAIL each one -- catching, not hiding, the change.
# ===========================================================================
f1_probe(){ # f1_probe <label> <repo-var-prefix> <pr> <path> <parent-content> <child-content>
  local label="$1" pfx="$2" pr="$3" path="$4" parent_content="$5" child_content="$6"
  local dir="$WORK/r$pfx"
  new_repo "$dir"
  git -C "$dir" checkout -q -b pr-branch
  mkdir -p "$dir/$(dirname "$path")"
  printf '%s' "$parent_content" > "$dir/$path"
  git -C "$dir" add "$path"
  git -C "$dir" commit -q -m "AI: feat: add $path"
  local approval; approval=$(git -C "$dir" rev-parse HEAD)
  printf '%s' "$child_content" > "$dir/$path"
  git -C "$dir" add "$path"
  git -C "$dir" commit -q -m "AI: semantic edit to $path

Reviewer-applied: PR #$pr round 1 finding 1"
  local head; head=$(git -C "$dir" rev-parse HEAD)
  local fix="$WORK/fix$pfx"; mkdir -p "$fix"
  write_pull_fixture "$fix" "$head" main
  write_ci_green "$fix"
  local rc; rc=$(run_check "$fix" "$dir" "$pr" "$approval" "$head")
  [ "$rc" = 1 ] || { dump_on "f1-$pfx"; report "$label: expected exit 1, got $rc"; }
  grep -qF "condition3 FAIL: $path differs after strip" "$WORK/last.out" \
    || report "$label: expected condition3 FAIL line for $path"
  # Exposed as R<pfx>/APPROVAL<pfx>/HEAD<pfx>/FIX<pfx>, matching every other
  # case's naming convention, so the round-2 R1 mutation probe below can
  # re-run this exact fixture against a mutant without rebuilding it.
  printf -v "R$pfx" '%s' "$dir"
  printf -v "APPROVAL$pfx" '%s' "$approval"
  printf -v "HEAD$pfx" '%s' "$head"
  printf -v "FIX$pfx" '%s' "$fix"
}

f1_probe "F1 Dockerfile.md genuine change" 21 121 ".claude/agents/Dockerfile.md" \
  '# Original Heading
Some body text
' \
  '# COMPLETELY DIFFERENT HEADING
Some body text
'

f1_probe "F1 Makefile.js genuine change" 22 122 "Makefile.js" \
  '# helpful comment
let x = 1;
' \
  '# COMPLETELY DIFFERENT COMMENT
let x = 1;
'

f1_probe "F1 .env.md genuine change" 23 123 ".claude/agents/.env.md" \
  '# Original Heading
KEY=value
' \
  '# COMPLETELY DIFFERENT HEADING
KEY=value
'

f1_probe "F1 .environment.md genuine change" 24 124 ".claude/agents/.environment.md" \
  '# Original Heading
KEY=value
' \
  '# COMPLETELY DIFFERENT HEADING
KEY=value
'

f1_probe "F1 dockerfile.json genuine change" 25 125 "dockerfile.json" \
  '{"note": "# original"}
' \
  '{"note": "# different"}
'

# ===========================================================================
# Mutation probe (round-2 finding R1): F1 was the only fix with no reverting
# mutation probe -- the five fixtures above assert the fixed behaviour, but
# nothing asserted the suite disagrees once ext_of's is_recognized_extension
# consultation (the F1 fix itself) is removed. Guarded anchor lookup, like
# every other probe's: an empty result reports rather than degrading to an
# address-less `sed`.
# ===========================================================================
# shellcheck disable=SC2016 # single-quoted grep pattern on purpose; nothing here is meant to expand
f1_mut_line=$(grep -n 'is_recognized_extension "\$trailing_lc"; then' "$HERE/../scripts/check-reviewer-commits.sh" | cut -d: -f1)
if [ -z "$f1_mut_line" ]; then
  report "mutation probe (round-2 R1): could not find the is_recognized_extension consultation"
else
  MUT_F1="$WORK/mutant-f1.sh"
  cp "$HERE/../scripts/check-reviewer-commits.sh" "$MUT_F1"
  # Blank the 3-line `if ... is_recognized_extension ...; then` / body / `fi`
  # block so ext_of never consults the recognized-extension list and falls
  # straight to the Dockerfile/Makefile/.env basename override on every
  # dotted path -- the exact pre-F1 shape (N1's `makefile` arm, added
  # separately, is untouched by this mutant).
  sed -i "${f1_mut_line}s/.*/:/;$((f1_mut_line + 1))s/.*/:/;$((f1_mut_line + 2))s/.*/:/" "$MUT_F1"
  chmod +x "$MUT_F1"
  # All five F1 fixtures invert against this mutant (see the Fixes Applied
  # comment for which of them do so ONLY once N1's `makefile` arm also
  # exists); asserting on Dockerfile.md -- the reviewer's own end-to-end
  # repro -- is the minimum needed to prove the fix load-bearing.
  # shellcheck disable=SC2153 # R21/APPROVAL21/HEAD21/FIX21 are set indirectly
  # via printf -v inside f1_probe() above; shellcheck cannot see through that.
  rc=$( ( cd "$R21" && MOCK_GH_FIXTURES="$FIX21" PATH="$BIN:$PATH" bash "$MUT_F1" 121 \
      --base "$APPROVAL21" --head "$HEAD21" --repo o/r \
      > "$WORK/mutf1.out" 2> "$WORK/mutf1.err"; echo $? ) )
  [ "$rc" = 0 ] || report "mutation probe (round-2 R1): removing ext_of's is_recognized_extension consultation should have turned the Dockerfile.md genuine-change case into a PASS, got exit $rc"
  grep -qF "condition3 PASS: .claude/agents/Dockerfile.md identical after strip" "$WORK/mutf1.out" \
    || report "mutation probe (round-2 R1): expected condition3 PASS for .claude/agents/Dockerfile.md under the mutant"
fi



# ===========================================================================
# Case: condition 5 — a `.github/workflows` tree listing large enough to
# exceed the pipe buffer (~64 KiB) must still be detected as defining CI
# (issue #652: `git ls-tree | grep -q` under `set -o pipefail` reports
# SIGPIPE (141) as the pipeline's status once `grep -q` exits at its first
# match while git is still writing, so the `if` read false and the bar was
# silently skipped -- a should-FAIL PASSed BY-DECLARATION instead).
# ===========================================================================
R20="$WORK/r20"; new_repo "$R20"
git -C "$R20" checkout -q -b pr-branch
mkdir -p "$R20/.github/workflows"
i=0
while [ "$i" -lt 3000 ]; do
  printf 'name: x\non: push\njobs: {}\n' \
    > "$R20/.github/workflows/generated-workflow-file-number-$i-padded-to-be-long.yml"
  i=$((i + 1))
done
printf 'code\n' > "$R20/script.sh"
git -C "$R20" add .github/workflows script.sh
git -C "$R20" commit -q -m "AI: feat: add many workflow files, plus script.sh"
APPROVAL20=$(git -C "$R20" rev-parse HEAD)
printf '# a helpful note\ncode\n' > "$R20/script.sh"
git -C "$R20" add script.sh
git -C "$R20" commit -q -m "AI: reviewer note

Reviewer-applied: PR #120 round 1 finding 1"
HEAD20=$(git -C "$R20" rev-parse HEAD)
FIX20="$WORK/fix20"; mkdir -p "$FIX20"
write_pull_fixture "$FIX20" "$HEAD20" main
write_ci_empty_no_legacy "$FIX20"
rc=$(run_check "$FIX20" "$R20" 120 "$APPROVAL20" "$HEAD20")
[ "$rc" = 1 ] || { dump_on "cond5-large-workflows-tree"; report "large .github/workflows tree: expected exit 1, got $rc"; }
grep -q "round condition5 FAIL.*\.github/workflows defines CI" "$WORK/last.out" \
  || report "large .github/workflows tree: expected condition5 FAIL naming .github/workflows"

# Mutation probe (#652): restoring the unguarded `git ls-tree | grep -q`
# pipeline under pipefail must flip this same case from FAIL to
# PASS-BY-DECLARATION.
MUT652="$WORK/mutant-652.sh"
cp "$HERE/../scripts/check-reviewer-commits.sh" "$MUT652"
# shellcheck disable=SC2016 # literal pattern; nothing here is meant to expand
wf_start=$(grep -n 'workflow_tree=\$(git ls-tree' "$MUT652" | head -1 | cut -d: -f1)
wf_end=$(grep -nF "if grep -qE '\\.ya?ml\$' <<<\"\$workflow_tree\"; then" "$MUT652" | head -1 | cut -d: -f1)
if [ -z "$wf_start" ] || [ -z "$wf_end" ]; then
  report "mutation probe (#652): could not find the guarded workflow-tree lines"
else
  {
    head -n "$((wf_start - 1))" "$MUT652"
    cat <<'OLDWF'
      if git ls-tree -r --name-only "$HEAD" -- .github/workflows 2>/dev/null \
        | grep -qE '\.ya?ml$'; then
OLDWF
    tail -n "+$((wf_end + 1))" "$MUT652"
  } > "$MUT652.new"
  mv "$MUT652.new" "$MUT652"
  chmod +x "$MUT652"
  rc=$( ( cd "$R20" && MOCK_GH_FIXTURES="$FIX20" PATH="$BIN:$PATH" bash "$MUT652" 120 \
      --base "$APPROVAL20" --head "$HEAD20" --repo o/r \
      > "$WORK/mut652.out" 2> "$WORK/mut652.err"; echo $? ) )
  [ "$rc" = 0 ] || report "mutation probe (#652): restoring the unguarded ls-tree|grep -q pipeline should have flipped the large-tree case to PASS-BY-DECLARATION, got exit $rc"
  grep -q "PASS-BY-DECLARATION" "$WORK/mut652.out" \
    || report "mutation probe (#652): expected the reverted pipeline to report PASS-BY-DECLARATION on the large-tree case"
fi

# ===========================================================================
# Case: condition 5 — a repo that HAS CI but whose testing.md merely contains
# the words "review-only" must never reach the by-declaration branch (round-1
# finding S2). Zero check-runs there means CI did not run on this head.
# ===========================================================================
R11="$WORK/r11"
new_repo "$R11" "CI runs on every PR and is required. We do not accept review-only submissions."
git -C "$R11" checkout -q -b pr-branch
printf 'code\n' > "$R11/script.sh"
git -C "$R11" add script.sh; git -C "$R11" commit -q -m "AI: feat: add script"
APPROVAL11=$(git -C "$R11" rev-parse HEAD)
printf '# note\ncode\n' > "$R11/script.sh"
git -C "$R11" add script.sh
git -C "$R11" commit -q -m "AI: note fix

Reviewer-applied: PR #110 round 1 finding 1"
HEAD11=$(git -C "$R11" rev-parse HEAD)
FIX11="$WORK/fix11"; mkdir -p "$FIX11"
write_pull_fixture "$FIX11" "$HEAD11" main
write_ci_empty_no_legacy "$FIX11"
rc=$(run_check "$FIX11" "$R11" 110 "$APPROVAL11" "$HEAD11")
[ "$rc" = 1 ] || { dump_on "cond5-loose-wording"; report "loose no-CI wording: expected exit 1, got $rc"; }
grep -q "condition5 FAIL" "$WORK/last.out" \
  || report "loose no-CI wording: expected condition5 FAIL line"
grep -q "PASS-BY-DECLARATION" "$WORK/last.out" \
  && report "loose no-CI wording: must not report PASS-BY-DECLARATION"

# ===========================================================================
# Case: condition 5 — a repo carrying the verbatim declaration AND a workflow
# definition has CI, so the workflow evidence bars the by-declaration branch
# and zero check-runs FAILs.
# ===========================================================================
R12="$WORK/r12"; new_repo "$R12"
git -C "$R12" checkout -q -b pr-branch
mkdir -p "$R12/.github/workflows"
printf 'name: ci\non: [pull_request]\n' > "$R12/.github/workflows/ci.yml"
printf 'code\n' > "$R12/script.sh"
git -C "$R12" add script.sh .github/workflows/ci.yml
git -C "$R12" commit -q -m "AI: feat: add script and CI"
APPROVAL12=$(git -C "$R12" rev-parse HEAD)
printf '# note\ncode\n' > "$R12/script.sh"
git -C "$R12" add script.sh
git -C "$R12" commit -q -m "AI: note fix

Reviewer-applied: PR #111 round 1 finding 1"
HEAD12=$(git -C "$R12" rev-parse HEAD)
FIX12="$WORK/fix12"; mkdir -p "$FIX12"
write_pull_fixture "$FIX12" "$HEAD12" main
write_ci_empty_no_legacy "$FIX12"
rc=$(run_check "$FIX12" "$R12" 111 "$APPROVAL12" "$HEAD12")
[ "$rc" = 1 ] || { dump_on "cond5-workflows-present"; report "workflow definition present: expected exit 1, got $rc"; }
grep -q "defines CI" "$WORK/last.out" \
  || report "workflow definition present: expected the .github/workflows FAIL message"

# ===========================================================================
# Case: condition 3 — a ROOT commit in the range (no parent to compare
# against). Built with plumbing so the fixture worktree is untouched; the
# range still holds exactly one trailer-carrying commit.
# ===========================================================================
R13="$WORK/r13"; new_repo "$R13"
git -C "$R13" checkout -q -b pr-branch
printf 'code\n' > "$R13/script.sh"
git -C "$R13" add script.sh; git -C "$R13" commit -q -m "AI: feat: add script"
APPROVAL13=$(git -C "$R13" rev-parse HEAD)
BLOB13=$(printf 'code\n' | git -C "$R13" hash-object -w --stdin)
TREE13=$(printf '100644 blob %s\tscript.sh\n' "$BLOB13" | git -C "$R13" mktree)
HEAD13=$(git -C "$R13" commit-tree "$TREE13" -m "AI: parentless reviewer commit

Reviewer-applied: PR #112 round 1 finding 1")
FIX13="$WORK/fix13"; mkdir -p "$FIX13"
write_pull_fixture "$FIX13" "$HEAD13" main
write_ci_green "$FIX13"
rc=$(run_check "$FIX13" "$R13" 112 "$APPROVAL13" "$HEAD13")
[ "$rc" = 1 ] || { dump_on "cond3-root-commit"; report "root commit: expected exit 1, got $rc"; }
grep -q "condition3 FAIL: no parent commit (root commit)" "$WORK/last.out" \
  || report "root commit: expected the no-parent condition3 FAIL line"

# ===========================================================================
# Case: condition 3 — the reviewer ADDS a file. The path is inside the PR's
# own diff (the PR deleted it), so condition 2 passes and condition 3 is the
# only thing standing between an added file and the gate.
# ===========================================================================
R14="$WORK/r14"; new_repo "$R14"
printf 'helper\n' > "$R14/helper.sh"
git -C "$R14" add helper.sh; git -C "$R14" commit -q -m "AI: add helper"
git -C "$R14" fetch origin -q
git -C "$R14" checkout -q -b pr-branch
git -C "$R14" rm -q helper.sh
git -C "$R14" commit -q -m "AI: feat: drop helper"
APPROVAL14=$(git -C "$R14" rev-parse HEAD)
printf 'helper\n' > "$R14/helper.sh"
git -C "$R14" add helper.sh
git -C "$R14" commit -q -m "AI: put helper back

Reviewer-applied: PR #113 round 1 finding 1"
HEAD14=$(git -C "$R14" rev-parse HEAD)
FIX14="$WORK/fix14"; mkdir -p "$FIX14"
write_pull_fixture "$FIX14" "$HEAD14" main
write_ci_green "$FIX14"
rc=$(run_check "$FIX14" "$R14" 113 "$APPROVAL14" "$HEAD14")
[ "$rc" = 1 ] || { dump_on "cond3-added-file"; report "added file: expected exit 1, got $rc"; }
grep -q "condition3 FAIL: helper.sh did not exist at parent" "$WORK/last.out" \
  || report "added file: expected the did-not-exist-at-parent condition3 FAIL line"

# ===========================================================================
# Case: condition 3 — the reviewer REMOVES a file that is inside the PR's
# diff. Deleting a file is a semantic change, not a comment edit.
# ===========================================================================
R15="$WORK/r15"; new_repo "$R15"
git -C "$R15" checkout -q -b pr-branch
printf 'code\n' > "$R15/script.sh"
git -C "$R15" add script.sh; git -C "$R15" commit -q -m "AI: feat: add script"
APPROVAL15=$(git -C "$R15" rev-parse HEAD)
git -C "$R15" rm -q script.sh
git -C "$R15" commit -q -m "AI: delete the script

Reviewer-applied: PR #114 round 1 finding 1"
HEAD15=$(git -C "$R15" rev-parse HEAD)
FIX15="$WORK/fix15"; mkdir -p "$FIX15"
write_pull_fixture "$FIX15" "$HEAD15" main
write_ci_green "$FIX15"
rc=$(run_check "$FIX15" "$R15" 114 "$APPROVAL15" "$HEAD15")
[ "$rc" = 1 ] || { dump_on "cond3-removed-file"; report "removed file: expected exit 1, got $rc"; }
grep -q "condition3 FAIL: script.sh removed by this commit" "$WORK/last.out" \
  || report "removed file: expected the removed-by-this-commit condition3 FAIL line"

# ===========================================================================
# Case: condition 5 — no check-runs, no legacy status, and the head tree has
# no docs/process/testing.md at all. Absent is not a declaration: FAIL, and
# the message must say the doc is missing rather than mis-worded (round-2
# finding 2).
# ===========================================================================
R16="$WORK/r16"; new_repo "$R16"
git -C "$R16" checkout -q -b pr-branch
git -C "$R16" rm -q docs/process/testing.md
printf 'code\n' > "$R16/script.sh"
git -C "$R16" add script.sh
git -C "$R16" commit -q -m "AI: feat: add script, drop the testing doc"
APPROVAL16=$(git -C "$R16" rev-parse HEAD)
printf '# note\ncode\n' > "$R16/script.sh"
git -C "$R16" add script.sh
git -C "$R16" commit -q -m "AI: note fix

Reviewer-applied: PR #115 round 1 finding 1"
HEAD16=$(git -C "$R16" rev-parse HEAD)
FIX16="$WORK/fix16"; mkdir -p "$FIX16"
write_pull_fixture "$FIX16" "$HEAD16" main
write_ci_empty_no_legacy "$FIX16"
rc=$(run_check "$FIX16" "$R16" 115 "$APPROVAL16" "$HEAD16")
[ "$rc" = 1 ] || { dump_on "cond5-doc-absent"; report "absent testing.md: expected exit 1, got $rc"; }
grep -q "has no docs/process/testing.md" "$WORK/last.out" \
  || report "absent testing.md: expected the absent-doc condition5 FAIL message"
grep -q "PASS-BY-DECLARATION" "$WORK/last.out" \
  && report "absent testing.md: must not report PASS-BY-DECLARATION"

# ===========================================================================
# Case: condition 5 — docs/process/testing.md exists in the head tree but
# cannot be read as a document (here: the path is a directory). Unreadable is
# reported as its own error, never as "does not declare" (round-2 finding 2).
# ===========================================================================
R17="$WORK/r17"; new_repo "$R17"
git -C "$R17" checkout -q -b pr-branch
git -C "$R17" rm -q docs/process/testing.md
mkdir -p "$R17/docs/process/testing.md"
printf 'note\n' > "$R17/docs/process/testing.md/README.md"
printf 'code\n' > "$R17/script.sh"
git -C "$R17" add script.sh docs/process/testing.md/README.md
git -C "$R17" commit -q -m "AI: feat: add script, testing.md is a directory here"
APPROVAL17=$(git -C "$R17" rev-parse HEAD)
printf '# note\ncode\n' > "$R17/script.sh"
git -C "$R17" add script.sh
git -C "$R17" commit -q -m "AI: note fix

Reviewer-applied: PR #117 round 1 finding 1"
HEAD17=$(git -C "$R17" rev-parse HEAD)
FIX17="$WORK/fix17"; mkdir -p "$FIX17"
write_pull_fixture "$FIX17" "$HEAD17" main
write_ci_empty_no_legacy "$FIX17"
rc=$(run_check "$FIX17" "$R17" 117 "$APPROVAL17" "$HEAD17")
[ "$rc" = 1 ] || { dump_on "cond5-doc-unreadable"; report "unreadable testing.md: expected exit 1, got $rc"; }
grep -q "could not be read" "$WORK/last.out" \
  || report "unreadable testing.md: expected the unreadable-doc condition5 error message"
grep -q "does not declare" "$WORK/last.out" \
  && report "unreadable testing.md: must not be reported as a missing declaration"

# ===========================================================================
# Case: condition 3 — instruction text named by docs/process/testing.md
# itself ("or under a path the repo's docs/process/testing.md names as agent
# instructions", verdict-rules.md condition 3). A semantic edit to a Markdown
# file under such a path is NOT exempt.
# ===========================================================================
R18="$WORK/r18"
new_repo "$R18" "Declaration: no suites — review-only.
Agent instructions live under \`docs/agent-notes/\`."
git -C "$R18" checkout -q -b pr-branch
mkdir -p "$R18/docs/agent-notes"
printf 'line one\nline two\n' > "$R18/docs/agent-notes/guide.md"
git -C "$R18" add docs/agent-notes/guide.md
git -C "$R18" commit -q -m "AI: feat: add agent notes"
APPROVAL18=$(git -C "$R18" rev-parse HEAD)
printf 'line ONE CHANGED\nline two\n' > "$R18/docs/agent-notes/guide.md"
git -C "$R18" add docs/agent-notes/guide.md
git -C "$R18" commit -q -m "AI: semantic edit to doc-named instruction text

Reviewer-applied: PR #118 round 1 finding 1"
HEAD18=$(git -C "$R18" rev-parse HEAD)
FIX18="$WORK/fix18"; mkdir -p "$FIX18"
write_pull_fixture "$FIX18" "$HEAD18" main
write_ci_green "$FIX18"
rc=$(run_check "$FIX18" "$R18" 118 "$APPROVAL18" "$HEAD18")
[ "$rc" = 1 ] || { dump_on "cond3-doc-named-instructions"; report "doc-named instruction text: expected exit 1, got $rc"; }
grep -q "condition3 FAIL: docs/agent-notes/guide.md differs after strip" "$WORK/last.out" \
  || report "doc-named instruction text: expected condition3 FAIL line"

# ===========================================================================
# Mutation probes (issue #609 AC2): deleting the FAIL= assignment(s) that
# belong to one condition, one at a time, on a copy of the script, must turn
# a case that FAILed above into a PASS — proving that check is load-bearing
# rather than redundant with the others. Line numbers are read fresh from
# the real script each time rather than hardcoded, so a future edit that
# shifts line numbers cannot silently stop probing the intended lines.
# ---------------------------------------------------------------------------
mutate_blank_lines(){ # mutate_blank_lines <out-path> <line...> — blanks each
                       # given line number (keeps line count/numbers stable)
  local out="$1"; shift
  cp "$HERE/../scripts/check-reviewer-commits.sh" "$out"
  local ln
  for ln in "$@"; do
    sed -i "${ln}s/.*/:/" "$out"
  done
  chmod +x "$out"
}

# Condition 1 probe: blank the three FAIL=1 assignments under condition 1's
# checks; re-run the missing-trailer case, which must now PASS.
# Anchored on the condition-1 report lines themselves (each FAIL=1 sits on the
# line directly above its REPORT_LINES+= call) rather than on a line-number
# window, which an edit elsewhere in the script would silently invalidate.
# shellcheck disable=SC2016 # literal pattern: $sha is grep text, not an expansion
c1_fail_lines=$(grep -n 'REPORT_LINES+=("$sha condition1 FAIL' \
  "$HERE/../scripts/check-reviewer-commits.sh" | awk -F: '{print $1-1}')
for ln in $c1_fail_lines; do
  sed -n "${ln}p" "$HERE/../scripts/check-reviewer-commits.sh" | grep -q '^ *FAIL=1$' \
    || report "mutation probe (condition 1): line $ln is not the expected FAIL=1 assignment"
done
MUT1="$WORK/mutant-cond1.sh"
# shellcheck disable=SC2086 # word-splitting on purpose: multiple line numbers, one per word
mutate_blank_lines "$MUT1" $c1_fail_lines
rc=$( ( cd "$R1" && MOCK_GH_FIXTURES="$FIX_NT" PATH="$BIN:$PATH" bash "$MUT1" 100 \
    --base "$APPROVAL1" --head "$HEAD_NOTRAILER" --repo o/r \
    > "$WORK/mut1.out" 2> "$WORK/mut1.err"; echo $? ) )
[ "$rc" = 0 ] || report "mutation probe (condition 1): removing its FAIL=1 lines should have turned the missing-trailer FAIL case into a PASS, got exit $rc"

# Every probe below picks its mutation target by grepping for the REPORT_LINES
# call the FAIL=1 belongs to and asserting that the line above it really is a
# `FAIL=1` assignment, so a reindent or a moved block fails the probe loudly
# instead of mutating an unrelated line (round-2 note N3).
SRC="$HERE/../scripts/check-reviewer-commits.sh"
fail_line_above(){ # fail_line_above <label> <literal report-line fragment>
  local label="$1" pat="$2" ln
  ln=$(grep -n -F "$pat" "$SRC" | head -1 | awk -F: '{print $1-1}')
  if [ -z "$ln" ]; then
    report "mutation probe ($label): could not find the report line matching: $pat"
    echo ""
    return
  fi
  sed -n "${ln}p" "$SRC" | grep -q '^ *FAIL=1$' \
    || report "mutation probe ($label): line $ln is not the expected FAIL=1 assignment"
  echo "$ln"
}
run_mutant(){ # run_mutant <mutant> <repo> <pr> <base> <head> <fixdir> <tag>
  ( cd "$2" && MOCK_GH_FIXTURES="$6" PATH="$BIN:$PATH" bash "$1" "$3" \
      --base "$4" --head "$5" --repo o/r > "$WORK/$7.out" 2> "$WORK/$7.err"; echo $? )
}

# Condition 2 probe.
c2_fail_line=$(grep -n '^        cond2_fail=1$' "$SRC" | head -1 | cut -d: -f1)
[ -n "$c2_fail_line" ] || report "mutation probe (condition 2): could not find cond2_fail=1"
c2_fail_line2=$(fail_line_above "condition 2" 'condition2 FAIL:')
MUT2="$WORK/mutant-cond2.sh"
mutate_blank_lines "$MUT2" "$c2_fail_line" "$c2_fail_line2"
rc=$(run_mutant "$MUT2" "$R2" 101 "$APPROVAL2" "$HEAD2" "$FIX2" mut2)
[ "$rc" = 0 ] || report "mutation probe (condition 2): removing its FAIL markers should have turned the outside-diff FAIL case into a PASS, got exit $rc"

# Condition 3 probes: each of the four FAIL=1 sites is blanked ON ITS OWN and
# the case that depends on it must invert. Blanking them as a group hid three
# untested branches for two rounds (round-2 finding 4), so the group probe is
# replaced by four single-site probes.
c3_probe(){ # c3_probe <label> <report fragment> <repo> <pr> <base> <head> <fixdir> <tag>
  local ln mut rc
  ln=$(fail_line_above "$1" "$2")
  [ -n "$ln" ] || return
  mut="$WORK/mutant-$8.sh"
  mutate_blank_lines "$mut" "$ln"
  rc=$(run_mutant "$mut" "$3" "$4" "$5" "$6" "$7" "$8")
  [ "$rc" = 0 ] \
    || report "mutation probe ($1): blanking line $ln alone should have turned that FAIL case into a PASS, got exit $rc"
}
# shellcheck disable=SC2016 # literal pattern: $f is grep text, not an expansion
c3_probe "condition 3 (differs after strip)" 'condition3 FAIL: $f differs after strip' \
  "$R2" 101 "$APPROVAL2" "$HEAD_SEM" "$FIX_SEM" mut3-strip
c3_probe "condition 3 (root commit)" 'condition3 FAIL: no parent commit (root commit)' \
  "$R13" 112 "$APPROVAL13" "$HEAD13" "$FIX13" mut3-root
# shellcheck disable=SC2016 # literal pattern: $f is grep text, not an expansion
c3_probe "condition 3 (added file)" 'condition3 FAIL: $f did not exist at parent' \
  "$R14" 113 "$APPROVAL14" "$HEAD14" "$FIX14" mut3-added
# shellcheck disable=SC2016 # literal pattern: $f is grep text, not an expansion
c3_probe "condition 3 (removed file)" 'condition3 FAIL: $f removed by this commit' \
  "$R15" 114 "$APPROVAL15" "$HEAD15" "$FIX15" mut3-removed

# Condition 4 probe: blank the FAIL=1 that gates the line-cap check.
c4_fail_line=$(fail_line_above "condition 4" 'round condition4 FAIL:')
MUT4="$WORK/mutant-cond4.sh"
mutate_blank_lines "$MUT4" "$c4_fail_line"
rc=$(run_mutant "$MUT4" "$R5" 104 "$APPROVAL5" "$HEAD5B" "$FIX5B" mut4)
[ "$rc" = 0 ] || report "mutation probe (condition 4): removing its FAIL=1 line should have turned the over-the-cap FAIL case into a PASS, got exit $rc"

# Condition 5 probe: blank the `|| FAIL=1` on the check_ci call. The
# anchor-lookup-then-sed is factored into c5_replace_ci_line() (issue #654) so
# that BOTH this probe and the #654 meta-probe further below drive the exact
# same guarded code path — a regression of the #654 guard breaks both probes
# identically, rather than only a hand-written stand-in for it.
# shellcheck disable=SC2016 # single-quoted grep pattern on purpose; nothing here is meant to expand
c5_replace_ci_line(){ # c5_replace_ci_line <src-script> <dst-mutant> -> writes
                       # a copy of <src-script> to <dst-mutant> with the
                       # `ci_line=$(check_ci) || FAIL=1` line swapped for an
                       # unconditional `|| true`; returns 1 and leaves
                       # <dst-mutant> untouched (never created) when that
                       # anchor is not found in <src-script>, rather than
                       # degrading to an address-less `sed` that would
                       # corrupt every line of the copy.
  local src="$1" dst="$2" line
  line=$(grep -n 'ci_line=\$(check_ci) || FAIL=1' "$src" | cut -d: -f1)
  [ -n "$line" ] || return 1
  cp "$src" "$dst"
  sed -i "${line}s/.*/  ci_line=\$(check_ci) || true/" "$dst"
}
MUT5="$WORK/mutant-cond5.sh"
if ! c5_replace_ci_line "$SRC" "$MUT5"; then
  report "mutation probe (condition 5): could not find the check_ci FAIL propagation line"
else
  chmod +x "$MUT5"
  rc=$( ( cd "$R6" && MOCK_GH_FIXTURES="$FIX6_RED" PATH="$BIN:$PATH" bash "$MUT5" 105 \
      --base "$APPROVAL6" --head "$HEAD6" --repo o/r \
      > "$WORK/mut5.out" 2> "$WORK/mut5.err"; echo $? ) )
  [ "$rc" = 0 ] || report "mutation probe (condition 5): removing its FAIL propagation should have turned the CI-red FAIL case into a PASS, got exit $rc"
fi

# Probe 6 (round-1 finding S1): restore the pre-fix, line-based sed strip of
# `<!-- ... -->` and the two new condition-3 cases must both invert — the
# between-two-comments rewrite passes (permissive) and the multi-line
# comment-only edit fails (strict). Proves both regression cases are
# load-bearing on the perl strip specifically, not on anything else.
MUT6="$WORK/mutant-html-strip.sh"
cp "$HERE/../scripts/check-reviewer-commits.sh" "$MUT6"
s1_line=$(grep -n "perl -0pe 's{<!--" "$MUT6" | cut -d: -f1)
[ -n "$s1_line" ] || report "mutation probe (S1): could not find the HTML-comment strip line"
sed -i "${s1_line}s|.*|  sed -E 's/<!--.*?-->//g' \"\$1\"|" "$MUT6"
chmod +x "$MUT6"
rc=$( ( cd "$R8" && MOCK_GH_FIXTURES="$FIX8" PATH="$BIN:$PATH" bash "$MUT6" 107 \
    --base "$APPROVAL8" --head "$HEAD8" --repo o/r \
    > "$WORK/mut6a.out" 2> "$WORK/mut6a.err"; echo $? ) )
[ "$rc" = 0 ] || report "mutation probe (S1 direction A): the old line-based strip should have let the between-two-comments rewrite PASS, got exit $rc"
rc=$( ( cd "$R9" && MOCK_GH_FIXTURES="$FIX9" PATH="$BIN:$PATH" bash "$MUT6" 108 \
    --base "$APPROVAL9" --head "$HEAD9" --repo o/r \
    > "$WORK/mut6b.out" 2> "$WORK/mut6b.err"; echo $? ) )
[ "$rc" = 1 ] || report "mutation probe (S1 direction B): the old line-based strip should have made the multi-line comment-only edit FAIL, got exit $rc"

# Probe 7 (round-1 finding S2): restore the loose no-CI match and the
# CI-repo-that-merely-says-"review-only" case passes by declaration again.
MUT7="$WORK/mutant-noci-match.sh"
cp "$HERE/../scripts/check-reviewer-commits.sh" "$MUT7"
s2_line=$(grep -n "grep -qF 'no suites" "$MUT7" | cut -d: -f1)
[ -n "$s2_line" ] || report "mutation probe (S2): could not find the verbatim declaration match"
sed -i "${s2_line}s|.*|      if printf '%s' \"\$TESTING_DOC\" \| grep -qiE 'no (suites\|ci)\|review-only'; then|" "$MUT7"
chmod +x "$MUT7"
rc=$( ( cd "$R11" && MOCK_GH_FIXTURES="$FIX11" PATH="$BIN:$PATH" bash "$MUT7" 110 \
    --base "$APPROVAL11" --head "$HEAD11" --repo o/r \
    > "$WORK/mut7.out" 2> "$WORK/mut7.err"; echo $? ) )
[ "$rc" = 0 ] || report "mutation probe (S2): the loose no-CI match should have let the CI repo PASS-BY-DECLARATION, got exit $rc"

# Probe 8 (round-1 finding S4): restore the unreachable `Dockerfile` case arm
# and the comment-only Dockerfile edit falls to the whitespace-only default
# arm and FAILs again.
MUT8="$WORK/mutant-dockerfile.sh"
sed "s/|conf|dockerfile|makefile)/|conf|Dockerfile|makefile)/" \
  "$HERE/../scripts/check-reviewer-commits.sh" > "$MUT8"
chmod +x "$MUT8"
grep -q '|conf|Dockerfile|makefile)' "$MUT8" || report "mutation probe (S4): could not rewrite the case arm"
rc=$( ( cd "$R10" && MOCK_GH_FIXTURES="$FIX10" PATH="$BIN:$PATH" bash "$MUT8" 109 \
    --base "$APPROVAL10" --head "$HEAD10" --repo o/r \
    > "$WORK/mut8.out" 2> "$WORK/mut8.err"; echo $? ) )
[ "$rc" = 1 ] || report "mutation probe (S4): the unreachable Dockerfile arm should have made the comment-only Dockerfile edit FAIL, got exit $rc"

# Probe 9 (round-2 note N2): drop the docs/process/testing.md-named
# instruction prefixes and the doc-named Markdown file becomes exempt again,
# so the semantic edit under it PASSes — proving the third clause of
# verdict-rules.md condition 3 is enforced, not merely documented.
MUT9="$WORK/mutant-instruction-prefixes.sh"
# shellcheck disable=SC2016 # literal pattern: the variable name is grep text
n2_line=$(grep -n '^  done < "\$INSTRUCTION_PREFIXES_FILE"$' "$SRC" | head -1 | cut -d: -f1)
[ -n "$n2_line" ] || report "mutation probe (N2): could not find the instruction-prefix loop"
cp "$SRC" "$MUT9"
sed -i "${n2_line}s|.*|  done < /dev/null|" "$MUT9"
chmod +x "$MUT9"
rc=$(run_mutant "$MUT9" "$R18" 118 "$APPROVAL18" "$HEAD18" "$FIX18" mut9)
[ "$rc" = 0 ] || report "mutation probe (N2): ignoring the doc-named instruction prefixes should have made the semantic Markdown edit exempt and PASS, got exit $rc"

# Probe 10 (round-3 finding R1): restore the swallowed failure
# (`|| legacy_json=""`) and the failed-GET case passes by declaration again --
# proving the ci-error branch, not some neighbouring check, is what keeps an
# unestablished claim from being printed as an observed one.
MUT10="$WORK/mutant-legacy-swallow.sh"
cp "$SRC" "$MUT10"
r1_line=$(grep -n 'ci-error: GET commit status failed' "$MUT10" | head -1 | cut -d: -f1)
if [ -z "$r1_line" ]; then
  report "mutation probe (R1): could not find the failed-status-GET ci-error line"
else
  sed -i "${r1_line}s|.*|      \|\| legacy_json=\"\"|" "$MUT10"
  chmod +x "$MUT10"
  rc=$(run_mutant "$MUT10" "$R6" 105 "$APPROVAL6" "$HEAD6" "$FIX6_ERR" mut10)
  [ "$rc" = 0 ] || report "mutation probe (R1): swallowing the failed status GET should have let the no-CI repo PASS-BY-DECLARATION, got exit $rc"
fi

# ===========================================================================
# Mutation probe (issue #654): probe 5's own anchor lookup must be guarded
# before it is used as a `sed` address, the way every other probe's anchor
# is. This calls c5_replace_ci_line() -- the EXACT function probe 5 itself
# calls above, not a hand-written stand-in for it -- against a copy of the
# script whose anchor line has been renamed (simulating the anchor moving
# after an unrelated edit), so a regression of that function's own guard
# (e.g. dropping its `[ -n "$line" ] || return 1`) makes THIS probe fail too,
# the same way it would make probe 5 itself silently corrupt its mutant.
# A hand-written re-implementation of "guarded" and "unguarded" sed snippets,
# as this probe used to be, cannot detect that regression at all: removing
# c5_replace_ci_line's guard changes nothing about code this probe never
# calls.
# ===========================================================================
BROKEN_ANCHOR="$WORK/broken-anchor.sh"
# shellcheck disable=SC2016 # literal pattern text, nothing here is meant to expand
sed 's/ci_line=\$(check_ci) || FAIL=1/ci_line=\$(check_ci) || FAILED=1/' "$SRC" > "$BROKEN_ANCHOR"
chmod +x "$BROKEN_ANCHOR"

# shellcheck disable=SC2016 # literal pattern; nothing here is meant to expand
old_c5_line=$(grep -n 'ci_line=\$(check_ci) || FAIL=1' "$BROKEN_ANCHOR" | cut -d: -f1)
[ -z "$old_c5_line" ] || report "mutation probe (#654 setup): the renamed anchor should no longer match the probe's grep pattern"

# Historical control, kept for contrast only: the PRE-#654 shape (grep result
# used directly as a sed address, no check) degrades on this exact input to
# an address-less `sed -i "s/.../" file`, which corrupts EVERY line of the
# copy into the same line. This block asserts nothing about the current
# script; it exists to show the two behaviours genuinely differ on identical
# input, so the real assertion below (that the guarded function does NOT do
# this) is meaningful rather than vacuous.
OLD_STYLE_MUT="$WORK/old-style-mutant.sh"
cp "$BROKEN_ANCHOR" "$OLD_STYLE_MUT"
sed -i "${old_c5_line}s/.*/  ci_line=\$(check_ci) || true/" "$OLD_STYLE_MUT"
old_style_distinct_lines=$(sort -u "$OLD_STYLE_MUT" | wc -l | tr -d ' ')
[ "$old_style_distinct_lines" = 1 ] \
  || report "mutation probe (#654 control): expected the pre-#654 unguarded pattern to corrupt every line of the mutant into one, got $old_style_distinct_lines distinct lines"

# The real assertion: drive c5_replace_ci_line() -- probe 5's own function,
# unmodified -- against the SAME broken-anchor input. A correctly-guarded
# function refuses (returns 1) and never creates the destination file at
# all. If someone removes the `[ -n "$line" ] || return 1` guard from
# c5_replace_ci_line, it instead corrupts $GUARDED_MUT exactly like the
# control above and returns 0, and both checks below fail this suite.
GUARDED_MUT="$WORK/guarded-mutant.sh"
rm -f "$GUARDED_MUT"
if c5_replace_ci_line "$BROKEN_ANCHOR" "$GUARDED_MUT"; then
  report "mutation probe (#654): expected c5_replace_ci_line to report the missing anchor on a broken-anchor input, but it produced a mutant instead"
fi
[ -e "$GUARDED_MUT" ] \
  && report "mutation probe (#654): expected no mutant file when the anchor is missing, but $GUARDED_MUT was created"

# ===========================================================================
# Docs check (issue #653): workflow-merge-verifier.md must not claim
# check-reviewer-commits.sh replaces sub-step 5's by-hand Suggested Test
# Steps re-run on <new-head> -- the script reports PASS-BY-DECLARATION there
# instead and cannot re-run anything, and verdict-rules.md's condition 5
# never passes vacuously.
# ===========================================================================
AGENT_DOC="$HERE/../../../agents/workflow-merge-verifier.md"
[ -f "$AGENT_DOC" ] || report "docs (#653): could not find $AGENT_DOC"
if grep -qF 'replacing the by-hand run below' "$AGENT_DOC"; then
  report "docs (#653): workflow-merge-verifier.md still claims the script replaces the by-hand run"
fi
grep -qF '*supplements* that hand-run rather than replacing it' "$AGENT_DOC" \
  || report "docs (#653): workflow-merge-verifier.md is missing the corrected claim"

# Mutation probe (#653): reverting the corrected sentence back to the old
# wording must make the check above fail, proving it is load-bearing rather
# than a check that would pass regardless of the doc's wording.
doc_old_anchor_line=$(grep -n 'goes in your report alongside your own hand-run of all five' "$AGENT_DOC" | cut -d: -f1)
doc_new_anchor_line=$(grep -n 'the script \*supplements\* that hand-run rather than replacing it, since' "$AGENT_DOC" | cut -d: -f1)
if [ -z "$doc_old_anchor_line" ] || [ -z "$doc_new_anchor_line" ]; then
  report "mutation probe (#653): could not find the corrected sentence's anchor lines"
else
  MUT_DOC="$WORK/mutant-agent-doc.md"
  cp "$AGENT_DOC" "$MUT_DOC"
  sed -i "${doc_old_anchor_line}s/.*/line cap and CI lines — is what goes in your report, replacing the by-hand run below./" "$MUT_DOC"
  sed -i "${doc_new_anchor_line}s/.*/The five sub-steps here are what it computes, spelled out so a by-hand fallback is/" "$MUT_DOC"
  if grep -qF 'replacing the by-hand run below' "$MUT_DOC"; then
    mut_doc_result=fail
  else
    mut_doc_result=pass
  fi
  [ "$mut_doc_result" = fail ] \
    || report "mutation probe (#653): reverting to the old wording should have made the doc check fail"
fi

# ===========================================================================
# Hermeticity: no UNMOCKED-CONTEXT call was ever logged.
# ===========================================================================
if grep -q '^UNMOCKED-CONTEXT ' "$MOCK_GH_CALL_LOG"; then
  report "hermeticity: a gh call was made from an unmocked context: $(grep -m1 '^UNMOCKED-CONTEXT ' "$MOCK_GH_CALL_LOG")"
fi

if [ "$fail" -eq 0 ]; then
  echo "test_check_reviewer_commits: all checks passed"
  exit 0
else
  exit 1
fi
