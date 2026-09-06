#!/usr/bin/env bash
# test_batch_deferred.sh — fixture-driven regression test for
# batch-deferred.sh. Follows the mock-`gh` harness conventions in
# tests/README.md: a mocked `gh` binary on PATH serves fixture JSON from a
# private mktemp scratch dir, refuses any explicit non-GET verb, and no
# real network call is ever reachable. Pinned to LANG=C / LC_ALL=C for the
# same reason test_preflight.sh / test_board_audit.sh are: nothing under
# test is locale-sensitive, and pinning here catches a future regression
# that would make it so.
#
# Covers (structured `Unit:` marker derivation, #751 — the settled
# lexical/normalisation contract SKILL.md's Deferred Items rule and
# maintenance.md § 1 step 9 landed via #800/#808 `0261c13`; replaces the
# old Affected-Files-row-1 / backtick-fallback / area-label-fallback suite
# this file used to carry; none of those paths exist in the script
# anymore):
#  - a valid marker naming a script file path: three issues sharing unit
#    foo (one via the script's own path, one via its test's underscored
#    path, one via a hyphenated `test-foo.sh` spelling — all three fold to
#    the same bare stem) cross the >=3 dispatch threshold.
#  - a valid marker naming a directory path (trailing `/`) — mapped to
#    itself WITH the trailing slash kept, never reduced to a parent, and
#    below threshold as a single member.
#  - a valid marker naming an `area:*` label — the third legal form, for a
#    finding with no path at all — mapped to that label unchanged.
#  - a `Unit:` line separated from its value by a literal TAB, not a
#    space — legal under SKILL.md's `[[:blank:]]` lexical rule; this is
#    the exact case that cost #800/#808 a full review round when an
#    extractor used the bracket expression `[ \t]` instead (which, in a
#    POSIX ERE, means the three-character set {space, backslash, `t`}, not
#    "space or tab").
#  - a `Unit:` value naming a repo-ROOT file with no directory component
#    at all (`AGENTS.md`) — keys to `./`, the repo root itself, never the
#    filename with a slash appended (`AGENTS.md/`, which is not a
#    directory under any reading); a relayed PR #830 round-1 finding.
#  - no `Unit:` line anywhere in the body — excluded, with a stated
#    reason, never silently dropped.
#  - the exact-form requirement, three look-alike shapes that all land in
#    the SAME "no marker" excluded bucket as a body with no line at all:
#    wrong case (`unit:`), no whitespace after the colon (`Unit:path`),
#    and `Unit:` appearing mid-sentence rather than at the start of its
#    own line.
#  - TWO `Unit:` lines in the same body — NOT an error: the first line
#    wins and the second is silently ignored, per SKILL.md's explicit
#    "the first matching line … any later one is ignored". (This suite
#    used to treat two lines as an ambiguity error before the settled
#    text landed; that was wrong and is corrected here.)
#  - a single `Unit:` line whose value lists two paths, comma-separated —
#    excluded as malformed (not one of the three legal forms).
#  - a `Unit:` value wrapped in backticks — excluded as malformed: the
#    settled lexical rule explicitly forbids backticks ("no bold, no
#    backticks, no list marker"), unlike this suite's own pre-#808 guess.
#  - a marker value containing whitespace inside what should be a single
#    path (outside the path-safe charset) — excluded as malformed.
#  - a marker value carrying trailing punctuation (a sentence period) —
#    excluded as malformed: "nothing else may share the line … no
#    trailing punctuation".
#  - an `area:*` value with an uppercase letter — excluded as malformed
#    (no real area label in this repo is anything but lowercase kebab).
#  - a marker that maps, via the script/test convention, to an EMPTY unit
#    string (a bare `test_.sh`) — excluded with a reason naming the value
#    that was found, never silently dropped.
#  - all three PRE-derivation exclusions, unchanged by #751: a
#    `blocked by` link, a `question`-labelled (decision-shaped) item, and
#    a planned child of an epic (parent set AND the parent itself carries
#    the `epic` label) — each reported in `excluded[]`, never folded into
#    a batch. A same-shaped issue with a parent that is NOT epic-labelled
#    is the mutation-probe pair proving the epic-label half of that
#    exclusion is load-bearing (two variants: `area:epic`, an area label
#    merely containing the word, and `epic-blocked`, a label merely
#    containing the substring).
#  - the >=3 dispatch threshold, both sides: a 2-member unit (below) vs.
#    the same unit at 3 members (at threshold) — the same base fixture
#    set, one added issue, is the mutation probe.
#  - the ~8 member cap: a 9-member unit splits into an 8-member dispatchable
#    batch and a 1-member waiting remainder of the same unit, never one
#    9-member batch.
#  - milestone-wide flush: a unit below threshold whose sole milestone has
#    zero open non-`deferred` issues flushes (dispatchable); the same shape
#    with an open planned child left does not. A milestone-less member
#    counts toward the flush of the milestone the rest of the unit shares.
#  - --flush: forces dispatchable on the same not-yet-flushed fixture
#    without the script issuing the extra flush-check GET at all (asserted
#    against the mock's call log).
#  - repo-wide mode (no --milestone): a unit whose two members carry two
#    DIFFERENT real milestones never flushes, even when both of those
#    milestones individually have zero open planned children.
#  - --markdown renders a `triage.batches`-shaped JSON block
#    (`{unit, members:[N,…], dispatchable}`), matching
#    formats/maintenance-report.md.
#  - argument errors: an unknown flag, --max < --min, and non-canonical
#    --min/--max/--milestone forms (leading zero) — routed through the
#    mock exactly like the success paths (#477-style hermeticity).
#  - the mock records no non-GET verb, and a tripwire asserts no call ever
#    arrived from an unmocked context.
set -euo pipefail
export LANG=C LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BATCH_DEFERRED_SRC="$SCRIPT_DIR/../scripts/batch-deferred.sh"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/batch-deferred-test.XXXXXX")"
cleanup(){ rm -rf "$WORK"; }
trap cleanup EXIT

BIN="$WORK/bin"
OUT="$WORK/out"
mkdir -p "$BIN" "$OUT"

# The splice probes below mutate the script under test in place (backup,
# sed, run, restore). Doing that against the shared, TRACKED
# scripts/batch-deferred.sh is unsafe: two concurrent runs of this suite
# interleave their splices and each restores from its own backup, which
# may have been taken while the other run's splice was still live (#865),
# and a crashed or interrupted run before the restore step leaves the
# tracked file mutated on disk for every other agent (#857). Every
# invocation in this suite — spliced or not — instead runs a private
# per-run copy inside this suite's own mktemp -d, which is unique per
# process and removed by `cleanup` above regardless of how the run ends.
# The tracked file itself is only ever read (cp), never written.
BATCH_DEFERRED_SH="$WORK/batch-deferred.sh"
cp "$BATCH_DEFERRED_SRC" "$BATCH_DEFERRED_SH"
# batch-deferred.sh sources its sibling lib/project-items-walk.sh (#867) by
# a path relative to its own location, so the private copy needs that
# sibling directory copied alongside it too.
mkdir -p "$WORK/lib"
cp "$SCRIPT_DIR/../scripts/lib/project-items-walk.sh" "$WORK/lib/project-items-walk.sh"

# Regression guard for the private-copy mechanism itself (round-1 finding
# 1): every splice probe below mutates "$BATCH_DEFERRED_SH", never
# "$BATCH_DEFERRED_SRC" — the existing restore checks only compare the
# spliced file against its OWN backup, so they pass identically whether
# that file is the private copy or (if the mechanism above were ever
# reverted) the shared tracked source. Recording each tracked file's
# digest here, before any splice runs, and re-checking it unchanged at the
# very end of the suite is a second layer: a revert of BATCH_DEFERRED_SH
# to "$BATCH_DEFERRED_SRC" is caught by the $WORK check below, while these
# digests catch a splice probe whose restore never puts the file back.
BATCH_DEFERRED_SRC_SHA_BEFORE="$(sha256sum "$BATCH_DEFERRED_SRC" | awk '{print $1}')"
PROJECT_ITEMS_WALK_SRC="$SCRIPT_DIR/../scripts/lib/project-items-walk.sh"
PROJECT_ITEMS_WALK_SRC_SHA_BEFORE="$(sha256sum "$PROJECT_ITEMS_WALK_SRC" | awk '{print $1}')"

fail=0
report(){ echo "FAIL: $*" >&2; fail=1; }

LABELS_SEEN="$WORK/labels-seen.log"
: > "$LABELS_SEEN"

# ---------------------------------------------------------------------------
# Fixture builder: one JSON array element per open `deferred` issue, in the
# real REST shape `gh api repos/<o>/<r>/issues?...` actually returns (a
# handful of fields only — the script's own --jq narrows to these before the
# mock ever sees a full record, so fixtures are pre-narrowed the same way a
# real page's --jq output would be BUT the mock re-applies the script's own
# --jq expression against a FULL issue-shaped fixture, exactly as
# test_board_audit.sh's `apply()` does — so a fixture here is a full issue
# object, not a pre-narrowed one, and a defect in the script's own --jq
# expression is caught the same way it would be against the real API.
# ---------------------------------------------------------------------------
issue_json(){ # issue_json <number> <title> <body-file> <labels-csv> <milestone|null> <parent-url|null> <blocked_by>
  local n="$1" t="$2" bodyfile="$3" labels_csv="$4" ms="$5" purl="$6" bb="$7"
  jq -n --argjson n "$n" --arg t "$t" --rawfile body "$bodyfile" --arg labels "$labels_csv" \
    --argjson ms "$ms" --arg purl "$purl" --argjson bb "$bb" \
    '{number:$n, title:$t, body:$body, pull_request:null,
      labels:($labels|split(",")|map(select(length>0)|{name:.})),
      milestone:(if $ms==null then null else {number:$ms} end),
      parent_issue_url:(if $purl=="" then null else $purl end),
      issue_dependencies_summary:{blocked_by:$bb}}'
}

REPO_MAIN="test-org/main-repo"
MAIN="$WORK/fixtures-main"
mkdir -p "$MAIN"

# --- bodies ---
B101="$MAIN/b101.md"; cat > "$B101" <<'MD'
## Home
Milestone: story X. No epic parent. Spawned by #700.
Unit: .claude/skills/github-workflow/scripts/foo.sh

## Verified expectation
`n/a`.
MD
B102="$MAIN/b102.md"; cat > "$B102" <<'MD'
## Home
Milestone: story X. No epic parent. Spawned by #700.
Unit: .claude/skills/github-workflow/tests/test_foo.sh

## Verified expectation
`n/a`.
MD
B103="$MAIN/b103.md"; cat > "$B103" <<'MD'
## Home
Milestone: story X. No epic parent. Spawned by #700.
Unit: docs/other/

## Verified expectation
`n/a`.
MD
B104="$MAIN/b104.md"; cat > "$B104" <<'MD'
## Home
Milestone: story X. No epic parent. Spawned by #700.
No Unit: line at all in this body — must be excluded, never silently
dropped and never guessed at from any other field.

## Verified expectation
`n/a`.
MD
B105="$MAIN/b105.md"; cat > "$B105" <<'MD'
## Home
Milestone: story X. No epic parent. Spawned by #700.
unit: wrong-case/

## Verified expectation
`n/a`.
MD
B106="$MAIN/b106.md"; cat > "$B106" <<'MD'
## Home
Milestone: story X. No epic parent. Spawned by #700.
Unit: scripts/blocked.sh

## Verified expectation
`n/a`.
MD
B107="$MAIN/b107.md"; cat > "$B107" <<'MD'
## Home
Milestone: story X. No epic parent. Spawned by #700.
Unit: scripts/question.sh

## Verified expectation
`n/a`.
MD
B108="$MAIN/b108.md"; cat > "$B108" <<'MD'
## Home
Milestone: story X. No epic parent. Spawned by #700.
Unit: scripts/epicchild.sh

## Verified expectation
`n/a`.
MD
B109="$MAIN/b109.md"; cat > "$B109" <<'MD'
## Home
Milestone: story X. No epic parent. Spawned by #700.
Unit: .claude/skills/github-workflow/scripts/baz.sh

## Verified expectation
`n/a`.
MD
B114="$MAIN/b114.md"; cat > "$B114" <<'MD'
## Summary
Parent is labelled `area:epic` — an AREA label, not the `epic` type label, so this
child is NOT a planned epic child and must not be excluded.

## Home
Milestone: story X. No epic parent. Spawned by #700.
Unit: .claude/skills/github-workflow/scripts/areaepicchild.sh

## Verified expectation
`n/a`.
MD
B115="$MAIN/b115.md"; cat > "$B115" <<'MD'
## Summary
Parent is labelled `epic-blocked` — a label that merely CONTAINS "epic", so this child
is NOT a planned epic child and must not be excluded.

## Home
Milestone: story X. No epic parent. Spawned by #700.
Unit: .claude/skills/github-workflow/scripts/epicblockedchild.sh

## Verified expectation
`n/a`.
MD
B116="$MAIN/b116.md"; cat > "$B116" <<'MD'
## Home
Milestone: story X. No epic parent. Spawned by #700.
Unit: alpha-tool/
Unit: beta-tool/

## Verified expectation
`n/a`.
MD
B117="$MAIN/b117.md"; cat > "$B117" <<'MD'
## Home
Milestone: story X. No epic parent. Spawned by #700.
Unit: scripts/rowone.sh, scripts/rowtwo.sh

## Verified expectation
`n/a`.
MD
B118="$MAIN/b118.md"; cat > "$B118" <<'MD'
## Home
Milestone: story X. No epic parent. Spawned by #700.
Unit: `scripts/rowone.sh`

## Verified expectation
`n/a`.
MD
B119="$MAIN/b119.md"; cat > "$B119" <<'MD'
## Home
Milestone: story X. No epic parent. Spawned by #700.
Unit: scripts/foo bar.sh

## Verified expectation
`n/a`.
MD
B120="$MAIN/b120.md"; cat > "$B120" <<'MD'
## Home
Milestone: story X. No epic parent. Spawned by #700.
Unit: test_.sh

## Verified expectation
`n/a`.
MD
B121="$MAIN/b121.md"; cat > "$B121" <<'MD'
## Home
Milestone: story X. No epic parent. Spawned by #700.
Unit:scripts/no-space-after-colon.sh
See the Unit: scripts/mid-sentence.sh field above for the unit.

## Verified expectation
`n/a`.
MD
B124="$MAIN/b124.md"; cat > "$B124" <<'MD'
## Home
Milestone: story X. No epic parent. Spawned by #700.
Unit: scripts/trailing-period.sh.

## Verified expectation
`n/a`.
MD
B125="$MAIN/b125.md"; cat > "$B125" <<'MD'
## Summary
A finding with no path at all — a process question, not a file. The third
legal `Unit:` value form: an `area:*` label.

## Home
Milestone: story X. No epic parent. Spawned by #700.
Unit: area:skills

## Verified expectation
`n/a`.
MD
B126="$MAIN/b126.md"; cat > "$B126" <<'MD'
## Home
Milestone: story X. No epic parent. Spawned by #700.
Unit: area:Skills

## Verified expectation
`n/a`.
MD
BMANY="$MAIN/bmany.md"; cat > "$BMANY" <<'MD'
## Home
Milestone: story X. No epic parent. Spawned by #700.
Unit: .claude/skills/github-workflow/scripts/many.sh

## Verified expectation
`n/a`.
MD
B111="$MAIN/b111.md"; cat > "$B111" <<'MD'
## Home
Milestone: story X. No epic parent. Spawned by #700.
Unit: .claude/skills/github-workflow/scripts/multi-word.sh

## Verified expectation
`n/a`.
MD
B112="$MAIN/b112.md"; cat > "$B112" <<'MD'
## Home
Milestone: story X. No epic parent. Spawned by #700.
Unit: .claude/skills/github-workflow/tests/test_multi_word.sh

## Verified expectation
`n/a`.
MD
B113="$MAIN/b113.md"; cat > "$B113" <<'MD'
## Home
Milestone: story X. No epic parent. Spawned by #700.
Unit: .claude/skills/github-workflow/scripts/test-multi-word.sh

## Verified expectation
`n/a`.
MD
B127="$MAIN/b127.md"
# shellcheck disable=SC2016 # single-quoted on purpose: the backtick in the literal text is not meant to expand
printf '## Home\nMilestone: story X. No epic parent. Spawned by #700.\nUnit:\t.claude/skills/github-workflow/scripts/tabsep.sh\n\n## Verified expectation\n`n/a`.\n' > "$B127"
B128="$MAIN/b128.md"; cat > "$B128" <<'MD'
## Summary
A repo-ROOT file — no directory component at all. step 9's own examples
never exercise this case (PR #830 round-1 relayed finding): the old code
keyed this to `AGENTS.md/`, the filename with a slash appended, not a
directory at all.

## Home
Milestone: story X. No epic parent. Spawned by #700.
Unit: AGENTS.md

## Verified expectation
`n/a`.
MD

# Each issue is built as its own temp file and the whole milestone-10
# fixture is one `jq -s` slurp over all of them — file-per-issue avoids any
# hand-joined-JSON string fragility.
MS10_ITEMS="$MAIN/ms10-items"
mkdir -p "$MS10_ITEMS"
issue_json 101 "feat(foo): script-path unit marker, member 1 of 3" "$B101" "deferred,priority:high,area:skills" 10 "" 0 > "$MS10_ITEMS/101.json"
issue_json 102 "feat(foo): test-path (underscore) unit marker, member 2 of 3" "$B102" "deferred,priority:low,area:skills" 10 "" 0 > "$MS10_ITEMS/102.json"
issue_json 103 "docs(other): directory unit marker, below threshold" "$B103" "deferred,priority:medium,area:skills" 10 "" 0 > "$MS10_ITEMS/103.json"
issue_json 104 "chore(no-marker): no Unit: line at all" "$B104" "deferred,priority:low,area:skills" 10 "" 0 > "$MS10_ITEMS/104.json"
issue_json 105 "chore(no-marker): wrong-case token does not count" "$B105" "deferred,area:skills" 10 "" 0 > "$MS10_ITEMS/105.json"
issue_json 106 "chore(blocked): excluded via blocked-by link" "$B106" "deferred,priority:low,area:skills" 10 "" 1 > "$MS10_ITEMS/106.json"
issue_json 107 "question(decision): excluded via question label" "$B107" "deferred,question,priority:low,area:skills" 10 "" 0 > "$MS10_ITEMS/107.json"
issue_json 108 "chore(epicchild): excluded via epic parent" "$B108" "deferred,priority:low,area:skills" 10 "https://api.github.com/repos/test-org/main-repo/issues/999" 0 > "$MS10_ITEMS/108.json"
issue_json 109 "chore(baz): non-epic parent, not excluded" "$B109" "deferred,priority:low,area:skills" 10 "https://api.github.com/repos/test-org/main-repo/issues/998" 0 > "$MS10_ITEMS/109.json"
issue_json 114 "chore(areaepicchild): parent labelled area:epic, not excluded" "$B114" "deferred,priority:low,area:skills" 10 "https://api.github.com/repos/test-org/main-repo/issues/997" 0 > "$MS10_ITEMS/114.json"
issue_json 115 "chore(epicblockedchild): parent labelled epic-blocked, not excluded" "$B115" "deferred,priority:low,area:skills" 10 "https://api.github.com/repos/test-org/main-repo/issues/996" 0 > "$MS10_ITEMS/115.json"
issue_json 116 "chore(dup-marker): two Unit: lines, first wins" "$B116" "deferred,priority:low,area:skills" 10 "" 0 > "$MS10_ITEMS/116.json"
issue_json 117 "chore(comma-marker): one Unit: line, two comma-separated values" "$B117" "deferred,priority:low,area:skills" 10 "" 0 > "$MS10_ITEMS/117.json"
issue_json 118 "chore(backtick-marker): backtick-wrapped value is now malformed" "$B118" "deferred,priority:low,area:skills" 10 "" 0 > "$MS10_ITEMS/118.json"
issue_json 119 "chore(bad-charset): whitespace inside the path value" "$B119" "deferred,priority:low,not-area:skills,area:skills" 10 "" 0 > "$MS10_ITEMS/119.json"
issue_json 120 "chore(degenerate-unit): bare test_.sh marker maps to empty unit" "$B120" "deferred,priority:low,area:skills" 10 "" 0 > "$MS10_ITEMS/120.json"
issue_json 121 "chore(look-alike): no space after colon, and mid-sentence occurrence" "$B121" "deferred,area:skills" 10 "" 0 > "$MS10_ITEMS/121.json"
issue_json 124 "chore(trailing-punctuation): sentence period after the value" "$B124" "deferred,priority:low,area:skills" 10 "" 0 > "$MS10_ITEMS/124.json"
issue_json 125 "chore(area-label): no path at all, area:* marker form" "$B125" "deferred,priority:low,area:skills" 10 "" 0 > "$MS10_ITEMS/125.json"
issue_json 126 "chore(area-label): uppercase area value is malformed" "$B126" "deferred,priority:low,area:skills" 10 "" 0 > "$MS10_ITEMS/126.json"
issue_json 127 "chore(tabsep): Unit: separated from its value by a tab" "$B127" "deferred,priority:low,area:skills" 10 "" 0 > "$MS10_ITEMS/127.json"
issue_json 128 "chore(repo-root): Unit: names a repo-root file with no directory" "$B128" "deferred,priority:low,area:skills" 10 "" 0 > "$MS10_ITEMS/128.json"
issue_json 110 "feat(foo): script-path unit marker, member 3 of 3 — crosses the threshold" "$B101" "deferred,priority:medium,area:skills" 10 "" 0 > "$MS10_ITEMS/110.json"
issue_json 111 "chore(multi-word): script-path marker" "$B111" "deferred,priority:low,area:skills" 10 "" 0 > "$MS10_ITEMS/111.json"
issue_json 112 "chore(multi-word): test-path marker (underscore folded)" "$B112" "deferred,priority:low,area:skills" 10 "" 0 > "$MS10_ITEMS/112.json"
issue_json 113 "chore(multi-word): test-path marker (hyphen form test-<x>.sh)" "$B113" "deferred,priority:low,area:skills" 10 "" 0 > "$MS10_ITEMS/113.json"
# many-unit: 9 members, priorities descending high/medium/low so the split
# is deterministic (highest 8 dispatchable, #209 the lowest-priority the
# remainder) — issue numbers ascend with priority descending so a
# number-only sort would get this wrong and only a rank-aware sort passes.
i=201
for p in high high high medium medium medium low low low; do
  issue_json "$i" "chore(many): cap-split member $i" "$BMANY" "deferred,priority:$p,area:skills" 10 "" 0 \
    > "$MS10_ITEMS/$i.json"
  i=$((i+1))
done
jq -s '.' "$MS10_ITEMS"/*.json > "$MAIN/deferred_ms10.json"
echo '[]' > "$MAIN/deferred_none.json"
echo '{"labels":[{"name":"epic"}]}' > "$MAIN/parent_999.json"
echo '{"labels":[{"name":"chore"}]}' > "$MAIN/parent_998.json"
# Substring/word-boundary parents: `area:epic` and `epic-blocked` both CONTAIN
# "epic" as a `grep -w` word (":" and "-" are non-word characters), but neither
# IS the `epic` type label, so neither child is a planned epic child. These two
# are the fixtures that fail under a `grep -qw 'epic'` match and pass only under
# the exact `grep -qx 'epic'` match over the comma-split label list.
echo '{"labels":[{"name":"area:epic"},{"name":"chore"}]}' > "$MAIN/parent_997.json"
echo '{"labels":[{"name":"epic-blocked"}]}' > "$MAIN/parent_996.json"
# milestone 10's own flush check: at least one open non-deferred issue, so
# this milestone never auto-flushes in the MAIN scenario (threshold-only).
echo '[{"number":9001,"pull_request":null,"labels":[{"name":"enhancement"}]}]' > "$MAIN/flush_ms10.json"
# MAIN carries no parked riders (#802) and no board-status GET (--work-tracking
# points at a file that never exists here) — empty parked pool for both GETs
# the --milestone 10 scoping issues.
echo '[]' > "$MAIN/parked_ms10.json"
echo '[]' > "$MAIN/parked_none.json"
# ---------------------------------------------------------------------------
# CAPSPLIT: the cap-split boundary written from the rule ("remainder waits
# as its own batch"), not from the implementation — N=16 (an exact multiple
# of --max) and N=17 (one more than an exact multiple), the two shapes the
# off-by-one in `remaining -gt MAX` got wrong: at N=16 the second 8-member
# chunk IS the whole remainder (nothing after it), so it must be
# dispatchable, not waiting; a test written only at N=9 never exercises
# this because 9's remainder (1) is never itself a full MAX-sized chunk.
# ---------------------------------------------------------------------------
REPO_CAPSPLIT="test-org/capsplit-repo"
CAPSPLIT="$WORK/fixtures-capsplit"
mkdir -p "$CAPSPLIT"
BCAP16="$CAPSPLIT/cap16.md"; cat > "$BCAP16" <<'MD'
## Home
Milestone: story X. No epic parent. Spawned by #700.
Unit: scripts/cap16.sh

## Verified expectation
`n/a`.
MD
BCAP17="$CAPSPLIT/cap17.md"; cat > "$BCAP17" <<'MD'
## Home
Milestone: story X. No epic parent. Spawned by #700.
Unit: scripts/cap17.sh

## Verified expectation
`n/a`.
MD
: > "$CAPSPLIT/all.jsonl"
i=601
while [ "$i" -le 616 ]; do
  issue_json "$i" "chore(cap16): cap-split-16 member $i" "$BCAP16" "deferred,priority:low,area:skills" null "" 0 \
    >> "$CAPSPLIT/all.jsonl"
  i=$((i+1))
done
i=701
while [ "$i" -le 717 ]; do
  issue_json "$i" "chore(cap17): cap-split-17 member $i" "$BCAP17" "deferred,priority:low,area:skills" null "" 0 \
    >> "$CAPSPLIT/all.jsonl"
  i=$((i+1))
done
jq -s '.' "$CAPSPLIT/all.jsonl" > "$CAPSPLIT/deferred_all.json"
echo '[]' > "$CAPSPLIT/parked_all.json"

# ---------------------------------------------------------------------------
# FLUSHY: a 2-member unit (below threshold) whose milestone has zero open
# planned (non-deferred) children — flushes. One member carries no
# milestone at all, proving that rule too.
# ---------------------------------------------------------------------------
REPO_FLUSHY="test-org/flushy-repo"
FLUSHY="$WORK/fixtures-flushy"
mkdir -p "$FLUSHY"
BF="$FLUSHY/b.md"; cat > "$BF" <<'MD'
## Home
Milestone: story X. No epic parent. Spawned by #700.
Unit: scripts/flushme.sh

## Verified expectation
`n/a`.
MD
jq -s '.' <(issue_json 401 "flush member with milestone" "$BF" "deferred,priority:low,area:skills" 20 "" 0) \
  > "$FLUSHY/deferred_ms20.json"
jq -s '.' <(issue_json 402 "flush member with no milestone" "$BF" "deferred,priority:low,area:skills" null "" 0) \
  > "$FLUSHY/deferred_none.json"
echo '[{"number":9002,"pull_request":null,"labels":[{"name":"deferred"}]}]' > "$FLUSHY/flush_ms20.json"
echo '[]' > "$FLUSHY/parked_ms20.json"
echo '[]' > "$FLUSHY/parked_none.json"

# ---------------------------------------------------------------------------
# NOFLUSHY: a 1-member unit whose milestone still has an open planned
# (non-deferred) child — does not flush. Also the --flush override target.
# ---------------------------------------------------------------------------
REPO_NOFLUSHY="test-org/noflushy-repo"
NOFLUSHY="$WORK/fixtures-noflushy"
mkdir -p "$NOFLUSHY"
BN="$NOFLUSHY/b.md"; cat > "$BN" <<'MD'
## Home
Milestone: story X. No epic parent. Spawned by #700.
Unit: scripts/stuck.sh

## Verified expectation
`n/a`.
MD
jq -s '.' <(issue_json 501 "stuck member, milestone not flushed" "$BN" "deferred,priority:low,area:skills" 30 "" 0) \
  > "$NOFLUSHY/deferred_ms30.json"
echo '[]' > "$NOFLUSHY/deferred_none.json"
echo '[{"number":9003,"pull_request":null,"labels":[{"name":"enhancement"}]}]' > "$NOFLUSHY/flush_ms30.json"
echo '[]' > "$NOFLUSHY/parked_ms30.json"
echo '[]' > "$NOFLUSHY/parked_none.json"

# ---------------------------------------------------------------------------
# CONFLICT: repo-wide mode (no --milestone). Two members of the same unit
# carry two DIFFERENT real milestones (5 and 6), both individually zero-
# open-planned — the unit must still NOT flush (spans >1 real milestone).
# ---------------------------------------------------------------------------
REPO_CONFLICT="test-org/conflict-repo"
CONFLICT="$WORK/fixtures-conflict"
mkdir -p "$CONFLICT"
BC="$CONFLICT/b.md"; cat > "$BC" <<'MD'
## Home
Milestone: story X. No epic parent. Spawned by #700.
Unit: scripts/conflict.sh

## Verified expectation
`n/a`.
MD
jq -s '.' <(issue_json 301 "conflict member, milestone 5" "$BC" "deferred,priority:low,area:skills" 5 "" 0) \
          <(issue_json 302 "conflict member, milestone 6" "$BC" "deferred,priority:low,area:skills" 6 "" 0) \
  > "$CONFLICT/deferred_all.json"
echo '[{"number":9004,"pull_request":null,"labels":[{"name":"deferred"}]}]' > "$CONFLICT/flush_ms5.json"
echo '[{"number":9005,"pull_request":null,"labels":[{"name":"deferred"}]}]' > "$CONFLICT/flush_ms6.json"
echo '[]' > "$CONFLICT/parked_all.json"

# ---------------------------------------------------------------------------
# REPOVIEW: covers the --repo-omitted path (`gh repo view` fallback).
# ---------------------------------------------------------------------------
REPO_VIEW_NAME="test-org/autodetected-repo"
REPOVIEW="$WORK/fixtures-repoview"
mkdir -p "$REPOVIEW"
echo '[]' > "$REPOVIEW/deferred_all.json"
echo '[]' > "$REPOVIEW/parked_all.json"

# ---------------------------------------------------------------------------
# RIDERS (#802): a second, closed-issue `parked` pool. No --milestone (both
# pools read via the *_all.json endpoints), no board-status (no wt.md here).
#  - ridera: 3 open members (at threshold) + 1 matching parked candidate —
#    the rider MUST join, role rider.
#  - riderb: 2 open members (BELOW threshold) + 1 matching parked candidate —
#    the rider MUST NOT join; riderb stays a 2-member waiting batch.
#  - riderc: 7 open members (dispatchable, room=1 under --max 8) + 3 matching
#    parked candidates at priority low/high/medium — only the highest
#    priority one (#953, high) may join; the other two are left unplaced.
#  - riderd: 3 open members (at threshold) + 1 matching parked candidate that
#    carries a `Rejected: too flaky, not reproducible` comment — excluded
#    with that reason, never placed as a rider.
# ---------------------------------------------------------------------------
REPO_RIDERS="test-org/riders-repo"
RIDERS="$WORK/fixtures-riders"
mkdir -p "$RIDERS"
BRA="$RIDERS/ridera.md"; cat > "$BRA" <<'MD'
## Home
Milestone: none. No epic parent. Spawned by #700.
Unit: area:ridera

## Verified expectation
`n/a`.
MD
BRB="$RIDERS/riderb.md"; cat > "$BRB" <<'MD'
## Home
Milestone: none. No epic parent. Spawned by #700.
Unit: area:riderb

## Verified expectation
`n/a`.
MD
BRC="$RIDERS/riderc.md"; cat > "$BRC" <<'MD'
## Home
Milestone: none. No epic parent. Spawned by #700.
Unit: area:riderc

## Verified expectation
`n/a`.
MD
BRD="$RIDERS/riderd.md"; cat > "$BRD" <<'MD'
## Home
Milestone: none. No epic parent. Spawned by #700.
Unit: area:riderd

## Verified expectation
`n/a`.
MD
: > "$RIDERS/open.jsonl"
{
  issue_json 901 "chore(ridera): open member 1 of 3" "$BRA" "deferred,priority:low,area:skills" null "" 0
  issue_json 902 "chore(ridera): open member 2 of 3" "$BRA" "deferred,priority:low,area:skills" null "" 0
  issue_json 903 "chore(ridera): open member 3 of 3" "$BRA" "deferred,priority:low,area:skills" null "" 0
  issue_json 904 "chore(riderb): open member 1 of 2 (below threshold)" "$BRB" "deferred,priority:low,area:skills" null "" 0
  issue_json 905 "chore(riderb): open member 2 of 2 (below threshold)" "$BRB" "deferred,priority:low,area:skills" null "" 0
} >> "$RIDERS/open.jsonl"
i=906
while [ "$i" -le 912 ]; do
  issue_json "$i" "chore(riderc): open member $i of 7" "$BRC" "deferred,priority:low,area:skills" null "" 0 >> "$RIDERS/open.jsonl"
  i=$((i+1))
done
{
  issue_json 913 "chore(riderd): open member 1 of 3" "$BRD" "deferred,priority:low,area:skills" null "" 0
  issue_json 914 "chore(riderd): open member 2 of 3" "$BRD" "deferred,priority:low,area:skills" null "" 0
  issue_json 915 "chore(riderd): open member 3 of 3" "$BRD" "deferred,priority:low,area:skills" null "" 0
} >> "$RIDERS/open.jsonl"
jq -s '.' "$RIDERS/open.jsonl" > "$RIDERS/deferred_all.json"
: > "$RIDERS/parked.jsonl"
{
  issue_json 950 "chore(ridera): parked rider, must join" "$BRA" "deferred,parked,priority:low,area:skills" null "" 0
  issue_json 951 "chore(riderb): parked rider, unit not dispatchable, must NOT join" "$BRB" "deferred,parked,priority:low,area:skills" null "" 0
  issue_json 952 "chore(riderc): parked rider, priority low — excess, cap has no room" "$BRC" "deferred,parked,priority:low,area:skills" null "" 0
  issue_json 953 "chore(riderc): parked rider, priority high — the ONE that fits the cap" "$BRC" "deferred,parked,priority:high,area:skills" null "" 0
  issue_json 954 "chore(riderc): parked rider, priority medium — excess, cap has no room" "$BRC" "deferred,parked,priority:medium,area:skills" null "" 0
  issue_json 955 "chore(riderd): parked rider carrying a Rejected: comment" "$BRD" "deferred,parked,priority:low,area:skills" null "" 0
} >> "$RIDERS/parked.jsonl"
jq -s '.' "$RIDERS/parked.jsonl" > "$RIDERS/parked_all.json"
for n in 950 951 952 953 954; do echo '[]' > "$RIDERS/comments_$n.json"; done
echo '[{"body":"Rejected: too flaky, not reproducible"}]' > "$RIDERS/comments_955.json"

# ---------------------------------------------------------------------------
# INFLIGHT (#738): board Status excludes an in-flight member, and the
# `dispatchable` recompute happens AFTER that exclusion.
#  - inflightunit: 4 open members, #963 at Status "In review" — excluded,
#    leaves 3 real members, still dispatchable (>=3).
#  - belowunit: 3 open members, #972 at Status "In progress" — excluded,
#    leaves 2 real members, now BELOW threshold: dispatchable must flip to
#    false, not stay stale-true.
# ---------------------------------------------------------------------------
REPO_INFLIGHT="test-org/inflight-repo"
INFLIGHT="$WORK/fixtures-inflight"
mkdir -p "$INFLIGHT"
BIF="$INFLIGHT/inflightunit.md"; cat > "$BIF" <<'MD'
## Home
Milestone: none. No epic parent. Spawned by #700.
Unit: area:inflightunit

## Verified expectation
`n/a`.
MD
BBW="$INFLIGHT/belowunit.md"; cat > "$BBW" <<'MD'
## Home
Milestone: none. No epic parent. Spawned by #700.
Unit: area:belowunit

## Verified expectation
`n/a`.
MD
: > "$INFLIGHT/open.jsonl"
{
  issue_json 960 "chore(inflightunit): open, free" "$BIF" "deferred,priority:low,area:skills" null "" 0
  issue_json 961 "chore(inflightunit): open, free" "$BIF" "deferred,priority:low,area:skills" null "" 0
  issue_json 962 "chore(inflightunit): open, free" "$BIF" "deferred,priority:low,area:skills" null "" 0
  issue_json 963 "chore(inflightunit): in an open PR — Status In review" "$BIF" "deferred,priority:low,area:skills" null "" 0
  issue_json 970 "chore(belowunit): open, free" "$BBW" "deferred,priority:low,area:skills" null "" 0
  issue_json 971 "chore(belowunit): open, free" "$BBW" "deferred,priority:low,area:skills" null "" 0
  issue_json 972 "chore(belowunit): in an open PR — Status In progress" "$BBW" "deferred,priority:low,area:skills" null "" 0
} >> "$INFLIGHT/open.jsonl"
jq -s '.' "$INFLIGHT/open.jsonl" > "$INFLIGHT/deferred_all.json"
echo '[]' > "$INFLIGHT/parked_all.json"
# shellcheck disable=SC2016 # single-quoted on purpose: the backtick-wrapped id is literal fixture text, nothing here is meant to expand
echo '| Project | `PVT_test_inflight` |' > "$INFLIGHT/wt.md"
jq -n --arg repo "$REPO_INFLIGHT" '
  {data:{node:{items:{pageInfo:{hasNextPage:false,endCursor:null}, nodes:[
    {content:{number:963, repository:{nameWithOwner:$repo}}, status:{name:"In review"}},
    {content:{number:972, repository:{nameWithOwner:$repo}}, status:{name:"In progress"}},
    # A Project V2 board can hold items from several repositories. #960 is an
    # ORDINARY open member of area:inflightunit in THIS repo; the row below is
    # a different repo entirely that happens to reuse the number, and it must
    # not exclude our #960. Without the walk-level `select(...nameWithOwner==
    # $repo)` this row silently steals a member — the guard was unprobed
    # before round 1 (N4), so the [960,961,962] assertion below is now what
    # holds it in place.
    {content:{number:960, repository:{nameWithOwner:"other-org/other-repo"}}, status:{name:"In review"}}
  ]}}}}' > "$INFLIGHT/board_status.json"

# ---------------------------------------------------------------------------
# Mock gh: routes by endpoint shape, applying the real --jq expression via
# the real jq binary against a fixture, refuses any explicit non-GET verb,
# and tripwires any call arriving without the harness env (#477-style).
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
if [ "${1:-}" = "repo" ] && [ "${2:-}" = "view" ]; then
  if [ -n "${MOCK_GH_REPO_VIEW:-}" ]; then
    printf '%s\n' "$MOCK_GH_REPO_VIEW"
    exit 0
  fi
  echo "mock gh: repo view should not be called when --repo is passed" >&2
  exit 1
fi
if [ "${1:-}" != "api" ]; then
  echo "mock gh: unsupported command: $*" >&2
  exit 1
fi
shift
endpoint=""
jq_expr=""
method="GET"
explicit_method=0
implicit_write=0
paginate=0
while [ $# -gt 0 ]; do
  case "$1" in
    --paginate) paginate=1; shift ;;
    --jq) jq_expr="$2"; shift 2 ;;
    -X|--method) method="$2"; explicit_method=1; shift 2 ;;
    -X?*) method="${1#-X}"; explicit_method=1; shift ;;
    --method=*) method="${1#--method=}"; explicit_method=1; shift ;;
    -f|-F|--field|--raw-field|--input) implicit_write=1; shift 2 ;;
    *) endpoint="$1"; shift ;;
  esac
done
if [ "$explicit_method" -eq 0 ] && [ "$implicit_write" -eq 1 ] && [ "$endpoint" != "graphql" ]; then
  method="POST"
fi
if [ "$method" != "GET" ]; then
  echo "mock gh: refusing non-GET method ($method) on $endpoint" >&2
  exit 1
fi
apply(){ # apply <fixture-file>
  if [ ! -f "$1" ]; then
    echo "mock gh: no fixture at $1 for endpoint $endpoint" >&2
    exit 1
  fi
  if [ -n "$jq_expr" ]; then
    jq -c -r "$jq_expr" "$1"
  else
    cat "$1"
  fi
}
case "$endpoint" in
  *'issues?labels=deferred&state=open&milestone=none&per_page=100')
    apply "$MOCK_GH_FIXTURES/deferred_none.json" ;;
  *'issues?labels=deferred&state=open&milestone='*'&per_page=100')
    ms=$(printf '%s' "$endpoint" | grep -oP '(?<=milestone=)[0-9]+')
    apply "$MOCK_GH_FIXTURES/deferred_ms$ms.json" ;;
  *'issues?labels=deferred&state=open&per_page=100')
    apply "$MOCK_GH_FIXTURES/deferred_all.json" ;;
  *'issues?milestone='*'&state=open&per_page=100')
    ms=$(printf '%s' "$endpoint" | grep -oP '(?<=milestone=)[0-9]+')
    apply "$MOCK_GH_FIXTURES/flush_ms$ms.json" ;;
  *'issues?labels=parked&state=closed&milestone=none&per_page=100')
    apply "$MOCK_GH_FIXTURES/parked_none.json" ;;
  *'issues?labels=parked&state=closed&milestone='*'&per_page=100')
    ms=$(printf '%s' "$endpoint" | grep -oP '(?<=milestone=)[0-9]+')
    apply "$MOCK_GH_FIXTURES/parked_ms$ms.json" ;;
  *'issues?labels=parked&state=closed&per_page=100')
    apply "$MOCK_GH_FIXTURES/parked_all.json" ;;
  repos/*/issues/*/comments)
    n=$(printf '%s' "$endpoint" | grep -oP '(?<=issues/)[0-9]+(?=/comments$)')
    apply "$MOCK_GH_FIXTURES/comments_$n.json" ;;
  repos/*/issues/*)
    n=$(printf '%s' "$endpoint" | grep -oP '(?<=issues/)[0-9]+$')
    apply "$MOCK_GH_FIXTURES/parent_$n.json" ;;
  graphql)
    apply "$MOCK_GH_FIXTURES/board_status.json" ;;
  *)
    echo "mock gh: unknown endpoint: $endpoint" >&2
    exit 1 ;;
esac
MOCKGH
chmod +x "$BIN/gh"

REAL_GH="$(command -v gh || true)"
export PATH="$BIN:$PATH"
export MOCK_GH_CALL_LOG="$WORK/gh-calls.log"
: > "$MOCK_GH_CALL_LOG"
[ "$(command -v gh)" = "$BIN/gh" ] \
  || report "hermeticity: gh resolves to $(command -v gh), expected the mock at $BIN/gh"

# Sanity: the mock refuses a write verb outright.
if MOCK_GH_FIXTURES="$MAIN" PATH="$BIN:$PATH" gh api -X POST repos/x/y/issues 2>/dev/null; then
  report "mock sanity: expected the mock to refuse an explicit POST, but it succeeded"
fi

# board_args <fixtures> — the board-status arguments for a scenario.
# A scenario that deliberately creates "$fixtures/wt.md" (the #738 cases) runs
# the real Status walk against it; every other scenario opts OUT explicitly
# with --no-board-status. There is no third option any more: since #738 round
# 1 the exclusion fails closed, so simply pointing --work-tracking at a path
# that does not exist — which is what every pre-#738 scenario here used to do
# — is now a `die`, not a silent skip. That is the point of the change; these
# scenarios are not about the board, so they say so.
board_args(){ # board_args <fixtures>
  if [ -f "$1/wt.md" ]; then printf '%s\n%s\n' --work-tracking "$1/wt.md"
  else printf '%s\n' --no-board-status; fi
}

run_batch(){ # run_batch <fixtures> <repo> [args...]
  local fixtures="$1" repo="$2"; shift 2
  local label="run$RANDOM"
  local -a bargs=()
  while IFS= read -r a; do bargs+=("$a"); done < <(board_args "$fixtures")
  MOCK_GH_FIXTURES="$fixtures" PATH="$BIN:$PATH" \
    "$BATCH_DEFERRED_SH" --repo "$repo" "${bargs[@]}" "$@" >"$OUT/$label.stdout.log" 2>"$OUT/$label.stderr.log"
  local rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "run_batch $repo $*: exited $rc" >&2
    cat "$OUT/$label.stderr.log" >&2 || true
    report "batch-deferred.sh exited $rc for repo=$repo args: $*"
  fi
  printf '%s' "$OUT/$label.stdout.log"
}

run_argerr(){ # run_argerr <expected-exit> <label> <fixtures> <repo> [args...]
  local expect="$1" label="$2" fixtures="$3" repo="$4"; shift 4
  if grep -qxF "$label" "$LABELS_SEEN" 2>/dev/null; then
    report "run_argerr: duplicate label '$label' would overwrite a previous case's $OUT artifact"
  fi
  printf '%s\n' "$label" >> "$LABELS_SEEN"
  local rc=0
  set +e
  MOCK_GH_FIXTURES="$fixtures" PATH="$BIN:$PATH" \
    "$BATCH_DEFERRED_SH" --repo "$repo" "$@" >"$OUT/$label.stdout.log" 2>"$OUT/$label.stderr.log"
  rc=$?
  set -e
  [ "$rc" -eq "$expect" ] \
    || report "$label: expected exit $expect, got $rc: $(cat "$OUT/$label.stderr.log")"
}
# ===========================================================================
# ===========================================================================
# MAIN scenario — derivation paths, exclusions, threshold, cap split.
# ===========================================================================
MAIN_JSON=$(run_batch "$MAIN" "$REPO_MAIN" --milestone 10)

get_unit(){ jq -c --arg u "$1" '.batches[] | select(.unit==$u)' "$MAIN_JSON"; }

# --- unit foo: a script-path marker and its test-path marker fold to the
# same unit, crossing the >=3 threshold ---
foo_members=$(get_unit foo | jq -s 'map(.members)|add')
foo_issues=$(jq -c '[.[].issue]|sort' <<<"$foo_members")
[ "$foo_issues" = "[101,102,110]" ] \
  || report "unit foo: expected members [101,102,110], got $foo_issues"
foo_dispatchable=$(get_unit foo | jq -r .dispatchable)
[ "$foo_dispatchable" = "true" ] \
  || report "unit foo (3 members): expected dispatchable=true at the >=3 threshold, got $foo_dispatchable"
foo_derivations=$(jq -r '.[].derivation' <<<"$foo_members" | sort -u)
[ "$foo_derivations" = "unit-marker" ] \
  || report "unit foo: expected every member's derivation to be unit-marker, got: $foo_derivations"

# --- directory marker (trailing /) maps to itself, WITH the slash kept,
# never reduced to a parent ---
dir_unit=$(jq -r '.batches[] | select(.members[0].issue==103) | .unit' "$MAIN_JSON")
[ "$dir_unit" = "docs/other/" ] \
  || report "issue 103 (directory marker): expected unit docs/other/ (slash kept), got $dir_unit"
dir_dispatchable=$(jq -r '.batches[] | select(.members[0].issue==103) | .dispatchable' "$MAIN_JSON")
[ "$dir_dispatchable" = "false" ] \
  || report "unit docs/other/ (1 member): expected dispatchable=false (below threshold, no flush), got $dir_dispatchable"

# --- area:* label form (the third legal value, for a finding with no
# path at all) maps to that label unchanged ---
area_unit=$(jq -r '.batches[] | select(.members[0].issue==125) | .unit' "$MAIN_JSON")
[ "$area_unit" = "area:skills" ] \
  || report "issue 125 (area:* marker): expected unit area:skills, got $area_unit"

# --- three basename spellings for the SAME unit collapse together: a
# script's own path, its test's underscored path, and its test's
# hyphenated test-<x>.sh path — all three fold to the bare stem
# "multi-word", crossing the >=3 threshold. ---
mw_batch=$(jq -c '.batches[] | select(.unit=="multi-word")' "$MAIN_JSON")
mw_members=$(jq -c '[.members[].issue]|sort' <<<"$mw_batch")
[ "$mw_members" = "[111,112,113]" ] \
  || report "unit multi-word: expected members [111,112,113] (three basename spellings folded to one unit), got $mw_members"
[ "$(jq -r .dispatchable <<<"$mw_batch")" = "true" ] \
  || report "unit multi-word (3 members): expected dispatchable=true at the >=3 threshold"

# --- a Unit: line separated from its value by a TAB, not a space, is
# legal (SKILL.md's [[:blank:]] rule) — this is the exact case a
# hand-rolled [ \t] bracket expression gets wrong. ---
tabsep_unit=$(jq -r '.batches[] | select(.members[0].issue==127) | .unit' "$MAIN_JSON")
[ "$tabsep_unit" = "tabsep" ] \
  || report "issue 127 (tab-separated Unit: line): expected unit tabsep, got $tabsep_unit"
tabsep_derivation=$(jq -r '.batches[] | select(.members[0].issue==127) | .members[0].derivation' "$MAIN_JSON")
[ "$tabsep_derivation" = "unit-marker" ] \
  || report "issue 127: expected derivation unit-marker, got $tabsep_derivation"

# --- a repo-ROOT file (no directory component at all) keys to "./", the
# repo root itself, per dirname(1) — NOT the filename with a slash
# appended ("AGENTS.md/"), which is not a directory under any reading and
# was the relayed PR #830 round-1 defect. ---
reporoot_unit=$(jq -r '.batches[] | select(.members[0].issue==128) | .unit' "$MAIN_JSON")
[ "$reporoot_unit" = "./" ] \
  || report "issue 128 (repo-root file, no directory): expected unit ./ (dirname-consistent repo root), got $reporoot_unit"

# --- exclusions (unchanged by #751) ---
excluded_reason(){ jq -r --argjson n "$1" '.excluded[] | select(.issue==$n) | .reason' "$MAIN_JSON"; }
[ -n "$(excluded_reason 106)" ] || report "issue 106 (blocked_by=1): expected an excluded[] entry"
printf '%s' "$(excluded_reason 106)" | grep -qi 'blocked-by' \
  || report "issue 106: excluded reason should name the blocked-by link, got: $(excluded_reason 106)"
[ -n "$(excluded_reason 107)" ] || report "issue 107 (question label): expected an excluded[] entry"
printf '%s' "$(excluded_reason 107)" | grep -qi 'decision' \
  || report "issue 107: excluded reason should name it as decision-shaped, got: $(excluded_reason 107)"
[ -n "$(excluded_reason 108)" ] || report "issue 108 (epic parent): expected an excluded[] entry"
printf '%s' "$(excluded_reason 108)" | grep -qi 'planned child of epic' \
  || report "issue 108: excluded reason should name it as a planned epic child, got: $(excluded_reason 108)"
# Mutation-probe pair: #109 has a parent too, but that parent is NOT
# epic-labelled — proving the epic-label half of the check is load-bearing
# (a script that excluded on parent-presence alone would wrongly drop #109).
[ -z "$(excluded_reason 109)" ] \
  || report "issue 109 (non-epic parent): expected NOT excluded, got reason: $(excluded_reason 109)"
baz_unit=$(jq -r '.batches[] | select(.members[0].issue==109) | .unit' "$MAIN_JSON")
[ "$baz_unit" = "baz" ] || report "issue 109: expected unit baz, got $baz_unit"
# Exact-match probe pair for the parent's OWN label: #114's parent carries
# `area:epic` and #115's carries `epic-blocked`. Both contain "epic" as a
# `grep -w` word, so both children are wrongly excluded by a substring/word
# match and are kept only by the exact whole-label match over the comma-split
# list — these two assertions are what turn the suite red if the check ever
# regresses to `grep -qw 'epic'`.
[ -z "$(excluded_reason 114)" ] \
  || report "issue 114 (parent labelled area:epic — an area label, not the epic type label): expected NOT excluded, got reason: $(excluded_reason 114)"
areaepic_unit=$(jq -r '.batches[] | select(.members[0].issue==114) | .unit' "$MAIN_JSON")
[ "$areaepic_unit" = "areaepicchild" ] \
  || report "issue 114: expected unit areaepicchild, got $areaepic_unit"
[ -z "$(excluded_reason 115)" ] \
  || report "issue 115 (parent labelled epic-blocked — merely contains \"epic\"): expected NOT excluded, got reason: $(excluded_reason 115)"
epicblocked_unit=$(jq -r '.batches[] | select(.members[0].issue==115) | .unit' "$MAIN_JSON")
[ "$epicblocked_unit" = "epicblockedchild" ] \
  || report "issue 115: expected unit epicblockedchild, got $epicblocked_unit"

# --- no Unit: line at all (#104) — excluded, reason states the marker is
# missing. ---
[ -n "$(excluded_reason 104)" ] \
  || report "issue 104 (no Unit: line): expected an excluded[] entry"
printf '%s' "$(excluded_reason 104)" | grep -qi 'no Unit: marker' \
  || report "issue 104: excluded reason should say no Unit: marker, got: $(excluded_reason 104)"

# --- wrong-case token (#105): "unit:" does not count as a marker — lands
# in the SAME excluded bucket (identical reason text) as #104's true
# absence, proving the exact-case match is load-bearing, not merely a
# case-insensitive convenience. ---
[ -n "$(excluded_reason 105)" ] \
  || report "issue 105 (wrong-case token): expected an excluded[] entry"
[ "$(excluded_reason 105)" = "$(excluded_reason 104)" ] \
  || report "issue 105: expected the same 'no marker' reason text as issue 104 (both lack a valid Unit: line), got: $(excluded_reason 105)"

# --- two look-alike shapes in one body (#121): no whitespace after the
# colon, and "Unit:" occurring mid-sentence rather than at line start —
# neither counts, so this also lands in the same "no marker" bucket. ---
[ -n "$(excluded_reason 121)" ] \
  || report "issue 121 (look-alike Unit: shapes): expected an excluded[] entry"
[ "$(excluded_reason 121)" = "$(excluded_reason 104)" ] \
  || report "issue 121: expected the same 'no marker' reason text as issue 104, got: $(excluded_reason 121)"

# --- two Unit: lines (#116) — NOT an error: the first line wins, the
# second is silently ignored (SKILL.md's settled text; this suite used to
# treat this as an ambiguity error before #800/#808 landed — that was
# wrong). #116's first line names alpha-tool/, second names beta-tool/;
# only alpha-tool/ may appear, and NOT excluded. ---
[ -z "$(excluded_reason 116)" ] \
  || report "issue 116 (two Unit: lines): expected NOT excluded (first line wins), got reason: $(excluded_reason 116)"
twoline_unit=$(jq -r '.batches[] | select(.members[0].issue==116) | .unit' "$MAIN_JSON")
[ "$twoline_unit" = "alpha-tool/" ] \
  || report "issue 116: expected unit alpha-tool/ (the FIRST Unit: line), got $twoline_unit"
beta_present=$(jq -c '[.batches[].members[] | select(.issue==116)] | length' "$MAIN_JSON")
[ "$beta_present" = "1" ] \
  || report "issue 116: expected exactly one batch membership (not double-counted under both units)"
beta_batch_exists=$(jq -r '[.batches[].unit] | index("beta-tool/") // "absent"' "$MAIN_JSON")
[ "$beta_batch_exists" = "absent" ] \
  || report "issue 116: expected NO beta-tool/ batch at all (the second Unit: line must be fully ignored, not merely unused for #116)"

# --- comma-separated multi-value on one Unit: line (#117) — malformed. ---
[ -n "$(excluded_reason 117)" ] \
  || report "issue 117 (comma-separated Unit: value): expected an excluded[] entry"
printf '%s' "$(excluded_reason 117)" | grep -qi 'not one of the three legal forms' \
  || report "issue 117: excluded reason should say not one of the three legal forms, got: $(excluded_reason 117)"

# --- backtick-wrapped value (#118) — malformed under the settled lexical
# rule ("no backticks"), unlike this suite's own earlier (pre-#808) guess
# that backticks were acceptable. ---
[ -n "$(excluded_reason 118)" ] \
  || report "issue 118 (backtick-wrapped Unit: value): expected an excluded[] entry"
printf '%s' "$(excluded_reason 118)" | grep -qi 'not one of the three legal forms' \
  || report "issue 118: excluded reason should say not one of the three legal forms, got: $(excluded_reason 118)"

# --- whitespace inside the path value (#119) — outside the path-safe
# charset, malformed. ---
[ -n "$(excluded_reason 119)" ] \
  || report "issue 119 (whitespace inside path): expected an excluded[] entry"
printf '%s' "$(excluded_reason 119)" | grep -qi 'not one of the three legal forms' \
  || report "issue 119: excluded reason should say not one of the three legal forms, got: $(excluded_reason 119)"

# --- degenerate bare test_.sh marker (#120) — maps to the EMPTY unit via
# the script/test convention; must be reported in excluded[] with a
# reason naming the value that was found, never a silent drop from both
# batches[] and excluded[] (the #669 failure mode, re-tested under the new
# derivation). ---
[ -n "$(excluded_reason 120)" ] \
  || report "issue 120 (degenerate test_.sh marker): expected an excluded[] entry, got none — this is the silent-drop failure mode #669 originally reported"
printf '%s' "$(excluded_reason 120)" | grep -qi 'mapped to no usable unit' \
  || report "issue 120: excluded reason should say the marker mapped to no usable unit, got: $(excluded_reason 120)"
printf '%s' "$(excluded_reason 120)" | grep -qF 'test_.sh' \
  || report "issue 120: excluded reason should name the value test_.sh that was found, got: $(excluded_reason 120)"
[ "$(jq -c '[.batches[].members[] | select(.issue==120)] | length' "$MAIN_JSON")" = "0" ] \
  || report "issue 120: expected NOT present in any batch (it belongs in excluded[] only)"

# --- trailing sentence punctuation (#124) — malformed: SKILL.md's lexical
# rule forbids "trailing punctuation" on the Unit: line. ---
[ -n "$(excluded_reason 124)" ] \
  || report "issue 124 (trailing period): expected an excluded[] entry"
printf '%s' "$(excluded_reason 124)" | grep -qi 'not one of the three legal forms' \
  || report "issue 124: excluded reason should say not one of the three legal forms, got: $(excluded_reason 124)"

# --- uppercase area:* value (#126) — malformed: no real area label in
# this repo is anything but lowercase kebab. ---
[ -n "$(excluded_reason 126)" ] \
  || report "issue 126 (uppercase area:* value): expected an excluded[] entry"
printf '%s' "$(excluded_reason 126)" | grep -qi 'not one of the three legal forms' \
  || report "issue 126: excluded reason should say not one of the three legal forms, got: $(excluded_reason 126)"

for n in 101 102 103 109 110 111 112 113 114 115 116 125 127 128; do
  [ -z "$(excluded_reason "$n")" ] || report "issue $n: unexpectedly excluded: $(excluded_reason "$n")"
done

# --- conservation (#682): the sweep above is one-sided — `excluded_reason`
# returns empty both when an issue is correctly grouped into a batch AND
# when it is silently missing from batches[] and excluded[] alike (the
# #669 silent-drop shape). Assert the invariant structurally instead of
# case by case: every MS10 fixture this suite declared (one file per issue
# under $MS10_ITEMS) appears EXACTLY ONCE across
# batches[].members[].issue + excluded[].issue combined. A fixture added
# later with neither a positive membership assertion nor an excluded[]
# assertion would otherwise slip through undetected. ---
ms10_declared=$(find "$MS10_ITEMS" -maxdepth 1 -name '*.json' -printf '%f\n' | sed 's/\.json$//' | sort -n | jq -R . | jq -sc 'map(tonumber)')
ms10_accounted=$(jq -c '([.batches[].members[].issue] + [.excluded[].issue]) | sort' "$MAIN_JSON")
[ "$ms10_accounted" = "$ms10_declared" ] \
  || report "conservation: every MS10 fixture must appear in exactly one of batches[]/excluded[] — declared $ms10_declared, accounted for $ms10_accounted"

# --- cap split: 9-member unit "many" splits 8 + 1, never one 9-member batch ---
many_batches=$(jq -c '[.batches[] | select(.unit=="many")]' "$MAIN_JSON")
many_batch_count=$(jq 'length' <<<"$many_batches")
[ "$many_batch_count" = "2" ] \
  || report "unit many: expected exactly 2 batches after the ~8 cap split, got $many_batch_count"
many_sizes=$(jq -c '[.[] | (.members|length)] | sort' <<<"$many_batches")
[ "$many_sizes" = "[1,8]" ] \
  || report "unit many: expected batch sizes [1,8] after the cap split, got $many_sizes"
many_first=$(jq -c 'map(select((.members|length)==8))[0]' <<<"$many_batches")
[ "$(jq -r .dispatchable <<<"$many_first")" = "true" ] \
  || report "unit many (8-member batch): expected dispatchable=true"
many_first_issues=$(jq -r '[.members[].issue] | @csv' <<<"$many_first")
printf '%s' "$many_first_issues" | grep -q '209' \
  && report "unit many: the 8-member (highest-priority) batch should NOT include the lowest-priority #209, got: $many_first_issues"
many_rem=$(jq -c 'map(select((.members|length)==1))[0]' <<<"$many_batches")
[ "$(jq -r .dispatchable <<<"$many_rem")" = "false" ] \
  || report "unit many (1-member remainder): expected dispatchable=false (waits, per the prose)"
[ "$(jq -r '.members[0].issue' <<<"$many_rem")" = "209" ] \
  || report "unit many: expected #209 (lowest priority) as the remainder, got $(jq -r '.members[0].issue' <<<"$many_rem")"

# ===========================================================================
# CAPSPLIT — cap-split boundary at N=16 (exact multiple of --max) and N=17
# (one more than an exact multiple): both remainder chunks are themselves
# full MAX-sized chunks, so both must be dispatchable, never waiting.
# ===========================================================================
CAPSPLIT_JSON=$(run_batch "$CAPSPLIT" "$REPO_CAPSPLIT")

cap16_batches=$(jq -c '[.batches[] | select(.unit=="cap16")]' "$CAPSPLIT_JSON")
cap16_count=$(jq 'length' <<<"$cap16_batches")
[ "$cap16_count" = "2" ] \
  || report "unit cap16 (N=16): expected exactly 2 batches, got $cap16_count"
cap16_sizes=$(jq -c '[.[] | (.members|length)] | sort' <<<"$cap16_batches")
[ "$cap16_sizes" = "[8,8]" ] \
  || report "unit cap16 (N=16): expected batch sizes [8,8], got $cap16_sizes"
cap16_dispatchable=$(jq -r '[.[].dispatchable] | unique | sort | @csv' <<<"$cap16_batches")
[ "$cap16_dispatchable" = "true" ] \
  || report "unit cap16 (N=16): expected BOTH 8-member batches dispatchable=true (the second chunk is the whole remainder, not a partial waiting one), got: $cap16_dispatchable"

cap17_batches=$(jq -c '[.batches[] | select(.unit=="cap17")]' "$CAPSPLIT_JSON")
cap17_count=$(jq 'length' <<<"$cap17_batches")
[ "$cap17_count" = "3" ] \
  || report "unit cap17 (N=17): expected exactly 3 batches, got $cap17_count"
cap17_sizes=$(jq -c '[.[] | (.members|length)] | sort' <<<"$cap17_batches")
[ "$cap17_sizes" = "[1,8,8]" ] \
  || report "unit cap17 (N=17): expected batch sizes [1,8,8], got $cap17_sizes"
cap17_eight_dispatchable=$(jq -r '[.[] | select((.members|length)==8) | .dispatchable] | unique | sort | @csv' <<<"$cap17_batches")
[ "$cap17_eight_dispatchable" = "true" ] \
  || report "unit cap17 (N=17): expected both 8-member batches dispatchable=true, got: $cap17_eight_dispatchable"
cap17_one_dispatchable=$(jq -r '.[] | select((.members|length)==1) | .dispatchable' <<<"$cap17_batches")
[ "$cap17_one_dispatchable" = "false" ] \
  || report "unit cap17 (N=17): expected the 1-member remainder dispatchable=false (waits, per the prose), got: $cap17_one_dispatchable"

# ===========================================================================
# FLUSHY — milestone-wide flush, including the milestone-less-member rule.
# ===========================================================================
FLUSHY_JSON=$(run_batch "$FLUSHY" "$REPO_FLUSHY" --milestone 20)
flushy_batch=$(jq -c '.batches[] | select(.unit=="flushme")' "$FLUSHY_JSON")
[ "$(jq -r .dispatchable <<<"$flushy_batch")" = "true" ] \
  || report "unit flushme (2 members, milestone-flushed): expected dispatchable=true"
[ "$(jq -r .flush_eligible <<<"$flushy_batch")" = "true" ] \
  || report "unit flushme: expected flush_eligible=true"
flushy_issues=$(jq -c '[.members[].issue]|sort' <<<"$flushy_batch")
[ "$flushy_issues" = "[401,402]" ] \
  || report "unit flushme: expected members [401,402] (incl. the milestone-less one), got $flushy_issues"

# ===========================================================================
# NOFLUSHY — no flush (an open planned child remains), then --flush override.
# ===========================================================================
NOFLUSHY_JSON=$(run_batch "$NOFLUSHY" "$REPO_NOFLUSHY" --milestone 30)
noflushy_batch=$(jq -c '.batches[] | select(.unit=="stuck")' "$NOFLUSHY_JSON")
[ "$(jq -r .dispatchable <<<"$noflushy_batch")" = "false" ] \
  || report "unit stuck (1 member, milestone NOT flushed): expected dispatchable=false"
[ "$(jq -r .flush_eligible <<<"$noflushy_batch")" = "false" ] \
  || report "unit stuck: expected flush_eligible=false"

: > "$MOCK_GH_CALL_LOG"
NOFLUSHY_FLUSH_JSON=$(run_batch "$NOFLUSHY" "$REPO_NOFLUSHY" --milestone 30 --flush)
noflushy_flush_batch=$(jq -c '.batches[] | select(.unit=="stuck")' "$NOFLUSHY_FLUSH_JSON")
[ "$(jq -r .dispatchable <<<"$noflushy_flush_batch")" = "true" ] \
  || report "unit stuck with --flush: expected dispatchable=true (manual override)"
if grep -q 'milestone=30&state=open&per_page=100' "$MOCK_GH_CALL_LOG"; then
  report "--flush: expected the automatic flush-check GET to be skipped, but it was called: $(grep 'milestone=30&state=open&per_page=100' "$MOCK_GH_CALL_LOG")"
fi

# ===========================================================================
# CONFLICT — repo-wide (no --milestone): a unit spanning 2 real milestones
# never flushes, even though both milestones are individually zero-open.
# ===========================================================================
CONFLICT_JSON=$(run_batch "$CONFLICT" "$REPO_CONFLICT")
conflict_batch=$(jq -c '.batches[] | select(.unit=="conflict")' "$CONFLICT_JSON")
[ "$(jq -r .dispatchable <<<"$conflict_batch")" = "false" ] \
  || report "unit conflict (spans milestones 5 and 6): expected dispatchable=false"
[ "$(jq -r .flush_eligible <<<"$conflict_batch")" = "false" ] \
  || report "unit conflict: expected flush_eligible=false (spans >1 real milestone)"

# ===========================================================================
# --repo omitted: falls back to `gh repo view`.
# ===========================================================================
REPOVIEW_JSON=$(MOCK_GH_FIXTURES="$REPOVIEW" MOCK_GH_REPO_VIEW="$REPO_VIEW_NAME" PATH="$BIN:$PATH" \
  "$BATCH_DEFERRED_SH" --no-board-status 2>"$OUT/repoview.stderr.log" || true)
if [ -z "$REPOVIEW_JSON" ]; then
  report "--repo omitted: expected output via the gh-repo-view fallback, got none: $(cat "$OUT/repoview.stderr.log")"
else
  rv_repo=$(jq -r .repo <<<"$REPOVIEW_JSON")
  [ "$rv_repo" = "$REPO_VIEW_NAME" ] \
    || report "--repo omitted: expected repo=$REPO_VIEW_NAME from the gh-repo-view fallback, got $rv_repo"
fi

# ===========================================================================
# --markdown: a triage.batches-shaped JSON block.
# ===========================================================================
MD_LABEL="markdown1"
MOCK_GH_FIXTURES="$FLUSHY" PATH="$BIN:$PATH" \
  "$BATCH_DEFERRED_SH" --repo "$REPO_FLUSHY" --milestone 20 --markdown --no-board-status \
  >"$OUT/$MD_LABEL.stdout.log" 2>"$OUT/$MD_LABEL.stderr.log"
grep -q '^### Batch proposals' "$OUT/$MD_LABEL.stdout.log" \
  || report "--markdown: expected a '### Batch proposals' heading"
grep -q '^```json' "$OUT/$MD_LABEL.stdout.log" \
  || report "--markdown: expected a fenced json block for triage.batches"
TB_BLOCK=$(awk '/^```json/{flag=1;next}/^```$/{flag=0}flag' "$OUT/$MD_LABEL.stdout.log")
tb_unit=$(jq -r '.[0].unit' <<<"$TB_BLOCK")
[ "$tb_unit" = "flushme" ] || report "--markdown triage.batches: expected unit flushme, got $tb_unit"
tb_members=$(jq -c '.[0].members|sort' <<<"$TB_BLOCK")
[ "$tb_members" = "[401,402]" ] || report "--markdown triage.batches: expected members [401,402], got $tb_members"
jq -e '.[0] | has("dispatchable")' <<<"$TB_BLOCK" >/dev/null \
  || report "--markdown triage.batches: expected a dispatchable key"

# ===========================================================================
# RIDERS — parked-issue riders (#802).
# ===========================================================================
RIDERS_JSON=$(run_batch "$RIDERS" "$REPO_RIDERS")
rider_excluded_reason(){ jq -r --argjson n "$1" '.excluded[] | select(.issue==$n) | .reason' "$RIDERS_JSON"; }

# --- ridera: dispatchable at 3 open members; rider #950 MUST join, role rider ---
ridera_batch=$(jq -c '.batches[] | select(.unit=="area:ridera")' "$RIDERS_JSON")
[ "$(jq -r .dispatchable <<<"$ridera_batch")" = "true" ] \
  || report "unit area:ridera: expected dispatchable=true (3 open members)"
ridera_members=$(jq -c '[.members[].issue]|sort' <<<"$ridera_batch")
[ "$ridera_members" = "[901,902,903,950]" ] \
  || report "unit area:ridera: expected members [901,902,903,950] (rider #950 joined), got $ridera_members"
ridera_950_role=$(jq -r '.members[] | select(.issue==950) | .role' <<<"$ridera_batch")
[ "$ridera_950_role" = "rider" ] \
  || report "unit area:ridera: expected #950's role to be rider, got $ridera_950_role"
ridera_901_role=$(jq -r '.members[] | select(.issue==901) | .role' <<<"$ridera_batch")
[ "$ridera_901_role" = "member" ] \
  || report "unit area:ridera: expected #901's role to be member, got $ridera_901_role"

# --- riderb: only 2 open members (below threshold) — rider #951 must NOT
# join; a rider never makes a unit dispatchable and never counts toward
# the threshold. ---
riderb_batch=$(jq -c '.batches[] | select(.unit=="area:riderb")' "$RIDERS_JSON")
[ "$(jq -r .dispatchable <<<"$riderb_batch")" = "false" ] \
  || report "unit area:riderb: expected dispatchable=false (2 open members, below threshold)"
riderb_members=$(jq -c '[.members[].issue]|sort' <<<"$riderb_batch")
[ "$riderb_members" = "[904,905]" ] \
  || report "unit area:riderb: expected members [904,905] ONLY — rider #951 must not join a non-dispatchable unit, got $riderb_members"

# --- riderc: 7 open members, dispatchable, room=1 under --max 8; three
# matching parked riders at priority low/high/medium — only the highest
# priority one (#953) fits the cap. ---
riderc_batch=$(jq -c '.batches[] | select(.unit=="area:riderc")' "$RIDERS_JSON")
[ "$(jq -r .dispatchable <<<"$riderc_batch")" = "true" ] \
  || report "unit area:riderc: expected dispatchable=true (7 open members)"
riderc_members=$(jq -c '[.members[].issue]|sort' <<<"$riderc_batch")
[ "$(jq 'length' <<<"$riderc_members")" = "8" ] \
  || report "unit area:riderc: expected exactly 8 total members (cap counts riders), got $riderc_members"
riderc_has_953=$(jq -c 'index(953) != null' <<<"$riderc_members")
[ "$riderc_has_953" = "true" ] \
  || report "unit area:riderc: expected the highest-priority rider #953 to fill the one remaining cap slot, got $riderc_members"
for excess in 952 954; do
  jq -e --argjson n "$excess" 'index($n) == null' <<<"$riderc_members" >/dev/null \
    || report "unit area:riderc: expected lower-priority rider #$excess to be left unplaced (cap has no more room), but it was placed: $riderc_members"
done

# --- riderd: matching parked candidate #955 carries a Rejected: comment —
# excluded with that reason, never placed; riderd stays its 3 open members. ---
riderd_batch=$(jq -c '.batches[] | select(.unit=="area:riderd")' "$RIDERS_JSON")
riderd_members=$(jq -c '[.members[].issue]|sort' <<<"$riderd_batch")
[ "$riderd_members" = "[913,914,915]" ] \
  || report "unit area:riderd: expected members [913,914,915] ONLY — the Rejected rider #955 must not join, got $riderd_members"
[ -n "$(rider_excluded_reason 955)" ] \
  || report "issue 955 (Rejected: comment): expected an excluded[] entry"
printf '%s' "$(rider_excluded_reason 955)" | grep -qF 'Rejected: too flaky, not reproducible' \
  || report "issue 955: excluded reason should carry the Rejected: comment text, got: $(rider_excluded_reason 955)"

# --- --markdown distinguishes riders from members (AC: "--markdown output
# distinguishes riders from members") ---
RIDERS_MD_LABEL="ridersmd"
MOCK_GH_FIXTURES="$RIDERS" PATH="$BIN:$PATH" \
  "$BATCH_DEFERRED_SH" --repo "$REPO_RIDERS" --markdown --no-board-status \
  >"$OUT/$RIDERS_MD_LABEL.stdout.log" 2>"$OUT/$RIDERS_MD_LABEL.stderr.log"
grep -q '^  - riders:' "$OUT/$RIDERS_MD_LABEL.stdout.log" \
  || report "--markdown (RIDERS): expected a 'riders:' sub-list heading somewhere in the output"
grep -q '#950 \[low\] (rider)' "$OUT/$RIDERS_MD_LABEL.stdout.log" \
  || report "--markdown (RIDERS): expected rider #950 listed under its own sub-list entry"

# --- the triage.batches BLOCK itself, not just the human-readable sub-list
# (#802 round 1, F2). This is the block orchestration.md § The loop step 1
# tells the pick step to read, and formats/maintenance-report.md defines
# `members` as holding OPEN deferred items. A rider is a CLOSED parked
# issue, so a rider leaking into `members` gives the orchestrator a closed
# issue it will dispatch WITHOUT first reopening it (home-deferred.sh
# --readd --status Ready), and the batch PR then tries to close an
# already-closed issue. Hence: members open-only, riders in their own
# sibling key, and that key ALWAYS present so "no riders" and "producer too
# old to emit the key" can never be confused. ---
RIDERS_TB=$(awk '/^```json/{flag=1;next}/^```$/{flag=0}flag' "$OUT/$RIDERS_MD_LABEL.stdout.log")
jq -e . >/dev/null 2>&1 <<<"$RIDERS_TB" \
  || report "triage.batches (RIDERS): the fenced block is not parsable JSON: $RIDERS_TB"
tb_unit_get(){ jq -c --arg u "$1" '.[] | select(.unit==$u)' <<<"$RIDERS_TB"; }

tb_ridera=$(tb_unit_get "area:ridera")
tb_ridera_members=$(jq -c '.members|sort' <<<"$tb_ridera")
[ "$tb_ridera_members" = "[901,902,903]" ] \
  || report "triage.batches (area:ridera): members must hold the OPEN members only — rider #950 is closed and belongs in riders[], got $tb_ridera_members"
# `.riders // "MISSING"` rather than a bare `.riders`: when the key is absent
# entirely (the exact regression this asserts against) a bare `sort` errors
# and, under set -e, kills the suite with a raw jq trace instead of the
# diagnosis below.
tb_ridera_riders=$(jq -c '(.riders // "MISSING") | if type=="array" then sort else . end' <<<"$tb_ridera")
[ "$tb_ridera_riders" = "[950]" ] \
  || report "triage.batches (area:ridera): expected riders [950], got $tb_ridera_riders"

# Every batch carries the key, including one that placed no rider at all.
tb_missing_riders=$(jq -c '[.[] | select(has("riders")|not) | .unit]' <<<"$RIDERS_TB")
[ "$tb_missing_riders" = "[]" ] \
  || report "triage.batches: every batch object must carry a riders key (…[] when it placed none); missing on $tb_missing_riders"
tb_riderb_riders=$(jq -c '.riders // "MISSING"' <<<"$(tb_unit_get "area:riderb")")
[ "$tb_riderb_riders" = "[]" ] \
  || report "triage.batches (area:riderb): a unit that placed no rider must carry riders [], got $tb_riderb_riders"

# And the two keys must be disjoint: nothing may be reported as both.
tb_overlap=$(jq -c '[.[] | ((.members // []) - ((.members // []) - (.riders // [])))] | add // []' <<<"$RIDERS_TB")
[ "$tb_overlap" = "[]" ] \
  || report "triage.batches: members and riders must be disjoint, both list $tb_overlap"

# ===========================================================================
# RIDERS splice probe: dropping the rider (parked-pool) GET must turn this
# suite red — shown, not merely asserted. Splice out the parked-pool fetch
# (the block that appends to riders.jsonl) by forcing it empty before the
# unit-derivation loop runs, confirm ridera's rider #950 disappears (RED),
# then restore and confirm it is back (GREEN).
# ===========================================================================
SPLICE_BACKUP="$WORK/batch-deferred.sh.orig"
cp "$BATCH_DEFERRED_SH" "$SPLICE_BACKUP"
# shellcheck disable=SC2016 # single-quoted on purpose: the sed pattern text is not meant to expand
sed -i 's#done < "\$WORK/parked\.jsonl"#done < /dev/null#' "$BATCH_DEFERRED_SH"
if ! grep -qF 'done < /dev/null' "$BATCH_DEFERRED_SH"; then
  report "splice probe: sed substitution did not apply — cannot show the RED state"
fi
SPLICE_JSON=$(run_batch "$RIDERS" "$REPO_RIDERS")
splice_ridera=$(jq -c '[.batches[] | select(.unit=="area:ridera") | .members[].issue] | sort' "$SPLICE_JSON")
[ "$splice_ridera" = "[901,902,903]" ] \
  || report "splice probe: expected the rider GET dropped to REMOVE #950 from area:ridera (RED state), got $splice_ridera"
cp "$SPLICE_BACKUP" "$BATCH_DEFERRED_SH"
diff "$SPLICE_BACKUP" "$BATCH_DEFERRED_SH" >/dev/null \
  || report "splice probe: restore mismatch — batch-deferred.sh was not restored to its original bytes"
RESTORED_JSON=$(run_batch "$RIDERS" "$REPO_RIDERS")
restored_ridera=$(jq -c '[.batches[] | select(.unit=="area:ridera") | .members[].issue] | sort' "$RESTORED_JSON")
[ "$restored_ridera" = "[901,902,903,950]" ] \
  || report "splice probe: expected the restored script to bring #950 back (GREEN state), got $restored_ridera"

# ===========================================================================
# INFLIGHT — an in-flight member (board Status In progress / In review) is
# excluded, and `dispatchable` is computed AFTER that exclusion (#738).
# ===========================================================================
INFLIGHT_JSON=$(run_batch "$INFLIGHT" "$REPO_INFLIGHT")
inflight_excluded_reason(){ jq -r --argjson n "$1" '.excluded[] | select(.issue==$n) | .reason' "$INFLIGHT_JSON"; }

inflight_batch=$(jq -c '.batches[] | select(.unit=="area:inflightunit")' "$INFLIGHT_JSON")
[ "$(jq -r .dispatchable <<<"$inflight_batch")" = "true" ] \
  || report "unit area:inflightunit: expected dispatchable=true (3 real members after excluding #963)"
inflight_members=$(jq -c '[.members[].issue]|sort' <<<"$inflight_batch")
[ "$inflight_members" = "[960,961,962]" ] \
  || report "unit area:inflightunit: expected members [960,961,962] (#963 excluded as in-flight), got $inflight_members"
[ -n "$(inflight_excluded_reason 963)" ] \
  || report "issue 963 (Status In review): expected an excluded[] entry"
printf '%s' "$(inflight_excluded_reason 963)" | grep -qi 'in review' \
  || report "issue 963: excluded reason should name the In review board Status, got: $(inflight_excluded_reason 963)"

below_batch=$(jq -c '.batches[] | select(.unit=="area:belowunit")' "$INFLIGHT_JSON")
[ "$(jq -r .dispatchable <<<"$below_batch")" = "false" ] \
  || report "unit area:belowunit: expected dispatchable=false — excluding in-flight #972 drops this unit to 2 members, below the >=3 threshold"
below_members=$(jq -c '[.members[].issue]|sort' <<<"$below_batch")
[ "$below_members" = "[970,971]" ] \
  || report "unit area:belowunit: expected members [970,971] (#972 excluded as in-flight), got $below_members"
[ -n "$(inflight_excluded_reason 972)" ] \
  || report "issue 972 (Status In progress): expected an excluded[] entry"
printf '%s' "$(inflight_excluded_reason 972)" | grep -qi 'in progress' \
  || report "issue 972: excluded reason should name the In progress board Status, got: $(inflight_excluded_reason 972)"

# ===========================================================================
# INFLIGHT splice probe: dropping the board-Status exclusion must turn this
# suite red. Splice out the exclusion check itself, confirm #972 (and the
# below-threshold flip) comes back wrong (RED), then restore.
# ===========================================================================
cp "$BATCH_DEFERRED_SH" "$SPLICE_BACKUP"
# shellcheck disable=SC2016 # single-quoted on purpose: the sed pattern text is not meant to expand
sed -i 's/^  if \[ "\$board_status" = "In progress" \] || \[ "\$board_status" = "In review" \]; then$/  if false; then/' "$BATCH_DEFERRED_SH"
if ! grep -qF 'if false; then' "$BATCH_DEFERRED_SH"; then
  report "splice probe (#738): sed substitution did not apply — cannot show the RED state"
fi
SPLICE_INFLIGHT_JSON=$(run_batch "$INFLIGHT" "$REPO_INFLIGHT")
splice_below_dispatchable=$(jq -r '.batches[] | select(.unit=="area:belowunit") | .dispatchable' "$SPLICE_INFLIGHT_JSON")
[ "$splice_below_dispatchable" = "true" ] \
  || report "splice probe (#738): expected the in-flight exclusion dropped to leave area:belowunit wrongly dispatchable=true (RED state), got $splice_below_dispatchable"
cp "$SPLICE_BACKUP" "$BATCH_DEFERRED_SH"
diff "$SPLICE_BACKUP" "$BATCH_DEFERRED_SH" >/dev/null \
  || report "splice probe (#738): restore mismatch — batch-deferred.sh was not restored to its original bytes"
RESTORED_INFLIGHT_JSON=$(run_batch "$INFLIGHT" "$REPO_INFLIGHT")
restored_below_dispatchable=$(jq -r '.batches[] | select(.unit=="area:belowunit") | .dispatchable' "$RESTORED_INFLIGHT_JSON")
[ "$restored_below_dispatchable" = "false" ] \
  || report "splice probe (#738): expected the restored script to bring dispatchable=false back (GREEN state), got $restored_below_dispatchable"

# ===========================================================================
# Board-status config FAILS CLOSED (#738 round 1, F1). Each of the three
# no-op paths the first cut had — missing file, unparsable Project id,
# unreadable file — must now exit non-zero with its OWN message and print
# nothing on stdout. The bug being guarded against is not "wrong output": it
# is a clean exit 0 carrying `"excluded": []` and a stale
# `"dispatchable": true` for a unit whose member is demonstrably in an open
# PR, which is #738's own reported symptom. So each case asserts BOTH the
# non-zero exit AND the empty stdout — a refusal that still printed a
# batch proposal would be no better than the silent skip.
# ===========================================================================
wt_refusal(){ # wt_refusal <label> <wt-path> <expected-message-substring>
  run_argerr 1 "$1" "$INFLIGHT" "$REPO_INFLIGHT" --work-tracking "$2"
  grep -qF "$3" "$OUT/$1.stderr.log" \
    || report "board config ($1): expected stderr to name '$3', got: $(cat "$OUT/$1.stderr.log")"
  [ ! -s "$OUT/$1.stdout.log" ] \
    || report "board config ($1): refused runs must print NOTHING on stdout — a batch proposal here is the #738 fail-open, got: $(cat "$OUT/$1.stdout.log")"
}

# (a) --work-tracking names a file that does not exist.
wt_refusal wtmissing "$INFLIGHT/definitely-not-here.md" "file not found"

# (b) the file exists and is readable but carries no `| Project | \`id\` |` row.
WT_BAD="$WORK/wt-unparsable"
mkdir -p "$WT_BAD"
printf '%s\n' '# work tracking' 'no project row anywhere in this file' > "$WT_BAD/wt.md"
wt_refusal wtunparsable "$WT_BAD/wt.md" "could not parse a Project id"

# (c) the file exists and parses, but cannot be read. `chmod 000` means
# "unreadable" only for a caller WITHOUT CAP_DAC_OVERRIDE — a fully
# privileged root reads it regardless, and this probe would then assert
# nothing at all while still going green, which is precisely the
# fixture-vacuity shape this repo keeps re-catching. So the mode is not
# assumed from the uid: the file is chmod-ed and then actually READ to find
# out, and the probe adapts (or refuses to pretend) based on the answer.
WT_UNREAD="$WORK/wt-unreadable"
mkdir -p "$WT_UNREAD"
# shellcheck disable=SC2016 # single-quoted on purpose: the backtick-wrapped id is literal fixture text
printf '%s\n' '| Project | `PVT_test_unreadable` |' > "$WT_UNREAD/wt.md"
chmod 000 "$WT_UNREAD/wt.md"
# The board config is validated before any GET, so this case needs neither
# the mock nor a fixture dir — only traversal down to the file itself.
chmod 711 "$WORK" "$WT_UNREAD"
unread_prefix=""
unread_vacuous=""
if head -c1 "$WT_UNREAD/wt.md" >/dev/null 2>&1; then
  # This caller overrides file permissions. Drop to an unprivileged uid so
  # the script meets a genuinely unreadable file — but only after proving
  # the drop itself works, because a setpriv that cannot setresuid would
  # fail the run for the WRONG reason and still look like a pass.
  if command -v setpriv >/dev/null 2>&1 \
    && setpriv --reuid=65534 --regid=65534 --clear-groups true >/dev/null 2>&1; then
    unread_prefix="setpriv --reuid=65534 --regid=65534 --clear-groups"
  else
    unread_vacuous="this caller can read a chmod-000 file and no working setpriv is available to drop privileges"
  fi
fi
if [ -n "$unread_vacuous" ]; then
  report "board config (unreadable): probe cannot be made meaningful here — $unread_vacuous. Not silently skipped: an unreadable-file assertion that cannot fail is worth less than no assertion."
else
  unread_rc=0
  set +e
  # The mock env is passed even though a correct script dies before its first
  # GET: without it, a regression that let this run reach the pool fetch would
  # escape through the real `gh` and trip the hermeticity tripwire with a
  # confusing unmocked-context failure instead of this probe's own assertion.
  # shellcheck disable=SC2086 # unread_prefix is a deliberate multi-word command prefix, or empty
  MOCK_GH_FIXTURES="$INFLIGHT" PATH="$BIN:$PATH" \
    $unread_prefix "$BATCH_DEFERRED_SH" --repo "$REPO_INFLIGHT" --work-tracking "$WT_UNREAD/wt.md" \
    >"$OUT/wtunreadable.stdout.log" 2>"$OUT/wtunreadable.stderr.log"
  unread_rc=$?
  set -e
  [ "$unread_rc" -ne 0 ] \
    || report "board config (unreadable): expected a non-zero exit, got 0 with stdout: $(cat "$OUT/wtunreadable.stdout.log")"
  grep -qF "is not readable" "$OUT/wtunreadable.stderr.log" \
    || report "board config (unreadable): expected stderr to name the unreadable file, got: $(cat "$OUT/wtunreadable.stderr.log")"
  [ ! -s "$OUT/wtunreadable.stdout.log" ] \
    || report "board config (unreadable): refused runs must print NOTHING on stdout, got: $(cat "$OUT/wtunreadable.stdout.log")"
fi
chmod 644 "$WT_UNREAD/wt.md"

# Each of the three messages must be DISTINCT — "exits non-zero" alone does
# not tell an operator which of the three things is wrong with their config.
wt_msg(){ sed -n '1p' "$OUT/$1.stderr.log"; }
if [ -s "$OUT/wtunreadable.stderr.log" ]; then
  distinct_count=$(printf '%s\n%s\n%s\n' "$(wt_msg wtmissing)" "$(wt_msg wtunparsable)" "$(wt_msg wtunreadable)" | sort -u | wc -l)
  [ "$distinct_count" -eq 3 ] \
    || report "board config: expected 3 distinct refusal messages across the missing/unparsable/unreadable paths, got $distinct_count"
fi

# The ONLY non-error way to skip the exclusion is to ask for it, and asking
# is recorded in the output rather than being invisible.
optout_json=$(run_batch "$MAIN" "$REPO_MAIN" --milestone 10)
optout_skipped=$(jq -r '.exclusions_skipped | length' "$optout_json")
[ "$optout_skipped" -eq 1 ] \
  || report "--no-board-status: expected exactly one exclusions_skipped[] entry naming the skip, got $optout_skipped"
jq -r '.exclusions_skipped[0]' "$optout_json" | grep -qF 'board-status' \
  || report "--no-board-status: exclusions_skipped[0] should name the board-status exclusion, got: $(jq -r '.exclusions_skipped[0]' "$optout_json")"
# ...and a run that DID walk the board says so by leaving the list empty.
inflight_skipped=$(jq -c '.exclusions_skipped' "$INFLIGHT_JSON")
[ "$inflight_skipped" = "[]" ] \
  || report "board walk ran: expected exclusions_skipped [], got $inflight_skipped"

# ===========================================================================
# PAGFAIL (#867 round-1 finding 2): the shared walk's fail-closed refusal —
# a `hasNextPage: true` page with no usable `endCursor` — now reaches
# batch-deferred.sh's own board-Status walk via lib/project-items-walk.sh.
# No fixture in this suite ever produced that shape before this block: every
# existing board_status.json here is hasNextPage:false. The guard must die
# after exactly one GraphQL call (it can never loop), with a non-zero exit
# and a message naming pagination.
# ===========================================================================
REPO_PAGFAIL="test-org/pagfail-repo"
PAGFAIL="$WORK/fixtures-pagfail"
mkdir -p "$PAGFAIL"
BPF="$PAGFAIL/pagfailunit.md"; cat > "$BPF" <<'MD'
## Home
Milestone: none. No epic parent. Spawned by #700.
Unit: area:pagfailunit

## Verified expectation
`n/a`.
MD
: > "$PAGFAIL/open.jsonl"
issue_json 980 "chore(pagfailunit): open, free" "$BPF" "deferred,priority:low,area:skills" null "" 0 >> "$PAGFAIL/open.jsonl"
jq -s '.' "$PAGFAIL/open.jsonl" > "$PAGFAIL/deferred_all.json"
echo '[]' > "$PAGFAIL/parked_all.json"
# shellcheck disable=SC2016 # single-quoted on purpose: the backtick-wrapped id is literal fixture text, nothing here is meant to expand
echo '| Project | `PVT_test_pagfail` |' > "$PAGFAIL/wt.md"
echo '{"data":{"node":{"items":{"pageInfo":{"hasNextPage":true,"endCursor":null}, "nodes":[]}}}}' > "$PAGFAIL/board_status.json"

pagfail_calls_before="$(wc -l < "$MOCK_GH_CALL_LOG")"
run_argerr 1 pagfail "$PAGFAIL" "$REPO_PAGFAIL" --work-tracking "$PAGFAIL/wt.md"
grep -qi 'pagination' "$OUT/pagfail.stderr.log" \
  || report "PAGFAIL: expected stderr to name pagination, got: $(cat "$OUT/pagfail.stderr.log")"
pagfail_graphql_calls="$(tail -n "+$((pagfail_calls_before + 1))" "$MOCK_GH_CALL_LOG" | grep -c '^CALL gh api graphql' || true)"
[ "$pagfail_graphql_calls" -eq 1 ] \
  || report "PAGFAIL: expected the fail-closed guard to die after exactly 1 graphql call, got $pagfail_graphql_calls"

# ===========================================================================
# Argument errors — routed through the mock (#477-style hermeticity).
# ===========================================================================
run_argerr 2 badflag "$MAIN" "$REPO_MAIN" --bogus-flag
run_argerr 2 maxltmin "$MAIN" "$REPO_MAIN" --min 5 --max 3
run_argerr 2 minleadzero "$MAIN" "$REPO_MAIN" --min 03
run_argerr 2 maxleadzero "$MAIN" "$REPO_MAIN" --max 08
run_argerr 2 msleadzero "$MAIN" "$REPO_MAIN" --milestone 010
run_argerr 2 minzero "$MAIN" "$REPO_MAIN" --min 0
run_argerr 2 msnotnum "$MAIN" "$REPO_MAIN" --milestone abc

# ===========================================================================
# Hermeticity tripwire: the mock recorded every invocation, and none of
# them arrived from an unmocked context.
# ===========================================================================
[ -s "$MOCK_GH_CALL_LOG" ] \
  || report "hermeticity: the mock recorded zero invocations in the last call log — not wired up"
ALL_CALLS_ANY_LOG=0
for f in "$WORK"/*/gh-calls.log "$MOCK_GH_CALL_LOG"; do
  [ -f "$f" ] || continue
  ALL_CALLS_ANY_LOG=1
  if grep -q '^UNMOCKED-CONTEXT ' "$f"; then
    report "hermeticity: a gh call was made from an unmocked context ($f): $(grep -m1 '^UNMOCKED-CONTEXT ' "$f")"
  fi
done
[ "$ALL_CALLS_ANY_LOG" -eq 1 ] || report "hermeticity: found no call log to check at all"
[ "$(command -v gh)" = "$BIN/gh" ] \
  || report "hermeticity: gh resolves to $(command -v gh), not the mock at $BIN/gh (real gh: ${REAL_GH:-none})"

# ===========================================================================
# Private-copy regression guard (round-1 finding 1): the splice probes above
# must never have reached the shared, TRACKED source files, whatever they
# mutated. A revert of the private-copy mechanism back to the pre-PR shape
# (BATCH_DEFERRED_SH pointed straight at BATCH_DEFERRED_SRC) would pass
# every assertion above unchanged — they only ever compare a splice target
# against its own backup — and would show up here, in the $WORK check below.
# ===========================================================================
case "$BATCH_DEFERRED_SH" in
  "$WORK"/*) ;;
  *) report "private-copy guard: BATCH_DEFERRED_SH must resolve under \$WORK, got $BATCH_DEFERRED_SH" ;;
esac
BATCH_DEFERRED_SRC_SHA_AFTER="$(sha256sum "$BATCH_DEFERRED_SRC" | awk '{print $1}')"
[ "$BATCH_DEFERRED_SRC_SHA_AFTER" = "$BATCH_DEFERRED_SRC_SHA_BEFORE" ] \
  || report "private-copy guard: tracked scripts/batch-deferred.sh changed during this run (before=$BATCH_DEFERRED_SRC_SHA_BEFORE after=$BATCH_DEFERRED_SRC_SHA_AFTER) — a splice probe reached the shared tracked file instead of its private copy"
PROJECT_ITEMS_WALK_SRC_SHA_AFTER="$(sha256sum "$PROJECT_ITEMS_WALK_SRC" | awk '{print $1}')"
[ "$PROJECT_ITEMS_WALK_SRC_SHA_AFTER" = "$PROJECT_ITEMS_WALK_SRC_SHA_BEFORE" ] \
  || report "private-copy guard: tracked scripts/lib/project-items-walk.sh changed during this run (before=$PROJECT_ITEMS_WALK_SRC_SHA_BEFORE after=$PROJECT_ITEMS_WALK_SRC_SHA_AFTER) — a splice probe reached the shared tracked sibling instead of its private copy"

if [ "$fail" -ne 0 ]; then
  echo "test_batch_deferred: FAILED" >&2
  exit 1
fi

echo "test_batch_deferred: all assertions passed"
