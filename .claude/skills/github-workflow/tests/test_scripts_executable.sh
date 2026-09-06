#!/usr/bin/env bash
# test_scripts_executable.sh — guards the executable bit on every script this
# skill invokes directly, after issue #661: PR #626 flipped
# `scripts/check-manifest.sh` from 100755 to 100644, and nothing in the
# review apparatus could see it — Suggested Test Steps and this directory's
# own suites invoke scripts as `bash <script>`, which never needs the bit;
# `shellcheck` doesn't need it either; the reviewer-applied gate's
# strip-and-compare is a content diff, byte-identical across a mode change;
# and reviewers were reading `git diff --numstat`, which omits the mode line
# entirely (`git diff --stat` prints it, but no checklist item asks anyone to
# read it). Four review rounds, three reviewers, six calibrator helpers and a
# merge-verifier all passed the flip. This suite is the guard that would have
# failed the PR.
#
# Scope: `scripts/*.sh` (the AC's own wording) and `tests/test_*.sh`, for
# this skill. #661 framed the defect as a class, not an incident specific to
# this skill, but PR #663 correctly scoped its own fix to this directory
# alone. The tests directory is not exempt from the same class —
# `tests/README.md` states "each test file is ... executable on its own" as
# the documented contract, and that contract had already silently
# regressed: at the time this guard was added, `tests/test_board_audit.sh`
# was 100644 in every commit that ever touched it, never 100755, despite the
# same README describing it as executable. This suite's first real run
# caught that file for exactly the reason it exists to catch, and the fix
# restored its bit in the same PR.
#
# This is a pure filesystem check: no `gh` call, no network, no mock to
# route through. Follows this directory's conventions anyway — a
# `report()` / fail-counter accumulator so one run surfaces every offending
# file rather than aborting on the first, and LANG=C pinning for the sort
# order used when listing files.
#
# UNMOCKED-CONTEXT: not applicable. This suite issues no `gh` invocation at
# all, so there is no mock to bypass and no tripwire to wire up — the same
# exemption `test_agent_rules_drift.sh`, `test_evidence_single_source.sh`
# and `test_session_log_slugs.sh` document for themselves (#568).
#
# #665: this suite's own self-test hardcoded `check-manifest.sh` /
# `test_preflight.sh` as its mutation targets. A rename of either would
# abort the whole self-test under `set -e` outside `report()`, silently
# skipping every probe scheduled after it — exactly the failure class this
# suite exists to catch, one level out. Each target's existence is now
# asserted through `report()` immediately before it is mutated, and a
# dedicated rename probe proves the fix both ways: with the assertion, a
# copy missing the target yields a named `FAIL:` line and every remaining
# self-test probe still runs; without it, the same copy aborts mid-block on
# a bare `chmod` with no `FAIL:` line at all. The targets are named, not
# derived — a derived "first match" target would just move the hardcoding
# one level down and be exactly as blind to a rename that happens to sort
# first.
#
# #666/#684/#741: this guard's reach was `github-workflow` only, per decision
# E1 of the #285 interrogation record — one guard, deriving the sibling-skill
# list from the tree (`.claude/skills/*/{scripts,tests}`), not per-skill
# copies. #666 was dropped from PR #675 by owner decision on 2026-09-05 after
# two review rounds found every one of its defects in the sibling-skills
# half; this attempt starts from that comment rather than rediscovering it:
#   - Every nested self-test invocation this file spawns for the sibling arm
#     is SE_SELFTEST=0 (a single non-recursive check), never SE_SELFTEST=1,
#     so none of the new probes below can recurse — the runaway-recursion
#     class #675 hit does not apply to them by construction.
#   - A sibling `scripts/` or `tests/` directory that does not exist is a
#     skip (`optional=1` below); one that exists, is readable, and simply
#     holds no matching files is likewise a skip, not a failure (#859) — a
#     sibling skill with a placeholder directory should not fail the whole
#     suite. But one that exists and is unreadable (or unsearchable) is
#     always a hard `report()` failure, never folded into "no files
#     matched" — #675's round-1 fix conflated the two by adding
#     `empty_ok=1` to both sibling arms, which silently passed a `chmod 000`
#     scripts/ directory hiding a non-executable script. `check_dir`'s
#     `optional` flag only ever widens the missing-directory and
#     empty-directory branches; the unreadable branch is unconditional
#     regardless of `optional`.
#   - #859 round 2: the same missing-vs-unreadable conflation existed one
#     level up, at the *skill* directory itself. A `chmod 000` skill
#     directory makes `$skill/scripts` unstatable, which `check_dir`'s own
#     `[ ! -d ]` branch cannot tell apart from "does not exist", so it
#     silently took the optional skip too. The walk below now checks each
#     skill entry's own readability before calling `check_dir` at all, and
#     reports it as a named failure rather than folding it into the skip.
#   - #859 round 2, second gap: the walk itself had no floor. A
#     `SE_SKILLS_ROOT` that does not exist, or exists but is unreadable, or
#     exists and is readable but holds no skill directories at all, each
#     silently produced "all assertions passed" — the entire #666 reach
#     covering nothing while the suite stayed green. The walk now asserts
#     the root exists, is readable, and that at least one sibling skill was
#     scanned, each through `report()`.
#   - #684: sibling skills are installed elsewhere as symlinks
#     (`~/.claude/skills`), and enumerating with `find -type d` alone never
#     matches a symlinked directory. The skill-root walk below matches
#     `-type d -o -type l` and then confirms with `[ -d "$entry" ]` (which
#     follows the link) before treating an entry as a skill directory, so a
#     symlinked skill is scanned exactly like a real one. #684 also asks for
#     an explicit decision on whether a symlink *loop* among skill
#     directories needs a bound: **no bound is needed**, and this comment is
#     that record. The skills-root walk is `-maxdepth 1`, so `find` never
#     descends through a link; a self-referential or circular link matches
#     `-type l`, the `[ -d ]` re-check then fails with ELOOP, and the entry
#     is skipped exactly like a dangling link — no hang (verified by fixture
#     under a 30s timeout). `check_dir`'s `find -L` is likewise `-maxdepth 1`
#     one level below an entry already confirmed to be a directory, so it
#     cannot cycle either.
#   - Round-1 note 3, one level in from #684's own case: a *real* skill whose
#     `scripts/` is itself a symlink was silently unscanned, because `find`
#     does not follow a symlink given as its own starting point. `check_dir`
#     enumerates with `find -L` for that reason, with its own mutant and
#     positive control.
#   - #741: SE_SELFTEST_NONCE was an *existence* check, not a proof — any
#     pre-existing file (`SE_SELFTEST_NONCE=/etc/hostname`) passed as a
#     "live parent" nonce, because the check never verified the file's
#     *content* against anything a live parent alone could have produced.
#     Pairing the file with a per-run random value was still not enough:
#     both halves are caller-supplied, so `SE_SELFTEST_NONCE=/etc/hostname
#     SE_SELFTEST_NONCE_VALUE="$(cat /etc/hostname)"` satisfied that mere
#     consistency test and dropped the depth-0-only probes anyway (round-1
#     finding 2). The nonce value now carries the parent's own pid
#     (`selftest-nonce v1 pid=<pid> rand=<r>-<r>`), and depth 1 is accepted
#     only when the file exists, the value is non-empty, the file's content
#     equals the value, *and* that pid is both alive (`/proc/<pid>`) and is
#     this run's own immediate parent (`$PPID`, exactly — #860).
#   - #860: round 2 shipped that last clause as a bounded *ancestry* walk
#     (any pid within 64 `PPid:` hops), and its own header comment claimed
#     "it cannot forge its own ancestry" — false as written, corrected by a
#     reviewer-applied commit. `pid 1` is an ancestor of *every* process on
#     the host, so `SE_SELFTEST_NONCE_VALUE="selftest-nonce v1 pid=1
#     rand=9-9"` with a matching file satisfied the ancestry walk with zero
#     knowledge of the actual run, silently dropping 18 of 22 depth-0
#     probes. #860 judged the general shape likely unclosable in
#     principle — the process supplying the environment is by construction
#     an ancestor of the child it spawns, so no check the child runs on
#     parent-supplied data can ever tell a genuine parent from a forging one
#     that happens to be an ancestor. This file takes the narrower of
#     #860's two offered options: the check now requires the claimed pid to
#     equal `$PPID` exactly — this run's literal, immediate parent — not
#     merely an ancestor at any distance. That removes the zero-knowledge
#     shortcut (`pid=1` is not the `$PPID` of the depth-1
#     nested invocation this file actually performs) without needing any
#     ancestry walk at all. It does **not** close every forgery: a caller
#     that reads its own `$$` and reports that exact value still passes,
#     because that value genuinely *is* this run's immediate parent. That is
#     the recorded limit, not an implied one: this check defends against a
#     stale, ambient, or guessed `SE_SELFTEST_DEPTH=1` (a leftover nonce, or
#     a universal constant like `pid=1`), not against a caller with real
#     knowledge of its own process tree. The arms below cover empty path,
#     absent value, content mismatch, dead pid, a live pid that is not
#     `$PPID`, and the `pid=1` shortcut specifically, each reaching exactly
#     one clause — a clause no fixture reaches is not known to catch
#     anything (round-1 finding 1).
#   - #852: the liveness half of the check above (`/proc/<pid>`) still needs
#     a Linux-shaped `/proc`; there is no fallback. On a host without one
#     the depth-1 nonce is refused, which fails the suite **closed** rather
#     than open (no forged depth is ever accepted) but does mean the whole
#     suite goes red there instead of degrading. #852 weighed a
#     `ps -o ppid=` fallback and rejected it: it would need its own fixture
#     to be load-bearing per `tests/README.md`, and the only cheap way to
#     reach that fixture is a seam that redirects the liveness check to a
#     fake `/proc` — itself a forgery vector, since a caller who can
#     redirect the check can fake liveness the same way #860 found a caller
#     could fake ancestry. This suite is recorded as Linux-only instead (see
#     `tests/README.md`); every agent host in this repository is Linux
#     today, so nothing is broken by that requirement in practice.
set -euo pipefail
export LANG=C LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="${SE_SCRIPTS_DIR:-$SCRIPT_DIR/../scripts}"
TESTS_DIR="${SE_TESTS_DIR:-$SCRIPT_DIR}"
# Root of the skills tree, for the #666 sibling-skill walk. Two directories
# up from tests/ is the skill's own root (github-workflow/), and one more up
# is .claude/skills/ itself.
SKILLS_ROOT="${SE_SKILLS_ROOT:-$SCRIPT_DIR/../..}"
CURRENT_SKILL="$(basename "$(cd "$SCRIPT_DIR/.." && pwd)")"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/scripts-executable.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

fail=0
report(){ echo "FAIL: $*" >&2; fail=1; }

# Every self-test probe announces itself through pass(), which also counts it.
# The count is asserted at the end of the self-test block against the number of
# probes that level is supposed to run, so a probe that silently stops running
# is a FAIL rather than a shorter, still-green run.
probes_run=0
pass(){ echo "PASS: $*"; probes_run=$((probes_run + 1)); }

# #860: is pid $1 this run's own immediate parent? Round 1/2 implemented
# provenance as a bounded ancestry walk (any pid within 64 `PPid:` hops
# through /proc), which let a caller satisfy it with zero knowledge of the
# actual run by naming `pid=1` — an ancestor of every process on the host.
# This check is narrowed to an exact match against $PPID: the legitimate
# case is always exactly one level of nesting (the outer self-test invokes
# the nested run directly, so the outer script's own pid *is* the nested
# run's $PPID), so no walk is needed, and `pid=1` (or any pid that is not
# literally the parent) is refused outright. It does not close every
# forgery — a caller that reads its own $$ and reports that value still
# passes, since that value genuinely is this run's immediate parent — which
# is the recorded limit, not an implied one (see the file header, #860).
pid_is_immediate_parent(){
  [ "$1" = "$PPID" ]
}

check_dir(){
  # optional=1 (fourth arg) widens two branches: a *missing* directory is a
  # silent skip (not every sibling skill has a scripts/ or tests/
  # subdirectory), and so is one that exists, is readable, and simply holds
  # no files matching $pattern (#859 — a sibling skill with a placeholder
  # directory should not fail the whole suite). It never touches the
  # unreadable-directory branch: an existing-but-unreadable directory is
  # always a report(), optional or not, so a `chmod 000` scripts/ dir can
  # never be folded into "no files matched" the way #675's `empty_ok=1`
  # regression folded it (#666).
  local dir="$1" pattern="$2" label="$3" optional="${4:-0}" found=0
  if [ ! -d "$dir" ]; then
    [ "$optional" = "1" ] && return
    report "$label: directory not found: $dir"
    return
  fi
  if [ ! -r "$dir" ] || [ ! -x "$dir" ]; then
    report "$label: directory exists but is not readable: $dir"
    return
  fi
  while IFS= read -r -d '' f; do
    found=$((found + 1))
    if [ ! -x "$f" ]; then
      report "$label: not executable: $f"
    fi
  # `find -L` (round-1 note 3): a symlinked `scripts/` or `tests/` *inside* a
  # skill passes the `[ -d "$dir" ]` gate above (test follows the link) but a
  # plain `find "$dir"` does not follow a symlink given as its own starting
  # point, so every file under it was invisible and the arm degraded to "no
  # files matched" instead of naming the offending file. -L follows it, and
  # also makes a symlinked *file* inside a real directory match -type f (its
  # target's bit is what `[ -x ]` then tests, which is the mode that matters).
  # A -maxdepth 1 walk cannot loop, so -L needs no cycle bound here.
  done < <(find -L "$dir" -maxdepth 1 -type f -name "$pattern" -print0 | sort -z)
  if [ "$found" -eq 0 ]; then
    # #859: an existing, readable, but empty optional directory is a skip,
    # same as a missing one — not every sibling skill's placeholder
    # directory holds a script yet, and failing the whole suite over that
    # would contradict the optional semantics the sibling arm was given.
    # Non-optional callers (SCRIPTS_DIR/TESTS_DIR above) are unaffected:
    # optional is 0 there, so an empty directory is still a hard failure.
    [ "$optional" = "1" ] && return
    report "$label: no files matched $pattern under $dir — pattern or path is wrong"
  fi
}

check_dir "$SCRIPTS_DIR" '*.sh' "scripts/*.sh"
check_dir "$TESTS_DIR" 'test_*.sh' "tests/test_*.sh"

# #666/#684: walk every sibling directory directly under the skills root
# (excluding this skill itself, already covered by SCRIPTS_DIR/TESTS_DIR
# above) and guard its scripts/*.sh and tests/test_*.sh the same way,
# treating a missing or empty subdirectory as a skip (most skills carry no
# tests/) but an unreadable one as a failure. `-type d -o -type l` plus the
# `[ -d ]` re-check after matches a symlinked skill directory (#684) exactly
# like a real one — a plain `find -type d` walk never matches a symlink even
# when it resolves to a directory.
#
# #859: the walk itself has a floor. A skills root that does not exist, or
# exists but is unreadable, or exists and is readable but holds no skill
# directories at all, must each be a named report() — not silently "0
# skills scanned, all assertions passed", which is the same silent-green
# class this whole guard exists to catch, one level out from where its own
# fixtures probe.
if [ ! -d "$SKILLS_ROOT" ]; then
  report "sibling-skill walk: skills root not found: $SKILLS_ROOT"
elif [ ! -r "$SKILLS_ROOT" ] || [ ! -x "$SKILLS_ROOT" ]; then
  report "sibling-skill walk: skills root exists but is not readable: $SKILLS_ROOT"
else
  skills_scanned=0
  while IFS= read -r -d '' entry; do
    [ -d "$entry" ] || continue
    name="$(basename "$entry")"
    [ "$name" = "$CURRENT_SKILL" ] && continue
    # #859: a skill directory that is itself unreadable makes
    # "$entry/scripts" unstatable, which check_dir's `[ ! -d ]` branch
    # cannot tell apart from "does not exist" — folding it into the
    # optional skip the same way #675's empty_ok=1 folded an unreadable
    # scripts/ into "no files matched". Checked here, before check_dir ever
    # runs, so it is always a named failure instead.
    if [ ! -r "$entry" ] || [ ! -x "$entry" ]; then
      report "$name: skill directory exists but is not readable: $entry"
      continue
    fi
    skills_scanned=$((skills_scanned + 1))
    check_dir "$entry/scripts" '*.sh' "$name: scripts/*.sh" 1
    check_dir "$entry/tests" 'test_*.sh' "$name: tests/test_*.sh" 1
  done < <(find "$SKILLS_ROOT" -mindepth 1 -maxdepth 1 \( -type d -o -type l \) -print0 | sort -z)
  [ "$skills_scanned" -gt 0 ] || report "sibling-skill walk: no sibling skill directory scanned under $SKILLS_ROOT (root exists and is readable, but the #666 reach covers nothing)"
fi

# ===========================================================================
# Self-test / mutation probe: flip the bit on a throwaway copy and show the
# guard goes red, per tests/README.md's "Proving an assertion is
# load-bearing" — a check with no failing fixture is not known to catch
# anything. Every branch this suite carries has its own mutant and its own
# positive control; the two differ in exactly the one thing the branch is
# about, so each is proven to invert.
# ===========================================================================
if [ "${SE_SELFTEST:-1}" = "1" ]; then
  # SELFTEST_DEPTH guards the #665 rename probes (and the depth control)
  # below against infinite recursion: those probes point a nested
  # invocation's SCRIPTS_DIR/TESTS_DIR at a fixture that is *itself* missing
  # the mutation target, so a naive "recurse with SE_SELFTEST=1" would hit
  # the very same missing-target case one level down and recurse forever.
  # Depth 0 (the real, top-level run) is the only level that runs those
  # probes; a nested call raises the depth to 1, which still runs every
  # other self-test probe (so "did the remaining probes still run" is a real
  # question with a real answer) but never re-enters a probe that would
  # spawn another depth-1 run. Recursion is therefore bounded at two levels
  # by construction: depth 1 spawns only SE_SELFTEST=0 leaves, which run no
  # probes at all.
  #
  # The depth is not trusted as read. It must be exactly 0 or 1, and a depth
  # of 1 must be accompanied by a nonce whose value names a pid that is both
  # alive and this run's own immediate parent — otherwise an ambient, stale
  # `SE_SELFTEST_DEPTH=1`
  # in the caller's environment would silently drop the depth-0-only probes
  # while the run still printed "all assertions passed" and exited 0. Both
  # rejections fail loudly through report(); neither can ever fail *toward*
  # deeper recursion.
  #
  # #741: naming a file is not proof the file's *content* came from a live
  # parent — `[ -f "$SE_SELFTEST_NONCE" ]` alone is satisfied by any
  # pre-existing file (the comment's own repro: `SE_SELFTEST_NONCE=
  # /etc/hostname` passed) — and matching the file's content against a value
  # the same caller supplied is not proof either, since a forger holds both
  # (round-1 finding 2). #860: naming *an ancestor* is not proof either —
  # `pid 1` is an ancestor of everything, so the value must name this run's
  # exact, immediate parent ($PPID) — which a caller that invokes this
  # script directly can still supply as its own $$ (the limit #860 records).
  SELFTEST_DEPTH="${SE_SELFTEST_DEPTH:-0}"
  depth_ok=1
  case "$SELFTEST_DEPTH" in
    0) ;;
    1)
      # Four things must hold, in this order, and each has its own probe
      # below so no clause can short-circuit another into being unproven
      # (round-1 finding 1): the named file exists; a non-empty value was
      # handed down; the file's content equals that value; and the value
      # carries a pid that is *alive and this run's own immediate parent*
      # (round-1 finding 2, narrowed further by #860). The last is the only
      # clause that makes this provenance rather than a consistency test
      # between two caller-supplied strings — without it,
      # `SE_SELFTEST_NONCE=/etc/hostname
      # SE_SELFTEST_NONCE_VALUE="$(cat /etc/hostname)"` satisfies everything
      # and silently drops the depth-0-only probes. #860: an *ancestor* check
      # here is not enough either — `pid=1` (or the caller's own `$$`) is an
      # ancestor of everything, so the comparison must be against $PPID
      # exactly, not any pid reachable by walking up.
      nonce_problem=""
      nonce_pid=""
      if [ ! -f "${SE_SELFTEST_NONCE:-}" ]; then
        nonce_problem="no file at the named path"
      elif [ -z "${SE_SELFTEST_NONCE_VALUE:-}" ]; then
        nonce_problem="SE_SELFTEST_NONCE_VALUE is empty"
      elif [ "$(cat "${SE_SELFTEST_NONCE}" 2>/dev/null)" != "$SE_SELFTEST_NONCE_VALUE" ]; then
        nonce_problem="the file's content does not match SE_SELFTEST_NONCE_VALUE"
      else
        case "$SE_SELFTEST_NONCE_VALUE" in
          "selftest-nonce v1 pid="*)
            nonce_pid="${SE_SELFTEST_NONCE_VALUE#selftest-nonce v1 pid=}"
            nonce_pid="${nonce_pid%% *}"
            ;;
        esac
        case "$nonce_pid" in
          ''|*[!0-9]*)
            nonce_problem="the nonce carries no parent pid in the expected form"
            ;;
          *)
            # #852: liveness needs a Linux-shaped /proc; no fallback (see
            # header). Fail-closed: absence refuses the depth-1 nonce rather
            # than degrading.
            if [ ! -d /proc/self ]; then
              nonce_problem="/proc is not available, so the parent pid cannot be verified alive"
            elif [ ! -d "/proc/$nonce_pid" ]; then
              nonce_problem="parent pid $nonce_pid is not alive"
            elif ! pid_is_immediate_parent "$nonce_pid"; then
              nonce_problem="parent pid $nonce_pid is alive but is not this run's immediate parent (#860)"
            fi
            ;;
        esac
      fi
      if [ -n "$nonce_problem" ]; then
        report "self-test: SE_SELFTEST_DEPTH=1 without SE_SELFTEST_NONCE proving a live immediate-parent run — $nonce_problem — refusing to run the probes at an unverified depth (a stale depth, or a file merely named as the nonce, would silently drop the depth-0-only probes)"
        depth_ok=0
      fi
      ;;
    *)
      report "self-test: SE_SELFTEST_DEPTH must be 0 or 1, got '$SELFTEST_DEPTH' — refusing to run the probes at an unvalidated depth"
      depth_ok=0
      ;;
  esac
fi

if [ "${SE_SELFTEST:-1}" = "1" ] && [ "${depth_ok:-0}" = "1" ]; then
  # Nonce handed to the nested depth-1 runs below, so they can tell a real
  # parent from a stale environment variable (or, per #741, from a
  # pre-existing file merely named as the nonce). It lives under $WORK and
  # dies with the EXIT trap. The value is generated fresh every run — $$
  # (this process's pid) and two draws from $RANDOM give a value no
  # ambient environment variable or pre-existing file can be expected to
  # already hold.
  nonce_file="$WORK/selftest-nonce"
  nonce_value="selftest-nonce v1 pid=$$ rand=$RANDOM-$RANDOM"
  printf '%s' "$nonce_value" >"$nonce_file"

  # #665: the mutation target below is named, not derived, on purpose (a
  # derived "first match" target would just move the hardcoding one level
  # down and be just as blind to a rename that happens to sort first). What
  # #665 actually requires is that a rename of *this specific* target stop
  # aborting the suite under `set -e` outside `report()` — so the target's
  # existence is asserted through `report()` before it is ever mutated, and
  # the probe below (renamed_scripts / renamed_tests) proves that exact
  # scenario: a copy missing this file must fail loudly through report()
  # and let every remaining self-test probe still run, not die on a bare
  # `chmod`.
  scripts_mutation_target="check-manifest.sh"
  tests_mutation_target="test_preflight.sh"

  mutant_scripts="$WORK/scripts"
  mkdir -p "$mutant_scripts"
  cp "$SCRIPTS_DIR"/*.sh "$mutant_scripts"/
  chmod +x "$mutant_scripts"/*.sh
  if [ ! -e "$mutant_scripts/$scripts_mutation_target" ]; then
    report "self-test: mutation target $scripts_mutation_target not found under $SCRIPTS_DIR — cannot probe the scripts/*.sh arm (#665)"
  else
    # Flip exactly one bit — the same defect PR #626 introduced.
    chmod -x "$mutant_scripts/$scripts_mutation_target"

    rc=0
    SE_SELFTEST=0 SE_SCRIPTS_DIR="$mutant_scripts" SE_TESTS_DIR="$TESTS_DIR" \
      bash "${BASH_SOURCE[0]}" >"$WORK/mutant.out" 2>&1 || rc=$?
    if [ "$rc" -ne 0 ] && grep -qF "not executable: $mutant_scripts/$scripts_mutation_target" "$WORK/mutant.out"; then
      pass "self-test (a flipped bit on a throwaway copy is caught)"
    else
      report "self-test: flipping $scripts_mutation_target's bit on a throwaway copy did not fail the guard"
      sed 's/^/    /' "$WORK/mutant.out" >&2
    fi
    # Restore is implicit — $mutant_scripts is a throwaway copy under $WORK,
    # never the real tree, and is removed by the EXIT trap. The real
    # check-manifest.sh's bit is never touched by this self-test.
    [ -x "$mutant_scripts/$scripts_mutation_target" ] && report "self-test: chmod -x did not actually clear the bit on the mutant copy"
  fi

  # And the positive control: an all-executable throwaway copy must pass,
  # proving the guard isn't unconditionally red.
  control_scripts="$WORK/scripts-control"
  mkdir -p "$control_scripts"
  cp "$SCRIPTS_DIR"/*.sh "$control_scripts"/
  chmod +x "$control_scripts"/*.sh

  rc=0
  SE_SELFTEST=0 SE_SCRIPTS_DIR="$control_scripts" SE_TESTS_DIR="$TESTS_DIR" \
    bash "${BASH_SOURCE[0]}" >"$WORK/control.out" 2>&1 || rc=$?
  if [ "$rc" -eq 0 ]; then
    pass "self-test control (an all-executable throwaway copy passes)"
  else
    report "self-test control: an all-executable throwaway copy failed the guard"
    sed 's/^/    /' "$WORK/control.out" >&2
  fi

  # #665 mutation probe: a scripts/*.sh copy that is missing the named
  # mutation target (simulating check-manifest.sh having been renamed)
  # must fail through report(), not abort mid-script, and every later
  # self-test probe must still execute. SE_SELFTEST=1 here re-enters the
  # whole self-test block one level down so the guard code path above is
  # exercised against exactly that missing-target fixture; SE_SELFTEST_DEPTH=1
  # (with the nonce) keeps that nested run from re-entering this same probe
  # (see the SELFTEST_DEPTH comment above). Only run at depth 0 — a depth-1
  # run already proves the "remaining probes still run" half by definition
  # (it is one of those remaining probes), and running this again at depth
  # 1 would need its own depth-2 guard for no added coverage.
  if [ "$SELFTEST_DEPTH" = "0" ]; then
    renamed_scripts="$WORK/scripts-renamed"
    mkdir -p "$renamed_scripts"
    for f in "$SCRIPTS_DIR"/*.sh; do
      b="$(basename "$f")"
      [ "$b" = "$scripts_mutation_target" ] && continue
      cp "$f" "$renamed_scripts/$b"
    done
    chmod +x "$renamed_scripts"/*.sh

    rc=0
    SE_SELFTEST=1 SE_SELFTEST_DEPTH=1 SE_SELFTEST_NONCE="$nonce_file" SE_SELFTEST_NONCE_VALUE="$nonce_value" SE_SCRIPTS_DIR="$renamed_scripts" SE_TESTS_DIR="$TESTS_DIR" \
      bash "${BASH_SOURCE[0]}" >"$WORK/renamed.out" 2>&1 || rc=$?
    if [ "$rc" -ne 0 ] \
       && grep -qF "mutation target $scripts_mutation_target not found" "$WORK/renamed.out" \
       && grep -qF "PASS: self-test control" "$WORK/renamed.out"; then
      pass "self-test rename guard, scripts arm (a missing mutation target fails through report() and later probes still run) (#665)"
    else
      report "self-test rename guard, scripts arm: a scripts copy without $scripts_mutation_target did not fail cleanly through report() while letting remaining probes run (#665)"
      sed 's/^/    /' "$WORK/renamed.out" >&2
    fi
  fi

  # The tests/test_*.sh arm gets its own mutant and its own positive
  # control, exactly as the scripts/*.sh arm above — the two are separate
  # `check_dir` invocations over separate directories, and a probe of one
  # arm proves nothing about the other (#663 review round 1, F1).
  mutant_tests="$WORK/tests"
  mkdir -p "$mutant_tests"
  cp "$TESTS_DIR"/test_*.sh "$mutant_tests"/
  chmod +x "$mutant_tests"/test_*.sh
  if [ ! -e "$mutant_tests/$tests_mutation_target" ]; then
    report "self-test tests-arm: mutation target $tests_mutation_target not found under $TESTS_DIR — cannot probe the tests/test_*.sh arm (#665)"
  else
    # Flip exactly one bit, on a file this suite does not itself run out of
    # $mutant_tests (the nested invocation below runs "${BASH_SOURCE[0]}" from
    # its real path, never a copy), so mutating it here is inert beyond the
    # guard's own scan.
    chmod -x "$mutant_tests/$tests_mutation_target"

    rc=0
    SE_SELFTEST=0 SE_SCRIPTS_DIR="$SCRIPTS_DIR" SE_TESTS_DIR="$mutant_tests" \
      bash "${BASH_SOURCE[0]}" >"$WORK/mutant_tests.out" 2>&1 || rc=$?
    if [ "$rc" -ne 0 ] && grep -qF "not executable: $mutant_tests/$tests_mutation_target" "$WORK/mutant_tests.out"; then
      pass "self-test tests-arm (a flipped bit on a throwaway tests copy is caught)"
    else
      report "self-test tests-arm: flipping $tests_mutation_target's bit on a throwaway tests copy did not fail the guard"
      sed 's/^/    /' "$WORK/mutant_tests.out" >&2
    fi
    [ -x "$mutant_tests/$tests_mutation_target" ] && report "self-test tests-arm: chmod -x did not actually clear the bit on the mutant copy"
  fi

  control_tests="$WORK/tests-control"
  mkdir -p "$control_tests"
  cp "$TESTS_DIR"/test_*.sh "$control_tests"/
  chmod +x "$control_tests"/test_*.sh

  rc=0
  SE_SELFTEST=0 SE_SCRIPTS_DIR="$SCRIPTS_DIR" SE_TESTS_DIR="$control_tests" \
    bash "${BASH_SOURCE[0]}" >"$WORK/control_tests.out" 2>&1 || rc=$?
  if [ "$rc" -eq 0 ]; then
    pass "self-test tests-arm control (an all-executable throwaway tests copy passes)"
  else
    report "self-test tests-arm control: an all-executable throwaway tests copy failed the guard"
    sed 's/^/    /' "$WORK/control_tests.out" >&2
  fi

  # #665 mutation probe, tests arm: same shape as the scripts-arm rename
  # probe above, over test_preflight.sh instead of check-manifest.sh, and
  # the same depth-0-only guard for the same recursion reason.
  if [ "$SELFTEST_DEPTH" = "0" ]; then
    renamed_tests="$WORK/tests-renamed"
    mkdir -p "$renamed_tests"
    for f in "$TESTS_DIR"/test_*.sh; do
      b="$(basename "$f")"
      [ "$b" = "$tests_mutation_target" ] && continue
      cp "$f" "$renamed_tests/$b"
    done
    chmod +x "$renamed_tests"/test_*.sh

    rc=0
    SE_SELFTEST=1 SE_SELFTEST_DEPTH=1 SE_SELFTEST_NONCE="$nonce_file" SE_SELFTEST_NONCE_VALUE="$nonce_value" SE_SCRIPTS_DIR="$SCRIPTS_DIR" SE_TESTS_DIR="$renamed_tests" \
      bash "${BASH_SOURCE[0]}" >"$WORK/renamed_tests.out" 2>&1 || rc=$?
    if [ "$rc" -ne 0 ] \
       && grep -qF "mutation target $tests_mutation_target not found" "$WORK/renamed_tests.out" \
       && grep -qF "PASS: self-test tests-arm control" "$WORK/renamed_tests.out"; then
      pass "self-test rename guard, tests arm (a missing mutation target fails through report() and later probes still run) (#665)"
    else
      report "self-test rename guard, tests arm: a tests copy without $tests_mutation_target did not fail cleanly through report() while letting remaining probes run (#665)"
      sed 's/^/    /' "$WORK/renamed_tests.out" >&2
    fi
  fi

  # Depth mutants: an unvalidated depth. These two are themselves gated to
  # depth 0 — like every other nested SE_SELFTEST=1 invocation in this file
  # (both rename guards above, the depth-validation control below) — because
  # an ungated child re-enters this same unvalidated-depth code path one
  # level down: with the range check's `*)` arm neutered, a depth-1 child
  # spawned from here would itself treat its own inherited/forged depth as
  # unvalidated and spawn another, recursing without bound (round 1 F1,
  # reproduced at 21 concurrent processes and climbing before this gate).
  # With the gate in place, all five of this file's depth-0-only probes
  # (both rename guards, these two depth mutants, and the depth-validation
  # control) would be silently dropped by an unvalidated stale or forged
  # SE_SELFTEST_DEPTH=1 — which is exactly what SELFTEST_DEPTH's own
  # validation above exists to prevent — while the run still printed "all
  # assertions passed" and exited 0.
  if [ "$SELFTEST_DEPTH" = "0" ]; then
    rc=0
    SE_SELFTEST=1 SE_SELFTEST_DEPTH=abc \
      bash "${BASH_SOURCE[0]}" >"$WORK/depth_invalid.out" 2>&1 || rc=$?
    if [ "$rc" -ne 0 ] && grep -qF "SE_SELFTEST_DEPTH must be 0 or 1" "$WORK/depth_invalid.out"; then
      pass "self-test depth-validation arm (a non-numeric SE_SELFTEST_DEPTH is refused, not silently treated as non-zero)"
    else
      report "self-test depth-validation arm: a non-numeric SE_SELFTEST_DEPTH did not fail the guard"
      sed 's/^/    /' "$WORK/depth_invalid.out" >&2
    fi

    rc=0
    SE_SELFTEST=1 SE_SELFTEST_DEPTH=1 SE_SELFTEST_NONCE='' \
      bash "${BASH_SOURCE[0]}" >"$WORK/depth_stale.out" 2>&1 || rc=$?
    if [ "$rc" -ne 0 ] && grep -qF "live immediate-parent run — no file at the named path" "$WORK/depth_stale.out"; then
      pass "self-test depth-provenance arm (a stale SE_SELFTEST_DEPTH=1 with no live parent is refused, so it cannot silently drop the depth-0-only probes)"
    else
      report "self-test depth-provenance arm: a stale SE_SELFTEST_DEPTH=1 did not fail the guard"
      sed 's/^/    /' "$WORK/depth_stale.out" >&2
    fi

    # #741: the exact forgery from the #666 comment — a pre-existing file
    # (never written by this run's nonce mechanism) named as
    # SE_SELFTEST_NONCE, with no SE_SELFTEST_NONCE_VALUE at all. Before the
    # content check above, `[ -f "$SE_SELFTEST_NONCE" ]` alone was
    # satisfied and depth 1 was accepted; this proves the fix rejects an
    # existing-but-unrelated file the same way the depth-stale arm above
    # rejects an empty path.
    echo "arbitrary-preexisting-content, never written by this run's nonce mechanism" >"$WORK/forged-nonce"
    rc=0
    SE_SELFTEST=1 SE_SELFTEST_DEPTH=1 SE_SELFTEST_NONCE="$WORK/forged-nonce" \
      bash "${BASH_SOURCE[0]}" >"$WORK/depth_forged.out" 2>&1 || rc=$?
    if [ "$rc" -ne 0 ] && grep -qF "live immediate-parent run — SE_SELFTEST_NONCE_VALUE is empty" "$WORK/depth_forged.out"; then
      pass "self-test depth-forgery arm (a pre-existing file merely named as the nonce, with no SE_SELFTEST_NONCE_VALUE at all, is refused — existence alone no longer passes) (#741)"
    else
      report "self-test depth-forgery arm: a pre-existing file merely named as the nonce was accepted without a matching value — the depth check is forgeable by existence alone (#741)"
      sed 's/^/    /' "$WORK/depth_forged.out" >&2
    fi

    # Round-1 finding 1: the arm above never reaches the content comparison —
    # it is refused by the cheaper "VALUE is empty" clause, so deleting the
    # comparison outright left the suite green at 16/16. This arm supplies an
    # existing nonce file *and* a non-empty SE_SELFTEST_NONCE_VALUE that does
    # not match the file's content, so the first two clauses pass and only the
    # comparison can refuse it. Splicing that one clause out turns this arm
    # red — it is the fixture that makes the comparison load-bearing.
    printf '%s' "$nonce_value" >"$WORK/mismatch-nonce"
    rc=0
    SE_SELFTEST=1 SE_SELFTEST_DEPTH=1 SE_SELFTEST_NONCE="$WORK/mismatch-nonce" \
      SE_SELFTEST_NONCE_VALUE="${nonce_value} tampered" \
      bash "${BASH_SOURCE[0]}" >"$WORK/depth_mismatch.out" 2>&1 || rc=$?
    if [ "$rc" -ne 0 ] && grep -qF "the file's content does not match SE_SELFTEST_NONCE_VALUE" "$WORK/depth_mismatch.out"; then
      pass "self-test depth nonce-content-mismatch arm (an existing nonce file plus a non-empty, non-matching SE_SELFTEST_NONCE_VALUE is refused by the content comparison itself) (#741, round-1 finding 1)"
    else
      report "self-test depth nonce-content-mismatch arm: an existing nonce file with a non-matching SE_SELFTEST_NONCE_VALUE was accepted — the content comparison is not load-bearing (#741)"
      sed 's/^/    /' "$WORK/depth_mismatch.out" >&2
    fi

    # Round-1 finding 2 / the forgery #741 actually names: file content and
    # value agree, because the forger supplies both (`SE_SELFTEST_NONCE=
    # /etc/hostname SE_SELFTEST_NONCE_VALUE="$(cat /etc/hostname)"`). A
    # two-value consistency test accepts that; a provenance test does not,
    # because the value carries no pid this run can trace to an ancestor.
    printf '%s' "consistent-but-unrelated" >"$WORK/consistent-nonce"
    rc=0
    SE_SELFTEST=1 SE_SELFTEST_DEPTH=1 SE_SELFTEST_NONCE="$WORK/consistent-nonce" \
      SE_SELFTEST_NONCE_VALUE="consistent-but-unrelated" \
      bash "${BASH_SOURCE[0]}" >"$WORK/depth_consistent.out" 2>&1 || rc=$?
    if [ "$rc" -ne 0 ] && grep -qF "the nonce carries no parent pid in the expected form" "$WORK/depth_consistent.out"; then
      pass "self-test depth self-consistent-forgery arm (a caller-supplied file whose content matches the caller-supplied value is still refused — the check is provenance, not consistency) (#741, round-1 finding 2)"
    else
      report "self-test depth self-consistent-forgery arm: a self-consistent caller-supplied nonce was accepted — the depth check is still a consistency test, not a provenance test (#741)"
      sed 's/^/    /' "$WORK/depth_consistent.out" >&2
    fi

    # Liveness half of provenance: a well-formed nonce naming a pid that has
    # already exited must be refused. The pid comes from a shell that exits
    # before the command substitution returns, so it is dead by construction;
    # the assertion below fails loudly rather than guessing if the kernel
    # recycled it onto a live process before we looked. #860 secondary: a
    # single draw made this probe's own exit status depend on whether the
    # kernel recycled a pid in the narrow window between the subshell exiting
    # and this check running — an environmental flake, not a property of the
    # code under test. Retried up to 5 times for a pid that is still dead by
    # the time we look; only if every draw in that bounded retry comes back
    # live is it reported as a genuine anomaly, which pid recycling landing
    # on 5 consecutive fresh draws would not plausibly explain.
    dead_pid=""
    dead_pid_attempts=0
    while [ "$dead_pid_attempts" -lt 5 ]; do
      candidate="$(bash -c 'echo $$')"
      if [ ! -d "/proc/$candidate" ]; then
        dead_pid="$candidate"
        break
      fi
      dead_pid_attempts=$((dead_pid_attempts + 1))
    done
    if [ -z "$dead_pid" ]; then
      report "self-test depth dead-pid arm: 5 consecutive draws were all live (pid reuse) — cannot probe the liveness clause this run"
    else
      printf '%s' "selftest-nonce v1 pid=$dead_pid rand=probe" >"$WORK/dead-nonce"
      rc=0
      SE_SELFTEST=1 SE_SELFTEST_DEPTH=1 SE_SELFTEST_NONCE="$WORK/dead-nonce" \
        SE_SELFTEST_NONCE_VALUE="selftest-nonce v1 pid=$dead_pid rand=probe" \
        bash "${BASH_SOURCE[0]}" >"$WORK/depth_dead.out" 2>&1 || rc=$?
      if [ "$rc" -ne 0 ] && grep -qF "parent pid $dead_pid is not alive" "$WORK/depth_dead.out"; then
        pass "self-test depth dead-pid arm (a nonce naming an exited pid is refused — a stale nonce from a finished run cannot pass) (#741)"
      else
        report "self-test depth dead-pid arm: a nonce naming an exited pid was accepted — liveness is not enforced (#741)"
        sed 's/^/    /' "$WORK/depth_dead.out" >&2
      fi
    fi

    # Parent-identity half of provenance: a *live* pid that is not this run's
    # own immediate parent must also be refused, or "alive" alone would let
    # any running process on the host stand in for the parent. The stand-in
    # is a sleep this run starts itself (so only our own pid is ever
    # signalled, per agent-rules.md's shared-host rule) and is a sibling of
    # the nested run, never its parent.
    sleep 30 &
    live_other_pid=$!
    printf '%s' "selftest-nonce v1 pid=$live_other_pid rand=probe" >"$WORK/nonancestor-nonce"
    rc=0
    SE_SELFTEST=1 SE_SELFTEST_DEPTH=1 SE_SELFTEST_NONCE="$WORK/nonancestor-nonce" \
      SE_SELFTEST_NONCE_VALUE="selftest-nonce v1 pid=$live_other_pid rand=probe" \
      bash "${BASH_SOURCE[0]}" >"$WORK/depth_nonancestor.out" 2>&1 || rc=$?
    kill "$live_other_pid" 2>/dev/null || true
    wait "$live_other_pid" 2>/dev/null || true
    if [ "$rc" -ne 0 ] && grep -qF "is alive but is not this run's immediate parent (#860)" "$WORK/depth_nonancestor.out"; then
      pass "self-test depth non-ancestor-pid arm (a nonce naming a live but unrelated process is refused — liveness alone is not provenance) (#741, round-1 finding 2)"
    else
      report "self-test depth non-ancestor-pid arm: a nonce naming a live but unrelated process was accepted — parent identity is not enforced (#741)"
      sed 's/^/    /' "$WORK/depth_nonancestor.out" >&2
    fi

    # #860: the reproduction that motivated the narrowing. `pid 1` is an
    # ancestor of every process on the host — a universal constant a caller
    # can name with zero knowledge of the actual run. Before #860's fix, the
    # bounded ancestry walk accepted this outright (this exact fixture, on
    # the pre-#860 code, reproduces "4/4 probes ran at depth 1" / exit 0).
    # The narrowed check refuses it because pid 1 is (almost) never this
    # run's literal, immediate $PPID.
    printf '%s' "selftest-nonce v1 pid=1 rand=9-9" >"$WORK/pid1-nonce"
    rc=0
    SE_SELFTEST=1 SE_SELFTEST_DEPTH=1 SE_SELFTEST_NONCE="$WORK/pid1-nonce" \
      SE_SELFTEST_NONCE_VALUE="selftest-nonce v1 pid=1 rand=9-9" \
      bash "${BASH_SOURCE[0]}" >"$WORK/depth_pid1.out" 2>&1 || rc=$?
    if [ "$rc" -ne 0 ] && grep -qF "is alive but is not this run's immediate parent (#860)" "$WORK/depth_pid1.out"; then
      pass "self-test depth pid=1 forgery arm (a nonce naming pid 1 — an ancestor of every process — is refused, not accepted as a zero-knowledge shortcut) (#860)"
    else
      report "self-test depth pid=1 forgery arm: a nonce naming pid 1 was accepted — the zero-knowledge ancestor shortcut is not closed (#860)"
      sed 's/^/    /' "$WORK/depth_pid1.out" >&2
    fi
  fi

  # ...and the positive control for both: depth 1 *with* a live parent's nonce
  # is exactly what the rename probes above pass down, and must run cleanly.
  # Depth-0-only, since this control is itself a depth-1 run.
  if [ "$SELFTEST_DEPTH" = "0" ]; then
    rc=0
    SE_SELFTEST=1 SE_SELFTEST_DEPTH=1 SE_SELFTEST_NONCE="$nonce_file" SE_SELFTEST_NONCE_VALUE="$nonce_value" \
      bash "${BASH_SOURCE[0]}" >"$WORK/depth_control.out" 2>&1 || rc=$?
    if [ "$rc" -eq 0 ] && grep -qF "probes ran at depth 1" "$WORK/depth_control.out"; then
      pass "self-test depth-validation arm control (depth 1 with a live parent nonce runs and passes)"
    else
      report "self-test depth-validation arm control: depth 1 with a live parent nonce did not run cleanly"
      sed 's/^/    /' "$WORK/depth_control.out" >&2
    fi
  fi

  # #666/#684: the sibling-skill walk gets its own mutants and controls,
  # exactly as the two check_dir arms above — a probe of one arm proves
  # nothing about another. All of these nested invocations are SE_SELFTEST=0
  # (a single, non-recursive check of the fixture skills root), so none of
  # them can recurse; they are gated to depth 0 purely to keep the depth-1
  # probe count unchanged and match the accounting below, not because they
  # carry any recursion risk of their own.
  if [ "$SELFTEST_DEPTH" = "0" ]; then
    # Mutant: a fixture skills root with one sibling skill carrying a
    # non-executable script. A stray non-directory entry (README) at the
    # skills-root level is included to prove the walk skips it rather than
    # erroring on `$entry/scripts`.
    sib_mutant="$WORK/skills-sib-mutant"
    mkdir -p "$sib_mutant/skill-x/scripts" "$sib_mutant/skill-x/tests"
    printf '#!/usr/bin/env bash\n' >"$sib_mutant/skill-x/scripts/good.sh"
    printf '#!/usr/bin/env bash\n' >"$sib_mutant/skill-x/scripts/bad.sh"
    chmod +x "$sib_mutant/skill-x/scripts/good.sh"
    printf '#!/usr/bin/env bash\n' >"$sib_mutant/skill-x/tests/test_good.sh"
    chmod +x "$sib_mutant/skill-x/tests/test_good.sh"
    echo "not a skill" >"$sib_mutant/README.md"

    rc=0
    SE_SELFTEST=0 SE_SKILLS_ROOT="$sib_mutant" SE_SCRIPTS_DIR="$SCRIPTS_DIR" SE_TESTS_DIR="$TESTS_DIR" \
      bash "${BASH_SOURCE[0]}" >"$WORK/sib_mutant.out" 2>&1 || rc=$?
    if [ "$rc" -ne 0 ] && grep -qF "not executable: $sib_mutant/skill-x/scripts/bad.sh" "$WORK/sib_mutant.out"; then
      pass "self-test sibling-skill arm (a non-executable script in a sibling skill's scripts/ is caught) (#666)"
    else
      report "self-test sibling-skill arm: a non-executable script in a sibling skill's scripts/ was not caught (#666)"
      sed 's/^/    /' "$WORK/sib_mutant.out" >&2
    fi

    # Positive control: same fixture, every script executable — must pass.
    sib_control="$WORK/skills-sib-control"
    mkdir -p "$sib_control/skill-x/scripts" "$sib_control/skill-x/tests"
    printf '#!/usr/bin/env bash\n' >"$sib_control/skill-x/scripts/good.sh"
    chmod +x "$sib_control/skill-x/scripts/good.sh"
    printf '#!/usr/bin/env bash\n' >"$sib_control/skill-x/tests/test_good.sh"
    chmod +x "$sib_control/skill-x/tests/test_good.sh"
    echo "not a skill" >"$sib_control/README.md"

    rc=0
    SE_SELFTEST=0 SE_SKILLS_ROOT="$sib_control" SE_SCRIPTS_DIR="$SCRIPTS_DIR" SE_TESTS_DIR="$TESTS_DIR" \
      bash "${BASH_SOURCE[0]}" >"$WORK/sib_control.out" 2>&1 || rc=$?
    if [ "$rc" -eq 0 ]; then
      pass "self-test sibling-skill arm control (an all-executable sibling skill, plus a stray non-directory entry at the skills root, passes) (#666)"
    else
      report "self-test sibling-skill arm control: an all-executable sibling skill fixture failed the guard (#666)"
      sed 's/^/    /' "$WORK/sib_control.out" >&2
    fi

    # Missing-subdirectory control: a sibling skill with neither scripts/
    # nor tests/ at all (like github-pr-review, interrogate, with-secrets,
    # gitlab-workflow in this repository) must be a silent skip, not a
    # report() — optional=1 exists exactly for this case.
    sib_missing="$WORK/skills-sib-missing"
    mkdir -p "$sib_missing/skill-bare"

    rc=0
    SE_SELFTEST=0 SE_SKILLS_ROOT="$sib_missing" SE_SCRIPTS_DIR="$SCRIPTS_DIR" SE_TESTS_DIR="$TESTS_DIR" \
      bash "${BASH_SOURCE[0]}" >"$WORK/sib_missing.out" 2>&1 || rc=$?
    if [ "$rc" -eq 0 ] && ! grep -q "^FAIL:" "$WORK/sib_missing.out"; then
      pass "self-test sibling-skill missing-subdirectory control (a skill with no scripts/ or tests/ is skipped, not reported) (#666)"
    else
      report "self-test sibling-skill missing-subdirectory control: a skill with no scripts/ or tests/ was reported instead of skipped (#666)"
      sed 's/^/    /' "$WORK/sib_missing.out" >&2
    fi

    # Unreadable-directory arm: the #675 regression this issue names by
    # number — `empty_ok=1` folded an unreadable directory into "no files
    # matched", silently passing a chmod-000 scripts/ dir that hides a
    # non-executable script. chmod is restored immediately after the probe
    # regardless of outcome, so $WORK's EXIT-trap cleanup can still remove
    # the fixture (rm -rf cannot descend into a 000 directory).
    sib_unreadable="$WORK/skills-sib-unreadable"
    mkdir -p "$sib_unreadable/skill-locked/scripts"
    printf '#!/usr/bin/env bash\n' >"$sib_unreadable/skill-locked/scripts/hidden.sh"
    chmod 000 "$sib_unreadable/skill-locked/scripts"

    rc=0
    SE_SELFTEST=0 SE_SKILLS_ROOT="$sib_unreadable" SE_SCRIPTS_DIR="$SCRIPTS_DIR" SE_TESTS_DIR="$TESTS_DIR" \
      bash "${BASH_SOURCE[0]}" >"$WORK/sib_unreadable.out" 2>&1 || rc=$?
    chmod 755 "$sib_unreadable/skill-locked/scripts"
    if [ "$rc" -ne 0 ] && grep -qF "directory exists but is not readable: $sib_unreadable/skill-locked/scripts" "$WORK/sib_unreadable.out"; then
      pass "self-test sibling-skill unreadable-directory arm (a chmod-000 scripts/ dir is a failure, never folded into 'no files matched') (#666)"
    else
      report "self-test sibling-skill unreadable-directory arm: a chmod-000 sibling scripts/ dir did not fail the guard — the #675 empty_ok=1 regression (#666)"
      sed 's/^/    /' "$WORK/sib_unreadable.out" >&2
    fi

    # Symlinked skill directory (#684): a real skill directory elsewhere on
    # disk, reachable only via a symlink at the skills-root level. A plain
    # `find -type d` walk never matches the symlink itself; this fixture
    # fails if the guard falls back to that.
    sib_symlink_target="$WORK/real-skill-elsewhere"
    mkdir -p "$sib_symlink_target/scripts"
    printf '#!/usr/bin/env bash\n' >"$sib_symlink_target/scripts/bad.sh"
    sib_symlink_root="$WORK/skills-sib-symlink"
    mkdir -p "$sib_symlink_root"
    ln -s "$sib_symlink_target" "$sib_symlink_root/linked-skill"

    rc=0
    SE_SELFTEST=0 SE_SKILLS_ROOT="$sib_symlink_root" SE_SCRIPTS_DIR="$SCRIPTS_DIR" SE_TESTS_DIR="$TESTS_DIR" \
      bash "${BASH_SOURCE[0]}" >"$WORK/sib_symlink.out" 2>&1 || rc=$?
    if [ "$rc" -ne 0 ] && grep -qF "not executable: $sib_symlink_root/linked-skill/scripts/bad.sh" "$WORK/sib_symlink.out"; then
      pass "self-test sibling-skill symlink arm (a skill reachable only via a symlinked directory is scanned, not skipped) (#684)"
    else
      report "self-test sibling-skill symlink arm: a symlinked skill directory's non-executable script was not caught (#684)"
      sed 's/^/    /' "$WORK/sib_symlink.out" >&2
    fi

    # And its positive control: the same symlinked skill, fully executable.
    chmod +x "$sib_symlink_target/scripts/bad.sh"
    rc=0
    SE_SELFTEST=0 SE_SKILLS_ROOT="$sib_symlink_root" SE_SCRIPTS_DIR="$SCRIPTS_DIR" SE_TESTS_DIR="$TESTS_DIR" \
      bash "${BASH_SOURCE[0]}" >"$WORK/sib_symlink_control.out" 2>&1 || rc=$?
    if [ "$rc" -eq 0 ]; then
      pass "self-test sibling-skill symlink arm control (an all-executable symlinked skill passes) (#684)"
    else
      report "self-test sibling-skill symlink arm control: an all-executable symlinked skill failed the guard (#684)"
      sed 's/^/    /' "$WORK/sib_symlink_control.out" >&2
    fi

    # Round-1 note 3: one level in from #684's case — a *real* skill directory
    # whose scripts/ is itself a symlink. `[ -d "$dir" ]` follows the link and
    # passes, but `find "$dir"` does not follow a symlink given as its own
    # starting point, so before `find -L` the arm degraded to "no files
    # matched … pattern or path is wrong" and never named the 644 script.
    # This fixture fails if check_dir loses its -L.
    linkdir_target="$WORK/real-scripts-elsewhere"
    mkdir -p "$linkdir_target"
    printf '#!/usr/bin/env bash\n' >"$linkdir_target/bad.sh"
    linkdir_root="$WORK/skills-sib-linkdir"
    mkdir -p "$linkdir_root/skill-y"
    ln -s "$linkdir_target" "$linkdir_root/skill-y/scripts"

    rc=0
    SE_SELFTEST=0 SE_SKILLS_ROOT="$linkdir_root" SE_SCRIPTS_DIR="$SCRIPTS_DIR" SE_TESTS_DIR="$TESTS_DIR" \
      bash "${BASH_SOURCE[0]}" >"$WORK/sib_linkdir.out" 2>&1 || rc=$?
    if [ "$rc" -ne 0 ] && grep -qF "not executable: $linkdir_root/skill-y/scripts/bad.sh" "$WORK/sib_linkdir.out"; then
      pass "self-test symlinked-scripts-dir arm (a scripts/ that is itself a symlink is scanned and the offending file is named, not reported as 'no files matched') (round-1 note 3)"
    else
      report "self-test symlinked-scripts-dir arm: a non-executable script under a symlinked scripts/ was not named — check_dir's find lost its -L (round-1 note 3)"
      sed 's/^/    /' "$WORK/sib_linkdir.out" >&2
    fi

    # ...and its positive control: same symlinked scripts/, all executable.
    chmod +x "$linkdir_target/bad.sh"
    rc=0
    SE_SELFTEST=0 SE_SKILLS_ROOT="$linkdir_root" SE_SCRIPTS_DIR="$SCRIPTS_DIR" SE_TESTS_DIR="$TESTS_DIR" \
      bash "${BASH_SOURCE[0]}" >"$WORK/sib_linkdir_control.out" 2>&1 || rc=$?
    if [ "$rc" -eq 0 ]; then
      pass "self-test symlinked-scripts-dir arm control (an all-executable symlinked scripts/ passes) (round-1 note 3)"
    else
      report "self-test symlinked-scripts-dir arm control: an all-executable symlinked scripts/ failed the guard (round-1 note 3)"
      sed 's/^/    /' "$WORK/sib_linkdir_control.out" >&2
    fi

    # #859 floor, arm 1: a skills root that does not exist at all must fail
    # loudly, not silently scan zero skills and report "all assertions
    # passed" — the entire #666 reach covering nothing while the suite stays
    # green.
    rc=0
    SE_SELFTEST=0 SE_SKILLS_ROOT="$WORK/does-not-exist-at-all" SE_SCRIPTS_DIR="$SCRIPTS_DIR" SE_TESTS_DIR="$TESTS_DIR" \
      bash "${BASH_SOURCE[0]}" >"$WORK/sib_root_missing.out" 2>&1 || rc=$?
    if [ "$rc" -ne 0 ] && grep -qF "skills root not found: $WORK/does-not-exist-at-all" "$WORK/sib_root_missing.out"; then
      pass "self-test skills-root-missing arm (a nonexistent SE_SKILLS_ROOT fails loudly instead of silently scanning nothing) (#859)"
    else
      report "self-test skills-root-missing arm: a nonexistent SE_SKILLS_ROOT was silently accepted — the sibling walk has no floor (#859)"
      sed 's/^/    /' "$WORK/sib_root_missing.out" >&2
    fi

    # #859 floor, arm 2: a skills root that exists but is unreadable must
    # also fail loudly, for the same reason. Mode restored immediately after
    # the probe so $WORK's EXIT-trap cleanup can still remove the fixture.
    sib_root_unreadable="$WORK/skills-sib-root-unreadable"
    mkdir -p "$sib_root_unreadable"
    chmod 000 "$sib_root_unreadable"
    rc=0
    SE_SELFTEST=0 SE_SKILLS_ROOT="$sib_root_unreadable" SE_SCRIPTS_DIR="$SCRIPTS_DIR" SE_TESTS_DIR="$TESTS_DIR" \
      bash "${BASH_SOURCE[0]}" >"$WORK/sib_root_unreadable.out" 2>&1 || rc=$?
    chmod 755 "$sib_root_unreadable"
    if [ "$rc" -ne 0 ] && grep -qF "skills root exists but is not readable: $sib_root_unreadable" "$WORK/sib_root_unreadable.out"; then
      pass "self-test skills-root-unreadable arm (a chmod-000 SE_SKILLS_ROOT fails loudly instead of silently scanning nothing) (#859)"
    else
      report "self-test skills-root-unreadable arm: a chmod-000 SE_SKILLS_ROOT was silently accepted — the sibling walk has no floor (#859)"
      sed 's/^/    /' "$WORK/sib_root_unreadable.out" >&2
    fi

    # #859 floor, arm 3: a skills root that exists, is readable, but holds no
    # skill directories at all (only a stray non-directory entry) must also
    # fail loudly — the same silent-nothing-scanned outcome by a different
    # route.
    sib_root_empty="$WORK/skills-sib-root-empty"
    mkdir -p "$sib_root_empty"
    echo "not a skill" >"$sib_root_empty/README.md"
    rc=0
    SE_SELFTEST=0 SE_SKILLS_ROOT="$sib_root_empty" SE_SCRIPTS_DIR="$SCRIPTS_DIR" SE_TESTS_DIR="$TESTS_DIR" \
      bash "${BASH_SOURCE[0]}" >"$WORK/sib_root_empty.out" 2>&1 || rc=$?
    if [ "$rc" -ne 0 ] && grep -qF "no sibling skill directory scanned under $sib_root_empty" "$WORK/sib_root_empty.out"; then
      pass "self-test skills-root-zero-skills arm (a readable SE_SKILLS_ROOT with no skill directories fails loudly instead of reporting success over nothing) (#859)"
    else
      report "self-test skills-root-zero-skills arm: a SE_SKILLS_ROOT with no skill directories was silently accepted — the sibling walk has no floor (#859)"
      sed 's/^/    /' "$WORK/sib_root_empty.out" >&2
    fi

    # #859, skill-directory readability: a chmod-000 *skill* directory (one
    # level up from the chmod-000 scripts/ arm above) hiding a mode-644
    # script must be a named failure, not folded into the optional skip —
    # the same missing-vs-unreadable conflation #675 introduced at the
    # scripts/ level, found again one level out in #839 round 2. Mode
    # restored immediately after the probe regardless of outcome.
    sib_skilldir_unreadable="$WORK/skills-sib-skilldir-unreadable"
    mkdir -p "$sib_skilldir_unreadable/skill-locked/scripts"
    printf '#!/usr/bin/env bash\n' >"$sib_skilldir_unreadable/skill-locked/scripts/bad.sh"
    chmod 644 "$sib_skilldir_unreadable/skill-locked/scripts/bad.sh"
    chmod 000 "$sib_skilldir_unreadable/skill-locked"

    rc=0
    SE_SELFTEST=0 SE_SKILLS_ROOT="$sib_skilldir_unreadable" SE_SCRIPTS_DIR="$SCRIPTS_DIR" SE_TESTS_DIR="$TESTS_DIR" \
      bash "${BASH_SOURCE[0]}" >"$WORK/sib_skilldir_unreadable.out" 2>&1 || rc=$?
    chmod 755 "$sib_skilldir_unreadable/skill-locked"
    if [ "$rc" -ne 0 ] && grep -qF "skill-locked: skill directory exists but is not readable: $sib_skilldir_unreadable/skill-locked" "$WORK/sib_skilldir_unreadable.out"; then
      pass "self-test skill-directory-unreadable arm (a chmod-000 skill directory hiding a mode-644 script is a named failure, never folded into the optional skip) (#859)"
    else
      report "self-test skill-directory-unreadable arm: a chmod-000 skill directory hiding a mode-644 script was silently skipped (#859)"
      sed 's/^/    /' "$WORK/sib_skilldir_unreadable.out" >&2
    fi

    # #859, empty-optional-directory decision: a sibling skill whose
    # scripts/ exists, is readable, but holds no matching files at all (a
    # placeholder directory) must be a skip, not a hard failure — the
    # decision this issue asked to be made explicit, proven here rather than
    # only asserted in prose.
    sib_empty_optional="$WORK/skills-sib-empty-optional"
    mkdir -p "$sib_empty_optional/skill-placeholder/scripts"
    rc=0
    SE_SELFTEST=0 SE_SKILLS_ROOT="$sib_empty_optional" SE_SCRIPTS_DIR="$SCRIPTS_DIR" SE_TESTS_DIR="$TESTS_DIR" \
      bash "${BASH_SOURCE[0]}" >"$WORK/sib_empty_optional.out" 2>&1 || rc=$?
    if [ "$rc" -eq 0 ] && ! grep -q "^FAIL:" "$WORK/sib_empty_optional.out"; then
      pass "self-test empty-optional-directory control (a sibling skill's existing-but-empty scripts/ is skipped, not failed) (#859)"
    else
      report "self-test empty-optional-directory control: a sibling skill's existing-but-empty scripts/ failed the guard instead of being skipped (#859)"
      sed 's/^/    /' "$WORK/sib_empty_optional.out" >&2
    fi
  fi

  # Probe accounting: assert how many probes ran, so a probe that stops
  # running for any reason — a lost depth gate, an early `return`, an
  # edited branch — is a FAIL rather than a shorter, still-green run. Update
  # both counts deliberately when adding or removing a probe.
  if [ "$SELFTEST_DEPTH" = "0" ]; then
    expected_probes=28
  else
    expected_probes=4
  fi
  if [ "$probes_run" -ne "$expected_probes" ]; then
    report "self-test: $probes_run probes ran at depth $SELFTEST_DEPTH, expected $expected_probes — a probe was lost, or was added without updating the expected count"
  else
    echo "self-test: $probes_run/$expected_probes probes ran at depth $SELFTEST_DEPTH"
  fi
fi

if [ "$fail" -ne 0 ]; then
  echo "test_scripts_executable: FAILED" >&2
  exit 1
fi
echo "test_scripts_executable: all assertions passed"
