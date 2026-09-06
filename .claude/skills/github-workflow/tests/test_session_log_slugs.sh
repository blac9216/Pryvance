#!/usr/bin/env bash
# test_session_log_slugs.sh — guards the five canonical checklist-slug lists
# in formats/session-log.md against silent drift, from three angles:
#
#  1. Membership: every example `*-item`/`*-complete` line in
#     formats/session-log.md uses only `item`/`skipped[]` values drawn from
#     that same checklist's own canonical list (PR #408 round 1 found three
#     examples orphaned by a list rewrite; `jq -e` alone cannot see this,
#     since the orphaned lines stay valid JSON). An example whose `event`
#     has the `*-item`/`*-complete` shape but is absent from EVENT_TO_LIST
#     is a failure, not a silent skip, and the count of examples actually
#     checked must equal the count of `*-item`/`*-complete`-shaped example
#     lines present in the file.
#  2. Card agreement: templates/session-card.md's "Checklists" fenced-block
#     lists match session-log.md's canonical lists, in order, for all five
#     checklists.
#  3. Prose agreement: the owning-reference prose checklist for each of the
#     five checklists (SKILL.md step 0 for startup, maintenance.md § Triage
#     drain, orchestration.md's Dispatch and Report-handling checklists,
#     overnight-and-status.md's Close checklist) declares the same slugs, in
#     the same order, as session-log.md's canonical list for that checklist.
#     SKILL.md step 0's 12 startup items each open with their canonical
#     slug ("1. **`log-open`** — Session log opened: ..."), the same shape
#     the other four owning references use, so a slug rename in one place
#     without the other fails this check rather than passing on item count
#     alone.
#
# This is a pure file-vs-file check, following this directory's
# `test_agent_rules_drift.sh` for shape: no `gh` mock, no network, a
# `report()` / fail-counter accumulator so one run surfaces every mismatch
# rather than aborting on the first, and LANG=C pinning because slug
# comparison must not depend on the invoking shell's collation. Everything
# is read from the files at run time — nothing here hardcodes a slug list —
# so a future rewording of any list or prose checklist is caught by this
# test rather than silently drifting past it.
#
# UNMOCKED-CONTEXT: not applicable. This suite issues no `gh` invocation at
# all, so there is no mock to bypass and no tripwire to wire up — the same
# exemption `test_agent_rules_drift.sh` and `test_evidence_single_source.sh`
# document for themselves (#568).
set -euo pipefail
export LANG=C LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REFDIR="$SCRIPT_DIR/../references"
SESSION_LOG="$REFDIR/formats/session-log.md"
CARD="$REFDIR/templates/session-card.md"
SKILL="$REFDIR/../SKILL.md"
MAINTENANCE="$REFDIR/maintenance.md"
ORCHESTRATION="$REFDIR/orchestration.md"
OVERNIGHT="$REFDIR/overnight-and-status.md"

for f in "$SESSION_LOG" "$CARD" "$SKILL" "$MAINTENANCE" "$ORCHESTRATION" "$OVERNIGHT"; do
  [ -f "$f" ] || { echo "FAIL: required file not found: $f" >&2; exit 1; }
done

fail=0
report(){ echo "FAIL: $*" >&2; fail=1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/session-log-slugs-test.XXXXXX")"
cleanup(){ rm -rf "$WORK"; }
trap cleanup EXIT

# ---------------------------------------------------------------------------
# 1. Canonical lists from session-log.md itself.
#
# Each of the five paragraphs reads "Canonical `item` slugs ... : `a`, `b`,
# ... `z`." (startup's variant: "in checklist order (used verbatim by both
# ...): `a`, ...`z`."). Paragraph mode (awk RS='') isolates the whole
# paragraph regardless of hard-wrapping; the slug run itself is everything
# after the last "): " (or, when no parenthetical precedes the list, after
# "order: ") up to the first following period.
# ---------------------------------------------------------------------------
canonical_list(){
  local marker="$1"
  local para rest listtext
  para="$(awk -v RS='' -v marker="$marker" 'index($0, marker) { print; exit }' "$SESSION_LOG" | tr '\n' ' ')"
  if [ -z "$para" ]; then
    report "session-log.md: no paragraph found containing '$marker'"
    return
  fi
  if printf '%s' "$para" | grep -q '): '; then
    rest="$(printf '%s' "$para" | sed -E 's/^.*\): //')"
  else
    rest="$(printf '%s' "$para" | sed -E 's/^.*order: //')"
  fi
  listtext="$(printf '%s' "$rest" | sed -E 's/^([^.]*)\..*$/\1/')"
  # `|| true` (#517): a zero-match `grep -oE` here exits 1, and under
  # `set -euo pipefail` that would abort the whole script before the
  # "extracted zero canonical slugs" guard below (which reads this
  # function's redirected output) ever runs.
  # shellcheck disable=SC2016 # backtick-delimited slug pattern in single quotes; nothing here is meant to expand
  printf '%s' "$listtext" | grep -oE '`[a-z0-9-]+`' | tr -d '`' || true
}

# The five checklist names this test knows how to card- and prose-check
# (each has a hardcoded owning-reference file/marker pair below — deriving
# those too is future work, not attempted here). CHECKLIST_NAMES drives
# every loop below so there is exactly one place naming the set.
CHECKLIST_NAMES="startup triage dispatch report-handling close"

canonical_list "Canonical \`item\` slugs, in checklist order" > "$WORK/canon.startup"
canonical_list "for the **triage** checklist"                 > "$WORK/canon.triage"
canonical_list "for the **dispatch** checklist"                > "$WORK/canon.dispatch"
canonical_list "for the **report-handling** checklist"         > "$WORK/canon.report-handling"
canonical_list "for the **close** checklist"                   > "$WORK/canon.close"

for name in $CHECKLIST_NAMES; do
  [ -s "$WORK/canon.$name" ] || report "session-log.md: extracted zero canonical slugs for '$name'"
done

# ---------------------------------------------------------------------------
# 1b. Declared-set agreement (#505, #559): derive the checklist-name set from
# session-log.md itself, independent of CHECKLIST_NAMES above, and assert
# the two agree, in the order the paragraphs actually appear in the file.
# Every "Canonical `item` slugs for the **<name>** checklist" paragraph names
# one non-startup checklist; startup's paragraph uses the differently-worded
# "in checklist order (used verbatim by both `startup-item` and ...)" and is
# recovered from that `startup-item` mention instead. A sixth canonical list
# added to session-log.md — even one with no example line for guard 2 below
# to catch, and even one whose paragraph is not paragraph-initial (#559 gap
# 1) — changes this derived set and so fails here, rather than going
# unguarded. Because the name for each paragraph is read off in file order
# rather than startup being prepended unconditionally, relocating the
# startup paragraph elsewhere in the file changes the derived order too
# (#559 gap 2), rather than always reading "startup …" regardless of where
# it sits.
#
# The derivation reads every paragraph *containing* (not just opening with)
# "Canonical `item` slugs" — the same containment test canonical_list()
# above already uses (`index($0, marker)`), so a marker mid-paragraph (a
# lead-in sentence before it, #559 gap 1's second variant) is caught exactly
# as a paragraph-initial one is. Paragraphs are squashed to one line each in
# awk RS='' mode first — the same wrap-insensitivity canonical_list() relies
# on, so a hard-rewrap of one of these paragraphs cannot change the derived
# set (#519 round 1 F1). Requiring the "Canonical `item` slugs" marker,
# rather than grepping the whole file for "for the **name** checklist",
# means an ordinary sentence elsewhere that happens to say "for the
# **close** checklist" is never counted (#531) — it is not part of a
# "Canonical `item` slugs" paragraph. Both name forms are read from a
# single ordered `grep -oE` alternation rather than an if/elif that stops
# at the first hit, so a paragraph carrying n canonical lists contributes
# all n names, in the order they appear in it — a sixth list glued onto an
# existing canonical paragraph with no blank line between them (one
# paragraph under `awk RS=''`; #559 round 1 F1) changes the derived set and
# fails here exactly as a separate paragraph does, for any n and at either
# end of the paragraph. `|| true` on that extraction keeps a zero-match
# paragraph from aborting the script under `set -euo pipefail`, letting it
# fall through to the unnameable-paragraph report() below instead (#504's
# own guard shape, applied here too).
# ---------------------------------------------------------------------------
# shellcheck disable=SC2016 # single-quoted awk pattern matching literal backticks; nothing here is meant to expand
declared_paragraphs="$(awk -v RS='' '{ gsub(/\n/, " "); if (index($0, "Canonical `item` slugs")) print }' "$SESSION_LOG")"
declared_names=""
while IFS= read -r para; do
  [ -n "$para" ] || continue
  para_names=""
  # shellcheck disable=SC2016 # single-quoted grep patterns matching literal backticks; nothing here is meant to expand
  mentions="$(printf '%s' "$para" | grep -oE 'used verbatim by both `[a-z0-9-]+-item`|for the \*\*[a-z0-9-]+\*\* checklist' || true)"
  while IFS= read -r mention; do
    [ -n "$mention" ] || continue
    # shellcheck disable=SC2016 # single-quoted grep patterns matching literal backticks; nothing here is meant to expand
    case "$mention" in
      'used verbatim by both'*) name="$(printf '%s' "$mention" | grep -oE '`[a-z0-9-]+-item`' | tr -d '`' | sed -E 's/-item$//')" ;;
      *)                        name="$(printf '%s' "$mention" | grep -oE '\*\*[a-z0-9-]+\*\*' | tr -d '*')" ;;
    esac
    para_names="$para_names $name"
  done <<< "$mentions"
  if [ -n "$para_names" ]; then
    declared_names="$declared_names$para_names"
  else
    report "session-log.md: found a 'Canonical \`item\` slugs' paragraph whose checklist name could not be determined: $para"
  fi
done <<< "$declared_paragraphs"
declared_names="$(printf '%s' "$declared_names" | sed -E 's/^ +//; s/ +$//')"
if [ "$declared_names" != "$CHECKLIST_NAMES" ]; then
  report "session-log.md declares checklist name set '$declared_names' which disagrees with this test's hardcoded set '$CHECKLIST_NAMES' — a checklist was added, removed, renamed, or reordered"
fi

in_list(){
  # in_list <value> <list-file>
  grep -qxF "$1" "$2"
}

# ---------------------------------------------------------------------------
# 2. Example-line membership: every `item` and every `skipped[]` entry in
# session-log.md's own example JSON lines must appear in that checklist's
# canonical list.
# ---------------------------------------------------------------------------
declare -A EVENT_TO_LIST=(
  [startup-item]=startup     [startup-complete]=startup
  [triage-item]=triage       [triage-complete]=triage
  [dispatch-item]=dispatch   [dispatch-complete]=dispatch
  [report-item]=report-handling [report-complete]=report-handling
  [close-item]=close         [close-complete]=close
)

n_examples_checked=0
# `grep -oE` exits 1 (no match) when session-log.md's example-line shape
# changes underneath this extraction; under `set -euo pipefail` that would
# otherwise abort the script here, silently, before the
# "extraction regex may be broken" guard below ever runs (#504). `|| true`
# lets a zero-match extraction fall through to that guard instead.
# shellcheck disable=SC2016 # single-quoted grep/sed patterns matching literal backticks; nothing here is meant to expand
example_lines="$(grep -oE '^`\{.*\}`\s*$' "$SESSION_LOG" | sed -E 's/^`//; s/`\s*$//' || true)"
# Expected shape: every example line whose `event` ends in `-item` or
# `-complete` is one of the five checklists' membership examples and must
# resolve through EVENT_TO_LIST — an event of that shape absent from the
# map is a failure, not a silent skip, and n_examples_checked below must
# come out equal to this count or the loop dropped one. Same `|| true`
# rationale as above: a zero-match `grep -c` here must not abort the script
# ahead of the count-mismatch guard below (#504).
# shellcheck disable=SC2016 # single-quoted jq/grep patterns; nothing here is meant to expand
n_item_shaped_examples="$(printf '%s\n' "$example_lines" | while IFS= read -r l; do [ -n "$l" ] && printf '%s\n' "$l" | jq -r '.event'; done | grep -cE -- '-item$|-complete$' || true)"
while IFS= read -r line; do
  [ -n "$line" ] || continue
  event="$(printf '%s' "$line" | jq -r '.event')"
  listname="${EVENT_TO_LIST[$event]:-}"
  if [ -z "$listname" ]; then
    if printf '%s' "$event" | grep -qE -- '-item$|-complete$'; then
      report "session-log.md example: event '$event' has *-item/*-complete shape but is not in EVENT_TO_LIST"
    fi
    continue
  fi
  n_examples_checked=$((n_examples_checked + 1))
  item="$(printf '%s' "$line" | jq -r '.item // empty')"
  if [ -n "$item" ]; then
    in_list "$item" "$WORK/canon.$listname" \
      || report "session-log.md example: event '$event' item '$item' is not in the canonical '$listname' list"
  fi
  while IFS= read -r skipped; do
    [ -n "$skipped" ] || continue
    in_list "$skipped" "$WORK/canon.$listname" \
      || report "session-log.md example: event '$event' skipped[] value '$skipped' is not in the canonical '$listname' list"
  done < <(printf '%s' "$line" | jq -r '(.skipped[]? // empty)')
done <<< "$example_lines"

[ "$n_examples_checked" -gt 0 ] || report "session-log.md: found zero example *-item/*-complete lines to check — extraction regex may be broken"
[ "$n_examples_checked" -eq "$n_item_shaped_examples" ] || report "session-log.md: checked $n_examples_checked example line(s) but $n_item_shaped_examples *-item/*-complete-shaped example line(s) are present — an event dropped out of EVENT_TO_LIST"

# ---------------------------------------------------------------------------
# 3. Card agreement: templates/session-card.md's "## Checklists" fenced block
# lists the same five lists, in order, one per line, as
# "<name>: slug, slug, ...".
# ---------------------------------------------------------------------------
card_list(){
  local name="$1"
  # `|| true` (#517): a zero-match `grep` in the pipeline below exits 1, and
  # under `set -euo pipefail` that would abort the whole script before the
  # "extracted zero slugs" guard at this function's call site ever runs.
  awk -v name="$name:" '
    $0 ~ ("^" name) { sub("^" name, ""); buf=$0; getline nxt;
      while (nxt ~ /^  /) { buf = buf " " nxt; if ((getline nxt) <= 0) break }
      print buf; exit }
  ' "$CARD" | sed -E 's/\(.*$//' | tr ',' '\n' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' \
    | grep -E '^[a-z][a-z0-9-]*$' | grep -v '^see$' || true
}

for name in $CHECKLIST_NAMES; do
  card_list "$name" > "$WORK/card.$name"
  [ -s "$WORK/card.$name" ] || report "session-card.md: extracted zero slugs for '$name' from the Checklists block"
  if ! diff -u "$WORK/canon.$name" "$WORK/card.$name" > "$WORK/diff.card.$name.txt" 2>&1; then
    report "session-card.md's '$name' checklist list disagrees with session-log.md's canonical list — see diff below"
    cat "$WORK/diff.card.$name.txt" >&2
  fi
done

# ---------------------------------------------------------------------------
# 4. Prose agreement for all five checklists: each owning reference spells
# out the checklist as a numbered list, each item opening with a
# bold-backticked slug ("1. **`slug`** — ..."). Extract those in order and
# diff against the canonical list. SKILL.md step 0's 12 startup-item entries
# use the same shape; its closing item 13 is bolded as "`startup-complete`
# logged" rather than a bare slug, so it does not match the extraction
# regex and is correctly excluded from the diff.
# ---------------------------------------------------------------------------
prose_list(){
  local file="$1" start_marker="$2" end_marker="$3" section
  section="$(awk -v start="$start_marker" -v end="$end_marker" '
    $0 ~ start { on=1 }
    on && $0 ~ end && $0 !~ start { exit }
    on { print }
  ' "$file")"
  # `|| true` (#517): a zero-match `grep -oE` on either stage here exits 1,
  # and under `set -euo pipefail` that would abort the whole script before
  # the "extracted zero slugs — heading or numbering may have changed" guard
  # at this function's call sites ever runs.
  # shellcheck disable=SC2016 # single-quoted patterns matching literal backticks; nothing here is meant to expand
  printf '%s\n' "$section" | grep -oE '^[0-9]+\.\s+\*\*`[a-z0-9-]+`\*\*' | grep -oE '`[a-z0-9-]+`' | tr -d '`' || true
}

prose_list "$SKILL" "^\\*\\*0\\. Startup checklist\\*\\*" "^\\*\\*5\\. Execute\\*\\*" > "$WORK/prose.startup"
prose_list "$MAINTENANCE" "^## 1\\. Triage drain" "^## 2\\." > "$WORK/prose.triage"
prose_list "$ORCHESTRATION" "^## Dispatch checklist" "^## Report-handling checklist" > "$WORK/prose.dispatch"
prose_list "$ORCHESTRATION" "^## Report-handling checklist" "^## Parallel-agent manifest" > "$WORK/prose.report-handling"
prose_list "$OVERNIGHT" "^## Close checklist" '^\*\*$' > "$WORK/prose.close"
# Close checklist is the last section in overnight-and-status.md's relevant
# range for this purpose; cap at the first "Close with" completion line's
# following blank rather than a next heading that may not exist.
if [ ! -s "$WORK/prose.close" ]; then
  close_section="$(awk '/^## Close checklist/{on=1} on{print} on && /^Close with/{exit}' "$OVERNIGHT")"
  # `|| true` (#517): a zero-match `grep -oE` on either stage here exits 1,
  # and under `set -euo pipefail` that would abort the whole script before
  # the "extracted zero slugs" guard in the loop below ever runs.
  # shellcheck disable=SC2016 # single-quoted patterns matching literal backticks; nothing here is meant to expand
  printf '%s\n' "$close_section" \
    | grep -oE '^[0-9]+\.\s+\*\*`[a-z0-9-]+`\*\*' | grep -oE '`[a-z0-9-]+`' | tr -d '`' \
    > "$WORK/prose.close" || true
fi

for name in $CHECKLIST_NAMES; do
  [ -s "$WORK/prose.$name" ] || report "prose checklist for '$name': extracted zero slugs — heading or numbering may have changed"
  if ! diff -u "$WORK/canon.$name" "$WORK/prose.$name" > "$WORK/diff.prose.$name.txt" 2>&1; then
    report "the '$name' checklist's owning-reference prose disagrees with session-log.md's canonical list — see diff below"
    cat "$WORK/diff.prose.$name.txt" >&2
  fi
done

if [ "$fail" -ne 0 ]; then
  echo "test_session_log_slugs: FAILED" >&2
  exit 1
fi

echo "test_session_log_slugs: all assertions passed ($n_examples_checked example line(s) checked; 5 canonical lists cross-checked against session-card.md; 5 cross-checked against their owning-reference prose, including startup against SKILL.md step 0)"
