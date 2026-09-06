#!/usr/bin/env bash
# post-comment.sh — post (or edit) an issue/PR comment strictly from a body
# FILE, and prove via read-back that GitHub stored the file's contents and
# not the literal "@path" argument. Guards the failure mode recorded in
# failure-modes.md: `gh … --body "@file"` does not read the file — only
# `--body-file` (or `gh api -F body=@file`) does — so `gh` silently posts
# the ~100-byte path string and reports success with a normal comment URL.
# That has now recurred three times (issues #375, #479, and #479's own
# third-occurrence comment) despite the rule being documented in six files;
# this script is the mechanical guard instead of a seventh prose reminder.
#
# Usage: post-comment.sh <issue-or-pr-number> <body-file> [--repo owner/name]
#                         [--edit <comment-id>]
#
# Contract:
#   1. Refuses (before any write) a body file that does not exist, is
#      empty, or whose ENTIRE contents, trimmed, are a bare `@`-prefixed
#      path-shaped token (`^@\S+$`, no whitespace anywhere) — the exact
#      symptom a mis-typed `--body "@file"` invocation would itself
#      produce, so a caller who accidentally names the placeholder string
#      as "the body file" is caught here too, not just downstream. The
#      test is whole-body, never first-line: a body that legitimately
#      starts with an `@mention` is NOT refused, whether the mention is
#      followed by more text on the same line (`@user please re-check`) or
#      stands alone on line 1 with the message beneath it (issue #479's
#      AC — "a comment body consisting only of an `@`-prefixed path" — and
#      its Risks section). A leading UTF-8 BOM is stripped before this
#      match on both the pre-write and read-back sides (issue #569 item 2)
#      — no caller in this repo produces a BOM-prefixed body, so this only
#      closes a hardening gap, not an observed defect.
#   2. Posts with `gh api -X POST repos/<repo>/issues/<n>/comments
#      -F body=@<file>` (new comment) or, with --edit, `-X PATCH
#      repos/<repo>/issues/comments/<id>` (edit in place) — always
#      `-F body=@<file>`, never `--body "@<file>"`. Only the call's stdout
#      is captured as the API response; stderr (e.g. gh's own update
#      notices) never gets folded in and cannot corrupt the JSON parse.
#   2a. With --edit, the response's `issue_url` is compared against the
#       mandatory `<issue-or-pr-number>` argument: comment ids are
#       repo-global, so an id belonging to a different issue/PR is caught
#       here (after the PATCH — the earliest point the id's true owner is
#       knowable from a single API round trip) rather than silently
#       succeeding. This check is SKIPPED, not failed closed, when the
#       response's `issue_url` yields no parseable numeric tail (issue
#       #569 item 4): the PATCH has already happened by this point, and
#       GitHub has never been observed to return an `issue_url` in any
#       shape other than `.../issues/<n>`. On this skip path the caller
#       gets an ordinary success — the comment URL only, exit 0 —
#       byte-for-byte indistinguishable from a run where ownership WAS
#       confirmed; that is the accepted trade-off being made here, not a
#       risk the success path already covers by some other means. Failing
#       closed instead would turn a response shape nobody has seen into a
#       cost for every caller: callers using the plain two-argument
#       `<issue-or-pr> <body-file>` form never pass `--edit` and so never
#       reach this check at all, while the few callers that do pass
#       `--edit` would gain a new failure mode for a shape that has never
#       been observed, for no offsetting benefit. Deliberate, not an
#       oversight.
#   3. Reads the posted/edited comment back via one GET and fails — a
#      distinct exit code, message naming the comment URL — if the whole
#      stored body, trimmed, is a bare `@`-prefixed token or if it does
#      not begin with the file's own first line. This is the actual guard:
#      it catches the defect even if some future call site re-introduces
#      the wrong flag by construction. As with the write calls, only the
#      GET's stdout is captured; its stderr is kept separate so a `gh`
#      notice can never be compared as if it were the stored body.
#   4. Prints the comment's html_url on success, nothing else on stdout.
#
# No repository- or owner-specific nouns appear in this script; the target
# repo comes from --repo or, failing that, `gh repo view` on the current
# checkout or, failing THAT, the checkout's own `git remote get-url origin`
# parsed to `owner/name` (issue #680): `gh repo view` uses GraphQL, and a
# transient GraphQL-only rate limit can fail it while `gh api` REST calls —
# including this script's own POST/PATCH/GET — still work, and while the
# checkout's git remote answers the same question offline. The remote
# fallback is strictly LOWER precedence than both `--repo` and `gh repo
# view`, never higher: a fork or a foreign worktree's remote can name a
# different repo than the one actually being operated on, so it is only
# consulted once the higher-precedence sources have both been tried and
# both have failed. When every source fails, the error names each one that
# was tried.
#
# Exit codes: 2 = argument error. 1 = a `gh api` call (post/edit or the
# read-back GET) failed outright. 3 = the pre-write file guard refused (missing,
# empty, or a whole body that is a bare `@`-prefixed token) — distinct from 2
# because the arguments themselves were well-formed, only the file content was
# not. 4 = the read-back guard fired: the comment was posted/edited but its
# stored body does not match what was sent — this is the defect this script
# exists to catch, so it gets its own code rather than folding into 1. 5 = the
# post/edit call succeeded (exit 0) but its response body could not be parsed as
# JSON, or lacked `.id`/`.html_url` — distinct from 4 so a malformed response is
# never mistaken for the read-back guard firing. 6 = `--edit` targeted a comment
# id that does not belong to `<issue-or-pr-number>` — the PATCH already
# happened; this reports the mismatch rather than silently succeeding against
# the wrong thread.
set -euo pipefail

die(){ echo "post-comment: $*" >&2; exit 1; }
argerr(){ echo "post-comment: $*" >&2; exit 2; }
refuse(){ echo "post-comment: $*" >&2; exit 3; }
guardfail(){ echo "post-comment: $*" >&2; exit 4; }
malformed(){ echo "post-comment: $*" >&2; exit 5; }
edit_mismatch(){ echo "post-comment: $*" >&2; exit 6; }

# ---------------------------------------------------------------------------
# Helpers for the bare-`@`-token guard (contract points 1 and 3). No step
# here pipes a producer into a consumer that can exit early (e.g.
# `printf … | head`) — every read is either a whole-file command
# substitution or a parameter expansion, so there is no SIGPIPE to race
# with `pipefail` (round-1 review finding 2).
# ---------------------------------------------------------------------------
trim_ws(){ # $1 = a line; prints it with leading/trailing whitespace removed
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

strip_leading_boms(){ # $1 = a whole string; prints it with every leading
  # UTF-8 BOM (EF BB BF) removed, in one linear pass. Issue #636: a
  # byte-at-a-time `while` loop doing `t="${t#$BOM}"` per iteration is
  # O(n^2) in the number of leading BOMs — each iteration re-copies the
  # entire remainder of the string — measured at 241 ms for 1,000 leading
  # BOMs, 5.8 s for 5,000, and 110 s for 21,845 (GitHub's max comment
  # body, all BOM). A single anchored `(BOM)+` removal, done once via GNU
  # sed's regex engine rather than by repeated bash substring copies, is
  # linear in the input size regardless of how many BOMs lead it.
  #
  # Note the anchoring: `sed` applies `^` per LINE, so this strips a BOM
  # leading ANY line of a multi-line body, not only the string's first.
  # That differs from the bash loop it replaced, but only ever in the
  # stricter direction — removing BOM bytes can never turn a matching
  # bare-`@`-token body into a non-matching one, so no refusal is missed.
  LC_ALL=C sed -E 's/^(\xEF\xBB\xBF)+//' <<<"$1"
}

body_is_bare_at_token(){ # $1 = a WHOLE body; true if trimmed it is ^@[^space]+$
  # Deliberately a whole-body test, not a first-line test (#479's AC: "a
  # comment body consisting ONLY of an `@`-prefixed path"; its Risks
  # section: match the whole-body single-token shape "or the guard will
  # false-positive on a one-line mention"). Because the character class
  # excludes every whitespace character INCLUDING newline, and bash's `=~`
  # anchors ^ and $ to the whole string rather than to each line, a body of
  # `@user\nplease re-check\n` cannot match: the trimmed string still
  # holds an embedded newline. The `--body "@file"` slip this guards always
  # produces a body that is exactly the path token and nothing else, so
  # nothing real is lost by the narrowing.
  #
  # A leading UTF-8 BOM (EF BB BF) is stripped BEFORE trimming, and
  # repeatedly (issue #569 item 2 / round-1 review finding 1): `trim_ws`
  # only removes POSIX whitespace, and the BOM is neither whitespace nor
  # `@`, so trimming first would leave a BOM sitting in front of whatever
  # whitespace follows it and stop `trim_ws` right there — a BOM plus
  # padding (spaces, tabs, ...) or a doubled BOM would then still evade
  # the match on both the pre-write side (this function called on the
  # file's own contents) and the read-back side (this same function
  # called on the stored body) alike, since both funnel through this one
  # predicate. Stripping every leading BOM first, then trimming, closes
  # both shapes.
  local t="$1"
  t="$(strip_leading_boms "$t")"
  t="$(trim_ws "$t")"
  [[ "$t" =~ ^@[^[:space:]]+$ ]]
}

# ---------------------------------------------------------------------------
# Repo-resolution fallback helper (issue #680). Parses a git remote URL
# (SSH `git@host:owner/name.git`, `ssh://[user@]host/owner/name.git`, or
# HTTPS `https://host/owner/name.git`) down to `owner/name`. Prints nothing
# on a shape it does not recognize, so the caller can tell "parsed to
# nothing usable" apart from a real result without a separate exit code.
# ---------------------------------------------------------------------------
repo_from_remote_url(){ # $1 = a git remote URL; prints owner/name or nothing
  local url="$1" rest=""
  case "$url" in
    git@*:*) rest="${url#*:}" ;;
    ssh://*) rest="${url#ssh://*/}" ;;
    https://*|http://*) rest="${url#*://}"; rest="${rest#*/}" ;;
    *) rest="" ;;
  esac
  rest="${rest%.git}"
  case "$rest" in
    */*/*|*/) rest="" ;; # more than one slash, or a trailing slash: not owner/name
  esac
  printf '%s' "$rest"
}

NUMBER=""; FILE=""; REPO=""; EDIT_ID=""
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="${2:?--repo needs a value}"; shift 2 ;;
    --edit) EDIT_ID="${2:?--edit needs a value}"; shift 2 ;;
    -*) argerr "unknown flag $1" ;;
    *)
      if [ -z "$NUMBER" ]; then NUMBER="$1";
      elif [ -z "$FILE" ]; then FILE="$1";
      else argerr "unexpected extra argument $1"; fi
      shift ;;
  esac
done
[ -n "$NUMBER" ] || argerr "usage: post-comment.sh <issue-or-pr-number> <body-file> [--repo owner/name] [--edit <comment-id>]"
[ -n "$FILE" ] || argerr "usage: post-comment.sh <issue-or-pr-number> <body-file> [--repo owner/name] [--edit <comment-id>]"
case "$NUMBER" in ''|*[!0-9]*) argerr "<issue-or-pr-number> must be a positive integer, got: $NUMBER" ;; esac
if [ -n "$EDIT_ID" ]; then
  case "$EDIT_ID" in ''|*[!0-9]*) argerr "--edit must be a positive integer comment id, got: $EDIT_ID" ;; esac
fi

# ---------------------------------------------------------------------------
# Repo resolution (issue #680). Precedence, highest first: explicit --repo;
# `gh repo view` (GraphQL) on the current checkout; the checkout's own git
# remote `origin`, parsed to owner/name (REST-reachable even when GraphQL
# alone is rate-limited). The remote is never consulted ahead of the first
# two sources — see the header note above for why. TRIED accumulates the
# sources actually attempted so a total failure names all of them, not just
# the last.
# ---------------------------------------------------------------------------
if [ -z "$REPO" ]; then
  TRIED="'gh repo view'"
  REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null) || REPO=""
  if [ -z "$REPO" ]; then
    TRIED="$TRIED, git remote 'origin'"
    REMOTE_URL=$(git remote get-url origin 2>/dev/null) || REMOTE_URL=""
    [ -n "$REMOTE_URL" ] && REPO="$(repo_from_remote_url "$REMOTE_URL")"
  fi
  [ -n "$REPO" ] || die "could not resolve repo: tried $TRIED, none succeeded — pass --repo owner/name"
fi
OWNER="${REPO%%/*}"; NAME="${REPO#*/}"
[ -n "$OWNER" ] && [ -n "$NAME" ] && [ "$OWNER" != "$REPO" ] || argerr "--repo must be owner/name, got: $REPO"

# ---------------------------------------------------------------------------
# Pre-write file guard (contract point 1). Every refusal here happens BEFORE
# any `gh api` write call — the read that decides the outcome always comes
# first, same discipline as stamp-claim.sh's refuse-before-mutation.
# ---------------------------------------------------------------------------
[ -f "$FILE" ] || refuse "refusing: body file does not exist: $FILE"
[ -s "$FILE" ] || refuse "refusing: body file is empty: $FILE"
FIRST_LINE=$(head -n1 "$FILE")
FILE_BODY="$(cat "$FILE")"
if body_is_bare_at_token "$FILE_BODY"; then
  refuse "refusing: body file's entire contents are a bare '@'-prefixed path-shaped token (no whitespace, nothing else) — this is the exact symptom of a mis-typed --body \"@file\" argument being passed as the file itself: $FILE"
fi

# ---------------------------------------------------------------------------
# Post or edit (contract point 2). Always -F body=@<file> — never
# --body "@<file>". Only stdout is captured as the API response; stderr is
# captured separately so a benign gh stderr notice can never corrupt the
# JSON this script parses next (issue #520 item 1).
# ---------------------------------------------------------------------------
STDERR_TMP="$(mktemp "${TMPDIR:-/tmp}/post-comment-stderr.XXXXXX")"
trap 'rm -f "$STDERR_TMP"' EXIT

if [ -n "$EDIT_ID" ]; then
  if ! RESPONSE=$(gh api -X PATCH "repos/$REPO/issues/comments/$EDIT_ID" -F body=@"$FILE" 2>"$STDERR_TMP"); then
    die "PATCH repos/$REPO/issues/comments/$EDIT_ID failed: $(cat "$STDERR_TMP")"
  fi
else
  if ! RESPONSE=$(gh api -X POST "repos/$REPO/issues/$NUMBER/comments" -F body=@"$FILE" 2>"$STDERR_TMP"); then
    die "POST repos/$REPO/issues/$NUMBER/comments failed: $(cat "$STDERR_TMP")"
  fi
fi

if ! COMMENT_ID=$(printf '%s' "$RESPONSE" | jq -r '.id // empty' 2>/dev/null); then
  malformed "post/edit call succeeded but its response could not be parsed as JSON: $RESPONSE"
fi
if ! COMMENT_URL=$(printf '%s' "$RESPONSE" | jq -r '.html_url // empty' 2>/dev/null); then
  malformed "post/edit call succeeded but its response could not be parsed as JSON: $RESPONSE"
fi
[ -n "$COMMENT_ID" ] && [ -n "$COMMENT_URL" ] || malformed "post/edit response had no .id/.html_url: $RESPONSE"

# ---------------------------------------------------------------------------
# --edit target validation (contract point 2a, issue #520 item 3): comment
# ids are repo-global, so confirm the PATCHed comment actually belongs to
# the mandatory <issue-or-pr-number>. Skipped (not blocked) if the response
# carries no parseable issue number to check against — deliberate, not an
# oversight; see contract point 2a's header comment (issue #569 item 4) for
# why this stays a skip rather than failing closed.
# ---------------------------------------------------------------------------
if [ -n "$EDIT_ID" ]; then
  RESPONSE_ISSUE_URL=$(printf '%s' "$RESPONSE" | jq -r '.issue_url // empty' 2>/dev/null || true)
  RESPONSE_NUMBER="${RESPONSE_ISSUE_URL##*/}"
  case "$RESPONSE_NUMBER" in
    "$NUMBER") : ;;
    ''|*[!0-9]*) : ;;
    *) edit_mismatch "refusing: --edit $EDIT_ID targeted comment $COMMENT_ID, which belongs to issue/PR $RESPONSE_NUMBER, not the given $NUMBER: $COMMENT_URL" ;;
  esac
fi

# ---------------------------------------------------------------------------
# Read-back guard (contract point 3): a fresh GET, never trusting the
# post/edit response body alone — the defect this script exists to catch is
# GitHub silently storing something other than what was sent, so the proof
# has to come from reading it back, not from re-inspecting what was sent.
# ---------------------------------------------------------------------------
# Only the GET's stdout becomes $READBACK; its stderr goes to $STDERR_TMP,
# exactly as the POST/PATCH calls above do. Folding stderr in with `2>&1`
# would splice a benign `gh` notice (e.g. "A new release of gh is
# available") into the body being compared and fail the guard — exit 4,
# no URL printed — AFTER a comment was successfully posted (issue #520
# item 1, round-2 review finding 1).
READBACK=$(gh api "repos/$REPO/issues/comments/$COMMENT_ID" --jq '.body' 2>"$STDERR_TMP") \
  || die "read-back GET repos/$REPO/issues/comments/$COMMENT_ID failed: $(cat "$STDERR_TMP")"

if body_is_bare_at_token "$READBACK"; then
  guardfail "read-back guard fired on $COMMENT_URL — the entire stored body is a bare '@'-prefixed path-shaped token (the literal-path posting defect): $READBACK"
fi
READBACK_FIRST_LINE=${READBACK%%$'\n'*}
[ "$READBACK_FIRST_LINE" = "$FIRST_LINE" ] \
  || guardfail "read-back guard fired on $COMMENT_URL — stored body's first line does not match the file's first line. File: $FIRST_LINE | Stored: $READBACK_FIRST_LINE"

# ---------------------------------------------------------------------------
# Success (contract point 4).
# ---------------------------------------------------------------------------
printf '%s\n' "$COMMENT_URL"
