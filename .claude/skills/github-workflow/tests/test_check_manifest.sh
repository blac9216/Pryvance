#!/usr/bin/env bash
# test_check_manifest.sh — fixture-driven regression test for check-manifest.sh.
# Follows this directory's harness conventions (see tests/README.md): a mocked
# `gh` on PATH serving fixture JSON from a private mktemp scratch dir, refusing
# every non-GET verb, with no real network call reachable from any case —
# including the argument-error cases, which route through the same mock so a
# regressed guard cannot fall through to a real authenticated `gh` (#477). The
# mock marks any invocation arriving without the harness env as
# UNMOCKED-CONTEXT, asserted absent at the end.
#
# Pinned to LANG=C / LC_ALL=C: the manifest text under test carries em dashes
# and the script's own comparisons are byte comparisons, so the collation must
# not depend on the invoking shell's locale.
#
# Covers, one fixture per case (the five the issue names, plus the corners each
# check has of its own):
#  - a well-formed manifest passes every check, exit 0, with the manifest
#    comment reached only on page 2 of the comment list — a read that dropped
#    `--paginate` would report "no manifest" instead.
#  - a manifest omitting a required field bullet fails `fields` naming it.
#  - a **Command** entry the raw log never echoes fails `commands` — the
#    reviewer's check 3 condition 3 case, where the log names the command only
#    in a prose section header.
#  - a **Log SHA-256** that does not match the log on disk fails `digest`; an
#    absent one fails `fields` and `digest` both, since there is nothing to
#    recompute against.
#  - an **Env** quoting a look-alike rather than the testing doc's Declaration
#    fails `env-quote`, and the diagnostic names WHICH look-alike was quoted —
#    the "suites are not required" sentence and the conditional lint-state
#    phrase are separate cases, because "the wrong one" is the whole finding.
#  - a stale **Head SHA**, an unexpanded `<scratch>` placeholder in **Raw log**,
#    a footer missing one of the seven canonical keys, and a footer whose
#    digest disagrees with the visible bullet each fail their own check.
#  - a footer that is present but does not parse as JSON fails `footer` and
#    SKIPs `footer-agree` — never a PASS on an agreement it never established
#    (#596).
#  - **Exit code** carrying fewer or more entries than **Command**, and a
#    manifest where the two fields agree with each other but the raw log's own
#    `[exit=N]` marker count does not, each fail `exit-count`; `--markdown`
#    renders the mismatch as a table row (#602).
#  - the three **Exit code** shapes the field spec defines after the owner
#    ruling of 2026-09-04 (#651): a sub-bullet list counts by line (annotated
#    or not), a bare inline list with no annotation counts by comma, and a
#    field that is annotated AND inline is reported as a manifest defect rather
#    than parsed. The defect fixtures include the two shapes that defeated the
#    old inline parser — annotation prose carrying a comma followed by a digit
#    ("lines 7, 9, 12") and by a digit then a paren ("ranges 2, 3 (inclusive)")
#    — each of which the old rule counted as exactly right and PASSed, so their
#    FAIL here can only come from the refusal to parse.
#  - a `<log>.exits` sidecar that exists but cannot be read falls back to the
#    bounded scan and is named in the diagnostic, rather than aborting the run
#    at exit 2 and truncating every check after it.
#  - a log whose first command's own OUTPUT is an `[exit=99]` line — the worked
#    example in implementer.md — does not FAIL `exit-count`: the cross-check
#    reads the `<log>.exits` sidecar, or the bounded per-command scan when no
#    sidecar sits beside the log, never a whole-file `grep -c` (#539, #602).
#  - a command echoed in the log but carrying no `[exit=N]` of its own before
#    the next command fails `commands`; a log with no exit markers anywhere is
#    reported as not-checkable rather than failed, since only the recipe's
#    runner guarantees them.
#  - a log that is not on this disk SKIPs `digest`/`commands` and exits 3, not
#    0 — a cloud-posted manifest gets every check that does not need the file,
#    and "could not verify" stays distinguishable from "verified" by exit
#    status alone (#589).
#  - a log that echoes its commands BARE (no `$ `/`+ `/`> ` prompt) has the next
#    command as the marker scan's boundary, so an entry with no `[exit=N]` of
#    its own is not credited with a later command's marker.
#  - a **Command** sub-bullet carrying two code spans is reported with its
#    backticks balanced, and the skip diagnostic pluralises (#589).
#  - **Lint state** is required exactly when the testing doc carries a
#    conditional-linter sentence, and reported `n/a` when it does not.
#  - a testing.md 404 is a fact, not a failure: `env-quote` reports n/a, exit 0.
#  - bolded / em-dash-separated bullets (`- **Raw log** — …`) resolve the same
#    as the canonical unbolded colon form, the drift real manifests show.
#  - a manifest quoted inside a fenced code block never outranks the real one.
#  - `--round N` selects that round; the default selects the highest round.
#  - argument errors and a PR with no manifest exit 2, never 1: "this run could
#    not be performed" is a different answer from "the manifest is bad".
#  - every check above is load-bearing: a throwaway copy of the script with the
#    one guard line neutered turns the matching fixture green, and the case
#    asserts it does.
set -euo pipefail
export LANG=C LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK_SH="$SCRIPT_DIR/../scripts/check-manifest.sh"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/check-manifest-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

BIN="$WORK/bin"; LOGS="$WORK/logs"; CASES="$WORK/cases"; OUT="$WORK/out"
mkdir -p "$BIN" "$LOGS" "$CASES" "$OUT"

REPO="test-org/test-repo"
PR=42
HEAD_SHA="deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
OLD_SHA="0123456789abcdef0123456789abcdef01234567"

fail=0
report(){ echo "FAIL: $*" >&2; fail=1; }

# ---------------------------------------------------------------------------
# A real raw log, written by the same runner shape implementer.md's recipe
# documents: each command echoed as `$ <cmd>`, its output, then its own
# `[exit=N]` marker. The hash checks below are therefore genuine.
# ---------------------------------------------------------------------------
GOOD_LOG="$LOGS/test-r0.log"
{
  printf '$ grep -c "no suites" docs/process/testing.md\n1\n[exit=0]\n'
  printf '$ command -v markdownlint markdownlint-cli2\n[exit=1]\n'
} > "$GOOD_LOG"
GOOD_SHA=$(sha256sum "$GOOD_LOG" | awk '{print $1}')

# A log whose second command is named only in a prose section header — the
# exact shape evidence-paths.md check 3 condition 3 calls out.
PROSE_LOG="$LOGS/test-r0-prose.log"
{
  printf '$ grep -c "no suites" docs/process/testing.md\n1\n[exit=0]\n'
  printf '=== command -v markdownlint markdownlint-cli2 ===\n[exit=1]\n'
} > "$PROSE_LOG"
PROSE_SHA=$(sha256sum "$PROSE_LOG" | awk '{print $1}')

# A log that echoes both commands but records an exit marker for only the
# first: the runner died, or was never the recipe's.
PARTIAL_LOG="$LOGS/test-r0-partial.log"
{
  printf '$ grep -c "no suites" docs/process/testing.md\n1\n[exit=0]\n'
  printf '$ command -v markdownlint markdownlint-cli2\n'
} > "$PARTIAL_LOG"
PARTIAL_SHA=$(sha256sum "$PARTIAL_LOG" | awk '{print $1}')

# A log from a runner that records no exit markers at all.
NOMARK_LOG="$LOGS/test-r0-nomark.log"
printf '$ grep -c "no suites" docs/process/testing.md\n1\n' > "$NOMARK_LOG"
NOMARK_SHA=$(sha256sum "$NOMARK_LOG" | awk '{print $1}')

# A log from a runner that echoes each command BARE — no `$ `/`+ `/`> ` prompt,
# which the header documents as valid and the echo test accepts. `echo one` has
# no `[exit=N]` of its own: the only marker credited to it belongs to `echo
# two`. A marker scan whose only boundary is a prompt-prefixed line finds no
# boundary here at all, runs past `echo two`, and credits `echo one` with that
# marker — a false PASS on the one check this script exists for. A second,
# spurious `[exit=]` line at the end sits after every command, so neither the
# per-command scan nor the fixture's own boundary rule can reach it. (It was
# added when `exit-count` cross-checked a whole-file marker TOTAL; that
# cross-check now reads the bounded per-command scan, which reports the same
# missing marker `commands` does, so this fixture FAILs both checks for the one
# defect it exists to catch — and goes green on both under the probe below.)
BARE_LOG="$LOGS/test-r0-bare.log"
printf 'echo one\none\necho two\ntwo\n[exit=0]\n[exit=0]\n' > "$BARE_LOG"
BARE_SHA=$(sha256sum "$BARE_LOG" | awk '{print $1}')

# A log whose command list carries a backslash escape. `tr '\n' ' '` is an
# ordinary command, but awk expands escapes in a `-v` assignment, so passing an
# entry that way makes it unmatchable against the log's literal line — an honest
# manifest reported as unechoed. The entry reaches awk through ENVIRON instead,
# and this fixture is what holds it there.
ESCAPE_LOG="$LOGS/test-r0-escape.log"
{
  printf '$ grep -c "no suites" docs/process/testing.md\n1\n[exit=0]\n'
  printf "$ tr '\\\\n' ' ' < docs/process/testing.md | grep -c 'no suites'\n1\n[exit=0]\n"
} > "$ESCAPE_LOG"
ESCAPE_SHA=$(sha256sum "$ESCAPE_LOG" | awk '{print $1}')

WRONG_SHA="0000000000000000000000000000000000000000000000000000000000000000"

# ---------------------------------------------------------------------------
# The testing doc the manifests are arbitrated against — carrying all three
# sentences this repo's own doc carries, since telling them apart is the whole
# point of the env-quote check.
# ---------------------------------------------------------------------------
TESTING_MD="$WORK/testing.md"
cat > "$TESTING_MD" <<'MD'
# Testing

This repository is a content/holding area: no test suites and no CI checks are required
on PRs.

## Command

Declaration: **no suites — review-only.** This repository names no canonical suite
command by design.

## Test

- If `markdownlint` is on `PATH`, run it against the changed `.md` files.
- If neither is installed, say so explicitly: "not installed — review-only".
MD

# A second testing doc with no declaration and no conditional linter, for the
# n/a branches of env-quote and lint-state.
TESTING_PLAIN="$WORK/testing-plain.md"
printf '# Testing\n\nRun the project suite.\n' > "$TESTING_PLAIN"

# ---------------------------------------------------------------------------
# manifest <case> — a well-formed manifest body on stdout. Callers edit the
# result with sed/grep -v rather than re-typing it, so every defective fixture
# differs from the good one by exactly the defect it is named for.
# ---------------------------------------------------------------------------
good_manifest(){
  local log="$1" sha="$2" head="$3"
  cat <<MANIFEST
## Test Evidence — round 0
- Command:
  - \`grep -c "no suites" docs/process/testing.md\`
  - \`command -v markdownlint markdownlint-cli2\`
- Env: Linux 6.1; \`docs/process/testing.md\` L8 declares: "no suites — review-only."
- Head SHA: \`$head\`
- Exit code:
  - 0
  - 1 (expected — \`command -v\` probe, neither linter installed)
- Results: 2 commands, 0 unexpected failures
- Log SHA-256: \`$sha\`
- Raw log: \`$log\`
- Lint state: not installed — review-only
- Coverage: none — testing doc has no coverage section

<!-- evidence {"issue":503,"round":0,"head":"$head","exit":0,"log":"$log","sha256":"$sha","command":"grep -c \"no suites\" docs/process/testing.md; command -v markdownlint markdownlint-cli2"} -->
MANIFEST
}

# ---------------------------------------------------------------------------
# set_exit <src> <dst> — rewrite <src>'s **Exit code** field, the replacement
# block read from stdin (a `- Exit code:` header plus any sub-bullets), and drop
# whatever sub-bullets the source carried. Every Exit code fixture below is
# built this way rather than re-typed, so each differs from `good` by that field
# alone — and since `good` now carries the annotated sub-bullet form the spec
# requires, a fixture wanting the inline form has to say so explicitly.
# ---------------------------------------------------------------------------
set_exit(){
  local src="$1" dst="$2" blk="$WORK/exit-block"
  cat > "$blk"
  awk -v blk="$blk" '
    /^- (\*\*)?Exit code/ {
      while ((getline l < blk) > 0) print l
      close(blk); inx = 1; next
    }
    inx && /^[ \t]+- / { next }
    { inx = 0; print }' "$src" > "$dst"
}

# ---------------------------------------------------------------------------
# set_results <src> <dst> — rewrite <src>'s **Results** field to the value read
# from stdin (one physical line). Uses awk rather than sed so a value carrying
# backticks, quotes or slashes (a command entry quoted back into Results, for
# the #629 fixtures) needs no shell-level escaping at the call site.
# ---------------------------------------------------------------------------
set_results(){
  local src="$1" dst="$2" val
  val=$(cat)
  awk -v val="$val" '{ if ($0 ~ /^- Results:/) print "- Results: " val; else print }' "$src" > "$dst"
}

# ---------------------------------------------------------------------------
# mkcase <name> <manifest-file> [testing-md] [created-at] — a fixture dir for
# one case. The manifest lands on comment page 2 and page 1 carries a decoy
# manifest inside a fenced code block plus an unrelated review comment, so
# every case proves both the pagination and the fence-stripping at the same
# time. `created-at` defaults to a moment after the 2026-09-04 owner ruling
# (#657/#651) so every ordinary fixture reads as a present-day, post-ruling
# manifest by default; only the historical-manifest case (#657) below passes
# an earlier one explicitly.
# ---------------------------------------------------------------------------
mkcase(){
  local name="$1" manifest="$2" testing="${3:-$TESTING_MD}" created="${4:-2026-09-04T20:00:00Z}"
  local d="$CASES/$name"
  mkdir -p "$d"
  printf '{"state":"open","draft":false,"mergeable":true,"head":{"sha":"%s"}}\n' "$HEAD_SHA" > "$d/pull.json"

  local decoy="$WORK/decoy.md"
  cat > "$decoy" <<'DECOY'
Here is what a manifest looks like:

```
## Test Evidence — round 9
- Raw log: `/nowhere/decoy.log`
- Log SHA-256: `feedfacefeedfacefeedfacefeedfacefeedfacefeedfacefeedfacefeedface`
```
DECOY
  jq -n --rawfile b "$decoy" \
    '[{body:$b, html_url:"https://example.invalid/pr/42#issuecomment-1", created_at:"2026-01-01T00:00:00Z"}]' \
    > "$d/comments_page1.json"
  jq -n --rawfile b "$manifest" --arg created "$created" \
    '[{body:$b, html_url:"https://example.invalid/pr/42#issuecomment-2", created_at:$created}]' \
    > "$d/comments_page2.json"
  jq -n --rawfile c "$testing" '{content:($c|@base64)}' > "$d/testing.json"
  echo "$d"
}

# ---------------------------------------------------------------------------
# The mock. Routes the three endpoints check-manifest.sh calls, applies the
# script's own --jq with the real jq, refuses any non-GET verb, and logs every
# invocation — marking one that arrives without the harness env, which is how a
# regressed guard trying to reach the real `gh` becomes a named assertion
# failure rather than a network call.
# ---------------------------------------------------------------------------
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
endpoint=""; jq_expr=""; method="GET"; paginate=0
while [ $# -gt 0 ]; do
  case "$1" in
    --paginate) paginate=1; shift ;;
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
apply(){ if [ -n "$jq_expr" ]; then jq -c -r "$jq_expr" "$1"; else cat "$1"; fi }
case "$endpoint" in
  repos/*/pulls/*)
    apply "$MOCK_GH_FIXTURES/pull.json" ;;
  repos/*/issues/*/comments\?per_page=100)
    apply "$MOCK_GH_FIXTURES/comments_page1.json"
    [ "$paginate" -eq 1 ] && apply "$MOCK_GH_FIXTURES/comments_page2.json"
    : ;;
  repos/*/contents/docs/process/testing.md)
    if [ -f "$MOCK_GH_FIXTURES/testing.json" ]; then
      apply "$MOCK_GH_FIXTURES/testing.json"
    else
      echo "gh: Not Found (HTTP 404)" >&2
      exit 1
    fi ;;
  *)
    echo "mock gh: unrouted endpoint: $endpoint" >&2
    exit 1 ;;
esac
MOCKGH
chmod +x "$BIN/gh"
CALLS="$WORK/gh-calls.log"; : > "$CALLS"

# run <case-dir> <label> [extra args…] — runs the script under the mock,
# capturing stdout/stderr to files so a crash mid-run does not race the EXIT
# cleanup trap. Sets RC/RUN_OUT for the caller.
# #748: --lint is now mandatory. Every fixture in this suite is arbitrated against
# this repository's own testing.md, which carries a conditional-linter sentence, so
# --lint installed is the correct default for every case that does not test --lint
# itself; a case that does (e.g. the not-installed / missing-flag fixtures below) passes
# its own --lint after "$@", which — since the argument parser lets a later --lint win —
# overrides this default.
run(){
  local d="$1" label="$2"; shift 2
  RUN_OUT="$OUT/$label.out"
  RC=0
  MOCK_GH_FIXTURES="$d" MOCK_GH_CALLS="$CALLS" PATH="$BIN:$PATH" \
    bash "${SCRIPT_UNDER_TEST:-$CHECK_SH}" "$PR" --repo "$REPO" --lint installed "$@" \
    > "$RUN_OUT" 2> "$OUT/$label.err" || RC=$?
}

# expect_line <label> <substring> — the run's stdout carries it.
expect_line(){
  if ! grep -qF -- "$2" "$RUN_OUT"; then
    report "$1: expected output containing '$2'"
    sed 's/^/    /' "$RUN_OUT" >&2; sed 's/^/    err: /' "$OUT/$1.err" >&2
  fi
}
expect_rc(){
  if [ "$RC" -ne "$2" ]; then
    report "$1: expected exit $2, got $RC"
    sed 's/^/    /' "$RUN_OUT" >&2; sed 's/^/    err: /' "$OUT/$1.err" >&2
  fi
}

# ===========================================================================
# Case: a well-formed manifest.
# ===========================================================================
good_manifest "$GOOD_LOG" "$GOOD_SHA" "$HEAD_SHA" > "$WORK/good.md"
D_GOOD="$(mkcase good "$WORK/good.md")"
run "$D_GOOD" good
expect_rc good 0
for c in fields footer footer-agree head log-path digest commands env-quote lint-state exit-count; do
  expect_line good "PASS $c"
done
expect_line good "2 Command entries, 2 Exit code entries (sub-bullet list), 2 log [exit=N] markers — all three counts agree"
expect_line good "all 2 entries echoed verbatim, each with its own [exit=N]"
expect_line good "round 0 manifest"
grep -q 'issuecomment-2' "$RUN_OUT" || report "good: reported the decoy comment's URL, not the real manifest's"
if grep -q 'round 9' "$RUN_OUT"; then
  report "good: the fenced decoy manifest outranked the real one"
fi

# ===========================================================================
# Case: a required field bullet absent. Results is chosen deliberately — no
# other check reads it, so this fixture fails on `fields` ALONE, which is what
# lets the mutation probe below prove that check load-bearing.
# ===========================================================================
grep -v '^- Results:' "$WORK/good.md" > "$WORK/missing-field.md"
D_MISSING="$(mkcase missing-field "$WORK/missing-field.md")"
run "$D_MISSING" missing-field
expect_rc missing-field 1
expect_line missing-field "FAIL fields"
expect_line missing-field "Results"

# A bullet that is present but empty is a different defect and says so.
sed 's/^- Results:.*/- Results:/' "$WORK/good.md" > "$WORK/empty-field.md"
D_EMPTY="$(mkcase empty-field "$WORK/empty-field.md")"
run "$D_EMPTY" empty-field
expect_rc empty-field 1
expect_line empty-field "bullet present but carries no value"

# ===========================================================================
# Case: a Command entry the log names only in a prose section header.
# ===========================================================================
sed -e "s#$GOOD_LOG#$PROSE_LOG#g" -e "s#$GOOD_SHA#$PROSE_SHA#g" "$WORK/good.md" > "$WORK/unechoed.md"
D_UNECHOED="$(mkcase unechoed "$WORK/unechoed.md")"
run "$D_UNECHOED" unechoed
expect_rc unechoed 1
expect_line unechoed "FAIL commands"
expect_line unechoed "the log does not echo: command -v markdownlint markdownlint-cli2"
expect_line unechoed "PASS digest"

# ===========================================================================
# Case: a stated digest that does not match the log on disk.
# ===========================================================================
sed "s/$GOOD_SHA/$WRONG_SHA/g" "$WORK/good.md" > "$WORK/wrong-hash.md"
D_WRONG="$(mkcase wrong-hash "$WORK/wrong-hash.md")"
run "$D_WRONG" wrong-hash
expect_rc wrong-hash 1
expect_line wrong-hash "FAIL digest"
expect_line wrong-hash "recomputed $GOOD_SHA != stated $WRONG_SHA"

# A digest that is not 64 lowercase hex at all.
sed "s/$GOOD_SHA/ABC123/g" "$WORK/good.md" > "$WORK/short-hash.md"
D_SHORT="$(mkcase short-hash "$WORK/short-hash.md")"
run "$D_SHORT" short-hash
expect_rc short-hash 1
expect_line short-hash "not 64 lowercase hex characters"

# ===========================================================================
# Case: Env quoting a look-alike instead of the Declaration. Both look-alikes
# get their own case, and each asserts the diagnostic names which one.
# ===========================================================================
sed "s|^- Env:.*|- Env: Linux 6.1; docs/process/testing.md L3-4: 'no test suites and no CI checks are required on PRs.'|" \
  "$WORK/good.md" > "$WORK/lookalike-required.md"
D_LK1="$(mkcase lookalike-required "$WORK/lookalike-required.md")"
run "$D_LK1" lookalike-required
expect_rc lookalike-required 1
expect_line lookalike-required "FAIL env-quote"
expect_line lookalike-required "suites are not required"

sed "s|^- Env:.*|- Env: Linux 6.1; docs/process/testing.md says 'not installed — review-only'.|" \
  "$WORK/good.md" > "$WORK/lookalike-lint.md"
D_LK2="$(mkcase lookalike-lint "$WORK/lookalike-lint.md")"
run "$D_LK2" lookalike-lint
expect_rc lookalike-lint 1
expect_line lookalike-lint "conditional lint-state phrase"

# ===========================================================================
# Case: a stale Head SHA — the reviewer's check 1.
# ===========================================================================
sed "s/$HEAD_SHA/$OLD_SHA/g" "$WORK/good.md" > "$WORK/stale.md"
D_STALE="$(mkcase stale "$WORK/stale.md")"
run "$D_STALE" stale
expect_rc stale 1
expect_line stale "FAIL head"
expect_line stale "stale manifest, re-run and re-post"

# ===========================================================================
# Case: an unexpanded placeholder in Raw log.
# ===========================================================================
sed "s#$GOOD_LOG#/tmp/<scratch>/evidence/issue503/test-r0.log#g" "$WORK/good.md" > "$WORK/placeholder.md"
D_PH="$(mkcase placeholder "$WORK/placeholder.md")"
run "$D_PH" placeholder
expect_rc placeholder 1
expect_line placeholder "FAIL log-path"
expect_line placeholder "unexpanded placeholder"

# ===========================================================================
# Case: footer defects — a missing key, and a digest disagreeing with the
# visible bullet.
# ===========================================================================
sed 's/"issue":503,//' "$WORK/good.md" > "$WORK/footer-keys.md"
D_FK="$(mkcase footer-keys "$WORK/footer-keys.md")"
run "$D_FK" footer-keys
expect_rc footer-keys 1
expect_line footer-keys "FAIL footer"
expect_line footer-keys "expected [command,exit,head,issue,log,round,sha256]"

sed "s/\"sha256\":\"$GOOD_SHA\"/\"sha256\":\"$WRONG_SHA\"/" "$WORK/good.md" > "$WORK/footer-disagree.md"
D_FD="$(mkcase footer-disagree "$WORK/footer-disagree.md")"
run "$D_FD" footer-disagree
expect_rc footer-disagree 1
expect_line footer-disagree "FAIL footer-agree"

grep -v '^<!-- evidence ' "$WORK/good.md" > "$WORK/no-footer.md"
D_NF="$(mkcase no-footer "$WORK/no-footer.md")"
run "$D_NF" no-footer
expect_rc no-footer 1
expect_line no-footer "no '<!-- evidence {…} -->' footer"
expect_line no-footer "SKIP footer-agree"

# A footer that is present but does not parse as JSON (#596): footer-agree
# must SKIP, never fall through and PASS on an agreement it never established
# — this manifest also has no visible Head SHA/Raw log/Log SHA-256 bullets
# below the footer's own comparison would use, which is exactly the shape
# that let it silently compare "" against "" before the fix.
# The braces stay intact (the outer `\{.*\}` extractor still matches, so
# FOOTER is non-empty), but the content inside is not valid JSON (an unquoted
# key) — the shape that must land in the malformed-JSON branch, not the
# no-footer one.
sed -E 's/"issue":503,/issue:503,/' "$WORK/good.md" > "$WORK/bad-json-footer.md"
D_BJF="$(mkcase bad-json-footer "$WORK/bad-json-footer.md")"
run "$D_BJF" bad-json-footer
expect_rc bad-json-footer 1
expect_line bad-json-footer "FAIL footer       footer is present but does not parse as JSON"
expect_line bad-json-footer "SKIP footer-agree"
if grep -qF 'PASS footer-agree' "$RUN_OUT"; then
  report "bad-json-footer: reported PASS footer-agree on an unparseable footer it never compared"
fi

# The exact shape #596 was filed against: an unparseable footer AND no visible
# Head SHA/Raw log/Log SHA-256 bullets, so a guardless footer-agree compares
# "" against "" three times and prints a false PASS. Used only by the mutation
# probe below — the main case above already covers the ordinary shape (footer
# unparseable, bullets present).
sed -e '/^- Head SHA:/d' -e '/^- Raw log:/d' -e '/^- Log SHA-256:/d' \
    "$WORK/bad-json-footer.md" > "$WORK/bad-json-footer-no-bullets.md"
D_BJFNB="$(mkcase bad-json-footer-no-bullets "$WORK/bad-json-footer-no-bullets.md")"

# ===========================================================================
# Case: exit-count (#602) — an Exit code list shorter than Command's, the
# short-list case the issue names, and one where the raw log's own [exit=N]
# marker count disagrees even though the two fields agree with each other.
# ===========================================================================
# The short-list case: Command names 2 entries, Exit code names only 1 — the
# PR #530 finding, reproduced directly.
set_exit "$WORK/good.md" "$WORK/exit-short.md" <<<'- Exit code: 0'
D_XSHORT="$(mkcase exit-short "$WORK/exit-short.md")"
run "$D_XSHORT" exit-short
expect_rc exit-short 1
expect_line exit-short "FAIL exit-count"
expect_line exit-short "Command lists 2 entries, Exit code lists 1 (bare inline list) — counts disagree"

# The same shortfall on the sub-bullet path, which is the shape the spec now
# requires of every annotated field: one line for two commands. Counting lines
# has no separator to get wrong, but it still has to be compared.
set_exit "$WORK/good.md" "$WORK/exit-sub-short.md" <<'SUBSHORT'
- Exit code:
  - 0
SUBSHORT
D_XSUBSHORT="$(mkcase exit-sub-short "$WORK/exit-sub-short.md")"
run "$D_XSUBSHORT" exit-sub-short
expect_rc exit-sub-short 1
expect_line exit-sub-short "Command lists 2 entries, Exit code lists 1 (sub-bullet list) — counts disagree"

# The longer-list half of the same AC: Exit code names 3 entries for 2 Command
# entries.
set_exit "$WORK/good.md" "$WORK/exit-long.md" <<<'- Exit code: 0, 1, 0'
D_XLONG="$(mkcase exit-long "$WORK/exit-long.md")"
run "$D_XLONG" exit-long
expect_rc exit-long 1
expect_line exit-long "FAIL exit-count"
expect_line exit-long "Command lists 2 entries, Exit code lists 3 (bare inline list) — counts disagree"

# The two fields agree with each other (2 and 2) but the raw log carries only
# one [exit=N] marker — the marker cross-check the field-vs-field comparison
# alone cannot catch.
sed -e "s#$GOOD_LOG#$PARTIAL_LOG#g" -e "s#$GOOD_SHA#$PARTIAL_SHA#g" \
    "$WORK/good.md" > "$WORK/exit-marker-mismatch.md"
D_XMM="$(mkcase exit-marker-mismatch "$WORK/exit-marker-mismatch.md")"
run "$D_XMM" exit-marker-mismatch
expect_rc exit-marker-mismatch 1
expect_line exit-marker-mismatch "FAIL exit-count"
expect_line exit-marker-mismatch "agree with each other, but the log carries 1 [exit=N] marker(s) — disagreement with the raw log"

# --markdown renders the mismatch as a table row a reviewer can paste, without
# changing the plain-text report above it.
rc=0
MOCK_GH_FIXTURES="$D_XSHORT" MOCK_GH_CALLS="$CALLS" PATH="$BIN:$PATH" \
  bash "$CHECK_SH" "$PR" --repo "$REPO" --lint installed --markdown \
  > "$OUT/exit-short-markdown.out" 2> "$OUT/exit-short-markdown.err" || rc=$?
[ "$rc" -eq 1 ] || report "exit-short-markdown: expected exit 1, got $rc"
grep -qF 'FAIL exit-count' "$OUT/exit-short-markdown.out" \
  || report "exit-short-markdown: --markdown dropped the plain-text report"
grep -qF '| Status | Check | Detail |' "$OUT/exit-short-markdown.out" \
  || report "exit-short-markdown: --markdown did not render a table"
grep -qE '\| FAIL \| exit-count \| Command lists 2 entries, Exit code lists 1' "$OUT/exit-short-markdown.out" \
  || report "exit-short-markdown: --markdown table did not surface the exit-count mismatch"

# ===========================================================================
# Case: the three Exit code shapes the field spec now defines (#602, #651).
# Per the owner ruling of 2026-09-04 the field is written one entry per
# sub-bullet as soon as any entry carries an annotation; a bare list with no
# annotation may stay inline. So there are exactly three outcomes to cover:
# sub-bullets count by line, a bare inline list counts by comma, and a field
# that is annotated AND inline is a manifest defect that is reported rather
# than parsed. Each fixture below differs from `good` by its Exit code field
# ALONE.
#
# Every defect fixture here is chosen so that the OLD parser counted it
# correctly — two entries for two commands, exit 0. That is deliberate: it
# means the FAIL each one now asserts can only come from the defect branch,
# not from a count that happens to disagree for some other reason. A fixture
# that would fail either way proves nothing about the branch it is named for,
# which is how the last three rounds each shipped green past a live defect.
# ===========================================================================
# shellcheck disable=SC2016  # manifest text: literal backticks and $, not shell.
inline_case(){ # inline_case <label> <exit-code-value> <expected-rc> [created-at]
  local label="$1" line="$2" want="$3" created="${4:-}"
  set_exit "$WORK/good.md" "$WORK/$label.md" <<<"- Exit code: $line"
  if cmp -s "$WORK/$label.md" "$WORK/good.md"; then
    report "$label: the Exit code substitution changed nothing"
    return 0
  fi
  # CASE_DIR is a global, and the call site never wraps this in `$( )`: a
  # command substitution would run `run`/`report` in a subshell, where neither
  # RUN_OUT nor the suite's `fail` flag survives to the caller.
  if [ -n "$created" ]; then
    CASE_DIR="$(mkcase "$label" "$WORK/$label.md" "$TESTING_MD" "$created")"
  else
    CASE_DIR="$(mkcase "$label" "$WORK/$label.md")"
  fi
  run "$CASE_DIR" "$label"
  expect_rc "$label" "$want"
}

# --- the bare inline list: no annotation, so every comma is a separator -----
inline_case exit-inline-bare '0, 1' 0
expect_line exit-inline-bare "2 Exit code entries (bare inline list)"

# Spaces around the separators, and none at all — both are the same bare list.
inline_case exit-inline-bare-spaced '0 ,  1' 0
D_BARE_SPACED="$CASE_DIR"
expect_line exit-inline-bare-spaced "2 Exit code entries (bare inline list)"

# The aggregate form: annotated in appearance, but it is the whole field rather
# than an entry in a list, so it stays inline and is recognised before the
# bare/annotated test.
inline_case exit-aggregate '0 (every command above)' 0
expect_line exit-aggregate "aggregate form"

# --- annotated AND inline: a defect, reported rather than parsed -----------
# The parenthesised form `good` itself used to carry, verbatim. The old parser
# counted it as 2 for 2 commands and PASSed, so this fixture's FAIL is the
# defect branch and nothing else.
# shellcheck disable=SC2016  # manifest text / sed script: literal backticks and $, not shell.
inline_case exit-annot-paren \
  '0, 1 (expected — `command -v` probe, neither linter installed)' 1
expect_line exit-annot-paren "FAIL exit-count"
expect_line exit-annot-paren "annotated and written inline"
expect_line exit-annot-paren "one entry per sub-bullet"

# The shortest annotated inline value there is: one comma, one dash-introduced
# word. A naive comma count reads it as exactly 2 entries for 2 commands, so it
# is the fixture the two mutation probes below use — neutering either guard
# makes it green, which is what proves each guard is what turns this shape into
# a FAIL. Every other defect fixture would stay red under those mutants for the
# unrelated reason that its prose commas inflate the naive count.
inline_case exit-annot-1comma '0, 1 — expected' 1
D_ANNOT_INLINE="$CASE_DIR"
expect_line exit-annot-1comma "FAIL exit-count"
expect_line exit-annot-1comma "annotated and written inline"

# The em-dash form, verbatim from implementer.md's own **Exit code** bullet as
# it read before the ruling.
inline_case exit-annot-emdash \
  '0, 1 — grep with no matches, which is the result the Coverage field states' 1
expect_line exit-annot-emdash "annotated and written inline"

# ROUND 3, FINDING 1 — the blocker that spent this PR's round cap, reproduced
# literally. Annotation prose carrying a comma followed by a DIGIT: the old
# `is_entry()` read `7,` and `9,` as entry boundaries, counted 2 for a
# 2-command manifest, and PASSed — while the field names ONE entry, so the
# entry for the command that exited 1 was simply absent and the run read clean.
# That is verbatim #602's failure mode. Under the ruling it is not counted at
# all: it is annotated and inline, so it is a defect.
inline_case exit-r3-digit-comma '0 — clean, lines 7, 9, 12 matched' 1
expect_line exit-r3-digit-comma "annotated and written inline"

# The same finding's paren half: a digit followed by `(`, which the old rule
# also read as a boundary. Identically a defect now.
inline_case exit-r3-digit-paren '0 — clean, ranges 2, 3 (inclusive) apply' 1
expect_line exit-r3-digit-paren "annotated and written inline"

# Round 3, note 2: an UNPAIRED backtick in annotation prose. The old scanner
# stayed inside a code span for the rest of the value and swallowed the
# separator after it, a false FAIL on a manifest that was not short. There is
# no span scanner left to get stuck — the value is annotated and inline, which
# is the defect, and the verdict no longer depends on reading its prose.
inline_case exit-annot-unpaired-backtick '0, 1 — the ` character is literal' 1
expect_line exit-annot-unpaired-backtick "annotated and written inline"

# A code span carrying a comma, and a span fenced by more than one backtick
# carrying a backtick of its own — the shapes that drove rounds 1 and 2. Both
# are annotations, so both are the same defect, and neither is parsed.
# shellcheck disable=SC2016  # manifest text / sed script: literal backticks and $, not shell.
inline_case exit-annot-span '0, 1 — `grep -E "a,b"` found no match' 1
expect_line exit-annot-span "annotated and written inline"
# shellcheck disable=SC2016  # manifest text / sed script: literal backticks and $, not shell.
inline_case exit-annot-wide-span \
  '0 — ``a ` backtick, inside a span``, 1 — expected, neither linter installed' 1
expect_line exit-annot-wide-span "annotated and written inline"

# A genuinely short annotated list: one entry for two commands. It is reported
# as the defect rather than as a short list — the shape is refused before any
# count is attempted, which is the whole point of the ruling.
inline_case exit-annot-short '0 — clean, no unexpected exits, nothing to report' 1
expect_line exit-annot-short "annotated and written inline"
if grep -qF 'PASS exit-count' "$RUN_OUT"; then
  report "exit-annot-short: PASSed exit-count on an annotated inline field"
fi

# ===========================================================================
# Case: malformed punctuation, not annotation (#660). Each value below is
# accepted by `punct_only` (digits, commas, whitespace only) and rejected by
# `bare_inline` (a leading, trailing or doubled comma) — the same defect
# bucket the old diagnostic mislabelled "annotated". None of these carries any
# prose, so the message must say so, never "annotated".
# ===========================================================================
inline_case exit-punct-trailing '0, 1,' 1
expect_line exit-punct-trailing "FAIL exit-count"
expect_line exit-punct-trailing "a trailing comma"
if grep -qF 'annotated and written inline' "$RUN_OUT"; then
  report "exit-punct-trailing: called an unannotated trailing-comma value 'annotated and written inline'"
fi

inline_case exit-punct-doubled '0,,1' 1
D_PUNCT_DOUBLED="$CASE_DIR"
expect_line exit-punct-doubled "FAIL exit-count"
expect_line exit-punct-doubled "a doubled comma"
if grep -qF 'annotated and written inline' "$RUN_OUT"; then
  report "exit-punct-doubled: called an unannotated doubled-comma value 'annotated and written inline'"
fi

inline_case exit-punct-leading ',0, 1' 1
expect_line exit-punct-leading "FAIL exit-count"
expect_line exit-punct-leading "a leading comma"
if grep -qF 'annotated and written inline' "$RUN_OUT"; then
  report "exit-punct-leading: called an unannotated leading-comma value 'annotated and written inline'"
fi

# The remedy still resolves all three, so the diagnostic keeps pointing to it —
# only the stated REASON changes, per #660.
expect_line exit-punct-leading "one entry per sub-bullet"

# ===========================================================================
# Case: #678 — an unannotated value using a separator OTHER than a comma. None
# of these carry any alphabetic character, so none is annotation prose, and
# the fixed classifier must still call it the punctuation defect rather than
# "annotated and written inline" — the same defect #660 was filed against,
# narrowed to comma shapes rather than eliminated.
# ===========================================================================
inline_case exit-punct-semicolon '0;1' 1
D_PUNCT_SEMI="$CASE_DIR"
expect_line exit-punct-semicolon "FAIL exit-count"
expect_line exit-punct-semicolon "separated by ';'"
if grep -qF 'annotated and written inline' "$RUN_OUT"; then
  report "exit-punct-semicolon: called an unannotated semicolon-separated value 'annotated and written inline'"
fi

inline_case exit-punct-pipe '0|1' 1
expect_line exit-punct-pipe "FAIL exit-count"
expect_line exit-punct-pipe "separated by '|'"
if grep -qF 'annotated and written inline' "$RUN_OUT"; then
  report "exit-punct-pipe: called an unannotated pipe-separated value 'annotated and written inline'"
fi

# Space-separated, no comma at all: the remedy must not name a fixed comma
# shape when the value carries no comma of any kind (#678's second finding).
inline_case exit-punct-spaced '0 1' 1
expect_line exit-punct-spaced "FAIL exit-count"
expect_line exit-punct-spaced "separated by whitespace, with no comma at all"
if grep -qF 'annotated and written inline' "$RUN_OUT"; then
  report "exit-punct-spaced: called an unannotated space-separated value 'annotated and written inline'"
fi
if grep -qF 'a leading comma' "$RUN_OUT" || grep -qF 'a trailing comma' "$RUN_OUT" || grep -qF 'a doubled comma' "$RUN_OUT"; then
  report "exit-punct-spaced: named a comma shape for a value that carries no comma at all"
fi

# A genuinely annotated inline value keeps its existing diagnostic even though
# it also carries a semicolon — the alphabetic prose is what makes it
# annotated, not the presence or absence of a particular punctuation mark.
inline_case exit-annot-semicolon '0; 1 — expected' 1
expect_line exit-annot-semicolon "FAIL exit-count"
expect_line exit-annot-semicolon "annotated and written inline"

# ===========================================================================
# Case: a pre-ruling annotated-inline manifest (#657). Same shape as
# `exit-annot-1comma`, but its comment predates the 2026-09-04 owner ruling
# (`RULING_AT` in check-manifest.sh) — before that PR's own manifest was
# posted, an annotated inline Exit code field was the CORRECT form. The
# checker still FAILs it (arbitrated against today's spec, not a false FAIL —
# see #657's own filing), but the diagnostic must say the manifest is
# historical rather than telling an author of a merged PR to re-post it.
# ===========================================================================
inline_case exit-annot-historical '0, 1 — expected' 1 "2026-09-04T17:10:12Z"
D_ANNOT_HISTORICAL="$CASE_DIR"
expect_line exit-annot-historical "FAIL exit-count"
expect_line exit-annot-historical "annotated and written inline"
expect_line exit-annot-historical "2026-09-04T17:10:12Z"
expect_line exit-annot-historical "historical"
if grep -qF 'Re-post the manifest with one entry per sub-bullet' "$RUN_OUT"; then
  report "exit-annot-historical: told the author of a merged, pre-ruling PR to re-post"
fi

# The same value, same shape, but posted AFTER the ruling: the ordinary
# present-day diagnostic, not the historical one — proves the date is what
# distinguishes the two, not the shape.
inline_case exit-annot-current '0, 1 — expected' 1 "2026-09-04T20:00:00Z"
expect_line exit-annot-current "FAIL exit-count"
expect_line exit-annot-current "Re-post the manifest with one entry per sub-bullet"
if grep -qF 'historical' "$RUN_OUT"; then
  report "exit-annot-current: called a post-ruling manifest historical"
fi

# --- the sub-bullet form, which is what the spec now asks for --------------
# `good` already carries an ANNOTATED sub-bullet list (its second entry names
# the expected non-zero code), so the annotated path is covered by every case
# in this suite. This one is the bare sub-bullet list the recipe's own
# `sed 's/^/  - /' "$LOG.exits"` emits before any annotation is added.
set_exit "$WORK/good.md" "$WORK/exit-sub.md" <<'SUBLIST'
- Exit code:
  - 0
  - 1
SUBLIST
D_XSUB="$(mkcase exit-sub "$WORK/exit-sub.md")"
run "$D_XSUB" exit-sub
expect_rc exit-sub 0
expect_line exit-sub "2 Exit code entries (sub-bullet list)"

# An annotated sub-bullet list whose annotation carries the exact prose that
# defeated every inline parser — commas, digits, parens and a code span. On a
# sub-bullet list an entry is a line, so none of it is reachable by the count.
set_exit "$WORK/good.md" "$WORK/exit-sub-annot.md" <<'SUBANNOT'
- Exit code:
  - 0 — clean, lines 7, 9, 12 matched
  - 1 (expected — `command -v` probe, ranges 2, 3 (inclusive), neither linter installed)
SUBANNOT
D_XSUBA="$(mkcase exit-sub-annot "$WORK/exit-sub-annot.md")"
run "$D_XSUBA" exit-sub-annot
expect_rc exit-sub-annot 0
expect_line exit-sub-annot "2 Exit code entries (sub-bullet list)"

# ===========================================================================
# Case: the phantom `[exit=` line (#602 round 1, finding 2) — implementer.md's
# worked example, where the first command's own OUTPUT is an `[exit=99]` line.
# A whole-file `grep -c '^\[exit='` reports 3 markers for 2 commands and
# false-FAILs an honest manifest; the run's own per-command record reports 2.
# Both sources are covered: the `<log>.exits` sidecar, and — the same log
# without it — the bounded per-command scan.
# ===========================================================================
PHANTOM_LOG="$LOGS/test-r0-phantom.log"
cat > "$PHANTOM_LOG" <<'PHANTOM'
$ printf '[exit=99]\n'
[exit=99]
[exit=0]
$ grep -c "no suites" docs/process/testing.md
1
[exit=0]
PHANTOM
printf '0\n0\n' > "$PHANTOM_LOG.exits"
PHANTOM_SHA=$(sha256sum "$PHANTOM_LOG" | awk '{print $1}')
[ "$(grep -c '^\[exit=' "$PHANTOM_LOG")" -eq 3 ] \
  || report "phantom fixture: the log no longer carries the 3 [exit=-prefixed lines (2 markers + 1 phantom) the case exists for"

# The same log with no sidecar beside it, for the fallback scan.
PHANTOM2_LOG="$LOGS/test-r0-phantom-noside.log"
cp "$PHANTOM_LOG" "$PHANTOM2_LOG"
PHANTOM2_SHA=$(sha256sum "$PHANTOM2_LOG" | awk '{print $1}')

# The manifest for those logs, written out rather than sed-substituted: the
# first Command entry contains `[`, `]` and a backslash escape, none of which
# survive a sed replacement intact.
phantom_manifest(){ # phantom_manifest <log> <sha>
  cat <<PHMAN
## Test Evidence — round 0
- Command:
  - \`printf '[exit=99]\n'\`
  - \`grep -c "no suites" docs/process/testing.md\`
- Env: Linux 6.1; \`docs/process/testing.md\` L8 declares: "no suites — review-only."
- Head SHA: \`$HEAD_SHA\`
- Exit code: 0, 0
- Results: 2 commands, 0 unexpected failures
- Log SHA-256: \`$2\`
- Raw log: \`$1\`
- Lint state: not installed — review-only
- Coverage: none — testing doc has no coverage section

<!-- evidence {"issue":602,"round":0,"head":"$HEAD_SHA","exit":0,"log":"$1","sha256":"$2","command":"printf '[exit=99]\n'; grep -c \"no suites\" docs/process/testing.md"} -->
PHMAN
}
phantom_manifest "$PHANTOM_LOG" "$PHANTOM_SHA" > "$WORK/exit-phantom.md"
D_XPH="$(mkcase exit-phantom "$WORK/exit-phantom.md")"
run "$D_XPH" exit-phantom
expect_rc exit-phantom 0
expect_line exit-phantom "PASS exit-count"
expect_line exit-phantom "sidecar"

phantom_manifest "$PHANTOM2_LOG" "$PHANTOM2_SHA" > "$WORK/exit-phantom-noside.md"
D_XPH2="$(mkcase exit-phantom-noside "$WORK/exit-phantom-noside.md")"
run "$D_XPH2" exit-phantom-noside
expect_rc exit-phantom-noside 0
expect_line exit-phantom-noside "PASS exit-count"
expect_line exit-phantom-noside "bounded per-command scan"

# ===========================================================================
# Case: a `<log>.exits` sidecar that exists but cannot be read (round 2, note
# 6). A reviewer runs this script over another agent's scratch directory on a
# shared host, so this is an ordinary condition rather than a corner. Reading
# it anyway aborts the run under `set -euo pipefail` at exit 2 — the code
# `argerr` reserves for a bad invocation — and every check after `digest`
# vanishes from the report. The run must instead stay whole, fall back to the
# bounded per-command scan, and NAME the unreadable sidecar.
# ===========================================================================
UNREAD_LOG="$LOGS/test-r0-unreadable-sidecar.log"
cp "$GOOD_LOG" "$UNREAD_LOG"
printf '0\n1\n' > "$UNREAD_LOG.exits"
chmod 000 "$UNREAD_LOG.exits"
UNREAD_SHA=$(sha256sum "$UNREAD_LOG" | awk '{print $1}')
D_UNREAD=""
if [ -r "$UNREAD_LOG.exits" ]; then
  # root ignores the mode bits, so the case cannot be built here. Say so rather
  # than asserting something the environment never exercised.
  echo "SKIP: unreadable-sidecar case (this user can read a 000 file — running as root?)"
else
  sed -e "s#$GOOD_LOG#$UNREAD_LOG#g" -e "s#$GOOD_SHA#$UNREAD_SHA#g" \
      "$WORK/good.md" > "$WORK/unreadable-sidecar.md"
  D_UNREAD="$(mkcase unreadable-sidecar "$WORK/unreadable-sidecar.md")"
  run "$D_UNREAD" unreadable-sidecar
  expect_rc unreadable-sidecar 0
  expect_line unreadable-sidecar "PASS exit-count"
  expect_line unreadable-sidecar "is not readable, so it was not used"
  expect_line unreadable-sidecar "bounded per-command scan"
  # The whole report, not a truncated one: the checks that run after this point
  # are all present.
  expect_line unreadable-sidecar "env-quote"
  expect_line unreadable-sidecar "footer"
fi

# ===========================================================================
# Case: the aggregate Exit code form's own claim, arbitrated against the
# sidecar's per-command VALUES (#646). `exit-aggregate` above already covers
# the count-only path (no sidecar, so nothing to arbitrate the claim against);
# these two cover the sidecar-backed path, where the record can be read.
# ===========================================================================
# Honest: every marker really is 0, matching the aggregate form's own claim.
AGG_OK_LOG="$LOGS/test-r0-agg-ok.log"
{
  printf '$ grep -c "no suites" docs/process/testing.md\n1\n[exit=0]\n'
  printf '$ command -v markdownlint markdownlint-cli2\n[exit=0]\n'
} > "$AGG_OK_LOG"
printf '0\n0\n' > "$AGG_OK_LOG.exits"
AGG_OK_SHA=$(sha256sum "$AGG_OK_LOG" | awk '{print $1}')
set_exit "$WORK/good.md" "$WORK/exit-agg-ok-pre.md" <<<"- Exit code: 0 (every command above)"
sed -e "s#$GOOD_LOG#$AGG_OK_LOG#g" -e "s#$GOOD_SHA#$AGG_OK_SHA#g" \
    "$WORK/exit-agg-ok-pre.md" > "$WORK/exit-agg-ok.md"
D_AGG_OK="$(mkcase exit-agg-ok "$WORK/exit-agg-ok.md")"
run "$D_AGG_OK" exit-agg-ok
expect_rc exit-agg-ok 0
expect_line exit-agg-ok "PASS exit-count"

# Dishonest: the field claims "0 (every command above)" but the run's own
# sidecar records a 1 for the second command — the shape #646 was filed
# against, reproduced with a real sidecar rather than asserted in the
# abstract.
AGG_BAD_LOG="$LOGS/test-r0-agg-bad.log"
{
  printf '$ grep -c "no suites" docs/process/testing.md\n1\n[exit=0]\n'
  printf '$ command -v markdownlint markdownlint-cli2\n[exit=1]\n'
} > "$AGG_BAD_LOG"
printf '0\n1\n' > "$AGG_BAD_LOG.exits"
AGG_BAD_SHA=$(sha256sum "$AGG_BAD_LOG" | awk '{print $1}')
set_exit "$WORK/good.md" "$WORK/exit-agg-bad-pre.md" <<<"- Exit code: 0 (every command above)"
sed -e "s#$GOOD_LOG#$AGG_BAD_LOG#g" -e "s#$GOOD_SHA#$AGG_BAD_SHA#g" \
    "$WORK/exit-agg-bad-pre.md" > "$WORK/exit-agg-bad.md"
D_AGG_BAD="$(mkcase exit-agg-bad "$WORK/exit-agg-bad.md")"
run "$D_AGG_BAD" exit-agg-bad
expect_rc exit-agg-bad 1
expect_line exit-agg-bad "FAIL exit-count"
expect_line exit-agg-bad "aggregate form"
expect_line exit-agg-bad "sidecar records: 0, 1"
if grep -qF 'PASS exit-count' "$RUN_OUT"; then
  report "exit-agg-bad: PASSed exit-count on an aggregate claim its own sidecar contradicts"
fi

# ===========================================================================
# Case: #677 — a whitespace- or CR-contaminated all-zero sidecar must not FAIL
# the aggregate value gate, and a malformed (non-numeric or blank) record must
# be reported as malformed, not as a non-zero exit.
# ===========================================================================
# Same log as exit-agg-ok, but the sidecar's zero lines carry a trailing space.
AGG_WS_LOG="$LOGS/test-r0-agg-ws.log"
cp "$AGG_OK_LOG" "$AGG_WS_LOG"
printf '0 \n0\n' > "$AGG_WS_LOG.exits"
AGG_WS_SHA=$(sha256sum "$AGG_WS_LOG" | awk '{print $1}')
sed -e "s#$GOOD_LOG#$AGG_WS_LOG#g" -e "s#$GOOD_SHA#$AGG_WS_SHA#g" \
    "$WORK/exit-agg-ok-pre.md" > "$WORK/exit-agg-ws.md"
D_AGG_WS="$(mkcase exit-agg-ws "$WORK/exit-agg-ws.md")"
run "$D_AGG_WS" exit-agg-ws
expect_rc exit-agg-ws 0
expect_line exit-agg-ws "PASS exit-count"

# The CRLF row from #677's own table: both records are genuinely zero, but the
# sidecar's line endings are `\r\n`.
AGG_CRLF_LOG="$LOGS/test-r0-agg-crlf.log"
cp "$AGG_OK_LOG" "$AGG_CRLF_LOG"
printf '0\r\n0\r\n' > "$AGG_CRLF_LOG.exits"
AGG_CRLF_SHA=$(sha256sum "$AGG_CRLF_LOG" | awk '{print $1}')
sed -e "s#$GOOD_LOG#$AGG_CRLF_LOG#g" -e "s#$GOOD_SHA#$AGG_CRLF_SHA#g" \
    "$WORK/exit-agg-ok-pre.md" > "$WORK/exit-agg-crlf.md"
D_AGG_CRLF="$(mkcase exit-agg-crlf "$WORK/exit-agg-crlf.md")"
run "$D_AGG_CRLF" exit-agg-crlf
expect_rc exit-agg-crlf 0
expect_line exit-agg-crlf "PASS exit-count"

# A non-numeric sidecar record: reported as malformed, never as a non-zero exit.
AGG_NAN_LOG="$LOGS/test-r0-agg-nan.log"
cp "$AGG_OK_LOG" "$AGG_NAN_LOG"
printf '0\nxyz\n' > "$AGG_NAN_LOG.exits"
AGG_NAN_SHA=$(sha256sum "$AGG_NAN_LOG" | awk '{print $1}')
sed -e "s#$GOOD_LOG#$AGG_NAN_LOG#g" -e "s#$GOOD_SHA#$AGG_NAN_SHA#g" \
    "$WORK/exit-agg-ok-pre.md" > "$WORK/exit-agg-nan.md"
D_AGG_NAN="$(mkcase exit-agg-nan "$WORK/exit-agg-nan.md")"
run "$D_AGG_NAN" exit-agg-nan
expect_rc exit-agg-nan 1
expect_line exit-agg-nan "FAIL exit-count"
expect_line exit-agg-nan "not a decimal integer"
expect_line exit-agg-nan "xyz"
expect_line exit-agg-nan "a malformed record"
if grep -qF 'the aggregate form is only correct when every marker really is 0' "$RUN_OUT"; then
  report "exit-agg-nan: called a malformed sidecar record a non-zero exit"
fi

# A blank sidecar line: still FAILs, and still as malformed rather than as a
# non-zero exit.
AGG_BLANK_LOG="$LOGS/test-r0-agg-blank.log"
cp "$AGG_OK_LOG" "$AGG_BLANK_LOG"
printf '0\n\n' > "$AGG_BLANK_LOG.exits"
AGG_BLANK_SHA=$(sha256sum "$AGG_BLANK_LOG" | awk '{print $1}')
sed -e "s#$GOOD_LOG#$AGG_BLANK_LOG#g" -e "s#$GOOD_SHA#$AGG_BLANK_SHA#g" \
    "$WORK/exit-agg-ok-pre.md" > "$WORK/exit-agg-blank.md"
D_AGG_BLANK="$(mkcase exit-agg-blank "$WORK/exit-agg-blank.md")"
run "$D_AGG_BLANK" exit-agg-blank
expect_rc exit-agg-blank 1
expect_line exit-agg-blank "FAIL exit-count"
expect_line exit-agg-blank "<blank>"
expect_line exit-agg-blank "a malformed record"

# A whitespace-only sidecar line (spaces, no CR) — #712 round 2, note 5. The
# `\r`-only strip left this record non-empty but invisible; it must render
# as "<blank>" exactly like the genuinely-empty line above, not as nothing.
AGG_WSONLY_LOG="$LOGS/test-r0-agg-wsonly.log"
cp "$AGG_OK_LOG" "$AGG_WSONLY_LOG"
printf '0\n   \n' > "$AGG_WSONLY_LOG.exits"
AGG_WSONLY_SHA=$(sha256sum "$AGG_WSONLY_LOG" | awk '{print $1}')
sed -e "s#$GOOD_LOG#$AGG_WSONLY_LOG#g" -e "s#$GOOD_SHA#$AGG_WSONLY_SHA#g" \
    "$WORK/exit-agg-ok-pre.md" > "$WORK/exit-agg-wsonly.md"
D_AGG_WSONLY="$(mkcase exit-agg-wsonly "$WORK/exit-agg-wsonly.md")"
run "$D_AGG_WSONLY" exit-agg-wsonly
expect_rc exit-agg-wsonly 1
expect_line exit-agg-wsonly "FAIL exit-count"
expect_line exit-agg-wsonly "<blank>"
expect_line exit-agg-wsonly "a malformed record"

# Mutation check: reverting note 5's fix (stripping only \r, not all
# whitespace, before testing for emptiness) makes a whitespace-only record
# render as invisible spaces rather than "<blank>". Content-anchored, not by
# line number: a reviewer reproduced the line-number version silently
# retargeting an unrelated adjacent line after one line of drift above the
# anchor (`NR==757` instead of `NR==756` hit the neighbouring
# `malformed=...` line, unrelated to note 5) and still reported PASS with
# the suite green — this anchor instead matches the fix line's own literal
# text and REQUIRES exactly one match, so an ambiguous (duplicated) or
# absent (rewritten) target fails loudly instead of silently retargeting.
WSONLY_MUTANT="$WORK/mutant-exit-agg-wsonly.sh"
# shellcheck disable=SC2016  # literal target text: $shown/$( ) are not shell here.
WSONLY_TARGET='      if [ -z "$(printf '\''%s'\'' "$shown" | tr -d '\''[:space:]'\'')" ]; then shown="<blank>"; fi'
WSONLY_HITS=$(grep -cF -- "$WSONLY_TARGET" "$CHECK_SH" || true)
if [ "$WSONLY_HITS" -ne 1 ]; then
  report "mutation probe 'exit-agg-wsonly-blank': note 5's fix line matched $WSONLY_HITS time(s) in $CHECK_SH, not exactly 1 — refusing rather than guessing which one is the real target"
else
  awk -v target="$WSONLY_TARGET" '
    $0 == target { print "      [ -n \"$shown\" ] || shown=\"<blank>\""; next }
    { print }
  ' "$CHECK_SH" > "$WSONLY_MUTANT"
  if cmp -s "$WSONLY_MUTANT" "$CHECK_SH"; then
    report "mutation probe 'exit-agg-wsonly-blank': the replacement changed nothing"
  else
    SCRIPT_UNDER_TEST="$WSONLY_MUTANT" run "$D_AGG_WSONLY" probe-exit-agg-wsonly-blank
    if grep -qF '<blank>' "$OUT/probe-exit-agg-wsonly-blank.out"; then
      report "mutation probe 'exit-agg-wsonly-blank': the fixture still shows <blank> with note 5's fix reverted — this fix is not what renders it"
    else
      echo "PASS: mutation probe exit-agg-wsonly-blank (reverting note 5's fix drops <blank>, reproducing the invisible-record defect)"
    fi
  fi
fi

# ===========================================================================
# Case: #1 (round 1) — a sidecar whose final record carries no trailing
# newline must still be counted. Reproduced exactly as the round-1 review
# comment did: a `0\n1` sidecar with the trailing newline stripped off. A
# plain `while read; do …; done < file` loop drops this record silently
# (`read` returns non-zero at EOF without a delimiter, and the loop tests
# only that status), which is the false-PASS direction #677's own AC3 named.
# ===========================================================================
AGG_NONL_LOG="$LOGS/test-r0-agg-nonl.log"
cp "$AGG_OK_LOG" "$AGG_NONL_LOG"
printf '0\n1' > "$AGG_NONL_LOG.exits"
AGG_NONL_SHA=$(sha256sum "$AGG_NONL_LOG" | awk '{print $1}')
sed -e "s#$GOOD_LOG#$AGG_NONL_LOG#g" -e "s#$GOOD_SHA#$AGG_NONL_SHA#g" \
    "$WORK/exit-agg-ok-pre.md" > "$WORK/exit-agg-nonl.md"
D_AGG_NONL="$(mkcase exit-agg-nonl "$WORK/exit-agg-nonl.md")"
run "$D_AGG_NONL" exit-agg-nonl
expect_rc exit-agg-nonl 1
expect_line exit-agg-nonl "FAIL exit-count"
expect_line exit-agg-nonl "aggregate form"
expect_line exit-agg-nonl "sidecar records: 0, 1"
if grep -qF 'PASS exit-count' "$RUN_OUT"; then
  report "exit-agg-nonl: PASSed exit-count on an aggregate claim whose sidecar's final, newline-less record was non-zero"
fi

# ===========================================================================
# Case: #5 (round 1) — a sidecar record of "00" is a genuinely-zero value,
# not a non-zero one. `[ "$val" = "0" ]` is a string test that misreports it;
# the fix compares numerically.
# ===========================================================================
AGG_DZERO_LOG="$LOGS/test-r0-agg-dzero.log"
cp "$AGG_OK_LOG" "$AGG_DZERO_LOG"
printf '0\n00\n' > "$AGG_DZERO_LOG.exits"
AGG_DZERO_SHA=$(sha256sum "$AGG_DZERO_LOG" | awk '{print $1}')
sed -e "s#$GOOD_LOG#$AGG_DZERO_LOG#g" -e "s#$GOOD_SHA#$AGG_DZERO_SHA#g" \
    "$WORK/exit-agg-ok-pre.md" > "$WORK/exit-agg-dzero.md"
D_AGG_DZERO="$(mkcase exit-agg-dzero "$WORK/exit-agg-dzero.md")"
run "$D_AGG_DZERO" exit-agg-dzero
expect_rc exit-agg-dzero 0
expect_line exit-agg-dzero "PASS exit-count"

# ===========================================================================
# Case: exit markers — one command echoed without its own, and a log with no
# markers at all (reported as not-checkable, not failed).
# ===========================================================================
sed -e "s#$GOOD_LOG#$PARTIAL_LOG#g" -e "s#$GOOD_SHA#$PARTIAL_SHA#g" "$WORK/good.md" > "$WORK/partial.md"
D_PART="$(mkcase partial "$WORK/partial.md")"
run "$D_PART" partial
expect_rc partial 1
expect_line partial "no [exit=N] of its own before the next command"

# The no-marker log carries only the first command, so the manifest names only
# it — Exit code is trimmed to match, so this fixture stays isolated to the
# no-markers-in-the-log case and does not also trip `exit-count`.
sed -e "s#$GOOD_LOG#$NOMARK_LOG#g" -e "s#$GOOD_SHA#$NOMARK_SHA#g" \
    -e '/command -v markdownlint markdownlint-cli2`$/d' \
    "$WORK/good.md" > "$WORK/nomark-src.md"
set_exit "$WORK/nomark-src.md" "$WORK/nomark.md" <<<'- Exit code: 0'
D_NOMARK="$(mkcase nomark "$WORK/nomark.md")"
run "$D_NOMARK" nomark
expect_rc nomark 0
expect_line nomark "the log carries no [exit=N] markers, so per-command exits were not checkable"

# ===========================================================================
# Case: the log is not on this disk — every check that does not need it still
# runs, and the run is still a pass.
# ===========================================================================
sed -e "s#$GOOD_LOG#/nowhere/evidence/issue503/test-r0.log#g" "$WORK/good.md" > "$WORK/absent-log.md"
D_ABS="$(mkcase absent-log "$WORK/absent-log.md")"
run "$D_ABS" absent-log
expect_rc absent-log 3
expect_line absent-log "SKIP digest"
expect_line absent-log "SKIP commands"
expect_line absent-log "PASS head"
# #589: the skip count is pluralised, never the literal alternation, and the
# exit status alone separates this run from the fully-verified one above.
expect_line absent-log "2 entries to check"
if grep -qF 'entr(y|ies)' "$RUN_OUT"; then
  report "absent-log: printed the literal alternation instead of pluralising"
fi

# The singular. One Command entry, log absent: "1 entry", not "1 entries".
# Exit code is trimmed to match the single Command entry, same reason as nomark.
sed -e "s#$GOOD_LOG#/nowhere/evidence/issue503/test-r0.log#g" \
    -e '/command -v markdownlint markdownlint-cli2`$/d' \
    "$WORK/good.md" > "$WORK/absent-one-src.md"
set_exit "$WORK/absent-one-src.md" "$WORK/absent-one.md" <<<'- Exit code: 0'
D_ABS1="$(mkcase absent-one "$WORK/absent-one.md")"
run "$D_ABS1" absent-one
expect_rc absent-one 3
expect_line absent-one "1 entry to check"

# ===========================================================================
# Case: a bare-echo log — the marker scan's boundary is the next command, not
# only a prompt-prefixed line. `echo one` carries no marker of its own, and the
# scan must not credit it with `echo two`'s.
# ===========================================================================
# shellcheck disable=SC2016  # sed script over manifest text: literal backticks, not shell.
sed -e "s#$GOOD_LOG#$BARE_LOG#g" -e "s#$GOOD_SHA#$BARE_SHA#g" \
    -e 's#^  - `grep -c "no suites" docs/process/testing.md`$#  - `echo one`#' \
    -e 's#^  - `command -v markdownlint markdownlint-cli2`$#  - `echo two`#' \
    "$WORK/good.md" > "$WORK/bare-echo.md"
D_BARE="$(mkcase bare-echo "$WORK/bare-echo.md")"
run "$D_BARE" bare-echo
expect_rc bare-echo 1
expect_line bare-echo "FAIL commands"
expect_line bare-echo "no [exit=N] of its own before the next command: echo one"

# ===========================================================================
# Case: a Command sub-bullet carrying two code spans is rendered with balanced
# backticks (#589). The FAIL is correct — a prose paraphrase is not a command —
# and only the rendering was ever wrong, so the assertion is on the text.
# ===========================================================================
# shellcheck disable=SC2016  # sed script over manifest text: literal backticks, not shell.
sed -e 's#^  - `command -v markdownlint markdownlint-cli2`$#  - `bash test_agent_rules_drift.sh` (run from `tests/`)#' \
    "$WORK/good.md" > "$WORK/two-span.md"
D_2SPAN="$(mkcase two-span "$WORK/two-span.md")"
run "$D_2SPAN" two-span
expect_rc two-span 1
expect_line two-span "the log does not echo: \`bash test_agent_rules_drift.sh\` (run from \`tests/\`)"

# The same defect one level harder: two spans where the line also ENDS in a
# backtick, so the leading and trailing runs are equal length and a
# length-only rule would strip both and unbalance the middle. Written as an
# INLINE `- Command:` value, which is how PR #564 carried it — the inline and
# sub-bullet paths must render a value identically.
# shellcheck disable=SC2016  # sed script over manifest text: literal backticks, not shell.
sed -e '/^  - `/d' \
    -e 's#^- Command:$#- Command: `bash one.sh` and `bash two.sh`#' \
    "$WORK/good.md" > "$WORK/two-span-inline.md"
D_2SPANI="$(mkcase two-span-inline "$WORK/two-span-inline.md")"
run "$D_2SPANI" two-span-inline
expect_rc two-span-inline 1
expect_line two-span-inline "the log does not echo: \`bash one.sh\` and \`bash two.sh\`"

# And the shape the stripping exists for still unwraps: a value that IS one
# span, including the recipe's widened fence around a command carrying a
# backtick.
run "$D_GOOD" good-head-span
expect_rc good-head-span 0
expect_line good-head-span "$HEAD_SHA == PR head"

# ===========================================================================
# Case: the bolded / em-dash bullet form real manifests drift to.
# ===========================================================================
# The Exit code bullet carries no inline value now, so it takes the bolded form
# with the colon rather than the em dash — which is also what exercises
# `sublist`'s bolded pattern against a real sub-bullet list.
sed -E -e 's/^- (Command|Env|Head SHA|Results|Log SHA-256|Raw log|Lint state|Coverage): /- **\1** — /' \
       -e 's/^- (Exit code):$/- **\1**:/' \
  "$WORK/good.md" > "$WORK/bolded.md"
D_BOLD="$(mkcase bolded "$WORK/bolded.md")"
run "$D_BOLD" bolded
expect_rc bolded 0
expect_line bolded "PASS fields"
expect_line bolded "PASS digest"
expect_line bolded "2 Exit code entries (sub-bullet list)"

# ===========================================================================
# Case: a testing doc with no "no suites" declaration (env-quote still reads
# docs/process/testing.md for that ONE literal-string extraction, #748's
# narrower scope — see the script's header note) AND no conditional-linter
# sentence either — the caller declares that with --lint none, restoring
# implementer.md's own "omit only when docs/process/testing.md names no
# linter at all" split (#748 round-1 relay: the first cut of --lint dropped
# this vocabulary entirely). good.md's Lint state bullet is still present
# here — --lint none must report n/a regardless, since presence is not what
# decides this case, --lint is.
# ===========================================================================
D_PLAIN="$(mkcase plain-testing "$WORK/good.md" "$TESTING_PLAIN")"
run "$D_PLAIN" plain-testing --lint none
expect_rc plain-testing 0
expect_line plain-testing "n/a  env-quote"
expect_line plain-testing "n/a  lint-state"

# The Lint state bullet is required whenever --lint is installed or
# not-installed (a conditional-linter sentence exists in the doc either way).
grep -v '^- Lint state:' "$WORK/good.md" > "$WORK/no-lint.md"
D_NOLINT="$(mkcase no-lint "$WORK/no-lint.md")"
run "$D_NOLINT" no-lint
expect_rc no-lint 1
expect_line no-lint "FAIL lint-state"

# ===========================================================================
# Case: --lint none makes the Lint state bullet's ABSENCE a non-issue — gate:
# the `if [ "$LINT" = "none" ]; then na lint-state ...` skip, exercised here
# against D_NOLINT (the same fixture immediately above, whose manifest
# genuinely has no Lint state bullet at all), proving the skip is a real
# requiredness decision and not just a relabelling of PASS/FAIL text: with
# --lint installed the identical manifest FAILs (case above); with --lint
# none it must report n/a and exit 0.
# ===========================================================================
run "$D_NOLINT" lint-none-no-field --lint none
expect_rc lint-none-no-field 0
expect_line lint-none-no-field "n/a  lint-state"

# Splice: reverting the --lint none skip must turn lint-none-no-field's n/a
# back into FAIL — proving the decision is load-bearing, not report text the
# round-1 relay's own caveat warned could be mistaken for a fix. Content-
# anchored with an exactly-one-match guard, syntax-checked before running,
# and diffed against the original for the record.
# shellcheck disable=SC2016  # literal target text: $LINT is not shell here.
LINTNONE_TARGET='if [ "$LINT" = "none" ]; then'
LINTNONE_HITS=$(grep -cF -- "$LINTNONE_TARGET" "$CHECK_SH" || true)
if [ "$LINTNONE_HITS" -ne 1 ]; then
  report "splice 'lint-none-decision': target line matched $LINTNONE_HITS time(s) in $CHECK_SH, not exactly 1 — refusing rather than guessing which one is the real target"
else
  LINTNONE_MUTANT="$WORK/mutant-lint-none.sh"
  awk -v target="$LINTNONE_TARGET" '
    $0 == target { print "if false; then"; next }
    { print }
  ' "$CHECK_SH" > "$LINTNONE_MUTANT"
  if cmp -s "$LINTNONE_MUTANT" "$CHECK_SH"; then
    report "splice 'lint-none-decision': the replacement changed nothing"
  elif ! bash -n "$LINTNONE_MUTANT" 2>/dev/null; then
    report "splice 'lint-none-decision': mutant is not even valid bash — the anchor text must have moved"
  else
    diff -u "$CHECK_SH" "$LINTNONE_MUTANT" > "$OUT/lint-none-splice.diff" || true
    SCRIPT_UNDER_TEST="$LINTNONE_MUTANT" run "$D_NOLINT" splice-lint-none --lint none
    if [ "$RC" -eq 0 ]; then
      report "splice 'lint-none-decision': reverting the --lint none skip did NOT make the FAIL fire (still exit 0) — the n/a fixture above does not depend on this decision: $(cat "$OUT/splice-lint-none.out")"
    else
      echo "PASS: splice lint-none-decision (reverting the --lint none skip turns the no-field fixture from n/a into FAIL — a real requiredness decision, not just report text)"
    fi
  fi
fi

# ===========================================================================
# Case: --lint not-installed is classified as "not installed" — the pair
# `grep -qi 'installed'` gets wrong (#748), reproduced here in the argument
# domain: good.md's own Lint state bullet reads "not installed — review-only"
# verbatim, and --lint not-installed must be classified as "not installed",
# never misread as "installed" because the negation contains the affirmative
# word as a substring.
# ===========================================================================
run "$D_GOOD" lint-not-installed --lint not-installed
expect_rc lint-not-installed 0
expect_line lint-not-installed "PASS lint-state"
expect_line lint-not-installed "declared not installed via --lint"
if grep -qF "declared installed via --lint" "$OUT/lint-not-installed.out"; then
  report "lint-not-installed: --lint not-installed was misclassified as installed"
fi

# Splice: reverting the exact-match LINT_LABEL test to the ORIGINAL substring
# grep this issue names (#748) — now applied to the --lint argument instead of
# docs/process/testing.md's prose — must make lint-not-installed's
# classification wrong (reads "not-installed" as "installed"), proving the
# fixture above actually depends on the exact-match fix. Content-anchored with
# an exactly-one-match guard, never a line number.
# shellcheck disable=SC2016  # literal target text: $LINT is not shell here.
LINTLABEL_TARGET='  if [ "$LINT" = "installed" ]; then LINT_LABEL="installed"; else LINT_LABEL="not installed"; fi'
LINTLABEL_HITS=$(grep -cF -- "$LINTLABEL_TARGET" "$CHECK_SH" || true)
if [ "$LINTLABEL_HITS" -ne 1 ]; then
  report "splice 'lint-label-exact-match': target line matched $LINTLABEL_HITS time(s) in $CHECK_SH, not exactly 1 — refusing rather than guessing which one is the real target"
else
  LINTLABEL_MUTANT="$WORK/mutant-lint-label.sh"
  # shellcheck disable=SC2016  # literal replacement text: $LINT is not shell here.
  LINTLABEL_REPL='if printf '"'"'%s'"'"' "$LINT" | grep -qi '"'"'installed'"'"'; then LINT_LABEL="installed"; else LINT_LABEL="not installed"; fi'
  awk -v target="$LINTLABEL_TARGET" -v repl="$LINTLABEL_REPL" '
    $0 == target { print repl; next }
    { print }
  ' "$CHECK_SH" > "$LINTLABEL_MUTANT"
  if cmp -s "$LINTLABEL_MUTANT" "$CHECK_SH"; then
    report "splice 'lint-label-exact-match': the replacement changed nothing"
  elif ! bash -n "$LINTLABEL_MUTANT" 2>/dev/null; then
    report "splice 'lint-label-exact-match': mutant is not even valid bash — the anchor text must have moved"
  else
    SCRIPT_UNDER_TEST="$LINTLABEL_MUTANT" run "$D_GOOD" splice-lint-label --lint not-installed
    if grep -qF "declared not installed via --lint" "$OUT/splice-lint-label.out"; then
      report "splice 'lint-label-exact-match': reverting to the substring grep did NOT reproduce the misclassification — the fixture above does not depend on the exact-match fix"
    elif ! grep -qF "declared installed via --lint" "$OUT/splice-lint-label.out"; then
      report "splice 'lint-label-exact-match': mutant produced neither label — something else broke: $(cat "$OUT/splice-lint-label.out")"
    else
      echo "PASS: splice lint-label-exact-match (reverting to grep -qi 'installed' misreads --lint not-installed as installed, as PR #748's own doc-prose defect did)"
    fi
  fi
fi

# ===========================================================================
# Case: testing.md absent altogether (mock 404) is a fact, not a failure.
# ===========================================================================
D_404="$(mkcase testing-404 "$WORK/good.md")"
rm -f "$D_404/testing.json"
run "$D_404" testing-404
expect_rc testing-404 0
expect_line testing-404 "n/a  env-quote"

# ===========================================================================
# Case: #629 — a **Results** field asserting a check count nowhere in the raw
# log, a raw-log-section pointer to a section the log does not carry, or a
# command it claims was run that is absent from **Command**.
# ===========================================================================
# results-count: "66" appears in neither the log nor the good manifest's log
# output — PR #621's round-0 finding, reproduced.
set_results "$WORK/good.md" "$WORK/results-count-bad.md" <<<'66 checks passed, 0 failed.'
D_RC_BAD="$(mkcase results-count-bad "$WORK/results-count-bad.md")"
run "$D_RC_BAD" results-count-bad
expect_rc results-count-bad 1
expect_line results-count-bad "FAIL results-count"
expect_line results-count-bad "66"

# Honest: the count Results states appears in the log — the first command's
# own output is the literal line "1".
set_results "$WORK/good.md" "$WORK/results-count-ok.md" <<<'1 check ran clean, 0 unexpected failures'
D_RC_OK="$(mkcase results-count-ok "$WORK/results-count-ok.md")"
run "$D_RC_OK" results-count-ok
expect_rc results-count-ok 0
expect_line results-count-ok "PASS results-count"

# A Command-derived count phrased without the "check(s)"/"assertion(s)" word
# is not this check's concern at all — `good` itself says "2 commands" and
# must never FAIL on it.
grep -qF "n/a  results-count" "$OUT/good.out" || report "good: expected n/a results-count in the original good run"

# ===========================================================================
# Case: round selection.
# ===========================================================================
sed -e 's/^## Test Evidence — round 0/## Test Evidence — round 1/' \
    -e 's/"round":0/"round":1/' "$WORK/good.md" > "$WORK/round1.md"
D_R="$(mkcase rounds "$WORK/good.md")"
jq -n --rawfile b "$WORK/round1.md" \
  '[{body:$b, html_url:"https://example.invalid/pr/42#issuecomment-3", created_at:"2026-01-03T00:00:00Z"}]' \
  > "$D_R/comments_page2.json"
jq -n --rawfile b "$WORK/good.md" \
  '[{body:$b, html_url:"https://example.invalid/pr/42#issuecomment-2", created_at:"2026-01-02T00:00:00Z"}]' \
  > "$D_R/comments_page1.json"
run "$D_R" rounds-default
expect_rc rounds-default 0
expect_line rounds-default "round 1 manifest"
run "$D_R" rounds-explicit --round 0
expect_rc rounds-explicit 0
expect_line rounds-explicit "round 0 manifest"

# ===========================================================================
# Cases: "this run could not be performed" — exit 2, never 1. Each routes
# through the mock so a regressed guard cannot reach a real `gh` (#477).
# ===========================================================================
D_NONE="$(mkcase no-manifest "$WORK/good.md")"
printf '[]\n' > "$D_NONE/comments_page1.json"
printf '[]\n' > "$D_NONE/comments_page2.json"
run "$D_NONE" no-manifest
expect_rc no-manifest 2
grep -qF "carries no '## Test Evidence — round N' comment" "$OUT/no-manifest.err" \
  || report "no-manifest: expected a diagnostic naming the absent manifest"

run_argerr(){
  local label="$1"; shift
  local rc=0
  MOCK_GH_FIXTURES="$D_GOOD" MOCK_GH_CALLS="$CALLS" PATH="$BIN:$PATH" \
    bash "$CHECK_SH" "$@" > "$OUT/$label.out" 2> "$OUT/$label.err" || rc=$?
  [ "$rc" -eq 2 ] || report "$label: expected exit 2 on an argument error, got $rc"
}
run_argerr argerr-none
run_argerr argerr-nonnumeric abc --repo "$REPO"
run_argerr argerr-flag "$PR" --repo "$REPO" --nope
run_argerr argerr-extra "$PR" 43 --repo "$REPO"
run_argerr argerr-round "$PR" --repo "$REPO" --round x
# #748: --lint is now mandatory; absent or bad it is an argument error (exit 2), naming
# the flag, never a silent doc-derived guess.
run_argerr argerr-nolint "$PR" --repo "$REPO"
grep -qF -- "--lint" "$OUT/argerr-nolint.err" \
  || report "argerr-nolint: expected the diagnostic to name --lint, got: $(cat "$OUT/argerr-nolint.err")"
run_argerr argerr-lintbad "$PR" --repo "$REPO" --lint maybe
grep -qF -- "--lint" "$OUT/argerr-lintbad.err" \
  || report "argerr-lintbad: expected the diagnostic to name --lint, got: $(cat "$OUT/argerr-lintbad.err")"

# ===========================================================================
# The mock refuses every write-verb spelling, and a non-`api` subcommand.
# Asserted against the mock directly rather than hoping the script attempts
# one: a test that never proves the refusal has not proven the script is
# read-only.
# ===========================================================================
for spelling in "-X POST" "--method PATCH" "-XPOST" "--method=DELETE"; do
  rc=0
  # shellcheck disable=SC2086
  MOCK_GH_FIXTURES="$D_GOOD" MOCK_GH_CALLS="$CALLS" PATH="$BIN:$PATH" \
    gh api $spelling "repos/$REPO/issues/$PR/comments" >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || report "mock accepted a write verb ($spelling)"
done
rc=0
MOCK_GH_FIXTURES="$D_GOOD" MOCK_GH_CALLS="$CALLS" PATH="$BIN:$PATH" \
  gh pr merge "$PR" >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || report "mock accepted a non-api subcommand (gh pr merge)"

grep -q 'method\|-X' "$CALLS" >/dev/null 2>&1 || true
if grep -q 'UNMOCKED-CONTEXT' "$CALLS"; then
  report "a gh invocation reached the mock without the harness env — some case was not hermetic"
  grep 'UNMOCKED-CONTEXT' "$CALLS" >&2
fi

# ===========================================================================
# Mutation probes: each check proven load-bearing. A throwaway copy of the
# script has exactly one guard neutered; the fixture that check fails must
# then pass. A guard whose only proof is a green test is not known to be
# doing anything (tests/README.md).
# ===========================================================================
probe(){ # probe <label> <case-dir> <sed-expression>
  local label="$1" dir="$2" expr="$3"
  local mutant="$WORK/mutant-$label.sh"
  sed "$expr" "$CHECK_SH" > "$mutant"
  if cmp -s "$mutant" "$CHECK_SH"; then
    report "mutation probe '$label': the sed expression changed nothing — the anchor line moved"
    return 0
  fi
  local rc=0
  SCRIPT_UNDER_TEST="$mutant" run "$dir" "probe-$label"
  rc="$RC"
  # Green means "nothing FAILed": 0, or 3 when some check SKIPs — the fixture's
  # log being off this disk is one such case, and an incomplete per-command scan
  # (which makes `exit-count` skip for want of a record to cross-check against)
  # is another, on a fixture whose log is on disk. 1 is the only verdict that
  # means the guard still fired.
  if [ "$rc" -eq 0 ] || [ "$rc" -eq 3 ]; then
    echo "PASS: mutation probe $label (neutering the guard turns its fixture green)"
  else
    report "mutation probe '$label': the fixture still fails with the guard neutered — the failure comes from somewhere else, so this check is not what catches it"
    sed 's/^/    /' "$OUT/probe-$label.out" >&2
  fi
}
probe fields      "$D_MISSING"  "s/missing=\"\\\$missing, \\\$f\"/:/"
probe commands    "$D_UNECHOED" "s/unechoed=\"\\\$unechoed, \\\$c\"/:/"
probe digest      "$D_WRONG"    "s/if \\[ \"\\\$actual\" = \"\\\$B_SHA\" \\]; then/if true; then/"
probe env-quote   "$D_LK1"      "s/elif printf '%s' \"\\\$ENV_V\" | grep -qF -- \"\\\$DECL\"; then/elif true; then/"
probe head        "$D_STALE"    "s/elif \\[ \"\\\$B_HEAD\" = \"\\\$HEAD_SHA\" \\]; then/elif true; then/"
probe footer      "$D_FK"       "s/if \\[ \"\\\$keys\" = \"\\\$want\" \\]; then/if true; then/"
probe log-path    "$D_PH"       "s/bad log-path \"names an unexpanded placeholder/ok log-path \"mutant/"
# shellcheck disable=SC2016  # sed script: literal $ and quotes, not shell.
probe lint-state  "$D_NOLINT"   's/if has_field "Lint state" \&\& \[ -n "\$(field "Lint state")" \]; then/if true; then/'
# shellcheck disable=SC2016  # sed/manifest text: literal $ and backticks, not shell.
probe exit-count  "$D_XSHORT"   's/elif ! same_count "\${#cmds\[@\]}" "\$exit_n"; then/elif false; then/'
# #629: neutering each new Results guard turns its own FAIL fixture green —
# proof each is what catches PR #621's own round-0 finding, rather than
# something else in the ladder doing so incidentally.
# shellcheck disable=SC2016  # sed over check-manifest.sh's own source: literal, not shell.
probe results-count       "$D_RC_BAD"   's/if \[ -n "\$unseen" \]; then/if false; then/'
# #1 (round 1): reverting the `|| [ -n "$rec" ]` disjunct restores the
# pre-fix `while read` loop, which silently drops a sidecar's final record
# when it carries no trailing newline — the false PASS this fixture exists
# to catch (#677's own AC3).
# shellcheck disable=SC2016  # sed over check-manifest.sh's own source: literal, not shell.
probe exit-agg-nonl-read "$D_AGG_NONL" \
  's/while IFS= read -r rec || \[ -n "\$rec" \]; do/while IFS= read -r rec; do/'
# #651: the classification branch. `bare_inline` is what refuses to read an
# annotated value as a countable list; loosen its anchor so any value starting
# with a digit is taken for a bare list, and the annotated fixture is counted by
# its commas again — 2 for 2 commands, green, which is exactly the false PASS
# rounds 1-3 kept reaching by different routes.
# shellcheck disable=SC2016  # sed over check-manifest.sh's own source: literal, not shell.
probe exit-annot-classify "$D_ANNOT_INLINE" \
  's#^bare_inline().*#bare_inline(){ printf "%s" "$1" | grep -qE "^[0-9]"; }#'
# #651: the report branch. With the defect left unreported and the count taken
# from Command instead, the same fixture goes green — the guard that turns a
# refusal-to-parse into a FAIL is this line and nothing else.
# shellcheck disable=SC2016  # sed over check-manifest.sh's own source: literal, not shell.
probe exit-annot-report "$D_ANNOT_INLINE" \
  's/EXIT_DEFECT=1; EXIT_DEFECT_KIND=annot; exit_n=0; exit_src="annotated inline list"/EXIT_DEFECT=0; exit_n="${#cmds[@]}"; exit_src="mutant"/'
# #646: neuter the aggregate-vs-sidecar guard and prove the dishonest aggregate
# fixture — whose own sidecar records a 1 — goes green. Without this line, the
# aggregate form's COUNT check is all that ever ran, and it agrees by
# construction, so nothing else in the ladder would catch it.
# shellcheck disable=SC2016  # sed over check-manifest.sh's own source: literal, not shell.
probe exit-agg-nonzero "$D_AGG_BAD" \
  's/elif \[ -n "\$AGGREGATE_NONZERO" \]; then/elif false; then/'

# ---------------------------------------------------------------------------
# wording_probe <label> <case-dir> <sed-expr> <wrong-substring> — for a guard
# whose fixture FAILs either way (verdict does not change), so `probe`'s
# green-vs-red test cannot see it: it distinguishes DIAGNOSTIC WORDING
# instead. Neutering the guard must make the wrong wording — the one the guard
# exists to prevent — appear.
# ---------------------------------------------------------------------------
wording_probe(){
  local label="$1" dir="$2" expr="$3" bad="$4"
  local mutant="$WORK/mutant-$label.sh"
  sed "$expr" "$CHECK_SH" > "$mutant"
  if cmp -s "$mutant" "$CHECK_SH"; then
    report "mutation probe '$label': the sed expression changed nothing — the anchor line moved"
    return 0
  fi
  SCRIPT_UNDER_TEST="$mutant" run "$dir" "probe-$label"
  if grep -qF -- "$bad" "$OUT/probe-$label.out"; then
    echo "PASS: mutation probe $label (neutering the guard produces the wrong wording it exists to prevent)"
  else
    report "mutation probe '$label': the wrong wording did not appear with the guard neutered — this guard may not be what prevents it"
    sed 's/^/    /' "$OUT/probe-$label.out" >&2
  fi
}
# #660: neuter `punct_only` and prove an honest punctuation-only value
# (`0,,1`, no prose at all) is mislabelled "annotated and written inline" — the
# exact wrong wording #660 was filed against.
# shellcheck disable=SC2016  # sed over check-manifest.sh's own source: literal, not shell.
wording_probe exit-punct-classify "$D_PUNCT_DOUBLED" \
  's#^punct_only().*#punct_only(){ return 1; }#' \
  "annotated and written inline"
# #657: neuter the historical-date comparison and prove a pre-ruling manifest
# is told to re-post a merged PR — the wrong instruction #657 was filed
# against.
# shellcheck disable=SC2016  # sed over check-manifest.sh's own source: literal, not shell.
wording_probe exit-annot-historical-date "$D_ANNOT_HISTORICAL" \
  's/\[ -n "\$COMMENT_AT" \] && \[ "\$COMMENT_AT" \\< "\$RULING_AT" \]/false/' \
  "Re-post the manifest with one entry per sub-bullet"
# #678: reverting `punct_only` to the old digit/comma/whitespace-only
# whitelist reproduces the exact defect the issue was filed against — a
# semicolon-separated value carries no alphabetic character (so it is not
# annotation prose), but the old whitelist rejects the semicolon and falls
# through to the annotated branch anyway.
# shellcheck disable=SC2016  # sed over check-manifest.sh's own source: literal, not shell.
wording_probe exit-punct-alpha-classify "$D_PUNCT_SEMI" \
  's#^punct_only().*#punct_only(){ printf "%s" "$1" | grep -qE "^[[:space:]]*[0-9,[:space:]]*$"; }#' \
  "annotated and written inline"
# #678: neutering `punct_shape`'s non-comma detection (the line that finds
# which literal separator character is actually present) makes the semicolon
# fixture fall through to the old generic "stray punctuation" fallback instead
# of naming the separator found — the residual the issue's second finding was
# filed against.
# shellcheck disable=SC2016  # sed over check-manifest.sh's own source: literal, not shell.
wording_probe exit-punct-shape-naming "$D_PUNCT_SEMI" \
  's/^    other=.*/    other=""/' \
  "stray punctuation"

# ---------------------------------------------------------------------------
# The inverted half of the same idea, for the two #602 round-1 guards whose
# fixtures are GREEN by construction: neutering them cannot turn a red fixture
# green, so the assertion is that the mutant turns a green fixture RED with the
# specific false FAIL the guard exists to prevent. A guard whose fixture passes
# either way is not known to be doing anything (tests/README.md).
# ---------------------------------------------------------------------------
antiprobe(){ # antiprobe <label> <case-dir> <sed-expression> <expected-substring>
  local label="$1" dir="$2" expr="$3" want="$4"
  local mutant="$WORK/mutant-$label.sh"
  sed "$expr" "$CHECK_SH" > "$mutant"
  if cmp -s "$mutant" "$CHECK_SH"; then
    report "mutation probe '$label': the sed expression changed nothing — the anchor line moved"
    return 0
  fi
  SCRIPT_UNDER_TEST="$mutant" run "$dir" "probe-$label"
  if grep -qF -- "$want" "$OUT/probe-$label.out"; then
    echo "PASS: mutation probe $label (reintroducing the defect false-FAILs the honest fixture)"
  else
    report "mutation probe '$label': the fixture stayed green with the defect reintroduced — this guard is not what keeps it green"
    sed 's/^/    /' "$OUT/probe-$label.out" >&2
  fi
}
# #651: the sub-bullet path is what an honest annotated manifest now takes, and
# `good` itself takes it. Make the sub-bullet list unreachable — the count falls
# through to the inline field, which is the header line's empty value — and the
# honest manifest FAILs for want of entries. This is the inverted half: it
# proves the sub-bullet branch is what keeps `good` green, rather than something
# downstream of it.
# shellcheck disable=SC2016  # manifest text / sed script: literal backticks and $, not shell.
# #651: `bare_inline`'s tolerance of whitespace around the separators. Drop it
# and a bare list written `0 ,  1` is no longer counted as one (`punct_only`
# still accepts it — it is digits, commas and whitespace only — so #660's
# split reclassifies it as malformed punctuation rather than annotated, but
# either way it is now a `FAIL exit-count` on an honest manifest that has
# neither shape of defect. The false FAIL this check must never produce.
# shellcheck disable=SC2016  # sed over check-manifest.sh's own source: literal, not shell.
antiprobe exit-bare-spacing "$D_BARE_SPACED" \
  's#^bare_inline().*#bare_inline(){ printf "%s" "$1" | grep -qE "^[0-9]+(,[0-9]+)*$"; }#' \
  "FAIL exit-count"
# shellcheck disable=SC2016  # sed over check-manifest.sh's own source: literal, not shell.
antiprobe exit-sub-count "$D_GOOD" \
  's/if \[ "\${#exit_sub\[@\]}" -gt 0 \]; then/if false; then/' \
  "FAIL exit-count"
# Finding 2: with the sidecar's count replaced by the whole-file read-back #539
# removed, the phantom `[exit=` line in command 1's own output counts as a
# third marker and false-FAILs an honest 2-command manifest.
# shellcheck disable=SC2016  # sed/manifest text: literal $ and backticks, not shell.
antiprobe exit-source-sidecar "$D_XPH" \
  's|EXITS_N=\$(awk .END { print NR }. "\$RESOLVED.exits")|EXITS_N=\$(grep -c "^\\[exit=" "\$RESOLVED")|' \
  "the log carries 3 [exit=N] marker(s)"
# The same for the fallback source, on the same log with no sidecar beside it.
# shellcheck disable=SC2016  # sed/manifest text: literal $ and backticks, not shell.
antiprobe exit-source-scan "$D_XPH2" \
  's|EXITS_N="\$SCAN_MARKED"; EXITS_SRC=scan|EXITS_N=\$(grep -c "^\\[exit=" "\$RESOLVED"); EXITS_SRC=scan|' \
  "the log carries 3 [exit=N] marker(s)"
# #677: reverting SIDECAR_INT_RE to a strict '^0$' anchor is exactly the
# pre-fix defect — an honest all-zero sidecar contaminated by a trailing space
# or a CRLF line ending is no longer read as zero, so the fixtures the fix
# exists for turn red again.
# shellcheck disable=SC2016  # sed over check-manifest.sh's own source: literal, not shell.
antiprobe exit-agg-ws-strip "$D_AGG_WS" \
  's/^SIDECAR_INT_RE=.*/SIDECAR_INT_RE="^0\$"/' \
  "FAIL exit-count"
# shellcheck disable=SC2016  # sed over check-manifest.sh's own source: literal, not shell.
antiprobe exit-agg-crlf-strip "$D_AGG_CRLF" \
  's/^SIDECAR_INT_RE=.*/SIDECAR_INT_RE="^0\$"/' \
  "FAIL exit-count"
# #5 (round 1): reverting the numeric comparison back to `[ "$val" = "0" ]`
# — a string test — misreads a genuinely-zero "00" sidecar record as
# non-zero and false-FAILs the honest fixture.
# shellcheck disable=SC2016  # sed over check-manifest.sh's own source: literal, not shell.
antiprobe exit-agg-dzero-numeric "$D_AGG_DZERO" \
  's/\[ "\$val" -eq 0 \] 2>\/dev\/null || has_nonzero=1/[ "\$val" = "0" ] || has_nonzero=1/' \
  "FAIL exit-count"
# #677: with the malformed/non-zero distinction removed (every line is judged
# by the strict decimal test, and anything that fails it is folded straight
# into "nonzero" the way the pre-fix code did), the non-numeric sidecar record
# is reported with the old #646 wording instead of as a malformed record.
# shellcheck disable=SC2016  # sed over check-manifest.sh's own source: literal, not shell.
wording_probe exit-agg-malformed-classify "$D_AGG_NAN" \
  's/^SIDECAR_INT_RE=.*/SIDECAR_INT_RE=".*"/' \
  "the aggregate form is only correct when every marker really is 0"
# #596: neutering the FOOTER_OK guard on the exact bug shape (unparseable
# footer, no visible bullets to compare) restores the false PASS it used to
# print — the generic `probe` helper checks the overall exit code, but this
# fixture's other required-field FAILs keep that code non-zero regardless of
# the guard, so the assertion here is the specific report line instead.
FOOTER_OK_MUTANT="$WORK/mutant-footer-ok.sh"
# shellcheck disable=SC2016  # sed script over check-manifest.sh's own source: literal, not shell.
sed 's/if \[ "\$FOOTER_OK" -eq 0 \]; then/if false; then/' "$CHECK_SH" > "$FOOTER_OK_MUTANT"
if cmp -s "$FOOTER_OK_MUTANT" "$CHECK_SH"; then
  report "mutation probe 'footer-ok': the sed expression changed nothing — the anchor line moved"
else
  SCRIPT_UNDER_TEST="$FOOTER_OK_MUTANT" run "$D_BJFNB" probe-footer-ok
  if grep -qF 'PASS footer-agree' "$OUT/probe-footer-ok.out"; then
    echo "PASS: mutation probe footer-ok (neutering the FOOTER_OK guard restores PASS footer-agree on an unparseable footer)"
  else
    report "mutation probe 'footer-ok': neutering the guard did not restore the false PASS footer-agree — this check may not be what prevents it"
    sed 's/^/    /' "$OUT/probe-footer-ok.out" >&2
  fi
fi
# The bare-echo boundary: with the next-command rule removed the scan falls back
# to the prompt-only boundary, finds none on this log, and credits `echo one`
# with `echo two`'s marker — the fixture goes green, which is the false PASS.
probe bare-echo   "$D_BARE"     "s/if (line in is_cmd) exit }/}/"
# The skip status: with the exit-3 line removed, the off-disk-log fixture is
# indistinguishable from a fully-verified run by exit code.
SKIP_MUTANT="$WORK/mutant-skip-status.sh"
sed '/exit 3$/d' "$CHECK_SH" > "$SKIP_MUTANT"
if cmp -s "$SKIP_MUTANT" "$CHECK_SH"; then
  report "mutation probe 'skip-status': the sed changed nothing — the exit line moved"
else
  SCRIPT_UNDER_TEST="$SKIP_MUTANT" run "$D_ABS" probe-skip-status
  if [ "$RC" -eq 0 ]; then
    echo "PASS: mutation probe skip-status (without it, a skipped run exits 0 like a verified one)"
  else
    report "mutation probe 'skip-status': removing the exit-3 line did not make the skipped run exit 0 (got $RC)"
  fi
fi

# ===========================================================================
# An entry containing a backslash escape is matched literally, not with the
# escape expanded. The manifest is honest and every check must pass; a FAIL
# here is the worst verdict this script can give, since it sends an author
# hunting for a defect in a log that is correct.
# ===========================================================================
sed -e "s#$GOOD_LOG#$ESCAPE_LOG#g" -e "s#$GOOD_SHA#$ESCAPE_SHA#g" \
    -e "s#^  - \`command -v markdownlint markdownlint-cli2\`\$#  - \`tr '\\\\n' ' ' < docs/process/testing.md | grep -c 'no suites'\`#" \
    -e "s#command -v markdownlint markdownlint-cli2\"} -->#tr '\\\\\\\\n' ' ' < docs/process/testing.md | grep -c 'no suites'\"} -->#" \
    "$WORK/good.md" > "$WORK/escape.md"
if cmp -s "$WORK/escape.md" "$WORK/good.md"; then
  report "escape: the fixture edit changed nothing — the good manifest's shape moved"
fi
D_ESCAPE="$(mkcase escape "$WORK/escape.md")"
run "$D_ESCAPE" escape
expect_rc escape 0
expect_line escape "PASS commands"
expect_line escape "all 2 entries echoed verbatim, each with its own [exit=N]"

# Inverted probe. The other probes neuter a guard and assert the fixture goes
# green; this one restores the defect and asserts an HONEST fixture goes red,
# which is the only way to show the ENVIRON hand-off is what keeps it green.
ESC_MUTANT="$WORK/mutant-escape-v.sh"
sed -e 's/^    ln=$(CM_ENTRY="$c" awk .$/    ln=$(awk -v cmd="$c" '"'"'/' \
    -e '/^      BEGIN { cmd = ENVIRON\["CM_ENTRY"\] }$/d' \
    "$CHECK_SH" > "$ESC_MUTANT"
if cmp -s "$ESC_MUTANT" "$CHECK_SH"; then
  report "mutation probe 'escape-v': the sed changed nothing — the ENVIRON hand-off moved"
else
  SCRIPT_UNDER_TEST="$ESC_MUTANT" run "$D_ESCAPE" probe-escape-v
  if [ "$RC" -ne 0 ] && grep -qF "the log does not echo" "$RUN_OUT"; then
    echo "PASS: mutation probe escape-v (awk -v re-expands the escape and false-FAILs an honest manifest)"
  else
    report "mutation probe 'escape-v': reverting to awk -v did not false-FAIL the honest fixture"
    sed 's/^/    /' "$RUN_OUT" >&2
  fi
fi

# The `-r` guard on the sidecar (round 2, note 6). Without it the unreadable
# sidecar aborts the run under `set -euo pipefail`: the process exits 2 — the
# code reserved for an argument error — and `exit-count` never reports at all.
if [ -n "$D_UNREAD" ]; then
  UNREAD_MUTANT="$WORK/mutant-sidecar-readable.sh"
  # shellcheck disable=SC2016  # sed over check-manifest.sh's own source: literal, not shell.
  sed 's/    if \[ -r "\$RESOLVED.exits" \]; then/    if true; then/' "$CHECK_SH" > "$UNREAD_MUTANT"
  if cmp -s "$UNREAD_MUTANT" "$CHECK_SH"; then
    report "mutation probe 'sidecar-readable': the sed changed nothing — the guard moved"
  else
    SCRIPT_UNDER_TEST="$UNREAD_MUTANT" run "$D_UNREAD" probe-sidecar-readable
    if [ "$RC" -eq 2 ] && ! grep -q 'exit-count' "$RUN_OUT"; then
      echo "PASS: mutation probe sidecar-readable (without the guard the run aborts at exit 2 and the report is truncated)"
    else
      report "mutation probe 'sidecar-readable': removing the -r guard neither aborted at exit 2 nor truncated the report (got $RC)"
      sed 's/^/    /' "$RUN_OUT" >&2
    fi
  fi
fi
# Restored so the suite leaves nothing unreadable behind for its own cleanup.
chmod 600 "$UNREAD_LOG.exits"

if [ "$fail" -ne 0 ]; then
  echo "test_check_manifest: FAILED" >&2
  exit 1
fi
echo "test_check_manifest: all assertions passed"
