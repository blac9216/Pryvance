#!/usr/bin/env bash
# check-test-steps.sh — READ-ONLY. Pure git ancestry, nothing else: the
# `NAMES`/`PATTERNS` phrase-matching arrays that used to hold a PR body's
# **Suggested Test Steps** section to a wording list (moving-ref shapes like
# `origin/…`, `@{u}`, `HEAD~n`) were interpretation of prose and were removed
# per the 2026-09-05 owner ruling on #732 (item 4) — issue #752 implements
# that removal. `--check-shas` is unchanged by it: it never read that wording
# list, only git plumbing, and stays opt-in exactly as before. Without
# `--check-shas` this script now checks nothing at all and always exits 0 —
# there is no non-interpretive check left to run by default; the caller
# passes `--check-shas` to get the one that remains.
#
# Usage: check-test-steps.sh <pr> [--repo owner/name] [--body-file <path>]
#                             [--check-shas [--head <ref>]]
#
# Contract: GET-only (never a write verb) — one read, `gh api repos/<repo>/pulls/<pr>`
# for the body. `--body-file` reads a body from local disk instead and issues no call at
# all, which is how an author checks a body before posting it.
#
# --check-shas (issue #640): a rebase or force-push mid-review moves the branch out
# from under the PR body without anything re-checking it — PR #615's `## Rollback`
# named a commit `git revert`-able before the round-1 force-push and unreachable after
# it, and nothing caught that before merge. With this flag, every 40-hex commit SHA
# named ANYWHERE in the body (not just a particular section — a stale SHA in Rollback
# or a mutation-probe summary is exactly what #640 was filed on) must be an ancestor of
# `--head <ref>` (default `HEAD`), checked locally with `git merge-base --is-ancestor`;
# this needs a real git checkout with the SHA and the head already fetched; it does not
# itself fetch anything, and it makes no `gh` call — same READ-ONLY, local-only contract
# as the rest of the script. `--head` is only meaningful with `--check-shas` and is
# rejected alone. A SHA that does not resolve to a commit object at all counts as
# unreachable too, reported the same way.
#
# Known limits, deliberately not chased further: any 40-hex token is treated as a
# candidate commit SHA, so a cross-repo permalink (a SHA valid in some OTHER repo's
# history, unresolvable in this checkout) and a non-commit 40-hex digest (a hash sum,
# not a git object) both read as an ordinary unreachable SHA rather than being told
# apart from one — the script has no repo identity to compare against in --body-file
# mode, and distinguishing "wrong kind of 40 hex characters" from "real but stale SHA"
# needs more than a local `git cat-file`. Abbreviated (short) SHAs are not checked at
# all — only exactly 40 hex characters match. The one shape narrowed explicitly: a
# GitHub blob permalink (`.../blob/<sha>/path`) is skipped, because it names a tree/blob
# object rather than an author's commit assertion, and because the shape a sibling PR's
# mutation-probe demonstration takes — a blob link to that PR's own pre-squash head SHA
# — turns permanently unreachable the moment the sibling is squash-merged, which is
# normal history hygiene, not staleness this check should flag.
#
# Output: one `STALE-SHA` line per unreachable SHA (with `--check-shas`), naming the
# body section that carries it, then a one-line summary. Exit 0 when `--check-shas` was
# not passed, or was passed and every SHA in the body is reachable (including the case
# where the body names none); 1 when at least one is not; 2 on an argument error
# (including an unreadable or nonexistent `--body-file`, `--head` without
# `--check-shas`, `--check-shas` outside a git checkout, or perl absent — perl is
# required for `--check-shas`'s 40-hex-token extraction, which needs a per-match loop a
# `grep`/`sed` one-liner cannot express without also matching the wrong span for an
# adjacent blob-permalink occurrence).
#
# No repository- or owner-specific nouns appear in this script; the target repo comes
# from --repo or, failing that, `gh repo view` on the current checkout.
set -euo pipefail
export LC_ALL=C

die(){ echo "check-test-steps: $*" >&2; exit 1; }
argerr(){ echo "check-test-steps: $*" >&2; exit 2; }

# perl is required for --check-shas's 40-hex SHA extraction below (a
# per-match loop with per-occurrence blob-permalink narrowing) — checked
# unconditionally, before argument parsing decides whether --check-shas was
# even passed, same as the rest of this script's argument-independent guards.
command -v perl >/dev/null 2>&1 \
  || argerr "perl is required: --check-shas's 40-hex SHA extraction needs a per-match loop GNU sed cannot express"

PR=""; REPO=""; BODY_FILE=""; CHECK_SHAS=0; HEAD_REF=""
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="${2:?--repo needs a value}"; shift 2 ;;
    --body-file) BODY_FILE="${2:?--body-file needs a value}"; shift 2 ;;
    --check-shas) CHECK_SHAS=1; shift ;;
    --head) HEAD_REF="${2:?--head needs a value}"; shift 2 ;;
    -*) argerr "unknown flag $1" ;;
    *)
      [ -z "$PR" ] || argerr "unexpected extra argument $1"
      PR="$1"; shift ;;
  esac
done
[ "$CHECK_SHAS" -eq 1 ] || [ -z "$HEAD_REF" ] || argerr "--head is only meaningful with --check-shas"
[ -n "$HEAD_REF" ] || HEAD_REF="HEAD"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/check-test-steps.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# find_inaccessible_ancestor <path> -> prints the first ancestor directory
# that cannot be traversed (missing the execute/search bit), or nothing.
# `[ -e ]` returns false on EACCES exactly like it does on a genuinely
# missing path (issue #623) — an ancestor directory that is `chmod 000` makes
# every `-e`/`-r`/`-x` test on the path below it fail the same way a
# nonexistent path would, so a bare failed `-e` on one level can never be
# trusted as "this level is genuinely absent": the real culprit may be a
# GRANDparent (or higher) still further up, itself present but unexecutable,
# which is exactly what makes every level beneath it fail `-e` too. The walk
# therefore never returns on a failed `-e` alone — it keeps climbing past it
# — and only concludes genuine absence when it reaches the real filesystem
# root without ever finding a present-but-unexecutable ancestor.
find_inaccessible_ancestor(){
  local path="$1" dir parent
  dir=$(dirname -- "$path")
  while :; do
    if [ -e "$dir" ] && [ ! -x "$dir" ]; then
      printf '%s' "$dir"
      return 0
    fi
    [ "$dir" != "/" ] && [ "$dir" != "." ] || return 1
    parent=$(dirname -- "$dir")
    [ "$parent" != "$dir" ] || return 1
    dir="$parent"
  done
}

if [ -n "$BODY_FILE" ]; then
  # `-e`/`-r` rather than `-f`: an author checking a body legitimately passes
  # /dev/null or a process substitution (`--body-file <(gh api …)`), and a `-f`
  # test rejects both — a character device and a fifo are not regular files — so
  # the run dies on the argument guard for a reason that has nothing to do with
  # the body it was handed. A genuinely absent path keeps its own diagnostic,
  # separate from a path that exists but cannot be read. A directory satisfies
  # both `-e` and `-r` too, so it needs its own explicit rejection — otherwise
  # control reaches the unguarded `cp` below, which fails under `set -e` and
  # exits 1 (the findings code) instead of 2 (an argument error).
  if [ ! -e "$BODY_FILE" ]; then
    BLOCKED=$(find_inaccessible_ancestor "$BODY_FILE") || BLOCKED=""
    if [ -n "$BLOCKED" ]; then
      argerr "--body-file is under an unreadable directory ($BLOCKED), cannot tell whether it exists: $BODY_FILE"
    fi
    argerr "--body-file does not exist: $BODY_FILE"
  fi
  [ -r "$BODY_FILE" ] || argerr "--body-file is not readable: $BODY_FILE"
  [ ! -d "$BODY_FILE" ] || argerr "--body-file is a directory, not a body: $BODY_FILE"
  cp "$BODY_FILE" "$WORK/body.md"
  LABEL="$BODY_FILE"
else
  [ -n "$PR" ] || argerr "usage: check-test-steps.sh <pr> [--repo owner/name] [--body-file <path>] [--check-shas [--head <ref>]]"
  case "$PR" in ''|*[!0-9]*) argerr "<pr> must be a positive integer, got: $PR" ;; esac
  [ -n "$REPO" ] || REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null) \
    || die "could not resolve --repo and 'gh repo view' failed — pass --repo owner/name"
  gh api "repos/$REPO/pulls/$PR" --jq '.body // ""' > "$WORK/body.md" 2>"$WORK/pr.err" \
    || die "GET repos/$REPO/pulls/$PR failed: $(cat "$WORK/pr.err")"
  LABEL="PR #$PR ($REPO)"
fi

found=0

# ---------------------------------------------------------------------------
# --check-shas (issue #640): every 40-hex SHA named ANYWHERE in the body —
# the only check this script performs since the NAMES/PATTERNS moving-ref
# check was removed (issue #752) — must be an ancestor of --head (default
# HEAD). Skipped entirely, with no findings at all, when the flag is absent.
# ---------------------------------------------------------------------------
if [ "$CHECK_SHAS" -eq 1 ]; then
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || argerr "--check-shas requires running inside a git checkout to test SHA reachability"
  git rev-parse --verify "${HEAD_REF}^{commit}" >/dev/null 2>&1 \
    || argerr "--head $HEAD_REF does not resolve to a commit in this checkout"

  # Nearest-preceding-heading map, one line of output per input line (NR
  # aligned). Deliberately fence-blind: a SHA inside a fenced Rollback
  # command (`git revert <sha>`) still names a real commit and must still be
  # checked, so a `#` inside a fence is allowed to end a "section" here — the
  # worst case is a slightly wrong section label on the report line, never a
  # missed SHA. Heading depth is counted by hand rather than matched with a
  # `{1,6}` interval: `mawk` is the default `awk` on Debian-family images and
  # does not implement interval expressions.
  awk '
    /^#/ {
      n = 0
      while (n < length($0) && substr($0, n + 1, 1) == "#") n++
      if (n >= 1 && n <= 6 && substr($0, n + 1, 1) == " ") {
        title = substr($0, n + 1)
        sub(/^ +/, "", title); sub(/ +$/, "", title)
        section = title
      }
    }
    { print (section == "" ? "(preamble)" : section) }
  ' "$WORK/body.md" > "$WORK/line-sections.txt"

  # 40-hex tokens only: `{40,}` (not `{40}`) so a longer hex run (e.g. a
  # SHA-256) is read in full and then rejected by the exact-length check
  # below, rather than a bare `{40}` silently matching its first 40 characters
  # as if that were a real, standalone SHA.
  #
  # The blob-permalink skip below is scoped to the OCCURRENCE, not the line:
  # extracted here with perl's `\G`/`pos()` per-match loop rather than a
  # line-level `grep`, because a `case "$fullline" in *"/blob/$sha"*)` test
  # (an earlier shape) matches the instant a `/blob/<sha>` substring
  # appears ANYWHERE on the line, silently suppressing every OTHER
  # occurrence of that same SHA on the line too — including a genuine
  # `.../commit/<sha>` assertion sitting right next to it. A GitHub blob
  # permalink (`.../blob/<sha>/path...`) names a tree/blob object, not a
  # commit the author asserted survives rebase — the one shape guaranteed to
  # appear opted-in on THIS repo's own PRs (a mutation-probe demonstration
  # linking to a sibling PR's pre-squash head reads that head's SHA in a
  # blob URL, and squashing the sibling makes it unreachable by design, not
  # staleness) — so only a match whose immediately preceding six characters
  # are literally `/blob/` is skipped; a commit permalink or a bare SHA in
  # prose, even sharing a line with a blob permalink of the very same SHA,
  # is unaffected and still checked below.
  while IFS=: read -r shaline shatext; do
    [ "${#shatext}" -eq 40 ] || continue
    section=$(sed -n "${shaline}p" "$WORK/line-sections.txt")
    [ -n "$section" ] || section="(preamble)"
    if ! git cat-file -e "${shatext}^{commit}" 2>/dev/null \
       || ! git merge-base --is-ancestor "$shatext" "$HEAD_REF" 2>/dev/null; then
      printf 'STALE-SHA %s: %s is not reachable from %s\n' "$section" "$shatext" "$HEAD_REF"
      found=$((found + 1))
    fi
  done < <(perl -ne '
    my $n = $.;
    while (/[0-9a-fA-F]{40,}/g) {
      my $start = $-[0];
      my $match = $&;
      my $prefix = substr($_, 0, $start);
      next if $prefix =~ m{/blob/\z};
      print "$n:$match\n";
    }
  ' "$WORK/body.md")
fi

if [ "$found" -eq 0 ]; then
  if [ "$CHECK_SHAS" -eq 1 ]; then
    echo "check-test-steps: $LABEL — every SHA in the body is reachable from $HEAD_REF"
  else
    echo "check-test-steps: $LABEL — no check performed (pass --check-shas to verify SHA reachability)"
  fi
  exit 0
fi
echo "check-test-steps: $LABEL — $found finding(s): a body SHA unreachable from $HEAD_REF; a rebase or force-push mid-review must not leave a stale SHA behind" >&2
exit 1
