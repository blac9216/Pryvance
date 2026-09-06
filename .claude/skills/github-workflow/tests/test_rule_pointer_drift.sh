#!/usr/bin/env bash
# test_rule_pointer_drift.sh — proves every sibling skill's SKILL.md still
# carries the one-line pointer decision A2 (spike #285) requires: the family
# rule — extraction vs. interpretation (#732), no discovery (#736) — lives
# once in `github-workflow/references/github-tools.md` § Extraction vs.
# interpretation, and every sibling SKILL.md points at it rather than
# restating it. A pointer nobody checks rots (#793).
#
# ---------------------------------------------------------------------------
# SCOPING RULE — read this before asking "why isn't my skill checked?"
# ---------------------------------------------------------------------------
# The skill list comes from `configure-workflow/manifests/family.json`'s
# `.skills[]`, not a hardcoded list, so an added/removed family member is
# picked up automatically. Two skills are always dropped because they hold
# the rule rather than pointing at it: `github-workflow` (the rule's home)
# and `github-pr-review` (the reviewer side of the same rule, #736). Of what
# remains, the rule binds only a skill that ships a `scripts/` directory —
# a script is the thing #732/#736 are about (a script reads only what it is
# given; no discovery). `gitlab-workflow`, `interrogate` and `with-secrets`
# have no `scripts/` directory today and carry no pointer; that is correct
# under this scoping rule, not a gap this suite reports. A skill's scope is
# decided solely by whether it has a non-empty `scripts/` directory at check
# time — nothing about the skill's name or purpose is special-cased.
#
# Same shape as test_agent_rules_drift.sh: file-vs-file, no mocked `gh`, a
# `report()` / fail-counter accumulator so one run surfaces every defect
# rather than aborting on the first, LANG=C pinning, and a self-test phase
# that copies the real sources into a scratch dir, applies exactly one
# defect per case, and re-invokes this script against the copy through env
# overrides (`DRIFT_*`), with `DRIFT_SELFTEST=0` on the nested run so it
# does not recurse.
#
# The pointer is matched two ways, both already load-bearing in the tree:
# the anchor GitHub derives from the section heading
# (`#extraction-vs-interpretation`, from `## Extraction vs. interpretation`),
# attached directly to a `github-tools.md` link; or the section named in
# prose immediately after such a link — `§ Extraction vs. interpretation` —
# the way `plan-work/SKILL.md` and `design-docs/SKILL.md` do today. Neither
# form is loosened to "any mention of github-tools.md anywhere in the file":
# the section citation must sit right after the link, so an unrelated
# mention elsewhere in the file does not count.
#
# UNMOCKED-CONTEXT: not applicable. This suite issues no `gh` invocation at
# all (grep the file: none), so there is no mock to bypass and no tripwire
# to wire up — the same exemption test_agent_rules_drift.sh,
# test_evidence_single_source.sh and test_session_log_slugs.sh document for
# themselves (#568).
#
# Covers:
#  - every in-scope sibling skill (family.json's list, minus github-workflow
#    and github-pr-review, filtered to those shipping a non-empty scripts/)
#    has a SKILL.md, and that SKILL.md carries a pointer to github-tools.md's
#    Extraction vs. interpretation section, in either accepted form.
#  - a skill missing its pointer line entirely fails, naming that skill.
#  - a skill whose SKILL.md is missing fails, naming that skill.
#  - the section heading no longer existing in github-tools.md (renamed or
#    removed) fails, naming the expected heading/anchor.
#  - the skill list is read from family.json, not hardcoded: a fixture
#    manifest adding a fake skill with a scripts/ directory and no SKILL.md
#    fails, naming that fake skill.
#  - github-workflow and github-pr-review are never required to carry the
#    pointer even though the former ships scripts, since they hold the rule.
#  - a skill with no scripts/ directory is never required to carry the
#    pointer (the scoping rule above), proven by a fixture that drops the
#    pointer from such a skill's SKILL.md and asserts the suite still
#    passes.
#  - an unreadable skill directory or an unreadable scripts/ directory fails
#    loudly, naming the skill and which directory could not be read, rather
#    than silently being folded into "no scripts/" (out of scope) the way a
#    bare `[ -d ... ]`/`ls -A ... 2>/dev/null` check would (#914 round 1
#    finding F1).
#
# Sources are overridable through `DRIFT_MANIFEST`, `DRIFT_GITHUB_TOOLS` and
# `DRIFT_SKILLS_ROOT` so the self-test can point a nested run at a mutated
# copy; `DRIFT_SELFTEST=0` suppresses the self-test in that nested run.
# Defaults are the real files, so a plain invocation checks the real tree
# and then proves its own checks.
set -euo pipefail
export LANG=C LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"
MANIFEST="${DRIFT_MANIFEST:-$SCRIPT_DIR/../../configure-workflow/manifests/family.json}"
GITHUB_TOOLS="${DRIFT_GITHUB_TOOLS:-$SCRIPT_DIR/../references/github-tools.md}"
SKILLS_ROOT="${DRIFT_SKILLS_ROOT:-$SCRIPT_DIR/../..}"
SELFTEST="${DRIFT_SELFTEST:-1}"

# The section this suite holds every pointer to. A constant, not derived
# from prose that could drift out from under it: this is the specific
# section decision A2 names, and the check below is exactly "does this
# still exist, under this name, in github-tools.md".
EXPECTED_HEADING="Extraction vs. interpretation"

# HELD_SKILLS — the two skills that hold the rule rather than pointing at
# it, dropped from family.json's list unconditionally.
HELD_SKILLS="github-workflow github-pr-review"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/rule-pointer-drift-test.XXXXXX")"
cleanup(){ rm -rf "$WORK"; }
trap cleanup EXIT

fail=0
report(){ echo "FAIL: $*" >&2; fail=1; }

# anchor_of <heading> — GitHub's slug of a Markdown heading: lowercase,
# drop everything but [a-z0-9 -], spaces to hyphens.
anchor_of(){
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -e 's/[^a-z0-9 -]//g' -e 's/  */ /g' -e 's/^ *//' -e 's/ *$//' -e 's/ /-/g'
}

# has_scripts_dir <skills-root> <skill> — true when <skill>/scripts exists
# and is non-empty. Used only where a plain boolean is enough (building
# self-test fixtures). The real scoping loop below uses scripts_dir_status
# instead: this boolean folds "definitely no scripts/" together with
# "cannot tell" (permission denied), which is exactly the F1 bug (PR #914
# round 1) — an unreadable directory silently drops a skill from scope
# instead of failing loudly.
has_scripts_dir(){
  local root="$1" skill="$2" d
  d="$root/$skill/scripts"
  [ -d "$d" ] && [ -n "$(ls -A "$d" 2>/dev/null)" ]
}

# scripts_dir_status <skills-root> <skill> — echoes exactly one of:
#   present                — <skill>/scripts exists, is readable and searchable,
#                            and has at least one entry
#   absent                 — <skill>, or <skill>/scripts, does not exist, is not
#                            a directory, or exists but is empty
#   unreadable-skill-dir   — <skill> itself cannot be searched (no x bit), so
#                            whether it ships a scripts/ cannot be determined
#   unreadable-scripts-dir — <skill>/scripts exists but cannot be read and/or
#                            searched, so whether it is empty cannot be
#                            determined
# `[ -d "$d" ]` is false both when a directory genuinely does not exist and
# when it cannot be stat'd because an ancestor lacks search permission, and
# `ls -A "$d" 2>/dev/null` silently swallows a permission-denied listing the
# same way — both collapse into "no scripts/" under has_scripts_dir's plain
# boolean above. This function checks each directory's own permission bits
# before asking whether it has entries, so a genuinely-unreadable directory
# comes back as one of the two indeterminate statuses instead.
scripts_dir_status(){
  local root="$1" skill="$2" skill_dir scripts_dir
  skill_dir="$root/$skill"
  scripts_dir="$skill_dir/scripts"

  [ -e "$skill_dir" ] || { printf 'absent\n'; return; }
  [ -x "$skill_dir" ] || { printf 'unreadable-skill-dir\n'; return; }
  [ -e "$scripts_dir" ] || { printf 'absent\n'; return; }
  [ -d "$scripts_dir" ] || { printf 'absent\n'; return; }
  if [ ! -r "$scripts_dir" ] || [ ! -x "$scripts_dir" ]; then
    printf 'unreadable-scripts-dir\n'
    return
  fi
  if [ -n "$(ls -A "$scripts_dir" 2>/dev/null)" ]; then
    printf 'present\n'
  else
    printf 'absent\n'
  fi
}

# has_pointer <skill-md-file> <anchor> <heading> — true when the file
# carries a pointer to github-tools.md's named section, in either accepted
# form: the anchor fragment glued directly to the link
# (`github-tools.md#<anchor>`), or the section named in prose immediately
# after a `github-tools.md` link (`§ <heading>`, matching plan-work's and
# design-docs' SKILL.md today). Whitespace-flattened first so a wrap across
# lines (the shape every pointer in the tree uses today) is still found;
# only the text right after the link counts, so an unrelated mention of
# github-tools.md elsewhere in the file does not.
has_pointer(){
  local file="$1" anchor="$2" heading="$3" joined after snippet
  joined="$(tr '\n' ' ' < "$file" | tr -s ' ')"
  case "$joined" in
    *"github-tools.md"*) ;;
    *) return 1 ;;
  esac
  after="${joined#*github-tools.md}"
  snippet="${after:0:200}"
  case "$snippet" in
    "#$anchor"*) return 0 ;;
    *"§ $heading"*) return 0 ;;
    *) return 1 ;;
  esac
}

[ -f "$MANIFEST" ] || { report "family manifest not found: $MANIFEST"; echo "test_rule_pointer_drift: FAILED" >&2; exit 1; }
[ -r "$MANIFEST" ] || { report "family manifest is not readable: $MANIFEST"; echo "test_rule_pointer_drift: FAILED" >&2; exit 1; }
[ -f "$GITHUB_TOOLS" ] || { report "canonical file not found: $GITHUB_TOOLS"; echo "test_rule_pointer_drift: FAILED" >&2; exit 1; }
[ -r "$GITHUB_TOOLS" ] || { report "canonical file is not readable: $GITHUB_TOOLS"; echo "test_rule_pointer_drift: FAILED" >&2; exit 1; }
[ -d "$SKILLS_ROOT" ] || { report "skills root not found: $SKILLS_ROOT"; echo "test_rule_pointer_drift: FAILED" >&2; exit 1; }

GITHUB_TOOLS_NAME="$(basename "$GITHUB_TOOLS")"

if ! grep -qF "## $EXPECTED_HEADING" "$GITHUB_TOOLS"; then
  report "$GITHUB_TOOLS_NAME: section '## $EXPECTED_HEADING' not found — the anchor '$(anchor_of "$EXPECTED_HEADING")' cannot be derived, so no sibling's pointer can be verified against it"
  echo "test_rule_pointer_drift: FAILED" >&2
  exit 1
fi
ANCHOR="$(anchor_of "$EXPECTED_HEADING")"

skills=()
while IFS= read -r s; do skills+=("$s"); done < <(jq -r '.skills[]' "$MANIFEST")
[ "${#skills[@]}" -gt 0 ] || report "$(basename "$MANIFEST"): .skills[] is empty — cannot derive the sibling list"

in_scope=()
for s in "${skills[@]}"; do
  case " $HELD_SKILLS " in
    *" $s "*) continue ;;
  esac
  status="$(scripts_dir_status "$SKILLS_ROOT" "$s")"
  case "$status" in
    present) in_scope+=("$s") ;;
    absent) ;;
    unreadable-skill-dir)
      report "$s: skill directory is not readable — cannot tell whether it ships a scripts/ directory, so scope cannot be decided"
      ;;
    unreadable-scripts-dir)
      report "$s: scripts/ directory is not readable — cannot tell whether it is empty, so scope cannot be decided"
      ;;
  esac
done

for s in "${in_scope[@]}"; do
  skill_md="$SKILLS_ROOT/$s/SKILL.md"
  if [ ! -f "$skill_md" ]; then
    report "$s: ships scripts/ but has no SKILL.md — cannot carry the required pointer to $GITHUB_TOOLS_NAME § $EXPECTED_HEADING"
    continue
  fi
  if [ ! -r "$skill_md" ]; then
    report "$s: SKILL.md is not readable"
    continue
  fi
  if ! has_pointer "$skill_md" "$ANCHOR" "$EXPECTED_HEADING"; then
    report "$s: SKILL.md carries no pointer to $GITHUB_TOOLS_NAME § $EXPECTED_HEADING (anchor '$ANCHOR') — decision A2 requires every script-bearing sibling to point at the family rule rather than restate it"
    continue
  fi
  echo "PASS: $s (pointer to $GITHUB_TOOLS_NAME § $EXPECTED_HEADING present)"
done

if [ "$fail" -ne 0 ]; then
  echo "test_rule_pointer_drift: FAILED" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Self-test: each check above, proven load-bearing.
#
# Every case copies the real manifest, the real github-tools.md, and the
# real SKILL.md of each in-scope skill into a scratch tree shaped like
# SKILLS_ROOT, applies exactly one defect, and re-invokes this script
# against the copy with DRIFT_SELFTEST=0 (so the nested run does not
# recurse). A case that expects failure also names the diagnostic it
# expects, so a mutation that fails the run for some unrelated reason does
# not count as proof.
# ---------------------------------------------------------------------------

# selftest_case_dir <case-name> — an unmutated scratch copy: the manifest,
# github-tools.md, and one directory per skill in family.json's list, each
# carrying a scripts/ marker (or not) matching the real tree's scoping, and
# a copy of the real SKILL.md where one exists.
selftest_case_dir(){
  local case_name="$1"
  local c="$WORK/selftest/$case_name" s
  mkdir -p "$c/skills"
  cp "$MANIFEST" "$c/family.json"
  cp "$GITHUB_TOOLS" "$c/github-tools.md"
  for s in "${skills[@]}"; do
    mkdir -p "$c/skills/$s"
    if has_scripts_dir "$SKILLS_ROOT" "$s"; then
      mkdir -p "$c/skills/$s/scripts"
      touch "$c/skills/$s/scripts/.keep"
    fi
    if [ -f "$SKILLS_ROOT/$s/SKILL.md" ]; then
      cp "$SKILLS_ROOT/$s/SKILL.md" "$c/skills/$s/SKILL.md"
    fi
  done
  echo "$c"
}

# run_case <case-name> <pass|fail> [expected-diagnostic-substring]
run_case(){
  local case_name="$1" expect="$2" want="${3:-}"
  local c="$WORK/selftest/$case_name" rc=0
  DRIFT_SELFTEST=0 \
  DRIFT_MANIFEST="$c/family.json" \
  DRIFT_GITHUB_TOOLS="$c/github-tools.md" \
  DRIFT_SKILLS_ROOT="$c/skills" \
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

# drop_pointer_line <file> — removes every line of the SKILL.md pointer
# paragraph: the markdown-link line naming github-tools.md and, since the
# section citation wraps onto the following line in every pointer this tree
# carries today, the two lines that follow it — three lines in all.
drop_pointer_line(){
  local file="$1" tmp="$1.tmp"
  awk '
    /github-tools\.md/ { skip = 2; next }
    skip > 0 { skip--; next }
    { print }
  ' "$file" > "$tmp"
  mv "$tmp" "$file"
}

if [ "$SELFTEST" = "1" ]; then
  [ "${#in_scope[@]}" -gt 0 ] || report "self-test: no in-scope skill found — cannot prove the pointer checks load-bearing"

  c="$(selftest_case_dir clean)"
  run_case clean pass

  if [ "${#in_scope[@]}" -gt 0 ]; then
    target="${in_scope[0]}"

    c="$(selftest_case_dir pointer-removed)"
    drop_pointer_line "$c/skills/$target/SKILL.md"
    run_case pointer-removed fail "$target: SKILL.md carries no pointer"

    c="$(selftest_case_dir skill-md-missing)"
    rm -f "$c/skills/$target/SKILL.md"
    run_case skill-md-missing fail "$target: ships scripts/ but has no SKILL.md"

    # F1 (PR #914 round 1): an unreadable directory must fail loudly through
    # report(), not silently fold into "no scripts/" (out of scope). `chmod
    # 000` only proves this for a non-root invoker: `-x`/`-r` are true for
    # uid 0 regardless of mode bits, so root bypasses the DAC check these
    # fixtures rely on and neither mutation would fail the nested run — not
    # because scripts_dir_status is not load-bearing, but because this
    # fixture cannot express an unreadable directory to root. Skip both
    # cases with a stated reason under root rather than let them silently
    # drop out or false-fail the whole suite. Both directories are chmod'd
    # back to 755 before the case returns (even on the report()/return-early
    # paths inside run_case) so the scratch tree under $WORK can still be
    # removed by this script's own EXIT trap.
    if [ "$(id -u)" -eq 0 ]; then
      echo "SKIP: self-test unreadable-skill-dir (running as uid 0 — chmod 000 does not block root's search permission, so this fixture cannot prove scripts_dir_status load-bearing here)"
      echo "SKIP: self-test unreadable-scripts-dir (running as uid 0 — chmod 000 does not block root's search permission, so this fixture cannot prove scripts_dir_status load-bearing here)"
    else
      c="$(selftest_case_dir unreadable-skill-dir)"
      chmod 000 "$c/skills/$target"
      run_case unreadable-skill-dir fail "$target: skill directory is not readable"
      chmod 755 "$c/skills/$target"

      c="$(selftest_case_dir unreadable-scripts-dir)"
      chmod 000 "$c/skills/$target/scripts"
      run_case unreadable-scripts-dir fail "$target: scripts/ directory is not readable"
      chmod 755 "$c/skills/$target/scripts"
    fi
  fi

  c="$(selftest_case_dir heading-renamed)"
  sed -i.bak "s/^## $EXPECTED_HEADING\$/## Extraction versus interpretation/" "$c/github-tools.md"
  rm -f "$c/github-tools.md.bak"
  run_case heading-renamed fail "section '## $EXPECTED_HEADING' not found"

  c="$(selftest_case_dir fake-skill-in-manifest)"
  jq '.skills += ["fake-skill-793"]' "$c/family.json" > "$c/family.json.tmp"
  mv "$c/family.json.tmp" "$c/family.json"
  mkdir -p "$c/skills/fake-skill-793/scripts"
  touch "$c/skills/fake-skill-793/scripts/.keep"
  run_case fake-skill-in-manifest fail "fake-skill-793: ships scripts/ but has no SKILL.md"

  # The scoping rule itself: a skill with no scripts/ directory never needs
  # the pointer. Pick one from the real tree (gitlab-workflow, interrogate,
  # with-secrets are the current examples) and prove that dropping its
  # (nonexistent) pointer, or giving it no SKILL.md at all, still passes.
  no_scripts_skill=""
  for s in "${skills[@]}"; do
    case " $HELD_SKILLS " in
      *" $s "*) continue ;;
    esac
    has_scripts_dir "$SKILLS_ROOT" "$s" && continue
    no_scripts_skill="$s"
    break
  done
  if [ -z "$no_scripts_skill" ]; then
    report "self-test: no scripts-free sibling skill found — cannot prove the scoping rule load-bearing"
  else
    c="$(selftest_case_dir scoping-rule-out-of-scope-skill-unchecked)"
    rm -f "$c/skills/$no_scripts_skill/SKILL.md"
    run_case scoping-rule-out-of-scope-skill-unchecked pass
  fi

  # HELD_SKILLS: github-workflow ships scripts/ (it holds the rule) but must
  # never be required to carry the pointer to itself.
  c="$(selftest_case_dir held-skill-not-required)"
  rm -f "$c/skills/github-workflow/SKILL.md" 2>/dev/null || true
  run_case held-skill-not-required pass
fi

if [ "$fail" -ne 0 ]; then
  echo "test_rule_pointer_drift: FAILED" >&2
  exit 1
fi

echo "test_rule_pointer_drift: all assertions passed (${#in_scope[@]} in-scope sibling skill(s) checked, anchor '$ANCHOR')"
