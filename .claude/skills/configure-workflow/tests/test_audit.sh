#!/usr/bin/env bash
# test_audit.sh — fixture-driven regression test for audit.sh.
# Follows the mock-`gh` harness conventions in ../../github-workflow/tests/README.md:
# a mocked `gh` binary on PATH serves fixture responses, refuses any non-GET verb,
# and no real network call is ever reachable. Pinned to LANG=C / LC_ALL=C.
#
# audit.sh is READ-ONLY (it shells out to labels.sh/project.sh --audit, which are
# also read-only in that mode), so this test never needs the mock to accept a write
# verb from audit.sh itself; the refusal check below still proves the mock rejects
# one if it ever grew to send one.
#
# Covers (#782's Acceptance Criteria):
#  - `grep -n 'provenance\|prov_nums' scripts/audit.sh` returns nothing (asserted
#    directly against the resolved script file, not re-derived).
#  - without --repo or --family (with --owner/--project/--machine all present),
#    exits 2 before any `gh` call.
#  - a fixture tree missing one listed skill, and separately one missing one
#    listed agent file, reports that name as a GAP under "== skills"/"== agents"
#    and exits 1.
#  - a fixture tree carrying the full family reports "ok" for every name in
#    both lists, and its exit code is asserted (not just its per-name lines).
#  - a FULLY-CONFIGURED tree — labels in sync and the board matching
#    manifests/project.json, both served by the mock — reports
#    "AUDIT: configured" and exits 0. This is the only fixture that can prove
#    the `== labels` check ever reaches "ok", so it is what makes the --areas
#    threading load-bearing (#887).
#  - --areas is threaded to labels.sh: a stub labels.sh records its own argv
#    and the suite asserts the flag AND the path audit.sh was given appear in
#    it, so dropping the argument fails here rather than passing a grep.
#  - labels.sh exit 1 (real drift) is a GAP + exit 1, while exit 2 (usage /
#    unusable --areas) aborts with exit 2 naming labels.sh's own stderr — a
#    tool that could not run is never reported as label drift.
#  - an empty "skills"/"agents" array is refused (exit 2 naming the key)
#    rather than iterating once over the empty string, which produced one
#    spurious "ok" and one spurious "GAP" for a name that does not exist.
#  - a drift assertion: the real, shipped `manifests/family.json` lists EXACTLY
#    the directories under `.claude/skills/` and the files under
#    `.claude/agents/` in this repository, right now — not a re-statement of
#    the same list by hand.
#  - the `docs/process` pointer check stays a literal path-string presence
#    check: it is satisfied by the literal substring `docs/process` appearing
#    anywhere in AGENTS.md/CLAUDE.md, and is a GAP when neither file mentions it.
#
# UNMOCKED-CONTEXT: every mock invocation is logged before anything else happens;
# one arriving without the per-run harness env is recorded as UNMOCKED-CONTEXT
# instead of silently reaching the real, authenticated gh, and the end of this
# suite asserts that string never appears in the call log.
set -euo pipefail
export LANG=C LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUDIT_SH="$SCRIPT_DIR/../scripts/audit.sh"
REPO_FAMILY="$SCRIPT_DIR/../manifests/family.json"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/audit-test.XXXXXX")"
# shellcheck disable=SC2329 # invoked indirectly via `trap cleanup EXIT` on the next line
cleanup(){ rm -rf "$WORK"; }
trap cleanup EXIT

BIN="$WORK/bin"
mkdir -p "$BIN"

REPO="test-org/test-repo"
OWNER="test-owner"
NUM=7
MACHINE="machine-bot"
CALL_LOG="$WORK/calls.log"
: > "$CALL_LOG"

fail=0
report(){ echo "FAIL: $*" >&2; fail=1; }

# ---------------------------------------------------------------------------
# 0. Static checks against the resolved script (no gh involved).
# ---------------------------------------------------------------------------
if grep -n 'provenance\|prov_nums' "$AUDIT_SH" >/dev/null; then
  report "audit.sh still mentions provenance/prov_nums"
fi

# ---------------------------------------------------------------------------
# Mock gh. Generic enough to satisfy audit.sh's own calls plus the read-only
# --audit calls labels.sh and project.sh make; every invocation is logged
# first (UNMOCKED-CONTEXT tripwire), and any non-GET verb is refused.
# ---------------------------------------------------------------------------
cat > "$BIN/gh" <<'MOCKGH'
#!/usr/bin/env bash
set -euo pipefail
: "${MOCK_GH_CALL_LOG:?MOCK_GH_CALL_LOG must be set}"
printf 'CALL gh %s\n' "$*" >> "$MOCK_GH_CALL_LOG"
if [ -z "${MOCK_ACTIVE:-}" ]; then
  printf 'UNMOCKED-CONTEXT gh %s\n' "$*" >> "$MOCK_GH_CALL_LOG"
  echo "mock gh: invoked with no MOCK_ACTIVE -- unmocked call context" >&2
  exit 1
fi

if [ "${1:-}" = "auth" ] && [ "${2:-}" = "status" ]; then
  echo "Logged in to github.com as test-bot"
  echo "  - Token scopes: 'repo', 'project', 'read:org'"
  exit 0
fi
if [ "${1:-}" = "label" ] && [ "${2:-}" = "list" ]; then
  # MOCK_LABEL_LIST names a file holding the repo's live label set; with none
  # set the repo has no labels at all, so labels.sh --audit reports drift.
  if [ -n "${MOCK_LABEL_LIST:-}" ]; then cat "$MOCK_LABEL_LIST"; else echo "[]"; fi
  exit 0
fi
if [ "${1:-}" != "api" ]; then
  echo "mock gh: unsupported command: $*" >&2
  exit 1
fi
shift
endpoint=""; jqexpr=""; method="GET"; declare -a fargs=()
while [ $# -gt 0 ]; do
  case "$1" in
    --jq) jqexpr="$2"; shift 2 ;;
    -X|--method) method="$2"; shift 2 ;;
    -X?*) method="${1#-X}"; shift ;;
    --method=*) method="${1#--method=}"; shift ;;
    -f|-F) fargs+=("$2"); shift 2 ;;
    *) endpoint="$1"; shift ;;
  esac
done
if [ "$method" != "GET" ]; then
  echo "mock gh: refusing non-GET method ($method) on $endpoint" >&2
  exit 1
fi
apply(){ if [ -n "$jqexpr" ]; then jq -r "$jqexpr" <<<"$1"; else printf '%s\n' "$1"; fi; }
case "$endpoint" in
  graphql)
    query=""
    for a in "${fargs[@]+"${fargs[@]}"}"; do case "$a" in query=*) query="${a#query=}" ;; esac; done
    if grep -q 'organization(login' <<<"$query"; then
      apply '{"data":{"organization":{"projectV2":{"id":"PVT_x"}}}}'
    elif grep -q 'user(login' <<<"$query"; then
      apply '{"data":{"user":{"projectV2":null}}}'
    elif [ -n "${MOCK_PROJECT_NODE:-}" ]; then
      # A board that already matches manifests/project.json, so project.sh
      # --audit exits 0 and audit.sh's "== project" check reports ok.
      apply "$(jq -c '{data:{node:.}}' "$MOCK_PROJECT_NODE")"
    else
      apply '{"data":{"node":{"fields":{"nodes":[]},"views":{"nodes":[]},"workflows":{"nodes":[]}}}}'
    fi ;;
  repos/*/collaborators/*/permission)
    apply '{"permission":"write"}' ;;
  repos/*/rules/branches/*)
    apply '[{"type":"pull_request"}]' ;;
  repos/*)
    apply '{"default_branch":"main"}' ;;
  *) echo "mock gh: unsupported endpoint: $endpoint" >&2; exit 1 ;;
esac
MOCKGH
chmod +x "$BIN/gh"

# ---------------------------------------------------------------------------
# Fixture-tree builder. Each scenario gets its own tree under $WORK/trees/<n>
# with docs/process fully filled (no markers), .gitignore/AGENTS.md set, and
# a manifests/family.json + .claude/skills / .claude/agents shaped by the
# caller. Deliberately a SMALL, made-up family (not this repo's real one) so
# this suite's assertions are independent of what this repository happens to
# ship today.
# ---------------------------------------------------------------------------
mktree(){ # mktree <name> -> prints the tree path
  local t="$WORK/trees/$1"; mkdir -p "$t/docs/process" "$t/.claude/skills" "$t/.claude/agents"
  for f in work-tracking labels testing validation maintenance overnight failure-modes; do
    printf '# %s\n' "$f" > "$t/docs/process/$f.md"
  done
  printf '*.local.md\n' > "$t/.gitignore"
  printf 'Process lives in docs/process/.\n' > "$t/AGENTS.md"
  # The step-4 area-set JSON file --areas actually takes. NOT docs/process/labels.md:
  # that is the table process-docs.sh renders FROM this JSON, and labels.sh exits 2
  # on it (#887 / SKILL.md step 11).
  printf '%s\n' "$AREAS_JSON" > "$t/areas.json"
  printf '%s\n' "$t"
}
AREAS_JSON='[{"name":"area:docs","color":"0e8a16","description":"Docs and process files"},{"name":"area:scripts","color":"1d76db","description":"Scripts and tooling"}]'
FAMILY_JSON='{"skills":["skill-a","skill-b"],"agents":["agent-a.md","agent-b.md"]}'

# run_audit <tree> <family-file> [areas-path] -- captures stdout+stderr via globals.
# AUDIT_BIN overrides the audit.sh under test (used by the stub-labels.sh cases);
# MOCK_LABEL_LIST / MOCK_PROJECT_NODE / LABELS_ARGV_LOG are passed through when set.
run_audit(){
  local areas="${3:-areas.json}"
  set +e
  AUDIT_OUT=$(cd "$1" && MOCK_GH_CALL_LOG="$CALL_LOG" MOCK_ACTIVE=1 PATH="$BIN:$PATH" \
    MOCK_LABEL_LIST="${MOCK_LABEL_LIST:-}" MOCK_PROJECT_NODE="${MOCK_PROJECT_NODE:-}" \
    LABELS_ARGV_LOG="${LABELS_ARGV_LOG:-}" \
    "${AUDIT_BIN:-$AUDIT_SH}" --owner "$OWNER" --project "$NUM" --machine "$MACHINE" --repo "$REPO" --family "$2" --areas "$areas" 2>&1)
  AUDIT_RC=$?
  set -e
}

# mkskill <tag> <labels-rc> -> prints the path of an audit.sh whose sibling
# labels.sh is a stub exiting <labels-rc> and recording its own argv. A COPY of
# the whole scripts/ + manifests/ tree, placed outside the repository, so the
# real labels.sh is never mutated to make a fixture fail.
mkskill(){
  local d="$WORK/skill-$1"
  mkdir -p "$d"
  cp -a "$SCRIPT_DIR/../scripts" "$SCRIPT_DIR/../manifests" "$d/"
  {
    printf '#!/usr/bin/env bash\n'
    # shellcheck disable=SC2016 # deliberate: $* / $LABELS_ARGV_LOG must reach the GENERATED stub unexpanded
    printf '[ -n "${LABELS_ARGV_LOG:-}" ] && printf "labels-stub argv: %%s\\n" "$*" >> "$LABELS_ARGV_LOG"\n'
    printf 'printf "%%s\\n" "labels-stub: simulated labels.sh exit %s" >&2\n' "$2"
    printf 'exit %s\n' "$2"
  } > "$d/scripts/labels.sh"
  chmod +x "$d/scripts/labels.sh"
  printf '%s\n' "$d/scripts/audit.sh"
}

# run_argerr <expected-exit> <label> <tree> <args...>
# Every negative case runs under the full mock env (MOCK_GH_CALL_LOG, MOCK_ACTIVE,
# PATH) — the same env the positive `run_audit` calls use — so a guard that
# regresses and lets a `gh` call through is caught as a logged, non-empty call
# log instead of silently reaching the real, authenticated `gh`.
run_argerr(){
  local expect="$1" label="$2" tree="$3"; shift 3
  set +e
  out=$(cd "$tree" && MOCK_GH_CALL_LOG="$CALL_LOG" MOCK_ACTIVE=1 PATH="$BIN:$PATH" \
    MOCK_LABEL_LIST="${MOCK_LABEL_LIST:-}" MOCK_PROJECT_NODE="${MOCK_PROJECT_NODE:-}" \
    LABELS_ARGV_LOG="${LABELS_ARGV_LOG:-}" "${AUDIT_BIN:-$AUDIT_SH}" "$@" 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq "$expect" ] || report "$label: expected exit $expect, got $rc (output: $out)"
}

# ---------------------------------------------------------------------------
# 1. Without --repo or --family: exits 2 before any gh call.
# ---------------------------------------------------------------------------
: > "$CALL_LOG"
T=$(mktree noargs)
run_argerr 2 "no --repo/--family" "$T" --owner "$OWNER" --project "$NUM" --machine "$MACHINE"
[ -s "$CALL_LOG" ] && report "no --repo/--family: expected zero gh calls, call log: $(cat "$CALL_LOG")"

# ---------------------------------------------------------------------------
# 2. Full family present: every name reports ok.
# ---------------------------------------------------------------------------
: > "$CALL_LOG"
T=$(mktree full)
mkdir -p "$T/.claude/skills/skill-a" "$T/.claude/skills/skill-b"
: > "$T/.claude/agents/agent-a.md"; : > "$T/.claude/agents/agent-b.md"
FAM="$T/family.json"; printf '%s' "$FAMILY_JSON" > "$FAM"
run_audit "$T" "$FAM"
for n in skill-a skill-b; do
  grep -qE "ok +$n present in repo" <<<"$AUDIT_OUT" || report "full family: expected ok for skill $n (output: $AUDIT_OUT)"
done
for n in agent-a.md agent-b.md; do
  grep -qE "ok +$n present in repo" <<<"$AUDIT_OUT" || report "full family: expected ok for agent $n (output: $AUDIT_OUT)"
done
# The exit code is part of the contract, not incidental: with no MOCK_LABEL_LIST the
# repo has no labels and the board is empty, so labels and project are genuine gaps and
# audit.sh must exit 1 — asserted here so this fixture can never silently pass while
# reporting something other than what its name claims.
[ "$AUDIT_RC" -eq 1 ] || report "full family: expected exit 1 (labels+project gaps), got $AUDIT_RC (output: $AUDIT_OUT)"
grep -qE "GAP +labels drift" <<<"$AUDIT_OUT" || report "full family: expected the labels GAP under an empty label set (output: $AUDIT_OUT)"
grep -qF "AUDIT: gaps found" <<<"$AUDIT_OUT" || report "full family: expected 'AUDIT: gaps found' (output: $AUDIT_OUT)"

# ---------------------------------------------------------------------------
# 2b. FULLY CONFIGURED: labels in sync and the board matching the manifest, so
#     every check reports ok, the run ends "AUDIT: configured" and exits 0.
#     This is the fixture that proves the `== labels` check can reach "ok" at
#     all — without it, dropping --areas from the labels.sh call would leave
#     the suite green (#887).
# ---------------------------------------------------------------------------
: > "$CALL_LOG"
T=$(mktree configured)
mkdir -p "$T/.claude/skills/skill-a" "$T/.claude/skills/skill-b"
: > "$T/.claude/agents/agent-a.md"; : > "$T/.claude/agents/agent-b.md"
FAM="$T/family.json"; printf '%s' "$FAMILY_JSON" > "$FAM"
# The live label set = the canonical manifest set + exactly this tree's areas.json,
# so labels.sh --audit finds nothing to create, correct or prune.
jq -s '.[0].labels + .[1]' "$SCRIPT_DIR/../manifests/labels.json" "$T/areas.json" > "$T/labels-live.json"
# The live board, derived from manifests/project.json itself: every custom field with
# its options, every view with its columns/layout/filter, every workflow enabled, plus
# a node for each built-in column name a view references (Title, Labels, …) so the
# script's field-id lookup resolves.
jq '
  (.views | map(.columns[]) | unique) as $cols
  | (.custom_fields | map({id:("F_"+.name), name:.name, dataType:.dataType}
      + (if .options then {options:(.options|map({id:("O_"+.name),name:.name}))} else {} end))) as $cf
  | (($cols - ($cf|map(.name))) | map({id:("F_"+.), name:., dataType:"TEXT"})) as $bf
  | {fields:{nodes:($cf+$bf)},
     views:{nodes:(.views|map({id:("V_"+.name), name:.name, layout:.layout, filter:.filter,
                               fields:{nodes:(.columns|map({name:.}))}}))},
     workflows:{nodes:(.workflows|map({name:., enabled:true}))}}
' "$SCRIPT_DIR/../manifests/project.json" > "$T/project-live.json"
MOCK_LABEL_LIST="$T/labels-live.json" MOCK_PROJECT_NODE="$T/project-live.json" run_audit "$T" "$FAM"
[ "$AUDIT_RC" -eq 0 ] || report "configured tree: expected exit 0, got $AUDIT_RC (output: $AUDIT_OUT)"
grep -qF "AUDIT: configured" <<<"$AUDIT_OUT" || report "configured tree: expected 'AUDIT: configured' (output: $AUDIT_OUT)"
grep -qE "ok +canonical \+ area labels in sync" <<<"$AUDIT_OUT" || report "configured tree: expected the labels check to reach ok (output: $AUDIT_OUT)"
grep -qE "ok +fields/views/workflows match manifest" <<<"$AUDIT_OUT" || report "configured tree: expected the project check to reach ok (output: $AUDIT_OUT)"
grep -qE "GAP " <<<"$AUDIT_OUT" && report "configured tree: expected no GAP line at all (output: $AUDIT_OUT)"

# ---------------------------------------------------------------------------
# 2c. --areas is THREADED to labels.sh: a stub labels.sh records its own argv
#     and both the flag and the exact path audit.sh was given must appear in
#     it. A regression dropping the argument fails here (a grep for the flag
#     name in the source cannot tell the difference).
# ---------------------------------------------------------------------------
: > "$CALL_LOG"
T=$(mktree areas_threaded)
mkdir -p "$T/.claude/skills/skill-a" "$T/.claude/skills/skill-b"
: > "$T/.claude/agents/agent-a.md"; : > "$T/.claude/agents/agent-b.md"
FAM="$T/family.json"; printf '%s' "$FAMILY_JSON" > "$FAM"
ARGV_LOG="$WORK/labels-argv.log"; : > "$ARGV_LOG"
STUB_BIN=$(mkskill ok0 0)
LABELS_ARGV_LOG="$ARGV_LOG" AUDIT_BIN="$STUB_BIN" run_audit "$T" "$FAM" "$T/areas.json"
grep -qF -- "--areas $T/areas.json" "$ARGV_LOG" \
  || report "areas threading: labels.sh was not given '--areas $T/areas.json' (argv log: $(cat "$ARGV_LOG"))"
grep -qF -- "--audit" "$ARGV_LOG" || report "areas threading: labels.sh was not run in --audit mode (argv log: $(cat "$ARGV_LOG"))"
grep -qE "ok +canonical \+ area labels in sync" <<<"$AUDIT_OUT" || report "areas threading: labels.sh exit 0 must report ok (output: $AUDIT_OUT)"

# ---------------------------------------------------------------------------
# 2d. labels.sh exit 1 = real drift -> GAP and exit 1 (audit.sh keeps running
#     the other checks and reports the gap).
# ---------------------------------------------------------------------------
: > "$CALL_LOG"
: > "$ARGV_LOG"
STUB_BIN=$(mkskill drift1 1)
LABELS_ARGV_LOG="$ARGV_LOG" AUDIT_BIN="$STUB_BIN" run_audit "$T" "$FAM" "$T/areas.json"
[ "$AUDIT_RC" -eq 1 ] || report "labels exit 1: expected exit 1 (drift), got $AUDIT_RC (output: $AUDIT_OUT)"
grep -qE "GAP +labels drift \(run labels.sh\)" <<<"$AUDIT_OUT" || report "labels exit 1: expected the drift GAP (output: $AUDIT_OUT)"
grep -qF "usage/--areas error" <<<"$AUDIT_OUT" && report "labels exit 1: real drift must NOT be reported as a usage error (output: $AUDIT_OUT)"

# ---------------------------------------------------------------------------
# 2e. labels.sh exit 2 = usage / unusable --areas -> audit.sh dies with exit 2
#     naming labels.sh's own stderr. It must NEVER be reported as label drift:
#     the remedy that message offers ("run labels.sh") reproduces the exit 2.
#     Runs through run_argerr, under the full mock env, like every other
#     negative case.
# ---------------------------------------------------------------------------
: > "$CALL_LOG"
: > "$ARGV_LOG"
STUB_BIN=$(mkskill usage2 2)
LABELS_ARGV_LOG="$ARGV_LOG" AUDIT_BIN="$STUB_BIN" run_argerr 2 "labels exit 2" "$T" \
  --owner "$OWNER" --project "$NUM" --machine "$MACHINE" --repo "$REPO" --family "$FAM" --areas "$T/areas.json"
grep -qF "labels.sh usage/--areas error" <<<"$out" || report "labels exit 2: expected a usage error naming labels.sh (output: $out)"
grep -qF "$T/areas.json" <<<"$out" || report "labels exit 2: the message must name the --areas path (output: $out)"
grep -qF "labels-stub: simulated labels.sh exit 2" <<<"$out" || report "labels exit 2: expected labels.sh's own stderr to be surfaced (output: $out)"
grep -qF "labels drift" <<<"$out" && report "labels exit 2: a usage error must never be reported as label drift (output: $out)"
grep -qF "AUDIT: configured" <<<"$out" && report "labels exit 2: must never report AUDIT: configured (output: $out)"

# ---------------------------------------------------------------------------
# 2f. Any OTHER labels.sh exit (e.g. 3, missing dependency) also dies rather
#     than being folded into "drift".
# ---------------------------------------------------------------------------
: > "$CALL_LOG"
STUB_BIN=$(mkskill dep3 3)
LABELS_ARGV_LOG="$ARGV_LOG" AUDIT_BIN="$STUB_BIN" run_argerr 2 "labels exit 3" "$T" \
  --owner "$OWNER" --project "$NUM" --machine "$MACHINE" --repo "$REPO" --family "$FAM" --areas "$T/areas.json"
grep -qF "labels.sh failed unexpectedly (exit 3" <<<"$out" || report "labels exit 3: expected an unexpected-exit abort naming the code (output: $out)"
grep -qF "labels drift" <<<"$out" && report "labels exit 3: must never be reported as label drift (output: $out)"

# ---------------------------------------------------------------------------
# 3. Missing one listed skill: reports that name as a GAP, exits 1.
# ---------------------------------------------------------------------------
: > "$CALL_LOG"
T=$(mktree missing_skill)
mkdir -p "$T/.claude/skills/skill-a"   # skill-b deliberately absent
: > "$T/.claude/agents/agent-a.md"; : > "$T/.claude/agents/agent-b.md"
FAM="$T/family.json"; printf '%s' "$FAMILY_JSON" > "$FAM"
run_audit "$T" "$FAM"
[ "$AUDIT_RC" -eq 1 ] || report "missing skill: expected exit 1, got $AUDIT_RC (output: $AUDIT_OUT)"
grep -qE "GAP +\.claude/skills/skill-b missing" <<<"$AUDIT_OUT" || report "missing skill: expected GAP naming skill-b (output: $AUDIT_OUT)"
grep -qE "ok +skill-a present in repo" <<<"$AUDIT_OUT" || report "missing skill: expected ok for skill-a (output: $AUDIT_OUT)"

# ---------------------------------------------------------------------------
# 4. Missing one listed agent file: reports that name as a GAP, exits 1.
# ---------------------------------------------------------------------------
: > "$CALL_LOG"
T=$(mktree missing_agent)
mkdir -p "$T/.claude/skills/skill-a" "$T/.claude/skills/skill-b"
: > "$T/.claude/agents/agent-a.md"   # agent-b.md deliberately absent
FAM="$T/family.json"; printf '%s' "$FAMILY_JSON" > "$FAM"
run_audit "$T" "$FAM"
[ "$AUDIT_RC" -eq 1 ] || report "missing agent: expected exit 1, got $AUDIT_RC (output: $AUDIT_OUT)"
grep -qE "GAP +\.claude/agents/agent-b.md missing" <<<"$AUDIT_OUT" || report "missing agent: expected GAP naming agent-b.md (output: $AUDIT_OUT)"
grep -qE "ok +agent-a.md present in repo" <<<"$AUDIT_OUT" || report "missing agent: expected ok for agent-a.md (output: $AUDIT_OUT)"

# ---------------------------------------------------------------------------
# 5. docs/process pointer check stays a literal path-string presence check:
#    an AGENTS.md that never mentions docs/process, and no CLAUDE.md, is a
#    GAP; restoring the literal substring makes it ok again.
# ---------------------------------------------------------------------------
: > "$CALL_LOG"
T=$(mktree no_pointer)
mkdir -p "$T/.claude/skills/skill-a" "$T/.claude/skills/skill-b"
: > "$T/.claude/agents/agent-a.md"; : > "$T/.claude/agents/agent-b.md"
printf 'Nothing about process here.\n' > "$T/AGENTS.md"
FAM="$T/family.json"; printf '%s' "$FAMILY_JSON" > "$FAM"
run_audit "$T" "$FAM"
grep -qE "GAP +AGENTS\.md/CLAUDE\.md do not mention docs/process" <<<"$AUDIT_OUT" \
  || report "no pointer: expected GAP for the docs/process pointer (output: $AUDIT_OUT)"

# ---------------------------------------------------------------------------
# 5b. An unusable --family manifest fails CLOSED (exit 2, never "AUDIT:
#     configured") — never fails open just because the skills/agents loops
#     can't be trusted to report accurately. (F1)
# ---------------------------------------------------------------------------
T=$(mktree bad_family)
mkdir -p "$T/.claude/skills/skill-a" "$T/.claude/skills/skill-b"
: > "$T/.claude/agents/agent-a.md"; : > "$T/.claude/agents/agent-b.md"

# 5b-i. Trailing-comma JSON (invalid JSON outright).
: > "$CALL_LOG"
FAM="$T/family-trailing-comma.json"
printf '{"skills":["skill-a","skill-b",],"agents":["agent-a.md","agent-b.md"]}\n' > "$FAM"
run_argerr 2 "bad family: trailing comma" "$T" --owner "$OWNER" --project "$NUM" --machine "$MACHINE" --repo "$REPO" --family "$FAM" --areas areas.json
grep -qF "AUDIT: configured" <<<"$out" && report "bad family: trailing comma must never report AUDIT: configured (output: $out)"

# 5b-ii. Typo'd keys (no "skills"/"agents" arrays present at all).
: > "$CALL_LOG"
FAM="$T/family-typo.json"
printf '{"skilsl":["skill-a","skill-b"],"agentz":["agent-a.md","agent-b.md"]}\n' > "$FAM"
run_argerr 2 "bad family: typo'd keys" "$T" --owner "$OWNER" --project "$NUM" --machine "$MACHINE" --repo "$REPO" --family "$FAM" --areas areas.json
grep -qF "AUDIT: configured" <<<"$out" && report "bad family: typo'd keys must never report AUDIT: configured (output: $out)"

# 5b-iii. Mode-000 (unreadable) manifest, otherwise well-formed.
: > "$CALL_LOG"
FAM="$T/family-unreadable.json"
printf '%s' "$FAMILY_JSON" > "$FAM"
chmod 000 "$FAM"
run_argerr 2 "bad family: unreadable" "$T" --owner "$OWNER" --project "$NUM" --machine "$MACHINE" --repo "$REPO" --family "$FAM" --areas areas.json
grep -qF "AUDIT: configured" <<<"$out" && report "bad family: unreadable must never report AUDIT: configured (output: $out)"
chmod 644 "$FAM"

# 5b-iv. The sharpest case: a manifest listing an absent skill AND carrying a
#        trailing comma — must still exit non-zero, never "configured".
: > "$CALL_LOG"
FAM="$T/family-sharp.json"
printf '{"skills":["skill-a","skill-absent",],"agents":["agent-a.md","agent-b.md"]}\n' > "$FAM"
run_argerr 2 "bad family: absent skill + trailing comma" "$T" --owner "$OWNER" --project "$NUM" --machine "$MACHINE" --repo "$REPO" --family "$FAM" --areas areas.json
grep -qF "AUDIT: configured" <<<"$out" && report "bad family: absent skill + trailing comma must never report AUDIT: configured (output: $out)"

# ---------------------------------------------------------------------------
# 5c. An EMPTY skills[] or agents[] array is refused (exit 2, naming the key).
#     An empty array is still an array, so the type guard alone let it through
#     and each loop then ran exactly once over the empty string: one spurious
#     "ok   present in repo" (because .claude/skills/ itself exists) and one
#     spurious GAP for a name that does not exist.
# ---------------------------------------------------------------------------
T=$(mktree empty_family)
mkdir -p "$T/.claude/skills/skill-a" "$T/.claude/skills/skill-b"
: > "$T/.claude/agents/agent-a.md"; : > "$T/.claude/agents/agent-b.md"

: > "$CALL_LOG"
FAM="$T/family-empty-both.json"
printf '{"skills":[],"agents":[]}\n' > "$FAM"
run_argerr 2 "empty family: both arrays" "$T" --owner "$OWNER" --project "$NUM" --machine "$MACHINE" --repo "$REPO" --family "$FAM" --areas areas.json
grep -qF "empty skills[] array" <<<"$out" || report "empty family: expected the message to name skills[] (output: $out)"
grep -qE "ok +present in repo" <<<"$out" && report "empty family: the empty-string iteration must not report a spurious ok (output: $out)"
grep -qE "GAP +\.claude/agents/ missing" <<<"$out" && report "empty family: the empty-string iteration must not report a spurious GAP (output: $out)"
grep -qF "AUDIT: configured" <<<"$out" && report "empty family: must never report AUDIT: configured (output: $out)"
[ -s "$CALL_LOG" ] && report "empty family: expected zero gh calls, call log: $(cat "$CALL_LOG")"

: > "$CALL_LOG"
FAM="$T/family-empty-agents.json"
printf '{"skills":["skill-a"],"agents":[]}\n' > "$FAM"
run_argerr 2 "empty family: agents only" "$T" --owner "$OWNER" --project "$NUM" --machine "$MACHINE" --repo "$REPO" --family "$FAM" --areas areas.json
grep -qF "empty agents[] array" <<<"$out" || report "empty family (agents): expected the message to name agents[] (output: $out)"
[ -s "$CALL_LOG" ] && report "empty family (agents): expected zero gh calls, call log: $(cat "$CALL_LOG")"

# ---------------------------------------------------------------------------
# 6. Write-verb refusal: the mock rejects a verb it does not model.
# ---------------------------------------------------------------------------
: > "$CALL_LOG"
set +e
MOCK_GH_CALL_LOG="$CALL_LOG" MOCK_ACTIVE=1 PATH="$BIN:$PATH" gh api -X DELETE "repos/$REPO" >/dev/null 2>&1
rc=$?
set -e
[ "$rc" -ne 0 ] || report "mock gh: expected DELETE to be refused"

# ---------------------------------------------------------------------------
# 7. Drift assertion: the real, shipped family.json lists EXACTLY the
#    directories under .claude/skills/ and the files under .claude/agents/
#    in this repository, right now.
# ---------------------------------------------------------------------------
want_skills=$(find "$REPO_ROOT/.claude/skills" -mindepth 1 -maxdepth 1 -type d -printf "%f\n" | sort)
have_skills=$(jq -r '.skills[]' "$REPO_FAMILY" | sort)
[ "$want_skills" = "$have_skills" ] || report "family.json skills[] drift: want [$want_skills] have [$have_skills]"
want_agents=$(cd "$REPO_ROOT/.claude/agents" && find . -maxdepth 1 -type f -printf '%f\n' | sort)
have_agents=$(jq -r '.agents[]' "$REPO_FAMILY" | sort)
[ "$want_agents" = "$have_agents" ] || report "family.json agents[] drift: want [$want_agents] have [$have_agents]"

# ---------------------------------------------------------------------------
# UNMOCKED-CONTEXT tripwire: never appears in any call log produced above.
# ---------------------------------------------------------------------------
if grep -q 'UNMOCKED-CONTEXT' "$CALL_LOG" 2>/dev/null; then
  report "UNMOCKED-CONTEXT appeared in the call log — a call reached the mock without harness env"
fi

if [ "$fail" -eq 0 ]; then
  echo "test_audit.sh: ok"
  exit 0
else
  exit 1
fi
