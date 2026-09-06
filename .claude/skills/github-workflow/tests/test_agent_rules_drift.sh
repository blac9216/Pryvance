#!/usr/bin/env bash
# test_agent_rules_drift.sh — proves every `.claude/agents/workflow-*.md`
# definition's marked blocks stay byte-identical to their source: rule
# blocks against agent-rules.md, and `<!-- rubric:<slug> -->` blocks
# against github-pr-review/SKILL.md. Follows this directory's harness
# conventions (see tests/README.md): a `report()` / fail-counter
# accumulator so one run surfaces every defect rather than aborting on the
# first, and locale pinning — LANG=C / LC_ALL=C, since a mismatched byte
# comparison must not depend on the invoking shell's collation.
#
# Unlike this directory's other tests, there is no `gh` to mock: this is a
# pure file diff between the canonical sources and each mirrored
# definition, no network or fixtures involved. The self-test phase at the
# bottom is the exception — it builds mutated copies of the real files in
# a scratch dir and re-invokes this script against them, which is how each
# check below is proven load-bearing rather than merely present.
#
# UNMOCKED-CONTEXT: not applicable. This suite issues no `gh` invocation at
# all (grep the file: none), so there is no mock to bypass and no tripwire
# to wire up — the exemption tests/README.md's Shape section documents for
# this file (#568).
#
# Covers:
#  - every `<!-- rule:<slug> --> ... <!-- /rule -->` block inside a
#    definition diffs clean against the same-slug block in agent-rules.md.
#  - a definition naming a slug agent-rules.md does not have (renamed or
#    removed upstream) fails, distinctly from a content mismatch.
#  - malformed markers — an unclosed block, a stray closing marker with no
#    matching open, or a block still open at end-of-file — fail with a
#    diagnostic naming which file and which condition.
#  - a definition that opens the same slug twice fails. Extraction writes
#    one file per slug, so a second copy would otherwise overwrite the
#    first and hide drift in the earlier copy behind a clean later one.
#  - a definition mirroring zero blocks (extraction finds none) fails: a
#    definition file is supposed to mirror the applicable canonical blocks
#    verbatim, and finding none is itself a defect worth surfacing, not a
#    silent pass.
#  - the `<!-- mirrors: <slug>, … -->` declaration each definition carries
#    below its frontmatter agrees with the blocks actually present, in BOTH
#    directions: a declared slug whose block is missing fails (this is what
#    catches deletion of a whole mirrored block, which a content diff alone
#    cannot see), and a block present but undeclared fails. A definition
#    with no declaration line, or more than one, fails too.
#  - deleting a `mirrors:` slug together with its rule block, as a pair —
#    the block-deletion case the declaration check above cannot see on its
#    own, because both signals it compares (the declaration and the block)
#    are gone at once and agree with each other. Caught instead by this
#    suite's EXPECTED_MIRRORS ledger below: a slug the ledger expects but
#    the definition no longer declares fails, independent of what that
#    file now says about itself. The ledger is an exact set, so the
#    reverse fails too: a declared-and-mirrored slug the ledger omits.
#  - every `<!-- rubric:<slug> -->` block a definition carries diffs clean
#    against the same-slug block in github-pr-review/SKILL.md. The tree's
#    invariant is exactly one mirror per canonical rubric slug: zero fails
#    (the block exists to be copied, so deleting the copy fails too) and
#    more than one fails the same way `duplicate-rule-slug` does — a
#    second copy could be deleted without the first ever showing drift.
#  - a `.claude/agents/workflow-*.md` `tools:` frontmatter line listing
#    `Skill` or `TodoWrite` fails: platform-claude.md's "no definition in
#    this suite lists either" is a claim about the tree, held to the tree
#    rather than to prose. The closed set of gated tokens is derived from
#    platform-claude.md's own "`X` and `Y` are gated the same way as every
#    other tool" sentence rather than hardcoded, and the `tools:` line is
#    parsed in five legal YAML spellings: inline (`tools: A, B, C`), an
#    inline quoted scalar (`tools: "A, B, C"`), an inline flow sequence
#    (`tools: [A, B, C]`), the YAML block-sequence form (`tools:` alone,
#    followed by `- A` / `- B` items), and a block-sequence item carrying a
#    trailing ` # comment`.
#  - the canonical rules file, the rubric source and the platform doc each
#    exist and are readable before any extraction runs: a missing or
#    unreadable source fails with a diagnostic naming which file and which
#    condition, rather than a downstream extraction or derivation error
#    standing in for it.
#  - a definition file that cannot be read (permission denied) fails with
#    a diagnostic naming it, rather than aborting the whole run on a bare
#    shell arithmetic error.
#  - every self-test case maps to a bullet above: each mutates a
#    throwaway copy one defect at a time and asserts the stated failure.
#
# Sources are overridable through `DRIFT_RULES`, `DRIFT_AGENTS_DIR`,
# `DRIFT_RUBRIC_SOURCE` and `DRIFT_PLATFORM_DOC` so the self-test can point
# a nested run at a mutated copy; `DRIFT_SELFTEST=0` suppresses the
# self-test in that nested run. Defaults are the real files, so a plain
# invocation checks the real tree and then proves its own checks.
#
# Portability: POSIX-ish on purpose — no `find -printf`, no `mapfile`, no
# `sed -i`, no GNU-only primaries; block files are enumerated with a plain
# shell glob so the test behaves the same on a BSD/macOS userland as on
# GNU/Linux.
set -euo pipefail
export LANG=C LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"
RULES="${DRIFT_RULES:-$SCRIPT_DIR/../references/agent-rules.md}"
AGENTS_DIR="${DRIFT_AGENTS_DIR:-$SCRIPT_DIR/../../../agents}"
RUBRIC_SOURCE="${DRIFT_RUBRIC_SOURCE:-$SCRIPT_DIR/../../github-pr-review/SKILL.md}"
PLATFORM_DOC="${DRIFT_PLATFORM_DOC:-$SCRIPT_DIR/../references/platform-claude.md}"
SELFTEST="${DRIFT_SELFTEST:-1}"

# EXPECTED_MIRRORS — the mirrors ledger this suite holds each definition to,
# independent of what the definition's own `<!-- mirrors: … -->` line
# currently says. The declaration-vs-blocks check below (~L442) catches a
# declared slug whose block went missing, or a block present but
# undeclared — but a slug removed from the `<!-- mirrors: … -->` line
# *together with* its rule block leaves both signals agreeing with each
# other, so neither direction of that check ever fires (#704). This ledger
# is the second, independent signal: a snapshot of the real tree's rule
# slugs, kept in step with agent-rules.md and each definition's mirrors line
# the same way the rest of this suite is.
#
# Enforced as an EXACT set, not a subset: a ledger slug missing from the
# declaration fails (the paired-deletion case #704 was filed about), and a
# declared-and-mirrored slug the ledger does not list ALSO fails — this
# second direction is deliberate, not an oversight. A hand-maintained ledger
# that only ever grows without complaint reproduces #704's original defect
# one level up: a slug could be added and later deleted as a pair entirely
# inside the ledger's blind spot. The design choice this suite makes is that
# the ledger must be updated by hand whenever a definition legitimately
# gains or loses a mirrored rule block, and the suite fails loudly with a
# diagnostic naming exactly which ledger entry to change until that update
# is made — silence is never the correct response to drift here, including
# drift the ledger itself falls behind. A definition absent from this map
# entirely fails the completeness guard below rather than silently going
# unchecked.
declare -A EXPECTED_MIRRORS=(
  [workflow-calibrator.md]="no-subagents report shared-host"
  [workflow-fix.md]="no-subagents bounded-wait evidence git ci-gate shared-host report"
  [workflow-implementer.md]="no-subagents bounded-wait evidence git ci-gate shared-host report"
  [workflow-merge-verifier.md]="no-subagents bounded-wait evidence git ci-gate shared-host reviewer-identity report"
  [workflow-rebase.md]="no-subagents bounded-wait evidence git ci-gate shared-host report"
  [workflow-reviewer.md]="helper-tier bounded-wait evidence git ci-gate shared-host reviewer-identity report"
)

WORK="$(mktemp -d "${TMPDIR:-/tmp}/agent-rules-drift-test.XXXXXX")"
cleanup(){ rm -rf "$WORK"; }
trap cleanup EXIT

fail=0
report(){ echo "FAIL: $*" >&2; fail=1; }

# extract_blocks <source-file> <output-dir> [kind]
# `kind` is the marker family — `rule` (default) or `rubric`. Writes one
# file per mirrored slug (<output-dir>/<slug>.block, block body only,
# markers stripped) and a log of any malformed-marker or duplicate-slug
# findings to <output-dir>/.awklog. Returns non-zero when such findings
# were made; the caller inspects .awklog either way.
extract_blocks(){
  local file="$1" outdir="$2" kind="${3:-rule}"
  mkdir -p "$outdir"
  awk -v outdir="$outdir" -v kind="$kind" '
    BEGIN {
      openre = "^<!-- " kind ":[A-Za-z0-9_.-]+ -->$"
      closer = "<!-- /" kind " -->"
    }
    {
      line = $0
      gsub(/[ \t]+$/, "", line)
      if (line ~ openre) {
        if (open) {
          print "unclosed block before new " kind " marker (previous slug: " slug ")"
          malformed = 1
        }
        slug = line
        sub("^<!-- " kind ":", "", slug)
        sub(/ -->$/, "", slug)
        if (slug in seen) {
          print "duplicate " kind " block for slug \"" slug "\" — a later copy overwrites the first, hiding drift in the earlier one"
          malformed = 1
        }
        seen[slug] = 1
        open = 1
        buf = ""
        next
      }
      if (line == closer) {
        if (!open) {
          print "stray /" kind " marker with no matching open"
          malformed = 1
          next
        }
        f = outdir "/" slug ".block"
        printf "%s", buf > f
        close(f)
        open = 0
        slug = ""
        next
      }
      if (open) buf = buf $0 "\n"
    }
    END {
      if (open) {
        print "unclosed block at end of file (slug: " slug ")"
        malformed = 1
      }
      exit (malformed ? 1 : 0)
    }
  ' "$file" > "$outdir/.awklog" 2>&1
}

# drain_awklog <label> <outdir> — turn extraction findings into failures.
# Sets `drain_found` to 1 when anything was reported, so a caller can mark
# its own scope failed without re-reading the log. It reports through the
# global `report`, so it must never be called in a command substitution:
# `fail=1` set inside a subshell is lost, and the run would print FAIL
# lines and still exit 0.
drain_awklog(){
  local label="$1" outdir="$2"
  drain_found=0
  if [ -s "$outdir/.awklog" ]; then
    while IFS= read -r line; do
      report "$label: $line"
    done < "$outdir/.awklog"
    drain_found=1
  fi
}

# list_blocks <outdir> — basenames of the extracted block files, in glob
# (LC_ALL=C) order. No `find -printf`, no `mapfile`.
list_blocks(){
  local outdir="$1" bf
  shopt -s nullglob
  for bf in "$outdir"/*.block; do
    echo "${bf##*/}"
  done
  shopt -u nullglob
}

# get_tools_tokens <file> — one token per line from the frontmatter `tools:`
# line, whichever legal YAML spelling it uses: inline (`tools: A, B, C` on
# one line), an inline quoted scalar (`tools: "A, B, C"`), an inline flow
# sequence (`tools: [A, B, C]`), or the YAML block-sequence form (`tools:`
# alone, followed by `- A` / `- B` / `- C` items, each stripped of its
# leading `- ` marker, any ` #`-introduced trailing comment, and any
# trailing whitespace). Each token is also stripped of a surrounding quote
# pair, whichever form carried one. Only the first `tools:` line inside the
# leading `---` frontmatter block counts, matching how the inline form was
# scoped before.
get_tools_tokens(){
  local file="$1"
  awk '
    function trim_token(v) {
      gsub(/^[ \t]+|[ \t]+$/, "", v)
      gsub(/^["\x27]|["\x27]$/, "", v)
      return v
    }
    NR == 1 && $0 == "---" { infm = 1; next }
    infm && $0 == "---" { exit }
    !infm { next }
    found { if (inlist && $0 ~ /^[ \t]*-[ \t]*/) {
        val = $0
        sub(/^[ \t]*-[ \t]*/, "", val)
        sub(/[ \t]+#.*$/, "", val)
        val = trim_token(val)
        if (val != "") print val
        next
      }
      inlist = 0
      next
    }
    $0 ~ /^tools:[ \t]*$/ { found = 1; inlist = 1; next }
    $0 ~ /^tools:/ {
      found = 1
      val = $0
      sub(/^tools:[ \t]*/, "", val)
      gsub(/[ \t]+$/, "", val)
      gsub(/^["\x27]|["\x27]$/, "", val)
      gsub(/^\[|\][ \t]*$/, "", val)
      n = split(val, arr, ",")
      for (i = 1; i <= n; i++) {
        v = trim_token(arr[i])
        if (v != "") print v
      }
      next
    }
  ' "$file"
}

[ -f "$RULES" ] || { report "canonical file not found: $RULES"; echo "test_agent_rules_drift: FAILED" >&2; exit 1; }
[ -d "$AGENTS_DIR" ] || { report "agents directory not found: $AGENTS_DIR"; echo "test_agent_rules_drift: FAILED" >&2; exit 1; }
[ -f "$RUBRIC_SOURCE" ] || { report "rubric source not found: $RUBRIC_SOURCE"; echo "test_agent_rules_drift: FAILED" >&2; exit 1; }

# A canonical source that exists but cannot be read (permission denied) must
# fail with a diagnostic naming it unreadable, not "malformed" — awk cannot
# tell the two apart once it is handed an unopenable file, so check
# readability up front, before extract_blocks ever gets a chance to blur the
# two failure modes together.
[ -r "$RULES" ] || { report "canonical file is not readable: $RULES"; echo "test_agent_rules_drift: FAILED (canonical file unreadable)" >&2; exit 1; }
[ -r "$RUBRIC_SOURCE" ] || { report "rubric source is not readable: $RUBRIC_SOURCE"; echo "test_agent_rules_drift: FAILED (rubric source unreadable)" >&2; exit 1; }
[ -f "$PLATFORM_DOC" ] || { report "platform doc not found: $PLATFORM_DOC"; echo "test_agent_rules_drift: FAILED" >&2; exit 1; }
[ -r "$PLATFORM_DOC" ] || { report "platform doc is not readable: $PLATFORM_DOC"; echo "test_agent_rules_drift: FAILED (platform doc unreadable)" >&2; exit 1; }

RULES_NAME="$(basename "$RULES")"
RUBRIC_NAME="$(basename "$RUBRIC_SOURCE")"
PLATFORM_NAME="$(basename "$PLATFORM_DOC")"

# ---------------------------------------------------------------------------
# Derive the Skill/TodoWrite closed set from platform-claude.md itself,
# rather than hardcoding it, so a reworded or widened claim there is held to
# by the test instead of the test quietly enforcing a stale set. The claim
# lives in one sentence — "`Skill` and `TodoWrite` are gated the same way as
# every other tool" — followed, a line or two later, by "no definition in
# this suite lists either". Both pieces are checked: the first names the
# tokens, the second is asserted present verbatim (across a possible line
# wrap) so deleting or rewording the "no definition ... lists either" half
# fails too, even though it names no new tokens itself.
# ---------------------------------------------------------------------------
tools_claim_line="$(grep -m1 'are gated the same way as every other tool' "$PLATFORM_DOC" || true)"
# shellcheck disable=SC2016  # single-quoted sed pattern matching literal backticks; nothing here is meant to expand
closed_set="$(printf '%s\n' "$tools_claim_line" \
  | sed -n 's/^`\([A-Za-z][A-Za-z0-9]*\)` and `\([A-Za-z][A-Za-z0-9]*\)` are gated the same way as every other tool.*/\1 \2/p')"
if [ -z "$closed_set" ]; then
  report "$PLATFORM_NAME: no sentence of the form '\`X\` and \`Y\` are gated the same way as every other tool' found — cannot derive the closed-set tokens the tools: guard enforces"
fi

platform_joined="$(tr '\n' ' ' < "$PLATFORM_DOC" | tr -s ' ')"
case "$platform_joined" in
  *"no definition in this suite lists either"*) ;;
  *) report "$PLATFORM_NAME: sentence 'no definition in this suite lists either' not found — the tools: guard's closed-set claim is not stated, or was reworded, so drift there would go unenforced" ;;
esac

# ---------------------------------------------------------------------------
# Extract the canonical blocks once, both families. A malformed canonical
# file is a defect worth failing loudly on rather than silently comparing
# against nothing.
# ---------------------------------------------------------------------------
CANON="$WORK/canon"
canon_rc=0
extract_blocks "$RULES" "$CANON" rule || canon_rc=$?
drain_awklog "$RULES_NAME" "$CANON"
if [ "$canon_rc" -ne 0 ]; then
  echo "test_agent_rules_drift: FAILED (canonical file malformed)" >&2
  exit 1
fi

canon_blocks=()
while IFS= read -r b; do canon_blocks+=("$b"); done < <(list_blocks "$CANON")
n_canon_blocks="${#canon_blocks[@]}"
[ "$n_canon_blocks" -gt 0 ] || report "$RULES_NAME: extracted zero rule blocks — markers absent or all malformed"

CANON_RUBRIC="$WORK/canon-rubric"
canon_rubric_rc=0
extract_blocks "$RUBRIC_SOURCE" "$CANON_RUBRIC" rubric || canon_rubric_rc=$?
drain_awklog "$RUBRIC_NAME" "$CANON_RUBRIC"
if [ "$canon_rubric_rc" -ne 0 ]; then
  echo "test_agent_rules_drift: FAILED (rubric source malformed)" >&2
  exit 1
fi

canon_rubrics=()
while IFS= read -r b; do canon_rubrics+=("$b"); done < <(list_blocks "$CANON_RUBRIC")
n_canon_rubrics="${#canon_rubrics[@]}"
[ "$n_canon_rubrics" -gt 0 ] || report "$RUBRIC_NAME: extracted zero rubric blocks — markers absent or all malformed"

# Which canonical rubric slugs some definition mirrors; a slug nothing
# mirrors is reported after the loop.
rubric_mirrors=""

# ---------------------------------------------------------------------------
# One definition at a time.
# ---------------------------------------------------------------------------
shopt -s nullglob
definitions=("$AGENTS_DIR"/workflow-*.md)
shopt -u nullglob

[ "${#definitions[@]}" -gt 0 ] || report "no .claude/agents/workflow-*.md definitions found under $AGENTS_DIR"

# A definition absent from EXPECTED_MIRRORS is a ledger gap, not a pass: the
# paired-deletion guard below only ever checks a name this ledger knows
# about, so a new definition added without an entry here would otherwise go
# unchecked by this guard silently.
for def in "${definitions[@]}"; do
  bn="$(basename "$def")"
  [ -n "${EXPECTED_MIRRORS[$bn]+set}" ] || report "$bn: no entry in this suite's EXPECTED_MIRRORS ledger — add one so a mirrored rule block deleted together with its '<!-- mirrors: … -->' declaration is still caught"
done

for def in "${definitions[@]}"; do
  name="$(basename "$def")"

  # An unreadable definition must fail with a named diagnostic rather than
  # abort the whole run: awk and grep below both fail to open() it, and a
  # downstream integer comparison against grep's then-empty output is what
  # turned that into a bare `[: : integer expression expected` before this
  # check existed. Check readability first and skip the rest of this
  # definition's checks — there is nothing left to read.
  if [ ! -r "$def" ]; then
    report "$name: definition file is not readable — skipping its checks"
    echo "FAIL: $name"
    continue
  fi

  defdir="$WORK/${name%.md}"
  def_rc=0
  extract_blocks "$def" "$defdir" rule || def_rc=$?

  def_fail=0
  drain_awklog "$name" "$defdir"
  [ "$drain_found" -eq 0 ] || def_fail=1
  if [ "$def_rc" -ne 0 ]; then
    def_fail=1
  fi

  # -------------------------------------------------------------------------
  # platform-claude.md asserts a closed set — the tokens derived above from
  # its own "`X` and `Y` are gated the same way as every other tool" claim —
  # on the definition's `tools:` frontmatter line. That is a claim about the
  # tree, not just prose, so hold it to the tree: a widened allowlist would
  # silently falsify the sentence otherwise. Both frontmatter forms are
  # parsed: inline (`tools: A, B, C`) and YAML block-sequence (`tools:` on
  # its own line, followed by `- A` / `- B` / `- C` list items).
  # -------------------------------------------------------------------------
  tool_tokens=()
  while IFS= read -r t; do [ -n "$t" ] && tool_tokens+=("$t"); done < <(get_tools_tokens "$def")
  for tok in "${tool_tokens[@]}"; do
    for closed_tok in $closed_set; do
      if [ "$tok" = "$closed_tok" ]; then
        report "$name: tools: line lists '$tok' — $PLATFORM_NAME states no definition in this suite lists any of: ${closed_set% }"
        def_fail=1
      fi
    done
  done

  # Portable enumeration: a plain glob over the extraction dir, basenames
  # taken with parameter expansion. No `find -printf`, no `mapfile`.
  # Glob expansion is already sorted, and LC_ALL=C above pins the collation,
  # so the diagnostics below come out in a deterministic order without an
  # extra `sort` round-trip.
  blocks=()
  while IFS= read -r b; do blocks+=("$b"); done < <(list_blocks "$defdir")
  if [ "${#blocks[@]}" -eq 0 ]; then
    report "$name: mirrors zero rule blocks"
    def_fail=1
  fi

  # -------------------------------------------------------------------------
  # The `<!-- mirrors: … -->` declaration, cross-checked against the blocks
  # actually present. A content diff cannot see a block that is simply gone;
  # this is what makes whole-block deletion fail.
  # -------------------------------------------------------------------------
  n_decl=$(grep -c '^<!-- mirrors:.*-->$' "$def" || true)
  if [ "$n_decl" -eq 0 ]; then
    report "$name: no '<!-- mirrors: … -->' declaration line — every definition must declare the slugs it mirrors"
    def_fail=1
  elif [ "$n_decl" -gt 1 ]; then
    report "$name: $n_decl '<!-- mirrors: … -->' declaration lines — expected exactly 1"
    def_fail=1
  else
    declared="$(grep '^<!-- mirrors:.*-->$' "$def" \
      | sed -e 's/^<!-- mirrors://' -e 's/-->$//' -e 's/,/ /g')"
    present=" "
    for blockfile in "${blocks[@]}"; do
      present="$present${blockfile%.block} "
    done
    declared_norm=" "
    for slug in $declared; do
      declared_norm="$declared_norm$slug "
      case "$present" in
        *" $slug "*) ;;
        *)
          report "$name: declares slug '$slug' in its '<!-- mirrors: … -->' line but the block is missing from the file"
          def_fail=1
          ;;
      esac
      if [ ! -f "$CANON/$slug.block" ]; then
        report "$name: declares slug '$slug', which $RULES_NAME does not define"
        def_fail=1
      fi
    done
    for blockfile in "${blocks[@]}"; do
      slug="${blockfile%.block}"
      case "$declared_norm" in
        *" $slug "*) ;;
        *)
          report "$name: mirrors block '$slug' but does not declare it in its '<!-- mirrors: … -->' line"
          def_fail=1
          ;;
      esac
    done

    # -----------------------------------------------------------------------
    # The paired-deletion guard (#704): hold the declaration against the
    # ledger, not just against the blocks present in this same file. A slug
    # removed from the declaration line together with its rule block leaves
    # `declared_norm` and `present` agreeing with each other — both checks
    # above pass — so this is the only check that can still see the slug
    # missing. Enforced as an exact set, both directions: a ledger slug the
    # declaration no longer carries fails (the deletion case above), and a
    # declared-and-mirrored slug the ledger does not yet list ALSO fails —
    # otherwise a slug could be added and later removed as a pair entirely
    # inside a ledger that only ever grows without complaint, reopening
    # #704 one level up.
    # -----------------------------------------------------------------------
    if [ -n "${EXPECTED_MIRRORS[$name]+set}" ]; then
      ledger_norm=" ${EXPECTED_MIRRORS[$name]} "
      for exp_slug in ${EXPECTED_MIRRORS[$name]}; do
        case "$declared_norm" in
          *" $exp_slug "*) ;;
          *)
            report "$name: expected to mirror slug '$exp_slug' per this suite's EXPECTED_MIRRORS ledger, but no longer declares it — a mirrored rule block may have been deleted together with its '<!-- mirrors: … -->' declaration"
            def_fail=1
            ;;
        esac
      done
      for slug in $declared; do
        case "$ledger_norm" in
          *" $slug "*) ;;
          *)
            report "$name: declares and mirrors slug '$slug', which this suite's EXPECTED_MIRRORS ledger does not list — add '$slug' to EXPECTED_MIRRORS[$name] in $(basename "$SELF") to keep the ledger an exact set"
            def_fail=1
            ;;
        esac
      done
    fi
  fi

  for blockfile in "${blocks[@]}"; do
    slug="${blockfile%.block}"
    canon_block="$CANON/$blockfile"
    def_block="$defdir/$blockfile"
    if [ ! -f "$canon_block" ]; then
      report "$name: slug '$slug' has no matching block in $RULES_NAME"
      def_fail=1
      continue
    fi
    if ! diff -u "$canon_block" "$def_block" > "$WORK/diff.$slug.$name.txt" 2>&1; then
      report "$name: slug '$slug' drifted from $RULES_NAME — see diff below"
      cat "$WORK/diff.$slug.$name.txt" >&2
      def_fail=1
    fi
  done

  # -------------------------------------------------------------------------
  # Rubric blocks. Same treatment, different source: a
  # `<!-- rubric:<slug> -->` block in a definition is a verbatim copy of
  # SKILL.md's block of that slug, and prose telling the reader not to
  # hand-edit it is not a check.
  # -------------------------------------------------------------------------
  rubdir="$WORK/${name%.md}-rubric"
  rub_rc=0
  extract_blocks "$def" "$rubdir" rubric || rub_rc=$?
  drain_awklog "$name" "$rubdir"
  [ "$drain_found" -eq 0 ] || def_fail=1
  if [ "$rub_rc" -ne 0 ]; then
    def_fail=1
  fi

  rubrics=()
  while IFS= read -r b; do rubrics+=("$b"); done < <(list_blocks "$rubdir")
  for blockfile in "${rubrics[@]}"; do
    slug="${blockfile%.block}"
    rubric_mirrors="$rubric_mirrors $slug"
    canon_block="$CANON_RUBRIC/$blockfile"
    if [ ! -f "$canon_block" ]; then
      report "$name: rubric block '$slug' has no matching block in $RUBRIC_NAME"
      def_fail=1
      continue
    fi
    if ! diff -u "$canon_block" "$rubdir/$blockfile" > "$WORK/rubricdiff.$slug.$name.txt" 2>&1; then
      report "$name: rubric block '$slug' drifted from $RUBRIC_NAME — see diff below"
      cat "$WORK/rubricdiff.$slug.$name.txt" >&2
      def_fail=1
    fi
  done

  n_all=$(( ${#blocks[@]} + ${#rubrics[@]} ))
  if [ "$def_fail" -eq 0 ]; then
    echo "PASS: $name ($n_all block(s) match their source)"
  else
    echo "FAIL: $name"
  fi
done

# A rubric block in SKILL.md that no definition mirrors is drift too — the
# markers exist so a copy can be held to the original, and a deleted copy
# is exactly what a content diff cannot see. The invariant this tree
# establishes is exactly one mirror per canonical rubric slug: a count of
# zero is the deleted-copy case above, and a count above one is the
# overwrite-hides-drift shape `duplicate-rule-slug` guards in the opposite
# direction — a second copy of the same slug could be deleted without the
# first ever showing drift, hiding it. Both directions fail here.
for blockfile in "${canon_rubrics[@]}"; do
  slug="${blockfile%.block}"
  count="$(printf '%s\n' "$rubric_mirrors" | tr ' ' '\n' | grep -c -x -- "$slug" || true)"
  case "$count" in
    0) report "no definition mirrors rubric block '$slug' from $RUBRIC_NAME — the block is marked to be copied, so a definition must carry it" ;;
    1) ;;
    *) report "$count definitions mirror rubric block '$slug' from $RUBRIC_NAME — exactly 1 mirror is the invariant this tree establishes, and a count above that hides drift the same way a duplicate rule-block slug would" ;;
  esac
done

# ---------------------------------------------------------------------------
# Self-test: each check above, proven load-bearing.
#
# Every case copies the real sources into a scratch tree, applies exactly
# one defect, and re-invokes this script against the copy with
# DRIFT_SELFTEST=0 (so the nested run does not recurse). A case that
# expects failure also names the diagnostic it expects, so a mutation that
# fails the run for some unrelated reason does not count as proof.
# ---------------------------------------------------------------------------

# selftest_case_dir <case-name> — an unmutated copy of the three sources.
selftest_case_dir(){
  local case_name="$1"
  local c="$WORK/selftest/$case_name"
  mkdir -p "$c/agents"
  cp "$RULES" "$c/agent-rules.md"
  cp "$AGENTS_DIR"/workflow-*.md "$c/agents/"
  cp "$RUBRIC_SOURCE" "$c/rubric-source.md"
  cp "$PLATFORM_DOC" "$c/platform-claude.md"
  echo "$c"
}

# run_case <case-name> <pass|fail> [expected-diagnostic-substring]
run_case(){
  local case_name="$1" expect="$2" want="${3:-}"
  local c="$WORK/selftest/$case_name" rc=0
  DRIFT_SELFTEST=0 \
  DRIFT_RULES="$c/agent-rules.md" \
  DRIFT_AGENTS_DIR="$c/agents" \
  DRIFT_RUBRIC_SOURCE="$c/rubric-source.md" \
  DRIFT_PLATFORM_DOC="$c/platform-claude.md" \
    bash "$SELF" > "$c/run.log" 2>&1 || rc=$?
  if [ "$expect" = "pass" ] && [ "$rc" -ne 0 ]; then
    report "self-test '$case_name': expected exit 0 on an unmutated copy, got $rc"
    cat "$c/run.log" >&2
    return 0
  fi
  if [ "$expect" = "fail" ]; then
    if [ "$rc" -eq 0 ]; then
      report "self-test '$case_name': mutation did not fail the check — it is not load-bearing"
      cat "$c/run.log" >&2
      return 0
    fi
    if [ -n "$want" ] && ! grep -qF -- "$want" "$c/run.log"; then
      report "self-test '$case_name': failed, but with no diagnostic matching '$want' — it failed for the wrong reason"
      cat "$c/run.log" >&2
      return 0
    fi
  fi
  echo "PASS: self-test $case_name (expected $expect, exit $rc)"
}

# mutate_first_line <file> <opening-marker> — appends a marker word to the
# first non-empty line inside the named block: the one-word edit the drift
# check exists to catch.
mutate_first_line(){
  local file="$1" open="$2" tmp="$1.tmp"
  awk -v open="$open" '
    $0 == open { print; inb = 1; next }
    inb && !done && $0 != "" { print $0 " DRIFT"; done = 1; inb = 0; next }
    { print }
  ' "$file" > "$tmp"
  mv "$tmp" "$file"
}

# drop_block <file> <opening-marker> <closing-marker> — `close` is an awk
# builtin, so the closing marker travels into awk as `endm`.
drop_block(){
  local file="$1" open="$2" close="$3" tmp="$1.tmp"
  awk -v open="$open" -v endm="$close" '
    $0 == open { skip = 1; next }
    skip && $0 == endm { skip = 0; next }
    !skip { print }
  ' "$file" > "$tmp"
  mv "$tmp" "$file"
}

# add_mirrors_slug <file> <slug> — appends exactly one slug to a
# definition's `<!-- mirrors: … -->` declaration line, leaving every other
# slug and the line's own marker syntax intact. Paired with
# append_block_copy for the same slug's rule block, this reproduces the
# opposite pairing from remove_mirrors_slug/drop_block: a slug added and
# mirrored together, proving the EXPECTED_MIRRORS ledger's reverse
# direction — a declared-and-present slug the ledger does not list — is
# load-bearing (F2, PR #726 round 1 relay).
add_mirrors_slug(){
  local file="$1" slug="$2" tmp="$1.tmp"
  awk -v slug="$slug" '
    /^<!-- mirrors:.*-->$/ {
      line = $0
      sub(/^<!-- mirrors:[ \t]*/, "", line)
      sub(/[ \t]*-->$/, "", line)
      print "<!-- mirrors: " line ", " slug " -->"
      next
    }
    { print }
  ' "$file" > "$tmp"
  mv "$tmp" "$file"
}

# remove_mirrors_slug <file> <slug> — removes exactly one slug from a
# definition's `<!-- mirrors: … -->` declaration line, leaving every other
# slug and the line's own marker syntax intact. Paired with drop_block on
# the same slug's rule block, this reproduces #704's paired deletion: the
# declaration and the block vanish together, so neither direction of the
# ordinary mirrors-vs-blocks check (which compares only within this one
# file) ever disagrees with itself.
remove_mirrors_slug(){
  local file="$1" slug="$2" tmp="$1.tmp"
  awk -v slug="$slug" '
    /^<!-- mirrors:.*-->$/ {
      line = $0
      sub(/^<!-- mirrors:[ \t]*/, "", line)
      sub(/[ \t]*-->$/, "", line)
      n = split(line, arr, ",")
      out = ""
      for (i = 1; i <= n; i++) {
        v = arr[i]
        gsub(/^[ \t]+|[ \t]+$/, "", v)
        if (v != "" && v != slug) {
          out = (out == "" ? v : out ", " v)
        }
      }
      print "<!-- mirrors: " out " -->"
      next
    }
    { print }
  ' "$file" > "$tmp"
  mv "$tmp" "$file"
}

# duplicate_block <file> <opening-marker> <closing-marker> — appends a
# second, byte-identical copy of the block to the end of the file.
duplicate_block(){
  local file="$1" open="$2" close="$3" tmp="$1.tmp"
  { cat "$file"
    echo
    awk -v open="$open" -v endm="$close" '
      $0 == open { emit = 1 }
      emit { print }
      emit && $0 == endm { exit }
    ' "$file"
  } > "$tmp"
  mv "$tmp" "$file"
}

# append_block_copy <file> <opening-marker> <closing-marker> <content-file>
# — appends a new `<opening-marker> ... <closing-marker>` block built from
# an already-extracted block body, onto a *different* definition than the
# one it came from. Used to prove the rubric-mirror-count invariant: a
# second definition mirroring the same canonical rubric slug.
append_block_copy(){
  local file="$1" open="$2" close="$3" contentfile="$4" tmp="$1.tmp"
  { cat "$file"
    echo
    echo "$open"
    cat "$contentfile"
    echo "$close"
  } > "$tmp"
  mv "$tmp" "$file"
}

# add_to_tools_line <file> <tool-name> — appends ", <tool-name>" to the
# frontmatter `tools:` line, the one-line edit the Skill/TodoWrite
# closed-set check exists to catch.
add_to_tools_line(){
  local file="$1" tool="$2" tmp="$1.tmp"
  awk -v tool="$tool" '
    /^tools:/ && !done { print $0 ", " tool; done = 1; next }
    { print }
  ' "$file" > "$tmp"
  mv "$tmp" "$file"
}

# to_yaml_list_tools <file> <tool-name> — rewrites a definition's inline
# `tools: A, B, C` frontmatter line to the YAML block-sequence form, adding
# <tool-name> as one more list item. Proves the list-form parser catches a
# closed-set violation the same way the inline-form parser does.
to_yaml_list_tools(){
  local file="$1" tool="$2" tmp="$1.tmp"
  awk -v tool="$tool" '
    /^tools:/ && !done {
      done = 1
      line = $0
      sub(/^tools:[ \t]*/, "", line)
      n = split(line, arr, ",")
      print "tools:"
      for (i = 1; i <= n; i++) {
        v = arr[i]
        gsub(/^[ \t]+|[ \t]+$/, "", v)
        if (v != "") print "  - " v
      }
      print "  - " tool
      next
    }
    { print }
  ' "$file" > "$tmp"
  mv "$tmp" "$file"
}

# to_quoted_scalar_tools <file> <tool-name> — rewrites a definition's inline
# `tools: A, B, C` frontmatter line to the quoted-scalar form
# `tools: "A, B, C"`, adding <tool-name> as one more comma-separated member.
# Proves the quoted-scalar parser catches a closed-set violation the same
# way the bare inline form does.
to_quoted_scalar_tools(){
  local file="$1" tool="$2" tmp="$1.tmp"
  awk -v tool="$tool" '
    /^tools:/ && !done {
      done = 1
      line = $0
      sub(/^tools:[ \t]*/, "", line)
      print "tools: \"" line ", " tool "\""
      next
    }
    { print }
  ' "$file" > "$tmp"
  mv "$tmp" "$file"
}

# to_flow_seq_tools <file> <tool-name> — rewrites a definition's inline
# `tools: A, B, C` frontmatter line to the YAML flow-sequence form
# `tools: [A, B, C]`, adding <tool-name> as one more member. Proves the
# flow-sequence parser catches a closed-set violation the same way the bare
# inline form does.
to_flow_seq_tools(){
  local file="$1" tool="$2" tmp="$1.tmp"
  awk -v tool="$tool" '
    /^tools:/ && !done {
      done = 1
      line = $0
      sub(/^tools:[ \t]*/, "", line)
      print "tools: [" line ", " tool "]"
      next
    }
    { print }
  ' "$file" > "$tmp"
  mv "$tmp" "$file"
}

# to_yaml_list_tools_commented <file> <tool-name> — like to_yaml_list_tools,
# but appends <tool-name> as a list item carrying a trailing ` # note`
# comment. Proves the list-item parser strips a trailing comment before
# matching the closed set, rather than comparing the token-plus-comment
# string and missing the violation.
to_yaml_list_tools_commented(){
  local file="$1" tool="$2" tmp="$1.tmp"
  awk -v tool="$tool" '
    /^tools:/ && !done {
      done = 1
      line = $0
      sub(/^tools:[ \t]*/, "", line)
      n = split(line, arr, ",")
      print "tools:"
      for (i = 1; i <= n; i++) {
        v = arr[i]
        gsub(/^[ \t]+|[ \t]+$/, "", v)
        if (v != "") print "  - " v
      }
      print "  - " tool " # note"
      next
    }
    { print }
  ' "$file" > "$tmp"
  mv "$tmp" "$file"
}

# reword_closed_set_sentence <file> — breaks platform-claude.md's "no
# definition in this suite lists either" sentence, which wraps across a
# line break in the real file, so the phrase cannot be matched with a
# single-line sed. Joins only the two wrapped lines carrying the sentence —
# never the whole file — substitutes across that join, and emits the result
# as one line; every other line, including the unrelated "gated the same
# way as every other tool" sentence the other half of this guard derives
# the closed set from, passes through untouched. Flattening the whole file
# (the previous approach) collaterally broke that other, `^`-anchored
# derivation too, so the mutation failed for two reasons instead of the one
# it names (#632) — this join is scoped to exactly the sentence in play, so
# the line wrap really is not load-bearing here, which the previous
# comment's claim did not hold up to.
reword_closed_set_sentence(){
  local file="$1" tmp="$1.tmp"
  awk '
    { lines[NR] = $0 }
    END {
      target = "no definition in this suite lists either"
      replacement = "every definition in this suite may list either"
      i = 1
      while (i <= NR) {
        if (i < NR) {
          joined = lines[i] " " lines[i + 1]
          if (index(joined, target) > 0) {
            gsub(target, replacement, joined)
            print joined
            i += 2
            continue
          }
        }
        print lines[i]
        i += 1
      }
    }
  ' "$file" > "$tmp"
  mv "$tmp" "$file"
}

if [ "$SELFTEST" = "1" ]; then
  # The four up-front source-existence/readability guards (RULES,
  # RUBRIC_SOURCE, PLATFORM_DOC) added alongside the per-definition
  # unreadable-file check above. Same shape: a missing PLATFORM_DOC has no
  # DAC obstacle and runs unconditionally; the three unreadable-source
  # cases hit the same root DAC bypass as unreadable-definition below, so
  # they reuse its `[ "$(id -u)" -eq 0 ]` skip rather than a second
  # mechanism.
  if [ "$(id -u)" -eq 0 ]; then
    echo "SKIP: self-test canonical-source-unreadable (running as uid 0 — chmod 000 does not block root's read)"
    echo "SKIP: self-test rubric-source-unreadable (running as uid 0 — chmod 000 does not block root's read)"
    echo "SKIP: self-test platform-doc-unreadable (running as uid 0 — chmod 000 does not block root's read)"
  else
    c="$(selftest_case_dir canonical-source-unreadable)"
    chmod 000 "$c/agent-rules.md"
    run_case canonical-source-unreadable fail "canonical file unreadable"

    c="$(selftest_case_dir rubric-source-unreadable)"
    chmod 000 "$c/rubric-source.md"
    run_case rubric-source-unreadable fail "rubric source unreadable"

    c="$(selftest_case_dir platform-doc-unreadable)"
    chmod 000 "$c/platform-claude.md"
    run_case platform-doc-unreadable fail "platform doc unreadable"
  fi

  c="$(selftest_case_dir platform-doc-missing)"
  rm -f "$c/platform-claude.md"
  run_case platform-doc-missing fail "platform doc not found"

  # Derive the fixture targets from the tree rather than hardcoding a
  # filename or a slug, so renaming either does not quietly skip a case.
  rubric_def=""
  for def in "${definitions[@]}"; do
    if grep -q '^<!-- rubric:' "$def"; then rubric_def="$(basename "$def")"; break; fi
  done
  rubric_slug=""
  [ "$n_canon_rubrics" -gt 0 ] && rubric_slug="${canon_rubrics[0]%.block}"

  if [ -z "$rubric_def" ] || [ -z "$rubric_slug" ]; then
    report "self-test: no definition carries a '<!-- rubric:<slug> -->' block, or $RUBRIC_NAME marks none — the rubric checks cannot be proven load-bearing"
  else
    rubric_open="<!-- rubric:$rubric_slug -->"
    rule_slug="$(grep -m1 '^<!-- rule:' "$AGENTS_DIR/$rubric_def" | sed -e 's/^<!-- rule://' -e 's/ -->$//')"

    c="$(selftest_case_dir clean)"
    run_case clean pass

    c="$(selftest_case_dir rubric-drift-in-definition)"
    mutate_first_line "$c/agents/$rubric_def" "$rubric_open"
    run_case rubric-drift-in-definition fail "rubric block '$rubric_slug' drifted"

    c="$(selftest_case_dir rubric-drift-in-source)"
    mutate_first_line "$c/rubric-source.md" "$rubric_open"
    run_case rubric-drift-in-source fail "rubric block '$rubric_slug' drifted"

    c="$(selftest_case_dir rubric-copy-deleted)"
    drop_block "$c/agents/$rubric_def" "$rubric_open" "<!-- /rubric -->"
    run_case rubric-copy-deleted fail "no definition mirrors rubric block '$rubric_slug'"

    c="$(selftest_case_dir duplicate-rule-slug)"
    duplicate_block "$c/agents/$rubric_def" "<!-- rule:$rule_slug -->" "<!-- /rule -->"
    run_case duplicate-rule-slug fail "duplicate rule block for slug \"$rule_slug\""

    c="$(selftest_case_dir rule-drift)"
    mutate_first_line "$c/agents/$rubric_def" "<!-- rule:$rule_slug -->"
    run_case rule-drift fail "slug '$rule_slug' drifted"

    # #704: a `mirrors:` slug removed together with its rule block, as a
    # pair — the case the ordinary declaration-vs-blocks check cannot see,
    # since both signals it compares are gone at once and so agree with
    # each other. Derived from the EXPECTED_MIRRORS ledger rather than a
    # hardcoded filename/slug, so renaming either does not quietly skip it.
    manifest_def=""
    manifest_slug=""
    for def in "${definitions[@]}"; do
      bn="$(basename "$def")"
      if [ -n "${EXPECTED_MIRRORS[$bn]+set}" ] && [ -n "${EXPECTED_MIRRORS[$bn]}" ]; then
        for s in ${EXPECTED_MIRRORS[$bn]}; do
          manifest_def="$bn"
          manifest_slug="$s"
          break
        done
      fi
      [ -n "$manifest_def" ] && break
    done
    if [ -z "$manifest_def" ]; then
      report "self-test: EXPECTED_MIRRORS ledger is empty — cannot prove the paired-deletion guard load-bearing"
    else
      c="$(selftest_case_dir mirrored-rule-block-deleted)"
      remove_mirrors_slug "$c/agents/$manifest_def" "$manifest_slug"
      drop_block "$c/agents/$manifest_def" "<!-- rule:$manifest_slug -->" "<!-- /rule -->"
      run_case mirrored-rule-block-deleted fail "expected to mirror slug '$manifest_slug'"
    fi

    # F2 (PR #726 round 1 relay): EXPECTED_MIRRORS is an exact set, not a
    # subset — a slug added and mirrored (declared AND its block present)
    # that the ledger does not list must also fail, or a slug could be
    # added and later removed as a pair entirely inside a ledger that only
    # ever grows without complaint, reopening #704 one level up. Pick a
    # definition/canonical-slug pair where the ledger genuinely omits that
    # slug for that definition, rather than hardcoding one.
    extra_def=""
    extra_slug=""
    for def in "${definitions[@]}"; do
      bn="$(basename "$def")"
      [ -n "${EXPECTED_MIRRORS[$bn]+set}" ] || continue
      ledger_norm=" ${EXPECTED_MIRRORS[$bn]} "
      for cb in "${canon_blocks[@]}"; do
        cslug="${cb%.block}"
        case "$ledger_norm" in
          *" $cslug "*) ;;
          *)
            extra_def="$bn"
            extra_slug="$cslug"
            ;;
        esac
        [ -n "$extra_def" ] && break
      done
      [ -n "$extra_def" ] && break
    done
    if [ -z "$extra_def" ]; then
      report "self-test: no definition/slug pair available — every canonical slug is already listed in every definition's EXPECTED_MIRRORS entry — cannot prove the ledger's exact-set reverse direction load-bearing"
    else
      c="$(selftest_case_dir mirrored-slug-added-not-in-ledger)"
      add_mirrors_slug "$c/agents/$extra_def" "$extra_slug"
      append_block_copy "$c/agents/$extra_def" "<!-- rule:$extra_slug -->" "<!-- /rule -->" "$CANON/$extra_slug.block"
      run_case mirrored-slug-added-not-in-ledger fail "which this suite's EXPECTED_MIRRORS ledger does not list"
    fi

    # A second definition mirroring the same canonical rubric slug: the
    # count-above-one direction of the rubric-mirror invariant.
    other_def=""
    for def in "${definitions[@]}"; do
      bn="$(basename "$def")"
      if [ "$bn" != "$rubric_def" ]; then other_def="$bn"; break; fi
    done
    if [ -z "$other_def" ]; then
      report "self-test: only one definition exists — cannot prove the rubric double-mirror check load-bearing"
    else
      c="$(selftest_case_dir rubric-double-mirror)"
      append_block_copy "$c/agents/$other_def" "$rubric_open" "<!-- /rubric -->" "$CANON_RUBRIC/$rubric_slug.block"
      run_case rubric-double-mirror fail "definitions mirror rubric block '$rubric_slug'"
    fi
  fi

  if [ "${#definitions[@]}" -eq 0 ]; then
    report "self-test: no definitions found — cannot prove the tools-line and unreadable-file checks load-bearing"
  else
    # Skill/TodoWrite closed-set check: platform-claude.md's claim held to
    # the tree.
    skill_def="$(basename "${definitions[0]}")"
    c="$(selftest_case_dir skill-in-tools-line)"
    add_to_tools_line "$c/agents/$skill_def" "Skill"
    run_case skill-in-tools-line fail "tools: line lists 'Skill'"

    # The same closed-set violation, expressed in the YAML block-sequence
    # form the inline-only parser used to miss.
    c="$(selftest_case_dir skill-in-yaml-tools-list)"
    to_yaml_list_tools "$c/agents/$skill_def" "Skill"
    run_case skill-in-yaml-tools-list fail "tools: line lists 'Skill'"

    # The same closed-set violation, expressed in the quoted-scalar form
    # (`tools: "A, B, C"`) — one of the three legal YAML spellings #631
    # found the parser silently missing.
    c="$(selftest_case_dir skill-in-quoted-scalar-tools)"
    to_quoted_scalar_tools "$c/agents/$skill_def" "Skill"
    run_case skill-in-quoted-scalar-tools fail "tools: line lists 'Skill'"

    # The same closed-set violation, expressed in the YAML flow-sequence
    # form (`tools: [A, B, C]`).
    c="$(selftest_case_dir skill-in-flow-seq-tools)"
    to_flow_seq_tools "$c/agents/$skill_def" "Skill"
    run_case skill-in-flow-seq-tools fail "tools: line lists 'Skill'"

    # The same closed-set violation, as a YAML block-sequence list item
    # carrying a trailing ` # note` comment — proves the comment is
    # stripped before the token is compared, rather than compared with the
    # comment still attached (which would never equal 'Skill').
    c="$(selftest_case_dir skill-in-yaml-tools-list-commented)"
    to_yaml_list_tools_commented "$c/agents/$skill_def" "Skill"
    run_case skill-in-yaml-tools-list-commented fail "tools: line lists 'Skill'"

    # The doc -> test direction: rewording platform-claude.md's "no
    # definition in this suite lists either" sentence must fail too, since
    # the closed set the guard enforces is derived from it rather than
    # hardcoded.
    c="$(selftest_case_dir closed-set-sentence-reworded)"
    reword_closed_set_sentence "$c/platform-claude.md"
    run_case closed-set-sentence-reworded fail "sentence 'no definition in this suite lists either' not found"

    # An unreadable definition file must fail with a named diagnostic, not
    # a bare shell arithmetic error. `chmod 000` only proves this for a
    # non-root invoker: `-r` is true for uid 0 regardless of mode bits, so
    # root bypasses the DAC read check the fixture relies on and the
    # mutation would not fail the nested run — not because the production
    # check `[ ! -r "$def" ]` (~L232) is not load-bearing, but because this
    # fixture cannot express an unreadable file to root. Skip the case with
    # a stated reason under root rather than let it silently drop out or
    # false-fail the whole suite.
    unreadable_def="$(basename "${definitions[0]}")"
    if [ "$(id -u)" -eq 0 ]; then
      echo "SKIP: self-test unreadable-definition (running as uid 0 — chmod 000 does not block root's read, so this fixture cannot prove the check load-bearing here)"
    else
      c="$(selftest_case_dir unreadable-definition)"
      chmod 000 "$c/agents/$unreadable_def"
      run_case unreadable-definition fail "definition file is not readable"
    fi
  fi
fi

if [ "$fail" -ne 0 ]; then
  echo "test_agent_rules_drift: FAILED" >&2
  exit 1
fi

echo "test_agent_rules_drift: all assertions passed ($n_canon_blocks canonical rule block(s), $n_canon_rubrics canonical rubric block(s), ${#definitions[@]} definition(s))"
