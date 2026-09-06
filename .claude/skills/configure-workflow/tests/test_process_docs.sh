#!/usr/bin/env bash
# test_process_docs.sh — fixture-driven regression test for process-docs.sh
# (#781). Follows the harness conventions in github-workflow/tests/README.md
# (fixtures in a private mktemp dir, `report()`/fail-counter, the
# UNMOCKED-CONTEXT tripwire) with one deliberate difference: every fixture
# run below executes process-docs.sh under a **hermetic toolbox PATH that
# resolves no `gh` at all** — symlinks to exactly the bash/coreutils/jq/awk/
# sed binaries the script and _lib.sh call (plus `bash` itself, since `env
# bash` on the shebang line still resolves through PATH), built fresh from
# the real PATH at suite start, and nothing else. That is the strongest
# available proof of the script's contract (it never shells out to `gh` and
# reads no file outside `templates/` and its own `--areas` file): a
# `command -v gh` tripwire binary placed earlier on PATH would still
# satisfy _lib.sh's `need gh` gate without ever running, which is exactly
# why an earlier revision of this suite could not detect `LIB_SKIP_GH=1`
# being deleted from process-docs.sh — `need gh` passed on the tripwire's
# mere presence, so the deletion never surfaced as a run-time failure. A
# separate case below (`no_gh_opt_out`) additionally runs the tripwire PATH
# so a regression that starts calling `gh` is still named by
# UNMOCKED-CONTEXT, not left as a bare "command not found".
#
# Covers #781's Verification list:
#  - the script reads no file outside templates/ and --areas (mock/no-gh).
#  - each flag substitutes its marker; an omitted flag leaves {{MARKER}}
#    intact (fixture per flag).
#  - esc/awk_esc protections survive: a value containing |, & and \ renders
#    literally.
#  - --force <file> and the never-overwrite rule, with a fixture.
set -euo pipefail
export LANG=C LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROCESS_DOCS_SH="$SCRIPT_DIR/../scripts/process-docs.sh"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/process-docs-test.XXXXXX")"
cleanup(){ rm -rf "$WORK"; }
trap cleanup EXIT

BIN="$WORK/bin"
TOOLBOX="$WORK/toolbox"
OUT="$WORK/out"
mkdir -p "$BIN" "$TOOLBOX" "$OUT"

fail=0
report(){ echo "FAIL: $*" >&2; fail=1; }

# ---------------------------------------------------------------------------
# Hermetic toolbox: symlink in exactly the external binaries process-docs.sh
# and _lib.sh call (awk, basename, dirname, head, jq, mkdir, sed) from the real
# PATH, and nothing else — in particular, no `gh`, from anywhere. This is
# the load-bearing PATH below: with it, deleting `LIB_SKIP_GH=1` from
# process-docs.sh makes `_lib.sh`'s `need gh` gate fail for real (`command
# -v gh` finds nothing), instead of a tripwire binary silently satisfying
# the check without ever running.
# ---------------------------------------------------------------------------
for tool in awk basename bash dirname head jq mkdir sed; do
  tool_path=$(command -v "$tool") || { echo "FAIL: no '$tool' on the ambient PATH; cannot build the hermetic toolbox" >&2; exit 1; }
  ln -s "$tool_path" "$TOOLBOX/$tool"
done

# ---------------------------------------------------------------------------
# Tripwire `gh`: used only by the dedicated no_gh_opt_out case below, which
# runs with the tripwire on PATH to prove that a regression making
# process-docs.sh call `gh` is named loudly (UNMOCKED-CONTEXT) rather than
# only failing with a bare "command not found" under the hermetic toolbox.
# ---------------------------------------------------------------------------
cat > "$BIN/gh" <<'MOCKGH'
#!/usr/bin/env bash
: "${MOCK_GH_CALL_LOG:?MOCK_GH_CALL_LOG must be set}"
printf 'UNMOCKED-CONTEXT gh %s\n' "$*" >> "$MOCK_GH_CALL_LOG"
echo "mock gh: process-docs.sh must never call gh" >&2
exit 1
MOCKGH
chmod +x "$BIN/gh"

AREAS_GOOD="$WORK/areas-good.json"
cat > "$AREAS_GOOD" <<'JSON'
[{"name":"area:backend","color":"1d76db","description":"pipes | amps & back\\slashes"}]
JSON
AREAS_BAD="$WORK/areas-bad.json"
cat > "$AREAS_BAD" <<'JSON'
[{"name":"backend","color":"1d76db","description":"no prefix"}]
JSON

run_pd(){ # run_pd <label> <dir> <want_rc> <args…> — uses the hermetic, gh-free toolbox PATH
  local label="$1" dir="$2" want_rc="$3"; shift 3
  run_pd_on_path "$TOOLBOX" "$label" "$dir" "$want_rc" "$@"
}
run_pd_on_path(){ # run_pd_on_path <path> <label> <dir> <want_rc> <args…>
  local path="$1" label="$2" dir="$3" want_rc="$4"; shift 4
  mkdir -p "$dir"
  local rc=0
  set +e
  MOCK_GH_CALL_LOG="$OUT/$label.gh-calls.log" PATH="$path" \
    "$PROCESS_DOCS_SH" --dir "$dir" "$@" > "$OUT/$label.stdout.log" 2> "$OUT/$label.stderr.log"
  rc=$?
  set -e
  if [ "$rc" -ne "$want_rc" ]; then
    echo "--- stdout ($label) ---" >&2; cat "$OUT/$label.stdout.log" >&2 || true
    echo "--- stderr ($label) ---" >&2; cat "$OUT/$label.stderr.log" >&2 || true
    report "process-docs.sh ($label) exited $rc, expected $want_rc"
  fi
  if [ -f "$OUT/$label.gh-calls.log" ] && grep -q '^UNMOCKED-CONTEXT ' "$OUT/$label.gh-calls.log"; then
    report "$label: process-docs.sh called gh: $(grep -m1 '^UNMOCKED-CONTEXT ' "$OUT/$label.gh-calls.log")"
  fi
}

# --- no flags at all: every marker this issue names is left in place. ------
D1="$WORK/none"
run_pd none "$D1" 0
for pair in \
  "work-tracking.md:{{PROJECT_TITLE}}" \
  "work-tracking.md:{{PROJECT_URL}}" \
  "work-tracking.md:{{REVIEWER_IDENTITY}}" \
  "work-tracking.md:{{SESSION_LOG_ARCHIVE}}" \
  "testing.md:{{UNIT_CMD}}" \
  "testing.md:{{LINT_CMD}}" \
  "maintenance.md:{{WORKTREE_ROOT}}" \
  "labels.md:{{AREA_ROWS}}"; do
  f="${pair%%:*}"; marker="${pair##*:}"
  grep -qF -- "$marker" "$D1/$f" || report "none: expected $marker intact in $f"
done

# --- each flag, given, substitutes its own marker and no other. -------------
D2="$WORK/each"
run_pd each "$D2" 0 \
  --project-title 'Acme Board' \
  --project-url 'https://example.com/projects/1' \
  --unit-cmd 'make test' \
  --lint-cmd 'make lint' \
  --worktree-root '/srv/worktrees' \
  --reviewer none \
  --archive none \
  --areas "$AREAS_GOOD"
grep -qF 'Acme Board' "$D2/work-tracking.md" || report "each: PROJECT_TITLE not substituted"
grep -qF 'https://example.com/projects/1' "$D2/work-tracking.md" || report "each: PROJECT_URL not substituted"
grep -qxF '| Reviewer identity | none — single account; the review comment plus the merge are the verdict of record |' "$D2/work-tracking.md" \
  || report "each: --reviewer none did not render the single-account wording"
grep -qxF '| Session-log archive | none — session logs stay scratch-only |' "$D2/work-tracking.md" \
  || report "each: --archive none did not render the scratch-only wording"
grep -qF 'make test' "$D2/testing.md" || report "each: UNIT_CMD not substituted"
grep -qF 'make lint' "$D2/testing.md" || report "each: LINT_CMD not substituted"
grep -qF '/srv/worktrees' "$D2/maintenance.md" || report "each: WORKTREE_ROOT not substituted"
grep -qxF '| area:backend | 1d76db | pipes | amps & back\slashes |' "$D2/labels.md" \
  || report "each: AREA_ROWS did not render the area row literally (pipes/amps/backslash intact)"
# --project-title was given in this fixture, so the {{PROJECT_TITLE}} marker itself must be
# gone (not merely have "Acme Board" appear somewhere alongside a still-literal marker,
# which the positive grep above would not by itself rule out); D1 above is the fixture
# that covers the complementary case — a marker with no corresponding flag stays literal.
grep -qF '{{PROJECT_TITLE}}' "$D2/work-tracking.md" && report "each: PROJECT_TITLE should have been substituted, found the marker still literal"
true

# --- --reviewer <login> and --archive <owner/repo> render the login/repo path. ---
D3="$WORK/login"
run_pd login "$D3" 0 --reviewer someone --archive owner/logs
grep -qxF '| Reviewer identity | someone via GH_TOKEN; native reviews required by the ruleset |' "$D3/work-tracking.md" \
  || report "login: --reviewer <login> did not render the GH_TOKEN wording"
grep -qxF '| Session-log archive | owner/logs |' "$D3/work-tracking.md" \
  || report "login: --archive <owner/repo> did not render the repo path"

# --- esc/awk_esc: |, & and \ in a single-line flag value render literally. --
D4="$WORK/escapes"
run_pd escapes "$D4" 0 --project-title 'A | B & C \ D'
grep -qxF '| Project board | [A | B & C \ D #<owner: project number>]({{PROJECT_URL}}) — owner `<owner: login>`; automation account `<owner: login>` (admin) |' "$D4/work-tracking.md" \
  || report "escapes: |, & and \\ in --project-title did not render literally"

# --- --areas: malformed input exits 2 naming the defect, no files written. --
D5="$WORK/badareas"
run_pd badareas "$D5" 2 --areas "$AREAS_BAD"
grep -qF 'does not start with' "$OUT/badareas.stderr.log" || report "badareas: expected the defect named on stderr"
[ ! -e "$D5/labels.md" ] || report "badareas: labels.md should not have been written on a malformed --areas file"

# --- --force / never-overwrite: a pre-existing file is kept unless named by
# --- --force, and --force replaces only that one file. ----------------------
D6="$WORK/force"
mkdir -p "$D6"
echo 'PRE-EXISTING' > "$D6/labels.md"
echo 'PRE-EXISTING-2' > "$D6/testing.md"
run_pd force_keep "$D6" 0 --areas "$AREAS_GOOD"
grep -qxF 'PRE-EXISTING' "$D6/labels.md" || report "force_keep: existing labels.md was overwritten without --force"
grep -qF 'keep    ' "$OUT/force_keep.stdout.log" || grep -qF 'keep    ' "$OUT/force_keep.stderr.log" \
  || report "force_keep: expected a 'keep' line naming the untouched file"
run_pd force_replace "$D6" 0 --areas "$AREAS_GOOD" --force labels.md
grep -qxF 'PRE-EXISTING' "$D6/labels.md" && report "force_replace: --force labels.md should have replaced the file"
grep -qxF 'PRE-EXISTING-2' "$D6/testing.md" || report "force_replace: --force labels.md must not touch testing.md"

# --- secondary safety net: with the logging tripwire on PATH ahead of the
# --- hermetic toolbox, a regression that starts calling gh is still named
# --- by UNMOCKED-CONTEXT, not left as a bare "command not found". ----------
D7="$WORK/no_gh_opt_out"
run_pd_on_path "$BIN:$TOOLBOX" no_gh_opt_out "$D7" 0 --areas "$AREAS_GOOD"

if [ "$fail" -ne 0 ]; then
  echo "test_process_docs: FAILED" >&2
  exit 1
fi

echo "test_process_docs: all assertions passed"
