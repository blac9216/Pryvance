#!/usr/bin/env bash
# save-log.sh — archive the local session log into the configured private
# archive repository with a single Contents-API PUT. No clone.
#
# Usage: save-log.sh --log <session.jsonl> [--archive <owner/repo>]
#                     [--repo <owner/repo>] [--work-tracking <path>]
#                     [--session-id <id>] [--claim <id>] [--dry-run]
#
# Contract: refuse rather than guess.
#
#   - Archive location: read from docs/process/work-tracking.md's
#     `Session-log archive: <owner>/<repo>` bare line (written by the
#     configure-workflow session-log-archive fixture step) OR a markdown
#     TABLE ROW naming it — `| Session-log archive | <owner>/<repo> |`,
#     label matched case-insensitively, value optionally backtick-wrapped,
#     row optionally indented by 0-3 leading spaces per CommonMark/GFM
#     (4+ is an indented code block, not a table row, and a leading TAB
#     is treated the same as 4+ spaces — see #758) — since every other
#     configured value in this document is a table row and a filer
#     following that convention instead of the bare-line one must not
#     read as silently not-configured (#746). The bare line
#     is tried first; the table row is tried only when no bare line
#     matches, so a document carrying both (should that ever happen) is
#     resolved by the bare line, unambiguously. `--archive` overrides the
#     doc either way. NOT-CONFIGURED BEHAVIOUR:
#     when neither `--archive` nor a repository-naming line is present —
#     the line is absent entirely, or it reads the documented
#     "none — session logs stay scratch-only" fallback, matched EXACTLY
#     and case-insensitively (never a `none*` prefix match, which would
#     misclassify a genuinely configured archive such as `nonesuch/logs`)
#     — this script exits 2 with "archive not configured — run the
#     configure-workflow session-log archive step" and issues no API call
#     at all — not even the `--repo` resolution below, which is only
#     attempted once this gate has already passed. It never guesses a
#     repository name. An EXPLICITLY-PASSED `--work-tracking` path that
#     does not exist is a distinct, louder failure (exit 1, naming the
#     missing file) from not-configured — only the DEFAULT path
#     (docs/process/work-tracking.md, unset by the caller) being absent
#     folds into the ordinary not-configured case, since "no doc yet" is
#     expected there. A THIRD case is likewise distinct (issue #805): a
#     `Session-log archive` line/row that IS present in the document but
#     matches neither the bare-line nor the table-row regex — a filer's
#     near-miss — is never folded into "not configured" either; an
#     unanchored, un-shape-checked grep for the bare label text catches
#     this and exits 1 naming the parse failure, so a filer's real effort
#     is never misread as "nothing is here".
#   - File path in the archive: `logs/<repo>/<session-start-ISO>-<session_id>.jsonl`,
#     where <repo> is the WORKING repo this session ran in (--repo, else
#     `gh repo view` on the current checkout) — distinct from the archive
#     repo the file is PUT into — and <session-start-ISO>/<session_id> come
#     from the local log's own `session-start` event (`ts`, `session_id`
#     keys, formats/session-log.md). Fails loudly, before any API call,
#     when the log has no `session-start` event, that event is missing
#     both `session_id` and `--session-id`, `ts` is missing (no override
#     for `ts` — see below), or `ts`/`session_id` is not a safe single
#     path segment (see Input validation below).
#   - `--session-id <id>`: a HISTORICAL log's `session-start` event can
#     predate the `session_id` field entirely (issue #737) — every other
#     way past the refusal above is worse (editing the log falsifies the
#     record it exists to preserve; bypassing this script for a hand PUT
#     skips every check below). The flag is therefore an explicit,
#     narrow override: it is used ONLY when the log's own `session-start`
#     carries no `session_id` at all. When the event already HAS one and
#     `--session-id` is also passed, the two must agree exactly — a
#     mismatch is refused loudly (argerr, no API call) rather than either
#     value winning silently, since a caller who typed a wrong override is
#     better told than half-obeyed. An override actually used is recorded
#     in the PUT's commit message (`, session_id supplied via
#     --session-id` appended) — provenance belongs in the artifact itself,
#     not a sidecar note someone has to maintain. An EMPTY `--session-id`
#     value is refused at parse time (argerr), before it can ever be
#     mistaken for "not passed" and surface as the log's own missing-
#     session_id failure instead. `--session-id`'s value is validated by
#     the same character check as the log's own `session_id` (see Input
#     validation below) before it reaches `ARCHIVE_PATH` — but a value that
#     fails is blamed on `--session-id` BY NAME, never on "the log's
#     session-start event": the log did not carry this value at all, and
#     naming it as the source would point the operator at editing the log
#     to fix it, exactly the outcome #737 exists to avoid (issue #836
#     relay F1).
#   - JSON-lines validation runs INDEPENDENTLY of `session-start` lookup
#     (issue #737): a line that fails to parse as JSON no longer aborts the
#     whole archive — it is collected by line number and reported on
#     stderr (`N invalid JSON line(s) at ...`), and the run proceeds using
#     whatever valid lines remain, including the `session-start` event
#     itself if it is one of them. A historical log with a couple of bad
#     lines out of dozens is exactly the file most worth preserving, so
#     "archived, with 2 invalid lines named" beats either silently
#     accepting it or refusing it wholesale. Only when NO valid
#     `session-start` event can be found among the lines that DID parse
#     does this remain a hard failure.
#   - Input validation: every value that is interpolated into an API
#     endpoint path is shape-checked before it can reach a call, and
#     every one of those checks is a WHOLE-STRING test — bash `[[ =~ ]]`
#     (whose `^`/`$` are string start/end, never line start/end) or a
#     `case` glob, never `printf '%s' "$v" | grep -Eq '^...$'`. A piped
#     `grep` is LINE-oriented: it succeeds when ANY line matches, so a
#     value whose FIRST line conforms passes with the rest unchecked, and
#     `--repo $'ok/ok\n../../../etc/pwn'` (or a `session_id` carrying an
#     embedded newline) sails through and traverses out of the archive
#     repository's `logs/` prefix anyway. That bypass is the reason this
#     file contains no piped-grep validator at all.
#       * `--repo` and `--archive` must both match `owner/name`
#         (`^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$`) AND have no `.` or `..`
#         segment — the character class alone admits `../..`, which is a
#         two-segment traversal that matches the pattern exactly. `--repo`
#         is checked as soon as it is resolved (from the flag, or from
#         `gh repo view`) and before it derives `ARCHIVE_PATH`;
#         `--archive` (from the flag or from the work-tracking doc line)
#         is checked immediately after the not-configured gate, before
#         `gh repo view` or any other call, since it is the PUT's target
#         repository and the more consequential of the two.
#       * The log's own `session-start` event's `ts` and `session_id` are
#         each required to be a single path segment, checked before either
#         is interpolated into `ARCHIVE_PATH`, for the same reason: they
#         come from file content this script does not control. This check
#         is an ALLOW-LIST — `^[A-Za-z0-9:_.+-]+$` — not a deny-list: an
#         ISO 8601 UTC `ts` and a harness-assigned `session_id`
#         (formats/session-log.md) both fit that class fully, so nothing
#         legitimate is excluded, and every byte outside it is refused,
#         including raw non-ASCII bytes a deny-list of `/`, whitespace,
#         `..` and `%` would silently pass — e.g. an over-long UTF-8
#         encoding of `.` (`0xC0 0xAE`) or `/` (`0xC0 0xAF`), neither of
#         which carries a literal `.`, `/`, `%` or whitespace byte (issue
#         #630). The explicit `..` and `%` checks below are kept ahead of
#         the allow-list purely so those two specific, previously-known
#         shapes stay individually attributable in the failure message
#         rather than falling through to the generic "not a safe path
#         segment character" one; the allow-list is what actually keeps the
#         check fail-closed even if one of those two explicit checks were
#         ever deleted. `%` is not itself in the allow-list character
#         class, so a payload such as `%2e%2e%2f%2e%2e%2fetc` is refused
#         either way; it is refused outright rather than percent-decoded,
#         since decoding first would be one more transform of untrusted
#         content rather than fewer (issue #595).
#   - Skip path: a GET of the remote file's `sha` (a plain HTTP 404 means
#     "first save", not a failure) compared against `git hash-object` of the
#     local file, AS IT CURRENTLY STANDS — the same SHA-1 the Contents API
#     reports for an existing blob. Equal shas print "unchanged, skipped"
#     and issue zero PUTs. HTTP status is read from `gh api`'s own
#     parenthesised `(HTTP <code>)` error form, matched as that literal
#     form (parentheses included) and not merely as the bare digits —
#     never a bare substring match over the whole stderr text, which also
#     embeds the endpoint URL (and therefore the archive path's repo name,
#     session timestamp and session id) and so could misclassify an
#     unrelated failure whose URL happens to contain the same digits.
#   - Update path (append-before-hash): a `note` confirmation line is
#     built first, and a WORKING COPY of the log carrying it — a snapshot
#     of `--log` as it stood when the copy was taken, plus that one note
#     line — is what gets hashed, encoded and PUT. Never the pre-append
#     content. This is what makes the skip path above reachable on every
#     save after the first: a run with nothing new appended since the
#     previous save hashes to exactly the sha that previous save's PUT
#     carried, so it skips with zero PUTs — three consecutive saves with
#     no session activity between them issue exactly one PUT (the first),
#     not three. The PUT itself carries the previous `sha` (a create PUT —
#     first save — carries no `sha` at all) and a commit message naming
#     the working repo and the session id. A 409 or 422 response is
#     re-GET'd for a fresh `sha`, and the working copy is RE-SNAPSHOTTED
#     from `--log` as it now stands (not the pre-conflict snapshot) before
#     the single retry — so a concurrent writer's line that landed between
#     the first attempt and the retry is not silently dropped from the
#     retried PUT. Retried exactly once; any other failure, or a second
#     409/422, is a hard failure.
#   - Trailing newline: `--log` is JSON LINES (formats/session-log.md), one
#     object per physical line. If the file does not already end in a
#     newline — the realistic source is a writer killed mid-append — a
#     newline is inserted before the note line is added, both in the
#     working copy that gets PUT and in the write-back to `--log` itself,
#     so the note is never concatenated onto the previous (unterminated)
#     line. Without this, two JSON objects would land on one physical
#     line, which every line-oriented consumer of the log (`head -1`,
#     `wc -l`, per-line greps) would then miscount.
#   - Write-back is an APPEND, never an overwrite. `--log` is declared
#     append-only by formats/session-log.md and the heartbeat cron is
#     still live at the point in the close checklist where this script
#     runs, so the working copy is NEVER copied back over `--log`: on a
#     confirmed PUT the single note line — the same line the archived blob
#     carries — is appended to the live file with one `>>` write, and
#     nothing else about that file is touched. The consequence is a
#     deliberate, documented weakening of the old byte-identity claim:
#     after a successful save the local file is byte-identical to the
#     archived blob WHEN NOTHING WAS APPENDED DURING THE PUT, and
#     otherwise a strict SUPERSET of it (every line of the blob is in the
#     local file, plus whatever raced in) — never a truncation of it. The
#     superset case simply fails the next run's unchanged check, so the
#     next save PUTs the fuller file and the two converge after exactly
#     one extra PUT, which this design already tolerates everywhere else.
#     On any failure the `--log` file is left completely untouched — the
#     note is appended only after the PUT is confirmed to have succeeded.
#   - Output: the archive path and the response's commit URL on stdout.
#     `--dry-run` performs the GET and the hash comparison against the
#     file's current (pre-append) content (so it reports accurately what a
#     real run's skip/no-skip decision would be) but issues no PUT, builds
#     no working copy, and appends no log line.
#   - `--log <path>` is BOTH the session log this script archives AND,
#     after a successful (non-dry-run) archive, the file this script
#     appends its own event line to — the two are the same file by design,
#     since the log being archived is exactly the log a caller would want
#     the confirmation appended to. session-log.md has no dedicated event
#     for this, so a `note` event is appended (`text:"log archived to
#     <path>"`), carrying the required `claim` key (`--claim`'s value, or
#     JSON `null` when not passed — same rule board-audit.sh and
#     stamp-claim.sh follow for their own appended lines); without a
#     successful archive nothing is appended, and the line is never
#     written to stderr instead — --log is this script's required INPUT,
#     not an optional destination, so there is nothing to fall back to
#     when it is absent (there is no run without it).
#   - Bounded file size: the GitHub Contents API rejects a PUT/GET over
#     1 MB of blob content; this script refuses any local file above that
#     bound BEFORE any API call, with a message naming the limit, rather
#     than let a 400-class response bubble up unexplained partway through.
#     The bound is applied TWICE against the same limit: once to `--log`
#     itself before any call at all, and once to the post-append candidate
#     just before the PUT — a file at exactly the bound grows past it once
#     the note line is added, and it is the candidate, not the input, that
#     the API actually has to accept.
#   - The payload never touches argv. Linux caps a SINGLE argv element at
#     MAX_ARG_STRLEN (131072 bytes) regardless of ARG_MAX, so passing the
#     base64 body as `-f content=<base64>` capped this script at roughly a
#     93 KB log — a tenth of the 1 MB it advertises — and failed there
#     with a bare `Argument list too long` naming neither cause nor
#     remedy. The request body is therefore built as a JSON FILE with
#     `jq -n --rawfile` (the base64 is read from a file, never expanded
#     into a shell word) and handed to `gh api --input <file>`, so payload
#     size is bounded only by the 1 MB check above.
#
# No repository- or owner-specific nouns appear in this script; both the
# working repo and the archive repo are supplied by the caller or read from
# docs/process/work-tracking.md.
#
# Exit codes: 2 = argument error — a missing/unknown flag or its value, a
# malformed `--repo` or `--archive` (not `owner/name`, or carrying a `.`
# or `..` segment), "archive not configured" (no API call issued), or
# `--session-id` conflicting with the log's own `session-start`
# `session_id`. 1 = a hard failure — the file is missing, over the 1 MB
# bound (either as given or as the post-append candidate), has no usable
# `session-start` event among its valid JSON lines, that event's
# `ts`/(`session_id` or `--session-id`) is not a safe path segment, an
# explicitly-passed `--work-tracking` path does not exist, work-tracking.md
# has a `Session-log archive` line/row present but unparseable (#805), a
# GET/PUT failed for a reason other than the documented 404-means-
# first-save case, or the note line could not be appended after a
# successful archive. Individual invalid JSON lines in `--log` are no
# longer themselves a failure (#737) — see the JSON-lines validation bullet
# above.
set -euo pipefail

die(){ echo "save-log: $*" >&2; exit 1; }
argerr(){ echo "save-log: $*" >&2; exit 2; }

LOG_PATH=""; ARCHIVE=""; REPO=""; WORK_TRACKING=""; WORK_TRACKING_EXPLICIT=0; CLAIM=""; DRY_RUN=0
SESSION_ID_OVERRIDE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --log) [ $# -ge 2 ] || argerr "--log needs a value"; LOG_PATH="$2"; shift 2 ;;
    --archive) [ $# -ge 2 ] || argerr "--archive needs a value"; ARCHIVE="$2"; shift 2 ;;
    --repo) [ $# -ge 2 ] || argerr "--repo needs a value"; REPO="$2"; shift 2 ;;
    --work-tracking)
      [ $# -ge 2 ] || argerr "--work-tracking needs a value"
      WORK_TRACKING="$2"; WORK_TRACKING_EXPLICIT=1; shift 2 ;;
    --session-id)
      [ $# -ge 2 ] || argerr "--session-id needs a value"
      [ -n "$2" ] || argerr "--session-id must not be empty"
      SESSION_ID_OVERRIDE="$2"; shift 2 ;;
    --claim) [ $# -ge 2 ] || argerr "--claim needs a value"; CLAIM="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -*) argerr "unknown flag $1" ;;
    *) argerr "unexpected extra argument $1" ;;
  esac
done
[ -n "$LOG_PATH" ] || argerr "usage: save-log.sh --log <session.jsonl> [--archive <owner/repo>] [--repo <owner/repo>] [--work-tracking <path>] [--session-id <id>] [--claim <id>] [--dry-run]"
[ -f "$LOG_PATH" ] || die "log file not found: $LOG_PATH"
# Checked as its own step, before any redirection (`wc -c <`, `jq ... <path>`)
# tries to open the file: an unreadable file would otherwise surface as
# bash's own unattributed "Permission denied" and abort under set -e
# before die() ever runs.
[ -r "$LOG_PATH" ] || die "log file not readable: $LOG_PATH"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/save-log.XXXXXX")"
cleanup(){ rm -rf "$WORK"; }
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Bounded file size — the Contents API's 1 MB blob limit — checked before
# any other work, including before resolving the archive location, so an
# oversized file is refused for exactly one reason.
# ---------------------------------------------------------------------------
MAX_BYTES=1048576
LOG_BYTES=$(wc -c < "$LOG_PATH" | tr -d ' ')
[ "$LOG_BYTES" -le "$MAX_BYTES" ] \
  || die "$LOG_PATH is $LOG_BYTES bytes, over the Contents API's 1 MB ($MAX_BYTES byte) limit — cannot archive as a single PUT"

# ---------------------------------------------------------------------------
# Archive location: --archive wins outright; otherwise the
# "Session-log archive: <owner>/<repo>" line in work-tracking.md. Its
# documented "none — ..." fallback value is matched EXACTLY and
# case-insensitively (never a `none*` prefix, which would misclassify a
# genuinely configured archive like `nonesuch/logs`), and the line's
# outright absence in the DEFAULT doc is the same not-configured fact —
# never guessed, never defaulted to a plausible-looking repo name. An
# EXPLICITLY-PASSED --work-tracking path that does not exist is a
# different, louder failure (see below) — it is not folded into
# not-configured. Resolved BEFORE --repo below so the not-configured exit
# issues no API call at all, including no `gh repo view`.
#
# The bare `^Session-log archive:` line at column zero is tried first; a
# markdown TABLE ROW naming it (`| Session-log archive | <value> |`, label
# matched case-insensitively) is tried only when the bare line is absent
# (#746) — every other configured value in this document is a table row,
# so that filers following the document's own convention are read, not
# silently treated as not-configured.
# ---------------------------------------------------------------------------
NOTCONFIG_FALLBACK="none — session logs stay scratch-only"

# validate_owner_name — the ONE shape check both --archive and --repo go
# through, and a WHOLE-STRING one. bash's `[[ =~ ]]` anchors `^`/`$` to the
# start and end of the whole string (no REG_NEWLINE), so a value carrying
# an embedded newline or carriage return fails outright; the piped
# `printf '%s' "$v" | grep -Eq '^...$'` spelling this replaces was
# LINE-oriented and accepted any value whose FIRST line conformed. The
# second test is not redundant with the first: the character class admits
# `.` and `..` as whole segments, so `../..` matches `owner/name` exactly
# while being pure traversal — every segment must therefore be refused as
# `.` or `..` explicitly. Returns 1 (never dies) so each caller can name
# its own flag in the message.
validate_owner_name(){ # validate_owner_name <value>
  local v="$1"
  [[ "$v" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || return 1
  case "/$v/" in
    */./*|*/../*) return 1 ;;
  esac
  return 0
}
if [ -z "$ARCHIVE" ]; then
  if [ -z "$WORK_TRACKING" ]; then
    REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) \
      || die "could not resolve the repo root to find docs/process/work-tracking.md — pass --work-tracking"
    WORK_TRACKING="$REPO_ROOT/docs/process/work-tracking.md"
  fi
  if [ -f "$WORK_TRACKING" ]; then
    LINE=$(grep -m1 -E '^Session-log archive:' "$WORK_TRACKING" || true)
    VALUE=$(printf '%s' "$LINE" | sed -E 's/^Session-log archive:[[:space:]]*//')
    if [ -z "$VALUE" ]; then
      # No bare line — try the table-row form. Label matched
      # case-insensitively; value is everything up to the row's closing
      # `|`, then trimmed and stripped of backtick wrapping (#746).
      # CommonMark/GFM permits up to three leading spaces before any
      # block-level construct (a table row included) without it losing
      # its block-level meaning, so `^[ ]{0,3}` before the leading `|`
      # accepts 0-3 spaces of indentation and rejects 4+, which CommonMark
      # itself reinterprets as an indented code block, not a table row
      # (#758). The leading class is `[ ]` (a literal space), never
      # `[[:space:]]` — a leading TAB is deliberately NOT accepted here:
      # CommonMark expands a tab to the next multiple-of-4 column, so even
      # a single leading tab reaches column 4 and lands in the same
      # indented-code-block territory as four spaces; treating it as
      # equivalent to "a little indentation" would be wrong in exactly the
      # direction #758 was filed to close.
      # shellcheck disable=SC2016 # this grep -oP pattern is intentionally single-quoted; nothing here is meant to expand
      ROW_VALUE=$(grep -m1 -ioP '^[ ]{0,3}\|[[:space:]]*Session-log archive[[:space:]]*\|[[:space:]]*\K[^|]*' \
        "$WORK_TRACKING" || true)
      VALUE=$(printf '%s' "$ROW_VALUE" | sed -E 's/`//g; s/[[:space:]]+$//')
    fi
    if [ -z "$VALUE" ]; then
      # Issue #805: neither the bare-line nor the table-row regex captured
      # a value. That is the same observable outcome whether a
      # `Session-log archive` line/row is genuinely absent (the ordinary,
      # expected "not configured" case) or one is PRESENT but shaped
      # wrong — a filer's near-miss that reads identically to "nothing is
      # here" unless something distinguishes the two. Grep the document,
      # unanchored and case-insensitively, for the bare label text itself
      # (not shape-checked at all): a match here with VALUE still empty
      # means a line/row exists that neither regex could parse, which is a
      # malformed configuration, not an absent one, and deserves a loud,
      # distinct failure naming the actual cause rather than silently
      # reading as not-configured (the same conflation #743 and #770 each
      # fixed once already this session, for the reader and the validator
      # respectively).
      if grep -qi 'Session-log archive' "$WORK_TRACKING"; then
        die "$WORK_TRACKING has a 'Session-log archive' line/row that could not be parsed — check its exact shape against the documented forms: a bare 'Session-log archive: <owner>/<repo>' line, or a '| Session-log archive | <owner>/<repo> |' table row indented 0-3 spaces (never a tab)"
      fi
      ARCHIVE=""
    else
      VALUE_LC=$(printf '%s' "$VALUE" | tr '[:upper:]' '[:lower:]')
      case "$VALUE_LC" in
        "$NOTCONFIG_FALLBACK") ARCHIVE="" ;;
        *) ARCHIVE="$VALUE" ;;
      esac
    fi
  elif [ "$WORK_TRACKING_EXPLICIT" -eq 1 ]; then
    # An explicitly-named --work-tracking that does not exist is a real
    # error naming the real cause, not "not configured" — distinct from
    # the default path being absent, which is the ordinary "no doc yet"
    # case handled by the not-configured gate just below.
    die "work-tracking doc not found: $WORK_TRACKING (pass --work-tracking)"
  fi
fi
[ -n "$ARCHIVE" ] \
  || argerr "archive not configured — run the configure-workflow session-log archive step"
# The archive repo is interpolated into BOTH endpoint paths
# (`repos/$ARCHIVE/contents/...`, the GET and the PUT), so it gets the same
# owner/name shape check --repo gets, and it gets it here — after the
# not-configured gate (so "not configured" stays the message for an absent
# value) but before `gh repo view` or any API call, whether the value came
# from --archive or from the work-tracking doc line. Issue #555.
validate_owner_name "$ARCHIVE" \
  || argerr "--archive must be owner/name (letters, digits, '.', '_', '-' per segment, no '.' or '..' segment), got: $ARCHIVE"

# ---------------------------------------------------------------------------
# Working repo: --repo wins outright; otherwise `gh repo view` on the
# current checkout. Only reached once the not-configured gate above has
# already passed, so this call is never issued on that path. Validated as
# `owner/name` immediately, before it is used to derive ARCHIVE_PATH or
# issue any further call — see the header's Input validation note.
# ---------------------------------------------------------------------------
[ -n "$REPO" ] || REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null) \
  || die "could not resolve --repo and 'gh repo view' failed — pass --repo owner/name"
validate_owner_name "$REPO" \
  || argerr "--repo must be owner/name (letters, digits, '.', '_', '-' per segment, no '.' or '..' segment), got: $REPO"

# ---------------------------------------------------------------------------
# session-start event: ts + session_id, read from the local log itself.
# JSON-lines validation now runs INDEPENDENTLY of that lookup (issue #737):
# a single jq invocation (`-Rn`/`inputs`, never the default top-level
# streaming parse `jq -c 'select(...)' file` used before) reads the file
# ONE RAW LINE AT A TIME and wraps each line's `fromjson` in its own
# `try/catch`, so one malformed line can no longer abort parsing of every
# line after it — the default streaming parser dies outright on the FIRST
# bad token in the stream, discarding whatever session-start event a later,
# perfectly valid line carries. Nothing here pipes jq's stdout into `head`
# (the issue #592 EPIPE regression this file already guards against): the
# whole scan, including the search for the first session-start event, is
# one jq process that reads to EOF and writes one JSON object to a file.
#
# The reduce accumulates {ss: <first session-start object or null>,
# bad: [<1-based line numbers that failed to parse>]}. A parse-error
# sentinel object ({"__save_log_parse_error__":true}) distinguishes a
# genuine parse failure from a legitimately-parsed value, rather than
# comparing against a bare string a valid JSON-lines record could
# coincidentally equal.
if ! jq -Rn '
  reduce inputs as $line ({ss:null, bad:[]};
    .idx = (.idx // 0) + 1
    | ( $line | try fromjson catch {__save_log_parse_error__:true} ) as $r
    | if (($r|type)=="object") and ($r|has("__save_log_parse_error__")) then
        .bad += [.idx]
      elif (.ss==null) and (($r|type)=="object") and ($r.event=="session-start") then
        .ss = $r
      else
        .
      end
  ) | {ss:.ss, bad:.bad}
' "$LOG_PATH" >"$WORK/scan.json" 2>"$WORK/scan.err"; then
  die "$LOG_PATH's JSON-lines scan failed to run: $(cat "$WORK/scan.err")"
fi
INVALID_COUNT=$(jq '.bad | length' "$WORK/scan.json")
if [ "$INVALID_COUNT" -gt 0 ]; then
  INVALID_LINES_STR=$(jq -r '.bad | map(tostring) | join(", ")' "$WORK/scan.json")
  echo "save-log: $LOG_PATH has $INVALID_COUNT invalid JSON line(s) at $INVALID_LINES_STR — archiving as-is; the archived blob preserves them unmodified" >&2
fi
SS_EVENT=$(jq -c '.ss // empty' "$WORK/scan.json")
[ -n "$SS_EVENT" ] || die "$LOG_PATH has no session-start event among its valid JSON lines — cannot derive the archive file path"
SESSION_TS=$(printf '%s' "$SS_EVENT" | jq -r '.ts // empty')
SESSION_ID=$(printf '%s' "$SS_EVENT" | jq -r '.session_id // empty')
[ -n "$SESSION_TS" ] || die "$LOG_PATH's session-start event is missing ts — cannot derive the archive file path"

# --session-id (issue #737): a narrow override, used ONLY when the log's
# own session-start carries no session_id at all — the realistic case is a
# HISTORICAL log predating the field. When the event already has one and
# --session-id is also passed, the two must agree exactly; a mismatch is
# refused loudly rather than either value winning silently.
SESSION_ID_FROM_FLAG=0
if [ -z "$SESSION_ID" ]; then
  if [ -n "$SESSION_ID_OVERRIDE" ]; then
    SESSION_ID="$SESSION_ID_OVERRIDE"
    SESSION_ID_FROM_FLAG=1
  fi
elif [ -n "$SESSION_ID_OVERRIDE" ] && [ "$SESSION_ID_OVERRIDE" != "$SESSION_ID" ]; then
  argerr "--session-id ($SESSION_ID_OVERRIDE) conflicts with $LOG_PATH's own session-start session_id ($SESSION_ID) — pass no --session-id, or one matching the log's own value"
fi
[ -n "$SESSION_ID" ] \
  || die "$LOG_PATH's session-start event is missing session_id — cannot derive the archive file path (pass --session-id to override for a historical log with none)"

# Both values come from content this script does not control (the log
# itself for ts, and EITHER the log or an operator-supplied argv value for
# session_id — see #737's --session-id override just above), and both are
# interpolated straight into ARCHIVE_PATH below — validated as a single
# safe path segment (no '/', no '..', no whitespace) BEFORE that
# interpolation, so neither can traverse out of the archive repository's
# `logs/` prefix. See header's Input validation note and issue #459.
#
# The caller passes a SOURCE DESCRIPTION, not a bare field label (issue
# #836 relay F1): a bad --session-id must be blamed on --session-id, not
# on "the log's session-start event" — the log did not carry this value at
# all, and pointing at the log is exactly the wrong-cause diagnostic
# editing-the-log-to-fix-it would invite, which is what #737 exists to
# avoid. The two call sites below build that description from
# SESSION_ID_FROM_FLAG, so the message always names where the value
# actually came from.
validate_path_segment(){ # validate_path_segment <source-description> <value>
  local desc="$1" val="$2"
  case "$val" in
    *..*) die "$desc must not contain '..': $val" ;;
  esac
  # `%` is refused outright rather than percent-decoded: a value such as
  # `%2e%2e%2f%2e%2e%2fetc` passes the '..' check above verbatim (no
  # literal '..' byte), and decoding before that check would be one more
  # transform of untrusted content. No real ISO ts or session_id needs
  # '%', so refusing it is a pure narrowing, not a functional loss (issue
  # #595).
  case "$val" in
    *%*) die "$desc must not contain '%' (percent-encoding is refused outright, never decoded): $val" ;;
  esac
  # ALLOW-LIST (issue #630): the two checks above stay for their specific,
  # attributable messages, but this is what actually keeps the check
  # fail-closed. Whole-string, for the same reason validate_owner_name is:
  # `[[ =~ ]]` anchors `^`/`$` to the ends of the STRING (no REG_NEWLINE),
  # so a session_id like $'sess-1\netc/pwn' — whose first line is a
  # perfectly good segment — is refused here instead of putting a '/' into
  # ARCHIVE_PATH. The class covers every legal value of both fields — `ts`
  # is an ISO 8601 UTC timestamp, `session_id` is a harness-assigned
  # identifier or short random token (formats/session-log.md) — and
  # excludes everything else, including raw multi-byte/non-ASCII content
  # (e.g. an over-long UTF-8 encoding of '.' or '/') and control
  # characters that a deny-list of '/', whitespace, '..' and '%' would let
  # straight through.
  [[ "$val" =~ ^[A-Za-z0-9:_.+-]+$ ]] \
    || die "$desc must match ^[A-Za-z0-9:_.+-]+\$ (letters, digits, ':', '_', '.', '+', '-' only): $val"
}
validate_path_segment "$LOG_PATH's session-start event's ts" "$SESSION_TS"
if [ "$SESSION_ID_FROM_FLAG" -eq 1 ]; then
  validate_path_segment "--session-id" "$SESSION_ID"
else
  validate_path_segment "$LOG_PATH's session-start event's session_id" "$SESSION_ID"
fi

ARCHIVE_PATH="logs/$REPO/${SESSION_TS}-${SESSION_ID}.jsonl"

# ---------------------------------------------------------------------------
# HTTP status classification helper: `gh api` appends `(HTTP <code>)` to
# its own error message. Matching that exact parenthesised form, literal
# parentheses included — never a bare substring match over the whole
# stderr text — means the endpoint URL embedded in the same message (and
# therefore the archive path's repo name, session timestamp and session
# id) can never be misread as a status code. The match IS end-anchored:
# the installed `gh` (2.97.0) puts the parenthetical strictly last —
# `gh: <message> (HTTP <code>)`, verified directly against this repo's
# `gh` by triggering a real 404 — so nothing legitimate ever follows it.
# Anchoring at the end also closes a case an unanchored match misses: a
# message BODY that itself embeds a parenthesised code ahead of the real
# one, e.g. `gh: Internal server error: upstream said "not found (HTTP
# 404)" (HTTP 500)` — an unanchored `\(HTTP 404\)` matches the embedded
# code and misclassifies a genuine 500 as "first save"; the end-anchored
# form only ever matches the trailing, authoritative code (issue #594).
# ---------------------------------------------------------------------------
http_status_is(){ # http_status_is <code> <stderr-file>
  grep -qE "\(HTTP $1\)\$" "$2"
}

# ---------------------------------------------------------------------------
# GET the remote blob sha. A plain 404 means "first save" — a legitimate
# fact, not a failure; anything else is a hard failure.
# ---------------------------------------------------------------------------
get_remote_sha(){
  if REMOTE_SHA=$(gh api "repos/$ARCHIVE/contents/$ARCHIVE_PATH" --jq '.sha' 2>"$WORK/get.err"); then
    return 0
  elif http_status_is 404 "$WORK/get.err"; then
    REMOTE_SHA=""
    return 0
  else
    die "GET repos/$ARCHIVE/contents/$ARCHIVE_PATH failed: $(cat "$WORK/get.err")"
  fi
}
get_remote_sha

# LOCAL_SHA_CURRENT is the hash of --log exactly as it stands right now
# (before any append). This is what the skip decision compares against:
# a run with nothing appended since the previous successful save hashes to
# exactly the sha that save's PUT carried (see the append-before-hash note
# below), so this comparison is what makes repeat no-op saves skip.
LOCAL_SHA_CURRENT=$(git hash-object "$LOG_PATH") || die "git hash-object failed on $LOG_PATH"

if [ -n "$REMOTE_SHA" ] && [ "$REMOTE_SHA" = "$LOCAL_SHA_CURRENT" ]; then
  echo "save-log: $ARCHIVE:$ARCHIVE_PATH unchanged, skipped"
  exit 0
fi

if [ "$DRY_RUN" -eq 1 ]; then
  if [ -z "$REMOTE_SHA" ]; then
    echo "save-log: DRY RUN — would create $ARCHIVE:$ARCHIVE_PATH (first save)"
  else
    echo "save-log: DRY RUN — would update $ARCHIVE:$ARCHIVE_PATH (sha $REMOTE_SHA -> $LOCAL_SHA_CURRENT)"
  fi
  exit 0
fi

# ---------------------------------------------------------------------------
# Append-before-hash: build the confirmation line and a WORKING COPY of the
# log carrying it, then hash/encode/PUT that working copy — never the
# pre-append file. That working copy is a snapshot of --log plus exactly
# one note line, and it is what makes the unchanged check above reachable
# on every later save (see the header). It is NEVER written back over
# --log; the write-back below appends the same single note line to the live
# file instead. The --log file stays completely untouched until the PUT is
# confirmed to have succeeded, so a failed PUT never leaves a local file
# claiming an archive that did not happen.
#
# needs_nl reports true when --log is non-empty and does not already end
# in a newline — the realistic source is a writer killed mid-append. Both
# the working copy below and the live write-back near the end of the
# script check this immediately before they append, so a note line is
# never concatenated onto an unterminated previous line in either place.
# ---------------------------------------------------------------------------
needs_nl(){ # needs_nl <file>
  [ -s "$1" ] && [ -n "$(tail -c1 "$1")" ]
}

NOTE_LINE=$(jq -nc --arg ts "$(date -u +%FT%TZ)" --arg claim "$CLAIM" \
  --arg text "log archived to $ARCHIVE:$ARCHIVE_PATH" \
  '{ts:$ts, event:"note", claim:(if $claim=="" then null else $claim end), text:$text}')
CANDIDATE="$WORK/candidate.jsonl"
B64_FILE="$WORK/content.b64"

# build_candidate (re)builds the working copy from --log AS IT STANDS
# RIGHT NOW, then re-checks the 1 MB bound and re-derives its hash and
# base64 encoding. Called once before the first PUT attempt, and again
# before the 409/422 retry below — the retry therefore always sends a
# fresh snapshot (picking up anything a concurrent writer appended between
# the first attempt and the retry), never the pre-conflict body.
build_candidate(){
  local prefix=""
  needs_nl "$LOG_PATH" && prefix=$'\n'
  { cat "$LOG_PATH"; [ -z "$prefix" ] || printf '%s' "$prefix"; printf '%s\n' "$NOTE_LINE"; } > "$CANDIDATE"

  # Re-apply the 1 MB bound to the CANDIDATE, not just to the input: a
  # file at exactly MAX_BYTES passes the pre-flight check above and then
  # grows past the limit once the note line is added, and it is the
  # candidate that the API actually has to accept. Still before the PUT,
  # so nothing is written and no oversized body is ever sent.
  local candidate_bytes
  candidate_bytes=$(wc -c < "$CANDIDATE" | tr -d ' ')
  [ "$candidate_bytes" -le "$MAX_BYTES" ] \
    || die "$LOG_PATH plus this run's note line is $candidate_bytes bytes, over the Contents API's 1 MB ($MAX_BYTES byte) limit — cannot archive as a single PUT"

  LOCAL_SHA=$(git hash-object "$CANDIDATE") || die "git hash-object failed on the working copy"

  # The base64 payload goes to a FILE, never into a shell word: Linux caps
  # a single argv element at MAX_ARG_STRLEN (131072 bytes) irrespective of
  # ARG_MAX, so an `-f content=<base64>` spelling would fail with
  # `Argument list too long` at roughly a 93 KB log — a tenth of the 1 MB
  # bound this script advertises and enforces. `jq --rawfile` reads it
  # straight off disk into the JSON body, and `gh api --input` reads that
  # body off disk too, so the payload never crosses an exec boundary as an
  # argument.
  if ! base64 -w0 "$CANDIDATE" > "$B64_FILE" 2>/dev/null; then
    base64 "$CANDIDATE" | tr -d '\n' > "$B64_FILE"
  fi
}
build_candidate

# Issue #737: when session_id came from --session-id rather than the log's
# own session-start event, the commit message says so — provenance belongs
# in the artifact itself, not a sidecar note someone has to maintain.
if [ "$SESSION_ID_FROM_FLAG" -eq 1 ]; then
  MESSAGE="archive session log for $REPO ($SESSION_ID, session_id supplied via --session-id)"
else
  MESSAGE="archive session log for $REPO ($SESSION_ID)"
fi

BODY_FILE="$WORK/body.json"
build_body(){ # build_body <sha-or-empty> -> $BODY_FILE
  local sha="$1"
  if [ -n "$sha" ]; then
    jq -n --arg message "$MESSAGE" --rawfile content "$B64_FILE" --arg sha "$sha" \
      '{message:$message, content:($content|rtrimstr("\n")), sha:$sha}' > "$BODY_FILE"
  else
    jq -n --arg message "$MESSAGE" --rawfile content "$B64_FILE" \
      '{message:$message, content:($content|rtrimstr("\n"))}' > "$BODY_FILE"
  fi
}

put_once(){ # put_once <sha-or-empty>
  build_body "$1" || die "could not build the PUT request body"
  gh api -X PUT "repos/$ARCHIVE/contents/$ARCHIVE_PATH" --input "$BODY_FILE" \
    >"$WORK/put.out" 2>"$WORK/put.err"
}

if ! put_once "$REMOTE_SHA"; then
  if http_status_is 409 "$WORK/put.err" || http_status_is 422 "$WORK/put.err"; then
    # Conflict: someone else moved the remote sha since our GET. Re-GET,
    # re-snapshot the candidate from --log as it now stands (not the
    # pre-conflict snapshot — see build_candidate above), and retry
    # exactly once with the fresh sha — never loop, never guess.
    get_remote_sha
    build_candidate
    put_once "$REMOTE_SHA" \
      || die "PUT repos/$ARCHIVE/contents/$ARCHIVE_PATH failed after a 409/422 retry: $(cat "$WORK/put.err")"
  else
    die "PUT repos/$ARCHIVE/contents/$ARCHIVE_PATH failed: $(cat "$WORK/put.err")"
  fi
fi

# PUT succeeded — the archived blob (LOCAL_SHA) is now authoritative.
# Write-back is a single APPEND of the same note line the blob carries, not
# a copy of the working copy: --log is append-only (formats/session-log.md)
# and the heartbeat cron is live at this point in the close checklist, so
# copying the pre-PUT snapshot back would silently destroy anything that
# raced in during the network call. Appending is byte-for-byte identical to
# the copy when nothing raced, and loses nothing when something did — the
# local file is then a superset of the blob, the next run's unchanged check
# fails, and the two converge after exactly one extra PUT. needs_nl is
# re-checked here (--log may have changed since build_candidate ran) so the
# live file never gets its note line concatenated onto an unterminated
# previous line either. The read (needs_nl) happens BEFORE the group that
# opens LOG_PATH for append, so the same file is never read and written in
# one pipeline.
WRITE_BACK_PREFIX=""
needs_nl "$LOG_PATH" && WRITE_BACK_PREFIX=$'\n'
{
  [ -z "$WRITE_BACK_PREFIX" ] || printf '%s' "$WRITE_BACK_PREFIX"
  printf '%s\n' "$NOTE_LINE"
} >> "$LOG_PATH" \
  || die "archive PUT SUCCEEDED (sha $LOCAL_SHA) but the confirmation note could not be appended to the local log at $LOG_PATH — re-run to reconcile"

COMMIT_URL=$(jq -r '.commit.html_url // empty' "$WORK/put.out")
echo "save-log: archived to $ARCHIVE:$ARCHIVE_PATH"
echo "save-log: commit $COMMIT_URL"
