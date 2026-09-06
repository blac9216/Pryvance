#!/usr/bin/env bash
# process-docs.sh — scaffold docs/process/*.md from the skill's templates.
# Every repo-specific value is a flag; an omitted flag leaves its {{MARKER}}
# in place for the agent/owner to fill, exactly like an unfilled <owner: …>
# marker. Never overwrites an existing file (use --force to replace one).
# Makes no `gh` call and reads no file outside templates/ and --areas.
# Usage: process-docs.sh [--project-title <title>] [--project-url <url>]
#   [--unit-cmd <cmd>] [--lint-cmd <cmd>] [--worktree-root <path>]
#   [--reviewer <login|none>] [--archive <owner/repo|none>]
#   [--areas <file>] [--dir docs/process] [--force <file>]
# Exit codes: 0 wrote/kept every template; 2 bad usage or a malformed
# --areas file; 3 missing dependency (_lib.sh). Class: writer (creates
# docs/process/*.md; never touches anything else).
# shellcheck disable=SC2034 # consumed by _lib.sh when sourced, not here
LIB_SKIP_GH=1
source "$(dirname "$0")/_lib.sh"
PROJECT_TITLE=""; PROJECT_URL=""; UNIT_CMD=""; LINT_CMD=""; WORKTREE_ROOT=""
REVIEWER=""; ARCHIVE=""; AREAS=""; DIR="docs/process"; FORCE=""
while [ $# -gt 0 ]; do case $1 in
  --project-title) PROJECT_TITLE=$2; shift 2;;
  --project-url) PROJECT_URL=$2; shift 2;;
  --unit-cmd) UNIT_CMD=$2; shift 2;;
  --lint-cmd) LINT_CMD=$2; shift 2;;
  --worktree-root) WORKTREE_ROOT=$2; shift 2;;
  --reviewer) REVIEWER=$2; shift 2;;
  --archive) ARCHIVE=$2; shift 2;;
  --areas) AREAS=$2; shift 2;;
  --dir) DIR=$2; shift 2;;
  --force) FORCE=$2; shift 2;;
  *) say "unknown arg $1"; exit 2;;
esac; done
T="$HERE/../templates/process"; mkdir -p "$DIR"

# --areas: the same JSON shape labels.sh takes — rendered here as
# labels.md's table rows. Optional: omitted leaves {{AREA_ROWS}} in place.
area_rows=""
if [ -n "$AREAS" ]; then
  [ -f "$AREAS" ] || { say "--areas file not found: $AREAS"; exit 2; }
  validate_areas "$AREAS" || exit 2
  area_rows=$(jq -r '.[] | "| \(.name) | \(.color) | \(.description) |"' "$AREAS")
fi

# esc: escape a replacement value for use on the RHS of a sed s|…|…| expression
# (backslash, & and the | delimiter all need protecting so untrusted-shaped values — e.g. a
# Project title containing "|" or "&" — cannot corrupt or reinterpret the substitution).
esc(){ printf '%s' "$1" | sed -e 's/[\&|]/\\&/g'; }
# awk_esc: escape a replacement value passed to awk's gsub(regex, replacement, …) — gsub
# treats a bare & in the replacement as "insert the matched text", so a literal & (or \)
# in the area-rows table must be backslash-escaped first, or it silently expands to the
# matched {{MARKER}} instead of rendering literally. The escaped value reaches awk through
# ENVIRON, never `-v`: awk runs its own escape-sequence processing on -v assignments before
# the program starts, which would strip exactly the backslash layer this adds
# (`awk -v x='a\\b' 'BEGIN{print length(x)}'` prints 3, not 4). ENVIRON is verbatim.
awk_esc(){ printf '%s' "$1" | sed -e 's/\\/\\\\/g; s/&/\\\&/g'; }

reviewer_text=""
case "$REVIEWER" in
  "") ;;
  none) reviewer_text="none — single account; the review comment plus the merge are the verdict of record";;
  *) reviewer_text="$REVIEWER via GH_TOKEN; native reviews required by the ruleset";;
esac
archive_text=""
case "$ARCHIVE" in
  "") ;;
  none) archive_text="none — session logs stay scratch-only";;
  *) archive_text="$ARCHIVE";;
esac

title_e=$(esc "$PROJECT_TITLE"); url_e=$(esc "$PROJECT_URL")
unit_e=$(esc "$UNIT_CMD"); lint_e=$(esc "$LINT_CMD"); wt_e=$(esc "$WORKTREE_ROOT")
reviewer_e=$(esc "$reviewer_text"); archive_e=$(esc "$archive_text")
rows_e=$(awk_esc "$area_rows")

render(){
  local sed_prog=""
  [ -n "$PROJECT_TITLE" ] && sed_prog+="s|{{PROJECT_TITLE}}|$title_e|; "
  [ -n "$PROJECT_URL" ] && sed_prog+="s|{{PROJECT_URL}}|$url_e|; "
  [ -n "$UNIT_CMD" ] && sed_prog+="s|{{UNIT_CMD}}|$unit_e|; "
  [ -n "$LINT_CMD" ] && sed_prog+="s|{{LINT_CMD}}|$lint_e|; "
  [ -n "$WORKTREE_ROOT" ] && sed_prog+="s|{{WORKTREE_ROOT}}|$wt_e|; "
  [ -n "$REVIEWER" ] && sed_prog+="s|{{REVIEWER_IDENTITY}}|$reviewer_e|; "
  [ -n "$ARCHIVE" ] && sed_prog+="s|{{SESSION_LOG_ARCHIVE}}|$archive_e|; "
  # fixed substitutions unaffected by this refactor: never detected, never a flag
  sed_prog+="s|{{UNIT_ENV}}||; s|{{INTEGRATION_CMD}}|<owner>|; s|{{INTEGRATION_ENV}}|<owner>|; s|{{COVERAGE_CMD}}|<owner>|; s|{{COVERAGE_GATE}}|80% and no regression vs base|; s|{{SANITIZE_CMD}}|<owner>|; s|{{PENDING_LIVE_THRESHOLD}}|5|; s|{{SCRATCH_DIR}}|<owner>|; s|{{TEST_PREFIX}}|<owner>|; s|{{LOAD_MAX}}|<owner>|; s|{{MEM_MIN_PCT}}|10|; s|{{DISK_DELTA_GB}}|5|; s|{{SEQUENCE_RESOURCES}}|<owner: e.g. numbered migrations — or none>|"
  if [ -n "$AREAS" ]; then
    sed -e "$sed_prog" | ROWS="$rows_e" awk 'BEGIN{r=ENVIRON["ROWS"]} {gsub(/\{\{AREA_ROWS\}\}/,r); print}'
  else
    sed -e "$sed_prog"
  fi
}
for f in "$T"/*.md; do b=$(basename "$f"); out="$DIR/$b"
  if [ -e "$out" ] && [ "$FORCE" != "$b" ]; then say "keep    $out (exists)"; continue; fi
  render < "$f" > "$out"; say "wrote   $out"; done
say "next: fill every <owner: …> marker and {{…}} left in $DIR (audit.sh fails on them); then labels.sh"
