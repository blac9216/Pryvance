#!/usr/bin/env bash
# test_preflight.sh — fixture-driven regression test for preflight.sh.
# Follows the mock-`gh` harness conventions from plan-work/tests/test_history.sh
# and test_timeline_classifier.sh (see tests/README.md in this directory): a
# mocked `gh` binary on PATH serves fixture JSON from a private mktemp scratch
# dir, refuses any non-GET verb, and no real network call is ever reachable.
# Pinned to LANG=C / LC_ALL=C — nothing in preflight.sh's own parsing is
# locale-sensitive, and pinning here catches a future regression that would
# make it so.
#
# Covers:
#  - round count spans two comment-list pages (the endpoint the motivating
#    incident undercounted by using `gh pr view --json comments` instead of
#    paginated `gh api`): one round from a heading-only comment on page 1,
#    two more rounds from footer-bearing comments on page 2 -> rounds=3. A
#    truncated (page-1-only) read would report rounds=1.
#  - a footer-bearing verdict (round 2, "changes_requested") and a
#    heading-only verdict (round 1, no footer at all) are both counted, and
#    (#658) so is a footer-bearing "approved" verdict (round 3) — every
#    terminal verdict slug is a round that happened, "approved" included.
#  - the latest verdict (the same "Approved" footer comment, newest by
#    created_at) is ALSO reported as `.latest_verdict`, distinctly from the
#    round count that now includes it too — the two facts are independent,
#    not mutually exclusive.
#  - a Test Evidence manifest with a matching SHA-256 and one with a
#    mismatching SHA-256, one heading-only and one footer-bearing.
#  - a draft PR is reported as such, in both JSON and --markdown.
#  - the mock's write-verb refusal: `gh api -X POST`, `gh api --method PATCH`,
#    `gh api -XPOST` (glued), and a non-`api` subcommand (`gh pr merge`,
#    `gh issue edit`) — all four are refused, not just the first spelling
#    (#305).
#  - --log appends one event line to a file; without --log the same line
#    goes to stderr instead of being silently dropped, and never to stdout.
#  - evidence-footer digest-key aliasing (#357): the pre-#269 `log_sha256`
#    alias and the #269-canonical `sha256` key are each isolated in a
#    footer-only fixture (no visible bullet to rescue a broken alias read),
#    plus a footer-present-but-no-digest-key fixture that must fall back to
#    the visible "Log SHA-256" bullet.
#  - the digest-fallback case above reports `source:"footer+field"`, not
#    plain `footer` (#362), truthfully flagging the mixed provenance; the
#    pre-#269 `log_sha256`-only fixture also asserts plain `source:"footer"`
#    (#374, #362's verification was previously half-ungated).
#  - the pre-#269 `exit_code` alias resolves to the same `exit` a canonical
#    footer would (#363), isolated (no other source for the value).
#  - `field()`'s bullet-field fallback matches a bold-bulleted, colon- or
#    em-dash-separated manifest (`- **Raw log** — …`), not only the
#    unbolded canonical-template form (#363).
#  - an empty-string canonical alias key (`""`) does not shadow a populated
#    legacy alias, for all four alias pairs at once (#374).
#  - `field()` ignores a decoy bullet quoted inside a fenced code block and
#    resolves the real bullet that follows the fence (#374).
#  - a `grep -P` failure (as opposed to a legitimate no-match) is reported
#    distinctly rather than silently read as an absent field (#374).
#  - a Test Evidence manifest naming a nonexistent Raw log path reports
#    `log_exists:false` / `sha256_match:false`, and `--markdown` renders its
#    "MISSING on disk" branch (#305).
#  - `--markdown`'s CI-state line is anchored to `- CI: <state>` rather than
#    a bare substring match that would also pass on a per-check `success`
#    text (#305).
#  - the `## PR Review` and `## Test Evidence — round N` heading fallbacks
#    accept an em dash, en dash, `--`, or a plain hyphen as the separator,
#    each contributing to the round count / manifest set (#306).
#  - `field()`'s trailing-strip runs the whitespace strip before the
#    backtick strip, so a bullet value whose closing backtick is immediately
#    followed by trailing whitespace still resolves with the backtick
#    removed (#431).
#  - a `<!-- evidence {...} -->` footer that is present but fails to parse
#    as JSON is reported as `source:"malformed_footer"` (and rendered
#    "footer unparseable" / "MALFORMED FOOTER" in --markdown), never
#    misdescribed as an ordinary "no path stated" manifest (#438).
#  - the `## PR Review` and `## Test Evidence — round N` heading matchers
#    ignore a decoy heading quoted inside a fenced code block, for every
#    accepted separator spelling at once, the same fence-blind-proof
#    treatment field() already got (#448).
#  - a heading (or footer) verdict slug outside the closed set the review
#    templates define is reported under `unrecognized_verdicts`, never
#    recorded as a verdict — it neither displaces a genuine `latest_verdict`
#    nor counts toward `.rounds` (#448).
#  - CI falls back to the legacy commit-status API when check-runs is empty:
#    a fixture with data on the legacy endpoint reports `ci.source:
#    "legacy_status"` and a state derived from it; a fixture with both
#    endpoints genuinely empty reports `ci.source:"none"` (#299).
#  - `--markdown` renders a line naming every `unrecognized_verdicts` entry
#    (slug + URL) when the list is non-empty, and renders nothing extra when
#    it is empty — the byte-for-byte-unchanged property on a real PR with no
#    off-template verdict (#493).
#  - a malformed evidence footer with readable dashed/bolded bullets still
#    resolves the bullet fields (`source:"malformed_footer+field"`) instead
#    of discarding them, and `--markdown` renders the real path and hash
#    verdict alongside the "MALFORMED FOOTER" note; a footer that parses but
#    names no `log`/`log_path` key renders "footer parsed, no log key
#    stated", distinct from "no path stated" for a manifest with no footer
#    and no Raw log bullet at all (#494).
#  - the verdict-slug set `is_known_verdict()` accepts is derived at test
#    time from the pr-review templates' own `## PR Review — <Verdict>`
#    headings, not restated by hand — dropping any one of the four slugs
#    (approved/changes_requested/decomposition_requested/escalated) from the
#    script surfaces as a nonzero `unrecognized_verdicts` count here (#495).
#  - an `escalated` round counts toward `.rounds` the same as
#    `changes_requested`/`decomposition_requested`/`approved`, and a
#    `## Review Findings — relay` comment on the same (reopened) PR does
#    NOT — isolated fixture: round 1 changes_requested, round 2 escalated,
#    then a relay comment -> rounds=2, latest_verdict=escalated, and the
#    relay comment is neither counted nor reported as unrecognized (#658).
#  - `strip_fences()` treats a nested fence (a shorter/different-character
#    marker inside a longer one), a `~~~` fence, and a fence indented by up
#    to 3 spaces the same as a plain 3-backtick fence — a decoy inside any of
#    them stays hidden; an unterminated fence's content is flushed raw
#    instead of discarded, so a real heading following it is never
#    permanently hidden (#496).
#  - a Test Evidence manifest naming a Raw log that exists on disk but is
#    unreadable (chmod 000) reports `log_readable:false` and renders
#    "UNREADABLE (permission denied)" in --markdown, distinct from both
#    "MISSING on disk" and "HASH MISMATCH" (#601).
#  - two Test Evidence manifests for the same round, the older naming a Raw
#    log whose content has since changed (the legitimate re-run-and-re-post
#    case): the older reports `superseded:true` and renders "superseded
#    (hash not checked)" instead of a hash verdict, while the newest keeps
#    its real hash verdict — including a genuine HASH MISMATCH when the
#    newest manifest's own stated hash is wrong (#585). Supersession is
#    scoped to (round, log_path) together, not round alone: two same-round
#    manifests naming DIFFERENT, untouched logs never supersede each other,
#    including the exact pre-relay/post-relay log pair this repo's own relay
#    round produces every time (#585 round-1 relay finding F2).
#  - the #496 2-space-indented-fence fixture's decoy heading is itself
#    un-indented (not indented like the fence), so the assertion can only
#    hold if strip_fences() actually treated the indented backtick lines as
#    a fence open/close — an indented decoy would be invisible to the
#    heading regex's anchoring regardless of fence handling, which is the
#    residual #600 closes. A 3-space case (the exact CommonMark boundary)
#    pins the same from the other side (#600).
#  - #716: an off-vocabulary VERDICT FOOTER (`"verdict":"changes"`, PR #696's
#    exact defect, not `"changes_requested"`) sitting between two genuine
#    footer-bearing verdicts reports `rounds:2` (correct — neither eaten nor
#    inflated), `rounds_is_lower_bound:true`, the RAW value `"changes"`
#    preserved in `unrecognized_verdicts` (not silently coerced), and a loud
#    `WARNING` line on stderr naming the comment's URL and that raw value —
#    regardless of `--markdown`; `--markdown` additionally qualifies "Review
#    rounds so far" with `(LOWER BOUND — …)` and renders the WARNING line
#    itself. The #448/#493 fence fixture above is reused to assert the same
#    two facts for a HEADING-sourced (not footer-sourced) unrecognized entry,
#    so both sources are covered.
#  - #703: PR class (`class`/`round_cap` in JSON, "PR class:" line in
#    --markdown) is computed from the PR's changed file paths, mechanically:
#    all-`.md` -> doc-only (cap 2), all-under-a-test-root -> test-only (cap
#    2), anything mixed or otherwise uncertain -> executable-code (cap 3),
#    `LICENSE.md` -> executable-code despite the `.md` extension (basename
#    exclusion takes precedence), and zero changed paths -> executable-code
#    (never vacuously doc-only/test-only). The same fixture set is re-run
#    with only its files.json swapped to prove class is recomputed fresh
#    every call rather than cached — the exact shape a relay produces on a
#    real PR (same PR, same review thread, a later call sees a different
#    diff) — in both the widening and narrowing directions.
set -euo pipefail
export LANG=C LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFLIGHT_SH="$SCRIPT_DIR/../scripts/preflight.sh"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/preflight-test.XXXXXX")"
cleanup(){ rm -rf "$WORK"; }
trap cleanup EXIT

FIXTURES="$WORK/fixtures"
BIN="$WORK/bin"
OUT="$WORK/out"
LOGS="$WORK/logs"
mkdir -p "$FIXTURES" "$BIN" "$OUT" "$LOGS"

REPO="test-org/test-repo"
PR=42
HEAD_SHA="deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"

fail=0
report(){ echo "FAIL: $*" >&2; fail=1; }

# ---------------------------------------------------------------------------
# Real log files the manifests point at, so the hash checks are genuine.
# ---------------------------------------------------------------------------
printf 'pass 1\n' > "$LOGS/round0.log"
MATCH_SHA=$(sha256sum "$LOGS/round0.log" | awk '{print $1}')
printf 'fail 1\n' > "$LOGS/round1.log"
MISMATCH_SHA="0000000000000000000000000000000000000000000000000000000000000000"
printf 'pass 2\n' > "$LOGS/round2.log"
ROUND2_SHA=$(sha256sum "$LOGS/round2.log" | awk '{print $1}')
printf 'pass 3\n' > "$LOGS/round3.log"
ROUND3_SHA=$(sha256sum "$LOGS/round3.log" | awk '{print $1}')
printf 'pass 4\n' > "$LOGS/round4.log"
ROUND4_SHA=$(sha256sum "$LOGS/round4.log" | awk '{print $1}')
printf 'pass 5\n' > "$LOGS/round5.log"
ROUND5_SHA=$(sha256sum "$LOGS/round5.log" | awk '{print $1}')
printf 'pass 6\n' > "$LOGS/round6.log"
ROUND6_SHA=$(sha256sum "$LOGS/round6.log" | awk '{print $1}')
printf 'pass 8\n' > "$LOGS/round8.log"
ROUND8_SHA=$(sha256sum "$LOGS/round8.log" | awk '{print $1}')
printf 'pass 10\n' > "$LOGS/round10.log"
ROUND10_SHA=$(sha256sum "$LOGS/round10.log" | awk '{print $1}')
printf 'pass 12\n' > "$LOGS/round12.log"
ROUND12_SHA=$(sha256sum "$LOGS/round12.log" | awk '{print $1}')
# round 7's manifest deliberately names a path under $LOGS that is never
# created — it exercises the "Raw log names a nonexistent path" case (#305).
ROUND7_MISSING_LOG="$LOGS/round7-missing.log"

# ---------------------------------------------------------------------------
# PR detail: open, draft.
# ---------------------------------------------------------------------------
cat > "$FIXTURES/pull.json" <<JSON
{"state":"open","draft":true,"mergeable":true,"head":{"sha":"$HEAD_SHA"}}
JSON

# ---------------------------------------------------------------------------
# Comments, page 1: a heading-only "Changes Requested" verdict (round 1, no
# footer at all -> exercises the mandatory regex fallback) and a heading-only
# Test Evidence manifest (round 0) whose hash matches its real log file.
# ---------------------------------------------------------------------------
cat > "$FIXTURES/comments_page1.json" <<JSON
[
  {
    "body": "## PR Review — Changes Requested\n\n| # | Severity | Note |\n|---|---|---|\n| 1 | blocker | fix X |\n",
    "created_at": "2026-01-01T00:00:00Z",
    "html_url": "https://example.invalid/pr/42#issuecomment-1"
  },
  {
    "body": "## Test Evidence — round 0\n- Command: \`echo hi\`\n- Env: bash 5\n- Head SHA: \`$HEAD_SHA\`\n- Exit code: 0\n- Results: 1 passed\n- Log SHA-256: \`$MATCH_SHA\`\n- Raw log: \`$LOGS/round0.log\`\n",
    "created_at": "2026-01-01T01:00:00Z",
    "html_url": "https://example.invalid/pr/42#issuecomment-2"
  }
]
JSON

# ---------------------------------------------------------------------------
# Comments, page 2: a footer-bearing "Changes Requested" verdict (round 2), a
# footer-bearing Test Evidence manifest (round 1) whose stated hash does NOT
# match its real log file, and the newest comment overall — a footer-bearing
# "Approved" verdict, itself round 3 (#658: "approved" is a terminal verdict
# and counts). A read that stops at page 1 would report rounds=1 instead of
# 3 and would never see the Approved verdict at all.
# ---------------------------------------------------------------------------
cat > "$FIXTURES/comments_page2.json" <<JSON
[
  {
    "body": "<!-- review {\"v\":1,\"round\":2,\"verdict\":\"changes_requested\",\"findings\":[1]} -->\n## PR Review — Changes Requested\n\nstill broken",
    "created_at": "2026-01-02T00:00:00Z",
    "html_url": "https://example.invalid/pr/42#issuecomment-3"
  },
  {
    "body": "<!-- evidence {\"issue\":42,\"round\":1,\"head\":\"$HEAD_SHA\",\"exit\":1,\"log\":\"$LOGS/round1.log\",\"sha256\":\"$MISMATCH_SHA\",\"command\":\"echo bye\"} -->\n## Test Evidence — round 1\n- Command: \`echo bye\`\n- Exit code: 1\n",
    "created_at": "2026-01-02T01:00:00Z",
    "html_url": "https://example.invalid/pr/42#issuecomment-4"
  },
  {
    "body": "<!-- review {\"v\":1,\"round\":3,\"verdict\":\"approved\",\"findings\":[]} -->\n## PR Review — Approved\n\nLGTM",
    "created_at": "2026-01-03T00:00:00Z",
    "html_url": "https://example.invalid/pr/42#issuecomment-5"
  }
]
JSON

# ---------------------------------------------------------------------------
# Comments, page 3: three more Test Evidence manifests exercising the
# pre-#269/canonical digest-key aliasing (issue #357) — none carry a review
# verdict, so they do not affect the round-2 count above.
#  - round 2: footer-ONLY, no visible "Log SHA-256"/"Raw log" bullet at all,
#    using the pre-#269 spelling `log_sha256`/`head_sha`/`log_path` only; the
#    hash matches -> must report sha256_match:true, not a spurious HASH
#    MISMATCH from the key-name difference alone. Deliberately footer-only
#    (round-1 review finding 1): a fixture that also carried the visible
#    bullet would let the bullet-field fallback rescue a broken alias read
#    and the assertion would pass either way.
#  - round 3: footer-ONLY, same reasoning, using the #269 canonical
#    `sha256`/`head`/`log` -> sha256_match:true (the "both spellings
#    accepted, one absent" case from the other side, isolated the same way).
#  - round 4: footer is present but carries neither digest-key spelling at
#    all, and (unlike rounds 2/3) DOES carry the visible "Log SHA-256"
#    bullet -> must fall back to it, same regex the heading-only path
#    already uses, and report source:"footer+field" (#362) — not plain
#    "footer" — since the digest's provenance is now mixed.
# ---------------------------------------------------------------------------
cat > "$FIXTURES/comments_page3.json" <<JSON
[
  {
    "body": "<!-- evidence {\"issue\":42,\"round\":2,\"head_sha\":\"$HEAD_SHA\",\"exit\":0,\"log_path\":\"$LOGS/round2.log\",\"log_sha256\":\"$ROUND2_SHA\",\"command\":\"echo r2\"} -->\n## Test Evidence — round 2\n\nFooter-only fixture, no visible bullet fields (pre-#269 log_sha256 alias).\n",
    "created_at": "2026-01-04T00:00:00Z",
    "html_url": "https://example.invalid/pr/42#issuecomment-6"
  },
  {
    "body": "<!-- evidence {\"issue\":42,\"round\":3,\"head\":\"$HEAD_SHA\",\"exit\":0,\"log\":\"$LOGS/round3.log\",\"sha256\":\"$ROUND3_SHA\",\"command\":\"echo r3\"} -->\n## Test Evidence — round 3\n\nFooter-only fixture, no visible bullet fields (#269 canonical sha256).\n",
    "created_at": "2026-01-04T01:00:00Z",
    "html_url": "https://example.invalid/pr/42#issuecomment-7"
  },
  {
    "body": "<!-- evidence {\"issue\":42,\"round\":4,\"head\":\"$HEAD_SHA\",\"exit\":0,\"log\":\"$LOGS/round4.log\",\"command\":\"echo r4\"} -->\n## Test Evidence — round 4\n- Command: \`echo r4\`\n- Exit code: 0\n- Log SHA-256: \`$ROUND4_SHA\`\n- Raw log: \`$LOGS/round4.log\`\n",
    "created_at": "2026-01-04T02:00:00Z",
    "html_url": "https://example.invalid/pr/42#issuecomment-8"
  }
]
JSON

# ---------------------------------------------------------------------------
# Comments, page 4: two more Test Evidence manifests, exercising #363's two
# residuals directly.
#  - round 5: footer-only, `exit_code` alias with no canonical `exit` key at
#    all — nothing else could rescue the value, so this isolates the alias
#    the same way rounds 2/3 above isolate the digest-key aliases.
#  - round 6: heading-only (no footer at all), every bullet field bolded and
#    the Raw log / Head SHA fields using the em-dash separator real drifted
#    manifests use (`- **Name** — value`) instead of the canonical unbolded
#    colon form — must resolve head/exit/command/log/sha exactly as the
#    unbolded heading-only fixture (round 0) does, and report hash OK.
#  - round 7 (#305): footer-bearing, names a Raw log path that is never
#    created on disk — must report `log_exists:false`, `sha256_match:false`,
#    and `--markdown` must render its "MISSING on disk" branch.
#  - round 8 (#374): footer carries an empty string for every canonical
#    alias key (`head`/`exit`/`log`/`sha256`) alongside a populated legacy
#    alias (`head_sha`/`exit_code`/`log_path`/`log_sha256`) — none of the
#    four may be shadowed by the empty canonical value.
#  - round 9 (#374): heading-only, a decoy "Log SHA-256" bullet sits inside
#    a fenced code block ahead of the real bolded bullet — `field()` must
#    ignore the fence and resolve the real, later bullet.
#  - round 10 (#431): heading-only, the "Log SHA-256" bullet's closing
#    backtick is immediately followed by trailing whitespace before the
#    newline (`` `<sha>`  `` — two trailing spaces) — `field()`'s trailing
#    strip must still remove the backtick, not leave it stuck on the value
#    (a sed chain that strips whitespace only after trying to strip the
#    backtick would leave it there, since the backtick is not yet the last
#    character on the line while the whitespace remains).
#  - round 11 (#438): a footer that is present but fails to parse as JSON —
#    its `command` value embeds a literal backslash-backtick sequence,
#    exactly PR #424's real footer, an invalid JSON escape — accompanied by
#    the `## Test Evidence — round 11` heading. Must report
#    `source:"malformed_footer"`, never a plain "no path stated" derived from
#    the (nonexistent) heading-only bullet fields.
#  - round 12 (#494 part 1): same malformed-footer shape as round 11, but
#    this comment ALSO carries a real dashed bullet list with a readable
#    path and a matching hash. Must report `source:"malformed_footer+field"`
#    and recover the real path/hash instead of discarding them, and render
#    the path, hash verdict, and the malformed-footer note together.
#  - round 13 (#494 part 2): a footer that parses as valid JSON but names
#    neither `log` nor `log_path` at all, with no visible bullet fields in
#    the body either — must report `source:"footer"` with `log_path:null`,
#    rendered "footer parsed, no log key stated", distinct from round 14.
#  - round 14 (#494 part 2 baseline): heading-only, no footer, no bullet
#    fields at all — the genuine "no path was ever stated" case, must still
#    render plain "no path stated", unaffected by round 13's distinct text.
# ---------------------------------------------------------------------------
cat > "$FIXTURES/comments_page4.json" <<JSON
[
  {
    "body": "<!-- evidence {\"issue\":42,\"round\":5,\"head\":\"$HEAD_SHA\",\"exit_code\":9,\"log\":\"$LOGS/round5.log\",\"sha256\":\"$ROUND5_SHA\",\"command\":\"echo r5\"} -->\n## Test Evidence — round 5\n\nFooter-only fixture, no visible bullet fields.\n",
    "created_at": "2026-01-05T00:00:00Z",
    "html_url": "https://example.invalid/pr/42#issuecomment-9"
  },
  {
    "body": "## Test Evidence — round 6\n- **Command**: \`echo r6\`\n- **Head SHA**: \`$HEAD_SHA\`\n- **Exit code**: 0\n- **Results**: 1 passed\n- **Log SHA-256**: \`$ROUND6_SHA\`\n- **Raw log** — \`$LOGS/round6.log\`\n",
    "created_at": "2026-01-05T01:00:00Z",
    "html_url": "https://example.invalid/pr/42#issuecomment-10"
  },
  {
    "body": "<!-- evidence {\"issue\":42,\"round\":7,\"head\":\"$HEAD_SHA\",\"exit\":0,\"log\":\"$ROUND7_MISSING_LOG\",\"sha256\":\"$MATCH_SHA\",\"command\":\"echo r7\"} -->\n## Test Evidence — round 7\n\nFooter names a Raw log path that is never created on disk (#305).\n",
    "created_at": "2026-01-05T02:00:00Z",
    "html_url": "https://example.invalid/pr/42#issuecomment-11"
  },
  {
    "body": "<!-- evidence {\"issue\":42,\"round\":8,\"head\":\"\",\"head_sha\":\"$HEAD_SHA\",\"exit\":\"\",\"exit_code\":0,\"log\":\"\",\"log_path\":\"$LOGS/round8.log\",\"sha256\":\"\",\"log_sha256\":\"$ROUND8_SHA\",\"command\":\"echo r8\"} -->\n## Test Evidence — round 8\n\nFooter carries an empty-string canonical value for every alias pair, with a\npopulated legacy alias behind each one (#374) — none may be shadowed.\n",
    "created_at": "2026-01-05T03:00:00Z",
    "html_url": "https://example.invalid/pr/42#issuecomment-12"
  },
  {
    "body": "## Test Evidence — round 9\n\n\`\`\`\n- **Log SHA-256**: \`decoydecoydecoydecoydecoydecoydecoydecoydecoydecoydecoydecoyde\`\n\`\`\`\n- **Command**: \`echo r9\`\n- **Head SHA**: \`$HEAD_SHA\`\n- **Exit code**: 0\n- **Log SHA-256**: \`$ROUND6_SHA\`\n- **Raw log** — \`$LOGS/round6.log\`\n",
    "created_at": "2026-01-05T04:00:00Z",
    "html_url": "https://example.invalid/pr/42#issuecomment-13"
  },
  {
    "body": "## Test Evidence — round 10\n- Command: \`echo r10\`\n- Head SHA: \`$HEAD_SHA\`\n- Exit code: 0\n- Log SHA-256: \`$ROUND10_SHA\`  \n- Raw log: \`$LOGS/round10.log\`\n",
    "created_at": "2026-01-05T05:00:00Z",
    "html_url": "https://example.invalid/pr/42#issuecomment-14"
  },
  {
    "body": "<!-- evidence {\"issue\":42,\"round\":11,\"command\":\"grep \\\\\`Verified\\\\\` orchestration.md\"} -->\n## Test Evidence — round 11\n\nFooter is present but fails jq's JSON parse (#438): its command value embeds\na literal backslash-backtick sequence, an invalid JSON escape, exactly PR\n#424's real footer.\n",
    "created_at": "2026-01-05T06:00:00Z",
    "html_url": "https://example.invalid/pr/42#issuecomment-15"
  },
  {
    "body": "<!-- evidence {\"issue\":42,\"round\":12,\"command\":\"grep \\\\\`Verified\\\\\` orchestration.md\"} -->\n## Test Evidence — round 12\n- Command: \`echo r12\`\n- Head SHA: \`$HEAD_SHA\`\n- Exit code: 0\n- Log SHA-256: \`$ROUND12_SHA\`\n- Raw log: \`$LOGS/round12.log\`\n",
    "created_at": "2026-01-05T07:00:00Z",
    "html_url": "https://example.invalid/pr/42#issuecomment-16"
  },
  {
    "body": "<!-- evidence {\"issue\":42,\"round\":13,\"head\":\"$HEAD_SHA\",\"exit\":0,\"command\":\"echo r13\"} -->\n## Test Evidence — round 13\n\nFooter parses fine but names no log/log_path key at all, and no visible\nbullet fields either (#494 part 2) — must render distinctly from a manifest\nthat never had a footer.\n",
    "created_at": "2026-01-05T08:00:00Z",
    "html_url": "https://example.invalid/pr/42#issuecomment-17"
  },
  {
    "body": "## Test Evidence — round 14\n\nHeading-only, no footer and no bullet fields at all (#494 part 2 baseline) —\nmust still render plain \"no path stated\".\n",
    "created_at": "2026-01-05T09:00:00Z",
    "html_url": "https://example.invalid/pr/42#issuecomment-18"
  }
]
JSON

# ---------------------------------------------------------------------------
# CI check runs for the head SHA: both completed and successful.
# ---------------------------------------------------------------------------
cat > "$FIXTURES/checks.json" <<JSON
{"check_runs":[{"name":"lint","status":"completed","conclusion":"success"},{"name":"test","status":"completed","conclusion":"success"}]}
JSON

# ---------------------------------------------------------------------------
# Mock gh: routes by endpoint shape, applying the real --jq expression (via
# the real jq binary) against fixture JSON, exactly as `gh api --jq` would
# against live API output (raw-ish output: `jq -c -r`, matching test_history.sh's
# documented reasoning). Comments are the one endpoint that actually pages:
# with --paginate, both page fixtures are applied and concatenated in order;
# without it, only page 1 is served (would undercount rounds, kept here so a
# future regression that drops --paginate from preflight.sh is caught).
# Refuses any non-GET verb rather than silently serving a read fixture.
# ---------------------------------------------------------------------------
cat > "$BIN/gh" <<'MOCKGH'
#!/usr/bin/env bash
set -euo pipefail
# Hermeticity tripwire (#568, following tests/README.md's convention and
# #477): every invocation is logged before anything else happens, and one
# arriving without MOCK_GH_FIXTURES -- the env only run_preflight() and the
# harness's own helper calls set -- is recorded as UNMOCKED-CONTEXT instead
# of silently reaching the real, authenticated gh.
: "${MOCK_GH_CALL_LOG:?MOCK_GH_CALL_LOG must be set}"
printf 'CALL gh %s\n' "$*" >> "$MOCK_GH_CALL_LOG"
if [ -z "${MOCK_GH_FIXTURES:-}" ]; then
  printf 'UNMOCKED-CONTEXT gh %s\n' "$*" >> "$MOCK_GH_CALL_LOG"
  echo "mock gh: invoked with no MOCK_GH_FIXTURES -- unmocked call context" >&2
  exit 1
fi
if [ "${1:-}" = "repo" ] && [ "${2:-}" = "view" ]; then
  echo "mock gh: repo view should not be called when --repo is passed" >&2
  exit 1
fi
if [ "${1:-}" != "api" ]; then
  echo "mock gh: unsupported command: $*" >&2
  exit 1
fi
shift
endpoint=""
jq_expr=""
method="GET"
paginate=0
while [ $# -gt 0 ]; do
  case "$1" in
    --paginate) paginate=1; shift ;;
    --jq) jq_expr="$2"; shift 2 ;;
    -X|--method) method="$2"; shift 2 ;;
    -X?*) method="${1#-X}"; shift ;;
    --method=*) method="${1#--method=}"; shift ;;
    *) endpoint="$1"; shift ;;
  esac
done
if [ "$method" != "GET" ]; then
  echo "mock gh: refusing non-GET method ($method) on $endpoint" >&2
  exit 1
fi
apply(){ # apply <fixture-file>
  if [ -n "$jq_expr" ]; then
    jq -c -r "$jq_expr" "$1"
  else
    cat "$1"
  fi
}
case "$endpoint" in
  repos/*/pulls/*/files\?per_page=100)
    # #703: PR class is computed from this endpoint. Fixture sets that do not
    # care about class (almost all of them) omit files.json entirely and get
    # a harmless single-file default here rather than having to state one;
    # the class-change fixture below supplies its own real files.json.
    if [ -f "$MOCK_GH_FIXTURES/files.json" ]; then
      apply "$MOCK_GH_FIXTURES/files.json"
    else
      printf '%s\n' "irrelevant.txt"
    fi
    ;;
  repos/*/pulls/*)
    apply "$MOCK_GH_FIXTURES/pull.json" ;;
  repos/*/issues/*/comments\?per_page=100)
    apply "$MOCK_GH_FIXTURES/comments_page1.json"
    if [ "$paginate" -eq 1 ]; then
      apply "$MOCK_GH_FIXTURES/comments_page2.json"
      apply "$MOCK_GH_FIXTURES/comments_page3.json"
      apply "$MOCK_GH_FIXTURES/comments_page4.json"
    fi
    ;;
  repos/*/commits/*/check-runs\?per_page=100)
    apply "$MOCK_GH_FIXTURES/checks.json" ;;
  repos/*/commits/*/status)
    # #299: only reached by preflight.sh when check-runs is empty; every
    # fixture set that exercises the normal (non-empty check-runs) path has
    # no status.json at all, so an unexpected call here fails loudly instead
    # of silently serving a fixture that shouldn't be read.
    if [ -f "$MOCK_GH_FIXTURES/status.json" ]; then
      apply "$MOCK_GH_FIXTURES/status.json"
    else
      echo "mock gh: no status.json fixture for repos/*/commits/*/status" >&2
      exit 1
    fi
    ;;
  *)
    echo "mock gh: unknown endpoint: $endpoint" >&2
    exit 1 ;;
esac
MOCKGH
chmod +x "$BIN/gh"

export MOCK_GH_CALL_LOG="$OUT/gh-calls.log"
: > "$MOCK_GH_CALL_LOG"

# ---------------------------------------------------------------------------
# The mock refuses a write verb outright — sanity-check the harness itself,
# same class of gap test_history.sh closes for its own mock. Every write-verb
# spelling the mock implements is asserted, not just the first (#305): `-X
# POST`, `--method PATCH`, glued `-XPOST`, and a non-`api` subcommand.
# ---------------------------------------------------------------------------
check_write_refused(){ # check_write_refused <label> <args...>
  local label="$1"; shift
  set +e
  MOCK_GH_FIXTURES="$FIXTURES" PATH="$BIN:$PATH" \
    gh "$@" >/dev/null 2>"$OUT/writeverb.stderr.log"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || report "mock gh ($label): expected exit non-zero, got 0"
}

check_write_refused "-X POST" api -X POST "repos/$REPO/issues/$PR/comments"
grep -qi 'refusing non-GET' "$OUT/writeverb.stderr.log" \
  || report "mock gh (-X POST): expected a 'refusing non-GET' message, got: $(cat "$OUT/writeverb.stderr.log")"

check_write_refused "--method PATCH" api --method PATCH "repos/$REPO/issues/$PR/comments"
grep -qi 'refusing non-GET' "$OUT/writeverb.stderr.log" \
  || report "mock gh (--method PATCH): expected a 'refusing non-GET' message, got: $(cat "$OUT/writeverb.stderr.log")"

check_write_refused "-XPOST" api -XPOST "repos/$REPO/issues/$PR/comments"
grep -qi 'refusing non-GET' "$OUT/writeverb.stderr.log" \
  || report "mock gh (-XPOST): expected a 'refusing non-GET' message, got: $(cat "$OUT/writeverb.stderr.log")"

check_write_refused "pr merge" pr merge "$PR"
grep -qi 'unsupported command' "$OUT/writeverb.stderr.log" \
  || report "mock gh (pr merge): expected an 'unsupported command' message, got: $(cat "$OUT/writeverb.stderr.log")"

check_write_refused "issue edit" issue edit "$PR"
grep -qi 'unsupported command' "$OUT/writeverb.stderr.log" \
  || report "mock gh (issue edit): expected an 'unsupported command' message, got: $(cat "$OUT/writeverb.stderr.log")"

# ---------------------------------------------------------------------------
# Run preflight.sh under test.
# ---------------------------------------------------------------------------
run_preflight(){
  local rc=0
  set +e
  MOCK_GH_FIXTURES="$FIXTURES" PATH="$BIN:$PATH" \
    "$PREFLIGHT_SH" "$@" > "$OUT/run.stdout.log" 2> "$OUT/run.stderr.log"
  rc=$?
  set -e
  if [ "$rc" -ne 0 ]; then
    echo "run_preflight $*: exited $rc" >&2
    echo "--- stdout ---" >&2; cat "$OUT/run.stdout.log" >&2 || true
    echo "--- stderr ---" >&2; cat "$OUT/run.stderr.log" >&2 || true
    report "preflight.sh exited $rc for args: $*"
  fi
}

run_preflight "$PR" --repo "$REPO"
JSON_OUT="$OUT/run.stdout.log"

if jq -e . "$JSON_OUT" >/dev/null 2>&1; then
  check_eq(){ # field jq_path expected
    local field="$1" path="$2" want="$3" got
    got=$(jq -r "$path" "$JSON_OUT")
    [ "$got" = "$want" ] || report "$field: expected $want, got $got"
  }
  check_eq repo        .repo         "$REPO"
  check_eq pr           .pr           "$PR"
  check_eq head_sha      .head_sha      "$HEAD_SHA"
  check_eq state          .state          "open"
  check_eq draft           .draft           "true"
  check_eq rounds           .rounds           "3"
  check_eq rounds_is_lower_bound .rounds_is_lower_bound "false"
  check_eq latest_verdict    .latest_verdict.verdict "approved"
  check_eq latest_verdict_src .latest_verdict.source  "footer"
  check_eq ci_state             .ci.state               "success"

  n_evidence=$(jq '.evidence|length' "$JSON_OUT")
  [ "$n_evidence" = "15" ] || report "evidence: expected 15 manifests, got $n_evidence"

  ok_round=$(jq -c '.evidence[]|select(.round==0)' "$JSON_OUT")
  [ -n "$ok_round" ] || report "evidence: no round-0 manifest found"
  if [ -n "$ok_round" ]; then
    [ "$(jq -r '.sha256_match' <<<"$ok_round")" = "true" ] || report "evidence round 0: expected sha256_match=true, got: $ok_round"
    [ "$(jq -r '.log_exists' <<<"$ok_round")" = "true" ] || report "evidence round 0: expected log_exists=true"
    [ "$(jq -r '.source' <<<"$ok_round")" = "heading" ] || report "evidence round 0: expected source=heading"
  fi

  bad_round=$(jq -c '.evidence[]|select(.round==1)' "$JSON_OUT")
  [ -n "$bad_round" ] || report "evidence: no round-1 manifest found"
  if [ -n "$bad_round" ]; then
    [ "$(jq -r '.sha256_match' <<<"$bad_round")" = "false" ] || report "evidence round 1: expected sha256_match=false, got: $bad_round"
    [ "$(jq -r '.log_exists' <<<"$bad_round")" = "true" ] || report "evidence round 1: expected log_exists=true (mismatched hash, not a missing file)"
    [ "$(jq -r '.source' <<<"$bad_round")" = "footer" ] || report "evidence round 1: expected source=footer"
    [ "$(jq -r '.issue' <<<"$bad_round")" = "$PR" ] || report "evidence round 1: expected issue=$PR from the footer"
    [ "$(jq -r '.exit' <<<"$bad_round")" = "1" ] || report "evidence round 1: expected exit=1 from the footer"
  fi

  # -------------------------------------------------------------------------
  # Digest-key alias coverage (issue #357): pre-#269 spelling (round 2),
  # #269 canonical spelling (round 3), and neither spelling present at all
  # (round 4, must fall back to the "Log SHA-256" bullet-field regex). None
  # of these may report a spurious HASH MISMATCH.
  # -------------------------------------------------------------------------
  alias_round=$(jq -c '.evidence[]|select(.round==2)' "$JSON_OUT")
  [ -n "$alias_round" ] || report "evidence: no round-2 manifest found"
  if [ -n "$alias_round" ]; then
    [ "$(jq -r '.sha256_match' <<<"$alias_round")" = "true" ] || report "evidence round 2 (log_sha256 alias): expected sha256_match=true, got: $alias_round"
    [ "$(jq -r '.head' <<<"$alias_round")" = "$HEAD_SHA" ] || report "evidence round 2: expected head resolved from head_sha alias"
    [ "$(jq -r '.log_path' <<<"$alias_round")" = "$LOGS/round2.log" ] || report "evidence round 2: expected log_path resolved from log_path alias"
    [ "$(jq -r '.source' <<<"$alias_round")" = "footer" ] || report "evidence round 2 (#374, #362 verification): expected source=footer for a footer-supplied log_sha256 alias, got: $alias_round"
  fi

  canon_round=$(jq -c '.evidence[]|select(.round==3)' "$JSON_OUT")
  [ -n "$canon_round" ] || report "evidence: no round-3 manifest found"
  if [ -n "$canon_round" ]; then
    [ "$(jq -r '.sha256_match' <<<"$canon_round")" = "true" ] || report "evidence round 3 (canonical sha256): expected sha256_match=true, got: $canon_round"
  fi

  fallback_round=$(jq -c '.evidence[]|select(.round==4)' "$JSON_OUT")
  [ -n "$fallback_round" ] || report "evidence: no round-4 manifest found"
  if [ -n "$fallback_round" ]; then
    [ "$(jq -r '.sha256_match' <<<"$fallback_round")" = "true" ] || report "evidence round 4 (no digest key in footer, regex fallback): expected sha256_match=true, got: $fallback_round"
    [ "$(jq -r '.stated_sha256' <<<"$fallback_round")" = "$ROUND4_SHA" ] || report "evidence round 4: expected stated_sha256 recovered via regex fallback"
    [ "$(jq -r '.source' <<<"$fallback_round")" = "footer+field" ] || report "evidence round 4 (#362): expected source=footer+field for a digest recovered from the bullet, got: $fallback_round"
  fi

  # -------------------------------------------------------------------------
  # #363 residual 1: `exit_code` alias, isolated (footer-only, no other
  # source for the value).
  # -------------------------------------------------------------------------
  exitc_round=$(jq -c '.evidence[]|select(.round==5)' "$JSON_OUT")
  [ -n "$exitc_round" ] || report "evidence: no round-5 manifest found"
  if [ -n "$exitc_round" ]; then
    [ "$(jq -r '.exit' <<<"$exitc_round")" = "9" ] || report "evidence round 5 (#363 exit_code alias): expected exit=9, got: $exitc_round"
    [ "$(jq -r '.sha256_match' <<<"$exitc_round")" = "true" ] || report "evidence round 5: expected sha256_match=true, got: $exitc_round"
  fi

  # -------------------------------------------------------------------------
  # #363 residual 2: `field()` on a bold-bulleted, em-dash-separated
  # heading-only manifest must resolve exactly as the unbolded round-0
  # fixture does — head/exit/command/log/sha and hash OK, not "no path
  # stated".
  # -------------------------------------------------------------------------
  bold_round=$(jq -c '.evidence[]|select(.round==6)' "$JSON_OUT")
  [ -n "$bold_round" ] || report "evidence: no round-6 manifest found"
  if [ -n "$bold_round" ]; then
    [ "$(jq -r '.head' <<<"$bold_round")" = "$HEAD_SHA" ] || report "evidence round 6 (#363 bold bullets): expected head resolved, got: $bold_round"
    [ "$(jq -r '.exit' <<<"$bold_round")" = "0" ] || report "evidence round 6: expected exit=0 resolved from bold bullet"
    [ "$(jq -r '.log_path' <<<"$bold_round")" = "$LOGS/round6.log" ] || report "evidence round 6: expected log_path resolved from the em-dash-separated bold bullet"
    [ "$(jq -r '.log_exists' <<<"$bold_round")" = "true" ] || report "evidence round 6: expected log_exists=true"
    [ "$(jq -r '.sha256_match' <<<"$bold_round")" = "true" ] || report "evidence round 6: expected sha256_match=true, got: $bold_round"
    [ "$(jq -r '.source' <<<"$bold_round")" = "heading" ] || report "evidence round 6: expected source=heading"
  fi

  # -------------------------------------------------------------------------
  # #305: a manifest whose Raw log names a path that is never created on
  # disk — log_exists/sha256_match must both be false, never a crash.
  # -------------------------------------------------------------------------
  missing_round=$(jq -c '.evidence[]|select(.round==7)' "$JSON_OUT")
  [ -n "$missing_round" ] || report "evidence: no round-7 manifest found"
  if [ -n "$missing_round" ]; then
    [ "$(jq -r '.log_exists' <<<"$missing_round")" = "false" ] || report "evidence round 7 (#305 missing log): expected log_exists=false, got: $missing_round"
    [ "$(jq -r '.sha256_match' <<<"$missing_round")" = "false" ] || report "evidence round 7: expected sha256_match=false, got: $missing_round"
    [ "$(jq -r '.actual_sha256' <<<"$missing_round")" = "null" ] || report "evidence round 7: expected actual_sha256=null, got: $missing_round"
  fi

  # -------------------------------------------------------------------------
  # #374: an empty-string canonical alias value must not shadow a populated
  # legacy alias, for all four alias pairs at once.
  # -------------------------------------------------------------------------
  emptyalias_round=$(jq -c '.evidence[]|select(.round==8)' "$JSON_OUT")
  [ -n "$emptyalias_round" ] || report "evidence: no round-8 manifest found"
  if [ -n "$emptyalias_round" ]; then
    [ "$(jq -r '.head' <<<"$emptyalias_round")" = "$HEAD_SHA" ] || report "evidence round 8 (#374 empty-string head): expected head resolved from head_sha, got: $emptyalias_round"
    [ "$(jq -r '.exit' <<<"$emptyalias_round")" = "0" ] || report "evidence round 8 (#374 empty-string exit): expected exit=0 resolved from exit_code, got: $emptyalias_round"
    [ "$(jq -r '.log_path' <<<"$emptyalias_round")" = "$LOGS/round8.log" ] || report "evidence round 8 (#374 empty-string log): expected log_path resolved from log_path, got: $emptyalias_round"
    [ "$(jq -r '.sha256_match' <<<"$emptyalias_round")" = "true" ] || report "evidence round 8 (#374 empty-string sha256): expected sha256_match=true resolved from log_sha256, got: $emptyalias_round"
  fi

  # -------------------------------------------------------------------------
  # #374: a decoy "Log SHA-256" bullet inside a fenced code block must not
  # win over the real, later bullet.
  # -------------------------------------------------------------------------
  fenced_round=$(jq -c '.evidence[]|select(.round==9)' "$JSON_OUT")
  [ -n "$fenced_round" ] || report "evidence: no round-9 manifest found"
  if [ -n "$fenced_round" ]; then
    [ "$(jq -r '.stated_sha256' <<<"$fenced_round")" = "$ROUND6_SHA" ] || report "evidence round 9 (#374 fenced decoy): expected the real bullet's sha256, got: $fenced_round"
    [ "$(jq -r '.sha256_match' <<<"$fenced_round")" = "true" ] || report "evidence round 9: expected sha256_match=true, got: $fenced_round"
  fi

  # -------------------------------------------------------------------------
  # #431: a "Log SHA-256" bullet whose closing backtick is immediately
  # followed by trailing whitespace before the newline must still resolve
  # with the backtick stripped — a sed chain that tries the backtick strip
  # before the whitespace strip would leave it stuck on the value, and the
  # hash comparison (which never tolerates a trailing backtick) would then
  # report a spurious HASH MISMATCH instead of hash OK.
  # -------------------------------------------------------------------------
  backtick_round=$(jq -c '.evidence[]|select(.round==10)' "$JSON_OUT")
  [ -n "$backtick_round" ] || report "evidence: no round-10 manifest found"
  if [ -n "$backtick_round" ]; then
    [ "$(jq -r '.stated_sha256' <<<"$backtick_round")" = "$ROUND10_SHA" ] || report "evidence round 10 (#431 trailing backtick+whitespace): expected stated_sha256=$ROUND10_SHA with no trailing backtick, got: $backtick_round"
    [ "$(jq -r '.sha256_match' <<<"$backtick_round")" = "true" ] || report "evidence round 10 (#431): expected sha256_match=true, got: $backtick_round"
  fi

  # -------------------------------------------------------------------------
  # #438: a footer that is present but fails to parse as JSON must be
  # reported as such (source=malformed_footer), never misdescribed via the
  # heading-only fallback as an ordinary "no path stated" manifest — no
  # bullet fields exist in this fixture's body at all, so a script that fell
  # through to the heading path would resolve every field to empty and look
  # indistinguishable from a manifest that genuinely never named a path.
  # -------------------------------------------------------------------------
  malformed_round=$(jq -c '.evidence[]|select(.round==11)' "$JSON_OUT")
  [ -n "$malformed_round" ] || report "evidence: no round-11 manifest found"
  if [ -n "$malformed_round" ]; then
    [ "$(jq -r '.source' <<<"$malformed_round")" = "malformed_footer" ] || report "evidence round 11 (#438 malformed footer): expected source=malformed_footer, got: $malformed_round"
  fi

  # -------------------------------------------------------------------------
  # #494 part 1: a malformed footer that ALSO has readable dashed bullets
  # must recover them (source=malformed_footer+field) rather than discard
  # them — the real path and hash verdict survive despite the footer fault.
  # -------------------------------------------------------------------------
  malformed_field_round=$(jq -c '.evidence[]|select(.round==12)' "$JSON_OUT")
  [ -n "$malformed_field_round" ] || report "evidence: no round-12 manifest found"
  if [ -n "$malformed_field_round" ]; then
    [ "$(jq -r '.source' <<<"$malformed_field_round")" = "malformed_footer+field" ] || report "evidence round 12 (#494 malformed+field): expected source=malformed_footer+field, got: $malformed_field_round"
    [ "$(jq -r '.log_path' <<<"$malformed_field_round")" = "$LOGS/round12.log" ] || report "evidence round 12: expected log_path recovered from the dashed bullet, got: $malformed_field_round"
    [ "$(jq -r '.sha256_match' <<<"$malformed_field_round")" = "true" ] || report "evidence round 12: expected sha256_match=true, got: $malformed_field_round"
  fi

  # -------------------------------------------------------------------------
  # #494 part 2: a footer that parses fine but names no log/log_path key at
  # all, with no bullet field to rescue it either, must still report
  # source=footer (not heading) with log_path:null — the fact that a footer
  # existed and was readable is preserved, distinguishing this from round 14
  # below in --markdown.
  # -------------------------------------------------------------------------
  nolog_round=$(jq -c '.evidence[]|select(.round==13)' "$JSON_OUT")
  [ -n "$nolog_round" ] || report "evidence: no round-13 manifest found"
  if [ -n "$nolog_round" ]; then
    [ "$(jq -r '.source' <<<"$nolog_round")" = "footer" ] || report "evidence round 13 (#494 footer, no log key): expected source=footer, got: $nolog_round"
    [ "$(jq -r '.log_path' <<<"$nolog_round")" = "null" ] || report "evidence round 13: expected log_path=null, got: $nolog_round"
  fi

  # -------------------------------------------------------------------------
  # #494 part 2 baseline: no footer at all and no bullet field either — the
  # genuine "no path stated" case, source=heading, unaffected by round 13's
  # distinct rendering.
  # -------------------------------------------------------------------------
  noheading_round=$(jq -c '.evidence[]|select(.round==14)' "$JSON_OUT")
  [ -n "$noheading_round" ] || report "evidence: no round-14 manifest found"
  if [ -n "$noheading_round" ]; then
    [ "$(jq -r '.source' <<<"$noheading_round")" = "heading" ] || report "evidence round 14 (#494 baseline): expected source=heading, got: $noheading_round"
    [ "$(jq -r '.log_path' <<<"$noheading_round")" = "null" ] || report "evidence round 14: expected log_path=null, got: $noheading_round"
  fi
else
  report "preflight.sh stdout is not valid JSON: $(cat "$JSON_OUT")"
fi

# ---------------------------------------------------------------------------
# --markdown: head SHA, round count, each manifest's path + hash verdict, CI
# state, and the draft marker must all appear in the rendered block.
# ---------------------------------------------------------------------------
run_preflight "$PR" --repo "$REPO" --markdown
MD_OUT="$OUT/run.stdout.log"
grep -qF "$HEAD_SHA" "$MD_OUT" || report "--markdown: missing head SHA"
grep -qE 'rounds so far: 3' "$MD_OUT" || report "--markdown: missing round count 3"
grep -qF "(draft)" "$MD_OUT" || report "--markdown: missing draft marker"
grep -qF "$LOGS/round0.log" "$MD_OUT" || report "--markdown: missing round-0 manifest path"
grep -qF "$LOGS/round1.log" "$MD_OUT" || report "--markdown: missing round-1 manifest path"
grep -qF "hash OK" "$MD_OUT" || report "--markdown: missing round-0 'hash OK' verdict"
grep -qF "HASH MISMATCH" "$MD_OUT" || report "--markdown: missing round-1 'HASH MISMATCH' verdict"
# #305: anchored to the "- CI: " line itself, not a bare substring — a
# per-check "lint=success" text elsewhere in the block would also satisfy a
# plain `grep -qF "success"`, even if `.ci.state` were wrong.
grep -qE '^- CI: success' "$MD_OUT" || report "--markdown: missing anchored CI state line"
# #305: round 7's manifest names a Raw log path that is never created on
# disk — its rendered verdict must be "MISSING on disk", not a hash verdict.
grep -qF "$ROUND7_MISSING_LOG" "$MD_OUT" || report "--markdown: missing round-7 manifest path"
grep -qF "MISSING on disk" "$MD_OUT" || report "--markdown: missing round-7 'MISSING on disk' verdict"
# #438: round 11's manifest has a footer that fails to parse — the rendered
# line must say so ("footer unparseable", the round) rather than the
# "no path stated" text that would otherwise describe an author omission.
grep -qF "footer unparseable" "$MD_OUT" || report "--markdown: missing round-11 'footer unparseable' text"
grep -qE 'round 11.*MALFORMED FOOTER \(round 11\)' "$MD_OUT" || report "--markdown: missing round-11 MALFORMED FOOTER line naming the round"
# finding 1 (PR #530 round 1): the backticked slot must be source-aware, not
# computed independently of the explanation that follows it — a
# malformed_footer record with a null log_path must never render the phrase
# "no path stated" anywhere on its line (that phrase means the manifest
# genuinely never named a path, a different fault from a footer the script
# could not read at all). An absence assertion, not just the pre-existing
# presence check on "footer unparseable" above.
round11_line=$(grep '^  - round 11:' "$MD_OUT" || true)
[ -n "$round11_line" ] || report "--markdown: no rendered line for round 11, got: $(cat "$MD_OUT")"
case "$round11_line" in
  *"no path stated"*) report "--markdown: round-11 (malformed footer) line must NEVER render 'no path stated', got: $round11_line" ;;
  *) ;;
esac
# The contrast case: round 13's footer parsed fine but named no log key at
# all — a genuinely path-less manifest, where "no path stated" (in the
# backticked slot, unchanged by finding 1's fix) is the correct and expected
# text, alongside the distinct "footer parsed, no log key stated" explanation
# asserted below.
round13_line=$(grep '^  - round 13:' "$MD_OUT" || true)
[ -n "$round13_line" ] || report "--markdown: no rendered line for round 13, got: $(cat "$MD_OUT")"
case "$round13_line" in
  *"no path stated"*) ;;
  *) report "--markdown: round-13 (well-formed footer, no log key) line missing 'no path stated' in the backticked slot, got: $round13_line" ;;
esac
# #493: this fixture set carries no off-template verdict heading at all, so
# unrecognized_verdicts is empty — the rendered block must say nothing about
# it (byte-for-byte-unchanged property on a real PR with no unrecognised
# verdict).
! grep -q "Unrecognised verdict headings" "$MD_OUT" \
  || report "--markdown: unexpected 'Unrecognised verdict headings' line when unrecognized_verdicts is empty"
# #494 part 1: round 12's footer is malformed but its dashed bullets are
# readable — the rendered line must carry the real path AND a hash verdict
# AND the malformed-footer note together, not "footer unparseable" alone.
# Checked as three independent facts on the round-12 line rather than one
# fragile combined regex: the real path, "hash OK", and the MALFORMED FOOTER
# note naming the round.
round12_line=$(grep '^  - round 12:' "$MD_OUT" || true)
[ -n "$round12_line" ] || report "--markdown: no rendered line for round 12, got: $(cat "$MD_OUT")"
case "$round12_line" in
  *"$LOGS/round12.log"*) ;;
  *) report "--markdown: round-12 line missing the real path, got: $round12_line" ;;
esac
case "$round12_line" in
  *"hash OK"*) ;;
  *) report "--markdown: round-12 line missing 'hash OK', got: $round12_line" ;;
esac
case "$round12_line" in
  *"MALFORMED FOOTER (round 12)"*) ;;
  *) report "--markdown: round-12 line missing the MALFORMED FOOTER note, got: $round12_line" ;;
esac
# #494 part 2: round 13's footer parsed but named no log key — distinct text
# from round 14's genuine "no path stated" (no footer, no bullet at all).
grep -qE 'round 13.*footer parsed, no log key stated' "$MD_OUT" \
  || report "--markdown: missing round-13 'footer parsed, no log key stated' text"
grep -qE 'round 14.*no path stated' "$MD_OUT" \
  || report "--markdown: missing round-14 'no path stated' text"

# ---------------------------------------------------------------------------
# --log: appends one event line to the given file; without --log the same
# line goes to stderr, and stdout stays pure JSON either way.
# ---------------------------------------------------------------------------
LOG_FILE="$WORK/session.jsonl"
run_preflight "$PR" --repo "$REPO" --log "$LOG_FILE"
[ -s "$LOG_FILE" ] || report "--log: expected a non-empty log file"
n_lines=$(wc -l < "$LOG_FILE")
[ "$n_lines" = "1" ] || report "--log: expected exactly 1 line, got $n_lines"
if [ -s "$LOG_FILE" ]; then
  logrec=$(tail -1 "$LOG_FILE")
  [ "$(jq -r .event <<<"$logrec")" = "preflight" ] || report "--log: expected event=preflight, got: $logrec"
  [ "$(jq -r .pr <<<"$logrec")" = "$PR" ] || report "--log: expected pr=$PR, got: $logrec"
  [ "$(jq -r .rounds <<<"$logrec")" = "3" ] || report "--log: expected rounds=3, got: $logrec"
fi
jq -e . "$OUT/run.stdout.log" >/dev/null 2>&1 || report "--log: stdout must still be pure JSON"

run_preflight "$PR" --repo "$REPO"
grep -q '"event":"preflight"' "$OUT/run.stderr.log" \
  || report "no --log: expected the event line on stderr, got: $(cat "$OUT/run.stderr.log")"
! grep -q '"event":"preflight"' "$OUT/run.stdout.log" \
  || report "no --log: the event line must never land on stdout"

# ---------------------------------------------------------------------------
# #306: the `## PR Review` and `## Test Evidence — round N` heading fallbacks
# accept an em dash, en dash, `--`, and a plain hyphen as the separator, each
# contributing to the round count / manifest set. An isolated single-page
# fixture set, independent of the main run above, so the main run's rounds=2
# expectation is untouched.
# ---------------------------------------------------------------------------
FIXTURES_SEP="$WORK/fixtures_sep"
mkdir -p "$FIXTURES_SEP"
cp "$FIXTURES/pull.json" "$FIXTURES/checks.json" "$FIXTURES_SEP/"
cat > "$FIXTURES_SEP/comments_page1.json" <<JSON
[
  {"body": "## PR Review — Changes Requested\n\nem dash", "created_at": "2026-02-01T00:00:00Z", "html_url": "https://example.invalid/pr/42#sep-1"},
  {"body": "## PR Review – Changes Requested\n\nen dash", "created_at": "2026-02-01T01:00:00Z", "html_url": "https://example.invalid/pr/42#sep-2"},
  {"body": "## PR Review -- Changes Requested\n\ndouble hyphen", "created_at": "2026-02-01T02:00:00Z", "html_url": "https://example.invalid/pr/42#sep-3"},
  {"body": "## PR Review - Changes Requested\n\nplain hyphen", "created_at": "2026-02-01T03:00:00Z", "html_url": "https://example.invalid/pr/42#sep-4"},
  {"body": "## Test Evidence - round 10\n\nplain-hyphen manifest heading, no bullet fields.", "created_at": "2026-02-01T04:00:00Z", "html_url": "https://example.invalid/pr/42#sep-5"}
]
JSON
echo '[]' > "$FIXTURES_SEP/comments_page2.json"
echo '[]' > "$FIXTURES_SEP/comments_page3.json"
echo '[]' > "$FIXTURES_SEP/comments_page4.json"

set +e
MOCK_GH_FIXTURES="$FIXTURES_SEP" PATH="$BIN:$PATH" \
  "$PREFLIGHT_SH" "$PR" --repo "$REPO" > "$OUT/sep.stdout.log" 2> "$OUT/sep.stderr.log"
rc=$?
set -e
[ "$rc" -eq 0 ] || report "#306 separators: expected exit 0, got $rc: $(cat "$OUT/sep.stderr.log")"
if jq -e . "$OUT/sep.stdout.log" >/dev/null 2>&1; then
  sep_rounds=$(jq -r '.rounds' "$OUT/sep.stdout.log")
  [ "$sep_rounds" = "4" ] || report "#306 separators: expected rounds=4 (one per separator), got $sep_rounds"
  sep_manifest=$(jq -c '.evidence[]|select(.round==10)' "$OUT/sep.stdout.log")
  [ -n "$sep_manifest" ] \
    || report "#306 separators: expected a round-10 manifest from the plain-hyphen Test Evidence heading"
else
  report "#306 separators: stdout is not valid JSON: $(cat "$OUT/sep.stdout.log")"
fi

# ---------------------------------------------------------------------------
# #448: the `## PR Review` and `## Test Evidence — round N` heading matchers
# honour fenced code blocks the same way field() does, and only a slug from
# the closed verdict set counts as a verdict. An isolated single-page fixture
# set, independent of the main run above.
#  - comment 1 (earliest): a genuine em-dash "Changes Requested" verdict —
#    the one real round in this fixture set.
#  - comment 2 (later): an off-template "## PR Review - notes" heading — its
#    slug ("notes") is not in the closed set, so it must not displace comment
#    1 as `.latest_verdict`, and must not count toward `.rounds`.
#  - comment 3 (latest of all): a single comment whose ONLY `## PR Review`
#    heading, for all four accepted separator spellings, and whose only
#    `## Test Evidence — round 99` heading, sit inside a fenced code block —
#    a fence-blind matcher would count all four as additional rounds and
#    would also produce a round-99 manifest; a fence-aware one must not.
# ---------------------------------------------------------------------------
FIXTURES_FENCE="$WORK/fixtures_fence"
mkdir -p "$FIXTURES_FENCE"
cp "$FIXTURES/pull.json" "$FIXTURES/checks.json" "$FIXTURES_FENCE/"
cat > "$FIXTURES_FENCE/comments_page1.json" <<JSON
[
  {"body": "## PR Review — Changes Requested\n\ngenuine verdict, round 1", "created_at": "2026-03-01T00:00:00Z", "html_url": "https://example.invalid/pr/42#fence-1"},
  {"body": "## PR Review - notes\n\noff-template, not a recognised verdict slug", "created_at": "2026-03-01T01:00:00Z", "html_url": "https://example.invalid/pr/42#fence-2"},
  {"body": "Quoting the template for reference:\n\n\`\`\`\n## PR Review — Changes Requested\n## PR Review – Changes Requested\n## PR Review -- Changes Requested\n## PR Review - Changes Requested\n## Test Evidence — round 99\n\`\`\`\n\nNo heading or manifest outside the fence.", "created_at": "2026-03-01T02:00:00Z", "html_url": "https://example.invalid/pr/42#fence-3"}
]
JSON
echo '[]' > "$FIXTURES_FENCE/comments_page2.json"
echo '[]' > "$FIXTURES_FENCE/comments_page3.json"
echo '[]' > "$FIXTURES_FENCE/comments_page4.json"

set +e
MOCK_GH_FIXTURES="$FIXTURES_FENCE" PATH="$BIN:$PATH" \
  "$PREFLIGHT_SH" "$PR" --repo "$REPO" > "$OUT/fence.stdout.log" 2> "$OUT/fence.stderr.log"
rc=$?
set -e
[ "$rc" -eq 0 ] || report "#448 fence-blind: expected exit 0, got $rc: $(cat "$OUT/fence.stderr.log")"
if jq -e . "$OUT/fence.stdout.log" >/dev/null 2>&1; then
  fence_rounds=$(jq -r '.rounds' "$OUT/fence.stdout.log")
  [ "$fence_rounds" = "1" ] || report "#448 fence-blind: expected rounds=1 (fenced decoys and the off-template heading must not count), got $fence_rounds"
  fence_latest=$(jq -r '.latest_verdict.verdict' "$OUT/fence.stdout.log")
  [ "$fence_latest" = "changes_requested" ] || report "#448: expected latest_verdict=changes_requested (the genuine comment), got $fence_latest — the off-template '## PR Review - notes' comment must not displace it despite being newer"
  fence_manifest=$(jq -c '.evidence[]|select(.round==99)' "$OUT/fence.stdout.log")
  [ -z "$fence_manifest" ] || report "#448: expected no round-99 manifest (its only heading sits inside a fenced code block), got: $fence_manifest"
  n_unrecognized=$(jq '.unrecognized_verdicts|length' "$OUT/fence.stdout.log")
  [ "$n_unrecognized" = "1" ] || report "#448: expected exactly 1 unrecognized_verdicts entry (the 'notes' heading), got $n_unrecognized"
  unrec_slug=$(jq -r '.unrecognized_verdicts[0].verdict_slug' "$OUT/fence.stdout.log")
  [ "$unrec_slug" = "notes" ] || report "#448: expected unrecognized_verdicts[0].verdict_slug=notes, got $unrec_slug"
else
  report "#448 fence-blind: stdout is not valid JSON: $(cat "$OUT/fence.stdout.log")"
fi

# ---------------------------------------------------------------------------
# #493 (format updated by #716): --markdown must name the one unrecognised
# verdict heading (the off-template "notes" comment above) by its exact
# value, its slug, and comment URL — the fact that a JSON consumer already
# saw via unrecognized_verdicts must also reach a reviewer reading only the
# rendered block. #716: the same run also asserts the loud WARNING wording
# and the "Review rounds so far" line's LOWER BOUND qualifier — this fixture
# has exactly one real round (the round-1 "Changes Requested" heading) and
# one off-template heading ("notes"), so rounds=1 but is still qualified,
# proving the qualifier fires on ANY unrecognized entry, not just one framed
# as a footer.
# ---------------------------------------------------------------------------
set +e
MOCK_GH_FIXTURES="$FIXTURES_FENCE" PATH="$BIN:$PATH" \
  "$PREFLIGHT_SH" "$PR" --repo "$REPO" --markdown > "$OUT/fence.md.stdout.log" 2> "$OUT/fence.md.stderr.log"
rc=$?
set -e
[ "$rc" -eq 0 ] || report "#493 fence markdown: expected exit 0, got $rc: $(cat "$OUT/fence.md.stderr.log")"
grep -qE '^- WARNING: unrecognized verdict \(round count above is a LOWER BOUND, not counted\): 1 \("notes" \(slug notes\) — https://example\.invalid/pr/42#fence-2\)$' "$OUT/fence.md.stdout.log" \
  || report "#493/#716: --markdown missing the loud unrecognised-verdict WARNING line, got: $(cat "$OUT/fence.md.stdout.log")"
grep -qE '^- Review rounds so far: 1 \(LOWER BOUND — see WARNING below, not the true round total\) · latest verdict: changes_requested \(heading\)$' "$OUT/fence.md.stdout.log" \
  || report "#716: --markdown 'Review rounds so far' line missing its LOWER BOUND qualifier, got: $(cat "$OUT/fence.md.stdout.log")"
grep -qE 'WARNING: unrecognized verdict "notes" \(from heading\) on https://example\.invalid/pr/42#fence-2 — Review rounds so far \(1\) is a LOWER BOUND' "$OUT/fence.md.stderr.log" \
  || report "#716: stderr missing the loud per-comment WARNING line (must fire regardless of --markdown), got: $(cat "$OUT/fence.md.stderr.log")"
fence_lower_bound=$(jq -r '.rounds_is_lower_bound' "$OUT/fence.stdout.log")
[ "$fence_lower_bound" = "true" ] || report "#716: expected rounds_is_lower_bound=true on the JSON already captured for #448 above, got $fence_lower_bound"

# ---------------------------------------------------------------------------
# #374: a `grep -P` failure while reading a bullet field must be reported
# distinctly (script exits non-zero with a `grep -P failed` message) rather
# than silently read as an absent field. A poisoned `grep` shim intercepts
# only field()'s own `-oP` pattern shape (`^- (\*\*)?<name>...`) and forces
# it to fail; every other grep invocation in preflight.sh (heading regexes,
# `-qi`, etc.) is passed straight through to the real binary untouched.
# ---------------------------------------------------------------------------
REAL_GREP="$(command -v grep)"
BIN_GREPFAIL="$WORK/bin_grepfail"
mkdir -p "$BIN_GREPFAIL"
cp "$BIN/gh" "$BIN_GREPFAIL/gh"
cat > "$BIN_GREPFAIL/grep" <<SHIM
#!/usr/bin/env bash
set -euo pipefail
for a in "\$@"; do
  case "\$a" in
    *'^- (\\*\\*)?'*) echo "grep: simulated -P failure (test)" >&2; exit 2 ;;
  esac
done
exec "$REAL_GREP" "\$@"
SHIM
chmod +x "$BIN_GREPFAIL/grep"

set +e
MOCK_GH_FIXTURES="$FIXTURES" PATH="$BIN_GREPFAIL:$PATH" \
  "$PREFLIGHT_SH" "$PR" --repo "$REPO" > "$OUT/grepfail.stdout.log" 2> "$OUT/grepfail.stderr.log"
rc=$?
set -e
[ "$rc" -eq 1 ] || report "#374 grep -P failure: expected exit 1, got $rc"
[ ! -s "$OUT/grepfail.stdout.log" ] \
  || report "#374 grep -P failure: expected zero bytes on stdout, got: $(cat "$OUT/grepfail.stdout.log")"
grep -qi 'grep -P failed' "$OUT/grepfail.stderr.log" \
  || report "#374 grep -P failure: expected a 'grep -P failed' message, got: $(cat "$OUT/grepfail.stderr.log")"

# ---------------------------------------------------------------------------
# #495: the verdict-slug set is pinned by deriving the EXPECTED set from the
# pr-review templates themselves — never restated by hand here — so a
# template rename fails this test the same way dropping a slug from
# preflight.sh's is_known_verdict() does. slugify() reimplements preflight.sh's
# own slug() mapping (lowercase, non-letters -> underscore) so the derived
# set matches what the script itself would compute from the same heading
# text. One comment per template heading, ascending timestamps; the
# assertion that matters is unrecognized_verdicts staying empty — dropping
# ANY one of the four slugs from is_known_verdict() reclassifies that single
# comment into unrecognized_verdicts and this fails, regardless of which
# slug was dropped or where it falls in round/latest-verdict terms.
# ---------------------------------------------------------------------------
PR_REVIEW_TEMPLATES_DIR="$SCRIPT_DIR/../../github-pr-review/references/templates"
slugify(){ printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z]+/_/g; s/^_+//; s/_+$//'; }

# finding 3 (PR #530 round 1): the extraction below must accept every
# separator preflight.sh's own verdict-heading regex accepts — em dash, en
# dash, `--`, or a plain hyphen (issue #306) — not just the em-dash form. An
# em-dash-only extraction silently `continue`s past a template whose heading
# separator drifts to one of the other three forms preflight.sh still
# accepts, shrinking EXPECTED_SLUGS without failing anything. The pattern is
# a single constant, asserted to be byte-identical to the one preflight.sh
# itself uses (grep -qF below), so the two can never drift apart silently.
VERDICT_HEADING_SEP_RE='^## PR Review (?:—|–|--|-)\s*\K.*'
grep -qF "$VERDICT_HEADING_SEP_RE" "$PREFLIGHT_SH" \
  || report "#495/finding 3: preflight.sh's verdict-heading regex no longer matches the test's constant \"$VERDICT_HEADING_SEP_RE\" — update both together"

EXPECTED_SLUGS=()
slug_entries='[]'
hour=0
TEMPLATE_COUNT=0
for f in "$PR_REVIEW_TEMPLATES_DIR"/*.md; do
  TEMPLATE_COUNT=$((TEMPLATE_COUNT+1))
  heading=$(grep -m1 -oP "$VERDICT_HEADING_SEP_RE" "$f" | sed -E 's/[[:space:]]+$//' || true)
  [ -n "$heading" ] \
    || report "#495/finding 3: template $f yielded no heading via the shared separator regex — a silently continue'd template must fail loudly instead of shrinking the derived set"
  slug=$(slugify "$heading")
  EXPECTED_SLUGS+=("$slug")
  created=$(printf '2026-04-01T%02d:00:00Z' "$hour")
  body=$(printf '## PR Review — %s\n\nfixture for #495 (slug: %s)' "$heading" "$slug")
  entry=$(jq -nc --arg body "$body" --arg created "$created" --arg url "https://example.invalid/pr/42#slug-$slug" \
    '{body:$body, created_at:$created, html_url:$url}')
  slug_entries=$(jq -c --argjson e "$entry" '. + [$e]' <<<"$slug_entries")
  hour=$((hour+1))
done
# The floor is now the exact template-file count, not a vacuous `-ge 1` — a
# rename or reshape that drops the derived-slug count below the number of
# `*.md` files in the templates directory must fail loudly.
[ "${#EXPECTED_SLUGS[@]}" -eq "$TEMPLATE_COUNT" ] \
  || report "#495/finding 3: derived ${#EXPECTED_SLUGS[@]} verdict slugs but $PR_REVIEW_TEMPLATES_DIR/*.md has $TEMPLATE_COUNT templates — a template silently yielded no heading"
[ "$TEMPLATE_COUNT" -ge 1 ] \
  || report "#495: found zero template files in $PR_REVIEW_TEMPLATES_DIR — templates dir moved"

FIXTURES_SLUGS="$WORK/fixtures_slugs"
mkdir -p "$FIXTURES_SLUGS"
cp "$FIXTURES/pull.json" "$FIXTURES/checks.json" "$FIXTURES_SLUGS/"
printf '%s\n' "$slug_entries" > "$FIXTURES_SLUGS/comments_page1.json"
echo '[]' > "$FIXTURES_SLUGS/comments_page2.json"
echo '[]' > "$FIXTURES_SLUGS/comments_page3.json"
echo '[]' > "$FIXTURES_SLUGS/comments_page4.json"

set +e
MOCK_GH_FIXTURES="$FIXTURES_SLUGS" PATH="$BIN:$PATH" \
  "$PREFLIGHT_SH" "$PR" --repo "$REPO" > "$OUT/slugs.stdout.log" 2> "$OUT/slugs.stderr.log"
rc=$?
set -e
[ "$rc" -eq 0 ] || report "#495 verdict slugs: expected exit 0, got $rc: $(cat "$OUT/slugs.stderr.log")"
if jq -e . "$OUT/slugs.stdout.log" >/dev/null 2>&1; then
  n_unrec=$(jq '.unrecognized_verdicts|length' "$OUT/slugs.stdout.log")
  [ "$n_unrec" = "0" ] \
    || report "#495: expected 0 unrecognized_verdicts for the templates' own slugs (derived: ${EXPECTED_SLUGS[*]}), got $n_unrec: $(jq -c '.unrecognized_verdicts' "$OUT/slugs.stdout.log")"
  # #658: every terminal verdict slug is a round that happened — approved and
  # escalated count the same as changes_requested and decomposition_requested;
  # an escalated round is no longer invisible to the count.
  expected_rounds=0
  for slug in "${EXPECTED_SLUGS[@]}"; do
    case "$slug" in approved|changes_requested|decomposition_requested|escalated) expected_rounds=$((expected_rounds+1)) ;; esac
  done
  got_rounds=$(jq -r '.rounds' "$OUT/slugs.stdout.log")
  [ "$got_rounds" = "$expected_rounds" ] \
    || report "#495: expected rounds=$expected_rounds derived from the templates (${EXPECTED_SLUGS[*]}), got $got_rounds"
else
  report "#495 verdict slugs: stdout is not valid JSON: $(cat "$OUT/slugs.stdout.log")"
fi

# ---------------------------------------------------------------------------
# #658: an escalated round is not invisible to the count, and a relay
# comment never advances it. Isolated fixture set, independent of the main
# run above: round 1 a footer-bearing "Changes Requested", round 2 a
# footer-bearing "Escalated" (the round that used to be invisible to the
# count), then a "## Review Findings — relay" comment on the now-reopened
# PR (no `## PR Review — …` heading, no `verdict` footer key) that must NOT
# be counted as round 3. Expected rounds=2: the escalated round counts, the
# relay comment does not.
# ---------------------------------------------------------------------------
FIXTURES_ESCALATED="$WORK/fixtures_escalated"
mkdir -p "$FIXTURES_ESCALATED"
cp "$FIXTURES/pull.json" "$FIXTURES/checks.json" "$FIXTURES_ESCALATED/"
cat > "$FIXTURES_ESCALATED/comments_page1.json" <<JSON
[
  {
    "body": "<!-- review {\"v\":1,\"round\":1,\"verdict\":\"changes_requested\",\"findings\":[1]} -->\n## PR Review — Changes Requested\n\nfix X",
    "created_at": "2026-05-01T00:00:00Z",
    "html_url": "https://example.invalid/pr/42#escalated-r1"
  },
  {
    "body": "<!-- review {\"v\":1,\"round\":2,\"verdict\":\"escalated\",\"findings\":[]} -->\n## PR Review — Escalated\n\nneeds an owner ruling",
    "created_at": "2026-05-02T00:00:00Z",
    "html_url": "https://example.invalid/pr/42#escalated-r2"
  },
  {
    "body": "## Review Findings — relay\n\n| # | Severity | Note |\n|---|---|---|\n| 1 | minor | tidy up |\n",
    "created_at": "2026-05-03T00:00:00Z",
    "html_url": "https://example.invalid/pr/42#escalated-relay"
  }
]
JSON
echo '[]' > "$FIXTURES_ESCALATED/comments_page2.json"
echo '[]' > "$FIXTURES_ESCALATED/comments_page3.json"
echo '[]' > "$FIXTURES_ESCALATED/comments_page4.json"

set +e
MOCK_GH_FIXTURES="$FIXTURES_ESCALATED" PATH="$BIN:$PATH" \
  "$PREFLIGHT_SH" "$PR" --repo "$REPO" > "$OUT/escalated.stdout.log" 2> "$OUT/escalated.stderr.log"
rc=$?
set -e
[ "$rc" -eq 0 ] || report "#658 escalated/relay: expected exit 0, got $rc: $(cat "$OUT/escalated.stderr.log")"
if jq -e . "$OUT/escalated.stdout.log" >/dev/null 2>&1; then
  got=$(jq -r '.rounds' "$OUT/escalated.stdout.log")
  [ "$got" = "2" ] \
    || report "#658: expected rounds=2 (escalated round counted, relay comment does not), got $got"
  latest=$(jq -r '.latest_verdict.verdict' "$OUT/escalated.stdout.log")
  [ "$latest" = "escalated" ] \
    || report "#658: expected latest_verdict=escalated, got $latest"
  n_unrec=$(jq '.unrecognized_verdicts|length' "$OUT/escalated.stdout.log")
  [ "$n_unrec" = "0" ] \
    || report "#658: the relay comment must not surface as an unrecognized verdict either (it carries no ## PR Review heading), got $n_unrec: $(jq -c '.unrecognized_verdicts' "$OUT/escalated.stdout.log")"
else
  report "#658 escalated/relay: stdout is not valid JSON: $(cat "$OUT/escalated.stdout.log")"
fi

# ---------------------------------------------------------------------------
# #496/#600: strip_fences() shapes beyond a plain 3-backtick fence — a nested
# fence (shorter 3-backtick inner marker inside a 4-backtick outer one), a
# `~~~` fence, and fences indented by 2 and by 3 spaces all keep their decoy
# hidden; an unterminated fence's real heading (never closed before end of
# comment) must still be seen, not permanently hidden. Each shape is its own
# comment so a failure names exactly which shape broke.
#
# #600: the 2-space fixture's decoy heading must NOT itself be indented — an
# indented decoy is invisible to preflight.sh's anchored `^## PR Review`
# heading regex regardless of whether strip_fences() treats the surrounding
# backtick lines as a fence at all, so that shape of fixture passes for the
# wrong reason and pins nothing about the indent bound (found against the
# original fixture, which indented the decoy by the same 2 spaces as the
# fence). Un-indenting the decoy means the assertion can only hold if
# strip_fences() actually consumed the 2-/3-space-indented marker lines as a
# real fence open/close and buffered the heading between them. A 3-space case
# is added alongside as the exact CommonMark boundary. Tightening
# strip_fences()'s indent bound to `^ ?(` (allows only 0-1 leading spaces) or
# `^ ? ?(` (0-2) makes the corresponding backtick lines stop being fence
# markers, so the un-indented decoy heading between them prints as ordinary
# text and IS matched — fence2_rounds below rises above 1 and the assertion
# fails, which it would not have under the original indented-decoy fixture.
# ---------------------------------------------------------------------------
FIXTURES_FENCE2="$WORK/fixtures_fence2"
mkdir -p "$FIXTURES_FENCE2"
cp "$FIXTURES/pull.json" "$FIXTURES/checks.json" "$FIXTURES_FENCE2/"
cat > "$FIXTURES_FENCE2/comments_page1.json" <<JSON
[
  {"body": "Nested fence, 4-backtick outer wrapping a 3-backtick inner:\n\n\`\`\`\`\nouter\n\`\`\`\n## PR Review — Changes Requested\n\`\`\`\nstill outer\n\`\`\`\`\n\nNo heading outside the outer fence.", "created_at": "2026-05-01T00:00:00Z", "html_url": "https://example.invalid/pr/42#fence2-nested"},
  {"body": "Tilde fence:\n\n~~~\n## PR Review — Changes Requested\n~~~\n\nNo heading outside the tilde fence.", "created_at": "2026-05-01T01:00:00Z", "html_url": "https://example.invalid/pr/42#fence2-tilde"},
  {"body": "Fence indented by 2 spaces, decoy heading NOT indented (#600):\n\n  \`\`\`\n## PR Review — Changes Requested\n  \`\`\`\n\nNo heading outside the indented fence.", "created_at": "2026-05-01T02:00:00Z", "html_url": "https://example.invalid/pr/42#fence2-indented2"},
  {"body": "Fence indented by 3 spaces (the exact CommonMark boundary), decoy heading NOT indented (#600):\n\n   \`\`\`\n## PR Review — Changes Requested\n   \`\`\`\n\nNo heading outside the indented fence.", "created_at": "2026-05-01T02:30:00Z", "html_url": "https://example.invalid/pr/42#fence2-indented3"},
  {"body": "Unterminated fence — never closes before the comment ends, so the\nreal heading below must still be seen, not hidden:\n\n\`\`\`\ndecoy content\n## PR Review — Changes Requested\nmore decoy content", "created_at": "2026-05-01T03:00:00Z", "html_url": "https://example.invalid/pr/42#fence2-unterminated"}
]
JSON
echo '[]' > "$FIXTURES_FENCE2/comments_page2.json"
echo '[]' > "$FIXTURES_FENCE2/comments_page3.json"
echo '[]' > "$FIXTURES_FENCE2/comments_page4.json"

set +e
MOCK_GH_FIXTURES="$FIXTURES_FENCE2" PATH="$BIN:$PATH" \
  "$PREFLIGHT_SH" "$PR" --repo "$REPO" > "$OUT/fence2.stdout.log" 2> "$OUT/fence2.stderr.log"
rc=$?
set -e
[ "$rc" -eq 0 ] || report "#496 fence shapes: expected exit 0, got $rc: $(cat "$OUT/fence2.stderr.log")"
if jq -e . "$OUT/fence2.stdout.log" >/dev/null 2>&1; then
  fence2_rounds=$(jq -r '.rounds' "$OUT/fence2.stdout.log")
  # 4 decoys (nested, tilde, 2-space-indented, 3-space-indented) hidden -> 0
  # rounds from them; the unterminated fence's real heading must still be
  # seen -> 1 round total.
  [ "$fence2_rounds" = "1" ] \
    || report "#496/#600: expected rounds=1 (nested/tilde/2-space/3-space decoys hidden, unterminated-fence heading visible), got $fence2_rounds"
  fence2_latest=$(jq -r '.latest_verdict.verdict' "$OUT/fence2.stdout.log")
  [ "$fence2_latest" = "changes_requested" ] \
    || report "#496: expected latest_verdict=changes_requested (from the unterminated-fence comment), got $fence2_latest"
  fence2_latest_url=$(jq -r '.latest_verdict.url' "$OUT/fence2.stdout.log")
  [ "$fence2_latest_url" = "https://example.invalid/pr/42#fence2-unterminated" ] \
    || report "#496: expected the recognised verdict to come from the unterminated-fence comment, got url=$fence2_latest_url"
else
  report "#496 fence shapes: stdout is not valid JSON: $(cat "$OUT/fence2.stdout.log")"
fi

# ---------------------------------------------------------------------------
# #590: strip_fences()'s indent bound is pinned at "up to 3 leading spaces"
# (CommonMark: a fence indented 4 or more spaces is instead an indented code
# block, not a fence, so its backtick lines are NOT fence markers at all).
# A comment whose backtick-bracketed heading is indented by 4 spaces must
# therefore have that heading counted normally (NOT hidden), unlike the
# #496 2-space-indented fixture above, which is inside the bound and DOES
# hide its heading. This is the direction a mutation to `^ *(` (unlimited
# indent, no upper bound) would get wrong: under that mutation the 4-space
# lines would wrongly become fence markers and the heading between them
# would wrongly vanish.
# ---------------------------------------------------------------------------
FIXTURES_FENCE4="$WORK/fixtures_fence4"
mkdir -p "$FIXTURES_FENCE4"
cp "$FIXTURES/pull.json" "$FIXTURES/checks.json" "$FIXTURES_FENCE4/"
cat > "$FIXTURES_FENCE4/comments_page1.json" <<'JSON'
[
  {"body": "Backtick lines indented by 4 spaces are NOT fence markers (CommonMark:\n4+ spaces is an indented code block instead, out of the up-to-3 fence bound),\nso the un-indented heading between them must be seen normally, not treated\nas fenced content:\n\n    ```\n## PR Review — Changes Requested\n    ```\n\nVisible: the 4-space lines above/below are not a real fence.", "created_at": "2026-06-01T00:00:00Z", "html_url": "https://example.invalid/pr/42#fence4-fourspace"}
]
JSON
echo '[]' > "$FIXTURES_FENCE4/comments_page2.json"
echo '[]' > "$FIXTURES_FENCE4/comments_page3.json"
echo '[]' > "$FIXTURES_FENCE4/comments_page4.json"

set +e
MOCK_GH_FIXTURES="$FIXTURES_FENCE4" PATH="$BIN:$PATH" \
  "$PREFLIGHT_SH" "$PR" --repo "$REPO" > "$OUT/fence4.stdout.log" 2> "$OUT/fence4.stderr.log"
rc=$?
set -e
[ "$rc" -eq 0 ] || report "#590 4-space indent: expected exit 0, got $rc: $(cat "$OUT/fence4.stderr.log")"
if jq -e . "$OUT/fence4.stdout.log" >/dev/null 2>&1; then
  fence4_rounds=$(jq -r '.rounds' "$OUT/fence4.stdout.log")
  [ "$fence4_rounds" = "1" ] \
    || report "#590: a 4-space-indented backtick pair is NOT a fence (CommonMark), so the heading between them must be seen (expected rounds=1, got $fence4_rounds — a mutation to \`^ *(\` (unlimited indent) would hide it and yield 0)"
  fence4_latest=$(jq -r '.latest_verdict.verdict' "$OUT/fence4.stdout.log")
  [ "$fence4_latest" = "changes_requested" ] \
    || report "#590: expected latest_verdict=changes_requested (heading not hidden by the 4-space-indented non-fence), got $fence4_latest"
else
  report "#590 4-space indent: stdout is not valid JSON: $(cat "$OUT/fence4.stdout.log")"
fi

# ---------------------------------------------------------------------------
# #557: strip_fences()'s marker threshold is pinned at "3 or more" — a run of
# exactly 1 or 2 backticks must NOT open a fence. Each comment brackets its
# real heading between a matched OPEN/CLOSE pair of sub-threshold marker
# lines (not left unterminated, which the #496 end-of-input flush would
# recover regardless of the threshold and so would not distinguish the
# mutation): under the correct `>= 3` guard, a 1- or 2-backtick line is never
# a marker at all, so the heading between the pair prints normally along
# with everything else. Under the mutation `length(marker) >= 1`, the first
# such line opens a fence, the second (same character, same or greater
# length) closes it, and everything buffered between them — including the
# heading — is discarded, dropping rounds from 2 to 0 and latest_verdict to
# null. Two comments, one per sub-threshold length, so a failure names which
# length broke.
# ---------------------------------------------------------------------------
FIXTURES_FENCE3="$WORK/fixtures_fence3"
mkdir -p "$FIXTURES_FENCE3"
cp "$FIXTURES/pull.json" "$FIXTURES/checks.json" "$FIXTURES_FENCE3/"
cat > "$FIXTURES_FENCE3/comments_page1.json" <<JSON
[
  {"body": "A matched pair of 1-backtick lines is not a fence (CommonMark requires 3+), so the heading between them must never be hidden:\n\n\`\ndecoy-open\n## PR Review — Changes Requested\ndecoy-close\n\`\n\nStill visible after the closing 1-backtick line.", "created_at": "2026-05-01T04:00:00Z", "html_url": "https://example.invalid/pr/42#fence3-onebacktick"},
  {"body": "A matched pair of 2-backtick lines is not a fence (CommonMark requires 3+), so the heading between them must never be hidden:\n\n\`\`\ndecoy-open\n## PR Review — Decomposition Requested\ndecoy-close\n\`\`\n\nStill visible after the closing 2-backtick line.", "created_at": "2026-05-01T05:00:00Z", "html_url": "https://example.invalid/pr/42#fence3-twobacktick"}
]
JSON
echo '[]' > "$FIXTURES_FENCE3/comments_page2.json"
echo '[]' > "$FIXTURES_FENCE3/comments_page3.json"
echo '[]' > "$FIXTURES_FENCE3/comments_page4.json"

set +e
MOCK_GH_FIXTURES="$FIXTURES_FENCE3" PATH="$BIN:$PATH" \
  "$PREFLIGHT_SH" "$PR" --repo "$REPO" > "$OUT/fence3.stdout.log" 2> "$OUT/fence3.stderr.log"
rc=$?
set -e
[ "$rc" -eq 0 ] || report "#557 sub-threshold marker: expected exit 0, got $rc: $(cat "$OUT/fence3.stderr.log")"
if jq -e . "$OUT/fence3.stdout.log" >/dev/null 2>&1; then
  fence3_rounds=$(jq -r '.rounds' "$OUT/fence3.stdout.log")
  [ "$fence3_rounds" = "2" ] \
    || report "#557: a 1- or 2-backtick run must NOT open a fence, so both headings below them must be seen (expected rounds=2, got $fence3_rounds — a mutation to \`length(marker) >= 1\` would hide both and yield 0)"
  fence3_latest=$(jq -r '.latest_verdict.verdict' "$OUT/fence3.stdout.log")
  [ "$fence3_latest" = "decomposition_requested" ] \
    || report "#557: expected latest_verdict=decomposition_requested (heading not hidden by the 2-backtick run), got $fence3_latest"
else
  report "#557 sub-threshold marker: stdout is not valid JSON: $(cat "$OUT/fence3.stdout.log")"
fi

# ---------------------------------------------------------------------------
# #512: any issue-thread comment whose entire trimmed body matches
# `^@\S+$` is the literal-path posting defect (`gh ... --body "@file"` run
# instead of `-F body=@file` or a --body-file equivalent, so the comment's
# visible text is the shell-quoted path itself rather than the file's
# content). Reported in both the JSON (`malformed_comments: [{id, url}]`)
# and --markdown (a warning line). A well-formed comment (real prose, or a
# body that merely starts with "@" but has trailing content/whitespace)
# must NOT be flagged. Round-2 finding 1: the detector must match the
# WHOLE trimmed body, not any single line — a multi-line comment that
# merely contains a lone `@mention` line among ordinary prose (the exact
# shape a GitHub reviewer types every day) must NOT be flagged, even though
# a naive per-line `grep -q '^@\S+$'` would flag it.
# ---------------------------------------------------------------------------
FIXTURES_ATPATH="$WORK/fixtures_atpath"
mkdir -p "$FIXTURES_ATPATH"
cp "$FIXTURES/pull.json" "$FIXTURES/checks.json" "$FIXTURES_ATPATH/"
cat > "$FIXTURES_ATPATH/comments_page1.json" <<JSON
[
  {"id": 9001, "body": "@dispatch.md", "created_at": "2026-05-02T00:00:00Z", "html_url": "https://example.invalid/pr/42#atpath-bare"},
  {"id": 9002, "body": "  @scratch/evidence/issue299/manifest.md  \n", "created_at": "2026-05-02T01:00:00Z", "html_url": "https://example.invalid/pr/42#atpath-padded"},
  {"id": 9003, "body": "@user please take a look, this is real prose", "created_at": "2026-05-02T02:00:00Z", "html_url": "https://example.invalid/pr/42#atpath-mention"},
  {"id": 9004, "body": "Some normal review comment text.", "created_at": "2026-05-02T03:00:00Z", "html_url": "https://example.invalid/pr/42#atpath-normal"},
  {"id": 9005, "body": "Handing back to the orchestrator.\n@machine-blac9216\nRound 2 complete.", "created_at": "2026-05-02T04:00:00Z", "html_url": "https://example.invalid/pr/42#atpath-multiline-mention"},
  {"id": 9006, "body": "@/tmp/x.md", "created_at": "2026-05-02T05:00:00Z", "html_url": "https://example.invalid/pr/42#atpath-tmp"},
  {"id": 9007, "body": "@user\n", "created_at": "2026-05-02T06:00:00Z", "html_url": "https://example.invalid/pr/42#atpath-trailing-newline"}
]
JSON
echo '[]' > "$FIXTURES_ATPATH/comments_page2.json"
echo '[]' > "$FIXTURES_ATPATH/comments_page3.json"
echo '[]' > "$FIXTURES_ATPATH/comments_page4.json"

set +e
MOCK_GH_FIXTURES="$FIXTURES_ATPATH" PATH="$BIN:$PATH" \
  "$PREFLIGHT_SH" "$PR" --repo "$REPO" > "$OUT/atpath.stdout.log" 2> "$OUT/atpath.stderr.log"
rc=$?
set -e
[ "$rc" -eq 0 ] || report "#512 @-path detector: expected exit 0, got $rc: $(cat "$OUT/atpath.stderr.log")"
if jq -e . "$OUT/atpath.stdout.log" >/dev/null 2>&1; then
  n_malformed=$(jq '.malformed_comments|length' "$OUT/atpath.stdout.log")
  [ "$n_malformed" = "4" ] \
    || report "#512: expected 4 malformed @-path comments (bare + padded + /tmp/x.md + trailing-newline), got $n_malformed: $(jq -c '.malformed_comments' "$OUT/atpath.stdout.log")"
  malformed_urls=$(jq -r '.malformed_comments[].url' "$OUT/atpath.stdout.log" | sort | tr '\n' ' ')
  for want in atpath-bare atpath-padded atpath-tmp atpath-trailing-newline; do
    case "$malformed_urls" in
      *"$want"*) : ;;
      *) report "#512: expected malformed_comments to name $want, got: $malformed_urls" ;;
    esac
  done
  case "$malformed_urls" in
    *atpath-mention*) report "#512: a comment with trailing prose after the @-mention must NOT be flagged, got: $malformed_urls" ;;
    *atpath-normal*) report "#512: a normal prose comment must NOT be flagged, got: $malformed_urls" ;;
    *atpath-multiline-mention*) report "round-2 finding 1: a multi-line comment containing a lone @mention LINE (not the whole body) must NOT be flagged (line-oriented grep regression), got: $malformed_urls" ;;
    *) : ;;
  esac
else
  report "#512 @-path detector: stdout is not valid JSON: $(cat "$OUT/atpath.stdout.log")"
fi

set +e
MOCK_GH_FIXTURES="$FIXTURES_ATPATH" PATH="$BIN:$PATH" \
  "$PREFLIGHT_SH" "$PR" --repo "$REPO" --markdown > "$OUT/atpath.md.log" 2> "$OUT/atpath.md.stderr.log"
rc=$?
set -e
[ "$rc" -eq 0 ] || report "#512 --markdown: expected exit 0, got $rc: $(cat "$OUT/atpath.md.stderr.log")"
grep -qF "malformed @-path comment" "$OUT/atpath.md.log" \
  || report "#512 --markdown: missing the malformed @-path comment warning line, got: $(cat "$OUT/atpath.md.log")"
grep -qF "atpath-bare" "$OUT/atpath.md.log" \
  || report "#512 --markdown: warning line missing the bare @-path comment's URL, got: $(cat "$OUT/atpath.md.log")"

# ---------------------------------------------------------------------------
# #299: CI falls back to the legacy commit-status API when check-runs is
# empty. Two isolated fixture sets, each with an empty check-runs.json:
#  - CI_LEGACY: the status endpoint has real data -> ci.source=legacy_status,
#    ci.state derived from it (one failing context -> "failure").
#  - CI_NONE: the status endpoint is also empty -> ci.source=none, true
#    absence, distinct from "not checked".
# ---------------------------------------------------------------------------
FIXTURES_CI_LEGACY="$WORK/fixtures_ci_legacy"
mkdir -p "$FIXTURES_CI_LEGACY"
cp "$FIXTURES/pull.json" "$FIXTURES_CI_LEGACY/"
echo '[]' > "$FIXTURES_CI_LEGACY/comments_page1.json"
echo '[]' > "$FIXTURES_CI_LEGACY/comments_page2.json"
echo '[]' > "$FIXTURES_CI_LEGACY/comments_page3.json"
echo '[]' > "$FIXTURES_CI_LEGACY/comments_page4.json"
echo '{"check_runs":[]}' > "$FIXTURES_CI_LEGACY/checks.json"
cat > "$FIXTURES_CI_LEGACY/status.json" <<JSON
{"state":"failure","statuses":[{"context":"legacy-ci/build","state":"failure"},{"context":"legacy-ci/lint","state":"success"}]}
JSON

set +e
MOCK_GH_FIXTURES="$FIXTURES_CI_LEGACY" PATH="$BIN:$PATH" \
  "$PREFLIGHT_SH" "$PR" --repo "$REPO" > "$OUT/cilegacy.stdout.log" 2> "$OUT/cilegacy.stderr.log"
rc=$?
set -e
[ "$rc" -eq 0 ] || report "#299 legacy status: expected exit 0, got $rc: $(cat "$OUT/cilegacy.stderr.log")"
if jq -e . "$OUT/cilegacy.stdout.log" >/dev/null 2>&1; then
  [ "$(jq -r '.ci.source' "$OUT/cilegacy.stdout.log")" = "legacy_status" ] \
    || report "#299: expected ci.source=legacy_status, got: $(jq -c '.ci' "$OUT/cilegacy.stdout.log")"
  [ "$(jq -r '.ci.state' "$OUT/cilegacy.stdout.log")" = "failure" ] \
    || report "#299: expected ci.state=failure from the legacy status endpoint, got: $(jq -c '.ci' "$OUT/cilegacy.stdout.log")"
  [ "$(jq -r '.ci.checks|length' "$OUT/cilegacy.stdout.log")" = "2" ] \
    || report "#299: expected 2 synthetic checks folded in from the legacy statuses, got: $(jq -c '.ci' "$OUT/cilegacy.stdout.log")"
else
  report "#299 legacy status: stdout is not valid JSON: $(cat "$OUT/cilegacy.stdout.log")"
fi

set +e
MOCK_GH_FIXTURES="$FIXTURES_CI_LEGACY" PATH="$BIN:$PATH" \
  "$PREFLIGHT_SH" "$PR" --repo "$REPO" --markdown > "$OUT/cilegacy.md.stdout.log" 2> "$OUT/cilegacy.md.stderr.log"
rc=$?
set -e
[ "$rc" -eq 0 ] || report "#299 legacy status markdown: expected exit 0, got $rc: $(cat "$OUT/cilegacy.md.stderr.log")"
grep -qE '^- CI: failure \(via legacy status API\)' "$OUT/cilegacy.md.stdout.log" \
  || report "#299: --markdown missing the 'via legacy status API' annotation, got: $(cat "$OUT/cilegacy.md.stdout.log")"

FIXTURES_CI_NONE="$WORK/fixtures_ci_none"
mkdir -p "$FIXTURES_CI_NONE"
cp "$FIXTURES/pull.json" "$FIXTURES_CI_NONE/"
echo '[]' > "$FIXTURES_CI_NONE/comments_page1.json"
echo '[]' > "$FIXTURES_CI_NONE/comments_page2.json"
echo '[]' > "$FIXTURES_CI_NONE/comments_page3.json"
echo '[]' > "$FIXTURES_CI_NONE/comments_page4.json"
echo '{"check_runs":[]}' > "$FIXTURES_CI_NONE/checks.json"
echo '{"state":"pending","statuses":[]}' > "$FIXTURES_CI_NONE/status.json"

set +e
MOCK_GH_FIXTURES="$FIXTURES_CI_NONE" PATH="$BIN:$PATH" \
  "$PREFLIGHT_SH" "$PR" --repo "$REPO" > "$OUT/cinone.stdout.log" 2> "$OUT/cinone.stderr.log"
rc=$?
set -e
[ "$rc" -eq 0 ] || report "#299 true absence: expected exit 0, got $rc: $(cat "$OUT/cinone.stderr.log")"
if jq -e . "$OUT/cinone.stdout.log" >/dev/null 2>&1; then
  [ "$(jq -r '.ci.source' "$OUT/cinone.stdout.log")" = "none" ] \
    || report "#299: expected ci.source=none (both endpoints genuinely empty), got: $(jq -c '.ci' "$OUT/cinone.stdout.log")"
  [ "$(jq -r '.ci.state' "$OUT/cinone.stdout.log")" = "none" ] \
    || report "#299: expected ci.state=none, got: $(jq -c '.ci' "$OUT/cinone.stdout.log")"
else
  report "#299 true absence: stdout is not valid JSON: $(cat "$OUT/cinone.stdout.log")"
fi

# ---------------------------------------------------------------------------
# finding 2 (PR #530 round 1): the legacy-status fold must map the Status
# API's real state vocabulary (error/failure/pending/success) honestly, not
# hardcode status:"completed" for every state. A genuinely PENDING legacy
# status must resolve ci.state to "pending", not "unknown" (which is what
# {status:"completed", conclusion:"pending"} would silently produce — it
# satisfies neither the failure disjuncts, nor "any(.status!=completed)",
# nor the success "all(...)"). A genuine ERROR legacy status must resolve to
# "failure", exercising the `.conclusion=="error"` disjunct that was
# otherwise never fixture-covered (review note 2).
# ---------------------------------------------------------------------------
FIXTURES_CI_LEGACY_PENDING="$WORK/fixtures_ci_legacy_pending"
mkdir -p "$FIXTURES_CI_LEGACY_PENDING"
cp "$FIXTURES/pull.json" "$FIXTURES_CI_LEGACY_PENDING/"
echo '[]' > "$FIXTURES_CI_LEGACY_PENDING/comments_page1.json"
echo '[]' > "$FIXTURES_CI_LEGACY_PENDING/comments_page2.json"
echo '[]' > "$FIXTURES_CI_LEGACY_PENDING/comments_page3.json"
echo '[]' > "$FIXTURES_CI_LEGACY_PENDING/comments_page4.json"
echo '{"check_runs":[]}' > "$FIXTURES_CI_LEGACY_PENDING/checks.json"
cat > "$FIXTURES_CI_LEGACY_PENDING/status.json" <<JSON
{"state":"pending","statuses":[{"context":"legacy-ci/build","state":"pending"}]}
JSON

set +e
MOCK_GH_FIXTURES="$FIXTURES_CI_LEGACY_PENDING" PATH="$BIN:$PATH" \
  "$PREFLIGHT_SH" "$PR" --repo "$REPO" > "$OUT/cilegacypending.stdout.log" 2> "$OUT/cilegacypending.stderr.log"
rc=$?
set -e
[ "$rc" -eq 0 ] || report "finding 2 legacy pending: expected exit 0, got $rc: $(cat "$OUT/cilegacypending.stderr.log")"
if jq -e . "$OUT/cilegacypending.stdout.log" >/dev/null 2>&1; then
  [ "$(jq -r '.ci.source' "$OUT/cilegacypending.stdout.log")" = "legacy_status" ] \
    || report "finding 2: expected ci.source=legacy_status, got: $(jq -c '.ci' "$OUT/cilegacypending.stdout.log")"
  [ "$(jq -r '.ci.state' "$OUT/cilegacypending.stdout.log")" = "pending" ] \
    || report "finding 2: expected ci.state=pending from a legacy pending status, got: $(jq -c '.ci' "$OUT/cilegacypending.stdout.log")"
  [ "$(jq -r '.ci.checks[0].status' "$OUT/cilegacypending.stdout.log")" = "in_progress" ] \
    || report "finding 2: expected the folded pending status to carry status=in_progress, got: $(jq -c '.ci' "$OUT/cilegacypending.stdout.log")"
else
  report "finding 2 legacy pending: stdout is not valid JSON: $(cat "$OUT/cilegacypending.stdout.log")"
fi

FIXTURES_CI_LEGACY_ERROR="$WORK/fixtures_ci_legacy_error"
mkdir -p "$FIXTURES_CI_LEGACY_ERROR"
cp "$FIXTURES/pull.json" "$FIXTURES_CI_LEGACY_ERROR/"
echo '[]' > "$FIXTURES_CI_LEGACY_ERROR/comments_page1.json"
echo '[]' > "$FIXTURES_CI_LEGACY_ERROR/comments_page2.json"
echo '[]' > "$FIXTURES_CI_LEGACY_ERROR/comments_page3.json"
echo '[]' > "$FIXTURES_CI_LEGACY_ERROR/comments_page4.json"
echo '{"check_runs":[]}' > "$FIXTURES_CI_LEGACY_ERROR/checks.json"
cat > "$FIXTURES_CI_LEGACY_ERROR/status.json" <<JSON
{"state":"error","statuses":[{"context":"legacy-ci/build","state":"error"}]}
JSON

set +e
MOCK_GH_FIXTURES="$FIXTURES_CI_LEGACY_ERROR" PATH="$BIN:$PATH" \
  "$PREFLIGHT_SH" "$PR" --repo "$REPO" > "$OUT/cilegacyerror.stdout.log" 2> "$OUT/cilegacyerror.stderr.log"
rc=$?
set -e
[ "$rc" -eq 0 ] || report "finding 2/note 2 legacy error: expected exit 0, got $rc: $(cat "$OUT/cilegacyerror.stderr.log")"
if jq -e . "$OUT/cilegacyerror.stdout.log" >/dev/null 2>&1; then
  [ "$(jq -r '.ci.state' "$OUT/cilegacyerror.stdout.log")" = "failure" ] \
    || report "finding 2/note 2: expected ci.state=failure from a legacy error status, got: $(jq -c '.ci' "$OUT/cilegacyerror.stdout.log")"
  [ "$(jq -r '.ci.checks[0].status' "$OUT/cilegacyerror.stdout.log")" = "completed" ] \
    || report "finding 2/note 2: expected the folded error status to keep status=completed, got: $(jq -c '.ci' "$OUT/cilegacyerror.stdout.log")"
else
  report "finding 2/note 2 legacy error: stdout is not valid JSON: $(cat "$OUT/cilegacyerror.stdout.log")"
fi

# ---------------------------------------------------------------------------
# #591: the checks API's conclusion vocabulary also includes
# "action_required" and "stale", neither of which appeared in any CI_STATE
# branch before this round — both used to fall through to the "unknown"
# catch-all. action_required folds into the failure-class disjuncts (a check
# that completed but demands a human step before it can be trusted); stale
# folds into "pending" (GitHub no longer considers a prior run's conclusion
# current, the same "do not trust this as final" posture as still-running).
# One check-runs fixture per conclusion, each alongside an ordinary
# completed/success check-run so a wrong catch-all can't hide behind an
# empty-list special case.
# ---------------------------------------------------------------------------
FIXTURES_CI_ACTION_REQUIRED="$WORK/fixtures_ci_action_required"
mkdir -p "$FIXTURES_CI_ACTION_REQUIRED"
cp "$FIXTURES/pull.json" "$FIXTURES_CI_ACTION_REQUIRED/"
echo '[]' > "$FIXTURES_CI_ACTION_REQUIRED/comments_page1.json"
echo '[]' > "$FIXTURES_CI_ACTION_REQUIRED/comments_page2.json"
echo '[]' > "$FIXTURES_CI_ACTION_REQUIRED/comments_page3.json"
echo '[]' > "$FIXTURES_CI_ACTION_REQUIRED/comments_page4.json"
cat > "$FIXTURES_CI_ACTION_REQUIRED/checks.json" <<JSON
{"check_runs":[{"name":"deploy-approval","status":"completed","conclusion":"action_required"},{"name":"lint","status":"completed","conclusion":"success"}]}
JSON

set +e
MOCK_GH_FIXTURES="$FIXTURES_CI_ACTION_REQUIRED" PATH="$BIN:$PATH" \
  "$PREFLIGHT_SH" "$PR" --repo "$REPO" > "$OUT/ciactionrequired.stdout.log" 2> "$OUT/ciactionrequired.stderr.log"
rc=$?
set -e
[ "$rc" -eq 0 ] || report "#591 action_required: expected exit 0, got $rc: $(cat "$OUT/ciactionrequired.stderr.log")"
if jq -e . "$OUT/ciactionrequired.stdout.log" >/dev/null 2>&1; then
  [ "$(jq -r '.ci.state' "$OUT/ciactionrequired.stdout.log")" = "failure" ] \
    || report "#591: expected ci.state=failure from an action_required check-run conclusion, got: $(jq -c '.ci' "$OUT/ciactionrequired.stdout.log")"
else
  report "#591 action_required: stdout is not valid JSON: $(cat "$OUT/ciactionrequired.stdout.log")"
fi

FIXTURES_CI_STALE="$WORK/fixtures_ci_stale"
mkdir -p "$FIXTURES_CI_STALE"
cp "$FIXTURES/pull.json" "$FIXTURES_CI_STALE/"
echo '[]' > "$FIXTURES_CI_STALE/comments_page1.json"
echo '[]' > "$FIXTURES_CI_STALE/comments_page2.json"
echo '[]' > "$FIXTURES_CI_STALE/comments_page3.json"
echo '[]' > "$FIXTURES_CI_STALE/comments_page4.json"
cat > "$FIXTURES_CI_STALE/checks.json" <<JSON
{"check_runs":[{"name":"integration","status":"completed","conclusion":"stale"},{"name":"lint","status":"completed","conclusion":"success"}]}
JSON

set +e
MOCK_GH_FIXTURES="$FIXTURES_CI_STALE" PATH="$BIN:$PATH" \
  "$PREFLIGHT_SH" "$PR" --repo "$REPO" > "$OUT/cistale.stdout.log" 2> "$OUT/cistale.stderr.log"
rc=$?
set -e
[ "$rc" -eq 0 ] || report "#591 stale: expected exit 0, got $rc: $(cat "$OUT/cistale.stderr.log")"
if jq -e . "$OUT/cistale.stdout.log" >/dev/null 2>&1; then
  [ "$(jq -r '.ci.state' "$OUT/cistale.stdout.log")" = "pending" ] \
    || report "#591: expected ci.state=pending from a stale check-run conclusion, got: $(jq -c '.ci' "$OUT/cistale.stdout.log")"
else
  report "#591 stale: stdout is not valid JSON: $(cat "$OUT/cistale.stdout.log")"
fi

# ---------------------------------------------------------------------------
# #601: an evidence log that EXISTS on disk but is chmod 000 (unreadable by
# this process) must render as a distinct "UNREADABLE" state, never as
# "HASH MISMATCH" — the same words a genuinely disagreeing log gets. Skipped
# when running as root (root ignores file permission bits, so chmod 000
# would not actually deny the read — the assertions below would then see a
# real hash comparison instead of the unreadable branch this fixture exists
# to pin).
# ---------------------------------------------------------------------------
if [ "$(id -u)" -eq 0 ]; then
  echo "SKIP: #601 unreadable-log fixture (running as root, chmod 000 has no effect)" >&2
else
  FIXTURES_UNREADABLE="$WORK/fixtures_unreadable"
  mkdir -p "$FIXTURES_UNREADABLE"
  cp "$FIXTURES/pull.json" "$FIXTURES/checks.json" "$FIXTURES_UNREADABLE/"
  printf 'secret log content\n' > "$LOGS/unreadable.log"
  UNREADABLE_SHA=$(sha256sum "$LOGS/unreadable.log" | awk '{print $1}')
  chmod 000 "$LOGS/unreadable.log"
  cat > "$FIXTURES_UNREADABLE/comments_page1.json" <<JSON
[
  {"body": "## Test Evidence — round 0\n- Command: \`echo hi\`\n- Head SHA: \`$HEAD_SHA\`\n- Exit code: 0\n- Log SHA-256: \`$UNREADABLE_SHA\`\n- Raw log: \`$LOGS/unreadable.log\`\n", "created_at": "2026-07-01T00:00:00Z", "html_url": "https://example.invalid/pr/42#unreadable-1"}
]
JSON
  echo '[]' > "$FIXTURES_UNREADABLE/comments_page2.json"
  echo '[]' > "$FIXTURES_UNREADABLE/comments_page3.json"
  echo '[]' > "$FIXTURES_UNREADABLE/comments_page4.json"

  set +e
  MOCK_GH_FIXTURES="$FIXTURES_UNREADABLE" PATH="$BIN:$PATH" \
    "$PREFLIGHT_SH" "$PR" --repo "$REPO" > "$OUT/unreadable.stdout.log" 2> "$OUT/unreadable.stderr.log"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || report "#601 unreadable log: expected exit 0, got $rc: $(cat "$OUT/unreadable.stderr.log")"
  if jq -e . "$OUT/unreadable.stdout.log" >/dev/null 2>&1; then
    unreadable_round=$(jq -c '.evidence[]|select(.round==0)' "$OUT/unreadable.stdout.log")
    [ -n "$unreadable_round" ] || report "#601: no round-0 manifest found"
    if [ -n "$unreadable_round" ]; then
      [ "$(jq -r '.log_exists' <<<"$unreadable_round")" = "true" ] \
        || report "#601: expected log_exists=true (the file IS on disk, just unreadable), got: $unreadable_round"
      [ "$(jq -r '.log_readable' <<<"$unreadable_round")" = "false" ] \
        || report "#601: expected log_readable=false for a chmod-000 log, got: $unreadable_round"
      [ "$(jq -r '.sha256_match' <<<"$unreadable_round")" = "false" ] \
        || report "#601: expected sha256_match=false (never computed, not a real comparison), got: $unreadable_round"
      [ "$(jq -r '.actual_sha256' <<<"$unreadable_round")" = "null" ] \
        || report "#601: expected actual_sha256=null (sha256sum never ran), got: $unreadable_round"
    fi
  else
    report "#601 unreadable log: stdout is not valid JSON: $(cat "$OUT/unreadable.stdout.log")"
  fi

  set +e
  MOCK_GH_FIXTURES="$FIXTURES_UNREADABLE" PATH="$BIN:$PATH" \
    "$PREFLIGHT_SH" "$PR" --repo "$REPO" --markdown > "$OUT/unreadable.md.stdout.log" 2> "$OUT/unreadable.md.stderr.log"
  rc=$?
  set -e
  chmod 644 "$LOGS/unreadable.log"
  [ "$rc" -eq 0 ] || report "#601 --markdown: expected exit 0, got $rc: $(cat "$OUT/unreadable.md.stderr.log")"
  grep -qF "UNREADABLE (permission denied)" "$OUT/unreadable.md.stdout.log" \
    || report "#601 --markdown: missing 'UNREADABLE (permission denied)' verdict, got: $(cat "$OUT/unreadable.md.stdout.log")"
  ! grep -qF "HASH MISMATCH" "$OUT/unreadable.md.stdout.log" \
    || report "#601 --markdown: an unreadable log must never render as HASH MISMATCH, got: $(cat "$OUT/unreadable.md.stdout.log")"
fi

# ---------------------------------------------------------------------------
# #585: two manifests for the same round, the older naming a log whose
# content has since changed (the legitimate re-run-and-re-post case
# implementer.md and the Evidence rule require after a push), must not both
# report a hash verdict — the older is `superseded`, the newer keeps its real
# verdict. Two rounds pin this from both directions:
#  - round 20: the newer manifest's stated hash matches the (rewritten) file
#    -> "hash OK"; the older's stale hash would mismatch the same file, but
#    must render "superseded (hash not checked)" instead of HASH MISMATCH.
#  - round 21: the newer manifest's stated hash is itself genuinely wrong ->
#    a real HASH MISMATCH must still surface on the newest manifest (AC3) —
#    supersession never launders an actual mismatch on the current round.
# Round-1 relay finding F2: supersession must be scoped to (round, log_path)
# together, never round alone — two same-round manifests naming DIFFERENT,
# untouched logs are never in supersession over each other. Three more
# rounds pin the shapes the reviewer reproduced plus the shape this repo's
# own relay round produces every time:
#  - round 22 (F2 shape a): older names a.log with a genuine mismatch, newer
#    names a DIFFERENT b.log with a real "hash OK" -> neither is superseded;
#    the older's real mismatch must still surface, not be swallowed by the
#    newer manifest's mere timing.
#  - round 23 (F2 shape b): older names a real log with a genuine mismatch,
#    newer states no log path at all (log_path:null) -> the older is still
#    not superseded (its group has one member: itself) and its mismatch must
#    still surface; the newer keeps its own "no path stated" text.
#  - round 1 (relay shape, F2): a pre-relay `test-r1.log` and a post-relay
#    `test-r1-relay.log` — the exact pair this repo's Evidence rule produces
#    on every relayed round — each names its own real, distinct, untouched
#    log with a correct hash. Neither is superseded; both must render "hash
#    OK", the shape a round-alone grouping would have wrongly suppressed on
#    one of them every single time.
# A mutation that reverts EVIDENCE to grouping on `.round` alone (dropping
# `log_path` from the group key) makes every #585/F2 assertion below fail:
# round 22's older manifest and round 23's older manifest would both become
# `superseded` (masking their real mismatches), and one of round 1's two
# manifests would too (masking a real "hash OK").
# ---------------------------------------------------------------------------
FIXTURES_SUPERSEDED="$WORK/fixtures_superseded"
mkdir -p "$FIXTURES_SUPERSEDED"
cp "$FIXTURES/pull.json" "$FIXTURES/checks.json" "$FIXTURES_SUPERSEDED/"
printf 'round 20 rewritten content\n' > "$LOGS/round20.log"
ROUND20_SHA=$(sha256sum "$LOGS/round20.log" | awk '{print $1}')
ROUND20_STALE_SHA="1111111111111111111111111111111111111111111111111111111111111111"
printf 'round 21 rewritten content\n' > "$LOGS/round21.log"
ROUND21_STALE_SHA="2222222222222222222222222222222222222222222222222222222222222222"
ROUND21_WRONG_SHA="3333333333333333333333333333333333333333333333333333333333333333"
# F2 shape a (round 22): two DIFFERENT, untouched logs in one round.
printf 'round 22 log a\n' > "$LOGS/round22a.log"
ROUND22A_WRONG_SHA="4444444444444444444444444444444444444444444444444444444444444444"
printf 'round 22 log b\n' > "$LOGS/round22b.log"
ROUND22B_SHA=$(sha256sum "$LOGS/round22b.log" | awk '{print $1}')
# F2 shape b (round 23): older names a real log with a genuine mismatch,
# newer states no log path at all.
printf 'round 23 log\n' > "$LOGS/round23.log"
ROUND23_WRONG_SHA="5555555555555555555555555555555555555555555555555555555555555555"
# F2 relay shape (round 1 within this isolated fixture set): the exact
# pre-relay/post-relay log pair the Evidence rule produces on every relayed
# round, each a real, distinct, untouched log with a correct hash.
printf 'pre-relay content\n' > "$LOGS/test-r1.log"
TESTR1_SHA=$(sha256sum "$LOGS/test-r1.log" | awk '{print $1}')
printf 'post-relay content\n' > "$LOGS/test-r1-relay.log"
TESTR1RELAY_SHA=$(sha256sum "$LOGS/test-r1-relay.log" | awk '{print $1}')
cat > "$FIXTURES_SUPERSEDED/comments_page1.json" <<JSON
[
  {"body": "## Test Evidence — round 20\n- Command: \`echo r20\`\n- Head SHA: \`$HEAD_SHA\`\n- Exit code: 0\n- Log SHA-256: \`$ROUND20_STALE_SHA\`\n- Raw log: \`$LOGS/round20.log\`\n", "created_at": "2026-08-01T00:00:00Z", "html_url": "https://example.invalid/pr/42#superseded-20-old"},
  {"body": "## Test Evidence — round 20\n- Command: \`echo r20\`\n- Head SHA: \`$HEAD_SHA\`\n- Exit code: 0\n- Log SHA-256: \`$ROUND20_SHA\`\n- Raw log: \`$LOGS/round20.log\`\n", "created_at": "2026-08-01T01:00:00Z", "html_url": "https://example.invalid/pr/42#superseded-20-new"},
  {"body": "## Test Evidence — round 21\n- Command: \`echo r21\`\n- Head SHA: \`$HEAD_SHA\`\n- Exit code: 0\n- Log SHA-256: \`$ROUND21_STALE_SHA\`\n- Raw log: \`$LOGS/round21.log\`\n", "created_at": "2026-08-01T02:00:00Z", "html_url": "https://example.invalid/pr/42#superseded-21-old"},
  {"body": "## Test Evidence — round 21\n- Command: \`echo r21\`\n- Head SHA: \`$HEAD_SHA\`\n- Exit code: 0\n- Log SHA-256: \`$ROUND21_WRONG_SHA\`\n- Raw log: \`$LOGS/round21.log\`\n", "created_at": "2026-08-01T03:00:00Z", "html_url": "https://example.invalid/pr/42#superseded-21-new"},
  {"body": "## Test Evidence — round 22\n- Command: \`echo r22a\`\n- Head SHA: \`$HEAD_SHA\`\n- Exit code: 0\n- Log SHA-256: \`$ROUND22A_WRONG_SHA\`\n- Raw log: \`$LOGS/round22a.log\`\n", "created_at": "2026-08-01T04:00:00Z", "html_url": "https://example.invalid/pr/42#f2-22-a"},
  {"body": "## Test Evidence — round 22\n- Command: \`echo r22b\`\n- Head SHA: \`$HEAD_SHA\`\n- Exit code: 0\n- Log SHA-256: \`$ROUND22B_SHA\`\n- Raw log: \`$LOGS/round22b.log\`\n", "created_at": "2026-08-01T05:00:00Z", "html_url": "https://example.invalid/pr/42#f2-22-b"},
  {"body": "## Test Evidence — round 23\n- Command: \`echo r23\`\n- Head SHA: \`$HEAD_SHA\`\n- Exit code: 0\n- Log SHA-256: \`$ROUND23_WRONG_SHA\`\n- Raw log: \`$LOGS/round23.log\`\n", "created_at": "2026-08-01T06:00:00Z", "html_url": "https://example.invalid/pr/42#f2-23-old"},
  {"body": "## Test Evidence — round 23\n\nNo Raw log bullet, no footer log key at all — the newer manifest never named a path.\n", "created_at": "2026-08-01T07:00:00Z", "html_url": "https://example.invalid/pr/42#f2-23-new"},
  {"body": "## Test Evidence — round 1\n- Command: \`echo pre-relay\`\n- Head SHA: \`$HEAD_SHA\`\n- Exit code: 0\n- Log SHA-256: \`$TESTR1_SHA\`\n- Raw log: \`$LOGS/test-r1.log\`\n", "created_at": "2026-08-01T08:00:00Z", "html_url": "https://example.invalid/pr/42#f2-relay-pre"},
  {"body": "## Test Evidence — round 1 (relay)\n- Command: \`echo post-relay\`\n- Head SHA: \`$HEAD_SHA\`\n- Exit code: 0\n- Log SHA-256: \`$TESTR1RELAY_SHA\`\n- Raw log: \`$LOGS/test-r1-relay.log\`\n", "created_at": "2026-08-01T09:00:00Z", "html_url": "https://example.invalid/pr/42#f2-relay-post"}
]
JSON
echo '[]' > "$FIXTURES_SUPERSEDED/comments_page2.json"
echo '[]' > "$FIXTURES_SUPERSEDED/comments_page3.json"
echo '[]' > "$FIXTURES_SUPERSEDED/comments_page4.json"

set +e
MOCK_GH_FIXTURES="$FIXTURES_SUPERSEDED" PATH="$BIN:$PATH" \
  "$PREFLIGHT_SH" "$PR" --repo "$REPO" > "$OUT/superseded.stdout.log" 2> "$OUT/superseded.stderr.log"
rc=$?
set -e
[ "$rc" -eq 0 ] || report "#585 superseded: expected exit 0, got $rc: $(cat "$OUT/superseded.stderr.log")"
if jq -e . "$OUT/superseded.stdout.log" >/dev/null 2>&1; then
  n_r20=$(jq '[.evidence[]|select(.round==20)]|length' "$OUT/superseded.stdout.log")
  [ "$n_r20" = "2" ] || report "#585: expected 2 manifests for round 20, got $n_r20"
  r20_old=$(jq -c '.evidence[]|select(.round==20 and (.url|endswith("superseded-20-old")))' "$OUT/superseded.stdout.log")
  r20_new=$(jq -c '.evidence[]|select(.round==20 and (.url|endswith("superseded-20-new")))' "$OUT/superseded.stdout.log")
  [ -n "$r20_old" ] || report "#585: no round-20 'old' manifest found"
  [ -n "$r20_new" ] || report "#585: no round-20 'new' manifest found"
  if [ -n "$r20_old" ]; then
    [ "$(jq -r '.superseded' <<<"$r20_old")" = "true" ] \
      || report "#585: expected round-20 old manifest superseded=true, got: $r20_old"
  fi
  if [ -n "$r20_new" ]; then
    [ "$(jq -r '.superseded' <<<"$r20_new")" = "false" ] \
      || report "#585: expected round-20 new (newest) manifest superseded=false, got: $r20_new"
    [ "$(jq -r '.sha256_match' <<<"$r20_new")" = "true" ] \
      || report "#585: expected round-20 newest manifest sha256_match=true (its stated hash matches the rewritten file), got: $r20_new"
  fi

  r21_old=$(jq -c '.evidence[]|select(.round==21 and (.url|endswith("superseded-21-old")))' "$OUT/superseded.stdout.log")
  r21_new=$(jq -c '.evidence[]|select(.round==21 and (.url|endswith("superseded-21-new")))' "$OUT/superseded.stdout.log")
  [ -n "$r21_old" ] || report "#585: no round-21 'old' manifest found"
  [ -n "$r21_new" ] || report "#585: no round-21 'new' manifest found"
  if [ -n "$r21_old" ]; then
    [ "$(jq -r '.superseded' <<<"$r21_old")" = "true" ] \
      || report "#585: expected round-21 old manifest superseded=true, got: $r21_old"
  fi
  if [ -n "$r21_new" ]; then
    # AC3: a genuine mismatch on the newest manifest of a round must still
    # surface as HASH MISMATCH — supersession must never launder a real one.
    [ "$(jq -r '.superseded' <<<"$r21_new")" = "false" ] \
      || report "#585: expected round-21 newest manifest superseded=false, got: $r21_new"
    [ "$(jq -r '.sha256_match' <<<"$r21_new")" = "false" ] \
      || report "#585 (AC3): expected round-21 newest manifest sha256_match=false (its own stated hash is genuinely wrong), got: $r21_new"
  fi

  # F2 shape a (round 22): two manifests naming DIFFERENT logs. Neither is
  # superseded — each is alone in its (round, log_path) group — so the
  # older's real mismatch must still surface and the newer's real match must
  # too.
  r22_a=$(jq -c '.evidence[]|select(.round==22 and (.url|endswith("f2-22-a")))' "$OUT/superseded.stdout.log")
  r22_b=$(jq -c '.evidence[]|select(.round==22 and (.url|endswith("f2-22-b")))' "$OUT/superseded.stdout.log")
  [ -n "$r22_a" ] || report "#585/F2: no round-22 'a' manifest found"
  [ -n "$r22_b" ] || report "#585/F2: no round-22 'b' manifest found"
  if [ -n "$r22_a" ]; then
    [ "$(jq -r '.superseded' <<<"$r22_a")" = "false" ]       || report "#585/F2 shape a: expected round-22 'a' (older, different log than 'b') superseded=false, got: $r22_a"
    [ "$(jq -r '.sha256_match' <<<"$r22_a")" = "false" ]       || report "#585/F2 shape a: expected round-22 'a' sha256_match=false (its own genuine mismatch, never laundered by 'b' being newer), got: $r22_a"
  fi
  if [ -n "$r22_b" ]; then
    [ "$(jq -r '.superseded' <<<"$r22_b")" = "false" ]       || report "#585/F2 shape a: expected round-22 'b' superseded=false, got: $r22_b"
    [ "$(jq -r '.sha256_match' <<<"$r22_b")" = "true" ]       || report "#585/F2 shape a: expected round-22 'b' sha256_match=true, got: $r22_b"
  fi

  # F2 shape b (round 23): older names a real log with a genuine mismatch;
  # newer states no log path at all. The older must not be superseded by a
  # manifest that names no log of its own.
  r23_old=$(jq -c '.evidence[]|select(.round==23 and (.url|endswith("f2-23-old")))' "$OUT/superseded.stdout.log")
  r23_new=$(jq -c '.evidence[]|select(.round==23 and (.url|endswith("f2-23-new")))' "$OUT/superseded.stdout.log")
  [ -n "$r23_old" ] || report "#585/F2: no round-23 'old' manifest found"
  [ -n "$r23_new" ] || report "#585/F2: no round-23 'new' manifest found"
  if [ -n "$r23_old" ]; then
    [ "$(jq -r '.superseded' <<<"$r23_old")" = "false" ]       || report "#585/F2 shape b: expected round-23 'old' (real log, no other manifest shares its path) superseded=false, got: $r23_old"
    [ "$(jq -r '.sha256_match' <<<"$r23_old")" = "false" ]       || report "#585/F2 shape b: expected round-23 'old' sha256_match=false (its own genuine mismatch, never laundered by a path-less newer manifest), got: $r23_old"
  fi
  if [ -n "$r23_new" ]; then
    [ "$(jq -r '.log_path' <<<"$r23_new")" = "null" ]       || report "#585/F2 shape b: expected round-23 'new' log_path=null, got: $r23_new"
  fi

  # F2 relay shape (round 1 in this isolated fixture set): the exact
  # pre-relay/post-relay log pair the Evidence rule produces every time.
  # Neither is superseded by the other's timing — each names its own real,
  # distinct log with a correct hash.
  r1_pre=$(jq -c '.evidence[]|select(.round==1 and (.url|endswith("f2-relay-pre")))' "$OUT/superseded.stdout.log")
  r1_post=$(jq -c '.evidence[]|select(.round==1 and (.url|endswith("f2-relay-post")))' "$OUT/superseded.stdout.log")
  [ -n "$r1_pre" ] || report "#585/F2 relay: no pre-relay round-1 manifest found"
  [ -n "$r1_post" ] || report "#585/F2 relay: no post-relay round-1 manifest found"
  if [ -n "$r1_pre" ]; then
    [ "$(jq -r '.superseded' <<<"$r1_pre")" = "false" ]       || report "#585/F2 relay: expected the pre-relay test-r1.log manifest superseded=false, got: $r1_pre"
    [ "$(jq -r '.sha256_match' <<<"$r1_pre")" = "true" ]       || report "#585/F2 relay: expected the pre-relay test-r1.log manifest sha256_match=true, got: $r1_pre"
  fi
  if [ -n "$r1_post" ]; then
    [ "$(jq -r '.superseded' <<<"$r1_post")" = "false" ]       || report "#585/F2 relay: expected the post-relay test-r1-relay.log manifest superseded=false, got: $r1_post"
    [ "$(jq -r '.sha256_match' <<<"$r1_post")" = "true" ]       || report "#585/F2 relay: expected the post-relay test-r1-relay.log manifest sha256_match=true, got: $r1_post"
  fi
else
  report "#585 superseded: stdout is not valid JSON: $(cat "$OUT/superseded.stdout.log")"
fi

set +e
MOCK_GH_FIXTURES="$FIXTURES_SUPERSEDED" PATH="$BIN:$PATH" \
  "$PREFLIGHT_SH" "$PR" --repo "$REPO" --markdown > "$OUT/superseded.md.stdout.log" 2> "$OUT/superseded.md.stderr.log"
rc=$?
set -e
[ "$rc" -eq 0 ] || report "#585 --markdown: expected exit 0, got $rc: $(cat "$OUT/superseded.md.stderr.log")"
superseded_lines=$(grep -c 'superseded (hash not checked)' "$OUT/superseded.md.stdout.log" || true)
[ "$superseded_lines" = "2" ] \
  || report "#585 --markdown: expected exactly 2 'superseded (hash not checked)' lines (round 20 and round 21 old manifests), got $superseded_lines: $(cat "$OUT/superseded.md.stdout.log")"
grep -qF "HASH MISMATCH" "$OUT/superseded.md.stdout.log" \
  || report "#585 --markdown (AC3): expected round-21's genuine mismatch to still render HASH MISMATCH, got: $(cat "$OUT/superseded.md.stdout.log")"
# The round-20 newest manifest's real "hash OK" verdict must survive
# unchanged alongside the superseded line for its own round (AC2).
round20_lines=$(grep '^  - round 20:' "$OUT/superseded.md.stdout.log" || true)
case "$round20_lines" in
  *"hash OK"*) ;;
  *) report "#585 --markdown (AC2): expected a 'hash OK' line among round 20's manifests, got: $round20_lines" ;;
esac
case "$round20_lines" in
  *"superseded (hash not checked)"*) ;;
  *) report "#585 --markdown: expected a 'superseded (hash not checked)' line among round 20's manifests, got: $round20_lines" ;;
esac
# F2: rounds 22, 23 and 1 (the relay-shape pair) must add NO further
# "superseded" lines — the count above stays exactly 2 (round 20's old +
# round 21's old), never 4 or 5, which is what a round-alone grouping would
# have produced by also superseding one manifest in each of these three.
round22_lines=$(grep '^  - round 22:' "$OUT/superseded.md.stdout.log" || true)
[ "$(printf '%s
' "$round22_lines" | grep -c 'HASH MISMATCH')" = "1" ]   || report "#585/F2 --markdown: expected exactly one HASH MISMATCH line among round 22's manifests, got: $round22_lines"
! printf '%s
' "$round22_lines" | grep -q 'superseded'   || report "#585/F2 --markdown: round 22 (two different logs) must render no 'superseded' line, got: $round22_lines"
round23_lines=$(grep '^  - round 23:' "$OUT/superseded.md.stdout.log" || true)
[ "$(printf '%s
' "$round23_lines" | grep -c 'HASH MISMATCH')" = "1" ]   || report "#585/F2 --markdown: expected exactly one HASH MISMATCH line among round 23's manifests, got: $round23_lines"
! printf '%s
' "$round23_lines" | grep -q 'superseded'   || report "#585/F2 --markdown: round 23 (path-less newer manifest) must render no 'superseded' line, got: $round23_lines"
round1_relay_lines=$(grep '^  - round 1:' "$OUT/superseded.md.stdout.log" || true)
[ "$(printf '%s
' "$round1_relay_lines" | grep -c 'hash OK')" = "2" ]   || report "#585/F2 relay --markdown: expected both round-1 manifests (pre-relay and post-relay logs) to render 'hash OK', got: $round1_relay_lines"
! printf '%s
' "$round1_relay_lines" | grep -q 'superseded'   || report "#585/F2 relay --markdown: the pre-relay/post-relay pair must render no 'superseded' line, got: $round1_relay_lines"

# ---------------------------------------------------------------------------
# #716: an off-vocabulary VERDICT FOOTER — the exact PR #696 shape:
# `"verdict":"changes"` where verdict-rules.md L172-174 requires the
# heading-derived slug `changes_requested` — must not silently under-report
# the round count, and its presence must be reported LOUDLY, not filed as a
# quiet bucket. Isolated single-page fixture set, independent of every run
# above:
#  - comment 1 (earliest): a genuine footer-bearing "changes_requested"
#    verdict — round 1, a real round.
#  - comment 2 (middle): a footer whose `verdict` is the off-vocabulary
#    "changes" (not "changes_requested") — this is PR #696's round-1
#    footer defect reproduced exactly. It must land in
#    unrecognized_verdicts, carrying the RAW value "changes" (not silently
#    coerced to a recognised slug), and must NOT count toward .rounds.
#  - comment 3 (latest): a genuine footer-bearing "approved" verdict —
#    round 2, the second real round.
# The round count in this comment's PRESENCE must be exactly 2 (only the
# two genuine verdicts), proving the off-vocabulary footer does not silently
# eat a round OR silently inflate one — and rounds_is_lower_bound must be
# true, and a WARNING naming comment 2's URL and its exact "changes" value
# must appear on stderr, so a JSON-only caller is not left in the dark.
# ---------------------------------------------------------------------------
FIXTURES_OFFVOCAB="$WORK/fixtures_offvocab"
mkdir -p "$FIXTURES_OFFVOCAB"
cp "$FIXTURES/pull.json" "$FIXTURES/checks.json" "$FIXTURES_OFFVOCAB/"
cat > "$FIXTURES_OFFVOCAB/comments_page1.json" <<JSON
[
  {"body": "<!-- review {\"v\":1,\"round\":1,\"verdict\":\"changes_requested\",\"findings\":[1]} -->\n## PR Review — Changes Requested\n\ngenuine round 1", "created_at": "2026-04-01T00:00:00Z", "html_url": "https://example.invalid/pr/42#offvocab-1"},
  {"body": "<!-- review {\"v\":1,\"round\":2,\"verdict\":\"changes\",\"findings\":[]} -->\n## PR Review — Changes Requested\n\nPR #696's exact defect: footer verdict is the off-vocabulary \"changes\", not \"changes_requested\".", "created_at": "2026-04-02T00:00:00Z", "html_url": "https://example.invalid/pr/42#offvocab-2"},
  {"body": "<!-- review {\"v\":1,\"round\":2,\"verdict\":\"approved\",\"findings\":[]} -->\n## PR Review — Approved\n\ngenuine round 2 (LGTM after the fix round)", "created_at": "2026-04-03T00:00:00Z", "html_url": "https://example.invalid/pr/42#offvocab-3"}
]
JSON
echo '[]' > "$FIXTURES_OFFVOCAB/comments_page2.json"
echo '[]' > "$FIXTURES_OFFVOCAB/comments_page3.json"
echo '[]' > "$FIXTURES_OFFVOCAB/comments_page4.json"

set +e
MOCK_GH_FIXTURES="$FIXTURES_OFFVOCAB" PATH="$BIN:$PATH" \
  "$PREFLIGHT_SH" "$PR" --repo "$REPO" > "$OUT/offvocab.stdout.log" 2> "$OUT/offvocab.stderr.log"
rc=$?
set -e
[ "$rc" -eq 0 ] || report "#716 off-vocab footer: expected exit 0, got $rc: $(cat "$OUT/offvocab.stderr.log")"
if jq -e . "$OUT/offvocab.stdout.log" >/dev/null 2>&1; then
  offvocab_rounds=$(jq -r '.rounds' "$OUT/offvocab.stdout.log")
  [ "$offvocab_rounds" = "2" ] || report "#716: expected rounds=2 (the two genuine verdicts; the off-vocab footer neither eats nor inflates a round), got $offvocab_rounds"
  offvocab_lower=$(jq -r '.rounds_is_lower_bound' "$OUT/offvocab.stdout.log")
  [ "$offvocab_lower" = "true" ] || report "#716: expected rounds_is_lower_bound=true, got $offvocab_lower"
  offvocab_n=$(jq '.unrecognized_verdicts|length' "$OUT/offvocab.stdout.log")
  [ "$offvocab_n" = "1" ] || report "#716: expected exactly 1 unrecognized_verdicts entry, got $offvocab_n"
  offvocab_v=$(jq -r '.unrecognized_verdicts[0].verdict' "$OUT/offvocab.stdout.log")
  [ "$offvocab_v" = "changes" ] || report "#716: expected the RAW off-vocabulary value \"changes\" preserved, got $offvocab_v"
  offvocab_latest=$(jq -r '.latest_verdict.verdict' "$OUT/offvocab.stdout.log")
  [ "$offvocab_latest" = "approved" ] || report "#716: expected latest_verdict=approved (the off-vocab comment must never become latest_verdict), got $offvocab_latest"
else
  report "#716 off-vocab footer: stdout is not valid JSON: $(cat "$OUT/offvocab.stdout.log")"
fi
grep -qE 'WARNING: unrecognized verdict "changes" \(from footer\) on https://example\.invalid/pr/42#offvocab-2 — Review rounds so far \(2\) is a LOWER BOUND' "$OUT/offvocab.stderr.log" \
  || report "#716: expected a loud stderr WARNING naming the comment URL and its raw \"changes\" value, got: $(cat "$OUT/offvocab.stderr.log")"

set +e
MOCK_GH_FIXTURES="$FIXTURES_OFFVOCAB" PATH="$BIN:$PATH" \
  "$PREFLIGHT_SH" "$PR" --repo "$REPO" --markdown > "$OUT/offvocab.md.stdout.log" 2> "$OUT/offvocab.md.stderr.log"
rc=$?
set -e
[ "$rc" -eq 0 ] || report "#716 off-vocab footer --markdown: expected exit 0, got $rc: $(cat "$OUT/offvocab.md.stderr.log")"
grep -qE '^- Review rounds so far: 2 \(LOWER BOUND — see WARNING below, not the true round total\) · latest verdict: approved \(footer\)$' "$OUT/offvocab.md.stdout.log" \
  || report "#716: --markdown 'Review rounds so far' line missing its LOWER BOUND qualifier for a footer-sourced off-vocab entry, got: $(cat "$OUT/offvocab.md.stdout.log")"
grep -qE '^- WARNING: unrecognized verdict \(round count above is a LOWER BOUND, not counted\): 1 \("changes" \(slug changes\) — https://example\.invalid/pr/42#offvocab-2\)$' "$OUT/offvocab.md.stdout.log" \
  || report "#716: --markdown missing the loud WARNING line naming the raw \"changes\" value, got: $(cat "$OUT/offvocab.md.stdout.log")"

# ---------------------------------------------------------------------------
# #716 second trap: the new reporting code (the WARNING line and the JSON
# value it carries) must itself be probed against a verdict spelling it does
# not expect — a guard written to catch off-vocabulary footers can itself
# mishandle an off-vocabulary VALUE. This footer's `verdict` is a pathological
# string: embedded double quotes, a slash, and internal whitespace/hyphens —
# none of `slug()`, the WARNING `echo`, or the JSON round-trip may crash,
# truncate at the embedded quote, or silently coerce it into a recognised
# slug via over-normalization. Isolated single-comment fixture.
# ---------------------------------------------------------------------------
FIXTURES_PATHOLOGICAL="$WORK/fixtures_pathological"
mkdir -p "$FIXTURES_PATHOLOGICAL"
cp "$FIXTURES/pull.json" "$FIXTURES/checks.json" "$FIXTURES_PATHOLOGICAL/"
PATHOLOGICAL_VALUE='changes "requested" / draft-ish'
# Built with jq rather than a hand-escaped heredoc: the footer's own JSON
# (embedded as a string inside the comment body, itself a string inside the
# outer fixture JSON) needs two independent levels of quote-escaping, which a
# hand-typed heredoc gets wrong far too easily — jq computes both levels
# correctly from the raw Bash string.
FOOTER_JSON=$(jq -nc --arg v "$PATHOLOGICAL_VALUE" '{v:1,round:1,verdict:$v,findings:[]}')
BODY=$(printf '<!-- review %s -->\n## PR Review — Changes Requested\n\npathological footer value' "$FOOTER_JSON")
jq -n --arg body "$BODY" --arg u "https://example.invalid/pr/42#pathological-1" --arg c "2026-05-01T00:00:00Z" \
  '[{body:$body, created_at:$c, html_url:$u}]' > "$FIXTURES_PATHOLOGICAL/comments_page1.json"
echo '[]' > "$FIXTURES_PATHOLOGICAL/comments_page2.json"
echo '[]' > "$FIXTURES_PATHOLOGICAL/comments_page3.json"
echo '[]' > "$FIXTURES_PATHOLOGICAL/comments_page4.json"

set +e
MOCK_GH_FIXTURES="$FIXTURES_PATHOLOGICAL" PATH="$BIN:$PATH" \
  "$PREFLIGHT_SH" "$PR" --repo "$REPO" > "$OUT/pathological.stdout.log" 2> "$OUT/pathological.stderr.log"
rc=$?
set -e
[ "$rc" -eq 0 ] || report "#716 pathological spelling: expected exit 0 (must never crash on an unexpected verdict spelling), got $rc: $(cat "$OUT/pathological.stderr.log")"
if jq -e . "$OUT/pathological.stdout.log" >/dev/null 2>&1; then
  path_n=$(jq '.unrecognized_verdicts|length' "$OUT/pathological.stdout.log")
  [ "$path_n" = "1" ] || report "#716 pathological: expected exactly 1 unrecognized_verdicts entry, got $path_n"
  path_v=$(jq -r '.unrecognized_verdicts[0].verdict' "$OUT/pathological.stdout.log")
  [ "$path_v" = "$PATHOLOGICAL_VALUE" ] || report "#716 pathological: expected the raw value preserved byte-for-byte through the JSON round-trip, got: $path_v"
  path_rounds=$(jq -r '.rounds' "$OUT/pathological.stdout.log")
  [ "$path_rounds" = "0" ] || report "#716 pathological: expected rounds=0 (the only comment is unrecognized, not a real round; over-normalization must not slug this into changes_requested), got $path_rounds"
  path_lower=$(jq -r '.rounds_is_lower_bound' "$OUT/pathological.stdout.log")
  [ "$path_lower" = "true" ] || report "#716 pathological: expected rounds_is_lower_bound=true, got $path_lower"
else
  report "#716 pathological spelling: stdout is not valid JSON: $(cat "$OUT/pathological.stdout.log")"
fi
grep -qF 'https://example.invalid/pr/42#pathological-1' "$OUT/pathological.stderr.log" \
  || report "#716 pathological: expected the WARNING line to still name the comment URL despite the pathological verdict value, got: $(cat "$OUT/pathological.stderr.log")"

# ---------------------------------------------------------------------------
# #703: PR class and round cap, computed mechanically from the changed
# paths, recomputed fresh every call. One isolated fixture set, re-used with
# a different files.json per sub-case rather than four separate directories
# — comments/pull/checks never change, only the file list does, which is
# exactly the shape a relay produces on a real PR (same PR, same review
# thread, a later call sees a different diff).
# ---------------------------------------------------------------------------
FIXTURES_CLASS="$WORK/fixtures_class"
mkdir -p "$FIXTURES_CLASS"
cp "$FIXTURES/pull.json" "$FIXTURES/checks.json" "$FIXTURES_CLASS/"
echo '[]' > "$FIXTURES_CLASS/comments_page1.json"
echo '[]' > "$FIXTURES_CLASS/comments_page2.json"
echo '[]' > "$FIXTURES_CLASS/comments_page3.json"
echo '[]' > "$FIXTURES_CLASS/comments_page4.json"

class_of(){ # class_of <label> <files.json-content> <expected-class> <expected-cap>
  local label="$1" content="$2" want_class="$3" want_cap="$4"
  printf '%s' "$content" > "$FIXTURES_CLASS/files.json"
  MOCK_GH_FIXTURES="$FIXTURES_CLASS" PATH="$BIN:$PATH" \
    "$PREFLIGHT_SH" "$PR" --repo "$REPO" > "$OUT/class.stdout.log" 2>"$OUT/class.stderr.log"
  if ! jq -e . "$OUT/class.stdout.log" >/dev/null 2>&1; then
    report "#703 $label: stdout is not valid JSON: $(cat "$OUT/class.stdout.log")"
    return
  fi
  got_class=$(jq -r '.class' "$OUT/class.stdout.log")
  got_cap=$(jq -r '.round_cap' "$OUT/class.stdout.log")
  [ "$got_class" = "$want_class" ] || report "#703 $label: expected class=$want_class, got $got_class"
  [ "$got_cap" = "$want_cap" ] || report "#703 $label: expected round_cap=$want_cap, got $got_cap"
}

class_of "all-doc" '[{"filename":"references/orchestration.md"},{"filename":"README.md"}]' "doc-only" "2"
class_of "all-test" '[{"filename":".claude/skills/github-workflow/tests/test_preflight.sh"},{"filename":"spec/widget_spec.rb"}]' "test-only" "2"
class_of "license-precedence" '[{"filename":"LICENSE.md"}]' "executable-code" "3"
class_of "mixed-test-and-doc" '[{"filename":"tests/test_x.sh"},{"filename":"README.md"}]' "executable-code" "3"
class_of "zero-files" '' "executable-code" "3"
class_of "plain-code" '[{"filename":"scripts/preflight.sh"}]' "executable-code" "3"

# whole-set predicates (#703 Spec 2, round 1): test-only and doc-only are
# independent predicates over the WHOLE changed-path set, not an exclusive
# per-path bucketing tested test-root-before-extension. A path under a test
# root that is ALSO a doc-extension/README* path (tests/README.md) must not
# disqualify the doc-only predicate when every OTHER path is doc-only too —
# this fixture goes RED under a per-path exclusive bucketing that assigns
# tests/README.md to "test" before ever considering its README* extension.
class_of "test-root-and-doc-both-predicates" \
  '[{"filename":"tests/README.md"},{"filename":"docs/guide.md"}]' "doc-only" "2"
# A single path satisfying BOTH the test-only and doc-only predicates must
# not disqualify either one; the whole-set all() reduction checks test-only
# first, so this single-path set pins to test-only — cap 2 either way.
class_of "single-path-satisfies-both-predicates" \
  '[{"filename":"tests/README.md"}]' "test-only" "2"
# README* is case-sensitive (the doc capitalizes it): a lowercase readme.txt
# matches neither the extension list nor the README* glob and falls through
# to executable-code, per orchestration.md's explicit ".txt falls through"
# rule — it must NOT be classed doc-only.
class_of "lowercase-readme-txt-falls-through" \
  '[{"filename":"readme.txt"}]' "executable-code" "3"

# The relay scenario itself: the SAME PR, doc-only before a relay, then a
# relayed commit adds an executable test file — class widens mid-round with
# nothing but a re-run of this same script against the new head noticing it,
# exactly as `orchestration.md` § PR class and round caps now states. Then
# the reverse (narrowing), same mechanism.
class_of "relay-before-widen" '[{"filename":"references/orchestration.md"}]' "doc-only" "2"
class_of "relay-after-widen" '[{"filename":"references/orchestration.md"},{"filename":"tests/test_evidence_single_source.sh"}]' "executable-code" "3"
class_of "relay-before-narrow" '[{"filename":"scripts/preflight.sh"},{"filename":"tests/test_preflight.sh"}]' "executable-code" "3"
class_of "relay-after-narrow" '[{"filename":"references/orchestration.md"}]' "doc-only" "2"

# --markdown renders the class and cap too, not JSON-only.
printf '%s' '[{"filename":"references/orchestration.md"}]' > "$FIXTURES_CLASS/files.json"
MOCK_GH_FIXTURES="$FIXTURES_CLASS" PATH="$BIN:$PATH" \
  "$PREFLIGHT_SH" "$PR" --repo "$REPO" --markdown > "$OUT/class.md.log" 2>"$OUT/class.md.stderr.log"
grep -qE '^- PR class: doc-only \(round cap 2\)' "$OUT/class.md.log" \
  || report "#703 --markdown: missing PR class line, got: $(cat "$OUT/class.md.log")"

# ---------------------------------------------------------------------------
# Argument errors: no PR at all, and an unknown flag, both exit 2 without
# ever reaching the mock (no PATH override — a stray gh call would fail
# outright since the real gh is not authenticated in this sandbox, but we
# check the exit code and message directly rather than relying on that).
# ---------------------------------------------------------------------------
set +e
"$PREFLIGHT_SH" >/dev/null 2>"$OUT/noarg.stderr.log"
rc=$?
set -e
[ "$rc" -eq 2 ] || report "no args: expected exit 2, got $rc"

set +e
"$PREFLIGHT_SH" "$PR" --bogus-flag >/dev/null 2>"$OUT/badflag.stderr.log"
rc=$?
set -e
[ "$rc" -eq 2 ] || report "unknown flag: expected exit 2, got $rc"

# ---------------------------------------------------------------------------
# Hermeticity tripwire (#568, #477): the mock recorded every invocation it
# served, and none of them arrived from a context the harness did not set
# up. Proved load-bearing first, against its own throwaway log: the script
# under test is run with the mock on PATH but WITHOUT MOCK_GH_FIXTURES, and
# the marker must appear.
# ---------------------------------------------------------------------------
TRIPWIRE_LOG="$OUT/tripwire-probe.log"
: > "$TRIPWIRE_LOG"
set +e
env -u MOCK_GH_FIXTURES PATH="$BIN:$PATH" MOCK_GH_CALL_LOG="$TRIPWIRE_LOG" \
  "$PREFLIGHT_SH" "$PR" --repo "$REPO" >/dev/null 2>&1
set -e
grep -q '^UNMOCKED-CONTEXT ' "$TRIPWIRE_LOG" \
  || report "tripwire probe: an unmocked-context gh call was NOT marked — the tripwire is not load-bearing"

[ -s "$MOCK_GH_CALL_LOG" ] \
  || report "hermeticity: the mock recorded zero invocations — the call log is not wired up"
if grep -q '^UNMOCKED-CONTEXT ' "$MOCK_GH_CALL_LOG"; then
  report "hermeticity: a gh call was made from an unmocked context: $(grep -m1 '^UNMOCKED-CONTEXT ' "$MOCK_GH_CALL_LOG")"
fi

if [ "$fail" -ne 0 ]; then
  echo "test_preflight: FAILED" >&2
  exit 1
fi

echo "test_preflight: all assertions passed (repo=$REPO, pr=$PR)"
