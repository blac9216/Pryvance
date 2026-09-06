#!/usr/bin/env bash
# test_history.sh — fixture-driven regression test for history.sh's GraphQL
# rewrite (#201). Follows the mock-`gh` harness conventions from
# github-workflow/tests/README.md (first established in this file and
# test_timeline_classifier.sh): a mocked `gh` on PATH serving fixture JSON
# from a private mktemp scratch dir, refusing any non-GET-shaped call (here:
# any `gh api graphql` whose query text contains a `mutation` operation
# rather than `query` — the meaningful analogue of the REST GET-only
# refusal for a script that only ever POSTs `query { ... }` bodies), and no
# real network call ever reachable. Hermeticity tripwire (per
# tests/README.md and test_preflight.sh's #568 pattern): every invocation is
# logged before anything else happens, and one arriving without
# MOCK_GH_FIXTURES set is recorded as UNMOCKED-CONTEXT instead of silently
# reaching the real, authenticated gh.
#
# Covers:
#  - documented output: one GraphQL page with one merged PR (#501) closing
#    one issue (#301, full-featured: estimate, labels, milestone, parent,
#    cross-reference, review-round finding, metrics comment) and one merged
#    PR (#502) closing nothing produces a full issues.jsonl record for #301
#    only, and a calibration.json/calibration.md aggregate — same record
#    shape history.sh has always produced (AC-2's ≤2-REST-calls-or-GraphQL
#    criterion; here, one GraphQL call for the whole page, zero REST calls,
#    zero repeated `issues/{i}` fetches for parent — AC-3).
#  - failure mode: an unrecognized CLI flag exits 2 without any gh call.
#  - failure mode: --repo absent exits 2 without any gh call (#736: no
#    `gh repo view` fallback). Both negative cases run through
#    run_history_negative, under the same full mock env as the success paths
#    and asserting the call log did not grow, so "without any gh call" is a
#    checked claim and the UNMOCKED-CONTEXT tripwire covers them too
#    (github-workflow/tests/README.md § Negative cases; round-2 finding 3).
#  - AC-6 on the fatal in-loop exits (round-2 finding 1): a run whose page 2
#    fails — the `gh api graphql` call itself, or an unreadable rateLimit on
#    the response — still leaves calibration.md describing the issues.jsonl
#    that exists at exit, headed CUT SHORT, at a documented non-zero code.
#  - AC-4 over an interrupted append (round-2 finding 2): issues.jsonl with a
#    truncated final line is repaired loudly, the dedupe set survives the
#    parse failure (no duplicate records, no line glued onto the fragment),
#    the lost record is re-collected exactly once, and the run exits 0; a
#    malformed line that is not the trailing partial is a named stop at
#    exit 1 pointing at --refresh.
#  - resume (AC-4): a first run whose one page already reports remaining
#    below --min-remaining stops after that page (the rate-guard fixture),
#    writes a resume cursor, and a second run (same --out, no --refresh)
#    resumes from that cursor rather than refetching page 1 — the mock
#    fixture for page 1's cursor is asserted served exactly once across
#    both runs. The combined issues.jsonl carries both records, deduplicated
#    by issue+PR.
#  - rate guard (AC-5): the same first run above proves the stop-before-the-
#    wall path directly: non-zero exit, a partial issues.jsonl, and a
#    calibration.md header reading "PARTIAL — N of M records" with a reset
#    time.
#  - calibration rebuild (AC-6): the second (resuming) run's calibration.md
#    is rebuilt from the two-record file that exists at its exit, not left
#    over from the first run's one-record partial table.
#  - --aggregate-only (AC-7): reruns aggregation on a hand-built
#    issues.jsonl with zero gh calls at all.
#  - an unreadable issues.jsonl is a named stop at exit 1 (round-3 finding
#    R1), never awk's own status 2 wearing this script's "usage error"
#    meaning.
#  - observed parallelism has no silent default (round-2 note 5): a record
#    whose `started` will not parse leaves parallelism.txt EMPTY and the table
#    reading "unavailable", with the failure named on stderr — never a
#    plausible-looking 1.00.
#  - size (round-1 finding 1): size_est comes from the `size:*` label, never
#    the `## Estimate` prose — #301 carries `size:m` while its prose says
#    `Size: L` (expect M), and sibling #302 carries prose `Size: S` with no
#    label (expect null).
#  - a malformed `<!-- metrics -->` footer (round-1 finding 2, found on a
#    real PR by the round-1 live run) costs one field, not the record and
#    not its PR siblings: metrics null, metrics_malformed true.
#  - dropped records are loud (round-1 finding 2): null `labels`/`comments`
#    on one issue node lose neither that record nor its sibling, and a PR
#    node that genuinely fails extraction is named on stderr, counted in
#    completeness.dropped_pr_nodes, and exits 3.
#  - the rate guard fails closed (round-1 finding 3): a null `rateLimit`
#    block, or a non-ISO `resetAt`, stops the run with a named error instead
#    of reading as headroom.
#  - the PARTIAL header counts merged PRs on both sides (round-1 finding 4):
#    page 1 holds one in-window PR closing two issues, so a header counting
#    records against PR totalCount would claim "2 of 2".
#  - stale-reuse guard (round-1 finding 5): a mismatched --repo/--since, or a
#    data file with no provenance at all, stops before any gh call; --refresh
#    rebuilds; the default --out is keyed by repository.
#  - the Issue.parent fallback (round-1 note 6): a schema rejecting the field
#    warns once, retries without it, and completes with parent=null.
#  - the mock's write-verb (mutation) refusal, asserted directly against the
#    mock per tests/README.md's "Adding a new script's test" step 4.
#  - footer rounds are the ONLY source (#289, epic #773 decision B3 as
#    amended): PR #501 carries both a heading-only comment and a
#    footer-bearing comment for the same round, and rounds/findings come
#    from the footer alone (rounds_source "footer"). The `footer` scenario
#    then covers B3 proper — a heading-only PR gets rounds null and no
#    source, is excluded from rounds_p50/first_pass_rate, and the exclusion
#    count reaches stderr, calibration.md's rounds-statistics line and its
#    per-row `rounds n`/`rounds excl.` columns.
#  - first_pass_rate is defined for footer semantics (round-1 finding 1):
#    approved at round 1 with no earlier changes_requested, not the
#    heading-era `rounds==0`, which no footer-sourced record can satisfy.
#    The `footer` scenario pins a non-zero rate (1 of 6 = 17%), so a
#    predicate that renders the statistic a structural 0 fails here. Each
#    of the definition's three clauses is separately load-bearing
#    (round-2 relay finding 1): #1306, #1307 and #1308 each violate exactly
#    one, so replacing any single conjunct with `(true)` fails the suite.
#  - footer extraction takes the LAST WHOLE-LINE candidate and parses each
#    candidate separately (round-1 finding 6): #1301's body quotes a footer
#    example (round 99) before its real one and repeats it indented
#    (round 98) after; #1305's only candidate is malformed JSON and is
#    counted, not swallowed into a fallback.
#  - triage (#289): #302's LabeledEvent timeline item is the triage source
#    when no archived log covers it (triage_source "timeline"); with
#    --logs, a log's `triage` event for #301 wins outright (triage_source
#    "session-log").
#  - --logs (#289): an archived session log supplies #302's metrics
#    (`report`, role implementer) even though #302's own metrics footer is
#    malformed JSON — metrics_source "session-log" — and a --logs directory
#    that does not exist is an argument error (exit 2) before any gh call.
#  - --logs avoids the issue-comments REQUEST, not just a footer parse
#    (round-1 finding 3): with partial coverage the page query carries no
#    issue-level comments sub-selection and a second aliased request fetches
#    only the uncovered issue; with full coverage the run makes exactly one
#    request and fetches no issue comments at all. The mock serves a
#    response shaped to the query, as a real GraphQL server would, so the
#    saving cannot be asserted vacuously.
#  - an UNREADABLE --logs directory is a named exit-2 argument error, never
#    an archive that covered nothing (round-1 finding 5) — `[ -d ]` alone is
#    true at mode 000; and a readable-but-empty archive is reported on
#    stderr, so the two states stay distinguishable.
set -euo pipefail
LANG=C
LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HISTORY_SH="$SCRIPT_DIR/../scripts/history.sh"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/history-test.XXXXXX")"
cleanup(){ rm -rf "$WORK"; }
trap cleanup EXIT

FIXTURES="$WORK/fixtures"
BIN="$WORK/bin"
OUT="$WORK/out"
mkdir -p "$FIXTURES" "$BIN" "$OUT"

REPO="test-org/test-repo"
SINCE="2026-01-01"
ADOPT="2026-01-01"
CALL_LOG="$WORK/calls.log"
: > "$CALL_LOG"

fail=0
report(){ echo "FAIL: $*" >&2; fail=1; }

# ---------------------------------------------------------------------------
# Fixture: one GraphQL page. PR #501 closes issue #301 (full-featured);
# PR #502 closes nothing (closingIssuesReferences empty — the GraphQL
# analogue of "no closing keyword in the body"). remaining=4000 (well above
# the default --min-remaining 1500), hasNextPage=false.
# ---------------------------------------------------------------------------
cat > "$FIXTURES/page_main.json" <<'JSON'
{
  "data": {
    "rateLimit": {"remaining": 4000, "resetAt": "2026-01-11T00:00:00Z"},
    "repository": {
      "pullRequests": {
        "totalCount": 2,
        "pageInfo": {"hasNextPage": false, "endCursor": "END_MAIN"},
        "nodes": [
          {
            "number": 501, "additions": 40, "deletions": 10, "changedFiles": 3,
            "createdAt": "2026-01-01T00:00:00Z", "mergedAt": "2026-01-10T12:00:00Z",
            "headRefName": "301-fix",
            "comments": {"nodes": [
              {"body": "## PR Review — Changes Requested\n\n| # | Severity | Note |\n|---|---|---|\n| 1 | blocker | fix X |\n| 2 | major | fix Y |\n", "createdAt": "2026-01-09T00:00:00Z"},
              {"body": "<!-- review {\"v\":1,\"round\":1,\"verdict\":\"changes_requested\",\"findings\":[{\"id\":\"1\"},{\"id\":\"2\"}]} -->\n## PR Review — Changes Requested\n\nsame round, footer-bearing copy (#289 fixture: a heading-only comment and a footer-bearing comment on the same PR must yield the same round count)", "createdAt": "2026-01-09T00:05:00Z"}
            ]},
            "closingIssuesReferences": {"nodes": [
              {
                "number": 301, "title": "Fix the thing", "state": "CLOSED",
                "createdAt": "2026-01-01T00:00:00Z", "closedAt": "2026-01-10T12:30:00Z",
                "body": "## Estimate\nSize: L\nest. cycle: 6 h\n",
                "labels": {"nodes": [{"name": "area:tests"}, {"name": "bug"}, {"name": "size:m"}, {"name": "severity:major"}, {"name": "priority:p2"}]},
                "milestone": {"title": "M1"},
                "parent": {"number": 200},
                "timelineItems": {"nodes": [
                  {"__typename": "AssignedEvent", "createdAt": "2026-01-02T00:00:00Z"},
                  {"__typename": "CrossReferencedEvent", "createdAt": "2026-01-03T00:00:00Z", "source": {"number": 205}}
                ]},
                "comments": {"nodes": [
                  {"body": "some discussion"},
                  {"body": "<!-- metrics {\"attempts\":2} -->"}
                ]}
              },
              {
                "number": 302, "title": "Prose estimate, no size label", "state": "CLOSED",
                "createdAt": "2026-01-01T00:00:00Z", "closedAt": "2026-01-10T12:30:00Z",
                "body": "## Estimate\nSize: S\nest. cycle: 2 h\n",
                "labels": {"nodes": [{"name": "area:tests"}, {"name": "chore"}]},
                "milestone": null, "parent": null,
                "timelineItems": {"nodes": [
                  {"__typename": "LabeledEvent", "createdAt": "2026-01-01T12:00:00Z"}
                ]},
                "comments": {"nodes": [
                  {"body": "<!-- metrics {not json at all} -->"}
                ]}
              }
            ]}
          },
          {
            "number": 502, "additions": 5, "deletions": 1, "changedFiles": 1,
            "createdAt": "2026-01-02T00:00:00Z", "mergedAt": "2026-01-05T08:00:00Z",
            "headRefName": "cleanup",
            "comments": {"nodes": []},
            "closingIssuesReferences": {"nodes": []}
          }
        ]
      }
    }
  }
}
JSON

# ---------------------------------------------------------------------------
# Fixtures for the resume / rate-guard scenario: two pages under a separate
# --out. Page 1 reports remaining=50 (below --min-remaining 100, the value
# this scenario passes explicitly) and hasNextPage=true — the rate guard
# must stop after processing it, before fetching page 2. Page 2 (served
# only when the cursor "CUR_R1" is passed) reports remaining=4000 and
# hasNextPage=false.
# ---------------------------------------------------------------------------
cat > "$FIXTURES/page_r1.json" <<'JSON'
{
  "data": {
    "rateLimit": {"remaining": 50, "resetAt": "2026-02-01T00:00:00Z"},
    "repository": {
      "pullRequests": {
        "totalCount": 2,
        "pageInfo": {"hasNextPage": true, "endCursor": "CUR_R1"},
        "nodes": [
          {
            "number": 601, "additions": 20, "deletions": 5, "changedFiles": 2,
            "createdAt": "2026-01-01T00:00:00Z", "mergedAt": "2026-01-06T00:00:00Z",
            "headRefName": "401-fix",
            "comments": {"nodes": []},
            "closingIssuesReferences": {"nodes": [
              {
                "number": 401, "title": "First resumed issue", "state": "CLOSED",
                "createdAt": "2026-01-01T00:00:00Z", "closedAt": "2026-01-06T00:00:00Z",
                "body": "", "labels": {"nodes": [{"name": "area:tests"}]},
                "milestone": null, "parent": null,
                "timelineItems": {"nodes": []}, "comments": {"nodes": []}
              },
              {
                "number": 403, "title": "Second issue closed by the same PR", "state": "CLOSED",
                "createdAt": "2026-01-01T00:00:00Z", "closedAt": "2026-01-06T00:00:00Z",
                "body": "", "labels": {"nodes": [{"name": "area:tests"}]},
                "milestone": null, "parent": null,
                "timelineItems": {"nodes": []}, "comments": {"nodes": []}
              }
            ]}
          }
        ]
      }
    }
  }
}
JSON

cat > "$FIXTURES/page_r2.json" <<'JSON'
{
  "data": {
    "rateLimit": {"remaining": 4000, "resetAt": "2026-02-02T00:00:00Z"},
    "repository": {
      "pullRequests": {
        "totalCount": 2,
        "pageInfo": {"hasNextPage": false, "endCursor": "CUR_R2"},
        "nodes": [
          {
            "number": 602, "additions": 8, "deletions": 2, "changedFiles": 1,
            "createdAt": "2026-01-02T00:00:00Z", "mergedAt": "2026-01-07T00:00:00Z",
            "headRefName": "402-fix",
            "comments": {"nodes": []},
            "closingIssuesReferences": {"nodes": [
              {
                "number": 402, "title": "Second resumed issue", "state": "CLOSED",
                "createdAt": "2026-01-02T00:00:00Z", "closedAt": "2026-01-07T00:00:00Z",
                "body": "", "labels": {"nodes": [{"name": "area:tests"}]},
                "milestone": null, "parent": null,
                "timelineItems": {"nodes": []}, "comments": {"nodes": []}
              }
            ]}
          }
        ]
      }
    }
  }
}
JSON


# ---------------------------------------------------------------------------
# Fixture for the record-extraction failure path (finding 2, round 1). Two
# merged PR nodes on one page:
#  - PR #801 closes issue #701, whose `labels` and `comments` are `null`
#    (GitHub renders an inaccessible/absent connection this way), plus a
#    well-formed sibling #702. Both must be recorded: a null connection is
#    not a reason to lose a record, let alone the whole node.
#  - PR #802 carries a malformed `mergedAt`, which no `// []` tolerance can
#    rescue — record extraction genuinely fails. That failure must be LOUD
#    (named on stderr, counted, non-zero exit), never a silent drop at
#    exit 0.
# ---------------------------------------------------------------------------
cat > "$FIXTURES/page_tolerant.json" <<'JSON'
{
  "data": {
    "rateLimit": {"remaining": 4000, "resetAt": "2026-03-01T00:00:00Z"},
    "repository": {
      "pullRequests": {
        "totalCount": 2,
        "pageInfo": {"hasNextPage": false, "endCursor": "END_TOL"},
        "nodes": [
          {
            "number": 801, "additions": 30, "deletions": 10, "changedFiles": 2,
            "createdAt": "2026-01-01T00:00:00Z", "mergedAt": "2026-01-09T00:00:00Z",
            "headRefName": "701-fix",
            "comments": {"nodes": []},
            "closingIssuesReferences": {"nodes": [
              {
                "number": 701, "title": "Null labels and comments", "state": "CLOSED",
                "createdAt": "2026-01-01T00:00:00Z", "closedAt": "2026-01-09T00:00:00Z",
                "body": "", "labels": null,
                "milestone": null, "parent": null,
                "timelineItems": {"nodes": []}, "comments": null
              },
              {
                "number": 702, "title": "Well-formed sibling on the same PR", "state": "CLOSED",
                "createdAt": "2026-01-01T00:00:00Z", "closedAt": "2026-01-09T00:00:00Z",
                "body": "", "labels": {"nodes": [{"name": "area:tests"}, {"name": "size:l"}]},
                "milestone": null, "parent": null,
                "timelineItems": {"nodes": []}, "comments": {"nodes": []}
              }
            ]}
          },
          {
            "number": 802, "additions": 1, "deletions": 0, "changedFiles": 1,
            "createdAt": "2026-01-02T00:00:00Z", "mergedAt": "merged-yesterday",
            "headRefName": "703-fix",
            "comments": {"nodes": []},
            "closingIssuesReferences": {"nodes": [
              {
                "number": 703, "title": "Lost to the malformed PR node", "state": "CLOSED",
                "createdAt": "2026-01-02T00:00:00Z", "closedAt": "2026-01-09T00:00:00Z",
                "body": "", "labels": {"nodes": [{"name": "area:tests"}]},
                "milestone": null, "parent": null,
                "timelineItems": {"nodes": []}, "comments": {"nodes": []}
              }
            ]}
          }
        ]
      }
    }
  }
}
JSON

# ---------------------------------------------------------------------------
# Fixtures for the fail-closed rate guard (finding 3, round 1): a response
# whose `rateLimit` block is null, and one whose `resetAt` is not an ISO
# instant. Both must stop the run with a named error rather than be read as
# headroom. Both pages report hasNextPage=true, so a guard that fails open
# would keep paging (and, in the null case, print "remaining ... : null").
# ---------------------------------------------------------------------------
cat > "$FIXTURES/page_ratenull.json" <<'JSON'
{
  "data": {
    "rateLimit": null,
    "repository": {
      "pullRequests": {
        "totalCount": 1,
        "pageInfo": {"hasNextPage": false, "endCursor": "END_RN"},
        "nodes": [
          {
            "number": 901, "additions": 3, "deletions": 1, "changedFiles": 1,
            "createdAt": "2026-01-01T00:00:00Z", "mergedAt": "2026-01-04T00:00:00Z",
            "headRefName": "801-fix",
            "comments": {"nodes": []},
            "closingIssuesReferences": {"nodes": []}
          }
        ]
      }
    }
  }
}
JSON

cat > "$FIXTURES/page_ratebadreset.json" <<'JSON'
{
  "data": {
    "rateLimit": {"remaining": 4000, "resetAt": "soon"},
    "repository": {
      "pullRequests": {
        "totalCount": 1,
        "pageInfo": {"hasNextPage": false, "endCursor": "END_RB"},
        "nodes": []
      }
    }
  }
}
JSON

# ---------------------------------------------------------------------------
# Fixture for the Issue.parent fallback (note 6, round 1): the response the
# mock serves once the retried query has dropped `parent { number }` — the
# field is simply absent from the issue node, as it would be on an account
# whose schema version lacks it.
# ---------------------------------------------------------------------------
cat > "$FIXTURES/page_noparent.json" <<'JSON'
{
  "data": {
    "rateLimit": {"remaining": 4000, "resetAt": "2026-04-01T00:00:00Z"},
    "repository": {
      "pullRequests": {
        "totalCount": 1,
        "pageInfo": {"hasNextPage": false, "endCursor": "END_NP"},
        "nodes": [
          {
            "number": 1001, "additions": 12, "deletions": 2, "changedFiles": 1,
            "createdAt": "2026-01-01T00:00:00Z", "mergedAt": "2026-01-08T00:00:00Z",
            "headRefName": "1101-fix",
            "comments": {"nodes": []},
            "closingIssuesReferences": {"nodes": [
              {
                "number": 1101, "title": "Collected without Issue.parent", "state": "CLOSED",
                "createdAt": "2026-01-01T00:00:00Z", "closedAt": "2026-01-08T00:00:00Z",
                "body": "", "labels": {"nodes": [{"name": "area:tests"}, {"name": "size:s"}]},
                "milestone": null,
                "timelineItems": {"nodes": []}, "comments": {"nodes": []}
              }
            ]}
          }
        ]
      }
    }
  }
}
JSON

# ---------------------------------------------------------------------------
# Cut-short fixtures (round-2 finding 1, AC-6). page_cut1 is a clean
# single-page run (one merged PR closing one issue, hasNextPage false) that
# leaves a one-record calibration.md behind. page_cut2 is the FIRST page of a
# second run against the same --out: it appends a second record and reports
# hasNextPage true, so the run goes on to a second page that fails — either
# the `gh api graphql` call itself (scenario cutfail) or an unreadable
# rateLimit block on the response (scenario cutbadrate, reusing
# page_ratenull.json). Both are exits that append records and then die, which
# is where the stale table came from.
# ---------------------------------------------------------------------------
cat > "$FIXTURES/page_cut1.json" <<'JSON'
{
  "data": {
    "rateLimit": {"remaining": 4000, "resetAt": "2026-02-01T00:00:00Z"},
    "repository": {
      "pullRequests": {
        "totalCount": 2,
        "pageInfo": {"hasNextPage": false, "endCursor": "END_CUT1"},
        "nodes": [
          {
            "number": 701, "additions": 30, "deletions": 10, "changedFiles": 2,
            "createdAt": "2026-01-01T00:00:00Z", "mergedAt": "2026-01-05T00:00:00Z",
            "headRefName": "501-fix",
            "comments": {"nodes": []},
            "closingIssuesReferences": {"nodes": [
              {
                "number": 501, "title": "Record present before the cut-short run", "state": "CLOSED",
                "createdAt": "2026-01-01T00:00:00Z", "closedAt": "2026-01-05T00:00:00Z",
                "body": "", "labels": {"nodes": [{"name": "area:tests"}]},
                "milestone": null, "parent": null,
                "timelineItems": {"nodes": []}, "comments": {"nodes": []}
              }
            ]}
          }
        ]
      }
    }
  }
}
JSON

cat > "$FIXTURES/page_cut2.json" <<'JSON'
{
  "data": {
    "rateLimit": {"remaining": 4000, "resetAt": "2026-02-01T00:00:00Z"},
    "repository": {
      "pullRequests": {
        "totalCount": 4,
        "pageInfo": {"hasNextPage": true, "endCursor": "CUR_CUT"},
        "nodes": [
          {
            "number": 702, "additions": 60, "deletions": 20, "changedFiles": 4,
            "createdAt": "2026-01-02T00:00:00Z", "mergedAt": "2026-01-07T00:00:00Z",
            "headRefName": "502-fix",
            "comments": {"nodes": []},
            "closingIssuesReferences": {"nodes": [
              {
                "number": 502, "title": "Record appended by the run that then dies", "state": "CLOSED",
                "createdAt": "2026-01-02T00:00:00Z", "closedAt": "2026-01-07T00:00:00Z",
                "body": "", "labels": {"nodes": [{"name": "area:tests"}]},
                "milestone": null, "parent": null,
                "timelineItems": {"nodes": []}, "comments": {"nodes": []}
              }
            ]}
          }
        ]
      }
    }
  }
}
JSON

# ---------------------------------------------------------------------------
# Footer-sourcing fixture (#289 decision B3 as amended, round-1 findings 1,
# 2 and 6). One page, five merged PRs, one closed issue each:
#  - #1201/#1301 — a review comment that QUOTES a footer example (round 99)
#    in prose before emitting its own real footer (round 2), and then closes
#    with the same shape INDENTED inside an appendix (round 98). The real
#    footer is the LAST whole-line one: taking the first (capture()) yields
#    99, and matching without line anchors yields 98. Only "last whole-line
#    match" yields 2.
#  - #1202/#1302 — a heading-only `## PR Review — Changes Requested` comment
#    and no footer at all. Under B3 this is rounds null / rounds_source null,
#    excluded from the rounds statistics and counted in the exclusion — NOT
#    a heading-fallback round count.
#  - #1203/#1303 — one round-1 `approved` footer: the first-pass case. This
#    is the record that makes first_pass_rate non-zero, which the pre-fix
#    `select(.rounds==0)` predicate could not do for any footer-sourced
#    record at all (a review round starts at 1).
#  - #1204/#1304 — round 1 changes_requested then round 2 approved: approved
#    in the end, but NOT first-pass.
#  - #1205/#1305 — a comment whose only whole-line footer candidate is
#    malformed JSON. It must be counted as malformed and leave the PR
#    footer-less (rounds null), never voided into a heading-derived number.
#
# The last three isolate one clause each of `first_pass`'s three-way
# conjunction (round-2 relay finding 1). #1303 satisfies all three clauses
# and #1304 violates all three, so between them no single clause is
# load-bearing; each PR below violates EXACTLY ONE, which is what makes
# replacing that clause with `(true)` fail:
#  - #1206/#1306 — round 1 approved AND round 2 approved, no changes
#    requested anywhere. Only the `$maxround == 1` clause fails. Approved
#    twice is not approved first time.
#  - #1207/#1307 — one round-1 footer whose verdict is neither `approved`
#    nor any of the three rejected ones. Only the round-1-approval clause
#    fails: a verdict this script does not recognise (a future value, or a
#    typo) must never be read as an approval.
#  - #1208/#1308 — two round-1 footers, changes_requested then approved
#    (a within-round relay). Only the no-rejected-verdict clause fails:
#    max round is 1 and round 1 does carry an approval, but changes were
#    requested before it, so this is not a first pass.
# ---------------------------------------------------------------------------
cat > "$FIXTURES/page_footer.json" <<'JSON'
{
  "data": {
    "rateLimit": {"remaining": 4000, "resetAt": "2026-05-01T00:00:00Z"},
    "repository": {
      "pullRequests": {
        "totalCount": 8,
        "pageInfo": {"hasNextPage": false, "endCursor": "END_FOOTER"},
        "nodes": [
          {
            "number": 1201, "additions": 20, "deletions": 4, "changedFiles": 2,
            "createdAt": "2026-01-01T00:00:00Z", "mergedAt": "2026-01-06T00:00:00Z",
            "headRefName": "1301-fix",
            "comments": {"nodes": [
              {"body": "## PR Review — Changes Requested\n\nThe footer this skill emits has the shape\n\n<!-- review {\"v\":1,\"round\":99,\"verdict\":\"approved\",\"findings\":[]} -->\n\nquoted just above as an example. My own verdict follows.\n\n<!-- review {\"v\":1,\"round\":2,\"verdict\":\"changes_requested\",\"findings\":[{\"id\":\"1\"},{\"id\":\"2\"},{\"id\":\"3\"}]} -->\n\nAppendix, the same shape indented inside a list item, which is not a footer:\n\n    <!-- review {\"v\":1,\"round\":98,\"verdict\":\"approved\",\"findings\":[]} -->\n", "createdAt": "2026-01-05T00:00:00Z"}
            ]},
            "closingIssuesReferences": {"nodes": [
              {
                "number": 1301, "title": "Decoy footers in the body", "state": "CLOSED",
                "createdAt": "2026-01-01T00:00:00Z", "closedAt": "2026-01-06T00:00:00Z",
                "body": "", "labels": {"nodes": [{"name": "area:tests"}, {"name": "size:s"}]},
                "milestone": null, "parent": null,
                "timelineItems": {"nodes": []}, "comments": {"nodes": []}
              }
            ]}
          },
          {
            "number": 1202, "additions": 10, "deletions": 2, "changedFiles": 1,
            "createdAt": "2026-01-01T00:00:00Z", "mergedAt": "2026-01-06T00:00:00Z",
            "headRefName": "1302-fix",
            "comments": {"nodes": [
              {"body": "## PR Review — Changes Requested\n\n| # | Severity | Note |\n|---|---|---|\n| 1 | blocker | pre-footer-era review comment, no footer anywhere |\n", "createdAt": "2026-01-05T00:00:00Z"}
            ]},
            "closingIssuesReferences": {"nodes": [
              {
                "number": 1302, "title": "Heading-only review, no footer", "state": "CLOSED",
                "createdAt": "2026-01-01T00:00:00Z", "closedAt": "2026-01-06T00:00:00Z",
                "body": "", "labels": {"nodes": [{"name": "area:tests"}, {"name": "size:s"}]},
                "milestone": null, "parent": null,
                "timelineItems": {"nodes": []}, "comments": {"nodes": []}
              }
            ]}
          },
          {
            "number": 1203, "additions": 15, "deletions": 3, "changedFiles": 1,
            "createdAt": "2026-01-01T00:00:00Z", "mergedAt": "2026-01-06T00:00:00Z",
            "headRefName": "1303-fix",
            "comments": {"nodes": [
              {"body": "## PR Review — Approved\n\nNothing blocking.\n\n<!-- review {\"v\":1,\"round\":1,\"verdict\":\"approved\",\"findings\":[]} -->\n", "createdAt": "2026-01-05T00:00:00Z"}
            ]},
            "closingIssuesReferences": {"nodes": [
              {
                "number": 1303, "title": "Approved at round 1 -- the first-pass case", "state": "CLOSED",
                "createdAt": "2026-01-01T00:00:00Z", "closedAt": "2026-01-06T00:00:00Z",
                "body": "", "labels": {"nodes": [{"name": "area:tests"}, {"name": "size:s"}]},
                "milestone": null, "parent": null,
                "timelineItems": {"nodes": []}, "comments": {"nodes": []}
              }
            ]}
          },
          {
            "number": 1204, "additions": 25, "deletions": 5, "changedFiles": 2,
            "createdAt": "2026-01-01T00:00:00Z", "mergedAt": "2026-01-06T00:00:00Z",
            "headRefName": "1304-fix",
            "comments": {"nodes": [
              {"body": "## PR Review — Changes Requested\n\n<!-- review {\"v\":1,\"round\":1,\"verdict\":\"changes_requested\",\"findings\":[{\"id\":\"1\"},{\"id\":\"2\"}]} -->\n", "createdAt": "2026-01-04T00:00:00Z"},
              {"body": "## PR Review — Approved\n\n<!-- review {\"v\":1,\"round\":2,\"verdict\":\"approved\",\"findings\":[]} -->\n", "createdAt": "2026-01-05T00:00:00Z"}
            ]},
            "closingIssuesReferences": {"nodes": [
              {
                "number": 1304, "title": "Approved at round 2 -- not first-pass", "state": "CLOSED",
                "createdAt": "2026-01-01T00:00:00Z", "closedAt": "2026-01-06T00:00:00Z",
                "body": "", "labels": {"nodes": [{"name": "area:tests"}, {"name": "size:s"}]},
                "milestone": null, "parent": null,
                "timelineItems": {"nodes": []}, "comments": {"nodes": []}
              }
            ]}
          },
          {
            "number": 1206, "additions": 12, "deletions": 3, "changedFiles": 1,
            "createdAt": "2026-01-01T00:00:00Z", "mergedAt": "2026-01-06T00:00:00Z",
            "headRefName": "1306-fix",
            "comments": {"nodes": [
              {"body": "## PR Review — Approved\n\n<!-- review {\"v\":1,\"round\":1,\"verdict\":\"approved\",\"findings\":[]} -->\n", "createdAt": "2026-01-04T00:00:00Z"},
              {"body": "## PR Review — Approved\n\nMerge verification.\n\n<!-- review {\"v\":1,\"round\":2,\"verdict\":\"approved\",\"findings\":[]} -->\n", "createdAt": "2026-01-05T00:00:00Z"}
            ]},
            "closingIssuesReferences": {"nodes": [
              {
                "number": 1306, "title": "Approved at round 1 AND round 2 -- maxround clause", "state": "CLOSED",
                "createdAt": "2026-01-01T00:00:00Z", "closedAt": "2026-01-06T00:00:00Z",
                "body": "", "labels": {"nodes": [{"name": "area:tests"}, {"name": "size:s"}]},
                "milestone": null, "parent": null,
                "timelineItems": {"nodes": []}, "comments": {"nodes": []}
              }
            ]}
          },
          {
            "number": 1207, "additions": 7, "deletions": 2, "changedFiles": 1,
            "createdAt": "2026-01-01T00:00:00Z", "mergedAt": "2026-01-06T00:00:00Z",
            "headRefName": "1307-fix",
            "comments": {"nodes": [
              {"body": "## PR Review\n\n<!-- review {\"v\":1,\"round\":1,\"verdict\":\"not_a_known_verdict\",\"findings\":[]} -->\n", "createdAt": "2026-01-05T00:00:00Z"}
            ]},
            "closingIssuesReferences": {"nodes": [
              {
                "number": 1307, "title": "Round 1, unrecognised verdict -- round-1-approval clause", "state": "CLOSED",
                "createdAt": "2026-01-01T00:00:00Z", "closedAt": "2026-01-06T00:00:00Z",
                "body": "", "labels": {"nodes": [{"name": "area:tests"}, {"name": "size:s"}]},
                "milestone": null, "parent": null,
                "timelineItems": {"nodes": []}, "comments": {"nodes": []}
              }
            ]}
          },
          {
            "number": 1208, "additions": 9, "deletions": 2, "changedFiles": 1,
            "createdAt": "2026-01-01T00:00:00Z", "mergedAt": "2026-01-06T00:00:00Z",
            "headRefName": "1308-fix",
            "comments": {"nodes": [
              {"body": "## PR Review — Changes Requested\n\n<!-- review {\"v\":1,\"round\":1,\"verdict\":\"changes_requested\",\"findings\":[{\"id\":\"1\"}]} -->\n", "createdAt": "2026-01-04T00:00:00Z"},
              {"body": "## PR Review — Approved\n\nRelay fix verified within the same round.\n\n<!-- review {\"v\":1,\"round\":1,\"verdict\":\"approved\",\"findings\":[]} -->\n", "createdAt": "2026-01-05T00:00:00Z"}
            ]},
            "closingIssuesReferences": {"nodes": [
              {
                "number": 1308, "title": "Changes requested then approved, both round 1 -- rejected-verdict clause", "state": "CLOSED",
                "createdAt": "2026-01-01T00:00:00Z", "closedAt": "2026-01-06T00:00:00Z",
                "body": "", "labels": {"nodes": [{"name": "area:tests"}, {"name": "size:s"}]},
                "milestone": null, "parent": null,
                "timelineItems": {"nodes": []}, "comments": {"nodes": []}
              }
            ]}
          },
          {
            "number": 1205, "additions": 5, "deletions": 1, "changedFiles": 1,
            "createdAt": "2026-01-01T00:00:00Z", "mergedAt": "2026-01-06T00:00:00Z",
            "headRefName": "1305-fix",
            "comments": {"nodes": [
              {"body": "## PR Review — Approved\n\n<!-- review {\"v\":1,\"round\":1,\"verdict\":\"approved\",findings:[]} -->\n", "createdAt": "2026-01-05T00:00:00Z"}
            ]},
            "closingIssuesReferences": {"nodes": [
              {
                "number": 1305, "title": "Only footer candidate is malformed JSON", "state": "CLOSED",
                "createdAt": "2026-01-01T00:00:00Z", "closedAt": "2026-01-06T00:00:00Z",
                "body": "", "labels": {"nodes": [{"name": "area:tests"}, {"name": "size:s"}]},
                "milestone": null, "parent": null,
                "timelineItems": {"nodes": []}, "comments": {"nodes": []}
              }
            ]}
          }
        ]
      }
    }
  }
}
JSON

# ---------------------------------------------------------------------------
# Mock gh: routes `gh api graphql -f query=... -F owner=... -F name=... -F
# pageSize=... [-F cursor=...]`. Refuses any query whose text is a mutation
# rather than a query — the GraphQL-shaped analogue of the REST GET-only
# refusal (a `gh api graphql` call is always a POST at the transport level,
# so the write/read boundary for THIS script is the operation type inside
# the query body, not the HTTP verb). Serves page_r1.json unconditionally on
# the first call of the resume scenario, page_r2.json only when cursor
# "CUR_R1" is passed, and page_main.json for every other call.
# ---------------------------------------------------------------------------
cat > "$BIN/gh" <<'MOCKGH'
#!/usr/bin/env bash
set -euo pipefail
: "${MOCK_GH_CALL_LOG:?MOCK_GH_CALL_LOG must be set}"
# The graphql query text embeds real newlines; flatten to spaces so one
# invocation is always exactly one log line (a line-count-based call tally,
# and the cursor= grep below, would otherwise be corrupted by a multi-line
# "$*").
oneline_args=$(printf '%s' "$*" | tr '\n' ' ')
printf 'CALL gh %s\n' "$oneline_args" >> "$MOCK_GH_CALL_LOG"
if [ -z "${MOCK_GH_FIXTURES:-}" ]; then
  printf 'UNMOCKED-CONTEXT gh %s\n' "$oneline_args" >> "$MOCK_GH_CALL_LOG"
  echo "mock gh: invoked with no MOCK_GH_FIXTURES -- unmocked call context" >&2
  exit 1
fi
if [ "${1:-}" != "api" ] || [ "${2:-}" != "graphql" ]; then
  echo "mock gh: unsupported command: $*" >&2
  exit 1
fi
shift 2
query=""
cursor=""
while [ $# -gt 0 ]; do
  case "$1" in
    -f) case "$2" in query=*) query="${2#query=}" ;; esac; shift 2 ;;
    -F) case "$2" in cursor=*) cursor="${2#cursor=}" ;; esac; shift 2 ;;
    *) shift ;;
  esac
done
if printf '%s' "$query" | grep -qiE '(^|[^a-zA-Z_])mutation([^a-zA-Z_]|$)'; then
  echo "mock gh: refusing a mutation-shaped graphql query" >&2
  exit 1
fi
case "${MOCK_GH_SCENARIO:-main}" in
  resume)
    if [ "$cursor" = "CUR_R1" ]; then
      raw="$MOCK_GH_FIXTURES/page_r2.json"
    else
      raw="$MOCK_GH_FIXTURES/page_r1.json"
    fi
    ;;
  tolerant)     raw="$MOCK_GH_FIXTURES/page_tolerant.json" ;;
  cutfirst)     raw="$MOCK_GH_FIXTURES/page_cut1.json" ;;
  cutfail)
    # Page 2's GraphQL call fails outright (a 502 / secondary rate limit).
    # The message deliberately avoids the word "parent", which would trip the
    # Issue.parent retry path instead of the failure path under test.
    if [ "$cursor" = "CUR_CUT" ]; then
      echo "gh: HTTP 502 Bad Gateway (graphql)" >&2
      exit 1
    fi
    raw="$MOCK_GH_FIXTURES/page_cut2.json"
    ;;
  cutbadrate)
    # Page 2 comes back with an unreadable rateLimit block, so the run dies on
    # the fail-closed guard AFTER page 1 has already appended a record.
    if [ "$cursor" = "CUR_CUT" ]; then
      raw="$MOCK_GH_FIXTURES/page_ratenull.json"
    else
      raw="$MOCK_GH_FIXTURES/page_cut2.json"
    fi
    ;;
  ratenull)     raw="$MOCK_GH_FIXTURES/page_ratenull.json" ;;
  ratebadreset) raw="$MOCK_GH_FIXTURES/page_ratebadreset.json" ;;
  noparent)
    # Stand in for an account whose GraphQL schema has no Issue.parent: any
    # query still asking for it is rejected with the real error text, so the
    # script must notice, drop the field and retry. The retried query (no
    # `parent { number }`) is served normally.
    if printf '%s' "$query" | grep -qF 'parent { number }'; then
      echo "GraphQL: Field 'parent' doesn't exist on type 'Issue' (repository.pullRequests.nodes.closingIssuesReferences.nodes.parent)" >&2
      exit 1
    fi
    raw="$MOCK_GH_FIXTURES/page_noparent.json"
    ;;
  footer)       raw="$MOCK_GH_FIXTURES/page_footer.json" ;;
  *)
    raw="$MOCK_GH_FIXTURES/page_main.json" ;;
esac
[ -f "$raw" ] || { echo "mock gh: no fixture: $raw" >&2; exit 1; }

# --logs phase 2 (#289 round-1 finding 3): the aliased follow-up request
# `iN: issue(number: N) { comments }`. Served from the SAME page fixture, so
# the comments the script gets back are exactly the ones the full query would
# have carried — the only difference is that they had to be asked for.
if printf '%s' "$query" | grep -q 'issue(number:'; then
  nums=$(printf '%s' "$query" | grep -oE 'issue\(number: [0-9]+\)' | grep -oE '[0-9]+' | jq -R . | jq -s -c 'map(tonumber)')
  jq -c --argjson nums "$nums" '
    { data: { rateLimit: .data.rateLimit,
              repository: ([ .data.repository.pullRequests.nodes[]?
                             | (.closingIssuesReferences.nodes // [])[]?
                             | select(.number != null and (.number as $n | $nums | index($n) | . != null))
                             | {key: ("i" + (.number|tostring)),
                                value: {number: .number, comments: (.comments // {nodes:[]})}} ]
                           | from_entries) } }' "$raw"
  exit 0
fi

# A real GraphQL server returns only the fields the query selected. The LIGHT
# page query omits the issue-level comments sub-selection, so the response
# must omit it too — otherwise a --logs run would still receive every issue
# comment and the fixtures asserting the saving would be vacuous. The
# sub-selection is recognised by its own GraphQL SHAPE, never by any marker
# comment history.sh happens to write next to it: a mock that keys off the
# implementation cannot tell a script that made the saving from one that did
# not. The PR-level line selects `body createdAt` and so does not match.
if printf '%s' "$query" | grep -qF 'comments(first: 100) { nodes { body } }'; then
  cat "$raw"
else
  jq -c 'if (.data.repository.pullRequests.nodes | type) == "array"
         then .data.repository.pullRequests.nodes |= map(
                .closingIssuesReferences.nodes |= ((. // []) | map(del(.comments))))
         else . end' "$raw"
fi
MOCKGH
chmod +x "$BIN/gh"

# ---------------------------------------------------------------------------
# Failure modes that must never call gh at all (round-2 finding 3).
#
# These run under the FULL mock env, exactly as run_history does, and assert
# the call log is unchanged across each — per github-workflow/tests/README.md
# § Negative cases: "a case that passes only because a guard fires before the
# first `gh` call stops being hermetic the moment that guard regresses, and
# then the real, authenticated `gh` runs. Route every negative case through
# one helper that sets the mock env ... and back it with a tripwire". Without
# the mock on PATH the UNMOCKED-CONTEXT tripwire cannot fire on these paths
# and the header's "without any gh call" claim is unchecked; with it, a
# regression that moves a `gh` call ahead of the guard fails here rather than
# reaching the network.
# ---------------------------------------------------------------------------
NEG_RC=0
run_history_negative(){ # label, then history.sh args
  local label="$1"; shift
  local before after rc=0
  before=$(grep -c "^CALL gh " "$CALL_LOG" || true)
  set +e
  MOCK_GH_FIXTURES="$FIXTURES" MOCK_GH_CALL_LOG="$CALL_LOG" MOCK_GH_SCENARIO=main \
    PATH="$BIN:$PATH" \
    "$HISTORY_SH" "$@" >"$OUT/$label.stdout.log" 2>"$OUT/$label.stderr.log"
  rc=$?
  set -e
  after=$(grep -c "^CALL gh " "$CALL_LOG" || true)
  [ "$before" = "$after" ] \
    || report "$label: expected zero gh calls, but the call log grew by $((after - before)): $(awk -v n="$before" 'NR>n' "$CALL_LOG" | head -1)"
  NEG_RC=$rc
  return 0
}

run_history_negative badflag --bogus-flag
[ "$NEG_RC" -eq 2 ] || report "unknown-flag: expected exit 2, got $NEG_RC"
grep -qF "unknown arg --bogus-flag" "$OUT/badflag.stderr.log" \
  || report "unknown-flag: expected 'unknown arg' message on stderr, got: $(cat "$OUT/badflag.stderr.log")"

run_history_negative norepo --since "$SINCE" --out "$OUT/norepo"
[ "$NEG_RC" -eq 2 ] || report "--repo absent: expected exit 2, got $NEG_RC"
grep -qF -- "--repo is required" "$OUT/norepo.stderr.log" \
  || report "--repo absent: expected '--repo is required' message on stderr, got: $(cat "$OUT/norepo.stderr.log")"

# ---------------------------------------------------------------------------
# Mock write-verb (mutation) refusal, asserted directly against the mock
# (tests/README.md's "Adding a new script's test" step 4).
# ---------------------------------------------------------------------------
set +e
MOCK_GH_FIXTURES="$FIXTURES" MOCK_GH_CALL_LOG="$CALL_LOG" MOCK_GH_SCENARIO=main \
  PATH="$BIN:$PATH" gh api graphql -f query='mutation { doSomething }' >/dev/null 2>"$OUT/mutation.stderr.log"
rc=$?
set -e
[ "$rc" -ne 0 ] || report "mock: expected a mutation-shaped query to be refused"
grep -qF "refusing a mutation-shaped graphql query" "$OUT/mutation.stderr.log" \
  || report "mock: expected the mutation-refusal message, got: $(cat "$OUT/mutation.stderr.log")"

# ---------------------------------------------------------------------------
# Run history.sh under test against the main-scenario fixture. Crash-path
# diagnostics: dump captured stdout/stderr before returning non-zero.
# ---------------------------------------------------------------------------
run_history(){
  # Callers wrap every invocation in their own `set +e ... ; rc=$? ; set -e`
  # (errexit must already be off) — toggling `set -e`/`set +e` in here too
  # would leak process-wide the moment `set -e` runs before this function's
  # own `return` executes, aborting the *caller's* still-in-flight `set +e`
  # command instead of letting it capture `$?` normally.
  local scenario="$1" out_dir="$2"; shift 2
  local rc=0
  MOCK_GH_FIXTURES="$FIXTURES" MOCK_GH_CALL_LOG="$CALL_LOG" MOCK_GH_SCENARIO="$scenario" PATH="$BIN:$PATH" \
    "$HISTORY_SH" --repo "$REPO" --since "$SINCE" --adoption-date "$ADOPT" --out "$out_dir" "$@" \
    > "$out_dir.stdout.log" 2> "$out_dir.stderr.log"
  rc=$?
  # 0 (clean), 1 (rate-guard stop / fatal collection error) and 3 (records
  # dropped) are all outcomes scenarios below assert deliberately; anything
  # else is a crash worth dumping.
  if [ "$rc" -gt 3 ]; then
    echo "run_history: $HISTORY_SH exited $rc" >&2
    echo "--- stdout ($out_dir.stdout.log) ---" >&2
    cat "$out_dir.stdout.log" >&2 || true
    echo "--- stderr ($out_dir.stderr.log) ---" >&2
    cat "$out_dir.stderr.log" >&2 || true
  fi
  return "$rc"
}

mkdir -p "$OUT/run"
set +e
run_history main "$OUT/run"
rc=$?
set -e
[ "$rc" -eq 0 ] || report "main scenario: expected exit 0, got $rc"

ISSUES_JSONL="$OUT/run/issues.jsonl"
CALIBRATION_JSON="$OUT/run/calibration.json"
CALIBRATION_MD="$OUT/run/calibration.md"

for f in "$ISSUES_JSONL" "$CALIBRATION_JSON" "$CALIBRATION_MD"; do
  [ -s "$f" ] || report "missing or empty output: $f"
done

n502=$(jq -s '[.[]|select(.pr==502)]|length' <"$ISSUES_JSONL" 2>/dev/null || echo error)
[ "$n502" = "0" ] || report "PR #502 (no closing issues): expected 0 records, got $n502"

rec=$(jq -c 'select(.issue==301)' "$ISSUES_JSONL")
[ -n "$rec" ] || report "no record emitted for issue #301"

if [ -n "$rec" ]; then
  check_eq(){ # field jq_path expected
    local field="$1" path="$2" want="$3" got
    got=$(jq -r "$path" <<<"$rec")
    [ "$got" = "$want" ] || report "issue #301: expected $field=$want, got $got"
  }
  check_eq pr           .pr            501
  check_eq type          .type          bug
  check_eq areas         '.areas|join(",")' "area:tests"
  check_eq severity      .severity      "severity:major"
  check_eq priority      .priority      "priority:p2"
  check_eq milestone     .milestone     M1
  check_eq parent        .parent        200
  check_eq start_source  .start_source  assigned
  check_eq started       .started       "2026-01-02T00:00:00Z"
  check_eq cycle_hours   .cycle_hours   204
  check_eq cycle_days    .cycle_days    8.5
  # #289: PR #501 carries BOTH a heading-only comment (pre-footer style) and
  # a footer-bearing comment for the same round. The footer is authoritative
  # whenever present, so rounds/findings come from it alone (rounds_source
  # "footer") — a PR with both must yield the SAME round count as one with
  # only the footer.
  check_eq rounds        .rounds        1
  check_eq rounds_source .rounds_source footer
  check_eq findings      '.findings|join(",")' 2
  check_eq additions     .additions     40
  check_eq deletions     .deletions     10
  check_eq net_loc       .net_loc       30
  # The label (size:m) wins over the prose (## Estimate / Size: L) — the
  # prose must not reach size_est at all (#734 / #201 scope note B4).
  check_eq size_est      .size_est      "M"
  check_eq metrics       '.metrics.attempts' 2
  check_eq metrics_source .metrics_source footer
  check_eq deferred      '.deferred|join(",")' 205
  check_eq era           .era           post-adoption
  # #289: no --logs and no LabeledEvent/MilestonedEvent in #301's timeline
  # fixture -> triage is unknown, not guessed.
  check_eq triage_source .triage_source null
  check_eq triage_at     .triage_at     null

  got_est=$(jq -r '.estimate_text' <<<"$rec")
  case "$got_est" in
    *"Size: L"*"est. cycle: 6 h"*) ;;
    *) report "issue #301: expected estimate_text to keep the raw prose ('Size: L', 'est. cycle: 6 h'), got: $got_est" ;;
  esac
fi

# Sibling issue #302 on the same PR: `## Estimate` prose says Size: S but the
# issue carries no size:* label, so size_est must be null — the prose is
# never read for size.
rec302=$(jq -c 'select(.issue==302)' "$ISSUES_JSONL")
[ -n "$rec302" ] || report "no record emitted for issue #302 (second closing issue on PR #501)"
if [ -n "$rec302" ]; then
  got=$(jq -r '.size_est' <<<"$rec302")
  [ "$got" = "null" ] \
    || report "issue #302 (## Estimate prose 'Size: S', no size:* label): expected size_est=null, got $got"
  got=$(jq -r '.estimate_text' <<<"$rec302")
  case "$got" in
    *"Size: S"*) ;;
    *) report "issue #302: expected estimate_text to still carry the raw prose, got: $got" ;;
  esac
  # #302's metrics footer is malformed JSON: the record survives, the field
  # is null, and the malformation is visible rather than silent.
  got=$(jq -r '.metrics' <<<"$rec302")
  [ "$got" = "null" ] || report "issue #302 (malformed metrics footer): expected metrics=null, got $got"
  got=$(jq -r '.metrics_malformed' <<<"$rec302")
  [ "$got" = "true" ] || report "issue #302 (malformed metrics footer): expected metrics_malformed=true, got $got"
  # #289: no --logs cover #302, so triage falls back to its own
  # LabeledEvent timeline item (the fixture's only timelineItems entry).
  got=$(jq -r '.triage_source' <<<"$rec302")
  [ "$got" = "timeline" ] || report "issue #302 (LabeledEvent, no --logs): expected triage_source=timeline, got $got"
  got=$(jq -r '.triage_at' <<<"$rec302")
  [ "$got" = "2026-01-01T12:00:00Z" ] || report "issue #302: expected triage_at=2026-01-01T12:00:00Z, got $got"
fi
rec301_mm=$(jq -r 'select(.issue==301)|.metrics_malformed' "$ISSUES_JSONL" 2>/dev/null || echo error)
[ "$rec301_mm" = "false" ] \
  || report "issue #301 (well-formed metrics footer): expected metrics_malformed=false, got $rec301_mm"

completeness=$(jq -c '.completeness' "$CALIBRATION_JSON")
want_completeness='{"with_assigned_start":1,"with_estimate":1,"with_metrics":1,"metrics_from_logs":0,"malformed_metrics":1,"with_area":2,"with_footer_rounds":2,"without_footer_rounds":0,"malformed_review_footers":0,"first_pass_records":0,"with_triage":1,"triage_from_logs":0,"dropped_pr_nodes":0,"total":2}'
[ "$completeness" = "$want_completeness" ] || report "calibration.json completeness: expected $want_completeness, got $completeness"

area_row=$(jq -c --arg size "M" '.by_area_size[]|select(.area=="area:tests" and .size==$size)' "$CALIBRATION_JSON")
[ -n "$area_row" ] || report "calibration.json: expected a by_area_size row for area:tests, got none"

grep -qF "area:tests" "$CALIBRATION_MD" || report "calibration.md: expected the area:tests row in the table"
grep -qF "PARTIAL" "$CALIBRATION_MD" && report "calibration.md (full run): unexpectedly carries a PARTIAL header"

# ---------------------------------------------------------------------------
# --logs (#289): an archived session log naming issue #301 (a `triage`
# event) and issue #302 (a `report` event, role implementer) supplies
# metrics/triage WITHOUT needing #302's metrics footer read at all — #302's
# footer is malformed JSON (asserted above), yet with --logs its `metrics`
# is still populated, sourced from the log instead. Same GraphQL fixture
# (MOCK_GH_SCENARIO=main) as the run above; only --logs is new.
# ---------------------------------------------------------------------------
LOGS_DIR="$WORK/logs"
mkdir -p "$LOGS_DIR"
cat > "$LOGS_DIR/session1.jsonl" <<'JSONL'
{"ts":"2026-01-05T00:00:00Z","event":"triage","claim":"test-01","issue":301,"decision":"homed to milestone M1, no epic parent","applied":["milestone:M1"]}
{"ts":"2026-01-09T00:00:00Z","event":"report","role":"implementer","agent":"a1","model":"sonnet","issue":302,"pr":501,"tokens":12345,"duration_s":3600,"outcome":"merged"}
JSONL
mkdir -p "$OUT/withlogs"
calls_before_wl=$(grep -c "^CALL gh " "$CALL_LOG" || true)
set +e
run_history main "$OUT/withlogs" --logs "$LOGS_DIR"
rc=$?
set -e
[ "$rc" -eq 0 ] || report "--logs scenario: expected exit 0, got $rc"
WITHLOGS_JSONL="$OUT/withlogs/issues.jsonl"
wl_calls=$(awk -v n="$calls_before_wl" 'NR>n' "$CALL_LOG")

rec301_log=$(jq -c 'select(.issue==301)' "$WITHLOGS_JSONL")
[ -n "$rec301_log" ] || report "--logs scenario: no record emitted for issue #301"
if [ -n "$rec301_log" ]; then
  got=$(jq -r '.triage_source' <<<"$rec301_log")
  [ "$got" = "session-log" ] || report "--logs scenario, issue #301: expected triage_source=session-log, got $got"
  got=$(jq -r '.triage_at' <<<"$rec301_log")
  [ "$got" = "2026-01-05T00:00:00Z" ] || report "--logs scenario, issue #301: expected triage_at=2026-01-05T00:00:00Z, got $got"
  got=$(jq -r '.triage_decision' <<<"$rec301_log")
  [ "$got" = "homed to milestone M1, no epic parent" ] || report "--logs scenario, issue #301: expected triage_decision to be recorded, got $got"
fi

rec302_log=$(jq -c 'select(.issue==302)' "$WITHLOGS_JSONL")
[ -n "$rec302_log" ] || report "--logs scenario: no record emitted for issue #302"
if [ -n "$rec302_log" ]; then
  got=$(jq -r '.metrics_source' <<<"$rec302_log")
  [ "$got" = "session-log" ] || report "--logs scenario, issue #302 (malformed footer): expected metrics_source=session-log, got $got"
  got=$(jq -r '.metrics.tokens' <<<"$rec302_log")
  [ "$got" = "12345" ] || report "--logs scenario, issue #302: expected metrics.tokens=12345 from the log, got $got"
  got=$(jq -r '.metrics.outcome' <<<"$rec302_log")
  [ "$got" = "merged" ] || report "--logs scenario, issue #302: expected metrics.outcome=merged from the log, got $got"
fi

completeness_logs=$(jq -c '.completeness' "$OUT/withlogs/calibration.json")
metrics_from_logs=$(jq -r '.metrics_from_logs' <<<"$completeness_logs")
[ "$metrics_from_logs" = "1" ] || report "--logs scenario: expected completeness.metrics_from_logs=1, got $metrics_from_logs"
triage_from_logs=$(jq -r '.triage_from_logs' <<<"$completeness_logs")
[ "$triage_from_logs" = "1" ] || report "--logs scenario: expected completeness.triage_from_logs=1, got $triage_from_logs"

# ---------------------------------------------------------------------------
# --logs must avoid the issue-comments REQUEST, not merely a footer parse
# (#289's "fixture archived log yields metrics without the comments call";
# round-1 finding 3). The archive above covers #302's metrics but not #301's,
# so this page is PARTIALLY covered:
#  - the page query must be the LIGHT variant, carrying no issue-level
#    comments sub-selection at all (the mock serves a response shaped to
#    match, exactly as a real GraphQL server would);
#  - a second, aliased request must fetch the comments of the UNCOVERED
#    issue #301 only, and must not ask for covered #302's;
#  - #301's metrics must still come from its own footer, which proves that
#    second request really carried the comments rather than the run quietly
#    recording "no footer".
# ---------------------------------------------------------------------------
wl_call_n=$(printf '%s\n' "$wl_calls" | grep -c "^CALL gh " || true)
[ "$wl_call_n" -eq 2 ] \
  || report "--logs (partial coverage): expected 2 gh calls (one light page request + one comments request for the uncovered issue), got $wl_call_n: $wl_calls"
wl_page_call=$(printf '%s\n' "$wl_calls" | grep -m1 "pullRequests" || true)
[ -n "$wl_page_call" ] || report "--logs: no page request found in the call log: $wl_calls"
case "$wl_page_call" in
  *'comments(first: 100) { nodes { body } }'*) report "--logs: the page query still requests the issue-level comments sub-selection, so the flag avoids no API work at all (round-1 finding 3)" ;;
esac
wl_ic_call=$(printf '%s\n' "$wl_calls" | grep -m1 "issue(number:" || true)
[ -n "$wl_ic_call" ] \
  || report "--logs: expected a follow-up request fetching the uncovered issue's comments, got: $wl_calls"
case "$wl_ic_call" in
  *"issue(number: 301)"*) ;;
  *) report "--logs: the follow-up request must fetch UNCOVERED issue #301's comments, got: $wl_ic_call" ;;
esac
case "$wl_ic_call" in
  *"issue(number: 302)"*) report "--logs: the follow-up request also fetched COVERED issue #302's comments — the archive already carries its metrics, so requesting them is the waste this flag exists to avoid" ;;
esac
# The merge back into the page response is load-bearing: without it #301
# would look like an issue with no metrics footer.
got=$(jq -r 'select(.issue==301)|.metrics_source' "$WITHLOGS_JSONL")
[ "$got" = "footer" ] \
  || report "--logs (partial coverage), issue #301: expected metrics_source=footer from the separately-fetched comments, got $got"
got=$(jq -r 'select(.issue==301)|.metrics.attempts' "$WITHLOGS_JSONL")
[ "$got" = "2" ] \
  || report "--logs (partial coverage), issue #301: expected metrics.attempts=2 from the separately-fetched comments, got $got"

# Full coverage: an archive naming BOTH issues on the page. Now no issue
# comments are needed at all, so the run must cost ONE request and fetch no
# comments — the case #289's Verification bullet names.
LOGS_ALL="$WORK/logs-all"
mkdir -p "$LOGS_ALL"
cat > "$LOGS_ALL/session-all.jsonl" <<'JSONL'
{"ts":"2026-01-05T00:00:00Z","event":"triage","claim":"test-01","issue":301,"decision":"homed to milestone M1","applied":["milestone:M1"]}
{"ts":"2026-01-09T00:00:00Z","event":"report","role":"implementer","agent":"a1","model":"sonnet","issue":301,"pr":501,"tokens":11111,"duration_s":1800,"outcome":"merged"}
{"ts":"2026-01-09T00:00:00Z","event":"report","role":"implementer","agent":"a1","model":"sonnet","issue":302,"pr":501,"tokens":12345,"duration_s":3600,"outcome":"merged"}
JSONL
mkdir -p "$OUT/logsall"
calls_before_la=$(grep -c "^CALL gh " "$CALL_LOG" || true)
set +e
run_history main "$OUT/logsall" --logs "$LOGS_ALL"
rc=$?
set -e
[ "$rc" -eq 0 ] || report "--logs (full coverage): expected exit 0, got $rc (stderr: $(cat "$OUT/logsall.stderr.log"))"
la_calls=$(awk -v n="$calls_before_la" 'NR>n' "$CALL_LOG")
la_call_n=$(printf '%s\n' "$la_calls" | grep -c "^CALL gh " || true)
[ "$la_call_n" -eq 1 ] \
  || report "--logs (full coverage): expected exactly 1 gh call — the archive covers every issue on the page, so no comments request is needed — got $la_call_n: $la_calls"
printf '%s\n' "$la_calls" | grep -q "issue(number:" \
  && report "--logs (full coverage): the run still fetched issue comments although the archive covered every issue (round-1 finding 3)"
case "$la_calls" in
  *'comments(first: 100) { nodes { body } }'*) report "--logs (full coverage): the page query still carried the issue-level comments sub-selection" ;;
esac
grep -qF "covers every issue on this page" "$OUT/logsall.stderr.log" \
  || report "--logs (full coverage): expected the run to say it fetched no issue comments, got: $(cat "$OUT/logsall.stderr.log")"
for n in 301 302; do
  got=$(jq -r "select(.issue==$n)|.metrics_source" "$OUT/logsall/issues.jsonl")
  [ "$got" = "session-log" ] || report "--logs (full coverage), issue #$n: expected metrics_source=session-log, got $got"
done

# The saving is conditional on coverage, not on the flag: without --logs the
# SAME page is fetched with the issue-comments sub-selection in one call.
nolog_page_call=$(grep "^CALL gh " "$CALL_LOG" | grep -m1 "pullRequests" || true)
case "$nolog_page_call" in
  *'comments(first: 100) { nodes { body } }'*) ;;
  *) report "without --logs the page query should still request issue comments (there is no other source for the metrics footer), got: $nolog_page_call" ;;
esac

# --logs pointed at a directory that does not exist is an argument error
# (exit 2), before any gh call.
run_history_negative nologsdir --repo "$REPO" --logs "$WORK/no-such-logs-dir"
[ "$NEG_RC" -eq 2 ] || report "--logs missing dir: expected exit 2, got $NEG_RC"
grep -qF -- "--logs directory not found" "$OUT/nologsdir.stderr.log" \
  || report "--logs missing dir: expected the 'directory not found' message, got: $(cat "$OUT/nologsdir.stderr.log")"

# ---------------------------------------------------------------------------
# An UNREADABLE --logs directory is a named argument error, never an archive
# that covered nothing (round-1 finding 5). `[ -d ]` is true for a chmod 000
# directory whose parent is traversable, so the pre-fix guard did not fire,
# the `*.jsonl` glob expanded to nothing, and the run was byte-identical to
# one whose archive matched no issue — silently. Under the FULL mock env via
# run_history_negative, so the stop is also asserted to precede any gh call.
# ---------------------------------------------------------------------------
UNREADABLE_LOGS="$WORK/logs-unreadable"
mkdir -p "$UNREADABLE_LOGS"
cp "$LOGS_DIR/session1.jsonl" "$UNREADABLE_LOGS/session1.jsonl"
chmod 000 "$UNREADABLE_LOGS"
if [ -r "$UNREADABLE_LOGS" ] && [ -x "$UNREADABLE_LOGS" ]; then
  # root (or an ACL) ignores mode 000, so the case cannot be staged; say so
  # loudly rather than passing vacuously.
  echo "SKIP: unreadable --logs directory case — the directory is still readable at mode 000 (running as uid $(id -u)?)" >&2
else
  run_history_negative unreadablelogs --repo "$REPO" --out "$OUT/unreadablelogs" --logs "$UNREADABLE_LOGS"
  [ "$NEG_RC" -eq 2 ] \
    || report "--logs unreadable dir: expected exit 2, got $NEG_RC (an unreadable archive must never read as an empty one)"
  grep -qF -- "--logs directory is not readable" "$OUT/unreadablelogs.stderr.log" \
    || report "--logs unreadable dir: expected a named 'not readable' error, got: $(cat "$OUT/unreadablelogs.stderr.log")"
  grep -qF "$UNREADABLE_LOGS" "$OUT/unreadablelogs.stderr.log" \
    || report "--logs unreadable dir: the error must name the directory, got: $(cat "$OUT/unreadablelogs.stderr.log")"
fi
chmod 755 "$UNREADABLE_LOGS"

# A readable --logs directory holding no event lines is reported too, so
# "the archive covered nothing" stays distinguishable from "I could not read
# the archive" (the pair of states finding 5 is about).
EMPTY_LOGS="$WORK/logs-empty"
mkdir -p "$EMPTY_LOGS"
: > "$EMPTY_LOGS/empty.jsonl"
mkdir -p "$OUT/emptylogs"
set +e
run_history main "$OUT/emptylogs" --logs "$EMPTY_LOGS"
rc=$?
set -e
[ "$rc" -eq 0 ] || report "--logs empty archive: expected exit 0, got $rc"
grep -qF "hold no event lines" "$OUT/emptylogs.stderr.log" \
  || report "--logs empty archive: expected a warning that the archive is readable but empty, got: $(cat "$OUT/emptylogs.stderr.log")"

# ---------------------------------------------------------------------------
# Footer sourcing under decision B3 as amended (#289; round-1 findings 1, 2
# and 6). Five PRs, five records — see the page_footer.json comment above for
# what each one stages.
# ---------------------------------------------------------------------------
mkdir -p "$OUT/footer"
set +e
run_history footer "$OUT/footer"
rc=$?
set -e
[ "$rc" -eq 0 ] || report "footer scenario: expected exit 0, got $rc (stderr: $(cat "$OUT/footer.stderr.log"))"
F_JSONL="$OUT/footer/issues.jsonl"
F_JSON="$OUT/footer/calibration.json"
F_MD="$OUT/footer/calibration.md"

fcheck(){ # issue, jq path, expected
  local n="$1" path="$2" want="$3" got
  got=$(jq -r "select(.issue==$n)|$path" "$F_JSONL" 2>/dev/null || echo error)
  [ "$got" = "$want" ] || report "footer scenario, issue #$n: expected $path=$want, got $got"
}

# #1301: the body carries a quoted decoy footer (round 99) BEFORE the real
# one and an indented copy (round 98) AFTER it. Taking capture()'s first
# match yields 99; matching without line anchors yields 98; only the last
# WHOLE-LINE match yields the real 2.
fcheck 1301 .rounds 2
fcheck 1301 .rounds_source footer
fcheck 1301 '.findings|join(",")' 3
fcheck 1301 .first_pass false
fcheck 1301 .review_footers_malformed 0

# #1302: heading-only, no footer anywhere. B3: rounds null, no source, and
# excluded from the rounds statistics — never a heading-derived count.
fcheck 1302 .rounds null
fcheck 1302 .rounds_source null
fcheck 1302 .first_pass null
fcheck 1302 '.findings|length' 0

# #1303: approved at round 1, nothing requested earlier -> first pass.
fcheck 1303 .rounds 1
fcheck 1303 .first_pass true
# #1304: changes requested at round 1, approved at round 2 -> not first pass.
fcheck 1304 .rounds 2
fcheck 1304 .first_pass false

# `first_pass` is a three-way conjunction, and #1303 (all three clauses hold)
# against #1304 (all three fail) leaves every clause individually redundant —
# each could be replaced by `(true)` with the suite still green (round-2 relay
# finding 1). The three records below each violate EXACTLY ONE clause, so each
# clause is separately load-bearing. All three must also still count toward
# rounds_n: they are footer-sourced records, merely not first passes.
#
# #1306 — round 1 approved AND round 2 approved, nothing ever requested. Only
# `$maxround == 1` fails. Approved twice is not approved first time; without
# this clause the record would be counted a first pass.
fcheck 1306 .rounds 2
fcheck 1306 .rounds_source footer
fcheck 1306 .first_pass false
# #1307 — one round-1 footer carrying a verdict this script does not
# recognise. Only the round-1-approval clause fails: an unknown verdict (a
# future value, or a typo) must never be read as an approval.
fcheck 1307 .rounds 1
fcheck 1307 .rounds_source footer
fcheck 1307 .first_pass false
# #1308 — changes requested and then approved, both within round 1. Only the
# no-rejected-verdict clause fails: max round is 1 and round 1 does carry an
# approval, so without that clause this would read as a first pass.
fcheck 1308 .rounds 1
fcheck 1308 .rounds_source footer
fcheck 1308 .first_pass false
# #1305: the only whole-line candidate does not parse. Counted, not
# swallowed, and the PR stays footer-less rather than falling back.
fcheck 1305 .rounds null
fcheck 1305 .rounds_source null
fcheck 1305 .review_footers_malformed 1

f_median=$(jq -c '.repo_median' "$F_JSON")
got=$(jq -r '.n' <<<"$f_median");              [ "$got" = "8" ]  || report "footer scenario: expected repo_median.n=8, got $got"
got=$(jq -r '.rounds_n' <<<"$f_median");       [ "$got" = "6" ]  || report "footer scenario: expected repo_median.rounds_n=6 (the footer-sourced records), got $got"
got=$(jq -r '.rounds_excluded' <<<"$f_median");[ "$got" = "2" ]  || report "footer scenario: expected repo_median.rounds_excluded=2 (#1302 heading-only, #1305 malformed footer), got $got"
got=$(jq -r '.rounds_p50' <<<"$f_median");     [ "$got" = "1" ]  || report "footer scenario: expected repo_median.rounds_p50=1 over the six footer-sourced records (rounds 2,1,2,2,1,1), got $got"
# THE round-1-finding-1 assertion. Exactly one of the six footer-sourced
# records (#1303) is a first pass, so the true rate is 17% (1/6 rounded). The
# pre-fix predicate `map(select(.rounds==0))` is unsatisfiable for any
# footer-sourced record — a review round starts at 1 — so it yields 0 here
# however many first-pass PRs the sample holds. The rate is also what each
# per-clause probe moves: relaxing any single clause admits one of #1306,
# #1307 or #1308 and takes this to 33.
got=$(jq -r '.first_pass_rate' <<<"$f_median")
[ "$got" = "17" ] \
  || report "footer scenario: expected repo_median.first_pass_rate=17 (1 of 6 footer-sourced records approved at round 1), got $got — a structurally-0 rate means the predicate is still the heading-era rounds==0; 33 means a clause of the conjunction is not being applied"
[ "$got" != "0" ] \
  || report "footer scenario: first_pass_rate is 0 with a first-pass record in the sample — the statistic is structurally unsatisfiable, which is round-1 finding 1"

f_comp=$(jq -c '.completeness' "$F_JSON")
while IFS=' ' read -r key want; do
  [ -n "$key" ] || continue
  got=$(jq -r ".$key" <<<"$f_comp")
  [ "$got" = "$want" ] || report "footer scenario: expected completeness.$key=$want, got $got"
done <<'COMPLETENESS'
with_footer_rounds 6
without_footer_rounds 2
malformed_review_footers 1
first_pass_records 1
total 8
COMPLETENESS

# Decision B3 asks for the exclusion count to be PRINTED. It must reach both
# stderr and calibration.md, and calibration.md's per-row table must carry
# rounds n / rounds excl. so a rounds p50 drawn from a subset of n is visible
# in the row itself (round-1 note 7).
grep -qF "excluded from rounds_p50/first_pass_rate" "$OUT/footer.stderr.log" \
  || report "footer scenario: expected the exclusion count on stderr, got: $(cat "$OUT/footer.stderr.log")"
grep -qF "| rounds n | rounds excl. |" "$F_MD" \
  || report "footer scenario: calibration.md's table must carry rounds n / rounds excl. columns, got: $(grep -m1 '^| Area' "$F_MD" || echo '<none>')"
grep -qF "Rounds statistics (decision B3)" "$F_MD" \
  || report "footer scenario: calibration.md must state which records the rounds statistics rest on"
grep -qE 'over the 6 footer-sourced record\(s\) only; 2 record\(s\) carry no review footer' "$F_MD" \
  || report "footer scenario: expected calibration.md's rounds-statistics line to name 6 footer-sourced and 2 excluded, got: $(grep -m1 'Rounds statistics' "$F_MD" || echo '<none>')"
grep -qF "heading-fallback" "$F_JSONL" \
  && report "footer scenario: a record still carries rounds_source=heading-fallback — decision B3 forbids the heading fallback outright"

# ---------------------------------------------------------------------------
# Resume + rate-guard scenario. Run 1 must stop after page 1 (remaining=50
# < --min-remaining 100), non-zero exit, partial file with one record
# (issue #401), and a PARTIAL header naming N of M records with a reset
# time. Run 2 (no --refresh) must resume from the saved cursor, fetch only
# page_r2 (page_r1 must NOT be re-requested — asserted via the call log),
# and end with both records present, calibration.md rebuilt without the
# PARTIAL header.
# ---------------------------------------------------------------------------
mkdir -p "$OUT/resume"
calls_before_r1=$(grep -c "^CALL gh " "$CALL_LOG" || true)
set +e
run_history resume "$OUT/resume" --min-remaining 100
rc1=$?
set -e
[ "$rc1" -eq 1 ] || report "resume run 1 (rate guard): expected exit 1, got $rc1"

R1_JSONL="$OUT/resume/issues.jsonl"
R1_MD="$OUT/resume/calibration.md"
[ -s "$R1_JSONL" ] || report "resume run 1: expected a non-empty partial issues.jsonl"
n1=$(jq -s length "$R1_JSONL" 2>/dev/null || echo error)
[ "$n1" = "2" ] || report "resume run 1: expected 2 partial records (PR #601 closes #401 and #403), got $n1"
has_issue(){ jq -es --argjson n "$2" 'any(.[]; .issue==$n)' "$1"; } # file issue -> "true"/"false"
[ "$(has_issue "$R1_JSONL" 401)" = "true" ] \
  || report "resume run 1: expected issue #401's record"
[ "$(has_issue "$R1_JSONL" 403)" = "true" ] \
  || report "resume run 1: expected issue #403's record (same PR as #401)"
# The PARTIAL header must count merged PRs on BOTH sides. Page 1 holds one
# in-window merged PR (#601) out of totalCount 2, and that one PR closes TWO
# issues — so a header that counted issue records against PR totalCount would
# read "2 of 2" here and claim a complete run. It must read 1 of ~2 PRs, and
# say that ~M is an upper bound.
grep -qF 'PARTIAL — 1 of ~2 merged PRs processed' "$R1_MD" \
  || report "resume run 1: expected calibration.md header 'PARTIAL — 1 of ~2 merged PRs processed', got: $(head -3 "$R1_MD")"
grep -qE 'PARTIAL — [0-9]+ of [~0-9]+ records' "$R1_MD" \
  && report "resume run 1: calibration.md still counts issue records against merged-PR totalCount in the PARTIAL header: $(head -3 "$R1_MD")"
grep -qF 'upper bound' "$R1_MD" \
  || report "resume run 1: expected the PARTIAL header to say ~M is an upper bound (not --since-filtered), got: $(head -3 "$R1_MD")"
grep -qF "2026-02-01T00:00:00Z" "$R1_MD" \
  || report "resume run 1: expected the reset time noted in calibration.md"
[ -f "$OUT/resume/.state.json" ] || report "resume run 1: expected a saved resume cursor (.state.json)"

calls_after_r1=$(grep -c "^CALL gh " "$CALL_LOG" || true)
r1_page_calls=$((calls_after_r1 - calls_before_r1))
[ "$r1_page_calls" -eq 1 ] || report "resume run 1: expected exactly 1 gh call (one page), got $r1_page_calls"

set +e
run_history resume "$OUT/resume" --min-remaining 100
rc2=$?
set -e
[ "$rc2" -eq 0 ] || report "resume run 2: expected exit 0 (completes after resuming), got $rc2"

n2=$(jq -s length "$R1_JSONL" 2>/dev/null || echo error)
[ "$n2" = "3" ] || report "resume run 2: expected 3 total records after resuming, got $n2"
[ "$(has_issue "$R1_JSONL" 402)" = "true" ] \
  || report "resume run 2: expected issue #402's newly-collected record"
[ "$(has_issue "$R1_JSONL" 401)" = "true" ] \
  || report "resume run 2: expected issue #401's record still present, not dropped"
grep -q 'PARTIAL' "$R1_MD" \
  && report "resume run 2: calibration.md still carries a PARTIAL header after a full completion — not rebuilt (AC-6)"

# Run 2 must resume from the saved cursor -- it should request page_r2 (via
# cursor=CUR_R1), never re-request page_r1. Assert by grepping the tail of
# the call log (everything logged after run 1's calls) for that cursor arg.
run2_calls=$(awk -v n="$calls_after_r1" 'NR>n' "$CALL_LOG")
echo "$run2_calls" | grep -qF "cursor=CUR_R1" \
  || report "resume run 2: expected the resumed call to pass cursor=CUR_R1, call log tail: $run2_calls"

# ---------------------------------------------------------------------------
# Record-extraction failures are loud (finding 2, round 1). One page, two PR
# nodes: #801's issue #701 has null `labels`/`comments` (must still be
# recorded, and must not take its well-formed sibling #702 down with it), and
# #802 is malformed beyond rescue (must be named on stderr, counted in
# completeness.dropped_pr_nodes, and force a non-zero exit — never a silent
# drop reported as a complete run).
# ---------------------------------------------------------------------------
mkdir -p "$OUT/tolerant"
set +e
run_history tolerant "$OUT/tolerant"
rc=$?
set -e
[ "$rc" -eq 3 ] || report "tolerant scenario: expected exit 3 (a PR node's records were dropped), got $rc"

T_JSONL="$OUT/tolerant/issues.jsonl"
nt=$(jq -s length "$T_JSONL" 2>/dev/null || echo error)
[ "$nt" = "2" ] || report "tolerant scenario: expected 2 records (#701 with null labels and its sibling #702), got $nt"
[ "$(has_issue "$T_JSONL" 701)" = "true" ] \
  || report "tolerant scenario: issue #701 (null labels/comments) was dropped instead of recorded"
[ "$(has_issue "$T_JSONL" 702)" = "true" ] \
  || report "tolerant scenario: well-formed sibling #702 was lost along with its PR node"
[ "$(has_issue "$T_JSONL" 703)" = "false" ] \
  || report "tolerant scenario: #703 came from the malformed PR node and cannot have been recorded"

rec701=$(jq -c 'select(.issue==701)' "$T_JSONL" 2>/dev/null || echo "")
if [ -n "$rec701" ]; then
  got=$(jq -r '.areas|length' <<<"$rec701")
  [ "$got" = "0" ] || report "tolerant scenario: #701 has null labels, expected areas=[], got length $got"
  got=$(jq -r '.size_est' <<<"$rec701")
  [ "$got" = "null" ] || report "tolerant scenario: #701 has null labels, expected size_est=null, got $got"
fi
rec702=$(jq -c 'select(.issue==702)' "$T_JSONL" 2>/dev/null || echo "")
if [ -n "$rec702" ]; then
  got=$(jq -r '.size_est' <<<"$rec702")
  [ "$got" = "L" ] || report "tolerant scenario: #702 carries size:l, expected size_est=L, got $got"
fi

grep -qF "record extraction failed for merged PR #802" "$OUT/tolerant.stderr.log" \
  || report "tolerant scenario: expected stderr to name the PR node whose records were dropped, got: $(cat "$OUT/tolerant.stderr.log")"
grep -qF "MISSING" "$OUT/tolerant.stderr.log" \
  || report "tolerant scenario: expected stderr to say the dropped records are MISSING from the output"
grep -qF "INCOMPLETE: 1 of" "$OUT/tolerant.stderr.log" \
  || report "tolerant scenario: expected an exit-time INCOMPLETE summary counting the dropped node, got: $(cat "$OUT/tolerant.stderr.log")"
dropped=$(jq -r '.completeness.dropped_pr_nodes' "$OUT/tolerant/calibration.json" 2>/dev/null || echo error)
[ "$dropped" = "1" ] \
  || report "tolerant scenario: expected calibration.json completeness.dropped_pr_nodes=1, got $dropped"

# ---------------------------------------------------------------------------
# The rate guard fails CLOSED (finding 3, round 1): an unreadable rateLimit
# block is a named stop, not headroom, and the exit line never prints a
# non-number as the remaining budget.
# ---------------------------------------------------------------------------
mkdir -p "$OUT/ratenull"
set +e
run_history ratenull "$OUT/ratenull"
rc=$?
set -e
[ "$rc" -eq 1 ] || report "rateLimit null: expected exit 1 (stop), got $rc"
grep -qF "unreadable rate limit" "$OUT/ratenull.stderr.log" \
  || report "rateLimit null: expected a named 'unreadable rate limit' error, got: $(cat "$OUT/ratenull.stderr.log")"
grep -qF "remaining requests at exit: null" "$OUT/ratenull.stderr.log" \
  && report "rateLimit null: the run charged past the guard and reported a non-number as its remaining budget"

mkdir -p "$OUT/ratebad"
set +e
run_history ratebadreset "$OUT/ratebad"
rc=$?
set -e
[ "$rc" -eq 1 ] || report "rateLimit resetAt malformed: expected exit 1 (stop), got $rc"
grep -qF "resetAt" "$OUT/ratebad.stderr.log" \
  || report "rateLimit resetAt malformed: expected the error to name resetAt, got: $(cat "$OUT/ratebad.stderr.log")"

# ---------------------------------------------------------------------------
# Issue.parent fallback (note 6, round 1): a schema that rejects the field
# must produce one warning, a retry without it, and a completed run whose
# records all carry parent=null.
# ---------------------------------------------------------------------------
mkdir -p "$OUT/noparent"
calls_before_np=$(grep -c "^CALL gh " "$CALL_LOG" || true)
set +e
run_history noparent "$OUT/noparent"
rc=$?
set -e
[ "$rc" -eq 0 ] || report "noparent scenario: expected exit 0 after the retry, got $rc"
grep -qF "rejects Issue.parent" "$OUT/noparent.stderr.log" \
  || report "noparent scenario: expected the one-time warning naming Issue.parent, got: $(cat "$OUT/noparent.stderr.log")"
calls_after_np=$(grep -c "^CALL gh " "$CALL_LOG" || true)
np_calls=$((calls_after_np - calls_before_np))
[ "$np_calls" -eq 2 ] \
  || report "noparent scenario: expected exactly 2 gh calls (rejected query + retry without the field), got $np_calls"
rec1101=$(jq -c 'select(.issue==1101)' "$OUT/noparent/issues.jsonl" 2>/dev/null || echo "")
[ -n "$rec1101" ] || report "noparent scenario: expected issue #1101's record from the retried query"
if [ -n "$rec1101" ]; then
  got=$(jq -r '.parent' <<<"$rec1101")
  [ "$got" = "null" ] || report "noparent scenario: expected parent=null on every record, got $got"
  got=$(jq -r '.size_est' <<<"$rec1101")
  [ "$got" = "S" ] || report "noparent scenario: expected size_est=S from the size:s label, got $got"
fi

# ---------------------------------------------------------------------------
# Stale-reuse guard (finding 5, round 1): issues.jsonl carries the --repo and
# --since that built it, and a mismatched (or unprovenanced) reuse is a hard
# stop naming both sides — before any gh call — rather than a quiet pooling
# of two different samples. --refresh is the way through.
# ---------------------------------------------------------------------------
cp -r "$OUT/run" "$OUT/prov"
[ -s "$OUT/prov/.provenance.json" ] || report "provenance: expected the completed run to leave a .provenance.json"

calls_before_prov=$(grep -c "^CALL gh " "$CALL_LOG" || true)
set +e
MOCK_GH_FIXTURES="$FIXTURES" MOCK_GH_CALL_LOG="$CALL_LOG" MOCK_GH_SCENARIO=main PATH="$BIN:$PATH" \
  "$HISTORY_SH" --repo "$REPO" --since "2026-02-01" --out "$OUT/prov" \
  >"$OUT/prov.since.stdout.log" 2>"$OUT/prov.since.stderr.log"
rc=$?
set -e
[ "$rc" -eq 1 ] || report "provenance (--since mismatch): expected exit 1, got $rc"
if ! grep -qF "2026-01-01" "$OUT/prov.since.stderr.log" || ! grep -qF "2026-02-01" "$OUT/prov.since.stderr.log"; then
  report "provenance (--since mismatch): expected the error to name both windows, got: $(cat "$OUT/prov.since.stderr.log")"
fi
grep -qF -- "--refresh" "$OUT/prov.since.stderr.log" \
  || report "provenance (--since mismatch): expected the error to name --refresh as the way through"

set +e
MOCK_GH_FIXTURES="$FIXTURES" MOCK_GH_CALL_LOG="$CALL_LOG" MOCK_GH_SCENARIO=main PATH="$BIN:$PATH" \
  "$HISTORY_SH" --repo "other-org/other-repo" --since "$SINCE" --out "$OUT/prov" \
  >"$OUT/prov.repo.stdout.log" 2>"$OUT/prov.repo.stderr.log"
rc=$?
set -e
[ "$rc" -eq 1 ] || report "provenance (--repo mismatch): expected exit 1, got $rc"
if ! grep -qF "$REPO" "$OUT/prov.repo.stderr.log" || ! grep -qF "other-org/other-repo" "$OUT/prov.repo.stderr.log"; then
  report "provenance (--repo mismatch): expected the error to name both repos, got: $(cat "$OUT/prov.repo.stderr.log")"
fi

rm -f "$OUT/prov/.provenance.json"
set +e
MOCK_GH_FIXTURES="$FIXTURES" MOCK_GH_CALL_LOG="$CALL_LOG" MOCK_GH_SCENARIO=main PATH="$BIN:$PATH" \
  "$HISTORY_SH" --repo "$REPO" --since "$SINCE" --out "$OUT/prov" \
  >"$OUT/prov.none.stdout.log" 2>"$OUT/prov.none.stderr.log"
rc=$?
set -e
[ "$rc" -eq 1 ] || report "provenance (absent): expected a non-empty issues.jsonl with no provenance to stop the run, got exit $rc"
grep -qF "no provenance" "$OUT/prov.none.stderr.log" \
  || report "provenance (absent): expected a 'no provenance' error, got: $(cat "$OUT/prov.none.stderr.log")"

calls_after_prov=$(grep -c "^CALL gh " "$CALL_LOG" || true)
[ "$calls_after_prov" -eq "$calls_before_prov" ] \
  || report "provenance: the stale-reuse stops must happen before any gh call, got $((calls_after_prov - calls_before_prov)) call(s)"

# --refresh rebuilds under the new window instead of stopping.
set +e
MOCK_GH_FIXTURES="$FIXTURES" MOCK_GH_CALL_LOG="$CALL_LOG" MOCK_GH_SCENARIO=main PATH="$BIN:$PATH" \
  "$HISTORY_SH" --repo "$REPO" --since "2026-02-01" --out "$OUT/prov" --refresh \
  >"$OUT/prov.refresh.stdout.log" 2>"$OUT/prov.refresh.stderr.log"
rc=$?
set -e
[ "$rc" -eq 0 ] || report "provenance (--refresh): expected exit 0 rebuilding under the new window, got $rc (stderr: $(cat "$OUT/prov.refresh.stderr.log"))"
got=$(jq -r '.since' "$OUT/prov/.provenance.json" 2>/dev/null || echo error)
[ "$got" = "2026-02-01" ] || report "provenance (--refresh): expected the provenance rewritten to the new window, got $got"

# The default --out is keyed by repository, so two repos cannot pool into one
# directory when --out is left off.
DEFOUT="$WORK/defout"
mkdir -p "$DEFOUT"
set +e
MOCK_GH_FIXTURES="$FIXTURES" MOCK_GH_CALL_LOG="$CALL_LOG" MOCK_GH_SCENARIO=main PATH="$BIN:$PATH" \
  TMPDIR="$DEFOUT" "$HISTORY_SH" --repo "$REPO" --since "$SINCE" \
  >"$OUT/defout.stdout.log" 2>"$OUT/defout.stderr.log"
rc=$?
set -e
[ "$rc" -eq 0 ] || report "default --out: expected exit 0, got $rc (stderr: $(cat "$OUT/defout.stderr.log"))"
[ -s "$DEFOUT/plan-work-history/test-org__test-repo/issues.jsonl" ] \
  || report "default --out: expected a repo-keyed default directory, got: $(find "$DEFOUT" -maxdepth 3 | tr '\n' ' ')"
[ -e "$DEFOUT/plan-work-history/issues.jsonl" ] \
  && report "default --out: records landed in the un-keyed shared directory, where a second repo's run would pool with them"

# ---------------------------------------------------------------------------
# --aggregate-only (AC-7): rebuilds calibration from a hand-built
# issues.jsonl with zero gh calls.
# ---------------------------------------------------------------------------
mkdir -p "$OUT/agg"
cat > "$OUT/agg/issues.jsonl" <<'JSONL'
{"issue":901,"title":"agg-only fixture","pr":701,"type":"chore","areas":["area:tests"],"severity":null,"priority":null,"milestone":null,"parent":null,"created":"2026-01-01T00:00:00Z","started":"2026-01-01T00:00:00Z","start_source":"issue-created","pr_opened":"2026-01-01T00:00:00Z","merged":"2026-01-02T00:00:00Z","closed":"2026-01-02T00:00:00Z","cycle_hours":24,"cycle_days":1,"rounds":0,"findings":[],"additions":10,"deletions":0,"files":1,"net_loc":10,"size_est":"S","estimate_text":null,"metrics":null,"deferred":[],"era":null}
JSONL
calls_before_agg=$(grep -c "^CALL gh " "$CALL_LOG" || true)
set +e
MOCK_GH_FIXTURES="$FIXTURES" MOCK_GH_CALL_LOG="$CALL_LOG" MOCK_GH_SCENARIO=main PATH="$BIN:$PATH" \
  "$HISTORY_SH" --repo "$REPO" --out "$OUT/agg" --aggregate-only \
  >"$OUT/agg.stdout.log" 2>"$OUT/agg.stderr.log"
rc=$?
set -e
[ "$rc" -eq 0 ] || report "--aggregate-only: expected exit 0, got $rc (stderr: $(cat "$OUT/agg.stderr.log"))"
calls_after_agg=$(grep -c "^CALL gh " "$CALL_LOG" || true)
[ "$calls_after_agg" -eq "$calls_before_agg" ] || report "--aggregate-only: expected zero gh calls, got $((calls_after_agg - calls_before_agg))"
[ -s "$OUT/agg/calibration.json" ] || report "--aggregate-only: expected calibration.json to be (re)built"
[ -s "$OUT/agg/calibration.md" ] || report "--aggregate-only: expected calibration.md to be (re)built"
grep -qF "area:tests" "$OUT/agg/calibration.md" || report "--aggregate-only: expected the area:tests row in the rebuilt table"

# ---------------------------------------------------------------------------
# Observed parallelism has no silent default (round-2 note 5). One malformed
# `started`/`merged` value is enough to fail the jq that computes it; the
# fallback must be visibly distinct from a computed figure, because
# timeline.sh consumes parallelism.txt as a planning input and a literal `1`
# renders as "observed parallelism: 1.00" — indistinguishable from a genuine
# 1.00. An EMPTY parallelism.txt is the shape timeline.sh already documents as
# "no history" and reports falling back from.
# ---------------------------------------------------------------------------
mkdir -p "$OUT/parbad"
printf '%s\n' '{"issue":901,"pr":902,"areas":["area:tests"],"started":"not-a-date","merged":"2026-01-02T00:00:00Z","cycle_hours":1,"rounds":0,"net_loc":10,"size_est":null,"metrics":null,"metrics_malformed":false,"start_source":"assigned"}' > "$OUT/parbad/issues.jsonl"
set +e
MOCK_GH_FIXTURES="$FIXTURES" MOCK_GH_CALL_LOG="$CALL_LOG" MOCK_GH_SCENARIO=main PATH="$BIN:$PATH" \
  "$HISTORY_SH" --repo "$REPO" --out "$OUT/parbad" --aggregate-only \
  >"$OUT/parbad.stdout.log" 2>"$OUT/parbad.stderr.log"
rc=$?
set -e
[ "$rc" -eq 0 ] || report "parallelism fallback: expected exit 0, got $rc (stderr: $(cat "$OUT/parbad.stderr.log"))"
grep -qF "observed parallelism could not be computed" "$OUT/parbad.stderr.log" \
  || report "parallelism fallback: the failure must be named on stderr, got: $(cat "$OUT/parbad.stderr.log")"
grep -qF "observed parallelism: unavailable" "$OUT/parbad/calibration.md" \
  || report "parallelism fallback: calibration.md must say 'unavailable', got: $(grep -m1 '^Records:' "$OUT/parbad/calibration.md")"
if grep -qE 'observed parallelism: [0-9]' "$OUT/parbad/calibration.md"; then
  report "parallelism fallback: calibration.md reports a NUMBER for a parallelism that could not be computed"
fi
[ ! -s "$OUT/parbad/parallelism.txt" ] \
  || report "parallelism fallback: parallelism.txt must be left empty, got: $(cat "$OUT/parbad/parallelism.txt")"

# ---------------------------------------------------------------------------
# AC-6 on the fatal in-loop exits (round-2 finding 1): a run that appends
# records and THEN dies must still leave calibration.md describing the
# issues.jsonl that exists at exit. Two shapes, both reproduced by the round-2
# review: the `gh api graphql` call for page 2 fails, and page 2's response
# carries an unreadable rateLimit block. Each is preceded by a clean run
# against the same --out, so a table left over from that run reads "Records:
# 1" while the file holds 2 — verbatim the state AC-6 forbids.
# ---------------------------------------------------------------------------
cut_short_case(){ # scenario, out_dir, expected_stderr_fragment
  local scenario="$1" dir="$2" want_err="$3" rc=0 n_file n_table

  mkdir -p "$dir"
  set +e
  run_history cutfirst "$dir"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || report "$scenario: the priming clean run expected exit 0, got $rc"
  n_file=$(jq -s length "$dir/issues.jsonl" 2>/dev/null || echo error)
  [ "$n_file" = "1" ] || report "$scenario: the priming run should leave 1 record, got $n_file"
  grep -qE '^Records: 1( |$)' "$dir/calibration.md" \
    || report "$scenario: the priming run's table should read 'Records: 1', got: $(grep -m1 '^Records:' "$dir/calibration.md" || echo '<none>')"

  # The cut-short run: page 1 appends a second record, page 2 dies.
  set +e
  run_history "$scenario" "$dir"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || report "$scenario: a run cut short must exit non-zero, got $rc"
  [ "$rc" -le 3 ] || report "$scenario: exit $rc is not one of the documented codes 0/1/2/3"
  grep -qF "$want_err" "$dir.stderr.log" \
    || report "$scenario: expected '$want_err' on stderr, got: $(cat "$dir.stderr.log")"

  n_file=$(jq -s length "$dir/issues.jsonl" 2>/dev/null || echo error)
  [ "$n_file" = "2" ] || report "$scenario: expected 2 records in issues.jsonl at exit, got $n_file"
  n_table=$(sed -n 's/^Records: \([0-9][0-9]*\).*/\1/p' "$dir/calibration.md" | head -1)
  [ -n "$n_table" ] || report "$scenario: calibration.md has no 'Records:' line at exit"
  # THE assertion: the table and the file agree at exit, whatever the run did.
  [ "$n_table" = "$n_file" ] \
    || report "$scenario: AC-6 violated — calibration.md reads 'Records: $n_table' while issues.jsonl holds $n_file records"
  grep -q 'CUT SHORT' "$dir/calibration.md" \
    || report "$scenario: the rebuilt table should be headed CUT SHORT, got: $(head -2 "$dir/calibration.md")"
}

cut_short_case cutfail    "$OUT/cutfail"    "HTTP 502 Bad Gateway"
cut_short_case cutbadrate "$OUT/cutbadrate" "unreadable rate limit"

# ---------------------------------------------------------------------------
# AC-4 resume over an interrupted append (round-2 finding 2): issues.jsonl
# whose FINAL line is truncated is what a run killed mid-append leaves behind.
# The resumed run must repair that one partial line loudly, keep the dedupe
# set built from the complete records before it, append only records it does
# not already have, and leave every line valid JSON. Emptying the dedupe set
# on the parse failure (the pre-fix behaviour) re-appends a record the file
# already holds, glues it onto the fragment, and exits with an undocumented
# code.
# ---------------------------------------------------------------------------
mkdir -p "$OUT/truncseed"
set +e
run_history main "$OUT/truncseed"
rc=$?
set -e
[ "$rc" -eq 0 ] || report "truncated-resume: the seed run expected exit 0, got $rc"

mkdir -p "$OUT/trunc"
# One complete record (issue #301, already collected) followed by a fragment
# of the next one — byte-for-byte the shape of an interrupted append.
jq -c 'select(.issue==301)' "$OUT/truncseed/issues.jsonl" > "$OUT/trunc/issues.jsonl"
printf '%s' '{"issue":302,"pr":501,"title":"Sibling issue","are' >> "$OUT/trunc/issues.jsonl"
jq -n --arg repo "$REPO" --arg since "$SINCE" '{repo:$repo,since:$since}' > "$OUT/trunc/.provenance.json"
seed_lines=$(awk 'END{print NR}' "$OUT/trunc/issues.jsonl")
[ "$seed_lines" = "2" ] || report "truncated-resume: the seeded file should hold 2 lines, got $seed_lines"

set +e
run_history main "$OUT/trunc"
rc=$?
set -e
[ "$rc" -eq 0 ] || report "truncated-resume: expected the documented exit 0, got $rc (an interrupted append must not be a crash)"
grep -qF "TRUNCATED record" "$OUT/trunc.stderr.log" \
  || report "truncated-resume: the truncated final line must be reported loudly on stderr, got: $(cat "$OUT/trunc.stderr.log")"

# Every line valid JSON: a record appended onto the fragment would not be.
bad_line=$(awk 'NR>0' "$OUT/trunc/issues.jsonl" | while IFS= read -r l; do
  jq -e . >/dev/null 2>&1 <<<"$l" || printf '%s' "$l"
done)
[ -z "$bad_line" ] || report "truncated-resume: issues.jsonl holds a malformed line after the run: $bad_line"

n301=$(jq -s '[.[]|select(.issue==301 and .pr==501)]|length' "$OUT/trunc/issues.jsonl" 2>/dev/null || echo error)
[ "$n301" = "1" ] || report "truncated-resume: issue #301 should appear exactly once (the dedupe set must survive the parse failure), got $n301"
n302=$(jq -s '[.[]|select(.issue==302)]|length' "$OUT/trunc/issues.jsonl" 2>/dev/null || echo error)
[ "$n302" = "1" ] || report "truncated-resume: issue #302 (the record the truncated line lost) should be re-collected exactly once, got $n302"
n_trunc=$(jq -s length "$OUT/trunc/issues.jsonl" 2>/dev/null || echo error)
[ "$n_trunc" = "2" ] || report "truncated-resume: expected 2 records after the resume, got $n_trunc"
grep -qE '^Records: 2( |$)' "$OUT/trunc/calibration.md" \
  || report "truncated-resume: calibration.md should read 'Records: 2', got: $(grep -m1 '^Records:' "$OUT/trunc/calibration.md" || echo '<none>')"

# A malformed line that is NOT the trailing partial is corruption, not an
# interrupted append: a named stop pointing at --refresh, at a documented code.
mkdir -p "$OUT/corrupt"
{ printf '%s\n' '{"issue":901,"pr":9' ; jq -c 'select(.issue==301)' "$OUT/truncseed/issues.jsonl" ; } > "$OUT/corrupt/issues.jsonl"
jq -n --arg repo "$REPO" --arg since "$SINCE" '{repo:$repo,since:$since}' > "$OUT/corrupt/.provenance.json"
set +e
run_history main "$OUT/corrupt"
rc=$?
set -e
[ "$rc" -eq 1 ] || report "corrupt-resume: expected the documented exit 1, got $rc"
grep -qF -- "--refresh" "$OUT/corrupt.stderr.log" \
  || report "corrupt-resume: the stop must point at --refresh, got: $(cat "$OUT/corrupt.stderr.log")"
grep -qF "line 1" "$OUT/corrupt.stderr.log" \
  || report "corrupt-resume: the stop must name the offending line, got: $(cat "$OUT/corrupt.stderr.log")"

# ---------------------------------------------------------------------------
# An unreadable issues.jsonl is a NAMED stop at a documented code (round-3
# finding R1). Left to `awk`, this path failed inside build_seen and awk's own
# exit status (2) surfaced as the script's "usage error" code, carrying only
# awk's raw "Permission denied" — no `error:` prefix, no file named, no
# remedy. Two claims are asserted: the code is 1, not 2, and the message is in
# the same shape as the provenance and corrupt-line guards.
# ---------------------------------------------------------------------------
mkdir -p "$OUT/unreadable"
jq -c 'select(.issue==301)' "$OUT/truncseed/issues.jsonl" > "$OUT/unreadable/issues.jsonl"
jq -n --arg repo "$REPO" --arg since "$SINCE" '{repo:$repo,since:$since}' > "$OUT/unreadable/.provenance.json"
chmod 000 "$OUT/unreadable/issues.jsonl"
if [ -r "$OUT/unreadable/issues.jsonl" ]; then
  # root (or an ACL) ignores mode 000, so the case cannot be staged; say so
  # rather than passing vacuously.
  echo "SKIP: unreadable-issues.jsonl case — the file is still readable at mode 000 (running as uid $(id -u)?)" >&2
else
  set +e
  run_history main "$OUT/unreadable"
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || report "unreadable issues.jsonl: expected the documented exit 1, got $rc (awk's own status must not surface as this script's exit code)"
  [ "$rc" -ne 2 ] || report "unreadable issues.jsonl: exited 2 — the header's 'usage error' code — for a file-permission failure"
  grep -q '^error: ' "$OUT/unreadable.stderr.log" \
    || report "unreadable issues.jsonl: expected a named 'error: ' stop like the other guards, got: $(cat "$OUT/unreadable.stderr.log")"
  grep -qF "is not readable" "$OUT/unreadable.stderr.log" \
    || report "unreadable issues.jsonl: the error must say the file is not readable, got: $(cat "$OUT/unreadable.stderr.log")"
  grep -qF "$OUT/unreadable/issues.jsonl" "$OUT/unreadable.stderr.log" \
    || report "unreadable issues.jsonl: the error must name the file, got: $(cat "$OUT/unreadable.stderr.log")"
  grep -qF -- "--refresh" "$OUT/unreadable.stderr.log" \
    || report "unreadable issues.jsonl: the error must point at a remedy (--refresh), got: $(cat "$OUT/unreadable.stderr.log")"
fi
chmod 644 "$OUT/unreadable/issues.jsonl"

# ---------------------------------------------------------------------------
# Named mutation probe (#778). The suite's own assertions are only worth
# anything if they fail when the behaviour they describe changes, so one
# mutation is named here with the assertion it breaks and the message it
# produces. Probed by hand against a copy of history.sh OUTSIDE the worktree
# (the splice-restore recipe: never against the tracked file), and recorded
# in the PR body's Splice results.
#
# Mutation: in history.sh's RECORD_JQ, revert the footer extraction to the
# pre-fix single `capture("<!-- review (?<f>\{.*?\}) -->";"s")` — i.e. the
# FIRST match anywhere in the body rather than the LAST whole-line one.
# Assertion broken: the footer scenario's #1301 checks above.
# Failure message: `FAIL: footer scenario, issue #1301: expected .rounds=2,
# got 99` — the round taken from the decoy footer the comment merely quotes.
#
# Second mutation, for the statistic rather than the extraction: change
# `select(.first_pass==true)` back to `select(.rounds==0)` in `aggregate`.
# Assertion broken: the first_pass_rate check in the footer scenario.
# Failure message: `FAIL: footer scenario: expected
# repo_median.first_pass_rate=17 (1 of 6 footer-sourced records approved at
# round 1), got 0 — a structurally-0 rate means the predicate is still the
# heading-era rounds==0; 33 means a clause of the conjunction is not being
# applied`.
#
# `first_pass` is a three-way conjunction, and an aggregate-level probe like
# the one above cannot tell which clause is doing the work: with only the
# all-hold and all-fail fixtures, each clause could be replaced by `(true)`
# and the suite would still pass (round-2 relay finding 1). Fixtures #1306,
# #1307 and #1308 each violate exactly ONE clause, so each clause has its own
# mutation and its own failing assertion. All three mutations replace one
# conjunct of RECORD_JQ's `$first_pass` expression with `(true)`:
#
# Mutation 3 — drop the no-rejected-verdict clause, i.e. replace
# `(($verdicts|map(select(.=="changes_requested" or ...))|length) == 0)` with
# `(true)`. Assertion broken: #1308 (changes requested then approved, both in
# round 1). Failure message: `FAIL: footer scenario, issue #1308: expected
# .first_pass=false, got true`, alongside `expected
# repo_median.first_pass_rate=17 …, got 33`.
#
# Mutation 4 — drop the max-round clause, i.e. replace `($maxround == 1)`
# with `(true)`. Assertion broken: #1306 (approved at round 1 AND at round
# 2). Failure message: `FAIL: footer scenario, issue #1306: expected
# .first_pass=false, got true`, alongside the same rate assertion at 33.
#
# Mutation 5 — drop the round-1-approval clause, i.e. replace the
# `map(select((.round // 0) == 1))|map(.verdict // "")|any(. == "approved")`
# conjunct with `(true)`. Assertion broken: #1307 (round 1, unrecognised
# verdict). Failure message: `FAIL: footer scenario, issue #1307: expected
# .first_pass=false, got true`, alongside the same rate assertion at 33.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Hermeticity: the tripwire itself is load-bearing (an unmocked call really
# is caught), and no call anywhere in this run was made from an unmocked
# context.
# ---------------------------------------------------------------------------
TRIPWIRE_LOG="$WORK/tripwire.log"
: > "$TRIPWIRE_LOG"
set +e
env -u MOCK_GH_FIXTURES PATH="$BIN:$PATH" MOCK_GH_CALL_LOG="$TRIPWIRE_LOG" \
  gh api graphql -f query='query { x }' >/dev/null 2>&1
set -e
grep -q '^UNMOCKED-CONTEXT ' "$TRIPWIRE_LOG" \
  || report "tripwire probe: an unmocked-context gh call was NOT marked — the tripwire is not load-bearing"

[ -s "$CALL_LOG" ] || report "hermeticity: the mock recorded zero invocations — the call log is not wired up"
if grep -q '^UNMOCKED-CONTEXT ' "$CALL_LOG"; then
  report "hermeticity: a gh call was made from an unmocked context: $(grep -m1 '^UNMOCKED-CONTEXT ' "$CALL_LOG")"
fi

if [ "$fail" -ne 0 ]; then
  echo "test_history: FAILED" >&2
  exit 1
fi

echo "test_history: all assertions passed (repo=$REPO)"
