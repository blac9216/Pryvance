#!/usr/bin/env bash
# test_check_test_steps.sh — fixture-driven regression test for
# check-test-steps.sh. Follows this directory's harness conventions (see
# tests/README.md): a mocked `gh` on PATH serving fixture JSON from a private
# mktemp scratch dir, refusing every non-GET verb, with every case — argument
# errors included (#477) — routed through it so nothing can reach a real,
# authenticated `gh`. The mock marks an invocation arriving without the harness
# env as UNMOCKED-CONTEXT, asserted absent at the end.
#
# Pinned to LANG=C / LC_ALL=C: the extraction is over byte patterns, and the
# collation must not depend on the invoking shell's locale.
#
# 2026-09-05 owner ruling on #732 (item 4): the `NAMES`/`PATTERNS`
# phrase-matching arrays that used to hold a PR body's **Suggested Test
# Steps** section to a wording list are removed (issue #752); this suite no
# longer exercises them. `--check-shas` (issue #640, pure git ancestry) is
# unchanged and every fixture below that predates this removal is preserved
# verbatim for it.
#
# Covers:
#  - without --check-shas, ANY body (including one full of moving refs and
#    stale SHAs, which this script no longer reads at all) exits 0 with a
#    "no check performed" message — proving the removal is real and not just
#    unreachable dead code: the same unreachable-SHA body that fails WITH the
#    flag passes WITHOUT it.
#  - --check-shas: a reachable SHA passes; an unreachable-but-real SHA fails,
#    naming the body section that carries it; a SHA that isn't a real object
#    fails the same way; a body naming no SHA passes; --head overrides the
#    ancestry target; a GitHub blob permalink to an unreachable SHA is
#    skipped (it names a tree/blob object, not a commit assertion) while a
#    commit permalink of the same SHA is still flagged, even sharing a line
#    with the blob form.
#  - --head without --check-shas is an argument error.
#  - --check-shas outside a git checkout is an argument error, not a crash.
#  - a perl-less host cannot proceed at all, exit 2 (not 1, not a silent 0).
#  - --body-file checks a local body and issues no `gh` call at all; it
#    accepts any readable non-directory path, `/dev/null` included; a path
#    that does not exist, a directory, or a path under an unreadable ancestor
#    (issue #623, depths 1 and 2) each keep their own diagnostic.
#  - argument errors exit 2.
#  - the mock refuses every write-verb spelling and a non-`api` subcommand.
#  - every retained check is proven load-bearing by a mutation probe: a copy
#    of the script with that check's logic removed/short-circuited must turn
#    its own fixture the wrong way.
set -euo pipefail
export LANG=C LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK_SH="$SCRIPT_DIR/../scripts/check-test-steps.sh"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/check-test-steps-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

BIN="$WORK/bin"; CASES="$WORK/cases"; OUT="$WORK/out"; BODIES="$WORK/bodies"
mkdir -p "$BIN" "$CASES" "$OUT" "$BODIES"

REPO="test-org/test-repo"
PR=42

fail=0
report(){ echo "FAIL: $*" >&2; fail=1; }

# ---------------------------------------------------------------------------
# Bodies.
# ---------------------------------------------------------------------------
cat > "$BODIES/clean.md" <<'MD'
## Summary

Closes #1

## Suggested Test Steps

1. `bash .claude/skills/github-workflow/tests/test_check_manifest.sh` — expected: exit 0
2. `grep -n 'end of the log' .claude/skills/github-workflow/references/templates/implementer.md` — expected: one hit

## Verified expectation

`n/a`.
MD

# ---------------------------------------------------------------------------
# Fixture dirs + mock.
# ---------------------------------------------------------------------------
mkcase(){ # mkcase <name> <body-file>
  local d="$CASES/$1"
  mkdir -p "$d"
  jq -n --rawfile b "$2" '{body:$b}' > "$d/pull.json"
  echo "$d"
}

cat > "$BIN/gh" <<'MOCKGH'
#!/usr/bin/env bash
set -euo pipefail
if [ -z "${MOCK_GH_FIXTURES:-}" ] || [ -z "${MOCK_GH_CALLS:-}" ]; then
  echo "UNMOCKED-CONTEXT: $*" >> "${MOCK_GH_CALLS:-/dev/stderr}"
  echo "mock gh: invoked without the harness env" >&2
  exit 1
fi
echo "gh $*" >> "$MOCK_GH_CALLS"
if [ "${1:-}" = "repo" ] && [ "${2:-}" = "view" ]; then
  echo "mock gh: repo view should not be called when --repo is passed" >&2
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
  echo "mock gh: refusing non-GET method ($method) on $endpoint" >&2
  exit 1
fi
case "$endpoint" in
  repos/*/pulls/*)
    if [ -n "$jq_expr" ]; then jq -c -r "$jq_expr" "$MOCK_GH_FIXTURES/pull.json"
    else cat "$MOCK_GH_FIXTURES/pull.json"; fi ;;
  *) echo "mock gh: unrouted endpoint: $endpoint" >&2; exit 1 ;;
esac
MOCKGH
chmod +x "$BIN/gh"
CALLS="$WORK/gh-calls.log"; : > "$CALLS"

run(){ # run <case-dir> <label> [args…]
  local d="$1" label="$2"; shift 2
  RUN_OUT="$OUT/$label.out"; RUN_ERR="$OUT/$label.err"; RC=0
  MOCK_GH_FIXTURES="$d" MOCK_GH_CALLS="$CALLS" PATH="$BIN:$PATH" \
    bash "${SCRIPT_UNDER_TEST:-$CHECK_SH}" "$@" > "$RUN_OUT" 2> "$RUN_ERR" || RC=$?
}
expect_rc(){
  if [ "$RC" -ne "$2" ]; then
    report "$1: expected exit $2, got $RC"
    sed 's/^/    /' "$RUN_OUT" >&2; sed 's/^/    err: /' "$RUN_ERR" >&2
  fi
}
expect_out(){
  if ! grep -qF -- "$2" "$RUN_OUT"; then
    report "$1: expected stdout containing '$2'"
    sed 's/^/    /' "$RUN_OUT" >&2
  fi
}

D_CLEAN="$(mkcase clean "$BODIES/clean.md")"

# ===========================================================================
# Argument errors — through the mock, so a regressed guard cannot reach a
# real `gh`.
# ===========================================================================
run_argerr(){
  local label="$1"; shift
  local rc=0
  MOCK_GH_FIXTURES="$D_CLEAN" MOCK_GH_CALLS="$CALLS" PATH="$BIN:$PATH" \
    bash "$CHECK_SH" "$@" > "$OUT/$label.out" 2> "$OUT/$label.err" || rc=$?
  [ "$rc" -eq 2 ] || report "$label: expected exit 2, got $rc"
}
run_argerr argerr-none
run_argerr argerr-nonnumeric abc --repo "$REPO"
run_argerr argerr-flag "$PR" --repo "$REPO" --nope
run_argerr argerr-extra "$PR" 43 --repo "$REPO"
run_argerr argerr-bodyfile --body-file "$WORK/nope.md"
grep -qF -- "--body-file does not exist" "$OUT/argerr-bodyfile.err" \
  || report "argerr-bodyfile: a path that does not exist must keep its own diagnostic"

# A directory satisfies both `-e` and `-r`, so it slips past the guard those
# two alone provide and reaches the unguarded `cp`, which fails under `set -e`
# and exits 1 instead of 2, an argument error, unless it is rejected
# explicitly with its own diagnostic naming the path.
mkdir -p "$WORK/bodydir"
run_argerr argerr-bodyfile-dir --body-file "$WORK/bodydir"
grep -qF -- "$WORK/bodydir" "$OUT/argerr-bodyfile-dir.err" \
  || report "argerr-bodyfile-dir: expected a diagnostic naming the directory path"

# A readable non-regular file and an empty regular file both reach the "no
# check performed" answer rather than dying on the argument guard, which is
# what a `-f` test did to /dev/null and to a process substitution.
: > "$WORK/empty.md"
for path in /dev/null "$WORK/empty.md"; do
  label="bodyfile-empty-$(basename "$path")"
  run "$D_CLEAN" "$label" --body-file "$path"
  expect_rc "$label" 0
  expect_out "$label" "no check performed"
done
run "$D_CLEAN" bodyfile-procsub --body-file <(cat "$BODIES/clean.md")
expect_rc bodyfile-procsub 0

# --body-file checks a local body and issues no gh call at all.
: > "$CALLS"
run "$D_CLEAN" bodyfile --body-file "$BODIES/clean.md"
expect_rc bodyfile 0
if [ -s "$CALLS" ]; then
  report "bodyfile: --body-file issued a gh call; it must read local disk only"
  sed 's/^/    /' "$CALLS" >&2
fi

# ===========================================================================
# A perl-less host cannot proceed at all (--check-shas's 40-hex extraction
# needs a per-match loop GNU sed cannot express), and that is an argument
# error (exit 2), not this script's "finding" code (exit 1) or a silent 0 —
# every other cannot-proceed condition here already exits 2, and a perl-less
# host that misreports as "no findings" (were this exit 0) makes any caller
# branching on the exit code trust a check that never ran. The guard fires
# unconditionally, before --check-shas is even parsed, so a perl-less host is
# refused even on a plain, no-flags invocation. PATH is stripped of every
# perl binary rather than shadowed, so the guard's own `command -v perl`
# genuinely finds none.
# A flattened, single-directory PATH built from symlinks to every executable
# on the real PATH except any named `perl`/`perl5*` — removing whole
# directories instead would also remove `bash` itself wherever it happens to
# share a directory with `perl` (as it commonly does), turning "perl is
# absent" into "bash is absent" and testing nothing.
# ===========================================================================
NOPERL_DIR="$WORK/noperl-bin"
mkdir -p "$NOPERL_DIR"
IFS=: read -ra _pathdirs <<< "$PATH"
for _d in "${_pathdirs[@]}"; do
  [ -d "$_d" ] || continue
  for _f in "$_d"/*; do
    [ -x "$_f" ] || continue
    _b="$(basename -- "$_f")"
    case "$_b" in perl|perl5*) continue ;; esac
    [ -e "$NOPERL_DIR/$_b" ] || ln -s "$_f" "$NOPERL_DIR/$_b"
  done
done
NOPERL_PATH="$BIN:$NOPERL_DIR"
rc=0
MOCK_GH_FIXTURES="$D_CLEAN" MOCK_GH_CALLS="$CALLS" PATH="$NOPERL_PATH"   bash "$CHECK_SH" --body-file "$BODIES/clean.md" > "$OUT/noperl.out" 2> "$OUT/noperl.err" || rc=$?
if [ "$rc" -ne 2 ]; then
  report "noperl: expected exit 2 (argument error) on a perl-less host, got $rc"
  sed 's/^/    /' "$OUT/noperl.err" >&2
fi
grep -qF "perl is required" "$OUT/noperl.err"   || report "noperl: expected the perl-required diagnostic, got: $(cat "$OUT/noperl.err")"

# ===========================================================================
# issue #623: an unreadable ANCESTOR directory is a permission problem, not
# absence — `[ -e ]` returns false on EACCES exactly like it does on a
# genuinely missing path, so the naive guard misreports it. Skipped when
# running as root, where chmod 000 grants nothing to test against.
# ===========================================================================
if [ "$(id -u)" -ne 0 ]; then
  mkdir -p "$WORK/noxdir"
  chmod 000 "$WORK/noxdir"
  run_argerr argerr-bodyfile-noxancestor --body-file "$WORK/noxdir/body.md"
  grep -qF -- "unreadable directory" "$OUT/argerr-bodyfile-noxancestor.err" \
    || report "argerr-bodyfile-noxancestor: expected a permission diagnostic naming the unreadable ancestor, got: $(cat "$OUT/argerr-bodyfile-noxancestor.err")"
  grep -qF -- "$WORK/noxdir" "$OUT/argerr-bodyfile-noxancestor.err" \
    || report "argerr-bodyfile-noxancestor: expected the diagnostic to name the ancestor directory"
  if grep -qF -- "does not exist" "$OUT/argerr-bodyfile-noxancestor.err"; then
    report "argerr-bodyfile-noxancestor: reported absence instead of a permission problem"
  fi
  chmod 755 "$WORK/noxdir"
else
  echo "SKIP: argerr-bodyfile-noxancestor (running as root — chmod 000 grants nothing to probe)"
fi

# ===========================================================================
# issue #623, depth 2: the inaccessible ancestor is a GRANDparent, not the
# immediate parent — a body path two levels under a `chmod 000` directory.
# `[ -e ]` is false on every level beneath the wall, not just the wall
# itself, so a walk that gives up on the first failed `-e` (rather than
# climbing past it) reports "does not exist" here exactly as it would for a
# genuinely missing path — the depth-1 case above cannot tell the two apart,
# since there the wall and the immediate parent are the same directory.
# ===========================================================================
if [ "$(id -u)" -ne 0 ]; then
  mkdir -p "$WORK/noxgrandparent/child"
  chmod 000 "$WORK/noxgrandparent"
  run_argerr argerr-bodyfile-noxgrandparent --body-file "$WORK/noxgrandparent/child/body.md"
  grep -qF -- "unreadable directory" "$OUT/argerr-bodyfile-noxgrandparent.err" \
    || report "argerr-bodyfile-noxgrandparent: expected a permission diagnostic naming the unreadable ancestor, got: $(cat "$OUT/argerr-bodyfile-noxgrandparent.err")"
  grep -qF -- "$WORK/noxgrandparent" "$OUT/argerr-bodyfile-noxgrandparent.err" \
    || report "argerr-bodyfile-noxgrandparent: expected the diagnostic to name the grandparent directory, not just its unreadable child"
  if grep -qF -- "does not exist" "$OUT/argerr-bodyfile-noxgrandparent.err"; then
    report "argerr-bodyfile-noxgrandparent: reported absence instead of a permission problem two levels up"
  fi
  chmod 755 "$WORK/noxgrandparent"
else
  echo "SKIP: argerr-bodyfile-noxgrandparent (running as root — chmod 000 grants nothing to probe)"
fi

# ===========================================================================
# The mock refuses every write verb and a non-`api` subcommand.
# ===========================================================================
for spelling in "-X POST" "--method PATCH" "-XPOST" "--method=DELETE"; do
  rc=0
  # shellcheck disable=SC2086
  MOCK_GH_FIXTURES="$D_CLEAN" MOCK_GH_CALLS="$CALLS" PATH="$BIN:$PATH" \
    gh api $spelling "repos/$REPO/pulls/$PR" >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || report "mock accepted a write verb ($spelling)"
done
rc=0
MOCK_GH_FIXTURES="$D_CLEAN" MOCK_GH_CALLS="$CALLS" PATH="$BIN:$PATH" \
  gh pr edit "$PR" >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || report "mock accepted a non-api subcommand (gh pr edit)"

if grep -q 'UNMOCKED-CONTEXT' "$CALLS"; then
  report "a gh invocation reached the mock without the harness env — some case was not hermetic"
fi

# ===========================================================================
# issue #640: --check-shas. Real, throwaway git repo — there is no mocking
# `git merge-base`/`git cat-file` the way `gh` is mocked, same rationale as
# test_check_reviewer_commits.sh's git fixtures. GIT_CEILING_DIRECTORIES pins
# discovery to this one repo so an ambient parent repo (if $TMPDIR ever sat
# inside one) can never be walked into by mistake.
# ===========================================================================
SHA_REPO="$WORK/sharepo"
mkdir -p "$SHA_REPO"
git -C "$SHA_REPO" init -q
git -C "$SHA_REPO" config user.email a@example.invalid
git -C "$SHA_REPO" config user.name test
git -C "$SHA_REPO" checkout -q -b main
git -C "$SHA_REPO" commit -q -m base --allow-empty
BASE_SHA=$(git -C "$SHA_REPO" rev-parse HEAD)
git -C "$SHA_REPO" checkout -q -b other-branch
git -C "$SHA_REPO" commit -q -m other --allow-empty
OTHER_SHA=$(git -C "$SHA_REPO" rev-parse HEAD)
git -C "$SHA_REPO" checkout -q main
git -C "$SHA_REPO" commit -q -m head --allow-empty
HEAD_SHA=$(git -C "$SHA_REPO" rev-parse HEAD)
UNREAL_SHA=$(printf '%040d' 1)

run_sha(){ # run_sha <case-dir> <label> [args…] — like run(), but cwd'd into
           # SHA_REPO and with git-repo discovery pinned to it, since
           # --check-shas is a real `git` operation, never mocked.
  local d="$1" label="$2"; shift 2
  RUN_OUT="$OUT/$label.out"; RUN_ERR="$OUT/$label.err"; RC=0
  ( cd "$SHA_REPO" \
    && MOCK_GH_FIXTURES="$d" MOCK_GH_CALLS="$CALLS" PATH="$BIN:$PATH" \
       GIT_CEILING_DIRECTORIES="$SHA_REPO" \
       bash "${SCRIPT_UNDER_TEST:-$CHECK_SH}" "$@" ) > "$RUN_OUT" 2> "$RUN_ERR" || RC=$?
}

# AC1 — a reachable SHA (the branch point, an ancestor of HEAD) passes.
# shellcheck disable=SC2016  # fixture body text: literal backticks, not shell.
printf '## Suggested Test Steps\n\n1. `git log --oneline -1` — expected: some output\n\n## Rollback\n\ngit revert %s\n' \
  "$BASE_SHA" > "$BODIES/sha-reachable.md"
run_sha "$D_CLEAN" sha-reachable --body-file "$BODIES/sha-reachable.md" --check-shas
expect_rc sha-reachable 0
expect_out sha-reachable "reachable from HEAD"

# AC1 — an unreachable-but-real SHA (a sibling branch, never merged) fails,
# naming the Rollback section that carries it.
# shellcheck disable=SC2016  # fixture body text: literal backticks, not shell.
printf '## Suggested Test Steps\n\n1. `git log --oneline -1` — expected: some output\n\n## Rollback\n\ngit revert %s\n' \
  "$OTHER_SHA" > "$BODIES/sha-unreachable.md"
run_sha "$D_CLEAN" sha-unreachable --body-file "$BODIES/sha-unreachable.md" --check-shas
expect_rc sha-unreachable 1
expect_out sha-unreachable "STALE-SHA Rollback"
expect_out sha-unreachable "$OTHER_SHA"

# AC1 — a SHA that is not a real object at all fails the same way.
# shellcheck disable=SC2016  # fixture body text: literal backticks, not shell.
printf '## Suggested Test Steps\n\n1. `git log --oneline -1` — expected: some output\n\n## Rollback\n\ngit revert %s\n' \
  "$UNREAL_SHA" > "$BODIES/sha-unreal.md"
run_sha "$D_CLEAN" sha-unreal --body-file "$BODIES/sha-unreal.md" --check-shas
expect_rc sha-unreal 1
expect_out sha-unreal "STALE-SHA Rollback"

# AC2 — a body naming no SHA at all still passes with --check-shas.
run_sha "$D_CLEAN" sha-none --body-file "$BODIES/clean.md" --check-shas
expect_rc sha-none 0

# --check-shas is opt-in: the same unreachable-SHA body, WITHOUT the flag,
# is not checked at all and passes — this is the discriminating proof that
# the removal of NAMES/PATTERNS left --check-shas itself untouched: a body
# guaranteed to fail WITH the flag must still pass WITHOUT it.
run_sha "$D_CLEAN" sha-unreachable-noflag --body-file "$BODIES/sha-unreachable.md"
expect_rc sha-unreachable-noflag 0
expect_out sha-unreachable-noflag "no check performed"

# The same proof again with a PR fetched through the mocked gh API rather
# than --body-file, so the ordinary (non-file) invocation path is covered
# too: an unreachable SHA in the mocked PR body still passes when
# --check-shas is omitted.
D_SHA_UNREACHABLE="$(mkcase sha-unreachable "$BODIES/sha-unreachable.md")"
run_sha "$D_SHA_UNREACHABLE" sha-unreachable-pr-noflag "$PR" --repo "$REPO"
expect_rc sha-unreachable-pr-noflag 0
expect_out sha-unreachable-pr-noflag "no check performed"
# And the same PR-mode fetch WITH --check-shas does find it — proving the
# skip above is really about the flag, not about PR-mode being unable to see
# the SHA at all.
run_sha "$D_SHA_UNREACHABLE" sha-unreachable-pr-checkshas "$PR" --repo "$REPO" --check-shas
expect_rc sha-unreachable-pr-checkshas 1
expect_out sha-unreachable-pr-checkshas "STALE-SHA Rollback"

# --head overrides the ancestry target: OTHER_SHA is its own ancestor, and
# HEAD_SHA (main's tip) is NOT reachable from the diverged other-branch tip.
run_sha "$D_CLEAN" sha-head-override-pass --body-file "$BODIES/sha-unreachable.md" --check-shas --head "$OTHER_SHA"
expect_rc sha-head-override-pass 0
# shellcheck disable=SC2016  # fixture body text: literal backticks, not shell.
printf '## Suggested Test Steps\n\n1. `git log --oneline -1` — expected: some output\n\n## Rollback\n\ngit revert %s\n' \
  "$HEAD_SHA" > "$BODIES/sha-headsha.md"
run_sha "$D_CLEAN" sha-head-override-fail --body-file "$BODIES/sha-headsha.md" --check-shas --head "$OTHER_SHA"
expect_rc sha-head-override-fail 1

# A blob permalink to an unreachable SHA is skipped, not flagged: it names a
# tree/blob object (the "/blob/<sha>/path" shape a sibling PR's own
# mutation-probe demonstration takes), not an author's commit assertion, and
# it is the shape that will go permanently unreachable the moment a sibling
# PR square-merges — normal history hygiene, not staleness.
# shellcheck disable=SC2016  # fixture body text: literal backticks, not shell.
printf '## Suggested Test Steps\n\n1. `git log --oneline -1` — expected: some output\n\n## Rollback\n\nSee https://github.com/o/r/blob/%s/path/to/file.md for context.\n' \
  "$OTHER_SHA" > "$BODIES/sha-blob-permalink.md"
run_sha "$D_CLEAN" sha-blob-permalink --body-file "$BODIES/sha-blob-permalink.md" --check-shas
expect_rc sha-blob-permalink 0

# The same unreachable SHA in a commit permalink (not a blob permalink) is
# still flagged: only the blob shape is narrowed.
# shellcheck disable=SC2016  # fixture body text: literal backticks, not shell.
printf '## Suggested Test Steps\n\n1. `git log --oneline -1` — expected: some output\n\n## Rollback\n\nSee https://github.com/o/r/commit/%s for context.\n' \
  "$OTHER_SHA" > "$BODIES/sha-commit-permalink.md"
run_sha "$D_CLEAN" sha-commit-permalink --body-file "$BODIES/sha-commit-permalink.md" --check-shas
expect_rc sha-commit-permalink 1
expect_out sha-commit-permalink "STALE-SHA Rollback"

# The narrowing must be scoped to the MATCHED OCCURRENCE, not the line: a
# line carrying BOTH forms of the same unreachable SHA — the blob form and
# the commit form — still reports STALE-SHA, because the blob form's
# presence must not suppress the separate, genuine commit-permalink
# assertion sharing its line (issue found in round-1 review).
# shellcheck disable=SC2016  # fixture body text: literal backticks, not shell.
printf '## Suggested Test Steps\n\n1. `git log --oneline -1` — expected: some output\n\n## Rollback\n\nSee https://github.com/o/r/blob/%s/f.md and https://github.com/o/r/commit/%s for context.\n' \
  "$OTHER_SHA" "$OTHER_SHA" > "$BODIES/sha-blob-and-commit-combined.md"
run_sha "$D_CLEAN" sha-blob-and-commit-combined --body-file "$BODIES/sha-blob-and-commit-combined.md" --check-shas
expect_rc sha-blob-and-commit-combined 1
expect_out sha-blob-and-commit-combined "STALE-SHA Rollback"

# --head without --check-shas is an argument error.
run_argerr argerr-head-without-checkshas --body-file "$BODIES/clean.md" --head "$BASE_SHA"

# --check-shas outside a git checkout is an argument error, not a crash.
NOGIT_DIR="$WORK/nogit"
mkdir -p "$NOGIT_DIR"
rc=0
( cd "$NOGIT_DIR" && GIT_CEILING_DIRECTORIES="$NOGIT_DIR" \
    MOCK_GH_FIXTURES="$D_CLEAN" MOCK_GH_CALLS="$CALLS" PATH="$BIN:$PATH" \
    bash "$CHECK_SH" --body-file "$BODIES/clean.md" --check-shas ) \
  > "$OUT/checkshas-nogit.out" 2> "$OUT/checkshas-nogit.err" || rc=$?
[ "$rc" -eq 2 ] || report "checkshas-nogit: expected exit 2 outside a git checkout, got $rc"

if grep -q 'UNMOCKED-CONTEXT' "$CALLS"; then
  report "a gh invocation reached the mock without the harness env during the --check-shas cases — not hermetic"
fi

# ===========================================================================
# Mutation probes: each retained check proven load-bearing. Removing or
# short-circuiting one must turn its own fixture the wrong way — a check
# whose only proof is a passing test is not known to be the thing that
# catches it. `bash -n` first so a failure cannot be a syntax artifact.
# ===========================================================================
mutate_literal(){ # mutate_literal <out-file> <old-literal> <new-literal>
  local out="$1" old="$2" new="$3"
  MUTATE_OLD="$old" MUTATE_NEW="$new" perl -0777 -pe \
    's/\Q$ENV{MUTATE_OLD}\E/$ENV{MUTATE_NEW}/' "$CHECK_SH" > "$out"
  bash -n "$out" || report "mutate_literal($out): mutant fails bash -n — not a valid probe"
}

# issue #640's ancestry check, proven load-bearing: with `git merge-base
# --is-ancestor` short-circuited to always succeed, the unreachable-SHA
# fixture must go green — a reachability check whose only proof is a passing
# test is not known to be checking reachability at all.
SHA_MUTANT="$WORK/mutant-sha-ancestor.sh"
# shellcheck disable=SC2016  # literal perl source in single quotes, not shell expansion
mutate_literal "$SHA_MUTANT" \
  '|| ! git merge-base --is-ancestor "$shatext" "$HEAD_REF" 2>/dev/null; then' \
  '|| false; then'
if cmp -s "$SHA_MUTANT" "$CHECK_SH"; then
  report "mutation probe 'sha-ancestor': mutate_literal changed nothing — the ancestry check moved"
else
  SCRIPT_UNDER_TEST="$SHA_MUTANT" run_sha "$D_CLEAN" probe-sha-ancestor --body-file "$BODIES/sha-unreachable.md" --check-shas
  if [ "$RC" -eq 0 ]; then
    echo "PASS: mutation probe sha-ancestor (without the ancestry check, an unreachable SHA is reported reachable)"
  else
    report "mutation probe 'sha-ancestor': short-circuiting ancestry did not turn the unreachable-SHA fixture green (rc $RC)"
    sed 's/^/    /' "$RUN_OUT" >&2
  fi
fi

# The perl guard, proven load-bearing: removing it entirely must let a
# perl-less host reach the (now-crashing, since --check-shas's extraction
# needs perl) rest of the script instead of being refused up front with a
# clean exit 2 — a guard whose only proof is a passing test is not known to
# be the one enforced. Run WITHOUT --check-shas: the guard fires
# unconditionally, before the flag is even parsed, so this proves it is not
# accidentally gated behind --check-shas.
PERLGUARD_MUTANT="$WORK/mutant-perlguard.sh"
mutate_literal "$PERLGUARD_MUTANT" \
  '  || argerr "perl is required: --check-shas'"'"'s 40-hex SHA extraction needs a per-match loop GNU sed cannot express"' \
  '  || true'
if cmp -s "$PERLGUARD_MUTANT" "$CHECK_SH"; then
  report "mutation probe 'perlguard': mutate_literal changed nothing — the guard moved"
else
  rc=0
  MOCK_GH_FIXTURES="$D_CLEAN" MOCK_GH_CALLS="$CALLS" PATH="$NOPERL_PATH" \
    bash "$PERLGUARD_MUTANT" --body-file "$BODIES/clean.md" > "$OUT/probe-perlguard.out" 2> "$OUT/probe-perlguard.err" || rc=$?
  if [ "$rc" -eq 0 ]; then
    echo "PASS: mutation probe perlguard (without the guard, a perl-less host silently passes a no-flags invocation instead of being refused)"
  else
    report "mutation probe 'perlguard': removing the guard did not reproduce a silent pass (rc $rc)"
    sed 's/^/    /' "$OUT/probe-perlguard.err" >&2
  fi
fi

# The blob-permalink narrowing, proven load-bearing: with the occurrence
# check removed entirely, the blob-permalink-only fixture (harmless, the
# shape a sibling PR's own mutation-probe demonstration takes) must go red
# — a narrowing whose only proof is a passing test is not known to be doing
# anything.
BLOB_MUTANT="$WORK/mutant-blob-skip.sh"
# shellcheck disable=SC2016  # literal perl source in single quotes, not shell expansion
mutate_literal "$BLOB_MUTANT"   'next if $prefix =~ m{/blob/\z};'   '1;'
if cmp -s "$BLOB_MUTANT" "$CHECK_SH"; then
  report "mutation probe 'blob-skip': mutate_literal changed nothing — the narrowing moved"
else
  SCRIPT_UNDER_TEST="$BLOB_MUTANT" run_sha "$D_CLEAN" probe-blob-skip --body-file "$BODIES/sha-blob-permalink.md" --check-shas
  if [ "$RC" -eq 1 ] && grep -qF "STALE-SHA" "$RUN_OUT"; then
    echo "PASS: mutation probe blob-skip (without the narrowing, a blob permalink to a sibling PR's pre-squash head reports STALE-SHA)"
  else
    report "mutation probe 'blob-skip': removing the narrowing did not turn the blob-permalink fixture red (rc $RC)"
    sed 's/^/    /' "$RUN_OUT" >&2
  fi
fi

# The occurrence-scoping itself, proven load-bearing the other direction
# (round-1 review finding F1): reverting the per-occurrence prefix check to
# a per-LINE test — does this line contain `/blob/<the same SHA>` ANYWHERE
# — reproduces the exact false negative the finding was filed on: the
# combined-form fixture (both a blob and a commit permalink of the same
# unreachable SHA, on one line) must go clean (rc 0) instead of reporting
# STALE-SHA, because the blob form anywhere on the line wrongly suppresses
# the separate commit-permalink occurrence too.
BLOB_SCOPE_MUTANT="$WORK/mutant-blob-skip-scope.sh"
# shellcheck disable=SC2016  # literal perl source in single quotes, not shell expansion
mutate_literal "$BLOB_SCOPE_MUTANT"   'next if $prefix =~ m{/blob/\z};'   'next if $_ =~ m{/blob/\Q$match\E};'
if cmp -s "$BLOB_SCOPE_MUTANT" "$CHECK_SH"; then
  report "mutation probe 'blob-skip-scope': mutate_literal changed nothing — the occurrence check moved"
else
  SCRIPT_UNDER_TEST="$BLOB_SCOPE_MUTANT" run_sha "$D_CLEAN" probe-blob-skip-scope --body-file "$BODIES/sha-blob-and-commit-combined.md" --check-shas
  if [ "$RC" -eq 0 ]; then
    echo "PASS: mutation probe blob-skip-scope (line-scoped instead of occurrence-scoped, a commit permalink sharing a line with a blob permalink of the same SHA goes unreported)"
  else
    report "mutation probe 'blob-skip-scope': reverting to line-scoping did not reproduce the F1 false negative (rc $RC)"
    sed 's/^/    /' "$RUN_OUT" >&2
  fi
fi

# issue #623's ancestor-EACCES diagnostic, proven the same way: with
# find_inaccessible_ancestor's own detection short-circuited to "never
# found", the unreadable-ancestor case must regress to the old, misleading
# "does not exist" diagnostic. Skipped when running as root for the same
# reason the case above is.
if [ "$(id -u)" -ne 0 ]; then
  ANCESTOR_MUTANT="$WORK/mutant-ancestor.sh"
  # shellcheck disable=SC2016  # literal perl source in single quotes, not shell expansion
  mutate_literal "$ANCESTOR_MUTANT" \
    'find_inaccessible_ancestor(){' \
    'find_inaccessible_ancestor(){ return 1;'
  if cmp -s "$ANCESTOR_MUTANT" "$CHECK_SH"; then
    report "mutation probe 'ancestor-eacces': mutate_literal changed nothing — the function moved"
  else
    mkdir -p "$WORK/noxdir2"
    chmod 000 "$WORK/noxdir2"
    rc=0
    SCRIPT_UNDER_TEST="$ANCESTOR_MUTANT" bash "$ANCESTOR_MUTANT" \
      --body-file "$WORK/noxdir2/body.md" > "$OUT/probe-ancestor.out" 2> "$OUT/probe-ancestor.err" || rc=$?
    chmod 755 "$WORK/noxdir2"
    if [ "$rc" -eq 2 ] && grep -qF "does not exist" "$OUT/probe-ancestor.err"; then
      echo "PASS: mutation probe ancestor-eacces (without the ancestor check, an unreadable directory misreports as absence)"
    else
      report "mutation probe 'ancestor-eacces': short-circuiting the check did not reproduce the misdiagnosis (rc $rc)"
      sed 's/^/    /' "$OUT/probe-ancestor.err" >&2
    fi
  fi
else
  echo "SKIP: mutation probe ancestor-eacces (running as root)"
fi

# issue #623, depth 2: the depth-1 fixture alone cannot distinguish the fixed
# walk from the original bug, since at depth 1 the wall IS the immediate
# parent and both versions climb no further before finding it. Restoring the
# original `else return 1` — give up on the first failed `-e` instead of
# climbing past it — must leave the depth-1 case passing (proving this probe
# is not just a blunter copy of the one above) while turning the depth-2
# fixture's correct permission diagnostic into the old, wrong "does not
# exist".
if [ "$(id -u)" -ne 0 ]; then
  ANCESTOR_MUTANT2="$WORK/mutant-ancestor-depth2.sh"
  # shellcheck disable=SC2016  # literal shell source in single quotes, not shell expansion
  mutate_literal "$ANCESTOR_MUTANT2"     'if [ -e "$dir" ] && [ ! -x "$dir" ]; then
      printf '"'"'%s'"'"' "$dir"
      return 0
    fi'     'if [ -e "$dir" ]; then
      if [ ! -x "$dir" ]; then
        printf '"'"'%s'"'"' "$dir"
        return 0
      fi
    else
      return 1
    fi'
  if cmp -s "$ANCESTOR_MUTANT2" "$CHECK_SH"; then
    report "mutation probe 'ancestor-eacces-depth2': mutate_literal changed nothing — the walk moved"
  else
    mkdir -p "$WORK/noxdir3"
    chmod 000 "$WORK/noxdir3"
    rc=0
    SCRIPT_UNDER_TEST="$ANCESTOR_MUTANT2" bash "$ANCESTOR_MUTANT2"       --body-file "$WORK/noxdir3/body.md" > "$OUT/probe-ancestor-depth2-d1.out" 2> "$OUT/probe-ancestor-depth2-d1.err" || rc=$?
    chmod 755 "$WORK/noxdir3"
    if [ "$rc" -ne 2 ] || ! grep -qF "unreadable directory" "$OUT/probe-ancestor-depth2-d1.err"; then
      report "mutation probe 'ancestor-eacces-depth2': the depth-1 case regressed too (rc $rc) — this probe is not isolating depth 2"
      sed 's/^/    /' "$OUT/probe-ancestor-depth2-d1.err" >&2
    fi
    mkdir -p "$WORK/noxgrandparent2/child"
    chmod 000 "$WORK/noxgrandparent2"
    rc=0
    SCRIPT_UNDER_TEST="$ANCESTOR_MUTANT2" bash "$ANCESTOR_MUTANT2"       --body-file "$WORK/noxgrandparent2/child/body.md" > "$OUT/probe-ancestor-depth2-d2.out" 2> "$OUT/probe-ancestor-depth2-d2.err" || rc=$?
    chmod 755 "$WORK/noxgrandparent2"
    if [ "$rc" -eq 2 ] && grep -qF "does not exist" "$OUT/probe-ancestor-depth2-d2.err"; then
      echo "PASS: mutation probe ancestor-eacces-depth2 (giving up on the first failed -e misreports a chmod'd GRANDparent as absence, while depth 1 stays correct)"
    else
      report "mutation probe 'ancestor-eacces-depth2': the depth-2 fixture did not regress to the absence misdiagnosis (rc $rc)"
      sed 's/^/    /' "$OUT/probe-ancestor-depth2-d2.err" >&2
    fi
  fi
else
  echo "SKIP: mutation probe ancestor-eacces-depth2 (running as root)"
fi

# The --check-shas gate itself, proven load-bearing in the removal direction:
# with the `if [ "$CHECK_SHAS" -eq 1 ]` wrapper's condition forced true, the
# unreachable-SHA fixture must fail even WITHOUT the flag — proving the gate
# (not some other accident) is what keeps a no-flags invocation from ever
# reading the body's SHAs at all.
GATE_MUTANT="$WORK/mutant-checkshas-gate.sh"
# shellcheck disable=SC2016  # literal shell source in single quotes, not shell expansion
mutate_literal "$GATE_MUTANT" 'if [ "$CHECK_SHAS" -eq 1 ]; then' 'if true; then'
if cmp -s "$GATE_MUTANT" "$CHECK_SH"; then
  report "mutation probe 'checkshas-gate': mutate_literal changed nothing — the gate moved"
else
  SCRIPT_UNDER_TEST="$GATE_MUTANT" run_sha "$D_CLEAN" probe-checkshas-gate --body-file "$BODIES/sha-unreachable.md"
  if [ "$RC" -eq 1 ] && grep -qF "STALE-SHA" "$RUN_OUT"; then
    echo "PASS: mutation probe checkshas-gate (forcing the check on unconditionally, a no-flags call now reports the unreachable SHA it should have skipped)"
  else
    report "mutation probe 'checkshas-gate': forcing the gate on did not make the no-flags call report the SHA (rc $RC)"
    sed 's/^/    /' "$RUN_OUT" >&2
  fi
fi

if [ "$fail" -ne 0 ]; then
  echo "test_check_test_steps: FAILED" >&2
  exit 1
fi
echo "test_check_test_steps: all assertions passed"
