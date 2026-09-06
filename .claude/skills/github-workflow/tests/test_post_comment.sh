#!/usr/bin/env bash
# test_post_comment.sh — fixture-driven regression test for post-comment.sh.
# Follows the mock-`gh` harness conventions in tests/README.md: a mocked
# `gh` binary on PATH serves fixture state from a private mktemp scratch
# dir, and no real network call is ever reachable. Pinned to LANG=C /
# LC_ALL=C.
#
# post-comment.sh is a WRITER (POST/PATCH a comment) but its whole purpose
# is the read-back GUARD after the write, so the mock here does double
# duty: it behaves like the real GitHub API on the happy path (storing
# whatever `-F body=@<file>` actually read off disk), AND, when
# MOCK_GH_STORE_LITERAL=1, reproduces the literal-path-posting defect this
# script exists to catch — storing the raw "@<path>" argument instead of
# reading the file — so the read-back guard can be proven to fire on
# exactly that shape (issue #479's own three real-world occurrences). It
# also tracks which issue/PR number each comment id was created against
# (issue #520 item 3), can inject benign stderr noise alongside a valid
# response (#520 item 1), and can return non-JSON on POST (#520 item 1).
#
# Covers (per issue #479's Acceptance Criteria / Suggested Test Steps, plus
# #479 round-1 review findings 1 and 2, plus issue #520 items 1, 3, 4):
#  - success: POST a real file, read-back matches, exit 0, prints the
#    comment's html_url and nothing else on stdout.
#  - missing body file: exit 3, refusal message names the path, ZERO gh
#    api calls issued (proven via calls.log — the refuse-before-any-call
#    contract, same discipline as stamp-claim.sh).
#  - empty body file: exit 3, zero gh api calls.
#  - a body file whose WHOLE contents are a bare `@`-prefixed single token:
#    exit 3, zero gh api calls (this is the *pre-write* guard, distinct
#    from the read-back guard below). Covers both a trailing-newline body
#    and a no-trailing-newline one, and re-runs #479's three historical
#    occurrences through it verbatim. Also covers a whitespace-padded token
#    (pins `trim_ws`, issue #569 item 1) and a BOM-prefixed token (pins the
#    BOM strip, issue #569 item 2), both pre-write and read-back.
#  - an `@mention`-leading body is NOT refused — round-1 finding 1 and
#    round-2 finding 2's regressions: both `@user please re-check …` (the
#    mention followed by text on the same line) and a mention ALONE on
#    line 1 with the message beneath it post successfully, exit 0, with
#    the read-back guard not false-positiving on either.
#  - a stored body that is a bare `@`-token equal to the file's own first
#    line (MOCK_GH_STORE_TEXT): passes the first-line-equality check, so
#    only the read-back `@`-token guard can catch it — exit 4.
#  - a mock that stores the literal path (MOCK_GH_STORE_LITERAL=1): the
#    post succeeds at the transport level (gh reports a normal comment
#    URL) but the read-back guard fires — exit 4, message names the
#    comment URL, distinct from every other exit code.
#  - --edit <comment-id>: PATCH instead of POST, calls.log records the
#    PATCH and the stored body becomes the file's contents, read-back
#    guard still applies.
#  - --edit against a comment id that belongs to a different issue/PR
#    number than the one given: exit 6, distinct from every other code
#    (issue #520 item 3).
#  - a successful call whose stderr carries benign noise (e.g. gh's own
#    update-available notice) no longer corrupts the JSON parse: exit 0
#    (issue #520 item 1 regression) — injected on the POST branch AND,
#    separately, on the READ-BACK GET branch, where folding stderr into
#    the compared body produced a false exit 4 after a successful post
#    (round-2 review finding 1). The GET-noise case is run twice: once
#    with gh's real update notice, once with an `@`-token-shaped line that
#    would trip the read-back @-guard rather than the mismatch guard.
#  - a successful call whose stdout is not valid JSON: exit 5, distinct
#    from the read-back guard's exit 4 (issue #520 item 1).
#  - a body at or past a single stdio buffer (>= 32 KB): exit 0 with the
#    comment URL on stdout, run 10x to demonstrate determinism (round-1
#    review finding 2 — the SIGPIPE-under-pipefail regression).
#  - hermeticity tripwire (#549): the mock marks any invocation arriving
#    without the harness env as UNMOCKED-CONTEXT; the suite proves the
#    marker fires for a deliberately unmocked run and then asserts it
#    never appears in the suite's own call log.
set -euo pipefail
export LANG=C LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POST_COMMENT_SH="$SCRIPT_DIR/../scripts/post-comment.sh"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/post-comment-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

BIN="$WORK/bin"
OUT="$WORK/out"
FIXTURES="$WORK/fixtures"
STATE="$WORK/state"
mkdir -p "$BIN" "$OUT" "$FIXTURES" "$STATE"

REPO="test-org/test-repo"
NUMBER=42

fail=0
report(){ echo "FAIL: $*" >&2; fail=1; }

# ---------------------------------------------------------------------------
# Mock gh. Routes:
#   repo view --json nameWithOwner --jq .nameWithOwner   -> $MOCK_GH_REPO_VIEW
#   api -X POST repos/<repo>/issues/<n>/comments -F body=@<file>
#   api -X PATCH repos/<repo>/issues/comments/<id> -F body=@<file>
#   api repos/<repo>/issues/comments/<id> --jq '.body'   (read-back)
# State (comment id -> stored body) persists as one file per id under
# $MOCK_GH_STATE; the id's owning issue/PR number persists alongside as
# "$MOCK_GH_STATE/<id>.issue". MOCK_GH_STORE_LITERAL=1 makes POST/PATCH
# store the raw "@<path>" argument string instead of reading the file —
# reproducing the real-world defect this script guards against.
# MOCK_GH_STDERR_NOISE=1 writes a benign line to stderr on a successful
# POST without affecting stdout. MOCK_GH_BAD_JSON=1 makes POST print
# non-JSON to stdout while still exiting 0.
# ---------------------------------------------------------------------------
cat > "$BIN/gh" <<'MOCKGH'
#!/usr/bin/env bash
set -euo pipefail
# Hermeticity tripwire (#477, #549). MOCK_GH_CALL_LOG is exported once for
# the whole suite, so it is visible to any process the suite spawns — while
# the rest of the harness env (MOCK_GH_CALLS, MOCK_GH_STATE, …) is set only
# by run_post_comment(). A call that arrives here without that per-run env
# therefore came from a context the harness did not set up (e.g. a case
# that stopped routing through the helper), and is recorded as
# UNMOCKED-CONTEXT rather than being allowed to fall through to the real,
# authenticated gh. The end of the suite asserts the marker never appears.
: "${MOCK_GH_CALL_LOG:?MOCK_GH_CALL_LOG must be set}"
printf 'CALL gh %s\n' "$*" >> "$MOCK_GH_CALL_LOG"
if [ -z "${MOCK_GH_STATE:-}" ] || [ -z "${MOCK_GH_CALLS:-}" ]; then
  printf 'UNMOCKED-CONTEXT gh %s\n' "$*" >> "$MOCK_GH_CALL_LOG"
  echo "mock gh: invoked with no MOCK_GH_STATE/MOCK_GH_CALLS — unmocked call context" >&2
  exit 1
fi
: "${MOCK_GH_CALLS:?MOCK_GH_CALLS must be set}"
: "${MOCK_GH_STATE:?MOCK_GH_STATE must be set}"
: "${MOCK_GH_NEXT_ID_FILE:?MOCK_GH_NEXT_ID_FILE must be set}"
: "${MOCK_GH_REPO_VIEW:-}"
: "${MOCK_GH_STORE_LITERAL:-0}"
: "${MOCK_GH_STORE_TEXT:-}"
: "${MOCK_GH_GARBLE:-0}"
: "${MOCK_GH_STDERR_NOISE:-0}"
: "${MOCK_GH_STDERR_NOISE_GET:-}"
: "${MOCK_GH_BAD_JSON:-0}"

echo "$*" >> "$MOCK_GH_CALLS"

if [ "${1:-}" = "repo" ] && [ "${2:-}" = "view" ]; then
  [ -n "$MOCK_GH_REPO_VIEW" ] || { echo "mock gh: MOCK_GH_REPO_VIEW not set" >&2; exit 1; }
  printf '%s\n' "$MOCK_GH_REPO_VIEW"
  exit 0
fi

if [ "${1:-}" = "api" ]; then
  shift
  method="GET"
  endpoint=""
  jq_expr=""
  body_arg=""
  while [ $# -gt 0 ]; do
    case "$1" in
      -X|--method) method="$2"; shift 2 ;;
      --jq) jq_expr="$2"; shift 2 ;;
      -F)
        case "$2" in
          body=*) body_arg="${2#body=}" ;;
        esac
        shift 2 ;;
      *) endpoint="$1"; shift ;;
    esac
  done

  next_id(){
    local n
    n=$(cat "$MOCK_GH_NEXT_ID_FILE")
    echo $((n + 1)) > "$MOCK_GH_NEXT_ID_FILE"
    printf '%s' "$n"
  }

  resolve_body(){ # resolve_body <body_arg like "@/path/to/file">
    local arg="$1"
    if [ -n "$MOCK_GH_STORE_TEXT" ]; then
      # Store an arbitrary caller-chosen body: lets a test pin what the
      # read-back guard does about a stored body that is NOT the literal
      # `@<path>` argument but is still a bare `@`-token.
      printf '%s' "$MOCK_GH_STORE_TEXT"
    elif [ "$MOCK_GH_STORE_LITERAL" = "1" ]; then
      printf '%s' "$arg"
    elif [ "$MOCK_GH_GARBLE" = "1" ]; then
      # Simulate a stored body that is NOT the literal-path defect (does
      # not start with '@') but still differs from the file's own first
      # line — isolates the read-back mismatch guard from the read-back
      # @-prefix guard, so a mutation removing only one of the two still
      # fails this specific test.
      printf 'GARBLED — this is not what was sent'
    else
      case "$arg" in
        @*) cat "${arg#@}" ;;
        *) printf '%s' "$arg" ;;
      esac
    fi
  }

  case "$method" in
    POST)
      case "$endpoint" in
        repos/*/issues/*/comments)
          id=$(next_id)
          resolve_body "$body_arg" > "$MOCK_GH_STATE/$id"
          repo_slug=$(printf '%s' "$endpoint" | sed -E 's#repos/([^/]+/[^/]+)/issues/([0-9]+)/comments#\1#')
          issue_num=$(printf '%s' "$endpoint" | sed -E 's#repos/[^/]+/[^/]+/issues/([0-9]+)/comments#\1#')
          printf '%s' "$issue_num" > "$MOCK_GH_STATE/$id.issue"
          url="https://github.com/$repo_slug/issues/$issue_num#issuecomment-$id"
          issue_url="https://api.github.com/repos/$repo_slug/issues/$issue_num"
          if [ "$MOCK_GH_STDERR_NOISE" = "1" ]; then
            echo "gh: a new release is available (benign notice)" >&2
          fi
          if [ "$MOCK_GH_BAD_JSON" = "1" ]; then
            printf 'not-json-at-all\n'
          else
            jq -nc --argjson id "$id" --arg url "$url" --arg issue_url "$issue_url" '{id:$id, html_url:$url, issue_url:$issue_url}'
          fi
          ;;
        *) echo "mock gh: unknown POST endpoint: $endpoint" >&2; exit 1 ;;
      esac
      ;;
    PATCH)
      case "$endpoint" in
        repos/*/issues/comments/*)
          id="${endpoint##*/}"
          [ -f "$MOCK_GH_STATE/$id" ] || { echo "mock gh: PATCH on unknown comment id $id" >&2; exit 1; }
          resolve_body "$body_arg" > "$MOCK_GH_STATE/$id"
          repo_slug=$(printf '%s' "$endpoint" | sed -E 's#repos/([^/]+/[^/]+)/issues/comments/.*#\1#')
          issue_num=$(cat "$MOCK_GH_STATE/$id.issue" 2>/dev/null || echo 1)
          url="https://github.com/$repo_slug/issues/$issue_num#issuecomment-$id"
          issue_url="https://api.github.com/repos/$repo_slug/issues/$issue_num"
          jq -nc --argjson id "$id" --arg url "$url" --arg issue_url "$issue_url" '{id:$id, html_url:$url, issue_url:$issue_url}'
          ;;
        *) echo "mock gh: unknown PATCH endpoint: $endpoint" >&2; exit 1 ;;
      esac
      ;;
    GET)
      case "$endpoint" in
        repos/*/issues/comments/*)
          id="${endpoint##*/}"
          [ -f "$MOCK_GH_STATE/$id" ] || { echo "mock gh: GET on unknown comment id $id" >&2; exit 1; }
          # Benign stderr noise on the READ-BACK call, not just on the
          # write (round-2 review finding 1): the real gh emits its
          # update notice on any subcommand, and a script that captures
          # the GET with 2>&1 folds that line into the body it compares.
          if [ "$MOCK_GH_STDERR_NOISE" = "1" ]; then
            echo "gh: A new release of gh is available: 2.40.0 -> 2.63.2" >&2
          fi
          if [ -n "$MOCK_GH_STDERR_NOISE_GET" ]; then
            printf '%s\n' "$MOCK_GH_STDERR_NOISE_GET" >&2
          fi
          body=$(cat "$MOCK_GH_STATE/$id")
          resp=$(jq -nc --arg body "$body" '{body:$body}')
          if [ -n "$jq_expr" ]; then jq -c -r "$jq_expr" <<<"$resp"; else printf '%s\n' "$resp"; fi
          ;;
        *) echo "mock gh: unknown GET endpoint: $endpoint" >&2; exit 1 ;;
      esac
      ;;
    *) echo "mock gh: unsupported method: $method" >&2; exit 1 ;;
  esac
  exit 0
fi

echo "mock gh: unsupported command: $*" >&2
exit 1
MOCKGH
chmod +x "$BIN/gh"

export MOCK_GH_CALL_LOG="$OUT/gh-calls.log"
: > "$MOCK_GH_CALL_LOG"

run_post_comment(){ # run_post_comment <store-literal 0|1> <args...> [--garble] [--stderr-noise] [--stderr-noise-get=<text>] [--store-text=<text>] [--bad-json]
  local store_literal="$1" garble="0" noise="0" badjson="0" noise_get="" store_text=""; shift
  local args=() a
  for a in "$@"; do
    case "$a" in
      --garble) garble="1" ;;
      --stderr-noise) noise="1" ;;
      --stderr-noise-get=*) noise_get="${a#--stderr-noise-get=}" ;;
      --store-text=*) store_text="${a#--store-text=}" ;;
      --bad-json) badjson="1" ;;
      *) args+=("$a") ;;
    esac
  done
  : > "$OUT/calls.log"
  echo 1 > "$OUT/next-id"
  local rc=0
  set +e
  PATH="$BIN:$PATH" \
    MOCK_GH_CALLS="$OUT/calls.log" MOCK_GH_STATE="$STATE" \
    MOCK_GH_NEXT_ID_FILE="$OUT/next-id" MOCK_GH_REPO_VIEW="$REPO" \
    MOCK_GH_STORE_LITERAL="$store_literal" MOCK_GH_STORE_TEXT="$store_text" \
    MOCK_GH_GARBLE="$garble" \
    MOCK_GH_STDERR_NOISE="$noise" MOCK_GH_STDERR_NOISE_GET="$noise_get" \
    MOCK_GH_BAD_JSON="$badjson" \
    "$POST_COMMENT_SH" "${args[@]}" >"$OUT/stdout" 2>"$OUT/stderr"
  rc=$?
  set -e
  if [ "$rc" -ne 0 ] && [ "${DEBUG:-0}" = "1" ]; then
    echo "--- stdout ---" >&2; cat "$OUT/stdout" >&2
    echo "--- stderr ---" >&2; cat "$OUT/stderr" >&2
  fi
  return "$rc"
}

# ---------------------------------------------------------------------------
# 1. Success: a real body file, POST, read-back matches, exit 0.
# ---------------------------------------------------------------------------
GOOD_FILE="$FIXTURES/good.md"
printf '## Test Evidence — round 0\n\nSome real content.\n' > "$GOOD_FILE"

rm -rf "$STATE"; mkdir -p "$STATE"
if run_post_comment 0 "$NUMBER" "$GOOD_FILE" --repo "$REPO"; then
  url=$(cat "$OUT/stdout")
  case "$url" in
    https://github.com/*issuecomment-*) : ;;
    *) report "success: stdout is not a comment URL: $url" ;;
  esac
  ncalls=$(grep -c '^api ' "$OUT/calls.log" || true)
  [ "$ncalls" = "2" ] || report "success: expected 2 gh api calls (POST + read-back GET), got $ncalls"
else
  report "success case: expected exit 0, got $?. stderr: $(cat "$OUT/stderr")"
fi

# ---------------------------------------------------------------------------
# 2. Missing file.
# ---------------------------------------------------------------------------
rm -rf "$STATE"; mkdir -p "$STATE"
MISSING_FILE="$FIXTURES/does-not-exist.md"
if run_post_comment 0 "$NUMBER" "$MISSING_FILE" --repo "$REPO"; then
  report "missing file: expected non-zero exit, got 0"
else
  rc=$?
  [ "$rc" = "3" ] || report "missing file: expected exit 3, got $rc"
  grep -q "does not exist" "$OUT/stderr" || report "missing file: stderr does not name the reason: $(cat "$OUT/stderr")"
  [ -s "$OUT/calls.log" ] && report "missing file: expected zero gh api calls, got: $(cat "$OUT/calls.log")"
fi

# ---------------------------------------------------------------------------
# 3. Empty file.
# ---------------------------------------------------------------------------
rm -rf "$STATE"; mkdir -p "$STATE"
EMPTY_FILE="$FIXTURES/empty.md"
: > "$EMPTY_FILE"
if run_post_comment 0 "$NUMBER" "$EMPTY_FILE" --repo "$REPO"; then
  report "empty file: expected non-zero exit, got 0"
else
  rc=$?
  [ "$rc" = "3" ] || report "empty file: expected exit 3, got $rc"
  grep -q "empty" "$OUT/stderr" || report "empty file: stderr does not name the reason: $(cat "$OUT/stderr")"
  [ -s "$OUT/calls.log" ] && report "empty file: expected zero gh api calls, got: $(cat "$OUT/calls.log")"
fi

# ---------------------------------------------------------------------------
# 4. A bare `@`-prefixed single-token first line — the symptom itself,
#    caught pre-write (body has a trailing newline / second line does not
#    exist).
# ---------------------------------------------------------------------------
rm -rf "$STATE"; mkdir -p "$STATE"
ATFILE="$FIXTURES/at-prefixed.md"
printf '@/tmp/some/scratch/path.md\n' > "$ATFILE"
if run_post_comment 0 "$NUMBER" "$ATFILE" --repo "$REPO"; then
  report "@-prefixed file: expected non-zero exit, got 0"
else
  rc=$?
  [ "$rc" = "3" ] || report "@-prefixed file: expected exit 3, got $rc"
  grep -q "bare '@'-prefixed path-shaped token" "$OUT/stderr" || report "@-prefixed file: stderr does not name the reason: $(cat "$OUT/stderr")"
  [ -s "$OUT/calls.log" ] && report "@-prefixed file: expected zero gh api calls, got: $(cat "$OUT/calls.log")"
fi

# ---------------------------------------------------------------------------
# 4b. Whole body IS a single `@`-prefixed token — no trailing newline, no
#     second line — still refused pre-write.
# ---------------------------------------------------------------------------
rm -rf "$STATE"; mkdir -p "$STATE"
WHOLEFILE="$FIXTURES/whole-token.md"
printf '@/tmp/x/y.md' > "$WHOLEFILE"
if run_post_comment 0 "$NUMBER" "$WHOLEFILE" --repo "$REPO"; then
  report "whole-body single-token file: expected non-zero exit, got 0"
else
  rc=$?
  [ "$rc" = "3" ] || report "whole-body single-token file: expected exit 3, got $rc"
  grep -q "bare '@'-prefixed path-shaped token" "$OUT/stderr" || report "whole-body single-token file: stderr does not name the reason: $(cat "$OUT/stderr")"
fi

# ---------------------------------------------------------------------------
# 4b2. Issue #569 item 1: a bare `@`-token padded with leading/trailing
#      whitespace — pins `trim_ws` as load-bearing in `body_is_bare_at_token`
#      pre-write. Replacing `t="$(trim_ws "$1")"` with `t="$1"` leaves this
#      body unrefused (it posts instead), since the raw string then has
#      leading spaces before the `@` and can never match `^@[^space]+$`.
# ---------------------------------------------------------------------------
rm -rf "$STATE"; mkdir -p "$STATE"
PADDEDFILE="$FIXTURES/padded-token.md"
printf '   @/tmp/x/y.md   ' > "$PADDEDFILE"
if run_post_comment 0 "$NUMBER" "$PADDEDFILE" --repo "$REPO"; then
  report "whitespace-padded @-token file: expected non-zero exit, got 0"
else
  rc=$?
  [ "$rc" = "3" ] || report "whitespace-padded @-token file: expected exit 3, got $rc"
  grep -q "bare '@'-prefixed path-shaped token" "$OUT/stderr" || report "whitespace-padded @-token file: stderr does not name the reason: $(cat "$OUT/stderr")"
  [ -s "$OUT/calls.log" ] && report "whitespace-padded @-token file: expected zero gh api calls, got: $(cat "$OUT/calls.log")"
fi

# ---------------------------------------------------------------------------
# 4b3. Issue #569 item 2: a leading UTF-8 BOM before a bare `@`-token —
#      pins the BOM strip in `body_is_bare_at_token`, pre-write side.
#      Without it, the BOM is a non-whitespace character in front of `@`
#      and the token-shaped predicate cannot match, so the file would post.
# ---------------------------------------------------------------------------
rm -rf "$STATE"; mkdir -p "$STATE"
BOMFILE="$FIXTURES/bom-token.md"
printf '\xEF\xBB\xBF@/tmp/x/y.md\n' > "$BOMFILE"
if run_post_comment 0 "$NUMBER" "$BOMFILE" --repo "$REPO"; then
  report "BOM-prefixed @-token file: expected non-zero exit, got 0"
else
  rc=$?
  [ "$rc" = "3" ] || report "BOM-prefixed @-token file: expected exit 3, got $rc"
  grep -q "bare '@'-prefixed path-shaped token" "$OUT/stderr" || report "BOM-prefixed @-token file: stderr does not name the reason: $(cat "$OUT/stderr")"
  [ -s "$OUT/calls.log" ] && report "BOM-prefixed @-token file: expected zero gh api calls, got: $(cat "$OUT/calls.log")"
fi

# ---------------------------------------------------------------------------
# 4b4. Round-1 review finding 1: a leading BOM followed by whitespace
#      padding before the `@`-token — pins that the BOM is stripped BEFORE
#      trimming, not after. Stripping after trimming would leave `trim_ws`
#      stopping at the BOM (a non-whitespace byte) and never reach the
#      whitespace behind it, so this shape would evade the guard and post.
# ---------------------------------------------------------------------------
rm -rf "$STATE"; mkdir -p "$STATE"
BOMPADFILE="$FIXTURES/bom-padded-token.md"
printf '\xEF\xBB\xBF   @/tmp/x/y.md   ' > "$BOMPADFILE"
if run_post_comment 0 "$NUMBER" "$BOMPADFILE" --repo "$REPO"; then
  report "BOM+whitespace-padded @-token file: expected non-zero exit, got 0"
else
  rc=$?
  [ "$rc" = "3" ] || report "BOM+whitespace-padded @-token file: expected exit 3, got $rc"
  grep -q "bare '@'-prefixed path-shaped token" "$OUT/stderr" || report "BOM+whitespace-padded @-token file: stderr does not name the reason: $(cat "$OUT/stderr")"
  [ -s "$OUT/calls.log" ] && report "BOM+whitespace-padded @-token file: expected zero gh api calls, got: $(cat "$OUT/calls.log")"
fi

# ---------------------------------------------------------------------------
# 4b5. Round-1 review finding 1: a DOUBLED leading BOM before the
#      `@`-token — pins that the BOM strip repeats rather than stripping
#      only one occurrence.
# ---------------------------------------------------------------------------
rm -rf "$STATE"; mkdir -p "$STATE"
DOUBLEBOMFILE="$FIXTURES/double-bom-token.md"
printf '\xEF\xBB\xBF\xEF\xBB\xBF@/tmp/x/y.md\n' > "$DOUBLEBOMFILE"
if run_post_comment 0 "$NUMBER" "$DOUBLEBOMFILE" --repo "$REPO"; then
  report "double-BOM @-token file: expected non-zero exit, got 0"
else
  rc=$?
  [ "$rc" = "3" ] || report "double-BOM @-token file: expected exit 3, got $rc"
  grep -q "bare '@'-prefixed path-shaped token" "$OUT/stderr" || report "double-BOM @-token file: stderr does not name the reason: $(cat "$OUT/stderr")"
  [ -s "$OUT/calls.log" ] && report "double-BOM @-token file: expected zero gh api calls, got: $(cat "$OUT/calls.log")"
fi

# ---------------------------------------------------------------------------
# 4c. Round-1 review finding 1 regression: a body whose first line is an
#     `@mention` followed by more text is NOT refused — it posts
#     successfully and the read-back guard does not false-positive on it.
# ---------------------------------------------------------------------------
rm -rf "$STATE"; mkdir -p "$STATE"
MENTIONFILE="$FIXTURES/mention.md"
printf '@machine-blac9216 please re-check the manifest\n\nMore body text.\n' > "$MENTIONFILE"
if run_post_comment 0 "$NUMBER" "$MENTIONFILE" --repo "$REPO"; then
  url=$(cat "$OUT/stdout")
  case "$url" in
    https://github.com/*issuecomment-*) : ;;
    *) report "@mention-leading body: stdout is not a comment URL: $url" ;;
  esac
else
  report "@mention-leading body: expected exit 0 (no false-positive refusal), got $?. stderr: $(cat "$OUT/stderr")"
fi

# ---------------------------------------------------------------------------
# 4d. Round-2 review finding 2 regression: an `@mention` ALONE on line 1
#     with the message beneath it — an entirely ordinary comment shape —
#     must post. The old first-non-empty-line predicate refused this with
#     exit 3 and never posted; #479's AC scopes the guard to a body
#     consisting ONLY of an `@`-prefixed path, so the predicate is a
#     whole-body test.
# ---------------------------------------------------------------------------
rm -rf "$STATE"; mkdir -p "$STATE"
MENTION_LINE_FILE="$FIXTURES/mention-own-line.md"
printf '@machine-blac9216\nplease re-check the manifest\n' > "$MENTION_LINE_FILE"
if run_post_comment 0 "$NUMBER" "$MENTION_LINE_FILE" --repo "$REPO"; then
  url=$(cat "$OUT/stdout")
  case "$url" in
    https://github.com/*issuecomment-*) : ;;
    *) report "mention-alone-then-body: stdout is not a comment URL: $url" ;;
  esac
  stored_id="${url##*issuecomment-}"
  [ "$(cat "$STATE/$stored_id")" = "$(cat "$MENTION_LINE_FILE")" ] \
    || report "mention-alone-then-body: stored body is not the file's contents"
else
  report "mention-alone-then-body: expected exit 0 (whole-body guard, not first-line), got $?. stderr: $(cat "$OUT/stderr")"
fi

# ---------------------------------------------------------------------------
# 4e. The three historical occurrences from #479 (two on PR #436, plus the
#     issue's own third-occurrence comment) — each a whole body that is
#     nothing but an `@`-prefixed scratch path. All three stay refused
#     pre-write, with and without a trailing newline, and issue zero calls.
# ---------------------------------------------------------------------------
HIST_1='@/tmp/claude-1000/-workspaces-git-Personal-storage/374156c2-b083-4bdc-afbe-1b7634ee5def/scratchpad/issue418/evidence-comment-r1.md'
HIST_2='@/tmp/claude-1000/-workspaces-git-Personal-storage/374156c2-b083-4bdc-afbe-1b7634ee5def/scratchpad/issue418/fixes-applied-r1.md'
HIST_3='@issue479/fixes-applied-r1.md'
hist_n=0
for hist in "$HIST_1" "$HIST_2" "$HIST_3"; do
  hist_n=$((hist_n + 1))
  for newline in with without; do
    rm -rf "$STATE"; mkdir -p "$STATE"
    HISTFILE_FIXTURE="$FIXTURES/historical-$hist_n-$newline.md"
    if [ "$newline" = "with" ]; then
      printf '%s\n' "$hist" > "$HISTFILE_FIXTURE"
    else
      printf '%s' "$hist" > "$HISTFILE_FIXTURE"
    fi
    if run_post_comment 0 "$NUMBER" "$HISTFILE_FIXTURE" --repo "$REPO"; then
      report "historical shape $hist_n ($newline newline): expected exit 3, got 0"
    else
      rc=$?
      [ "$rc" = "3" ] || report "historical shape $hist_n ($newline newline): expected exit 3, got $rc"
      grep -q "bare '@'-prefixed path-shaped token" "$OUT/stderr" \
        || report "historical shape $hist_n ($newline newline): stderr does not name the reason: $(cat "$OUT/stderr")"
      [ -s "$OUT/calls.log" ] && report "historical shape $hist_n ($newline newline): expected zero gh api calls, got: $(cat "$OUT/calls.log")"
    fi
  done
done

# ---------------------------------------------------------------------------
# 5. Mock stores the literal path (the real-world defect) — read-back
#    guard must fire, exit 4, message names the comment URL.
# ---------------------------------------------------------------------------
rm -rf "$STATE"; mkdir -p "$STATE"
if run_post_comment 1 "$NUMBER" "$GOOD_FILE" --repo "$REPO"; then
  report "literal-store guard: expected non-zero exit, got 0. stdout: $(cat "$OUT/stdout")"
else
  rc=$?
  [ "$rc" = "4" ] || report "literal-store guard: expected exit 4, got $rc"
  grep -q "read-back guard fired" "$OUT/stderr" || report "literal-store guard: stderr missing 'read-back guard fired': $(cat "$OUT/stderr")"
  grep -q "issuecomment-" "$OUT/stderr" || report "literal-store guard: stderr does not name the comment URL: $(cat "$OUT/stderr")"
fi

# ---------------------------------------------------------------------------
# 5b. The read-back `@`-token check is load-bearing in its own right once
#     the predicate is whole-body (round-2 finding 2): a file may now
#     legitimately have `@token` as its FIRST line, so a stored body that
#     is nothing but that token passes the first-line-equality check and
#     only this guard catches it. Exit 4, naming the URL.
# ---------------------------------------------------------------------------
rm -rf "$STATE"; mkdir -p "$STATE"
if run_post_comment 0 "$NUMBER" "$MENTION_LINE_FILE" --repo "$REPO" \
     --store-text="@machine-blac9216"; then
  report "stored-bare-token matching first line: expected non-zero exit, got 0. stdout: $(cat "$OUT/stdout")"
else
  rc=$?
  [ "$rc" = "4" ] || report "stored-bare-token matching first line: expected exit 4, got $rc"
  grep -q "bare '@'-prefixed path-shaped token" "$OUT/stderr" \
    || report "stored-bare-token matching first line: stderr does not name the read-back @-token guard: $(cat "$OUT/stderr")"
  grep -q "issuecomment-" "$OUT/stderr" \
    || report "stored-bare-token matching first line: stderr does not name the comment URL: $(cat "$OUT/stderr")"
fi

# ---------------------------------------------------------------------------
# 5c. Issue #569 item 1: `trim_ws` pinned on the READ-BACK side too — a
#     stored body that is a bare `@`-token padded with leading/trailing
#     whitespace must still be caught by the read-back guard, exit 4.
# ---------------------------------------------------------------------------
rm -rf "$STATE"; mkdir -p "$STATE"
if run_post_comment 0 "$NUMBER" "$GOOD_FILE" --repo "$REPO" \
     --store-text="  @/tmp/some/scratch/path.md  "; then
  report "whitespace-padded stored @-token: expected non-zero exit, got 0. stdout: $(cat "$OUT/stdout")"
else
  rc=$?
  [ "$rc" = "4" ] || report "whitespace-padded stored @-token: expected exit 4, got $rc"
  grep -q "bare '@'-prefixed path-shaped token" "$OUT/stderr" \
    || report "whitespace-padded stored @-token: stderr does not name the read-back @-token guard: $(cat "$OUT/stderr")"
  grep -q "issuecomment-" "$OUT/stderr" \
    || report "whitespace-padded stored @-token: stderr does not name the comment URL: $(cat "$OUT/stderr")"
fi

# ---------------------------------------------------------------------------
# 5d. Round-1 review finding 1: a stored body that is a BOM, then
#     whitespace padding, then a bare `@`-token — read-back side of the
#     same ordering fix as 4b4.
# ---------------------------------------------------------------------------
rm -rf "$STATE"; mkdir -p "$STATE"
if run_post_comment 0 "$NUMBER" "$GOOD_FILE" --repo "$REPO" \
     --store-text="$(printf '\xEF\xBB\xBF   @/tmp/some/scratch/path.md   ')"; then
  report "BOM+whitespace-padded stored @-token: expected non-zero exit, got 0. stdout: $(cat "$OUT/stdout")"
else
  rc=$?
  [ "$rc" = "4" ] || report "BOM+whitespace-padded stored @-token: expected exit 4, got $rc"
  grep -q "bare '@'-prefixed path-shaped token" "$OUT/stderr" \
    || report "BOM+whitespace-padded stored @-token: stderr does not name the read-back @-token guard: $(cat "$OUT/stderr")"
  grep -q "issuecomment-" "$OUT/stderr" \
    || report "BOM+whitespace-padded stored @-token: stderr does not name the comment URL: $(cat "$OUT/stderr")"
fi

# ---------------------------------------------------------------------------
# 5e. Round-1 review finding 1: a stored body with a DOUBLED leading BOM
#     before a bare `@`-token — read-back side of the same repeat-strip fix
#     as 4b5.
# ---------------------------------------------------------------------------
rm -rf "$STATE"; mkdir -p "$STATE"
if run_post_comment 0 "$NUMBER" "$GOOD_FILE" --repo "$REPO" \
     --store-text="$(printf '\xEF\xBB\xBF\xEF\xBB\xBF@/tmp/some/scratch/path.md')"; then
  report "double-BOM stored @-token: expected non-zero exit, got 0. stdout: $(cat "$OUT/stdout")"
else
  rc=$?
  [ "$rc" = "4" ] || report "double-BOM stored @-token: expected exit 4, got $rc"
  grep -q "bare '@'-prefixed path-shaped token" "$OUT/stderr" \
    || report "double-BOM stored @-token: stderr does not name the read-back @-token guard: $(cat "$OUT/stderr")"
  grep -q "issuecomment-" "$OUT/stderr" \
    || report "double-BOM stored @-token: stderr does not name the comment URL: $(cat "$OUT/stderr")"
fi

# ---------------------------------------------------------------------------
# 6. --edit <comment-id>: PATCH instead of POST, existing id (owned by the
#    same issue number given), read-back guard still applies on the happy
#    path.
# ---------------------------------------------------------------------------
rm -rf "$STATE"; mkdir -p "$STATE"
printf 'placeholder' > "$STATE/7"
printf '%s' "$NUMBER" > "$STATE/7.issue"
if run_post_comment 0 "$NUMBER" "$GOOD_FILE" --repo "$REPO" --edit 7; then
  url=$(cat "$OUT/stdout")
  case "$url" in
    *issuecomment-7) : ;;
    *) report "--edit: stdout URL does not reference comment id 7: $url" ;;
  esac
  grep -q 'PATCH' "$OUT/calls.log" || report "--edit: expected a PATCH call, calls.log: $(cat "$OUT/calls.log")"
  stored=$(cat "$STATE/7")
  [ "$stored" = "$(cat "$GOOD_FILE")" ] || report "--edit: comment 7's stored body was not updated to the file's contents"
else
  report "--edit case: expected exit 0, got $?. stderr: $(cat "$OUT/stderr")"
fi

# ---------------------------------------------------------------------------
# 6b. --edit against a comment id belonging to a DIFFERENT issue/PR number
#     than the one given: exit 6, distinct from every other code (issue
#     #520 item 3).
# ---------------------------------------------------------------------------
rm -rf "$STATE"; mkdir -p "$STATE"
printf 'placeholder' > "$STATE/9"
printf '99' > "$STATE/9.issue"
if run_post_comment 0 "$NUMBER" "$GOOD_FILE" --repo "$REPO" --edit 9; then
  report "--edit mismatch: expected non-zero exit, got 0"
else
  rc=$?
  [ "$rc" = "6" ] || report "--edit mismatch: expected exit 6, got $rc"
  grep -q "belongs to issue/PR 99" "$OUT/stderr" || report "--edit mismatch: stderr does not name the actual owner: $(cat "$OUT/stderr")"
fi

# ---------------------------------------------------------------------------
# 7. Garbled read-back (no '@' prefix, but content mismatched) — isolates
#    the first-line-mismatch guard from the '@'-prefix guard: a mutation
#    that removes only ONE of the two read-back checks must still fail
#    this specific case since the garbled body never starts with '@'.
# ---------------------------------------------------------------------------
rm -rf "$STATE"; mkdir -p "$STATE"
if run_post_comment 0 "$NUMBER" "$GOOD_FILE" --repo "$REPO" --garble; then
  report "garbled read-back guard: expected non-zero exit, got 0. stdout: $(cat "$OUT/stdout")"
else
  rc=$?
  [ "$rc" = "4" ] || report "garbled read-back guard: expected exit 4, got $rc"
  grep -q "does not match the file's first line" "$OUT/stderr" || report "garbled read-back guard: stderr missing mismatch message: $(cat "$OUT/stderr")"
  grep -q "issuecomment-" "$OUT/stderr" || report "garbled read-back guard: stderr does not name the comment URL: $(cat "$OUT/stderr")"
fi

# ---------------------------------------------------------------------------
# 8. A successful call whose stderr carries benign noise no longer
#    corrupts the JSON parse (issue #520 item 1 regression): exit 0.
# ---------------------------------------------------------------------------
rm -rf "$STATE"; mkdir -p "$STATE"
if run_post_comment 0 "$NUMBER" "$GOOD_FILE" --repo "$REPO" --stderr-noise; then
  url=$(cat "$OUT/stdout")
  case "$url" in
    https://github.com/*issuecomment-*) : ;;
    *) report "stderr-noise: stdout is not a comment URL: $url" ;;
  esac
else
  report "stderr-noise: expected exit 0, got $?. stderr: $(cat "$OUT/stderr")"
fi

# ---------------------------------------------------------------------------
# 8b. Round-2 review finding 1 regression: the noise is on the READ-BACK
#     GET, not on the POST. A script that captures the GET with `2>&1`
#     splices gh's update notice into the body it compares and aborts with
#     exit 4 — a false failure AFTER a comment was successfully posted,
#     with no URL printed. Correct behaviour: exit 0, URL on stdout, and
#     the stored body untouched by the noise.
# ---------------------------------------------------------------------------
rm -rf "$STATE"; mkdir -p "$STATE"
if run_post_comment 0 "$NUMBER" "$GOOD_FILE" --repo "$REPO" \
     --stderr-noise-get="gh: A new release of gh is available: 2.40.0 -> 2.63.2"; then
  url=$(cat "$OUT/stdout")
  case "$url" in
    https://github.com/*issuecomment-*) : ;;
    *) report "noisy read-back GET: stdout is not a comment URL: $url" ;;
  esac
  grep -q 'new release of gh' "$OUT/stdout" && report "noisy read-back GET: gh's stderr leaked onto the script's stdout"
  stored_id="${url##*issuecomment-}"
  [ "$(cat "$STATE/$stored_id")" = "$(cat "$GOOD_FILE")" ] \
    || report "noisy read-back GET: stored body is not the file's contents"
else
  report "noisy read-back GET: expected exit 0, got $?. stderr: $(cat "$OUT/stderr")"
fi

# ---------------------------------------------------------------------------
# 8c. Same, with a GET stderr line that is itself `@`-token-shaped: folding
#     it into the body would fire the read-back @-token branch instead of
#     the mismatch branch, so this pins BOTH read-back checks to the
#     stored body alone.
# ---------------------------------------------------------------------------
rm -rf "$STATE"; mkdir -p "$STATE"
if run_post_comment 0 "$NUMBER" "$GOOD_FILE" --repo "$REPO" \
     --stderr-noise-get="@/tmp/some/gh/notice.md"; then
  url=$(cat "$OUT/stdout")
  case "$url" in
    https://github.com/*issuecomment-*) : ;;
    *) report "@-shaped GET stderr noise: stdout is not a comment URL: $url" ;;
  esac
else
  report "@-shaped GET stderr noise: expected exit 0, got $?. stderr: $(cat "$OUT/stderr")"
fi

# ---------------------------------------------------------------------------
# 9. A successful call whose stdout is not valid JSON: exit 5, distinct
#    from the read-back guard's exit 4 (issue #520 item 1).
# ---------------------------------------------------------------------------
rm -rf "$STATE"; mkdir -p "$STATE"
if run_post_comment 0 "$NUMBER" "$GOOD_FILE" --repo "$REPO" --bad-json; then
  report "bad-json response: expected non-zero exit, got 0"
else
  rc=$?
  [ "$rc" = "5" ] || report "bad-json response: expected exit 5, got $rc"
  grep -q "could not be parsed as JSON" "$OUT/stderr" || report "bad-json response: stderr missing parse-failure message: $(cat "$OUT/stderr")"
fi

# ---------------------------------------------------------------------------
# 10. A body at or past one stdio buffer (>= 32 KB): exit 0 with the
#     comment URL on stdout — round-1 review finding 2 regression. Run 10x
#     to demonstrate determinism (the original bug was intermittent: 2-3
#     failures per 10 trials at this size range).
# ---------------------------------------------------------------------------
BIGFILE="$FIXTURES/big.md"
{
  printf '## Test Evidence — round 1\n\n'
  i=0
  while [ "$i" -lt 500 ]; do
    printf 'The quick brown fox jumps over the lazy dog. 0123456789 abcdefghij\n'
    i=$((i + 1))
  done
} > "$BIGFILE"
BIGSIZE=$(wc -c < "$BIGFILE")
[ "$BIGSIZE" -ge 32768 ] || report "big body fixture: expected >= 32768 bytes, got $BIGSIZE"

trial=0
while [ "$trial" -lt 10 ]; do
  trial=$((trial + 1))
  rm -rf "$STATE"; mkdir -p "$STATE"
  if run_post_comment 0 "$NUMBER" "$BIGFILE" --repo "$REPO"; then
    url=$(cat "$OUT/stdout")
    case "$url" in
      https://github.com/*issuecomment-*) : ;;
      *) report "big body trial $trial: stdout is not a comment URL: $url" ;;
    esac
  else
    report "big body trial $trial: expected exit 0, got $?. stderr: $(cat "$OUT/stderr")"
  fi
done

# ---------------------------------------------------------------------------
# 12. Issue #680: repo resolution falls back to the checkout's own git
#     remote when `gh repo view` fails and no --repo was given, with
#     --repo the highest-precedence source, `gh repo view` next, and the
#     remote strictly lowest. Uses a private git repo under $FIXTURES so
#     the real repository's own remote is never consulted.
# ---------------------------------------------------------------------------
GITREMOTE_DIR="$FIXTURES/gitremote"
mkdir -p "$GITREMOTE_DIR"
(cd "$GITREMOTE_DIR" && git init -q -b main >/dev/null 2>&1)

run_post_comment_in(){ # run_post_comment_in <dir> <store-literal> <args...>
  local dir="$1"; shift
  ( cd "$dir" && run_post_comment "$@" )
}

# 12a. gh repo view fails, no --repo: HTTPS remote origin resolves the repo
# and the post succeeds using it.
(cd "$GITREMOTE_DIR" && git remote remove origin >/dev/null 2>&1 || true; git remote add origin https://github.com/remote-org/remote-repo.git)
rm -rf "$STATE"; mkdir -p "$STATE"
REPO_SAVE="$REPO"; REPO=""
if run_post_comment_in "$GITREMOTE_DIR" 0 "$NUMBER" "$GOOD_FILE"; then
  url=$(cat "$OUT/stdout")
  case "$url" in
    https://github.com/remote-org/remote-repo/*issuecomment-*) : ;;
    *) report "git-remote fallback (HTTPS): stdout did not resolve to the remote's repo: $url" ;;
  esac
  grep -q '^repo view' "$OUT/calls.log" || report "git-remote fallback (HTTPS): 'gh repo view' was not tried before falling back"
else
  report "git-remote fallback (HTTPS): expected exit 0, got $?. stderr: $(cat "$OUT/stderr")"
fi
REPO="$REPO_SAVE"

# 12b. Same, with an SSH-form remote (git@host:owner/name.git) — proves the
# fallback parses both URL shapes, not just HTTPS.
(cd "$GITREMOTE_DIR" && git remote remove origin >/dev/null 2>&1 || true; git remote add origin git@github.com:remote-org/remote-repo-ssh.git)
rm -rf "$STATE"; mkdir -p "$STATE"
REPO_SAVE="$REPO"; REPO=""
if run_post_comment_in "$GITREMOTE_DIR" 0 "$NUMBER" "$GOOD_FILE"; then
  url=$(cat "$OUT/stdout")
  case "$url" in
    https://github.com/remote-org/remote-repo-ssh/*issuecomment-*) : ;;
    *) report "git-remote fallback (SSH): stdout did not resolve to the remote's repo: $url" ;;
  esac
else
  report "git-remote fallback (SSH): expected exit 0, got $?. stderr: $(cat "$OUT/stderr")"
fi
REPO="$REPO_SAVE"

# 12c. Precedence: an explicit --repo wins over BOTH `gh repo view`
# (mocked to a different repo, MOCK_GH_REPO_VIEW=$REPO="test-org/test-repo"
# throughout the suite) and the git remote (also a different repo) —
# neither is ever consulted.
(cd "$GITREMOTE_DIR" && git remote remove origin >/dev/null 2>&1 || true; git remote add origin https://github.com/remote-org/remote-repo.git)
rm -rf "$STATE"; mkdir -p "$STATE"
if run_post_comment_in "$GITREMOTE_DIR" 0 "$NUMBER" "$GOOD_FILE" --repo "explicit-org/explicit-repo"; then
  url=$(cat "$OUT/stdout")
  case "$url" in
    https://github.com/explicit-org/explicit-repo/*issuecomment-*) : ;;
    *) report "explicit --repo precedence: stdout did not use the explicit repo: $url" ;;
  esac
  grep -q '^repo view' "$OUT/calls.log" && report "explicit --repo precedence: 'gh repo view' was consulted even though --repo was given"
else
  report "explicit --repo precedence: expected exit 0, got $?. stderr: $(cat "$OUT/stderr")"
fi

# 12d. Precedence: `gh repo view` succeeding wins over the git remote —
# the remote (a different repo) must never be reached when repo view
# already resolved it.
rm -rf "$STATE"; mkdir -p "$STATE"
if run_post_comment_in "$GITREMOTE_DIR" 0 "$NUMBER" "$GOOD_FILE"; then
  url=$(cat "$OUT/stdout")
  case "$url" in
    https://github.com/"$REPO"/*issuecomment-*) : ;;
    *) report "gh-repo-view precedence over remote: stdout did not use gh repo view's repo ($REPO): $url" ;;
  esac
else
  report "gh-repo-view precedence over remote: expected exit 0, got $?. stderr: $(cat "$OUT/stderr")"
fi

# 12e. Every source fails: gh repo view fails, no --repo, and no git
# remote 'origin' at all — the error names each source it tried, and
# zero real gh api (POST/PATCH/GET) calls are issued.
NOREMOTE_DIR="$FIXTURES/gitremote-none"
mkdir -p "$NOREMOTE_DIR"
(cd "$NOREMOTE_DIR" && git init -q -b main >/dev/null 2>&1)
rm -rf "$STATE"; mkdir -p "$STATE"
REPO_SAVE="$REPO"; REPO=""
if run_post_comment_in "$NOREMOTE_DIR" 0 "$NUMBER" "$GOOD_FILE"; then
  report "all repo sources fail: expected non-zero exit, got 0"
else
  rc=$?
  [ "$rc" = "1" ] || report "all repo sources fail: expected exit 1, got $rc"
  grep -q "gh repo view" "$OUT/stderr" || report "all repo sources fail: stderr does not name 'gh repo view' as tried: $(cat "$OUT/stderr")"
  grep -q "git remote 'origin'" "$OUT/stderr" || report "all repo sources fail: stderr does not name the git remote as tried: $(cat "$OUT/stderr")"
  grep -qE '^api ' "$OUT/calls.log" && report "all repo sources fail: expected zero gh api (POST/PATCH/GET) calls, got: $(cat "$OUT/calls.log")"
fi
REPO="$REPO_SAVE"

# ---------------------------------------------------------------------------
# 13. Issue #685: an unrecognised flag is a hard argument error, not a
#     silent success. Exit 2 matches stamp-claim.sh's argument-error
#     convention (claims.md § Script), and zero gh api calls are issued —
#     the defect this guarded against was a usage line plus exit 0 with
#     nothing posted.
# ---------------------------------------------------------------------------
rm -rf "$STATE"; mkdir -p "$STATE"
if run_post_comment 0 "$NUMBER" "$GOOD_FILE" --repo "$REPO" --frobnicate; then
  report "unknown flag: expected non-zero exit, got 0 — the exact silent-success defect issue #685 reports"
else
  rc=$?
  [ "$rc" = "2" ] || report "unknown flag: expected exit 2 (stamp-claim.sh's argument-error convention), got $rc"
  grep -q "unknown flag" "$OUT/stderr" || report "unknown flag: stderr does not name the reason: $(cat "$OUT/stderr")"
  [ -s "$OUT/calls.log" ] && report "unknown flag: expected zero gh api calls, got: $(cat "$OUT/calls.log")"
fi

# 13b. Issue #685's own reported repro shape verbatim: `--body-file`
# guessed instead of the positional form. Still an unknown flag (this
# script never grew a --body-file alias), so it is caught at the very
# first argument, before <issue-or-pr-number>/<body-file> are even looked
# at — exits non-zero and posts nothing, per #685's own Acceptance
# Criteria wording.
rm -rf "$STATE"; mkdir -p "$STATE"
if run_post_comment 0 --body-file "x" "$NUMBER" --repo "$REPO"; then
  report "issue #685 repro (--body-file x $NUMBER): expected non-zero exit, got 0"
else
  rc=$?
  [ "$rc" -ne 0 ] || report "issue #685 repro: exit code must be non-zero, got $rc"
  [ -s "$OUT/calls.log" ] && report "issue #685 repro: expected zero gh api calls, got: $(cat "$OUT/calls.log")"
fi

# ---------------------------------------------------------------------------
# 14. Hermeticity tripwire (#549, following tests/README.md's convention
#     and #477): the mock recorded every invocation it served, and none of
#     them arrived from a context the harness did not set up. A case that
#     stopped routing through run_post_comment() would reach the real,
#     authenticated gh; here it is logged as UNMOCKED-CONTEXT and reported
#     as a named assertion failure instead.
#
#     The tripwire is proved load-bearing first, against its own throwaway
#     log: the script under test is run with the mock on PATH but WITHOUT
#     the per-run harness env, and the marker must appear.
# ---------------------------------------------------------------------------
TRIPWIRE_LOG="$OUT/tripwire-probe.log"
: > "$TRIPWIRE_LOG"
set +e
env -u MOCK_GH_STATE -u MOCK_GH_CALLS \
  PATH="$BIN:$PATH" MOCK_GH_CALL_LOG="$TRIPWIRE_LOG" \
  "$POST_COMMENT_SH" "$NUMBER" "$GOOD_FILE" >/dev/null 2>&1
set -e
grep -q '^UNMOCKED-CONTEXT ' "$TRIPWIRE_LOG" \
  || report "tripwire probe: an unmocked-context gh call was NOT marked — the tripwire is not load-bearing"

[ -s "$MOCK_GH_CALL_LOG" ] \
  || report "hermeticity: the mock recorded zero invocations — the call log is not wired up"
if grep -q '^UNMOCKED-CONTEXT ' "$MOCK_GH_CALL_LOG"; then
  report "hermeticity: a gh call was made from an unmocked context: $(grep -m1 '^UNMOCKED-CONTEXT ' "$MOCK_GH_CALL_LOG")"
fi

if [ "$fail" -eq 0 ]; then
  echo "test_post_comment.sh: all checks passed"
  exit 0
else
  exit 1
fi
