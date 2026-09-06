#!/usr/bin/env bash
# test_save_log.sh — fixture-driven regression test for save-log.sh.
# Follows the mock-`gh` harness conventions in tests/README.md: a mocked
# `gh` binary on PATH serves fixture responses from a private mktemp
# scratch dir, and no real network call is ever reachable. Pinned to
# LANG=C / LC_ALL=C — nothing in save-log.sh's own parsing is
# locale-sensitive, and pinning here catches a future regression that
# would make it so. `git hash-object` is the one real (non-mocked) command
# the script shells out to — it needs no network and is deterministic, so
# leaving it real (rather than faking a sha) is what actually proves the
# script compares against the real blob-hash algorithm the Contents API
# uses, not a stand-in.
#
# Like stamp-claim.sh, save-log.sh is a WRITER (a Contents-API PUT), so the
# mock records every PUT call it sees to $OUT/mutations.log — one JSON
# object per line — so a refusal or skip path can be proven to have issued
# none, and a changed-content path can be proven to carry the exact
# previous sha rather than a guessed or omitted one. The PUT body never
# arrives as a `-f` argument: the mock REFUSES `-f content=` outright (a
# deliberate regression guard — a base64 body in a single argv element
# dies at MAX_ARG_STRLEN long before the 1 MB bound this script
# advertises) and instead reads the JSON body from the file named by
# `--input`, exactly as the real API would. Each PUT's base64 `content` is
# decoded to its own file under $OUT/bodies (`put-<n>.bin`), so a test
# asserts byte-identity with `cmp` against the real local file rather than
# re-deriving a hash; `message`, `sha`, `sha_given` and the decoded
# `body_file`/`body_sha` are what land in mutations.log, never `content`
# itself.
#
# Covers (per issue #264's Acceptance Criteria):
#  - first save: remote GET 404s -> exactly one PUT, carrying no `sha` key
#    at all (a create, not an update).
#  - unchanged: remote sha equals `git hash-object` of the local file ->
#    zero PUTs, "unchanged, skipped" on stdout.
#  - changed: remote sha differs -> exactly one PUT, carrying the previous
#    (pre-change) sha, not the new local one.
#  - conflict: first PUT 409s -> exactly one re-GET, then exactly one more
#    PUT (two PUTs total) carrying the freshly re-GET'd sha, not the stale
#    one from the first GET.
#  - not configured: no --archive and no "Session-log archive:" line (and,
#    separately, the documented "none — ..." fallback line) -> exit 2,
#    zero calls of any kind (no GET, no PUT, no repo-view) — including a
#    dedicated case with --repo OMITTED, proving the not-configured gate
#    runs before REPO resolution, not just that a passed --repo is unused.
#  - missing session-start event -> hard failure, zero calls of any kind
#    (the path cannot be derived, so nothing is even attempted).
#  - mutation probes: the "unchanged" and "changed" paths are re-run with
#    the mock configured to make the *wrong* choice detectable — an
#    unchanged run that issued any PUT, or a changed run whose PUT sha
#    doesn't match the pre-change remote sha, fails the assertion, proving
#    those guards are load-bearing rather than incidentally true.
#  - dry-run issues no PUT and appends no log line, on both the unchanged
#    and changed paths.
#  - --log: a successful (non-dry-run) archive appends exactly one `note`
#    event line, carrying the required `claim` key (null unless --claim is
#    passed), to the same file it just archived. The note reaches the
#    WORKING COPY that gets hashed and PUT before the hash, but reaches the
#    LIVE --log only AFTER the PUT is confirmed, and by a single `>>`
#    append rather than a copy-back — --log is append-only
#    (formats/session-log.md) and the heartbeat cron is live at this point
#    in the close checklist. So the guarantee is a SUPERSET, not
#    unconditional byte-identity: the local file equals the archived blob
#    when nothing was appended during the PUT, and is a strict superset of
#    it when something raced in (see the concurrent-append bullet below),
#    never a truncation of it. An unsuccessful run (not-configured,
#    malformed --repo/--archive, missing session-start, failed PUT)
#    appends nothing at all.
#  - input validation is WHOLE-STRING: --repo, --archive and the log's own
#    ts/session_id are each refused, with zero gh calls, when they carry an
#    embedded newline or carriage return whose FIRST line would have
#    conformed — the bypass a line-oriented `printf | grep -Eq '^...$'`
#    validator admits — and --repo/--archive are refused for a `.` or `..`
#    segment, which the owner/name character class alone would accept
#    (`../..`).
#  - three consecutive saves against the same accumulating file with zero
#    session activity between them issue exactly ONE PUT total (the
#    first), not three — the stateful regression for the append-before-
#    hash design; the second and third runs must both take the
#    "unchanged, skipped" path.
#  - --claim: the appended note line carries the caller-supplied claim id.
#  - the 1 MB bound, three ways: a file over the limit is refused before
#    any call; a file at EXACTLY the limit is refused too, because the
#    post-append candidate is what the API must accept and it is over;
#    and a file just UNDER the limit (~960 KB — an order of magnitude past
#    the ~93 KB ceiling an argv-borne base64 payload imposes) archives
#    successfully, with the decoded PUT body byte-identical to the local
#    file. That last case is the regression guard for the payload leaving
#    argv: the mock refuses `-f content=` outright, and no fixture in the
#    band the script advertises could pass while the payload rode in a
#    shell word.
#  - concurrent append during the PUT: an event written to --log while the
#    PUT is in flight SURVIVES in the local file (the write-back is an
#    append of the note line, never a copy of the pre-PUT snapshot back
#    over the file), the archived blob still holds the snapshot + note,
#    and the next two saves converge after exactly one extra PUT.
set -euo pipefail
export LANG=C LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SAVE_LOG_SH="$SCRIPT_DIR/../scripts/save-log.sh"
STALL_CHECK_SH="$SCRIPT_DIR/../scripts/stall-check.sh"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/save-log-test.XXXXXX")"
cleanup(){ rm -rf "$WORK"; }
trap cleanup EXIT

FIXTURES="$WORK/fixtures"
BIN="$WORK/bin"
OUT="$WORK/out"
LOGS="$WORK/logs"
mkdir -p "$FIXTURES" "$BIN" "$OUT" "$LOGS"

WORKING_REPO="test-org/test-repo"
ARCHIVE_REPO="test-org/workflow-logs"
SESSION_ID="s-9f3c"
SESSION_TS="2026-08-30T09:00:00Z"
ARCHIVE_PATH="logs/$WORKING_REPO/${SESSION_TS}-${SESSION_ID}.jsonl"

fail=0
report(){ echo "FAIL: $*" >&2; fail=1; }

# ---------------------------------------------------------------------------
# Session-log fixtures. Two distinct contents (v1/v2) so a "changed" test
# has a genuinely different git-blob sha to compare against; both share the
# same session-start event so the derived archive path is identical.
# ---------------------------------------------------------------------------
mk_log(){ # mk_log <path> <extra-line-or-empty>
  local path="$1" extra="$2"
  {
    printf '{"ts":"%s","event":"session-start","claim":"test-01","session_id":"%s"}\n' "$SESSION_TS" "$SESSION_ID"
    [ -z "$extra" ] || printf '%s\n' "$extra"
  } > "$path"
}
LOG_V1="$LOGS/v1.jsonl"
LOG_V2="$LOGS/v2.jsonl"
mk_log "$LOG_V1" ""
mk_log "$LOG_V2" '{"ts":"2026-08-30T09:05:00Z","event":"startup-item","claim":"test-01","item":"probe"}'
SHA_V1=$(git hash-object "$LOG_V1")
SHA_V2=$(git hash-object "$LOG_V2")
[ "$SHA_V1" != "$SHA_V2" ] || { echo "fixture bug: v1 and v2 hash the same" >&2; exit 1; }

LOG_NO_START="$LOGS/no-start.jsonl"
printf '{"ts":"%s","event":"note","claim":"test-01","text":"no session-start here"}\n' "$SESSION_TS" > "$LOG_NO_START"

WT_CONFIGURED="$WORK/wt-configured.md"
cat > "$WT_CONFIGURED" <<DOC
# Work tracking
Session-log archive: $ARCHIVE_REPO
DOC

WT_NONE="$WORK/wt-none.md"
cat > "$WT_NONE" <<DOC
# Work tracking
Session-log archive: none — session logs stay scratch-only
DOC

WT_ABSENT="$WORK/wt-absent.md"
cat > "$WT_ABSENT" <<DOC
# Work tracking
No archive line here at all.
DOC

# ---------------------------------------------------------------------------
# Mock gh: routes `api repos/<archive>/contents/<path>` (GET vs PUT,
# distinguished by -X/--method) and refuses `repo view` (tests always pass
# --repo, so a call here is itself a defect). Every invocation is appended
# to calls.log; every PUT is additionally appended to mutations.log — read
# off the `--input` file the PUT actually carried, never a `-f` argument
# (see the header above) — so a skip/refusal path can prove zero PUTs and
# a real PUT can be checked for the exact sha it carried.
#
# $MOCK_GH_MODE selects the GET/PUT script for the contents endpoint:
#   404       - GET always 404s (first save).
#   match     - GET always returns $MOCK_GH_SHA (unchanged).
#   mismatch  - GET always returns $MOCK_GH_SHA (a sha that differs from
#               the local file, i.e. a changed-content run).
#   conflict  - first GET returns $MOCK_GH_OLD_SHA; the first PUT 409s;
#               the second GET (the re-GET after the conflict) returns
#               $MOCK_GH_NEW_SHA; the second PUT succeeds.
#   get-decoy-500 - GET fails with a genuine HTTP 500 whose message text
#               happens to embed the digits "404" and "409" OUTSIDE the
#               `(HTTP <code>)` suffix (in a fake URL) — a status
#               classifier that substring-matches the whole stderr text
#               would misread this as "first save"; one anchored on the
#               `(HTTP <code>)` form must not.
#   put-decoy-500 - GET 404s (first save); the PUT then fails with a
#               genuine HTTP 500 whose message text embeds "409" and "422"
#               the same decoy way — a substring-matching classifier would
#               misread this as a retryable conflict and re-GET/re-PUT; an
#               anchored one must fail hard after exactly one PUT.
#   get-embedded-code-500 - GET fails with a genuine HTTP 500 whose MESSAGE
#               BODY itself embeds a parenthesised "(HTTP 404)" ahead of
#               the real, trailing "(HTTP 500)" — an UNANCHORED match on
#               `(HTTP 404)` finds the embedded one and misclassifies this
#               as "first save"; only an END-anchored match reads the
#               trailing, authoritative code (issue #594).
# ---------------------------------------------------------------------------
cat > "$BIN/gh" <<'MOCKGH'
#!/usr/bin/env bash
set -euo pipefail
# Hermeticity tripwire (#568, following tests/README.md's convention and
# #477): every invocation is logged before anything else happens, and one
# arriving without the per-run harness env (set only by run_save_log()) is
# recorded as UNMOCKED-CONTEXT instead of silently reaching the real,
# authenticated gh.
: "${MOCK_GH_CALL_LOG:?MOCK_GH_CALL_LOG must be set}"
printf 'CALL gh %s\n' "$*" >> "$MOCK_GH_CALL_LOG"
if [ -z "${MOCK_GH_CALLS:-}" ] || [ -z "${MOCK_GH_MUTATIONS:-}" ] \
  || [ -z "${MOCK_GH_GET_COUNT:-}" ] || [ -z "${MOCK_GH_PUT_COUNT:-}" ] \
  || [ -z "${MOCK_GH_PUT_BODIES:-}" ] || [ -z "${MOCK_GH_MODE:-}" ]; then
  printf 'UNMOCKED-CONTEXT gh %s\n' "$*" >> "$MOCK_GH_CALL_LOG"
  echo "mock gh: invoked with no per-run harness env -- unmocked call context" >&2
  exit 1
fi
: "${MOCK_GH_CALLS:?}"
: "${MOCK_GH_MUTATIONS:?}"
: "${MOCK_GH_GET_COUNT:?}"
: "${MOCK_GH_PUT_COUNT:?}"
: "${MOCK_GH_PUT_BODIES:?}"
: "${MOCK_GH_MODE:?}"

echo "call: $*" >> "$MOCK_GH_CALLS"

if [ "${1:-}" = "repo" ] && [ "${2:-}" = "view" ]; then
  echo "mock gh: repo view should not be called when --repo is passed" >&2
  exit 1
fi

if [ "${1:-}" = "api" ]; then
  shift
  method="GET"
  endpoint=""
  jq_expr=""
  f_message=""; f_sha=""; sha_given=0; input_file=""
  while [ $# -gt 0 ]; do
    case "$1" in
      -X|--method) method="$2"; shift 2 ;;
      --jq) jq_expr="$2"; shift 2 ;;
      --input) input_file="$2"; shift 2 ;;
      -f)
        # The real `gh` still accepts -f, but save-log.sh must never use it
        # for the payload: a base64 body in argv dies at MAX_ARG_STRLEN
        # (131072 bytes), roughly a 93 KB log. Refuse it outright so a
        # regression back to `-f content=` fails loudly here rather than
        # passing on the small fixtures and breaking on real logs.
        case "$2" in
          content=*)
            echo "mock gh: -f content= is refused — the payload must not travel in argv (MAX_ARG_STRLEN); use --input" >&2
            exit 1 ;;
          message=*) f_message="${2#message=}" ;;
          sha=*) f_sha="${2#sha=}"; sha_given=1 ;;
        esac
        shift 2 ;;
      *) endpoint="$1"; shift ;;
    esac
  done

  case "$endpoint" in
    repos/*/contents/*)
      if [ "$method" = "GET" ]; then
        n=$(( $(cat "$MOCK_GH_GET_COUNT") + 1 ))
        echo "$n" > "$MOCK_GH_GET_COUNT"
        case "$MOCK_GH_MODE" in
          404) echo "gh: Not Found (HTTP 404)" >&2; exit 1 ;;
          match|mismatch) sha="$MOCK_GH_SHA" ;;
          conflict)
            if [ "$n" -eq 1 ]; then sha="$MOCK_GH_OLD_SHA"; else sha="$MOCK_GH_NEW_SHA"; fi
            ;;
          put-decoy-500) sha="" ; echo "gh: Not Found (HTTP 404)" >&2; exit 1 ;;
          get-decoy-500)
            echo "gh: Internal Server Error (HTTP 500) — repos/test-org/workflow-logs/contents/logs/test-org/test-repo/2026-08-30T09:00:00Z-session-404-and-409-decoy.jsonl" >&2
            exit 1 ;;
          get-embedded-code-500)
            echo 'gh: Internal server error: upstream said "not found (HTTP 404)" (HTTP 500)' >&2
            exit 1 ;;
          *) echo "mock gh: unknown MOCK_GH_MODE $MOCK_GH_MODE" >&2; exit 1 ;;
        esac
        resp=$(jq -nc --arg sha "$sha" '{sha:$sha}')
        if [ -n "$jq_expr" ]; then jq -r "$jq_expr" <<<"$resp"; else printf '%s\n' "$resp"; fi
      elif [ "$method" = "PUT" ]; then
        n=$(( $(cat "$MOCK_GH_PUT_COUNT") + 1 ))
        echo "$n" > "$MOCK_GH_PUT_COUNT"
        [ -n "$input_file" ] \
          || { echo "mock gh: PUT arrived without --input — the JSON body must be a file, not argv" >&2; exit 1; }
        [ -f "$input_file" ] \
          || { echo "mock gh: --input names a file that does not exist: $input_file" >&2; exit 1; }
        # Read the body off the file exactly as the real API would, and
        # DECODE the base64 payload to its own file so a test can assert
        # byte-identity against the log rather than re-deriving a hash.
        f_message=$(jq -r '.message // ""' "$input_file")
        if jq -e 'has("sha")' "$input_file" >/dev/null; then
          f_sha=$(jq -r '.sha' "$input_file"); sha_given=1
        else
          f_sha=""; sha_given=0
        fi
        body_file="$MOCK_GH_PUT_BODIES/put-$n.bin"
        jq -r '.content' "$input_file" | base64 -d > "$body_file"
        body_sha=$(git hash-object "$body_file")
        if [ "$sha_given" -eq 1 ]; then
          jq -nc --arg message "$f_message" --arg sha "$f_sha" \
            --arg body_file "$body_file" --arg body_sha "$body_sha" \
            '{message:$message, sha:$sha, sha_given:true, body_file:$body_file, body_sha:$body_sha}' >> "$MOCK_GH_MUTATIONS"
        else
          jq -nc --arg message "$f_message" \
            --arg body_file "$body_file" --arg body_sha "$body_sha" \
            '{message:$message, sha_given:false, body_file:$body_file, body_sha:$body_sha}' >> "$MOCK_GH_MUTATIONS"
        fi
        # An optional delay makes the PUT observably slow, so a test can
        # append to --log while this call is genuinely in flight.
        [ -z "${MOCK_GH_PUT_DELAY:-}" ] || { : > "$MOCK_GH_PUT_BODIES/put-started"; sleep "$MOCK_GH_PUT_DELAY"; }
        if [ "$MOCK_GH_MODE" = "conflict" ] && [ "$n" -eq 1 ]; then
          echo "gh: Unprocessable Entity (HTTP 422)" >&2
          exit 1
        fi
        if [ "$MOCK_GH_MODE" = "put-decoy-500" ]; then
          echo "gh: Internal Server Error (HTTP 500) — repos/test-org/workflow-logs/contents/logs/test-org/test-repo/2026-08-30T09:00:00Z-session-409-and-422-decoy.jsonl" >&2
          exit 1
        fi
        resp=$(jq -nc '{content:{sha:"newsha"}, commit:{html_url:"https://example.invalid/commit/abc123"}}')
        printf '%s\n' "$resp"
      else
        echo "mock gh: unsupported method $method on $endpoint" >&2
        exit 1
      fi
      ;;
    *)
      echo "mock gh: unknown endpoint: $endpoint" >&2
      exit 1 ;;
  esac
  exit 0
fi

echo "mock gh: unsupported command: $*" >&2
exit 1
MOCKGH
chmod +x "$BIN/gh"

export MOCK_GH_CALL_LOG="$OUT/gh-calls.log"
: > "$MOCK_GH_CALL_LOG"

run_save_log(){ # run_save_log <mode> <sha-or-empty> <old-sha-or-empty> <new-sha-or-empty> <log-file> <args...>
  local mode="$1" sha="$2" old="$3" new="$4" logfile="$5"; shift 5
  : > "$OUT/calls.log"
  : > "$OUT/mutations.log"
  echo 0 > "$OUT/get_count"
  echo 0 > "$OUT/put_count"
  rm -rf "$OUT/bodies"; mkdir -p "$OUT/bodies"
  local rc=0
  set +e
  MOCK_GH_CALLS="$OUT/calls.log" MOCK_GH_MUTATIONS="$OUT/mutations.log" \
    MOCK_GH_GET_COUNT="$OUT/get_count" MOCK_GH_PUT_COUNT="$OUT/put_count" \
    MOCK_GH_PUT_BODIES="$OUT/bodies" \
    MOCK_GH_MODE="$mode" MOCK_GH_SHA="$sha" MOCK_GH_OLD_SHA="$old" MOCK_GH_NEW_SHA="$new" \
    PATH="$BIN:$PATH" \
    "$SAVE_LOG_SH" --log "$logfile" --repo "$WORKING_REPO" "$@" \
    > "$OUT/run.stdout.log" 2> "$OUT/run.stderr.log"
  rc=$?
  set -e
  if [ "$rc" -gt 100 ]; then
    echo "--- stdout ---" >&2; cat "$OUT/run.stdout.log" >&2
    echo "--- stderr ---" >&2; cat "$OUT/run.stderr.log" >&2
  fi
  return $rc
}
n_calls(){ wc -l < "$OUT/calls.log" | tr -d ' '; }
n_puts(){ [ -f "$OUT/mutations.log" ] && wc -l < "$OUT/mutations.log" | tr -d ' ' || echo 0; }

# ---------------------------------------------------------------------------
# first save: GET 404s -> exactly one PUT, no sha key at all.
# ---------------------------------------------------------------------------
cp "$LOG_V1" "$WORK/first.jsonl"
RC=0; run_save_log "404" "" "" "" "$WORK/first.jsonl" --archive "$ARCHIVE_REPO" || RC=$?
[ "$RC" -eq 0 ] || report "first save: expected exit 0, got $RC — $(cat "$OUT/run.stderr.log")"
[ "$(n_puts)" = "1" ] || report "first save: expected exactly 1 PUT, got $(n_puts)"
mut=$(tail -1 "$OUT/mutations.log")
[ "$(jq -r .sha_given <<<"$mut")" = "false" ] || report "first save: PUT unexpectedly carried a sha: $mut"
grep -q "$ARCHIVE_REPO:$ARCHIVE_PATH" "$OUT/run.stdout.log" \
  || report "first save: stdout did not name the archive path — $(cat "$OUT/run.stdout.log")"
grep -q "https://example.invalid/commit/abc123" "$OUT/run.stdout.log" \
  || report "first save: stdout did not name the commit URL"
NOTES=$(jq -c 'select(.event=="note")' "$WORK/first.jsonl")
[ -n "$NOTES" ] || report "first save: no note event appended to the log after success"
[ "$(jq -c 'select(.event=="note")' "$WORK/first.jsonl" | wc -l | tr -d ' ')" = "1" ] \
  || report "first save: expected exactly one appended note line"
[ "$(jq -r 'has("claim")' <<<"$NOTES")" = "true" ] \
  || report "first save: appended note line is missing the required claim key (formats/session-log.md) — $NOTES"
[ "$(jq -r '.claim' <<<"$NOTES")" = "null" ] \
  || report "first save: appended note line's claim should be null when --claim was not passed — $NOTES"

# -----------------------------------------------------------------------
# Issue #743/#754: pin the appended note line's ts to formats/session-log.md's
# exact, second-precision form (YYYY-MM-DDTHH:MM:SSZ) — not merely "jq -e .ts
# exists", which the pre-#754 minute-precision bug also satisfied. A fixture
# that only checks presence cannot tell buggy from fixed; see the splice
# test in the PR body that proves this one can.
# -----------------------------------------------------------------------
note_ts="$(jq -r .ts <<<"$NOTES")"
[[ "$note_ts" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] \
  || report "first save: note ts '$note_ts' is not exactly YYYY-MM-DDTHH:MM:SSZ (session-log.md, issue #743/#754)"

# Round-trip fixture (issue #743/#754): the note line save-log.sh actually
# appended to the local log must not be skipped by stall-check.sh's ts_ok
# predicate — a healthy over-limit agent recorded beside it in the same log
# is still reported, proving the reader consumed the writer's own line
# rather than discarding it as malformed/unsupported-precision.
RT_LOG="$WORK/roundtrip.jsonl"
cp "$WORK/first.jsonl" "$RT_LOG"
RT_OLD_TS="$(date -u -d '90 minutes ago' +%FT%TZ)"
printf '%s\n' "{\"ts\":\"$RT_OLD_TS\",\"event\":\"dispatch\",\"claim\":\"c\",\"role\":\"implementer\",\"agent\":\"rt1\",\"pr\":9500,\"issue\":950}" >> "$RT_LOG"
rt_out="$(bash "$STALL_CHECK_SH" 60 "$RT_LOG" 2>"$WORK/roundtrip-stderr")" && rt_rc=0 || rt_rc=$?
[ "$rt_rc" -eq 1 ] || report "round-trip: expected exit 1 (rt1 idle over limit), got $rt_rc — stderr: $(cat "$WORK/roundtrip-stderr")"
echo "$rt_out" | grep -q '^  rt1 dispatch' \
  || report "round-trip: rt1 (healthy, over limit) was not reported alongside save-log.sh's own note line"
grep -qi 'unsupported precision\|malformed' "$WORK/roundtrip-stderr" \
  && report "round-trip: save-log.sh's own appended note line was rejected by stall-check.sh's ts_ok: $(cat "$WORK/roundtrip-stderr")"

# Nothing raced during this PUT, so the superset guarantee collapses to
# equality here: the file on disk right now must be BYTE-IDENTICAL to the
# decoded payload the PUT actually carried (the write-back appended the
# same single note line the archived working copy carries). Compared
# against the mock's decoded body file rather than a re-derived hash, so a
# payload-encoding regression is caught as a content diff. The racing case
# — where the local file is a strict superset instead — is covered by the
# concurrent-append case further down.
cmp -s "$WORK/first.jsonl" "$(jq -r .body_file <<<"$mut")" \
  || report "first save: local file after append is not byte-identical to the decoded content that was PUT"

# ---------------------------------------------------------------------------
# --claim: the appended note line carries the caller-supplied claim id.
# ---------------------------------------------------------------------------
cp "$LOG_V1" "$WORK/claimed.jsonl"
RC=0; run_save_log "404" "" "" "" "$WORK/claimed.jsonl" --archive "$ARCHIVE_REPO" --claim "264-fix1" || RC=$?
[ "$RC" -eq 0 ] || report "--claim: expected exit 0, got $RC — $(cat "$OUT/run.stderr.log")"
CLAIMED_NOTE=$(jq -c 'select(.event=="note")' "$WORK/claimed.jsonl")
[ "$(jq -r '.claim' <<<"$CLAIMED_NOTE")" = "264-fix1" ] \
  || report "--claim: appended note line did not carry the passed claim id — $CLAIMED_NOTE"

# ---------------------------------------------------------------------------
# unchanged: remote sha == local git-blob sha -> zero PUTs.
# ---------------------------------------------------------------------------
cp "$LOG_V1" "$WORK/unchanged.jsonl"
RC=0; run_save_log "match" "$SHA_V1" "" "" "$WORK/unchanged.jsonl" --archive "$ARCHIVE_REPO" || RC=$?
[ "$RC" -eq 0 ] || report "unchanged: expected exit 0, got $RC — $(cat "$OUT/run.stderr.log")"
[ "$(n_puts)" = "0" ] || report "unchanged: expected zero PUTs, got $(n_puts)"
grep -qi "unchanged, skipped" "$OUT/run.stdout.log" \
  || report "unchanged: stdout did not report 'unchanged, skipped' — $(cat "$OUT/run.stdout.log")"
[ "$(jq -c 'select(.event=="note")' "$WORK/unchanged.jsonl" 2>/dev/null | wc -l | tr -d ' ')" = "0" ] \
  || report "unchanged: a note line was appended even though nothing was archived — mutation probe: the unchanged path must not silently start logging"

# Mutation probe: force the mock's GET to instead report a DIFFERENT sha
# (mismatch mode with the local file's own sha withheld) and confirm a
# real PUT is issued — proving the "match" case above was actually
# comparing shas, not always skipping regardless of input.
cp "$LOG_V1" "$WORK/probe-not-actually-unchanged.jsonl"
RC=0; run_save_log "mismatch" "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" "" "" \
  "$WORK/probe-not-actually-unchanged.jsonl" --archive "$ARCHIVE_REPO" || RC=$?
[ "$RC" -eq 0 ] || report "probe (not actually unchanged): expected exit 0, got $RC"
[ "$(n_puts)" = "1" ] \
  || report "probe (not actually unchanged): expected exactly 1 PUT once the remote sha genuinely differs — got $(n_puts); the unchanged guard may be short-circuiting unconditionally"

# ---------------------------------------------------------------------------
# changed: remote sha differs from local -> exactly one PUT carrying the
# PREVIOUS (remote) sha, not the new local one.
# ---------------------------------------------------------------------------
OLD_SHA_FOR_CHANGE="cafebabecafebabecafebabecafebabecafebabe"
cp "$LOG_V2" "$WORK/changed.jsonl"
RC=0; run_save_log "mismatch" "$OLD_SHA_FOR_CHANGE" "" "" "$WORK/changed.jsonl" --archive "$ARCHIVE_REPO" || RC=$?
[ "$RC" -eq 0 ] || report "changed: expected exit 0, got $RC — $(cat "$OUT/run.stderr.log")"
[ "$(n_puts)" = "1" ] || report "changed: expected exactly 1 PUT, got $(n_puts)"
mut=$(tail -1 "$OUT/mutations.log")
[ "$(jq -r .sha_given <<<"$mut")" = "true" ] || report "changed: PUT did not carry a sha at all: $mut"
[ "$(jq -r .sha <<<"$mut")" = "$OLD_SHA_FOR_CHANGE" ] \
  || report "changed: PUT carried the wrong sha — expected the previous remote sha $OLD_SHA_FOR_CHANGE, got: $(jq -r .sha <<<"$mut")"
[ "$(jq -r .sha <<<"$mut")" != "$SHA_V2" ] \
  || report "changed: PUT's sha equals the NEW local sha — mutation probe: this must be the previous remote sha, not the file being uploaded"

# ---------------------------------------------------------------------------
# F1 regression: three consecutive saves against the SAME accumulating file
# with zero session activity in between issue exactly ONE PUT (the first),
# not three. The append-before-hash design means the second and third runs'
# GET returns the exact sha the first run's PUT carried, and the local file
# (which already has the first run's note appended) hashes to that same
# value, so both later runs take the "unchanged, skipped" path with zero
# PUTs. This is the stateful probe the round-1 review ran by hand; it fails
# against the pre-fix code (which issued three PUTs and never skipped).
# ---------------------------------------------------------------------------
cp "$LOG_V1" "$WORK/three-saves.jsonl"
RC=0; run_save_log "404" "" "" "" "$WORK/three-saves.jsonl" --archive "$ARCHIVE_REPO" || RC=$?
[ "$RC" -eq 0 ] || report "three-saves run1: expected exit 0, got $RC — $(cat "$OUT/run.stderr.log")"
[ "$(n_puts)" = "1" ] || report "three-saves run1: expected exactly 1 PUT, got $(n_puts)"
SHA_AFTER_1=$(git hash-object "$WORK/three-saves.jsonl")

RC=0; run_save_log "match" "$SHA_AFTER_1" "" "" "$WORK/three-saves.jsonl" --archive "$ARCHIVE_REPO" || RC=$?
[ "$RC" -eq 0 ] || report "three-saves run2: expected exit 0, got $RC — $(cat "$OUT/run.stderr.log")"
[ "$(n_puts)" = "0" ] \
  || report "three-saves run2: expected 0 PUTs (F1: unchanged skip must be reachable after a save), got $(n_puts)"
grep -qi "unchanged, skipped" "$OUT/run.stdout.log" \
  || report "three-saves run2: expected 'unchanged, skipped' on stdout — $(cat "$OUT/run.stdout.log")"
SHA_AFTER_2=$(git hash-object "$WORK/three-saves.jsonl")
[ "$SHA_AFTER_2" = "$SHA_AFTER_1" ] \
  || report "three-saves run2: local file changed despite the skip path (no PUT should mean no append either)"

RC=0; run_save_log "match" "$SHA_AFTER_2" "" "" "$WORK/three-saves.jsonl" --archive "$ARCHIVE_REPO" || RC=$?
[ "$RC" -eq 0 ] || report "three-saves run3: expected exit 0, got $RC — $(cat "$OUT/run.stderr.log")"
[ "$(n_puts)" = "0" ] \
  || report "three-saves run3: expected 0 PUTs (F1: unchanged skip must stay reachable on the SECOND repeat too), got $(n_puts)"
grep -qi "unchanged, skipped" "$OUT/run.stdout.log" \
  || report "three-saves run3: expected 'unchanged, skipped' on stdout — $(cat "$OUT/run.stdout.log")"

# ---------------------------------------------------------------------------
# F(round-2) regression: a concurrent append DURING the PUT survives.
#
# formats/session-log.md declares the session log append-only, and
# templates/session-card.md orders the close checklist so save-log runs
# while the heartbeat cron is still live — so an event landing in --log
# during the network call is expected, not exotic. The pre-fix code copied
# a snapshot taken before the PUT back over --log, silently destroying it
# while exiting 0. This drives a real background writer against a
# deliberately slow (delayed) mocked PUT and asserts the raced line is
# still there afterwards. Against the old `cp "$CANDIDATE" "$LOG_PATH"`
# write-back it fails on the very first assertion below.
# ---------------------------------------------------------------------------
CONC_LOG="$WORK/concurrent.jsonl"
cp "$LOG_V1" "$CONC_LOG"
CONC_BASE_LINES=$(wc -l < "$CONC_LOG" | tr -d ' ')
RACE_LINE='{"ts":"2026-08-30T09:07:00Z","event":"heartbeat","claim":"test-01","text":"appended while the PUT was in flight"}'

: > "$OUT/calls.log"; : > "$OUT/mutations.log"
echo 0 > "$OUT/get_count"; echo 0 > "$OUT/put_count"
rm -rf "$OUT/bodies"; mkdir -p "$OUT/bodies"
set +e
MOCK_GH_CALLS="$OUT/calls.log" MOCK_GH_MUTATIONS="$OUT/mutations.log" \
  MOCK_GH_GET_COUNT="$OUT/get_count" MOCK_GH_PUT_COUNT="$OUT/put_count" \
  MOCK_GH_PUT_BODIES="$OUT/bodies" MOCK_GH_PUT_DELAY=3 \
  MOCK_GH_MODE="404" MOCK_GH_SHA="" MOCK_GH_OLD_SHA="" MOCK_GH_NEW_SHA="" \
  PATH="$BIN:$PATH" \
  "$SAVE_LOG_SH" --log "$CONC_LOG" --repo "$WORKING_REPO" --archive "$ARCHIVE_REPO" \
  > "$OUT/run.stdout.log" 2> "$OUT/run.stderr.log" &
CONC_PID=$!
set -e
# Bounded wait for the PUT to actually be in flight (the mock touches
# put-started before it sleeps) — never a blind sleep.
waited=0
while [ ! -f "$OUT/bodies/put-started" ] && [ "$waited" -lt 150 ]; do
  sleep 0.1; waited=$((waited + 1))
done
[ -f "$OUT/bodies/put-started" ] \
  || report "concurrent append: the mocked PUT never signalled that it was in flight — the race could not be staged"
printf '%s\n' "$RACE_LINE" >> "$CONC_LOG"
RC=0; set +e; wait "$CONC_PID"; RC=$?; set -e

[ "$RC" -eq 0 ] || report "concurrent append: expected exit 0, got $RC — $(cat "$OUT/run.stderr.log")"
[ "$(n_puts)" = "1" ] || report "concurrent append: expected exactly 1 PUT, got $(n_puts)"
# THE regression: the raced line must still be in the local log.
grep -qF "appended while the PUT was in flight" "$CONC_LOG" \
  || report "concurrent append: the event appended to --log during the PUT was DESTROYED by the write-back — the local log must never be overwritten with a pre-PUT snapshot"
[ "$(jq -c 'select(.event=="note")' "$CONC_LOG" | wc -l | tr -d ' ')" = "1" ] \
  || report "concurrent append: expected exactly one appended note line in the local log"
[ "$(wc -l < "$CONC_LOG" | tr -d ' ')" = "$((CONC_BASE_LINES + 2))" ] \
  || report "concurrent append: local log should hold the original lines plus the raced line plus one note — got $(wc -l < "$CONC_LOG" | tr -d ' ') lines"

# The archived blob is the pre-PUT snapshot plus the same note line: it
# does NOT carry the raced event (it could not — it was encoded before the
# race), and the local file is a strict SUPERSET of it, never a truncation.
conc_mut=$(tail -1 "$OUT/mutations.log")
CONC_BODY=$(jq -r .body_file <<<"$conc_mut")
if grep -qF "appended while the PUT was in flight" "$CONC_BODY"; then
  report "concurrent append: the blob unexpectedly contains the raced event — it was encoded before the race, so this assertion is mis-staged"
fi
while IFS= read -r blob_line; do
  grep -qxF "$blob_line" "$CONC_LOG" \
    || report "concurrent append: a line present in the archived blob is missing from the local log — the local file must be a superset of the blob: $blob_line"
done < "$CONC_BODY"
if cmp -s "$CONC_LOG" "$CONC_BODY"; then
  report "concurrent append: local log and blob are byte-identical, so the race did not actually happen — the test is not exercising the defect"
fi

# Convergence: because the local file is now a superset, the NEXT save
# sees a mismatch and PUTs the fuller file (one extra PUT), and the save
# after that skips with zero PUTs. This is the documented cost of never
# overwriting the log, and it must actually terminate.
CONC_BLOB_SHA=$(jq -r .body_sha <<<"$conc_mut")
RC=0; run_save_log "mismatch" "$CONC_BLOB_SHA" "" "" "$CONC_LOG" --archive "$ARCHIVE_REPO" || RC=$?
[ "$RC" -eq 0 ] || report "concurrent append convergence run2: expected exit 0, got $RC — $(cat "$OUT/run.stderr.log")"
[ "$(n_puts)" = "1" ] \
  || report "concurrent append convergence run2: expected exactly 1 catch-up PUT, got $(n_puts)"
conc_mut2=$(tail -1 "$OUT/mutations.log")
grep -qF "appended while the PUT was in flight" "$(jq -r .body_file <<<"$conc_mut2")" \
  || report "concurrent append convergence run2: the catch-up PUT still does not carry the raced event"
CONC_SHA_AFTER_2=$(git hash-object "$CONC_LOG")
[ "$CONC_SHA_AFTER_2" = "$(jq -r .body_sha <<<"$conc_mut2")" ] \
  || report "concurrent append convergence run2: local log does not hash to what was just PUT — the design has stopped converging"

RC=0; run_save_log "match" "$CONC_SHA_AFTER_2" "" "" "$CONC_LOG" --archive "$ARCHIVE_REPO" || RC=$?
[ "$RC" -eq 0 ] || report "concurrent append convergence run3: expected exit 0, got $RC — $(cat "$OUT/run.stderr.log")"
[ "$(n_puts)" = "0" ] \
  || report "concurrent append convergence run3: expected 0 PUTs (converged), got $(n_puts) — the extra-PUT cost must be ONE, not perpetual"

# ---------------------------------------------------------------------------
# conflict: first PUT 409/422s -> exactly one re-GET, then one more PUT
# (two PUTs total) carrying the FRESH sha, not the stale first-GET one.
# ---------------------------------------------------------------------------
OLD_SHA="1111111111111111111111111111111111111111"
NEW_SHA="2222222222222222222222222222222222222222"
cp "$LOG_V2" "$WORK/conflict.jsonl"
RC=0; run_save_log "conflict" "" "$OLD_SHA" "$NEW_SHA" "$WORK/conflict.jsonl" --archive "$ARCHIVE_REPO" || RC=$?
[ "$RC" -eq 0 ] || report "conflict: expected exit 0 after the retry, got $RC — $(cat "$OUT/run.stderr.log")"
[ "$(cat "$OUT/get_count")" = "2" ] || report "conflict: expected exactly 2 GETs (initial + one re-GET), got $(cat "$OUT/get_count")"
[ "$(n_puts)" = "2" ] || report "conflict: expected exactly 2 PUTs (failed + retried), got $(n_puts)"
first_put=$(sed -n '1p' "$OUT/mutations.log")
second_put=$(sed -n '2p' "$OUT/mutations.log")
[ "$(jq -r .sha <<<"$first_put")" = "$OLD_SHA" ] \
  || report "conflict: first PUT should carry the stale (first-GET) sha $OLD_SHA, got: $(jq -r .sha <<<"$first_put")"
[ "$(jq -r .sha <<<"$second_put")" = "$NEW_SHA" ] \
  || report "conflict: retried PUT should carry the fresh (re-GET) sha $NEW_SHA, got: $(jq -r .sha <<<"$second_put")"

# ---------------------------------------------------------------------------
# not configured: --archive absent, no "Session-log archive:" line at all
# -> exit 2, zero calls of any kind.
# ---------------------------------------------------------------------------
cp "$LOG_V1" "$WORK/not-configured.jsonl"
RC=0; run_save_log "404" "" "" "" "$WORK/not-configured.jsonl" --work-tracking "$WT_ABSENT" || RC=$?
[ "$RC" -eq 2 ] || report "not configured (absent line): expected exit 2, got $RC — $(cat "$OUT/run.stderr.log")"
[ "$(n_calls)" = "0" ] || report "not configured (absent line): expected zero gh calls, got $(n_calls) — $(cat "$OUT/calls.log")"
grep -qi "archive not configured" "$OUT/run.stderr.log" \
  || report "not configured (absent line): stderr did not name the configured error"

# Same not-configured outcome via the documented "none — ..." fallback line.
cp "$LOG_V1" "$WORK/not-configured-none.jsonl"
RC=0; run_save_log "404" "" "" "" "$WORK/not-configured-none.jsonl" --work-tracking "$WT_NONE" || RC=$?
[ "$RC" -eq 2 ] || report "not configured (none line): expected exit 2, got $RC — $(cat "$OUT/run.stderr.log")"
[ "$(n_calls)" = "0" ] || report "not configured (none line): expected zero gh calls, got $(n_calls)"

# ---------------------------------------------------------------------------
# #746: a markdown TABLE ROW naming the archive — the format every other
# configured value in work-tracking.md uses — is read, not just the bare
# line. Value optionally backtick-wrapped; label matched
# case-insensitively.
# ---------------------------------------------------------------------------
WT_TABLE_ROW="$WORK/wt-table-row.md"
cat > "$WT_TABLE_ROW" <<DOC
# Work tracking

| Field | Value |
|---|---|
| Session-log archive | $ARCHIVE_REPO |
DOC
cp "$LOG_V1" "$WORK/table-row.jsonl"
RC=0; run_save_log "404" "" "" "" "$WORK/table-row.jsonl" --work-tracking "$WT_TABLE_ROW" || RC=$?
[ "$RC" -eq 0 ] || report "table-row archive line (#746): expected exit 0, got $RC — $(cat "$OUT/run.stderr.log")"
[ "$(n_puts)" = "1" ] || report "table-row archive line (#746): expected exactly 1 PUT, got $(n_puts)"
grep -q "$ARCHIVE_REPO" "$OUT/run.stdout.log" \
  || report "table-row archive line (#746): stdout did not name the archive parsed from the table row"

WT_TABLE_ROW_BACKTICK="$WORK/wt-table-row-backtick.md"
cat > "$WT_TABLE_ROW_BACKTICK" <<DOC
# Work tracking

| Field | Value |
|---|---|
| Session-log archive | \`$ARCHIVE_REPO\` |
DOC
cp "$LOG_V1" "$WORK/table-row-backtick.jsonl"
RC=0; run_save_log "404" "" "" "" "$WORK/table-row-backtick.jsonl" --work-tracking "$WT_TABLE_ROW_BACKTICK" || RC=$?
[ "$RC" -eq 0 ] || report "table-row archive line, backtick-wrapped (#746): expected exit 0, got $RC — $(cat "$OUT/run.stderr.log")"
grep -q "$ARCHIVE_REPO" "$OUT/run.stdout.log" \
  || report "table-row archive line, backtick-wrapped (#746): stdout did not name the archive, backticks were not stripped"

# ---------------------------------------------------------------------------
# #758: CommonMark/GFM permits 0-3 leading spaces before a block-level
# construct (a table row included) without the row losing its meaning; the
# script's table-row regex must accept the same 0-3 and reject 4+ (which
# CommonMark itself reinterprets as an indented code block, not a table
# row). Boundary fixtures at 0, 1, 2, 3 (accepted) and 4 (rejected), plus a
# leading TAB and a mixed tab-then-space lead (both rejected — a tab
# expands to the next multiple-of-4 column in CommonMark, so even one
# leading tab reaches column 4, the same indented-code-block territory as
# four spaces).
# ---------------------------------------------------------------------------
for n in 0 1 2 3; do
  INDENT=$(printf '%*s' "$n" '')
  WT_INDENT="$WORK/wt-table-row-indent-$n.md"
  {
    echo "# Work tracking"
    echo
    echo "| Field | Value |"
    echo "|---|---|"
    printf '%s| Session-log archive | %s |\n' "$INDENT" "$ARCHIVE_REPO"
  } > "$WT_INDENT"
  cp "$LOG_V1" "$WORK/table-row-indent-$n.jsonl"
  RC=0; run_save_log "404" "" "" "" "$WORK/table-row-indent-$n.jsonl" --work-tracking "$WT_INDENT" || RC=$?
  [ "$RC" -eq 0 ] || report "table-row archive line, $n-space indent (#758): expected exit 0, got $RC — $(cat "$OUT/run.stderr.log")"
  grep -q "$ARCHIVE_REPO" "$OUT/run.stdout.log" \
    || report "table-row archive line, $n-space indent (#758): stdout did not name the archive parsed from the indented row"
done

# #758 rejects each of these three as a table row (4+ spaces or a leading
# tab put them in indented-code-block territory), but the label text
# "Session-log archive" is genuinely PRESENT in the document — exactly the
# near-miss #805 was filed to stop misreading as "not configured" (exit 2).
# Each now gets the distinct, loud exit-1 parse-failure instead.
WT_INDENT_4="$WORK/wt-table-row-indent-4.md"
{
  echo "# Work tracking"
  echo
  echo "| Field | Value |"
  echo "|---|---|"
  printf '    | Session-log archive | %s |\n' "$ARCHIVE_REPO"
} > "$WT_INDENT_4"
cp "$LOG_V1" "$WORK/table-row-indent-4.jsonl"
RC=0; run_save_log "404" "" "" "" "$WORK/table-row-indent-4.jsonl" --work-tracking "$WT_INDENT_4" || RC=$?
[ "$RC" -eq 1 ] || report "table-row archive line, 4-space indent (#758/#805): expected exit 1 (present but unparseable — 4 spaces is a code block, not a table row), got $RC — $(cat "$OUT/run.stderr.log")"
[ "$(n_calls)" = "0" ] || report "table-row archive line, 4-space indent (#758/#805): expected zero gh calls, got $(n_calls)"
grep -qi "archive not configured" "$OUT/run.stderr.log" \
  && report "table-row archive line, 4-space indent (#805): reported 'not configured' for a line/row that IS present but malformed — the two causes must stay distinct"
grep -qi "could not be parsed" "$OUT/run.stderr.log" \
  || report "table-row archive line, 4-space indent (#805): stderr did not name the parse failure — $(cat "$OUT/run.stderr.log")"

WT_INDENT_TAB="$WORK/wt-table-row-indent-tab.md"
{
  echo "# Work tracking"
  echo
  echo "| Field | Value |"
  echo "|---|---|"
  printf '\t| Session-log archive | %s |\n' "$ARCHIVE_REPO"
} > "$WT_INDENT_TAB"
cp "$LOG_V1" "$WORK/table-row-indent-tab.jsonl"
RC=0; run_save_log "404" "" "" "" "$WORK/table-row-indent-tab.jsonl" --work-tracking "$WT_INDENT_TAB" || RC=$?
[ "$RC" -eq 1 ] || report "table-row archive line, leading tab (#758/#805): expected exit 1 (present but unparseable — a tab expands past the 3-space boundary), got $RC — $(cat "$OUT/run.stderr.log")"
[ "$(n_calls)" = "0" ] || report "table-row archive line, leading tab (#758/#805): expected zero gh calls, got $(n_calls)"
grep -qi "archive not configured" "$OUT/run.stderr.log" \
  && report "table-row archive line, leading tab (#805): reported 'not configured' for a line/row that IS present but malformed"

WT_INDENT_MIXED="$WORK/wt-table-row-indent-mixed.md"
{
  echo "# Work tracking"
  echo
  echo "| Field | Value |"
  echo "|---|---|"
  printf ' \t| Session-log archive | %s |\n' "$ARCHIVE_REPO"
} > "$WT_INDENT_MIXED"
cp "$LOG_V1" "$WORK/table-row-indent-mixed.jsonl"
RC=0; run_save_log "404" "" "" "" "$WORK/table-row-indent-mixed.jsonl" --work-tracking "$WT_INDENT_MIXED" || RC=$?
[ "$RC" -eq 1 ] || report "table-row archive line, mixed space-then-tab lead (#758/#805): expected exit 1, got $RC — $(cat "$OUT/run.stderr.log")"
[ "$(n_calls)" = "0" ] || report "table-row archive line, mixed space-then-tab lead (#758/#805): expected zero gh calls, got $(n_calls)"
grep -qi "archive not configured" "$OUT/run.stderr.log" \
  && report "table-row archive line, mixed space-then-tab lead (#805): reported 'not configured' for a line/row that IS present but malformed"

# ---------------------------------------------------------------------------
# Issue #805: the genuinely-absent case (no "Session-log archive" text
# anywhere in the document) is unaffected by the above — still the ordinary
# exit-2 not-configured outcome. Re-asserted here, right beside the
# present-but-unparseable cases, so the two are proven distinguishable in
# one place rather than trusting they stay so by accident.
RC=0; run_save_log "404" "" "" "" "$WORK/not-configured.jsonl" --work-tracking "$WT_ABSENT" || RC=$?
[ "$RC" -eq 2 ] || report "#805 control (genuinely absent): expected exit 2, got $RC — $(cat "$OUT/run.stderr.log")"

# Issue #805: a line/row that IS present but shaped like neither the
# bare-line nor the table-row form at all — a filer used a dash instead of
# the documented colon, matching no regex and no CommonMark table syntax —
# must ALSO get the distinct, loud parse failure, not the quiet
# not-configured exit.
WT_NEAR_MISS="$WORK/wt-near-miss.md"
cat > "$WT_NEAR_MISS" <<DOC
# Work tracking
Session-log archive - test-org/near-miss
DOC
cp "$LOG_V1" "$WORK/near-miss.jsonl"
RC=0; run_save_log "404" "" "" "" "$WORK/near-miss.jsonl" --work-tracking "$WT_NEAR_MISS" || RC=$?
[ "$RC" -eq 1 ] || report "near-miss archive line (#805): expected exit 1 (present but unparseable), got $RC — $(cat "$OUT/run.stderr.log")"
[ "$(n_calls)" = "0" ] || report "near-miss archive line (#805): expected zero gh calls, got $(n_calls)"
grep -qi "archive not configured" "$OUT/run.stderr.log" \
  && report "near-miss archive line (#805): reported 'not configured' for a line that IS present but malformed — the two causes must stay distinct"
grep -qi "could not be parsed" "$OUT/run.stderr.log" \
  || report "near-miss archive line (#805): stderr did not name the parse failure — $(cat "$OUT/run.stderr.log")"

# A bare `^Session-log archive:` line wins over a table row when both are
# somehow present — the bare line is tried first, unconditionally.
WT_BOTH_FORMS="$WORK/wt-both-forms.md"
BARE_WINS_REPO="test-org/bare-wins"
cat > "$WT_BOTH_FORMS" <<DOC
# Work tracking
Session-log archive: $BARE_WINS_REPO

| Field | Value |
|---|---|
| Session-log archive | $ARCHIVE_REPO |
DOC
cp "$LOG_V1" "$WORK/both-forms.jsonl"
RC=0; run_save_log "404" "" "" "" "$WORK/both-forms.jsonl" --work-tracking "$WT_BOTH_FORMS" || RC=$?
[ "$RC" -eq 0 ] || report "bare line + table row both present (#746): expected exit 0, got $RC"
grep -q "$BARE_WINS_REPO" "$OUT/run.stdout.log" \
  || report "bare line + table row both present (#746): expected the bare line's repo ($BARE_WINS_REPO) to win, got: $(cat "$OUT/run.stdout.log")"

# ---------------------------------------------------------------------------
# F2 regression: not configured, --repo OMITTED -> exit 2, zero gh calls of
# ANY kind — including no `gh repo view`. run_save_log always passes
# --repo, so this case is invoked directly against the script to actually
# exercise the not-configured gate running before REPO resolution; the
# mock's `repo view` handler fails loudly if it is ever called with --repo
# absent, so a regression here would surface as exit 1 (from the mock's
# failure) rather than the documented exit 2.
# ---------------------------------------------------------------------------
cp "$LOG_V1" "$WORK/not-configured-no-repo.jsonl"
: > "$OUT/calls.log"; : > "$OUT/mutations.log"
echo 0 > "$OUT/get_count"; echo 0 > "$OUT/put_count"
rm -rf "$OUT/bodies"; mkdir -p "$OUT/bodies"
RC=0
set +e
MOCK_GH_CALLS="$OUT/calls.log" MOCK_GH_MUTATIONS="$OUT/mutations.log" \
  MOCK_GH_GET_COUNT="$OUT/get_count" MOCK_GH_PUT_COUNT="$OUT/put_count" \
  MOCK_GH_PUT_BODIES="$OUT/bodies" \
  MOCK_GH_MODE="404" MOCK_GH_SHA="" MOCK_GH_OLD_SHA="" MOCK_GH_NEW_SHA="" \
  PATH="$BIN:$PATH" \
  "$SAVE_LOG_SH" --log "$WORK/not-configured-no-repo.jsonl" --work-tracking "$WT_ABSENT" \
  > "$OUT/run.stdout.log" 2> "$OUT/run.stderr.log"
RC=$?
set -e
[ "$RC" -eq 2 ] \
  || report "not configured, --repo omitted: expected exit 2 (gate before REPO resolution), got $RC — $(cat "$OUT/run.stderr.log")"
[ "$(n_calls)" = "0" ] \
  || report "not configured, --repo omitted: expected zero gh calls of any kind (including repo view), got $(n_calls) — $(cat "$OUT/calls.log")"

# ---------------------------------------------------------------------------
# missing session-start event -> hard failure, zero calls of any kind.
# ---------------------------------------------------------------------------
RC=0; run_save_log "404" "" "" "" "$LOG_NO_START" --archive "$ARCHIVE_REPO" || RC=$?
[ "$RC" -eq 1 ] || report "missing session-start: expected exit 1, got $RC — $(cat "$OUT/run.stderr.log")"
[ "$(n_calls)" = "0" ] || report "missing session-start: expected zero gh calls, got $(n_calls) — $(cat "$OUT/calls.log")"
grep -qi "session-start" "$OUT/run.stderr.log" \
  || report "missing session-start: stderr did not name the missing event"

# ---------------------------------------------------------------------------
# Issue #592: a log with hundreds of `session-start` events must not EPIPE.
# The first `session-start` line still wins (its ts/session_id derive
# ARCHIVE_PATH) — proven by asserting the exact archive path in stdout, not
# merely a non-error exit. Before the fix, `jq ... | head -1` under
# `set -o pipefail` had `head` close the pipe once it had its one line,
# jq died of SIGPIPE while still writing the rest, and the run failed with
# "could not be parsed as JSON lines" for a perfectly well-formed log.
# ---------------------------------------------------------------------------
LOG_MANY_STARTS="$LOGS/many-session-starts.jsonl"
{
  printf '{"ts":"%s","event":"session-start","claim":"test-01","session_id":"%s"}\n' "$SESSION_TS" "$SESSION_ID"
  i=0
  while [ "$i" -lt 500 ]; do
    printf '{"ts":"2026-08-30T09:%02d:00Z","event":"session-start","claim":"test-01","session_id":"decoy-%d"}\n' "$((i % 60))" "$i"
    i=$((i + 1))
  done
} > "$LOG_MANY_STARTS"
RC=0; run_save_log "404" "" "" "" "$LOG_MANY_STARTS" --archive "$ARCHIVE_REPO" || RC=$?
[ "$RC" -eq 0 ] \
  || report "many session-start events: expected exit 0, got $RC — $(cat "$OUT/run.stderr.log")"
grep -qi "could not be parsed as JSON lines" "$OUT/run.stderr.log" \
  && report "many session-start events: EPIPE regression — a well-formed log with many session-start lines was reported unparseable"
grep -qF "$ARCHIVE_REPO:$ARCHIVE_PATH" "$OUT/run.stdout.log" \
  || report "many session-start events: stdout did not name the archive path derived from the FIRST session-start event — $(cat "$OUT/run.stdout.log")"

# ---------------------------------------------------------------------------
# dry-run: no PUT, no appended log line, on both unchanged and changed.
# ---------------------------------------------------------------------------
cp "$LOG_V1" "$WORK/dry-unchanged.jsonl"
RC=0; run_save_log "match" "$SHA_V1" "" "" "$WORK/dry-unchanged.jsonl" --archive "$ARCHIVE_REPO" --dry-run || RC=$?
[ "$RC" -eq 0 ] || report "dry-run (unchanged): expected exit 0, got $RC"
[ "$(n_puts)" = "0" ] || report "dry-run (unchanged): expected zero PUTs, got $(n_puts)"
[ "$(jq -c 'select(.event=="note")' "$WORK/dry-unchanged.jsonl" 2>/dev/null | wc -l | tr -d ' ')" = "0" ] \
  || report "dry-run (unchanged): a note line was appended despite --dry-run"

cp "$LOG_V2" "$WORK/dry-changed.jsonl"
RC=0; run_save_log "mismatch" "$OLD_SHA_FOR_CHANGE" "" "" "$WORK/dry-changed.jsonl" --archive "$ARCHIVE_REPO" --dry-run || RC=$?
[ "$RC" -eq 0 ] || report "dry-run (changed): expected exit 0, got $RC"
[ "$(n_puts)" = "0" ] || report "dry-run (changed): expected zero PUTs, got $(n_puts)"
[ "$(jq -c 'select(.event=="note")' "$WORK/dry-changed.jsonl" 2>/dev/null | wc -l | tr -d ' ')" = "0" ] \
  || report "dry-run (changed): a note line was appended despite --dry-run"

# ---------------------------------------------------------------------------
# Payload size band. MAX_BYTES is save-log.sh's own 1 MB Contents-API
# bound; MAX_ARG_STRLEN is the Linux per-argv-element cap that an
# `-f content=<base64>` spelling would have collided with at roughly a
# 93 KB log — a tenth of the bound the script advertises. These fixtures
# are GENERATED here, never committed.
# ---------------------------------------------------------------------------
MAX_BYTES=1048576
mk_big_log(){ # mk_big_log <path> <target-bytes> — valid JSONL, exact size
  local path="$1" target="$2"
  local pre='{"ts":"2026-08-30T09:06:00Z","event":"startup-item","claim":null,"item":"'
  local post='"}'
  local overhead=$(( ${#pre} + ${#post} + 1 ))   # +1 for the newline
  printf '{"ts":"%s","event":"session-start","claim":"test-01","session_id":"%s"}\n' \
    "$SESSION_TS" "$SESSION_ID" > "$path"
  local pad900; pad900=$(head -c 900 /dev/zero | tr '\0' 'x')
  local full=$(( overhead + 900 ))
  while [ "$(( $(wc -c < "$path") + full ))" -le "$target" ]; do
    printf '%s%s%s\n' "$pre" "$pad900" "$post" >> "$path"
  done
  # One final short line sized to land on exactly $target.
  local cur padlen
  cur=$(wc -c < "$path")
  padlen=$(( target - cur - overhead ))
  if [ "$padlen" -ge 0 ]; then
    printf '%s%s%s\n' "$pre" "$(head -c "$padlen" /dev/zero | tr '\0' 'y')" "$post" >> "$path"
  fi
}

# Just UNDER the bound: must archive successfully, and the decoded PUT body
# must be byte-identical to the local file afterwards. At ~960 KB this is
# an order of magnitude past the ~93 KB an argv-borne base64 payload could
# carry, so it is the direct regression guard for the payload having left
# argv (the mock additionally refuses `-f content=` outright).
UNDER="$WORK/under-bound.jsonl"
mk_big_log "$UNDER" 983040
UNDER_BYTES=$(wc -c < "$UNDER" | tr -d ' ')
[ "$UNDER_BYTES" -eq 983040 ] || report "fixture bug: under-bound log is $UNDER_BYTES bytes, expected 983040"
[ "$UNDER_BYTES" -lt "$MAX_BYTES" ] || report "fixture bug: under-bound log is not under the 1 MB bound"
[ "$UNDER_BYTES" -gt 131072 ] \
  || report "fixture bug: under-bound log must exceed MAX_ARG_STRLEN (131072) to guard the argv defect"
RC=0; run_save_log "404" "" "" "" "$UNDER" --archive "$ARCHIVE_REPO" || RC=$?
[ "$RC" -eq 0 ] \
  || report "under-bound (${UNDER_BYTES}B): expected exit 0 — a log inside the advertised 1 MB band must archive, not die on an argv limit — got $RC: $(cat "$OUT/run.stderr.log")"
[ "$(n_puts)" = "1" ] || report "under-bound: expected exactly 1 PUT, got $(n_puts)"
under_mut=$(tail -1 "$OUT/mutations.log")
cmp -s "$UNDER" "$(jq -r .body_file <<<"$under_mut")" \
  || report "under-bound: the decoded PUT body is not byte-identical to the local log after the append"
[ "$(git hash-object "$UNDER")" = "$(jq -r .body_sha <<<"$under_mut")" ] \
  || report "under-bound: local log does not hash to the archived blob"
[ "$(jq -c 'select(.event=="note")' "$UNDER" | wc -l | tr -d ' ')" = "1" ] \
  || report "under-bound: expected exactly one appended note line"

# EXACTLY at the bound: the input passes the pre-flight check, but the
# post-append candidate is over, so the PUT must be refused rather than
# sent for the API to reject. The GET has already happened by then, so
# this asserts zero PUTs rather than zero calls.
EXACT="$WORK/exact-bound.jsonl"
mk_big_log "$EXACT" "$MAX_BYTES"
EXACT_BYTES=$(wc -c < "$EXACT" | tr -d ' ')
[ "$EXACT_BYTES" -eq "$MAX_BYTES" ] || report "fixture bug: exact-bound log is $EXACT_BYTES bytes, expected $MAX_BYTES"
RC=0; run_save_log "404" "" "" "" "$EXACT" --archive "$ARCHIVE_REPO" || RC=$?
[ "$RC" -eq 1 ] \
  || report "exact-bound (${EXACT_BYTES}B): expected exit 1 — the post-append candidate is over the bound — got $RC"
[ "$(n_puts)" = "0" ] || report "exact-bound: expected zero PUTs, got $(n_puts)"
grep -qi "1 MB\|1048576" "$OUT/run.stderr.log" \
  || report "exact-bound: stderr did not name the 1 MB bound — $(cat "$OUT/run.stderr.log")"
[ "$(jq -c 'select(.event=="note")' "$EXACT" | wc -l | tr -d ' ')" = "0" ] \
  || report "exact-bound: a note line was appended even though the archive was refused"

# ---------------------------------------------------------------------------
# 1 MB bound: a file over the limit is refused before any call.
# ---------------------------------------------------------------------------
BIG="$WORK/big.jsonl"
head -c 1100000 /dev/zero | tr '\0' 'a' > "$BIG"
RC=0; run_save_log "404" "" "" "" "$BIG" --archive "$ARCHIVE_REPO" || RC=$?
[ "$RC" -eq 1 ] || report "oversized file: expected exit 1, got $RC — $(cat "$OUT/run.stderr.log")"
[ "$(n_calls)" = "0" ] || report "oversized file: expected zero gh calls, got $(n_calls)"
grep -qi "1 MB\|1048576" "$OUT/run.stderr.log" \
  || report "oversized file: stderr did not name the 1 MB bound — $(cat "$OUT/run.stderr.log")"

# ---------------------------------------------------------------------------
# archive location parsed from work-tracking.md's "Session-log archive:"
# line when --archive is not passed.
# ---------------------------------------------------------------------------
cp "$LOG_V1" "$WORK/from-doc.jsonl"
RC=0; run_save_log "404" "" "" "" "$WORK/from-doc.jsonl" --work-tracking "$WT_CONFIGURED" || RC=$?
[ "$RC" -eq 0 ] || report "archive from doc: expected exit 0, got $RC — $(cat "$OUT/run.stderr.log")"
[ "$(n_puts)" = "1" ] || report "archive from doc: expected exactly 1 PUT, got $(n_puts)"
grep -q "$ARCHIVE_REPO" "$OUT/run.stdout.log" \
  || report "archive from doc: stdout did not name the archive parsed from work-tracking.md"

# ---------------------------------------------------------------------------
# --archive overrides work-tracking.md even when the doc names a
# different (or no) repository.
# ---------------------------------------------------------------------------
cp "$LOG_V1" "$WORK/override.jsonl"
RC=0; run_save_log "404" "" "" "" "$WORK/override.jsonl" --archive "$ARCHIVE_REPO" --work-tracking "$WT_ABSENT" || RC=$?
[ "$RC" -eq 0 ] || report "--archive override: expected exit 0, got $RC — $(cat "$OUT/run.stderr.log")"
grep -q "$ARCHIVE_REPO" "$OUT/run.stdout.log" \
  || report "--archive override: stdout did not name the overriding archive"

# run_raw is like run_save_log but does not force --repo, so a case can
# pass its own --repo value (including a malformed one) or omit it.
run_raw(){ # run_raw <mode> <sha> <old> <new> <args...>
  local mode="$1" sha="$2" old="$3" new="$4"; shift 4
  : > "$OUT/calls.log"; : > "$OUT/mutations.log"
  echo 0 > "$OUT/get_count"; echo 0 > "$OUT/put_count"
  rm -rf "$OUT/bodies"; mkdir -p "$OUT/bodies"
  local rc=0
  set +e
  MOCK_GH_CALLS="$OUT/calls.log" MOCK_GH_MUTATIONS="$OUT/mutations.log" \
    MOCK_GH_GET_COUNT="$OUT/get_count" MOCK_GH_PUT_COUNT="$OUT/put_count" \
    MOCK_GH_PUT_BODIES="$OUT/bodies" \
    MOCK_GH_MODE="$mode" MOCK_GH_SHA="$sha" MOCK_GH_OLD_SHA="$old" MOCK_GH_NEW_SHA="$new" \
    PATH="$BIN:$PATH" \
    "$SAVE_LOG_SH" "$@" \
    > "$OUT/run.stdout.log" 2> "$OUT/run.stderr.log"
  rc=$?
  set -e
  return $rc
}

# ---------------------------------------------------------------------------
# Issue #459, F1: --repo not matching owner/name exits 2 before any call —
# both a value with no '/' and one with an embedded space (the exact
# traversal probe from the issue body).
# ---------------------------------------------------------------------------
cp "$LOG_V1" "$WORK/bad-repo.jsonl"
RC=0; run_raw "404" "" "" "" --log "$WORK/bad-repo.jsonl" --archive "$ARCHIVE_REPO" --repo "not an owner/name" || RC=$?
[ "$RC" -eq 2 ] || report "--repo malformed (space): expected exit 2, got $RC — $(cat "$OUT/run.stderr.log")"
[ "$(n_calls)" = "0" ] || report "--repo malformed (space): expected zero gh calls, got $(n_calls)"
grep -qi "owner/name" "$OUT/run.stderr.log" \
  || report "--repo malformed (space): stderr did not name the owner/name requirement"

RC=0; run_raw "404" "" "" "" --log "$WORK/bad-repo.jsonl" --archive "$ARCHIVE_REPO" --repo "no-slash-at-all" || RC=$?
[ "$RC" -eq 2 ] || report "--repo malformed (no slash): expected exit 2, got $RC — $(cat "$OUT/run.stderr.log")"
[ "$(n_calls)" = "0" ] || report "--repo malformed (no slash): expected zero gh calls, got $(n_calls)"

# ---------------------------------------------------------------------------
# PR #558 round 1, F1 — the LINE-oriented-validator bypass. The previous
# spelling was `printf '%s' "$v" | grep -Eq '^owner/name$'`, and `grep`
# matches PER LINE: a value whose FIRST line conforms passed with the rest
# unchecked, so `--repo $'ok/ok\n../../../etc/pwn'` issued a real GET and a
# real PUT against a traversed archive path. Each case here asserts BOTH
# exit 2 AND an empty call log — a whole-string validator refuses before
# `gh` is reached at all, so one single `gh` call in calls.log is the
# regression. Mutating validate_owner_name's `[[ =~ ]]` back to the piped
# grep fails these three.
# ---------------------------------------------------------------------------
REPO_NEWLINE=$'ok/ok\n../../../etc/pwn'
RC=0; run_raw "404" "" "" "" --log "$WORK/bad-repo.jsonl" --archive "$ARCHIVE_REPO" --repo "$REPO_NEWLINE" || RC=$?
[ "$RC" -eq 2 ] \
  || report "--repo embedded newline: expected exit 2, got $RC — a line-oriented validator accepted a value whose first line conforms — $(cat "$OUT/run.stderr.log")"
[ "$(n_calls)" = "0" ] \
  || report "--repo embedded newline: expected ZERO gh calls, got $(n_calls) — the traversal reached the API — $(cat "$OUT/calls.log")"

# This one carries NO '..' at all, so the '.'/'..' segment `case` cannot
# refuse it — only the whole-string `[[ =~ ]]` can. It is the fixture that
# isolates the line-orientation bug itself: swap validate_owner_name's
# `[[ =~ ]]` back to `printf '%s' "$v" | grep -Eq '^...$'` and this case
# (alone among the --repo cases) starts issuing real gh calls.
REPO_NEWLINE_NODOTS=$'ok/ok\nnot an owner/name'
RC=0; run_raw "404" "" "" "" --log "$WORK/bad-repo.jsonl" --archive "$ARCHIVE_REPO" --repo "$REPO_NEWLINE_NODOTS" || RC=$?
[ "$RC" -eq 2 ] \
  || report "--repo embedded newline (no '..' anywhere): expected exit 2, got $RC — only a whole-string validator refuses this — $(cat "$OUT/run.stderr.log")"
[ "$(n_calls)" = "0" ] \
  || report "--repo embedded newline (no '..' anywhere): expected ZERO gh calls, got $(n_calls) — the line-oriented validator bypass is back — $(cat "$OUT/calls.log")"

REPO_CR=$'ok/ok\r'
RC=0; run_raw "404" "" "" "" --log "$WORK/bad-repo.jsonl" --archive "$ARCHIVE_REPO" --repo "$REPO_CR" || RC=$?
[ "$RC" -eq 2 ] || report "--repo trailing CR: expected exit 2, got $RC — $(cat "$OUT/run.stderr.log")"
[ "$(n_calls)" = "0" ] || report "--repo trailing CR: expected zero gh calls, got $(n_calls) — $(cat "$OUT/calls.log")"

# `../..` matches ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ exactly — the character
# class admits '.' — so the owner/name pattern alone is not a traversal
# check; the explicit per-segment '.'/'..' refusal is. Deleting that `case`
# from validate_owner_name fails these two.
for bad_repo in "../.." "ok/.." "../ok" "./ok"; do
  RC=0; run_raw "404" "" "" "" --log "$WORK/bad-repo.jsonl" --archive "$ARCHIVE_REPO" --repo "$bad_repo" || RC=$?
  [ "$RC" -eq 2 ] \
    || report "--repo dot segment ($bad_repo): expected exit 2, got $RC — $(cat "$OUT/run.stderr.log")"
  [ "$(n_calls)" = "0" ] \
    || report "--repo dot segment ($bad_repo): expected zero gh calls, got $(n_calls) — $(cat "$OUT/calls.log")"
done

# ---------------------------------------------------------------------------
# Issue #555: --archive — the PUT's TARGET repo, and the more consequential
# of the two interpolations — gets the same owner/name shape check --repo
# gets, before any API call, whether it came from the flag or from
# work-tracking.md's `Session-log archive:` line. Refused values exit 2
# with zero calls; the well-formed `nonesuch/logs` case further down proves
# the check does not over-refuse.
# ---------------------------------------------------------------------------
cp "$LOG_V1" "$WORK/bad-archive.jsonl"
for bad_archive in "not an owner/name" "no-slash-at-all" "../.." "ok/.." "too/many/segments" $'ok/ok\n../../../etc/pwn' $'ok/ok\nnot an owner/name' $'ok/ok\r'; do
  RC=0; run_save_log "404" "" "" "" "$WORK/bad-archive.jsonl" --archive "$bad_archive" || RC=$?
  [ "$RC" -eq 2 ] \
    || report "--archive malformed ($bad_archive): expected exit 2, got $RC — $(cat "$OUT/run.stderr.log")"
  [ "$(n_calls)" = "0" ] \
    || report "--archive malformed ($bad_archive): expected zero gh calls, got $(n_calls) — $(cat "$OUT/calls.log")"
  grep -qi "owner/name" "$OUT/run.stderr.log" \
    || report "--archive malformed ($bad_archive): stderr did not name the owner/name requirement — $(cat "$OUT/run.stderr.log")"
done

# The same refusal when the malformed value arrives from the doc line
# rather than from the flag — the doc is the ordinary source in production.
WT_BAD_ARCHIVE="$WORK/wt-bad-archive.md"
cat > "$WT_BAD_ARCHIVE" <<DOC
# Work tracking
Session-log archive: not an owner/name
DOC
RC=0; run_save_log "404" "" "" "" "$WORK/bad-archive.jsonl" --work-tracking "$WT_BAD_ARCHIVE" || RC=$?
[ "$RC" -eq 2 ] \
  || report "--archive malformed from work-tracking doc: expected exit 2, got $RC — $(cat "$OUT/run.stderr.log")"
[ "$(n_calls)" = "0" ] \
  || report "--archive malformed from work-tracking doc: expected zero gh calls, got $(n_calls) — $(cat "$OUT/calls.log")"
grep -qi "archive not configured" "$OUT/run.stderr.log" \
  && report "--archive malformed from work-tracking doc: reported 'not configured' for a value that IS present but malformed — the two causes must stay distinct"

# ---------------------------------------------------------------------------
# Issue #459, F1: a session_id (or ts) containing '/' or '..' in the log's
# own session-start event is refused before any API call — this is the
# exact traversal probe from the issue body (session_id
# "../../../etc/pwn"), now on the LOG-CONTENT side of the vector.
# ---------------------------------------------------------------------------
LOG_TRAVERSAL_ID="$LOGS/traversal-session-id.jsonl"
printf '{"ts":"%s","event":"session-start","claim":"test-01","session_id":"../../../etc/pwn"}\n' "$SESSION_TS" > "$LOG_TRAVERSAL_ID"
RC=0; run_save_log "404" "" "" "" "$LOG_TRAVERSAL_ID" --archive "$ARCHIVE_REPO" || RC=$?
[ "$RC" -eq 1 ] || report "traversal session_id: expected exit 1, got $RC — $(cat "$OUT/run.stderr.log")"
[ "$(n_calls)" = "0" ] || report "traversal session_id: expected zero gh calls, got $(n_calls)"
grep -qi "session_id" "$OUT/run.stderr.log" \
  || report "traversal session_id: stderr did not name session_id — $(cat "$OUT/run.stderr.log")"

LOG_TRAVERSAL_TS="$LOGS/traversal-ts.jsonl"
printf '{"ts":"../../etc/passwd","event":"session-start","claim":"test-01","session_id":"%s"}\n' "$SESSION_ID" > "$LOG_TRAVERSAL_TS"
RC=0; run_save_log "404" "" "" "" "$LOG_TRAVERSAL_TS" --archive "$ARCHIVE_REPO" || RC=$?
[ "$RC" -eq 1 ] || report "traversal ts: expected exit 1, got $RC — $(cat "$OUT/run.stderr.log")"
[ "$(n_calls)" = "0" ] || report "traversal ts: expected zero gh calls, got $(n_calls)"
grep -qi "\bts\b" "$OUT/run.stderr.log" \
  || report "traversal ts: stderr did not name ts — $(cat "$OUT/run.stderr.log")"

# PR #558 round 1, F1, log-content side: a session_id (or ts) whose FIRST
# line is a perfectly good path segment but which carries an embedded
# newline (or CR) after it. The old line-oriented validator accepted these
# and put a '/' straight into ARCHIVE_PATH from file content the script's
# own header declares untrusted; the whole-string `[[ =~ ]]` refuses them
# before any call. The fixtures are built with jq so the newline is a real
# JSON \n escape, not a broken (unparseable) log line — a parse failure
# would exit 1 for the WRONG reason, so each case also asserts the message
# names the offending key.
LOG_NL_ID="$LOGS/newline-session-id.jsonl"
jq -nc --arg ts "$SESSION_TS" --arg sid $'sess-1\netc/pwn' \
  '{ts:$ts, event:"session-start", claim:"test-01", session_id:$sid}' > "$LOG_NL_ID"
[ "$(wc -l < "$LOG_NL_ID" | tr -d ' ')" = "1" ] \
  || { echo "fixture bug: newline-session-id fixture is not a single JSON line" >&2; exit 1; }
RC=0; run_save_log "404" "" "" "" "$LOG_NL_ID" --archive "$ARCHIVE_REPO" || RC=$?
[ "$RC" -eq 1 ] \
  || report "embedded-newline session_id: expected exit 1, got $RC — $(cat "$OUT/run.stderr.log")"
[ "$(n_calls)" = "0" ] \
  || report "embedded-newline session_id: expected ZERO gh calls, got $(n_calls) — a '/' from log content reached the archive path — $(cat "$OUT/calls.log")"
grep -qi "session_id" "$OUT/run.stderr.log" \
  || report "embedded-newline session_id: stderr did not name session_id — $(cat "$OUT/run.stderr.log")"

LOG_NL_TS="$LOGS/newline-ts.jsonl"
jq -nc --arg ts $'2026-08-30T09:00:00Z\n../../etc/passwd' --arg sid "$SESSION_ID" \
  '{ts:$ts, event:"session-start", claim:"test-01", session_id:$sid}' > "$LOG_NL_TS"
RC=0; run_save_log "404" "" "" "" "$LOG_NL_TS" --archive "$ARCHIVE_REPO" || RC=$?
[ "$RC" -eq 1 ] || report "embedded-newline ts: expected exit 1, got $RC — $(cat "$OUT/run.stderr.log")"
[ "$(n_calls)" = "0" ] \
  || report "embedded-newline ts: expected ZERO gh calls, got $(n_calls) — $(cat "$OUT/calls.log")"
grep -qi "\bts\b" "$OUT/run.stderr.log" \
  || report "embedded-newline ts: stderr did not name ts — $(cat "$OUT/run.stderr.log")"

# A BARE '..' as ts or session_id has no '/' and no whitespace, so the
# single-segment pattern accepts it outright — the `case *..*` arm above it
# is the only thing that refuses it. Deleting that arm makes exactly these
# two cases fail, which is what makes it load-bearing rather than merely
# redundant with the pattern.
for dotdot_key in ts session_id; do
  LOG_DOTDOT="$LOGS/dotdot-$dotdot_key.jsonl"
  if [ "$dotdot_key" = "ts" ]; then
    jq -nc --arg sid "$SESSION_ID" '{ts:"..", event:"session-start", claim:"test-01", session_id:$sid}' > "$LOG_DOTDOT"
  else
    jq -nc --arg ts "$SESSION_TS" '{ts:$ts, event:"session-start", claim:"test-01", session_id:".."}' > "$LOG_DOTDOT"
  fi
  RC=0; run_save_log "404" "" "" "" "$LOG_DOTDOT" --archive "$ARCHIVE_REPO" || RC=$?
  [ "$RC" -eq 1 ] \
    || report "bare '..' $dotdot_key: expected exit 1, got $RC — $(cat "$OUT/run.stderr.log")"
  [ "$(n_calls)" = "0" ] \
    || report "bare '..' $dotdot_key: expected zero gh calls, got $(n_calls) — $(cat "$OUT/calls.log")"
  grep -qi "'\.\.'" "$OUT/run.stderr.log" \
    || report "bare '..' $dotdot_key: stderr did not name the '..' refusal — $(cat "$OUT/run.stderr.log")"
done

LOG_CR_ID="$LOGS/cr-session-id.jsonl"
jq -nc --arg ts "$SESSION_TS" --arg sid $'sess-1\r' \
  '{ts:$ts, event:"session-start", claim:"test-01", session_id:$sid}' > "$LOG_CR_ID"
RC=0; run_save_log "404" "" "" "" "$LOG_CR_ID" --archive "$ARCHIVE_REPO" || RC=$?
[ "$RC" -eq 1 ] || report "CR session_id: expected exit 1, got $RC — $(cat "$OUT/run.stderr.log")"
[ "$(n_calls)" = "0" ] || report "CR session_id: expected zero gh calls, got $(n_calls) — $(cat "$OUT/calls.log")"

# Issue #595: a percent-encoded traversal (`%2e%2e%2f...`) carries no
# literal '..' or '/' byte, so it would pass the '..'/'/' checks above
# verbatim — only a dedicated '%' refusal catches it. Mutation-probed via
# the AC command below (removing the '%' guard makes this fail).
LOG_PCT_ID="$LOGS/pct-session-id.jsonl"
printf '{"ts":"%s","event":"session-start","claim":"test-01","session_id":"%%2e%%2e%%2f%%2e%%2e%%2fetc"}\n' "$SESSION_TS" > "$LOG_PCT_ID"
RC=0; run_save_log "404" "" "" "" "$LOG_PCT_ID" --archive "$ARCHIVE_REPO" || RC=$?
[ "$RC" -eq 1 ] || report "percent-encoded traversal session_id: expected exit 1, got $RC — $(cat "$OUT/run.stderr.log")"
[ "$(n_calls)" = "0" ] \
  || report "percent-encoded traversal session_id: expected zero gh calls, got $(n_calls) — $(cat "$OUT/calls.log")"
grep -qi "session_id" "$OUT/run.stderr.log" \
  || report "percent-encoded traversal session_id: stderr did not name session_id — $(cat "$OUT/run.stderr.log")"

# ---------------------------------------------------------------------------
# Issue #630: validate_path_segment is an ALLOW-LIST, not a deny-list — a
# deny-list of '/', whitespace, '..' and '%' lets every OTHER byte through,
# including raw non-ASCII content that carries none of those literal
# bytes. Three shapes a deny-list would have passed, plus a fourth it
# would NOT have (kept here for the check it does guard):
#   - an over-long UTF-8 encoding of '.' (raw bytes 0xC0 0xAE — jq is
#     lenient on invalid UTF-8 on read, so this reaches the value)
#   - a literal control character (0x01) embedded via a JSON \u escape
#   - a segment that is only dots (four, here) — NOT a deny-list gap: it
#     contains '..', so the pre-existing *..* case check refuses it, as a
#     deny-list carrying that check would have; it guards that check, not
#     the allow-list
#   - a Unicode lookalike character that reads like a path separator but
#     is not the literal '/' byte (U+FF0F FULLWIDTH SOLIDUS)
# All four must be refused before any gh call, exactly like the traversal
# and percent-encoded cases above.
# ---------------------------------------------------------------------------
LOG_OVERLONG_UTF8="$LOGS/overlong-utf8.jsonl"
{
  printf '{"ts":"%s","event":"session-start","claim":"test-01","session_id":"' "$SESSION_TS"
  printf '\xC0\xAE'
  printf '"}\n'
} > "$LOG_OVERLONG_UTF8"
RC=0; run_save_log "404" "" "" "" "$LOG_OVERLONG_UTF8" --archive "$ARCHIVE_REPO" || RC=$?
[ "$RC" -eq 1 ] || report "over-long UTF-8 session_id (#630): expected exit 1, got $RC — $(cat "$OUT/run.stderr.log")"
[ "$(n_calls)" = "0" ] || report "over-long UTF-8 session_id (#630): expected zero gh calls, got $(n_calls)"
grep -qi "session_id" "$OUT/run.stderr.log" \
  || report "over-long UTF-8 session_id (#630): stderr did not name session_id — $(cat "$OUT/run.stderr.log")"

LOG_CTRL_CHAR="$LOGS/ctrl-char.jsonl"
printf '{"ts":"%s","event":"session-start","claim":"test-01","session_id":"evil\\u0001byte"}\n' "$SESSION_TS" > "$LOG_CTRL_CHAR"
RC=0; run_save_log "404" "" "" "" "$LOG_CTRL_CHAR" --archive "$ARCHIVE_REPO" || RC=$?
[ "$RC" -eq 1 ] || report "control-character session_id (#630): expected exit 1, got $RC — $(cat "$OUT/run.stderr.log")"
[ "$(n_calls)" = "0" ] || report "control-character session_id (#630): expected zero gh calls, got $(n_calls)"
grep -qi "session_id" "$OUT/run.stderr.log" \
  || report "control-character session_id (#630): stderr did not name session_id — $(cat "$OUT/run.stderr.log")"

LOG_DOTS_ONLY="$LOGS/dots-only.jsonl"
printf '{"ts":"%s","event":"session-start","claim":"test-01","session_id":"...."}\n' "$SESSION_TS" > "$LOG_DOTS_ONLY"
RC=0; run_save_log "404" "" "" "" "$LOG_DOTS_ONLY" --archive "$ARCHIVE_REPO" || RC=$?
[ "$RC" -eq 1 ] || report "dots-only session_id (#630): expected exit 1, got $RC — $(cat "$OUT/run.stderr.log")"
[ "$(n_calls)" = "0" ] || report "dots-only session_id (#630): expected zero gh calls, got $(n_calls)"

LOG_UNICODE_LOOKALIKE="$LOGS/unicode-lookalike.jsonl"
jq -nc --arg ts "$SESSION_TS" '{ts:$ts, event:"session-start", claim:"test-01", session_id:"a／b"}' > "$LOG_UNICODE_LOOKALIKE"
RC=0; run_save_log "404" "" "" "" "$LOG_UNICODE_LOOKALIKE" --archive "$ARCHIVE_REPO" || RC=$?
[ "$RC" -eq 1 ] || report "Unicode lookalike session_id (#630): expected exit 1, got $RC — $(cat "$OUT/run.stderr.log")"
[ "$(n_calls)" = "0" ] || report "Unicode lookalike session_id (#630): expected zero gh calls, got $(n_calls)"
grep -qi "session_id" "$OUT/run.stderr.log" \
  || report "Unicode lookalike session_id (#630): stderr did not name session_id — $(cat "$OUT/run.stderr.log")"

# ---------------------------------------------------------------------------
# Issue #459, F2: an EXPLICITLY-PASSED --work-tracking path that does not
# exist fails naming the missing file (exit 1), never "archive not
# configured" (exit 2) — distinct exit codes for two genuinely distinct
# causes.
# ---------------------------------------------------------------------------
WT_MISSING="$WORK/does-not-exist-work-tracking.md"
cp "$LOG_V1" "$WORK/missing-wt.jsonl"
RC=0; run_save_log "404" "" "" "" "$WORK/missing-wt.jsonl" --work-tracking "$WT_MISSING" || RC=$?
[ "$RC" -eq 1 ] || report "missing --work-tracking file: expected exit 1 (distinct from not-configured's exit 2), got $RC — $(cat "$OUT/run.stderr.log")"
[ "$(n_calls)" = "0" ] || report "missing --work-tracking file: expected zero gh calls, got $(n_calls)"
grep -qF "$WT_MISSING" "$OUT/run.stderr.log" \
  || report "missing --work-tracking file: stderr did not name the missing path — $(cat "$OUT/run.stderr.log")"
grep -qi "archive not configured" "$OUT/run.stderr.log" \
  && report "missing --work-tracking file: stderr wrongly reused the not-configured message instead of naming the real cause"

# ---------------------------------------------------------------------------
# Issue #459, F3: HTTP status is read from gh's own (HTTP <code>) suffix,
# never a bare substring match over the whole stderr text — a decoy 500
# whose message embeds "404"/"409"/"422" outside that suffix must NOT be
# misclassified as first-save or as a retryable conflict.
# ---------------------------------------------------------------------------
cp "$LOG_V1" "$WORK/get-decoy.jsonl"
RC=0; run_save_log "get-decoy-500" "" "" "" "$WORK/get-decoy.jsonl" --archive "$ARCHIVE_REPO" || RC=$?
[ "$RC" -eq 1 ] \
  || report "GET decoy 500 (digits in URL, not in (HTTP nnn)): expected exit 1 (hard failure), got $RC — a substring match on stderr would wrongly read this as first-save (exit 0)"
[ "$(n_puts)" = "0" ] \
  || report "GET decoy 500: expected zero PUTs (the decoy must not be read as first-save), got $(n_puts)"

cp "$LOG_V1" "$WORK/put-decoy.jsonl"
RC=0; run_save_log "put-decoy-500" "" "" "" "$WORK/put-decoy.jsonl" --archive "$ARCHIVE_REPO" || RC=$?
[ "$RC" -eq 1 ] \
  || report "PUT decoy 500 (digits in URL, not in (HTTP nnn)): expected exit 1 (hard failure), got $RC"
[ "$(n_puts)" = "1" ] \
  || report "PUT decoy 500: expected exactly 1 PUT (no retry — a substring match on stderr would wrongly treat this as a 409/422 conflict), got $(n_puts)"
[ "$(cat "$OUT/get_count")" = "1" ] \
  || report "PUT decoy 500: expected exactly 1 GET (no re-GET), got $(cat "$OUT/get_count")"

# ---------------------------------------------------------------------------
# Issue #594: a genuine 500 whose MESSAGE BODY embeds a parenthesised code
# (here "(HTTP 404)") ahead of the real, trailing code ("(HTTP 500)") must
# still be classified by the TRAILING code — never by the embedded one.
# This is the mutation probe for end-anchoring http_status_is: flipping the
# pattern back to unanchored (`\(HTTP $1\)`, no trailing `$`) makes this
# case fail, because an unanchored match finds the embedded "(HTTP 404)"
# and wrongly reads a genuine 500 as first-save.
# ---------------------------------------------------------------------------
cp "$LOG_V1" "$WORK/get-embedded-code.jsonl"
RC=0; run_save_log "get-embedded-code-500" "" "" "" "$WORK/get-embedded-code.jsonl" --archive "$ARCHIVE_REPO" || RC=$?
[ "$RC" -eq 1 ] \
  || report "GET embedded-code 500: expected exit 1 (hard failure), got $RC — an unanchored (HTTP 404) match would wrongly read this as first-save"
[ "$(n_puts)" = "0" ] \
  || report "GET embedded-code 500: expected zero PUTs (must not be read as first-save), got $(n_puts)"

# ---------------------------------------------------------------------------
# Issue #459, F4: the not-configured fallback is matched EXACTLY and
# case-insensitively, never a `none*` prefix — a genuinely configured
# archive whose name starts with "none" must archive normally, and the
# documented fallback must be recognized regardless of case.
# ---------------------------------------------------------------------------
NONESUCH_ARCHIVE="nonesuch/logs"
WT_NONESUCH="$WORK/wt-nonesuch.md"
cat > "$WT_NONESUCH" <<DOC
# Work tracking
Session-log archive: $NONESUCH_ARCHIVE
DOC
cp "$LOG_V1" "$WORK/nonesuch.jsonl"
RC=0; run_save_log "404" "" "" "" "$WORK/nonesuch.jsonl" --work-tracking "$WT_NONESUCH" || RC=$?
[ "$RC" -eq 0 ] \
  || report "nonesuch/logs: expected exit 0 (a real archive, not the not-configured fallback), got $RC — $(cat "$OUT/run.stderr.log")"
[ "$(n_puts)" = "1" ] || report "nonesuch/logs: expected exactly 1 PUT, got $(n_puts)"
grep -q "$NONESUCH_ARCHIVE" "$OUT/run.stdout.log" \
  || report "nonesuch/logs: stdout did not name the resolved archive"

WT_NONE_CAPITALIZED="$WORK/wt-none-capitalized.md"
cat > "$WT_NONE_CAPITALIZED" <<DOC
# Work tracking
Session-log archive: None — Session Logs Stay Scratch-Only
DOC
cp "$LOG_V1" "$WORK/none-capitalized.jsonl"
RC=0; run_save_log "404" "" "" "" "$WORK/none-capitalized.jsonl" --work-tracking "$WT_NONE_CAPITALIZED" || RC=$?
[ "$RC" -eq 2 ] \
  || report "capitalized None fallback: expected exit 2 (not-configured, matched case-insensitively), got $RC — $(cat "$OUT/run.stderr.log")"
[ "$(n_calls)" = "0" ] \
  || report "capitalized None fallback: expected zero gh calls, got $(n_calls)"
# The MESSAGE matters as much as the exit code here: "None — ..." is also
# not an owner/name, so #555's --archive shape check would refuse it with
# the same exit 2 and the same zero calls even if the case-insensitive
# fallback match were dropped. Asserting the not-configured wording — and
# that the owner/name refusal is NOT what fired — is what keeps the
# lowercase fold load-bearing (mutation: VALUE_LC="$VALUE").
grep -qi "archive not configured" "$OUT/run.stderr.log" \
  || report "capitalized None fallback: stderr did not report 'archive not configured' — the case-insensitive fallback match did not fire; it was refused for some other reason — $(cat "$OUT/run.stderr.log")"
grep -qi "must be owner/name" "$OUT/run.stderr.log" \
  && report "capitalized None fallback: refused as a malformed --archive rather than recognized as the documented not-configured fallback — the lowercase fold is not doing its job"

# ---------------------------------------------------------------------------
# Issue #737: JSON-lines validation runs independently of session-start
# lookup now — a malformed (non-JSON) line elsewhere in --log no longer
# refuses the whole archive; the valid session-start line still resolves
# the archive path, the run succeeds, and the invalid line is named by
# NUMBER on stderr rather than silently dropped or wholesale-refused. This
# is the exact scenario the issue's "waypoint-03" motivation names: a
# historical log with some bad lines is the file most worth preserving.
# ---------------------------------------------------------------------------
LOG_MALFORMED="$LOGS/malformed.jsonl"
{
  printf '{"ts":"%s","event":"session-start","claim":"test-01","session_id":"%s"}\n' "$SESSION_TS" "$SESSION_ID"
  printf 'NOT JSON AT ALL\n'
  printf '{"ts":"2026-08-30T09:05:00Z","event":"note","claim":"test-01","text":"trailing valid line"}\n'
} > "$LOG_MALFORMED"
RC=0; run_save_log "404" "" "" "" "$LOG_MALFORMED" --archive "$ARCHIVE_REPO" || RC=$?
[ "$RC" -eq 0 ] || report "malformed log line: expected exit 0 (archived despite the bad line), got $RC — $(cat "$OUT/run.stderr.log")"
[ "$(n_puts)" = "1" ] || report "malformed log line: expected exactly 1 PUT, got $(n_puts)"
grep -q '^save-log: ' "$OUT/run.stderr.log" \
  || report "malformed log line: stderr is missing the save-log: prefix — $(cat "$OUT/run.stderr.log")"
grep -qi "invalid JSON line" "$OUT/run.stderr.log" \
  || report "malformed log line: stderr did not report the invalid-line diagnostic — $(cat "$OUT/run.stderr.log")"
grep -qE '\bat 2\b' "$OUT/run.stderr.log" \
  || report "malformed log line: stderr did not name line 2 by NUMBER, per #737's acceptance criteria — $(cat "$OUT/run.stderr.log")"
mal_mut=$(tail -1 "$OUT/mutations.log")
mal_body_file=$(jq -r .body_file <<<"$mal_mut")
grep -qF "NOT JSON AT ALL" "$mal_body_file" \
  || report "malformed log line: the archived blob must preserve the invalid line UNMODIFIED, not repair or drop it"

# The same log, but with the ONLY session-start line itself being the
# malformed one — every line fails to parse or none is a session-start, so
# this remains the documented exit-1 hard failure, distinct from the
# above.
LOG_ALL_MALFORMED="$LOGS/all-malformed.jsonl"
{
  printf 'NOT JSON AT ALL\n'
  printf 'ALSO NOT JSON\n'
} > "$LOG_ALL_MALFORMED"
RC=0; run_save_log "404" "" "" "" "$LOG_ALL_MALFORMED" --archive "$ARCHIVE_REPO" || RC=$?
[ "$RC" -eq 1 ] || report "all-malformed log: expected exit 1 (no session-start among valid lines), got $RC — $(cat "$OUT/run.stderr.log")"
[ "$(n_calls)" = "0" ] || report "all-malformed log: expected zero gh calls, got $(n_calls)"
grep -qi "session-start" "$OUT/run.stderr.log" \
  || report "all-malformed log: stderr did not name the missing session-start event — $(cat "$OUT/run.stderr.log")"

# ---------------------------------------------------------------------------
# Issue #737: --session-id overrides a missing session_id — the historical-
# log case this issue exists for.
# ---------------------------------------------------------------------------
LOG_NO_SESSION_ID="$LOGS/no-session-id.jsonl"
printf '{"ts":"%s","event":"session-start","claim":"test-01"}\n' "$SESSION_TS" > "$LOG_NO_SESSION_ID"
OVERRIDE_ID="historical-42"
RC=0; run_save_log "404" "" "" "" "$LOG_NO_SESSION_ID" --archive "$ARCHIVE_REPO" --session-id "$OVERRIDE_ID" || RC=$?
[ "$RC" -eq 0 ] || report "--session-id override: expected exit 0, got $RC — $(cat "$OUT/run.stderr.log")"
grep -qF "$OVERRIDE_ID" "$OUT/run.stdout.log" \
  || report "--session-id override: stdout did not name the archive path derived from the override id — $(cat "$OUT/run.stdout.log")"
so_mut=$(tail -1 "$OUT/mutations.log")
grep -qF "supplied via --session-id" <<<"$(jq -r .message <<<"$so_mut")" \
  || report "--session-id override: the PUT's commit message did not record that session_id came from the flag — $(jq -r .message <<<"$so_mut")"

# Without the override, the same log still fails the documented exit 1 —
# the flag is required, never assumed.
cp "$LOG_NO_SESSION_ID" "$WORK/no-session-id-no-flag.jsonl"
RC=0; run_save_log "404" "" "" "" "$WORK/no-session-id-no-flag.jsonl" --archive "$ARCHIVE_REPO" || RC=$?
[ "$RC" -eq 1 ] || report "missing session_id, no override: expected exit 1, got $RC — $(cat "$OUT/run.stderr.log")"
[ "$(n_calls)" = "0" ] || report "missing session_id, no override: expected zero gh calls, got $(n_calls)"
grep -qi "session_id" "$OUT/run.stderr.log" \
  || report "missing session_id, no override: stderr did not name session_id — $(cat "$OUT/run.stderr.log")"
grep -qi "\-\-session-id" "$OUT/run.stderr.log" \
  || report "missing session_id, no override: stderr did not mention --session-id as the way past this — $(cat "$OUT/run.stderr.log")"

# A log whose session-start ALREADY carries a session_id ignores a
# --session-id that MATCHES it — a no-op, not an error.
cp "$LOG_V1" "$WORK/session-id-match.jsonl"
RC=0; run_save_log "404" "" "" "" "$WORK/session-id-match.jsonl" --archive "$ARCHIVE_REPO" --session-id "$SESSION_ID" || RC=$?
[ "$RC" -eq 0 ] || report "--session-id matching existing: expected exit 0, got $RC — $(cat "$OUT/run.stderr.log")"

# --session-id CONFLICTING with an existing session_id is refused loudly
# (argerr, exit 2, zero calls) rather than either value silently winning.
cp "$LOG_V1" "$WORK/session-id-conflict.jsonl"
RC=0; run_save_log "404" "" "" "" "$WORK/session-id-conflict.jsonl" --archive "$ARCHIVE_REPO" --session-id "some-other-id" || RC=$?
[ "$RC" -eq 2 ] || report "--session-id conflict: expected exit 2, got $RC — $(cat "$OUT/run.stderr.log")"
[ "$(n_calls)" = "0" ] || report "--session-id conflict: expected zero gh calls, got $(n_calls)"
grep -qi "conflict" "$OUT/run.stderr.log" \
  || report "--session-id conflict: stderr did not name the conflict — $(cat "$OUT/run.stderr.log")"

# ---------------------------------------------------------------------------
# Issue #836 relay F1: a malformed --session-id value must be blamed on
# --session-id BY NAME, never on "the log's session-start event" — the log
# never carried this value, and naming the log as the source would point
# the operator at editing it, exactly the wrong-cause diagnostic #737
# exists to avoid. Sub-case: an EMPTY --session-id is refused at parse
# time (exit 2), never accepted and misdiagnosed later as "session_id is
# missing, pass --session-id" when the caller just did.
# ---------------------------------------------------------------------------
LOG_NO_SESSION_ID_2="$LOGS/no-session-id-2.jsonl"
printf '{"ts":"%s","event":"session-start","claim":"test-01"}\n' "$SESSION_TS" > "$LOG_NO_SESSION_ID_2"
RC=0; run_save_log "404" "" "" "" "$LOG_NO_SESSION_ID_2" --archive "$ARCHIVE_REPO" --session-id "bad/id" || RC=$?
[ "$RC" -eq 1 ] || report "malformed --session-id (#836 F1): expected exit 1, got $RC — $(cat "$OUT/run.stderr.log")"
[ "$(n_calls)" = "0" ] || report "malformed --session-id (#836 F1): expected zero gh calls, got $(n_calls)"
grep -qF -- "--session-id" "$OUT/run.stderr.log" \
  || report "malformed --session-id (#836 F1): stderr did not blame --session-id by name — $(cat "$OUT/run.stderr.log")"
grep -qi "session-start event" "$OUT/run.stderr.log" \
  && report "malformed --session-id (#836 F1): stderr wrongly blamed the log's session-start event for a value that came from argv — $(cat "$OUT/run.stderr.log")"

cp "$LOG_NO_SESSION_ID_2" "$WORK/empty-session-id.jsonl"
RC=0; run_raw "404" "" "" "" --log "$WORK/empty-session-id.jsonl" --repo "$WORKING_REPO" --archive "$ARCHIVE_REPO" --session-id "" || RC=$?
[ "$RC" -eq 2 ] || report "empty --session-id (#836 F1): expected exit 2 (refused at parse time), got $RC — $(cat "$OUT/run.stderr.log")"
grep -qi "session-id" "$OUT/run.stderr.log" \
  || report "empty --session-id (#836 F1): stderr did not name --session-id — $(cat "$OUT/run.stderr.log")"
grep -qi "missing session_id" "$OUT/run.stderr.log" \
  && report "empty --session-id (#836 F1): an empty override must never surface as the log's own missing-session_id failure — $(cat "$OUT/run.stderr.log")"

# An unreadable --log (mode 000) is surfaced the same way — attributed and
# exit 1, not a bare bash "Permission denied" with no prefix.
LOG_UNREADABLE="$LOGS/unreadable.jsonl"
cp "$LOG_V1" "$LOG_UNREADABLE"
chmod 000 "$LOG_UNREADABLE"
RC=0; run_save_log "404" "" "" "" "$LOG_UNREADABLE" --archive "$ARCHIVE_REPO" || RC=$?
chmod 644 "$LOG_UNREADABLE"
if [ "$(id -u)" -eq 0 ]; then
  echo "SKIP: unreadable --log case skipped — running as root, mode 000 has no effect" >&2
else
  [ "$RC" -eq 1 ] || report "unreadable log: expected exit 1, got $RC"
  grep -q '^save-log: ' "$OUT/run.stderr.log" \
    || report "unreadable log: stderr is missing the save-log: prefix — $(cat "$OUT/run.stderr.log")"
fi

# ---------------------------------------------------------------------------
# Issue #459, round 3: a flag missing its value goes through argerr — exit
# 2, save-log:-prefixed — never bash's own bare `${2:?}` (exit 1,
# unprefixed).
# ---------------------------------------------------------------------------
RC=0; run_raw "404" "" "" "" --log || RC=$?
[ "$RC" -eq 2 ] || report "--log with no value: expected exit 2, got $RC — $(cat "$OUT/run.stderr.log")"
grep -q '^save-log: ' "$OUT/run.stderr.log" \
  || report "--log with no value: stderr is missing the save-log: prefix — $(cat "$OUT/run.stderr.log")"

RC=0; run_raw "404" "" "" "" --log "$WORK/x.jsonl" --archive || RC=$?
[ "$RC" -eq 2 ] || report "--archive with no value: expected exit 2, got $RC — $(cat "$OUT/run.stderr.log")"
grep -q '^save-log: ' "$OUT/run.stderr.log" \
  || report "--archive with no value: stderr is missing the save-log: prefix — $(cat "$OUT/run.stderr.log")"

# ---------------------------------------------------------------------------
# Issue #459, round 3: a log with no trailing newline does not get the
# note line concatenated onto its last line, in either the local file or
# the archived blob.
# ---------------------------------------------------------------------------
LOG_NO_TRAILING_NL="$WORK/no-trailing-nl.jsonl"
printf '{"ts":"%s","event":"session-start","claim":"test-01","session_id":"%s"}' \
  "$SESSION_TS" "$SESSION_ID" > "$LOG_NO_TRAILING_NL"
[ -z "$(tail -c1 "$LOG_NO_TRAILING_NL")" ] \
  && { echo "fixture bug: no-trailing-nl fixture unexpectedly ends in a newline" >&2; exit 1; }
RC=0; run_save_log "404" "" "" "" "$LOG_NO_TRAILING_NL" --archive "$ARCHIVE_REPO" || RC=$?
[ "$RC" -eq 0 ] || report "no trailing newline: expected exit 0, got $RC — $(cat "$OUT/run.stderr.log")"
[ "$(wc -l < "$LOG_NO_TRAILING_NL" | tr -d ' ')" = "2" ] \
  || report "no trailing newline: expected exactly 2 physical lines in the local log after the append (session-start + note), got $(wc -l < "$LOG_NO_TRAILING_NL" | tr -d ' ') — the note line must not be concatenated onto the unterminated first line"
[ "$(jq -c 'select(.event=="session-start")' "$LOG_NO_TRAILING_NL" | wc -l | tr -d ' ')" = "1" ] \
  || report "no trailing newline: session-start event is not parseable as its own line after the append"
nt_mut=$(tail -1 "$OUT/mutations.log")
[ "$(wc -l < "$(jq -r .body_file <<<"$nt_mut")" | tr -d ' ')" = "2" ] \
  || report "no trailing newline: the archived blob also concatenated the note line onto the unterminated first line"

# ---------------------------------------------------------------------------
# Issue #459, round 3: the 409/422 retry RE-SNAPSHOTS --log before
# resending — a line appended between the first (failed) PUT and the
# retry must be present in the retried PUT's body, not silently dropped
# in favor of the pre-conflict snapshot.
# ---------------------------------------------------------------------------
RETRY_LOG="$WORK/retry-resnapshot.jsonl"
cp "$LOG_V1" "$RETRY_LOG"
: > "$OUT/calls.log"; : > "$OUT/mutations.log"
echo 0 > "$OUT/get_count"; echo 0 > "$OUT/put_count"
rm -rf "$OUT/bodies"; mkdir -p "$OUT/bodies"

# Reuse the standard mock (conflict mode, with a delay on the PUT), and
# race the extra line in ourselves while the first (about-to-fail) PUT is
# genuinely in flight, using the same put-started delay signal the
# concurrent-append case above relies on. No separate wrapper mock needed.
RETRY_OLD_SHA="3333333333333333333333333333333333333333"
RETRY_NEW_SHA="4444444444444444444444444444444444444444"
set +e
MOCK_GH_CALLS="$OUT/calls.log" MOCK_GH_MUTATIONS="$OUT/mutations.log" \
  MOCK_GH_GET_COUNT="$OUT/get_count" MOCK_GH_PUT_COUNT="$OUT/put_count" \
  MOCK_GH_PUT_BODIES="$OUT/bodies" MOCK_GH_PUT_DELAY=2 \
  MOCK_GH_MODE="conflict" MOCK_GH_SHA="" MOCK_GH_OLD_SHA="$RETRY_OLD_SHA" MOCK_GH_NEW_SHA="$RETRY_NEW_SHA" \
  PATH="$BIN:$PATH" \
  "$SAVE_LOG_SH" --log "$RETRY_LOG" --repo "$WORKING_REPO" --archive "$ARCHIVE_REPO" \
  > "$OUT/run.stdout.log" 2> "$OUT/run.stderr.log" &
RETRY_PID=$!
set -e
waited=0
while [ ! -f "$OUT/bodies/put-started" ] && [ "$waited" -lt 150 ]; do
  sleep 0.1; waited=$((waited + 1))
done
[ -f "$OUT/bodies/put-started" ] \
  || report "retry re-snapshot: the mocked first PUT never signalled in-flight — the race could not be staged"
printf '%s\n' '{"ts":"2026-08-30T09:08:00Z","event":"heartbeat","claim":"test-01","text":"raced in before the conflict retry"}' >> "$RETRY_LOG"
RC=0; set +e; wait "$RETRY_PID"; RC=$?; set -e
[ "$RC" -eq 0 ] || report "retry re-snapshot: expected exit 0 after the retry, got $RC — $(cat "$OUT/run.stderr.log")"
[ "$(n_puts)" = "2" ] || report "retry re-snapshot: expected exactly 2 PUTs, got $(n_puts)"
retry_second_put=$(sed -n '2p' "$OUT/mutations.log")
retry_body_file=$(jq -r .body_file <<<"$retry_second_put")
grep -qF "raced in before the conflict retry" "$retry_body_file" \
  || report "retry re-snapshot: the retried PUT's body does not carry the line that raced in before it — the retry re-sent the PRE-conflict snapshot instead of re-snapshotting --log"
grep -qF "raced in before the conflict retry" "$RETRY_LOG" \
  || report "retry re-snapshot: fixture bug — the race line never actually landed in the local log"

# ---------------------------------------------------------------------------
# Hermeticity tripwire (#568, #477): the mock recorded every invocation it
# served, and none of them arrived from a context the harness did not set
# up. Proved load-bearing first, against its own throwaway log: the script
# under test is run with the mock on PATH but WITHOUT the per-run harness
# env, and the marker must appear.
# ---------------------------------------------------------------------------
TRIPWIRE_LOG="$OUT/tripwire-probe.log"
: > "$TRIPWIRE_LOG"
set +e
env -u MOCK_GH_CALLS -u MOCK_GH_MUTATIONS -u MOCK_GH_GET_COUNT -u MOCK_GH_PUT_COUNT \
  -u MOCK_GH_PUT_BODIES -u MOCK_GH_MODE \
  PATH="$BIN:$PATH" MOCK_GH_CALL_LOG="$TRIPWIRE_LOG" \
  "$SAVE_LOG_SH" --log "$LOG_V1" --repo "$WORKING_REPO" --archive "$ARCHIVE_REPO" \
  >/dev/null 2>&1
set -e
grep -q '^UNMOCKED-CONTEXT ' "$TRIPWIRE_LOG" \
  || report "tripwire probe: an unmocked-context gh call was NOT marked — the tripwire is not load-bearing"

[ -s "$MOCK_GH_CALL_LOG" ] \
  || report "hermeticity: the mock recorded zero invocations — the call log is not wired up"
if grep -q '^UNMOCKED-CONTEXT ' "$MOCK_GH_CALL_LOG"; then
  report "hermeticity: a gh call was made from an unmocked context: $(grep -m1 '^UNMOCKED-CONTEXT ' "$MOCK_GH_CALL_LOG")"
fi

if [ "$fail" -ne 0 ]; then
  echo "test_save_log: FAILED" >&2
  exit 1
fi

echo "test_save_log.sh: all checks passed"
