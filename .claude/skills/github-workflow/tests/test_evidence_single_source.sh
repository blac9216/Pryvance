#!/usr/bin/env bash
# test_evidence_single_source.sh — proves the evidence-manifest rules that
# `references/agent-rules.md`'s `<!-- rule:evidence -->` block states are stated
# there and nowhere else in this skill, in particular not restated in
# `references/templates/implementer.md`. A second, parallel check (below) proves
# the same thing one level down: `implementer.md`'s own local conformance-list
# properties (the `- **Field**:` colon, **Env**'s single physical line, the log's
# `$ <command>` / `[exit=N]` shape) are stated once, in that template, and not
# restated in `references/templates/fix-round.md`, which points at them instead
# (#634's own single-source requirement).
#
# Why a separate guard rather than an extension of test_agent_rules_drift.sh:
# that test enforces byte-identical *mirroring* — a block copied verbatim into
# an agent definition. The relationship here is the opposite one. implementer.md
# must NOT carry a copy; it points at the rule and adds only what is local to
# writing a manifest field in this repo. A byte-diff has nothing to compare, so
# the check is an absence check, and it belongs in its own file rather than
# bolted onto a test whose whole vocabulary is "these two blocks must match".
#
# The failure this prevents is the one issue #543 was filed on: the same
# sentences living in two files, one of them (agent-rules.md) guarded by the
# drift test and the other guarded by nothing, so a one-sided edit to either is
# invisible. Removing the duplicate beats guarding it — but nothing stopped it
# coming back, and a rule restated "just for convenience" is how it comes back.
#
# Comparison is done on a whitespace-flattened copy of each file, so a phrase
# that a reflow happens to split across two lines is still found. A guard that
# only catches an unwrapped copy would pass the moment someone ran the text
# through a formatter.
#
# Follows this directory's harness conventions (see tests/README.md): a
# `report()` / fail-counter accumulator so one run surfaces every defect rather
# than aborting on the first, and LANG=C / LC_ALL=C pinning, since these are
# byte comparisons over prose and must not depend on the caller's collation.
# There is no `gh` to mock: this is a pure read of two files in the tree.
#
# UNMOCKED-CONTEXT: not applicable. This suite issues no `gh` invocation at
# all, so there is no mock to bypass and no tripwire to wire up — the same
# exemption `test_agent_rules_drift.sh` documents for itself (#568).
set -euo pipefail
export LANG=C LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RULES="${EVSS_RULES:-$SCRIPT_DIR/../references/agent-rules.md}"
TEMPLATE="${EVSS_TEMPLATE:-$SCRIPT_DIR/../references/templates/implementer.md}"
FIXROUND="${EVSS_FIXROUND:-$SCRIPT_DIR/../references/templates/fix-round.md}"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/evidence-single-source.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

fail=0
report(){ echo "FAIL: $*" >&2; fail=1; }

for f in "$RULES" "$TEMPLATE" "$FIXROUND"; do
  [ -r "$f" ] || { echo "test_evidence_single_source: cannot read $f" >&2; exit 1; }
done

# The Evidence rule block on its own: a phrase must be canonical *there*, not
# merely somewhere in agent-rules.md.
sed -n '/<!-- rule:evidence -->/,/<!-- \/rule -->/p' "$RULES" > "$WORK/rule.md"
[ -s "$WORK/rule.md" ] || report "no <!-- rule:evidence --> block found in $RULES"

flatten(){ tr '\n' ' ' < "$1" | tr -s ' '; }
flatten "$WORK/rule.md" > "$WORK/rule.flat"
flatten "$TEMPLATE"     > "$WORK/template.flat"

# Each phrase is a distinctive clause of the Evidence rule — long enough that
# only a restatement carries it, and never a bare value a worked example would
# legitimately show. `the value is exactly ...` is phrased that way on purpose:
# implementer.md's sample manifest may show the coverage string as a field
# value, and showing a value is not restating the rule that picks it.
# shellcheck disable=SC2016  # the backticks are prose being matched, not shell.
PHRASES=(
  'never the pre-commit base'
  'Establish which case holds by grepping the testing documentation for'
  'never post the literal `<scratch>` placeholder or any other unexpanded variable'
  'the value is exactly `none — testing doc has no coverage section`'
  'A reviewer running its own tests for round'
  'carries exactly one of two values: the coverage command that was run'
)

for phrase in "${PHRASES[@]}"; do
  if ! grep -qF -- "$phrase" "$WORK/rule.flat"; then
    report "canonical phrase absent from the Evidence rule block — the rule was reworded, so update this guard's phrase list to match: '$phrase'"
    continue
  fi
  if grep -qF -- "$phrase" "$WORK/template.flat"; then
    report "implementer.md restates an agent-rules.md Evidence-rule sentence; point at the rule instead of copying it: '$phrase'"
  fi
done

# implementer.md has to actually point somewhere, or "not duplicated" would be
# satisfied by simply deleting the guidance.
for anchor in 'Head SHA' 'Raw log' 'Coverage'; do
  if ! grep -qF "agent-rules.md" "$TEMPLATE"; then
    report "implementer.md names no pointer to agent-rules.md at all"
    break
  fi
  grep -qF "**$anchor**" "$TEMPLATE" \
    || report "implementer.md no longer carries a **$anchor** field bullet"
done

# ===========================================================================
# Second, parallel check: implementer.md's own local conformance-list
# properties (added by #634) are stated once, in implementer.md, and not
# restated in fix-round.md, which points at them by reference instead. Same
# absence-check shape as the block above, one level down: the "rule" here is
# a section of implementer.md itself rather than agent-rules.md.
# ===========================================================================
sed -n '/^1\. \*\*Field colon\.\*\*/,/^   contents are\.$/p' "$TEMPLATE" > "$WORK/conformance.md"
[ -s "$WORK/conformance.md" ] || report "no conformance-list block (starting '1. **Field colon.**') found in $TEMPLATE"

flatten "$WORK/conformance.md" > "$WORK/conformance.flat"
flatten "$FIXROUND"            > "$WORK/fixround.flat"

# shellcheck disable=SC2016
PHRASES2=(
  'the checker'"'"'s field regex matches a bullet ending'
  'wrapping the value across a second line silently truncates it'
  "a runner's own prompt (\`\$ \`, \`+ \`, or \`> \`)"
)

for phrase in "${PHRASES2[@]}"; do
  if ! grep -qF -- "$phrase" "$WORK/conformance.flat"; then
    report "canonical phrase absent from implementer.md's conformance list — it was reworded, so update this guard's phrase list to match: '$phrase'"
    continue
  fi
  if grep -qF -- "$phrase" "$WORK/fixround.flat"; then
    report "fix-round.md restates an implementer.md conformance-list sentence; point at implementer.md instead of copying it: '$phrase'"
  fi
done

# fix-round.md has to actually point at implementer.md's Evidence section, or
# "not duplicated" would be satisfied by simply deleting the guidance.
grep -qF "implementer.md" "$FIXROUND" \
  || report "fix-round.md names no pointer to templates/implementer.md at all"

# ===========================================================================
# Self-test: each phrase is proven load-bearing. A copy of implementer.md with
# one canonical sentence pasted back in must fail this script — a guard whose
# only evidence is a passing run is not known to catch anything.
# ===========================================================================
if [ "${EVSS_SELFTEST:-1}" = "1" ]; then
  for i in "${!PHRASES[@]}"; do
    phrase="${PHRASES[$i]}"
    mutant="$WORK/mutant-$i.md"
    cp "$TEMPLATE" "$mutant"
    printf '\n%s\n' "$phrase" >> "$mutant"
    rc=0
    EVSS_SELFTEST=0 EVSS_RULES="$RULES" EVSS_TEMPLATE="$mutant" \
      bash "${BASH_SOURCE[0]}" >"$WORK/mutant-$i.out" 2>&1 || rc=$?
    if [ "$rc" -ne 0 ] && grep -qF "restates an agent-rules.md" "$WORK/mutant-$i.out"; then
      echo "PASS: self-test $i (a pasted-back copy of '${phrase:0:40}…' is caught)"
    else
      report "self-test $i: pasting '$phrase' back into implementer.md did not fail the guard"
      sed 's/^/    /' "$WORK/mutant-$i.out" >&2
    fi
  done

  # Same self-test, one level down: a copy of fix-round.md with one canonical
  # conformance-list sentence pasted back in must fail this script too.
  for i in "${!PHRASES2[@]}"; do
    phrase="${PHRASES2[$i]}"
    mutant2="$WORK/mutant2-$i.md"
    cp "$FIXROUND" "$mutant2"
    printf '\n%s\n' "$phrase" >> "$mutant2"
    rc=0
    EVSS_SELFTEST=0 EVSS_RULES="$RULES" EVSS_TEMPLATE="$TEMPLATE" EVSS_FIXROUND="$mutant2" \
      bash "${BASH_SOURCE[0]}" >"$WORK/mutant2-$i.out" 2>&1 || rc=$?
    if [ "$rc" -ne 0 ] && grep -qF "restates an implementer.md conformance-list" "$WORK/mutant2-$i.out"; then
      echo "PASS: self-test fixround-$i (a pasted-back copy of '${phrase:0:40}…' is caught)"
    else
      report "self-test fixround-$i: pasting '$phrase' back into fix-round.md did not fail the guard"
      sed 's/^/    /' "$WORK/mutant2-$i.out" >&2
    fi
  done

  # And the other direction: a reworded rule must fail loudly rather than pass
  # vacuously, which is what an absence check does when its phrase stops
  # existing on either side.
  reworded="$WORK/rules-reworded.md"
  sed 's/never the pre-commit base/never the uncommitted base/' "$RULES" > "$reworded"
  if cmp -s "$reworded" "$RULES"; then
    report "self-test rewording: the sed changed nothing — the anchor phrase moved"
  else
    rc=0
    EVSS_SELFTEST=0 EVSS_RULES="$reworded" EVSS_TEMPLATE="$TEMPLATE" \
      bash "${BASH_SOURCE[0]}" >"$WORK/reworded.out" 2>&1 || rc=$?
    if [ "$rc" -ne 0 ] && grep -qF "update this guard's phrase list" "$WORK/reworded.out"; then
      echo "PASS: self-test rewording (a reworded rule fails instead of passing vacuously)"
    else
      report "self-test rewording: a reworded Evidence rule did not fail the guard"
      sed 's/^/    /' "$WORK/reworded.out" >&2
    fi
  fi
fi

if [ "$fail" -ne 0 ]; then
  echo "test_evidence_single_source: FAILED" >&2
  exit 1
fi
echo "test_evidence_single_source: all assertions passed"
